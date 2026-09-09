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
#     --routes 10.10.0.0/24 --dns-domain internal.example.com \
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
declare -a AVAILABLE_PROTOCOLS=()
for f in "${LIB_DIR}"/protocol-*.sh; do
  [[ -e "$f" ]] || continue
  AVAILABLE_PROTOCOLS+=("$(basename "$f" .sh | sed 's/^protocol-//')")
done

NAME=""
PROTOCOL=""
GATEWAY=""
ROUTES=""
DNS_DOMAIN=""
OVPN=""
CONTAINER_USER="root"
IMAGE="ubuntu:24.04"
BUILD_OPENCONNECT=0
PRIVILEGED=0
PROFILE="vpn-client"
OPENCONNECT_TAG="v9.21"
ROUTE_NOPULL=1
LAUNCHPAD_ID=""
GITHUB_ID=""
FORTI_USER=""

usage() {
  cat <<EOF
Usage:
  create-vpn-lxd-container.sh --name NAME --protocol PROTO --routes CIDRS [options]

Required:
  --name NAME              Container name (e.g. vpn-example-anyconnect)
  --protocol PROTO         One of: ${AVAILABLE_PROTOCOLS[*]}
  --routes CIDRS           Comma-separated split routes (e.g. 10.1.0.0/16,10.2.0.0/24)

Protocol-specific:
  --gateway HOST[/path]    Required for anyconnect/gp
  --ovpn FILE              Required for openvpn (.ovpn profile path on host)

Optional:
  --dns-domain DOMAIN      Informational / helper default domain
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
  -h, --help               Show this help

Adding a new protocol: see docs/adding-a-protocol.md - no changes to this
file are required, just drop scripts/lib/protocol-<name>.sh.
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="${2:-}"; shift 2 ;;
    --protocol) PROTOCOL="${2:-}"; shift 2 ;;
    --gateway) GATEWAY="${2:-}"; shift 2 ;;
    --routes) ROUTES="${2:-}"; shift 2 ;;
    --dns-domain) DNS_DOMAIN="${2:-}"; shift 2 ;;
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
    -h|--help) usage ;;
    *) echo "Unknown arg: $1" >&2; usage ;;
  esac
done

if [[ -z "$NAME" || -z "$PROTOCOL" || -z "$ROUTES" ]]; then
  echo "ERROR: --name, --protocol and --routes are required." >&2
  usage
fi

PROTOCOL_LIB="${LIB_DIR}/protocol-${PROTOCOL}.sh"
if [[ ! -f "$PROTOCOL_LIB" ]]; then
  echo "ERROR: unsupported --protocol '$PROTOCOL' (available: ${AVAILABLE_PROTOCOLS[*]})" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$PROTOCOL_LIB"

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

if ! lxc profile device get "$PROFILE" tun type >/dev/null 2>&1; then
  lxc profile device add "$PROFILE" tun unix-char path=/dev/net/tun
fi

# PPP device required for FortiSSL VPN (openfortivpn uses pppd)
if ! lxc profile device get "$PROFILE" ppp type >/dev/null 2>&1; then
  lxc profile device add "$PROFILE" ppp unix-char path=/dev/ppp mode=0666
fi

lxc profile set "$PROFILE" security.nesting true >/dev/null

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
    if [[ -x /usr/sbin/openconnect && ! -L /usr/sbin/openconnect ]]; then
      dpkg-divert --local --rename --divert /usr/sbin/openconnect.dpkg-old /usr/sbin/openconnect || true
      ln -sf /usr/local/sbin/openconnect /usr/sbin/openconnect
    fi
    openconnect --version | head -3
  "
fi

echo "==> Writing /etc/vpn-client.env"
ENV_EXTRA="$(proto_write_env_extra)"
# Allow protocol to override the default interface name (e.g. fortissl needs ppp0)
VPN_IFACE="vpn0"
if declare -f proto_write_env_interface >/dev/null 2>&1; then
  VPN_IFACE="$(proto_write_env_interface)"
fi
lxc exec "$NAME" -- bash -lc "cat > /etc/vpn-client.env <<EOF
# Managed by create-vpn-lxd-container.sh
VPN_PROTOCOL=${PROTOCOL}
VPN_ROUTES=${ROUTES}
VPN_DNS_DOMAIN=${DNS_DOMAIN}
VPN_INTERFACE=${VPN_IFACE}
${ENV_EXTRA}
EOF
chmod 644 /etc/vpn-client.env
"

# Optional protocol-side host hook (e.g. openvpn pushing the .ovpn profile)
if declare -f proto_post_install >/dev/null 2>&1; then
  proto_post_install "$NAME"
fi

echo "==> Installing connect-vpn / disconnect-vpn"
# Assemble the in-container connect-vpn script: shared helpers (common.sh) +
# this protocol's proto_connect implementation + a small runner.
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
  cat "${LIB_DIR}/common.sh" | grep -v '^# lib/common.sh' | grep -v '^# Shared shell functions'
  echo
  echo "# ---- protocol implementation (scripts/lib/protocol-${PROTOCOL}.sh) ----"
  proto_connect_snippet
  cat <<'RUNNER'

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
)"

printf '%s\n' "$CONNECT_VPN_BODY" | lxc exec "$NAME" -- bash -c 'cat > /usr/local/bin/connect-vpn && chmod +x /usr/local/bin/connect-vpn'

lxc exec "$NAME" -- bash -lc 'cat > /usr/local/bin/disconnect-vpn <<'\''EOF'\''
#!/usr/bin/env bash
set -euo pipefail
ENV_FILE=/etc/vpn-client.env
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
VPN_INTERFACE="${VPN_INTERFACE:-vpn0}"

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
  # Kill screen session first (cleaner)
  sudo screen -S vpn-session -X quit 2>/dev/null || true
  sleep 1
  # Fallback: kill any remaining openfortivpn processes
  sudo pkill -TERM openfortivpn 2>/dev/null || true
  sleep 1
  sudo pkill -KILL openfortivpn 2>/dev/null || true
fi

for iface in "$VPN_INTERFACE" vpn0 tun0 ppp0; do
  if ip link show "$iface" >/dev/null 2>&1; then
    echo "Deleting $iface..."
    sudo ip link set "$iface" down 2>/dev/null || true
    sudo ip link delete "$iface" 2>/dev/null || true
  fi
done

echo "VPN down."
EOF
chmod +x /usr/local/bin/disconnect-vpn
'

echo "==> Passwordless sudo for VPN helpers (${CONTAINER_USER})"
if [[ "$CONTAINER_USER" != "root" ]]; then
  lxc exec "$NAME" -- bash -lc "
    if ! id '${CONTAINER_USER}' >/dev/null 2>&1; then
      useradd -m -s /bin/bash '${CONTAINER_USER}'
    fi
    usermod -aG sudo '${CONTAINER_USER}' 2>/dev/null || true
    cat > /etc/sudoers.d/vpn-client <<SUDO
${CONTAINER_USER} ALL=(root) NOPASSWD: /usr/sbin/openconnect, /usr/local/sbin/openconnect, /usr/sbin/openvpn, /usr/sbin/ip, /usr/bin/ip, /usr/bin/pkill, /usr/bin/kill
SUDO
    chmod 440 /etc/sudoers.d/vpn-client
  "
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

cat <<EOF

============================================================
Container ready: ${NAME}
  Protocol     : ${PROTOCOL}
  IP on lxdbr0 : ${IP:-<pending - run: lxc list ${NAME}>}
  Gateway/ovpn : ${GATEWAY:-${OVPN}}
  Split routes : ${ROUTES}
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
  sshuttle -r ${NAME} ${ROUTES//,/ } --dns

Docs: docs/lxd-vpn-client-containers.md
EOF
