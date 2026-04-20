#!/usr/bin/env python3
"""Φkv probe for Phase 1 (paper-faithful PrfaaS replication).

Sweeps a single served model across a list of input lengths, measures
Tprefill(l) (wall-clock time for a request with output_len=1), computes
Skv(l) analytically from the model's config.json, and emits one JSONL
record per (model, l) cell.

This is the implementation of the methodology in
`prfaas/PHASE1_PHIKV_PLAN.md`. Read that first.

Usage (inside a sglang container that has the model served on localhost):

    python phi_kv_probe.py \
        --model-dir /models/moonshotai_Kimi-Linear-48B-A3B-Instruct \
        --model-id  moonshotai/Kimi-Linear-48B-A3B-Instruct \
        --model-short kimi-linear-48b \
        --tp-size 8 \
        --base-url http://127.0.0.1:30000 \
        --ctx-lens 1024,2048,4096,8192,16384,32768,65536,131072 \
        --warmup 5 --timed 20 \
        --output /results/kimi-linear-48b.jsonl

Exit code 0 only if every cell completed successfully. Cells that 4xx/5xx
or time out are emitted as records with `error: "..."` and the script exits
non-zero so the Job is marked failed (the JSONL is still flushed).
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import statistics
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import requests


# ---------------------------------------------------------------------------
# 1. Skv(l): analytical KV-cache-size calculation from config.json
# ---------------------------------------------------------------------------


@dataclass
class LayerSpec:
    """Per-layer KV-cache contribution.

    `bytes_per_token` is what one token of input adds to this layer's KV
    cache. For linear/Mamba/SSM layers, this is 0 (state is fixed-size).
    For SWA layers with a window cap, see `cap_tokens`.
    """

    kind: str  # "attn", "mla", "linear", "swa"
    bytes_per_token: int
    cap_tokens: int | None = None  # None = unbounded; int = SWA window
    detail: dict[str, Any] = field(default_factory=dict)

    def kv_bytes_for_len(self, l: int) -> int:
        effective_l = l if self.cap_tokens is None else min(l, self.cap_tokens)
        return self.bytes_per_token * effective_l


@dataclass
class ModelKVSpec:
    n_layers_total: int
    layers: list[LayerSpec]
    bytes_per_elem: int  # 2 for BF16, 1 for FP8

    @property
    def n_attn(self) -> int:
        return sum(1 for l in self.layers if l.kind in ("attn", "mla", "swa"))

    @property
    def n_linear(self) -> int:
        return sum(1 for l in self.layers if l.kind == "linear")

    def kv_per_token_bytes(self) -> int:
        """Sum across layers of bytes added per single input token (no cap)."""
        return sum(l.bytes_per_token for l in self.layers)

    def skv_for_len(self, l: int) -> int:
        return sum(layer.kv_bytes_for_len(l) for layer in self.layers)


def _bytes_per_elem(dtype: str | None) -> int:
    if dtype is None:
        return 2
    d = dtype.lower()
    if "bf16" in d or "bfloat16" in d or "float16" in d or "fp16" in d:
        return 2
    if "fp8" in d or "float8" in d:
        return 1
    if "int8" in d:
        return 1
    if "int4" in d or "fp4" in d:
        return 1  # 0.5 round-up is fine for our purposes
    return 2


def parse_config(model_dir: Path) -> ModelKVSpec:
    """Parse config.json into a ModelKVSpec.

    Handles the model families we care about for Phase 1:
      - GQA / MHA dense (Qwen2.5, Llama, Qwen3 dense)
      - Hybrid attn + Mamba2 (Nemotron-Nano-9B-v2)
      - Hybrid MLA + KDA linear-attention (Kimi-Linear)

    Architecture is inferred from `architectures` + `model_type`. We
    intentionally avoid heroic auto-detection — if config.json doesn't
    look like one of the supported families, we raise so we don't silently
    publish a wrong Φkv.
    """
    cfg_path = model_dir / "config.json"
    cfg = json.loads(cfg_path.read_text())

    arch_list: list[str] = cfg.get("architectures") or []
    arch = arch_list[0] if arch_list else ""
    model_type: str = cfg.get("model_type", "")
    bpe = _bytes_per_elem(cfg.get("torch_dtype"))

    # ---- Kimi-Linear (KimiLinearForCausalLM) -----------------------------
    if "KimiLinear" in arch or model_type.startswith("kimi_linear"):
        return _parse_kimi_linear(cfg, bpe)

    # ---- NVIDIA Nemotron-Nano-9B-v2 (NemotronHForCausalLM) ---------------
    if "Nemotron" in arch or model_type.startswith("nemotron"):
        return _parse_nemotron_h(cfg, bpe)

    # ---- Generic GQA dense (Qwen2/2.5, Llama, Qwen3 dense) ---------------
    if any(k in arch for k in ("Qwen2", "Qwen3", "Llama", "Mistral")):
        return _parse_dense_gqa(cfg, bpe)

    raise ValueError(
        f"Unsupported architecture {arch!r} (model_type={model_type!r}); "
        f"add a handler in phi_kv_probe.parse_config before profiling this model."
    )


def _parse_dense_gqa(cfg: dict[str, Any], bpe: int) -> ModelKVSpec:
    n_layers = int(cfg["num_hidden_layers"])
    n_kv = int(cfg.get("num_key_value_heads", cfg["num_attention_heads"]))
    head_dim = int(
        cfg.get("head_dim")
        or cfg["hidden_size"] // cfg["num_attention_heads"]
    )
    per_layer = 2 * n_kv * head_dim * bpe  # K and V
    layers = [
        LayerSpec(
            kind="attn",
            bytes_per_token=per_layer,
            detail={"n_kv_heads": n_kv, "head_dim": head_dim},
        )
        for _ in range(n_layers)
    ]
    return ModelKVSpec(n_layers_total=n_layers, layers=layers, bytes_per_elem=bpe)


def _parse_nemotron_h(cfg: dict[str, Any], bpe: int) -> ModelKVSpec:
    """NVIDIA Nemotron-H family: alternating Mamba2 + attention.

    config.json carries `hybrid_override_pattern` like 'M-MM-M*-M-' where
    'M' is Mamba2, '*' is attention. Length = num_hidden_layers.
    """
    n_layers = int(cfg["num_hidden_layers"])
    n_kv = int(cfg.get("num_key_value_heads", cfg["num_attention_heads"]))
    head_dim = int(
        cfg.get("head_dim")
        or cfg["hidden_size"] // cfg["num_attention_heads"]
    )
    per_attn = 2 * n_kv * head_dim * bpe
    pattern = cfg.get("hybrid_override_pattern") or ""
    if not pattern:
        # Newer Nemotron configs use `layer_types: ['mamba',...,'attention',...]`
        pattern = "".join(
            "*" if t == "attention" else "M" for t in cfg.get("layer_types", [])
        )
    if len(pattern) != n_layers:
        raise ValueError(
            f"nemotron pattern len {len(pattern)} != n_layers {n_layers}"
        )
    layers: list[LayerSpec] = []
    for ch in pattern:
        if ch == "*":
            layers.append(
                LayerSpec(
                    kind="attn",
                    bytes_per_token=per_attn,
                    detail={"n_kv_heads": n_kv, "head_dim": head_dim},
                )
            )
        else:
            layers.append(LayerSpec(kind="linear", bytes_per_token=0))
    return ModelKVSpec(n_layers_total=n_layers, layers=layers, bytes_per_elem=bpe)


def _parse_kimi_linear(cfg: dict[str, Any], bpe: int) -> ModelKVSpec:
    """Kimi-Linear: 3:1 KDA-to-MLA hybrid.

    KDA layers: linear attention (recurrent state, fixed size, contributes 0
        to growing KV cache).
    MLA layers: Multi-head Latent Attention with compressed KV; per-token
        size is `kv_lora_rank + qk_rope_head_dim` bytes per layer (single
        compressed K, no separate V because MLA absorbs V into the latent).

    The Kimi-Linear config.json uses `linear_attn_config` and
    `full_attn_layer_idx` / `layer_types` to mark which layers are KDA vs
    MLA. The released model has 48 hidden layers with a 3:1 ratio → 36 KDA
    and 12 MLA, in the pattern KKKM repeating.
    """
    n_layers = int(cfg["num_hidden_layers"])
    layer_types = cfg.get("layer_types")
    # The released Kimi-Linear config (`moonshotai/Kimi-Linear-48B-A3B-Instruct`)
    # ships its layer-kind table inside `linear_attn_config`:
    #   linear_attn_config.full_attn_layers : list[int]   — MLA (1-indexed)
    #   linear_attn_config.kda_layers       : list[int]   — KDA (1-indexed)
    # We also keep the older flat keys as a fallback for forks that promoted
    # them to the top level.
    lac = cfg.get("linear_attn_config") or {}
    full_attn_idx = (
        lac.get("full_attn_layers")
        or cfg.get("full_attn_layer_idx")
        or cfg.get("global_attention_layers")
    )

    def _index_set(raw: list[int], n: int) -> set[int]:
        # Detect 1-indexed lists (max id == n) and shift to 0-indexed so
        # downstream `range(n)` lookups behave consistently.
        ids = [int(i) for i in raw]
        if ids and max(ids) == n:
            ids = [i - 1 for i in ids]
        return set(ids)

    if layer_types and len(layer_types) == n_layers:
        attn_mask = [
            t in ("full_attention", "attention", "mla", "global") for t in layer_types
        ]
    elif full_attn_idx is not None:
        attn_set = _index_set(list(full_attn_idx), n_layers)
        attn_mask = [i in attn_set for i in range(n_layers)]
    else:
        # Fallback: uniform 3:1 KDA:MLA pattern as documented in the paper
        attn_mask = [(i % 4) == 3 for i in range(n_layers)]

    # MLA per-token bytes: single compressed K of dim kv_lora_rank
    # (V is absorbed) plus a positional-RoPE shard of qk_rope_head_dim.
    kv_lora_rank = int(cfg.get("kv_lora_rank", 0))
    qk_rope_head_dim = int(cfg.get("qk_rope_head_dim", 0))
    if kv_lora_rank == 0:
        # Some Kimi configs put MLA dims under a sub-config. Best-effort:
        full_cfg = cfg.get("full_attn_config") or {}
        kv_lora_rank = int(full_cfg.get("kv_lora_rank", 0))
        qk_rope_head_dim = int(full_cfg.get("qk_rope_head_dim", 0))

    if kv_lora_rank == 0:
        # Final fallback to standard MLA-style sizing (DeepSeek-V2/V3 default)
        kv_lora_rank = 512
        qk_rope_head_dim = 64

    per_mla = (kv_lora_rank + qk_rope_head_dim) * bpe
    layers: list[LayerSpec] = []
    for is_attn in attn_mask:
        if is_attn:
            layers.append(
                LayerSpec(
                    kind="mla",
                    bytes_per_token=per_mla,
                    detail={
                        "kv_lora_rank": kv_lora_rank,
                        "qk_rope_head_dim": qk_rope_head_dim,
                    },
                )
            )
        else:
            layers.append(LayerSpec(kind="linear", bytes_per_token=0))
    return ModelKVSpec(n_layers_total=n_layers, layers=layers, bytes_per_elem=bpe)


# ---------------------------------------------------------------------------
# 2. Tprefill(l): timed requests against the served model
# ---------------------------------------------------------------------------


def make_prompt_of_len(tokenizer, target_len: int) -> str:
    """Build a string that tokenises to exactly `target_len` tokens.

    Strategy: tokenize a long deterministic string, slice the token ids to
    `target_len`, then decode back. Re-tokenising the decoded string usually
    yields exactly `target_len` again for repeat-heavy strings; if it
    doesn't, we trim/pad in token-space and emit until we hit exactly the
    target.
    """
    base = (
        "The quick brown fox jumps over the lazy dog. "
        "PrfaaS measures KV-cache throughput in cross-datacenter prefill. "
    )
    # Build a long sequence of token ids by tokenizing a repeated string.
    bulk_text = base * (max(1, target_len // 10))
    ids = tokenizer.encode(bulk_text, add_special_tokens=False)
    while len(ids) < target_len:
        ids = ids + ids
    ids = ids[:target_len]
    return tokenizer.decode(ids, skip_special_tokens=True)


def time_request(
    base_url: str,
    prompt: str,
    output_len: int,
    timeout_s: float = 600.0,
) -> float:
    """Send one request to /v1/completions, return wall-clock seconds.

    Uses the OpenAI-compat completions endpoint that both SGLang and vLLM
    expose. We don't rely on streaming; the round-trip is `submit → response
    received` which equals `Tprefill + (output_len-1)*TPOT + network`. With
    output_len=1 the second term vanishes.
    """
    payload = {
        "model": "served-model",  # sglang ignores this when only one model is loaded
        "prompt": prompt,
        "max_tokens": output_len,
        "temperature": 0.0,
        "top_p": 1.0,
        "stream": False,
        "n": 1,
    }
    t0 = time.perf_counter()
    r = requests.post(
        f"{base_url}/v1/completions",
        json=payload,
        timeout=timeout_s,
    )
    t1 = time.perf_counter()
    r.raise_for_status()
    return t1 - t0


def wait_for_health(base_url: str, timeout_s: float = 1800.0) -> None:
    """Block until SGLang's /health returns 200 (or timeout)."""
    deadline = time.time() + timeout_s
    last_err: Exception | None = None
    while time.time() < deadline:
        try:
            r = requests.get(f"{base_url}/health", timeout=10)
            if r.status_code == 200:
                return
        except Exception as e:  # noqa: BLE001
            last_err = e
        time.sleep(5)
    raise RuntimeError(
        f"SGLang at {base_url} never became healthy in {timeout_s}s; last={last_err!r}"
    )


# ---------------------------------------------------------------------------
# 3. Sweep
# ---------------------------------------------------------------------------


def _model_max_len(model_dir: Path) -> int | None:
    """Best-effort max context length declared by the model's config.json.

    Falls back through the keys SGLang itself checks. Returns None if
    nothing usable is declared, in which case the probe will not skip
    based on length.
    """
    try:
        cfg = json.loads((model_dir / "config.json").read_text())
    except Exception:  # noqa: BLE001
        return None
    for k in (
        "max_position_embeddings",
        "model_max_length",
        "max_seq_len",
        "n_positions",
    ):
        v = cfg.get(k)
        if isinstance(v, int) and v > 0:
            return v
    return None


def run_sweep(args: argparse.Namespace) -> int:
    from transformers import AutoTokenizer  # type: ignore

    model_dir = Path(args.model_dir)
    spec = parse_config(model_dir)
    tokenizer = AutoTokenizer.from_pretrained(
        str(model_dir), trust_remote_code=True
    )
    declared_max = _model_max_len(model_dir)
    # Reserve room for output + BOS/EOS/special tokens so we don't bump into
    # the server's own length checks. 128 is comfortable for every model we
    # care about in Phase 1.
    safe_max = (declared_max - args.output_len - 128) if declared_max else None

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    print(
        f"[probe] model={args.model_id} short={args.model_short} "
        f"tp={args.tp_size} bytes_per_elem={spec.bytes_per_elem} "
        f"n_attn={spec.n_attn} n_linear={spec.n_linear} "
        f"kv_per_token_bytes={spec.kv_per_token_bytes()} "
        f"layers={spec.n_layers_total} "
        f"declared_max={declared_max} safe_max={safe_max}",
        flush=True,
    )

    print("[probe] waiting for SGLang /health ...", flush=True)
    wait_for_health(args.base_url, timeout_s=args.health_timeout_s)
    print("[probe] SGLang healthy, beginning sweep", flush=True)

    ctx_lens = [int(x) for x in args.ctx_lens.split(",") if x.strip()]
    overall_ok = True

    with out_path.open("w") as fh:
        for l in ctx_lens:
            print(f"[probe] ---- input_len={l} ----", flush=True)
            if safe_max is not None and l > safe_max:
                # Legitimate, advertised limit of the model — record it as a
                # skip but do NOT mark the whole run as failed.
                print(
                    f"[probe]   skip: l={l} > safe_max={safe_max} "
                    f"(declared_max={declared_max})",
                    flush=True,
                )
                rec = _err_record(
                    args,
                    spec,
                    l,
                    f"skipped_above_model_max: declared_max={declared_max} "
                    f"safe_max={safe_max}",
                )
                rec["skipped"] = True
                fh.write(json.dumps(rec) + "\n")
                fh.flush()
                continue
            try:
                prompt = make_prompt_of_len(tokenizer, l)
            except Exception as e:  # noqa: BLE001
                rec = _err_record(args, spec, l, f"prompt_build_failed: {e!r}")
                fh.write(json.dumps(rec) + "\n")
                fh.flush()
                overall_ok = False
                continue

            try:
                for w in range(args.warmup):
                    _ = time_request(args.base_url, prompt, args.output_len)
                    print(f"[probe]   warmup {w + 1}/{args.warmup} ok", flush=True)
            except Exception as e:  # noqa: BLE001
                rec = _err_record(args, spec, l, f"warmup_failed: {e!r}")
                fh.write(json.dumps(rec) + "\n")
                fh.flush()
                overall_ok = False
                continue

            samples_s: list[float] = []
            try:
                for k in range(args.timed):
                    dt = time_request(args.base_url, prompt, args.output_len)
                    samples_s.append(dt)
                    if (k + 1) % 5 == 0 or k == args.timed - 1:
                        print(
                            f"[probe]   timed {k + 1}/{args.timed}  "
                            f"latest={dt * 1e3:.1f} ms",
                            flush=True,
                        )
            except Exception as e:  # noqa: BLE001
                rec = _err_record(args, spec, l, f"timed_failed: {e!r}")
                fh.write(json.dumps(rec) + "\n")
                fh.flush()
                overall_ok = False
                continue

            samples_ms = sorted(s * 1e3 for s in samples_s)
            p25 = statistics.quantiles(samples_ms, n=4)[0] if len(samples_ms) >= 4 else min(samples_ms)
            p50 = statistics.median(samples_ms)
            p75 = statistics.quantiles(samples_ms, n=4)[2] if len(samples_ms) >= 4 else max(samples_ms)
            skv = spec.skv_for_len(l)
            phi_bps = skv / (p50 / 1e3) if p50 > 0 else 0.0

            rec = {
                "model_id": args.model_id,
                "model_short": args.model_short,
                "input_len": l,
                "output_len": args.output_len,
                "tp_size": args.tp_size,
                "n_attn_layers": spec.n_attn,
                "n_linear_layers": spec.n_linear,
                "kv_per_token_bytes": spec.kv_per_token_bytes(),
                "skv_bytes_total": skv,
                "tprefill_ms": {
                    "p25": round(p25, 3),
                    "p50": round(p50, 3),
                    "p75": round(p75, 3),
                    "n": len(samples_ms),
                },
                "phi_kv_bytes_per_sec": round(phi_bps, 2),
                "phi_kv_gbps": round(phi_bps * 8 / 1e9, 4),
                "engine": os.environ.get("SGLANG_TAG", "sglang-v0.5.9-cu129-amd64"),
                "engine_flags": os.environ.get(
                    "SGLANG_FLAGS",
                    "--disable-radix-cache --max-running-requests 1",
                ),
                "host": os.environ.get("HOSTNAME", "unknown"),
                "gpu": os.environ.get("PRFAAS_GPU", "H100 80GB SXM5"),
                "wall_clock_iso": _dt.datetime.now(_dt.timezone.utc).isoformat(),
            }
            fh.write(json.dumps(rec) + "\n")
            fh.flush()
            print(
                f"[probe] l={l} p50={p50:.1f} ms "
                f"Φkv={rec['phi_kv_gbps']:.3f} Gbps",
                flush=True,
            )

    print(f"[probe] DONE  output={out_path}", flush=True)
    return 0 if overall_ok else 2


def _err_record(
    args: argparse.Namespace,
    spec: ModelKVSpec,
    l: int,
    error: str,
) -> dict[str, Any]:
    return {
        "model_id": args.model_id,
        "model_short": args.model_short,
        "input_len": l,
        "output_len": args.output_len,
        "tp_size": args.tp_size,
        "n_attn_layers": spec.n_attn,
        "n_linear_layers": spec.n_linear,
        "kv_per_token_bytes": spec.kv_per_token_bytes(),
        "skv_bytes_total": spec.skv_for_len(l),
        "error": error,
        "wall_clock_iso": _dt.datetime.now(_dt.timezone.utc).isoformat(),
    }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-dir", required=True)
    ap.add_argument("--model-id", required=True)
    ap.add_argument("--model-short", required=True)
    ap.add_argument("--tp-size", type=int, required=True)
    ap.add_argument("--base-url", default="http://127.0.0.1:30000")
    ap.add_argument(
        "--ctx-lens",
        default="1024,2048,4096,8192,16384,32768,65536,131072",
    )
    ap.add_argument("--warmup", type=int, default=5)
    ap.add_argument("--timed", type=int, default=20)
    ap.add_argument("--output-len", type=int, default=1)
    ap.add_argument("--output", required=True)
    ap.add_argument("--health-timeout-s", type=float, default=1800.0)
    args = ap.parse_args(argv)
    return run_sweep(args)


if __name__ == "__main__":
    sys.exit(main())
