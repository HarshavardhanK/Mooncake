# PrfaaS on Mooncake

This subtree hosts an experimental implementation of **Prefill-as-a-Service (PrfaaS)** — a cross-datacenter PD-disaggregation architecture — built on top of Mooncake's Transfer Engine, Mooncake Store, and KV Indexer.

Reference paper: *Prefill-as-a-Service: KVCache of Next-Generation Models Could Go Cross-Datacenter* (Qin et al., arXiv:2604.15039, 2026).

> **Start here:** [`EXPERIMENT_PLAN.md`](./EXPERIMENT_PLAN.md) is the end-to-end
> plan for proving the paper on real GPUs (current revision: v0.3 — locks in
> hybrid-attention models, Λ_max-at-SLO as the primary metric, and a
> three-config head-to-head). It maps the milestones below to concrete
> deployment stages (0–D), workloads, hardware roles, and go/no-go criteria.
>
> The actionable runbook for the active milestone (M1.5) is at
> [`m1.5-vllm-baseline/RUNBOOK.md`](./m1.5-vllm-baseline/RUNBOOK.md);
> what the agent needs from you to start is at
> [`m1.5-vllm-baseline/PREFLIGHT.md`](./m1.5-vllm-baseline/PREFLIGHT.md).
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
| **M1.5** | Cross-DC vLLM serving baseline on **hybrid-attention models** (primary: `Qwen/Qwen3-Next-80B-A3B-Instruct`; smoke: `nvidia/NVIDIA-Nemotron-Nano-9B-v2`). Three-config head-to-head (homogeneous decode-only / naive het / PrfaaS-style) sweeping concurrency to find Λ_max at TTFT P95 ≤ SLO. Stages 0 → A → B → C → D. **This is the deliverable that proves (or refutes) the paper.** See [`EXPERIMENT_PLAN.md`](./EXPERIMENT_PLAN.md) and [`m1.5-vllm-baseline/`](./m1.5-vllm-baseline/). | `feat/prfaas-m1.5-vllm-baseline` *(active, blocked on `m1.5-vllm-baseline/PREFLIGHT.md`)* |
| **M2** | Length-based router prototype. Replace the round-robin proxy with one that queries the Mooncake KV indexer; route per §3.4.3 short-term policy. | `feat/prfaas-m2-router` *(planned)* |
| **M3** | Hybrid prefix pool wrapper. Tag prefix-cache vs transfer-cache blocks; rebalance across clusters via `CreateCopyTask`. | `feat/prfaas-m3-hybrid-pool` *(planned)* |
| **M4** | Bandwidth-aware controller. Closed loop on egress utilization + queue depth; periodic `t` and `Np/Nd` re-optimization per §3.4.3. | `feat/prfaas-m4-controller` *(planned)* |

Status of each milestone is tracked in its own README.
