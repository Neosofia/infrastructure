# Setup our host-level backup and restoration solution
MISSING_REAR_VARS=$(get_missing_vars "REAR_BACKUP_DEVICE" "${REAR_BACKUP_DEVICE:-}")

if [[ -n "$MISSING_REAR_VARS" ]]; then
  echo "WARNING: Skipping REAR setup. Missing required variables: $MISSING_REAR_VARS"
else
  echo "Setting up REAR"

  apt-get install rear -y

  cat <<EOF >> /etc/rear/local.conf
USB_DEVICE_FILESYSTEM=ext4

OUTPUT=USB

BACKUP=NETFS
BACKUP_URL=usb:///dev/disk/by-label/REAR-000
BACKUP_TYPE=incremental
USB_SUFFIX="backups"
FULLBACKUPDAY=(Sat)
USB_RETAIN_BACKUP_NR=1

GRUB2_DEFAULT_BOOT="rear_secure_boot"
GRUB2_TIMEOUT=5
KERNEL_CMDLINE="unattended"

USER_INPUT_TIMEOUT=3
EOF

  # Format the disk and make our first baseline backup
  # TBD: Don't hardcode host OS backups device
  echo Yes | rear format $REAR_BACKUP_DEVICE
  rear -v mkbackup


  # Need to rethink how we're going to handle backups and restores with REAR.
  # Also need to consider the integration with PBS and how we partition the backup disk.
  # TBD: need to lookup efi boot manager device vs hardcode 0000B
  #cat <<EOF >> /etc/crontab
#15  2    * * *   root    rear -v mkbackup; efibootmgr -n 000B; systemctl reboot
#EOF


fi

