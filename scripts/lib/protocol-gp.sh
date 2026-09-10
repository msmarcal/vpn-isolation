# shellcheck shell=bash
# Palo Alto GlobalProtect via openconnect.

# PROTO_NAME must match this file's name suffix; the orchestrator verifies it.
PROTO_NAME="gp"
# PROTO_DESC is listed by the orchestrator's --help, which reads it with sed
# instead of sourcing this file - hence no in-file reference.
# shellcheck disable=SC2034
PROTO_DESC="Palo Alto GlobalProtect (openconnect --protocol=gp)"

proto_validate_args() {
  if [[ -z "$GATEWAY" ]]; then
    echo "ERROR: --gateway is required for protocol=${PROTO_NAME}" >&2
    exit 1
  fi
}

proto_needs_build_openconnect() { echo 1; }

proto_apt_packages() { echo "openconnect vpnc-scripts"; }

proto_write_env_extra() {
  cat <<EOF
VPN_GATEWAY=${GATEWAY}
EOF
}

proto_connect_snippet() {
  cat <<'EOF'
proto_connect() {
  [[ -n "$VPN_GATEWAY" ]] || { echo "VPN_GATEWAY empty" >&2; exit 1; }
  echo "Connecting openconnect protocol=gp to ${VPN_GATEWAY}"
  echo "Split routes after connect: ${VPN_ROUTES:-<none>}"
  echo
  sudo openconnect \
    --protocol=gp \
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

proto_version_cmd() { echo "openconnect --version 2>/dev/null | head -1"; }
