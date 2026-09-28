#!/usr/bin/env bash
# The tunnel state report: reading the record, classifying what is observable,
# and the subcommand that prints it.
#
# Sources are resolved at runtime from REPO_ROOT, which is what lets the suite run
# from anywhere; shellcheck cannot follow that and does not need to. Setting
# variables inside a subshell is the technique here, not a mistake. PROTOCOL is
# read by the render functions, and some asserts match literal $-expressions.
# shellcheck disable=SC1090,SC1091,SC2016,SC2030,SC2031,SC2034
set -uo pipefail
source "$(dirname "$0")/lib.sh"
source "${LIB_DIR}/common.sh"
use_stubs

export VPN_STATE_FILE="${TMPD}/state"
export VPN_CLIENT_PROCESSES=openfortivpn

# write_record ROUTES CLIENT PID [RESOLV]
write_record() {
  { printf 'VPN_STATE_IFACE=ppp0\n'
    printf 'VPN_STATE_ROUTES=%s\n' "$1"
    printf 'VPN_STATE_ROUTE_SOURCE=configured\n'
    printf 'VPN_STATE_CLIENT=%s\n' "$2"
    printf 'VPN_STATE_PID=%s\n' "$3"
    [[ -n "${4:-}" ]] && printf 'VPN_STATE_RESOLV=%s\n' "$4"; } > "$VPN_STATE_FILE"
}

# --------------------------------------------------------------- reading it
write_record '10.1.0.0/16,10.2.0.0/24' openfortivpn 4242 '127.0.0.53'
assert_eq "reads a known key"             'ppp0'                      "$(state_get VPN_STATE_IFACE)"
assert_eq "reads a comma-separated list"  '10.1.0.0/16,10.2.0.0/24'   "$(state_get VPN_STATE_ROUTES)"
assert_eq "an unknown key yields nothing" ''                          "$(state_get VPN_NOT_A_KEY)"

# The record's directory is owned by the container's login user, so root reading
# it must never execute what is in it. This is why it is parsed, not sourced.
canary="${TMPD}/canary"
rm -f "$canary"
printf 'VPN_STATE_IFACE=$(touch %s)\n' "$canary" > "$VPN_STATE_FILE"
assert_eq "a value with command substitution is rejected" '' "$(state_get VPN_STATE_IFACE)"
if [[ -e "$canary" ]]; then
  fail "reading the record must never execute it" "the canary was created"
else pass; fi

printf 'not a key=value line\nVPN_STATE_IFACE=ppp0\n' > "$VPN_STATE_FILE"
assert_eq "a malformed line is skipped" 'ppp0' "$(state_get VPN_STATE_IFACE)"

rm -f "$VPN_STATE_FILE"
assert_eq "no record at all yields nothing" '' "$(state_get VPN_STATE_IFACE)"
: > "$VPN_STATE_FILE"
assert_eq "an empty record yields nothing"  '' "$(state_get VPN_STATE_IFACE)"

# ------------------------------------------------------------- is it alive
# Both the pid and the name are checked: pids are recycled, so a dead client's id
# can belong to something unrelated and leftovers would report as a live tunnel.
write_record '10.1.0.0/16' bash "$$" ''
assert_status "pid alive and name matching is alive"    0 state_client_alive
write_record '10.1.0.0/16' openfortivpn "$$" ''
assert_status "pid alive but name mismatched is not"    1 state_client_alive
write_record '10.1.0.0/16' bash 999999 ''
assert_status "a pid that is gone is not alive"         1 state_client_alive
rm -f "$VPN_STATE_FILE"
assert_status "no record means not alive"               1 state_client_alive

# ----------------------------------------------------------- classification
state_for() {
  ( export STUB_IP_LINKS="$1" STUB_IP_ROUTES="$2" STUB_IP_DEFAULT_DEV="$3" \
           STUB_PGREP_ALIVE="$4" VPN_TUNNEL_MODE="${5:-split}"
    tunnel_state ppp0 )
}

write_record '10.1.0.0/16,10.2.0.0/24' openfortivpn 999999 '127.0.0.53'
assert_eq "no client and no interface is down"        'down'      "$(state_for '' '' eth0 '')"
assert_eq "no client but leftovers is stale"          'stale'     "$(state_for ppp0 '10.1.0.0/16,10.2.0.0/24' eth0 '')"
assert_eq "everything in place is connected"          'connected' "$(state_for ppp0 '10.1.0.0/16,10.2.0.0/24' eth0 openfortivpn)"
assert_eq "a missing route is degraded"               'degraded'  "$(state_for ppp0 '10.1.0.0/16' eth0 openfortivpn)"
assert_eq "a stolen default route is degraded"        'degraded'  "$(state_for ppp0 '10.1.0.0/16,10.2.0.0/24' ppp0 openfortivpn)"
assert_eq "declared full, default on the tunnel, is connected" \
  'connected' "$(state_for ppp0 '10.1.0.0/16,10.2.0.0/24' ppp0 openfortivpn full)"

# An unknown expectation must not by itself be degraded, or every container older
# than the record would look broken.
rm -f "$VPN_STATE_FILE"
assert_eq "no record with a live client is not degraded" \
  'connected' "$(state_for ppp0 '' eth0 openfortivpn)"

# --------------------------------------------------- expected versus installed
write_record '10.1.0.0/16,10.2.0.0/24' openfortivpn 4242 ''
assert_eq "nothing missing when all are installed" '' \
  "$( ( export STUB_IP_ROUTES='10.1.0.0/16,10.2.0.0/24'; status_missing_routes ppp0 ) )"
assert_eq "the missing one is named" '10.2.0.0/24' \
  "$( ( export STUB_IP_ROUTES='10.1.0.0/16'; status_missing_routes ppp0 ) )"
rm -f "$VPN_STATE_FILE"
assert_eq "an unknown expectation reports nothing missing" '' \
  "$( ( export STUB_IP_ROUTES=''; status_missing_routes ppp0 ) )"

# ------------------------------------------------------------- the verdict
# One implementation, shared with the connect report, judged against the declared
# mode rather than a fixed rule.
verdict_for() { ( export STUB_IP_DEFAULT_DEV="$2" VPN_TUNNEL_MODE="$1"; default_route_verdict ppp0 ); }
assert_eq "split with the default elsewhere is ok"     'eth0 ok'         "$(verdict_for split eth0)"
assert_eq "split with the default on the tunnel breaks" 'ppp0 broken'    "$(verdict_for split ppp0)"
assert_eq "full with the default on the tunnel is ok"  'ppp0 ok'         "$(verdict_for full ppp0)"
assert_eq "full with no default pushed is noted"       'eth0 not-pushed' "$(verdict_for full eth0)"

# ------------------------------------------------------------ the subcommand
printf 'VPN_PROTOCOL=fortissl\nVPN_ROUTES=10.1.0.0/16,10.2.0.0/24\nVPN_INTERFACE=ppp0\nVPN_TUNNEL_MODE=split\n' > "${TMPD}/env"
cmd="${TMPD}/vpn"
( source "${LIB_DIR}/orchestrator.sh"
  PROTOCOL=fortissl; source "${LIB_DIR}/protocol-fortissl.sh"
  render_vpn ) | sed "s#^ENV_FILE=/etc/vpn-client.env#ENV_FILE=${TMPD}/env#" > "$cmd"
parses_ok "the command with a status branch parses" "$(cat "$cmd")"

status_out() {
  ( export STUB_IP_LINKS="$1" STUB_IP_ROUTES="$2" STUB_IP_DEFAULT_DEV="$3" STUB_PGREP_ALIVE="$4"
    bash "$cmd" status 2>&1 )
}

write_record '10.1.0.0/16,10.2.0.0/24' openfortivpn 4242 '127.0.0.53'
out="$(status_out ppp0 '10.1.0.0/16,10.2.0.0/24' eth0 openfortivpn)"
assert_contains "connected is in the headline"  "$out" 'connected'
assert_contains "the client is named"           "$out" 'openfortivpn running'
assert_contains "the interface and address"     "$out" 'ppp0 10.99.0.2/32'
assert_contains "the routes are counted"        "$out" 'all 2 present'
assert_contains "the default route is judged"   "$out" 'as declared (split)'
assert_contains "the resolver is compared"      "$out" 'unchanged since connect'

out="$(status_out ppp0 '10.1.0.0/16' eth0 openfortivpn)"
assert_contains "degraded names the missing route" "$out" 'missing: 10.2.0.0/24'
assert_contains "and counts what is there"         "$out" '1 of 2 present'

out="$(status_out ppp0 '10.1.0.0/16,10.2.0.0/24' ppp0 openfortivpn)"
assert_contains "a stolen default route is called out" "$out" 'SPLIT TUNNEL NOT IN EFFECT'

out="$(status_out ppp0 '10.1.0.0/16,10.2.0.0/24' eth0 '')"
assert_contains "stale says how to clear it" "$out" "vpn disconnect"

rm -f "$VPN_STATE_FILE"
out="$(status_out ppp0 '10.1.0.0/16' eth0 openfortivpn)"
assert_contains "an unknown expectation says so"  "$out" 'expected set unknown'
assert_contains "and so does a missing baseline"  "$out" 'cannot tell whether it changed'

# Reporting successfully is success, whatever the state.
for links in '' 'ppp0'; do
  assert_status "reporting exits 0 (links='${links}')" 0 \
    env STUB_IP_LINKS="$links" STUB_IP_DEFAULT_DEV=eth0 bash "$cmd" status
done

out="$(bash "$cmd" --help 2>&1)"
assert_contains "usage lists the new subcommand" "$out" 'status'
assert_status "an unrecognized subcommand still exits 2" 2 bash "$cmd" statuss

# ----------------------------------------------------------- it changes nothing
# Easy to state and easy to erode: the next person to notice a missing route will
# want to install it. So the calls the report makes are checked directly.
write_record '10.1.0.0/16,10.2.0.0/24' openfortivpn 4242 '127.0.0.53'
before="$(md5sum "$VPN_STATE_FILE" | cut -d' ' -f1)"
: > "$STUB_LOG"
status_out ppp0 '10.1.0.0/16' ppp0 openfortivpn >/dev/null
log="$(stub_log)"
for bad in 'route add' 'route del' 'route replace' 'link set' 'link delete' 'link add' 'pkill' 'file push' 'file delete'; do
  assert_not_contains "the report never runs '${bad}'" "$log" "$bad"
done
assert_eq "and never rewrites the record" "$before" "$(md5sum "$VPN_STATE_FILE" | cut -d' ' -f1)"

finish
