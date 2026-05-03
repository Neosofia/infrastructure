#!/usr/bin/env bash
# Deploy a service image to its Docker environment.
#
# Shared across all services — lives in the infrastructure repo and is
# installed to /opt/neosofia/scripts/ on every service host by create-ct.sh.
#
# Usage:
#   deploy.sh <service_name> <image_tag> <repository>
#
# Arguments:
#   service_name  - Service directory name under services/ (e.g. authentication)
#   image_tag     - The image tag to deploy (e.g. v1.0.0)
#   repository    - GitHub repository in owner/repo format (e.g. acme/platform);
#                   used to locate the GHCR image and derive the secret namespace
#
# Environment:
#   COMPOSE_DIR         - Override compose file directory
#                         (default: GITHUB_WORKSPACE/services/<service_name>)
#   LOCALSTACK_URL      - URL of the secrets service
#                         (required — no default; set on the host via /etc/environment or similar)
#   DEPLOY_ENV          - Environment name used as the secret path segment
#                         (default: dev)
#
# The script:
#   1. Checks out service secrets from the secrets service → /etc/<service>/env
#   2. Pulls the tagged image from GHCR and retags as :latest
#   3. docker compose up -d (depends_on + healthchecks handle ordering)
#   4. Polls the service healthcheck until healthy or 90s timeout

set -euo pipefail

SERVICE_NAME="${1:?service_name argument is required}"
IMAGE_TAG="${2:?image_tag argument is required}"
REPOSITORY="${3:?repository argument is required (owner/repo format, e.g. acme/platform)}"
IMAGE="ghcr.io/${REPOSITORY}/${SERVICE_NAME}"
LOCALSTACK_URL="${LOCALSTACK_URL:?LOCALSTACK_URL is required (set it on the host, e.g. in /etc/environment)}"
DEPLOY_ENV="${DEPLOY_ENV:-dev}"
COMPOSE_DIR="${COMPOSE_DIR:-${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel)}/services/${SERVICE_NAME}}"
APP_NAMESPACE="${REPOSITORY##*/}"
SECRET_NAME="${APP_NAMESPACE}/${SERVICE_NAME}/${DEPLOY_ENV}/env"
ENV_DEST="/etc/${SERVICE_NAME}/env"

echo "==> Checking out secrets from LocalStack (${SECRET_NAME})"
mkdir -p "/etc/${SERVICE_NAME}"
LOCALSTACK_URL="${LOCALSTACK_URL}" SECRET_NAME="${SECRET_NAME}" ENV_DEST="${ENV_DEST}" \
python3 - <<'PYEOF'
import boto3, json, os, sys
client = boto3.client(
    "secretsmanager",
    endpoint_url=os.environ["LOCALSTACK_URL"],
    region_name="us-east-1",
    aws_access_key_id="test",
    aws_secret_access_key="test",
)
secret_name = os.environ["SECRET_NAME"]
dest = os.environ["ENV_DEST"]
try:
    resp = client.get_secret_value(SecretId=secret_name)
except client.exceptions.ResourceNotFoundException:
    print(f"ERROR: secret '{secret_name}' not found in LocalStack", file=sys.stderr)
    sys.exit(1)
bundle = json.loads(resp["SecretString"])
with open(dest, "w") as fh:
    for k, v in bundle.items():
        fh.write(f"{k}={v}\n")
    # Inject deploy-time infrastructure config that is not a secret
    fh.write(f"AWS_ENDPOINT_URL={os.environ['LOCALSTACK_URL']}\n")
os.chmod(dest, 0o640)
print(f"Wrote {len(bundle)} keys to {dest}")
PYEOF

echo "==> Pulling ${IMAGE}:${IMAGE_TAG}"
docker pull "${IMAGE}:${IMAGE_TAG}"

echo "==> Tagging ${IMAGE}:${IMAGE_TAG} as ${IMAGE}:latest"
docker tag "${IMAGE}:${IMAGE_TAG}" "${IMAGE}:latest"

echo "==> Starting database"
docker compose \
  -f "${COMPOSE_DIR}/docker-compose.yml" \
  -f "${COMPOSE_DIR}/docker-compose.cloud.yml" \
  up -d auth-postgres

echo "==> Waiting for database to be healthy (up to 60s)"
for i in $(seq 1 20); do
  status=$(docker inspect --format='{{.State.Health.Status}}' cdp-auth-postgres 2>/dev/null)
  if [[ "${status}" == "healthy" ]]; then
    echo "  Database is healthy."
    break
  fi
  if [[ "${i}" -eq 20 ]]; then
    echo "ERROR: database did not become healthy in time." >&2
    exit 1
  fi
  echo "  attempt $i/20 — status: ${status:-unknown}"
  sleep 3
done

echo "==> Running database migrations"
docker run --rm \
  --network "${SERVICE_NAME}_default" \
  --env-file "${ENV_DEST}" \
  "${IMAGE}:latest" \
  python -m alembic upgrade head

echo "==> Bringing up ${SERVICE_NAME} stack"
docker compose \
  -f "${COMPOSE_DIR}/docker-compose.yml" \
  -f "${COMPOSE_DIR}/docker-compose.cloud.yml" \
  up -d --force-recreate "${SERVICE_NAME}"

echo "==> Waiting for ${SERVICE_NAME} to report healthy (up to 90s)"
for i in $(seq 1 30); do
  container_id=$(docker compose \
    -f "${COMPOSE_DIR}/docker-compose.yml" \
    -f "${COMPOSE_DIR}/docker-compose.cloud.yml" \
    ps -q "${SERVICE_NAME}" 2>/dev/null)
  status=$(docker inspect --format='{{.State.Health.Status}}' "${container_id}" 2>/dev/null)
  if [[ "${status}" == "healthy" ]]; then
    echo "Service is healthy."
    exit 0
  fi
  echo "  attempt $i/30 — status: ${status:-unknown}"
  sleep 3
done

echo "ERROR: ${SERVICE_NAME} did not become healthy in time." >&2
docker compose \
  -f "${COMPOSE_DIR}/docker-compose.yml" \
  -f "${COMPOSE_DIR}/docker-compose.cloud.yml" \
  logs --tail=50
exit 1
