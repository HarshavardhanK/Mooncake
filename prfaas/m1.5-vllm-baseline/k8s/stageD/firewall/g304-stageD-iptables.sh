#!/usr/bin/env bash
# Stage D firewall extension for g304 (X-gateway, public IP 159.26.81.50).
#
# DO NOT auto-run. The agent has no SSH automation budget for X cluster
# hosts. Operator runs this manually:
#
#   sshv vpsupport@159.26.81.50
#   sudo bash /tmp/g304-stageD-iptables.sh   # after scp'ing it over
#
# What this opens:
#   TCP 8998 from g126 (147.185.40.126) only — Mooncake bootstrap port.
#
# What is ALREADY open from Stage 0a (do NOT re-add; this script no-ops them):
#   TCP 13000-17000 from 147.185.40.126/32 (Mooncake transport range).
#
# What we deliberately do NOT open:
#   - 8010 (vLLM OpenAI HTTP). The decoder talks Mooncake, not OpenAI HTTP,
#     to the prefiller. The proxy on Y reaches the prefiller's /query on 8998
#     (bootstrap) for engine_id discovery; the actual prefill request flows
#     through the connector via the bootstrap+transport ports. We do not
#     want the OpenAI API exposed publicly.
#   - Anything bidirectional on the wider Internet — every rule is scoped
#     to source 147.185.40.126/32 (g126 public IP).

set -euo pipefail

PEER_IP="147.185.40.126"     # g126 (Y, public IP)
BOOTSTRAP_PORT="8998"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: must run as root (use sudo)" >&2
  exit 1
fi

# Idempotency guard — only insert the rule if it isn't already present.
already_present() {
  iptables -C INPUT -p tcp -s "${PEER_IP}/32" --dport "${BOOTSTRAP_PORT}" -j ACCEPT 2>/dev/null
}

if already_present; then
  echo "[firewall] TCP ${BOOTSTRAP_PORT} from ${PEER_IP} already allowed; nothing to do."
else
  echo "[firewall] inserting rule: allow TCP ${BOOTSTRAP_PORT} from ${PEER_IP}"
  # The exact line that gets appended to INPUT (insert at top so it precedes
  # any DROP rule the host may already have):
  iptables -I INPUT 1 -p tcp -s "${PEER_IP}/32" --dport "${BOOTSTRAP_PORT}" -j ACCEPT \
    -m comment --comment "prfaas stageD: Mooncake bootstrap from g126"
  echo "[firewall] inserted."
fi

echo
echo "[firewall] current rules touching :${BOOTSTRAP_PORT} or 13000-17000 ::"
iptables -S INPUT | grep -E ":${BOOTSTRAP_PORT}|13000:17000|prfaas" || echo "  (none)"

echo
echo "[firewall] To persist across reboots, save with one of:"
echo "  apt-get install -y iptables-persistent && netfilter-persistent save"
echo "  iptables-save > /etc/iptables/rules.v4"
echo "(Stage 0a's rules were saved this way; do whatever matches the host's policy.)"
