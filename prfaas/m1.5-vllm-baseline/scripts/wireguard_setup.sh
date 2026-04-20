#!/usr/bin/env bash
# OPTIONAL: stand up a WireGuard tunnel between X-gateway and Y, used ONLY
# for the Stage 0b ablation measurement. The benchmark path uses raw TCP +
# firewall whitelist (firewall_setup.sh) for the reasons in
# EXPERIMENT_PLAN §2.1.
#
# Usage:
#   sudo bash prfaas/m1.5-vllm-baseline/scripts/wireguard_setup.sh {up|down|keys}
#
# `keys`: print a fresh keypair to stdout. Run once per side to get
#         (private, public). Save the private key locally and share the
#         public key with the other side; then re-run with `up` after
#         setting WG_PEER_PUBLIC_KEY in your env.

set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

ACTION="${1:-up}"

if ! command -v wg >/dev/null 2>&1; then
  m15_log "wireguard tools not installed; installing (apt)"
  sudo apt-get install -y wireguard-tools >/dev/null
fi

case "${ACTION}" in
  keys)
    priv="$(wg genkey)"
    pub="$(echo "${priv}" | wg pubkey)"
    echo "WG_PRIVATE_KEY=${priv}"
    echo "WG_PUBLIC_KEY=${pub}"
    exit 0
    ;;
  up)
    : ;;
  down)
    sudo wg-quick down "${HOME}/.prfaas/wg0.conf" 2>/dev/null || true
    rm -f "${HOME}/.prfaas/wg0.conf"
    exit 0
    ;;
  *)
    m15_die "usage: $0 {up|down|keys}"
    ;;
esac

if [[ "$(id -u)" -ne 0 ]]; then
  m15_die "must run as root for 'up' (wg-quick)"
fi

m15_require_env PRFAAS_ROLE WG_PRIVATE_KEY WG_PEER_PUBLIC_KEY \
                X_GATEWAY_PUBLIC_IP Y_PUBLIC_IP

case "${PRFAAS_ROLE}" in
  x_gateway)
    LOCAL_TUN_IP="10.42.0.1/24"
    PEER_TUN_IP="10.42.0.2/32"
    PEER_ENDPOINT="${Y_PUBLIC_IP}:51820"
    ;;
  y)
    LOCAL_TUN_IP="10.42.0.2/24"
    PEER_TUN_IP="10.42.0.1/32"
    PEER_ENDPOINT="${X_GATEWAY_PUBLIC_IP}:51820"
    ;;
  *)
    m15_die "wireguard only runs on x_gateway or y; this is ${PRFAAS_ROLE}"
    ;;
esac

mkdir -p "${HOME}/.prfaas"
WG_CONF="${HOME}/.prfaas/wg0.conf"
cat > "${WG_CONF}" <<EOF
[Interface]
Address = ${LOCAL_TUN_IP}
ListenPort = 51820
PrivateKey = ${WG_PRIVATE_KEY}
# MTU set to 1420 to leave room for the WG header on a 1500-MTU public path.
MTU = 1420

[Peer]
PublicKey = ${WG_PEER_PUBLIC_KEY}
AllowedIPs = ${PEER_TUN_IP}
Endpoint = ${PEER_ENDPOINT}
PersistentKeepalive = 25
EOF
chmod 600 "${WG_CONF}"

sudo wg-quick up "${WG_CONF}"
m15_log "WireGuard up. Local tun IP: ${LOCAL_TUN_IP%%/*}, peer: ${PEER_TUN_IP%%/*}"
m15_log "Test reachability:  ping -c 3 ${PEER_TUN_IP%%/*}"
