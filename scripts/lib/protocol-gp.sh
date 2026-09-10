# shellcheck shell=bash
# Palo Alto GlobalProtect via openconnect.

# PROTO_NAME must match this file's name suffix; the orchestrator verifies it.
PROTO_NAME="gp"
# PROTO_DESC is listed by the orchestrator's --help, which reads it with sed
# instead of sourcing this file - hence no in-file reference.
# shellcheck disable=SC2034
PROTO_DESC="Palo Alto GlobalProtect (openconnect --protocol=gp)"

# This file is a near-copy of protocol-anyconnect.sh - the two differ only in
# the --protocol flag passed to openconnect and in anyconnect's route
# auto-detection. protocol-anyconnect.sh carries the fuller commentary on what
# each contract function is for; docs/adding-a-protocol.md has the contract.

# proto_validate_args: exit 1 with a message if required flags are missing.
# Reads the orchestrator GATEWAY/OVPN globals.
proto_validate_args() {
  if [[ -z "$GATEWAY" ]]; then
    echo "ERROR: --gateway is required for protocol=${PROTO_NAME}" >&2
    exit 1
  fi
}

# GlobalProtect portals track openconnect closely enough that the distro
# package is often too old - recommend building from source.
proto_needs_build_openconnect() { echo 1; }

# vpnc-scripts provides /usr/share/vpnc-scripts/vpnc-script, which openconnect
# runs to configure the tunnel interface and the server-pushed routes.
proto_apt_packages() { echo "openconnect vpnc-scripts"; }

# Host-side globals are not visible inside the container, so anything the
# connect snippet needs has to be handed over through /etc/vpn-client.env.
proto_write_env_extra() {
  cat <<EOF
VPN_GATEWAY=${GATEWAY}
EOF
}

# proto_connect_snippet: emits the proto_connect function as TEXT, spliced into
# the generated /usr/local/bin/connect-vpn. The quoted heredoc matters - these
# variables must expand inside the container, not here.
proto_connect_snippet() {
  cat <<'EOF'
proto_connect() {
  [[ -n "$VPN_GATEWAY" ]] || { echo "VPN_GATEWAY empty" >&2; exit 1; }
  echo "Connecting openconnect protocol=gp to ${VPN_GATEWAY}"
  echo "Split routes after connect: ${VPN_ROUTES:-<none>}"
  echo
  # -b backgrounds openconnect once authentication succeeds, so connect-vpn can
  # return while the tunnel stays up. Because it detaches, a failed login shows
  # up only as a missing interface below, not as a non-zero exit here.
  sudo openconnect \
    --protocol=gp \
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
  apply_split_routes "$VPN_ROUTES" "$VPN_INTERFACE"
}
EOF
}

proto_version_cmd() { echo "openconnect --version 2>/dev/null | head -1"; }
