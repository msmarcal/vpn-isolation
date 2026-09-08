# lib/protocol-anyconnect.sh
# Cisco AnyConnect via openconnect.
PROTO_NAME="anyconnect"
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
  echo "Split routes after connect: ${VPN_ROUTES:-<none>}"
  echo
  sudo openconnect \
    --protocol=anyconnect \
    --interface="$VPN_INTERFACE" \
    -b \
    "$VPN_GATEWAY"
  NEW_IFACE="$(wait_for_iface "$VPN_INTERFACE" tun0)" || {
    echo "ERROR: tunnel interface did not appear (auth failed?)" >&2
    exit 1
  }
  VPN_INTERFACE="$NEW_IFACE"
  apply_split_routes "$VPN_ROUTES" "$VPN_INTERFACE"
}
EOF
}

# proto_version_cmd: command (as a string, run inside the container) that
# prints the installed client version.
proto_version_cmd() { echo "openconnect --version 2>/dev/null | head -1"; }
