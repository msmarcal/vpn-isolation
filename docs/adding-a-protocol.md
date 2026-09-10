# Adding a new VPN protocol

The orchestrator (`scripts/create-vpn-lxd-container.sh`) discovers protocols
dynamically from `scripts/lib/protocol-*.sh` - it never needs to change when
you add one. Drop a new file implementing the contract below and it's
immediately available as `--protocol <name>`.

## Contract

Create `scripts/lib/protocol-<name>.sh`. It must set two variables and define
six functions, plus two optional hooks the orchestrator probes for with
`declare -f` and skips when absent:

```bash
PROTO_NAME="<name>"                 # must match the filename suffix
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

# Print (stdout) extra KEY=VALUE lines to append to the container's
# /etc/vpn-client.env. Has access to orchestrator globals (GATEWAY, OVPN,
# ROUTE_NOPULL, etc).
proto_write_env_extra() { cat <<EOF
VPN_SOMETHING=${SOME_GLOBAL}
EOF
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
bash -n scripts/lib/protocol-<name>.sh   # syntax check
./scripts/create-vpn-lxd-container.sh --help   # confirm it's listed under "One of: ..."
```

To sanity-check the assembled `connect-vpn` script without `lxc`, source
`scripts/lib/common.sh` and your new protocol file in a throwaway shell,
call `proto_connect_snippet`, and run the result through `bash -n`.

## The one place a new client binary DOES need orchestrator changes

Connecting is fully pluggable; **disconnecting is not**. Two spots in
`scripts/create-vpn-lxd-container.sh` hardcode the set of known client
binaries, and a protocol introducing a new one has to add itself to both:

1. The "already connected" guard in the generated `connect-vpn` runner -
   currently `pgrep -x openconnect || pgrep -x openvpn || pgrep -x
   openfortivpn`. A client missing from this list lets a second `connect-vpn`
   start on top of a live tunnel.
2. The generated `disconnect-vpn` - it stops each known client by name and
   then deletes any leftover `vpn0`/`tun0`/`ppp0` link. A client missing here
   is simply never stopped, and `disconnect-vpn` will report "VPN down."
   while the tunnel is still up.

Add your client to both lists, and to the interface loop if your tunnel
device is named something other than `vpn0`/`tun0`/`ppp0`. If your client
needs a non-obvious teardown (fortissl, for instance, must first quit its
`screen` session), put it next to the existing per-client blocks.

Non-root containers need one more line: the sudoers allowlist written for
`--user` grants NOPASSWD only for the binaries it knows about, so add yours
if the container is meant to run as anything other than `root`.

## What you should NOT need to touch

- The rest of `scripts/create-vpn-lxd-container.sh` - profile setup, launch,
  package install, env file, SSH provisioning and the `connect-vpn` assembly
  are all protocol-agnostic.
- `scripts/lib/common.sh` (shared helpers - only touch if genuinely shared
  logic is missing, and keep it protocol-agnostic). Note this file is copied
  verbatim into the in-container `connect-vpn`, so it must stay self-contained
  and depend on nothing beyond the base package set.

If you find yourself editing anything beyond the teardown lists above, the
contract is probably missing something - open an issue/PR describing the gap
instead of hardcoding a protocol name into the orchestrator.
