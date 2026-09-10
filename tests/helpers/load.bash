# shellcheck shell=bash
# Shared setup for every .bats file.
#
# Sourced as: load ../helpers/load

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT
ORCHESTRATOR="${REPO_ROOT}/scripts/create-vpn-lxd-container.sh"
export ORCHESTRATOR
LIB_DIR="${REPO_ROOT}/scripts/lib"
export LIB_DIR
GOLDEN_DIR="${REPO_ROOT}/tests/golden"
export GOLDEN_DIR

# All protocols the repo ships, derived the same way the orchestrator derives
# them - so a new plugin is picked up by the tests with no edit here.
all_protocols() {
  local f
  for f in "${LIB_DIR}"/protocol-*.sh; do
    [[ -e "$f" ]] || continue
    basename "$f" .sh | sed 's/^protocol-//'
  done
}

# Fail with a message. bats reports the last output on failure, so print
# context before returning non-zero.
fail() {
  echo "$@" >&2
  return 1
}
