# customer-vpn-isolation

Isolate corporate VPN clients (Cisco AnyConnect/openconnect, Palo Alto GlobalProtect, OpenVPN, and future protocols) inside LXD containers, so no VPN ever rewrites routes/DNS on the host laptop.

**Run this on a work laptop, isolated from your other networking (home network, VPS, etc).** Not intended to run inside a shared/multi-tenant server.

## Why

Multiple VPN clients (native vendor client, NetworkManager/openconnect, OpenVPN) fighting over the same host routing table and `/etc/resolv.conf` causes daily breakage: DNS lost, wrong default route, leftover `tun`/`vpn0` interfaces, background agents conflicting with NetworkManager.

**Fix:** one LXD container per VPN. Each container gets its own network namespace - routes and DNS changes stay inside it. The host only does SSH (`ProxyJump`) and, if needed, HTTP via a SOCKS tunnel into the container.

## Quick start

```bash
git clone https://git.msmarcal.xyz/msmarcal/customer-vpn-isolation.git
cd customer-vpn-isolation
chmod +x scripts/create-vpn-lxd-container.sh

# Cisco AnyConnect example
./scripts/create-vpn-lxd-container.sh \
  --name vpn-example-anyconnect --protocol anyconnect \
  --gateway vpn.example.com/group-path \
  --routes 10.10.0.0/24 --dns-domain internal.example.com \
  --build-openconnect
```

Full guide: [`docs/lxd-vpn-client-containers.md`](docs/lxd-vpn-client-containers.md)

## Supported protocols

| Protocol | Flag |
|---|---|
| Cisco AnyConnect (with optional MFA) | `--protocol anyconnect` |
| Palo Alto GlobalProtect | `--protocol gp` |
| OpenVPN | `--protocol openvpn --ovpn <file>` |

New VPNs/protocols: the script is plugin-based - drop a new `scripts/lib/protocol-<name>.sh` implementing the small contract described in [`docs/adding-a-protocol.md`](docs/adding-a-protocol.md). No changes to the orchestrator are needed.

## Repo layout

```
customer-vpn-isolation/
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
        └── protocol-openvpn.sh        # OpenVPN (.ovpn profile)
```

## Security notes

- Never commit `.ovpn` files, certs, keys, or credentials to this repo. Push them directly into the container with `lxc file push` (see docs) and keep them out of git.
- This repo is **private**.
- If a VPN password/token ever leaks in a terminal paste or log, rotate it immediately.

## Roadmap / open items

- [ ] Optional: `lxc publish` a `vpn-client-template` image after first successful container, to speed up cloning for new projects
- [ ] Consider auto-detecting split-include routes from server response before falling back to manual `--routes`
