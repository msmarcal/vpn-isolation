# Adding a new VPN protocol

The orchestrator (`scripts/create-vpn-lxd-container.sh`) discovers protocols
dynamically from `scripts/lib/protocol-*.sh` - it never needs to change when
you add one. Drop a new file implementing the contract below and it's
immediately available as `--protocol <name>`.

## Contract

Create `scripts/lib/protocol-<name>.sh`. It must set two variables and define
eight functions, plus three optional hooks the orchestrator probes for with
`declare -f` and skips when absent. The orchestrator checks the required ones
at startup and refuses to run if any is missing:

```bash
# Must match the filename suffix - the orchestrator dispatches on the filename
# and refuses to run if the two disagree.
PROTO_NAME="<name>"
# One line, shown in the protocol list printed by --help. The orchestrator
# reads it with sed rather than sourcing this file, so keep it a plain
# double-quoted literal on a single line - no variables, no concatenation.
PROTO_DESC="Human-readable description"

# Validate required orchestrator globals (GATEWAY, OVPN, etc). Exit 1 with a
# clear message on failure. Runs on the host before any lxc calls.
proto_validate_args() { ... }

# Print "1" or "0" - whether --build-openconnect should be recommended by
# default for this protocol (only relevant for openconnect-based protocols;
# print 0 if not applicable).
proto_needs_build_openconnect() { echo 0; }

# Print (stdout) a space-separated list of extra apt packages needed inside
# the container for this protocol, on top of the always-installed base set
# (iproute2, iptables, curl, openssh-*, dnsutils, vim).
proto_apt_packages() { echo "some-client-package"; }

# Print (stdout) the process name(s) of the client, as `pgrep -x` sees them.
# connect-vpn refuses to start while one is running, and the default
# disconnect-vpn stops each one (SIGTERM, wait, SIGKILL).
proto_client_processes() { echo "some-client"; }

# Print (stdout) the absolute paths a non-root --user container may run under
# sudo for this protocol: the client binary (every path it may be installed
# at) plus any wrapper the snippets invoke with sudo. ip, pkill and kill are
# always granted. A missing path makes connect-vpn hang on a sudo prompt.
proto_sudo_commands() { echo "/usr/sbin/some-client"; }

# Print (stdout) extra KEY=VALUE lines to append to the container's
# /etc/vpn-client.env. Has access to orchestrator globals (GATEWAY, OVPN,
# ROUTE_NOPULL, etc).
#
# Emit every assignment with `env_kv KEY VALUE`, which the orchestrator
# defines. connect-vpn `source`s this file, so a value written raw is shell
# code: a space in it runs the rest as a command, an apostrophe breaks the
# whole file, and `$(...)` executes. env_kv quotes the value only when needed,
# so plain values still read naturally. Comment lines can be printed with a
# quoted heredoc (`cat <<'EOF'`).
proto_write_env_extra() {
  env_kv VPN_SOMETHING "$SOME_GLOBAL"
}

# Print (stdout) a bash function definition named exactly `proto_connect`.
# This text is spliced into the in-container connect-vpn script, so it must
# be valid standalone bash relying only on:
#   - variables sourced from /etc/vpn-client.env (VPN_PROTOCOL, VPN_ROUTES,
#     VPN_INTERFACE, plus anything you added via proto_write_env_extra)
#   - helpers from scripts/lib/common.sh: apply_split_routes, wait_for_iface
# On success it should update $VPN_INTERFACE to the real tunnel interface
# name and call apply_split_routes "$VPN_ROUTES" "$VPN_INTERFACE".
proto_connect_snippet() { cat <<'EOF'
proto_connect() {
  # ... bring up the tunnel ...
  NEW_IFACE="$(wait_for_iface "$VPN_INTERFACE" some-fallback-iface)" || {
    echo "ERROR: tunnel interface did not appear" >&2
    exit 1
  }
  VPN_INTERFACE="$NEW_IFACE"
  apply_split_routes "$VPN_ROUTES" "$VPN_INTERFACE"
}
EOF
}

# Print (stdout) a shell command (run inside the container via `bash -c`)
# that prints the installed client's version string.
proto_version_cmd() { echo "some-client --version | head -1"; }

# OPTIONAL: proto_post_install NAME - runs on the HOST (not inside the
# container) after packages are installed, for any host-side file staging
# (e.g. protocol-openvpn.sh uses this to `lxc file push` the .ovpn profile
# and any certs/keys it references). Omit entirely if not needed.
proto_post_install() {
  local name="$1"
  # lxc file push ...
}

# OPTIONAL: print (stdout) the value written to VPN_INTERFACE in
# /etc/vpn-client.env. Omit to accept the default `vpn0`. Define it when the
# kernel - not your client - picks the interface name, so proto_connect has a
# sane starting point to poll from (protocol-fortissl.sh returns "ppp0",
# because PPP interfaces are always named pppN and cannot be renamed inside
# an LXD container).
proto_write_env_interface() { echo "ppp0"; }

# OPTIONAL: print (stdout) a bash function named exactly `proto_disconnect`,
# spliced into the in-container disconnect-vpn in place of the default one.
# Define it only when stopping the processes from proto_client_processes is
# not enough. Like proto_connect_snippet it runs inside the container and may
# use the helpers from common.sh; `stop_client NAME [TIMEOUT]` does the
# SIGTERM / wait / SIGKILL dance and returns 1 if the kill was needed.
# protocol-fortissl.sh uses this to also close the screen session it runs in.
proto_disconnect_snippet() { cat <<'EOF'
proto_disconnect() {
  stop_client some-client 10 || true
  # ... extra teardown ...
}
EOF
}
```

## Reference implementations

- `scripts/lib/protocol-openvpn.sh` - most complete example, uses
  `proto_post_install` to push a `.ovpn` profile and sibling cert/key files.
- `scripts/lib/protocol-anyconnect.sh` / `protocol-gp.sh` - near-identical
  thin wrappers around `openconnect --protocol=<anyconnect|gp>`, good
  templates for any other openconnect-backed VPN (e.g. Fortinet, Juniper
  Pulse-via-openconnect if support lands upstream).

## Testing a new protocol file without a real container

```bash
bash -n scripts/lib/protocol-<name>.sh          # syntax check
shellcheck scripts/lib/protocol-<name>.sh       # optional, but the repo is clean
./scripts/create-vpn-lxd-container.sh --help    # confirm name + PROTO_DESC are listed
```

The `proto_connect_snippet` output is *text* that only gets parsed inside the
container, so a typo in it survives every check above and only surfaces on a
real connect. Parse it explicitly:

```bash
bash -c 'source scripts/lib/protocol-<name>.sh; proto_connect_snippet' | bash -n /dev/stdin
```

A PROTO_NAME that disagrees with the filename is caught early - the
orchestrator exits before touching `lxc`, so this is safe to run anywhere:

```bash
./scripts/create-vpn-lxd-container.sh --name t --protocol <name>
```

## Where the client binaries end up

Nothing in the orchestrator names a client. `proto_client_processes` feeds
the "already connected" guard in `connect-vpn` and the default teardown in
`disconnect-vpn`; `proto_sudo_commands` feeds the sudoers allowlist for a
non-root `--user`. Get either wrong and the symptom is specific: a missing
process name means `disconnect-vpn` reports "VPN down." with the tunnel still
up, and a missing sudo path means `connect-vpn` hangs on a password prompt.

The interface sweep at the end of `disconnect-vpn` deletes `$VPN_INTERFACE`,
`vpn0`, `tun0` and `ppp0`. A client that names its tunnel something else should
set it through `proto_write_env_interface`.

Changes to a plugin only affect containers created afterwards; existing ones
pick them up with `--refresh-helpers`.

## What you should NOT need to touch

- `scripts/create-vpn-lxd-container.sh` and `scripts/lib/orchestrator.sh` -
  profile setup, launch, package install, env file, SSH provisioning and the
  helper assembly are all protocol-agnostic.
- `scripts/lib/common.sh` (shared helpers - only touch if genuinely shared
  logic is missing, and keep it protocol-agnostic). Note this file is copied
  verbatim into the in-container `connect-vpn`, so it must stay self-contained
  and depend on nothing beyond the base package set.

If you find yourself editing either of those to add a protocol, the
contract is probably missing something - open an issue/PR describing the gap
instead of hardcoding a protocol name into the orchestrator.
