#!/usr/bin/env bash
# Stage A — single-machine 1P1D smoke test on cluster Y.
#
# Brings up 1 prefiller (4 GPUs) + 1 decoder (4 GPUs) + proxy on localhost,
# all using vLLM's v1 MooncakeConnector (no master, no etcd; the connector
# is point-to-point with a bootstrap-port handshake).
#
# Two-phase smoke:
#   Phase 1 — vanilla vLLM serving the same model on 4 GPUs (no connector).
#             Catches model/vLLM compatibility issues before we add the
#             connector to the picture.
#   Phase 2 — full 1P1D with MooncakeConnector + round-robin proxy, plus
#             one concurrency=16 cell to record TTFT/TPOT for Y-on-self.
#
# Pre-req: bash node_setup.sh smoke   (or the manual install in
#          STAGE_A_PLAN.md §1-3 if you skipped node_setup).
#
# Usage:
#   bash prfaas/m1.5-vllm-baseline/scripts/run_stage_a.sh

set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

m15_require_env PRFAAS_VENV
[[ -d "${PRFAAS_VENV}" ]] || m15_die "venv missing at ${PRFAAS_VENV}; see STAGE_A_PLAN.md §1"

MODEL="${MODEL:-${SMOKE_MODEL}}"
# Resolve to local path if available — vLLM is happy with either, but
# loading from local saves the second-pass HF check.
MODEL_LOCAL_DIR=""
if [[ "${MODEL}" == */* && -d "${HOME}/models/$(echo "${MODEL}" | tr '/' '_')" ]]; then
  MODEL_LOCAL_DIR="${HOME}/models/$(echo "${MODEL}" | tr '/' '_')"
  m15_log "found local weights at ${MODEL_LOCAL_DIR}, using that"
  MODEL_PATH="${MODEL_LOCAL_DIR}"
else
  MODEL_PATH="${MODEL}"
fi
MODEL_TAG="${MODEL//\//_}"
SERVED_NAME="${SERVED_NAME:-${MODEL_TAG##*nvidia_NVIDIA-}}"
SERVED_NAME="${SERVED_NAME,,}"
RESULTS_DIR="${M15_DIR}/results/stageA/${MODEL_TAG}"
mkdir -p "${RESULTS_DIR}"

m15_log "Stage A: 1P1D smoke on ${MODEL} (4P+4D on localhost)"
m15_log "  served-model-name=${SERVED_NAME}"
m15_log "  results=${RESULTS_DIR}"

# ------------------------------------------------------------------------
# Phase 1 — vanilla vLLM smoke (NO connector), 4 GPUs.
# ------------------------------------------------------------------------
if [[ "${SKIP_VANILLA_SMOKE:-0}" != "1" ]]; then
  m15_log "Phase 1: vanilla vLLM smoke (no Mooncake)"

  m15_kill_tag "vllm_vanilla_8000"

  CUDA_VISIBLE_DEVICES=0,1,2,3 \
  VLLM_WORKER_MULTIPROC_METHOD=spawn \
  "${PRFAAS_VENV}/bin/python" -m vllm.entrypoints.openai.api_server \
    --model "${MODEL_PATH}" \
    --served-model-name "${SERVED_NAME}" \
    --port 8000 \
    --tensor-parallel-size 4 \
    --max-model-len 32768 \
    --gpu-memory-utilization 0.85 \
    --trust-remote-code \
    >"${PRFAAS_LOG_DIR}/vllm_vanilla.log" 2>&1 &
  m15_track_pid "vllm_vanilla_8000" $!

  m15_wait_for_vllm 8000 600

  m15_log "Phase 1: smoke curl..."
  resp="$(curl -sf -X POST http://localhost:8000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model":"'"${SERVED_NAME}"'","messages":[{"role":"user","content":"What is 2+2? Answer in one word."}],"max_tokens":16,"temperature":0}')" \
    || m15_die "Phase 1 vanilla smoke failed; see ${PRFAAS_LOG_DIR}/vllm_vanilla.log"
  echo "${resp}" | head -c 500; echo
  m15_log "Phase 1 OK — vLLM can serve ${MODEL}. Tearing down vanilla."
  m15_kill_tag "vllm_vanilla_8000"
  sleep 5  # let GPUs free
else
  m15_log "Phase 1 SKIPPED (SKIP_VANILLA_SMOKE=1)"
fi

# ------------------------------------------------------------------------
# Phase 2 — 1P1D with MooncakeConnector + proxy.
# ------------------------------------------------------------------------
m15_log "Phase 2: 1P1D with MooncakeConnector"

bash "${M15_DIR}/scripts/render_config.sh" \
  --template "${M15_DIR}/configs/mooncake.localhost.json.template" \
  --out /tmp/mooncake-stageA.json

# NOTE: vLLM v1 MooncakeConnector is point-to-point with a bootstrap port.
# No mooncake_master, no etcd. start_master.sh is intentionally NOT called.

MOONCAKE_CONFIG_PATH=/tmp/mooncake-stageA.json \
MODEL="${MODEL_PATH}" TP=4 ROLE=kv_producer PORT=8010 GPU_IDS=0,1,2,3 \
VLLM_MOONCAKE_BOOTSTRAP_PORT=8998 \
  bash "${M15_DIR}/scripts/start_prefiller.sh"

MOONCAKE_CONFIG_PATH=/tmp/mooncake-stageA.json \
MODEL="${MODEL_PATH}" TP=4 ROLE=kv_consumer PORT=8020 GPU_IDS=4,5,6,7 \
  bash "${M15_DIR}/scripts/start_decoder.sh"

MODEL="${SERVED_NAME}" PREFILL=localhost:8010 DECODE=localhost:8020 PROXY_PORT=8000 \
  bash "${M15_DIR}/scripts/start_proxy.sh"

m15_log "Phase 2 smoke curl through proxy..."
resp="$(curl -sf -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"'"${SERVED_NAME}"'","messages":[{"role":"user","content":"In one sentence, what is a transformer?"}],"max_tokens":64,"temperature":0}')" \
  || m15_die "Phase 2 proxy smoke failed; see ${PRFAAS_LOG_DIR}/proxy_8000.log"
echo "${resp}" | head -c 1000; echo

# Best-effort search for KV-transfer evidence in the prefiller log.
if grep -qiE 'mooncake|kv.transfer|kv_transfer|kv producer' "${PRFAAS_LOG_DIR}/prefiller_8010.log"; then
  m15_log "Phase 2 OK — MooncakeConnector is wired into the prefiller log"
else
  m15_log "WARN: no mooncake/kv-transfer log lines in prefiller_8010.log — connector may be a no-op. Continuing anyway."
fi

# ------------------------------------------------------------------------
# Phase 3 — one concurrency cell, informational only (NOT Lambda_max).
# ------------------------------------------------------------------------
m15_log "Phase 3: chat_balanced concurrency=16 (informational)"
WORKLOAD=chat_balanced \
CONCURRENCIES=16 \
NUM_FOLDS=10 \
PROXY_PORT=8000 \
MODEL="${SERVED_NAME}" \
RESULTS_DIR="${RESULTS_DIR}" \
  bash "${M15_DIR}/scripts/run_concurrency_sweep.sh"

m15_log "Stage A green. Tearing down."
bash "${M15_DIR}/scripts/stop_all.sh"
m15_log "Stage A done — see ${RESULTS_DIR}"
