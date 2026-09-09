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

**`--routes` accepts multiple networks** as a comma-separated list (no spaces). These become split routes inside the container - only traffic to these subnets goes through the VPN; everything else uses your normal connection. Edit later in `/etc/vpn-client.env` inside the container if needed.

Full guide: [`docs/lxd-vpn-client-containers.md`](docs/lxd-vpn-client-containers.md)

## Supported protocols

| Protocol | Flag |
|---|---|
| Cisco AnyConnect (with optional MFA) | `--protocol anyconnect` |
| Palo Alto GlobalProtect | `--protocol gp` |
| OpenVPN | `--protocol openvpn --ovpn <file>` |
| FortiGate SSL VPN | `--protocol fortissl` |

New VPNs/protocols: the script is plugin-based - drop a new `scripts/lib/protocol-<name>.sh` implementing the small contract described in [`docs/adding-a-protocol.md`](docs/adding-a-protocol.md). No changes to the orchestrator are needed.

## Repo layout

```
vpn-isolation/
├── README.md
├── docs/
│   ├── lxd-vpn-client-containers.md   # full setup + troubleshooting guide
│   └── adding-a-protocol.md           # plugin contract for new VPN protocols
└── scripts/
    ├── create-vpn-lxd-container.sh    # orchestrator: LXD profile/launch, dispatch to protocol libs
    └── lib/
        ├── common.sh                  # shared helpers (split routes, interface wait)
        ├── protocol-anyconnect.sh     # Cisco AnyConnect (openconnect)
        ├── protocol-gp.sh             # Palo Alto GlobalProtect (openconnect)
        ├── protocol-openvpn.sh        # OpenVPN (.ovpn profile)
        └── protocol-fortissl.sh       # FortiGate SSL VPN (openfortivpn)
```

## Security notes

- Never commit `.ovpn` files, certs, keys, or credentials to this repo. Push them directly into the container with `lxc file push` (see docs) and keep them out of git.
- If a VPN password/token ever leaks in a terminal paste or log, rotate it immediately.

## Roadmap / open items

- [ ] Optional: `lxc publish` a `vpn-client-template` image after first successful container, to speed up cloning for new projects
- [ ] Consider auto-detecting split-include routes from server response before falling back to manual `--routes`
