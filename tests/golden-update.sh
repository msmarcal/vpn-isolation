#!/usr/bin/env bash
# Regenerate tests/golden/connect-vpn.* from the current source.
#
# Run this ONLY after an intentional change to the assembly logic, a protocol
# snippet, or common.sh - then read the resulting diff before committing it. A
# golden file updated without reading the diff tests nothing.
#
# Usage: make golden-update   (or: tests/golden-update.sh)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The helpers expect the per-test tmpdir bats normally provides.
BATS_TEST_TMPDIR="$(mktemp -d)"
export BATS_TEST_TMPDIR
trap 'rm -rf "$BATS_TEST_TMPDIR"' EXIT

# shellcheck source=helpers/load.bash
source "${REPO_ROOT}/tests/helpers/load.bash"
# shellcheck source=helpers/mock-lxc.bash
source "${REPO_ROOT}/tests/helpers/mock-lxc.bash"

setup_mock_lxc
mkdir -p "$GOLDEN_DIR"

for proto in $(all_protocols); do
  : > "$LXC_CALLS"
  rm -f "${CAPTURE_DIR}/connect-vpn"
  # stdin from /dev/null: the orchestrator must never block on input here.
  run_orchestrator "$proto" >/dev/null 2>&1 < /dev/null
  cp "${CAPTURE_DIR}/connect-vpn" "${GOLDEN_DIR}/connect-vpn.${proto}"
  printf '  %-12s %s lines\n' "$proto" "$(wc -l < "${GOLDEN_DIR}/connect-vpn.${proto}")"
done

echo
echo "Golden files regenerated. Review the diff before committing:"
echo "  git diff tests/golden/"
