#!/usr/bin/env bash
# Deploy a service image to its Docker environment on an LXC CT.
#
# Shared across all services — lives in the infrastructure repo and is
# checked out by each service's GHA deploy workflow.
#
# Usage:
#   deploy.sh <service_name> <image_tag> [repository_owner]
#
# Arguments:
#   service_name        - Service directory name under services/ (e.g. authentication)
#   image_tag           - The image tag to deploy (e.g. 2026.04.26)
#   repository_owner    - GitHub org/user that owns the GHCR package (default: byoung)
#
# Environment:
#   COMPOSE_DIR         - Override compose file directory
#                         (default: GITHUB_WORKSPACE/services/<service_name>)
#
# The script:
#   1. Pulls the tagged image from GHCR
#   2. Retags it as :latest
#   3. docker compose up -d (depends_on + healthchecks in the compose files
#      handle startup ordering — no extra wait logic needed here)
#   4. Polls the service healthcheck until healthy or 90 s timeout

set -euo pipefail

SERVICE_NAME="${1:?service_name argument is required}"
IMAGE_TAG="${2:?image_tag argument is required}"
REPO_OWNER="${3:-byoung}"
IMAGE="ghcr.io/${REPO_OWNER}/pdc/${SERVICE_NAME}"
# GITHUB_WORKSPACE is set by the GHA runner; fall back for local testing.
COMPOSE_DIR="${COMPOSE_DIR:-${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel)}/services/${SERVICE_NAME}}"

echo "==> Pulling ${IMAGE}:${IMAGE_TAG}"
docker pull "${IMAGE}:${IMAGE_TAG}"

echo "==> Tagging ${IMAGE}:${IMAGE_TAG} as ${IMAGE}:latest"
docker tag "${IMAGE}:${IMAGE_TAG}" "${IMAGE}:latest"

echo "==> Bringing up ${SERVICE_NAME} stack"
docker compose \
  -f "${COMPOSE_DIR}/docker-compose.yml" \
  -f "${COMPOSE_DIR}/docker-compose.cloud.yml" \
  up -d --force-recreate --no-deps "${SERVICE_NAME}"

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
