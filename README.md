# Infrastructure Repository

This repository contains all infrastructure-related scripts, configurations, and documentation for Neosofia.

## Structure

*   `/os/proxmox/9/`: Scripts for setting up, configuring, and provisioning Proxmox VE servers from raw metal to a fully functioning cluster node. (Targeting Proxmox 9)

## Overview

The purpose of these scripts is to establish a repeatable, fully-automated standard for infrastructure deployment and disaster recovery. All scripts should be kept up to date with the latest deployment targets and thoroughly commented on behavior.

## Remote Deployment (On-Save Hooks)

To streamline script development, this repository utilizes `.vscode/settings.json` task rules to seamlessly push changes to a target Proxmox host locally each time you save a `.sh` or config file.

### Setup Requirements:

1. **Install the VS Code Extension**: Search for and install the **Run on Save** extension by *emeraldwalk* (`emeraldwalk.RunOnSave`).
2. **Passwordless SSH**: The hook executes transparently in the background and does not support password prompts. You must have an SSH key pair generated and your public key added into `/root/.ssh/authorized_keys` on the target Proxmox box.
3. **SSH Target Hostname**: By default, the `settings.json` hook attempts to `scp`/`ssh` as `root@pve0001`. You must either:
   * Keep your remote Proxmox box accessible via DNS as `pve0001`
   * Open your local `~/.ssh/config` and map host `pve0001` to its real IP address.
   * Open `.vscode/settings.json` and change the `root@pve0001` targets inside the `"cmd"` string to match your server's IP.

Once properly configured, hitting **Save** in VS Code will sync the workspace scripts over to `/root/neosofia/proxmox` on the remote server, normalize line endings to Linux (`LF`), and automatically apply execute (`chmod +x`) permissions.
