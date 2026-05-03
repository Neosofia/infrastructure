# Public Cloud

OpenTofu IaC for managing platform services in a public cloud (initially AWS).

## Sub-directories

- [`aws/`](aws/) — AWS environments and reusable modules.
- [`RUNBOOK.md`](RUNBOOK.md) — minimal public cloud deployment runbook.

## Structure (planned)

```
aws/
├── modules/          # Reusable OpenTofu modules
└── environments/
    ├── dev/
    ├── staging/
    └── prod/
```
