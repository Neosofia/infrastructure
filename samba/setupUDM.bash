#!/usr/bin/env bash
#
# Samba share on a UDM Pro Max, consumed by a Proxmox host via CIFS, then
# bind-mounted into an LXC container running a media server and a scheduled
# downloader job.
#
# Lessons learned the hard way (April 2026):
#
# - UniFiOS 4.x ships NO kernel nfsd and no podman. NFS server on the UDM is
#   not an option without replacing UniFiOS. CIFS is the only path.
# - The UDM has nightly internal activity (lease breaks, smbd churn) around
#   02:00 that can drop the SMB session for several minutes. The Proxmox
#   CIFS client must be configured to survive that, or it gets stuck in a
#   reconnect loop for hours.
# - Any client that writes through temp files (`.__smb0001`-style hidden
#   in-flight files) with WRONLY + LEASE will leave zombie handles on the
#   server if it crashes AND the CIFS client loses its handles. The server
#   then keeps those leases alive indefinitely. Every subsequent run
#   collides with the zombie leases and hangs on lock acquisition -- which
#   presents as "/mnt/media is locked up". `nobrl` on the client prevents
#   this class of failure. If you ever see it again, clear the zombies on
#   the UDM with `smbcontrol smbd close-share "UDM Shared"`.

set -euo pipefail

# ---------------------------------------------------------------------------
# UDM Pro Max: Samba server
# ---------------------------------------------------------------------------
# Single drive in slot 1, shared publicly on the LAN (guest-readable).

sudo apt update && sudo apt install -y samba
sudo systemctl restart smbd nmbd

cat <<QED >> /etc/samba/smb.conf
[global]
    guest account = nobody

[UDM Shared]
    path = /volume1/shared
    browsable = yes
    guest ok = yes
    writable = yes
    create mask = 0666
    directory mask = 0777
QED

sudo systemctl restart smbd nmbd


# ---------------------------------------------------------------------------
# Proxmox host: CIFS client /etc/fstab entry
# ---------------------------------------------------------------------------
# The only fstab line you should be running on the pve host:
#
# //192.168.3.1/UDM\040Shared/media /mnt/media cifs guest,rw,vers=3.1.1,dir_mode=0777,file_mode=0777,iocharset=utf8,_netdev,nofail,x-systemd.mount-timeout=60,x-systemd.automount,x-systemd.idle-timeout=0,soft,retrans=2,echo_interval=10,resilienthandles,handletimeout=60000,noserverino,nobrl,mfsymlinks 0 0
#
# Why each option matters:
#   vers=3.1.1          Pin the dialect. Without this the kernel occasionally
#                       negotiates down and fails to reconnect cleanly.
#   x-systemd.automount Autofs layer so LXC bind mounts survive CIFS drops
#                       without stopping the container.
#   x-systemd.idle-timeout=0  Never unmount when idle.
#   soft,retrans=2      Return EIO quickly on failure instead of blocking
#                       forever. (Swap for `hard` if soft still leaves
#                       pinned dentries -- hard often recovers more cleanly.)
#   echo_interval=10    Keepalive every 10s. Default is 60s, which is too
#                       long: a dead TCP session is noticed only on the next
#                       I/O, by which time handles are already stale.
#   resilienthandles    Server preserves open handles across brief blips.
#   handletimeout=60000 Server reaps orphaned handles after 60s instead of
#                       holding them for days (see zombie-lease note above).
#   noserverino         Avoid inode-number collisions that confuse rsync and
#                       other tools when the server recycles inodes.
#   nobrl               Disable byte-range locks. SQLite and most media
#                       workloads do not need them on a single-writer share,
#                       and they are the #1 cause of "mount is locked" hangs.
#   mfsymlinks          Allow clients and postprocessors to create symlinks
#                       instead of returning EOPNOTSUPP.
#
# Proxmox bind mount to the media LXC (cid 103):
#   pct set 103 -mp0 /mnt/media,mp=/mnt/media,backup=0


# ---------------------------------------------------------------------------
# Proxmox host: CIFS watchdog (INSTALLED -- belt and suspenders)
# ---------------------------------------------------------------------------
# Pokes /mnt/media every minute with a 10s timeout. On failure, force+lazy
# unmounts so x-systemd.automount can remount on next access. Silent when
# healthy; only logs when it has to act.
#
# cat >/usr/local/sbin/cifs-watchdog.sh <<'EOS'
# #!/bin/bash
# set -u
# MP=/mnt/media
# if ! timeout 10 stat -f "$MP" >/dev/null 2>&1; then
#   logger -t cifs-watchdog "stat on $MP failed; force+lazy unmount"
#   umount -f -l "$MP" || true
# fi
# EOS
# chmod +x /usr/local/sbin/cifs-watchdog.sh
#
# cat >/etc/systemd/system/cifs-watchdog.service <<'EOS'
# [Unit]
# Description=CIFS /mnt/media health watchdog
# [Service]
# Type=oneshot
# ExecStart=/usr/local/sbin/cifs-watchdog.sh
# EOS
#
# cat >/etc/systemd/system/cifs-watchdog.timer <<'EOS'
# [Unit]
# Description=Run CIFS watchdog every minute
# [Timer]
# OnBootSec=2min
# OnUnitActiveSec=1min
# AccuracySec=15s
# [Install]
# WantedBy=timers.target
# EOS
# systemctl daemon-reload
# systemctl enable --now cifs-watchdog.timer


# ---------------------------------------------------------------------------
# Proxmox host: LXC shutdown drop-in (optional, for cid 103)
# ---------------------------------------------------------------------------
# When CIFS is in a bad state, processes holding open files enter D-state
# (uninterruptible sleep) and cannot be killed by SIGTERM/SIGKILL. Force+lazy
# unmount of /mnt/media first sends EIO to all blocked I/O, making them
# killable. TimeoutStopSec=30 caps the worst-case wait vs the default 120s.
#
# mkdir -p /etc/systemd/system/pve-container@103.service.d/
# printf '[Service]\nExecStop=/bin/umount -f -l /mnt/media\nTimeoutStopSec=30\n' \
#   > /etc/systemd/system/pve-container@103.service.d/override.conf
# systemctl daemon-reload


# ---------------------------------------------------------------------------
# Debug cheat sheet
# ---------------------------------------------------------------------------
#
# ON THE UDM (Samba server) -------------------------------------------------
#
#   # Active SMB sessions -- one line per client:
#   smbstatus -b
#
#   # Every currently open file / lock on the server. Look for dates >1 day
#   # old with LEASE(RWH) -- those are zombie handles from crashed clients.
#   smbstatus -L | head -40
#
#   # Per-client connection counts in the last hour (find chatty clients):
#   journalctl --since "1 hour ago" -u smbd --no-pager 2>/dev/null | \
#     grep -oE 'from [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort | uniq -c | sort -rn
#
#   # Kick everyone off the share so they reconnect fresh (clears zombie
#   # leases). Clients reconnect automatically within seconds.
#   smbcontrol smbd close-share "UDM Shared"
#
#   # What is actually listening on 445 and who is connected right now:
#   ss -tnp 'sport = :445' | awk 'NR>1 {print $5}' | sed 's/:.*//' | sort | uniq -c | sort -rn
#
#   # Nightly maintenance check (look for unexpected activity around 02:00):
#   systemctl list-timers --all | sort -k2
#   journalctl --since "2 hours ago" --until "1 hour ago" --no-pager | head -80
#
# ON THE PROXMOX HOST (CIFS client) -----------------------------------------
#
#   # Verify the mount actually picked up our options (look for nobrl,
#   # echo_interval=10, resilienthandles, handletimeout=60000, mfsymlinks):
#   mount | grep /mnt/media
#
#   # fstab sanity: one line, exactly 6 fields:
#   awk '/media/ {print NR": "NF" fields"; print}' /etc/fstab
#
#   # CIFS kernel state (server, dialect, active requests, reconnect count):
#   cat /proc/fs/cifs/DebugData | head -40
#
#   # CIFS events -- the canary for UDM blackouts. "has not responded in N
#   # seconds. Reconnecting..." means the UDM dropped the session; one or
#   # two is normal, a 3-hour storm is a real outage.
#   dmesg -T | grep -iE 'cifs|smb' | tail -20
#
#   # Did the watchdog fire? Empty = healthy. Entries = mount was hung and
#   # the watchdog force-unmounted it.
#   journalctl -t cifs-watchdog --since yesterday --no-pager
#   systemctl list-timers cifs-watchdog.timer
#
#   # Is the share reachable right now, without risking a hang?
#   timeout 5 stat -f /mnt/media && echo OK || echo HUNG
#
#   # Clean recovery when the mount is wedged (do this BEFORE rebooting):
#   systemctl stop mnt-media.automount mnt-media.mount 2>/dev/null
#   umount -f -l /mnt/media
#   systemctl start mnt-media.automount
#   ls /mnt/media >/dev/null   # triggers remount
#
# IN THE LXC CONTAINER (cid 103) --------------------------------------------
#
#   # From the pve host, poke the container's view of the share:
#   pct exec 103 -- stat -f /mnt/media
#   pct exec 103 -- ls /mnt/media | head
#
#   # "Remote address changed" from inside the container means the host
#   # remounted CIFS but the container's bind mount still references the
#   # old superblock. Fix:
#   pct stop 103 && pct start 103
#   # If a process is stuck in D-state on dead CIFS I/O:
#   pct stop 103 --force 1 --timeout 30
#
# DIAGNOSING SCHEDULED-JOB "failed to write" ERRORS -------------------------
#
#   # 99% of the time this is CIFS lease contention, not the app. Check:
#   #   1. On UDM: smbstatus -L | head -40
#   #      Any LEASE(RWH) entry older than a day is a zombie from a crashed
#   #      prior run. Clear with `smbcontrol smbd close-share "UDM Shared"`.
#   #   2. On pve: dmesg -T | grep -i cifs | tail
#   #      If you see recent "has not responded" lines, the UDM had a blip
#   #      and the watchdog should have recovered it. If it didn't, run
#   #      the manual unmount recovery above.
