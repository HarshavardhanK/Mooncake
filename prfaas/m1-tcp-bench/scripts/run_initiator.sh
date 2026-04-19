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

# Run.
log=$(mktemp)
set +e
# `${env_args[@]}` would error under `set -u` if the array is empty; the
# `+"${env_args[@]}"` form expands to nothing in that case.
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
exit_code=$?
set -e

retx_after=$(read_retrans)
retx_delta=$(( retx_after - retx_before ))

# Parse the bench's reported throughput. The bench logs (via glog to stderr,
# which we redirect into $log):
#   "Test completed: duration 20.00, batch count 1234, throughput 78.32 Gb/s"
# We pull the value adjacent to "throughput" so we don't accidentally match
# the units string from elsewhere in the log.
goodput_gbps=$(grep -Eo 'throughput[[:space:]]+[0-9]+\.[0-9]+[[:space:]]*Gb/s' "$log" \
               | tail -1 | awk '{print $2}' || true)
p50_us=""
p99_us=""

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# CSV-escape notes by stripping commas.
notes_clean="${notes//,/;}"

echo "${ts},${profile},${rtt_ms},${loss_pct},${bw_mbit},${op},${block_size},${threads},${batch_size},${slice_size},${conn_pool},${roundrobin},${duration},${goodput_gbps},${p50_us},${p99_us},${retx_delta},${exit_code},${notes_clean}" >> "$csv"

echo "[run_initiator] cell complete: profile=${profile} bs=${block_size} th=${threads} slice=${slice_size:-default} pool=${conn_pool:-default} rr=${roundrobin:-default} -> ${goodput_gbps:-?} Gbps (exit=${exit_code})"

# Keep last log around for debugging.
mv "$log" "${csv}.last.log"
