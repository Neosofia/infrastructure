#!/usr/bin/env bash
# Provision a shared LocalStack CT on the Proxmox host.
#
# Creates an unprivileged Debian 13 CT, installs Docker, and starts LocalStack
# as a persistent Docker service on port 4566.  All service CTs point their
# AWS_ENDPOINT_URL at this CT's IP so LocalStack is provisioned and running
# before any service deploy is attempted.
#
# Usage:
#   ./proxmox/create-localstack-ct.sh [ctid] [ip-cidr]
#
# Defaults:
#   ctid    190
#   ip-cidr 10.0.0.190/10
#
# Reads from ~/.ops.env or $OPS_ENV:
#   PVE_HOST  SSH target for the Proxmox host (e.g. root@10.0.0.1)
#
# Idempotent: safe to re-run; exits cleanly if the CT already exists.

set -euo pipefail

OPS_ENV="${OPS_ENV:-${HOME}/.ops.env}"
[[ -f "${OPS_ENV}" ]] && set -a && source "${OPS_ENV}" && set +a

CTID="${1:-190}"
IP_ADDR="${2:-10.0.0.190/10}"

PVE_HOST="${PVE_HOST:-}"
if [[ -z "${PVE_HOST}" ]]; then
  echo "ERROR: PVE_HOST is not set. Add it to ${OPS_ENV}" >&2
  exit 1
fi

HOSTNAME="secrets-dev"
BRIDGE="local"
GATEWAY="10.0.0.1"
STORAGE="local-lvm"
ROOTFS_SIZE="10"    # GiB — LocalStack data only
CORES="2"
MEMORY="2048"       # MiB
SWAP="256"

LOCALSTACK_IMAGE="localstack/localstack:4"
LOCALSTACK_DATA="/var/lib/localstack"

log() { printf '[create-localstack-ct] %s\n' "$*" >&2; }
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
# Create CT (unprivileged, nesting for Docker)
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
# Install Docker
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

log "Docker installed."

# ---------------------------------------------------------------------------
# Install seed-localstack.py and python3-boto3
# ---------------------------------------------------------------------------
log "Installing seed-localstack.py into CT ${CTID}..."

pve "pct exec ${CTID} -- apt-get install -y -qq python3-boto3"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
pve "pct exec ${CTID} -- mkdir -p /opt/neosofia/scripts"
pve "pct push ${CTID} ${SCRIPT_DIR}/seed-localstack.py /opt/neosofia/scripts/seed-localstack.py --perms 0755"

log "seed-localstack.py installed."
# ---------------------------------------------------------------------------
log "Starting LocalStack container..."

pve "pct exec ${CTID} -- bash -c '
  set -e
  mkdir -p ${LOCALSTACK_DATA}
  docker run -d \
    --name localstack \
    --restart unless-stopped \
    -p 4566:4566 \
    -e SERVICES=secretsmanager \
    -e PERSISTENCE=1 \
    -v ${LOCALSTACK_DATA}:/var/lib/localstack \
    ${LOCALSTACK_IMAGE}
'"

# Wait for LocalStack to be ready
log "Waiting for LocalStack to become ready (up to 60s)..."
for i in $(seq 1 20); do
  if pve "pct exec ${CTID} -- curl -sf http://localhost:4566/_localstack/health" >/dev/null 2>&1; then
    log "LocalStack is ready."
    break
  fi
  if [[ "${i}" -eq 20 ]]; then
    log "ERROR: LocalStack did not become ready in time." >&2
    exit 1
  fi
  sleep 3
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log ""
log "═══════════════════════════════════════════════════════════════"
log " CT ${CTID} (${HOSTNAME}) is provisioned and running."
log ""
log "  LocalStack URL : http://${IP_ADDR%/*}:4566"
log "  Data volume    : ${LOCALSTACK_DATA} (bind-mounted, persistent)"
log "  CT IP          : ${IP_ADDR%/*}"
log "═══════════════════════════════════════════════════════════════"
log ""
log " Service CTs and deploy.sh use LOCALSTACK_URL=http://${IP_ADDR%/*}:4566"
log " by default.  Secrets are seeded by deploy.sh on every deploy."
log ""
log " To tear down this CT:"
log "   ssh ${PVE_HOST} \"pct stop ${CTID} && pct destroy ${CTID}\""
log "═══════════════════════════════════════════════════════════════"
