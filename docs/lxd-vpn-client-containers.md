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
- **For FortiGate SSL VPN only: the host kernel needs the PPP line discipline loaded.** The container gets `/dev/ppp` from the profile, but the discipline `pppd` switches the tty to lives in a separate module the container cannot load itself:

  ```bash
  sudo modprobe ppp_async
  grep -q ppp /proc/tty/ldiscs && echo "ppp line discipline present"
  # persist it across reboots
  echo ppp_async | sudo tee /etc/modules-load.d/ppp.conf
  ```

  `ppp_generic` is built into the Ubuntu kernel, so `/dev/ppp` exists and opens whether or not this is done - which is why the symptom points somewhere else entirely. `ppp_async` is a module, and with `dev.tty.ldisc_autoload=0` (the default on Ubuntu) loading a line discipline on demand needs `CAP_SYS_MODULE`, which an unprivileged container does not have. The result is `Couldn't set tty to PPP discipline: Operation not permitted` on every connect, surviving container restarts and recreation, until the module is loaded on the **host**.

## One-time host setup

```bash
chmod +x scripts/create-vpn-lxd-container.sh
```

The create script ensures profile `vpn-client` exists (`eth0` on `lxdbr0`, `/dev/net/tun`, `/dev/ppp` mode 0660). It does not enable `security.nesting`: nothing here runs a container inside the container, and tun, ppp and split routing were verified to work without it.

## Create containers

### Cisco AnyConnect

```bash
./scripts/create-vpn-lxd-container.sh \
  --name vpn-example-anyconnect \
  --protocol anyconnect \
  --gateway vpn.example.com/group-path \
  --routes 10.10.0.0/24 \
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

Uses `openfortivpn` (open-source FortiGate SSL VPN client). **Password is prompted interactively** - run `lxc exec -t vpn-example-fortissl -- vpn connect` (the `-t` flag is important, otherwise the TTY-less prompt will fail).

**OTP/2FA is opt-in, not auto-detected.** `openfortivpn` runs inside a detached `screen` session (it needs a TTY and cannot daemonize), so it never gets to prompt for anything itself - `vpn connect` collects the password and token up front and passes them as `--password` / `--otp`. If your gateway requires 2FA, enable the token prompt once, after creation:

```bash
lxc exec vpn-example-fortissl -- bash -lc 'echo VPN_FORTI_OTP_REQUIRED=1 >> /etc/vpn-client.env'
```

Without it, a 2FA-protected gateway simply fails to bring up the PPP interface; check `sudo tail -f /var/log/openfortivpn.log` inside the container to confirm.

No certificate/key files to push (FortiSSL VPN authenticates with username/password only, like the Cisco AnyConnect case). The gateway port defaults to 443; pass `--forti-port 10443` at creation, or edit `VPN_FORTI_PORT` in the container's `/etc/vpn-client.env` afterwards.

**Note:** The LXD profile automatically includes `/dev/ppp` (mode 0660, root-owned) which `openfortivpn` requires to create the PPP tunnel interface. `vpn connect` always invokes the client through `sudo`, so root reaches the device even in a `--user` container. If you get "Couldn't open the /dev/ppp device" errors, verify the device is present with `lxc exec <container> -- ls -la /dev/ppp`.

A profile created by an older revision of the script used mode 0666, which also let unprivileged processes in the container open `/dev/ppp`. Re-running the create script tightens an existing profile to 0660 automatically; containers already using it pick the new mode up on their next restart. To apply it without creating a container:

```bash
lxc profile device set vpn-client ppp mode=0660
lxc restart <container>   # per container using the profile
```

**Known issue - "Couldn't set tty to PPP discipline: Operation not permitted".** Two different causes produce this, and they need opposite responses. Check which one first:

```bash
grep ppp /proc/tty/ldiscs    # on the HOST, not in the container
```

No output means the host is missing `ppp_async` - see [Prerequisites on the host](#prerequisites-on-the-host). Restarting or recreating the container will not help, because nothing in the container can load a kernel module. A line reading `ppp 3` means the discipline is there and the cause is the second one below.

If a previous `openfortivpn`/`pppd` process was killed abruptly (crash, `lxc stop` while connected, manual `pkill -9`), the kernel can leave `/dev/ppp` in a state where the *next* connection attempt fails with this error, even though everything looks clean (`pgrep openfortivpn` empty, device permissions correct). `vpn disconnect` sends `SIGTERM` to `openfortivpn` first (clean PPP logout) and waits up to 15 seconds for it to actually exit before touching the screen session, specifically to avoid this. If the client does not exit in time it is force-killed, and `vpn disconnect` prints a warning saying so, since that is the case most likely to leave `/dev/ppp` stuck. If it still happens: `lxc restart <container>` clears the stuck kernel state and the next `vpn connect` works. Always prefer `vpn disconnect` over killing the container/process directly.

Containers created before this fix still carry the old teardown, which closed the screen session after a fixed delay. Update them with `--refresh-helpers` (see [Updating helpers in an existing container](#updating-helpers-in-an-existing-container)).

## Daily workflow

### Connect

> **Renamed.** A container installs a single `vpn` command with `connect` and
> `disconnect` subcommands. It replaced `connect-vpn` and `disconnect-vpn`, which
> are removed - there are no aliases. A container created earlier keeps working on
> the pair it has until you run `--refresh-helpers`, which installs the new command
> and removes the old two. See
> [Updating helpers in an existing container](#updating-helpers-in-an-existing-container).

```bash
lxc start vpn-example-anyconnect
lxc exec vpn-example-anyconnect -- vpn connect
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
lxc exec vpn-example-anyconnect -- vpn disconnect
lxc stop vpn-example-anyconnect
```

## Updating helpers in an existing container

The `vpn` command and the sudoers allowlist are generated from this repo when a container is created, and nothing inside the container reads the repo again. So after pulling a newer version, existing containers keep running the command they were built with until you refresh them:

```bash
./scripts/create-vpn-lxd-container.sh --name vpn-example-fortissl --refresh-helpers
```

- Regenerates `/usr/local/bin/vpn` and, for a container created with a non-root `--user`, `/etc/sudoers.d/vpn-client`, from exactly the same source a new container would get.
- Removes `/usr/local/bin/connect-vpn` and `/usr/local/bin/disconnect-vpn`, the per-action commands `vpn` replaced. Without that a refreshed container would hold both, and the old pair would keep working while frozen at whatever version installed it.
- Reads the protocol from the container's `/etc/vpn-client.env`, so `--protocol` is not needed. Passing a different one is refused rather than rebuilding the container with another protocol's helpers.
- Works on a **stopped** container (it uses `lxc file push`, not `lxc exec`), and leaves it stopped.
- Does not touch `/etc/vpn-client.env`, installed packages, the openconnect build, or SSH keys. Changes that need any of those still mean recreating the container.
- Also refreshes `/etc/tmpfiles.d/vpn-client.conf`, the rule that creates the runtime directory `vpn connect` records into. On a running container the directory is created immediately as well; on a stopped one it appears at next start.
- The generated scripts are checked with `bash -n`, and the sudoers entry with `visudo -c`, before anything is pushed.

## Split routes

`vpn connect` keeps the container default route on `eth0` and only adds `--routes` via the VPN interface.

`--routes` is validated on the host before anything is created. Each entry needs an explicit prefix length (`/32` for a single host) and must be a network address, with no host bits set: `10.10.1.0/16` is rejected with a suggestion of `10.10.0.0/16`. Spaces around commas are removed. This check exists because `ip route` refuses such entries and route failures do not abort a connect that already succeeded, so a bad entry would otherwise just be a missing route and internal hosts that time out.

### `auto`

`--routes auto` is the default, and it works for every protocol. After the tunnel is up, `vpn connect` reads back the routes the client installed on the tunnel interface and treats those as the route set. There is no separate query to the gateway: every supported client installs what the server pushed, so reading the routing table is what asking the server amounts to.

Two things follow from that:

- A gateway that pushes nothing leaves you with no routes. `vpn connect` says so and stays up, since the tunnel itself is fine. Set `--routes` explicitly if internal hosts then time out.
- A default route the gateway pushed is never part of the detected set. Split tunnel is the point, and the container's default stays on `eth0`.

Detection waits for the route set to settle rather than reading once, because the tunnel interface exists before the client has finished installing routes - on PPP the gap is wide enough to matter. The cost is that a genuinely route-less gateway pauses for the full settle window before reporting nothing.

OpenVPN used to be the exception: it was created with `--route-nopull`, which discards every route the server pushes, so `auto` had nothing to find - a tunnel with no routes on it, from the default flags alone. It is now configured to accept the server's subnets and refuse only its default route, so `auto` works there like everywhere else.

Edit later:

```bash
lxc exec vpn-example-anyconnect -- vim /etc/vpn-client.env
# VPN_ROUTES=10.10.0.0/24,10.20.0.0/24
```

Hand edits skip that validation, so double-check the format. After `vpn connect`, compare the routes it prints against what you set.

### Declaring a full tunnel

`--tunnel-mode split|full` at creation records what the container is for. `split` is the default and is what the rest of this document assumes. `--no-route-nopull` is still accepted and means `--tunnel-mode full`; asking for both in contradictory directions is refused.

The declaration does two things. For OpenVPN it decides how the client treats the routes a server pushes:

| `VPN_TUNNEL_MODE` | `VPN_ROUTES`     | What the client is told                                     |
| ----------------- | ---------------- | ------------------------------------------------------------- |
| `split`           | `auto`           | accept the server's subnets, ignore its default route          |
| `split`           | explicit CIDRs   | discard everything pushed; only the listed routes are added    |
| `full`            | either           | accept everything, default route included                      |

For every protocol, including the three whose clients cannot be told any of this, it decides how `vpn connect` reports the default route. A `full` container is told its default route on the tunnel is expected. A `split` container whose client took the default route anyway is told the invariant is broken, in as many words - and the route is left alone, because this reports the invariant rather than enforcing it. Reject a design that silently rewrites it.

### Asking what the tunnel is doing

```bash
lxc exec vpn-example-fortissl -- vpn status
```

One screen, no flags, and it changes nothing: every command it runs is a read, and
it will not install a route it finds missing. The state is in the text rather than
the exit status - reporting successfully is success, whatever the state, so this is
a report for a person rather than something to branch on in a script.

| State       | What it means                                                                    |
| ----------- | ---------------------------------------------------------------------------------- |
| `down`      | no client running and no tunnel interface                                          |
| `connected` | client running, interface up, every expected route installed, default route where the declared mode says |
| `degraded`  | client running, but a route is missing or the default route is not where the declared mode says |
| `stale`     | no client running, but the interface and its routes are still there - run `vpn disconnect` |

Two things it is careful about. A client can exit without removing its record, so
being alive is established from the process - both its id **and** its name, because
ids get recycled - never from the record existing. And a connection made before
records were written has no expected route set, which is reported as unknown rather
than as nothing missing: `degraded` is never claimed on that basis alone.

What it deliberately does not do: no reachability probing, because no target host
is configured anywhere and picking one would be a guess; no reading the client's
log, which needs a privilege the sudoers allowlist withholds on purpose; and no
repair. It reports the split tunnel invariant, it does not enforce it.

### What a connect records

While a tunnel is up, `vpn connect` records it in `/run/vpn-client/state`: the interface that actually came up, the effective route set and whether it was configured or detected, the client process and its PID, when it connected, and the resolver configuration as it stood. That last one is the baseline `vpn status` compares against - without it, whether DNS was rewritten is unanswerable, since a nameserver list on its own says nothing about whether it changed. The file is transient by design - `/run` is tmpfs, so it is gone after a container restart - and a reader should treat it as absent when the recorded PID is no longer alive.

The directory is created by `/etc/tmpfiles.d/vpn-client.conf`, owned by the container login user so that a non-root `--user` container can write the record without any extra sudo privilege.

## `/etc/vpn-client.env` reference

Written once at creation and sourced by `vpn connect` / `vpn disconnect` on every run, so editing it is the supported way to change a container's behavior after the fact. No restart needed - the next `vpn connect` picks up the new values.

Because the file is `source`d, it is shell syntax. Plain values (hostnames, paths, CIDR lists) are written bare; any value with a space, quote, `$` or other shell character is written in single quotes, e.g. `VPN_GATEWAY='vpn.example.com/my group'`. Keep that quoting when editing by hand.

| Key | Set for | Meaning |
|---|---|---|
| `VPN_PROTOCOL` | all | Which protocol the container was built for. **Do not edit.** `--refresh-helpers` reads it to decide which protocol's `vpn connect` to generate, but it installs no packages, so pointing it at another protocol produces a container that cannot connect. Recreate the container instead. |
| `VPN_ROUTES` | all | Comma-separated split routes, no spaces. `auto` (the default) reads back the routes the client installed on the tunnel, for every protocol; empty behaves the same as `auto`. See "Split routes" above for what `auto` can and cannot find. |
| `VPN_INTERFACE` | all | Expected tunnel interface. `vpn0` by default, `ppp0` for fortissl. `vpn connect` overwrites it at runtime with whatever actually appeared. |
| `VPN_GATEWAY` | anyconnect, gp, fortissl | Portal/gateway host, including any group path for anyconnect. |
| `VPN_OVPN` | openvpn | Path to the profile inside the container (`/etc/openvpn/client/client.ovpn`). |
| `VPN_AUTH_MODE` | all | `native` (default) or `sso`. Which authentication path a bare `vpn connect` takes. **Absent in containers created before it existed**, where it reads as `native`. `vpn connect --sso` / `--native` override it for one run without writing here. Setting it to `sso` for a protocol with no SSO path makes `vpn connect` refuse, naming the protocol. |
| `VPN_TUNNEL_MODE` | all | `split` (default) or `full`. Declares whether the container's default route should stay on `eth0`. It is intent, not mechanism: OpenVPN derives its client flags from it, and for every protocol it decides how `vpn connect` describes the default route. **Absent in containers created before it existed**, where it is derived - `full` when `VPN_ROUTE_NOPULL=0`, `split` otherwise - so nothing has to be edited. |
| `VPN_ROUTE_NOPULL` | openvpn | `1` passes `--route-nopull`, discarding every route the server pushes. `0` accepts them all. **Written only when asked for**, and it overrides `VPN_TUNNEL_MODE` when present, so a container that has it keeps behaving exactly as it did. No flag sets it any more; add it by hand for the rare case where you want the client to ignore the server's routes entirely. |
| `VPN_FORTI_USER` | fortissl | Username passed to `openfortivpn`. Falls back to `$USER` if empty. |
| `VPN_FORTI_PORT` | fortissl | Gateway port, defaults to `443`. |
| `VPN_FORTI_OTP_REQUIRED` | fortissl | Any non-empty value makes `vpn connect` prompt for an OTP/2FA token. Empty = no prompt. |

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
- A server pushing `redirect-gateway` does not full-tunnel a `split` container: the client is told to ignore that directive, and a pushed route for the whole address space, so the subnets arrive and the default route does not. Both forms are filtered, because a server can express the same intent either way.

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

## SSO logins (SAML, with a second factor)

Corporate portals increasingly front their login with SAML - ADFS, Okta, Azure AD -
usually with a second factor. The VPN client never sees a password: the exchange
happens in a browser, and a short-lived session credential comes back.

Supported for `anyconnect`, `gp` and `fortissl`. OpenVPN has no equivalent in the
community client, so `--auth-mode sso` is refused for it at creation.

> **Renamed.** This replaced two commands `--protocol gp` containers used to
> carry, `connect-vpn-saml` and `connect-vpn-saml-finish`. They are removed by
> `--refresh-helpers`, and `vpn connect --sso` covers the same flow through the
> checked path - those two were never parse-checked and had been failing at runtime
> with a message blaming an expired cookie.

### Which path a connect takes

```bash
lxc exec -t vpn-example-gp -- vpn connect --sso      # browser login
lxc exec -t vpn-example-gp -- vpn connect --native   # the client's own prompts
lxc exec -t vpn-example-gp -- vpn connect            # whatever VPN_AUTH_MODE says
```

`--auth-mode native|sso` at creation sets the default; either is selectable per
connect regardless, and the flags never write to `/etc/vpn-client.env`. Absent
in containers created before this existed, where it reads as `native`.

### By hand, inside the container

`vpn connect --sso` prints where to log in and then prompts for what the browser
produced:

```
Open this in a browser on your own machine, NOT in this container:

  https://sts.example.com/adfs/ls/?SAMLRequest=...

Paste the values from the browser:
  SAML username from the browser: alice@example.com
  Session cookie (...):
  Usergroup path [gateway:prelogin-cookie]:
  Server that authenticated the exchange [vpn.example.com]:
```

The credential goes to the client on its standard input, never as an argument, so
it does not appear in the container's process table. It needs a terminal, hence
`lxc exec -t`.

Reading the credential out of the browser's developer tools is the slow part, and
these cookies live for seconds rather than minutes. That race is why the next
section exists.

### With the host-side helper

```bash
./scripts/vpn-sso-login.sh vpn-example-gp
```

For GlobalProtect it drives [`gp-saml-gui`](https://github.com/dlenski/gp-saml-gui)
(`sudo apt install gp-saml-gui`), which embeds a browser, carries out the exchange
and reads the credential out of the response headers - no developer tools and no
race. It then hands the values to the container over standard input.

Four values come out of that exchange and all four are carried: the SAML username,
the credential, **which kind** of credential it is (a portal can return either a
prelogin cookie or a portal user-auth cookie, and that selects the usergroup path),
and the server the exchange **actually** authenticated against, which may differ
from the one first contacted when the portal redirects. Assuming either of the last
two is why the helpers this replaced could not connect some portals at all.

The helper is optional in both directions. A container works with no helper present
- the section above is the whole flow - and the helper falls back to exactly that
when the extraction tool is not installed, saying why. It refuses a stopped
container rather than starting it, since that would be a change to your environment
you did not ask for.

**It never runs a VPN client.** Isolating the VPN from the host is the point of this
project, so the helper does not use `gp-saml-gui`'s options that would exec
`openconnect` on your machine. It also passes the option that stops the tool storing
an identity-provider session on disk, since this project does not keep credentials.

**A second factor that needs a hardware security key will not work through the
helper**, because the embedded browser does not support WebAuthn. Phone push and
one-time codes are ordinary web content and do. For a security key, use the manual
flow above with your real browser.

## Troubleshooting

| Symptom | Check |
|---|---|
| cannot create tun | `lxc config set vpn-X security.privileged true` + restart |
| Cisco/ASA auth 404 on `/` | rebuild openconnect (`--build-openconnect`) |
| MFA/token login failed before token prompt | account lockout - wait / ask the VPN provider's IT |
| GlobalProtect stuck on portal | confirm portal vs gateway URL; try `-v` |
| GlobalProtect: `XML response has no "auth" node` | Portal is SAML-fronted (ADFS/Okta/Azure AD, often with a second factor) - a plain connect cannot finish that login. Use `vpn connect --sso`, or `scripts/vpn-sso-login.sh <container>` from your own machine - see "SSO logins" above |
| SSO: `the login did not complete - no credential was supplied` | The browser step was abandoned, or a required value was left empty. Nothing was sent to the gateway; this is **not** an expired credential |
| SSO: `the gateway refused the credential, or it had already expired` | The credential reached the gateway and was rejected. These live for seconds - repeat the browser step without pausing, or use the host-side helper, which removes the delay |
| SSO: `could not get a login URL` | The gateway was not reachable or did not offer SSO. No credential has been sent - distinct from either row above |
| OpenVPN connects but no internal access | subnet missing from `VPN_ROUTES`; or the server pushes a different topology. Containers created before `VPN_TUNNEL_MODE` existed may also carry `VPN_ROUTE_NOPULL=1`, which discards the server's routes and makes `auto` find nothing - give those an explicit `--routes`, or remove that key |
| SSH timeout to internal host | `lxc exec vpn-X -- vpn status` - it names the state, the routes installed against those expected, and where the default route is |
| host DNS/routes broken | VPN was started on the host - stop it and delete leftover `vpn0` |
| fortissl: "requires interactive password entry" | missing `-t`: use `lxc exec -t vpn-X -- vpn connect` |
| fortissl: PPP interface never appears | wrong password, or 2FA gateway without `VPN_FORTI_OTP_REQUIRED` set - check `sudo tail /var/log/openfortivpn.log` |
| `vpn connect` stops at a sudo password prompt | non-root `--user` and a path is missing from the plugin's `proto_sudo_commands`; fix, then `--refresh-helpers` |
| `vpn disconnect` says "VPN down." but traffic still flows | `vpn status` reporting `stale` confirms it - the client is gone but the interface and its routes remain. A process name missing from the plugin's `proto_client_processes` is the usual cause; fix, then `--refresh-helpers` |
| a fix from a newer version of this repo has no effect | the container still has the helpers it was created with - `--refresh-helpers` |
| fortissl: "Couldn't set tty to PPP discipline" on connect | Check `grep ppp /proc/tty/ldiscs` **on the host**. Empty: `sudo modprobe ppp_async` and persist it, see prerequisites - a container restart cannot fix this. Present: `lxc restart vpn-X` clears a stuck `/dev/ppp`, and if the container predates the disconnect fix, also `--refresh-helpers` |
| fortissl: tunnel is up but `VPN_ROUTES` are not applied and nothing is in `/run/vpn-client/state` | The PPP wait loop used to abort the whole connect on its first iteration - `grep` exits 1 while no `ppp*` interface exists yet, and under `set -euo pipefail` that killed the script. The client survived because it runs under detached `screen`, so the tunnel came up unrouted and unrecorded. Fixed; run `--refresh-helpers` on containers created before it |

## Files

- Guide: `docs/lxd-vpn-client-containers.md`
- Script: `scripts/create-vpn-lxd-container.sh`
