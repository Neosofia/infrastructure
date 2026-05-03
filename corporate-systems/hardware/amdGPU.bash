#!/usr/bin/env bash
# AMD GPU passthrough to unprivileged Plex LXC on Proxmox 9
# Tested On: iMac (2019), i9-10910 (no iGPU), AMD Radeon Pro 5700 XT (Navi 10) after following the T2 Mac setup instructions in t2MacSetup.sh to get a compatible kernel and hardware support.
# Goal: enable hardware-accelerated transcoding in Plex via /dev/dri (VAAPI)
# 

if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 <lxc-id>" >&2
    echo "  lxc-id: the Proxmox container ID to configure for AMD GPU passthrough" >&2
    exit 1
fi
LXC_ID="$1"

# Resolve the render group GID dynamically — it varies by distro/install order.
# All idmap and subgid values below are derived from this.
RENDER_GID=$(getent group render | cut -d: -f3)
if [[ -z "${RENDER_GID}" ]]; then
    echo "Error: render group not found on host" >&2
    exit 1
fi
RENDER_GID_NEXT=$((RENDER_GID + 1))
RENDER_GID_NEXT_HOST=$((RENDER_GID + 100001))
RENDER_GID_NEXT_COUNT=$((65536 - RENDER_GID - 1))

# 1. Verify GPU is detected and check which driver is in use. The i9-10910 has no integrated GPU,
#    so only the AMD card is available. We need the amdgpu kernel module to create the
#    /dev/dri/renderD128 render node that Plex uses.
lspci -k -s 03:00.0
ls -la /dev/dri/
lsmod | grep amdgpu

# 2. Load the amdgpu module and make it persistent across reboots. Without this,
#    /dev/dri/renderD128 does not exist and hardware acceleration is impossible.
modprobe amdgpu
echo "amdgpu" > /etc/modules-load.d/amdgpu.conf

# Remove amdgpu from the blacklist if present (Proxmox sometimes adds it)
sed -i '/^blacklist amdgpu/d' /etc/modprobe.d/blacklist.conf
update-initramfs -u

# Verify renderD128 now exists
ls -la /dev/dri/

# 3. Confirm the render group GID resolved correctly.
echo "render GID: ${RENDER_GID}"

# 4. Allow the unprivileged LXC to access the AMD GPU devices by mapping the host render GID into
#    the container. Without this, the container sees the render node as owned by "nogroup"
#    and cannot open it.
echo "root:${RENDER_GID}:1" >> /etc/subgid

# 5. Update the Plex LXC config to:
#    - Allow cgroup access to card1 (226:1) and renderD128 (226:128)
#    - Bind-mount /dev/dri into the container
#    - Set up GID mappings so the render group is passed through directly while all other
#      GIDs use the default unprivileged mapping offset (100000)
cat >> "/etc/pve/lxc/${LXC_ID}.conf" << EOF
lxc.cgroup2.devices.allow: c 226:1 rwm
lxc.cgroup2.devices.allow: c 226:128 rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.idmap: u 0 100000 65536
lxc.idmap: g 0 100000 ${RENDER_GID}
lxc.idmap: g ${RENDER_GID} ${RENDER_GID} 1
lxc.idmap: g ${RENDER_GID_NEXT} ${RENDER_GID_NEXT_HOST} ${RENDER_GID_NEXT_COUNT}
EOF

# 6. Restart the LXC to apply the new cgroup and mount config.
pct stop "${LXC_ID}" && pct start "${LXC_ID}"
sleep 5 # Wait a few seconds for the container to fully start

# 7. Inside the LXC: create the render group with the same GID as the host so ownership of
#    renderD128 resolves correctly, then add the plex user to render and video groups.
pct exec "${LXC_ID}" -- groupadd -g "${RENDER_GID}" render
pct exec "${LXC_ID}" -- usermod -aG render,video plex

# Confirm /dev/dri is visible inside the container; expected: renderD128 owned by group render
pct exec "${LXC_ID}" -- ls -la /dev/dri/

# Confirm plex user has the render group; expected: groups=...,44(video),993(render)
pct exec "${LXC_ID}" -- id plex

# Restart Plex to pick up the new group membership
pct exec "${LXC_ID}" -- systemctl restart plexmediaserver

# 8. Enable hardware acceleration in Plex:
#    Settings → Transcoder → "Use hardware acceleration when available"
#    Verify GPU usage on the host during transcoding:
#    if the pveSetup.sh script was run then btop should be showing GPU usage to verify.
