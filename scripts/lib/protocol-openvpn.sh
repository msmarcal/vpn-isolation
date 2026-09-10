# shellcheck shell=bash
# OpenVPN client using a server-exported .ovpn profile.

# PROTO_NAME must match this file's name suffix; the orchestrator verifies it.
PROTO_NAME="openvpn"
# PROTO_DESC is listed by the orchestrator's --help, which reads it with sed
# instead of sourcing this file - hence no in-file reference.
# shellcheck disable=SC2034
PROTO_DESC="OpenVPN (.ovpn profile)"

proto_validate_args() {
  if [[ -z "$OVPN" ]]; then
    echo "ERROR: --ovpn is required for protocol=${PROTO_NAME}" >&2
    exit 1
  fi
  if [[ ! -f "$OVPN" ]]; then
    echo "ERROR: ovpn file not found: $OVPN" >&2
    exit 1
  fi
}

proto_needs_build_openconnect() { echo 0; }

proto_apt_packages() { echo "openvpn"; }

proto_write_env_extra() {
  cat <<EOF
VPN_OVPN=/etc/openvpn/client/client.ovpn
VPN_ROUTE_NOPULL=${ROUTE_NOPULL}
EOF
}

# proto_post_install: orchestrator-side hook (runs on the host, not inside
# the container) for any protocol-specific file staging. Optional - only
# openvpn needs this to push the .ovpn profile and its referenced siblings.
proto_post_install() {
  local name="$1"
  echo "==> Installing OpenVPN profile"
  lxc exec "$name" -- mkdir -p /etc/openvpn/client
  lxc file push "$OVPN" "$name/etc/openvpn/client/client.ovpn" >/dev/null
  lxc exec "$name" -- chmod 600 /etc/openvpn/client/client.ovpn

  local ovpn_dir ref
  ovpn_dir="$(cd "$(dirname "$OVPN")" && pwd)"
  while read -r ref; do
    [[ -z "$ref" ]] && continue
    if [[ "$ref" != /* && -f "${ovpn_dir}/${ref}" ]]; then
      echo "    pushing referenced file: $ref"
      lxc file push "${ovpn_dir}/${ref}" "$name/etc/openvpn/client/${ref}" >/dev/null
      lxc exec "$name" -- chmod 600 "/etc/openvpn/client/${ref}"
    fi
  done < <(grep -E '^(ca|cert|key|tls-auth|tls-crypt|pkcs12|auth-user-pass) ' "$OVPN" | awk '{print $2}' | sed 's/"//g' || true)
}

proto_connect_snippet() {
  cat <<'EOF'
proto_connect() {
  [[ -f "$VPN_OVPN" ]] || { echo "Missing profile: $VPN_OVPN" >&2; exit 1; }
  echo "Connecting OpenVPN with $VPN_OVPN"
  echo "Split routes after connect: ${VPN_ROUTES:-<none>}"
  echo
  EXTRA=()
  if [[ "${VPN_ROUTE_NOPULL:-1}" == "1" ]]; then
    EXTRA+=(--route-nopull)
  fi
  sudo openvpn \
    --config "$VPN_OVPN" \
    --daemon openvpn-client \
    --writepid /run/openvpn-client.pid \
    --log /var/log/openvpn-client.log \
    "${EXTRA[@]}"
  VPN_INTERFACE=tun0
  NEW_IFACE="$(wait_for_iface "$VPN_INTERFACE")" || {
    echo "ERROR: tun0 did not appear. Last log lines:" >&2
    sudo tail -n 40 /var/log/openvpn-client.log 2>/dev/null || true
    exit 1
  }
  VPN_INTERFACE="$NEW_IFACE"
  apply_split_routes "$VPN_ROUTES" "$VPN_INTERFACE"
}
EOF
}

proto_version_cmd() { echo "openvpn --version 2>/dev/null | head -1"; }
