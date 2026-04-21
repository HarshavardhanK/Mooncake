#!/usr/bin/env bash
# Start the M1 transfer_engine_lat_bench in target mode on g304 for Stage 0a.
# Background the bench, scrape the announced RPC port, print machine-readable
# vars to stdout for the orchestrator to consume.

set -euo pipefail
# shellcheck disable=SC1091  # env file lives on the remote node
. /scratch/prfaas/.prfaas_stage0a_env

mkdir -p "$PRFAAS_WORK_DIR/run" "$PRFAAS_WORK_DIR/logs"
target_log="$PRFAAS_WORK_DIR/logs/stage0a_target.log"
target_pid_file="$PRFAAS_WORK_DIR/run/stage0a_target.pid"
: > "$target_log"

pkill -f 'transfer_engine_lat_bench --mode=target' 2>/dev/null || true
sleep 1

setsid nohup bash -c "
  . /scratch/prfaas/.prfaas_stage0a_env
  exec transfer_engine_lat_bench \
    --mode=target \
    --metadata_server=P2PHANDSHAKE \
    --local_server_name=159.26.81.50 \
    --buffer_size=4294967296
" >"$target_log" 2>&1 < /dev/null &

echo $! > "$target_pid_file"
disown || true

for _ in $(seq 1 30); do
  if grep -Eq 'listening on [^ ]+:[0-9]+' "$target_log" 2>/dev/null; then
    break
  fi
  sleep 1
done

listen_line=$(grep -Eo 'listening on [^ ]+:[0-9]+' "$target_log" | tail -1 || true)
if [[ -z "$listen_line" ]]; then
  echo "TARGET_FAILED_TO_START"
  echo "--- log tail ---"
  tail -50 "$target_log"
  exit 1
fi

port="${listen_line##*:}"
target_pid=$(cat "$target_pid_file")
echo "TARGET_RPC_PORT=${port}"
echo "TARGET_PID=${target_pid}"
echo "TARGET_LISTEN=${listen_line}"
ss -tlnp 2>/dev/null | awk -v p="${port}" '$4 ~ ":" p "$" {print}'
echo "TARGET_LOG=${target_log}"
