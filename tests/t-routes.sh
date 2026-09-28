#!/usr/bin/env bash
# The routing helpers. validate_routes runs on the host before any lxc call;
# detect_split_routes and apply_split_routes run inside the container under
# `set -euo pipefail`, which is where an empty pipeline used to abort a connect
# that had already succeeded.
# Sources are resolved at runtime from REPO_ROOT, which is what lets the suite
# run from anywhere; shellcheck cannot follow that and does not need to. Setting
# variables inside a subshell is the technique here, not a mistake: each case runs
# isolated so the next cannot inherit it. Some asserts match literal text
# containing $-expressions.
# shellcheck disable=SC1090,SC1091,SC2016,SC2030,SC2031
set -uo pipefail
source "$(dirname "$0")/lib.sh"
source "${LIB_DIR}/common.sh"
source "${LIB_DIR}/orchestrator.sh"   # validate_routes lives here
use_stubs

# ---------------------------------------------------------------- validate_routes
# It exits rather than returning, so each case runs in a subshell.
vr() { ( validate_routes "$1" ) ; }

assert_status "auto alone is valid"            0 vr 'auto'
assert_status "single CIDR is valid"           0 vr '10.10.0.0/16'
assert_status "list of CIDRs is valid"         0 vr '10.1.0.0/16,10.2.0.0/24,172.16.8.0/24'
assert_status "single host as /32 is valid"    0 vr '10.1.2.3/32'
assert_status "IPv6 CIDR is valid"             0 vr '2001:db8::/32'

assert_status "host bits set is rejected"      1 vr '10.10.1.0/16'
assert_status "missing prefix is rejected"     1 vr '10.10.0.0'
assert_status "auto plus a CIDR is rejected"   1 vr 'auto,10.1.0.0/16'
assert_status "trailing comma is rejected"     1 vr '10.1.0.0/16,'
assert_status "leading comma is rejected"      1 vr ',10.1.0.0/16'
assert_status "doubled comma is rejected"      1 vr '10.1.0.0/16,,10.2.0.0/24'
assert_status "octet above 255 is rejected"    1 vr '10.300.0.0/16'
assert_status "prefix above 32 is rejected"    1 vr '10.1.0.0/33'
assert_status "empty list is rejected"         1 vr ''

out="$( ( validate_routes '10.10.1.0/16' ) 2>&1 || true )"
assert_contains "host-bits error suggests the network address" "$out" '10.10.0.0/16'

# ------------------------------------------------------------ detect_split_routes
export VPN_ROUTE_SETTLE_WINDOW=2 VPN_ROUTE_SETTLE_INTERVAL=0
export STUB_IP_LINKS='tun0'

export STUB_IP_ROUTES='10.2.0.0/24,10.1.0.0/16'
assert_eq "detected set is sorted and comma-joined" \
  '10.1.0.0/16,10.2.0.0/24' "$(detect_split_routes tun0)"

# A default route the gateway pushed is never part of the detected set.
export STUB_IP_ROUTES='default,10.1.0.0/16'
got="$(detect_split_routes tun0)"
assert_not_contains "detected set excludes a default route" "$got" 'default'
assert_eq "and keeps the subnet"                    '10.1.0.0/16' "$got"

export STUB_IP_ROUTES=''
assert_eq "nothing to detect gives an empty string" '' "$(detect_split_routes tun0)"
assert_eq "a missing interface gives an empty string" '' "$(detect_split_routes no-such-iface)"

# The regression that matters: an empty result must not be a failure, or a
# caller under `set -euo pipefail` dies with the tunnel already up.
assert_survives "empty detection must exit 0 under set -e" '
  source "'"${LIB_DIR}"'/common.sh"
  detect_split_routes tun0 >/dev/null
  detect_split_routes no-such-iface >/dev/null'

# ------------------------------------------------------------ wait_for_iface_up
# An interface exists before it is usable: pppd creates the link, but IFF_UP is
# only set when negotiation finishes, and the kernel refuses a route whose device
# is not up. Waiting for the NAME is not enough - that was a live bug: the three
# configured routes all failed with "Device for nexthop is not up" while the
# tunnel itself was fine.
export VPN_IFACE_UP_WINDOW=2 VPN_IFACE_UP_INTERVAL=0

STUB_IP_UP='lo,eth0,ppp0' assert_status "an interface carrying IFF_UP is accepted" 0 wait_for_iface_up ppp0
STUB_IP_UP='lo,eth0'      assert_status "one that exists but is not up is refused" 1 wait_for_iface_up ppp0
STUB_IP_UP=''             assert_status "and so is one that does not exist"        1 wait_for_iface_up ppp0

# A name that only appears as a prefix of another must not match.
STUB_IP_UP='lo,ppp01' assert_status "matching is exact, not a prefix" 1 wait_for_iface_up ppp0

# It must never abort its caller, whichever way it goes.
assert_survives "waiting never aborts, up or not" '
  source "${LIB_DIR}/common.sh"
  export VPN_IFACE_UP_WINDOW=1 VPN_IFACE_UP_INTERVAL=0
  STUB_IP_UP=ppp0 wait_for_iface_up ppp0 || true
  STUB_IP_UP= wait_for_iface_up ppp0 || true'

# And finish_connect must wait rather than routing into a device that is not up.
export VPN_STATE_FILE="${TMPD}/state-up" VPN_CLIENT_PROCESSES=openconnect
out="$( ( export STUB_IP_UP='lo,eth0' STUB_IP_DEFAULT_DEV=eth0 VPN_ROUTES=10.1.0.0/16
          export VPN_IFACE_UP_WINDOW=1 VPN_IFACE_UP_INTERVAL=0
          source "${LIB_DIR}/common.sh"
          finish_connect ppp0 ) 2>&1 )"
assert_contains "finish_connect says when the interface never came up" "$out" 'never came up'

out="$( ( export STUB_IP_UP='lo,eth0,ppp0' STUB_IP_DEFAULT_DEV=eth0 VPN_ROUTES=10.1.0.0/16
          export VPN_IFACE_UP_WINDOW=1 VPN_IFACE_UP_INTERVAL=0
          source "${LIB_DIR}/common.sh"
          finish_connect ppp0 ) 2>&1 )"
assert_not_contains "and says nothing when it did" "$out" 'never came up'

# ------------------------------------------------------------- apply_split_routes
: > "$STUB_LOG"
apply_split_routes '10.1.0.0/16,10.2.0.0/24' tun0 >/dev/null
first="$(stub_log)"
: > "$STUB_LOG"
apply_split_routes '10.1.0.0/16,10.2.0.0/24' tun0 >/dev/null
assert_eq "applying twice issues the same calls (idempotent)" "$first" "$(stub_log)"
assert_contains "uses route replace" "$first" 'ip route replace 10.1.0.0/16 dev tun0'

: > "$STUB_LOG"
export STUB_IP_FAIL_CIDR='10.9.0.0/16'
err="$(apply_split_routes '10.1.0.0/16,10.9.0.0/16,10.2.0.0/24' tun0 2>&1 >/dev/null)"
assert_contains "a failed entry is named on stderr"   "$err" '10.9.0.0/16'
assert_contains "and the reason is included"          "$err" 'Invalid prefix'
assert_contains "the entry after it is still applied" "$(stub_log)" 'ip route replace 10.2.0.0/24 dev tun0'

assert_survives "a failed route must not abort under set -e" '
  source "'"${LIB_DIR}"'/common.sh"
  apply_split_routes "10.9.0.0/16" tun0'
unset STUB_IP_FAIL_CIDR

assert_eq "an empty route list is a no-op" '' "$(apply_split_routes '' tun0)"

# ------------------------------------------------------------- record_connection
export VPN_STATE_FILE="${TMPD}/state" VPN_CLIENT_PROCESSES='openconnect'
state_get() { ( set +u; source "$VPN_STATE_FILE"; printf '%s' "${!1-}" ); }

STUB_PGREP_ALIVE='openconnect' record_connection tun0 '10.1.0.0/16,10.2.0.0/24' detected
assert_eq "record: interface" 'tun0'                    "$(state_get VPN_STATE_IFACE)"
assert_eq "record: routes"    '10.1.0.0/16,10.2.0.0/24' "$(state_get VPN_STATE_ROUTES)"
assert_eq "record: source"    'detected'                "$(state_get VPN_STATE_ROUTE_SOURCE)"
assert_eq "record: client"    'openconnect'             "$(state_get VPN_STATE_CLIENT)"
assert_eq "record: pid"       '4242'                    "$(state_get VPN_STATE_PID)"

# A client that is not running leaves no PID, so a reader can tell leftovers
# from a live tunnel.
STUB_PGREP_ALIVE='' record_connection tun0 '10.1.0.0/16' configured
assert_eq "no running client means an empty PID" '' "$(state_get VPN_STATE_PID)"

# Losing the record must not fail a connect that already succeeded.
assert_survives "an unwritable record must not abort under set -e" '
  source "'"${LIB_DIR}"'/common.sh"
  VPN_STATE_FILE=/proc/nope/state record_connection tun0 "10.1.0.0/16" configured'

finish
