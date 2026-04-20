#!/usr/bin/env bash
# Start mooncake_master + a co-located etcd, both bound to MOONCAKE_MASTER_HOST.
# Idempotent: kills any existing instances tracked by us.

set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

m15_kill_tag mooncake_master
m15_kill_tag etcd

# ---- etcd -----------------------------------------------------------------
if ! command -v etcd >/dev/null 2>&1; then
  m15_log "installing etcd via apt"
  sudo apt-get install -y etcd-server etcd-client >/dev/null 2>&1 || \
    sudo apt-get install -y etcd >/dev/null
fi

ETCD_DATA="${PRFAAS_PID_DIR}/etcd-data"
rm -rf "${ETCD_DATA}"
mkdir -p "${ETCD_DATA}"
etcd --data-dir "${ETCD_DATA}" \
     --listen-client-urls "http://0.0.0.0:${ETCD_PORT}" \
     --advertise-client-urls "http://${MOONCAKE_MASTER_HOST:-127.0.0.1}:${ETCD_PORT}" \
     >"${PRFAAS_LOG_DIR}/etcd.log" 2>&1 &
m15_track_pid etcd $!
sleep 2

# ---- mooncake_master ------------------------------------------------------
if ! command -v mooncake_master >/dev/null 2>&1; then
  m15_die "mooncake_master not on PATH; run node_setup.sh first"
fi
mooncake_master --port "${MOONCAKE_MASTER_PORT}" \
  >"${PRFAAS_LOG_DIR}/mooncake_master.log" 2>&1 &
m15_track_pid mooncake_master $!
sleep 1

m15_log "started mooncake_master (pid $(cat "${PRFAAS_PID_DIR}/mooncake_master.pid"))" \
        "and etcd (pid $(cat "${PRFAAS_PID_DIR}/etcd.pid"))"
