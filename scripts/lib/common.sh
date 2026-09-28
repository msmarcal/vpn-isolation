# shellcheck shell=bash
#
# Shared VPN helpers.
#
# This file is used two ways: sourced directly by the orchestrator
# (create-vpn-lxd-container.sh) on the host, and COPIED VERBATIM into the
# generated /usr/local/bin/connect-vpn inside each container. The container
# never has a copy of this repository, so these functions only exist there
# because their text was pasted in.
#
# That second use is the binding constraint: keep this file self-contained,
# protocol-agnostic, and free of any dependency beyond the base package set
# the orchestrator installs (iproute2, iptables, curl, openssh-*, dnsutils).
# Anything sourced, imported, or shelled out to here must also exist inside
# every container this repo can build.

# apply_split_routes CIDR_LIST IFACE
# CIDR_LIST is a comma-separated string (e.g. "10.1.0.0/16,10.2.0.0/24")
#
# Idempotent: `ip route replace` is a no-op for a route the client already
# installed, which is the normal case once the gateway pushed its own set.
#
# Never aborts. By the time this runs the tunnel is up and the operator has
# already authenticated, so failing the whole connect over one route would
# throw away an interactive login. A failed entry is named on stderr instead
# of being swallowed - the host-side validate_routes guard catches malformed
# input earlier and with a better message, so anything reaching here and
# failing is worth seeing.
apply_split_routes() {
  local routes="$1" iface="$2"
  [[ -z "$routes" ]] && return 0
  IFS="," read -ra RLIST <<< "$routes"
  local cidr cidr_trimmed err
  for cidr in "${RLIST[@]}"; do
    cidr_trimmed="$(echo "$cidr" | xargs)"
    [[ -z "$cidr_trimmed" ]] && continue
    echo "Adding split route: $cidr_trimmed dev $iface"
    if err="$(sudo ip route replace "$cidr_trimmed" dev "$iface" 2>&1)"; then
      continue
    fi
    if err="$(sudo ip route add "$cidr_trimmed" dev "$iface" 2>&1)"; then
      continue
    fi
    echo "WARNING: could not install route ${cidr_trimmed} dev ${iface}: ${err}" >&2
  done
  return 0
}

# detect_split_routes IFACE
# Print the routes the VPN client installed on IFACE as a comma-separated list,
# excluding any default route. This is what "asking the server" amounts to:
# every supported client installs the routes the gateway pushed before anything
# reads them back, so there is no protocol-specific query to make.
#
# The routing table is polled rather than read once. wait_for_iface returns as
# soon as the LINK exists, which is before the client has installed anything,
# and on PPP the gap is wider still because the link appears while address
# negotiation is in progress. The set is accepted once it has been non-empty
# and unchanged across two consecutive polls, or the window expires.
#
# ALWAYS exits 0, including when nothing was found. A caller under `set -e`
# with pipefail would otherwise be killed by the empty case, which is exactly
# the bug this replaces: `grep -v` exits 1 on no input, and the assignment
# inherited that status and aborted connect-vpn with the tunnel already up.
detect_split_routes() {
  local iface="$1"
  local window="${VPN_ROUTE_SETTLE_WINDOW:-20}"
  local interval="${VPN_ROUTE_SETTLE_INTERVAL:-1}"
  local current="" previous="" elapsed=0 step

  while (( elapsed < window )); do
    # Sorted so that the stability comparison is not fooled by kernel ordering.
    current="$(ip route show dev "$iface" 2>/dev/null \
                 | awk '{print $1}' \
                 | grep -v '^default' \
                 | sort \
                 | paste -sd, -)" || current=""
    if [[ -n "$current" && "$current" == "$previous" ]]; then
      printf '%s\n' "$current"
      return 0
    fi
    previous="$current"
    sleep "$interval"
    # Accounting advances by at least one even when the interval is fractional
    # or zero, so the loop always terminates. Without this a zero interval spins
    # forever - only reachable from a test, but still a real trap.
    step="${interval%%.*}"
    (( step < 1 )) && step=1
    elapsed=$(( elapsed + step ))
  done

  # Window expired. Whatever is there (usually nothing) is the answer; a
  # route-less gateway is legitimate and must not look like a failure.
  printf '%s\n' "$current"
  return 0
}

# wait_for_iface IFACE [FALLBACK_IFACE]
# Polls up to ~40s for IFACE to appear; if FALLBACK_IFACE appears instead
# (common with tools that always name their tunnel tun0), prints the fallback
# name to stdout so callers can pick it up.
wait_for_iface() {
  local iface="$1" fallback="${2:-}"
  local i
  for i in $(seq 1 40); do
    if ip link show "$iface" >/dev/null 2>&1; then
      echo "$iface"
      return 0
    fi
    if [[ -n "$fallback" ]] && ip link show "$fallback" >/dev/null 2>&1; then
      echo "$fallback"
      return 0
    fi
    sleep 1
  done
  return 1
}

# stop_client NAME [TIMEOUT]
# Sends SIGTERM to every process named NAME, waits up to TIMEOUT seconds (5 by
# default) for them to exit, then SIGKILLs whatever is left. Returns 1 when the
# kill was needed, so a protocol teardown can add a client-specific hint.
stop_client() {
  local name="$1" timeout="${2:-5}"
  pgrep -x "$name" >/dev/null 2>&1 || return 0
  echo "Stopping ${name}..."
  sudo pkill -TERM "$name" 2>/dev/null || true
  for _ in $(seq 1 "$timeout"); do
    pgrep -x "$name" >/dev/null 2>&1 || return 0
    sleep 1
  done
  echo "${name} did not exit within ${timeout}s of SIGTERM; killing it." >&2
  sudo pkill -KILL "$name" 2>/dev/null || true
  return 1
}

# finish_connect IFACE
# Everything that happens after a tunnel is up: resolve the route set, apply
# it, record the connection, report.
#
# This is deliberately ONE function rather than inline code in the generated
# runner. A plugin may install an extra container helper for a login flow a
# single command cannot express (protocol-gp.sh generates one), and such a
# helper is a separate script, not the runner. Inline code would leave it with
# nothing to call and invite the copy that this arrangement exists to remove.
# The runner owns the sequence; this file owns the steps.
#
# Reads VPN_ROUTES and VPN_CLIENT_PROCESSES from the calling helper. Exports
# nothing: the caller passes the interface in, because only the caller knows
# which one actually came up.
finish_connect() {
  local iface="$1"
  local routes="${VPN_ROUTES:-}" source="configured"

  if [[ -z "$routes" || "$routes" == "auto" ]]; then
    echo "Detecting routes pushed by the server on ${iface}..."
    routes="$(detect_split_routes "$iface")"
    source="detected"
    if [[ -n "$routes" ]]; then
      echo "Detected routes from server: ${routes}"
    else
      echo "WARNING: no routes were detected on ${iface}." >&2
      echo "         The gateway may be full-tunnel, or may push nothing." >&2
      echo "         Set explicit routes with --routes if internal hosts time out." >&2
    fi
  fi

  apply_split_routes "$routes" "$iface"
  record_connection "$iface" "$routes" "$source"

  echo
  echo "VPN up on ${iface}."
  ip -br addr show "$iface" || true
  if [[ -n "$routes" ]]; then
    echo "Split routes (${source}):"
    local r
    IFS="," read -ra FCLIST <<< "$routes"
    for r in "${FCLIST[@]}"; do
      printf '  %s\n' "$r"
    done
  else
    echo "Split routes: none"
  fi
  echo "Default route (must stay off the tunnel):"
  ip route show default || true
}

# VPN_STATE_FILE - where a live connection records itself.
#
# /run is tmpfs, so the record cannot outlive a container restart, which is the
# lifetime a connection has. Correctness does not rest on that though: the
# record carries the client PID and a reader must treat it as absent when that
# PID is gone. That covers what tmpfs cannot - a client that exited while the
# container kept running - and is what lets a reader tell a live tunnel from
# leftovers.
VPN_STATE_FILE="${VPN_STATE_FILE:-/run/vpn-client/state}"

# record_connection IFACE ROUTES SOURCE
# SOURCE is "configured" or "detected", saying where ROUTES came from.
#
# Reads VPN_CLIENT_PROCESSES (set by the generated helper from the plugin's
# proto_client_processes) to find the client PID.
#
# Never aborts the connect. The tunnel is up by now; losing the record is a
# degraded outcome for a later status reader, not a reason to fail a live
# connection, so a failure here is a warning.
record_connection() {
  local iface="$1" routes="$2" source="$3"
  local dir client="" pid="" p

  dir="$(dirname "$VPN_STATE_FILE")"
  if [[ ! -d "$dir" ]] && ! mkdir -p "$dir" 2>/dev/null; then
    echo "WARNING: cannot create ${dir}; this connection will not be recorded." >&2
    return 0
  fi

  for p in ${VPN_CLIENT_PROCESSES:-}; do
    pid="$(pgrep -x "$p" 2>/dev/null | head -1)" || pid=""
    if [[ -n "$pid" ]]; then
      client="$p"
      break
    fi
  done

  # Written to a temporary file and moved into place, so a reader never sources
  # a half-written record.
  local tmp="${VPN_STATE_FILE}.tmp.$$"
  {
    echo "# Written by connect-vpn. Transient: one connection, cleared on restart."
    env_kv VPN_STATE_IFACE "$iface"
    env_kv VPN_STATE_ROUTES "$routes"
    env_kv VPN_STATE_ROUTE_SOURCE "$source"
    env_kv VPN_STATE_CLIENT "$client"
    env_kv VPN_STATE_PID "$pid"
    env_kv VPN_STATE_CONNECTED_AT "$(date +%s)"
  } > "$tmp" 2>/dev/null || {
    echo "WARNING: cannot write ${VPN_STATE_FILE}; this connection will not be recorded." >&2
    rm -f "$tmp" 2>/dev/null || true
    return 0
  }

  mv -f "$tmp" "$VPN_STATE_FILE" 2>/dev/null || {
    echo "WARNING: cannot update ${VPN_STATE_FILE}; this connection will not be recorded." >&2
    rm -f "$tmp" 2>/dev/null || true
  }
  return 0
}

# env_kv KEY VALUE - print one assignment, quoted so that `source` yields VALUE
# back byte for byte.
#
# Used on both sides of the split: the orchestrator builds /etc/vpn-client.env
# with it on the host, and the container writes its connection record with it.
# That is why it lives here rather than in orchestrator.sh - this file is the
# only one that travels into the container.
#
# Values made only of characters that are literal in an assignment (hostnames,
# paths, CIDR lists, numbers) are written bare, so a file stays easy to edit by
# hand. Anything else is single-quoted, with embedded single quotes written as
# '\''. Not `printf %q`: it also escapes commas, turning a,b into a\,b.
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
