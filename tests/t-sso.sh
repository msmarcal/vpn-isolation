#!/usr/bin/env bash
# The SSO authentication path: mode selection, value collection, the second
# entry into the dispatcher, and the plugin contract around it.
#
# Sources are resolved at runtime from REPO_ROOT, which lets the suite run from
# anywhere; shellcheck cannot follow that. Setting variables inside a subshell is
# the technique here, not a mistake. PROTOCOL and GATEWAY are read by the render
# functions, and some asserts match literal $-expressions.
# shellcheck disable=SC1090,SC1091,SC2016,SC2030,SC2031,SC2034
set -uo pipefail
source "$(dirname "$0")/lib.sh"
source "${LIB_DIR}/common.sh"
source "${LIB_DIR}/orchestrator.sh"
use_stubs

# ------------------------------------------------------------------ the mode
# Absent means native, so a container created before this existed is unaffected -
# a refresh never rewrites its environment file.
mode() { ( unset VPN_AUTH_MODE; [[ -n "$1" ]] && export VPN_AUTH_MODE="$1"; auth_mode 2>/dev/null ) }
assert_eq "absent is native"      'native' "$(mode '')"
assert_eq "native is native"      'native' "$(mode native)"
assert_eq "sso is sso"            'sso'    "$(mode sso)"
assert_eq "anything else is native" 'native' "$(mode nonsense)"
out="$( ( export VPN_AUTH_MODE=nonsense; auth_mode ) 2>&1 >/dev/null )"
assert_contains "and says so rather than silently" "$out" 'not native or sso'

# --------------------------------------------------------- which plugins have it
for p in anyconnect gp fortissl; do
  assert_status "${p} implements the SSO contract" 0 \
    env -i bash -c "cd '$REPO_ROOT'; LIB_DIR=scripts/lib
      source scripts/lib/common.sh; source scripts/lib/orchestrator.sh
      PROTOCOL=$p; source scripts/lib/protocol-$p.sh; proto_has_sso"
done
assert_status "openvpn does not, which is not an error" 1 \
  env -i bash -c "cd '$REPO_ROOT'; LIB_DIR=scripts/lib
    source scripts/lib/common.sh; source scripts/lib/orchestrator.sh
    PROTOCOL=openvpn; source scripts/lib/protocol-openvpn.sh; proto_has_sso"

# A partial set is refused, naming what is missing, rather than failing later in
# some obscure way.
cat > "${TMPD}/protocol-partial.sh" <<'PLUG'
PROTO_NAME="partial"
PROTO_DESC="Half an SSO contract"
proto_sso_values() { printf 'cookie|secret||c\n'; }
PLUG
out="$( ( PROTOCOL=partial; source "${TMPD}/protocol-partial.sh"; proto_has_sso ) 2>&1 )" || true
assert_contains "a partial SSO contract is refused"        "$out" 'missing'
assert_contains "and names the function that is absent"    "$out" 'proto_sso_url_snippet'

# ------------------------------------------------------------ collecting values
DECL='username|plain||SAML username
cookie|secret||Session cookie
usergroup|plain|gateway:prelogin-cookie|Usergroup path'

# Supplied on standard input, which is the form an automated caller uses and needs
# no terminal. Redirected from a file rather than piped: the real caller reads its
# own standard input, and a pipe would put the collection in a subshell where the
# values it sets could not survive.
printf 'username=alice\ncookie=SEKRIT\n' > "${TMPD}/values"
got="$( ( sso_values_read < "${TMPD}/values"
          sso_values_collect "$DECL" </dev/null
          printf '%s|%s|%s' "${SSO_username-}" "${SSO_cookie-}" "${SSO_usergroup-}" ) )"
assert_eq "values arrive from standard input" 'alice|SEKRIT|gateway:prelogin-cookie' "$got"

# A required value with nothing supplied fails naming it, and the default fills in
# only what has one.
printf 'username=alice\n' > "${TMPD}/partial"
out="$( ( sso_values_read < "${TMPD}/partial"; sso_values_collect "$DECL" </dev/null ) 2>&1 )" || true
assert_contains "a missing required value is named" "$out" "cookie"
assert_status "and collection fails" 1 \
  bash -c "cd '$REPO_ROOT'; source scripts/lib/common.sh
           sso_values_read < '${TMPD}/partial'; sso_values_collect '$DECL' </dev/null"

# Nothing in the collected values is evaluated.
canary="${TMPD}/sso-canary"
rm -f "$canary"
printf 'cookie=$(touch %s)\nusername=alice\n' "$canary" > "${TMPD}/evil"
( sso_values_read < "${TMPD}/evil"
  sso_values_collect "$DECL" </dev/null
  printf '%s' "${SSO_cookie-}" ) > "${TMPD}/collected" 2>/dev/null || true
if [[ -e "$canary" ]]; then
  fail "a collected value must never be executed" "the canary was created"
else pass; fi
assert_eq "and it is kept literally" '$(touch '"${canary}"')' "$(cat "${TMPD}/collected")"

# ------------------------------------------------------------- the terminal check
assert_status "no terminal is refused"                1 bash -c "cd '$REPO_ROOT'; source scripts/lib/common.sh; require_tty 'x' </dev/null"
out="$( ( source "${LIB_DIR}/common.sh"; require_tty "SSO login" ) 2>&1 </dev/null )" || true
assert_contains "and says how to attach one"          "$out" 'lxc exec -t'
assert_contains "and mentions the non-interactive form" "$out" '--from-stdin'

# --------------------------------------------------------------- the dispatcher
render_for() {
  ( source "${LIB_DIR}/common.sh"; source "${LIB_DIR}/orchestrator.sh"
    PROTOCOL="$1"; GATEWAY=vpn.example.com; source "${LIB_DIR}/protocol-$1.sh"
    render_vpn )
}

for p in anyconnect gp openvpn fortissl; do
  vpn="$(render_for "$p")"
  parses_ok "the command parses with the SSO path ($p)" "$vpn"
  assert_contains "it defines auth_mode ($p)"           "$vpn" 'auth_mode() {'
  assert_contains "and the collection helpers ($p)"     "$vpn" 'sso_values_collect() {'
  if [[ "$p" == "openvpn" ]]; then
    assert_contains "openvpn is marked as having no SSO" "$vpn" 'PROTO_HAS_SSO=0'
    assert_not_contains "and carries no SSO connect"     "$vpn" 'proto_sso_connect() {'
  else
    assert_contains "${p} is marked as having SSO"       "$vpn" 'PROTO_HAS_SSO=1'
    assert_contains "and carries its SSO connect"        "$vpn" 'proto_sso_connect() {'
    assert_contains "and its declared values"            "$vpn" 'PROTO_SSO_VALUES='
  fi
  # The container must never try to open a browser: it has none, and that is the
  # isolation it exists for.
  for browser in xdg-open x-www-browser firefox chromium 'BROWSER='; do
    assert_not_contains "no browser invocation ($p, ${browser})" "$vpn" "$browser"
  done
done

# A protocol without the hooks refuses --sso rather than doing something else.
printf 'VPN_PROTOCOL=openvpn\nVPN_ROUTES=10.1.0.0/16\nVPN_INTERFACE=tun0\nVPN_OVPN=/dev/null\n' > "${TMPD}/env-ov"
render_for openvpn | sed "s#^ENV_FILE=/etc/vpn-client.env#ENV_FILE=${TMPD}/env-ov#" > "${TMPD}/vpn-ov"
out="$( ( export STUB_IP_LINKS=''; bash "${TMPD}/vpn-ov" connect --sso ) 2>&1 )" || st=$?
assert_contains "openvpn refuses --sso naming the protocol" "$out" "openvpn"
assert_contains "and says its client authenticates directly" "$out" 'authenticates directly'
assert_not_contains "and starts no client"                   "$(stub_log)" 'CLIENT'

out="$( ( bash "${TMPD}/vpn-ov" connect --nonsense ) 2>&1 )" || true
assert_contains "an unknown connect option is refused" "$out" 'unknown option'

# --------------------------------------------------- the host helper's safety
# The one property that must not erode: it cannot connect the host.
helper="${REPO_ROOT}/scripts/vpn-sso-login.sh"
assert_status "the helper exists and parses" 0 bash -n "$helper"
h="$(cat "$helper")"
for bad in 'openconnect' 'openfortivpn' 'openvpn' '-S ' '--sudo-openconnect' '--pkexec-openconnect'; do
  assert_not_contains "the helper never invokes a client (${bad})" "$h" "$bad"
done
assert_contains "it refuses a stopped container" "$h" 'Start it first'
assert_contains "and falls back when automation is missing" "$h" 'Falling back'

# The gp extraction hook must never use the tool's exec modes, which would bring a
# tunnel up on this machine.
gp="$(cat "${LIB_DIR}/protocol-gp.sh")"
assert_contains "the gp hook disables the tool's session store" "$gp" 'gp-saml-gui -K'
for bad in 'gp-saml-gui -S' 'gp-saml-gui -P' '--sudo-openconnect' '--pkexec-openconnect'; do
  assert_not_contains "and never its exec mode (${bad})" "$gp" "$bad"
done

# It maps the tool's output onto the declared names, checked against recorded
# samples rather than a live login.
parse_fixture() { ( source "${LIB_DIR}/protocol-gp.sh"; proto_sso_host_parse < "${REPO_ROOT}/tests/fixtures/$1" ) }
out="$(parse_fixture gp-saml-gui-gateway.out)"
assert_contains "gateway sample: username" "$out" 'username=test.user@example.com'
assert_contains "gateway sample: the credential kind selects the usergroup" "$out" 'usergroup=gateway:prelogin-cookie'
out="$(parse_fixture gp-saml-gui-portal.out)"
assert_contains "portal sample: the OTHER credential kind is honored" "$out" 'usergroup=portal:portal-userauthcookie'
out="$(parse_fixture gp-saml-gui-redirected.out)"
assert_contains "redirected sample: the server that authenticated is used" "$out" 'server=127.0.0.1:18804'

out="$( ( source "${LIB_DIR}/protocol-gp.sh"; printf 'USER=x\n' | proto_sso_host_parse ) 2>&1 )" || true
assert_contains "an incomplete sample is refused" "$out" 'did not provide all'

# ------------------------------------------------------ the allowlist stays narrow
# `sudo bash` or `sudo setsid <anything>` is a root shell. Neither may appear.
for p in anyconnect gp fortissl; do
  sud="$( ( source "${LIB_DIR}/common.sh"; source "${LIB_DIR}/orchestrator.sh"
            source "${LIB_DIR}/protocol-$p.sh"; render_sudoers vpnuser ) )"
  for bad in '/bin/bash' '/usr/bin/bash' '/bin/sh' '/usr/bin/sh' 'setsid' '/usr/bin/env'; do
    assert_not_contains "${p}: the allowlist grants no shell (${bad})" "$sud" "$bad"
  done
done

finish
