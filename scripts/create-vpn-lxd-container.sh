#!/usr/bin/env bash
# create-vpn-lxd-container.sh
# Create an LXD container that isolates a corporate VPN from the host.
#
# Protocols are pluggable: each scripts/lib/protocol-<name>.sh implements a
# small contract of functions (see scripts/lib/protocol-openvpn.sh for the
# most complete example, or docs/adding-a-protocol.md for the full contract).
# This orchestrator never needs to change to add a new protocol - drop a new
# lib/protocol-<name>.sh file next to the others and it's available.
#
# Examples:
#   # Cisco AnyConnect
#   ./create-vpn-lxd-container.sh \
#     --name vpn-example-anyconnect --protocol anyconnect \
#     --gateway vpn.example.com/group-path \
#     --routes 10.10.0.0/24 \
#     --launchpad-id your-launchpad-id \
#     --build-openconnect
#
#   # GlobalProtect
#   ./create-vpn-lxd-container.sh \
#     --name vpn-example-globalprotect --protocol gp \
#     --gateway vpn.example.com \
#     --routes 10.0.0.0/8 --build-openconnect
#
#   # OpenVPN
#   ./create-vpn-lxd-container.sh \
#     --name vpn-example-openvpn --protocol openvpn \
#     --ovpn ~/Downloads/profile.ovpn \
#     --routes 10.10.0.0/16
#
# Docs: docs/lxd-vpn-client-containers.md, docs/adding-a-protocol.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# shellcheck source=lib/common.sh
source "${LIB_DIR}/common.sh"

# Discover available protocols from lib/protocol-*.sh (sorted, stable order).
# Each plugin's PROTO_DESC is extracted with sed rather than by sourcing the
# file: usage() runs before any protocol lib is sourced, and --help must never
# execute plugin code just to print a list.
declare -a AVAILABLE_PROTOCOLS=()
declare -a PROTOCOL_SUMMARIES=()
for f in "${LIB_DIR}"/protocol-*.sh; do
  [[ -e "$f" ]] || continue
  proto_name="$(basename "$f" .sh | sed 's/^protocol-//')"
  proto_desc="$(sed -n 's/^PROTO_DESC="\(.*\)"[[:space:]]*$/\1/p' "$f" | head -1)"
  AVAILABLE_PROTOCOLS+=("$proto_name")
  PROTOCOL_SUMMARIES+=("$(printf '%-12s %s' "$proto_name" "${proto_desc:-(no PROTO_DESC set)}")")
done

NAME=""
PROTOCOL=""
GATEWAY=""
ROUTES=""
OVPN=""
CONTAINER_USER="root"
IMAGE="ubuntu:24.04"
BUILD_OPENCONNECT=0
PRIVILEGED=0
PROFILE="vpn-client"
OPENCONNECT_TAG="v9.21"
LAUNCHPAD_ID=""
GITHUB_ID=""
REFRESH_HELPERS=0

# These are consumed indirectly: the sourced protocol lib reads them from
# proto_validate_args / proto_write_env_extra, so nothing in THIS file
# references them and shellcheck cannot see the use.
# shellcheck disable=SC2034
ROUTE_NOPULL=1   # openvpn
# shellcheck disable=SC2034
FORTI_USER=""    # fortissl
# shellcheck disable=SC2034
FORTI_PORT=""    # fortissl

# usage - print help on stdout. It does not exit: --help ends with status 0,
# while argument errors send the same text to stderr and end with status 1, so
# a wrapper can tell asking for help apart from calling the script wrong.
usage() {
  cat <<EOF
Usage:
  create-vpn-lxd-container.sh --name NAME --protocol PROTO [options]
  create-vpn-lxd-container.sh --name NAME --refresh-helpers

Required:
  --name NAME              Container name (e.g. vpn-example-anyconnect)
  --protocol PROTO         One of:
$(printf '                             %s\n' "${PROTOCOL_SUMMARIES[@]}")

Protocol-specific:
  --gateway HOST[/path]    Required for anyconnect/gp/fortissl
  --ovpn FILE              Required for openvpn (.ovpn profile path on host)

Optional:
  --routes CIDRS           Comma-separated split routes (e.g. 10.1.0.0/16,10.2.0.0/24).
                            Each entry needs an explicit prefix (/32 for one
                            host) and no host bits set; checked before anything
                            is created. Defaults to 'auto': ask the protocol to
                            detect the server-pushed routes after connecting
                            (implemented for anyconnect; other protocols add no
                            manual routes). Editable later in /etc/vpn-client.env.
  --user USER              Container login user (default: root - always exists;
                            if set to a non-root user that doesn't exist yet,
                            it will be created with sudo + a home dir)
  --image IMAGE            LXD image (default: ubuntu:24.04)
  --build-openconnect      Build openconnect 9.21 from source (recommended for Cisco/GP)
  --privileged             Run container privileged (if tun/routing fails)
  --profile NAME           LXD profile name (default: vpn-client)
  --no-route-nopull        For openvpn: allow server-pushed default route
  --launchpad-id ID        Import SSH keys via 'ssh-import-id lp:ID' (preferred)
  --github-id ID           Import SSH keys via 'ssh-import-id gh:ID' (combinable with --launchpad-id)
  --forti-user USER        For fortissl: FortiGate SSL VPN username (stored in /etc/vpn-client.env)
  --forti-port PORT        For fortissl: gateway port (default: 443)
  --refresh-helpers        Regenerate connect-vpn, disconnect-vpn and (for a
                            non-root container) the sudoers allowlist inside an
                            EXISTING container, from the current source. Works
                            on a stopped container. Leaves /etc/vpn-client.env,
                            packages and SSH keys untouched. The protocol is
                            read from the container; --protocol is optional.
  -h, --help               Show this help

Adding a new protocol: see docs/adding-a-protocol.md - no changes to this
file are required, just drop scripts/lib/protocol-<name>.sh.
EOF
}

# ---------------------------------------------------------------------------
# Generated in-container helpers
#
# connect-vpn, disconnect-vpn and the sudoers allowlist are rendered here on the
# host into local files, then copied into the container with `lxc file push`.
# Container creation and --refresh-helpers share these render functions, so an
# existing container gets exactly what a fresh one would; and `lxc file push`
# works on a stopped container, where `lxc exec` does not.
# ---------------------------------------------------------------------------

HELPER_WORK_DIR=""

cleanup_helper_work_dir() {
  if [[ -n "$HELPER_WORK_DIR" ]]; then
    rm -rf "$HELPER_WORK_DIR"
  fi
}

helper_work_dir() {
  if [[ -z "$HELPER_WORK_DIR" ]]; then
    HELPER_WORK_DIR="$(mktemp -d)"
    trap cleanup_helper_work_dir EXIT
  fi
}

# render_connect_vpn - print the in-container connect-vpn for $PROTOCOL.
# The protocol lib must already be sourced (for proto_connect_snippet).
#
# The script is four concatenated pieces:
#
#   1. a header that sources /etc/vpn-client.env and pins the variables every
#      protocol can rely on;
#   2. lib/common.sh COPIED VERBATIM - not sourced. The container has no copy of
#      this repo, so the helpers have to travel inside the generated script.
#      That is why common.sh must stay self-contained and must not depend on
#      anything beyond the base package set;
#   3. the text emitted by this protocol's proto_connect_snippet, which defines
#      the proto_connect function;
#   4. a fixed runner that refuses to start on top of a live tunnel, calls
#      proto_connect, and prints the resulting interface and routes.
#
# Nothing at runtime reads this repo again.
render_connect_vpn() {
  cat <<'HEADER'
#!/usr/bin/env bash
set -euo pipefail

ENV_FILE=/etc/vpn-client.env
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

VPN_PROTOCOL="${VPN_PROTOCOL:?Set VPN_PROTOCOL in /etc/vpn-client.env}"
VPN_ROUTES="${VPN_ROUTES:-}"
VPN_INTERFACE="${VPN_INTERFACE:-vpn0}"

HEADER
  echo "# ---- shared helpers (copied verbatim from scripts/lib/common.sh) ----"
  cat "${LIB_DIR}/common.sh"
  echo
  echo "# ---- protocol implementation (scripts/lib/protocol-${PROTOCOL}.sh) ----"
  proto_connect_snippet
  cat <<'RUNNER'

# HARDCODED CLIENT LIST (1 of 3) - a new protocol must add its client binary
# here, in disconnect-vpn, and in the sudoers allowlist. A client missing from
# this guard lets a second connect-vpn start on top of a live tunnel.
# See docs/adding-a-protocol.md.
if pgrep -x openconnect >/dev/null 2>&1 || pgrep -x openvpn >/dev/null 2>&1 || pgrep -x openfortivpn >/dev/null 2>&1; then
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
}

# render_disconnect_vpn - print the in-container disconnect-vpn. It is the same
# for every protocol. The quoted heredoc delimiter keeps $VPN_INTERFACE and
# friends literal, so they expand inside the container at disconnect time.
render_disconnect_vpn() {
  cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ENV_FILE=/etc/vpn-client.env
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
VPN_INTERFACE="${VPN_INTERFACE:-vpn0}"

# HARDCODED CLIENT LIST (2 of 3) - see docs/adding-a-protocol.md.
# One block per known client binary. A protocol whose client is missing here is
# never stopped, and this script still reports "VPN down." at the end, so the
# omission looks like success while the tunnel stays up. Each block is a no-op
# when that client is not running, so adding one is always safe.

if pgrep -x openconnect >/dev/null 2>&1; then
  echo "Stopping openconnect..."
  sudo pkill -TERM openconnect || true
  sleep 1
  sudo pkill -KILL openconnect 2>/dev/null || true
fi

if pgrep -x openvpn >/dev/null 2>&1; then
  echo "Stopping openvpn..."
  if [[ -f /run/openvpn-client.pid ]]; then
    sudo kill "$(cat /run/openvpn-client.pid)" 2>/dev/null || true
  fi
  sudo pkill -TERM openvpn || true
  sleep 1
  sudo pkill -KILL openvpn 2>/dev/null || true
fi

if pgrep -x openfortivpn >/dev/null 2>&1; then
  echo "Stopping openfortivpn..."
  # SIGTERM first and wait for it to exit, so it logs out of the gateway and
  # releases /dev/ppp itself. Closing the screen session while it is still
  # tearing down can leave /dev/ppp unusable ("Could not set tty to PPP
  # discipline") until the container is restarted. Give up after 15 seconds.
  sudo pkill -TERM openfortivpn 2>/dev/null || true
  for _ in $(seq 1 15); do
    pgrep -x openfortivpn >/dev/null 2>&1 || break
    sleep 1
  done
  # Now it is safe to close the (now-empty) screen session
  sudo screen -S vpn-session -X quit 2>/dev/null || true
  # Fallback: force-kill anything still around, and say so - a forced kill is
  # the case that can leave /dev/ppp stuck and need an lxc restart.
  if pgrep -x openfortivpn >/dev/null 2>&1; then
    echo "openfortivpn did not exit within 15s of SIGTERM; killing it." >&2
    echo "If the next connect fails with a PPP discipline error, run: lxc restart <container>" >&2
    sudo pkill -KILL openfortivpn 2>/dev/null || true
  fi
fi

# Sweep up interfaces the clients above left behind - a killed client does not
# always remove its own link. VPN_INTERFACE covers whatever the container was
# configured for; the rest are the names the supported clients actually use.
# Extend this list if a new protocol names its tunnel something else. Deleting
# a ppp link usually fails because pppd owns it and it disappears with the
# process, hence the tolerated errors.
for iface in "$VPN_INTERFACE" vpn0 tun0 ppp0; do
  if ip link show "$iface" >/dev/null 2>&1; then
    echo "Deleting $iface..."
    sudo ip link set "$iface" down 2>/dev/null || true
    sudo ip link delete "$iface" 2>/dev/null || true
  fi
done

echo "VPN down."
EOF
}

# render_sudoers USER - print the /etc/sudoers.d/vpn-client line for USER.
#
# HARDCODED CLIENT LIST (3 of 3) - see docs/adding-a-protocol.md.
# Every VPN client binary that connect-vpn / disconnect-vpn invoke under sudo
# has to be listed here, or the helpers stall on a password prompt. A new
# protocol adds its client (and any wrapper it needs, the way fortissl needs
# screen) to this line.
#
# Deliberately NOT granted: tail. The only sudo tail calls are error-path log
# dumps guarded with '|| true', so they degrade to no output instead of
# failing, and granting it would hand this user root-read on every file.
render_sudoers() {
  printf '%s ALL=(root) NOPASSWD: /usr/sbin/openconnect, /usr/local/sbin/openconnect, /usr/sbin/openvpn, /usr/bin/openfortivpn, /usr/bin/screen, /usr/sbin/ip, /usr/bin/ip, /usr/bin/pkill, /usr/bin/kill\n' "$1"
}

# install_helpers NAME - render connect-vpn and disconnect-vpn and push them.
install_helpers() {
  local name="$1" f
  helper_work_dir
  render_connect_vpn > "${HELPER_WORK_DIR}/connect-vpn"
  render_disconnect_vpn > "${HELPER_WORK_DIR}/disconnect-vpn"
  for f in connect-vpn disconnect-vpn; do
    # The generated text is only ever parsed inside the container, so a broken
    # protocol snippet would otherwise surface on the next real connect.
    if ! bash -n "${HELPER_WORK_DIR}/${f}"; then
      echo "ERROR: generated ${f} does not parse; not installing it." >&2
      exit 1
    fi
    lxc file push --uid 0 --gid 0 --mode 0755 \
      "${HELPER_WORK_DIR}/${f}" "${name}/usr/local/bin/${f}" >/dev/null
  done
}

# install_sudoers NAME USER - render the allowlist for USER and push it.
install_sudoers() {
  local name="$1" user="$2"
  helper_work_dir
  render_sudoers "$user" > "${HELPER_WORK_DIR}/vpn-client"
  # A malformed file in sudoers.d breaks sudo for the whole container, not just
  # for these helpers, so validate it on the host first when visudo is there.
  if command -v visudo >/dev/null 2>&1 \
     && ! visudo -cf "${HELPER_WORK_DIR}/vpn-client" >/dev/null; then
    echo "ERROR: generated sudoers entry failed 'visudo -c'; not installing it." >&2
    exit 1
  fi
  lxc file push --uid 0 --gid 0 --mode 0440 \
    "${HELPER_WORK_DIR}/vpn-client" "${name}/etc/sudoers.d/vpn-client" >/dev/null
}

# ---------------------------------------------------------------------------
# /etc/vpn-client.env
#
# connect-vpn and disconnect-vpn `source` this file, so every value in it is
# shell syntax, not plain text. Values come straight from the command line
# (--gateway, --forti-user, ...); written raw, a space would make `source` run
# the rest of the value as a command, an apostrophe would break the whole file,
# and `$(...)` would execute. So the file is rendered on the host with env_kv
# and copied in with `lxc file push`, which does no expansion.
# ---------------------------------------------------------------------------

# env_kv KEY VALUE - print one assignment, quoted so that `source` yields VALUE
# back byte for byte.
#
# Values made only of characters that are literal in an assignment (hostnames,
# paths, CIDR lists, numbers) are written bare, so the file stays easy to edit
# by hand. Anything else is single-quoted, with embedded single quotes written
# as '\''. Not `printf %q`: it also escapes commas, turning a,b into a\,b.
#
# Protocol plugins call this from proto_write_env_extra, so it is part of the
# plugin contract - see docs/adding-a-protocol.md.
env_kv() {
  local key="$1" value="$2"
  if [[ "$value" =~ ^[A-Za-z0-9._/:,@%+=-]*$ ]]; then
    printf '%s=%s\n' "$key" "$value"
  else
    printf "%s='%s'\n" "$key" "${value//\'/\'\\\'\'}"
  fi
}

# render_env_file - print /etc/vpn-client.env for the current configuration.
render_env_file() {
  echo "# Managed by create-vpn-lxd-container.sh"
  env_kv VPN_PROTOCOL "$PROTOCOL"
  env_kv VPN_ROUTES "$ROUTES"
  env_kv VPN_INTERFACE "$VPN_IFACE"
  proto_write_env_extra
}

# install_env_file NAME - render /etc/vpn-client.env and push it.
install_env_file() {
  local name="$1"
  helper_work_dir
  render_env_file > "${HELPER_WORK_DIR}/vpn-client.env"
  if ! bash -n "${HELPER_WORK_DIR}/vpn-client.env"; then
    echo "ERROR: generated /etc/vpn-client.env does not parse; not installing it." >&2
    exit 1
  fi
  # 0644 on purpose: this file is configuration only and never holds a password
  # or token (those are prompted for on every connect). Any protocol that would
  # need a secret in here must not put it in this file.
  lxc file push --uid 0 --gid 0 --mode 0644 \
    "${HELPER_WORK_DIR}/vpn-client.env" "${name}/etc/vpn-client.env" >/dev/null
}

# validate_routes LIST - exit 1 with a specific message unless LIST is "auto" or
# a comma-separated list of CIDRs that `ip route replace` will take as-is.
#
# This matters more than it looks: apply_split_routes tolerates `ip route`
# failures (`|| true`), so a malformed or host-bits-set entry does not fail the
# connect - the route is silently missing and internal hosts just time out.
# Catching it here, on the host and before any lxc call, turns that into an
# error at the moment the typo is made.
validate_routes() {
  local list="$1" cidr addr prefix a b c d ip mask net
  [[ "$list" == "auto" ]] && return 0

  if [[ -z "$list" || "$list" == ,* || "$list" == *, || "$list" == *,,* ]]; then
    echo "ERROR: --routes '${list}' has an empty entry (check for stray commas)." >&2
    exit 1
  fi

  local -a items
  IFS=',' read -ra items <<< "$list"
  for cidr in "${items[@]}"; do
    if [[ "$cidr" == "auto" ]]; then
      echo "ERROR: --routes: 'auto' cannot be combined with explicit CIDRs." >&2
      exit 1
    fi
    if [[ "$cidr" != */* ]]; then
      echo "ERROR: --routes: '${cidr}' has no prefix length. For a single host use '${cidr}/32'." >&2
      exit 1
    fi
    addr="${cidr%/*}"
    prefix="${cidr##*/}"

    if [[ "$addr" == *:* ]]; then
      # IPv6: shape and prefix range only. Full validation is not worth doing
      # in bash; this still catches separators and stray characters.
      if [[ ! "$addr" =~ ^[0-9a-fA-F:]+$ || "$addr" == *:::* \
            || ! "$prefix" =~ ^(0|[1-9][0-9]{0,2})$ ]] || (( prefix > 128 )); then
        echo "ERROR: --routes: '${cidr}' is not a valid IPv6 CIDR." >&2
        exit 1
      fi
      continue
    fi

    # IPv4. Leading zeros are rejected: some tools read them as octal.
    if [[ ! "$addr" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]]; then
      echo "ERROR: --routes: '${cidr}' is not a valid IPv4 CIDR." >&2
      exit 1
    fi
    a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"; c="${BASH_REMATCH[3]}"; d="${BASH_REMATCH[4]}"
    if (( a > 255 || b > 255 || c > 255 || d > 255 )); then
      echo "ERROR: --routes: '${cidr}' has an octet above 255." >&2
      exit 1
    fi
    if [[ ! "$prefix" =~ ^(0|[1-9][0-9]?)$ ]] || (( prefix > 32 )); then
      echo "ERROR: --routes: '${cidr}' has an invalid prefix length (0-32)." >&2
      exit 1
    fi

    # `ip route` rejects a network with host bits set ("Invalid prefix for
    # given prefix length"), and apply_split_routes would swallow that error.
    ip=$(( (a << 24) | (b << 16) | (c << 8) | d ))
    mask=$(( prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    if (( (ip & ~mask) & 0xFFFFFFFF )); then
      net=$(( ip & mask ))
      printf "ERROR: --routes: '%s' has host bits set. Did you mean %d.%d.%d.%d/%s?\n" \
        "$cidr" $(( (net >> 24) & 255 )) $(( (net >> 16) & 255 )) \
        $(( (net >> 8) & 255 )) $(( net & 255 )) "$prefix" >&2
      exit 1
    fi
  done
}

# ROUTE_NOPULL / FORTI_USER / FORTI_PORT are assigned here but read only by the
# protocol lib sourced further down, which shellcheck cannot follow.
# shellcheck disable=SC2034
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="${2:-}"; shift 2 ;;
    --protocol) PROTOCOL="${2:-}"; shift 2 ;;
    --gateway) GATEWAY="${2:-}"; shift 2 ;;
    --routes) ROUTES="${2:-}"; shift 2 ;;
    --ovpn) OVPN="${2:-}"; shift 2 ;;
    --user) CONTAINER_USER="${2:-}"; shift 2 ;;
    --image) IMAGE="${2:-}"; shift 2 ;;
    --build-openconnect) BUILD_OPENCONNECT=1; shift ;;
    --privileged) PRIVILEGED=1; shift ;;
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --no-route-nopull) ROUTE_NOPULL=0; shift ;;
    --launchpad-id) LAUNCHPAD_ID="${2:-}"; shift 2 ;;
    --github-id) GITHUB_ID="${2:-}"; shift 2 ;;
    --forti-user) FORTI_USER="${2:-}"; shift 2 ;;
    --forti-port) FORTI_PORT="${2:-}"; shift 2 ;;
    --refresh-helpers) REFRESH_HELPERS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$NAME" ]]; then
  echo "ERROR: --name is required." >&2
  usage >&2
  exit 1
fi

# --refresh-helpers: the container already exists and already knows which
# protocol it was built for, so read that back instead of trusting the caller.
# Rebuilding a fortissl container's helpers from the anyconnect snippet would
# silently leave it unable to connect.
if [[ "$REFRESH_HELPERS" -eq 1 ]]; then
  if ! command -v lxc >/dev/null 2>&1; then
    echo "ERROR: lxc not found. Install/configure LXD first." >&2
    exit 1
  fi
  if ! lxc info "$NAME" >/dev/null 2>&1; then
    echo "ERROR: container '${NAME}' does not exist; --refresh-helpers only updates an existing one." >&2
    exit 1
  fi
  # `lxc file pull` works on a stopped container, so nothing is started here.
  # `|| true`: under pipefail a missing file would otherwise abort right here,
  # before the explanatory error below gets printed.
  ENV_PROTOCOL="$(lxc file pull "${NAME}/etc/vpn-client.env" - 2>/dev/null \
    | sed -n 's/^VPN_PROTOCOL=//p' | head -1 || true)"
  if [[ -z "$ENV_PROTOCOL" ]]; then
    echo "ERROR: could not read VPN_PROTOCOL from ${NAME}:/etc/vpn-client.env." >&2
    echo "       Was this container created by create-vpn-lxd-container.sh?" >&2
    exit 1
  fi
  if [[ -n "$PROTOCOL" && "$PROTOCOL" != "$ENV_PROTOCOL" ]]; then
    echo "ERROR: ${NAME} was built for protocol '${ENV_PROTOCOL}', not '${PROTOCOL}'." >&2
    echo "       Refreshing it with another protocol's helpers would break it; recreate it instead." >&2
    exit 1
  fi
  PROTOCOL="$ENV_PROTOCOL"
fi

if [[ -z "$PROTOCOL" ]]; then
  echo "ERROR: --protocol is required." >&2
  usage >&2
  exit 1
fi

# The protocol name becomes part of a path that gets sourced. In refresh mode it
# comes from a file inside the container, so hold it to the shape a plugin
# filename can actually have before it gets anywhere near `source`.
if [[ ! "$PROTOCOL" =~ ^[a-z0-9-]+$ ]]; then
  echo "ERROR: invalid protocol name '${PROTOCOL}'." >&2
  exit 1
fi

# --routes is optional; defaults to "auto" for auto-detection if protocol supports it
ROUTES="${ROUTES:-auto}"

PROTOCOL_LIB="${LIB_DIR}/protocol-${PROTOCOL}.sh"
if [[ ! -f "$PROTOCOL_LIB" ]]; then
  echo "ERROR: unsupported --protocol '$PROTOCOL' (available: ${AVAILABLE_PROTOCOLS[*]})" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$PROTOCOL_LIB"

# PROTO_NAME is the plugin's self-declaration. Dispatch happens on the filename,
# so a mismatch means the plugin's own error messages would name a different
# protocol than the one the user asked for - catch it here rather than let it
# confuse whoever hits the error later.
if [[ "${PROTO_NAME:-}" != "$PROTOCOL" ]]; then
  echo "ERROR: ${PROTOCOL_LIB} declares PROTO_NAME='${PROTO_NAME:-<unset>}'," >&2
  echo "       but must declare '${PROTOCOL}' to match its filename." >&2
  exit 1
fi

if [[ "$REFRESH_HELPERS" -eq 1 ]]; then
  echo "==> Refreshing helpers in ${NAME} (protocol: ${PROTOCOL})"

  # The container's login user is not recorded anywhere except in the sudoers
  # entry this script wrote for it, so read it back from there. No entry means
  # a root container, which has no allowlist to refresh. Checked BEFORE pushing
  # anything, so a bad entry aborts the refresh instead of leaving it half done.
  SUDO_USER_IN_CONTAINER="$(lxc file pull "${NAME}/etc/sudoers.d/vpn-client" - 2>/dev/null \
    | awk '!/^[[:space:]]*(#|$)/ { print $1; exit }' || true)"
  if [[ -n "$SUDO_USER_IN_CONTAINER" && ! "$SUDO_USER_IN_CONTAINER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo "ERROR: unexpected user '${SUDO_USER_IN_CONTAINER}' in ${NAME}:/etc/sudoers.d/vpn-client; nothing was changed." >&2
    exit 1
  fi

  install_helpers "$NAME"
  echo "    /usr/local/bin/connect-vpn and /usr/local/bin/disconnect-vpn updated"

  if [[ -n "$SUDO_USER_IN_CONTAINER" ]]; then
    install_sudoers "$NAME" "$SUDO_USER_IN_CONTAINER"
    echo "    /etc/sudoers.d/vpn-client updated for ${SUDO_USER_IN_CONTAINER}"
  else
    echo "    no /etc/sudoers.d/vpn-client (root container); sudoers left alone"
  fi

  cat <<EOF

Done. /etc/vpn-client.env, packages and SSH keys were not touched.
The new helpers take effect on the next connect-vpn / disconnect-vpn run.
If a VPN is connected right now, the next disconnect-vpn already uses the new
teardown.
EOF
  exit 0
fi

# Whitespace cannot be part of a CIDR, so strip it rather than reject
# "10.1.0.0/16, 10.2.0.0/24" - the stored value is then the canonical form.
ROUTES="${ROUTES//[[:space:]]/}"
validate_routes "$ROUTES"

proto_validate_args

BUILD_OPENCONNECT_DEFAULT="$(proto_needs_build_openconnect)"
if [[ "$BUILD_OPENCONNECT" -eq 0 && "$BUILD_OPENCONNECT_DEFAULT" -eq 1 ]]; then
  echo "NOTE: protocol=${PROTOCOL} usually needs openconnect 9.21+. Consider re-running with --build-openconnect." >&2
fi

if ! command -v lxc >/dev/null 2>&1; then
  echo "ERROR: lxc not found. Install/configure LXD first." >&2
  exit 1
fi

echo "==> Ensuring LXD profile '${PROFILE}' exists"
if ! lxc profile show "$PROFILE" >/dev/null 2>&1; then
  lxc profile create "$PROFILE"
fi

if ! lxc profile device get "$PROFILE" eth0 type >/dev/null 2>&1; then
  lxc profile device add "$PROFILE" eth0 nic network=lxdbr0 name=eth0
fi

# /dev/net/tun: every tunnel-based client here (openconnect, openvpn) opens it
# to create its tun interface. Unprivileged containers do not get it by default.
if ! lxc profile device get "$PROFILE" tun type >/dev/null 2>&1; then
  lxc profile device add "$PROFILE" tun unix-char path=/dev/net/tun
fi

# PPP device required for FortiSSL VPN (openfortivpn uses pppd). 0660 is
# enough: connect-vpn always runs openfortivpn through sudo, so pppd opens the
# device as root even in a non-root --user container. Stated explicitly rather
# than relying on the LXD default.
if ! lxc profile device get "$PROFILE" ppp type >/dev/null 2>&1; then
  lxc profile device add "$PROFILE" ppp unix-char path=/dev/ppp mode=0660
fi

# Tighten a profile that still has the old 0666 mode. Existing containers pick
# it up on their next restart.
PPP_MODE="$(lxc profile device get "$PROFILE" ppp mode 2>/dev/null || echo "")"
if [[ -n "$PPP_MODE" && "$PPP_MODE" != "0660" ]]; then
  echo "    tightening /dev/ppp mode on profile '${PROFILE}': ${PPP_MODE} -> 0660"
  lxc profile device set "$PROFILE" ppp mode=0660
fi

# security.nesting is deliberately not set: nothing here runs a container inside
# the container, and tun, ppp and split routing were verified to work without
# it. Re-enable only for a specific, recorded failure.

if lxc info "$NAME" >/dev/null 2>&1; then
  echo "ERROR: container '${NAME}' already exists. Delete it first: lxc delete -f ${NAME}" >&2
  exit 1
fi

echo "==> Launching ${NAME} from ${IMAGE}"
lxc launch "$IMAGE" "$NAME" -p default -p "$PROFILE"

if [[ "$PRIVILEGED" -eq 1 ]]; then
  echo "==> Enabling privileged mode on ${NAME}"
  lxc config set "$NAME" security.privileged true
  lxc restart "$NAME"
fi

echo "==> Waiting for network and package manager"
for i in $(seq 1 60); do
  if lxc exec "$NAME" -- bash -c 'getent hosts archive.ubuntu.com >/dev/null 2>&1'; then
    break
  fi
  sleep 2
  if [[ "$i" -eq 60 ]]; then
    echo "WARNING: container network may not be ready yet; continuing anyway" >&2
  fi
done
# cloud-init may still hold the apt/dpkg lock right after boot; wait it out
lxc exec "$NAME" -- bash -c '
  for i in $(seq 1 60); do
    if command -v cloud-init >/dev/null 2>&1; then
      cloud-init status --wait >/dev/null 2>&1 && break
    fi
    if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
' || true

echo "==> Installing base packages"
lxc exec "$NAME" -- apt-get update -qq
lxc exec --env DEBIAN_FRONTEND=noninteractive "$NAME" -- apt-get install -y -qq \
  iproute2 iptables curl ca-certificates openssh-client openssh-server \
  iputils-ping dnsutils vim

# Word splitting on proto_apt_packages is intentional: it prints a space-
# separated package list that must reach apt-get as separate arguments.
# Quoting it would pass the whole list as one bogus package name.
# shellcheck disable=SC2046
lxc exec --env DEBIAN_FRONTEND=noninteractive "$NAME" -- apt-get install -y -qq $(proto_apt_packages)

if [[ "$BUILD_OPENCONNECT" -eq 1 ]]; then
  echo "==> Building openconnect ${OPENCONNECT_TAG} from source"
  lxc exec --env DEBIAN_FRONTEND=noninteractive "$NAME" -- apt-get install -y -qq \
    build-essential git pkg-config libxml2-dev libgnutls28-dev \
    libp11-kit-dev zlib1g-dev libpcsclite-dev libstoken-dev liblz4-dev \
    libproxy-dev libtss2-dev autoconf automake libtool gettext vpnc-scripts

  lxc exec "$NAME" -- bash -lc "
    set -euo pipefail
    cd /tmp
    rm -rf openconnect
    git clone --depth 1 --branch '${OPENCONNECT_TAG}' https://gitlab.com/openconnect/openconnect.git
    cd openconnect
    ./autogen.sh
    ./configure --prefix=/usr/local --with-vpnc-script=/usr/share/vpnc-scripts/vpnc-script
    make -j\"\$(nproc)\"
    make install
    ldconfig
    # The build installs into /usr/local/sbin, but the distro package owns
    # /usr/sbin/openconnect and that is what ends up being run. Move the
    # packaged binary aside with dpkg-divert (so a later apt upgrade does not
    # silently restore it) and point /usr/sbin at the freshly built one -
    # otherwise --build-openconnect appears to succeed while connect-vpn keeps
    # using the old version this flag exists to escape.
    if [[ -x /usr/sbin/openconnect && ! -L /usr/sbin/openconnect ]]; then
      dpkg-divert --local --rename --divert /usr/sbin/openconnect.dpkg-old /usr/sbin/openconnect || true
      ln -sf /usr/local/sbin/openconnect /usr/sbin/openconnect
    fi
    openconnect --version | head -3
  "
fi

echo "==> Writing /etc/vpn-client.env"
# Allow protocol to override the default interface name (e.g. fortissl needs ppp0)
VPN_IFACE="vpn0"
if declare -f proto_write_env_interface >/dev/null 2>&1; then
  VPN_IFACE="$(proto_write_env_interface)"
fi
install_env_file "$NAME"

# Optional protocol-side host hook (e.g. openvpn pushing the .ovpn profile)
if declare -f proto_post_install >/dev/null 2>&1; then
  proto_post_install "$NAME"
fi

echo "==> Installing connect-vpn / disconnect-vpn"
install_helpers "$NAME"

echo "==> Passwordless sudo for VPN helpers (${CONTAINER_USER})"
if [[ "$CONTAINER_USER" != "root" ]]; then
  lxc exec "$NAME" -- bash -lc "
    if ! id '${CONTAINER_USER}' >/dev/null 2>&1; then
      useradd -m -s /bin/bash '${CONTAINER_USER}'
    fi
    usermod -aG sudo '${CONTAINER_USER}' 2>/dev/null || true
  "
  # The allowlist itself lives in render_sudoers, shared with --refresh-helpers.
  install_sudoers "$NAME" "$CONTAINER_USER"
else
  echo "    (root user - sudo not needed, skipping sudoers setup)"
fi

echo "==> Importing SSH keys for ${CONTAINER_USER}"
lxc exec "$NAME" -- bash -lc 'command -v ssh-import-id >/dev/null 2>&1 || apt-get install -y -qq ssh-import-id'

IMPORT_IDS=()
[[ -n "$LAUNCHPAD_ID" ]] && IMPORT_IDS+=("lp:${LAUNCHPAD_ID}")
[[ -n "$GITHUB_ID" ]] && IMPORT_IDS+=("gh:${GITHUB_ID}")

if [[ ${#IMPORT_IDS[@]} -gt 0 ]]; then
  for id in "${IMPORT_IDS[@]}"; do
    echo "    ssh-import-id ${id} -> ${CONTAINER_USER}"
    if [[ "$CONTAINER_USER" == "root" ]]; then
      lxc exec "$NAME" -- ssh-import-id "$id"
    else
      lxc exec "$NAME" -- sudo -u "$CONTAINER_USER" -H ssh-import-id "$id"
    fi
  done
elif [[ -f "${HOME}/.ssh/id_ed25519.pub" || -f "${HOME}/.ssh/id_rsa.pub" ]]; then
  PUB="${HOME}/.ssh/id_ed25519.pub"
  [[ -f "$PUB" ]] || PUB="${HOME}/.ssh/id_rsa.pub"
  echo "    no --launchpad-id/--github-id given; falling back to local pubkey ${PUB}"
  lxc file push "$PUB" "$NAME/tmp/host.pub" >/dev/null
  lxc exec "$NAME" -- bash -lc "
    set -e
    u='${CONTAINER_USER}'
    home=\$(getent passwd \"\$u\" | cut -d: -f6)
    mkdir -p \"\$home/.ssh\"
    touch \"\$home/.ssh/authorized_keys\"
    cat /tmp/host.pub >> \"\$home/.ssh/authorized_keys\"
    sort -u \"\$home/.ssh/authorized_keys\" -o \"\$home/.ssh/authorized_keys\"
    chown -R \"\$u:\$u\" \"\$home/.ssh\"
    chmod 700 \"\$home/.ssh\"
    chmod 600 \"\$home/.ssh/authorized_keys\"
    rm -f /tmp/host.pub
  "
else
  echo "WARNING: no --launchpad-id/--github-id and no local pubkey found; ${CONTAINER_USER} has no authorized_keys yet." >&2
  echo "          Run manually: lxc exec ${NAME} -- sudo -u ${CONTAINER_USER} -H ssh-import-id lp:<your-launchpad-id>" >&2
fi

echo "==> Enabling sshd"
if [[ "$CONTAINER_USER" == "root" ]]; then
  # Debian/Ubuntu sshd defaults to PermitRootLogin prohibit-password, which is
  # actually fine for key-based auth - but be explicit so it survives package updates.
  lxc exec "$NAME" -- bash -lc "
    sed -i 's/^#\\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
  "
fi
lxc exec "$NAME" -- systemctl enable --now ssh >/dev/null

IP="$(lxc list "$NAME" -c 4 --format csv 2>/dev/null | head -1 | awk -F, '{print $1}' | awk '{print $1}')"
TOOL_VER="$(lxc exec "$NAME" -- bash -c "$(proto_version_cmd)" 2>/dev/null || echo unknown)"

# With --routes auto the CIDRs are only known after the first connect, so do
# not print "auto" as if it were a subnet sshuttle could use.
if [[ "$ROUTES" == "auto" ]]; then
  ROUTES_SUMMARY="auto (detected at connect time; connect-vpn prints them)"
  SSHUTTLE_ROUTES="<cidrs printed by connect-vpn>"
else
  ROUTES_SUMMARY="$ROUTES"
  SSHUTTLE_ROUTES="${ROUTES//,/ }"
fi

cat <<EOF

============================================================
Container ready: ${NAME}
  Protocol     : ${PROTOCOL}
  IP on lxdbr0 : ${IP:-<pending - run: lxc list ${NAME}>}
  Gateway/ovpn : ${GATEWAY:-${OVPN}}
  Split routes : ${ROUTES_SUMMARY}
  Client       : ${TOOL_VER}
============================================================

Daily use:
  lxc start ${NAME}
  lxc exec ${NAME} -- connect-vpn
  lxc exec ${NAME} -- disconnect-vpn
  lxc stop ${NAME}

Suggested SSH snippet (~/.ssh/config.d/):

Host ${NAME}
  HostName ${IP:-10.254.2.XX}
  User ${CONTAINER_USER}

Host <internal-alias>
  HostName <internal-ip>
  User <remote-user>
  ProxyJump ${NAME}

HTTP via sshuttle (transparent, no per-app proxy config):
  sshuttle -r ${NAME} ${SSHUTTLE_ROUTES} --dns

After pulling a newer version of this repo, update this container's helpers:
  ./scripts/create-vpn-lxd-container.sh --name ${NAME} --refresh-helpers

Docs: docs/lxd-vpn-client-containers.md
EOF
