# Operations — Infrastructure Setup

This document covers the one-time groundwork required before any service can
be deployed.  Run these steps once per environment (dev, staging, prod).
After they are complete, service deploys are fully automated via GitHub Actions.

---

## Prerequisites

### 1. Proxmox host

A running Proxmox VE 9 host reachable over SSH.  All scripts SSH into the PVE
host as root and issue `pct` commands — no direct SSH into individual CTs is
required.

Use the scripts in [`hypervisor/proxmox/9/`](hypervisor/proxmox/9/) to provision and harden a
fresh Proxmox node.  See [`hypervisor/proxmox/9/README.md`](hypervisor/proxmox/9/README.md)
for the full procedure, then run in order:

### 2. ops.env

All scripts read credentials from `~/.ops.env`.  Create it once:

```bash
cat > ~/.ops.env <<'EOF'
# Proxmox host SSH target
PVE_HOST=root@192.168.x.x

# GitHub repo that owns the service (owner/repo format)
# The repo name (e.g. "platform" from "acme/platform") is used as the secret namespace
GHA_REPO=owner/repo

# Runner registration token — expires after 1 hour
# Generate at: GitHub → Settings → Actions → Runners → New runner
GHA_RUNNER_TOKEN=

# Optional — only needed if GHCR packages are private
GHCR_USER=
GHCR_TOKEN=

# CT IDs used during provisioning (for reference)
DEV_LOCALSTACK_CTID=190
EOF
chmod 600 ~/.ops.env
```

### 3. SSH key to Proxmox

```bash
ssh-copy-id root@<proxmox-ip>
```

## Step 1 — Provision the shared LocalStack CT

LocalStack runs on a dedicated CT (`10.0.0.190`) and acts as the AWS Secrets
Manager endpoint for all service CTs.  It is provisioned once and stays
running permanently.

```bash
cd ~/projects/neosofia/infrastructure
./private-cloud/containers/create-localstack-ct.sh        # uses defaults: ctid=190, ip=10.0.0.190/10
```

What it does:
- Creates an unprivileged Debian 13 LXC CT (2 cores, 2 GB RAM)
- Installs Docker
- Starts `localstack/localstack:4` with `PERSISTENCE=1` and a bind-mount at
  `/var/lib/localstack` so secrets survive reboots
- Waits for LocalStack to become healthy before returning

Verify:
```bash
curl -s http://10.0.0.190:4566/_localstack/health | python3 -m json.tool
```

---

## Step 2 — Provision a service CT

Run once per service.  The script is generic — the service name becomes the
runner label and the `/etc/<service-name>/env` secrets path.

```bash
# Generate a fresh runner token first (tokens expire after 1 hour):
# GitHub → <repo> → Settings → Actions → Runners → New runner → copy token
# Then update ops.env:
#   GHA_RUNNER_TOKEN=<token>

cd ~/projects/neosofia/infrastructure
./private-cloud/containers/create-ct.sh authentication 120 10.0.0.120/10
```

What it does:
- Creates an unprivileged Debian 13 LXC CT (2 cores, 4 GB RAM)
- Installs Docker + `python3-boto3`
- Copies shared scripts to `/opt/neosofia/scripts/` on the CT
- Creates a `gha-runner` user (member of the `docker` group)
- Downloads and registers a GitHub Actions self-hosted runner
  (label: `<service-name>`) as a systemd service

The runner starts immediately and begins polling GitHub for jobs.

---

## Step 3 — Seed service secrets

Each service may ship with a helper script that generates all cryptographic material
(RSA keypair, CSRF secret, cookie password) and copies in the remaining
variables from its `.env.example`.  Fill in the remaining credentials, then
push the file to the CT.  `deploy.sh` reads it on every deploy and upserts the
values into LocalStack automatically. For example, the authentication service is
handled as follows from the top level director of the repo: 

```bash
# 1. Generate secrets (handles all crypto — do not skip or hand-craft this step)
./scripts/setup-env.sh          # creates .local.env from .local.env.example + generates secrets
$EDITOR .local.env              # fill in WORKOS_CLIENT_ID, WORKOS_API_KEY, PUBLIC_BASE_URL, etc.

# 2. Push to the secrets service
cd ~/projects/neosofia/infrastructure
bash private-cloud/containers/seed-ct-env.sh authentication /path/to/authentication/.dev.env
```

See the service's `OPS-CLOUD.md` for details on each variable.

---

## Step 4 — Trigger the first deploy

Push a SemVer tag from the service repo to kick off the build → deploy
pipeline:

```bash
cd ~/projects/neosofia/<service-repo>
git tag authentication/v1.0.0
git push origin authentication/v1.0.0
```

Or trigger the deploy workflow manually in GitHub Actions with a specific tag.

The deploy workflow (`authentication-deploy-dev.yml`) runs on the self-hosted
runner inside CT 120 and:
1. Pulls the tagged image from GHCR
2. Calls `deploy.sh` which upserts `/etc/authentication/env` into LocalStack
3. Runs `docker compose up -d` (postgres only as a dependency)
4. Polls `/api/health` until healthy

---

## Repeatable service onboarding

To add a second service (e.g. `my-new-service` on CT 130):

```bash
# 1. Provision the CT
./private-cloud/containers/create-ct.sh my-new-service 130 10.0.0.130/10

# 2. Seed secrets (run from the service directory after generating .env)
bash private-cloud/containers/seed-ct-env.sh my-new-service /path/to/my-new-service/.env

# 3. Push a tag from the service repo
#    git tag my-new-service/v1.0.0 && git push origin my-new-service/v1.0.0
```

No changes to the shared LocalStack CT required — `deploy.sh` creates the
secret namespace automatically (`<repo>/my-new-service/dev/env`, where `<repo>` is the
repo-name portion of `GHA_REPO`).

---

## CT inventory (dev)

| CT ID | Hostname              | IP            | Role                              |
|-------|-----------------------|---------------|-----------------------------------|
| 190   | secrets-dev           | 10.0.0.190    | Shared LocalStack (Secrets Mgr)   |
| 120   | authentication-dev    | 10.0.0.120    | Authentication service + runner   |

---

## Teardown

```bash
# Remove a service CT
ssh root@<proxmox-ip> "pct stop 120 && pct destroy 120"

# Remove the LocalStack CT (destroys all seeded secrets)
ssh root@<proxmox-ip> "pct stop 190 && pct destroy 190"
```
