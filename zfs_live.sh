#!/bin/bash

set -e
cd /root

# Add ZFS repo

wget -N http://archive.zfsonlinux.org/debian/pool/main/z/zfsonlinux/zfsonlinux_2%7Ewheezy_all.deb
dpkg -i zfsonlinux_2~wheezy_all.deb

apt-get update

# Install base packages

apt-get install firmware-linux-nonfree linux-headers-amd64 \
  linux-{image,headers}-3.12-0.bpo.1-amd64 \
  gdisk dosfstools e2fsprogs

apt-get install debian-zfs

# Check ZFS

modprobe zfs
if dmesg | grep -q 'ZFS:'; then
	echo 'ZFS OK.'
else
	echo 'ZFS module not running, check errors.'
	exit 1
fi






