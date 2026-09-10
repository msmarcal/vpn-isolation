# LXD VPN Client Containers (multi-protocol)

Isolate corporate VPNs inside LXD containers so they never touch the host's routes, DNS, or other networking.

## Supported protocol patterns

| Example use case | Protocol | Client tooling inside container | Notes |
|---|---|---|---|
| Cisco AnyConnect / ASA-Firepower with SAML or token MFA | Cisco AnyConnect (openconnect) | `openconnect --protocol=anyconnect` | Gateway path matters (e.g. a group-specific path). Need openconnect **9.21+** on updated ASA/Firepower. Prefer the CLI over GUI auth dialogs. |
| Palo Alto GlobalProtect | GlobalProtect (openconnect) | `openconnect --protocol=gp` | Same openconnect binary, different protocol. Portal vs gateway URL may differ - confirm with the vendor's portal docs. |
| OpenVPN (server-issued profile) | OpenVPN | `openvpn` + `.ovpn` profile (+ optional auth user-pass / certs) | Usually a single `.ovpn` export from the server admin. Keep certs/keys only inside the container. |
| FortiGate SSL VPN | FortiSSL VPN | `openfortivpn` | Gateway + username/password, often with OTP/2FA. Password is prompted interactively; no good way to pre-supply it without storing plaintext credentials (security risk). |

Add a new container with the matching `--protocol` template for any new VPN. If a VPN **mandates** a proprietary native client with GUI/HostScan/posture-check requirements, use a VM instead of a container.

## Architecture

```
Host (laptop)
├── local LAN + LXD bridge (never touched by VPN containers)
├── ~/.ssh/config.d/<project>-config   # ProxyJump into container
├── optional: sshuttle for HTTP/HTTPS
│
├── lxc: vpn-example-anyconnect     # openconnect anyconnect
├── lxc: vpn-example-globalprotect  # openconnect gp
├── lxc: vpn-example-openvpn        # openvpn + .ovpn profile
├── lxc: vpn-example-fortissl       # openfortivpn (FortiGate SSL VPN)
└── (rare) VM                       # only if a native client is mandatory
```

Daily use is SSH + occasional HTTP/HTTPS. No RDP/VNC required.

## Prerequisites on the host

- LXD installed (`lxdbr0` present).
- Do **not** keep host NetworkManager VPN profiles or a native VPN client session active while using these containers.
- For Cisco/GlobalProtect portals that fail on distro-packaged openconnect (e.g. 404 on auth), build a recent openconnect inside the container (`--build-openconnect`).

## One-time host setup

```bash
chmod +x scripts/create-vpn-lxd-container.sh
```

The create script ensures profile `vpn-client` exists (`eth0` on `lxdbr0`, `/dev/net/tun`, nesting).

## Create containers

### Cisco AnyConnect

```bash
./scripts/create-vpn-lxd-container.sh \
  --name vpn-example-anyconnect \
  --protocol anyconnect \
  --gateway vpn.example.com/group-path \
  --routes 10.10.0.0/24 \
  --dns-domain internal.example.com \
  --launchpad-id your-launchpad-id \
  --build-openconnect
```

## SSH key provisioning

By default the container login user is **`root`** (`--user` overrides it). This is deliberate: LXD's `ubuntu:*` images do *not* auto-create a `ubuntu` user the way public clouds (AWS/GCE/Azure) do - that behavior comes from a cloud datasource-specific default user that LXD's cloud-init datasource doesn't trigger. `root` always exists in any LXD image, so it's the safe default. If you pass `--user someone` for a non-root name that doesn't exist yet, the script creates it (`useradd -m`, added to `sudo` group) before importing keys.

Keys are imported via `ssh-import-id`:

```bash
--launchpad-id your-launchpad-id   # ssh-import-id lp:your-launchpad-id
--github-id your-github-id         # ssh-import-id gh:your-github-id (combinable)
```

If neither flag is given, the script falls back to pushing your local `~/.ssh/id_ed25519.pub` (or `id_rsa.pub`) into the container's `authorized_keys`. If neither a Launchpad/GitHub id nor a local pubkey is available, it prints a warning and you can import manually:

```bash
# root (default)
lxc exec vpn-example-anyconnect -- ssh-import-id lp:your-launchpad-id

# non-root --user
lxc exec vpn-example-anyconnect -- sudo -u someone -H ssh-import-id lp:your-launchpad-id
```

### GlobalProtect

```bash
./scripts/create-vpn-lxd-container.sh \
  --name vpn-example-globalprotect \
  --protocol gp \
  --gateway vpn.example.com \
  --routes 10.0.0.0/8 \
  --build-openconnect
```

Replace gateway/routes with the real portal and internal subnets when you have them. If portal and gateway URLs differ, put the **portal** in `--gateway` first; adjust `/etc/vpn-client.env` after testing.

### OpenVPN

```bash
./scripts/create-vpn-lxd-container.sh \
  --name vpn-example-openvpn \
  --protocol openvpn \
  --ovpn /path/to/profile.ovpn \
  --routes 10.20.0.0/24
```

The script copies the `.ovpn` (and referenced cert/key files next to it, if embedded paths are relative and present) into the container at `/etc/openvpn/client/client.ovpn`.

If the profile needs a separate user-pass file:

```bash
lxc file push userpass.txt vpn-example-openvpn/etc/openvpn/client/userpass.txt
lxc exec vpn-example-openvpn -- bash -lc 'echo "auth-user-pass /etc/openvpn/client/userpass.txt" >> /etc/openvpn/client/client.ovpn'
```

### FortiGate SSL VPN

```bash
./scripts/create-vpn-lxd-container.sh \
  --name vpn-example-fortissl \
  --protocol fortissl \
  --gateway vpn.example.com \
  --routes 10.30.0.0/24 \
  --forti-user your-username
```

Uses `openfortivpn` (open-source FortiGate SSL VPN client). **Password is prompted interactively** - run `lxc exec -t vpn-example-fortissl -- connect-vpn` (the `-t` flag is important, otherwise the TTY-less prompt will fail).

**OTP/2FA is opt-in, not auto-detected.** `openfortivpn` runs inside a detached `screen` session (it needs a TTY and cannot daemonize), so it never gets to prompt for anything itself - `connect-vpn` collects the password and token up front and passes them as `--password` / `--otp`. If your gateway requires 2FA, enable the token prompt once, after creation:

```bash
lxc exec vpn-example-fortissl -- bash -lc 'echo VPN_FORTI_OTP_REQUIRED=1 >> /etc/vpn-client.env'
```

Without it, a 2FA-protected gateway simply fails to bring up the PPP interface; check `sudo tail -f /var/log/openfortivpn.log` inside the container to confirm.

No certificate/key files to push (FortiSSL VPN authenticates with username/password only, like the Cisco AnyConnect case). The gateway port defaults to 443; override by setting `VPN_FORTI_PORT` in the container's `/etc/vpn-client.env` after creation if needed.

**Note:** The LXD profile automatically includes `/dev/ppp` (mode 0666) which `openfortivpn` requires to create the PPP tunnel interface. If you get "Couldn't open the /dev/ppp device" errors, verify the device is present with `lxc exec <container> -- ls -la /dev/ppp`.

## Daily workflow

### Connect

```bash
lxc start vpn-example-anyconnect
lxc exec vpn-example-anyconnect -- connect-vpn
# anyconnect/gp: username, password, MFA/token prompts
# openvpn: starts openvpn with the packaged profile
```

### SSH from host (transparent)

```sshconfig
# ~/.ssh/config.d/example-config
Host vpn-example-anyconnect
  HostName 10.254.2.XX
  User root

Host internal-host-example
  HostName 10.10.0.10
  User remote-user
  ProxyJump vpn-example-anyconnect
```

Multi-hop chains (e.g. container -> internal jumphost -> final target) need each intermediate host to declare its own `ProxyJump` pointing at the previous hop - `ProxyJump` is not transitive across unrelated `Host` blocks unless each one chains to the next.

### Occasional HTTP/HTTPS (sshuttle)

`sshuttle` gives transparent access to the VPN's internal subnets without configuring a proxy in every tool - point it at the same CIDRs you passed to `--routes`, and any local app (browser, curl, etc) just works, no per-app proxy or `HTTPS_PROXY` juggling required.

Install once on the host (not inside the container):

```bash
sudo apt install sshuttle   # or: pipx install sshuttle
```

Then, with the container's VPN already connected:

```bash
sshuttle -r vpn-example-anyconnect 10.10.0.0/24 --dns
```

- `-r vpn-example-anyconnect` reuses the same SSH `Host` alias from your `~/.ssh/config`
- The CIDR list should match `--routes` (comma-separated `--routes` becomes multiple arguments here, e.g. `10.10.0.0/24 10.20.0.0/16`)
- `--dns` resolves internal hostnames through the container instead of your local resolver, avoiding split-DNS issues
- Runs in the foreground by default; add `-D --pidfile=/tmp/sshuttle-example.pid` to daemonize, and `sshuttle --stop-pidfile=/tmp/sshuttle-example.pid` (or `pkill -f sshuttle`) to stop it

### Disconnect / stop

```bash
lxc exec vpn-example-anyconnect -- disconnect-vpn
lxc stop vpn-example-anyconnect
```

## Split routes

`connect-vpn` keeps the container default route on `eth0` and only adds `--routes` via the VPN interface. Edit later:

```bash
lxc exec vpn-example-anyconnect -- vim /etc/vpn-client.env
# VPN_ROUTES=10.10.0.0/24,10.20.0.0/24
```

## `/etc/vpn-client.env` reference

Written once at creation and sourced by `connect-vpn` / `disconnect-vpn` on every run, so editing it is the supported way to change a container's behavior after the fact. No restart needed - the next `connect-vpn` picks up the new values.

| Key | Set for | Meaning |
|---|---|---|
| `VPN_PROTOCOL` | all | Which protocol the container was built for. Informational after creation - changing it does not swap the baked-in `connect-vpn` logic. |
| `VPN_ROUTES` | all | Comma-separated split routes, no spaces. `auto` asks the protocol to detect server-pushed routes (anyconnect only); empty means no manual routes. |
| `VPN_DNS_DOMAIN` | all | Informational only - nothing in `connect-vpn` reads it. |
| `VPN_INTERFACE` | all | Expected tunnel interface. `vpn0` by default, `ppp0` for fortissl. `connect-vpn` overwrites it at runtime with whatever actually appeared. |
| `VPN_GATEWAY` | anyconnect, gp, fortissl | Portal/gateway host, including any group path for anyconnect. |
| `VPN_OVPN` | openvpn | Path to the profile inside the container (`/etc/openvpn/client/client.ovpn`). |
| `VPN_ROUTE_NOPULL` | openvpn | `1` (default) passes `--route-nopull`, ignoring a server-pushed default route. `0` accepts it - full tunnel inside the container. |
| `VPN_FORTI_USER` | fortissl | Username passed to `openfortivpn`. Falls back to `$USER` if empty. |
| `VPN_FORTI_PORT` | fortissl | Gateway port, defaults to `443`. |
| `VPN_FORTI_OTP_REQUIRED` | fortissl | Any non-empty value makes `connect-vpn` prompt for an OTP/2FA token. Empty = no prompt. |

Passwords and tokens are deliberately absent: they are prompted for on every connect and never written to this file.

## Protocol-specific notes

### anyconnect

- Keep any group path in the gateway URL if the server requires it.
- Prefer interactive CLI inside the container; GUI auth dialogs (e.g. GNOME NetworkManager) can loop on MFA and lock the account.
- openconnect **9.21+** may be required for updated Cisco ASA/Firepower gateways (older versions can POST to the wrong path and get a 404).

### gp (GlobalProtect)

- `openconnect --protocol=gp`.
- Some portals need `--usergroup=` or a separate gateway cookie flow; test with:
  ```bash
  lxc exec vpn-example-globalprotect -- openconnect --protocol=gp -v <portal>
  ```
- Same split-route approach as anyconnect after the tunnel is up.

### openvpn

- Prefer a single exported `.ovpn` from the server admin.
- Store secrets only inside the container (`/etc/openvpn/client/`), mode `600`.
- If the server pushes `redirect-gateway` and you still want split-tunnel, `connect-vpn` adds explicit routes and can ignore the pulled default route via `--route-nopull` when `VPN_ROUTE_NOPULL=1` (default for this framework).

## Do not mix with host VPN clients

```bash
lxc stop vpn-example-anyconnect vpn-example-globalprotect vpn-example-openvpn 2>/dev/null || true
nmcli connection down <host-vpn-profile> 2>/dev/null || true
sudo ip link delete vpn0 2>/dev/null || true
sudo systemctl restart vpnagentd 2>/dev/null || true
```

## Cloning / new project

```bash
lxc stop vpn-example-anyconnect
lxc publish vpn-example-anyconnect --alias vpn-client-template
lxc launch vpn-client-template vpn-newproject
lxc exec vpn-newproject -- vim /etc/vpn-client.env
```

Or re-run `create-vpn-lxd-container.sh` with a new `--name` / `--protocol`.

## Troubleshooting

| Symptom | Check |
|---|---|
| cannot create tun | `lxc config set vpn-X security.privileged true` + restart |
| Cisco/ASA auth 404 on `/` | rebuild openconnect (`--build-openconnect`) |
| MFA/token login failed before token prompt | account lockout - wait / ask the VPN provider's IT |
| GlobalProtect stuck on portal | confirm portal vs gateway URL; try `-v` |
| OpenVPN connects but no internal access | subnet missing from `VPN_ROUTES`; or server pushes a different topology |
| SSH timeout to internal host | VPN up? `lxc exec vpn-X -- ip route` |
| host DNS/routes broken | VPN was started on the host - stop it and delete leftover `vpn0` |

## Files

- Guide: `docs/lxd-vpn-client-containers.md`
- Script: `scripts/create-vpn-lxd-container.sh`
