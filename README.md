# supabase-lxc

A Proxmox VE helper script that deploys self-hosted Supabase into a Debian LXC.

## Install

Run on the **Proxmox host** (as root), not inside a guest:

```sh
bash -c "$(curl -fsSL http://192.168.0.94:3000/jimmyj1979/supabase-lxc/raw/branch/main/supabase_lxc.sh)"
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

## Notes

- **Storage:** Docker's `overlay2` driver does not work on a ZFS-backed rootfs
  inside LXC and falls back to `vfs` — slow and disk-hungry. Prefer LVM-thin or
  a directory storage. The script warns and asks before continuing on ZFS.
- **Sizing:** defaults are 4 cores / 8 GB RAM / 60 GB disk. Upstream's minimum
  is 4 GB RAM and 40 GB disk; the Logs & Analytics overlay (Logflare + Vector)
  adds another 1–2 GB of RAM.
- **Exposure:** the stack is plain HTTP and Studio sits behind basic auth only.
  Put it behind a Cloudflare tunnel or add the Caddy overlay before exposing it.
