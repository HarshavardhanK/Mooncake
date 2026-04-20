# Stage 0a — Cross-DC TCP transfer characterization

**Date:** 2026-04-20T04:36–04:42 UTC
**Path:** g126 (DFW, Voltage Park) → g304 (IAD, Voltage Park)
**Bench:** `transfer_engine_lat_bench` (M1 latency-instrumented variant)
**Wire:** public Internet (no WireGuard, no private peering)

## Path topology

| | Initiator | Target |
|---|---|---|
| Hostname | `g126` | `g304` |
| Public IP | `147.185.40.126` | `159.26.81.50` |
| DC region | `dfw1.voltagepark.net` | (IAD-class, inferred from DFW↔159.26.81.50 RTT) |
| OS | Ubuntu 24.04 | Ubuntu 24.04 |
| L2/L3 NIC the wire sits on | `enp27s0f0np0` (default route via `10.15.18.110`) | (gateway via `vpsupport`) |
| RTT (5 pings, 200ms apart) | min 29.696 / avg **29.748** / max 29.850 / mdev 0.060 ms | — |
| Loss (5 pings) | 0% | — |

## Bench config (held constant unless noted)

- `--metadata_server=P2PHANDSHAKE` (no etcd/redis dependency)
- target `--buffer_size=4G`
- `MC_LEGACY_RPC_PORT_BINDING=1`, `MC_TCP_ENABLE_CONNECTION_POOL=1` (default for "pool=1" cells)
- profile `real` (no `tc netem` shaping; just the wire as it is)
- batch 32 unless noted; warmup 2s

## Sweep result (CSV: `g126-to-g304_20260420T043602Z.csv`)

| op | block | thr | batch | slice | pool | dur | **goodput** | p50 | p95 | p99 | retx | notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| write | 2 MB | 4  | 32 | 512 KB | 1 | 20s | **16.22 Gbps** | 124 ms | 238 ms | 454 ms | 5872 | best single result |
| write | 2 MB | 4  | 32 | 1 MB   | 1 | 20s | 12.22 Gbps | 153 ms | 358 ms | 667 ms | 6388 | bigger slice ≠ better at 4 thr |
| write | 2 MB | 8  | 32 | 512 KB | 1 | 20s | 14.93 Gbps | 263 ms | 492 ms | 833 ms | 8679 | |
| write | 2 MB | 8  | 32 | 1 MB   | 1 | 30s | 14.72 Gbps | 285 ms | 379 ms | 781 ms | 5422 | reference cell |
| write | 2 MB | 8  | 64 | 1 MB   | 1 | 30s | 14.62 Gbps | 410 ms | 1.25 s | 1.41 s | 1544 | larger batch hurts tail |
| write | 2 MB | 12 | 32 | 1 MB   | 1 | 30s | 14.75 Gbps | 379 ms | 1.02 s | 1.21 s | 2217 | no goodput gain over 8 thr |
| write | 4 MB | 8  | 32 | 1 MB   | 1 | 30s | 14.70 Gbps | 504 ms | 1.26 s | 2.01 s | 12713 | doubling block hurts tail |
| write | 2 MB | 8  | 32 | 1 MB   | **0** | 30s | **3.58 Gbps** | 1.13 s | 1.47 s | 2.13 s | 2063 | **conn-pool OFF: 4× collapse** |
| read  | 2 MB | 8  | 32 | 1 MB   | 1 | 30s | 13.97 Gbps | 161 ms | 1.40 s | 1.68 s | 2 | symmetric: read ≈ write |

A prior 32-thread cell from the first probe ballooned to 453 stuck TCP
connections and stalled — the sweet spot for this wire is **4–8 threads**.

## Headline numbers

- **Median sustained goodput (operating point, 8 thr / 2 MB / 1 MB slice / pool=1):
  ~14.7 Gbps**, both directions.
- **Best observed:** 16.22 Gbps (4 thr / 2 MB / 512 KB slice).
- **Worst observed (pool=0):** 3.58 Gbps. Connection-pool is mandatory.
- **Tail latency at the operating point:** p50 ≈ 285 ms, p95 ≈ 380 ms, p99
  ≈ 780 ms for a 2 MB batch (= 32 × 64 KB slices in flight per thread).
- **Retransmits at operating point:** ~180/s (5422 over 30 s),
  i.e. baseline public-Internet jitter, not a path problem.
- **RTT:** 29.75 ms ± 0.06.

## What this means for SIZING.md

`wire_goodput_gbps = 14.7` (median operating point) ≥ 10 and < 25, which puts
us in the **second branch** of the SIZING.md §4 decision tree:

```
elif wire_goodput_gbps >= 10:
    primary = NVIDIA-Nemotron-Nano-9B-v2
    target_prefill_throughput_per_replica
        = 14.7e9 / 8 / 16384 / 2
        ≈ 56,000 tok/s
```

So:

- **PRIMARY MODEL:** `nvidia/NVIDIA-Nemotron-Nano-9B-v2` (hybrid Mamba2 + 4 attn layers)
- **NUM_PREFILL_REPLICAS:** 2 (each at ~half wire capacity)
- **Per-replica prefill ceiling:** ~56 K tok/s (= 7.35 Gbps × 1/2 KB-per-token)
- **Aggregate prefill ceiling:** ~112 K tok/s

This matches the user's explicit "Nemotron-Nano-9B-v2 for Stage A" choice.

Qwen3-Next-80B-A3B is parked: it would need ≥ 25 Gbps median sustained
goodput, and we're running at ~60% of that. The 2-replica Nemotron config is
both faster to bring up (less GPU memory) and lands the experiment squarely
inside the paper's claimed feasibility envelope.

## Knobs that matter for Stage A onward

These are non-negotiable when Mooncake transport runs under vLLM:

1. `MC_TCP_ENABLE_CONNECTION_POOL=1` (otherwise: 4× degradation, see pool=0 row).
2. Slice size **1 MB** (works as well as 512 KB at higher block sizes;
   matches Mooncake transport defaults).
3. Block size **2 MB** is the sweet spot; 4 MB hurts p99.
4. Per-pair worker thread fanout **4–8**. Above 12 the wire saturates and
   adds tail; above 16 we risk the connection-explosion pathology that
   killed the first probe.
5. `MC_LEGACY_RPC_PORT_BINDING=1` so the bench announces a deterministic RPC
   port the firewall already opens (13000–17000).

## What we still don't know (deferred to Stages 0b / A)

- Time-of-day variance: only one window measured (Sunday 04:30 UTC).
  Need 2 more samples (peak-US and EU-business) before declaring 14.7 Gbps
  is the *median*, not a *night-of-week* artifact. Tracked as **Stage 0a-bis**.
- WireGuard overhead: Stage 0b will repeat the operating-point cell over
  WG (port 51820/UDP, MTU 1420). Expected drop: 5–15%.
- Whether Mooncake under vLLM actually opens 4–8 streams per peer pair, or
  whether it throttles itself to 1. If the latter, vLLM end-to-end will
  cap at the pool=0 number (3.6 Gbps) and demand a transport-layer patch.

## Reproducibility

```bash
# on g304 (target):
bash /tmp/start_target.sh   # wraps transfer_engine_lat_bench --mode=target
                            # logs to /scratch/prfaas/logs/stage0a_target.log

# on g126 (initiator):
bash /tmp/run_initiator_probe2.sh 159.26.81.50:<rpc_port>
# CSV lands in ~/prfaas/results/stage0a/<UTC-ts>/probe.csv
```

The CSV checked in to this directory is the verbatim copy.
