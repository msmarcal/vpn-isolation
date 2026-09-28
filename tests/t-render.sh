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

# runnable PROTO - the rendered command, pointed at a throwaway env file so it
# can be executed. Every client is stubbed, so nothing can bring up a tunnel.
runnable() {
  local out="${TMPD}/vpn.$1"
  printf 'VPN_PROTOCOL=%s\nVPN_ROUTES=10.1.0.0/16\nVPN_INTERFACE=vpn0\nVPN_GATEWAY=vpn.example.com\nVPN_OVPN=/dev/null\n' "$1" > "${TMPD}/env.$1"
  render_for "$1" render_vpn | sed "s#^ENV_FILE=/etc/vpn-client.env#ENV_FILE=${TMPD}/env.$1#" > "$out"
  printf '%s' "$out"
}

for p in "${PROTOCOLS[@]}"; do
  vpn="$(render_for "$p" render_vpn)"
  parses_ok "the vpn command parses ($p)" "$vpn"

  # The bug class this exists for: a generated script that calls a shared helper
  # without carrying its definition fails at runtime, and under
  # `set -euo pipefail` it surfaces as whatever the next `||` branch says.
  for fn in wait_for_iface apply_split_routes detect_split_routes finish_connect record_connection env_kv stop_client; do
    assert_contains "vpn defines ${fn} ($p)" "$vpn" "${fn}() {"
  done
  assert_contains "vpn defines both actions ($p) - connect"    "$vpn" 'do_connect() {'
  assert_contains "vpn defines both actions ($p) - disconnect" "$vpn" 'do_disconnect() {'
  assert_contains "connect hands off to finish_connect ($p)"   "$vpn" 'finish_connect "$VPN_INTERFACE"'
  assert_contains "vpn publishes the client names ($p)"        "$vpn" 'VPN_CLIENT_PROCESSES='
  assert_contains "vpn defines the teardown ($p)"              "$vpn" 'proto_disconnect() {'

  # Nothing the container prints may name a command that no longer exists. The
  # plugin-installed SAML helpers keep their own names, so they are stripped
  # before the check rather than excluded from it.
  stripped="${vpn//connect-vpn-saml-finish/}"
  stripped="${stripped//connect-vpn-saml/}"
  assert_not_contains "never names the replaced connect command ($p)"    "$stripped" 'connect-vpn'
  assert_not_contains "never names the replaced disconnect command ($p)" "$stripped" 'disconnect-vpn'

  # Routing belongs to the framework now, not to the plugin.
  snippet="$( ( source "${LIB_DIR}/protocol-$p.sh"; proto_connect_snippet ) )"
  parses_ok "proto_connect_snippet parses ($p)" "$snippet"
  assert_not_contains "the snippet does not apply routes ($p)" "$snippet" 'apply_split_routes'
done

# ------------------------------------------------------------------ dispatcher
# The command surface itself: what it accepts, and what it does when asked for
# something else. Exit 2 marks a usage error, distinct from an action that ran
# and failed with 1.
cmd="$(runnable anyconnect)"
run_vpn() { STUB_PGREP_ALIVE="${STUB_ALIVE:-}" bash "$cmd" "$@"; }

out="$(run_vpn --help 2>&1)"; st=$?
assert_eq "--help exits 0" '0' "$st"
assert_contains "usage lists connect"    "$out" 'connect'
assert_contains "usage lists disconnect" "$out" 'disconnect'

out="$(run_vpn 2>&1)"; st=$?
assert_eq "a bare invocation exits 2" '2' "$st"
assert_contains "and prints the usage" "$out" 'Usage: vpn'

out="$(run_vpn frobnicate 2>&1)"; st=$?
assert_eq "an unknown subcommand exits 2" '2' "$st"
assert_contains "and names what was asked for" "$out" 'frobnicate'

# Neither misuse may touch a client. Every client is stubbed, so a call would be
# recorded rather than actually connecting anything.
: > "$STUB_LOG"
run_vpn >/dev/null 2>&1 || true
run_vpn frobnicate >/dev/null 2>&1 || true
assert_not_contains "a usage error starts no client" "$(stub_log)" 'CLIENT'

# The guard refuses to start on top of a live tunnel, and stops before the client.
: > "$STUB_LOG"
out="$(STUB_ALIVE=openconnect run_vpn connect 2>&1)"; st=$?
assert_eq "connect over a live tunnel exits 1" '1' "$st"
assert_contains "and names the new command in the hint" "$out" "vpn disconnect"
assert_not_contains "and starts no second client" "$(stub_log)" 'CLIENT'

# Disconnect runs its teardown and sweeps the interface.
: > "$STUB_LOG"
out="$(STUB_IP_LINKS=vpn0 run_vpn disconnect 2>&1)"; st=$?
assert_eq "disconnect exits 0" '0' "$st"
assert_contains "and reports the tunnel down" "$out" 'VPN down.'
assert_contains "and deletes the interface"   "$(stub_log)" 'ip link delete vpn0'

# These dispatcher assertions must not pass against a script with no dispatcher,
# or they are testing nothing. The pre-change shape is reconstructed by stripping
# the dispatcher out.
sed '/^case "${1:-}" in$/,$d' "$cmd" > "${TMPD}/nodispatch"
if bash "${TMPD}/nodispatch" frobnicate >/dev/null 2>&1; then
  # No dispatcher means arguments are ignored and the script exits 0. That is
  # what makes the exit-2 assertions above evidence of the dispatcher working,
  # rather than of nothing in particular.
  pass
else
  fail "the dispatcher assertions are meaningful" \
       "a script with the dispatcher stripped out also rejected the subcommand," \
       "so exiting 2 above proves nothing about the dispatcher"
fi

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
assert_contains "install_helpers pushes the vpn command" "$log" '/usr/local/bin/vpn'
assert_contains "install_helpers pushes the tmpfiles rule" "$log" '/vpn-client.conf'

# Refreshing must replace the surface, not add to it: the commands the single one
# replaced are deleted, and a path that is already gone is the ordinary case.
for f in connect-vpn disconnect-vpn; do
  assert_contains "install_helpers deletes ${f}" "$log" "file delete testctr/usr/local/bin/${f}"
done
if ( source "${LIB_DIR}/common.sh"; source "${LIB_DIR}/orchestrator.sh"
     PROTOCOL=anyconnect; source "${LIB_DIR}/protocol-anyconnect.sh"
     set -euo pipefail; install_helpers testctr vpnuser ) >/dev/null 2>&1; then pass
else fail "a missing path must not fail the install" "it aborted"; fi

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

# A plugin-installed command must not tell the operator to run something that was
# removed either. Its own name is stripped first, as above.
for f in connect-vpn-saml connect-vpn-saml-finish; do
  t="$(cat "${STUB_PUSH_DIR}/${f}" 2>/dev/null || true)"
  t="${t//connect-vpn-saml-finish/}"; t="${t//connect-vpn-saml/}"
  assert_not_contains "${f} names no replaced command" "$t" 'connect-vpn'
  assert_not_contains "${f} names no replaced disconnect" "$t" 'disconnect-vpn'
done

# Same ownership and mode the framework's own helpers get, and no `lxc exec`:
# without that, refreshing a stopped gp container aborted under set -e.
assert_contains "SAML helpers pushed as root:root 0755" "$(stub_log)" '--uid 0 --gid 0 --mode 0755'
assert_not_contains "proto_post_install never runs lxc exec" "$(stub_log)" 'lxc exec'

finish
