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
#      proto_connect, then hands the interface that came up to finish_connect,
#      which resolves the route set, applies it, records the connection and
#      reports. The runner owns the sequence; common.sh owns the steps, so that
#      an extra helper a plugin installs reaches the same path.
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
  # The plugin's client process names, needed twice inside the container: to
  # refuse starting on top of a live tunnel, and by record_connection to find
  # the running client's PID.
  printf '\nVPN_CLIENT_PROCESSES=%s\n' "$(printf '%q' "$(proto_client_processes)")"
  # $p is meant literally here: it expands inside the container.
  # shellcheck disable=SC2016
  printf 'for p in $VPN_CLIENT_PROCESSES; do\n'
  cat <<'RUNNER'
  if pgrep -x "$p" >/dev/null 2>&1; then
    echo "A VPN client ($p) is already running. Run disconnect-vpn first." >&2
    exit 1
  fi
done

# proto_connect authenticates, brings up the tunnel, and leaves the interface
# that actually appeared in VPN_INTERFACE. It does nothing about routing.
proto_connect

finish_connect "$VPN_INTERFACE"
RUNNER
}

# render_disconnect_vpn - print the in-container disconnect-vpn for $PROTOCOL.
# Like connect-vpn it carries common.sh verbatim, then the plugin's teardown:
# proto_disconnect_snippet when the plugin defines one (fortissl needs to close
# its screen session), otherwise a generic proto_disconnect that runs
# stop_client on each name from proto_client_processes.
render_disconnect_vpn() {
  cat <<'HEADER'
#!/usr/bin/env bash
set -euo pipefail
ENV_FILE=/etc/vpn-client.env
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
VPN_INTERFACE="${VPN_INTERFACE:-vpn0}"

HEADER
  echo "# ---- shared helpers (copied verbatim from scripts/lib/common.sh) ----"
  cat "${LIB_DIR}/common.sh"
  echo
  echo "# ---- protocol teardown (scripts/lib/protocol-${PROTOCOL}.sh) ----"
  if declare -f proto_disconnect_snippet >/dev/null 2>&1; then
    proto_disconnect_snippet
  else
    # $p is meant literally here: it expands inside the container.
    # shellcheck disable=SC2016
    printf 'proto_disconnect() {\n  local p\n  for p in %s; do\n    stop_client "$p" || true\n  done\n}\n' \
      "$(proto_client_processes)"
  fi
  cat <<'FOOTER'

proto_disconnect

# Sweep up interfaces the client left behind - a killed client does not always
# remove its own link. VPN_INTERFACE covers whatever the container was
# configured for; the rest are the names the supported clients actually use.
# Deleting a ppp link usually fails because pppd owns it and it disappears with
# the process, hence the tolerated errors.
for iface in "$VPN_INTERFACE" vpn0 tun0 ppp0; do
  if ip link show "$iface" >/dev/null 2>&1; then
    echo "Deleting $iface..."
    sudo ip link set "$iface" down 2>/dev/null || true
    sudo ip link delete "$iface" 2>/dev/null || true
  fi
done

echo "VPN down."
FOOTER
}

# render_sudoers USER - print the /etc/sudoers.d/vpn-client line for USER: the
# plugin's proto_sudo_commands plus what connect-vpn / disconnect-vpn themselves
# run under sudo (ip, pkill, kill).
#
# Deliberately NOT granted: tail. The only sudo tail calls are error-path log
# dumps guarded with '|| true', so they degrade to no output instead of
# failing, and granting it would hand this user root-read on every file.
render_sudoers() {
  local cmds
  # Word splitting is the point: one path per line for paste.
  # shellcheck disable=SC2046
  cmds="$(printf '%s\n' $(proto_sudo_commands) /usr/sbin/ip /usr/bin/ip /usr/bin/pkill /usr/bin/kill | paste -sd, - | sed 's/,/, /g')"
  printf '%s ALL=(root) NOPASSWD: %s\n' "$1" "$cmds"
}

# render_state_tmpfiles USER - print /etc/tmpfiles.d/vpn-client.conf.
#
# connect-vpn records the live connection under /run/vpn-client. /run is tmpfs
# and root-owned, so a non-root --user container cannot create that directory
# itself, and the sudoers allowlist deliberately grants no general-purpose
# write command. systemd-tmpfiles recreates it on every boot instead.
render_state_tmpfiles() {
  local user="$1"
  echo "# Managed by create-vpn-lxd-container.sh"
  echo "# Runtime directory for connect-vpn's connection record. Transient by"
  echo "# design: /run is tmpfs, so nothing here survives a container restart."
  printf 'd /run/vpn-client 0755 %s %s -\n' "$user" "$user"
}

# install_helpers NAME [USER] - render connect-vpn, disconnect-vpn and the
# state directory rule, and push them. USER defaults to root.
install_helpers() {
  local name="$1" user="${2:-root}" f
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

  render_state_tmpfiles "$user" > "${HELPER_WORK_DIR}/vpn-client.conf"
  lxc file push --uid 0 --gid 0 --mode 0644 \
    "${HELPER_WORK_DIR}/vpn-client.conf" "${name}/etc/tmpfiles.d/vpn-client.conf" >/dev/null
}

# install_state_dir NAME USER - create /run/vpn-client now.
#
# The tmpfiles rule install_helpers pushes only takes effect at the next boot,
# so the directory is created here too and a container works before it
# restarts. Must run AFTER the login user exists, which on the creation path is
# later than install_helpers - hence a separate function rather than a step
# inside it.
#
# Skipped when the container is stopped: `lxc file push` works on a stopped
# container, `lxc exec` does not, and /run is tmpfs so the rule covers it at
# next start anyway.
install_state_dir() {
  local name="$1" user="$2"
  if [[ "$(lxc info "$name" 2>/dev/null | awk '/^Status:/ {print tolower($2)}')" != "running" ]]; then
    return 0
  fi
  if ! lxc exec "$name" -- install -d -m 0755 -o "$user" -g "$user" /run/vpn-client 2>/dev/null; then
    echo "    NOTE: could not create /run/vpn-client now; it appears on next restart." >&2
  fi
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

# env_kv is defined in common.sh, not here. It is needed on both sides - the
# host writes /etc/vpn-client.env with it, and the container writes its
# connection record with it - and common.sh is the only file that travels.
# Plugins still call it from proto_write_env_extra exactly as before.

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
