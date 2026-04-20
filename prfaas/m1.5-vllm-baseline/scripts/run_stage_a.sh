#!/usr/bin/env bash
# Stage A — single-machine 1P1D smoke test on cluster Y.
#
# Brings up master + 1 prefiller (4 GPUs) + 1 decoder (4 GPUs) + proxy,
# all on localhost, runs a chat_balanced concurrency=16 cell, and tears
# down. Exits non-zero on any failure.
#
# Pre-req: bash node_setup.sh smoke   (installs vLLM, downloads
# Nemotron-Nano-9B-v2 to $Y_MODEL_DIR).
#
# Usage:
#   bash prfaas/m1.5-vllm-baseline/scripts/run_stage_a.sh

set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Stage A is intentionally smoke-only — pin to the smaller model for fast iteration.
MODEL="${SMOKE_MODEL}"
MODEL_TAG="${MODEL//\//_}"
RESULTS_DIR="${M15_DIR}/results/stageA/${MODEL_TAG}"
mkdir -p "${RESULTS_DIR}"

m15_log "Stage A: 1P1D smoke on ${MODEL} (4P+4D on localhost)"

bash "${M15_DIR}/scripts/render_config.sh" \
  --template "${M15_DIR}/configs/mooncake.localhost.json.template" \
  --out /tmp/mooncake-stageA.json

bash "${M15_DIR}/scripts/start_master.sh"

MOONCAKE_CONFIG_PATH=/tmp/mooncake-stageA.json \
MODEL="${MODEL}" TP=4 ROLE=kv_producer PORT=8100 GPU_IDS=0,1,2,3 \
  bash "${M15_DIR}/scripts/start_prefiller.sh"

MOONCAKE_CONFIG_PATH=/tmp/mooncake-stageA.json \
MODEL="${MODEL}" TP=4 ROLE=kv_consumer PORT=8200 GPU_IDS=4,5,6,7 \
  bash "${M15_DIR}/scripts/start_decoder.sh"

MODEL="${MODEL}" PREFILL=localhost:8100 DECODE=localhost:8200 PROXY_PORT=8000 \
  bash "${M15_DIR}/scripts/start_proxy.sh"

# Smoke curl
m15_log "smoke curl..."
resp="$(curl -sf -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"'"${MODEL}"'","messages":[{"role":"user","content":"What is 2+2? Answer in one word."}],"max_tokens":16,"temperature":0}')" \
  || m15_die "smoke curl failed; see proxy log"
echo "${resp}" | head -c 500
echo

# One-cell benchmark — small concurrency, short workload.
m15_log "benchmark: chat_balanced concurrency=16"
WORKLOAD=chat_balanced \
CONCURRENCIES=16 \
NUM_FOLDS=10 \
PROXY_PORT=8000 \
MODEL="${MODEL}" \
RESULTS_DIR="${RESULTS_DIR}" \
  bash "${M15_DIR}/scripts/run_concurrency_sweep.sh"

m15_log "Stage A green. Tearing down."
bash "${M15_DIR}/scripts/stop_all.sh"
m15_log "Stage A done — see ${RESULTS_DIR}"
