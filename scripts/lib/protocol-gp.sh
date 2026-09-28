# shellcheck shell=bash
# Palo Alto GlobalProtect via openconnect.

# PROTO_NAME must match this file's name suffix; the orchestrator verifies it.
PROTO_NAME="gp"
# PROTO_DESC is listed by the orchestrator's --help, which reads it with sed
# instead of sourcing this file - hence no in-file reference.
# shellcheck disable=SC2034
PROTO_DESC="Palo Alto GlobalProtect (openconnect --protocol=gp)"

# This file is a near-copy of protocol-anyconnect.sh - the two differ only in
# the --protocol flag passed to openconnect and in the SAML helpers below.
# Route handling is not in either of them: the generated helper calls
# finish_connect. protocol-anyconnect.sh carries the fuller commentary on what
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

# Process name(s) `vpn connect` refuses to start over and `vpn disconnect` stops.
proto_client_processes() { echo "openconnect"; }

# Absolute paths a non-root --user container may run under sudo for this
# protocol. Add any wrapper the snippets invoke with sudo as well.
proto_sudo_commands() { echo "/usr/sbin/openconnect /usr/local/sbin/openconnect"; }

# Host-side globals are not visible inside the container, so anything the
# connect snippet needs has to be handed over through /etc/vpn-client.env.
proto_write_env_extra() {
  # env_kv (defined in common.sh) shell-quotes the value, so a gateway
  # path with spaces or shell metacharacters survives `source` intact.
  env_kv VPN_GATEWAY "$GATEWAY"
}

# proto_connect_snippet: emits the proto_connect function as TEXT, spliced into
# the generated /usr/local/bin/vpn. The quoted heredoc matters - these
# variables must expand inside the container, not here.
proto_connect_snippet() {
  cat <<'EOF'
proto_connect() {
  [[ -n "$VPN_GATEWAY" ]] || { echo "VPN_GATEWAY empty" >&2; exit 1; }
  echo "Connecting openconnect protocol=gp to ${VPN_GATEWAY}"
  echo
  # -b backgrounds openconnect once authentication succeeds, so the connect can
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
}
EOF
}

proto_version_cmd() { echo "openconnect --version 2>/dev/null | head -1"; }

# ---------------------------------------------------------------------------
# SSO
#
# GlobalProtect portals increasingly front their login with SAML (ADFS, Okta,
# Azure AD...), often with a second factor. openconnect cannot finish that by
# itself: the exchange happens in a browser, and the container has none. So the
# container asks the gateway where to log in, prints it, and takes back what the
# browser produced.
#
# Four values come out of that exchange and all four matter. Assuming any of them
# is what made the helpers this replaced unable to connect a portal that returns
# the other credential kind, or that redirects.
# ---------------------------------------------------------------------------

# proto_sso_values: one per line, name|kind|default|prompt.
# kind is "secret" (read without echo) or "plain"; an empty default is required.
# Only what an operator actually has to supply. The server is deliberately NOT
# declared: proto_sso_connect falls back to VPN_GATEWAY, and the host-side hook can
# still send `server=` on stdin for the case where the exchange redirected - any
# name=value that arrives is kept, whether or not it is declared. Interpolating the
# gateway here instead would bake it into the rendered text, where a refresh - which
# reads only VPN_PROTOCOL from the container - would render it empty and turn the
# value into a required one nobody can answer.
proto_sso_values() {
  printf 'username|plain||SAML username from the browser\n'
  printf 'cookie|secret||Session cookie (prelogin-cookie or portal-userauthcookie)\n'
  printf 'usergroup|plain|gateway:prelogin-cookie|Usergroup path\n'
}

# Absolute paths the SSO path runs under sudo, on top of proto_sudo_commands.
proto_sso_sudo_commands() { echo "/usr/sbin/openconnect /usr/local/sbin/openconnect"; }

# proto_sso_url_snippet: defines proto_sso_url, which prints where to log in.
proto_sso_url_snippet() {
  cat <<'EOF'
proto_sso_url() {
  [[ -n "$VPN_GATEWAY" ]] || { echo "VPN_GATEWAY empty" >&2; return 1; }
  local out
  # Unauthenticated: this asks the portal for its auth form and gets a SAML
  # redirect instead. openconnect exits non-zero having sent no credential, so
  # the status is not a signal about one.
  out="$(echo | sudo openconnect --protocol=gp --usergroup=gateway --os=linux-64 \
           "$VPN_GATEWAY" 2>&1)" || true

  local url
  url="$(printf '%s\n' "$out" | grep -oE 'https://[^[:space:]]+' | head -1)" || url=""
  [[ -n "$url" ]] || { printf '%s\n' "$out" >&2; return 1; }

  cat <<TEXT

Open this in a browser on your own machine, NOT in this container:

  ${url}

Sign in, approve the second factor, then open the browser's developer tools,
find the POST to .../SAML20/SP/ACS and read these from its response headers:

  saml-username      -> username below
  prelogin-cookie    -> cookie below   (some portals send portal-userauthcookie;
                        if so, set usergroup to portal:portal-userauthcookie)

The cookie is short-lived, so do this without pausing.
TEXT
  return 0
}
EOF
}

# proto_sso_connect_snippet: defines proto_sso_connect, which consumes the
# collected values and brings up the tunnel.
proto_sso_connect_snippet() {
  cat <<'EOF'
proto_sso_connect() {
  local server="${SSO_server:-$VPN_GATEWAY}"
  echo
  echo "Completing SAML login as ${SSO_username} against ${server}"
  echo "  usergroup: ${SSO_usergroup}"

  # The credential goes on stdin, never in the argument list: an argument is
  # visible in the container's process table and in shell history.
  printf '%s' "$SSO_cookie" | sudo openconnect \
    --protocol=gp \
    --user="$SSO_username" \
    --usergroup="$SSO_usergroup" \
    --os=linux-64 \
    --passwd-on-stdin \
    --interface="$VPN_INTERFACE" \
    -b \
    "$server" || true
  # `|| true` on purpose: a client that refuses the credential exits non-zero, and
  # under `set -euo pipefail` that would kill this function before the check below
  # - so the operator would get no message at all instead of the one that says the
  # credential was rejected. The interface appearing is the verdict, not the exit.

  local new_iface
  new_iface="$(wait_for_iface "$VPN_INTERFACE" tun0)" || {
    echo "ERROR: the gateway refused the credential, or it had already expired." >&2
    echo "       These cookies live for seconds, not minutes. Run 'vpn connect --sso'" >&2
    echo "       again and do the browser step without pausing." >&2
    return 1
  }
  VPN_INTERFACE="$new_iface"
}
EOF
}

# ---------------------------------------------------------------------------
# Host-side extraction
#
# Optional, and it runs on the HOST, where a browser and a display exist. It
# drives gp-saml-gui, which embeds a browser, carries out the SAML exchange and
# reads the credential out of the response headers - so no developer tools, and no
# race against a cookie that lives for seconds.
# ---------------------------------------------------------------------------

# proto_sso_host_parse - map gp-saml-gui's output to the declared value names.
# Reads its stdout on standard input. Kept separate from the call so it can be
# exercised against a recorded sample instead of a live login.
#
# The tool prints four shell-quoted KEY=VALUE lines. They are read as DATA, never
# evaluated: a value must not be able to run anything, the same rule that governs
# the container's environment file.
proto_sso_host_parse() {
  local line key value host="" user="" cookie="" server="" usergroup=""
  while IFS= read -r line; do
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    # Strip the tool's own quoting without interpreting it.
    [[ "$value" == \'*\' ]] && value="${value:1:${#value}-2}"
    case "$key" in
      HOST)   host="$value" ;;
      USER)   user="$value" ;;
      COOKIE) cookie="$value" ;;
    esac
  done

  [[ -n "$host" && -n "$user" && -n "$cookie" ]] || {
    echo "ERROR: gp-saml-gui did not provide all of HOST, USER and COOKIE." >&2
    return 1
  }

  # HOST carries two facts at once: the server the exchange actually authenticated
  # against - which may differ from the one first contacted - and which credential
  # kind came back, as the <interface>:<cookie-name> path. Neither is assumed.
  local rest="${host#https://}"
  rest="${rest#http://}"
  server="${rest%%/*}"
  usergroup="${rest#*/}"
  [[ "$usergroup" != "$rest" ]] || usergroup="gateway:prelogin-cookie"

  printf 'username=%s\n' "$user"
  printf 'cookie=%s\n' "$cookie"
  printf 'usergroup=%s\n' "$usergroup"
  printf 'server=%s\n' "$server"
}

proto_sso_host_extract() {
  local name="$1" out
  command -v gp-saml-gui >/dev/null 2>&1 || {
    echo "ERROR: gp-saml-gui is not installed on this machine." >&2
    echo "       sudo apt install gp-saml-gui  (56 KB; its dependencies are already" >&2
    echo "       present on a desktop)" >&2
    return 1
  }
  [[ -n "${GATEWAY:-}" ]] || { echo "ERROR: no gateway known for ${name}." >&2; return 1; }

  # -K: do not keep the identity provider session. It would make the next login
  # shorter by storing a session on disk, and this project rejects persisted
  # credentials - an IdP session is one.
  #
  # Deliberately NOT -S or -P: those make the tool exec openconnect on THIS
  # machine, which would connect the host instead of the container. That is the
  # failure this whole arrangement exists to make impossible, so the flags are
  # never passed and the tool's default - print and exit - is what is used.
  out="$(gp-saml-gui -K -g "$GATEWAY" 2>/dev/null)" || {
    echo "ERROR: the SAML exchange did not complete." >&2
    echo "       The login window was closed, or the portal refused it. Nothing has" >&2
    echo "       been sent to the gateway." >&2
    return 1
  }
  printf '%s\n' "$out" | proto_sso_host_parse
}
