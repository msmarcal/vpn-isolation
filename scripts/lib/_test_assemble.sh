#!/usr/bin/env bash
# Test harness: simulates the connect-vpn assembly block for one protocol
# without needing lxc/a real container. Usage: _test_assemble.sh <protocol>
set -euo pipefail

PROTOCOL="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

source "${LIB_DIR}/common.sh"
GATEWAY="vpn.example.com"
OVPN="/tmp/fake.ovpn"
ROUTES="10.0.0.0/24"
ROUTE_NOPULL=1
# shellcheck disable=SC1090
source "${LIB_DIR}/protocol-${PROTOCOL}.sh"

CONNECT_VPN_BODY="$(
  cat <<'HEADER'
#!/usr/bin/env bash
set -euo pipefail

ENV_FILE=/etc/vpn-client.env
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

VPN_PROTOCOL="${VPN_PROTOCOL:?Set VPN_PROTOCOL in /etc/vpn-client.env}"
VPN_ROUTES="${VPN_ROUTES:-}"
VPN_INTERFACE="${VPN_INTERFACE:-vpn0}"

HEADER
  echo "# ---- shared helpers (scripts/lib/common.sh) ----"
  grep -v '^# lib/common.sh' "${LIB_DIR}/common.sh" | grep -v '^# Shared shell functions'
  echo
  echo "# ---- protocol implementation (scripts/lib/protocol-${PROTOCOL}.sh) ----"
  proto_connect_snippet
  cat <<'RUNNER'

if pgrep -x openconnect >/dev/null 2>&1 || pgrep -x openvpn >/dev/null 2>&1; then
  echo "A VPN client is already running. Run disconnect-vpn first." >&2
  exit 1
fi

proto_connect

echo
echo "VPN up on ${VPN_INTERFACE}."
ip -br addr show "$VPN_INTERFACE" || true
echo "Relevant routes:"
ip route | grep -E "${VPN_INTERFACE}|$(echo "$VPN_ROUTES" | tr "," "|")" || ip route
RUNNER
)"

printf '%s\n' "$CONNECT_VPN_BODY"
