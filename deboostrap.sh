#!/bin/bash

set -e

mirror='http://sft.if.usp.br/debian'
mount_path=$1
boot_part_uuid=$2
efi_part_uuid=$3
hostname=$4

apt-get install -y debootstrap

mkdir -p "${mount_path}/boot"
mount "UUID=$boot_part_uuid" "${mount_path}/boot"	

mkdir -p "${mount_path}/boot/efi"
mount "UUID=$efi_part_uuid" "${mount_path}/boot/efi"

debootstrap --arch=amd64 wheezy "$mount_path" "$mirror"

echo "$hostname" > "${mount_path}/etc/hostname"

cat > "${mount_path}/etc/fstab" <<EOF
UUID=${boot_part_uuid} /boot auto defaults 0 1
UUID=${efi_part_uuid} /boot/efi auto defaults 0 1
EOF

cat > "${mount_path}/etc/network/interfaces" <<'EOF'
# interfaces(5) file used by ifup(8) and ifdown(8)
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

ln -s /proc/mounts "${mount_path}/etc/mtab" 

mount --bind /dev "${mount_path}/dev"
mount --bind /dev/pts "${mount_path}/dev/pts"
mount --bind /proc "${mount_path}/proc"
mount --bind /sys "${mount_path}/sys"
