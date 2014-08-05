#!/bin/bash

set -e

target="$1"
hostname="$2"
boot_uuid="$3"
efi_uuid="$4"
mirror="$5"

if [ $# -lt 4 ]; then
    echo "Usage: $0 target_path hostname boot_uuid efi_uuid [mirror]"
    exit 1
fi

if ! [ -d "$target" ]; then
    echo "Invalid target"
    exit 1
fi

if [ -z "$hostname" ]; then
    echo "Invalid hostname"
    exit 1
fi

if [ -z "$boot_uuid" ] || ! blkid -t UUID="$boot_uuid"; then
    echo "Invalid boot_uuid"
    exit 1
fi

if [ -z "$efi_uuid" ] || ! blkid -t UUID="$efi_uuid"; then
    echo "Invalid efi_uuid"
    exit 1
fi

[ -n "$mirror" ] || mirror='http://sft.if.usp.br/debian'

export DEBIAN_FRONTEND=noninteractive
apt-get install -y debootstrap

debootstrap --arch=amd64 wheezy "$target" "$mirror"

echo "$hostname" > "${target}/etc/hostname"
sed "s/debian/${hostname}" /etc/hosts > "${target}/etc/hosts"

cat > "${target}/etc/fstab" <<EOF
UUID=${boot_uuid} /boot auto defaults 0 1
UUID=${efi_uuid} /boot/efi auto defaults 0 1
EOF

cat > "${target}/etc/network/interfaces" <<'EOF'
# interfaces(5) file used by ifup(8) and ifdown(8)
auto lo
iface lo inet loopback

auto eth0
allow-hotplug eth0
iface eth0 inet dhcp

auto eth1
allow-hotplug eth1
iface eth1 inet dhcp
EOF

echo 'LANG=en_US.UTF-8' > /etc/default/locale

ln -s /proc/mounts "${target}/etc/mtab"