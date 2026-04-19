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
│   ├── Dockerfile        ← Mooncake + tc netem + bench binary (canonical deps.sh)
│   └── compose.yml       ← two "DC" containers + a bridge with tc netem
├── bench/                ← latency-aware bench, gated by -DWITH_PRFAAS=ON
│   ├── CMakeLists.txt
│   └── transfer_engine_lat_bench.cpp
├── scripts/
│   ├── native_build.sh   ← build transfer_engine_bench on a cluster node (no Docker)
│   ├── smoke_test.sh     ← target+initiator on loopback; validates harness wiring
│   ├── wan_profiles.sh   ← tc netem profiles
│   ├── apply_wan.sh      ← apply a profile inside a container
│   ├── run_target.sh     ← starts transfer_engine_bench --mode=target
│   ├── run_initiator.sh  ← runs one cell of the matrix, appends to results CSV
│   ├── run_matrix.sh     ← drives the full sweep (MODE=compose|native)
│   └── plot_results.py   ← turns the CSV into figures
└── results/              ← CSVs + plots, committed for traceability
```

## Three ways to run

### A) Single-host smoke test (fastest sanity check)

Builds natively, runs target + initiator on loopback. ~3 min after deps are installed.

```bash
sudo ./dependencies.sh -y                            # canonical Mooncake deps + submodules
./prfaas/m1-tcp-bench/scripts/native_build.sh        # ~5–10 min cold
./prfaas/m1-tcp-bench/scripts/smoke_test.sh          # writes results/smoke.csv
```

If `smoke.csv` shows non-zero `goodput_gbps` and `bench_exit_code=0` for all rows, the harness is working end-to-end.

### B) Local emulated WAN (Docker required)

Two "DC" containers on a bridge with `tc netem` + `tbf` between them. Useful on a laptop to debug the matrix logic before two-DC runs.

```bash
git submodule update --init --recursive              # required for the Docker build
cd prfaas/m1-tcp-bench/docker
docker compose build                                 # ~15 min cold
docker compose up -d
cd ..
./scripts/run_matrix.sh regional                     # writes results/regional.csv
python3 ./scripts/plot_results.py results/regional.csv
```

### C) Two real DCs (no Docker)

```bash
# Build on both nodes:
sudo ./dependencies.sh -y && ./prfaas/m1-tcp-bench/scripts/native_build.sh

# DC-A — start target. Note the "listening on host:port" line.
PROTOCOL=tcp BUFFER_SIZE_MB=8192 \
  LD_LIBRARY_PATH=$PWD/build/mooncake-transfer-engine/src:$PWD/build/mooncake-asio \
  ./prfaas/m1-tcp-bench/scripts/run_target.sh

# DC-B — drive the matrix. WAN profile is "real" so we don't apply tc netem.
MODE=native TARGET_HOST=dc-a.internal:15123 \
  ./prfaas/m1-tcp-bench/scripts/run_matrix.sh real

python3 ./prfaas/m1-tcp-bench/scripts/plot_results.py prfaas/m1-tcp-bench/results/real.csv
```

## Status

- [x] Dockerfile + compose for emulated WAN
- [x] `wan_profiles.sh` with the four profiles
- [x] Driver scripts (`run_target.sh`, `run_initiator.sh`, `run_matrix.sh`)
- [x] Native build + smoke test (no Docker)
- [x] Result CSV schema + plotter
- [x] P50/P95/P99 latency tracking via `transfer_engine_lat_bench`
- [ ] Smoke test passes locally (run on cluster node)
- [ ] First report: `results/REPORT.md` summarizing H1–H5 outcomes

See `METHODOLOGY.md` for the measurement details and how each metric maps back to the paper's throughput model (Eq. 1, 2, 3).
