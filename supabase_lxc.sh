#!/usr/bin/env bash
#
# supabase_lxc.sh — deploy self-hosted Supabase into a Debian LXC on Proxmox VE
#
# Run on the Proxmox host (not inside a guest):
#   bash -c "$(curl -fsSL http://192.168.0.94:3000/jimmyj1979/supabase-lxc/raw/branch/main/supabase_lxc.sh)"
#
# Update an existing deployment (snapshots first):
#   bash supabase_lxc.sh update <CTID>
#
# The container runs upstream's stock docker/ directory, so update.sh, run.sh
# and the override system behave exactly as documented by Supabase.

set -euo pipefail

# ---------------------------------------------------------------- defaults ---
APP="Supabase"
SCRIPT_NAME="supabase_lxc.sh"   # $0 is just "bash" when run via bash -c "$(curl ...)"
DEFAULT_HOSTNAME="supabase"
DEFAULT_CORES=4
DEFAULT_RAM=8192          # MB — 4096 is the documented minimum
DEFAULT_DISK=60           # GB — 40 minimum, more if Storage holds real files
DEFAULT_SWAP=512
DEFAULT_BRIDGE="vmbr0"
DEFAULT_UNPRIVILEGED=1
DEFAULT_IP="dhcp"         # or a CIDR address, e.g. 192.168.0.210/24
PROJECT_DIR="/opt/supabase-project"

# ------------------------------------------------------------------ output ---
RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLU=$'\033[36m'; RST=$'\033[0m'
info()  { echo "${BLU}==>${RST} $*"; }
ok()    { echo "${GRN} ok${RST} $*"; }
warn()  { echo "${YLW}  !${RST} $*"; }
die()   { echo "${RED}  x${RST} $*" >&2; exit 1; }

# ------------------------------------------------------------- host checks ---
require_host() {
  command -v pveversion >/dev/null 2>&1 || die "This script must run on a Proxmox VE host."
  [ "$(id -u)" -eq 0 ] || die "Run as root."
}

# ------------------------------------------------------------- update mode ---
do_update() {
  local ctid="$1"
  require_host
  pct status "$ctid" >/dev/null 2>&1 || die "CT $ctid not found."

  local snap="preupdate-$(date +%Y%m%d-%H%M)"
  info "Snapshotting CT $ctid as $snap"
  if pct snapshot "$ctid" "$snap" --description "before supabase update.sh"; then
    ok "Snapshot taken. Roll back with: pct rollback $ctid $snap"
  else
    warn "Snapshot failed (storage may not support it). Continuing without one."
    read -rp "Proceed anyway? [y/N] " a; [[ "${a,,}" == "y" ]] || exit 1
  fi

  info "Running upstream update.sh inside the container"
  pct exec "$ctid" -- sh -c "cd $PROJECT_DIR && sh update.sh"
  pct exec "$ctid" -- sh -c "cd $PROJECT_DIR && sh run.sh start"
  ok "Update complete. Review the Supabase changelog for any manual migration steps."
  exit 0
}

[ "${1:-}" = "update" ] && { [ -n "${2:-}" ] || die "Usage: $SCRIPT_NAME update <CTID>"; do_update "$2"; }

require_host

# ---------------------------------------------------------------- settings ---
echo
echo "  ${BLU}${APP} LXC${RST} — Proxmox VE deployment"
echo

NEXTID=$(pvesh get /cluster/nextid)
read -rp "Container ID [$NEXTID]: " CTID; CTID=${CTID:-$NEXTID}
pct status "$CTID" >/dev/null 2>&1 && die "CT $CTID already exists."

read -rp "Hostname [$DEFAULT_HOSTNAME]: " HOSTNAME; HOSTNAME=${HOSTNAME:-$DEFAULT_HOSTNAME}
read -rp "Cores [$DEFAULT_CORES]: " CORES; CORES=${CORES:-$DEFAULT_CORES}
read -rp "RAM in MB [$DEFAULT_RAM]: " RAM; RAM=${RAM:-$DEFAULT_RAM}
read -rp "Disk in GB [$DEFAULT_DISK]: " DISK; DISK=${DISK:-$DEFAULT_DISK}
read -rp "Bridge [$DEFAULT_BRIDGE]: " BRIDGE; BRIDGE=${BRIDGE:-$DEFAULT_BRIDGE}

# A DHCP lease gets baked into SUPABASE_PUBLIC_URL/API_EXTERNAL_URL/SITE_URL
# below, so a later lease change silently breaks Studio and auth. Prefer static.
read -rp "IP as CIDR (e.g. 192.168.0.210/24) or 'dhcp' [$DEFAULT_IP]: " IPADDR
IPADDR=${IPADDR:-$DEFAULT_IP}
if [ "$IPADDR" = "dhcp" ]; then
  NET0="name=eth0,bridge=$BRIDGE,ip=dhcp"
  warn "Using DHCP — the lease address is written into .env and is not re-checked."
else
  case "$IPADDR" in
    */*) : ;;
    *) die "IP must include a prefix length, e.g. $IPADDR/24" ;;
  esac
  DEFAULT_GW=$(ip route show default | awk '{print $3}' | head -1)
  read -rp "Gateway [$DEFAULT_GW]: " GW; GW=${GW:-$DEFAULT_GW}
  [ -n "$GW" ] || die "No gateway given and none could be detected."
  NET0="name=eth0,bridge=$BRIDGE,ip=$IPADDR,gw=$GW"
fi

echo
info "Container storage options:"
pvesm status -content rootdir | awk 'NR>1 {printf "    %-16s %-10s %s free\n", $1, $2, $6}'
DEFAULT_STORAGE=$(pvesm status -content rootdir | awk 'NR==2 {print $1}')
read -rp "Storage for the container [$DEFAULT_STORAGE]: " STORAGE; STORAGE=${STORAGE:-$DEFAULT_STORAGE}

# Docker's overlay2 driver does not work on a ZFS-backed rootfs inside LXC; it
# falls back to vfs, which is slow and disk-hungry. Prefer LVM-thin or a dir.
STORAGE_TYPE=$(pvesm status | awk -v s="$STORAGE" '$1==s {print $2}')
if [ "$STORAGE_TYPE" = "zfspool" ]; then
  warn "$STORAGE is ZFS. Docker inside an LXC on ZFS falls back to the vfs storage"
  warn "driver — expect poor performance and heavy disk use."
  warn "Use LVM-thin or a directory storage for the rootfs if you can."
  read -rp "Continue with ZFS anyway? [y/N] " a; [[ "${a,,}" == "y" ]] || exit 1
fi

read -rp "Enable Logs & Analytics (Logflare + Vector, ~1-2 GB more RAM)? [y/N] " ENABLE_LOGS
read -rp "Unprivileged container? [Y/n] " a
UNPRIV=$DEFAULT_UNPRIVILEGED; [[ "${a,,}" == "n" ]] && UNPRIV=0

# ---------------------------------------------------------------- template ---
info "Checking for a Debian template"
pveam update >/dev/null 2>&1 || true

# pct create refuses a guest OS newer than the host's lxc-pve knows about:
# PVE 8 dies with "unsupported debian version '13.6'" on a trixie template.
# Debian 13 needs PVE 9, so cap the candidates by the host's major version.
PVE_VER=$(pveversion | cut -d/ -f2)   # e.g. 8.4.0
PVE_MAJOR=${PVE_VER%%.*}
if [ "${PVE_MAJOR:-8}" -ge 9 ]; then
  TEMPLATE_RE='^debian-1[23]-standard'
else
  TEMPLATE_RE='^debian-12-standard'
fi

TEMPLATE=$(pveam available --section system | awk '{print $2}' | grep -E "$TEMPLATE_RE" | sort -V | tail -1)
[ -n "$TEMPLATE" ] || die "No Debian standard template matching $TEMPLATE_RE available from pveam."

TPL_STORAGE=$(pvesm status -content vztmpl | awk 'NR==2 {print $1}')
if ! pveam list "$TPL_STORAGE" 2>/dev/null | grep -q "$TEMPLATE"; then
  info "Downloading $TEMPLATE to $TPL_STORAGE"
  pveam download "$TPL_STORAGE" "$TEMPLATE"
fi
ok "Template: $TEMPLATE"

# --------------------------------------------------------------- create ct ---
info "Creating CT $CTID"
pct create "$CTID" "$TPL_STORAGE:vztmpl/$TEMPLATE" \
  --hostname "$HOSTNAME" \
  --cores "$CORES" \
  --memory "$RAM" \
  --swap "$DEFAULT_SWAP" \
  --rootfs "$STORAGE:$DISK" \
  --net0 "$NET0" \
  --unprivileged "$UNPRIV" \
  --features nesting=1,keyctl=1 \
  --onboot 1 \
  --tags "supabase,database" \
  --description "Supabase self-hosted — $PROJECT_DIR — manage with: supabase start|stop|logs"

# runc >= 1.3.6 sets net.ipv4.ip_unprivileged_port_start during container init
# and reopens the sysctl via /proc/self/fd/N. The LXC AppArmor profile denies
# that reopen, so every `docker run` dies with:
#   error during container init: open sysctl net.ipv4.ip_unprivileged_port_start
#   file: reopen fd 8: permission denied
# Containers built on runc <= 1.3.0 never hit it. The unprivileged user
# namespace — the real isolation boundary — is unaffected; this only drops
# AppArmor's secondary confinement, which docker-in-LXC commonly requires.
info "Allowing Docker's runtime to init (AppArmor unconfined)"
echo "lxc.apparmor.profile: unconfined" >> "/etc/pve/lxc/$CTID.conf"

pct start "$CTID"
ok "CT $CTID started"

info "Waiting for network"
for i in $(seq 1 60); do
  pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 && break
  [ "$i" -eq 60 ] && die "Container has no network after 60s."
  sleep 1
done
IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
ok "Container IP: $IP"

# ----------------------------------------------------------- provisioning ----
info "Installing prerequisites"
pct exec "$CTID" -- bash -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl git openssl jq >/dev/null
'

info "Installing Docker Engine"
pct exec "$CTID" -- bash -c 'curl -fsSL https://get.docker.com | sh >/dev/null 2>&1'
pct exec "$CTID" -- systemctl enable --now docker >/dev/null 2>&1
pct exec "$CTID" -- docker --version

info "Running upstream Supabase setup.sh (this pulls ~4 GB of images)"
pct exec "$CTID" -- bash -c "
  mkdir -p /opt && cd /opt
  curl -fsSL https://supabase.link/setup.sh | sh -s -- -y
"
[ -n "$(pct exec "$CTID" -- ls -A "$PROJECT_DIR" 2>/dev/null)" ] || die "setup.sh did not produce $PROJECT_DIR"

# setup.sh -y writes localhost URLs; point them at the container instead.
info "Setting URLs to the container address"
pct exec "$CTID" -- bash -c "
  cd $PROJECT_DIR
  sed -i 's|^SUPABASE_PUBLIC_URL=.*|SUPABASE_PUBLIC_URL=http://$IP:8000|' .env
  sed -i 's|^API_EXTERNAL_URL=.*|API_EXTERNAL_URL=http://$IP:8000/auth/v1|' .env
  sed -i 's|^SITE_URL=.*|SITE_URL=http://$IP:3000|' .env
"

if [[ "${ENABLE_LOGS,,}" == "y" ]]; then
  info "Enabling the logs overlay"
  pct exec "$CTID" -- sh -c "cd $PROJECT_DIR && sh run.sh config add logs"
fi

# Convenience wrapper so you can type `supabase logs` instead of cd-ing about.
pct exec "$CTID" -- bash -c "cat > /usr/local/bin/supabase <<'EOF'
#!/bin/sh
cd $PROJECT_DIR || exit 1
exec sh run.sh \"\$@\"
EOF
chmod +x /usr/local/bin/supabase"

info "Starting the stack (waiting for all services to report healthy)"
pct exec "$CTID" -- sh -c "cd $PROJECT_DIR && sh run.sh start"

# ------------------------------------------------------------------ done -----
echo
ok "$APP is up in CT $CTID"
echo
if [ "$IPADDR" = "dhcp" ]; then
  MAC=$(pct config "$CTID" | tr ',' '\n' | sed -n 's/^hwaddr=//p')
  echo "  Address     $IP  ${YLW}(DHCP lease)${RST}  MAC $MAC"
  echo "              Reserve it on your DHCP server: the lease address is"
  echo "              written into .env and is never re-checked, so a new"
  echo "              lease silently breaks Studio and auth."
else
  echo "  Address     $IP  (static)"
fi
echo "  Studio      http://$IP:8000"
echo "  API base    http://$IP:8000"
echo "  Project     $PROJECT_DIR (inside the container)"
echo
echo "  Credentials:  pct exec $CTID -- supabase secrets"
echo "  Logs:         pct exec $CTID -- supabase logs [service]"
echo "  Restart:      pct exec $CTID -- supabase restart [service]"
echo "  Update:       bash $SCRIPT_NAME update $CTID"
echo
warn "Studio is behind HTTP basic auth and the stack is plain HTTP."
warn "Put it behind your Cloudflare tunnel or add the Caddy overlay before exposing it."
echo