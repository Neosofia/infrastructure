# Point to main Debian Repos
echo "Updating Proxmox VE Sources"


echo 'APT::Get::Update::SourceListWarnings::NonFreeFirmware "false";' >/etc/apt/apt.conf.d/no-trixie-firmware.conf

if [[ -z "${PVE_KEY}" ]]; then

  echo "Disabling 'pve-enterprise' repository"
  cat <<QED >/etc/apt/sources.list.d/pve-enterprise.sources
Types: deb
URIs: https://enterprise.proxmox.com/debian/pve
Suites: trixie
Components: pve-enterprise
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Enabled: false
QED

  echo "Enabling 'pve-no-subscription' repository"
  cat <<QED >/etc/apt/sources.list.d/proxmox.sources
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg

Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-test
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Enabled: false
QED

  cat <<QED >/etc/apt/sources.list.d/ceph.sources
Types: deb
URIs: https://enterprise.proxmox.com/debian/ceph-squid
Suites: trixie
Components: enterprise
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Enabled: false
QED


  # Get rid of nag
  echo "Disabling subscription nag"
  echo "DPkg::Post-Invoke { \"dpkg -V proxmox-widget-toolkit | grep -q '/proxmoxlib\.js$'; if [ \$? -eq 1 ]; then { echo 'Removing subscription nag from UI...'; sed -i '/.*data\.status.*{/{s/\!//;s/active/NoMoreNagging/}' /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js; }; fi\"; };" >/etc/apt/apt.conf.d/no-nag-script
  apt --reinstall install proxmox-widget-toolkit &>/dev/null
  echo "Disabled subscription nag (Delete browser cache)"
else
  pvesubscription set ${PVE_KEY}
  pvesubscription update -force
  pvesubscription get
fi

# Grab latests packages
# TBD: Restrict updates to pins?
echo "Starting apt-get updates"
apt-get update
apt-get -y dist-upgrade

apt-get install -y btop nvtop librocm-smi64-1


# Blank the physical console after 1 minute of inactivity.
# consoleblank=60 is a generic kernel parameter safe for any machine.
if ! grep -q "consoleblank" /etc/default/grub; then
  sed -i 's/^GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 consoleblank=60"/' /etc/default/grub
  update-grub
fi


# EAR Setup using Clevis and LUKS
# Checking requirements for EAR/LUKS setup
MISSING_EAR_VARS=$(get_missing_vars "PBS_BACKUP_DEVICE" "${PBS_BACKUP_DEVICE:-}" "EAR_PASSPHRASE" "${EAR_PASSPHRASE:-}")

if [[ -n "$MISSING_EAR_VARS" ]]; then
  echo "WARNING: Skipping EAR/LUKS setup. Missing required variables: $MISSING_EAR_VARS"
else
  # TBD: Do we still need clevis for systemd-cryptenroll?
  apt-get install clevis clevis-tpm2 clevis-luks -y

  # Use the commented commands below to cleanup the disk and start over
  #
  # !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  # !!! WARNING: these commands are hardcoded to /dev/sda and will wipe the disk
  # !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  #
  # cryptsetup close secbackups
  # echo "YES" | cryptsetup erase /dev/sda1
  # wipefs -a /dev/sda
  # echo 'type=83' | sfdisk /dev/sda 

  cryptsetup luksFormat /dev/${PBS_BACKUP_DEVICE} <<< "${EAR_PASSPHRASE}"
  cryptsetup open /dev/${PBS_BACKUP_DEVICE} secbackups <<< "${EAR_PASSPHRASE}"
  mkfs.ext4 /dev/mapper/secbackups 
  systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/${PBS_BACKUP_DEVICE} <<< "${EAR_PASSPHRASE}"

  export PBS_BACKUP_UUID=`blkid -s UUID -o value /dev/${PBS_BACKUP_DEVICE}`

  cat <<QED > /etc/crypttab
secbackups /dev/disk/by-uuid/${PBS_BACKUP_UUID} none tpm2-device=auto" >> /etc/crypttab'
QED

  update-initramfs -u

  # Now mount the LUKS device (secbackups) and add it to Proxmox VE for backups and ISOs
  echo "setting up PBS backups and ISOs mount point"
  mkdir -p /mnt/backups
  cat <<QED >> /etc/fstab
/dev/mapper/secbackups /mnt/backups ext4 rw,relatime 0 0 
QED
  systemctl daemon-reload
  mount /mnt/backups

  pvesm add dir backups \
          --path /mnt/backups \
          --is_mountpoint yes \
          --content backup,iso
fi

