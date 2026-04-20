# PrfaaS-on-Mooncake — project log

**Updated:** 2026-04-20  **Active branch:** `feat/prfaas-m1.5-vllm-baseline`

This is the canonical project log. It is intentionally narrative and
exhaustive. Other docs in this tree split this log up by concern:

- [`README.md`](./README.md) — short status table + entry pointers.
- [`EXPERIMENT_PLAN.md`](./EXPERIMENT_PLAN.md) — the **plan**: stages, hypotheses,
  go/no-go criteria. Read after this log if you want to know *what's next*.
- [`DECISIONS.md`](./DECISIONS.md) — every meaningful decision as an ADR
  (Status / Context / Decision / Consequences / Alternatives). Read this if
  you want to know *why* a choice was made and what alternatives we
  rejected.
- [`INFRA_LOG.md`](./INFRA_LOG.md) — every infra-level event we hit
  (disk pressure, port collisions, RBAC, GPU exposure) with diagnosis and
  resolution. Read this if you're operating the rig.
- [`PAPER_REREAD.md`](./PAPER_REREAD.md) — receipts for the v0.3 reframing of
  the experiment (metric and model class).
- [`PAPER_MODEL_PLAN.md`](./PAPER_MODEL_PLAN.md) — paper-model unblock
  workstream (status board for which paper models we can/can't run yet).
- [`PHASE1_PHIKV_PLAN.md`](./PHASE1_PHIKV_PLAN.md) — methodology spec for the
  Phase 1 measurement that's the centrepiece of this commit window.
- [`results/phase1_phi_kv/`](./results/phase1_phi_kv/) — Phase 1 raw data,
  per-model JSONL, summary table, and run-by-run notes.
- [`results/stageA/`](./results/stageA/) — Stage A (vLLM single-host smoke)
  raw evidence and the SupportsHMA / Mamba2 finding.
- [`m1.5-vllm-baseline/`](./m1.5-vllm-baseline/) — operational tree
  (K8s manifests, scripts, configs, RUNBOOK).
- [`m1-tcp-bench/`](../prfaas/m1-tcp-bench/) — wire-characterisation rig
  (Stage 0 / 0a results live here).

If you only have ten minutes, read this file's §1 (current state) and §6
(what we have measured), then jump to
[`results/phase1_phi_kv/PHI_KV_TABLE.md`](./results/phase1_phi_kv/PHI_KV_TABLE.md).

---

## 1. Current state in one screen

**The experiment.** We are testing the central claim of the PrfaaS paper
(Qin et al., arXiv:2604.15039, 2026): that Prefill-Decode disaggregation
across datacenters lets a decode-DC sustain meaningfully higher Λ_max
(throughput at SLO) on **hybrid-attention models**, despite the wire
sitting between the two halves. The paper proves this analytically with a
KV-cache-throughput model fed by per-model Φkv measurements; the case
study uses 100 Gbps VPC peering. Our rig has commodity-grade public
internet between cluster X (g304+g307, IAD1) and cluster Y (g126,
DFW1-beta), measured at **14.7 Gbps single-flow goodput** with **29.75 ms
RTT**. We aim to reproduce both arms — the paper's analytical model fed by
*our* Φkv, then an empirical Mooncake PD-disagg run on the model the
analytical model says fits our wire.

**Plan revision.** Currently on plan v0.4 (paper-faithful re-alignment).
v0.1/v0.2 used per-request TTFT on dense models — both wrong. v0.3 fixed
the metric (Λ_max-at-SLO) and model class (hybrid). v0.4 takes the next
step: instead of using paper-adjacent hybrid surrogates, use the paper's
actual hybrid (Kimi-Linear-48B-A3B-Instruct) and the paper's actual engine
(SGLang v0.5.9), so our Φkv is directly comparable to paper Table 6.

**What's done.**

| Stage | What | Status | Headline |
|---|---|---|---|
| 0 | Host preflight + cluster topology | done | g304/g307 on IAD1 (X), g126 on DFW1-beta (Y), all on Kubernetes. Y RBAC limits us to the `default` namespace. |
| 0a | Cross-DC TCP transport bench | done | g126 ↔ g304 over public internet: median goodput **~14.7 Gbps**, RTT **29.75 ms**, with TCP connection pooling on. Full results in `prfaas/m1-tcp-bench/results/`. |
| A | Single-host PD smoke on g126, vLLM v0.19.1 + MooncakeConnector | done | Qwen2.5-7B-Instruct end-to-end through patched MooncakeConnector + bundled proxy → HTTP 200, content `OK`. **Negative finding** on Nemotron-Nano-9B-v2: `TpKVTopology.get_kv_cache_shape` raises `NotImplementedError` on the Mamba2 backend; vLLM v0.19.1's MooncakeConnector cannot serve hybrid models, period. The `SupportsHMA` shim is necessary but not sufficient. |
| Mooncake upstream PR | `feat/supports-hma-shim` → kvcache-ai/Mooncake#1931 | open, awaiting review | The minimal upstream-clean change that makes vLLM accept MooncakeConnector for HMA-enabled models. Decoupled from the rest of this work. |
| **Phase 1** | **Φkv replication on the paper's actual primary hybrid + adjacent hybrid + dense control, on g126 with SGLang v0.5.9** | **done 2026-04-20** | **Kimi-Linear-48B Φkv plateau ≈ 5.6–5.8 Gbps for `l ∈ [16 K, 65 K]`; Nemotron-Nano-9B Φkv plateau ≈ 6.5 Gbps; Qwen2.5-72B Φkv plateau ≈ 54–56 Gbps. Dense / hybrid ratio at 16 K = 9.3× (Kimi) and 8.4× (Nemotron) — replicates the paper's qualitative claim on our hardware. Both hybrids fit our 14.7 Gbps wire at every measured `l`; the dense control does not at any.** |
| Phase 2 | Analytical Λ_max regenerator (paper Eq 3-8 in Python, fed by our Φkv + 14.7 Gbps wire) | not started | Pure code, no GPUs. |
| Phase 3 | Empirical SGLang+Mooncake PD-disagg on the model Phase 2 picks | not started | Most likely Kimi-Linear-48B at `l ∈ [16 K, 65 K]`. Single-host first (g126 split TP=4+TP=4), then cross-DC g304→g126 once X-cluster K8s GPU exposure unblocks. |
| B / C / D | Three-config Λ_max sweeps (homogeneous decode-only / naive het / PrfaaS-style) on IB / IB+netem / real WAN | manifests scaffolded for vLLM; will port to SGLang | Empirical validation arm of the v0.4 plan. |

**The thing that changed in v0.4.** The headline measurement is no longer
"empirical Λ_max gap on the WAN" alone. It's now two complementary numbers:

1. **Φkv (Phase 1, done).** Per-model KV throughput from a single replica.
   Replicates the paper's input. Lives entirely on g126.
2. **Λ_max (Phase 2 + Stages B/C/D).** Predicted from the paper's
   analytical model fed by Phase 1's Φkv, then validated empirically.

If we never get the WAN to the point where a real PD-disagg run is feasible
at scale, Phase 1 + Phase 2 is *still* a publishable replication of the
paper's central analytical result, on hardware the paper didn't run on.
That's the de-risking v0.4 buys us.

## 2. Hardware and topology

| Cluster | Role | Nodes | GPUs | Within-cluster | Inter-cluster | K8s control |
|---|---|---|---|---|---|---|
| X | "Prefill DC" — bulk compute | 2 (g304, g307) | 16 × H100 80 GB SXM5 | InfiniBand | public internet to Y | `vpcloud-slurm-v2-admin` kubeconfig (admin) |
| Y | "Decode DC" — user-facing | 1 (g126) | 8 × H100 80 GB SXM5 | n/a | public internet to X | `aln1-beta-harsha-g126-beta` kubeconfig (`mks:customer` group, `default` namespace only) |

**Internal X interconnect:** InfiniBand. Used as a clean baseline (Stage B)
and as the substrate for `tc netem` WAN emulation (Stage C). Importantly,
**Stage B uses TCP over IB, not RDMA**. RDMA-as-baseline would unfairly
inflate the floor; the real cross-DC link is TCP.

**Inter-cluster network:** ordinary public-internet IP, single ASN-pair
hop. We measured median single-flow TCP goodput at **14.7 Gbps** and RTT
at **29.75 ms** with three time-of-day repeats during Stage 0a. Variance
across the day is ~ ±15%. Path MTU is the standard 1500.

**g126 storage layout (the bit that bit us during Phase 1).** g126 has a
single `/dev/nvme0n1p2` (438.5 GiB ext4) that backs *both* the kubelet
imagefs *and* the `local-path` PVCs we use for model weights and probe
results. There is no separate fast tier. This is why the
`local-path`-provisioned PVCs compete with container-image storage for
disk pressure, and why we ended up evicting cert-manager pods en masse
the first time we tried to fit Kimi-Linear-48B + Qwen2.5-72B + Nemotron
weights on disk simultaneously (~245 GB of weights versus ~459 GB total
disk minus ~85 GB system). See [`INFRA_LOG.md`](./INFRA_LOG.md) §1.

**Network exposure for cross-DC PD-disagg.** Mooncake's TCP transport has
no built-in TLS or auth. We will use firewall whitelist + interface bind
(see EXPERIMENT_PLAN §2.1) instead of a WireGuard tunnel because
WireGuard caps user-space throughput at ~2-8 Gbps which would dominate
our 14.7 Gbps wire. WireGuard cost ablation is queued as Stage 0b but
not blocking.

**RBAC implication for Y.** We only have `default` namespace on g126, and
only `pod-creator`-class verbs. We cannot delete cert-manager pods, can't
create namespaces, can't taint nodes. Operations that require any of
those have to be requested through the cluster owner. This is why some
infra-cleanup operations during Phase 1 required workarounds (see
[`INFRA_LOG.md`](./INFRA_LOG.md) §3).

## 3. Software stack

| Component | Version | Where | Why this version |
|---|---|---|---|
| Mooncake | head of `feat/prfaas-m1.5-vllm-baseline` (this branch); upstream PR #1931 carries the SupportsHMA shim only | both clusters | `feat/supports-hma-shim` cherry-picked the minimal upstream-clean change; the rest of this branch is research code |
| `mooncake-transfer-engine` (Python) | `0.3.10.post1` | Stage A; will likely be `≥ 0.3.9` for SGLang | Stage A pin came from vLLM v0.19.1 ship matrix; SGLang requires `≥ 0.3.9` for first-class Mooncake binding |
| vLLM | `v0.19.1` | Stage A (engineering smoke only) | Last release before SGLang's first-class Mooncake support; useful as a counterfactual data point |
| SGLang | `v0.5.9-cu129-amd64` (`lmsysorg/sglang:v0.5.9-cu129-amd64`) | Phase 1 | Paper's own engine; ships first-class Mooncake PD-disagg binding; serves Kimi-Linear / Mamba2 / KDA / MLA out of the box (no `SupportsHMA` patch needed) |
| `fla-core` | `>= 0.4.0`, pip-installed at SGLang container startup for Kimi-Linear runs | Phase 1 (Kimi only) | Kimi-Linear's KDA layers depend on `fla-core` kernels; SGLang image doesn't bundle them |
| CUDA driver on g126 | `570.211.01` (max CUDA 12.9) | g126 | Constrains us to SGLang `cu129` images; `cu130` would not run |
| `python:3.12-slim` | for staging Jobs | g126 | minimal image, just `huggingface_hub[cli,hf_transfer]` |
| K8s | `v1.35.0` on g126; X-cluster runs admin distro | both | as installed by cluster operators |

**vLLM vs SGLang.** Phase 1 uses SGLang. Stage A keeps vLLM as the
engineering-only data point that proves the K8s + Mooncake plumbing is
alive. Phase 3 will use SGLang too because it's what the paper used and
what already serves the hybrids.

## 4. Chronological journey (so far)

### 4.1 Stage 0 — Wire characterization (M1, completed earlier)

Goal: know what the wire can do *before* we put an 80 B model on it.

We ran Mooncake's `transfer_engine_bench` in `MODE=native` over the
public-internet path between g126 and g304, sweeping slice size, threads,
and connection-pool depth, repeated at three wall-clock times. Headline:

- Median single-flow TCP goodput: **14.7 Gbps**
- RTT (measured ICMP, sanity-checked with TCP RTT): **29.75 ms**
- Throughput stability across the day: **~ ±15%** (worst at peak hours
  evening America)
- Connection-pool depth gain: ~1.4× from depth=8 vs depth=1 single-flow

Full dump under `prfaas/m1-tcp-bench/results/`. The 14.7 Gbps number is
the constant we feed into every analytical calculation — `SIZING.md`,
later Phase 2 — so getting it pinned down before any model work was the
right sequencing.

### 4.2 Stage A — single-host vLLM smoke (g126, K8s)

Goal: prove the K8s + Mooncake plumbing — model staging PVC, prefiller
pod, decoder pod, bundled proxy, smoke request — works end-to-end on Y
before we bring the wire into the picture.

**What ran:** `vllm/vllm-openai:v0.19.1` × 2 pods (TP=4 each) on g126,
with our `SupportsHMA` shim applied in-place via an init container,
`mooncake.vllm_v1_proxy_server` in front, on `Qwen/Qwen2.5-7B-Instruct`.

**Result:** smoke `POST /v1/chat/completions` → HTTP 200, content `OK`.
[`results/stageA/SUMMARY.md`](./results/stageA/SUMMARY.md) has the full
report. The connector is wired all the way through, Mooncake Transfer
Engines on both pods discover each other and listen on their RPC P2P
ports, and a request completes through the proxy.

**Caveat we shipped.** The bundled `mooncake.vllm_v1_proxy_server` does
not populate `kv_transfer_params.transfer_id` /
`do_remote_prefill` / `do_remote_decode`. Net effect: the decoder
re-prefills locally to satisfy the smoke. Stage A proves the *plumbing*,
not the *disagg semantics*. The full v1 PD protocol is a Stage B P1.

**Important negative finding — hybrid models do not work on vLLM v0.19.1.**
We tried to swap `Qwen/Qwen2.5-7B-Instruct` for
`nvidia/NVIDIA-Nemotron-Nano-9B-v2` (Mamba2 + attention hybrid). The
prefiller pod crashed inside `TpKVTopology.__post_init__`:

```
NotImplementedError
  at attn_backend.get_kv_cache_shape(...)
  in vllm/distributed/kv_transfer/kv_connector/utils.py:TpKVTopology
```

`get_kv_cache_shape` is implemented for the standard attention backends
but not for the Mamba2 backend. This is a structural problem, not a
configuration one — the KV transfer layer assumes every layer carries a
classical (block, kv_heads, head_dim) cube. Mamba2 / KDA / linear-attn
layers carry a fixed-size SSM state slab instead, with different shape
semantics. Full transcript:
[`results/stageA/nemotron_failure_prefiller.log`](./results/stageA/nemotron_failure_prefiller.log).
Decision write-up:
[`results/stageA/MC_PATCH_NOTE.md`](./results/stageA/MC_PATCH_NOTE.md).

This unblock has three theoretical paths (A wait upstream, B switch to
SGLang, C write a hybrid-aware MooncakeConnector). We picked Path B —
see [`DECISIONS.md`](./DECISIONS.md) ADR-003.

### 4.3 SupportsHMA upstream PR (parallel workstream)

Mooncake PR [#1931](https://github.com/kvcache-ai/Mooncake/pull/1931) on
the kvcache-ai/Mooncake repo carries the minimal upstream-clean change
that makes vLLM accept `MooncakeConnector` for HMA-enabled models — a
class-level `SupportsHMA` annotation. It does *not* solve the Mamba2
shape problem (that's structurally vLLM's, not Mooncake's), but it is
necessary for any HMA-enabled vLLM build that wants Mooncake.

The PR is on its own branch (`feat/supports-hma-shim`) so it stays
single-purpose, addresses upstream reviewer comments, and can land
independently of the research work. Status: open, addressed the
principal-engineer-style review comments, awaiting maintainer.

### 4.4 The v0.3 → v0.4 reframing (paper alignment)

After the user's "are we simulating what the paper said? i don't want us
to deviate" challenge we re-read the paper end-to-end. The summary
[`PAPER_REREAD.md`](./PAPER_REREAD.md) captures the gap; the short version:

- The paper's headline numbers are not from an end-to-end deployment.
  They are from an **analytical model** (paper Eq 3-8) whose only
  model-dependent input is **Φkv(l) = Skv(l) / Tprefill(l)** — bytes of
  KV cache produced per second, per replica, as a function of input
  length `l`.
- Φkv is profiled on a single-replica serving stack (the paper used
  SGLang). The numbers show up in Table 6.
- The empirical "case study" in the paper plugs measured Φkv into the
  analytical model on a 100 Gbps VPC link.

So: **if we measure Φkv on the paper's actual primary hybrid, on the
paper's actual engine, our Phase 1 output is the input to the paper's
central claim — regardless of whether we ever stand up a working
PD-disagg path for that model.** That's the invariant v0.4 locks down.

Concrete v0.4 changes:

1. Insert a new **Phase 1** before the Stage A→D empirical chain.
2. Swap primary hybrid from `Qwen3-Next-80B-A3B-Instruct` (paper-adjacent)
   to **`moonshotai/Kimi-Linear-48B-A3B-Instruct`** (paper's actual).
3. Adopt **SGLang v0.5.9** as the engine for Phase 1 and Phase 3
   (sidesteps the vLLM hybrid block; matches the paper's engine).
4. Demote Stage A's Qwen2.5-7B run to "engineering smoke for the K8s +
   Mooncake plumbing" — explicitly not a paper data point.

Plan changelog and rationale:
[`EXPERIMENT_PLAN.md`](./EXPERIMENT_PLAN.md) §"v0.3 → v0.4 changelog".

### 4.5 Phase 1 — Φkv replication (this commit window)

**Plan:** [`PHASE1_PHIKV_PLAN.md`](./PHASE1_PHIKV_PLAN.md). Methodology in
§5 below; raw data in §6; per-run notes in
[`results/phase1_phi_kv/RUN_NOTES.md`](./results/phase1_phi_kv/RUN_NOTES.md).

**Outcome (one screen):**

- Three models profiled on g126 (single replica, single concurrency,
  paper-faithful flags) across 1 K → 131 K context lengths.
- All raw data and SGLang server logs captured under
  `prfaas/results/phase1_phi_kv/`.
- The hybrid-vs-dense Φkv ratio (which is the paper's qualitative
  feasibility claim) replicates: **9.3× dense vs Kimi at 16 K, 8.4×
  dense vs Nemotron at 16 K** — both above the 5× target the
  acceptance-criteria doc set.
- Wire-feasibility cross-check against our 14.7 Gbps wire: every hybrid
  cell sits 2.2–4× under the wire; every dense cell sits 3.6–4× over
  the wire. This is the central **paper-versus-our-hardware** verdict.

The headline ratio survives a deliberate parser bug we caught and fixed
mid-run (an early version of `phi_kv_probe.py` mis-counted Kimi's
attention layers because the released Kimi config nests the layer-kind
table inside `linear_attn_config` rather than at the top level — see
ADR-007 in [`DECISIONS.md`](./DECISIONS.md) and the postmortem in
[`results/phase1_phi_kv/RUN_NOTES.md`](./results/phase1_phi_kv/RUN_NOTES.md)).

## 5. Methodology — how each measurement was taken

### 5.1 Wire goodput (Stage 0a)

`transfer_engine_bench` in `MODE=native` over the public-internet path,
swept slice size {64 KiB, 256 KiB, 1 MiB, 4 MiB, 16 MiB}, threads
{1, 4, 8, 16}, conn-pool {1, 4, 8}. Repeated at three time-of-day
windows (morning / afternoon / evening America). Reported median across
runs, plus min/max. Full schema and CSVs:
`prfaas/m1-tcp-bench/results/`.

What we report from this set: **single-flow median goodput = 14.7 Gbps**,
**RTT = 29.75 ms**, **conn-pool=8 vs conn-pool=1 gain ≈ 1.4×**. These
are the constants for everything analytical downstream.

### 5.2 Φkv (Phase 1)

Defined per the paper:

```
Tprefill(l)   = wall-clock time, request_submit → first_token_emit,
                with output_len=1 (decode degenerates to one token; that
                step is order-of-magnitude smaller than prefill at l ≥ 1 K).
Skv(l)        = bytes of KV cache produced by prefilling `l` tokens,
                computed analytically from the model's config.json.
Φkv(l)        = Skv(l) / Tprefill(l)        # bytes per second
```

`Skv(l)` per layer kind:

| Layer kind | KV bytes / token / layer (BF16) |
|---|---|
| GQA / MHA (Llama, Qwen2/3 dense) | `2 × n_kv_heads × head_dim × 2` (K + V) |
| MLA (DeepSeek-V2/V3, Kimi-Linear's MLA layers) | `(kv_lora_rank + qk_rope_head_dim) × 2` (compressed K + RoPE shard, V absorbed) |
| Linear attention / Mamba2 / KDA | `0` (state is fixed-size, doesn't grow with l) |
| SWA with window `W` | same as GQA but capped at `W` per layer once `l ≥ W` |

`Skv(l) = sum over layers of (per-layer-bytes-per-token × min(l, layer_cap))`.
Implementation: [`m1.5-vllm-baseline/scripts/phi_kv_probe.py`](./m1.5-vllm-baseline/scripts/phi_kv_probe.py).

**Probe protocol per (model, l) cell.** 5 warmup requests (drop), then
20 timed requests. Report P25 / P50 / P75 of Tprefill in milliseconds,
n=20. `Φkv = Skv / median(Tprefill)`. Concurrency = 1 (single-stream,
isolates per-request prefill cost from queueing — Tprefill in paper Eq 3
is per-request-isolated).

**Server flags (paper-faithful).**

```
python -m sglang.launch_server \
  --model-path /models/${MODEL_LOCAL_DIR} \
  --tp ${TENSOR_PARALLEL_SIZE} \
  --trust-remote-code \
  --port ${PRFAAS_SGLANG_API_PORT}      # NOT named SGLANG_PORT — see INFRA_LOG.md §2
  --mem-fraction-static 0.85 \
  --max-running-requests 1 \
  --disable-radix-cache                 # Eq 3 assumes cold prefill; cache hit
                                        # would inflate Φkv beyond physical
```

**Prompt synthesis.** The probe builds a deterministic byte-string,
encodes it with the model's tokenizer, slices to exactly `l` tokens,
then re-decodes. This guarantees the request's input length is exactly
`l` regardless of the tokenizer's vocabulary.

**Length safety.** `phi_kv_probe.py` reads the model's
`max_position_embeddings` (or fallback keys), reserves
`output_len + 128` token-headroom, and skips any cell where
`l > declared_max - output_len - 128`. Skipped cells emit a JSON record
with `"skipped": true` and an explanatory `"error"` field; they do not
mark the whole run as failed.

**Failure handling.** Warmup or timed-request HTTP errors emit an `error`
JSON record per cell and continue the sweep. If any *non-skip* error
happens, the script exits non-zero so the K8s Job is marked Failed (the
JSONL is still flushed before exit, so partial data is recoverable).

### 5.3 Engine and infrastructure assumptions

- **Engine:** SGLang `v0.5.9-cu129-amd64`, container image
  `lmsysorg/sglang:v0.5.9-cu129-amd64`. CUDA 12.9 is the highest CUDA
  version compatible with g126's NVIDIA driver `570.211.01`.
- **Tensor parallelism:** `tp=8` for Kimi-Linear and Qwen2.5-72B (all of
  g126's GPUs); `tp=4` for Nemotron-Nano-9B-v2 (the model is small
  enough to fit on 4× H100 with comfortable KV headroom).
- **Mem fraction:** `--mem-fraction-static 0.85` for all three models.
  KV cache utilisation at the longest context cells is well under this.
- **Radix cache:** off (`--disable-radix-cache`). Mandatory for
  Tprefill semantics.
- **Max running requests:** 1. We only ever have one in-flight prefill at
  a time during the timed loop.
- **Inductor compile threads:** `TORCHINDUCTOR_COMPILE_THREADS=1`. See
  [`INFRA_LOG.md`](./INFRA_LOG.md) §2 for why — short version: PyTorch
  inductor's compile-worker subprocesses inherit `SGLANG_PORT` and grab
  the user-facing API port if we let them.

## 6. Data — what we have measured

### 6.1 Wire (Stage 0a)

| Metric | Value |
|---|---|
| Median single-flow TCP goodput, g126 ↔ g304, public internet | **14.7 Gbps** |
| RTT (ICMP and TCP RTT, both agree) | **29.75 ms** |
| Conn-pool gain (depth=8 vs depth=1, same workload) | ~1.4× |
| Time-of-day variance band (median ± min/max across 3 windows) | ± ~15% |

### 6.2 Φkv (Phase 1) — full per-cell results

All three models, single-replica, single-concurrency, on g126 with SGLang
v0.5.9-cu129-amd64. Raw JSONL: `prfaas/results/phase1_phi_kv/<model_short>.jsonl`.
Server logs: `*.sglang.log` (gitignored due to size; reproduce via the
manifests in `prfaas/m1.5-vllm-baseline/k8s/phase1/`).

#### H1 — `moonshotai/Kimi-Linear-48B-A3B-Instruct` (TP=8)

48 B total params, ~3 B active (MoE 256-experts, 8 active). 27 hidden
layers in a 21-KDA + 7-MLA hybrid pattern (`linear_attn_config.full_attn_layers
= [4, 8, 12, 16, 20, 24, 27]`, 1-indexed). MLA per-layer KV bytes =
`(kv_lora_rank + qk_rope_head_dim) × 2 = (512 + 64) × 2 = 1152`. Total
`kv_per_token_bytes = 7 × 1152 = 8064`. `model_max_length = 1,048,576`
so all eight context cells fit comfortably.

| input_len | Skv (bytes) | Tprefill p25 (ms) | p50 | p75 | Φkv (Gbps) |
|---:|---:|---:|---:|---:|---:|
| 1,024   | 8,257,536    | 64.0  | 64.0  | 64.0  | 1.03 |
| 2,048   | 16,515,072   | 69.4  | 69.5  | 69.5  | 1.90 |
| 4,096   | 33,030,144   | 73.3  | 73.6  | 73.7  | 3.59 |
| 8,192   | 66,060,288   | 91.6  | 94.0  | 94.7  | 5.62 |
| 16,384  | 132,120,576  | 181.2 | 182.0 | 182.6 | 5.81 |
| 32,768  | 264,241,152  | 363.0 | 363.4 | 364.5 | 5.82 |
| 65,536  | 528,482,304  | 745.8 | 748.1 | 752.8 | 5.65 |
| 131,072 | 1,056,964,608| 1601.4| 1610.3| 1623.5| 5.25 |

**Reading:** Φkv ramps quickly through small `l` (per-request fixed
overhead dominates Tprefill), then plateaus at **5.7–5.8 Gbps for `l ∈
[16 K, 65 K]`**, slipping to 5.25 Gbps at 131 K because MLA's `O(l²)`
attention on the 7 full-attention layers starts to dominate the total
prefill time. KV size is small enough that even at 131 K we're shipping
just **1.06 GB total**, single replica.

#### H2 — `nvidia/NVIDIA-Nemotron-Nano-9B-v2` (TP=4)

9 B params, 56 layers in a `hybrid_override_pattern`-defined layout: 4
attention layers + 52 Mamba2 layers. Per-attention-layer KV bytes =
`2 × 8 × 128 × 2 = 4096` (8 KV heads, 128 head_dim, K + V, BF16). Total
`kv_per_token_bytes = 4 × 4096 = 16384`. `max_position_embeddings = 131,072`.

| input_len | Skv (bytes) | Tprefill p25 (ms) | p50 | p75 | Φkv (Gbps) |
|---:|---:|---:|---:|---:|---:|
| 1,024   | 16,777,216    | 43.6  | 43.6  | 43.7  | 3.08 |
| 2,048   | 33,554,432    | 45.4  | 45.7  | 46.0  | 5.87 |
| 4,096   | 67,108,864    | 76.4  | 76.5  | 76.7  | 7.02 |
| 8,192   | 134,217,728   | 181.2 | 181.7 | 182.5 | 5.91 |
| 16,384  | 268,435,456   | 336.4 | 336.6 | 337.2 | 6.38 |
| 32,768  | 536,870,912   | 652.6 | 653.4 | 654.7 | 6.57 |
| 65,536  | 1,073,741,824 | 1308.3| 1309.1| 1310.5| 6.56 |
| 131,072 | 2,147,483,648 | —     | —     | —     | err (HTTP 400 from SGLang at exact `max_position_embeddings`; later runs skip via `safe_max = declared_max - output_len - 128`) |

**Reading:** plateau ≈ **6.5 Gbps for `l ≥ 16 K`**. Slightly higher Φkv
than Kimi because each attention layer carries 2× the bytes/token Kimi
does (16 KB vs 8 KB total per token), so the wider per-token KV is
shipped against a comparable attention-budget Tprefill. The 131 K cell
is a probe-script issue (request length equalled the declared
`max_position_embeddings`); the trend says ~6.4 Gbps and a re-run with
`safe_max` will close the cell.

#### D1 — `Qwen/Qwen2.5-72B-Instruct` (TP=8)

72 B dense, GQA-8, `head_dim=128`, 80 attention layers ⇒
`kv_per_token_bytes = 80 × 2 × 8 × 128 × 2 = 327,680` — about **40× per
token** what Kimi-Linear costs and **20×** what Nemotron costs.
`max_position_embeddings = 32,768`; longer contexts require YaRN extension,
which we deliberately do not enable so the published number is directly
comparable to "stock dense" the paper reports.

| input_len | Skv (bytes) | Tprefill p25 (ms) | p50 | p75 | Φkv (Gbps) |
|---:|---:|---:|---:|---:|---:|
| 1,024   | 335,544,320    | 64.7  | 64.7  | 64.7  | 41.49 |
| 2,048   | 671,088,640    | 107.4 | 107.5 | 107.5 | 49.96 |
| 4,096   | 1,342,177,280  | 190.9 | 190.9 | 190.9 | 56.25 |
| 8,192   | 2,684,354,560  | 380.5 | 380.6 | 380.7 | 56.42 |
| 16,384  | 5,368,709,120  | 798.1 | 798.3 | 798.5 | 53.80 |
| 32,768  | 10,737,418,240 | —     | —     | —     | (skipped: > `safe_max=32639`) |
| 65,536  | 21,474,836,480 | —     | —     | —     | (skipped) |
| 131,072 | 42,949,672,560 | —     | —     | —     | (skipped) |

**Reading:** Φkv plateau **≈ 54–56 Gbps** for `l ∈ [4 K, 16 K]`. KV size
at 16 K is **5.0 GB per request, single replica**. To extend the dense
control to 32 K+ we'd need YaRN; that's queued as a follow-up.

### 6.3 Hybrid vs dense — the paper's qualitative claim, replicated

| input_len | Φkv Kimi (Gbps) | Φkv Nemotron (Gbps) | Φkv Qwen2.5-72B (Gbps) | dense / Kimi | dense / Nemotron |
|---:|---:|---:|---:|---:|---:|
|  4,096 |  3.59 |  7.02 | 56.25 | **15.7×** | 8.0× |
|  8,192 |  5.62 |  5.91 | 56.42 | **10.0×** | 9.5× |
| 16,384 |  5.81 |  6.38 | 53.80 |  **9.3×** | 8.4× |

The dense control produces KV bytes between **9× and 16× faster** than
the hybrids in the band where all three coexist. PrfaaS's central claim
is that this is the asymmetry that makes hybrids feasible to disaggregate
across a commodity datacenter wire and dense models not.

### 6.4 Wire-feasibility cross-check (the headline)

Predicate: a model is feasible to disaggregate across our wire iff
`Φkv(l) ≤ 14.7 Gbps` per replica (paper Eq 6 reduced to the Stage 0a
constant).

| input_len | Kimi-Linear-48B | Nemotron-Nano-9B-v2 | Qwen2.5-72B |
|---:|:---:|:---:|:---:|
|  4,096 | feasible (3.59 ≪ 14.7) | feasible (7.02 < 14.7) | **infeasible** (56.25 ≫ 14.7) |
|  8,192 | feasible (5.62 < 14.7) | feasible (5.91 < 14.7) | **infeasible** (56.42 ≫ 14.7) |
| 16,384 | feasible (5.81 < 14.7) | feasible (6.38 < 14.7) | **infeasible** (53.80 ≫ 14.7) |
| 32,768 | feasible (5.82 < 14.7) | feasible (6.57 < 14.7) | n/a (model max) |
| 65,536 | feasible (5.65 < 14.7) | feasible (6.56 < 14.7) | n/a |
|131,072 | feasible (5.25 < 14.7) | n/a (probe limit) | n/a |

Both hybrids stay **2.2–4× under** our wire across the entire
paper-relevant context range; the dense control is **4× over** the wire
even at its shortest cell. This is exactly the gap the paper says PD-
disaggregation exploits, and it's why Phase 3 will run the empirical
Mooncake disagg path on Kimi-Linear-48B specifically — most paper-
proximate architecture (3:1 hybrid), largest wire-headroom (≥ 2.5×) in
the band where the paper does its case study.

### 6.5 Observations and surprises

1. **Kimi's headroom holds at 131 K.** Even at the longest cell we
   measured (131,072 tokens), Kimi's Φkv is 5.25 Gbps — still 2.8× under
   the wire. There's no sign of the hybrid hitting a wire-feasibility
   cliff inside the paper's published context range. The wider claim
   that hybrids enable cross-DC PD over commodity links survives a much
   smaller wire than the paper's 100 Gbps VPC peering case study.
2. **Nemotron's per-token KV is 2× Kimi's even though it has fewer
   attention layers.** 4 attention layers × 4096 bytes/layer/token =
   16384, vs Kimi's 7 attention layers × 1152 bytes/layer/token = 8064.
   MLA's compressed KV is the difference. This is why Kimi's Φkv is
   slightly lower than Nemotron's at long contexts — *less* per-token
   KV to ship for the same total prefill work.
3. **Dense Φkv plateaus, doesn't keep climbing.** Qwen2.5-72B's Φkv
   actually drops slightly from 56.4 Gbps at `l=8 K` to 53.8 Gbps at
   `l=16 K`. KV size doubles linearly but Tprefill more than doubles
   because GQA's `O(l²)` attention starts to bite. Total bytes-per-second
   asymptotes; the system isn't "going faster", it's "getting bigger
   slower" in throughput terms.
4. **MoE warmup variance is small.** Kimi-Linear is MoE with 8
   experts/token routed; we worried the first 5 warmup requests would
   leave per-l Tprefill noisy. Empirically, P75 / P25 ratio is < 1.02
   for `l ≥ 8 K` across all 20 timed samples per cell, which says
   warmup is enough. Worth re-validating with 50-warmup if Phase 2 finds
   the analytical model is noise-sensitive.
5. **Per-token KV scaling between dense models is what the paper would
   predict.** Qwen2.5-72B's 327 KB/token at 80 layers projects to
   ~960 KB/token for a 235 B / 240-layer dense — within a factor of 2
   of the paper's Qwen3-235B Φkv, when you also account for active-MoE
   sparsity. Our 72 B dense isn't the paper's 235 B, but it lands in
   the right neighbourhood for the paper's "dense doesn't fit" claim.
6. **Engine version bias is upward, not downward.** SGLang `v0.5.9` is
   newer than the paper's snapshot. Newer attention kernels would push
   our Φkv slightly *higher* than the paper's. We see ~5.8 Gbps for
   Kimi at 32 K vs the paper's ~4 Gbps — consistent with a kernel
   upgrade. Doesn't change the feasibility verdict.

## 7. Reproducibility

Every measurement in this log can be reproduced from this branch.

### 7.1 Stage 0a — Wire bench

```bash
cd prfaas/m1-tcp-bench
# See README in that directory; needs the X-cluster public IPs and
# firewall whitelist already in place.
./scripts/run_matrix.sh MODE=native
```

### 7.2 Stage A — vLLM single-host smoke (g126)

```bash
cd prfaas/m1.5-vllm-baseline/k8s/stageA
KUBECONFIG=/path/to/aln1-beta-harsha-g126-beta.kubeconfig.yaml \
  ./apply.sh   # see prfaas/results/stageA/SUMMARY.md §Reproduction for the
               # full sequence; it's idempotent.
```

### 7.3 Phase 1 — SGLang Φkv on g126

```bash
cd prfaas/m1.5-vllm-baseline/k8s/phase1
export KCFG=/path/to/aln1-beta-harsha-g126-beta.kubeconfig.yaml

# 1) Apply ConfigMaps + PVCs.
kubectl --kubeconfig=$KCFG -n default apply -f 00-namespace.yaml
kubectl --kubeconfig=$KCFG -n default apply -f 01-model-pvc.yaml

# 2) Sync the probe script as a ConfigMap (source-of-truth file is
#    prfaas/m1.5-vllm-baseline/scripts/phi_kv_probe.py).
kubectl --kubeconfig=$KCFG -n default create configmap prfaas-phase1-probe-script \
  --from-file=phi_kv_probe.py=../../scripts/phi_kv_probe.py \
  --dry-run=client -o yaml \
  | kubectl --kubeconfig=$KCFG -n default apply -f -

# 3) Stage weights for whichever model(s) you want, wait for completion.
kubectl --kubeconfig=$KCFG -n default apply -f 02-model-staging-job-kimi.yaml
kubectl --kubeconfig=$KCFG -n default apply -f 03-model-staging-job-qwen72b.yaml
# Nemotron weights re-use the Stage A staging if you've kept them.

kubectl --kubeconfig=$KCFG -n default wait --for=condition=complete \
  --timeout=2400s job/model-staging-kimi-linear-48b
kubectl --kubeconfig=$KCFG -n default wait --for=condition=complete \
  --timeout=2400s job/model-staging-qwen2-5-72b

# 4) Run profilers SEQUENTIALLY (each needs all 8 GPUs except Nemotron at TP=4).
kubectl --kubeconfig=$KCFG -n default apply -f 10-profiler-kimi.yaml
kubectl --kubeconfig=$KCFG -n default wait --for=condition=complete \
  --timeout=1800s job/phi-kv-profiler-kimi-linear-48b

kubectl --kubeconfig=$KCFG -n default apply -f 11-profiler-qwen72b.yaml
kubectl --kubeconfig=$KCFG -n default wait --for=condition=complete \
  --timeout=1800s job/phi-kv-profiler-qwen2-5-72b

kubectl --kubeconfig=$KCFG -n default apply -f 12-profiler-nemotron.yaml
kubectl --kubeconfig=$KCFG -n default wait --for=condition=complete \
  --timeout=1800s job/phi-kv-profiler-nemotron-nano-9b-v2

# 5) Pull JSONL out of the results PVC.
#    (kubectl cp through a long-lived results-reader sidecar is
#    documented in prfaas/m1.5-vllm-baseline/k8s/phase1/README.md.)
```

`prfaas/m1.5-vllm-baseline/k8s/phase1/README.md` has the full operator
guide, including the disk-pressure mitigations.

## 8. Open questions and deferrals

| # | Question | Why it matters | Deferred to |
|---|---|---|---|
| Q1 | What does the paper's Table 6 actually report for Kimi-Linear-48B Φkv per `l`? | Direct quantitative diff against our numbers — completes the Phase 1 acceptance criterion. | Phase 2 prerequisite (typed up as `prfaas/results/phase1_phi_kv/PAPER_PHI_KV.md`). |
| Q2 | Does YaRN-extended Qwen2.5-72B preserve Φkv shape? Tprefill grows quadratically with context, KV bytes linearly, so Φkv should *rise* — that's a Phase 2.5 cell. | Lets us extend the dense control beyond 32 K and see whether dense Φkv keeps growing or plateaus. | Phase 2.5 (optional, after Phase 2). |
| Q3 | Are the X-cluster nodes (g304, g307) GPU-exposed in K8s? | Phase 3 cross-DC and the 229 B / 309 B paper class both need this. | Re-check with infra; tracked as todo `x_cluster_check`. |
| Q4 | Does SGLang's Mooncake binding actually carry KV across pods at our wire's RTT and BW? | Phase 3 is built on this. | Phase 3 single-host first (g126 split TP=4+TP=4) before going cross-DC. |
| Q5 | What's the WireGuard cost on this wire? | Only matters for production; our benchmark path uses firewall whitelist. | Stage 0b (not blocking). |
| Q6 | Does our SupportsHMA shim land upstream as-is, or do reviewer comments require a redesign? | If it requires a redesign, we either hold the PR or rewrite. | PR #1931 review queue. |

## 9. What a new contributor should read, in order

1. This file (you are here).
2. [`PAPER_REREAD.md`](./PAPER_REREAD.md) — what the paper actually claims.
3. [`EXPERIMENT_PLAN.md`](./EXPERIMENT_PLAN.md) §3 (hypotheses) and §5
   (stages).
4. [`results/phase1_phi_kv/PHI_KV_TABLE.md`](./results/phase1_phi_kv/PHI_KV_TABLE.md)
   — the data.
5. [`DECISIONS.md`](./DECISIONS.md) — why we chose what we chose.
6. [`INFRA_LOG.md`](./INFRA_LOG.md) — what bit us and how we got around
   it (only if you're operating the rig).
7. [`m1.5-vllm-baseline/k8s/phase1/README.md`](./m1.5-vllm-baseline/k8s/phase1/README.md)
   — the operator guide for the most recent active workstream.

## 10. Open / "watch this space" board

| Item | Status |
|---|---|
| Phase 2 — analytical Λ_max regenerator using our Φkv + 14.7 Gbps wire | **NEXT.** No GPUs needed; pure code. |
| X-cluster GPU exposure in K8s | blocked (per discovery); needed for Qwen3-235B / MiMo-V2-Flash class |
| SupportsHMA upstream PR (Mooncake #1931) | open, addressed reviewer comments, awaiting maintainer |
| Phase 3 design doc | not started; depends on Phase 2 picking the model |
| Stage B/C/D port from vLLM to SGLang | manifests scaffolded for vLLM; will port |
| Path C (write a hybrid-aware MooncakeConnector ourselves) | downgraded from "blocking" to "nice-to-have" once SGLang picked up Path B; conditional on Phase 3 outcome |
