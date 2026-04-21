# PrfaaS on Mooncake

This subtree hosts an experimental implementation of **Prefill-as-a-Service (PrfaaS)** — a cross-datacenter PD-disaggregation architecture — built on top of Mooncake's Transfer Engine, Mooncake Store, and KV Indexer.

Reference paper: *Prefill-as-a-Service: KVCache of Next-Generation Models Could Go Cross-Datacenter* (Qin et al., arXiv:2604.15039, 2026).

## Tree

```
prfaas/
├── README.md                       ← you are here (status + entry pointers)
├── docs/                           ← all narrative documentation
│   ├── 00-overview/                  PROJECT_LOG.md, EXPERIMENT_PLAN.md
│   ├── 10-paper/                     PAPER_REREAD.md, PAPER_MODEL_PLAN.md, PHASE1_PHIKV_PLAN.md
│   ├── 20-decisions/                 DECISIONS.md (ADR register)
│   ├── 30-operations/                INFRA_LOG.md (rig events, postmortems)
│   └── 40-milestones/                per-milestone narrative + RUNBOOK + PREFLIGHT + SIZING
│       ├── m1-tcp-bench/             (cross-DC TCP transport bench)
│       └── m1.5-vllm-baseline/       (cross-DC LLM serving baseline)
├── results/                        ← all measured data, one tree per milestone
│   ├── m1-tcp-bench/                 wire-bench CSVs + logs
│   └── m1.5-vllm-baseline/
│       ├── README.md                 (results schema + Λ_max derivation)
│       ├── discovery/                Phase 0 host discovery JSON + logs
│       ├── stage0a/                  cross-DC TCP characterization (g126↔g304)
│       ├── stageA/                   single-host PD smoke (g126, GREEN on Qwen2.5-7B)
│       ├── stageA-initial/           archived BLOCKED-on-Nemotron diagnostic
│       └── phase1_phi_kv/            paper-faithful Φkv replication (DONE)
├── m1-tcp-bench/                   ← code: bench/, docker/, scripts/
└── m1.5-vllm-baseline/             ← code: configs/, k8s/, scripts/
```

Operator-facing READMEs (the per-stage K8s manifest READMEs at `m1.5-vllm-baseline/k8s/<stage>/README.md` and the per-stage operational plans like `STAGE_B_PLAN.md`) are intentionally co-located with their manifests, not under `docs/` — they are the operator surface for `cd k8s/<stage> && less README.md`.

## Status (2026-04-20, plan v0.4)

| Stage | Status | Headline |
| --- | --- | --- |
| **0** — host preflight + DC assignments | done | g304/g307 on iad1 (X), g126 on dfw1-beta (Y), all on Kubernetes |
| **0a** — cross-DC TCP transfer benchmark (`transfer_engine_bench`) | done | g126 ↔ g304 over public internet: median goodput **~14.7 Gbps**, RTT **29.75 ms**, with TCP connection pooling on. Full results in [`results/m1.5-vllm-baseline/stage0a/`](./results/m1.5-vllm-baseline/stage0a/). |
| **A** — single-host PD smoke (g126, K8s, vLLM v0.19.1) | done — engineering smoke only (not a paper data point) | Qwen2.5-7B-Instruct serves end-to-end through patched MooncakeConnector + bundled proxy → HTTP 200, content `OK`. Negative finding on Nemotron-Nano-9B-v2 (Mamba2 hybrid) — `TpKVTopology.get_kv_cache_shape` `NotImplementedError`. **vLLM v0.19.1's MooncakeConnector cannot serve hybrid models, period.** Full evidence: [`results/m1.5-vllm-baseline/stageA/`](./results/m1.5-vllm-baseline/stageA/). |
| **`SupportsHMA` upstream PR** | open, awaiting maintainer | Single-purpose PR on `feat/supports-hma-shim` → kvcache-ai/Mooncake#1931. Reviewer comments addressed. |
| **Phase 1 — Φkv replication (Kimi-Linear-48B + Nemotron-Nano-9B + Qwen2.5-72B), g126 / SGLang v0.5.9** | **DONE 2026-04-20** | Kimi-Linear-48B Φkv plateau ≈ **5.6–5.8 Gbps** for `l ∈ [16K, 65K]`; Nemotron-Nano-9B Φkv plateau ≈ **6.5 Gbps**; Qwen2.5-72B Φkv plateau ≈ **54–56 Gbps**. Dense / hybrid ratio at 16 K = **9.3× (Kimi) / 8.4× (Nemotron)**. Both hybrids fit our 14.7 Gbps wire at every measured `l`; dense control does not fit at any. Replicates the paper's central qualitative claim on our hardware. Full table + paper diff: [`results/m1.5-vllm-baseline/phase1_phi_kv/PHI_KV_TABLE.md`](./results/m1.5-vllm-baseline/phase1_phi_kv/PHI_KV_TABLE.md). |
| **Phase 2 — Analytical Λ_max regenerator (paper Eq 3-8 in Python, fed by our Φkv + 14.7 Gbps wire)** | **DONE 2026-04-20** | Pure code, no GPUs. Pick: **Kimi-Linear-48B-A3B-Instruct**. Predicted speedup **7.94× at `l = 16384`** (paper-aligned long-context band) and peak **16.00× at `l = 8192`**. Full report: [`results/m1.5-vllm-baseline/phase2_analytical/PHASE2_PICK.md`](./results/m1.5-vllm-baseline/phase2_analytical/PHASE2_PICK.md). Equations + assumptions: [`results/m1.5-vllm-baseline/phase2_analytical/MODEL_AND_EQUATIONS.md`](./results/m1.5-vllm-baseline/phase2_analytical/MODEL_AND_EQUATIONS.md). |
| **Phase 3 — Empirical SGLang+Mooncake PD-disagg** | **MANIFESTS READY 2026-04-20** | Engine locked on SGLang v0.5.9 (rationale: [`docs/40-milestones/m1.5-vllm-baseline/ENGINE_DECISION.md`](./docs/40-milestones/m1.5-vllm-baseline/ENGINE_DECISION.md)). Single-host smoke on g126: [`m1.5-vllm-baseline/k8s/phase3-smoke/`](./m1.5-vllm-baseline/k8s/phase3-smoke/). Cross-DC g304→g126: [`m1.5-vllm-baseline/k8s/phase3-xdc/`](./m1.5-vllm-baseline/k8s/phase3-xdc/). Operator runbook: [`docs/30-operations/XDC_RUNBOOK.md`](./docs/30-operations/XDC_RUNBOOK.md). |
| **B / D — Original vLLM scaffolds (single-cluster + cross-DC)** | DEPRECATED for paper-replication path | Superseded by `phase3-smoke` + `phase3-xdc`. Files retained for historical reference; see each directory's `DEPRECATED.md`. |

## Where to start

1. [`docs/00-overview/PROJECT_LOG.md`](./docs/00-overview/PROJECT_LOG.md) — narrative + canonical state + every measurement we have. **The single most useful entry point.**
2. [`docs/00-overview/EXPERIMENT_PLAN.md`](./docs/00-overview/EXPERIMENT_PLAN.md) — the plan: stages, hypotheses, go/no-go criteria (current revision: v0.4 — paper-faithful re-alignment around Phase 1 / Phase 2 / Phase 3 plus the Stage 0–D empirical chain).
3. [`docs/20-decisions/DECISIONS.md`](./docs/20-decisions/DECISIONS.md) — every meaningful choice as an ADR (Status / Context / Decision / Consequences / Alternatives Rejected).
4. [`docs/30-operations/INFRA_LOG.md`](./docs/30-operations/INFRA_LOG.md) — every infra event we hit (disk pressure, port collisions, RBAC, GPU exposure) with diagnosis and resolution. Read this if you're operating the rig.
5. [`docs/10-paper/PAPER_REREAD.md`](./docs/10-paper/PAPER_REREAD.md) — what the paper actually claims, and the receipts behind the v0.3 → v0.4 reframing.
6. [`docs/10-paper/PAPER_MODEL_PLAN.md`](./docs/10-paper/PAPER_MODEL_PLAN.md) — paper-model unblock workstream (status board for which paper models we can/can't run yet).
7. [`docs/10-paper/PHASE1_PHIKV_PLAN.md`](./docs/10-paper/PHASE1_PHIKV_PLAN.md) — methodology spec for the Phase 1 Φkv replication.
8. [`results/m1.5-vllm-baseline/phase1_phi_kv/`](./results/m1.5-vllm-baseline/phase1_phi_kv/) — Phase 1 raw data (per-model JSONL), summary table ([`PHI_KV_TABLE.md`](./results/m1.5-vllm-baseline/phase1_phi_kv/PHI_KV_TABLE.md)), paper-comparison ([`COMPARE_TO_PAPER.md`](./results/m1.5-vllm-baseline/phase1_phi_kv/COMPARE_TO_PAPER.md)), and run-by-run notes ([`RUN_NOTES.md`](./results/m1.5-vllm-baseline/phase1_phi_kv/RUN_NOTES.md)) including the postmortems for every bug we caught mid-run.
9. [`results/m1.5-vllm-baseline/stageA/`](./results/m1.5-vllm-baseline/stageA/) — Stage A engineering smoke evidence + the SupportsHMA / Mamba2 negative finding. The earlier BLOCKED-on-Nemotron diagnostic is preserved at [`results/m1.5-vllm-baseline/stageA-initial/`](./results/m1.5-vllm-baseline/stageA-initial/).
10. [`m1.5-vllm-baseline/k8s/phase1/README.md`](./m1.5-vllm-baseline/k8s/phase1/README.md) — Phase 1 operator guide.
11. [`m1.5-vllm-baseline/k8s/phase3-smoke/README.md`](./m1.5-vllm-baseline/k8s/phase3-smoke/README.md) — single-host PD smoke (apply this **before** cross-DC).
12. [`m1.5-vllm-baseline/k8s/phase3-xdc/README.md`](./m1.5-vllm-baseline/k8s/phase3-xdc/README.md) + [`docs/30-operations/XDC_RUNBOOK.md`](./docs/30-operations/XDC_RUNBOOK.md) + [`docs/30-operations/X_CLUSTER_PREFLIGHT.md`](./docs/30-operations/X_CLUSTER_PREFLIGHT.md) — Phase 3 cross-DC stack and runbook.

The roadmap table below is a high-level index; the experiment plan is where the actual decisions live.

## Why a separate subtree?

Everything PrfaaS-specific lives under `prfaas/` so that:

- Upstream (`kvcache-ai/Mooncake`) merges stay trivial — no edits to the core tree are interleaved with research code.
- Each milestone is its own self-contained directory with its own narrative under `docs/40-milestones/<milestone>/`, code under `prfaas/<milestone>/`, and data under `prfaas/results/<milestone>/`.

## Roadmap

| Milestone | Goal | Branch |
|---|---|---|
| **M1** | Cross-DC TCP transfer baseline (synthetic). Wrap `transfer_engine_bench` in a reproducible WAN-emulated harness; characterize throughput vs. RTT, loss, slice size, threads, connection-pool. Validate the §3.4.1 throughput model assumptions. | `feat/prfaas-m1-tcp-bench` |
| **M1.5** | Cross-DC LLM serving baseline, paper-faithful (plan v0.4). Two arms: **(analytical)** Phase 1 measures Φkv on the paper's actual primary hybrid (Kimi-Linear-48B-A3B-Instruct) + adjacent hybrid (Nemotron-Nano-9B-v2) + paper-faithful dense control (Qwen2.5-72B-Instruct) on g126 with SGLang v0.5.9 (the paper's own engine). Phase 2 plugs those Φkv numbers into the paper's Eq 3-8 with our 14.7 Gbps wire to regenerate Λ_max(BW, SLO). **(empirical)** Phase 3 drives an SGLang+Mooncake PD-disaggregation run on the model Phase 2 picks (likely Kimi-Linear-48B). Stage B/C/D run the three-config head-to-head Λ_max sweep on IB / IB+netem / real WAN. The earlier vLLM Stage A (Qwen2.5-7B-Instruct on g126 + the SupportsHMA / Mamba2 negative finding) stays as engineering smoke for the K8s + Mooncake plumbing only. **Phase 1 is DONE; Phase 2 is the next milestone.** See [`docs/00-overview/PROJECT_LOG.md`](./docs/00-overview/PROJECT_LOG.md), [`docs/00-overview/EXPERIMENT_PLAN.md`](./docs/00-overview/EXPERIMENT_PLAN.md), [`results/m1.5-vllm-baseline/phase1_phi_kv/`](./results/m1.5-vllm-baseline/phase1_phi_kv/), and [`docs/40-milestones/m1.5-vllm-baseline/README.md`](./docs/40-milestones/m1.5-vllm-baseline/README.md). | `feat/prfaas-m1.5-vllm-baseline` *(active — Phase 1 done, Phase 2 next)* |
| **M2** | Length-based router prototype. Replace the round-robin proxy with one that queries the Mooncake KV indexer; route per §3.4.3 short-term policy. | `feat/prfaas-m2-router` *(planned)* |
| **M3** | Hybrid prefix pool wrapper. Tag prefix-cache vs transfer-cache blocks; rebalance across clusters via `CreateCopyTask`. | `feat/prfaas-m3-hybrid-pool` *(planned)* |
| **M4** | Bandwidth-aware controller. Closed loop on egress utilization + queue depth; periodic `t` and `Np/Nd` re-optimization per §3.4.3. | `feat/prfaas-m4-controller` *(planned)* |

Status of each milestone is tracked in [`docs/40-milestones/<milestone>/README.md`](./docs/40-milestones/).
