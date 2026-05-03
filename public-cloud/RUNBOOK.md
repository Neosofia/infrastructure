# Public Cloud — Minimal Runbook

This document is a minimal operational runbook for public-cloud services deployed
with OpenTofu.

It is intentionally small: service repos should define only their own runtime
dependencies, environment variables, and cloud-specific configuration. The
public-cloud runbook covers the common deployment pattern and operator
prerequisites.

---

## Scope

This runbook applies to public cloud environments managed from this repository:
- `public-cloud/aws/`

It does not cover service-specific configuration inside each repo.

---

## Operator prerequisites

- OpenTofu ≥ 1.7
- AWS CLI v2
- AWS credentials via `aws sso login` or environment variables
- SSH access to the service bootstrap host if using bastion or remote state

---

## One-time AWS account bootstrap

Run once per AWS account. Creates the S3 bucket, DynamoDB lock table, and KMS key
shared by all environments.

```bash
aws sso login   # or: export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...

cd <service-repo>/infra/tofu/bootstrap
tofu init
tofu apply

# Save backend configs for each env (gitignored — regenerate any time)
tofu output -raw backend_config_staging > ../envs/staging/backend.conf
tofu output -raw backend_config_prod    > ../envs/prod/backend.conf
```

> [!CAUTION]
> **Back up `terraform.tfstate`** before closing this terminal — copy it to a
> password manager or private encrypted location. It is gitignored by design.
> Losing it requires manual state reconstruction.

---

## Deploy an environment

```bash
cd <service-repo>/infra/tofu/envs/<env>

# First time only
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

tofu init -backend-config=backend.conf
tofu plan -out=<env>.tfplan
tofu apply <env>.tfplan
```

Verify after apply:
```bash
curl -s https://<svc>.<env>.<base-domain>/api/health
# → {"status":"ok"}
```

---

## Rotate secrets

```bash
# Single resource
tofu apply -replace=<module>.<resource>

# All random secrets
tofu apply -var='rotate_secrets=true'
```

If rotating a database password, wipe the data volume first:

```bash
ssh root@$PVE_HOST "pct exec $CTID bash -c '
  cd /opt/<service>
  docker compose down -v
  rm -rf /var/lib/<service>/postgres
'"
tofu apply
```

---

## Rollback a secret

```bash
aws secretsmanager get-secret-value \
  --secret-id <org>/<service>/<env>/env \
  --version-stage AWSPREVIOUS
```

---

## Troubleshooting

| Symptom | Likely cause |
|---------|-------------|
| `tofu apply` fails with S3 backend error | Run `aws sso login` and retry |
| Postgres password drift after secret rotation | Wipe the data volume and re-apply (see Rotate secrets above) |

---

## Suggested layout

```
public-cloud/aws/
├── modules/          # reusable OpenTofu modules
└── environments/
    ├── dev/
    ├── staging/
    └── prod/
```

Each environment should have its own backend config, tfvars, and state files.

---

## Service-specific guidance

- Keep service deployments small and parameterized.
- Do not duplicate shared infrastructure in every repo.
- Define service runtime dependencies in the repo's Dockerfile.
- Keep cloud-specific environment variables in the service repo's CI/CD or
  deploy variables, not in the shared runbook.

---

## References

- `public-cloud/aws/` — public cloud IaC root
- `hypervisor/proxmox/9/` — private cloud bootstrap root
- `private-cloud/RUNBOOK.md` — shared private-cloud operations
