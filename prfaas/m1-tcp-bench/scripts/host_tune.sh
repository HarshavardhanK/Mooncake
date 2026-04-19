#!/usr/bin/env bash
# Raise host-kernel TCP buffers so high-BDP WAN profiles in M1 can actually
# fill the pipe. These sysctls are NOT network-namespaced, so they must be set
# on the host (or VM) kernel — the per-container `sysctls:` block in compose
# only handles the netns-scoped `net.ipv4.tcp_{r,w}mem` knobs.
#
# At 10 Gbps × 200 ms RTT (continental profile) the bandwidth-delay product is
# ~250 MB, so wmem_max=256 MB lets a single TCP flow saturate the link.
#
# Usage (run on each cluster node before `docker compose up`):
#   sudo ./prfaas/m1-tcp-bench/scripts/host_tune.sh
#
# Intentionally idempotent: safe to re-run. Does NOT persist across reboots
# (we don't write /etc/sysctl.d/) — by design, since the cluster nodes may
# be shared and we don't want to mutate global config.
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: must run as root (sysctl writes /proc/sys)." >&2
  echo "       sudo $0" >&2
  exit 1
fi

# Bump only if current value is lower; never lower a higher operator setting.
bump() {
  local key="$1" want="$2"
  local cur
  cur="$(sysctl -n "${key}" 2>/dev/null || echo 0)"
  # Strip whitespace; if it's a tuple (tcp_rmem etc.), compare last field.
  cur="$(echo "${cur}" | awk '{print $NF}')"
  if (( cur < want )); then
    sysctl -w "${key}=${want}" >/dev/null
    echo "[host_tune] ${key}: ${cur} -> ${want}"
  else
    echo "[host_tune] ${key}: keeping ${cur} (>= ${want})"
  fi
}

bump net.core.rmem_max     268435456
bump net.core.wmem_max     268435456
bump net.core.rmem_default  67108864
bump net.core.wmem_default  67108864

# qdisc / backlog so apply_wan.sh's netem doesn't drop bursts.
bump net.core.netdev_max_backlog 30000
bump net.core.somaxconn          4096

echo "[host_tune] OK"
