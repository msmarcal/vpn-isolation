# shellcheck shell=bash
# Cisco AnyConnect via openconnect.

# PROTO_NAME must match this file's name suffix; the orchestrator verifies it.
PROTO_NAME="anyconnect"
# PROTO_DESC is listed by the orchestrator's --help, which reads it with sed
# instead of sourcing this file - hence no in-file reference.
# shellcheck disable=SC2034
PROTO_DESC="Cisco AnyConnect (openconnect --protocol=anyconnect)"

# proto_validate_args: exit 1 with a message if required flags are missing.
# Reads the orchestrator's GATEWAY/OVPN globals.
proto_validate_args() {
  if [[ -z "$GATEWAY" ]]; then
    echo "ERROR: --gateway is required for protocol=${PROTO_NAME}" >&2
    exit 1
  fi
}

# proto_needs_build_openconnect: "1" if this protocol benefits from building
# openconnect from source (recent versions needed for modern ASA/Firepower).
proto_needs_build_openconnect() { echo 1; }

# proto_apt_packages: space-separated extra apt packages for this protocol
# (on top of the always-installed base set).
proto_apt_packages() { echo "openconnect vpnc-scripts"; }

# proto_write_env_extra NAME: extra KEY=VALUE lines appended to
# /etc/vpn-client.env, one per line on stdout.
proto_write_env_extra() {
  cat <<EOF
VPN_GATEWAY=${GATEWAY}
EOF
}

# proto_connect_snippet: bash function body (as text) injected into the
# in-container connect-vpn script. Must define shell function proto_connect
# that uses env vars from /etc/vpn-client.env and prints the resulting
# interface name in variable VPN_INTERFACE (already exported by caller).
proto_connect_snippet() {
  cat <<'EOF'
proto_connect() {
  [[ -n "$VPN_GATEWAY" ]] || { echo "VPN_GATEWAY empty" >&2; exit 1; }
  echo "Connecting openconnect protocol=anyconnect to ${VPN_GATEWAY}"
  echo "Split routes after connect: ${VPN_ROUTES:-<auto-detect>}"
  echo
  # -b backgrounds openconnect once authentication succeeds, so connect-vpn can
  # return while the tunnel stays up. Because it detaches, a failed login shows
  # up only as a missing interface below, not as a non-zero exit here.
  sudo openconnect \
    --protocol=anyconnect \
    --interface="$VPN_INTERFACE" \
    -b \
    "$VPN_GATEWAY"
  # openconnect honors --interface when it can, but falls back to tun0; accept
  # either rather than guessing.
  NEW_IFACE="$(wait_for_iface "$VPN_INTERFACE" tun0)" || {
    echo "ERROR: tunnel interface did not appear (auth failed?)" >&2
    exit 1
  }
  VPN_INTERFACE="$NEW_IFACE"

  # Auto-detect routes from the server if VPN_ROUTES is empty or "auto".
  # There is no separate query for this: openconnect already ran vpnc-script,
  # which installed the server split-include routes on the tunnel interface, so
  # reading the routing table back is what "asking the server" amounts to. Only
  # works for a split-tunnel gateway - a full-tunnel one pushes a default route,
  # which is filtered out below, leaving nothing to detect.
  if [[ -z "$VPN_ROUTES" || "$VPN_ROUTES" == "auto" ]]; then
    echo "Attempting to auto-detect split-include routes from server..."
    DETECTED_ROUTES="$(ip route show dev "$VPN_INTERFACE" | awk '{print $1}' | grep -v '^default' | tr '\n' ',' | sed 's/,$//')"
    if [[ -n "$DETECTED_ROUTES" ]]; then
      echo "Detected routes from server: $DETECTED_ROUTES"
      VPN_ROUTES="$DETECTED_ROUTES"
    else
      echo "WARNING: No split-include routes detected from server."
      echo "         You may need to set --routes manually or use full tunnel."
      VPN_ROUTES=""
    fi
  fi
  
  apply_split_routes "$VPN_ROUTES" "$VPN_INTERFACE"
}
EOF
}

# proto_version_cmd: command (as a string, run inside the container) that
# prints the installed client version.
proto_version_cmd() { echo "openconnect --version 2>/dev/null | head -1"; }
