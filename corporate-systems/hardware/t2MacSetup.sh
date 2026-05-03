CODENAME=trixie

# Add the T2 Mac support package repository (https://github.com/AdityaGarg8/t2-ubuntu-repo)
# Provides hardware support packages (audio config, firmware scripts, fan control, etc.)
# Note: we use the pve-edge-kernel-t2 repo below for the kernel itself, not linux-t2 from here.

# Import the GPG signing key for the repository
curl -s --compressed \
    "https://adityagarg8.github.io/t2-ubuntu-repo/KEY.gpg" \
    | gpg --dearmor \
    | tee /etc/apt/trusted.gpg.d/t2-ubuntu-repo.gpg >/dev/null

# Fetch the base sources list entry
curl -s --compressed \
    -o /etc/apt/sources.list.d/t2.list \
    "https://adityagarg8.github.io/t2-ubuntu-repo/t2.list"

# Append the codename-specific release entry with signing key reference
DEB_URL="https://github.com/AdityaGarg8/t2-ubuntu-repo/releases/download/${CODENAME}"
echo "deb [signed-by=/etc/apt/trusted.gpg.d/t2-ubuntu-repo.gpg] ${DEB_URL} ./" \
    | sudo tee -a /etc/apt/sources.list.d/t2.list

apt update

# Install fan control daemon - without this, fans run at 100% constantly on T2 Macs
apt-get install -y t2fanrd

# Install the Proxmox-patched T2 kernel from https://github.com/AdityaGarg8/pve-edge-kernel-t2
# This is a PVE kernel (same base as proxmox-kernel-*-pve) with T2 Mac patches applied on top,
# giving us proper PVE kernel ABI for ZFS/KVM modules alongside T2 hardware support.
# Check the releases page for the latest version tag before updating the variable below.
PVE_T2_VERSION="6.17.13-2"
PVE_T2_RELEASE_TAG="v${PVE_T2_VERSION}-t2-1"
PVE_T2_BASE_URL="https://github.com/AdityaGarg8/pve-edge-kernel-t2/releases/download/${PVE_T2_RELEASE_TAG}"
PVE_T2_DEB="proxmox-kernel-${PVE_T2_VERSION}-pve-t2_${PVE_T2_VERSION}_amd64.deb"

# SHA256 of proxmox-kernel-6.17.13-2-pve-t2_6.17.13-2_amd64.deb from release v6.17.13-2-t2-1
# Update this hash whenever PVE_T2_VERSION or PVE_T2_RELEASE_TAG changes.
# To regenerate: curl -sLo /tmp/${PVE_T2_DEB} "${PVE_T2_BASE_URL}/${PVE_T2_DEB}" && sha256sum /tmp/${PVE_T2_DEB} && rm /tmp/${PVE_T2_DEB}
PVE_T2_SHA256="bf6b2525d37d4237220f15ec3276a67f256e2574fccae17bc4714bdc80129fcb"

curl -LO "${PVE_T2_BASE_URL}/${PVE_T2_DEB}"
echo "${PVE_T2_SHA256}  ${PVE_T2_DEB}" | sha256sum -c || { echo "ERROR: SHA256 mismatch — aborting kernel install"; rm -f "${PVE_T2_DEB}"; exit 1; }
dpkg -i "${PVE_T2_DEB}"
rm "${PVE_T2_DEB}"

proxmox-boot-tool kernel pin "${PVE_T2_VERSION}-pve-t2" && proxmox-boot-tool refresh && reboot