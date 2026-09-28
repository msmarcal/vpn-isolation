# shellcheck shell=bash
#
# Shared VPN helpers.
#
# This file is used two ways: sourced directly by the orchestrator
# (create-vpn-lxd-container.sh) on the host, and COPIED VERBATIM into the
# generated /usr/local/bin/vpn inside each container. The container
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

# wait_for_iface_up IFACE
# An interface can exist before it is usable. `ip` lists a PPP link as soon as
# pppd creates it, but IFF_UP is only set when negotiation finishes, and the
# kernel refuses a route whose device is not up ("Device for nexthop is not up").
# So routing has to wait for the flag, not for the name - waiting for the name is
# what wait_for_iface and the protocols' own polls do, and it is not enough.
#
# Returns 0 once the flag is set, 1 when the window expires. Never aborts: a
# device that never comes up is reported by the caller, not fatal here.
wait_for_iface_up() {
  local iface="$1"
  local window="${VPN_IFACE_UP_WINDOW:-20}"
  local interval="${VPN_IFACE_UP_INTERVAL:-1}"
  local elapsed=0 step
  while (( elapsed < window )); do
    # `ip link show up` lists only interfaces carrying IFF_UP.
    if ip link show up 2>/dev/null | grep -qE "^[0-9]+: ${iface}[:@]"; then
      return 0
    fi
    sleep "$interval"
    step="${interval%%.*}"
    (( step < 1 )) && step=1
    elapsed=$(( elapsed + step ))
  done
  return 1
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
# inherited that status and aborted the connect with the tunnel already up.
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

  # The interface may exist without being usable yet; adding a route to it would
  # fail, and on PPP that is the normal case rather than the exception.
  if ! wait_for_iface_up "$iface"; then
    echo "WARNING: ${iface} exists but never came up." >&2
    echo "         Routes will probably fail to install - see below." >&2
  fi

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
  # Described in terms of what was declared, so the report never asserts a rule
  # the container was not asked to follow. The judgment itself is shared with the
  # status report, so the two cannot drift apart.
  local verdict default_dev
  verdict="$(default_route_verdict "$iface")"
  default_dev="${verdict%% *}"
  case "${verdict##* }" in
    ok)
      if [[ "$default_dev" == "$iface" ]]; then
        echo "Default route: on ${iface} - full tunnel, as declared."
      else
        echo "Default route: on ${default_dev} - split tunnel intact."
      fi ;;
    not-pushed)
      echo "Default route: on ${default_dev} - a full tunnel was declared,"
      echo "               but the gateway pushed no default route." ;;
    broken)
      echo "Default route: on ${default_dev} - SPLIT TUNNEL DECLARED BUT NOT IN EFFECT." >&2
      echo "               The client took the default route. Traffic that should" >&2
      echo "               stay local is going over the VPN." >&2
      echo "               Left as it is: this reports the invariant, it does not" >&2
      echo "               enforce it. Set VPN_TUNNEL_MODE=full if that is wanted." >&2 ;;
  esac
  ip route show default || true
}

# tunnel_mode
# Print the container's declared tunnel mode: "split" or "full".
#
# The declaration answers one question - should the default route stay on the
# container's LAN interface? It is intent, not mechanism: it tells a protocol how
# to configure its client, and it tells a reader whether what it sees is what was
# asked for. It is never deduced from what a gateway turned out to push.
#
# When VPN_TUNNEL_MODE is absent the mode is DERIVED rather than assumed, because
# containers created before the key existed still have to report the truth, and a
# refresh deliberately never rewrites /etc/vpn-client.env.
#
# The derivation tests VPN_ROUTE_NOPULL and not the protocol. That key only ever
# exists in an OpenVPN container, so testing it alone is both sufficient and
# protocol-agnostic - which matters here, because this file must not grow
# knowledge of any particular protocol. Set to 0 it means the operator asked for
# every pushed route to be accepted, default route included, which is a full
# tunnel. Anything else, including the key being absent, is split.
tunnel_mode() {
  local declared="${VPN_TUNNEL_MODE:-}"
  case "$declared" in
    split|full) printf '%s\n' "$declared"; return 0 ;;
    "")         ;;
    *)          echo "WARNING: VPN_TUNNEL_MODE='${declared}' is not split or full; treating it as split." >&2
                printf 'split\n'; return 0 ;;
  esac

  if [[ "${VPN_ROUTE_NOPULL:-}" == "0" ]]; then
    printf 'full\n'
  else
    printf 'split\n'
  fi
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

# resolv_fingerprint
# A stable description of the container's resolver configuration: the nameservers
# it currently lists, comma separated. The list rather than a digest, because a
# digest says nothing useful to an operator when it differs, and this is shown.
#
# Whether the resolver CHANGED is unanswerable at status time on its own - a
# nameserver list is just a list - so a connect records this and the status
# compares. No recorded value means "cannot tell", never "unchanged".
resolv_fingerprint() {
  local ns
  ns="$(awk '/^nameserver[[:space:]]/ {print $2}' /etc/resolv.conf 2>/dev/null \
          | sort | paste -sd, -)" || ns=""
  printf '%s\n' "$ns"
}

# status_iface
# The tunnel interface to report on: what the record says, or failing that the
# first of the names the supported clients use that actually exists. A connection
# established before records were written has no record, and the report still has
# to describe it.
status_iface() {
  local iface candidate
  iface="$(state_get VPN_STATE_IFACE)"
  if [[ -n "$iface" ]] && ip link show "$iface" >/dev/null 2>&1; then
    printf '%s\n' "$iface"
    return 0
  fi
  for candidate in "${VPN_INTERFACE:-vpn0}" vpn0 tun0 ppp0; do
    if ip link show "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  printf '%s\n' "${iface:-${VPN_INTERFACE:-vpn0}}"
}

# tunnel_state IFACE
# Print one of: down, connected, degraded, stale.
#
#   down       no client running and no tunnel interface
#   connected  client running, interface up, routes present, default route where
#              the declared mode says it belongs
#   degraded   client running, but a route is missing or the default route is not
#              where the declared mode says
#   stale      no client running, but the interface and its routes are still there
#
# Liveness comes from checking the client, never from the record existing: a
# record outlives the client that wrote it. Where the expected route set is
# unknown - no record - that alone must NOT make the state degraded, or every
# container predating records would look broken.
tunnel_state() {
  local iface="$1" alive=1 present=1 p
  state_client_alive && alive=0
  if [[ "$alive" != "0" ]]; then
    for p in ${VPN_CLIENT_PROCESSES:-}; do
      pgrep -x "$p" >/dev/null 2>&1 && { alive=0; break; }
    done
  fi
  ip link show "$iface" >/dev/null 2>&1 && present=0

  if [[ "$alive" != "0" ]]; then
    [[ "$present" == "0" ]] && { printf 'stale\n'; return 0; }
    printf 'down\n'
    return 0
  fi

  [[ "$present" == "0" ]] || { printf 'degraded\n'; return 0; }
  [[ "$(default_route_verdict "$iface")" == *" broken" ]] && { printf 'degraded\n'; return 0; }
  [[ -n "$(status_missing_routes "$iface")" ]] && { printf 'degraded\n'; return 0; }
  printf 'connected\n'
}

# status_missing_routes IFACE
# Print the recorded routes that are NOT installed on IFACE, space separated.
# Prints nothing when the expected set is unknown, which is not the same as
# nothing missing - the caller has to tell those apart and say so.
status_missing_routes() {
  local iface="$1" expected missing="" cidr
  expected="$(state_get VPN_STATE_ROUTES)"
  [[ -n "$expected" ]] || return 0
  local -a want
  IFS=, read -ra want <<< "$expected"
  for cidr in "${want[@]}"; do
    [[ -n "$cidr" ]] || continue
    ip route show "$cidr" dev "$iface" 2>/dev/null | grep -q . || missing+="${cidr} "
  done
  printf '%s' "${missing% }"
}

# default_route_verdict IFACE
# Print "<device> <verdict>" for the container's default route, where verdict is
# one of: ok, broken, not-pushed. Judged against the declared tunnel mode, never
# against a fixed rule - a container that asked for a full tunnel must not be
# told its default route is in the wrong place.
#
# One implementation, called by both the connect report and the status report.
# Two would drift, and the one in the connect report is the one an operator sees
# least often, so it would drift silently.
default_route_verdict() {
  local iface="$1" mode dev
  mode="$(tunnel_mode)"
  dev="$(ip route show default 2>/dev/null \
           | awk '{for (i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}')" || dev=""

  if [[ "$mode" == "full" ]]; then
    if [[ -n "$dev" && "$dev" == "$iface" ]]; then
      printf '%s ok\n' "$dev"
    else
      printf '%s not-pushed\n' "${dev:-<none>}"
    fi
  else
    if [[ -n "$dev" && "$dev" == "$iface" ]]; then
      printf '%s broken\n' "$dev"
    else
      printf '%s ok\n' "${dev:-<none>}"
    fi
  fi
}

# STATE_KEYS - the keys the connection record may hold. A reader accepts these
# and nothing else.
STATE_KEYS="VPN_STATE_IFACE VPN_STATE_ROUTES VPN_STATE_ROUTE_SOURCE VPN_STATE_CLIENT VPN_STATE_PID VPN_STATE_CONNECTED_AT VPN_STATE_RESOLV"

# state_get KEY
# Print the recorded value for KEY, or nothing when there is no record, no such
# key, or the value is not one this writer could have produced.
#
# The record is NOT sourced, and that is deliberate. /etc/vpn-client.env is
# root-owned, but the record's directory is owned by the container's login user
# so that a non-root container can write it with no added privilege. Sourcing a
# user-writable file is harmless when the same user reads it - and an privilege
# escalation the moment root asks a --user container for its state. A diagnostic
# command is an absurd way to hand out root.
#
# So values are matched against the same conservative set env_kv writes bare.
# Every value this record holds - an interface name, a comma-separated CIDR list,
# a process name, digits - is inside it by construction, so nothing is lost, and
# anything else is treated as absent, which callers already have to handle.
state_get() {
  local key="$1"
  [[ " ${STATE_KEYS} " == *" ${key} "* ]] || return 0
  [[ -r "$VPN_STATE_FILE" ]] || return 0
  local line value
  while IFS= read -r line; do
    [[ "$line" == "${key}="* ]] || continue
    value="${line#*=}"
    [[ "$value" =~ ^[A-Za-z0-9._/:,@%+=-]*$ ]] || return 0
    printf '%s\n' "$value"
    return 0
  done < "$VPN_STATE_FILE"
}

# state_client_alive
# True when the record names a client that is actually running. The record
# outlives the client that wrote it - a client can exit without removing it - so
# a record on its own says nothing about whether a tunnel is live.
#
# Both the pid and the process name are checked, because pids are recycled: a
# dead client's pid can belong to something unrelated, and a stale tunnel would
# then report as live.
state_client_alive() {
  local pid name running
  pid="$(state_get VPN_STATE_PID)"
  name="$(state_get VPN_STATE_CLIENT)"
  [[ -n "$pid" && -n "$name" ]] || return 1
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  running="$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')" || running=""
  [[ "$running" == "$name" ]]
}

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
    echo "# Written by 'vpn connect'. Transient: one connection, cleared on restart."
    env_kv VPN_STATE_IFACE "$iface"
    env_kv VPN_STATE_ROUTES "$routes"
    env_kv VPN_STATE_ROUTE_SOURCE "$source"
    env_kv VPN_STATE_CLIENT "$client"
    env_kv VPN_STATE_PID "$pid"
    env_kv VPN_STATE_CONNECTED_AT "$(date +%s)"
    # The baseline the status report compares against. Absent in every record
    # written before this existed, which the reader treats as "cannot tell".
    env_kv VPN_STATE_RESOLV "$(resolv_fingerprint)"
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
