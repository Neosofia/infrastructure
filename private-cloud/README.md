# Private Cloud

Scripts for managing LXC containers and services inside a running Proxmox VE host.

## Sub-directories

- [`containers/`](containers/) — Provision service CTs, seed secrets, and deploy containers via GitHub Actions runners.

## Usage

See [RUNBOOK.md](RUNBOOK.md) for the full operations guide: CT provisioning, DNS/NetBird setup, secret seeding, deploy, rotate, CT inventory, and teardown.

## Remote Deployment (On-Save Hooks)

To streamline script development, this repository utilizes `.vscode/settings.json` task rules to seamlessly push changes to a target Proxmox host locally each time you save a `.sh` or config file.

### Setup Requirements:

1. **Install the VS Code Extension**: Search for and install the **Run on Save** extension by *emeraldwalk* (`emeraldwalk.RunOnSave`).
2. **Passwordless SSH**: The hook executes transparently in the background and does not support password prompts. You must have an SSH key pair generated and your public key added into `/root/.ssh/authorized_keys` on the target Proxmox box.
3. **Set the `PROXMOX_HOST` environment variable**: The deploy command reads the target host from `$PROXMOX_HOST`. Export it in `~/.zshenv` (not `~/.zshrc` — VS Code's backend shell is non-interactive and only sources `~/.zshenv`):
   ```sh
   export PROXMOX_HOST=pve0001
   ```
   The value can be an SSH config alias or a direct IP address. Restart VS Code after editing `~/.zshenv`.
4. **SSH alias (if using a hostname)**: If `PROXMOX_HOST` is a name rather than an IP, add a matching entry to `~/.ssh/config`:
   ```
   Host pve0001
       HostName <ip-address>
       User root
   ```

Once properly configured, hitting **Save** in VS Code will sync the workspace scripts over to `/root/neosofia/proxmox` on the remote server, normalize line endings to Linux (`LF`), and automatically apply execute (`chmod +x`) permissions. To retarget a different host, change `PROXMOX_HOST` in `~/.zshenv` and restart VS Code.
