# supabase-lxc

A Proxmox VE helper script that deploys self-hosted Supabase into a Debian LXC.

## Install

Run on the **Proxmox host** (as root), not inside a guest:

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jimmyj1979/supabase-lxc/main/supabase_lxc.sh)"
```

The script prompts for CTID, hostname, cores, RAM, disk, bridge and storage,
downloads a Debian 12/13 standard template, creates an unprivileged container
with `nesting=1,keyctl=1`, installs Docker, then runs upstream's
`supabase.link/setup.sh` into `/opt/supabase-project`.

Because it uses upstream's stock `docker/` directory, `update.sh`, `run.sh` and
the overlay system behave exactly as Supabase documents them.

## Update an existing deployment

```sh
bash supabase_lxc.sh update <CTID>
```

Takes a `preupdate-<timestamp>` snapshot first, then runs upstream `update.sh`
and restarts the stack. Roll back with `pct rollback <CTID> <snapshot>`.

## Managing the stack

A `supabase` wrapper is installed in the container:

```sh
pct exec <CTID> -- supabase secrets      # credentials
pct exec <CTID> -- supabase logs [svc]
pct exec <CTID> -- supabase restart [svc]
```

## Post-install configuration

`supabase_configure.sh` configures the things the installer deliberately leaves
alone. **It runs inside the container**, not on the Proxmox host.

The installer offers to fetch and run it for you at the end of a deployment —
that is the easiest path. To run it later, or again:

```sh
pct enter <CTID>
curl -fsSL https://raw.githubusercontent.com/jimmyj1979/supabase-lxc/main/supabase_configure.sh -o supabase_configure.sh
bash supabase_configure.sh
```

It is safe to re-run as often as you like. Because it runs in the container and
finds the project directory itself, it also works on any Supabase docker
deployment, Proxmox or not.

Every section is optional and is skipped with a plain `n`:

| Section | What it sets |
|---|---|
| **Resend** | SMTP host/user/key, `From` address, email confirmation required, and four branded HTML templates — created, mounted and registered |
| **Twilio** | SMS OTP on signup (Verify or Programmable Messaging) and TOTP 2FA |
| **Storage** | Upload size limit, image transformation |
| **Edge Functions** | `FUNCTIONS_VERIFY_JWT`, and scaffolds a new function |

It backs `.env` up first, changes nothing until you confirm at the end, and
recreates only the services that are actually affected. It finds the project
directory itself, so it also handles installs that live in
`/root/supabase-project` rather than `/opt/supabase-project`.

Three things it handles that are easy to get wrong by hand:

- **`FILE_SIZE_LIMIT` and `ENABLE_IMAGE_TRANSFORMATION` are hardcoded in
  upstream's `docker-compose.yml`, not read from `.env`.** Setting them in
  `.env` does nothing at all. They go in `docker-compose.override.yml` instead.
- **Upstream sets `COMPOSE_FILE=docker-compose.yml`, which disables Compose's
  automatic inclusion of `docker-compose.override.yml`** — so an override file
  is written and then silently ignored. The script appends the override to
  `COMPOSE_FILE` when needed.
- **GoTrue reads different variables for `twilio` and `twilio_verify`.**
  Choosing one provider while setting the other's credentials leaves it with
  none, and nothing complains until an SMS actually fails to send.

It also refuses to leave `ENABLE_PHONE_AUTOCONFIRM=true` alongside Twilio:
autoconfirm marks a phone verified without ever sending a code, which makes the
whole OTP flow decorative.

## Addressing — the container's IP is baked into `.env`

**Use a static address unless you have a reason not to.** The installer asks for
either a static CIDR address or `dhcp`; static is the safer answer, and the
prompt says so. Whichever you choose, the address the container ends up with is
written into three variables in `.env` and **is never re-checked afterwards**:

```
SUPABASE_PUBLIC_URL=http://<IP>:8000
API_EXTERNAL_URL=http://<IP>:8000/auth/v1
SITE_URL=http://<IP>:3000
```

That is unavoidable — Studio, the API gateway and the auth redirect flow all
need an absolute URL, and there is no name to use unless you put one there
yourself.

The consequence: **if the address changes, the stack keeps running but Studio
and auth break**, and the failure gives no hint as to why. Services stay
healthy, the ports stay open, and requests are simply redirected to an address
that is no longer the container.

So if you pick DHCP, either reserve the lease on your DHCP server or treat the
deployment as temporary. The installer prints the allocated address and MAC at
the end specifically so you can go and reserve it.

### Moving an existing deployment to a new address

Changing the container's NIC alone is not enough — the three `.env` values must
change with it, or Studio and auth will point at the old address:

```sh
pct set <CTID> --net0 name=eth0,bridge=vmbr0,ip=192.168.1.50/24,gw=192.168.1.1

pct exec <CTID> -- sh -c '
  cd /opt/supabase-project
  sed -i "s|^SUPABASE_PUBLIC_URL=.*|SUPABASE_PUBLIC_URL=http://192.168.1.50:8000|" .env
  sed -i "s|^API_EXTERNAL_URL=.*|API_EXTERNAL_URL=http://192.168.1.50:8000/auth/v1|" .env
  sed -i "s|^SITE_URL=.*|SITE_URL=http://192.168.1.50:3000|" .env
'

pct exec <CTID> -- supabase start
```

Use `supabase start` (which is `docker compose up -d --wait`) rather than
rebooting the container. Compose bakes environment variables into a container
when it is created, so a reboot brings the services back with the **old**
address still in place; `up -d` recreates the ones whose configuration changed.

The same applies if you later put the stack behind a domain or a tunnel: point
these three at the public URL rather than the container's LAN address.

## DNS: service names on your LAN

Proxmox ships `search local` in `/etc/resolv.conf`. An LXC inherits it, Docker
copies it into every container, and any lookup that fails inside the Docker
network is retried with the search domain appended and forwarded to the LAN
resolver. On a stock deploy that means queries like these hitting your router:

```
AAAA? auth.local.      AAAA? rest.local.       AAAA? storage.local.
AAAA? meta.local.      AAAA? functions.local.  AAAA? studio.local.
```

They are almost all `AAAA`: the `A` records resolve internally, the IPv6 ones
find nothing and fall through. Nothing leaves the machine but the names — no
payload, no connection — but it does advertise the service layout to anything
watching DNS, and `.local` is reserved for mDNS (RFC 6762), so the queries are
malformed as well as noisy.

The installer fixes this in two parts, both before the Docker daemon first
starts:

1. `"dns-search": ["."]` in `/etc/docker/daemon.json` removes the inherited
   search domain, so nothing is retried as `<service>.local`.
2. **dnsmasq**, bound to the `docker0` bridge only and configured with
   `domain-needed`, which *"never forwards A or AAAA queries for plain names,
   without dots or domain parts, to upstream nameservers"*. Containers are
   pointed at it with `"dns": ["172.17.0.1"]`.

The second part matters: removing the search domain alone still left bare
`auth`, `db` and `functions` queries going upstream, because Docker's embedded
resolver forwards anything it cannot answer. dnsmasq answers those NXDOMAIN
locally and forwards only real hostnames.

Measured on one container, identical force-recreate startups:

| | Stock | Search domain removed | Both |
|---|---|---|---|
| `.local` queries | 43 | 0 | **0** |
| Bare service-name queries | 78 | 12 | **0** |
| Total DNS packets to the LAN | 356 | 24 | **0** |
| Stack healthy | 11/11 | 11/11 | **11/11** |

Service-to-service resolution, external resolution and outbound HTTPS all
continue to work — verified by resolving every service name from inside the
Docker network, and by fetching over TLS from a container. The installer
asserts the resolver is answering before it finishes, because a broken dnsmasq
would leave containers with no DNS at all.

dnsmasq listens on `172.17.0.1` only, so it is not reachable from the LAN.

Worth knowing the stack also resolves **`jsr.io`** repeatedly — that is the
edge-functions Deno runtime fetching its dependencies, not part of this script.

## Security

**This script sets `lxc.apparmor.profile: unconfined` on every container it
creates.** Read this before running it on a host you care about.

Docker will not start a single container inside an unprivileged LXC without it.
runc 1.3.6 and newer set `net.ipv4.ip_unprivileged_port_start` during container
init and reopen the sysctl through `/proc/self/fd/N`; the LXC AppArmor profile
denies that reopen, so every `docker run` fails with:

```
error during container init: open sysctl net.ipv4.ip_unprivileged_port_start
file: reopen fd 8: permission denied
```

Containers built on runc 1.3.0 or older never hit this, which is why an older
Docker install on the same host can work while a fresh one does not.

What you are giving up, and what you are not:

- **Kept:** the container stays *unprivileged*. The user namespace — the boundary
  that actually contains a container escape — is untouched. Container root is
  not host root.
- **Given up:** AppArmor's confinement, which is defence-in-depth layered on top
  of that boundary.

This is the better half of the trade. The common alternative advice — run the
LXC privileged — removes the user namespace instead, which is considerably
worse. If you would rather keep AppArmor, pin runc to 1.3.0 or older in the
container and delete the `lxc.apparmor.profile` line from the script; the stack
runs fine that way, it just freezes you on an ageing runtime.

Also worth knowing:

- The install prints every generated secret to stdout once. If you redirect the
  output to a log, that log holds the credentials in plaintext — delete it
  afterwards.
- `supabase secrets` prints the full credential set. Avoid it on a shared
  terminal or in a screen share.

## Notes

- **Storage:** Docker's `overlay2` driver does not work on a ZFS-backed rootfs
  inside LXC and falls back to `vfs` — slow and disk-hungry. Prefer LVM-thin or
  a directory storage. The script warns and asks before continuing on ZFS.
- **Sizing:** defaults are 4 cores / 8 GB RAM / 60 GB disk. Upstream's minimum
  is 4 GB RAM and 40 GB disk; the Logs & Analytics overlay (Logflare + Vector)
  adds another 1–2 GB of RAM.
- **Disk, measured:** a fresh install occupies **9.7 GB** — 6.6 GB of Docker
  image layers, ~900 MB of Debian plus the Docker engine, and ~50 MB of project
  files. It will not install under roughly 11 GB. Two long-running instances
  measured on the same host had reached 26–27 GB, the growth being Postgres
  data and container logs rather than anything in the install, so 40 GB is a
  sensible floor and the 60 GB default leaves real headroom.
- **Container logs are capped** at 10 MB × 3 files per service via
  `/etc/docker/daemon.json`. Docker's `json-file` default is unbounded, and an
  11-service stack left alone will fill a disk with logs eventually.
- **Exposure:** the stack is plain HTTP and Studio sits behind basic auth only.
  Put it behind a Cloudflare tunnel or add the Caddy overlay before exposing it.
