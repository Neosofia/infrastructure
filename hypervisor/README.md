# Hypervisor

Scripts for installing and hardening Proxmox VE on bare-metal commodity hardware.

## Sub-directories

- [`proxmox/9/`](proxmox/9/) — Proxmox VE 9 installation and post-install hardening scripts. See [`proxmox/9/README.md`](proxmox/9/README.md) for the full procedure.

A new major version of Proxmox gets its own versioned sub-directory (e.g. `proxmox/10/`) since the install scripts change significantly between major releases.

## Non-standard hardware

Scripts for running Proxmox on unusual commodity hardware configurations live in [`corporate-systems/hardware/`](../corporate-systems/hardware/) rather than here. They are not part of the standard install path but are kept for reference:

- [`amdGPU.bash`](../corporate-systems/hardware/amdGPU.bash) — AMD GPU passthrough setup (e.g. for Plex hardware acceleration).
- [`t2MacSetup.sh`](../corporate-systems/hardware/t2MacSetup.sh) — T2 Mac support (2020 Intel iMac as a Proxmox host): fan control, T2-patched PVE kernel.
