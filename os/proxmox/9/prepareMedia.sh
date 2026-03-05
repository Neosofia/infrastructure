#!/usr/bin/env bash

# Load environment variables through a .env file
set -a; source .env; set +a

set -euo pipefail

# Shared utility to check for missing setup variables
get_missing_vars() {
  local missing=()
  while [[ $# -gt 0 ]]; do
    if [[ -z "$2" ]]; then
      missing+=("$1")
    fi
    shift 2
  done
  echo "${missing[*]}"
}

# Setup first boot script
cat << 'EOF' > firstBoot.sh
# Shared utility to check for missing setup variables after envsubst population
get_missing_vars() {
  local missing=()
  while [[ $# -gt 0 ]]; do
    if [[ -z "$2" ]]; then
      missing+=("$1")
    fi
    shift 2
  done
  echo "${missing[*]}"
}
EOF

# Use explicit variables for envsubst so it doesn't hollow out internal script bash variables
ALLOWED_VARS='$ROOT_PW $WAN_IP $WAN_GW $WAN_DEVICE $PVE_INSTALL_TO_DEVICE $PBS_BACKUP_DEVICE $REAR_BACKUP_DEVICE $PVE_KEY $EAR_PASSPHRASE'

cat pveSetup.sh | envsubst "$ALLOWED_VARS" >> firstBoot.sh
cat networkingSetup.sh | envsubst "$ALLOWED_VARS" >> firstBoot.sh
cat rearSetup.sh | envsubst "$ALLOWED_VARS" >> firstBoot.sh

echo "reboot" >> firstBoot.sh

chmod 775 firstBoot.sh



MISSING_MEDIA_VARS=$(get_missing_vars "PVE_INSTALL_FROM_DEVICE" "${PVE_INSTALL_FROM_DEVICE:-}" "ROOT_PW" "${ROOT_PW:-}" "WAN_IP" "${WAN_IP:-}" "WAN_GW" "${WAN_GW:-}" "WAN_DEVICE" "${WAN_DEVICE:-}" "PVE_INSTALL_TO_DEVICE" "${PVE_INSTALL_TO_DEVICE:-}")

if [[ -n "$MISSING_MEDIA_VARS" ]]; then
    echo "First boot script created. Missing variables for media creation: $MISSING_MEDIA_VARS."
    echo "Please set missing variables, review firstBoot.sh, and run it to complete setup if needed."
else
    echo "Preparing Proxmox VE installation media. This will write to ${PVE_INSTALL_FROM_DEVICE} and reboot when complete."
    
    # TBD: Add check for OS
    apt install proxmox-auto-install-assistant -y

    # Grab the current iso and don't clobber if you've already got it
    wget -nc https://enterprise.proxmox.com/iso/proxmox-ve_9.1-1.iso


    # Build the toml file
    # TBD: Add more env vars with "smart" defaults
    cat << EOF > answer.toml
[global]
keyboard = "en-us"
country = "us"
fqdn = "pve0001.local"
mailto = "server@pve0001.local"
timezone = "UTC"
root_password = "${ROOT_PW}"

[network]
source = "from-answer"
cidr = "${WAN_IP}"
dns = "1.1.1.1"
gateway = "${WAN_GW}"
filter.INTERFACE = "${WAN_DEVICE}"

[disk-setup]
filesystem = "ext4"
disk_list = ["${PVE_INSTALL_TO_DEVICE}"]

[first-boot]
source = "from-iso"
ordering = "fully-up"
EOF
  

  
    proxmox-auto-install-assistant prepare-iso proxmox-ve_9.1-1.iso \
        --fetch-from iso \
        --answer-file answer.toml \
        --on-first-boot firstBoot.sh
    #
    dd bs=1M conv=fdatasync if=./proxmox-ve_9.1-1-auto-from-iso.iso of=/dev/${PVE_INSTALL_FROM_DEVICE}

fi
