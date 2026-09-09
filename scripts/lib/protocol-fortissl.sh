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

proto_apt_packages() { echo "openfortivpn"; }

proto_write_env_extra() {
  cat <<EOF
VPN_GATEWAY=${GATEWAY}
VPN_FORTI_USER=${FORTI_USER:-}
VPN_FORTI_PORT=${FORTI_PORT:-443}
EOF
}

# proto_write_env_interface: override the default VPN_INTERFACE for this protocol.
# PPP interfaces are always named ppp0, ppp1, etc by the kernel - we don't control
# the name (and --ifname is broken in containers anyway).
proto_write_env_interface() { echo "ppp0"; }

# openfortivpn notes:
# - Prompts for password interactively by default (no good way around it without
#   storing plaintext password in env or on disk, which violates the security
#   model of this framework - credentials should be ephemeral/interactive).
# - Does not daemonize natively; using nohup + background (&) is the cleanest
#   workaround that keeps the VPN running after connect-vpn exits.
# - Do NOT use --ifname: in LXD containers it fails with ENODEV (error 19)
#   when trying to rename the PPP interface. The kernel always names PPP
#   interfaces ppp0, ppp1, etc - we just wait for whatever appears.
# - OTP/2FA: if the gateway requires it, openfortivpn prompts for it after the
#   password prompt (completely interactive, can't pre-populate).
proto_connect_snippet() {
  cat <<'EOF'
proto_connect() {
  [[ -n "$VPN_GATEWAY" ]] || { echo "VPN_GATEWAY empty" >&2; exit 1; }
  
  # Require TTY - openfortivpn prompts for password interactively
  if [[ ! -t 0 ]]; then
    echo "ERROR: openfortivpn requires interactive password entry (TTY)." >&2
    echo "       Run with: lxc exec -t <container> -- connect-vpn" >&2
    exit 1
  fi
  
  echo "Connecting FortiSSL VPN to ${VPN_GATEWAY}:${VPN_FORTI_PORT:-443}"
  echo "Password (and OTP/2FA if required) will be prompted interactively."
  echo
  
  FORTI_ARGS=(
    "${VPN_GATEWAY}:${VPN_FORTI_PORT:-443}"
  )
  
  [[ -n "$VPN_FORTI_USER" ]] && FORTI_ARGS+=(--username="$VPN_FORTI_USER")
  
  # Run in background via nohup (openfortivpn doesn't have native daemon mode)
  # Note: password prompt goes to stderr, so redirect stderr to the log too
  sudo nohup openfortivpn "${FORTI_ARGS[@]}" \
    > /var/log/openfortivpn.log 2>&1 &
  
  FORTI_PID=$!
  echo "openfortivpn started (PID $FORTI_PID), waiting for interface..."
  
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
    sudo kill "$FORTI_PID" 2>/dev/null || true
    exit 1
  fi
  
  VPN_INTERFACE="$NEW_IFACE"
  apply_split_routes "$VPN_ROUTES" "$VPN_INTERFACE"
  
  echo "FortiSSL VPN connected on ${VPN_INTERFACE}. openfortivpn running in background (PID $FORTI_PID)."
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
