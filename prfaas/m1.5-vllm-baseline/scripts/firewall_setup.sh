#!/usr/bin/env bash
# Open the minimal set of TCP ports needed for the named stage, scoped to
# the *other* cluster's public IP. Idempotent (uses iptables -C check).
#
# Stages:
#   stage0   — only the M1 transport bench port range (13000-13999)
#   stageD   — same + mooncake_master (10001) + etcd (2379)
#   clear    — flush our markers
#
# Usage:
#   sudo bash prfaas/m1.5-vllm-baseline/scripts/firewall_setup.sh {stage0|stageD|clear}

set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

if [[ "$(id -u)" -ne 0 ]]; then
  m15_die "must run as root (iptables)"
fi

STAGE="${1:-}"
case "${STAGE}" in
  stage0|stageD|clear) ;;
  *) m15_die "usage: $0 {stage0|stageD|clear}" ;;
esac

m15_require_env PRFAAS_ROLE X_GATEWAY_PUBLIC_IP Y_PUBLIC_IP

case "${PRFAAS_ROLE}" in
  x_gateway) PEER_IP="${Y_PUBLIC_IP}" ;;
  y)         PEER_IP="${X_GATEWAY_PUBLIC_IP}" ;;
  *)         m15_die "firewall_setup.sh only runs on x_gateway or y; this is ${PRFAAS_ROLE}" ;;
esac

# We tag every rule we add with a comment so `clear` can find them.
TAG="prfaas-m15"

add_rule_once() {
  local proto="$1" dport="$2" src="$3"
  if iptables -C INPUT -p "${proto}" --dport "${dport}" -s "${src}" \
       -m comment --comment "${TAG}" -j ACCEPT 2>/dev/null; then
    m15_log "rule exists: ACCEPT ${proto}/${dport} from ${src}"
    return
  fi
  iptables -A INPUT -p "${proto}" --dport "${dport}" -s "${src}" \
    -m comment --comment "${TAG}" -j ACCEPT
  m15_log "added: ACCEPT ${proto}/${dport} from ${src}"
}

add_port_range() {
  local low="$1" high="$2" src="$3"
  if iptables -C INPUT -p tcp --dport "${low}:${high}" -s "${src}" \
       -m comment --comment "${TAG}" -j ACCEPT 2>/dev/null; then
    m15_log "rule exists: ACCEPT tcp/${low}-${high} from ${src}"
    return
  fi
  iptables -A INPUT -p tcp --dport "${low}:${high}" -s "${src}" \
    -m comment --comment "${TAG}" -j ACCEPT
  m15_log "added: ACCEPT tcp/${low}-${high} from ${src}"
}

clear_rules() {
  m15_log "clearing all ${TAG} rules"
  while iptables-save | grep -q "${TAG}"; do
    iptables-save \
      | grep "${TAG}" \
      | head -1 \
      | sed 's/^-A /-D /' \
      | xargs -r iptables
  done
}

if [[ "${STAGE}" == "clear" ]]; then
  clear_rules
  exit 0
fi

# Mooncake transport plane (always)
low="${MOONCAKE_TRANSPORT_PORT_RANGE%-*}"
high="${MOONCAKE_TRANSPORT_PORT_RANGE#*-}"
add_port_range "${low}" "${high}" "${PEER_IP}/32"

if [[ "${STAGE}" == "stageD" ]]; then
  # Master + etcd live on x_gateway. Y needs to reach them.
  if [[ "${PRFAAS_ROLE}" == "x_gateway" ]]; then
    add_rule_once tcp "${MOONCAKE_MASTER_PORT}" "${PEER_IP}/32"
    add_rule_once tcp "${ETCD_PORT}" "${PEER_IP}/32"
  fi
fi

m15_log "firewall_setup ${STAGE} OK"
