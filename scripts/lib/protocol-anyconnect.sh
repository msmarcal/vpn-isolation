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

# Process name(s) `vpn connect` refuses to start over and `vpn disconnect` stops.
proto_client_processes() { echo "openconnect"; }

# Absolute paths a non-root --user container may run under sudo for this
# protocol. Add any wrapper the snippets invoke with sudo as well.
proto_sudo_commands() { echo "/usr/sbin/openconnect /usr/local/sbin/openconnect"; }

# proto_write_env_extra NAME: extra KEY=VALUE lines appended to
# /etc/vpn-client.env, one per line on stdout.
proto_write_env_extra() {
  # env_kv (defined in common.sh) shell-quotes the value, so a gateway
  # path with spaces or shell metacharacters survives `source` intact.
  env_kv VPN_GATEWAY "$GATEWAY"
}

# proto_connect_snippet: bash function body (as text) injected into the
# container's `vpn` command. Defines proto_connect, which authenticates,
# brings up the tunnel and leaves the interface that actually appeared in
# VPN_INTERFACE. It does nothing about routing: the generated helper calls
# finish_connect afterwards, which resolves VPN_ROUTES (including "auto",
# by reading back what the client installed), applies it, records the
# connection and reports.
proto_connect_snippet() {
  cat <<'EOF'
proto_connect() {
  [[ -n "$VPN_GATEWAY" ]] || { echo "VPN_GATEWAY empty" >&2; exit 1; }
  echo "Connecting openconnect protocol=anyconnect to ${VPN_GATEWAY}"
  echo
  # -b backgrounds openconnect once authentication succeeds, so the connect can
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
}
EOF
}

# ---------------------------------------------------------------------------
# SSO
#
# ASA and Firepower gateways can front their login with SAML too. The shape is the
# same as GlobalProtect's - the exchange happens in a browser the container does
# not have, and a session cookie comes back - but the client takes it differently:
# openconnect's anyconnect protocol wants the cookie as its authentication cookie
# rather than as a password.
# ---------------------------------------------------------------------------

# The server is deliberately not declared - proto_sso_connect falls back to
# VPN_GATEWAY, and a host-side hook can still send `server=` on stdin. See the
# longer note in protocol-gp.sh for why interpolating it here would break a refresh.
proto_sso_values() {
  printf 'cookie|secret||Session cookie from the browser (webvpn value)\n'
}

proto_sso_sudo_commands() { echo "/usr/sbin/openconnect /usr/local/sbin/openconnect"; }

proto_sso_url_snippet() {
  cat <<'EOF'
proto_sso_url() {
  [[ -n "$VPN_GATEWAY" ]] || { echo "VPN_GATEWAY empty" >&2; return 1; }
  local out url
  # Unauthenticated: asks the gateway for its auth form and reads back where it
  # wants the browser to go. No credential is sent, so a non-zero status here says
  # nothing about one.
  out="$(echo | sudo openconnect --protocol=anyconnect --os=linux-64 \
           "$VPN_GATEWAY" 2>&1)" || true
  url="$(printf '%s\n' "$out" | grep -oE 'https://[^[:space:]]+' | head -1)" || url=""
  [[ -n "$url" ]] || { printf '%s\n' "$out" >&2; return 1; }

  cat <<TEXT

Open this in a browser on your own machine, NOT in this container:

  ${url}

Sign in, approve the second factor, then read the session cookie the gateway set
(the webvpn cookie) from the browser's developer tools. It is short-lived, so do
this without pausing.
TEXT
  return 0
}
EOF
}

proto_sso_connect_snippet() {
  cat <<'EOF'
proto_sso_connect() {
  local server="${SSO_server:-$VPN_GATEWAY}"
  echo
  echo "Completing SAML login against ${server}"

  # On stdin, never as an argument: an argument is visible in the process table.
  printf '%s' "$SSO_cookie" | sudo openconnect \
    --protocol=anyconnect \
    --cookie-on-stdin \
    --interface="$VPN_INTERFACE" \
    -b \
    "$server" || true
  # `|| true` on purpose: a refused cookie exits non-zero, and under
  # `set -euo pipefail` that would kill this function before the check below, so
  # the operator would get no message. The interface appearing is the verdict.

  local new_iface
  new_iface="$(wait_for_iface "$VPN_INTERFACE" tun0)" || {
    echo "ERROR: the gateway refused the cookie, or it had already expired." >&2
    echo "       These live for seconds. Run 'vpn connect --sso' again and do the" >&2
    echo "       browser step without pausing." >&2
    return 1
  }
  VPN_INTERFACE="$new_iface"
}
EOF
}

# proto_version_cmd: command (as a string, run inside the container) that
# prints the installed client version.
proto_version_cmd() { echo "openconnect --version 2>/dev/null | head -1"; }
