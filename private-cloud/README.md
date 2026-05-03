# Private Cloud

Scripts for managing LXC containers and services inside a running Proxmox VE host.

## Sub-directories

- [`containers/`](containers/) — Provision service CTs, seed secrets, and deploy containers via GitHub Actions runners.

## Usage

See the [RUNBOOK.md](RUNBOOK.md) for the repeatable service operations guide (CT provisioning,
DNS/NetBird setup, secret seeding, deploy, rotate, teardown). The top-level
[OPERATIONS.md](../OPERATIONS.md) covers initial environment bootstrap.
