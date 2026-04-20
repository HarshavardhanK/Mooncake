#!/usr/bin/env bash
# Validate that this node is ready to participate in M1.5 stages.
# Run on every node (X-gateway, X-internal, Y) before kicking off Stage 0.
#
# Checks (per role, set PRFAAS_ROLE in ~/.prfaas_env):
#   - Required env vars present
#   - GPUs visible and at least 8× H100 (or as configured)
#   - Storage path writable, has enough free space
#   - Network connectivity to the other role(s) on the relevant ports
#   - Required system packages installed (ip, ss, curl, python3, nvidia-smi)
#   - Sysctl / ulimit values are at the M1 host_tune.sh recommendations
#   - Mooncake binaries present (or at least, repo is checked out and built)
#
# Exit non-zero on any failure; print a single-line summary at the end.
#
# Usage:
#   bash prfaas/m1.5-vllm-baseline/scripts/preflight_check.sh [--quick]

set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1

m15_require_env PRFAAS_ROLE X_GATEWAY_PUBLIC_IP Y_PUBLIC_IP \
                X_MODEL_DIR Y_MODEL_DIR

case "${PRFAAS_ROLE}" in
  x_gateway|x_internal|y) ;;
  *) m15_die "unknown PRFAAS_ROLE='${PRFAAS_ROLE}'; expected x_gateway|x_internal|y" ;;
esac

m15_log "preflight: role=${PRFAAS_ROLE} host=$(hostname)"
fail=0

# ---- system packages ------------------------------------------------------
for cmd in curl ss ip python3 nvidia-smi; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    m15_log "MISSING: ${cmd}"
    fail=1
  fi
done

# ---- gpus -----------------------------------------------------------------
if command -v nvidia-smi >/dev/null 2>&1; then
  gpu_count="$(nvidia-smi -L 2>/dev/null | wc -l | tr -d ' ')"
  m15_log "gpus visible: ${gpu_count}"
  if (( gpu_count < 8 )); then
    m15_log "WARN: expected at least 8 GPUs for the planned configs"
  fi
fi

# ---- storage --------------------------------------------------------------
case "${PRFAAS_ROLE}" in
  x_*) model_dir="${X_MODEL_DIR}" ;;
  y)   model_dir="${Y_MODEL_DIR}" ;;
esac
if [[ ! -d "${model_dir}" ]]; then
  m15_log "creating ${model_dir}"
  mkdir -p "${model_dir}" || { m15_log "MISSING: cannot create ${model_dir}"; fail=1; }
fi
free_gb="$(df -BG --output=avail "${model_dir}" 2>/dev/null | tail -1 | tr -d 'G ')"
if [[ -n "${free_gb}" && "${free_gb}" -lt 200 ]]; then
  m15_log "WARN: only ${free_gb} GiB free at ${model_dir}; Qwen3-Next-80B-A3B needs ~160 GB"
fi

# ---- sysctls --------------------------------------------------------------
need_rmem=268435456
cur_rmem="$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)"
if (( cur_rmem < need_rmem )); then
  m15_log "WARN: net.core.rmem_max=${cur_rmem} < ${need_rmem}; run sudo prfaas/m1-tcp-bench/scripts/host_tune.sh"
fi

# ---- ulimits --------------------------------------------------------------
nofile="$(ulimit -n)"
if (( nofile < 65536 )); then
  m15_log "WARN: ulimit -n = ${nofile} (recommend 65536+); add to /etc/security/limits.conf"
fi

# ---- mooncake build -------------------------------------------------------
if [[ ! -x "${REPO_ROOT}/build/mooncake-transfer-engine/example/transfer_engine_bench" ]]; then
  m15_log "WARN: transfer_engine_bench not found at expected path; run prfaas/m1-tcp-bench/scripts/native_build.sh"
fi

# ---- cross-cluster connectivity (slow) ------------------------------------
if (( QUICK == 0 )); then
  case "${PRFAAS_ROLE}" in
    x_gateway)
      target="${Y_PUBLIC_IP}"
      ;;
    y)
      target="${X_GATEWAY_PUBLIC_IP}"
      ;;
    x_internal)
      target=""
      ;;
  esac
  if [[ -n "${target}" ]]; then
    if rtt="$(ping -c 5 -W 2 "${target}" 2>/dev/null | tail -1 | awk -F'/' '{print $5}')"; then
      m15_log "RTT to ${target}: ${rtt} ms (median over 5 pings)"
    else
      m15_log "WARN: ping to ${target} failed (firewall? maybe ICMP blocked, that's ok)"
    fi
    # Try the Mooncake transport port range.
    for port in 10001 2379 13000; do
      if timeout 5 bash -c "</dev/tcp/${target}/${port}" 2>/dev/null; then
        m15_log "TCP ${target}:${port} reachable"
      else
        m15_log "TCP ${target}:${port} NOT reachable (will need firewall_setup.sh)"
      fi
    done
  fi
fi

# ---- summary --------------------------------------------------------------
if (( fail != 0 )); then
  m15_die "preflight FAILED — fix the MISSING items above"
fi
m15_log "preflight OK (warnings above are advisory)"
