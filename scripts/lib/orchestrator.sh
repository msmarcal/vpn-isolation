# shellcheck shell=bash
#
# Host-side helpers for create-vpn-lxd-container.sh: everything that renders
# and installs files into a container. Sourced by the orchestrator only; unlike
# common.sh, nothing here is copied into the container.
#
# Functions read the orchestrator's globals directly (PROTOCOL, ROUTES, LIB_DIR,
# VPN_IFACE) and expect the protocol plugin to be sourced already where they
# call into it (render_vpn, render_env_file).

# ---------------------------------------------------------------------------
# Generated in-container command
#
# The container's `vpn` command and the sudoers allowlist are rendered here on
# the host into local files, then copied into the container with `lxc file push`.
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

# proto_has_sso - true when the sourced plugin implements the SSO path.
#
# All of the container-side functions or none: a partial set is refused at startup
# with the missing name, the same way an incomplete required contract is. A plugin
# that defines none simply has no SSO path, which is not an error.
SSO_REQUIRED_FNS="proto_sso_url_snippet proto_sso_connect_snippet proto_sso_values"

proto_has_sso() {
  local fn found=0 missing=""
  for fn in $SSO_REQUIRED_FNS; do
    if declare -f "$fn" >/dev/null 2>&1; then found=1; else missing+="${fn} "; fi
  done
  (( found )) || return 1
  if [[ -n "$missing" ]]; then
    echo "ERROR: ${PROTOCOL} implements part of the SSO contract but is missing:" >&2
    echo "       ${missing% }" >&2
    echo "       It is all of ${SSO_REQUIRED_FNS} or none - see docs/adding-a-protocol.md." >&2
    exit 1
  fi
  return 0
}

# render_vpn - print the in-container `vpn` command for $PROTOCOL.
# The protocol lib must already be sourced.
#
# One script, five concatenated pieces:
#
#   1. a header that sources /etc/vpn-client.env and pins the variables every
#      protocol can rely on;
#   2. lib/common.sh COPIED VERBATIM - not sourced. The container has no copy of
#      this repo, so the helpers have to travel inside the generated script.
#      That is why common.sh must stay self-contained and must not depend on
#      anything beyond the base package set;
#   3. the text emitted by this protocol's proto_connect_snippet, defining
#      proto_connect;
#   4. the teardown - proto_disconnect_snippet when the plugin defines one
#      (fortissl needs to close its screen session), otherwise a generic
#      proto_disconnect running stop_client on each declared process name;
#   5. the dispatcher, which is the container's whole command surface.
#
# This replaced a pair of scripts that each carried their own copy of
# common.sh. One file means one copy, one parse check and one push - and one
# name in the operator's path, which is the point: a container runs one VPN, so
# the actions do not need to repeat what it is for. See
# openspec/specs/container-commands/.
#
# Nothing at runtime reads this repo again.
render_vpn() {
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
  echo
  # The SSO path, when the plugin implements it. Absent, the generated command
  # still has its `--sso` flag but refuses it naming the protocol - better than a
  # flag that silently does the wrong thing.
  if proto_has_sso; then
    echo
    echo "# ---- SSO implementation (scripts/lib/protocol-${PROTOCOL}.sh) ----"
    proto_sso_url_snippet
    echo
    proto_sso_connect_snippet
    echo
    printf 'PROTO_SSO_VALUES=%s\n' "$(printf '%q' "$(proto_sso_values)")"
    printf 'PROTO_HAS_SSO=1\n'
  else
    printf '\nPROTO_HAS_SSO=0\n'
  fi

  echo "# ---- protocol teardown (scripts/lib/protocol-${PROTOCOL}.sh) ----"
  if declare -f proto_disconnect_snippet >/dev/null 2>&1; then
    proto_disconnect_snippet
  else
    # $p is meant literally here: it expands inside the container.
    # shellcheck disable=SC2016
    printf 'proto_disconnect() {\n  local p\n  for p in %s; do\n    stop_client "$p" || true\n  done\n}\n' \
      "$(proto_client_processes)"
  fi

  # The plugin's client process names, needed three times inside the container:
  # to refuse starting on top of a live tunnel, by the default teardown, and by
  # record_connection to find the running client's PID.
  printf '\nVPN_CLIENT_PROCESSES=%s\n' "$(printf '%q' "$(proto_client_processes)")"
  cat <<'DISPATCH'

usage() {
  cat <<'USAGE'
Usage: vpn <subcommand>

  connect     authenticate, bring up the tunnel, apply the split routes
  disconnect  stop the client and remove the tunnel interface
  status      report what the tunnel is doing, and change nothing

connect accepts:
  --sso            authenticate in a browser outside this container
  --native         authenticate with the client's own prompts
  --from-stdin     with --sso, read the values as name=value lines instead
                   of prompting (needs no terminal)

Without a flag, connect uses the mode the container was created with.

This container runs one VPN, so the subcommands do not name it.
USAGE
}

do_connect() {
  local mode from_stdin=0 p
  mode="$(auth_mode)"

  while (( $# > 0 )); do
    case "$1" in
      --sso)        mode=sso; shift ;;
      --native)     mode=native; shift ;;
      --from-stdin) from_stdin=1; shift ;;
      *) echo "vpn connect: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    esac
  done

  if [[ "$mode" == "sso" && "${PROTO_HAS_SSO:-0}" != "1" ]]; then
    echo "ERROR: protocol '${VPN_PROTOCOL}' has no SSO path." >&2
    echo "       Its client authenticates directly; run 'vpn connect' without --sso." >&2
    exit 1
  fi

  for p in $VPN_CLIENT_PROCESSES; do
    if pgrep -x "$p" >/dev/null 2>&1; then
      echo "A VPN client ($p) is already running. Run 'vpn disconnect' first." >&2
      exit 1
    fi
  done

  if [[ "$mode" == "sso" ]]; then
    # This container cannot open a browser - it has none, no display, and no path
    # to the operator's session, which is the isolation it exists for. So it
    # prints where to go and collects what comes back.
    proto_sso_url || {
      echo "ERROR: could not get a login URL from ${VPN_GATEWAY:-the gateway}." >&2
      echo "       The gateway was not reachable or did not offer SSO. This is not" >&2
      echo "       a rejected credential - nothing has been sent yet." >&2
      exit 1
    }

    if (( from_stdin )); then
      sso_values_read
    else
      require_tty "SSO login" || exit 1
      echo
      echo "Paste the values from the browser:"
    fi
    sso_values_collect "$PROTO_SSO_VALUES" || {
      echo "ERROR: the login did not complete - no credential was supplied." >&2
      echo "       Nothing was sent to the gateway. This is not an expired" >&2
      echo "       credential; start again when the browser step is done." >&2
      exit 1
    }

    proto_sso_connect
  else
    # proto_connect authenticates, brings up the tunnel, and leaves the interface
    # that actually appeared in VPN_INTERFACE. It does nothing about routing.
    proto_connect
  fi

  finish_connect "$VPN_INTERFACE"
}

do_disconnect() {
  proto_disconnect

  # Sweep up interfaces the client left behind - a killed client does not always
  # remove its own link. VPN_INTERFACE covers whatever the container was
  # configured for; the rest are the names the supported clients actually use.
  # Deleting a ppp link usually fails because pppd owns it and it disappears
  # with the process, hence the tolerated errors.
  local iface
  for iface in "$VPN_INTERFACE" vpn0 tun0 ppp0; do
    if ip link show "$iface" >/dev/null 2>&1; then
      echo "Deleting $iface..."
      sudo ip link set "$iface" down 2>/dev/null || true
      sudo ip link delete "$iface" 2>/dev/null || true
    fi
  done

  echo "VPN down."
}

do_status() {
  # A read, start to finish. Nothing here applies a route, stops a client,
  # deletes an interface or touches the record. Asking a container how it is must
  # never be a way of changing how it is.
  local iface state verdict dev expected missing client pid uptime addr resolv_now resolv_was
  iface="$(status_iface)"
  state="$(tunnel_state "$iface")"
  verdict="$(default_route_verdict "$iface")"
  dev="${verdict%% *}"

  # Liveness the same way tunnel_state establishes it, so the facts cannot
  # contradict the headline: the record only counts when the process it names is
  # really that process, otherwise fall back to looking for a declared client.
  client=""; pid=""
  if state_client_alive; then
    client="$(state_get VPN_STATE_CLIENT)"
    pid="$(state_get VPN_STATE_PID)"
  else
    local candidate
    for candidate in ${VPN_CLIENT_PROCESSES:-}; do
      pid="$(pgrep -x "$candidate" 2>/dev/null | head -1)" || pid=""
      if [[ -n "$pid" ]]; then client="$candidate"; break; fi
    done
    # Nothing running: name what this container's client WOULD be, from the
    # record if there is one and otherwise from what the plugin declared. Saying
    # "<none> not running" tells the operator less than nothing.
    if [[ -z "$client" ]]; then
      client="$(state_get VPN_STATE_CLIENT)"
      [[ -n "$client" ]] || client="${VPN_CLIENT_PROCESSES%% *}"
    fi
  fi

  printf '%s   %s   %s\n\n' "$(hostname)" "$VPN_PROTOCOL" "$state"

  if [[ -n "$pid" ]]; then
    # Uptime from the process, not from the record: a recycled pid would make a
    # dead client look live, so the process is the authority on both.
    uptime="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')" || uptime=""
    printf '  client      %s running (pid %s%s)\n' "$client" "$pid" \
      "${uptime:+, up ${uptime}s}"
  else
    printf '  client      %s not running\n' "${client:-<none>}"
  fi

  if ip link show "$iface" >/dev/null 2>&1; then
    addr="$(ip -br addr show "$iface" 2>/dev/null | awk '{print $3}')" || addr=""
    printf '  interface   %s %s\n' "$iface" "${addr:-<no address>}"
    if [[ -n "${VPN_INTERFACE:-}" && "$iface" != "$VPN_INTERFACE" ]]; then
      printf '              configured as %s; the client renamed it\n' "$VPN_INTERFACE"
    fi
  else
    printf '  interface   %s absent\n' "$iface"
  fi

  expected="$(state_get VPN_STATE_ROUTES)"
  if [[ -z "$expected" ]]; then
    # Unknown is not the same as none: a connection older than the record has no
    # expectation, and calling that "complete" or "all missing" would both lie.
    printf '  routes      expected set unknown (no record for this connection)\n'
    ip route show dev "$iface" 2>/dev/null | awk '{print "              installed: " $1}' || true
  else
    missing="$(status_missing_routes "$iface")"
    if [[ -z "$missing" ]]; then
      printf '  routes      all %s present on %s\n' \
        "$(printf '%s' "$expected" | tr ',' '\n' | grep -c .)" "$iface"
    else
      printf '  routes      %s of %s present on %s\n' \
        "$(( $(printf '%s' "$expected" | tr ',' '\n' | grep -c .) - $(printf '%s' "$missing" | wc -w) ))" \
        "$(printf '%s' "$expected" | tr ',' '\n' | grep -c .)" "$iface"
      printf '              missing: %s\n' "$missing"
    fi
  fi

  case "${verdict##* }" in
    ok)         printf '  default     %s - as declared (%s)\n' "$dev" "$(tunnel_mode)" ;;
    not-pushed) printf '  default     %s - full tunnel declared, none pushed\n' "$dev" ;;
    broken)     printf '  default     %s - SPLIT TUNNEL NOT IN EFFECT\n' "$dev" ;;
  esac

  resolv_now="$(resolv_fingerprint)"
  resolv_was="$(state_get VPN_STATE_RESOLV)"
  if [[ -z "$resolv_was" ]]; then
    printf '  resolver    %s - cannot tell whether it changed (no baseline)\n' \
      "${resolv_now:-<none>}"
  elif [[ "$resolv_now" == "$resolv_was" ]]; then
    printf '  resolver    %s - unchanged since connect\n' "${resolv_now:-<none>}"
  else
    printf '  resolver    %s - REWRITTEN since connect (was %s)\n' \
      "${resolv_now:-<none>}" "$resolv_was"
  fi

  [[ "$state" == "stale" ]] && printf '\n  run '"'"'vpn disconnect'"'"' to clear the leftovers\n'
  return 0
}

# Exit 2 for a usage error, so a caller can tell "you asked for something that
# does not exist" from an action that ran and failed, which exits 1.
#
# `status` always reports success when it determined the state, whatever that
# state is: it is a report for a person, and the state is carried by the text.
case "${1:-}" in
  connect)    shift; do_connect "$@" ;;
  disconnect) do_disconnect ;;
  status)     do_status ;;
  -h|--help)  usage ;;
  "")         usage >&2; exit 2 ;;
  *)          echo "vpn: unknown subcommand '${1}'" >&2; usage >&2; exit 2 ;;
esac
DISPATCH
}

# render_sudoers USER - print the /etc/sudoers.d/vpn-client line for USER: the
# plugin's proto_sudo_commands plus what the vpn command itself
# run under sudo (ip, pkill, kill).
#
# Deliberately NOT granted: tail. The only sudo tail calls are error-path log
# dumps guarded with '|| true', so they degrade to no output instead of
# failing, and granting it would hand this user root-read on every file.
render_sudoers() {
  local cmds
  local sso_cmds=""
  if declare -f proto_sso_sudo_commands >/dev/null 2>&1; then
    sso_cmds="$(proto_sso_sudo_commands)"
  fi
  # Word splitting is the point: one path per line for paste. sort -u because the
  # SSO path usually needs the same binaries the native one already declared.
  # shellcheck disable=SC2046,SC2086
  cmds="$(printf '%s\n' $(proto_sudo_commands) ${sso_cmds} /usr/sbin/ip /usr/bin/ip /usr/bin/pkill /usr/bin/kill | sort -u | paste -sd, - | sed 's/,/, /g')"
  printf '%s ALL=(root) NOPASSWD: %s\n' "$1" "$cmds"
}

# render_state_tmpfiles USER - print /etc/tmpfiles.d/vpn-client.conf.
#
# 'vpn connect' records the live connection under /run/vpn-client. /run is tmpfs
# and root-owned, so a non-root --user container cannot create that directory
# itself, and the sudoers allowlist deliberately grants no general-purpose
# write command. systemd-tmpfiles recreates it on every boot instead.
render_state_tmpfiles() {
  local user="$1"
  echo "# Managed by create-vpn-lxd-container.sh"
  echo "# Runtime directory for the record 'vpn connect' writes. Transient by"
  echo "# design: /run is tmpfs, so nothing here survives a container restart."
  printf 'd /run/vpn-client 0755 %s %s -\n' "$user" "$user"
}

# REPLACED_COMMANDS - container commands this project used to install and no
# longer does. install_helpers removes each one, so a refreshed container ends up
# with the current surface rather than holding both. Left in place they would keep
# working while frozen at whatever version installed them, which is worse than
# either surface alone. See openspec/specs/container-commands/.
#
# The list is not only about the connect-vpn/disconnect-vpn split. The two SAML
# helpers were dropped when `vpn connect --sso` replaced them, and dropping them
# from the plugin only stopped them being *written*: a real gp container refreshed
# afterwards still carried both, executable, running the removed flow. That was
# verified against a throwaway container, where they had never existed - so the
# check passed and the containers that mattered kept them.
REPLACED_COMMANDS=(connect-vpn disconnect-vpn connect-vpn-saml connect-vpn-saml-finish)

# install_helpers NAME [USER] - render the container's `vpn` command and the
# state directory rule, push them, and remove the commands they replaced.
# USER defaults to root.
install_helpers() {
  local name="$1" user="${2:-root}" f
  helper_work_dir
  render_vpn > "${HELPER_WORK_DIR}/vpn"

  # The generated text is only ever parsed inside the container, so a broken
  # protocol snippet would otherwise surface on the next real connect. Both
  # actions now live in one file, so this check is also what keeps a container
  # on its previous working command instead of handing it a broken one.
  if ! bash -n "${HELPER_WORK_DIR}/vpn"; then
    echo "ERROR: generated vpn command does not parse; not installing it." >&2
    exit 1
  fi
  lxc file push --uid 0 --gid 0 --mode 0755 \
    "${HELPER_WORK_DIR}/vpn" "${name}/usr/local/bin/vpn" >/dev/null

  render_state_tmpfiles "$user" > "${HELPER_WORK_DIR}/vpn-client.conf"
  lxc file push --uid 0 --gid 0 --mode 0644 \
    "${HELPER_WORK_DIR}/vpn-client.conf" "${name}/etc/tmpfiles.d/vpn-client.conf" >/dev/null

  # `lxc file delete` works on a stopped container, which is why removal lives
  # here next to the push rather than behind an `lxc exec`. It exits non-zero
  # when the path is absent, and that is the ordinary case: a freshly created
  # container has nothing to remove, and neither does one refreshed twice.
  for f in "${REPLACED_COMMANDS[@]}"; do
    lxc file delete "${name}/usr/local/bin/${f}" >/dev/null 2>&1 || true
  done
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
# the container's `vpn` command `source`s this file, so every value in it is
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
  # Declared for every protocol, not just the ones whose client can act on it:
  # it also governs how the default route is reported, which is what makes a
  # gateway-imposed full tunnel a stated outcome instead of an unexplained one.
  env_kv VPN_TUNNEL_MODE "${TUNNEL_MODE:-split}"
  # Which authentication path this container uses by default. Overridable per
  # invocation with `vpn connect --sso` / `--native`, which never writes here.
  env_kv VPN_AUTH_MODE "${AUTH_MODE:-native}"
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
