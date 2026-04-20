# Paper-model unblock plan

The PrfaaS paper (Qin et al., arXiv:2604.15039, 2026) makes its central claim
on **hybrid-attention models** (large softmax ratio, mostly linear/SSM
layers, small per-token KV). Stage A established empirically that the
released vLLM (v0.19.1) MooncakeConnector cannot serve hybrid models —
not just gated by the `SupportsHMA` flag (we patched that and proved the
shim works), but structurally:
`TpKVTopology.__post_init__ → attn_backend.get_kv_cache_shape() →
NotImplementedError` on the Mamba2 backend.

So we have two separable workstreams from here:

1. **Wire baseline workstream** (stages A→B→C→D) — drive a *dense* model
   end-to-end so we measure the cross-DC transport, the proxy, the
   firewall, the SLO, the Λ_max curves. **Active.** Stage A green on
   Qwen2.5-7B-Instruct; Stage B/D manifests written and queued.
2. **Paper-model unblock workstream** (this document) — get one or more of
   the paper's actual models running on a connector that supports their
   layer mix. Independent of #1; runs as soon as a) one of the prerequisite
   patches lands upstream, or b) we invest the engineering to write one.

This document is the plan for #2.

## Models the paper actually evaluated

From §4 of the paper:

| Model | Total params | Active params | Layer mix | Why the paper picked it |
| --- | --- | --- | --- | --- |
| **MiniMax-M2.5** | 229B | 10B (MoE) | dense softmax | dense control — paper claim: PrfaaS *does not* beat WAN here |
| **Qwen3-235B** (Thinking-2507) | 235B | 22B (MoE) | dense softmax | dense control |
| **Kimi Linear** | 48B | 3B | hybrid (linear attn + softmax) | hybrid evaluator |
| **MiMo-V2-Flash** | 309B | 32B | 5:1 SWA-to-full hybrid | "claimed PrfaaS sweet spot" |
| **Qwen3.5** | 397B | 30B | 3:1 linear-to-full hybrid | hybrid evaluator |
| **Ring-2.5** | 1T | 50B | 7:1 linear-to-full hybrid | hybrid evaluator + scale stress |

For our rig we have 8× H100 80 GB on g126 plus 16× H100 80 GB across
g304+g307. That makes the only paper models we can serve at all (without
quantization tricks) **Kimi Linear (48B)** and at the edge **MiMo-V2-Flash
(309B, 32B active)** if we MoE-shard across both X-cluster hosts. The 397B
Qwen3.5 and 1T Ring-2.5 are out of reach without offloading. The dense
controls (MiniMax-M2.5, Qwen3-235B) are also out of reach but **we can
substitute Qwen2.5-72B-Instruct or Qwen3-32B as a same-class dense
control** — same-day swap, useful science.

Stage-A surrogate that we *have* running: `Qwen2.5-7B-Instruct` (dense,
not in the paper, but proves the wire). Will not appear in any paper-claim
plot — strictly engineering-baseline.

## What the connector needs to handle each paper model

| Model class | Connector requirement |
| --- | --- |
| Dense softmax (MiniMax-M2.5, Qwen3-235B; surrogates Qwen2.5-72B / Qwen3-32B) | **Already works** in vLLM v0.19.1 MooncakeConnector with our SupportsHMA patch as a no-op. Just needs the disaggregating proxy (see "Proxy" below). |
| Sliding-window-attention hybrids (MiMo-V2-Flash 5:1) | SWA layers still expose a (block, kv_heads, head_dim) cube — `get_kv_cache_shape` works. The hybrid allocator just needs to know the per-layer window. **Likely works** with current connector + a vLLM bump (≥0.20.x once SWA HMA paths stabilize). |
| Linear-attention + softmax hybrids (Kimi Linear, Qwen3.5, Ring-2.5) | Linear attention has no KV cache (or a fixed-size recurrent state). The connector needs to **transfer a per-layer fixed-size state slab in addition to the KV blocks**, with a different shape function. Same structural problem as Mamba2. |
| Mamba2 + attention (Nemotron-Nano-9B-v2 — paper-adjacent only) | SSM state slab + KV blocks. Same as linear-attn case. Currently impossible on released vLLM. |

## Three concrete paths to unblock hybrids (ordered by ETA)

### Path A — Wait for upstream (ETA: weeks to months)

Track:
- vllm-project/vllm PR **#36687** — NIXL connector RFC. Closest in-flight
  design that can speak heterogeneous KV layouts. Currently RFC-only.
- vllm-project/vllm milestone for **v0.20.x** — first release likely to
  ship a hybrid-aware connector path.
- `kvcache-ai/Mooncake` — any v1 MooncakeConnector update that lands
  hybrid awareness.

**Pros:** zero engineering on our side, supported path, comparable to
other research using vLLM.

**Cons:** unbounded ETA. If the paper's claim is correct, every minute we
wait is a minute we can't measure the only thing that matters.

**Plan:** keep our patched 10/20-prefiller/decoder manifests
ConfigMap-driven so the only delta to swap a hybrid model in once support
lands is `PRIMARY_MODEL` / `MODEL_LOCAL_DIR` / `PRIMARY_MODEL_SHORT`. Done.

### Path B — Use SGLang or TensorRT-LLM as the engine (ETA: 1–2 weeks)

SGLang has an experimental disaggregated-prefill mode that includes a
Mooncake transport (`sglang/disaggregation/mooncake/`). Their Mamba2 path
is more recent than vLLM's. Worth a probe before doing path C.

**Plan:** in `prfaas/m1.5-vllm-baseline/k8s/stageA-sglang/`, build a
parallel Stage A using SGLang on the same Qwen2.5-7B-Instruct +
Nemotron-Nano-9B-v2 pair. If SGLang serves Nemotron with KV transfer, we
have an immediate hybrid baseline and can put SGLang on the prefiller
side and vLLM on the decoder (or both SGLang).

**Risk:** SGLang's PD-disagg is also young. Their Mooncake binding may not
be production-ready either.

### Path C — Write a hybrid-aware MooncakeConnector ourselves (ETA: 2–4 weeks)

The shape of the work:

1. In `vllm/distributed/kv_transfer/kv_connector/utils.py::TpKVTopology`,
   replace the unconditional `attn_backend.get_kv_cache_shape(...)` with a
   per-layer-type dispatch. Mamba2 layers register a *contiguous* SSM
   state slab keyed by (request_id, layer_idx, rank); softmax/SWA layers
   register the existing block-based KV.
2. In `MooncakeConnectorWorker`, register two memory regions per worker
   (KV blocks region + SSM state region) with the Transfer Engine.
3. Extend the wire protocol: prefiller's response to the proxy includes
   `remote_block_ids` (already there) AND `remote_ssm_state_offsets`
   (new). Decoder uses both to issue separate `read_batch` calls.
4. Add a per-request `request_finished_all_groups` that releases blocks
   and SSM state in lockstep (the patch we already wrote is the right
   starting point but needs to actually free SSM regions, not just
   collapse block lists).

This is contained work — single connector module, no model changes — and
gives us a model we can submit upstream. It's also the only path that
gives the paper an apples-to-apples replication on the open-source stack.

**Risk:** Mamba2 SSM state size depends on the model's
`state_size`/`d_inner`/`expand`/`d_conv` — connector needs to be
config-driven; we can't hardcode shapes. Manageable.

## Decision (updated 2026-04-19 — Path B selected)

After confirming that **SGLang v0.5.9 ships first-class Mooncake PD-disagg**
(Mooncake transfer engine v0.3.9, GPU staging buffer for heterogeneous TP,
intra-node NVLink KV transfer — see release notes), Path B is no longer
"a probe" — it's the answer. The paper's authors used SGLang for their own
profiling (it's the engine that natively serves Kimi-Linear / Mamba2 /
KDA / MLA without `SupportsHMA` patching), so adopting SGLang for our
hybrid runs is a paper-fidelity *gain*, not a workaround.

**Active plan:**

1. **Phase 1 (now, paper-faithful Φkv replication).** SGLang v0.5.9 +
   Kimi-Linear-48B-A3B-Instruct + Qwen2.5-72B-Instruct (dense control) +
   Nemotron-Nano-9B-v2 (adjacent hybrid) on g126. Single-instance, no
   wire, no PD-disagg — just Φkv per (model, context length).
   Manifests: `prfaas/m1.5-vllm-baseline/k8s/phase1/`.
   Plan: `prfaas/PHASE1_PHIKV_PLAN.md`.
2. **Phase 2 (next).** Implement paper Eq 3-8, feed Phase 1's Φkv +
   Stage 0a's 14.7 Gbps wire, regenerate Λ_max(BW, SLO). Pick the hybrid
   that the analytical model says fits our wire as Phase 3's target.
3. **Phase 3 (after Phase 2).** Empirical SGLang Mooncake PD-disagg run
   on the chosen hybrid. Single-host first (g126 split TP=4+TP=4), then
   cross-DC g304→g126 once X-cluster K8s GPU exposure unblocks.
4. **Path C is now optional.** Our `SupportsHMA` upstream PR (#1931 on
   kvcache-ai/Mooncake) is still useful for vLLM users who want the same
   hybrid support, and the analysis there is still correct, but it is no
   longer on the critical path for *our* paper-replication work.

The original "Stage A on Qwen2.5-7B-Instruct (dense)" stays in the repo as
proof the K8s + Mooncake plumbing is alive, but it is not a paper data point
and is not cited from any paper-replication plot.

## Hardware capacity for each paper model on our rig

| Model | TP | Hosts needed | Fits? | Notes |
| --- | --- | --- | --- | --- |
| Kimi Linear 48B | 8 | g304+g307 (16× H100) | YES at BF16 | active 3B; KV is tiny; ideal first hybrid |
| MiMo-V2-Flash 309B (32B active) | 16 | g304+g307 (16× H100) at FP8 | borderline | MoE shards; needs FP8/INT8 weights |
| Qwen3.5 397B (30B active) | 16 | not without offloading | NO at BF16 | future stretch |
| Ring-2.5 1T (50B active) | — | not on this rig | NO | future stretch |
| MiniMax-M2.5 229B (10B active, dense) | 16 | g304+g307 at FP8 | borderline | dense control |
| Qwen3-235B (22B active, dense) | 16 | g304+g307 at FP8 | borderline | dense control; substitute Qwen2.5-72B if we want a clean BF16 dense control |

So the **most useful** first three hybrid runs once we have a connector
are, in order:

1. **Kimi Linear 48B** — fits comfortably at BF16, exercises the
   linear-attn KV transfer path the paper actually claims.
2. **Nemotron-Nano-9B-v2** — single-host, exercises the Mamba2 path.
3. **MiMo-V2-Flash 309B at FP8** — exercises the SWA hybrid path at
   paper-relevant scale.

## Status board

| Item | Status | Owner | ETA |
| --- | --- | --- | --- |
| Wire baseline on dense (Qwen2.5-7B-Instruct), Stage A | done | rig | done |
| `SupportsHMA` upstream PR — kvcache-ai/Mooncake#1931 | open, mergeable, awaiting human review | upstream | upstream queue |
| Phase 1 — SGLang Φkv on Kimi-Linear-48B-A3B-Instruct | manifests applied; weights downloading on g126 | rig | today (~1h after weights staged) |
| Phase 1 — SGLang Φkv on Qwen2.5-72B-Instruct (dense control) | manifests applied; weights downloading on g126 | rig | today |
| Phase 1 — SGLang Φkv on Nemotron-Nano-9B-v2 (adjacent hybrid) | manifests applied; weights downloading on g126 | rig | today (smallest model — first to validate the SGLang+probe pipeline) |
| Phase 2 — analytical Λ_max regenerator (paper Eq 3-8) | not started | rig | after Phase 1 |
| Phase 3 — SGLang Mooncake PD-disagg on Kimi-Linear (or whatever Phase 2 picks) | not started | rig | after Phase 2 |
| Stage B/C/D — full Λ_max sweep cross-DC on the Phase 3 model | manifests scaffolded for vLLM path; will port to SGLang | rig | after Phase 3 |
| X-cluster K8s GPU exposure (needed for Qwen3-235B / MiMo-V2-Flash) | blocked (per discovery notes) | infra | open |
| Track vllm PR #36687 + v0.20.x | watching | — | — |
| Path C connector PR | not started; downgraded from "blocking" to "nice-to-have" | rig | conditional on Phase 3 outcome |
