# Source me: defines WAN profiles as `delay loss bandwidth`.
# `bandwidth` is in mbit. Empty bandwidth means uncapped.

declare -A WAN_PROFILES=(
  # name        delay_ms  loss_pct  bw_mbit
  [lan]=        "0        0         "
  [metro]=      "2        0         100000"
  [regional]=   "10       0.01      100000"
  [continental]="40       0.05      40000"
)

# Print "delay loss bw" for the given profile name.
wan_profile_fields() {
  local name="$1"
  local fields="${WAN_PROFILES[$name]:-}"
  if [[ -z "$fields" ]]; then
    echo "unknown WAN profile: $name (have: ${!WAN_PROFILES[*]})" >&2
    return 1
  fi
  echo "$fields"
}
