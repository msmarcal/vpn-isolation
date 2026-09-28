#!/usr/bin/env bash
# env_kv writes /etc/vpn-client.env and the connection record. Both are read by
# being sourced, so every value in them is shell syntax: a space runs the rest
# as a command, an apostrophe breaks the file, and $(...) executes.
# Sources are resolved at runtime from REPO_ROOT, which is what lets the suite
# run from anywhere; shellcheck cannot follow that and does not need to.
# shellcheck disable=SC1090,SC1091
set -uo pipefail
source "$(dirname "$0")/lib.sh"
source "${LIB_DIR}/common.sh"

# round_trip VALUE - print what `source` yields back for that value.
round_trip() {
  local f="${TMPD}/rt.env"
  env_kv K "$1" > "$f"
  ( set +u; source "$f"; printf '%s' "${K-}" )
}

assert_eq "plain hostname stays bare"      'K=vpn.example.com'            "$(env_kv K 'vpn.example.com')"
assert_eq "gateway with a path stays bare" 'K=vpn.example.com/group'      "$(env_kv K 'vpn.example.com/group')"
assert_eq "CIDR list keeps its commas"     'K=10.1.0.0/16,10.2.0.0/24'    "$(env_kv K '10.1.0.0/16,10.2.0.0/24')"
assert_eq "empty value"                    'K='                           "$(env_kv K '')"

assert_eq "space survives"        'with space'        "$(round_trip 'with space')"
assert_eq "apostrophe survives"   "ma o'brien"        "$(round_trip "ma o'brien")"
assert_eq "tab survives"          "$(printf 'a\tb')"  "$(round_trip "$(printf 'a\tb')")"
assert_eq "quotes survive"        'say "hi"'          "$(round_trip 'say "hi"')"

# The one that matters: a value must never be executed on source.
canary="${TMPD}/canary"
round_trip "\$(touch ${canary})" >/dev/null
if [[ -e "$canary" ]]; then
  fail "command substitution must not execute" "the canary file was created"
else pass; fi
assert_eq "command substitution read back literally" "\$(touch ${canary})" "$(round_trip "\$(touch ${canary})")"

# Backtick form of the same hazard.
canary2="${TMPD}/canary2"
round_trip "\`touch ${canary2}\`" >/dev/null
if [[ -e "$canary2" ]]; then
  fail "backticks must not execute" "the canary file was created"
else pass; fi

finish
