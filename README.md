# vpn-isolation

Run each corporate VPN client inside its own LXD container, so no VPN ever rewrites
the routing table or `/etc/resolv.conf` on your laptop.

**Meant for your own work machine.** Not for a shared or multi-tenant server.

## Why

Several VPN clients competing for one host routing table and one `/etc/resolv.conf`
breaks things daily: DNS disappears, the default route goes somewhere unexpected,
`tun` and `vpn0` interfaces are left behind, vendor agents fight NetworkManager.

One container per VPN fixes it. Each gets its own network namespace, so routes and
DNS changes stay inside. The host reaches through with SSH (`ProxyJump`), or with
`sshuttle` when a browser needs to see the other side.

## Prerequisites

In the order you will run into them.

**LXD, with its bridge.** Everything else assumes a container can be launched and
given an address.

```bash
lxc network list | grep lxdbr0
```

**No VPN running on the host.** A NetworkManager VPN profile or a vendor client
session will fight the containers for the same routing table, and the symptoms are
confusing rather than obvious. Disconnect them and leave them disconnected.

**For FortiGate only: the PPP line discipline, loaded on the host.** The container
gets `/dev/ppp` from its profile, but the discipline `pppd` switches the tty to lives
in a module the container cannot load itself.

```bash
grep ppp /proc/tty/ldiscs || sudo modprobe ppp_async
echo ppp_async | sudo tee /etc/modules-load.d/ppp.conf   # survive reboots
```

Without it every connect fails with `Couldn't set tty to PPP discipline: Operation
not permitted`, and no amount of restarting or recreating the container helps.
[Why, in the guide](docs/lxd-vpn-client-containers.md#prerequisites-on-the-host).

**Only if a browser or an API client needs the far side: `sshuttle`.** On the host,
not in the container. SSH alone covers reaching machines; this is for the times
something local has to speak to an internal address directly.

```bash
sudo apt install sshuttle
```

**For GlobalProtect SSO only, and optional: `gp-saml-gui`.** It lets the host-side
helper read the login credential out of a browser instead of you copying it from
developer tools. Everything works without it; you just do that step by hand.

```bash
sudo apt install gp-saml-gui
```

## Quick start

```bash
git clone <this repo>
cd vpn-isolation

./scripts/create-vpn-lxd-container.sh \
  --name vpn-example-anyconnect --protocol anyconnect \
  --gateway vpn.example.com/group-path \
  --routes 10.10.0.0/24,10.20.0.0/16 \
  --launchpad-id your-launchpad-id \
  --build-openconnect
```

It prints an SSH snippet and a `sshuttle` line for the container it just made. The
full guide, including one section per protocol, is
[`docs/lxd-vpn-client-containers.md`](docs/lxd-vpn-client-containers.md).

## Day to day

One container, start to finish. The order matters more than the individual commands:
connecting and reaching something through the tunnel are separate steps.

```bash
# 1. Start it. Containers are usually left stopped between sessions.
lxc start vpn-example-anyconnect

# 2. Connect. Use -t: some clients prompt for a password or a token.
lxc exec -t vpn-example-anyconnect -- vpn connect

# 3. Check what it is actually doing. This changes nothing.
lxc exec vpn-example-anyconnect -- vpn status
```

`vpn status` answers the question the rest of this document cannot: whether the
tunnel is up, whether the routes you asked for are installed, and whether the
default route is still where it belongs. It reports one of `down`, `connected`,
`degraded` or `stale`.

```bash
# 4a. SSH to something on the far side, through the container.
#     In ~/.ssh/config, once:
#       Host vpn-example-anyconnect
#         HostName <container ip>
#         User <container user>
#       Host internal-box
#         HostName 10.10.0.5
#         User you
#         ProxyJump vpn-example-anyconnect
ssh internal-box

# 4b. Or, when a browser or an API client needs to see the far side:
sshuttle -r vpn-example-anyconnect 10.10.0.0/24 10.20.0.0/16 --dns

# 5. Done for the day.
lxc exec vpn-example-anyconnect -- vpn disconnect
lxc stop vpn-example-anyconnect
```

If a step does not behave, the guide has a
[troubleshooting table](docs/lxd-vpn-client-containers.md#troubleshooting) organized
by symptom.

## Supported protocols

| Protocol                             | Flag                                  | Browser-based SSO                          |
| ------------------------------------ | ------------------------------------- | ------------------------------------------ |
| Cisco AnyConnect (with optional MFA) | `--protocol anyconnect`               | yes                                        |
| Palo Alto GlobalProtect              | `--protocol gp`                       | yes, with host-side automation             |
| OpenVPN                              | `--protocol openvpn --ovpn <file>`    | no, the community client has no equivalent |
| FortiGate SSL VPN                    | `--protocol fortissl`                 | yes                                        |

**SSO** means the login happens in a browser on your own machine, which is how SAML
portals with a second factor work, and a short-lived credential is carried into the
container. `vpn connect --sso` prints where to go and prompts for what comes back;
`scripts/vpn-sso-login.sh <container>` does the same from your machine and, for
GlobalProtect, reads the credential out of the browser for you.
[Details](docs/lxd-vpn-client-containers.md#sso-logins-saml-with-a-second-factor).

New protocols are plugins: drop a `scripts/lib/protocol-<name>.sh` implementing the
contract in [`docs/adding-a-protocol.md`](docs/adding-a-protocol.md) and
`--protocol <name>` starts working. The orchestrator needs no changes.

## Flags worth knowing at creation

**`--routes`** takes a comma-separated list of networks. Each entry needs an explicit
prefix (`/32` for a single host) and must be a network address; the list is validated
before anything is created. These become the split routes: only traffic to them goes
through the VPN. Omitted or set to `auto`, the container reads back whatever routes
its client installed on the tunnel, for every protocol.

**`--tunnel-mode split|full`** declares whether the default route should stay off the
tunnel. `split` is the default and is the reason this tool exists. It also decides how
a connect describes the default route, so a full tunnel is something asked for rather
than noticed afterwards.

**`--auth-mode native|sso`** sets which authentication path a bare `vpn connect` takes.
Either is selectable per connect with `--sso` or `--native`, whatever this was set to.

Any of these can be changed afterwards by editing `/etc/vpn-client.env` inside the
container. The
[key reference](docs/lxd-vpn-client-containers.md#etcvpn-clientenv-reference) lists
them all.

## Updating existing containers

A container keeps the command it was created with. After pulling a newer version of
this repo, regenerate it in place. This works on a stopped container and touches
nothing else, not even `/etc/vpn-client.env`:

```bash
./scripts/create-vpn-lxd-container.sh --name vpn-example-anyconnect --refresh-helpers
```

## Tests

```bash
tests/run.sh
```

Seven files, around 460 assertions, a few seconds. Plain Bash, no framework: it covers
the host-side helpers, that every generated container command parses and defines the
helpers it calls, and the plugin contract across every `protocol-*.sh`. Anything
needing a real LXD daemon, a real gateway or root is deliberately left out rather than
faked.

## Repo layout

```
vpn-isolation/
├── README.md
├── docs/
│   ├── lxd-vpn-client-containers.md   # full setup, key reference, troubleshooting
│   └── adding-a-protocol.md           # plugin contract for new VPN protocols
├── scripts/
│   ├── create-vpn-lxd-container.sh    # orchestrator: profile, launch, dispatch to a plugin
│   ├── vpn-sso-login.sh               # optional: drive an SSO login from your machine
│   └── lib/
│       ├── common.sh                  # copied into each container: routing, connection
│       │                              #   record, tunnel mode, status, SSO collection
│       ├── orchestrator.sh            # host side: render and install the vpn command
│       ├── protocol-anyconnect.sh     # Cisco AnyConnect (openconnect)
│       ├── protocol-gp.sh             # Palo Alto GlobalProtect (openconnect)
│       ├── protocol-openvpn.sh        # OpenVPN (.ovpn profile)
│       └── protocol-fortissl.sh       # FortiGate SSL VPN (openfortivpn)
└── tests/
    ├── run.sh                         # the suite
    ├── lib.sh                         # assertions and stub plumbing
    ├── stubs/                         # lxc, ip, sudo, pgrep and the clients
    └── fixtures/                      # recorded tool output, a synthetic SAML endpoint
```

## Security notes

- **Never commit `.ovpn` files, certs, keys or credentials.** Pass a profile with
  `--ovpn <file>` and the orchestrator copies it into the container, along with any
  certs and keys it references relatively. A path referenced absolutely is left alone
  and needs `lxc file push` by hand, which the guide covers.
- **Passwords and tokens are prompted for, never stored.** Nothing is written to
  `/etc/vpn-client.env` or to disk. If one leaks through a terminal paste or a log,
  rotate it.
- A container created with `--user` gets a narrow `NOPASSWD` entry: the VPN client
  binaries, plus `ip`, `kill` and `pkill` for bringing the tunnel up and tearing it
  down. No shell, deliberately, and no `tail`: `sudo bash` would be a root shell, and
  `sudo tail` would be root-read on every file.

## Roadmap

- [ ] Optional: `lxc publish` a `vpn-client-template` image after the first successful
      container, to make later ones faster to create
