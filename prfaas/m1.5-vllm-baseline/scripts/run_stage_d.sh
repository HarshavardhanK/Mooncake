#!/usr/bin/env bash
# Stage D — real cross-DC. X-gateway hosts master + prefiller; Y hosts decoder
# + proxy. Bench is run from Y.
#
# Role-aware (uses PRFAAS_ROLE from ~/.prfaas_env):
#   x_gateway: stand up master + prefiller, bound to X_GATEWAY_PUBLIC_IP.
#   y:         stand up decoder + proxy (with PREFILL=X_GATEWAY_PUBLIC_IP:8100)
#              and drive the bench. Optionally, when CONFIG=H, just bring up a
#              single TP=8 vLLM on Y and skip Mooncake entirely.
#
# CONFIG selects which Stage D scenario to run:
#   CONFIG=P  (default) PrfaaS-style cross-DC.
#   CONFIG=H  homogeneous baseline on Y only (run on y; x_gateway is idle).
#
# Required env (sourced from ~/.prfaas_env):
#   PRIMARY_MODEL  PRIMARY_MODEL_TAG  PRFAAS_ROLE
#   X_GATEWAY_PUBLIC_IP   Y_PUBLIC_IP
#
# Optional:
#   WORKLOADS  default "chat_balanced long_context rag_summary code_complete"
#   TIME_TAG   subdirectory under results/stageD/<model>/configP/, default
#              $(date +%H00) so a single bench run lands under e.g. 0900/.
#
# Usage (each side, in its own ssh session):
#   sudo bash prfaas/m1.5-vllm-baseline/scripts/run_stage_d.sh
#
# Run the y side three times across the day (e.g. 09:00, 15:00, 23:00) to
# capture time-of-day variance, per EXPERIMENT_PLAN §5.4.

set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

m15_require_env PRFAAS_ROLE PRIMARY_MODEL PRIMARY_MODEL_TAG \
                X_GATEWAY_PUBLIC_IP Y_PUBLIC_IP
: "${CONFIG:=P}"
: "${WORKLOADS:=chat_balanced long_context rag_summary code_complete}"
: "${TIME_TAG:=$(date +%H00)}"
: "${MODEL:=${PRIMARY_MODEL}}"
: "${MODEL_TAG:=${PRIMARY_MODEL_TAG}}"

base_results="${M15_DIR}/results/stageD/${MODEL_TAG}"

case "${PRFAAS_ROLE}:${CONFIG^^}" in
  x_gateway:P)
    m15_log "Stage D / x_gateway / Config P — master + prefiller"
    sudo PRFAAS_ROLE=x_gateway X_GATEWAY_PUBLIC_IP="${X_GATEWAY_PUBLIC_IP}" \
         Y_PUBLIC_IP="${Y_PUBLIC_IP}" \
         bash "${M15_DIR}/scripts/firewall_setup.sh" stageD
    bash "${M15_DIR}/scripts/render_config.sh" \
      --template "${M15_DIR}/configs/mooncake.x_gateway.json.template" \
      --out /tmp/mooncake-stageD.json
    bash "${M15_DIR}/scripts/start_master.sh"
    MOONCAKE_CONFIG_PATH=/tmp/mooncake-stageD.json \
    MODEL="${MODEL}" TP=8 ROLE=kv_producer PORT=8100 GPU_IDS=0,1,2,3,4,5,6,7 \
      bash "${M15_DIR}/scripts/start_prefiller.sh"
    m15_log "x_gateway ready. Bench is driven from Y; this side stays up."
    m15_log "to tear down: bash ${M15_DIR}/scripts/stop_all.sh"
    ;;
  y:P)
    m15_log "Stage D / y / Config P — decoder + proxy + bench"
    sudo PRFAAS_ROLE=y X_GATEWAY_PUBLIC_IP="${X_GATEWAY_PUBLIC_IP}" \
         Y_PUBLIC_IP="${Y_PUBLIC_IP}" \
         bash "${M15_DIR}/scripts/firewall_setup.sh" stageD
    bash "${M15_DIR}/scripts/render_config.sh" \
      --template "${M15_DIR}/configs/mooncake.y.json.template" \
      --out /tmp/mooncake-stageD.json
    MOONCAKE_CONFIG_PATH=/tmp/mooncake-stageD.json \
    MODEL="${MODEL}" TP=8 ROLE=kv_consumer PORT=8200 GPU_IDS=0,1,2,3,4,5,6,7 \
      bash "${M15_DIR}/scripts/start_decoder.sh"
    PREFILL="${X_GATEWAY_PUBLIC_IP}:8100" DECODE=localhost:8200 PROXY_PORT=8000 \
    MODEL="${MODEL}" \
      bash "${M15_DIR}/scripts/start_proxy.sh"

    trap 'bash "${M15_DIR}/scripts/stop_all.sh"' EXIT
    for w in ${WORKLOADS}; do
      WORKLOAD="${w}" PROXY_PORT=8000 PROXY_HOST=127.0.0.1 \
      MODEL="${MODEL}" \
      RESULTS_DIR="${base_results}/configP/${TIME_TAG}" \
        bash "${M15_DIR}/scripts/run_concurrency_sweep.sh"
    done
    bash "${M15_DIR}/scripts/stop_all.sh"
    trap - EXIT
    ;;
  y:H)
    m15_log "Stage D / y / Config H — single TP=8 vLLM on Y, no Mooncake"
    MODEL="${MODEL}" TP=8 PORT=8000 GPU_IDS=0,1,2,3,4,5,6,7 NO_MOONCAKE=1 \
      bash "${M15_DIR}/scripts/start_decoder.sh"
    trap 'bash "${M15_DIR}/scripts/stop_all.sh"' EXIT
    for w in ${WORKLOADS}; do
      WORKLOAD="${w}" PROXY_PORT=8000 PROXY_HOST=127.0.0.1 \
      MODEL="${MODEL}" \
      RESULTS_DIR="${base_results}/configH" \
        bash "${M15_DIR}/scripts/run_concurrency_sweep.sh"
    done
    bash "${M15_DIR}/scripts/stop_all.sh"
    trap - EXIT
    ;;
  x_gateway:H)
    m15_log "Stage D / x_gateway / Config H — nothing to do here (Config H runs on Y)."
    exit 0
    ;;
  x_internal:*)
    m15_die "Stage D should not be driven from x_internal; it has no public path"
    ;;
  *)
    m15_die "unsupported PRFAAS_ROLE=${PRFAAS_ROLE} CONFIG=${CONFIG}"
    ;;
esac

if [[ "${PRFAAS_ROLE}" == "y" ]]; then
  m15_log "summarizing stageD/${MODEL_TAG}"
  python3 "${M15_DIR}/scripts/extract_lambda_max.py" \
    --stage stageD --results-dir "${base_results}" \
    --out "${base_results}/SUMMARY.md"
  m15_log "Stage D / Config ${CONFIG} done — see ${base_results}/SUMMARY.md"
fi
