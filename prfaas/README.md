# PrfaaS on Mooncake

This subtree hosts an experimental implementation of **Prefill-as-a-Service (PrfaaS)** — a cross-datacenter PD-disaggregation architecture — built on top of Mooncake's Transfer Engine, Mooncake Store, and KV Indexer.

Reference paper: *Prefill-as-a-Service: KVCache of Next-Generation Models Could Go Cross-Datacenter* (Qin et al., arXiv:2604.15039, 2026).

## Where we are right now (2026-04-20, plan v0.4)

| Stage | Status | Headline |
| --- | --- | --- |
| **0** — host preflight + DC assignments | done | g304/g307 on iad1 (X), g126 on dfw1-beta (Y), all on Kubernetes |
| **0a** — cross-DC TCP transfer benchmark (`transfer_engine_bench`) | done | g126 ↔ g304 over public internet: median goodput **~14.7 Gbps**, RTT **29.75 ms**, with TCP connection pooling on. Full results in `m1-tcp-bench/results/`. |
| **A** — single-host PD smoke (g126, K8s, vLLM v0.19.1) | done — engineering smoke only (not a paper data point) | Qwen2.5-7B-Instruct serves end-to-end through patched MooncakeConnector + bundled proxy → HTTP 200, content `OK`. Negative finding on Nemotron-Nano-9B-v2 (Mamba2 hybrid) — `TpKVTopology.get_kv_cache_shape` `NotImplementedError`. **vLLM v0.19.1's MooncakeConnector cannot serve hybrid models, period.** Full evidence: [`results/stageA/`](./results/stageA/). |
| **`SupportsHMA` upstream PR** | open, awaiting maintainer | Single-purpose PR on `feat/supports-hma-shim` → kvcache-ai/Mooncake#1931. Reviewer comments addressed. |
| **Phase 1 — Φkv replication on the paper's actual hybrid + adjacent hybrid + dense control, on g126 with SGLang v0.5.9** | **DONE 2026-04-20** | Kimi-Linear-48B Φkv plateau ≈ **5.6–5.8 Gbps** for `l ∈ [16K, 65K]`; Nemotron-Nano-9B Φkv plateau ≈ **6.5 Gbps**; Qwen2.5-72B Φkv plateau ≈ **54–56 Gbps**. Dense / hybrid ratio at 16 K = **9.3× (Kimi) / 8.4× (Nemotron)**. Both hybrids fit our 14.7 Gbps wire at every measured `l`; dense control does not fit at any. Replicates the paper's central qualitative claim on our hardware. Full table + paper diff: [`results/phase1_phi_kv/PHI_KV_TABLE.md`](./results/phase1_phi_kv/PHI_KV_TABLE.md). |
| **Phase 2 — Analytical Λ_max regenerator (paper Eq 3-8 in Python, fed by our Φkv + 14.7 Gbps wire)** | NEXT | Pure code, no GPUs. Picks the model + context band for the empirical Phase 3 run. |
| **Phase 3 — Empirical SGLang+Mooncake PD-disagg on the model Phase 2 picks** | not started | Most likely Kimi-Linear-48B at `l ∈ [16K, 65K]`. Single-host first (g126 split TP=4+TP=4), then cross-DC g304→g126 once X-cluster K8s GPU exposure unblocks. |
| **B / C / D — Three-config Λ_max sweeps (homogeneous decode-only / naive het / PrfaaS-style) on IB / IB+netem / real WAN** | manifests scaffolded for vLLM; will port to SGLang | Empirical validation arm of v0.4. |

> **Start here:**
>
> 1. [`PROJECT_LOG.md`](./PROJECT_LOG.md) — narrative + canonical state +
>    every measurement we have. **The single most useful entry point.**
> 2. [`EXPERIMENT_PLAN.md`](./EXPERIMENT_PLAN.md) — the plan: stages,
>    hypotheses, go/no-go criteria (current revision: v0.4 — paper-faithful
>    re-alignment around Phase 1 / Phase 2 / Phase 3 plus the Stage 0–D
>    empirical chain).
> 3. [`DECISIONS.md`](./DECISIONS.md) — every meaningful choice as an ADR
>    (Status / Context / Decision / Consequences / Alternatives Rejected).
> 4. [`INFRA_LOG.md`](./INFRA_LOG.md) — every infra event we hit (disk
>    pressure, port collisions, RBAC, GPU exposure) with diagnosis and
>    resolution. Read this if you're operating the rig.
> 5. [`PAPER_REREAD.md`](./PAPER_REREAD.md) — what the paper actually
>    claims, and the receipts behind the v0.3 → v0.4 reframing.
> 6. [`PAPER_MODEL_PLAN.md`](./PAPER_MODEL_PLAN.md) — paper-model unblock
>    workstream (status board for which paper models we can/can't run yet).
> 7. [`PHASE1_PHIKV_PLAN.md`](./PHASE1_PHIKV_PLAN.md) — methodology spec for
>    the Phase 1 Φkv replication.
> 8. [`results/phase1_phi_kv/`](./results/phase1_phi_kv/) — Phase 1 raw data
>    (per-model JSONL), summary table
>    ([`PHI_KV_TABLE.md`](./results/phase1_phi_kv/PHI_KV_TABLE.md)),
>    paper-comparison
>    ([`COMPARE_TO_PAPER.md`](./results/phase1_phi_kv/COMPARE_TO_PAPER.md)),
>    and run-by-run notes
>    ([`RUN_NOTES.md`](./results/phase1_phi_kv/RUN_NOTES.md)) including
>    the postmortems for every bug we caught mid-run.
> 9. [`results/stageA/`](./results/stageA/) — Stage A engineering smoke
>    evidence + the SupportsHMA / Mamba2 negative finding.
> 10. [`m1.5-vllm-baseline/k8s/phase1/README.md`](./m1.5-vllm-baseline/k8s/phase1/README.md)
>     — operator guide for the most-recently-active workstream.
>
> The roadmap table at the bottom of this README is a high-level index; the
> experiment plan is where the actual decisions live.

## Why a separate subtree?

Everything PrfaaS-specific lives under `prfaas/` so that:

- Upstream (`kvcache-ai/Mooncake`) merges stay trivial — no edits to the core tree are interleaved with research code.
- Each milestone is its own self-contained directory with its own README, scripts, and results.

## Roadmap

| Milestone | Goal | Branch |
|---|---|---|
| **M1** | Cross-DC TCP transfer baseline (synthetic). Wrap `transfer_engine_bench` in a reproducible WAN-emulated harness; characterize throughput vs. RTT, loss, slice size, threads, connection-pool. Validate the §3.4.1 throughput model assumptions. | `feat/prfaas-m1-tcp-bench` |
| **M1.5** | Cross-DC LLM serving baseline, paper-faithful (plan v0.4). Two arms: **(analytical)** Phase 1 measures Φkv on the paper's actual primary hybrid (Kimi-Linear-48B-A3B-Instruct) + adjacent hybrid (Nemotron-Nano-9B-v2) + paper-faithful dense control (Qwen2.5-72B-Instruct) on g126 with SGLang v0.5.9 (the paper's own engine). Phase 2 plugs those Φkv numbers into the paper's Eq 3-8 with our 14.7 Gbps wire to regenerate Λ_max(BW, SLO). **(empirical)** Phase 3 drives an SGLang+Mooncake PD-disaggregation run on the model Phase 2 picks (likely Kimi-Linear-48B). Stage B/C/D run the three-config head-to-head Λ_max sweep on IB / IB+netem / real WAN. The earlier vLLM Stage A (Qwen2.5-7B-Instruct on g126 + the SupportsHMA / Mamba2 negative finding) stays as engineering smoke for the K8s + Mooncake plumbing only. **Phase 1 is DONE; Phase 2 is the next milestone.** See [`PROJECT_LOG.md`](./PROJECT_LOG.md), [`EXPERIMENT_PLAN.md`](./EXPERIMENT_PLAN.md), [`results/phase1_phi_kv/`](./results/phase1_phi_kv/), and [`m1.5-vllm-baseline/`](./m1.5-vllm-baseline/). | `feat/prfaas-m1.5-vllm-baseline` *(active — Phase 1 done, Phase 2 next)* |
| **M2** | Length-based router prototype. Replace the round-robin proxy with one that queries the Mooncake KV indexer; route per §3.4.3 short-term policy. | `feat/prfaas-m2-router` *(planned)* |
| **M3** | Hybrid prefix pool wrapper. Tag prefix-cache vs transfer-cache blocks; rebalance across clusters via `CreateCopyTask`. | `feat/prfaas-m3-hybrid-pool` *(planned)* |
| **M4** | Bandwidth-aware controller. Closed loop on egress utilization + queue depth; periodic `t` and `Np/Nd` re-optimization per §3.4.3. | `feat/prfaas-m4-controller` *(planned)* |

Status of each milestone is tracked in its own README.
