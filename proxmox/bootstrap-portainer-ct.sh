#!/usr/bin/env bash
# Bootstrap Portainer CE inside a Proxmox LXC CT.
#
# Pulls portainer/portainer-ce:latest from Docker Hub and starts it.
# Portainer data is persisted in a named Docker volume.
#
# Usage:
#   ./proxmox/bootstrap-portainer-ct.sh [CTID] [IP_ADDR]
#
# Arguments (required):
#   CTID     Container ID to bootstrap (e.g. 114)
#   IP_ADDR  CT IP address for display (e.g. 10.0.0.114)
#
# Reads from ~/.ops.env or $OPS_ENV:
#   PVE_HOST  SSH target for the Proxmox host (e.g. root@10.0.0.1)
#
# Portainer UI will be available at:
#   https://<IP_ADDR>:9443  (HTTPS — self-signed cert on first boot)

set -euo pipefail

OPS_ENV="${OPS_ENV:-${HOME}/.ops.env}"
[[ -f "${OPS_ENV}" ]] && set -a && source "${OPS_ENV}" && set +a

PVE_HOST="${PVE_HOST:-}"
CTID="${1:-}"
IP_ADDR="${2:-}"

if [[ -z "${CTID}" || -z "${IP_ADDR}" ]]; then
  echo "Usage: $(basename "$0") CTID IP_ADDR" >&2
  echo "  e.g. $(basename "$0") 114 10.0.0.114" >&2
  exit 1
fi

if [[ -z "${PVE_HOST}" ]]; then
  echo "ERROR: PVE_HOST is not set. Add it to ${OPS_ENV}" >&2
  exit 1
fi

log() { printf '[bootstrap-portainer-ct] %s\n' "$*" >&2; }
pve() { ssh -o BatchMode=yes "${PVE_HOST}" "$@"; }

log "Pulling Portainer CE image..."
pve "pct exec ${CTID} -- /usr/bin/docker pull portainer/portainer-ce:latest"

log "Starting Portainer CE..."
pve "pct exec ${CTID} -- /usr/bin/docker run -d \
  --name portainer \
  --restart=always \
  -p 9443:9443 \
  -p 9000:9000 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  portainer/portainer-ce:latest" 2>/dev/null \
  || pve "pct exec ${CTID} -- /usr/bin/docker start portainer"

log "Waiting for Portainer to become ready..."
for i in {1..30}; do
  STATUS=$(pve "pct exec ${CTID} -- /usr/bin/docker inspect -f '{{.State.Running}}' portainer" 2>/dev/null || true)
  if [[ "${STATUS}" == "true" ]]; then
    break
  fi
  sleep 2
done

log ""
log "Portainer CE is running."
log "  CT       : ${CTID}"
log "  HTTPS UI : https://${IP_ADDR}:9443  (self-signed cert — accept browser warning)"
log "  HTTP UI  : http://${IP_ADDR}:9000"
log ""
log "On first visit you will be prompted to create an admin user."
log "You have 5 minutes before Portainer locks the initial setup."
