#!/usr/bin/env bash
# Drive the full M1 sweep for a single WAN profile.
#
#   ./run_matrix.sh <profile>
#
# Designed to be run *from the host*, against the docker-compose stack:
#   - applies the WAN profile inside dc_b's egress
#   - starts target inside dc_a (background)
#   - iterates the matrix from dc_b, appending to results/<profile>.csv
#
# For the "real" two-DC setup, override TARGET_HOST / INITIATOR_RUNNER:
#   TARGET_HOST=dc-a.example.com:15000 \
#   INITIATOR_RUNNER="ssh dc-b.example.com /opt/prfaas/scripts/run_initiator.sh" \
#   ./run_matrix.sh real

set -euo pipefail

profile="${1:?usage: run_matrix.sh <profile>}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
m1_root="$(cd "${here}/.." && pwd)"
results_csv="${m1_root}/results/${profile}.csv"

# Compose-mode defaults.
COMPOSE="${COMPOSE:-docker compose -f ${m1_root}/docker/compose.yml}"
TARGET_EXEC="${TARGET_EXEC:-${COMPOSE} exec -T dc_a}"
INIT_EXEC="${INIT_EXEC:-${COMPOSE} exec -T dc_b}"

if [[ "$profile" != "real" ]]; then
  echo "[run_matrix] applying WAN profile=${profile} on dc_b egress"
  ${INIT_EXEC} /work/scripts/apply_wan.sh "${profile}"
fi

echo "[run_matrix] starting target on dc_a"
target_log="${m1_root}/results/${profile}.target.log"
# Run target in background; capture stdout to read the RPC port.
${TARGET_EXEC} bash -lc "/work/scripts/run_target.sh" >"${target_log}" 2>&1 &
target_pid=$!

# Wait for the RPC listen line.
echo "[run_matrix] waiting for target RPC port..."
for _ in $(seq 1 60); do
  if grep -Eo 'listening on [^ ]+:[0-9]+' "${target_log}" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
listen_line=$(grep -Eo 'listening on [^ ]+:[0-9]+' "${target_log}" | tail -1 || true)
if [[ -z "$listen_line" ]]; then
  echo "[run_matrix] target failed to come up; see ${target_log}" >&2
  kill "$target_pid" 2>/dev/null || true
  exit 1
fi
target_addr="${listen_line##* }"
echo "[run_matrix] target=${target_addr}"

trap 'echo "[run_matrix] tearing down"; kill "$target_pid" 2>/dev/null || true; ${INIT_EXEC} bash -lc "tc qdisc del dev \$(ip -o -4 addr show | awk '"'"'\$2!=\"lo\"{print \$2; exit}'"'"') root 2>/dev/null || true" || true' EXIT

# Sweep matrix.
ops=(write read)
block_sizes=(65536 262144 2097152)
threads_list=(1 4 12 32)
slice_sizes=(65536 262144 1048576)
conn_pools=(0 1)
roundrobins=(0 1)

cells=0
for op in "${ops[@]}"; do
for bs in "${block_sizes[@]}"; do
for th in "${threads_list[@]}"; do
for ss in "${slice_sizes[@]}"; do
for cp in "${conn_pools[@]}"; do
for rr in "${roundrobins[@]}"; do
  ${INIT_EXEC} /work/scripts/run_initiator.sh \
    --segment-id "${target_addr}" \
    --csv "/work/results/${profile}.csv" \
    --profile "${profile}" \
    --op "${op}" \
    --block-size "${bs}" \
    --threads "${th}" \
    --slice-size "${ss}" \
    --conn-pool "${cp}" \
    --roundrobin "${rr}"
  cells=$((cells+1))
done; done; done; done; done; done

echo "[run_matrix] done: ${cells} cells -> ${results_csv}"
