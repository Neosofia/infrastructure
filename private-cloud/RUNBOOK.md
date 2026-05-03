# Private Cloud — Service Operations Runbook

This document covers the repeatable mechanics of deploying and operating **any** service
on the Neosofia private cloud (Proxmox + LocalStack + NetBird). Service repos link here
rather than duplicating these steps.

For initial environment bootstrap (provisioning the Proxmox host and shared LocalStack CT)
see the top-level [OPERATIONS.md](../OPERATIONS.md).

---

## Architecture pattern

Every service follows the same topology:

```
     ┌───────────────────────────────────────────────────────┐
     │ Operator terminal (NetBird client)                    │
     └──────────────────────────┬────────────────────────────┘
                                │ NetBird mesh
                                ▼
     ┌───────────────────────────────────────────────────────┐
     │ NetBird — custom domain → Docker                      │
     │  <svc>.dev.<base-domain>     → <dev IP>:<port>        │
     │  <svc>.staging.<base-domain> → <staging IP>:<port>    │
     │  <svc>.prod.<base-domain>    → <prod IP>:<port>       │
     └──────────────────────────┬────────────────────────────┘
                                │ Proxmox SDN
                                ▼
     ┌───────────────────────────────────────────────────────┐
     │ Service CT (Debian 13, Docker CE)                     │
     │  ┌─────────────────────┐  ┌──────────────────────┐   │
     │  │ <service>           │  │ <service>-postgres    │   │
     │  │ app container       │  │ PostgreSQL (if used)  │   │
     │  └──────────┬──────────┘  └──────────────────────┘   │
     │             │ fetches secrets at startup              │
     │             │ via /etc/<service>/env (deploy.sh)      │
     └───────────────────────────────────────────────────────┘
                                │
                                ▼
     ┌───────────────────────────────────────────────────────┐
     │ Secrets CT — LocalStack :4566 (CT 190, 10.0.0.190)   │
     └───────────────────────────────────────────────────────┘
```

---

## Operator prerequisites

### Tools

| Tool | Install |
|------|---------|
| SSH key-based access to Proxmox host | `ssh-copy-id root@<proxmox-ip>` |
| NetBird client | [netbird.io/install](https://netbird.io/install) — connect to the mesh |
| OpenTofu ≥ 1.7 (staging/prod only) | `brew install opentofu` |
| AWS CLI v2 (staging/prod only) | [aws.amazon.com/cli](https://aws.amazon.com/cli/) |

### `~/.ops.env`

All scripts read from `~/.ops.env` (outside any repo — never committed):

```bash
PVE_HOST=root@<proxmox-host>        # SSH target for Proxmox
GHA_ORG=neosofia                    # GitHub organisation
GHA_RUNNER_TOKEN=<token>            # Org-level runner registration token
                                    # Generate: GitHub → neosofia org → Settings → Actions → Runners → New runner
GHCR_USER=<github-username>         # Optional — only for private GHCR packages
GHCR_TOKEN=<pat>                    # Optional — only for private GHCR packages
```

Override the path at call time: `OPS_ENV=/other/path ./private-cloud/containers/create-ct.sh ...`

---

## DNS and reverse proxy setup (one-time, per environment)

Done once per environment in external dashboards. Examples use `dev` — substitute
`staging` or `prod` as needed.

### 1. Reverse proxy — wildcard custom domain

In the reverse proxy dashboard (e.g. NetBird: **Network → Routing → Reverse Proxy → Custom Domain**):

- Domain: `*.dev.<base-domain>`

The provider will display a **CNAME target** — note it, then complete step 2 before continuing.

Once DNS is in place, return and wait for the domain status to show **Active** with a wildcard cert issued.

> **Known issue (NetBird ≥ beta)**: requesting a cert for a _specific_ subdomain
> (e.g. `svc.dev.neosofia.tech`) wedges at "Issuing". Use a wildcard custom domain
> and rely on the wildcard cert instead. Track [NetBird #5517](https://github.com/netbirdio/netbird/issues/5517).

### 2. DNS

Add a wildcard CNAME (at Cloudflare or your DNS provider) using the CNAME target from step 1:

| Name | Type | Target | Proxy |
|------|------|--------|-------|
| `*.dev.<base-domain>` | CNAME | `<CNAME target from step 1>` | DNS only/Off |

One wildcard covers all services in that environment. Repeat for `*.staging.` and `*.prod.`
when those environments are brought up.

> **Cloudflare**: the record must be **DNS only** (grey cloud). Orange-cloud (proxied) breaks
> NetBird's TLS termination.

### 3. Reverse proxy — per-service route

For each service, add a route under the wildcard custom domain:

| Field | Value |
|-------|-------|
| Domain | `<svc>.dev.<base-domain>` |
| Target | `http://<ct-ip>:<port>` |
| Protocol | HTTP |

---

## First deployment of a service (dev environment)

**Step 1 — Provision the LXC CT** (from the infrastructure repo)

```bash
cd <neosofia-infrastructure-folder>
./private-cloud/containers/create-ct.sh <service-name> <ctid> <ip-cidr>
# e.g. ./private-cloud/containers/create-ct.sh my-service 130 10.0.0.130/10
```

Provisions an unprivileged Debian 13 CT: 2 vCPU, 4 GiB RAM, 20 GiB rootfs,
`nesting=1` + `keyctl=1` for Docker. Installs Docker CE. Registers an org-level
GHA self-hosted runner with label `<service-name>`. Idempotent — safe to re-run.

**Step 2 — Seed service secrets**

⚠ **Do this before pushing any tag.** The GHA runner is live immediately after Step 1.
If a deploy triggers before secrets exist, the deploy will fail.

```bash
# 1. Generate secrets per the service's own instructions (see its OPS-CLOUD.md)
# 2. Push to the CT
cd <neosofia-infrastructure-folder>
bash private-cloud/containers/seed-ct-env.sh <service-name> /path/to/<service>/.env
```

**Step 3 — Trigger the first deploy** (push a CalVer tag from the service repo)

```bash
git tag <service>/$(date +%Y.%m.%d)
git push origin <service>/$(date +%Y.%m.%d)
```

**Step 4 — Verify**

```bash
# Internal health check
ssh root@$PVE_HOST "pct exec $CTID -- /usr/bin/curl -s http://localhost:<port>/api/health"
# → {"status":"ok"}

# Public health check (once DNS + NetBird proxy are configured)
curl https://<svc>.dev.<base-domain>/api/health
```

---

## Ongoing operations

### Redeploy from a new image tag (automated)

Push a CalVer tag — the build → test → scan → push → deploy pipeline runs automatically
on the self-hosted runner inside the CT:

```bash
git tag <service>/$(date +%Y.%m.%d)
git push origin <service>/$(date +%Y.%m.%d)
```

To deploy manually (re-deploy an existing tag):

```bash
# GitHub UI: Actions → <Service> Deploy Dev → Run workflow → enter tag
# Or via CLI:
gh workflow run <service>-deploy-dev.yml -f image_tag=<tag>
```

### Rotate secrets

```bash
cd <neosofia-infrastructure-folder>
bash private-cloud/containers/seed-ct-env.sh <service-name> /path/to/<service>/.env

ssh $PVE_HOST "pct exec $CTID -- bash -c '
  docker compose -f /opt/actions-runner/_work/<service>/<service>/docker-compose.yml \
    -f /opt/actions-runner/_work/<service>/<service>/docker-compose.cloud.yml \
    restart <service>
'"
```

### Observability

```bash
COMPOSE="-f docker-compose.yml -f docker-compose.cloud.yml"
APP=/opt/actions-runner/_work/<service>/<service>

# Tail logs
ssh $PVE_HOST "pct exec $CTID -- bash -c 'cd $APP && docker compose $COMPOSE logs -f'"

# Container status
ssh $PVE_HOST "pct exec $CTID -- bash -c 'cd $APP && docker compose $COMPOSE ps'"

# Postgres shell (if applicable)
ssh $PVE_HOST "pct exec $CTID -- docker exec -it <service>-postgres psql -U <user> -d <db>"
```

### Backup Postgres data on demand

```bash
ssh root@$PVE_HOST "pct exec $CTID -- \
  docker exec <service>-postgres pg_dump -U <user> <db>" \
  > <service>-$(date +%F).sql
```

### Teardown

```bash
# Remove a service CT
ssh $PVE_HOST "pct stop $CTID && pct destroy $CTID"
```

Wipes everything including data volumes. Re-run Steps 1–3 to rebuild from scratch.

To tear down the shared LocalStack CT (destroys **all** seeded secrets across every service):

```bash
ssh $PVE_HOST "pct stop 190 && pct destroy 190"
```

---

## CT inventory (dev)

| CT ID | Hostname | IP | Role |
|-------|----------|----|------|
| 190 | secrets-dev | 10.0.0.190 | Shared LocalStack (Secrets Mgr) |
| 120 | authentication-dev | 10.0.0.120 | Authentication service + runner |

---

## Troubleshooting

| Symptom | Likely cause |
|---------|-------------|
| `docker: command not found` during bootstrap | `create-ct.sh` failed partway — re-run it (idempotent) |
| Service returns 500 on `/api/health` | Missing or malformed secret — check `/etc/<service>/env` exists and `docker logs <service> --tail 50` |
| NetBird cert stuck "Issuing" on a specific subdomain | Known NetBird beta bug ([#5517](https://github.com/netbirdio/netbird/issues/5517)) — use a wildcard Custom Domain (`*.dev.<base-domain>`) instead; verify DNS CNAME is DNS-only (grey cloud) |
| TLS `internal_error` / SSL alert 80 after cert issued | NetBird edge cert state is wedged — delete and re-create the service and custom domain in the NetBird dashboard |
| `tofu apply` fails with S3 backend error | Run `aws sso login` on the operator terminal and retry |
