#!/bin/sh

# Add ZFS repo

wget -N http://archive.zfsonlinux.org/debian/pool/main/z/zfsonlinux/zfsonlinux_2%7Ewheezy_all.deb
dpkg -i zfsonlinux_2~wheezy_all.deb

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y linux-{image,headers}-amd64 firmware-linux-nonfree  \
 gdisk dosfstools e2fsprogs

apt-get install -y debian-zfs

# Check ZFS

modprobe zfs
if dmesg | grep -q 'ZFS:'; then
    echo 'ZFS OK.'
else
    echo 'ZFS module not running, check errors.'
    exit 1
fi