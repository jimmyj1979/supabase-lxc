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
- **Exposure:** the stack is plain HTTP and Studio sits behind basic auth only.
  Put it behind a Cloudflare tunnel or add the Caddy overlay before exposing it.
