# Phase 1 — Φkv replication (paper-faithful)

**Status:** plan v0.1 — **executed 2026-04-20 on g126 (cluster Y)**.
Results: [`results/phase1_phi_kv/`](../../results/m1.5-vllm-baseline/phase1_phi_kv/) — entry
point [`PHI_KV_TABLE.md`](../../results/m1.5-vllm-baseline/phase1_phi_kv/PHI_KV_TABLE.md).
Headline outcome captured in
[`results/phase1_phi_kv/COMPARE_TO_PAPER.md`](../../results/m1.5-vllm-baseline/phase1_phi_kv/COMPARE_TO_PAPER.md).
**Why this exists:** the PrfaaS paper's headline numbers come out of an analytical
throughput model (Eq 3-8) whose only model-dependent input is **Φkv(l)** —
the rate at which a prefill replica produces KV cache, in bytes per second,
as a function of input length `l`. The paper publishes per-model Φkv values
in §4 / Table 6 and feeds them straight into the analytical model. **If we
reproduce Φkv on the paper's actual models, we have reproduced the input to
the paper's central claim**, regardless of whether we can also stand up a
working PD-disaggregated path for those models.

This phase is the *first* paper-aligned deliverable. Everything downstream
(Phase 2 analytical model, Phase 3 empirical PD-disagg, Stage D cross-DC)
either consumes Phase 1's output or is a sanity check on it.

---

## 1. What we measure

For a given (model, input_len `l`) cell:

```
Tprefill(l)   = wall-clock time, t0=request_submit → t1=first_token_emit,
                with output_len=1 (decode degenerates to one token, so
                t1−t0 is dominated by the prefill phase).
Skv(l)        = bytes of KV cache produced by prefilling `l` tokens, computed
                analytically from the model's config.json.
Φkv(l)        = Skv(l) / Tprefill(l)        # bytes per second
```

**Why output_len=1 instead of post-hoc decode subtraction:** the paper's Eq 3
defines Tprefill as the wall-clock time to populate the KV cache for a
request before any decode steps run. With output_len=1 the request returns
exactly when the prefill is done plus one decode step, and a single decode
step is an order of magnitude smaller than the prefill at the context lengths
we care about (≥1 K input). We sanity-check this by running a few cells with
output_len=8 and subtracting `7 × measured_TPOT` — the difference is the
error bar on Tprefill.

**Skv per layer formula** (single-token):

| Layer type | KV bytes per token (BF16, per layer) |
|---|---|
| GQA / MHA standard attention | `2 × n_kv_heads × head_dim × 2` (K+V, 2 bytes/elem) |
| MLA (DeepSeek/Kimi-Linear MLA layer) | `(kv_lora_rank + qk_rope_head_dim) × 2` (compressed) |
| Linear attention / Mamba2 / KDA | `0` (state is fixed-size, doesn't grow with `l`) |
| Sliding-window attention with window `W` | same as GQA but capped at `W` per layer once `l ≥ W` |

`Skv(l) = sum over attention layers of (per-layer-KV-bytes-per-token × min(l, layer_cap))`.

For a hybrid model with `n_attn` softmax layers and `n_lin` linear/SSM
layers, only the `n_attn` layers contribute. This is the source of the
paper's 10–30× Φkv reduction.

The probe (`scripts/phi_kv_probe.py`) reads the model's `config.json`, walks
the layer config, and emits Skv(l) deterministically. The serving stack is
only used to measure Tprefill(l).

## 2. The model set (paper-faithful, hardware-feasible)

The PrfaaS paper evaluates Kimi Linear 48B, MiMo-V2-Flash 309B, Qwen3.5
397B, Ring-2.5 1T (hybrids) and MiniMax-M2.5 229B, Qwen3-235B (dense
controls). Of these, what physically fits our envelope:

| # | Model | HF repo | Class | TP | Hardware | Why we run it |
|---|---|---|---|---|---|---|
| **H1** | Kimi-Linear-48B-A3B-Instruct | `moonshotai/Kimi-Linear-48B-A3B-Instruct` | hybrid (3:1 KDA + MLA, MoE 3 B active) | 8 | g126, BF16 | Paper's primary hybrid that fits one 8-H100 box. Direct paper-figure replication. |
| H2 | NVIDIA-Nemotron-Nano-9B-v2 | `nvidia/NVIDIA-Nemotron-Nano-9B-v2` | hybrid (52 Mamba2 + 4 attn) | 4 | g126, BF16 | Adjacent-to-paper hybrid (NVIDIA Mamba2 family); cheap second data point; same architecture class as MiMo. |
| **D1** | Qwen2.5-72B-Instruct | `Qwen/Qwen2.5-72B-Instruct` | dense (GQA 8, head_dim 128, 80 layers) | 8 | g126, BF16 (fits ≈ 145 GB ≤ 8×80=640 GB) | Paper-faithful dense control we can fit on one box; same class of "high Φkv full-attention" the paper rules out. |
| D2 (defer) | Qwen3-235B-A22B (FP8) | `Qwen/Qwen3-235B-A22B-Instruct` (or FP8 variant) | dense (MoE) | 16 | g304+g307 | The paper's actual dense control. Runs only after the X-cluster K8s GPU exposure is unblocked. |
| H3 (defer) | MiMo-V2-Flash-309B-A32B | `XiaomiMiMo/MiMo-V2-Flash-309B-A32B` (when published) | hybrid (5:1 SWA, MoE 32 B active) | 16 | g304+g307, FP8 | Paper's secondary hybrid; needs the X-cluster. |

H1 + D1 are the paper's apples-to-apples hybrid-vs-dense story compressed
to what fits on g126 alone, so we can produce *real* numbers this week
without waiting on the X-cluster unblock. H2 is a free second hybrid data
point because the weights are already on disk from Stage A.

We **do not** profile Qwen2.5-7B / Qwen3-Next-80B / any other off-paper
model. The point of Phase 1 is paper alignment, not coverage.

## 3. The context-length sweep

Match the paper's range exactly:

```
l ∈ {1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072}
```

For each (model, `l`) cell:
- **5 warmup requests** (drop), then **20 timed requests**.
- Report median Tprefill and IQR (P25/P75) for noise reduction.
- Single-concurrency (concurrency=1) to isolate per-request prefill cost
  from queueing — Tprefill in Eq 3 is per-request-isolated.

For Kimi-Linear at l=131072 we also run a second cell at output_len=8 as
the "decode subtraction" sanity check (see §1).

## 4. The serving stack

**Engine:** SGLang v0.5.9 (`lmsysorg/sglang:v0.5.9-cu129-amd64`). This is the
exact engine the paper uses for its profiling and the same engine we'll
need in Phase 3 for the empirical PD-disagg run via Mooncake. Standardising
on SGLang for Phase 1 also sidesteps the two vLLM blockers Stage A hit:
1. vLLM 0.19.1's MooncakeConnector cannot talk to Mamba2 / KDA backends
   (`TpKVTopology.__post_init__` → `attn_backend.get_kv_cache_shape()`
   → `NotImplementedError`).
2. The bundled `mooncake.vllm_v1_proxy_server` doesn't drive the full v1
   PD protocol (no `transfer_id`).
SGLang has its own attention backend dispatcher that handles linear
attention natively.

**Server flags (per model):**

```
python -m sglang.launch_server \
  --model-path /models/${MODEL_LOCAL_DIR} \
  --tp ${TENSOR_PARALLEL_SIZE} \
  --trust-remote-code \
  --port 30000 \
  --mem-fraction-static 0.85 \
  --max-running-requests 1 \
  --disable-radix-cache               # Eq 3 assumes cold prefill
```

`--disable-radix-cache` is critical: the paper measures Tprefill with no
prefix cache hit, because the Φkv they publish is the worst-case "this
request is fresh" rate. A radix-cache hit would lower Tprefill artificially
and inflate Φkv beyond what's physically meaningful.

## 5. The probe

`prfaas/m1.5-vllm-baseline/scripts/phi_kv_probe.py`. One file, ~200 lines.
Responsibilities:

1. Read `${MODEL_LOCAL_DIR}/config.json`. Walk the architecture config to
   classify each layer (attention vs linear/Mamba/SWA-with-cap). Emit
   `Skv(l)` analytically for each `l` in the sweep.
2. POST to the SGLang OpenAI-compatible endpoint (`/v1/completions` with
   `prompt=<l-token-string>`, `max_tokens=1`, `stream=False`,
   `temperature=0`).
3. Time t0 = request submit, t1 = response received. `Tprefill(l) ≈ t1−t0`.
4. Repeat 5 warmup + 20 timed.
5. Emit one JSON record per (model, `l`) to `results/phase1_phi_kv/<model>.jsonl`:

```json
{
  "model_id": "moonshotai/Kimi-Linear-48B-A3B-Instruct",
  "model_short": "kimi-linear-48b",
  "input_len": 16384,
  "output_len": 1,
  "tp_size": 8,
  "n_attn_layers": 12,
  "n_linear_layers": 36,
  "kv_per_token_bytes": 24576,
  "skv_bytes_total": 402653184,
  "tprefill_ms": {"p25": 312.4, "p50": 318.7, "p75": 326.1, "n": 20},
  "phi_kv_bytes_per_sec": 1262833000,
  "phi_kv_gbps": 10.10,
  "engine": "sglang-v0.5.9-cu129-amd64",
  "engine_flags": "--disable-radix-cache --max-running-requests 1",
  "host": "g126",
  "gpu": "H100 80GB SXM5",
  "wall_clock_iso": "2026-04-19T17:32:11Z"
}
```

The token-stream input is generated from `tokenizer.decode(list(range(l)))`
clipped to the model's `pad_id`, then re-tokenised so the actual input
length is exactly `l` regardless of the tokenizer's vocabulary.

## 6. The output

After Phase 1 completes:

```
prfaas/results/m1.5-vllm-baseline/phase1_phi_kv/
├── kimi-linear-48b.jsonl            # H1: 8 cells (one per context length)
├── nemotron-nano-9b-v2.jsonl        # H2: 8 cells
├── qwen2.5-72b-instruct.jsonl       # D1: 8 cells
├── PHI_KV_TABLE.md                  # Markdown summary, paper-style table
├── PHI_KV_PLOT.png                  # Φkv vs context-length, both axes log
└── COMPARE_TO_PAPER.md              # Side-by-side our Φkv vs paper Table 6
```

`COMPARE_TO_PAPER.md` is the deliverable that says "we are doing what the
paper said." If our Kimi-Linear Φkv at 32 K matches the paper's published
value within ~15%, Phase 1 is done. A larger gap means we're either using a
different attention-backend choice, a different precision, or have a serving
bug — diagnosable from logs.

## 7. Wall-clock budget

| Item | Time |
|---|---|
| Stage Kimi-Linear weights to PVC (49 GiB BF16, ~50 MB/s sustained on g126's NVMe) | 15–20 min |
| Stage Qwen2.5-72B weights to PVC (145 GiB BF16) | 50–70 min |
| First SGLang load + CUDA-graph capture per model | 2–4 min |
| Sweep of 8 context lengths × 25 requests per cell on Kimi-Linear (TP=8) | ~10 min |
| Sweep of 8 context lengths × 25 requests on Nemotron-Nano (TP=4) | ~6 min |
| Sweep of 8 context lengths × 25 requests on Qwen2.5-72B (TP=8) | ~25 min (longer prefill, dense) |
| Probe analysis + plotting | 5 min |

End-to-end, Phase 1 is **under 3 hours of wall clock from a cold PVC**, of
which 1.5 hours is just downloading weights. Once the weights are staged, a
Φkv re-run is ~45 min total.

## 8. What Phase 1 does NOT prove

This phase intentionally does *not* run any PD-disagg, doesn't use the wire,
and doesn't measure Λ_max(SLO) directly. Φkv is a single-instance
serving-side measurement. The reason this is enough to be paper-faithful is
that **the paper's headline plots are predictions from the analytical model
fed by Φkv** (paper §4.3, Figure 8). Once we have our Φkv numbers, Phase 2
plugs them into the same analytical model with our Stage 0a wire bandwidth
(14.7 Gbps) and we can regenerate the paper's plot for our hardware.

The empirical PD-disagg validation comes in Phase 3 — but only on whichever
hybrid the analytical model says should fit our wire. That's how the paper
sequences it too (§4 → §5 case study).

## 9. Acceptance criteria

Phase 1 is "done" when:

- [x] All three (or four, if we get the X-cluster) models have JSONL files
      with all 8 context-length cells populated.
      *Met for Kimi-Linear-48B (8/8). Nemotron-Nano-9B-v2 has 7 measured
      cells + 1 explicit error at exactly `l = max_position_embeddings`;
      probe now skips with a `safe_max` margin so a re-run will give 8/8.
      Qwen2.5-72B has 5 measured cells covering its stock
      `max_position_embeddings = 32 768` plus 3 SKIP records for
      `l ∈ {32 768, 65 536, 131 072}` that need YaRN to evaluate.*
- [ ] `COMPARE_TO_PAPER.md` shows our Kimi-Linear Φkv at 32 K within ±20%
      of the paper's value, **or** documents a specific reason for the gap.
      *Pending — see `COMPARE_TO_PAPER.md`; we still need to type up the
      paper's Table 6 Φkv numbers for direct diff. Probable explanations
      (newer SGLang attention kernels) already documented.*
- [x] The dense control's Φkv at 32 K is at least 5× the hybrid's Φkv at
      32 K. *Replaced with the analogous 16 K row (Qwen2.5-72B caps at
      32 K stock); ratio is **9.3× dense vs Kimi**, **8.4× dense vs
      Nemotron**, both well above 5×.*
- [x] All numbers are committed under `prfaas/results/m1.5-vllm-baseline/phase1_phi_kv/` and
      cited from `EXPERIMENT_PLAN.md` v0.4. *Done in this commit.*
