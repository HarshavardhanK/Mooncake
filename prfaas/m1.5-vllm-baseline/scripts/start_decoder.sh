#!/usr/bin/env bash
# Start a vLLM instance in kv_consumer (decode) role.
# Set NO_MOONCAKE=1 to start a vanilla vLLM (no Mooncake, no kv-transfer-config)
# — used for the Config H homogeneous baseline.
#
# Required env:
#   MODEL TP PORT GPU_IDS
#   MOONCAKE_CONFIG_PATH (unless NO_MOONCAKE=1)
# Optional:
#   MAX_MODEL_LEN         default 32768
#   ROLE                  default kv_consumer
#   NO_MOONCAKE           default 0

set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

m15_require_env MODEL TP PORT GPU_IDS
: "${ROLE:=kv_consumer}"
: "${MAX_MODEL_LEN:=32768}"
: "${NO_MOONCAKE:=0}"

if [[ "${NO_MOONCAKE}" -eq 0 ]]; then
  m15_require_env MOONCAKE_CONFIG_PATH
fi

vllm_version="$("${PRFAAS_VENV}/bin/python" -c 'import vllm; print(vllm.__version__)' 2>/dev/null || echo 0.15.0)"
if "${PRFAAS_VENV}/bin/python" -c "
import sys
from packaging import version
sys.exit(0 if version.parse('${vllm_version}') >= version.parse('0.16.0') else 1)
" 2>/dev/null; then
  CONNECTOR="MooncakeConnector"
  export VLLM_USE_V1=1
else
  CONNECTOR="MooncakeStoreConnector"
  export VLLM_USE_V1=0
fi

m15_kill_tag "vllm_decoder_${PORT}"

EXTRA_ARGS=()
if [[ "${NO_MOONCAKE}" -eq 0 ]]; then
  KV_CFG="{\"kv_connector\":\"${CONNECTOR}\",\"kv_role\":\"${ROLE}\"}"
  EXTRA_ARGS+=( --kv-transfer-config "${KV_CFG}" --no-enable-prefix-caching )
  export MOONCAKE_CONFIG_PATH
  m15_log "vLLM ${vllm_version}: using ${CONNECTOR} (role=${ROLE})"
else
  m15_log "vLLM ${vllm_version}: NO_MOONCAKE=1 (Config H baseline)"
fi

CUDA_VISIBLE_DEVICES="${GPU_IDS}" \
VLLM_WORKER_MULTIPROC_METHOD=spawn \
"${PRFAAS_VENV}/bin/python" -m vllm.entrypoints.openai.api_server \
  --model "${MODEL}" \
  --tensor-parallel-size "${TP}" \
  --port "${PORT}" \
  --max-model-len "${MAX_MODEL_LEN}" \
  --gpu-memory-utilization 0.85 \
  --trust-remote-code \
  "${EXTRA_ARGS[@]}" \
  >"${PRFAAS_LOG_DIR}/decoder_${PORT}.log" 2>&1 &
m15_track_pid "vllm_decoder_${PORT}" $!

m15_wait_for_vllm "${PORT}"
m15_log "decoder :${PORT} ready (pid $(cat "${PRFAAS_PID_DIR}/vllm_decoder_${PORT}.pid"))"
