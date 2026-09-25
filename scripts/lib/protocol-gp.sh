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

# Process name(s) connect-vpn refuses to start over and disconnect-vpn stops.
proto_client_processes() { echo "openconnect"; }

# Absolute paths a non-root --user container may run under sudo for this
# protocol. Add any wrapper the snippets invoke with sudo as well.
proto_sudo_commands() { echo "/usr/sbin/openconnect /usr/local/sbin/openconnect"; }

# Host-side globals are not visible inside the container, so anything the
# connect snippet needs has to be handed over through /etc/vpn-client.env.
proto_write_env_extra() {
  # env_kv (defined by the orchestrator) shell-quotes the value, so a gateway
  # path with spaces or shell metacharacters survives `source` intact.
  env_kv VPN_GATEWAY "$GATEWAY"
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
  #
  # NOTE: if this fails with 'XML response has no "auth" node', the portal is
  # SAML-fronted (ADFS/Okta/Azure AD + Duo etc) and plain openconnect cannot
  # complete the login by itself. Use connect-vpn-saml / connect-vpn-saml-finish
  # instead (installed alongside this script - see their --help/usage output).
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

# proto_post_install: orchestrator-side hook (runs on the host, not inside the
# container). GlobalProtect portals increasingly front SAML SSO (ADFS, Okta,
# Azure AD...) instead of native username/password - openconnect alone cannot
# complete that login (the SAML exchange, including any 2FA/Duo step, has to
# happen in a real browser), and connect-vpn fails with the tell-tale
# 'XML response has no "auth" node'. This pushes two extra helper scripts into
# the container, implementing the manual two-step flow documented by the
# openconnect / gp-saml-gui community for GP+SAML portals:
#
#   connect-vpn-saml [usergroup]
#     Asks openconnect for the SAML login URL (instead of an XML auth form)
#     and prints it, plus instructions.
#
#   connect-vpn-saml-finish <prelogin-cookie> <saml-username> [usergroup]
#     The user opens the printed URL in a browser OUTSIDE the container (host
#     laptop, where Duo push/SSO normally works), completes SSO + Duo there,
#     copies the prelogin-cookie + saml-username values out of the resulting
#     page (browser DevTools Network tab, POST to .../SAML20/SP/ACS or
#     similar), and passes them to this script. It feeds those values back
#     into openconnect via --usergroup=gateway:prelogin-cookie
#     --passwd-on-stdin, completing the handshake and bringing up the tunnel
#     the same way plain connect-vpn does (wait_for_iface +
#     apply_split_routes).
#
# Local script files are written to a temp dir and pushed with `lxc file
# push`, matching the pattern protocol-openvpn.sh uses for its .ovpn profile -
# far less fragile than nested single-quoted `lxc exec ... bash -c 'cat <<EOF'`
# heredocs (see the apostrophe pitfall in the lxd-customer-vpn-isolation
# skill).
proto_post_install() {
  local name="$1"
  echo "==> Installing GlobalProtect SAML helper scripts (connect-vpn-saml, connect-vpn-saml-finish)"

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  cat > "$tmp/connect-vpn-saml" <<'HELPER_EOF'
#!/usr/bin/env bash
set -euo pipefail

ENV_FILE=/etc/vpn-client.env
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

VPN_GATEWAY="${VPN_GATEWAY:?Set VPN_GATEWAY in /etc/vpn-client.env}"
USERGROUP="${1:-gateway}"

if pgrep -x openconnect >/dev/null 2>&1; then
  echo "A VPN client is already running. Run disconnect-vpn first." >&2
  exit 1
fi

echo "=== Step 1: fetch the SAML login URL from ${VPN_GATEWAY} ==="
echo "(usergroup=${USERGROUP} - pass \"portal\" as arg1 to try the portal path instead of gateway)"
echo

set +e
SAML_OUT="$(echo | sudo openconnect --protocol=gp --usergroup="${USERGROUP}" --os=linux-64 "$VPN_GATEWAY" 2>&1)"
set -e
echo "$SAML_OUT" | grep -iE "SAML|redirect|https://" || echo "$SAML_OUT"

echo
echo "=== Step 2: manual browser login (OUTSIDE this container, on your laptop) ==="
echo "1. Copy the SAML URL printed above into a normal browser on your laptop -"
echo "   NOT inside this container."
echo "2. Log in with your corporate credentials and approve the Duo prompt."
echo "3. After Duo succeeds, open browser DevTools -> Network tab and find the"
echo "   POST request to .../SAML20/SP/ACS (or similar). In its response look for:"
echo "     prelogin-cookie   (sometimes named portal-userauthcookie)"
echo "     saml-username"
echo "4. Copy those two values, then run on THIS container:"
echo
echo "     connect-vpn-saml-finish \"<prelogin-cookie value>\" \"<saml-username value>\""
echo
HELPER_EOF

  cat > "$tmp/connect-vpn-saml-finish" <<'HELPER_EOF'
#!/usr/bin/env bash
set -euo pipefail

ENV_FILE=/etc/vpn-client.env
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

VPN_GATEWAY="${VPN_GATEWAY:?Set VPN_GATEWAY in /etc/vpn-client.env}"
VPN_INTERFACE="${VPN_INTERFACE:-vpn0}"
VPN_ROUTES="${VPN_ROUTES:-}"

COOKIE="${1:?Usage: connect-vpn-saml-finish <prelogin-cookie> <saml-username> [usergroup]}"
SAML_USER="${2:?Usage: connect-vpn-saml-finish <prelogin-cookie> <saml-username> [usergroup]}"
USERGROUP="${3:-gateway:prelogin-cookie}"

if pgrep -x openconnect >/dev/null 2>&1; then
  echo "A VPN client is already running. Run disconnect-vpn first." >&2
  exit 1
fi

echo "Completing GlobalProtect SAML auth as ${SAML_USER} (usergroup=${USERGROUP})"
echo "$COOKIE" | sudo openconnect \
  --protocol=gp \
  --user="$SAML_USER" \
  --usergroup="$USERGROUP" \
  --os=linux-64 \
  --passwd-on-stdin \
  --interface="$VPN_INTERFACE" \
  -b \
  "$VPN_GATEWAY"

NEW_IFACE="$(wait_for_iface "$VPN_INTERFACE" tun0)" || {
  echo "ERROR: tunnel interface did not appear - cookie may be stale/expired (they are short-lived, retry from connect-vpn-saml if so)" >&2
  exit 1
}
VPN_INTERFACE="$NEW_IFACE"
apply_split_routes "$VPN_ROUTES" "$VPN_INTERFACE"
echo
echo "VPN up on ${VPN_INTERFACE}."
ip -br addr show "$VPN_INTERFACE" || true
HELPER_EOF

  chmod +x "$tmp/connect-vpn-saml" "$tmp/connect-vpn-saml-finish"
  lxc file push "$tmp/connect-vpn-saml" "$name/usr/local/bin/connect-vpn-saml" >/dev/null
  lxc file push "$tmp/connect-vpn-saml-finish" "$name/usr/local/bin/connect-vpn-saml-finish" >/dev/null
  lxc exec "$name" -- chmod +x /usr/local/bin/connect-vpn-saml /usr/local/bin/connect-vpn-saml-finish
}
