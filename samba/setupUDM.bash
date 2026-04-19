#!/usr/bin/env bash

set -euo pipefail

sudo apt update && sudo apt install -y samba

sudo systemctl restart smbd nmbd

# This is designed for a single drive in the first UDM Pro Max slot and
# the data is fully accessible to everyone on the network as it contains
# publicly available data. 
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

# Fstab entry for Proxmox/Debian server example
# x-systemd.automount creates an autofs layer so LXC bind mounts survive CIFS drops without needing the container stopped.
# x-systemd.idle-timeout=0 prevents systemd from proactively unmounting the share when idle.
# //192.168.3.1/UDM\040Shared/media /mnt/media cifs guest,rw,dir_mode=0777,file_mode=0777,iocharset=utf8,_netdev,nofail,x-systemd.mount-timeout=60,x-systemd.automount,x-systemd.idle-timeout=0,soft,retrans=2 0 0

# Proxmox bind mount on LXC container example for cid 103/plex
# pct set 103 -mp0 /mnt/media,mp=/mnt/media,backup=0

#mkdir -p /etc/systemd/system/pve-container@103.service.d/
#cat <<EOF > /etc/systemd/system/pve-container@103.service.d/override.conf
#[Unit]
#After=mnt-media.automount
#BindsTo=mnt-media.automount
#EOF
#systemctl daemon-reload