#!/usr/bin/env bash
# Stage 0b — WireGuard ablation. One representative M1 cell across the WG
# tunnel IPs, compared to the same cell from Stage 0a. Delta = WG tax.
#
# Pre-req: wireguard_setup.sh has been run on BOTH x_gateway and y, so each
# side has a peer at WG_PEER_IP (defaults: x_gateway=10.42.0.1, y=10.42.0.2).
#
# Role-aware:
#   x_gateway: starts run_target.sh on the WG iface.
#   y:         runs ONE matrix cell (slice=4M, threads=4, conn-pool=on) over WG.
#
# Usage:
#   sudo bash prfaas/m1.5-vllm-baseline/scripts/run_stage_0b.sh

set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

m15_require_env PRFAAS_ROLE
: "${WG_X_GATEWAY_IP:=10.42.0.1}"
: "${WG_Y_IP:=10.42.0.2}"
: "${BENCH_BIN:=lat}"

case "${PRFAAS_ROLE}" in
  x_gateway)
    m15_log "Stage 0b (target on WG) — ensuring tunnel is up"
    sudo bash "${M15_DIR}/scripts/wireguard_setup.sh"
    if ! ip -br a | grep -q "${WG_X_GATEWAY_IP}"; then
      m15_die "expected ${WG_X_GATEWAY_IP} on a wg* interface; check wireguard_setup.sh"
    fi
    MODE=native PROTOCOL=tcp BENCH_BIN="${BENCH_BIN}" \
    BIND_HOST="${WG_X_GATEWAY_IP}" \
      bash "${REPO_ROOT}/prfaas/m1-tcp-bench/scripts/run_target.sh"
    ;;
  y)
    : "${TARGET_RPC_PORT:?set TARGET_RPC_PORT (printed by the x_gateway run_target.sh)}"
    sudo bash "${M15_DIR}/scripts/wireguard_setup.sh"
    out_dir="${REPO_ROOT}/prfaas/results/m1-tcp-bench/cross_dc_xy/wg_ablation"
    mkdir -p "${out_dir}"
    m15_log "Stage 0b (initiator on WG) → ${WG_X_GATEWAY_IP}:${TARGET_RPC_PORT}"
    MODE=native PROTOCOL=tcp BENCH_BIN="${BENCH_BIN}" \
    TARGET_HOST="${WG_X_GATEWAY_IP}" TARGET_RPC_PORT="${TARGET_RPC_PORT}" \
    SLICE_SIZES=4194304 THREADS=4 CONN_POOL=on \
    RESULTS_DIR="${out_dir}" \
      bash "${REPO_ROOT}/prfaas/m1-tcp-bench/scripts/run_matrix.sh"
    m15_log "wg cell done — compare ${out_dir}/results.csv against the same cell"
    m15_log "in the latest cross_dc_xy/<timestamp>/results.csv to compute the WG tax"
    ;;
  x_internal)
    m15_die "Stage 0b runs only on x_gateway and y"
    ;;
  *)
    m15_die "unknown PRFAAS_ROLE=${PRFAAS_ROLE}"
    ;;
esac
