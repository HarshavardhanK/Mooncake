# M1 Methodology — what we measure and why

## Mapping to the PrfaaS paper

Recall the per-instance KV throughput (Eq. 1 of the paper):

\[
\Phi_{kv}(l) = \frac{S_{kv}(l)}{T_{prefill}(l)}
\]

and the cluster-level egress requirement (Eq. 2):

\[
B_{out} = \frac{N}{P} \cdot \Phi_{kv}(L_{avg})
\]

For the 1T hybrid case study, the paper reports `Φkv ≈ 2.6–3.6 Gbps/instance` and a measured PrfaaS egress of **13 Gbps** with the routing threshold `t = 19.4K`, well within a 100 Gbps Ethernet link.

PrfaaS-PD throughput (Eq. 3) is gated by the **slower** of compute and egress:

\[
\Theta_{prfaas} = \min\left(\frac{N_{prfaas}}{T_{prefill}(l_{long})},\; \frac{B_{out}}{S_{kv}(l_{long})}\right)
\]

If `B_{out}/S_{kv}` is the binding term, the entire serving system stalls. **M1 characterizes exactly that term in the Mooncake TCP transport.**

## What we measure

For each `(profile, block_size, threads, slice_size, conn_pool, op)` cell:

| Metric | Source | Why we care |
|---|---|---|
| **Aggregate goodput (Gbps)** | `transfer_engine_lat_bench` (or upstream) reported throughput | This *is* `B_{out}` in Eq. 2/3. Determines the bandwidth-bound term. |
| **P50 / P95 / P99 batch latency** | `transfer_engine_lat_bench` per-batch wall-clock measurement (`submitTransfer` → all `getTransferStatus(COMPLETED)`) | Drives end-to-end TTFT contribution under transient bursts (§3.3 "bursty traffic"). The lat bench prints a single `LAT_STATS samples=N p50_us=... p95_us=... p99_us=...` line on stdout for easy parsing. |
| **CPU% on initiator/target** | `pidstat -p $bench_pid 1` sampled in driver | The paper warns about sender-side CPU; we need to know if we're CPU-bound before declaring the link the bottleneck. |
| **Retransmits (`netstat -s`)** | sampled before/after each cell | Validates H5 — does Mooncake's connection pool absorb mild loss? |
| **Effective slice/QP utilization** | `MC_LOG_LEVEL=INFO` parsed | Sanity check for H4 (multi-path round-robin). |

## What we *don't* measure in M1 (deferred to later milestones)

- End-to-end TTFT through a real model — that's M2.
- Hybrid prefix pool hit rates — that's M3.
- Closed-loop scheduler reaction time — that's M4.
- GPUDirect / VRAM↔VRAM transfers — PrfaaS uses commodity Ethernet, so the cross-DC hop is DRAM↔DRAM. Intra-cluster RDMA path is already well-characterized upstream.

## Result schema

`results/<profile>.csv`:

```
timestamp,profile,rtt_ms,loss_pct,bw_cap_gbps,op,block_size,threads,slice_size,conn_pool,roundrobin,duration_s,
goodput_gbps,p50_us,p99_us,cpu_init_pct,cpu_target_pct,retx_delta,bench_exit_code,notes
```

One row per matrix cell. Committed to the repo so that regressions across Mooncake versions are traceable.

## Definition of done for M1

1. We can produce a deterministic CSV for the four WAN profiles, no manual steps beyond `./scripts/run_matrix.sh <profile>`.
2. `results/REPORT.md` documents the outcome of H1–H5 with the plots and one-paragraph analysis each.
3. We can answer with data: "for the 1T hybrid model's `Φkv` of 3.6 Gbps/instance, how many PrfaaS instances can a single 100 Gbps cross-DC link sustain on Mooncake's TCP transport, in our environment?"

That number is the input to M4's `t` and `Np/Nd` solver.
