#!/usr/bin/env bash
# Run a single matrix cell and append a row to the results CSV.
#
# Required:
#   --segment-id      <host:port>     target's RPC endpoint
#   --csv             <path>          results CSV (appended; header written if new)
#   --profile         <name>          WAN profile label (lan|metro|regional|continental|real)
# Knobs:
#   --op              read|write      (default: write — PrfaaS pushes KV)
#   --block-size      <bytes>         (default: 65536)
#   --threads         <n>             (default: 12)
#   --batch-size      <n>             (default: 128)
#   --duration        <s>             (default: 20)
#   --slice-size      <bytes>         sets MC_SLICE_SIZE
#   --conn-pool       0|1             sets MC_TCP_ENABLE_CONNECTION_POOL
#   --roundrobin      0|1             sets MC_PATH_ROUNDROBIN
#   --notes           <string>        free-form note column
# Env:
#   PROTOCOL          tcp|rdma        (default: tcp; ignored when BENCH_BIN=lat)
#   BENCH_BIN         upstream|lat    (default: lat — uses our latency-aware
#                                      bench to populate p50_us/p95_us/p99_us;
#                                      set to "upstream" to use the stock
#                                      transfer_engine_bench, which leaves the
#                                      latency columns blank)

set -euo pipefail

# Defaults
op="write"
block_size=65536
threads=12
batch_size=128
duration=20
slice_size=""
conn_pool=""
roundrobin=""
notes=""
segment_id=""
csv=""
profile=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --segment-id) segment_id="$2"; shift 2;;
    --csv)        csv="$2"; shift 2;;
    --profile)    profile="$2"; shift 2;;
    --op)         op="$2"; shift 2;;
    --block-size) block_size="$2"; shift 2;;
    --threads)    threads="$2"; shift 2;;
    --batch-size) batch_size="$2"; shift 2;;
    --duration)   duration="$2"; shift 2;;
    --slice-size) slice_size="$2"; shift 2;;
    --conn-pool)  conn_pool="$2"; shift 2;;
    --roundrobin) roundrobin="$2"; shift 2;;
    --notes)      notes="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[[ -z "$segment_id" ]] && { echo "--segment-id required"; exit 2; }
[[ -z "$csv" ]]        && { echo "--csv required"; exit 2; }
[[ -z "$profile" ]]    && { echo "--profile required"; exit 2; }

protocol="${PROTOCOL:-tcp}"
bench_bin="${BENCH_BIN:-lat}"

# Resolve WAN profile fields (rtt_ms, loss_pct, bw_mbit) for the CSV.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wan_profiles.sh
source "${here}/wan_profiles.sh"
if [[ "$profile" == "real" ]]; then
  rtt_ms=""; loss_pct=""; bw_mbit=""
else
  read -r rtt_ms loss_pct bw_mbit < <(wan_profile_fields "$profile")
fi

# Build env for Mooncake tunables.
env_args=()
[[ -n "$slice_size" ]] && env_args+=("MC_SLICE_SIZE=${slice_size}")
[[ -n "$conn_pool"  ]] && env_args+=("MC_TCP_ENABLE_CONNECTION_POOL=${conn_pool}")
[[ -n "$roundrobin" ]] && env_args+=("MC_PATH_ROUNDROBIN=${roundrobin}")

mkdir -p "$(dirname "$csv")"
if [[ ! -s "$csv" ]]; then
  echo "timestamp,profile,rtt_ms,loss_pct,bw_mbit,op,block_size,threads,batch_size,slice_size,conn_pool,roundrobin,duration_s,goodput_gbps,p50_us,p95_us,p99_us,retx_delta,bench_exit_code,bench_bin,notes" > "$csv"
fi

# Capture TCP retransmits before/after to attribute losses. We parse
# /proc/net/snmp by header name so we don't depend on column order, which
# differs across kernels.
read_retrans() {
  awk '
    /^Tcp:/ {
      if (h == "") { h = $0 } else { v = $0 }
    }
    END {
      if (h == "" || v == "") { print 0; exit }
      n = split(h, hs); split(v, vs)
      for (i = 1; i <= n; i++) {
        if (hs[i] == "RetransSegs") { print vs[i]; exit }
      }
      print 0
    }' /proc/net/snmp 2>/dev/null || echo 0
}
retx_before=$(read_retrans)

# Run. Two bench binaries are supported:
#   - `transfer_engine_lat_bench` (BENCH_BIN=lat, default): emits
#       TPUT_STATS ... goodput_gbps=NN.NN
#       LAT_STATS  ... p50_us=NN.NN p95_us=NN.NN p99_us=NN.NN
#     to stdout. TCP-only; no --protocol flag.
#   - `transfer_engine_bench`     (BENCH_BIN=upstream): the stock upstream
#     bench. Emits "throughput NN.NN Gb/s" via glog (stderr). Latency cols
#     remain blank.
log=$(mktemp)
set +e
case "$bench_bin" in
  lat)
    env ${env_args[@]+"${env_args[@]}"} \
      transfer_engine_lat_bench \
        --mode=initiator \
        --metadata_server=P2PHANDSHAKE \
        --segment_id="${segment_id}" \
        --operation="${op}" \
        --block_size="${block_size}" \
        --batch_size="${batch_size}" \
        --threads="${threads}" \
        --duration="${duration}" \
        >"$log" 2>&1
    ;;
  upstream)
    env ${env_args[@]+"${env_args[@]}"} \
      transfer_engine_bench \
        --mode=initiator \
        --protocol="${protocol}" \
        --metadata_server=P2PHANDSHAKE \
        --segment_id="${segment_id}" \
        --operation="${op}" \
        --block_size="${block_size}" \
        --batch_size="${batch_size}" \
        --threads="${threads}" \
        --duration="${duration}" \
        --report_unit=Gb \
        >"$log" 2>&1
    ;;
  *)
    echo "unknown BENCH_BIN=${bench_bin} (lat|upstream)" >&2
    exit 2
    ;;
esac
exit_code=$?
set -e

retx_after=$(read_retrans)
retx_delta=$(( retx_after - retx_before ))

# Parse throughput + latency. The lat bench emits machine-readable lines:
#   TPUT_STATS duration_s=20.00 batches=1234 bytes=... goodput_gbps=78.32
#   LAT_STATS  samples=1234 p50_us=120.50 p95_us=350.10 p99_us=512.00 ...
# The upstream bench logs "throughput 78.32 Gb/s" via glog; latency stays blank.
extract() {
  # extract <key> from a "key=val" pair on a line matching <prefix>.
  # Returns empty (and exit 0) if no match — important so a crashed bench
  # still produces a CSV row with the failure recorded, instead of bringing
  # down the whole matrix run via `set -e`.
  local prefix="$1" key="$2"
  { grep -E "^${prefix} " "$log" 2>/dev/null \
      | tail -1 \
      | grep -oE "${key}=[0-9]+(\.[0-9]+)?" \
      | head -1 \
      | cut -d= -f2; } || true
}

goodput_gbps=""
p50_us=""
p95_us=""
p99_us=""
case "$bench_bin" in
  lat)
    goodput_gbps=$(extract TPUT_STATS goodput_gbps)
    p50_us=$(extract LAT_STATS p50_us)
    p95_us=$(extract LAT_STATS p95_us)
    p99_us=$(extract LAT_STATS p99_us)
    ;;
  upstream)
    goodput_gbps=$(grep -Eo 'throughput[[:space:]]+[0-9]+\.[0-9]+[[:space:]]*Gb/s' "$log" \
                   | tail -1 | awk '{print $2}' || true)
    ;;
esac

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# CSV-escape notes by stripping commas.
notes_clean="${notes//,/;}"

echo "${ts},${profile},${rtt_ms},${loss_pct},${bw_mbit},${op},${block_size},${threads},${batch_size},${slice_size},${conn_pool},${roundrobin},${duration},${goodput_gbps},${p50_us},${p95_us},${p99_us},${retx_delta},${exit_code},${bench_bin},${notes_clean}" >> "$csv"

echo "[run_initiator] cell: profile=${profile} bs=${block_size} th=${threads} slice=${slice_size:-default} pool=${conn_pool:-default} rr=${roundrobin:-default} -> ${goodput_gbps:-?} Gbps p99=${p99_us:-?}us (exit=${exit_code})"

# Keep last log around for debugging.
mv "$log" "${csv}.last.log"
