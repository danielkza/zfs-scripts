#!/bin/bash

set -e
cd /root

mkdir -p /boot
mount /boot

mkdir -p /boot/efi
mount /boot/efi

src_dir="$(dirname "{BASH_SOURCE[0]}")"
zfs_prereqs="${src_dir}/zfs_prerequisites.sh"
if ! [ -x "$zfs_prereqs" ]; then
    echo "Missing prerequisites script"
    exit 1
fi

export LANG=en_US.UTF-8
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y locales

locale-gen en_US.UTF-8

# Fix base repos

sed -i -e 's/main$/main contrib non-free/' \
 -e 's/http\.debian\.net/sft.if.usp.br/' /etc/apt/sources.list

# Add backports
cat > /etc/apt/sources.list.d/wheezy-backports.list <<'EOF'
deb http://sft.if.usp.br/debian wheezy-backports main contrib non-free
deb-src http://sft.if.usp.br/debian wheezy-backports main contrib non-free
EOF

apt-get update

# Install kernel before ZFS so module is correctly built
apt-get install -y -t wheezy-backports linux-{image,headers}-3.12-0.bpo.1-amd64 

if ! "$zfs_prereqs"; then
    echo "ZFS prereqs failed"
    exit 1
fi

# Install base packages

tasksel install standard ssh-server
apt-get install nano vim

# Install GRUB

apt-get install -y grub-efi-amd64 zfs-initramfs

# Cleanup
umount /boot/efi
umount /boot