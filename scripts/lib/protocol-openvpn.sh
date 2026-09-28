# shellcheck shell=bash
# OpenVPN client using a server-exported .ovpn profile.

# PROTO_NAME must match this file's name suffix; the orchestrator verifies it.
PROTO_NAME="openvpn"
# PROTO_DESC is listed by the orchestrator's --help, which reads it with sed
# instead of sourcing this file - hence no in-file reference.
# shellcheck disable=SC2034
PROTO_DESC="OpenVPN (.ovpn profile)"

# proto_validate_args: runs on the host before any lxc call, so the profile is
# checked while the path still means something - once inside the container the
# host path is gone.
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

# openconnect is unrelated to this protocol - always 0.
proto_needs_build_openconnect() { echo 0; }

proto_apt_packages() { echo "openvpn"; }

# Process name(s) `vpn connect` refuses to start over and `vpn disconnect` stops.
proto_client_processes() { echo "openvpn"; }

# Absolute paths a non-root --user container may run under sudo for this
# protocol. Add any wrapper the snippets invoke with sudo as well.
proto_sudo_commands() { echo "/usr/sbin/openvpn"; }

# VPN_OVPN is the path INSIDE the container, which is where the container's `vpn` command runs;
# the host-side --ovpn path is only used by proto_post_install below.
proto_write_env_extra() {
  env_kv VPN_OVPN /etc/openvpn/client/client.ovpn
  # Written ONLY when the operator asked for it. An absent key is what lets
  # VPN_TUNNEL_MODE decide - see the derivation in tunnel_mode. Writing a default
  # here, as this used to, made the override always present and therefore always
  # winning, so the declared mode could never take effect.
  if [[ -n "${ROUTE_NOPULL:-}" ]]; then
    env_kv VPN_ROUTE_NOPULL "$ROUTE_NOPULL"
  fi
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

  # A .ovpn profile may either embed its certs inline (<ca>...</ca>, nothing to
  # do here) or reference them as sibling files. Scan the directives that carry
  # a filename and push each one alongside the profile, so the container ends up
  # self-contained.
  #
  # Deliberately narrow: only RELATIVE paths that exist next to the profile are
  # copied. An absolute path is left alone - it refers to a location on the host
  # that the profile author chose, and silently relocating it into
  # /etc/openvpn/client would change what the config means. Those cases need a
  # manual lxc file push; see docs/lxd-vpn-client-containers.md.
  local ovpn_dir ref
  ovpn_dir="$(cd "$(dirname "$OVPN")" && pwd)"
  while read -r ref; do
    [[ -z "$ref" ]] && continue
    if [[ "$ref" != /* && -f "${ovpn_dir}/${ref}" ]]; then
      echo "    pushing referenced file: $ref"
      lxc file push "${ovpn_dir}/${ref}" "$name/etc/openvpn/client/${ref}" >/dev/null
      # 600: unlike /etc/vpn-client.env, these ARE secrets.
      lxc exec "$name" -- chmod 600 "/etc/openvpn/client/${ref}"
    fi
  done < <(grep -E '^(ca|cert|key|tls-auth|tls-crypt|pkcs12|auth-user-pass) ' "$OVPN" | awk '{print $2}' | sed 's/"//g' || true)
}

proto_connect_snippet() {
  cat <<'EOF'
proto_connect() {
  [[ -f "$VPN_OVPN" ]] || { echo "Missing profile: $VPN_OVPN" >&2; exit 1; }
  echo "Connecting OpenVPN with $VPN_OVPN"
  echo
  EXTRA=()
  # What to do with the routes the server pushes, derived from the declared
  # tunnel mode and from whether the route list was named or is to be detected.
  # The three cases are genuinely different and must not be conflated:
  #
  #   split + auto      the server's subnets are wanted, its default route is not
  #   split + explicit  the operator named what they want; discard the rest
  #   full              accept everything, default route included
  #
  # VPN_ROUTE_NOPULL, when present, is an explicit override and wins: someone who
  # set it deliberately does not get it silently reinterpreted. It is absent in
  # containers created without asking for it, which is what lets the mode decide.
  if [[ -n "${VPN_ROUTE_NOPULL:-}" ]]; then
    # A nested if rather than `[[ ... ]] && EXTRA+=(...)`: written that way the
    # branch's last command fails whenever the value is 0, and this script runs
    # under `set -euo pipefail`. Bash exempts it, but the reader should not have
    # to know that, and this file has been bitten by that class of thing before.
    if [[ "$VPN_ROUTE_NOPULL" == "1" ]]; then
      EXTRA+=(--route-nopull)
    fi
  elif [[ "$(tunnel_mode)" == "full" ]]; then
    : # accept every pushed route, default included
  elif [[ -z "$VPN_ROUTES" || "$VPN_ROUTES" == "auto" ]]; then
    # Accept the subnets, refuse the default route. Filtered two ways because a
    # server can express the same intent either way, and a split tunnel that
    # depends on which one the far end happens to use is not a promise.
    EXTRA+=(--pull-filter ignore "redirect-gateway")
    EXTRA+=(--pull-filter ignore "route 0.0.0.0")
  else
    EXTRA+=(--route-nopull)
  fi
  # --daemon detaches, so authentication failures surface as a missing tun0
  # rather than a non-zero exit - hence the log dump in the error path below.
  sudo openvpn \
    --config "$VPN_OVPN" \
    --daemon openvpn-client \
    --writepid /run/openvpn-client.pid \
    --log /var/log/openvpn-client.log \
    "${EXTRA[@]}"
  # openvpn names its interface tun0; there is no --interface equivalent in use
  # here, so no fallback name is passed to wait_for_iface.
  VPN_INTERFACE=tun0
  NEW_IFACE="$(wait_for_iface "$VPN_INTERFACE")" || {
    echo "ERROR: tun0 did not appear. Last log lines:" >&2
    sudo tail -n 40 /var/log/openvpn-client.log 2>/dev/null || true
    exit 1
  }
  VPN_INTERFACE="$NEW_IFACE"
}
EOF
}

proto_version_cmd() { echo "openvpn --version 2>/dev/null | head -1"; }
