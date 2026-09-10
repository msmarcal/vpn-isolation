# shellcheck shell=bash
#
# Shared VPN helpers.
#
# This file is used two ways: sourced directly by the orchestrator
# (create-vpn-lxd-container.sh) on the host, and COPIED VERBATIM into the
# generated /usr/local/bin/connect-vpn inside each container. The container
# never has a copy of this repository, so these functions only exist there
# because their text was pasted in.
#
# That second use is the binding constraint: keep this file self-contained,
# protocol-agnostic, and free of any dependency beyond the base package set
# the orchestrator installs (iproute2, iptables, curl, openssh-*, dnsutils).
# Anything sourced, imported, or shelled out to here must also exist inside
# every container this repo can build.

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
  # The counter is never read - this is a fixed number of one-second attempts.
  for _ in $(seq 1 40); do
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
