#!/usr/bin/env bash
# Stage B — disagg over IB-as-TCP (X1 ↔ X2), three-config Λ_max sweep.
#
# Layout (per PREFLIGHT.md):
#   X1 (x_internal): prefiller (TP=8) for Config P; runs Config H solo for the
#                    "homogeneous decode-only" baseline.
#   X2 (x_gateway):  decoder (TP=8) + proxy + master + etcd. Drives the bench.
#
# CONFIG selects which configuration to run. Run each on its own (the
# benchmark needs the workload's full GPU budget):
#   CONFIG=H  homogeneous, 1× vLLM TP=8 on X1, no Mooncake.
#   CONFIG=N  naive heterogeneous, 4P+4D on X1 alone over loopback Mooncake.
#   CONFIG=P  PrfaaS-style, X1=prefiller TP=8, X2=decoder TP=8, IB-as-TCP.
#
# Required env (sourced from ~/.prfaas_env):
#   PRIMARY_MODEL  PRIMARY_MODEL_TAG
#   X_INTERNAL_INTERNAL_IP  (IB-side IP of X1, reachable from X2)
#   X_GATEWAY_INTERNAL_IP   (IB-side IP of X2, used as master/etcd host)
#
# Optional:
#   WORKLOADS  default "chat_balanced long_context rag_summary code_complete"
#   SSH        default "ssh"  (override if you need -i/-J flags)
#
# Usage (run on X2):
#   CONFIG=H bash prfaas/m1.5-vllm-baseline/scripts/run_stage_b.sh
#   CONFIG=N bash prfaas/m1.5-vllm-baseline/scripts/run_stage_b.sh
#   CONFIG=P bash prfaas/m1.5-vllm-baseline/scripts/run_stage_b.sh

set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

m15_require_env CONFIG PRIMARY_MODEL PRIMARY_MODEL_TAG \
                X_INTERNAL_INTERNAL_IP X_GATEWAY_INTERNAL_IP
: "${WORKLOADS:=chat_balanced long_context rag_summary code_complete}"
: "${SSH:=ssh}"
: "${MODEL:=${PRIMARY_MODEL}}"
: "${MODEL_TAG:=${PRIMARY_MODEL_TAG}}"

if [[ "$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -c "^${X_GATEWAY_INTERNAL_IP}\$")" -eq 0 ]]; then
  m15_log "WARN: this host doesn't appear to own X_GATEWAY_INTERNAL_IP=${X_GATEWAY_INTERNAL_IP};"
  m15_log "      Stage B is intended to run on X2 (the master/decoder host)."
fi

base_results="${M15_RESULTS_DIR}/stageB/${MODEL_TAG}"

run_h() {
  m15_log "Config H — single TP=8 vLLM on X1 (no Mooncake)"
  ${SSH} "${X_INTERNAL_INTERNAL_IP}" "
    set -e
    source ~/.prfaas_env
    MODEL='${MODEL}' TP=8 PORT=8000 GPU_IDS=0,1,2,3,4,5,6,7 NO_MOONCAKE=1 \
      bash ${REPO_ROOT}/prfaas/m1.5-vllm-baseline/scripts/start_decoder.sh
  " &
  remote_pid=$!
  trap '${SSH} "${X_INTERNAL_INTERNAL_IP}" "bash ${REPO_ROOT}/prfaas/m1.5-vllm-baseline/scripts/stop_all.sh"; kill "${remote_pid}" 2>/dev/null || true' EXIT
  wait_url="http://${X_INTERNAL_INTERNAL_IP}:8000/v1/models"
  m15_log "waiting for ${wait_url}"
  until curl -sf "${wait_url}" >/dev/null; do sleep 5; done

  for w in ${WORKLOADS}; do
    WORKLOAD="${w}" PROXY_HOST="${X_INTERNAL_INTERNAL_IP}" PROXY_PORT=8000 \
    MODEL="${MODEL}" \
    RESULTS_DIR="${base_results}/configH" \
      bash "${M15_DIR}/scripts/run_concurrency_sweep.sh"
  done
  ${SSH} "${X_INTERNAL_INTERNAL_IP}" "bash ${REPO_ROOT}/prfaas/m1.5-vllm-baseline/scripts/stop_all.sh"
  trap - EXIT
}

run_n() {
  m15_log "Config N — 4P+4D on X1, Mooncake over loopback"
  ${SSH} "${X_INTERNAL_INTERNAL_IP}" "
    set -e
    source ~/.prfaas_env
    bash ${M15_DIR}/scripts/render_config.sh \
      --template ${M15_DIR}/configs/mooncake.localhost.json.template \
      --out /tmp/mooncake-stageB-N.json
    bash ${M15_DIR}/scripts/start_master.sh
    MOONCAKE_CONFIG_PATH=/tmp/mooncake-stageB-N.json \
    MODEL='${MODEL}' TP=4 ROLE=kv_producer PORT=8100 GPU_IDS=0,1,2,3 \
      bash ${M15_DIR}/scripts/start_prefiller.sh
    MOONCAKE_CONFIG_PATH=/tmp/mooncake-stageB-N.json \
    MODEL='${MODEL}' TP=4 ROLE=kv_consumer PORT=8200 GPU_IDS=4,5,6,7 \
      bash ${M15_DIR}/scripts/start_decoder.sh
    MODEL='${MODEL}' PREFILL=localhost:8100 DECODE=localhost:8200 PROXY_PORT=8000 \
      bash ${M15_DIR}/scripts/start_proxy.sh
  "
  trap '${SSH} "${X_INTERNAL_INTERNAL_IP}" "bash ${M15_DIR}/scripts/stop_all.sh"' EXIT

  for w in ${WORKLOADS}; do
    WORKLOAD="${w}" PROXY_HOST="${X_INTERNAL_INTERNAL_IP}" PROXY_PORT=8000 \
    MODEL="${MODEL}" \
    RESULTS_DIR="${base_results}/configN" \
      bash "${M15_DIR}/scripts/run_concurrency_sweep.sh"
  done
  ${SSH} "${X_INTERNAL_INTERNAL_IP}" "bash ${M15_DIR}/scripts/stop_all.sh"
  trap - EXIT
}

run_p() {
  m15_log "Config P — X1 prefill TP=8, X2 decode TP=8, IB-as-TCP"
  bash "${M15_DIR}/scripts/render_config.sh" \
    --template "${M15_DIR}/configs/mooncake.x_internal.json.template" \
    --out /tmp/mooncake-stageB-P.json
  bash "${M15_DIR}/scripts/start_master.sh"

  # Push the same rendered config to X1 so prefiller and decoder agree.
  scp /tmp/mooncake-stageB-P.json "${X_INTERNAL_INTERNAL_IP}:/tmp/mooncake-stageB-P.json"
  ${SSH} "${X_INTERNAL_INTERNAL_IP}" "
    set -e
    source ~/.prfaas_env
    MOONCAKE_CONFIG_PATH=/tmp/mooncake-stageB-P.json \
    MODEL='${MODEL}' TP=8 ROLE=kv_producer PORT=8100 GPU_IDS=0,1,2,3,4,5,6,7 \
      bash ${M15_DIR}/scripts/start_prefiller.sh
  "
  MOONCAKE_CONFIG_PATH=/tmp/mooncake-stageB-P.json \
  MODEL="${MODEL}" TP=8 ROLE=kv_consumer PORT=8200 GPU_IDS=0,1,2,3,4,5,6,7 \
    bash "${M15_DIR}/scripts/start_decoder.sh"
  PREFILL="${X_INTERNAL_INTERNAL_IP}:8100" DECODE=localhost:8200 PROXY_PORT=8000 \
  MODEL="${MODEL}" \
    bash "${M15_DIR}/scripts/start_proxy.sh"

  trap 'bash "${M15_DIR}/scripts/stop_all.sh"; ${SSH} "${X_INTERNAL_INTERNAL_IP}" "bash ${M15_DIR}/scripts/stop_all.sh"' EXIT

  for w in ${WORKLOADS}; do
    WORKLOAD="${w}" PROXY_PORT=8000 PROXY_HOST=127.0.0.1 \
    MODEL="${MODEL}" \
    RESULTS_DIR="${base_results}/configP" \
      bash "${M15_DIR}/scripts/run_concurrency_sweep.sh"
  done

  bash "${M15_DIR}/scripts/stop_all.sh"
  ${SSH} "${X_INTERNAL_INTERNAL_IP}" "bash ${M15_DIR}/scripts/stop_all.sh"
  trap - EXIT
}

case "${CONFIG}" in
  H|h) run_h ;;
  N|n) run_n ;;
  P|p) run_p ;;
  *)   m15_die "CONFIG must be H, N, or P (got '${CONFIG}')" ;;
esac

m15_log "summarizing stageB → ${base_results}/SUMMARY.md"
python3 "${M15_DIR}/scripts/extract_lambda_max.py" \
  --stage stageB --results-dir "${base_results}" \
  --out "${base_results}/SUMMARY.md"
m15_log "Stage B / Config ${CONFIG} done"
