<!--- Referenced Glossary Terms -->
[ear]: /website/qms/glossary.md#encryption-at-rest-ear


<!--- External Links -->
[rear]: https://relax-and-recover.org/
[od]: https://github.com/abraunegg/onedrive
[pve]: https://www.proxmox.com/en/
[pvesetup]: https://www.proxmox.com/en/proxmox-virtual-environment/get-started
[pvehs]: https://community-scripts.github.io/ProxmoxVE/scripts?id=post-pve-install
[sdn]: https://pve.proxmox.com/pve-docs/chapter-pvesdn.html

# Proxmox Setup

> [!WARNING]
> **Production and staging environments require a paid Proxmox VE subscription.**
> These scripts disable the community-edition subscription nag screen, which is
> legitimate for development and test use. However, running without a subscription
> in a production or regulated environment means you receive no vendor security
> patches, no enterprise repository access, and no support SLA. For any environment
> handling real data or subject to compliance requirements (SOC 2, HIPAA, etc.),
> purchase an appropriate [Proxmox VE subscription](https://www.proxmox.com/en/proxmox-ve/pricing)
> before go-live. Lack of vendor support for core infrastructure is a material
> finding in most security audits.

In order to run corporate services and applications, Neosofia has elected to use Proxmox for virtualization. To support our compliance by design objective, the following procedures are followed in order to create the system that will automatically back up and restore the entire operating system on a daily basis. These scripts also support our [policies](/website/qms/policies.md) by setting up:
 * Encryption at Rest ([EAR][ear]) for the [PVE][pve] backup device
 * [REAR][rear] setup for automated host level backup and recovery
 * Tools need to move backups to an offsite location ([OneDrive][od])
 * [SDN][sdn] for network partitioning

## Prerequisites/Assumptions

Before starting this process, you will need any modern 2010+ PC with a UEFI BIOS, 4GB RAM, 4 core CPU, 256GB+ HD, and 1GB NIC connected to the Internet.

> [!NOTE] 
> This guide used a Beelink EQ system with dual 2.5GB ports, N100 processor, 512GB nvme, 1TB 2.5" SATA drive, and 64GB USB 3.0 pen drive. The NVME device is set as the first device to boot from as making the USB device first would cause an infinite reinstall loop :s


## OS Setup 

In order to bootstrap our system, an existing Proxmox installation must be used to create your first USB stick. Standard Proxmox installation instructions can be found [here][pvesetup] and if you don't have a subscription, you must also run the Proxmox post install helper scripts [here][pvehs]. Once the machine is booted we must set up environment variables to be used by the [prepareMedia.sh](prepareMedia.sh) script by copying the [env.sample](.env.sample) to `.env` and modifying to suit our hardware. Below are the defaults used in the current setup scripts.

> [!WARNING]
> Based on how you configure your environment variables, the unattended install process will **wipe out all devices** without any prompting!

| Variable              | Command to Lookup     | Default Value    | Notes |
|-----------------------|-----------------------|------------------| ----- |
| PVE_INSTALL_FROM_DEVICE | `lsblk -fs`           | N/A   | The USB stick you want the installation iso written to. typically sda or sdb |
| PVE_INSTALL_TO_DEVICE | `lsblk -fs`           | /dev/nvme*n1     | Optional: script defaults to first nvme device on your machine      |
| PBS_BACKUP_DEVICE     | `lsblk -fs `          |                  | Optional: This is where LXC and VM backups and ISOs will be stored to support the rebuild process. |
| REAR_BACKUP_DEVICE    | `lsblk -fs`           |.                 | Optional: Where REAR will be installed to back up and restore to/from for our Proxmox host. |
| ROOT_PW               | N/A                   |                  | This is the password to be used ONLY for the setup process. Always change the root password after setup |

Once your `.env` file is set up, run the [prepareMedia.sh](prepareMedia.sh) command to generate the answers file and burn the ISO catered to your system. If the installation target is the machine you're working on use the command below to force a reboot into the USB stick.

> [!CAUTION]
> FINAL WARNING: Based on how you configured your environment variables, the unattended install process will **wipe out all devices** without any prompting!

To find your USB stick with the Proxmox installer use the command `efibootmgr` and once identified run this command to reboot into the USB stick (000B in our case) `efibootmgr -n 000B && systemctl reboot`

After about five minutes the machine will boot into Proxmox for the first time and a second reboot will occur once packages are updated. If any errors occurred you can navigate to the pve0001 > System > System Log or if you only have terminal access use the `journalctl` command.

When finished, you'll have a fully functional Proxmox system with:
 * Local DNS, IDP, AD, VPN overlay, SMB, and many more company services that enable cloud independent work.
 * Windows and Linux desktop environments with GPU pass through
 * Daily backup of all services and desktop environments to the internal backup drive.
 * Daily backup of the host machine to the internal backup drive.
 * Weekly offsite backups for LXCs, VMs, and the Proxmox host.
 * Full disk level encryption of all drives for security.
 * A company landing page for all the services. 
 * 

### Gotchas

 * If you're Proxmox system is not getting an IP address from your DHCP server, you may have to disable spanning tree protocol (STP) and/or auto link negotiation to speed up IP address allocation. The unattended Proxmox install has very low DHCP timeout tolerances and may crash ahead with a self-assigned IP that may or may not work on your network.

*System administrator checklist TBD*

## SSL Certificate Setup

### Procedures

Follow these steps to set up SSL certificates on your Proxmox server.
1. Obtain a domain and API key/token from your DNS provider.
2. Under the `Datacenter => ACME` menu in your Proxmox instance, do the following
  * Add a Production account
  * Add a Staging account (optional for testing)
  * Add a Plugin based on your DNS provider. The information you need to enter varies based on the provider, but typically requires an API token and account ID.  
3. Add a local DNS entry for your machine. For example, the first Neosofia Proxmox node was `pve-0001.neosofia.tech` and was registered on a UDM Pro gateway using the Unifi control interface. This DNS entry will only be usable inside the network the Proxmox instance is running on.
4. Navigate to the `System => Certificates` menu on the PVE node you wish to register. NOTE: if you created a staging account in step #2, use it first to confirm everything is configured correctly, then switch to the production account (using the edit link) to issue the final certificate. Add a new certificate with challenge type `DNS` using the plugin you created in step #2.

Once you finish step #4, the system should reboot, and if you navigate to your newly created DNS entry, the annoying "This site is not secure" browser warnings should go away!

If you want a more visual experience please check out [Trey Does Devops](https://www.youtube.com/@treydoesdevops) YouTube [video](https://www.youtube.com/watch?v=CDmklu67nSU) where he walks through this process with his Cloudflare and Pi-Hole setup.


### Gotchas

Below are some common problems that can be encountered while going through the procedure above.

* If you see a permission error in step 4, it could mean that your API token was correct but did not have enough permissions to create the needed TXT record to do DNS confirmation. Check API token permissions and try again after adjusting.
* If you cannot access your server via your local DNS entry but can resolve it with `nslookup` in a terminal, you may have multiple DNS resolvers (e.g. using a VPN). Because of the way DNS resolution works, if multiple resolvers are present, system commands like ping and your web browser will pick the first DNSSEC server. This means if your local DNS does not support DNSSEC, then you may be able to do a `nslookup` but not ping or browse to the URL. 



## Future

These instructions are based on a single machine setup. In the future, we will expand these instructions to include 
 * Setting up a 3-5 node HA cluster
 * Rolling rebuilds for a single node in a HA cluster in a single region
 * Managing multiple clusters across multiple geographic regions
 
## TODOs

 * Setup FW rules for zone (local,region,global, and admin) segmentation. VMs on the local net can see the admin GW address right now.
