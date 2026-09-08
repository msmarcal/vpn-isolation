# lib/common.sh
# Shared shell functions sourced by both the orchestrator (create-vpn-lxd-container.sh)
# and the in-container connect-vpn script. Keep this POSIX-ish bash, no external deps
# beyond what's installed by the base package set.

# apply_split_routes CIDR_LIST IFACE
# CIDR_LIST is a comma-separated string (e.g. "10.1.0.0/16,10.2.0.0/24")
apply_split_routes() {
  local routes="$1" iface="$2"
  [[ -z "$routes" ]] && return 0
  IFS="," read -ra RLIST <<< "$routes"
  local cidr cidr_trimmed
  for cidr in "${RLIST[@]}"; do
    cidr_trimmed="$(echo "$cidr" | xargs)"
    [[ -z "$cidr_trimmed" ]] && continue
    echo "Adding split route: $cidr_trimmed dev $iface"
    sudo ip route replace "$cidr_trimmed" dev "$iface" 2>/dev/null \
      || sudo ip route add "$cidr_trimmed" dev "$iface" || true
  done
}

# wait_for_iface IFACE [FALLBACK_IFACE]
# Polls up to ~40s for IFACE to appear; if FALLBACK_IFACE appears instead
# (common with tools that always name their tunnel tun0), prints the fallback
# name to stdout so callers can pick it up.
wait_for_iface() {
  local iface="$1" fallback="${2:-}"
  local i
  for i in $(seq 1 40); do
    if ip link show "$iface" >/dev/null 2>&1; then
      echo "$iface"
      return 0
    fi
    if [[ -n "$fallback" ]] && ip link show "$fallback" >/dev/null 2>&1; then
      echo "$fallback"
      return 0
    fi
    sleep 1
  done
  return 1
}
