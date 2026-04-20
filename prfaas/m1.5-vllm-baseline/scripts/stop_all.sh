#!/usr/bin/env bash
# Tear down everything we tracked. Safe to run when nothing is up.

set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

shopt -s nullglob
for pidfile in "${PRFAAS_PID_DIR}"/*.pid; do
  tag="$(basename "${pidfile}" .pid)"
  m15_kill_tag "${tag}"
  m15_log "stopped ${tag}"
done

# Belt-and-braces: any leftover vllm api_servers from previous unclean runs.
pkill -f 'vllm.entrypoints.openai.api_server' 2>/dev/null || true
pkill -f 'mooncake_master' 2>/dev/null || true
pkill -f 'proxy_demo.py' 2>/dev/null || true
pkill -f '^etcd ' 2>/dev/null || true
m15_log "stop_all done"
