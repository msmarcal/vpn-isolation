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
# `vpn connect` refuses to start while one is running, and the default
# teardown stops each one (SIGTERM, wait, SIGKILL).
proto_client_processes() { echo "some-client"; }

# Print (stdout) the absolute paths a non-root --user container may run under
# sudo for this protocol: the client binary (every path it may be installed
# at) plus any wrapper the snippets invoke with sudo. ip, pkill and kill are
# always granted. A missing path makes `vpn connect` hang on a sudo prompt.
proto_sudo_commands() { echo "/usr/sbin/some-client"; }

# Print (stdout) extra KEY=VALUE lines to append to the container's
# /etc/vpn-client.env. Has access to orchestrator globals (GATEWAY, OVPN,
# ROUTE_NOPULL, etc).
#
# Emit every assignment with `env_kv KEY VALUE`, defined in
# scripts/lib/common.sh. The container's `vpn` command `source`s this file, so a value written raw is shell
# code: a space in it runs the rest as a command, an apostrophe breaks the
# whole file, and `$(...)` executes. env_kv quotes the value only when needed,
# so plain values still read naturally. Comment lines can be printed with a
# quoted heredoc (`cat <<'EOF'`).
proto_write_env_extra() {
  env_kv VPN_SOMETHING "$SOME_GLOBAL"
}

# Print (stdout) a bash function definition named exactly `proto_connect`.
# This text is spliced into the container's `vpn` command, so it must
# be valid standalone bash relying only on:
#   - variables sourced from /etc/vpn-client.env (VPN_PROTOCOL, VPN_ROUTES,
#     VPN_INTERFACE, plus anything you added via proto_write_env_extra)
#   - helpers from scripts/lib/common.sh, which travels into the container
#     verbatim: wait_for_iface, and the ones the framework calls for you
#
# proto_connect authenticates, brings up the tunnel, and leaves the interface
# that actually appeared in $VPN_INTERFACE. That is where it stops.
#
# It must NOT interpret VPN_ROUTES, must NOT detect routes, and must NOT call
# apply_split_routes. The generated helper calls finish_connect right after
# this function returns, and that resolves the route set (including "auto",
# by reading back what the client installed), applies it, records the live
# connection and prints the report. Routing is identical for every protocol
# because there is exactly one implementation of it.
proto_connect_snippet() { cat <<'EOF'
proto_connect() {
  # ... bring up the tunnel ...
  NEW_IFACE="$(wait_for_iface "$VPN_INTERFACE" some-fallback-iface)" || {
    echo "ERROR: tunnel interface did not appear" >&2
    exit 1
  }
  VPN_INTERFACE="$NEW_IFACE"
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
#
# It may also install an extra container command, for a login flow that a
# single command cannot express - protocol-gp.sh generates one for SAML
# portals. Such a command is its own executable, never a subcommand of `vpn`
# (whose verbs are connect, disconnect and status):
# the subcommands are the framework's verbs, so a plugin cannot change the
# shape of the surface an operator has learned, and the framework needs no
# mechanism for plugins to register verbs.
#
# Three rules apply, and skipping either of the first two is how the gp helpers
# ended up broken and unnoticed:
#
#   1. It must carry scripts/lib/common.sh verbatim, the same way the
#      generated `vpn` command does. The container has no copy of this repo, so
#      a shared function only exists in a script whose text contains it.
#      Calling one without that fails at runtime, and under `set -euo
#      pipefail` it surfaces as whatever the next `||` branch happens to say.
#   2. Once its tunnel is up it must call `finish_connect "$VPN_INTERFACE"`
#      rather than resolving or applying routes itself, so that a container
#      routes identically however it was authenticated.
#
# Text written here is not covered by the parse check that install_helpers
# runs on the `vpn` command, so check it yourself - see
# "Verifying" below.
proto_post_install() {
  local name="$1"
  # lxc file push ...
}

# The container's declared tunnel mode is available to your connect snippet as
# `tunnel_mode`, a helper from common.sh that returns "split" or "full" and
# derives it for containers created before the declaration existed. If your
# client can be told what to do with the routes a server pushes, derive that
# from it rather than inventing a key - protocol-openvpn.sh is the worked
# example. If your client offers no such control, ignore it: the declaration is
# still recorded and still governs how the default route is reported, so a
# gateway-imposed full tunnel is a stated outcome rather than a mystery.
#
# Never deduce the mode from what the gateway turned out to push, and never
# rewrite a default route to enforce it. This framework reports that invariant;
# enforcing it is deliberately out of scope.

# OPTIONAL: print (stdout) the value written to VPN_INTERFACE in
# /etc/vpn-client.env. Omit to accept the default `vpn0`. Define it when the
# kernel - not your client - picks the interface name, so proto_connect has a
# sane starting point to poll from (protocol-fortissl.sh returns "ppp0",
# because PPP interfaces are always named pppN and cannot be renamed inside
# an LXD container).
proto_write_env_interface() { echo "ppp0"; }

# OPTIONAL, all of these or none: the SSO path, for a gateway that fronts its
# login with SAML. A partial set is refused at startup naming what is missing.
#
# The container cannot open a browser - it has none, no display and no path to the
# operator's session, which is the isolation it exists for. So it prints where to
# go and takes back what the browser produced.
#
# Declare the values; do NOT prompt for them. The framework collects, which is
# where the rules about terminals and about never putting a credential in an
# argument are enforced. A plugin that prompted for its own would have to
# reimplement those, and each one would get them slightly wrong.
#
#   name|kind|default|prompt      kind is "secret" (no echo) or "plain";
#                                 an empty default makes the value required.
#
# This runs on the HOST, so orchestrator globals like $GATEWAY are available for a
# default - unlike the snippets below.
proto_sso_values() {
  printf 'cookie|secret||Session cookie from the browser\n'
  printf 'server|plain|%s|Server that authenticated the exchange\n' "${GATEWAY:-}"
}

# Text spliced into the container, defining proto_sso_url: print where to log in,
# return non-zero when the gateway could not be asked. Getting the URL sends no
# credential, so a failure here must read as "could not ask", never as "refused".
proto_sso_url_snippet() { cat <<'EOF'
proto_sso_url() { ...; }
EOF
}

# Text spliced into the container, defining proto_sso_connect: consume the
# collected values as $SSO_<name>, bring up the tunnel, leave the interface in
# VPN_INTERFACE. Like proto_connect it must NOT touch routing.
#
# Hand the credential to the client on its STANDARD INPUT. Not as an argument,
# which the process table shows; not through the environment, which /proc shows to
# anything running as the same user.
proto_sso_connect_snippet() { cat <<'EOF'
proto_sso_connect() { ...; }
EOF
}

# OPTIONAL: extra absolute paths the SSO path runs under sudo. Return nothing when
# it needs none. Never ask for a shell or setsid here: `sudo bash` and
# `sudo setsid <anything>` are both a root shell, which would undo the point of
# having a narrow allowlist.
proto_sso_sudo_commands() { echo ""; }

# OPTIONAL, host-side: obtain the declared values automatically, for the optional
# helper in scripts/vpn-sso-login.sh. Print them as name=value lines, one per
# declared name. It runs where a browser exists, which no container-side function
# can assume.
#
# It MUST NOT bring up a tunnel on the host. If it drives a tool that can do that,
# do not use that mode - the failure this project exists to prevent is the VPN
# landing on the operator's machine.
proto_sso_host_extract() {
  local name="$1"
  # ... print username=..., cookie=..., etc.
}

# OPTIONAL: print (stdout) a bash function named exactly `proto_disconnect`,
# spliced into the container's `vpn disconnect` in place of the default teardown.
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

That checks the snippet alone. After changing `common.sh` or the assembly
logic, check the whole assembled script, which is what actually runs:

```bash
LIB_DIR=scripts/lib PROTOCOL=<name>
bash -c "source $LIB_DIR/common.sh; source $LIB_DIR/orchestrator.sh
         source $LIB_DIR/protocol-$PROTOCOL.sh; render_connect_vpn" | bash -n /dev/stdin
```

An extra helper installed by `proto_post_install` gets no parse check from
`install_helpers`, so parse it the same way before trusting it.

A PROTO_NAME that disagrees with the filename is caught early - the
orchestrator exits before touching `lxc`, so this is safe to run anywhere:

```bash
./scripts/create-vpn-lxd-container.sh --name t --protocol <name>
```

## Where the client binaries end up

Nothing in the orchestrator names a client. `proto_client_processes` feeds
the "already connected" guard in `vpn connect` and the default teardown in
`vpn disconnect`; `proto_sudo_commands` feeds the sudoers allowlist for a
non-root `--user`. Get either wrong and the symptom is specific: a missing
process name means `vpn disconnect` reports "VPN down." with the tunnel still
up, and a missing sudo path means `vpn connect` hangs on a password prompt.

The interface sweep at the end of `vpn disconnect` deletes `$VPN_INTERFACE`,
`vpn0`, `tun0` and `ppp0`. A client that names its tunnel something else should
set it through `proto_write_env_interface`.

`proto_client_processes` is used a third way: the generated helper publishes it
as `VPN_CLIENT_PROCESSES`, and `record_connection` uses it to find the running
client's PID for the connection record. A name that does not match any running
process leaves the record without a PID, and a reader then cannot tell a live
tunnel from leftovers.

Changes to a plugin only affect containers created afterwards; existing ones
pick them up with `--refresh-helpers`.

## What you should NOT need to touch

- `scripts/create-vpn-lxd-container.sh` and `scripts/lib/orchestrator.sh` -
  profile setup, launch, package install, env file, SSH provisioning and the
  helper assembly are all protocol-agnostic.
- `scripts/lib/common.sh` (shared helpers - only touch if genuinely shared
  logic is missing, and keep it protocol-agnostic). Note this file is copied
  verbatim into the container's `vpn` command, so it must stay self-contained
  and depend on nothing beyond the base package set.

If you find yourself editing either of those to add a protocol, the
contract is probably missing something - open an issue/PR describing the gap
instead of hardcoding a protocol name into the orchestrator.
