echo "Starting PVE networking setup TEST NEW 5"

# Setup for basic DHCP services
apt-get -y install dnsmasq
systemctl disable --now dnsmasq

# Setup "basic" SDN
echo "setting up networking"
cat <<EOF >/etc/pve/sdn/zones.cfg
simple: default
        dhcp dnsmasq
        ipam pve
EOF

pvesh set /cluster/sdn

# TBD: The section below was an attempt at programmatically declaring the networking layout
# for our PVE hosts. This was done as the original setup routine did not use REAR as a full
# system backup, rather it was a full nuke of the host then recreate manually. As PVE 
echo "setup vnets"
cat <<EOF >/etc/pve/sdn/vnets.cfg
vnet: local
        zone default

vnet: region
        zone default

vnet: global
        zone default

vnet: admin
        zone default
EOF

echo "subnets setup"
cat <<EOF >/etc/pve/sdn/subnets.cfg
subnet: default-10.0.0.0-10
        vnet local
        gateway 10.0.0.1
        snat 1

subnet: default-10.64.0.0-10
        vnet region
        gateway 10.64.0.1
        snat 1

subnet: default-10.128.0.0-10
        vnet global
        gateway 10.128.0.1
        snat 1

# No snat for admin subnet as we don't want to allow external access
subnet: default-10.192.0.0-10
        vnet admin
        gateway 10.192.0.1
EOF

echo "firewall setup"
cat <<EOF >/etc/pve/firewall/cluster.fw
[OPTIONS]

enable: 1

[RULES]

GROUP admin_isolation

[group admin_isolation]

# Allow traffic within admin subnet
IN ACCEPT -source 10.192.0.0/10 -dest 10.192.0.0/10
# Block all other inbound traffic from admin subnet
IN DROP -source 10.192.0.0/10

# Allow outbound traffic within admin subnet
OUT ACCEPT -source 10.192.0.0/10 -dest 10.192.0.0/10
# Block all other outbound traffic from admin subnet
OUT DROP -source 10.192.0.0/10

EOF

echo "ipam setup"
cat << EOF > /etc/pve/sdn/pve-ipam-state.json
{"zones":{"default":{"subnets":
{ 
 "10.128.0.0/10":{"ips":{"10.128.0.1":{"gateway":1}}},
 "10.0.0.0/10":{"ips":{"10.0.0.1":{"gateway":1}}}},
 "10.192.0.0/10":{"ips":{"10.192.0.1":{"gateway":1}}},
 "10.64.0.0/10":{"ips":{"10.64.0.1":{"gateway":1}}}
 }},"localsrv":{"subnets":{}}}}
EOF



pvesh set /cluster/sdn

systemctl restart pve-firewall