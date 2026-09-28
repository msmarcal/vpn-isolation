#!/usr/bin/env bash
# Drive an SSO login for a container from the operator's own machine.
#
# The container cannot open a browser: it has none, no display, and no path to the
# operator's session, which is the isolation it exists for. This runs where a
# browser does exist, obtains what the exchange produces, and hands it to the
# container over standard input.
#
# It is optional in both directions. A container is fully usable without it -
# `lxc exec -t <name> -- vpn connect --sso` prints the login URL and prompts - and
# this falls back to exactly that when the automation it relies on is unavailable.
#
# It NEVER runs a VPN client. Isolating the VPN from the host is the whole point of
# this project, and a helper whose failure could connect the host instead of the
# container would defeat it. Nothing here invokes a client, and the extraction hook
# is forbidden from using its tool's exec mode for the same reason.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

usage() {
  cat <<'USAGE'
Usage: vpn-sso-login.sh <container>

Completes an SSO login for a container that was built for a protocol supporting
one, then brings its tunnel up. Run it from your own machine, not inside the
container.
USAGE
}

[[ $# -eq 1 ]] || { usage >&2; exit 2; }
NAME="$1"
case "$NAME" in -h|--help) usage; exit 0 ;; esac

command -v lxc >/dev/null 2>&1 || { echo "ERROR: lxc not found." >&2; exit 1; }

# A stopped container cannot be asked anything, and starting someone's container
# without being asked is a change to their environment. Refuse and say so.
status="$(lxc info "$NAME" 2>/dev/null | awk '/^Status:/ {print tolower($2)}')" || status=""
[[ -n "$status" ]] || { echo "ERROR: no container named '${NAME}'." >&2; exit 1; }
if [[ "$status" != "running" ]]; then
  echo "ERROR: ${NAME} is ${status}. Start it first: lxc start ${NAME}" >&2
  exit 1
fi

PROTOCOL="$(lxc file pull "${NAME}/etc/vpn-client.env" - 2>/dev/null \
              | awk -F= '/^VPN_PROTOCOL=/ {print $2; exit}')" || PROTOCOL=""
[[ -n "$PROTOCOL" ]] || {
  echo "ERROR: could not read VPN_PROTOCOL from ${NAME}." >&2
  echo "       Was this container created by create-vpn-lxd-container.sh?" >&2
  exit 1
}

PLUGIN="${LIB_DIR}/protocol-${PROTOCOL}.sh"
[[ -f "$PLUGIN" ]] || { echo "ERROR: no plugin for protocol '${PROTOCOL}'." >&2; exit 1; }

# shellcheck source=lib/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=/dev/null
source "$PLUGIN"

GATEWAY="$(lxc file pull "${NAME}/etc/vpn-client.env" - 2>/dev/null \
             | awk -F= '/^VPN_GATEWAY=/ {print $2; exit}')" || GATEWAY=""
export GATEWAY

fall_back() {
  echo "$1" >&2
  echo "Falling back to the container's own SSO flow: it prints the login URL" >&2
  echo "and prompts for what comes back." >&2
  echo >&2
  exec lxc exec -t "$NAME" -- vpn connect --sso
}

declare -f proto_sso_host_extract >/dev/null 2>&1 \
  || fall_back "protocol '${PROTOCOL}' has no host-side automation."

echo "==> Completing the SSO exchange for ${NAME} (${PROTOCOL})"

# The hook prints the declared values as name=value lines, or fails saying what it
# needs. Captured rather than piped straight through, so a failure does not send a
# half-written stream into the container.
VALUES="$(proto_sso_host_extract "$NAME")" || \
  fall_back "the host-side extraction did not produce the values."
[[ -n "$VALUES" ]] || fall_back "the host-side extraction produced nothing."

echo "==> Handing the values to ${NAME} over stdin"
# -T because there is nothing to type: the values arrive on standard input, which
# is also what keeps the credential out of any process's argument list.
printf '%s\n' "$VALUES" | lxc exec -T "$NAME" -- vpn connect --sso --from-stdin
