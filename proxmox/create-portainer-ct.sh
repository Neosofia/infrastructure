#!/usr/bin/env bash
# Provision a Portainer LXC CT on the Proxmox host.
#
# Run this from the operator terminal — it SSHes into the Proxmox host and
# issues pct commands there. Idempotent: exits cleanly if the CT already exists.
#
# Usage:
#   ./proxmox/create-portainer-ct.sh [CTID] [IP_ADDR]
#
# Arguments (required):
#   CTID     Container ID (e.g. 114)
#   IP_ADDR  CT IP in CIDR notation (e.g. 10.0.0.114/10)
#
# Reads from ~/.ops.env or $OPS_ENV:
#   PVE_HOST  SSH target for the Proxmox host (e.g. root@10.0.0.1)

set -euo pipefail

OPS_ENV="${OPS_ENV:-${HOME}/.ops.env}"
[[ -f "${OPS_ENV}" ]] && set -a && source "${OPS_ENV}" && set +a

PVE_HOST="${PVE_HOST:-}"

if [[ -z "${PVE_HOST}" ]]; then
  echo "ERROR: PVE_HOST is not set. Add it to ${OPS_ENV}" >&2
  exit 1
fi

CTID="${1:-}"
IP_ADDR="${2:-}"

if [[ -z "${CTID}" || -z "${IP_ADDR}" ]]; then
  echo "Usage: $(basename "$0") CTID IP_ADDR" >&2
  echo "  e.g. $(basename "$0") 114 10.0.0.114/10" >&2
  exit 1
fi

HOSTNAME="portainer"
BRIDGE="local"
GATEWAY="10.0.0.1"
STORAGE="local-lvm"
ROOTFS_SIZE="10"   # GiB — Portainer needs very little disk
CORES="1"
MEMORY="512"       # MiB
SWAP="256"

log() { printf '[create-portainer-ct] %s\n' "$*" >&2; }
pve() { ssh -o BatchMode=yes "${PVE_HOST}" "$@"; }

# ---------------------------------------------------------------------------
# Idempotency check
# ---------------------------------------------------------------------------
if pve "pct status ${CTID}" >/dev/null 2>&1; then
  log "CT ${CTID} already exists. Current status:"
  pve "pct status ${CTID}"
  log "Skipping creation. To recreate, destroy it first:"
  log "  ssh ${PVE_HOST} \"pct stop ${CTID} && pct destroy ${CTID}\""
  exit 0
fi

# ---------------------------------------------------------------------------
# Pick a Debian 13 template (download if missing)
# ---------------------------------------------------------------------------
log "Locating Debian 13 LXC template..."
TEMPLATE=$(pve "pveam list local | awk '/debian-13-standard.*\.zst$/ {print \$1}' | sort | tail -1" || true)

if [[ -z "${TEMPLATE}" ]]; then
  log "No Debian 13 template cached locally. Downloading..."
  pve "pveam update >/dev/null"
  TEMPLATE_NAME=$(pve "pveam available | awk '/debian-13-standard.*amd64/ {print \$2}' | sort | tail -1")
  pve "pveam download local '${TEMPLATE_NAME}'"
  TEMPLATE="local:vztmpl/${TEMPLATE_NAME}"
fi

log "Using template: ${TEMPLATE}"

# ---------------------------------------------------------------------------
# Create the CT (unprivileged, nesting + keyctl for Docker)
# ---------------------------------------------------------------------------
log "Creating CT ${CTID} (${HOSTNAME}) on ${PVE_HOST}..."

pve "pct create ${CTID} '${TEMPLATE}' \
    --hostname ${HOSTNAME} \
    --cores ${CORES} \
    --memory ${MEMORY} \
    --swap ${SWAP} \
    --rootfs ${STORAGE}:${ROOTFS_SIZE} \
    --net0 name=eth0,bridge=${BRIDGE},ip=${IP_ADDR},gw=${GATEWAY} \
    --unprivileged 1 \
    --features nesting=1,keyctl=1 \
    --onboot 1 \
    --start 0"

log "CT ${CTID} created. Starting..."
pve "pct start ${CTID}"

# Wait for network
log "Waiting for CT network to come up..."
for _ in {1..30}; do
  if pve "pct exec ${CTID} -- getent hosts deb.debian.org >/dev/null 2>&1"; then
    break
  fi
  sleep 1
done

# ---------------------------------------------------------------------------
# Install Docker inside the CT
# ---------------------------------------------------------------------------
log "Installing Docker inside CT ${CTID}..."

pve "pct exec ${CTID} -- bash -c '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \$(. /etc/os-release; echo \$VERSION_CODENAME) stable\" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable --now docker
'"

log "Docker installed. Verifying..."
pve "pct exec ${CTID} -- docker version --format '{{.Server.Version}}'"

log ""
log "CT ${CTID} is ready."
log "  Hostname : ${HOSTNAME}"
log "  IP       : ${IP_ADDR%/*}"
log ""
log "Next: run ./proxmox/bootstrap-portainer-ct.sh ${CTID} ${IP_ADDR%/*} to deploy Portainer."
