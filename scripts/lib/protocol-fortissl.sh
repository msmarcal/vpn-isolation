# shellcheck shell=bash
# FortiGate SSL VPN via openfortivpn (open-source client).

# PROTO_NAME must match this file's name suffix; the orchestrator verifies it.
PROTO_NAME="fortissl"
# PROTO_DESC is listed by the orchestrator's --help, which reads it with sed
# instead of sourcing this file - hence no in-file reference.
# shellcheck disable=SC2034
PROTO_DESC="FortiGate SSL VPN (openfortivpn)"

proto_validate_args() {
  if [[ -z "$GATEWAY" ]]; then
    echo "ERROR: --gateway is required for protocol=${PROTO_NAME}" >&2
    exit 1
  fi
}

proto_needs_build_openconnect() { echo 0; }

proto_apt_packages() { echo "openfortivpn screen"; }

# Process name(s) `vpn connect` refuses to start over and `vpn disconnect` stops.
proto_client_processes() { echo "openfortivpn"; }

# Absolute paths a non-root --user container may run under sudo for this
# protocol. Add any wrapper the snippets invoke with sudo as well.
proto_sudo_commands() { echo "/usr/bin/openfortivpn /usr/bin/screen"; }

proto_write_env_extra() {
  # env_kv (defined in common.sh) shell-quotes each value, so a username
  # like o'brien does not break `source` in the container's `vpn` command.
  env_kv VPN_GATEWAY "$GATEWAY"
  env_kv VPN_FORTI_USER "${FORTI_USER:-}"
  env_kv VPN_FORTI_PORT "${FORTI_PORT:-443}"
  cat <<'EOF'
# Set to any non-empty value if the gateway requires OTP/2FA. `vpn connect` then
# prompts for the token and passes it to openfortivpn as --otp. Left empty on
# creation because there is no way to probe the gateway for this beforehand.
EOF
  env_kv VPN_FORTI_OTP_REQUIRED ""
}

# proto_write_env_interface: override the default VPN_INTERFACE for this protocol.
# PPP interfaces are always named ppp0, ppp1, etc by the kernel - we don't control
# the name (and --ifname is broken in containers anyway).
proto_write_env_interface() { echo "ppp0"; }

# openfortivpn notes:
# - Credentials are collected by `vpn connect` itself (read -s), never stored in
#   /etc/vpn-client.env or on disk - they only ever live in the process
#   environment for the lifetime of the connection.
# - Does not daemonize natively and needs a TTY, so it runs inside a detached
#   `screen` session. That is what keeps the tunnel up after the connect exits;
#   it also means openfortivpn can no longer prompt for anything itself, which
#   is why the password and OTP are prompted up front and handed over as
#   --password / --otp arguments.
# - OTP/2FA is therefore NOT auto-detected: set VPN_FORTI_OTP_REQUIRED in
#   /etc/vpn-client.env to make `vpn connect` prompt for a token. Without it, a
#   gateway that demands 2FA just fails to bring up the interface.
# - Do NOT use --ifname: in LXD containers it fails with ENODEV (error 19)
#   when trying to rename the PPP interface. The kernel always names PPP
#   interfaces ppp0, ppp1, etc - we just wait for whatever appears.
proto_connect_snippet() {
  cat <<'EOF'
proto_connect() {
  [[ -n "$VPN_GATEWAY" ]] || { echo "VPN_GATEWAY empty" >&2; exit 1; }
  
  # Require TTY - openfortivpn needs interactive password entry
  if [[ ! -t 0 ]]; then
    echo "ERROR: openfortivpn requires interactive password entry (TTY)." >&2
    echo "       Run with: lxc exec -t <container> -- vpn connect" >&2
    exit 1
  fi
  
  echo "Connecting FortiSSL VPN to ${VPN_GATEWAY}:${VPN_FORTI_PORT:-443}"
  
  # Prompt for password BEFORE starting screen session
  if [[ -n "$VPN_FORTI_USER" ]]; then
    read -s -p "VPN password for ${VPN_FORTI_USER}: " VPN_PASSWORD
    echo
  else
    read -s -p "VPN password: " VPN_PASSWORD
    echo
  fi
  
  # If OTP is configured, prompt for it too
  VPN_OTP="${VPN_FORTI_OTP:-}"
  if [[ -n "${VPN_FORTI_OTP_REQUIRED:-}" ]]; then
    read -p "OTP/2FA token: " VPN_OTP
  fi
  
  FORTI_ARGS=(
    "${VPN_GATEWAY}:${VPN_FORTI_PORT:-443}"
    --username="${VPN_FORTI_USER:-$USER}"
    --password="${VPN_PASSWORD}"
  )
  
  # Add OTP if provided
  [[ -n "$VPN_OTP" ]] && FORTI_ARGS+=(--otp="${VPN_OTP}")
  
  # Use screen to maintain persistent session (openfortivpn requires TTY)
  # -dmS: detached, create new session with name
  # -L: enable logging to screenlog.0
  sudo screen -dmS vpn-session -L -Logfile /var/log/openfortivpn.log \
    openfortivpn "${FORTI_ARGS[@]}"
  
  echo "openfortivpn started in screen session, waiting for interface..."
  
  # Wait for any PPP interface to appear (kernel assigns ppp0, ppp1, etc)
  #
  # The `|| NEW_IFACE=""` is load-bearing. `grep` exits 1 while no ppp interface
  # exists yet, which is every iteration until the tunnel comes up; under
  # `set -euo pipefail` that status propagated through the assignment and killed
  # the whole connect on the FIRST iteration. The tunnel still came up, because
  # openfortivpn runs under detached screen and survives - so the visible symptom
  # was a working tunnel with none of VPN_ROUTES applied and no connection
  # recorded, which looks like anything but a dead script.
  local i
  NEW_IFACE=""
  for i in $(seq 1 "${VPN_PPP_WAIT:-60}"); do
    NEW_IFACE="$(ip -o link show | awk -F': ' '{print $2}' | grep '^ppp' | head -1)" || NEW_IFACE=""
    [[ -n "$NEW_IFACE" ]] && break
    sleep 1
  done
  
  if [[ -z "$NEW_IFACE" ]]; then
    echo "ERROR: PPP interface did not appear (auth failed?). Last log lines:" >&2
    sudo tail -n 30 /var/log/openfortivpn.log >&2 || true
    sudo screen -S vpn-session -X quit 2>/dev/null || true
    exit 1
  fi
  
  VPN_INTERFACE="$NEW_IFACE"

  echo "FortiSSL VPN connected on ${VPN_INTERFACE}."
  echo "Screen session: sudo screen -r vpn-session"
  echo "Logs: sudo tail -f /var/log/openfortivpn.log"
}
EOF
}

# ---------------------------------------------------------------------------
# SSO
#
# FortiGate portals can be fronted by SAML too. openfortivpn cannot do that
# exchange, but it accepts the session cookie the gateway sets once a browser has
# finished it - `--cookie-on-stdin`, which is also the only form that keeps the
# credential out of the process table.
#
# Unlike the openconnect protocols there is no unauthenticated request that yields
# a login URL, so the URL here is the portal itself.
# ---------------------------------------------------------------------------

proto_sso_values() {
  printf 'cookie|secret||SVPNCOOKIE value from the browser\n'
}

# Nothing. The SSO path runs only openfortivpn, which proto_sudo_commands already
# allows. Deliberately NOT granting a shell or setsid: `sudo bash` and
# `sudo setsid <anything>` are both a root shell, which would undo the point of
# having a narrow allowlist at all.
proto_sso_sudo_commands() { echo ""; }

proto_sso_url_snippet() {
  cat <<'EOF'
proto_sso_url() {
  [[ -n "$VPN_GATEWAY" ]] || { echo "VPN_GATEWAY empty" >&2; return 1; }
  cat <<TEXT

Open this in a browser on your own machine, NOT in this container:

  https://${VPN_GATEWAY}:${VPN_FORTI_PORT:-443}/remote/login

Sign in, approve the second factor, then read the SVPNCOOKIE cookie the gateway
set, from the browser's cookie inspector. It is short-lived, so do this without
pausing.
TEXT
  return 0
}
EOF
}

proto_sso_connect_snippet() {
  cat <<'EOF'
proto_sso_connect() {
  echo
  echo "Completing SAML login to ${VPN_GATEWAY}:${VPN_FORTI_PORT:-443}"

  # The cookie goes in on standard input, through a FIFO. Not as an argument,
  # which the process table shows; not through the environment, which /proc shows
  # to anything running as the same user. The FIFO is 0600 and removed as soon as
  # it has been read.
  #
  # No `screen` here, unlike the native path, and that is the interesting part.
  # Screen exists there because openfortivpn has to prompt for a password and
  # cannot daemonize. This path does not prompt - the credential arrives on stdin -
  # so the client is simply backgrounded with the FIFO as its input. Running it
  # under screen would mean `sudo screen ... bash -c '... < fifo'`, and allowing
  # `sudo bash` is a root shell: it would undo the narrow allowlist entirely.
  #
  # The risk this leaves, and it cannot be settled without the real gateway: if
  # openfortivpn insists on a tty even with the cookie on stdin, this fails with
  # the interface never appearing, and the error path below says so.
  local fifo
  fifo="$(mktemp -u "${TMPDIR:-/tmp}/.vpn-sso.XXXXXX")"
  mkfifo -m 600 "$fifo" || { echo "ERROR: could not create a pipe for the cookie." >&2; return 1; }

  # Backgrounded, so its exit status cannot abort this function; the interface
  # appearing is the verdict, the same as on the other protocols' SSO paths.
  sudo openfortivpn "${VPN_GATEWAY}:${VPN_FORTI_PORT:-443}" --cookie-on-stdin \
    < "$fifo" >> /var/log/openfortivpn.log 2>&1 &
  disown

  printf '%s' "$SSO_cookie" > "$fifo"
  rm -f "$fifo"

  echo "openfortivpn started in screen session, waiting for interface..."

  local i new_iface=""
  for i in $(seq 1 "${VPN_PPP_WAIT:-60}"); do
    new_iface="$(ip -o link show | awk -F': ' '{print $2}' | grep '^ppp' | head -1)" || new_iface=""
    [[ -n "$new_iface" ]] && break
    sleep 1
  done

  if [[ -z "$new_iface" ]]; then
    echo "ERROR: the gateway refused the cookie, or it had already expired." >&2
    echo "       These live for seconds. Run 'vpn connect --sso' again and do the" >&2
    echo "       browser step without pausing. Last log lines:" >&2
    sudo tail -n 20 /var/log/openfortivpn.log >&2 || true
    return 1
  fi
  VPN_INTERFACE="$new_iface"
}
EOF
}

proto_version_cmd() { echo "openfortivpn --version 2>&1 | head -1"; }

# proto_disconnect_snippet: the generic teardown (stop_client on each process)
# is not enough here, because openfortivpn runs inside a screen session that
# has to be closed too - and only AFTER the client is gone.
proto_disconnect_snippet() {
  cat <<'EOF'
proto_disconnect() {
  # SIGTERM first and wait, so openfortivpn logs out of the gateway and
  # releases /dev/ppp itself. Closing the screen session while it is still
  # tearing down, or force-killing it, can leave /dev/ppp unusable ("Could not
  # set tty to PPP discipline") until the container is restarted.
  if ! stop_client openfortivpn 15; then
    echo "If the next connect fails with a PPP discipline error, run: lxc restart <container>" >&2
  fi
  sudo screen -S vpn-session -X quit 2>/dev/null || true
}
EOF
}

# Optional orchestrator-side hook for any extra setup. Not needed for FortiSSL
# (no profile files to push like OpenVPN does), but defined here for reference.
# proto_post_install() {
#   local name="$1"
#   # nothing to do
# }
