#!/usr/bin/env bash
# Start a vLLM instance in kv_producer (prefill) role.
#
# Required env:
#   MODEL                 HF id or local path
#   TP                    tensor-parallel size
#   PORT                  HTTP port for the vLLM API
#   GPU_IDS               comma-separated, e.g. 0,1,2,3
#   MOONCAKE_CONFIG_PATH  path to mooncake.json
# Optional:
#   MAX_MODEL_LEN         default 32768
#   ROLE                  default kv_producer (overridable, but you should
#                         use start_decoder.sh for kv_consumer)

set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

m15_require_env MODEL TP PORT GPU_IDS MOONCAKE_CONFIG_PATH
: "${ROLE:=kv_producer}"
: "${MAX_MODEL_LEN:=32768}"

# Auto-detect vLLM v0 vs v1 connector name.
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
m15_log "vLLM ${vllm_version}: using ${CONNECTOR} (role=${ROLE})"

m15_kill_tag "vllm_prefiller_${PORT}"

KV_CFG="{\"kv_connector\":\"${CONNECTOR}\",\"kv_role\":\"${ROLE}\"}"

CUDA_VISIBLE_DEVICES="${GPU_IDS}" \
MOONCAKE_CONFIG_PATH="${MOONCAKE_CONFIG_PATH}" \
VLLM_WORKER_MULTIPROC_METHOD=spawn \
"${PRFAAS_VENV}/bin/python" -m vllm.entrypoints.openai.api_server \
  --model "${MODEL}" \
  --tensor-parallel-size "${TP}" \
  --port "${PORT}" \
  --max-model-len "${MAX_MODEL_LEN}" \
  --gpu-memory-utilization 0.85 \
  --no-enable-prefix-caching \
  --kv-transfer-config "${KV_CFG}" \
  --trust-remote-code \
  >"${PRFAAS_LOG_DIR}/prefiller_${PORT}.log" 2>&1 &
m15_track_pid "vllm_prefiller_${PORT}" $!

m15_wait_for_vllm "${PORT}"
m15_log "prefiller :${PORT} ready (pid $(cat "${PRFAAS_PID_DIR}/vllm_prefiller_${PORT}.pid"))"
