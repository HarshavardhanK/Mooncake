#!/usr/bin/env bash
# Phase 3 cross-DC firewall extension for g304 (X-gateway, public IP
# 159.26.81.50).
#
# DO NOT auto-run. The agent has no SSH automation budget for X cluster
# hosts. Operator runs this manually:
#
#   ssh vpsupport@159.26.81.50
#   sudo bash /tmp/g304-phase3-iptables.sh   # after scp'ing it over
#
# What this opens (delta over Stage D):
#   - TCP 30001 from 147.185.40.126/32 only — SGLang API (router on Y dials
#     this for /v1/chat/completions prefill).
#
# What is ALREADY open from Stage D (do NOT re-add; this script no-ops them):
#   - TCP 8998 from 147.185.40.126/32 (Mooncake bootstrap port).
#
# What is ALREADY open from Stage 0a (do NOT re-add; out of scope):
#   - TCP 13000-17000 from 147.185.40.126/32 (Mooncake transport range).
#
# What we deliberately do NOT open:
#   - 30001/8998 to the wider Internet. Every rule is scoped to source
#     147.185.40.126/32 (g126 public IP).

set -euo pipefail

PEER_IP="147.185.40.126"     # g126 (Y, public IP)
SGLANG_API_PORT="30001"
BOOTSTRAP_PORT="8998"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: must run as root (use sudo)" >&2
  exit 1
fi

already_present() {
  local port="$1"
  iptables -C INPUT -p tcp -s "${PEER_IP}/32" --dport "${port}" -j ACCEPT 2>/dev/null
}

ensure_rule() {
  local port="$1"
  local comment="$2"
  if already_present "${port}"; then
    echo "[firewall] TCP ${port} from ${PEER_IP} already allowed; nothing to do."
    return
  fi
  echo "[firewall] inserting rule: allow TCP ${port} from ${PEER_IP}"
  iptables -I INPUT 1 -p tcp -s "${PEER_IP}/32" --dport "${port}" -j ACCEPT \
    -m comment --comment "${comment}"
  echo "[firewall] inserted."
}

# Mooncake bootstrap (idempotent — Stage D may have inserted this already).
ensure_rule "${BOOTSTRAP_PORT}" "prfaas phase3: Mooncake bootstrap from g126"

# SGLang API for the cross-DC router on Y to call into the prefiller for
# /v1/chat/completions prefill.
ensure_rule "${SGLANG_API_PORT}" "prfaas phase3: SGLang API from g126"

echo
echo "[firewall] current rules touching :${BOOTSTRAP_PORT}, :${SGLANG_API_PORT}, or 13000-17000 ::"
iptables -S INPUT | grep -E ":${BOOTSTRAP_PORT}|:${SGLANG_API_PORT}|13000:17000|prfaas" || \
  echo "  (none)"

echo
echo "[firewall] To persist across reboots, save with one of:"
echo "  apt-get install -y iptables-persistent && netfilter-persistent save"
echo "  iptables-save > /etc/iptables/rules.v4"
echo "(Stage 0a/D's rules were saved this way; do whatever matches the host's policy.)"
