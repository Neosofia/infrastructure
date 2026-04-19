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
#!/usr/bin/env bash

export TERM=xterm

# set -euo pipefail

REAR_BACKUP_DEVICE="${REAR_BACKUP_DEVICE:-$(lsblk -d -o NAME,ROTA,TRAN | awk '$2 == 1 && $3 != "usb" {print "/dev/"$1}' | head -1)}"

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
ALLOWED_VARS='$ROOT_PW $PVE_INSTALL_TO_DEVICE $PBS_BACKUP_DEVICE $PVE_KEY $EAR_PASSPHRASE'

cat pveSetup.sh | envsubst "$ALLOWED_VARS" >> firstBoot.sh
cat networkingSetup.sh | envsubst "$ALLOWED_VARS" >> firstBoot.sh
cat rearSetup.sh | envsubst "$ALLOWED_VARS" >> firstBoot.sh

echo "reboot" >> firstBoot.sh

chmod 775 firstBoot.sh

MISSING_MEDIA_VARS=$(get_missing_vars "PVE_INSTALL_FROM_DEVICE" "${PVE_INSTALL_FROM_DEVICE:-}" "ROOT_PW" "${ROOT_PW:-}")

if [[ -n "$MISSING_MEDIA_VARS" ]]; then
    echo "First boot script created. Missing variables for media creation: $MISSING_MEDIA_VARS."
    echo "Please set missing variables, review firstBoot.sh, and run it to complete setup if needed."
else
    echo "Preparing Proxmox VE installation media. This will write to ${PVE_INSTALL_FROM_DEVICE} and reboot when complete."
    
    # TBD: Add check for OS
    apt install proxmox-auto-install-assistant -y

    # Pin both the ISO filename and its SHA256 together.
    # Fetching the checksum from the same server that serves the ISO provides no supply chain protection.
    # To update: download the new ISO, run `sha256sum proxmox-ve_X.Y-Z.iso`, and update both values below.
    ISO_NAME="proxmox-ve_9.1-1.iso"
    EXPECTED_HASH="6d8f5afc78c0c66812d7272cde7c8b98be7eb54401ceb045400db05eb5ae6d22"

    if [[ -f "${ISO_NAME}" ]] && [[ "$(sha256sum "${ISO_NAME}" | awk '{print $1}')" == "${EXPECTED_HASH}" ]]; then
        echo "ISO already exists and checksum verified, skipping download."
    else
        [[ -f "${ISO_NAME}" ]] && echo "ISO exists but checksum mismatch, re-downloading..." && rm -f "${ISO_NAME}"
        wget "https://enterprise.proxmox.com/iso/${ISO_NAME}"
        if [[ "$(sha256sum "${ISO_NAME}" | awk '{print $1}')" != "${EXPECTED_HASH}" ]]; then
            echo "Error: Downloaded ISO checksum verification failed!" >&2
            rm -f "${ISO_NAME}"
            exit 1
        fi
        echo "ISO checksum verified."
    fi


    # TBD: make more of this configurable/automated.
    # Note: to use DHCP you may need to disable STP on your switch port and/or set the link speed
    cat << EOF > answer.toml
[global]
keyboard = "en-us"
country = "us"
fqdn = "pve0001.local"
mailto = "server@pve0001.local"
timezone = "UTC"
root_password = "${ROOT_PW}"

[network]
source = "from-dhcp"

# Install to the first nvme device by default
[disk-setup]
filesystem = "ext4"
filter.DEVNAME = "/dev/nvme*n1"

[first-boot]
source = "from-iso"
ordering = "fully-up"
EOF
  
    proxmox-auto-install-assistant prepare-iso "${ISO_NAME}" \
        --fetch-from iso \
        --answer-file answer.toml \
        --on-first-boot firstBoot.sh

    dd bs=1M conv=fdatasync \
      if="./${ISO_NAME%.iso}-auto-from-iso.iso" \
      of="/dev/${PVE_INSTALL_FROM_DEVICE}"
  
    rm "${ISO_NAME%.iso}-auto-from-iso.iso"
fi
