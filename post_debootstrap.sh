#!/bin/bash

set -e
cd /root

src_dir=$(dirname "{BASH_SOURCE[0]}")
zfs_prereqs="${src_dir}/zfs_prerequisites.sh"
if ! [ -x "$zfs_prereqs" ]; then
    echo "Missing prerequisites script"
    exit 1
fi

if [ $# -lt 1 ]; then
    echo "Usage: $0 pool_name [mirror]"
    exit 1
fi

pool_name="$1"
if [ -z "$pool_name" ]; then
    echo "Invalid pool name"
    exit 1
fi

mirror="$2"
[ -n "$mirror" ] || mirror='http://debian.c3sl.ufpr.br/debian'

###

mkdir -p /boot
(mount | grep -q '/boot ') || mount /boot

mkdir -p /boot/efi
(mount | grep -q '/boot/efi ') || mount /boot/efi

export LANG=en_US.UTF-8
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y locales

sed_uncomment() {
    local search="$1"; shift
    sed -e "$search"'s/^# *//' "$@" 
}

sed_uncomment "/${LANG}/" -i /etc/locale.gen
locale-gen

# Fix base repos

sed -i -e 's/main$/main contrib non-free/' \
 -e "s#http://http\.debian\.net/debian#${mirror}#" /etc/apt/sources.list

# Add backports if needed
if ! [ -f /etc/apt/sources.list.d/wheezy-backports.list ]; then
    cat > /etc/apt/sources.list.d/wheezy-backports.list <<EOF
deb ${mirror} wheezy-backports main contrib non-free
deb-src ${mirror} wheezy-backports main contrib non-free
EOF
fi

apt-get update

# Install new kernel before ZFS so module is correctly built
apt-get install -t wheezy-backports -y linux-{image,headers}-amd64

if ! "$zfs_prereqs"; then
    echo "ZFS prereqs failed"
    exit 1
fi

# Install base packages

tasksel install standard ssh-server
apt-get install -y vim

# Install GRUB

apt-get install -y grub-efi-amd64 zfs-initramfs

# Update grub configuration

extract_value() {
    sed -e 's/^[^=]*=//' 
}

unquote() {
    sed -e 's/^"//' -e 's/"$//'
}

cmdline=$(grep '^GRUB_CMDLINE_LINUX=' /etc/default/grub | head -n1 | extract_value)

if [ $? -ne 0 ]; then
    echo "Failed to parse cmdline from /etc/default/grub"
    exit 1
fi

cmdline=$(echo "$cmdline" | unquote)
old_cmdline="$cmdline"

if [[ $cmdline != *bootfs=* ]]; then
    bootfs=$(zpool get bootfs "${pool_name}" | tail -n1 | awk '{ print $3 }')
    if [ $? -ne 0 ]; then
        echo "Failed to read bootfs from zpool"
        exit 1
    fi

    cmdline="rpool=${pool_name} bootfs=${bootfs} ${cmdline}"
fi

if [[ $cmdline != *boot=zfs* ]]; then
    cmdline="boot=zfs ${cmdline}"
fi

if [ "$cmdline" != "$old_cmdline" ]; then
    cmdline="GRUB_CMDLINE_LINUX=\"${cmdline}\""
    sed -i -e "s#^GRUB_CMDLINE_LINUX=.*#${cmdline}#" /etc/default/grub
fi

grub-install --target=x86_64-efi --efi-directory=/boot/efi
update-grub