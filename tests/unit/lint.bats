#!/usr/bin/env bats
# Static checks. Cheap, and they run with no LXD and no network.

load ../helpers/load

shell_files() {
  printf '%s\n' "$ORCHESTRATOR"
  printf '%s\n' "${LIB_DIR}"/*.sh
  printf '%s\n' "${REPO_ROOT}/tests/golden-update.sh"
}

@test "every shell file parses" {
  local f
  while read -r f; do
    bash -n "$f" || fail "bash -n failed: $f"
  done < <(shell_files)
}

@test "shellcheck reports nothing outside the known baseline" {
  command -v shellcheck >/dev/null || skip "shellcheck not installed"

  # The baseline is currently EMPTY, and that is the point: everything shellcheck
  # once reported here was either fixed or given an inline disable explaining
  # why it is intentional. Compared as file:CODE pairs, deliberately without line
  # numbers, so a finding moving down a file is not a failure.
  #
  # -x -P SCRIPTDIR mirrors the Makefile: without them every `source` line
  # reports SC1091 and drowns out real findings.
  local actual="${BATS_TEST_TMPDIR}/actual"
  # shellcheck disable=SC2046
  shellcheck -x -P SCRIPTDIR -f gcc $(shell_files) 2>/dev/null \
    | sed -E "s|^${REPO_ROOT}/||; s|^([^:]+):[0-9]+:[0-9]+: [a-z]+: .*\[(SC[0-9]+)\]$|\1:\2|" \
    | sort -u > "$actual" || true

  diff -u "${REPO_ROOT}/tests/shellcheck-baseline.txt" "$actual" \
    || fail "shellcheck findings changed (see diff). If intended: make lint-baseline"
}

@test "no protocol lib is missing a shell directive" {
  # These files have no shebang (they are sourced), so shellcheck needs to be
  # told what they are or it errors out with SC2148.
  local f
  for f in "${LIB_DIR}"/*.sh; do
    head -1 "$f" | grep -q 'shellcheck shell=bash' \
      || fail "$(basename "$f"): first line must be '# shellcheck shell=bash'"
  done
}

@test "docs use placeholder hostnames, never a real corporate gateway" {
  # The repo is public; a real portal hostname leaking into an example is the
  # kind of thing nobody notices in review.
  local hits
  hits="$(grep -rnoE '\b(vpn|portal|gw)[a-z0-9.-]*\.(com|net|org|io)\b' \
            "${REPO_ROOT}/README.md" "${REPO_ROOT}/docs" "${REPO_ROOT}/scripts" 2>/dev/null \
          | grep -vE 'example\.com|gitlab\.com|archive\.ubuntu\.com|github\.com' || true)"
  [ -z "$hits" ] || fail "non-placeholder hostname in docs/scripts:"$'\n'"$hits"
}

@test "no secrets-shaped files are tracked" {
  local tracked
  tracked="$(cd "$REPO_ROOT" && git ls-files | grep -E '\.(ovpn|pem|key|crt|p12|pfx)$|credentials|secrets' || true)"
  [ -z "$tracked" ] || fail "secret-shaped file is tracked by git:"$'\n'"$tracked"
}
