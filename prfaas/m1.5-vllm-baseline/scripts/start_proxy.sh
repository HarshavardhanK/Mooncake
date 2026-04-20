#!/usr/bin/env bash
# Start the round-robin disagg proxy from benchmarks/xypd_benchmarks/proxy_demo.py.
# Required env:
#   PREFILL       comma-separated host:port list
#   DECODE        comma-separated host:port list
#   PROXY_PORT    HTTP port to listen on (default 8000)
# Optional:
#   MODEL         (defaults to whatever vLLM reports on /v1/models;
#                  proxy_demo.py requires this match)

set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

m15_require_env PREFILL DECODE
: "${PROXY_PORT:=8000}"
: "${MODEL:=${PRIMARY_MODEL}}"

m15_kill_tag "proxy_${PROXY_PORT}"

PROXY_PY="${REPO_ROOT}/benchmarks/xypd_benchmarks/proxy_demo.py"
[[ -f "${PROXY_PY}" ]] || m15_die "proxy demo not found at ${PROXY_PY}"

# Translate "h1:p1,h2:p2" into "h1:p1 h2:p2" (proxy_demo.py expects nargs+).
read -r -a PREFILL_LIST <<< "${PREFILL//,/ }"
read -r -a DECODE_LIST  <<< "${DECODE//,/ }"

"${PRFAAS_VENV}/bin/python" "${PROXY_PY}" \
  --model "${MODEL}" \
  --prefill "${PREFILL_LIST[@]}" \
  --decode  "${DECODE_LIST[@]}" \
  --port "${PROXY_PORT}" \
  >"${PRFAAS_LOG_DIR}/proxy_${PROXY_PORT}.log" 2>&1 &
m15_track_pid "proxy_${PROXY_PORT}" $!

# Wait for the proxy itself to be reachable (it will validate prefill+decode
# during startup, which can take a second).
sleep 3
for _ in $(seq 1 30); do
  if curl -sf "http://localhost:${PROXY_PORT}/status" >/dev/null; then
    m15_log "proxy :${PROXY_PORT} ready (pid $(cat "${PRFAAS_PID_DIR}/proxy_${PROXY_PORT}.pid"))"
    exit 0
  fi
  sleep 2
done
m15_die "proxy on :${PROXY_PORT} never came up; see ${PRFAAS_LOG_DIR}/proxy_${PROXY_PORT}.log"
