# M1 — Cross-DC TCP Transfer Baseline

**Question this milestone answers:**
> Can Mooncake's `TcpTransport` deliver enough usable bandwidth, with low enough tail latency, across a realistic cross-datacenter Ethernet link to sustain hybrid-attention model KVCache transfer at PrfaaS scale (per the paper, ~13 Gbps avg, peak ≤ 100 Gbps)?

## Hypotheses to test

Derived from §3.3 ("multi-connection TCP transport") and §4.3.1 (13 Gbps observed) of the PrfaaS paper:

| # | Hypothesis | Knob(s) we sweep |
|---|---|---|
| H1 | TCP throughput on a 100 Gbps WAN link with 5–20 ms RTT can sustain ≥80 Gbps with the right slice/thread settings. | `--threads`, `MC_SLICE_SIZE`, `MC_TCP_ENABLE_CONNECTION_POOL` |
| H2 | KV-block-sized transfers (64 KB, 256 KB, 2 MiB) preserve P99 latency under load. | `--block_size`, offered load |
| H3 | Connection pooling materially helps at high RTT (avoids slow-start per request). | `MC_TCP_ENABLE_CONNECTION_POOL=on/off` |
| H4 | `MC_PATH_ROUNDROBIN` improves aggregate throughput when multiple TCP paths exist. | `MC_PATH_ROUNDROBIN=on/off` |
| H5 | Mild loss (0.01%–0.1%) — typical for inter-DC links — collapses single-stream throughput but is largely absorbed by multi-thread + multi-connection. | `tc netem loss` |

## Experimental matrix

For each `(rtt, loss, bw_cap)` WAN profile, we sweep:

- `block_size ∈ {65536, 262144, 2097152}` (64 KB, 256 KB, 2 MiB)
- `threads ∈ {1, 4, 12, 32}`
- `MC_SLICE_SIZE ∈ {65536, 262144, 1048576}` (64 KB, 256 KB, 1 MiB)
- `MC_TCP_ENABLE_CONNECTION_POOL ∈ {0, 1}`
- `operation ∈ {read, write}`

WAN profiles (`prfaas/m1-tcp-bench/scripts/wan_profiles.sh`):

| Profile | RTT | Loss | BW cap | Notional scenario |
|---|---|---|---|---|
| `lan` | 0 ms | 0% | uncapped | local sanity / control |
| `metro` | 2 ms | 0% | 100 Gbps | same-region peering |
| `regional` | 10 ms | 0.01% | 100 Gbps | cross-region VPC peering (paper's setup) |
| `continental` | 40 ms | 0.05% | 40 Gbps | cross-continent dedicated line |

Each cell runs for `--duration=20` and we capture mean Gbps + P50/P99 latency reported by `transfer_engine_bench`.

## Layout

```
m1-tcp-bench/
├── README.md             ← this file
├── METHODOLOGY.md        ← what we measure, why, and how it maps to the paper
├── docker/
│   ├── Dockerfile        ← Mooncake + tc netem + bench binary
│   └── compose.yml       ← two "DC" containers + a bridge with tc netem
├── scripts/
│   ├── wan_profiles.sh   ← tc netem profiles
│   ├── apply_wan.sh      ← apply a profile inside a container
│   ├── run_target.sh     ← starts transfer_engine_bench --mode=target
│   ├── run_initiator.sh  ← runs one cell of the matrix, appends to results CSV
│   ├── run_matrix.sh     ← drives the full sweep
│   └── plot_results.py   ← turns the CSV into figures
└── results/              ← CSVs + plots, committed for traceability
```

## Quickstart (local emulated WAN)

> Two real DCs are the eventual target; the emulated path lets us iterate without burning cluster time.

```bash
# 1. Build the bench image (≈ 15 min cold; cached after).
cd prfaas/m1-tcp-bench/docker
docker compose build

# 2. Run a single profile end-to-end. Results land in ../results/<profile>.csv
cd ..
./scripts/run_matrix.sh regional

# 3. Plot.
python3 ./scripts/plot_results.py results/regional.csv
```

## Two-cluster (real WAN) mode

Set `WAN_PROFILE=real` and skip the emulator; `run_target.sh`/`run_initiator.sh`
are the same scripts and just need the right `--metadata_server` and
`--segment_id` for your two clusters.

## Status

- [ ] Dockerfile + compose for emulated WAN
- [ ] `wan_profiles.sh` with the four profiles
- [ ] Driver scripts (`run_target.sh`, `run_initiator.sh`, `run_matrix.sh`)
- [ ] Result CSV schema + plotter
- [ ] First report: `results/REPORT.md` summarizing H1–H5 outcomes

See `METHODOLOGY.md` for the measurement details and how each metric maps back to the paper's throughput model (Eq. 1, 2, 3).
