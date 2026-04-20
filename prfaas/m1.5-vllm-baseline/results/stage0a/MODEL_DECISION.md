# Stage 0a → primary-model decision

**Decided:** 2026-04-20T04:42 UTC, by the SIZING.md §4 decision tree.

## Inputs

| Quantity | Value | Source |
|---|---|---|
| `wire_goodput_gbps` (median operating point) | **14.72 Gbps** | Stage 0a SUMMARY, 8 thr / 2 MB / 1 MB slice / pool=1 |
| `wire_goodput_gbps` (best observed) | 16.22 Gbps | Stage 0a SUMMARY, 4 thr / 2 MB / 512 KB slice |
| `wire_goodput_gbps` (worst, no pool) | 3.58 Gbps | Stage 0a SUMMARY, pool=0 row — drives the floor |
| RTT | 29.75 ms | ping g126 → g304 |
| Path | g126 (DFW) ↔ g304 (IAD), public Internet | discovery + traceroute |

## Branch taken

```
elif wire_goodput_gbps >= 10:    # 14.72 falls here
    primary = NVIDIA-Nemotron-Nano-9B-v2
```

Qwen3-Next-80B-A3B-Instruct branch (`>= 25 Gbps`) **not taken** — would
need 70%+ more sustained goodput than the wire delivers tonight.

## Decision

```
PRIMARY_MODEL=nvidia/NVIDIA-Nemotron-Nano-9B-v2
NUM_PREFILL_REPLICAS=2
TARGET_PREFILL_TOK_PER_SEC_PER_REPLICA=56000
TARGET_PREFILL_TOK_PER_SEC_AGGREGATE=112000
KV_PER_TOKEN_BYTES=16384
EXPECTED_KV_DEMAND_PER_REPLICA_GBPS=7.35
WIRE_HEADROOM_GBPS=0.0       # at saturation; ~7.4 Gbps headroom at 50% load
```

## Why two prefiller replicas (not one)

A single prefiller at full Nemotron-Nano TP=4 throughput (~300 K tok/s ×
16 KB) demands ~39 Gbps — well over what the wire sustains. Splitting
across two replicas pulls per-replica demand down to ~7.4 Gbps, which sits
inside the 14.7 Gbps median **with room for transient dips**.

This is the configuration that lets the round-robin proxy absorb wire
jitter without tipping any one replica into prefill stalls.

## Why we did NOT pick Qwen3-Next-80B-A3B

The model itself is feasible per its KV-per-token budget (24 KB), but at
its natural TP=8 prefill rate (~150 K tok/s) it produces ~29.5 Gbps of KV.
That's 2× the median wire. Running it at 30% utilization to fit would
defeat the experiment's headline metric (Λ_max), since prefiller stalls
would dominate before the wire became the bottleneck.

If Stage 0a-bis (different time-of-day window) lifts the median above
25 Gbps consistently, we revisit and run Qwen3-Next as a Stage E variant.

## What to do now (RUNBOOK Stage A inputs)

```bash
# write to ~/.prfaas_env on every node before Stage A:
export PRIMARY_MODEL="nvidia/NVIDIA-Nemotron-Nano-9B-v2"
export PREFILL_TP=4
export DECODE_TP=4
export NUM_PREFILL_REPLICAS=2
export NUM_DECODE_REPLICAS=1
export TARGET_PREFILL_TOK_PER_SEC_AGGREGATE=112000
export MC_TCP_ENABLE_CONNECTION_POOL=1   # mandatory; non-negotiable
export MC_LEGACY_RPC_PORT_BINDING=1
```

The two prefill replicas land on g304+g307 (X-cluster, 2× H100×8 nodes) at
TP=4 each (i.e. 4 GPUs per replica, 8 GPUs per node). Decoder lands on
g126 (Y-cluster, single H100×8 node) at TP=4 with the other 4 GPUs free for
KV-pinned receiver-side caching during Stage C.

This decision is the **input** to RUNBOOK Stage A. No further sizing work
required before we touch a GPU.
