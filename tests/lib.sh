# shellcheck shell=bash
#
# Assertions and stub plumbing. Sourced by every tests/t-*.sh.
#
# Deliberately small: no framework, no dependency beyond bash and coreutils.
# If something here starts needing a library, it is the wrong test for this repo
# (see CLAUDE.md).

# Consumed by the tests that source this file, not here.
# shellcheck disable=SC2034
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
}

stub_log() { cat "$STUB_LOG" 2>/dev/null || true; }

finish() {
  if (( FAILED > 0 )); then
    printf '  %d passed, %d FAILED\n' "$PASSED" "$FAILED"
    exit 1
  fi
  printf '  %d passed\n' "$PASSED"
}
