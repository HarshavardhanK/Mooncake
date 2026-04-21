#!/usr/bin/env bash
# Stage 0a — characterize the X-gateway ↔ Y wire with the M1 transport bench.
#
# Role-aware (uses PRFAAS_ROLE from ~/.prfaas_env):
#   x_gateway: starts run_target.sh (idempotent), prints the chosen RPC port.
#   y:         requires TARGET_RPC_PORT in env or --rpc-port; runs the M1 matrix
#              against $X_GATEWAY_PUBLIC_IP and writes results under
#              prfaas/results/m1-tcp-bench/cross_dc_xy/<timestamp>/.
#   x_internal: rejected (no public-side bench from the IB-only node).
#
# Usage (X-gateway):
#   sudo bash prfaas/m1.5-vllm-baseline/scripts/run_stage_0a.sh
#
# Usage (Y), repeat at 09:00, 15:00, 23:00 local:
#   TARGET_RPC_PORT=<from gateway> \
#     bash prfaas/m1.5-vllm-baseline/scripts/run_stage_0a.sh
#
# All knobs (THREADS, SLICE_SIZES, CONN_POOL, BENCH_BIN) flow straight through
# to prfaas/m1-tcp-bench/scripts/run_matrix.sh — see that script for the matrix.

set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

m15_require_env PRFAAS_ROLE X_GATEWAY_PUBLIC_IP Y_PUBLIC_IP
: "${BENCH_BIN:=lat}"
: "${PROTOCOL:=tcp}"
: "${MODE:=native}"

case "${PRFAAS_ROLE}" in
  x_gateway)
    m15_log "Stage 0a (target side) on x_gateway"
    if ! command -v sudo >/dev/null; then m15_die "sudo required"; fi
    m15_log "host_tune.sh + firewall_setup.sh stage0 (idempotent)"
    sudo bash "${REPO_ROOT}/prfaas/m1-tcp-bench/scripts/host_tune.sh"
    sudo PRFAAS_ROLE=x_gateway X_GATEWAY_PUBLIC_IP="${X_GATEWAY_PUBLIC_IP}" \
         Y_PUBLIC_IP="${Y_PUBLIC_IP}" \
         bash "${M15_DIR}/scripts/firewall_setup.sh" stage0
    m15_log "starting transfer_engine_${BENCH_BIN}_bench in target mode"
    MODE="${MODE}" PROTOCOL="${PROTOCOL}" BENCH_BIN="${BENCH_BIN}" \
      bash "${REPO_ROOT}/prfaas/m1-tcp-bench/scripts/run_target.sh"
    ;;
  y)
    m15_require_env X_GATEWAY_PUBLIC_IP
    : "${TARGET_RPC_PORT:?set TARGET_RPC_PORT (printed by the x_gateway run_target.sh)}"
    m15_log "Stage 0a (initiator) on y → ${X_GATEWAY_PUBLIC_IP}:${TARGET_RPC_PORT}"
    sudo bash "${REPO_ROOT}/prfaas/m1-tcp-bench/scripts/host_tune.sh"
    sudo PRFAAS_ROLE=y X_GATEWAY_PUBLIC_IP="${X_GATEWAY_PUBLIC_IP}" \
         Y_PUBLIC_IP="${Y_PUBLIC_IP}" \
         bash "${M15_DIR}/scripts/firewall_setup.sh" stage0
    local_ts="$(date +%Y%m%d-%H%M)"
    out_dir="${REPO_ROOT}/prfaas/results/m1-tcp-bench/cross_dc_xy/${local_ts}"
    mkdir -p "${out_dir}"
    m15_log "writing results to ${out_dir}"
    MODE="${MODE}" PROTOCOL="${PROTOCOL}" BENCH_BIN="${BENCH_BIN}" \
    TARGET_HOST="${X_GATEWAY_PUBLIC_IP}" \
    TARGET_RPC_PORT="${TARGET_RPC_PORT}" \
    RESULTS_DIR="${out_dir}" \
      bash "${REPO_ROOT}/prfaas/m1-tcp-bench/scripts/run_matrix.sh"
    m15_log "Stage 0a cell done — ${out_dir}/results.csv"
    m15_log "after ≥3 time-of-day repeats, decide model:"
    cat <<EOF
  python3 ${M15_DIR}/scripts/extract_lambda_max.py --decide-model \\
    --stage0-results ${REPO_ROOT}/prfaas/results/m1-tcp-bench/cross_dc_xy/ \\
    --out ${REPO_ROOT}/prfaas/results/m1.5-vllm-baseline/stage0a/MODEL_DECISION.md
EOF
    ;;
  x_internal)
    m15_die "Stage 0a should not run on x_internal (no public-internet path)"
    ;;
  *)
    m15_die "unknown PRFAAS_ROLE=${PRFAAS_ROLE}; expected x_gateway|y"
    ;;
esac
