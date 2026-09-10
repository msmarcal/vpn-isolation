# vpn-isolation

Isolate corporate VPN clients (Cisco AnyConnect/openconnect, Palo Alto GlobalProtect, OpenVPN, and future protocols) inside LXD containers, so no VPN ever rewrites routes/DNS on the host laptop.

**Run this on a work laptop, isolated from your other networking (home network, VPS, etc).** Not intended to run inside a shared/multi-tenant server.

## Why

Multiple VPN clients (native vendor client, NetworkManager/openconnect, OpenVPN) fighting over the same host routing table and `/etc/resolv.conf` causes daily breakage: DNS lost, wrong default route, leftover `tun`/`vpn0` interfaces, background agents conflicting with NetworkManager.

**Fix:** one LXD container per VPN. Each container gets its own network namespace - routes and DNS changes stay inside it. The host only does SSH (`ProxyJump`) and, if needed, HTTP via `sshuttle` into the container.

## Quick start

```bash
git clone <this repo>
cd vpn-isolation

# Cisco AnyConnect example
./scripts/create-vpn-lxd-container.sh \
  --name vpn-example-anyconnect --protocol anyconnect \
  --gateway vpn.example.com/group-path \
  --routes 10.10.0.0/24,10.20.0.0/16 --dns-domain internal.example.com \
  --launchpad-id your-launchpad-id \
  --build-openconnect
```

**`--routes` accepts multiple networks** as a comma-separated list (no spaces). These become split routes inside the container - only traffic to these subnets goes through the VPN; everything else uses your normal connection. If omitted or set to `auto`, the protocol attempts to detect routes from the server response (currently implemented for AnyConnect; other protocols may fallback to no manual routes). Edit later in `/etc/vpn-client.env` inside the container if needed.

Full guide: [`docs/lxd-vpn-client-containers.md`](docs/lxd-vpn-client-containers.md)

## Supported protocols

| Protocol | Flag |
|---|---|
| Cisco AnyConnect (with optional MFA) | `--protocol anyconnect` |
| Palo Alto GlobalProtect | `--protocol gp` |
| OpenVPN | `--protocol openvpn --ovpn <file>` |
| FortiGate SSL VPN | `--protocol fortissl` |

New VPNs/protocols: the script is plugin-based - drop a new `scripts/lib/protocol-<name>.sh` implementing the small contract described in [`docs/adding-a-protocol.md`](docs/adding-a-protocol.md). Dispatch needs no orchestrator change, and the test suite picks the new plugin up automatically.

## Tests

```bash
sudo apt install bats   # dev-only dependency
make test               # ~6s
```

The suite runs against a fake `lxc` on `PATH`, so it needs no LXD, no container, no root and no network - it asserts on the exact `lxc` calls the orchestrator would make, and diffs the generated in-container `connect-vpn` against committed snapshots. See [`tests/README.md`](tests/README.md).

It cannot prove a tunnel actually comes up; that stays a manual step, and never against a `vpn-client` profile already in use - pass a throwaway `--profile`.

## Repo layout

```
vpn-isolation/
├── README.md
├── Makefile                           # test, lint, golden-update
├── docs/
│   ├── lxd-vpn-client-containers.md   # full setup + troubleshooting guide
│   └── adding-a-protocol.md           # plugin contract for new VPN protocols
├── scripts/
│   ├── create-vpn-lxd-container.sh    # orchestrator: LXD profile/launch, dispatch to protocol libs
│   └── lib/
│       ├── common.sh                  # shared helpers (split routes, interface wait)
│       ├── protocol-anyconnect.sh     # Cisco AnyConnect (openconnect)
│       ├── protocol-gp.sh             # Palo Alto GlobalProtect (openconnect)
│       ├── protocol-openvpn.sh        # OpenVPN (.ovpn profile)
│       └── protocol-fortissl.sh       # FortiGate SSL VPN (openfortivpn)
└── tests/                             # bats suite, runs against a mocked lxc
    ├── helpers/                       # fake lxc, shared setup
    ├── unit/                          # lint, plugin contract, golden, orchestrator
    └── golden/                        # snapshots of the generated connect-vpn
```

## Security notes

- Never commit `.ovpn` files, certs, keys, or credentials to this repo. Push them directly into the container with `lxc file push` (see docs) and keep them out of git. `make test` fails if a secret-shaped file ever becomes tracked, and if a non-placeholder gateway hostname appears in the docs.
- Passwords and tokens are prompted for on every connect and never written to disk - `/etc/vpn-client.env` holds configuration only.
- If a VPN password/token ever leaks in a terminal paste or log, rotate it immediately.

## Roadmap / open items

- [ ] Optional: `lxc publish` a `vpn-client-template` image after first successful container, to speed up cloning for new projects
- [ ] Optional: integration tests that build a throwaway container and assert the tunnel device comes up
- [x] Auto-detect split-include routes from server response when `--routes` is omitted or `auto` (AnyConnect; other protocols fallback)
- [x] Test suite: plugin-contract, golden-file and orchestrator tests against a mocked `lxc`
