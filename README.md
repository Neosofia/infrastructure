# Infrastructure Repository

This repository contains all infrastructure-related scripts, configurations, and documentation for Neosofia.

## Overview

The purpose of these scripts is to establish a repeatable, fully-automated standard for infrastructure deployment and disaster recovery. All scripts should be kept up to date with the latest deployment targets and thoroughly commented on behavior.

## Structure

*   `hypervisor/proxmox/9/`: Scripts for installing, configuring, and hardening Proxmox VE on bare metal. (Targeting Proxmox 9)
*   `private-cloud/containers/`: Scripts for managing LXC containers and deploying services inside a running Proxmox host.
*   `public-cloud/aws/`: OpenTofu IaC for managing platform services in AWS.
*   `corporate-systems/`: Non-platform operational tooling — email sieve filters, network appliance setup, etc.


## Continued Reading

- [hypervisor/README.md](hypervisor/README.md) — Proxmox VE host setup
- [hypervisor/proxmox/9/README.md](hypervisor/proxmox/9/README.md) — Proxmox 9 install and hardening scripts
- [private-cloud/README.md](private-cloud/README.md) — LXC container management and on-save deploy hooks
- [private-cloud/RUNBOOK.md](private-cloud/RUNBOOK.md) — Full operations guide: CT provisioning, DNS, secrets, deploy, teardown
- [public-cloud/README.md](public-cloud/README.md) — OpenTofu IaC for AWS
- [corporate-systems/README.md](corporate-systems/README.md) — Email, network, and hardware tooling
