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
#   PROTOCOL          tcp|rdma        (default: tcp)

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
  echo "timestamp,profile,rtt_ms,loss_pct,bw_mbit,op,block_size,threads,batch_size,slice_size,conn_pool,roundrobin,duration_s,goodput_gbps,p50_us,p99_us,retx_delta,bench_exit_code,notes" > "$csv"
fi

# Capture retransmits before/after to attribute losses.
retx_before=$(awk '/segments retransmited/ {print $1; exit}' /proc/net/netstat 2>/dev/null \
              || awk '/TCPRetransSegs/ {print $2; exit}' /proc/net/snmp 2>/dev/null \
              || echo 0)

# Run.
log=$(mktemp)
set +e
env "${env_args[@]}" \
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
exit_code=$?
set -e

retx_after=$(awk '/segments retransmited/ {print $1; exit}' /proc/net/netstat 2>/dev/null \
             || awk '/TCPRetransSegs/ {print $2; exit}' /proc/net/snmp 2>/dev/null \
             || echo 0)
retx_delta=$(( retx_after - retx_before ))

# Parse the bench's reported throughput. The current bench prints a line that
# includes the throughput value; we grep liberally and let plot_results.py
# normalize. Latency percentiles are TBD — first revision: leave blank, then
# extend the bench (or wrap it) to emit them.
goodput_gbps=$(grep -Eio '([0-9]+\.[0-9]+)[[:space:]]*(Gbps|Gb/s|Gb)' "$log" | tail -1 | awk '{print $1}' || true)
p50_us=""
p99_us=""

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# CSV-escape notes by stripping commas.
notes_clean="${notes//,/;}"

echo "${ts},${profile},${rtt_ms},${loss_pct},${bw_mbit},${op},${block_size},${threads},${batch_size},${slice_size},${conn_pool},${roundrobin},${duration},${goodput_gbps},${p50_us},${p99_us},${retx_delta},${exit_code},${notes_clean}" >> "$csv"

echo "[run_initiator] cell complete: profile=${profile} bs=${block_size} th=${threads} slice=${slice_size:-default} pool=${conn_pool:-default} rr=${roundrobin:-default} -> ${goodput_gbps:-?} Gbps (exit=${exit_code})"

# Keep last log around for debugging.
mv "$log" "${csv}.last.log"
