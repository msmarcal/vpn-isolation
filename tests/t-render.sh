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

for p in "${PROTOCOLS[@]}"; do
  vpn="$(render_for "$p" render_vpn)"
  parses_ok "the vpn command parses ($p)" "$vpn"

  # The bug class this exists for: a generated script that calls a shared helper
  # without carrying its definition fails at runtime, and under
  # `set -euo pipefail` it surfaces as whatever the next `||` branch says.
  for fn in wait_for_iface wait_for_iface_up apply_split_routes detect_split_routes finish_connect record_connection env_kv stop_client tunnel_mode state_get state_client_alive tunnel_state status_iface status_missing_routes default_route_verdict resolv_fingerprint; do
    assert_contains "vpn defines ${fn} ($p)" "$vpn" "${fn}() {"
  done
  assert_contains "vpn defines the actions ($p) - connect"    "$vpn" 'do_connect() {'
  assert_contains "vpn defines the actions ($p) - disconnect" "$vpn" 'do_disconnect() {'
  assert_contains "vpn defines the actions ($p) - status"     "$vpn" 'do_status() {'
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

# --------------------------------------------- fortissl's wait for a PPP link
# This loop aborted the whole connect on its first iteration: `grep` exits 1
# while no ppp interface exists yet, and under `set -euo pipefail` that status
# came out through the assignment. The tunnel still came up, because the client
# runs under detached screen, so the symptom was a working tunnel with no routes
# applied and nothing recorded - which looks like anything but a dead script.
#
# The surrounding proto_connect cannot run here: it requires a terminal for the
# password prompt. So the loop is lifted out of the real snippet text, wrapped in
# a function so its `local` is valid, and run on its own.
forti="$( ( source "${LIB_DIR}/protocol-fortissl.sh"; proto_connect_snippet ) )"

# The loop is lifted out of the real snippet text and wrapped in a function so
# its `local` is valid, then run on its own. The surrounding proto_connect cannot
# run here: it needs a terminal for the password prompt.
POLL="$( { printf 'poll() {\n'
           printf '%s\n' "$forti" | sed -n '/^  local i$/,/^  done$/p'
           printf '  printf "%%s" "$NEW_IFACE"\n}\n'; } )"
POLL_NOGUARD="$(printf '%s\n' "$POLL" | sed 's/ || NEW_IFACE=""//')"
export POLL POLL_NOGUARD

assert_survives "no ppp link yet must not abort the connect" '
  export STUB_IP_LINKS=lo,eth0 VPN_PPP_WAIT=2
  eval "$POLL"
  poll'

# And prove that is not passing for some other reason: the same loop with the
# guard stripped out must abort.
assert_aborts "the guard is what makes that survive" '
  export STUB_IP_LINKS=lo,eth0 VPN_PPP_WAIT=2
  eval "$POLL_NOGUARD"
  poll'

# It must also find the interface once one appears.
got="$( ( export STUB_IP_LINKS=lo,eth0,ppp0 VPN_PPP_WAIT=2
          eval "$POLL"
          poll ) )"
assert_eq "the poll finds the interface once it appears" 'ppp0' "$got"

assert_contains "the poll tolerates the empty case explicitly" "$forti" '|| NEW_IFACE=""'

# ------------------------------------------------------------------ env file
out="$( ( source "${LIB_DIR}/common.sh"; source "${LIB_DIR}/orchestrator.sh"
          PROTOCOL=anyconnect ROUTES='10.1.0.0/16' VPN_IFACE=vpn0 GATEWAY="vpn.example.com/it's a group"
          source "${LIB_DIR}/protocol-anyconnect.sh"; render_env_file ) )"
printf '%s\n' "$out" > "${TMPD}/env"
parses_ok "generated env file parses" "$out"
assert_contains "env file declares the tunnel mode" "$out" "VPN_TUNNEL_MODE="
assert_eq "a gateway with a quote survives" "vpn.example.com/it's a group" \
  "$( set +u; source "${TMPD}/env"; printf '%s' "$VPN_GATEWAY" )"

# The declaration is generic, so it must appear for every protocol and not only
# for the one the env-file check above happens to use.
for p in "${PROTOCOLS[@]}"; do
  e="$( ( source "${LIB_DIR}/common.sh"; source "${LIB_DIR}/orchestrator.sh"
          PROTOCOL="$p" ROUTES='10.1.0.0/16' VPN_IFACE=vpn0 TUNNEL_MODE=split
          GATEWAY=vpn.example.com OVPN=/dev/null ROUTE_NOPULL='' FORTI_USER=u FORTI_PORT=443
          source "${LIB_DIR}/protocol-$p.sh"; render_env_file ) )"
  assert_contains "env file declares the mode ($p)" "$e" 'VPN_TUNNEL_MODE=split'
done

# The legacy OpenVPN override is written only when asked for: an absent key is
# what lets the declared mode decide, and writing a default made it always win.
e="$( ( source "${LIB_DIR}/common.sh"; source "${LIB_DIR}/orchestrator.sh"
        PROTOCOL=openvpn ROUTES=auto VPN_IFACE=vpn0 TUNNEL_MODE=split OVPN=/dev/null ROUTE_NOPULL=''
        source "${LIB_DIR}/protocol-openvpn.sh"; render_env_file ) )"
assert_not_contains "no legacy key when it was not requested" "$e" 'VPN_ROUTE_NOPULL'
e="$( ( source "${LIB_DIR}/common.sh"; source "${LIB_DIR}/orchestrator.sh"
        PROTOCOL=openvpn ROUTES=auto VPN_IFACE=vpn0 TUNNEL_MODE=split OVPN=/dev/null ROUTE_NOPULL=1
        source "${LIB_DIR}/protocol-openvpn.sh"; render_env_file ) )"
assert_contains "and the legacy key when it was" "$e" 'VPN_ROUTE_NOPULL=1'

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
assert_survives "a missing path must not fail the install" '
  source "${LIB_DIR}/common.sh"; source "${LIB_DIR}/orchestrator.sh"
  PROTOCOL=anyconnect; source "${LIB_DIR}/protocol-anyconnect.sh"
  install_helpers testctr vpnuser'

# ---------------------------------------------- plugin-installed extra helpers
# protocol-gp.sh used to generate two more container scripts for SAML portals.
# They were removed when the SSO path moved into the command itself, so no plugin
# installs an extra command now. The contract still allows one, and the rules it
# has to follow are in docs/adding-a-protocol.md - checked there rather than here,
# because there is nothing left to render.
: > "$STUB_LOG"
if declare -f proto_post_install >/dev/null 2>&1; then
  fail "no plugin should install extra container commands yet" \
       "a proto_post_install appeared; it needs the carry-common.sh and \
        delegate-to-finish_connect assertions this block used to make"
else pass; fi

finish
