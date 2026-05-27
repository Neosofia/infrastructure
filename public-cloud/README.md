# Public cloud — Platform service operations

Shared JWT, JWKS, CORS, healthcheck, and PaaS networking guidance for all platform services:

**→ [OPERATIONS.md](OPERATIONS.md)**

## Sub-directories

- [`aws/`](aws/) — AWS environments and reusable modules.
- [`OPERATIONS.md`](OPERATIONS.md) — platform service deployment patterns (JWKS, two traffic planes, gotchas).
- [`RUNBOOK.md`](RUNBOOK.md) — OpenTofu/AWS apply runbook.

## Structure (planned)

```
aws/
├── modules/          # Reusable OpenTofu modules
└── environments/
    ├── dev/
    ├── staging/
    └── prod/
```
