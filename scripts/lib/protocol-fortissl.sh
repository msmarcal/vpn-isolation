# lib/protocol-fortissl.sh
# FortiGate SSL VPN via openfortivpn (open-source client).
PROTO_NAME="fortissl"
PROTO_DESC="FortiGate SSL VPN (openfortivpn)"

proto_validate_args() {
  if [[ -z "$GATEWAY" ]]; then
    echo "ERROR: --gateway is required for protocol=${PROTO_NAME}" >&2
    exit 1
  fi
}

proto_needs_build_openconnect() { echo 0; }

proto_apt_packages() { echo "openfortivpn screen"; }

proto_write_env_extra() {
  cat <<EOF
VPN_GATEWAY=${GATEWAY}
VPN_FORTI_USER=${FORTI_USER:-}
VPN_FORTI_PORT=${FORTI_PORT:-443}
# Set to any non-empty value if the gateway requires OTP/2FA. connect-vpn then
# prompts for the token and passes it to openfortivpn as --otp. Left empty on
# creation because there is no way to probe the gateway for this beforehand.
VPN_FORTI_OTP_REQUIRED=
EOF
}

# proto_write_env_interface: override the default VPN_INTERFACE for this protocol.
# PPP interfaces are always named ppp0, ppp1, etc by the kernel - we don't control
# the name (and --ifname is broken in containers anyway).
proto_write_env_interface() { echo "ppp0"; }

# openfortivpn notes:
# - Credentials are collected by connect-vpn itself (read -s), never stored in
#   /etc/vpn-client.env or on disk - they only ever live in the process
#   environment for the lifetime of the connection.
# - Does not daemonize natively and needs a TTY, so it runs inside a detached
#   `screen` session. That is what keeps the tunnel up after connect-vpn exits;
#   it also means openfortivpn can no longer prompt for anything itself, which
#   is why the password and OTP are prompted up front and handed over as
#   --password / --otp arguments.
# - OTP/2FA is therefore NOT auto-detected: set VPN_FORTI_OTP_REQUIRED in
#   /etc/vpn-client.env to make connect-vpn prompt for a token. Without it, a
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
    echo "       Run with: lxc exec -t <container> -- connect-vpn" >&2
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
  local i
  NEW_IFACE=""
  for i in $(seq 1 60); do
    NEW_IFACE="$(ip -o link show | awk -F': ' '{print $2}' | grep '^ppp' | head -1)"
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
  apply_split_routes "$VPN_ROUTES" "$VPN_INTERFACE"
  
  echo "FortiSSL VPN connected on ${VPN_INTERFACE}."
  echo "Screen session: sudo screen -r vpn-session"
  echo "Logs: sudo tail -f /var/log/openfortivpn.log"
}
EOF
}

proto_version_cmd() { echo "openfortivpn --version 2>&1 | head -1"; }

# Optional orchestrator-side hook for any extra setup. Not needed for FortiSSL
# (no profile files to push like OpenVPN does), but defined here for reference.
# proto_post_install() {
#   local name="$1"
#   # nothing to do
# }
