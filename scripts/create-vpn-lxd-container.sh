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

# shellcheck source=lib/orchestrator.sh
source "${LIB_DIR}/orchestrator.sh"

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
# Allow protocol to override the default interface name (e.g. fortissl needs ppp0).
# Read by render_env_file in lib/orchestrator.sh, which shellcheck cannot follow.
# shellcheck disable=SC2034
VPN_IFACE="vpn0"
if declare -f proto_write_env_interface >/dev/null 2>&1; then
  # shellcheck disable=SC2034
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
