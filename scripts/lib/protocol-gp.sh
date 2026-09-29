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
  cat <<'EOF'
# Host Information Profile. A GlobalProtect gateway may require a posture report
# and, when it does not get one, establish the tunnel anyway and then limit what it
# carries - so the symptom is a connected VPN that reaches the internal resolver
# and nothing else. `auto` uses the hipreport.sh that openconnect ships, if it is
# present. A path uses that script. Empty disables it, and the connect says so.
EOF
  env_kv VPN_GP_HIP auto
}

# proto_connect_snippet: emits the proto_connect function as TEXT, spliced into
# the generated /usr/local/bin/vpn. The quoted heredoc matters - these
# variables must expand inside the container, not here.
proto_connect_snippet() {
  cat <<'EOF'
# gp_hip_wrapper - print the HIP report script to hand openconnect, or nothing.
# Absent key means `auto`, because --refresh-helpers does not rewrite
# /etc/vpn-client.env and containers created before this key exists must keep
# working. The source build and the distro package install the script in different
# places, so neither is hardcoded.
gp_hip_wrapper() {
  local want="${VPN_GP_HIP:-auto}" c
  [[ -n "$want" ]] || return 0
  if [[ "$want" != "auto" ]]; then
    if [[ -x "$want" ]]; then printf '%s' "$want"; else
      echo "WARNING: VPN_GP_HIP=${want} is not executable; sending no HIP report." >&2
    fi
    return 0
  fi
  for c in /usr/local/libexec/openconnect/hipreport.sh \
           /usr/libexec/openconnect/hipreport.sh; do
    [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  return 0
}

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
  # complete the login by itself. Use `vpn connect --sso`, which carries out that
  # exchange in a browser on the operator's own machine. It replaced the
  # connect-vpn-saml / connect-vpn-saml-finish pair this note used to name.
  HIP_ARGS=()
  HIP="$(gp_hip_wrapper)"
  if [[ -n "$HIP" ]]; then
    HIP_ARGS+=(--csd-wrapper="$HIP")
    echo "  HIP report: ${HIP}"
  else
    echo "  HIP report: none (VPN_GP_HIP). A gateway that requires one may limit" >&2
    echo "              what the tunnel carries without saying so." >&2
  fi
  sudo openconnect \
    --protocol=gp \
    --interface="$VPN_INTERFACE" \
    "${HIP_ARGS[@]}" \
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
  # Declared rather than assumed, for the same reason as the two above. A portal
  # publishes client configurations per OS and hands out none for an OS it does not
  # know: the Lear portal answers `Matching client config not found` to a Linux
  # client while a Windows one connects. This was hardcoded to linux-64 and cost a
  # live login to find, because the failure arrives AFTER the credential is
  # accepted and looked exactly like a rejected cookie.
  printf 'os|plain|linux-64|Client OS the portal publishes a config for (linux-64, win, mac-intel)\n'
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
  local client_os="${SSO_os:-linux-64}"
  echo "Completing SAML login as ${SSO_username} against ${server}"
  echo "  usergroup: ${SSO_usergroup}"
  echo "  client OS: ${client_os}"

  # The client's own output is kept so the failure below can name a cause instead
  # of guessing one. 0600 and removed on both paths: it holds openconnect's
  # transcript, not the cookie, but nothing here gets to be readable by default.
  #
  # REDIRECTED, never piped. `-b` makes openconnect fork and keep the inherited
  # stdout open in the daemon, so `| tee` never sees EOF and the connect hangs
  # forever with the tunnel already up - which is exactly what happened the first
  # time this was written that way, against a live gateway.
  local log
  log="$(mktemp "${TMPDIR:-/tmp}/.vpn-sso-log.XXXXXX")"
  chmod 600 "$log"

  # The credential goes on stdin, never in the argument list: an argument is
  # visible in the container's process table and in shell history.
  local hip
  hip="$(gp_hip_wrapper)"
  local hip_args=()
  if [[ -n "$hip" ]]; then
    hip_args+=(--csd-wrapper="$hip")
    echo "  HIP report: ${hip}"
  else
    echo "  HIP report: none - a gateway that requires one connects and then limits"
    echo "              what the tunnel carries, which reads as a routing problem."
  fi

  printf '%s' "$SSO_cookie" | sudo openconnect \
    --protocol=gp \
    --user="$SSO_username" \
    --usergroup="$SSO_usergroup" \
    --os="$client_os" \
    --passwd-on-stdin \
    --interface="$VPN_INTERFACE" \
    "${hip_args[@]}" \
    -b \
    "$server" > "$log" 2>&1 || true
  cat "$log"
  # `|| true` on purpose: a client that refuses the credential exits non-zero, and
  # under `set -euo pipefail` that would kill this function before the check below
  # - so the operator would get no message at all instead of the one that says the
  # credential was rejected. The interface appearing is the verdict, not the exit.

  local new_iface
  new_iface="$(wait_for_iface "$VPN_INTERFACE" tun0)" || {
    # Two failures look identical from here - no interface - and they have nothing
    # to do with each other. Saying "expired cookie" to someone whose login the
    # gateway accepted sends them to repeat a browser step that was never the
    # problem, which is the defect the removed SAML helpers had.
    if grep -qiE 'matching client config not found|getconfig\.esp' "$log" 2>/dev/null; then
      echo "ERROR: the gateway accepted the login and then published no client" >&2
      echo "       configuration for os=${client_os}." >&2
      echo "       The credential was fine: authentication-source appears above." >&2
      echo "       The portal serves configs per OS, so try one it knows:" >&2
      echo "         vpn connect --sso        and answer 'win' when it asks for os" >&2
      echo "       From your own machine, the host helper takes it as an override:" >&2
      echo "         VPN_SSO_CLIENTOS=Windows scripts/vpn-sso-login.sh <container>" >&2
    else
      echo "ERROR: the gateway refused the credential, or it had already expired." >&2
      echo "       These cookies live for seconds, not minutes. Run 'vpn connect --sso'" >&2
      echo "       again and do the browser step without pausing." >&2
    fi
    rm -f "$log"
    return 1
  }
  rm -f "$log"
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
  local line key value host="" user="" cookie="" server="" usergroup="" os=""
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
      # The tool reports the OS it carried out the exchange as, already in
      # openconnect's vocabulary rather than its own --clientos one. Passing it on
      # is what keeps the two halves agreeing; discarding it, as this did, is how a
      # Linux exchange ended up asking a Windows-only portal for a config.
      OS)     os="$value" ;;
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
  # Only when the tool said so. An empty line here would override the declared
  # default with nothing, which is worse than not sending the value at all.
  [[ -n "$os" ]] && printf 'os=%s\n' "$os"
  return 0
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
  # --clientos picks which client configuration the portal will be asked for, and
  # a portal hands out none for an OS it does not publish. Default Linux, since
  # that is what the container runs; VPN_SSO_CLIENTOS=Windows is the way out when
  # the portal only knows Windows clients, as the Lear one does.
  local clientos="${VPN_SSO_CLIENTOS:-Linux}"
  case "$clientos" in
    Windows|Mac|Linux) ;;
    *) echo "ERROR: VPN_SSO_CLIENTOS must be Windows, Mac or Linux (got: ${clientos})." >&2
       return 1 ;;
  esac

  out="$(gp-saml-gui -K --clientos "$clientos" -g "$GATEWAY" 2>/dev/null)" || {
    echo "ERROR: the SAML exchange did not complete." >&2
    echo "       The login window was closed, or the portal refused it. Nothing has" >&2
    echo "       been sent to the gateway." >&2
    return 1
  }
  printf '%s\n' "$out" | proto_sso_host_parse
}
