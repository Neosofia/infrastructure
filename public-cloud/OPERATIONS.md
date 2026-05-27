# Public Cloud — Platform Service Operations

Operational guide for deploying Neosofia platform services (authentication, capabilities, CDP UI, python-template, and forks) to a **public cloud** PaaS or managed container host.

This document is **platform-neutral**. Worked examples use [Railway](https://railway.com) because we use it for staging — not because Railway is required. For OpenTofu/AWS apply flows, see [RUNBOOK.md](RUNBOOK.md). For on-prem, see [private-cloud/RUNBOOK.md](../private-cloud/RUNBOOK.md).

**Service repos** should link here for shared JWT, networking, and healthcheck guidance; keep only service-specific runtime notes locally (policy bundles, OpenAPI paths, CI triggers).

---

## Why local docker-compose is not enough

Local compose gives you a single flat network: services resolve each other by container name, ports are fixed in compose files, and nothing crosses the public internet. That simplicity does **not** carry over unchanged to public cloud.

| Concern | Local (compose) | Public cloud |
|---------|-----------------|--------------|
| **Service discovery** | `http://authentication:8014` — DNS baked into compose | Each service has public and (usually) private addresses; choose per caller |
| **JWKS fetch** | Consumers call auth on the internal docker network | Consumers must reach auth on a URL that resolves **inside the cluster/VPC**, not necessarily the URL browsers use |
| **CORS / UI origin** | `http://localhost:5173` | Must be the **public HTTPS URL** where users load the UI |
| **Health probes** | `curl localhost:<port>/health` | Orchestrator often probes **plain HTTP** on the container port — must not redirect to HTTPS |
| **Cross-service config** | `.env.sample` files in each repo | Per-environment variables; typos fail at runtime with cryptic errors |

Start from each service's local `.env.sample`. Public cloud uses the **same variable names** with different values and more ways to get them wrong.

---

## Two traffic planes

Every JWT-validating API service sits in two call paths. Confusing them is the most common deployment mistake.

| Plane | Caller | Configuration | Rationale |
|-------|--------|---------------|-----------|
| **Browser → API** | User UI (`fetch` from JavaScript) | **`FRONTEND_URL`** — public HTTPS origin of the UI | Browsers only reach public hostnames. Flask-CORS matches `Origin` against `FRONTEND_URL`. An internal/VPC hostname never appears in the address bar and will break CORS. |
| **Service → authentication (JWKS)** | Downstream service validating JWTs | **`JWT_JWKS_URI`** — private mesh / VPC URL | JWKS is server-to-server. Prefer the platform private network (Railway `*.railway.internal`, K8s cluster DNS, VPC internal LB) over the public internet — lower latency, no egress, no dependency on auth's public edge on every cold worker. |

Services with no browser clients (batch workers, internal-only APIs) may omit `FRONTEND_URL` if CORS is unused — but most platform Flask services expose CORS for the CDP UI.

---

## JWKS and token validation

### How consumers obtain auth's public key

Pick **one** per environment:

| Option | Variable | When to use |
|--------|----------|-------------|
| **Private JWKS URI (preferred in cloud)** | `JWT_JWKS_URI` | Auth exposes `/.well-known/jwks.json` on the private mesh. |
| **Public JWKS URI (works, not ideal)** | `JWT_JWKS_URI` | Auth's public HTTPS JWKS URL. Simpler; adds latency and egress on cache miss. |
| **Pinned public key** | `JWT_PUBLIC_KEY` | Same PEM as auth. No runtime fetch; manual update on key rotation. If both `JWT_PUBLIC_KEY` and `JWT_JWKS_URI` are set, the **static key wins** and JWKS is ignored. |

**Local compose** (private mesh equivalent):

```dotenv
JWT_JWKS_URI=http://authentication:8014/.well-known/jwks.json
```

Port and hostname match the compose service name and exposed port in each repo's `.env.sample`.

### Authentication (token issuer)

| Variable | Purpose |
|----------|---------|
| `JWT_WEB_AUDIENCE` | Comma-separated `aud` values on platform JWTs. **Must include every downstream service** that validates tokens (e.g. `authentication,capabilities,python-template`). |
| `PORT` | Port gunicorn binds to. Must be **explicit and consistent** wherever other services reference this host. |

If a consumer's audience is missing from `JWT_WEB_AUDIENCE`, that service returns `401 Invalid token` even when JWKS is reachable.

### JWT consumers (capabilities, python-template, …)

| Variable | Purpose |
|----------|---------|
| `ENV` | `production` — enables Talisman, ProxyFix, etc. |
| `JWT_AUDIENCE` | Service-specific audience string (e.g. `capabilities`, `python-template`). Must appear in the token's `aud` claim. |
| `JWT_JWKS_URI` *or* `JWT_PUBLIC_KEY` | How this service obtains auth's signing public key. |
| `FRONTEND_URL` | Public HTTPS UI origin (CORS), when the CDP UI calls this API from the browser. |

---

## Healthcheck and internal HTTP endpoints

Orchestrators probe `GET /health` over **plain HTTP** on the container port. Downstream services fetch `GET /.well-known/jwks.json` from authentication over the **private mesh** — also plain HTTP. Flask-Talisman's `force_https` must **not** redirect those paths.

Python platform services exempt `/health` from the HTTPS redirect (capabilities **v0.5.8+**; template **v0.7.1+**). Authentication exempts `/health` and `/.well-known/jwks.json` (**v0.26.1+**). A `302` on either path breaks healthchecks or JWT validation (`JWKS Error`, empty CDP menu).

---

## Operational gotchas

Check these before debugging application code:

| Gotcha | Symptom | What to check |
|--------|---------|---------------|
| **Auth bind port not published to dependents** | `JWKS Error: Connection refused` | Port in `JWT_JWKS_URI` must match auth's listen port — define explicitly; platforms rarely auto-discover it for cross-service refs |
| **Private URL uses TLS** | Connection refused or TLS errors | Private meshes are usually plain **HTTP**; TLS terminates at the public edge |
| **Port omitted from JWKS URI** | Connection refused (defaults to 80) | Always include `:port` in internal URLs |
| **`JWT_WEB_AUDIENCE` missing a consumer** | `401 Invalid token` on that consumer | Fix on **authentication** |
| **`FRONTEND_URL` is internal/VPC-only** | Browser CORS failures | Must be the **public** UI origin |
| **Healthcheck `302` on `/health`** | Deploy fails at healthcheck | Exempt `/health` from Talisman HTTPS redirect |
| **JWKS `302` on internal fetch** | `401 Invalid token`, empty CDP menu, `Python-urllib` in auth access logs | Exempt `/.well-known/jwks.json` from Talisman HTTPS redirect on authentication |
| **`JWT_PUBLIC_KEY` set incorrectly** | `401 Invalid token`; JWKS ignored | Remove or match auth's current PEM exactly |
| **Quoted env values** | Malformed URLs | Do not wrap values in literal `"..."` in platform UIs |

Cross-service variable references (Railway `${{service.VAR}}`, K8s ConfigMaps, etc.) resolve from **variables you define** — not automatic runtime discovery. Preview resolved values before redeploying dependents.

---

## Verify a deployment

Replace placeholders with your public service hostnames.

```bash
# Any Python platform service
curl -s https://<service-host>/health
# → {"status":"ok"}

# Capabilities (example)
curl -s https://<capabilities-host>/api/v1/capabilities
# → {"namespaces":["ui"]}

# Authenticated endpoint (example)
curl -s \
  -H "Authorization: Bearer <platform-jwt>" \
  -H "X-Active-Role: admin" \
  https://<capabilities-host>/api/v1/capabilities/ui
# → {"ui:menu:admin": true, ...}
```

---

## Example: Neosofia staging on Railway

[Railway](https://railway.com) is one PaaS we use for staging. Map the patterns above as follows:

| Concept | Railway equivalent |
|---------|-------------------|
| Private mesh | `*.railway.internal` ([private networking](https://docs.railway.com/private-networking)) |
| Cross-service vars | `${{service.VAR}}` in the same project/environment |
| Public browser URL | `${{service.RAILWAY_PUBLIC_DOMAIN}}` |

### Capabilities (example)

```dotenv
ENV=production
JWT_AUDIENCE=capabilities
FRONTEND_URL=https://${{cdp.RAILWAY_PUBLIC_DOMAIN}}
JWT_JWKS_URI=http://${{authentication.RAILWAY_PRIVATE_DOMAIN}}:${{authentication.PORT}}/.well-known/jwks.json
```

### Authentication (example)

```dotenv
JWT_WEB_AUDIENCE=authentication,capabilities,python-template
PORT=8080
```

### CDP UI build (example)

```dotenv
VITE_CAPABILITIES_API_URL=https://<capabilities-public-host>
VITE_AUTH_API_URL=https://<authentication-public-host>
```

### Railway gremlins we hit in staging

- **`PORT=8080` must be set explicitly on authentication.** `${{authentication.PORT}}` references a **service variable you define**, not Railway's runtime-injected port. If unset, `JWT_JWKS_URI` expands with an empty port → connection refused.
- **Private URLs use `http://`, not `https://`.** TLS is at the public edge only.
- **Healthcheck** uses `RailwayHealthCheck/1.0` over HTTP on `/health`.

Staging smoke test (hostnames will differ in your project):

```bash
curl -s https://capabilities-production.up.railway.app/health
curl -s https://authentication.staging.neosofia.tech/.well-known/jwks.json
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Deploy fails at healthcheck; `302` on `/health` | HTTPS redirect on liveness probe | Exempt `/health` from Talisman (see [Healthcheck](#healthcheck)) |
| `JWKS Error: Connection refused` | Wrong scheme, missing port, or auth port not defined for cross-service refs | Private **http://** URL with explicit port; verify auth is listening |
| `401 Invalid token` | Token `aud` lacks this service's audience | `JWT_WEB_AUDIENCE` on **authentication** |
| UI nav empty after login | `/capabilities/ui` non-200 | Fix capabilities auth; check browser Network tab |
| CORS error from UI | `FRONTEND_URL` ≠ browser origin | Set to UI's **public** URL |

---

## Service-specific runbooks

| Service | Local ops | Cloud-specific notes |
|---------|-----------|---------------------|
| [authentication](https://github.com/Neosofia/authentication/blob/main/OPERATIONS.md) | WorkOS, keys, DB | Issuer: `JWT_WEB_AUDIENCE`, explicit `PORT` |
| [capabilities](https://github.com/Neosofia/capabilities/blob/main/OPERATIONS.md) | Policy bundle, Cedar | `cdp-ui-policies` image pin, UI entitlements API |
| [python-template](https://github.com/Neosofia/templates/blob/main/python/service/OPERATIONS.md) | Benchmark, Docker | Reference consumer implementation |
| [cdp](https://github.com/Neosofia/cdp/blob/main/OPERATIONS.md) | Compose stack, UI policies | UI build args, cross-service staging checklist |

---

## References

- [public-cloud/RUNBOOK.md](RUNBOOK.md) — OpenTofu/AWS deploy flow
- [private-cloud/RUNBOOK.md](../private-cloud/RUNBOOK.md) — Proxmox / LXC operations
- [Railway private networking](https://docs.railway.com/private-networking)
