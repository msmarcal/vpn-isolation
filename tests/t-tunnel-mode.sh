#!/usr/bin/env bash
# The declared tunnel mode: how it is read, how a protocol derives client
# configuration from it, and how the connect report describes the default route.
#
# Sources are resolved at runtime from REPO_ROOT, which is what lets the suite
# run from anywhere; shellcheck cannot follow that and does not need to. Setting
# variables inside a subshell is the technique here, not a mistake: each case
# runs isolated so the next one cannot inherit it. PROTOCOL is read by the render
# functions, and the asserts match literal text containing $-expressions.
# shellcheck disable=SC1090,SC1091,SC2016,SC2030,SC2031,SC2034
set -uo pipefail
source "$(dirname "$0")/lib.sh"
source "${LIB_DIR}/common.sh"
use_stubs

# ------------------------------------------------------------------ the reader
# An absent declaration is derived, never assumed: containers created before the
# key existed still have to report the truth, and a refresh never rewrites their
# configuration.
mode() { ( unset VPN_TUNNEL_MODE VPN_ROUTE_NOPULL
           [[ -n "$1" ]] && export VPN_TUNNEL_MODE="$1"
           [[ -n "$2" ]] && export VPN_ROUTE_NOPULL="$2"
           tunnel_mode 2>/dev/null ) }

assert_eq "declared split is split"                  'split' "$(mode split '')"
assert_eq "declared full is full"                    'full'  "$(mode full '')"
assert_eq "absent with no legacy key is split"       'split' "$(mode '' '')"
assert_eq "absent with the legacy key discarding"    'split' "$(mode '' 1)"
assert_eq "absent with the legacy key accepting"     'full'  "$(mode '' 0)"
assert_eq "a declared value wins over the legacy key" 'split' "$(mode split 0)"
assert_eq "an unrecognized value falls back to split" 'split' "$(mode sideways '')"

out="$( ( export VPN_TUNNEL_MODE=sideways; tunnel_mode ) 2>&1 >/dev/null )"
assert_contains "and says so rather than failing silently" "$out" 'not split or full'

# The reader has to be available on both sides of the split, so it must travel.
vpn="$( ( source "${LIB_DIR}/orchestrator.sh"
          PROTOCOL=anyconnect; source "${LIB_DIR}/protocol-anyconnect.sh"
          render_vpn ) )"
assert_contains "the generated command defines the reader" "$vpn" 'tunnel_mode() {'

# ------------------------------------------------- deriving client configuration
# Run the plugin's REAL snippet with the client stubbed, so this checks what
# ships rather than a restatement of it.
: > "${TMPD}/profile.ovpn"
snippet="$( ( source "${LIB_DIR}/protocol-openvpn.sh"; proto_connect_snippet ) )"

flags() {
  local declared="$1" routes="$2" legacy="$3"
  : > "$STUB_LOG"
  ( export STUB_IP_LINKS=tun0
    [[ -n "$declared" ]] && export VPN_TUNNEL_MODE="$declared"
    [[ -n "$legacy" ]] && export VPN_ROUTE_NOPULL="$legacy"
    export VPN_OVPN="${TMPD}/profile.ovpn" VPN_ROUTES="$routes" VPN_INTERFACE=tun0
    source "${LIB_DIR}/common.sh"
    eval "$snippet"
    proto_connect ) >/dev/null 2>&1
  grep 'CLIENT openvpn' "$STUB_LOG" | head -1
}

f="$(flags split auto '')"
assert_contains "split with detection accepts the subnets" "$f" '--pull-filter ignore redirect-gateway'
assert_contains "and refuses a redirected default"         "$f" '--pull-filter ignore route 0.0.0.0'
assert_not_contains "and does not discard everything"      "$f" '--route-nopull'

f="$(flags split 10.1.0.0/16 '')"
assert_contains "split with a named list discards the rest" "$f" '--route-nopull'
assert_not_contains "and does not filter instead"           "$f" '--pull-filter'

f="$(flags full auto '')"
assert_not_contains "full accepts everything - no discard" "$f" '--route-nopull'
assert_not_contains "full accepts everything - no filter"  "$f" '--pull-filter'

# The legacy key is an explicit override and wins, so nobody who set it
# deliberately gets it silently reinterpreted.
f="$(flags split auto 1)"
assert_contains "the legacy key discarding overrides the mode" "$f" '--route-nopull'
assert_not_contains "and suppresses the filters"               "$f" '--pull-filter'

f="$(flags split auto 0)"
assert_not_contains "the legacy key accepting overrides too" "$f" '--pull-filter'

# The derivation runs under `set -euo pipefail` inside the container, and the
# branch that handles the legacy key set to 0 ends on a failing test. Bash exempts
# that, but the connect must be shown to reach its end rather than assumed to.
: > "$STUB_LOG"
if ( set -euo pipefail
     export STUB_IP_LINKS=tun0 VPN_ROUTE_NOPULL=0 VPN_TUNNEL_MODE=split
     export VPN_OVPN="${TMPD}/profile.ovpn" VPN_ROUTES=auto VPN_INTERFACE=tun0
     source "${LIB_DIR}/common.sh"
     eval "$snippet"
     proto_connect ) >/dev/null 2>&1; then pass
else fail "the legacy-key branch must not abort under set -e" "it exited non-zero"; fi
assert_contains "and the client still ran" "$(stub_log)" 'CLIENT openvpn'

# An existing container must behave exactly as it does today. These two rows are
# what that promise reduces to.
assert_eq "existing container, legacy key discarding" \
  "$(flags '' auto 1)" "$(flags split 10.1.0.0/16 '')"
f="$(flags '' auto 0)"
assert_not_contains "existing container, legacy key accepting" "$f" '--pull-filter'

# ------------------------------------------------------------------- the report
report() {
  ( export STUB_IP_DEFAULT_DEV="$2" VPN_STATE_FILE="${TMPD}/state" \
           VPN_CLIENT_PROCESSES=openconnect VPN_ROUTE_SETTLE_WINDOW=1 \
           VPN_ROUTE_SETTLE_INTERVAL=0 VPN_TUNNEL_MODE="$1" VPN_ROUTES=10.1.0.0/16
    source "${LIB_DIR}/common.sh"
    finish_connect tun0 ) 2>&1
}

r="$(report split eth0)"
assert_contains "split intact is reported as expected" "$r" 'split tunnel intact'

r="$(report split tun0)"
assert_contains "split broken is named"        "$r" 'SPLIT TUNNEL DECLARED BUT NOT IN EFFECT'
assert_contains "and says it was not enforced" "$r" 'does not'

r="$(report full tun0)"
assert_contains "full as declared is expected"        "$r" 'full tunnel, as declared'
assert_not_contains "and is not called a problem"     "$r" 'NOT IN EFFECT'
assert_not_contains "nor labelled with the old rule"  "$r" 'must stay off the tunnel'

r="$(report full eth0)"
assert_contains "full declared but not pushed is stated" "$r" 'pushed no default route'

# The divergence reports and continues: the tunnel is up, and enforcing the
# invariant is a separate decision the design rules out.
: > "$STUB_LOG"
if ( set -euo pipefail
     export STUB_IP_DEFAULT_DEV=tun0 VPN_STATE_FILE="${TMPD}/state2" \
            VPN_CLIENT_PROCESSES=openconnect VPN_ROUTE_SETTLE_WINDOW=1 \
            VPN_ROUTE_SETTLE_INTERVAL=0 VPN_TUNNEL_MODE=split VPN_ROUTES=10.1.0.0/16
     source "${LIB_DIR}/common.sh"
     finish_connect tun0 ) >/dev/null 2>&1; then pass
else fail "a broken split tunnel must not fail the connect" "it exited non-zero"; fi
assert_not_contains "and must not alter the default route" "$(stub_log)" 'route del default'
assert_not_contains "nor replace it"                       "$(stub_log)" 'route replace default'

# These report assertions must not pass against the labelling this replaced, or
# they are testing nothing. The old wording asserted a rule unconditionally.
sed 's/^  mode="\$(tunnel_mode)"/  mode=split/' "${LIB_DIR}/common.sh" > "${TMPD}/old-common.sh"
r="$( ( export STUB_IP_DEFAULT_DEV=tun0 VPN_STATE_FILE="${TMPD}/state3" \
               VPN_CLIENT_PROCESSES=openconnect VPN_ROUTE_SETTLE_WINDOW=1 \
               VPN_ROUTE_SETTLE_INTERVAL=0 VPN_TUNNEL_MODE=full VPN_ROUTES=10.1.0.0/16
        source "${TMPD}/old-common.sh"
        finish_connect tun0 ) 2>&1 )"
if [[ "$r" == *'NOT IN EFFECT'* ]]; then
  # With the mode ignored, a declared full tunnel is wrongly called a problem -
  # which is what makes the assertions above evidence of the fix.
  pass
else
  fail "the report assertions are meaningful" \
       "ignoring the declared mode produced the same output, so reading it proves nothing"
fi

finish
