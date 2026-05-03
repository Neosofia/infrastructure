#!/usr/bin/env bash
# Seed a local .env file into LocalStack Secrets Manager on CT 190.
#
# This is the ONE place secrets enter the system.  After seeding, all
# service CTs check secrets out of LocalStack on every deploy via deploy.sh.
# No service CT stores a copy of the env file between deploys.
#
# Usage:
#   ./private-cloud/containers/seed-ct-env.sh <service-name> [env-file]
#
# Example:
#   ./private-cloud/containers/seed-ct-env.sh authentication
#   ./private-cloud/containers/seed-ct-env.sh authentication /path/to/custom.env
#
# Arguments:
#   service-name  Name of the service (e.g. authentication)
#   env-file      Path to the local .env file (default: .env in $PWD)
#
# Reads from ~/.ops.env or $OPS_ENV:
#   PVE_HOST              SSH target for the Proxmox host (e.g. root@10.0.0.1)
#   DEV_LOCALSTACK_CTID   CT ID of the shared LocalStack CT (default: 190)
#   GHA_REPO              GitHub repo in owner/repo format — repo name used as
#                         the secret namespace (e.g. byoung/platform → platform)
#   APP_NAMESPACE         Override the secret namespace (default: repo name from GHA_REPO)
#   DEPLOY_ENV            Environment segment in the secret path (default: dev)
#
# Idempotent: safe to re-run; existing secret is updated (upsert).

set -euo pipefail

OPS_ENV="${OPS_ENV:-${HOME}/.ops.env}"
[[ -f "${OPS_ENV}" ]] && set -a && source "${OPS_ENV}" && set +a

SERVICE="${1:?service-name argument is required}"
ENV_FILE="${2:-.env}"
PVE_HOST="${PVE_HOST:?PVE_HOST is required (set in ~/.ops.env)}"
LOCALSTACK_CTID="${DEV_LOCALSTACK_CTID:-190}"
PVE_IP="${PVE_HOST#*@}"
APP_NAMESPACE="${APP_NAMESPACE:-${GHA_REPO##*/}}"
DEPLOY_ENV="${DEPLOY_ENV:-dev}"
SECRET_NAME="${APP_NAMESPACE}/${SERVICE}/${DEPLOY_ENV}/env"

[[ -f "${ENV_FILE}" ]] || { echo "ERROR: env file not found: ${ENV_FILE}" >&2; exit 1; }

echo "==> Ensuring seed-localstack.py is present on CT ${LOCALSTACK_CTID}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scp "${SCRIPT_DIR}/seed-localstack.py" "root@${PVE_IP}:/tmp/seed-localstack.py"
ssh "root@${PVE_IP}" "
  pct exec ${LOCALSTACK_CTID} -- mkdir -p /opt/neosofia/scripts
  pct push ${LOCALSTACK_CTID} /tmp/seed-localstack.py /opt/neosofia/scripts/seed-localstack.py --perms 0755
  rm /tmp/seed-localstack.py
"

echo "==> Seeding ${ENV_FILE} into LocalStack as ${SECRET_NAME}"
scp "${ENV_FILE}" "root@${PVE_IP}:/tmp/${SERVICE}.env"
ssh "root@${PVE_IP}" "
  pct push ${LOCALSTACK_CTID} /tmp/${SERVICE}.env /tmp/${SERVICE}.env --perms 0600 && \
  rm /tmp/${SERVICE}.env && \
  pct exec ${LOCALSTACK_CTID} -- bash -c '
    SEED_ENV_FILE=/tmp/${SERVICE}.env \\
    SEED_SECRET_NAME=${SECRET_NAME} \\
    SEED_MODE=upsert \\
    AWS_ENDPOINT_URL=http://localhost:4566 \\
    AWS_DEFAULT_REGION=us-east-1 \\
    python3 /opt/neosofia/scripts/seed-localstack.py && \
    rm /tmp/${SERVICE}.env
  '
"

echo "==> Done. Secrets for ${SERVICE} stored as ${SECRET_NAME} in LocalStack (CT ${LOCALSTACK_CTID})"
