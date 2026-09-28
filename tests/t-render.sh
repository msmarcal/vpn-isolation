#!/usr/bin/env bash
# The generated container scripts. They are strings on the host, so a syntax
# error in one survives bash -n and shellcheck and only surfaces on a real
# connect - which is why every one of them gets parsed here.
# Sources are resolved at runtime from REPO_ROOT, which is what lets the suite
# run from anywhere; shellcheck cannot follow that and does not need to.
# The render_* functions read PROTOCOL, ROUTES, VPN_IFACE and GATEWAY as globals,
# and the asserts match literal text containing $-expressions.
# shellcheck disable=SC1090,SC1091,SC2034,SC2016
set -uo pipefail
source "$(dirname "$0")/lib.sh"
source "${LIB_DIR}/common.sh"
source "${LIB_DIR}/orchestrator.sh"
use_stubs

PROTOCOLS=(anyconnect gp openvpn fortissl)

# render_for PROTO FUNC - render in a subshell so each plugin's definitions
# cannot leak into the next.
render_for() {
  ( source "${LIB_DIR}/common.sh"
    source "${LIB_DIR}/orchestrator.sh"
    PROTOCOL="$1"
    source "${LIB_DIR}/protocol-$1.sh"
    "$2" )
}

for p in "${PROTOCOLS[@]}"; do
  connect="$(render_for "$p" render_connect_vpn)"
  disconnect="$(render_for "$p" render_disconnect_vpn)"
  parses_ok "connect-vpn parses ($p)"    "$connect"
  parses_ok "disconnect-vpn parses ($p)" "$disconnect"

  # The bug class this exists for: a generated script that calls a shared helper
  # without carrying its definition fails at runtime, and under
  # `set -euo pipefail` it surfaces as whatever the next `||` branch says.
  for fn in wait_for_iface apply_split_routes detect_split_routes finish_connect record_connection env_kv; do
    assert_contains "connect-vpn defines ${fn} ($p)" "$connect" "${fn}() {"
  done
  assert_contains "connect-vpn hands off to finish_connect ($p)" "$connect" 'finish_connect "$VPN_INTERFACE"'
  assert_contains "connect-vpn publishes the client names ($p)"  "$connect" 'VPN_CLIENT_PROCESSES='
  assert_contains "disconnect-vpn defines stop_client ($p)"      "$disconnect" 'stop_client() {'

  # Routing belongs to the framework now, not to the plugin.
  snippet="$( ( source "${LIB_DIR}/protocol-$p.sh"; proto_connect_snippet ) )"
  parses_ok "proto_connect_snippet parses ($p)" "$snippet"
  assert_not_contains "the snippet does not apply routes ($p)" "$snippet" 'apply_split_routes'
done

# ------------------------------------------------------------------ env file
out="$( ( source "${LIB_DIR}/common.sh"; source "${LIB_DIR}/orchestrator.sh"
          PROTOCOL=anyconnect ROUTES='10.1.0.0/16' VPN_IFACE=vpn0 GATEWAY="vpn.example.com/it's a group"
          source "${LIB_DIR}/protocol-anyconnect.sh"; render_env_file ) )"
printf '%s\n' "$out" > "${TMPD}/env"
parses_ok "generated env file parses" "$out"
assert_eq "a gateway with a quote survives" "vpn.example.com/it's a group" \
  "$( set +u; source "${TMPD}/env"; printf '%s' "$VPN_GATEWAY" )"

# ------------------------------------------------------------------ sudoers
sud="$( ( source "${LIB_DIR}/protocol-anyconnect.sh"
          source "${LIB_DIR}/common.sh"; source "${LIB_DIR}/orchestrator.sh"
          render_sudoers vpnuser ) )"
assert_contains "sudoers names the user"   "$sud" 'vpnuser ALL=(root) NOPASSWD:'
assert_contains "sudoers grants ip"        "$sud" '/usr/sbin/ip'
assert_not_contains "sudoers never grants tail" "$sud" 'tail'

# ------------------------------------------------------------ state directory
tf="$(render_state_tmpfiles vpnuser)"
assert_contains "tmpfiles rule owns the dir to the login user" "$tf" 'd /run/vpn-client 0755 vpnuser vpnuser'

# install_helpers must not need a running container: `lxc file push` works on a
# stopped one, `lxc exec` does not. Creating the runtime directory is a separate
# step precisely because on the creation path the login user does not exist yet.
: > "$STUB_LOG"
( source "${LIB_DIR}/common.sh"; source "${LIB_DIR}/orchestrator.sh"
  PROTOCOL=anyconnect; source "${LIB_DIR}/protocol-anyconnect.sh"
  install_helpers testctr vpnuser ) >/dev/null 2>&1
log="$(stub_log)"
assert_not_contains "install_helpers never runs lxc exec" "$log" 'lxc exec'
for f in connect-vpn disconnect-vpn vpn-client.conf; do
  assert_contains "install_helpers pushes ${f}" "$log" "/${f}"
done

# ---------------------------------------------- plugin-installed extra helpers
# protocol-gp.sh generates two more container scripts. install_helpers does not
# parse-check those, so they are checked here: this is where a helper that
# called functions it never carried went unnoticed.
: > "$STUB_LOG"; rm -f "${STUB_PUSH_DIR:?}"/*
( source "${LIB_DIR}/common.sh"; source "${LIB_DIR}/orchestrator.sh"
  PROTOCOL=gp; source "${LIB_DIR}/protocol-gp.sh"
  proto_post_install testctr ) >/dev/null 2>&1

for f in connect-vpn-saml connect-vpn-saml-finish; do
  if [[ -f "${STUB_PUSH_DIR}/${f}" ]]; then
    pass
    parses_ok "${f} parses" "$(cat "${STUB_PUSH_DIR}/${f}")"
  else
    fail "proto_post_install pushes ${f}" "not found in the push capture"
  fi
done

fin="$(cat "${STUB_PUSH_DIR}/connect-vpn-saml-finish" 2>/dev/null || true)"
for fn in wait_for_iface finish_connect apply_split_routes; do
  assert_contains "connect-vpn-saml-finish defines ${fn}" "$fin" "${fn}() {"
done
assert_contains "connect-vpn-saml-finish delegates to finish_connect" "$fin" 'finish_connect "$VPN_INTERFACE"'
assert_contains "and publishes the client names" "$fin" 'VPN_CLIENT_PROCESSES='

# Same ownership and mode the framework's own helpers get, and no `lxc exec`:
# without that, refreshing a stopped gp container aborted under set -e.
assert_contains "SAML helpers pushed as root:root 0755" "$(stub_log)" '--uid 0 --gid 0 --mode 0755'
assert_not_contains "proto_post_install never runs lxc exec" "$(stub_log)" 'lxc exec'

finish
