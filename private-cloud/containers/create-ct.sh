#!/usr/bin/env bash
# Provision a generic service LXC CT on the Proxmox host.
#
# Creates an unprivileged Debian 13 CT, installs Docker, and registers a
# repo-level GitHub Actions self-hosted runner with the service name as its
# label. The runner becomes the deployment mechanism — no further operator
# involvement is needed after first-time secret seeding.
#
# Usage:
#   ./private-cloud/containers/create-ct.sh <service-name> <ctid> <ip-cidr>
#
# Example:
#   ./private-cloud/containers/create-ct.sh authentication 121 10.0.0.121/10
#   ./private-cloud/containers/create-ct.sh my-new-service 130 10.0.0.130/10
#
# Reads from ~/.ops.env or $OPS_ENV:
#   PVE_HOST          SSH target for the Proxmox host (e.g. root@10.0.0.1)
#   GHA_RUNNER_TOKEN  Repo-level runner registration token (expires after 1 h)
#                     Generate at: GitHub → <owner>/<repo> → Settings → Actions → Runners → New runner
#   GHA_REPO          GitHub repo in owner/repo format (e.g. Neosofia/cdp)
#   GHCR_USER         GitHub username (optional — only for private GHCR packages)
#   GHCR_TOKEN        PAT with read:packages (optional — only for private GHCR packages)
#   LOCALSTACK_URL    URL of the secrets service (default: http://10.0.0.190:4566)
#
# Idempotent: safe to re-run; exits cleanly if the CT already exists.

set -euo pipefail

OPS_ENV="${OPS_ENV:-${HOME}/.ops.env}"
[[ -f "${OPS_ENV}" ]] && set -a && source "${OPS_ENV}" && set +a

SERVICE_NAME="${1:-}"
CTID="${2:-}"
IP_ADDR="${3:-}"     # CIDR notation, e.g. 10.0.0.121/10

if [[ -z "${SERVICE_NAME}" || -z "${CTID}" || -z "${IP_ADDR}" ]]; then
  echo "Usage: $(basename "$0") <service-name> <ctid> <ip-cidr>" >&2
  echo "  e.g. $(basename "$0") authentication 121 10.0.0.121/10" >&2
  exit 1
fi

PVE_HOST="${PVE_HOST:-}"
GHA_RUNNER_TOKEN="${GHA_RUNNER_TOKEN:-}"
GHA_REPO="${GHA_REPO:-}"
GHCR_USER="${GHCR_USER:-}"
GHCR_TOKEN="${GHCR_TOKEN:-}"
LOCALSTACK_URL="${LOCALSTACK_URL:-http://10.0.0.190:4566}"

if [[ -z "${PVE_HOST}" ]]; then
  echo "ERROR: PVE_HOST is not set. Add it to ${OPS_ENV}" >&2
  exit 1
fi
if [[ -z "${GHA_RUNNER_TOKEN}" ]]; then
  echo "ERROR: GHA_RUNNER_TOKEN is not set." >&2
  echo "  Generate one at: https://github.com/${GHA_REPO}/settings/actions/runners/new" >&2
  echo "  Then add it to ${OPS_ENV} or export it." >&2
  exit 1
fi
if [[ -z "${GHA_REPO}" ]]; then
  echo "ERROR: GHA_REPO is not set (expected owner/repo format, e.g. Neosofia/cdp)." >&2
  echo "  Add it to ${OPS_ENV} or export it." >&2
  exit 1
fi

HOSTNAME="${SERVICE_NAME}-dev"
BRIDGE="local"
GATEWAY="10.0.0.1"
STORAGE="local-lvm"
ROOTFS_SIZE="20"    # GiB
CORES="2"
MEMORY="4096"       # MiB
SWAP="512"
RUNNER_VERSION="2.334.0"

log() { printf '[create-ct:%s] %s\n' "${SERVICE_NAME}" "$*" >&2; }
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
# Create CT (unprivileged, nesting + keyctl for Docker)
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
  apt-get install -y -qq ca-certificates curl gnupg openssl git sudo
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \$(. /etc/os-release; echo \$VERSION_CODENAME) stable\" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  # boto3 is required by /opt/neosofia/scripts/seed-localstack.py (called from deploy.sh)
  apt-get install -y -qq python3-boto3
'"

log "Docker installed. Version: $(pve "pct exec ${CTID} -- docker version --format '{{.Server.Version}}'")"

# ---------------------------------------------------------------------------
# Install shared infrastructure scripts (seed-localstack, etc.)
# ---------------------------------------------------------------------------
log "Installing infrastructure scripts into CT ${CTID}..."

pve "pct exec ${CTID} -- bash -c '
  set -e
  mkdir -p /opt/neosofia/scripts
  chmod 0755 /opt/neosofia/scripts
'"

# Copy scripts from the infrastructure repo into the CT.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for script in seed-localstack.py resolve-image-tag.py deploy.sh; do
  pve "cat > /tmp/${script}" < "${SCRIPT_DIR}/${script}"
  pve "pct push ${CTID} /tmp/${script} /opt/neosofia/scripts/${script} --perms 0755"
  pve "rm /tmp/${script}"
done

log "Infrastructure scripts installed at /opt/neosofia/scripts/"

# ---------------------------------------------------------------------------
# Create gha-runner user (non-root; member of docker group)
# ---------------------------------------------------------------------------
log "Creating gha-runner user..."

pve "pct exec ${CTID} -- bash -c '
  set -e
  id gha-runner &>/dev/null || useradd -m -s /bin/bash gha-runner
  usermod -aG docker gha-runner
  mkdir -p /opt/actions-runner
  chown gha-runner:gha-runner /opt/actions-runner
  echo "gha-runner ALL=(root) NOPASSWD: /usr/bin/find" > /etc/sudoers.d/gha-runner
  chmod 440 /etc/sudoers.d/gha-runner
'"

# ---------------------------------------------------------------------------
# Download runner and register against org runner pool
# ---------------------------------------------------------------------------
log "Downloading GHA runner v${RUNNER_VERSION}..."

pve "pct exec ${CTID} -- su - gha-runner -c \"
  set -e
  cd /opt/actions-runner
  if [[ ! -f ./config.sh ]]; then
    curl -fsSL https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz | tar xz
  fi
\""

log "Registering runner with repo: ${GHA_REPO}, label: ${SERVICE_NAME}..."

pve "pct exec ${CTID} -- su - gha-runner -c \"
  set -e
  cd /opt/actions-runner
  ./config.sh \\
    --url https://github.com/${GHA_REPO} \\
    --token ${GHA_RUNNER_TOKEN} \
    --name ${SERVICE_NAME}-dev-ct${CTID} \
    --labels self-hosted,${SERVICE_NAME} \
    --work /opt/actions-runner/_work \
    --unattended \
    --replace
\""

# Install runner as a systemd service (must run as root, service runs as gha-runner)
pve "pct exec ${CTID} -- bash -c '
  cd /opt/actions-runner
  ./svc.sh install gha-runner
  ./svc.sh start
'"

log "Runner registered and running as a systemd service."

# ---------------------------------------------------------------------------
# Create the service secrets directory owned by gha-runner
# deploy.sh writes /etc/<service>/env on every deploy (checked out from LocalStack)
# ---------------------------------------------------------------------------
pve "pct exec ${CTID} -- bash -c '
  mkdir -p /etc/${SERVICE_NAME}
  chown gha-runner:gha-runner /etc/${SERVICE_NAME}
  chmod 750 /etc/${SERVICE_NAME}
'"
log "Created /etc/${SERVICE_NAME} (owned by gha-runner)."

# ---------------------------------------------------------------------------
# GHCR login (optional — only if packages are private)
# ---------------------------------------------------------------------------
if [[ -n "${GHCR_TOKEN}" && -n "${GHCR_USER}" ]]; then
  log "Logging gha-runner in to GHCR..."
  pve "pct exec ${CTID} -- bash -c \"echo '${GHCR_TOKEN}' | su - gha-runner -c 'docker login ghcr.io -u ${GHCR_USER} --password-stdin'\""
fi

# ---------------------------------------------------------------------------
# Summary + operator instructions
# ---------------------------------------------------------------------------
log ""
log "═══════════════════════════════════════════════════════════════"
log " CT ${CTID} (${SERVICE_NAME}-dev) is provisioned and running."
log ""
log "  Runner label : ${SERVICE_NAME}"
log "  Runner URL   : https://github.com/${GHA_REPO}"
log "  CT IP        : ${IP_ADDR%/*}"
log "═══════════════════════════════════════════════════════════════"
log ""
log " ⚠  ACTION REQUIRED BEFORE FIRST DEPLOY ⚠"
log ""
log " The GHA runner is live and listening NOW. Seed secrets into LocalStack"
log " before triggering a deploy — deploy.sh checks them out on every deploy."
log ""
log " From your operator machine:"
log ""
log "   cd infrastructure"
log "   bash private-cloud/containers/seed-ct-env.sh ${SERVICE_NAME} /path/to/${SERVICE_NAME}/.env"
log ""
log " Then trigger a deploy by pushing a tag from the service repo:"
log "   git tag <service>/<YYYY.MM.DD> && git push origin <tag>"
log ""
log " To teardown this CT:"
log "   ssh ${PVE_HOST} \"pct stop ${CTID} && pct destroy ${CTID}\""
log "═══════════════════════════════════════════════════════════════"
