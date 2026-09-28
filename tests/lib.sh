# shellcheck shell=bash
#
# Assertions and stub plumbing. Sourced by every tests/t-*.sh.
#
# Deliberately small: no framework, no dependency beyond bash and coreutils.
# If something here starts needing a library, it is the wrong test for this repo
# (see CLAUDE.md).

# SC2034: consumed by the tests that source this file, not here.
# SC1090/SC1091: render_for resolves its sources from REPO_ROOT at runtime, which
# is what lets the suite run from anywhere - shellcheck cannot follow that and
# does not need to.
# shellcheck disable=SC2034,SC1090,SC1091
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="${REPO_ROOT}/scripts/lib"
TESTS_DIR="${REPO_ROOT}/tests"

PASSED=0
FAILED=0

# Every test writes only here. Nothing in a test may touch the host.
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

pass() { PASSED=$((PASSED + 1)); }

fail() {
  FAILED=$((FAILED + 1))
  printf '    FAIL %s\n' "$1" >&2
  shift
  local line
  for line in "$@"; do printf '         %s\n' "$line" >&2; done
}

assert_eq() {
  local desc="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then pass; else
    fail "$desc" "expected: [${want}]" "got:      [${got}]"
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass; else
    fail "$desc" "expected to contain: [${needle}]"
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass; else
    fail "$desc" "expected NOT to contain: [${needle}]"
  fi
}

# assert_status DESC EXPECTED_STATUS COMMAND...
# Runs COMMAND in a subshell, so a function that calls `exit` cannot take the
# test down with it - validate_routes does exactly that.
assert_status() {
  local desc="$1" want="$2"; shift 2
  local out status
  out="$( "$@" 2>&1 )" && status=0 || status=$?
  if [[ "$status" == "$want" ]]; then pass; else
    fail "$desc" "expected status ${want}, got ${status}" "output: ${out}"
  fi
}

# assert_survives DESC BODY / assert_aborts DESC BODY
# Run BODY in a subshell under `set -euo pipefail` and check whether it ran to
# completion. Almost everything the container does runs under those options, and
# the bugs this repo keeps hitting are commands that fail there for reasons the
# author did not expect - a `grep` with no match, a test that comes out false.
#
# The subshell is run STANDALONE, with its status read on the next line. It must
# never be the condition of an `if`, nor part of a `&&` or `||` list: bash
# suppresses `set -e` inside a subshell in those positions, so an assertion
# written that way passes whether or not the code aborts. That mistake was in
# this file's own tests until it was found by a real bug the suite had missed.
_status_of() {
  ( set -euo pipefail; eval "$1" ) >/dev/null 2>&1
  printf '%s' "$?"
}

assert_survives() {
  local desc="$1" body="$2" st
  st="$(_status_of "$body")"
  if [[ "$st" == "0" ]]; then pass; else
    fail "$desc" "aborted with status ${st} under set -euo pipefail"
  fi
}

assert_aborts() {
  local desc="$1" body="$2" st
  st="$(_status_of "$body")"
  if [[ "$st" != "0" ]]; then pass; else
    fail "$desc" "ran to completion, so the guard it is checking proves nothing"
  fi
}

# parses_ok DESC TEXT - the check that matters for generated container scripts:
# they are strings on the host, so a syntax error survives shellcheck.
parses_ok() {
  local desc="$1" text="$2" f="${TMPD}/parse.$$"
  printf '%s\n' "$text" > "$f"
  local out
  if out="$(bash -n "$f" 2>&1)"; then pass; else
    fail "$desc" "does not parse: ${out}"
  fi
  rm -f "$f"
}

# use_stubs - put tests/stubs first on PATH and point them at a fresh log.
# This is how host-side rendering is checked with no LXD, and how routing is
# checked without touching the host's routing table.
use_stubs() {
  STUB_LOG="${TMPD}/stub.log"
  STUB_PUSH_DIR="${TMPD}/pushed"
  mkdir -p "$STUB_PUSH_DIR"
  : > "$STUB_LOG"
  export STUB_LOG STUB_PUSH_DIR
  export PATH="${TESTS_DIR}/stubs:${PATH}"

  # Every wait loop in common.sh is bounded by a window and polls on an interval.
  # A test must never spend that time: the suite has to stay under a few seconds,
  # and a test that waits on the wall clock is one nobody will run. Individual
  # cases override these when the point is what happens at the boundary.
  export VPN_ROUTE_SETTLE_WINDOW=2 VPN_ROUTE_SETTLE_INTERVAL=0
  export VPN_IFACE_UP_WINDOW=2 VPN_IFACE_UP_INTERVAL=0
}

stub_log() { cat "$STUB_LOG" 2>/dev/null || true; }

# render_for PROTO FUNC - render in a subshell so each plugin's definitions
# cannot leak into the next. Needs common.sh and orchestrator.sh sourced by the
# caller too, since the render_* functions read PROTOCOL and friends as globals.
render_for() {
  ( source "${LIB_DIR}/common.sh"
    source "${LIB_DIR}/orchestrator.sh"
    PROTOCOL="$1"
    source "${LIB_DIR}/protocol-$1.sh"
    "$2" )
}

# runnable PROTO - the rendered command, pointed at a throwaway env file so it
# can be executed. Every client is stubbed, so nothing can bring up a tunnel.
# Two test files need this: t-render checks what the command does, t-readme
# checks that the subcommands the README shows are ones it accepts.
runnable() {
  local out="${TMPD}/vpn.$1"
  printf 'VPN_PROTOCOL=%s\nVPN_ROUTES=10.1.0.0/16\nVPN_INTERFACE=vpn0\nVPN_GATEWAY=vpn.example.com\nVPN_OVPN=/dev/null\n' "$1" > "${TMPD}/env.$1"
  render_for "$1" render_vpn | sed "s#^ENV_FILE=/etc/vpn-client.env#ENV_FILE=${TMPD}/env.$1#" > "$out"
  printf '%s' "$out"
}

finish() {
  if (( FAILED > 0 )); then
    printf '  %d passed, %d FAILED\n' "$PASSED" "$FAILED"
    exit 1
  fi
  printf '  %d passed\n' "$PASSED"
}
