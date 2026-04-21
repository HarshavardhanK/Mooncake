#!/usr/bin/env bash
# Drive the full M1 sweep for a single WAN profile.
#
#   ./run_matrix.sh <profile>
#
# Two execution modes, controlled by env:
#
#   MODE=compose  (default)     uses docker-compose stack: dc_a is target,
#                               dc_b is initiator with the WAN qdisc.
#   MODE=native                 expects target on TARGET_HOST already running
#                               (or we'll spawn one locally on $LOCAL_TARGET=1).
#                               Useful for the two-DC setup or single-host
#                               loopback tests when Docker isn't available.
#
# Two-DC pattern (no Docker on the cluster):
#   On dc-a:  PROTOCOL=tcp BUFFER_SIZE_MB=8192 \
#             LD_LIBRARY_PATH=$BUILD/.../src:$BUILD/.../mooncake-asio \
#             prfaas/m1-tcp-bench/scripts/run_target.sh
#             # note the "listening on host:port" line
#   On dc-b:  MODE=native TARGET_HOST=dc-a:15123 \
#             prfaas/m1-tcp-bench/scripts/run_matrix.sh regional

set -euo pipefail

profile="${1:?usage: run_matrix.sh <profile>}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
m1_root="$(cd "${here}/.." && pwd)"
repo_root="$(cd "${m1_root}/../.." && pwd)"
results_root="${repo_root}/prfaas/results/m1-tcp-bench"
results_csv="${results_root}/${profile}.csv"
mkdir -p "${results_root}"

mode="${MODE:-compose}"

# -----------------------------------------------------------------------------
# Mode-specific setup: produce $RUN_INITIATOR_CMD (a shell command prefix that
# runs run_initiator.sh in the right place) and $TARGET_ADDR.
# -----------------------------------------------------------------------------

declare -a CLEANUP_CMDS=()
trap 'for c in "${CLEANUP_CMDS[@]}"; do eval "$c" || true; done' EXIT

case "$mode" in
  compose)
    COMPOSE="${COMPOSE:-docker compose -f ${m1_root}/docker/compose.yml}"
    target_exec=(${COMPOSE} exec -T dc_a)
    init_exec=(${COMPOSE} exec -T dc_b)

    if [[ "$profile" != "real" ]]; then
      echo "[run_matrix] applying WAN profile=${profile} on dc_b egress"
      "${init_exec[@]}" /work/scripts/apply_wan.sh "${profile}"
      CLEANUP_CMDS+=("${init_exec[*]} bash -lc 'tc qdisc del dev \$(ip -o -4 addr show | awk \"\\\$2!=\\\"lo\\\"{print \\\$2; exit}\") root 2>/dev/null || true'")
    fi

    target_log="${results_root}/${profile}.target.log"
    : > "${target_log}"
    "${target_exec[@]}" bash -lc "/work/scripts/run_target.sh" >"${target_log}" 2>&1 &
    target_local_pid=$!
    # Important: docker exec's local pid does NOT propagate signals into the
    # container. Kill the bench inside the container explicitly on cleanup.
    CLEANUP_CMDS+=("kill ${target_local_pid} 2>/dev/null")
    CLEANUP_CMDS+=("${target_exec[*]} pkill -f 'transfer_engine_(lat_)?bench --mode=target' 2>/dev/null")

    echo "[run_matrix] waiting for target RPC port..."
    for _ in $(seq 1 60); do
      if grep -Eq 'listening on [^ ]+:[0-9]+' "${target_log}"; then break; fi
      sleep 1
    done
    listen_line=$(grep -Eo 'listening on [^ ]+:[0-9]+' "${target_log}" | tail -1 || true)
    if [[ -z "$listen_line" ]]; then
      echo "[run_matrix] target failed to come up; see ${target_log}" >&2
      exit 1
    fi
    target_addr="${listen_line##* }"
    # In compose mode, dc_b reaches dc_a by service name. Port is what target printed.
    target_addr="dc_a:${target_addr##*:}"

    run_initiator_cmd=("${init_exec[@]}" /work/scripts/run_initiator.sh \
                       --csv "/work/results/${profile}.csv")
    ;;

  native)
    target_addr="${TARGET_HOST:?MODE=native requires TARGET_HOST=host:port}"
    run_initiator_cmd=("${here}/run_initiator.sh" --csv "${results_csv}")
    ;;

  *)
    echo "unknown MODE=${mode} (compose|native)" >&2
    exit 2
    ;;
esac

echo "[run_matrix] target=${target_addr}"

# -----------------------------------------------------------------------------
# Sweep
# -----------------------------------------------------------------------------

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
  "${run_initiator_cmd[@]}" \
    --segment-id "${target_addr}" \
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
