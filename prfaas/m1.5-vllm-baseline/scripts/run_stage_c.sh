#!/usr/bin/env bash
# Stage C — Stage B Config P with emulated WAN profiles applied via tc netem
# on the IB-bonded Ethernet iface (or whatever transport iface Mooncake uses
# in Stage B).
#
# Configs H and N do NOT need to be re-run for Stage C — they are unaffected
# by the cross-DC WAN. We only re-run Config P per profile.
#
# Required env (sourced from ~/.prfaas_env):
#   PRIMARY_MODEL  PRIMARY_MODEL_TAG
#   X_INTERNAL_INTERNAL_IP  X_GATEWAY_INTERNAL_IP
#   IB_IFACE       network iface to apply netem on (e.g. ibp0, bond0)
#
# Optional:
#   WAN_PROFILES   space-separated list, default "metro regional continental"
#   WORKLOADS      default same as Stage B
#   SSH            default "ssh"
#
# Usage (run on X2):
#   IB_IFACE=bond0 bash prfaas/m1.5-vllm-baseline/scripts/run_stage_c.sh

set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

m15_require_env PRIMARY_MODEL PRIMARY_MODEL_TAG \
                X_INTERNAL_INTERNAL_IP X_GATEWAY_INTERNAL_IP IB_IFACE
: "${WAN_PROFILES:=metro regional continental}"
: "${WORKLOADS:=chat_balanced long_context rag_summary code_complete}"
: "${SSH:=ssh}"

apply_wan="${REPO_ROOT}/prfaas/m1-tcp-bench/scripts/apply_wan.sh"
[[ -x "${apply_wan}" ]] || m15_die "missing ${apply_wan}"

clear_wan() {
  m15_log "clearing netem on ${IB_IFACE} (both sides)"
  sudo bash "${apply_wan}" clear "${IB_IFACE}" || true
  ${SSH} "${X_INTERNAL_INTERNAL_IP}" "sudo bash ${apply_wan} clear ${IB_IFACE}" || true
}
trap clear_wan EXIT

base_results="${M15_DIR}/results/stageC/${PRIMARY_MODEL_TAG}"

for profile in ${WAN_PROFILES}; do
  m15_log "applying WAN profile '${profile}' on ${IB_IFACE} (both sides)"
  sudo bash "${apply_wan}" "${profile}" "${IB_IFACE}"
  ${SSH} "${X_INTERNAL_INTERNAL_IP}" "sudo bash ${apply_wan} ${profile} ${IB_IFACE}"

  m15_log "→ Config P sweep under '${profile}' (re-using existing brought-up stack)"
  m15_log "  if you tore down between profiles, re-run: CONFIG=P bash run_stage_b.sh first"

  for w in ${WORKLOADS}; do
    WORKLOAD="${w}" PROXY_PORT=8000 WAN_PROFILE="${profile}" \
    MODEL="${PRIMARY_MODEL}" \
    RESULTS_DIR="${base_results}/${profile}" \
      bash "${M15_DIR}/scripts/run_concurrency_sweep.sh"
  done

  m15_log "clearing '${profile}' before next profile"
  sudo bash "${apply_wan}" clear "${IB_IFACE}"
  ${SSH} "${X_INTERNAL_INTERNAL_IP}" "sudo bash ${apply_wan} clear ${IB_IFACE}"
done

m15_log "summarizing stageC"
python3 "${M15_DIR}/scripts/extract_lambda_max.py" \
  --stage stageC --results-dir "${base_results}" \
  --out "${base_results}/SUMMARY.md"
m15_log "Stage C done — see ${base_results}/SUMMARY.md"
