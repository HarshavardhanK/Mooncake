# PrfaaS on Mooncake

This subtree hosts an experimental implementation of **Prefill-as-a-Service (PrfaaS)** — a cross-datacenter PD-disaggregation architecture — built on top of Mooncake's Transfer Engine, Mooncake Store, and KV Indexer.

Reference paper: *Prefill-as-a-Service: KVCache of Next-Generation Models Could Go Cross-Datacenter* (Qin et al., arXiv:2604.15039, 2026).

## Where we are right now (2026-04-20)

| Stage | Status | Headline |
| --- | --- | --- |
| **0** — host preflight + DC assignments | done | g304/g307 on iad1 (X), g126 on dfw1-beta (Y), all on Kubernetes |
| **0a** — cross-DC TCP transfer benchmark (`transfer_engine_bench`) | done | g126 ↔ g304 over public internet: median goodput **~14.7 Gbps**, RTT **29.75 ms**, with TCP connection pooling on. Full results in `m1-tcp-bench/results/` |
| **A** — single-host PD smoke (g126, K8s) | **done — green on dense + first paper-relevant negative finding on hybrid** | Qwen2.5-7B-Instruct serves end-to-end through patched MooncakeConnector + bundled proxy → HTTP 200, content `OK`. Nemotron-Nano-9B-v2 (Mamba2+attn hybrid) crashes deeper than `SupportsHMA` — `TpKVTopology.get_kv_cache_shape` raises `NotImplementedError` on the Mamba2 backend. **vLLM v0.19.1's MooncakeConnector cannot serve hybrid models, period.** Full evidence: [`results/stageA/`](./results/stageA/) |
| **B** — internal-X PD-disagg sweep (g304 prefiller, g307 decoder, low-RTT internal LACP) | manifests written, pending `kubectl apply` | [`m1.5-vllm-baseline/k8s/stageB/`](./m1.5-vllm-baseline/k8s/stageB/) |
| **C** — emulated-WAN sweep (g304+g307, `tc netem`) | not started | calibrate against the M1 wire benchmark |
| **D** — real cross-DC PD-disagg (X-cluster prefiller ↔ g126 decoder) | manifests written, pending firewall + apply | [`m1.5-vllm-baseline/k8s/stageD/`](./m1.5-vllm-baseline/k8s/stageD/) |

> **Start here:** [`EXPERIMENT_PLAN.md`](./EXPERIMENT_PLAN.md) is the end-to-end
> plan for proving the paper on real GPUs (current revision: v0.3 — locks in
> hybrid-attention models, Λ_max-at-SLO as the primary metric, and a
> three-config head-to-head). It maps the milestones below to concrete
> deployment stages (0–D), workloads, hardware roles, and go/no-go criteria.
>
> Stage A operational runbook (now realized in K8s):
> [`m1.5-vllm-baseline/k8s/stageA/README.md`](./m1.5-vllm-baseline/k8s/stageA/README.md)
>
> Paper-model follow-up plan (Kimi Linear, MiMo-V2-Flash, Qwen3.5, Ring-2.5,
> MiniMax-M2.5, Qwen3-235B):
> [`PAPER_MODEL_PLAN.md`](./PAPER_MODEL_PLAN.md)
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
| **M1.5** | Cross-DC vLLM serving baseline. Originally targeted hybrid-attention models (Qwen3-Next-80B-A3B as primary, Nemotron-Nano-9B-v2 as smoke). Stage A established empirically that vLLM v0.19.1's MooncakeConnector cannot serve any hybrid Mamba2+attn model on the released code path (see [`results/stageA/MC_PATCH_NOTE.md`](./results/stageA/MC_PATCH_NOTE.md)), so the rig now drives Qwen2.5-7B-Instruct (dense) for the wire-level baseline (Stages A→B→C→D) and tracks a separate "paper-model unblock" workstream for the hybrids ([`PAPER_MODEL_PLAN.md`](./PAPER_MODEL_PLAN.md)). Three-config head-to-head (homogeneous decode-only / naive het / PrfaaS-style) sweeping concurrency to find Λ_max at TTFT P95 ≤ SLO. **This is the deliverable that proves (or refutes) the paper.** See [`EXPERIMENT_PLAN.md`](./EXPERIMENT_PLAN.md) and [`m1.5-vllm-baseline/`](./m1.5-vllm-baseline/). | `feat/prfaas-m1.5-vllm-baseline` *(active — Stage A green, Stage B/D queued)* |
| **M2** | Length-based router prototype. Replace the round-robin proxy with one that queries the Mooncake KV indexer; route per §3.4.3 short-term policy. | `feat/prfaas-m2-router` *(planned)* |
| **M3** | Hybrid prefix pool wrapper. Tag prefix-cache vs transfer-cache blocks; rebalance across clusters via `CreateCopyTask`. | `feat/prfaas-m3-hybrid-pool` *(planned)* |
| **M4** | Bandwidth-aware controller. Closed loop on egress utilization + queue depth; periodic `t` and `Np/Nd` re-optimization per §3.4.3. | `feat/prfaas-m4-controller` *(planned)* |

Status of each milestone is tracked in its own README.
