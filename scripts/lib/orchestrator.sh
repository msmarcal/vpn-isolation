# shellcheck shell=bash
#
# Host-side helpers for create-vpn-lxd-container.sh: everything that renders
# and installs files into a container. Sourced by the orchestrator only; unlike
# common.sh, nothing here is copied into the container.
#
# Functions read the orchestrator's globals directly (PROTOCOL, ROUTES, LIB_DIR,
# VPN_IFACE) and expect the protocol plugin to be sourced already where they
# call into it (render_connect_vpn, render_env_file).

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
