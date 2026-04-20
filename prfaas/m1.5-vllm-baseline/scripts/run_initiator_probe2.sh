#!/usr/bin/env bash
# Stage 0a probe v2 — focused sweep around the 8-12 thread sweet spot the
# first probe found (15 Gbps at 8 threads / 2M block / 1M slice). Avoid the
# 32-thread regime that ballooned to 450+ TCP conns and stalled.
#
# Usage: bash run_initiator_probe2.sh <host:port>

set -euo pipefail
# shellcheck disable=SC1091  # env file lives on the remote node
. /home/ubuntu/prfaas/.prfaas_stage0a_env

target="${1:?usage: $0 <host:port>}"
ts=$(date -u +"%Y%m%dT%H%M%SZ")
out_dir="/home/ubuntu/prfaas/results/stage0a/${ts}"
mkdir -p "$out_dir"
csv="$out_dir/probe.csv"

run_initiator="${MOONCAKE_DIR}/prfaas/m1-tcp-bench/scripts/run_initiator.sh"
[[ -x "$run_initiator" ]] || { echo "missing $run_initiator"; exit 1; }

echo "[probe2] target=$target  csv=$csv"

cells=(
  "--op write --block-size 2097152 --threads 4  --batch-size 32 --slice-size 524288  --conn-pool 1 --roundrobin 0 --duration 20 --notes 4t_2M_512Kslice"
  "--op write --block-size 2097152 --threads 4  --batch-size 32 --slice-size 1048576 --conn-pool 1 --roundrobin 0 --duration 20 --notes 4t_2M_1Mslice"
  "--op write --block-size 2097152 --threads 8  --batch-size 32 --slice-size 524288  --conn-pool 1 --roundrobin 0 --duration 20 --notes 8t_2M_512Kslice"
  "--op write --block-size 2097152 --threads 8  --batch-size 32 --slice-size 1048576 --conn-pool 1 --roundrobin 0 --duration 30 --notes 8t_2M_1Mslice_30s"
  "--op write --block-size 2097152 --threads 8  --batch-size 64 --slice-size 1048576 --conn-pool 1 --roundrobin 0 --duration 30 --notes 8t_2M_1Mslice_b64"
  "--op write --block-size 2097152 --threads 12 --batch-size 32 --slice-size 1048576 --conn-pool 1 --roundrobin 0 --duration 30 --notes 12t_2M_1Mslice"
  "--op write --block-size 4194304 --threads 8  --batch-size 32 --slice-size 1048576 --conn-pool 1 --roundrobin 0 --duration 30 --notes 8t_4M_1Mslice"
  "--op write --block-size 2097152 --threads 8  --batch-size 32 --slice-size 1048576 --conn-pool 0 --roundrobin 0 --duration 30 --notes 8t_2M_1Mslice_NOPOOL"
  "--op read  --block-size 2097152 --threads 8  --batch-size 32 --slice-size 1048576 --conn-pool 1 --roundrobin 0 --duration 30 --notes 8t_2M_1Mslice_READ"
)

for cell in "${cells[@]}"; do
  echo
  echo "[probe2] cell: $cell"
  # shellcheck disable=SC2086
  timeout 90s bash "$run_initiator" --segment-id "$target" --csv "$csv" --profile real $cell || \
    echo "[probe2] cell exited non-zero or timed out (recorded in CSV row)"
  sleep 3   # let TIME-WAIT drain a bit
done

echo
echo "[probe2] DONE"
echo "[probe2] csv=$csv"
echo
echo "=== Results ==="
column -t -s, "$csv"
