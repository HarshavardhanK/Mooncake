#!/usr/bin/env bash
# Apply a WAN profile to the egress qdisc of $IFACE inside this container.
# Usage: apply_wan.sh <profile_name> [iface]
#   profile_name: see wan_profiles.sh
#   iface:        defaults to first non-loopback iface
#
# Idempotent: clears any existing root qdisc before applying.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wan_profiles.sh
source "${here}/wan_profiles.sh"

profile="${1:?profile name required (lan|metro|regional|continental)}"
iface="${2:-$(ip -o -4 addr show | awk '$2!="lo"{print $2; exit}')}"

read -r delay_ms loss_pct bw_mbit < <(wan_profile_fields "$profile")

echo "[apply_wan] profile=${profile} iface=${iface} delay=${delay_ms}ms loss=${loss_pct}% bw=${bw_mbit:-uncapped}mbit"

tc qdisc del dev "$iface" root 2>/dev/null || true

# Build qdisc chain: tbf (rate cap) → netem (delay/loss). If no rate cap,
# netem alone is enough.
if [[ -n "$bw_mbit" ]]; then
  # tbf needs burst sized to ~bandwidth*delay; pick a generous default.
  burst_bytes=$(( bw_mbit * 125 ))   # ≈ 1ms worth
  [[ $burst_bytes -lt 32000 ]] && burst_bytes=32000
  tc qdisc add dev "$iface" root handle 1: tbf rate "${bw_mbit}mbit" \
      burst "${burst_bytes}" latency 400ms
  tc qdisc add dev "$iface" parent 1:1 handle 10: netem \
      delay "${delay_ms}ms" loss "${loss_pct}%"
else
  tc qdisc add dev "$iface" root netem \
      delay "${delay_ms}ms" loss "${loss_pct}%"
fi

tc -s qdisc show dev "$iface"
