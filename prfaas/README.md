# PrfaaS on Mooncake

This subtree hosts an experimental implementation of **Prefill-as-a-Service (PrfaaS)** — a cross-datacenter PD-disaggregation architecture — built on top of Mooncake's Transfer Engine, Mooncake Store, and KV Indexer.

Reference paper: *Prefill-as-a-Service: KVCache of Next-Generation Models Could Go Cross-Datacenter* (Qin et al., arXiv:2604.15039, 2026).

## Why a separate subtree?

Everything PrfaaS-specific lives under `prfaas/` so that:

- Upstream (`kvcache-ai/Mooncake`) merges stay trivial — no edits to the core tree are interleaved with research code.
- Each milestone is its own self-contained directory with its own README, scripts, and results.

## Roadmap

| Milestone | Goal | Branch |
|---|---|---|
| **M1** | Cross-DC TCP transfer baseline. Wrap `transfer_engine_bench` in a reproducible WAN-emulated harness; characterize throughput vs. RTT, loss, slice size, threads, connection-pool. Validate the §3.4.1 throughput model assumptions. | `feat/prfaas-m1-tcp-bench` |
| **M2** | Length-based router prototype. Sit in front of two vLLM instances (`kv_producer` + `kv_consumer`); query the Mooncake KV indexer; route per §3.4.3 short-term policy. | `feat/prfaas-m2-router` *(planned)* |
| **M3** | Hybrid prefix pool wrapper. Tag prefix-cache vs transfer-cache blocks; rebalance across clusters via `CreateCopyTask`. | `feat/prfaas-m3-hybrid-pool` *(planned)* |
| **M4** | Bandwidth-aware controller. Closed loop on egress utilization + queue depth; periodic `t` and `Np/Nd` re-optimization per §3.4.3. | `feat/prfaas-m4-controller` *(planned)* |

Status of each milestone is tracked in its own README.
