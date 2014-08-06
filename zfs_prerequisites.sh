#!/bin/bash

set -e
cd /root

# Add ZFS repo

wget -N http://archive.zfsonlinux.org/debian/pool/main/z/zfsonlinux/zfsonlinux_2%7Ewheezy_all.deb
dpkg -i zfsonlinux_2~wheezy_all.deb

# Add backports for udev
if ! [ -f /etc/apt/sources.list.d/wheezy-backports.list ]; then
    cat > /etc/apt/sources.list.d/wheezy-backports.list <<EOF
deb ${mirror} wheezy-backports main contrib non-free
deb-src ${mirror} wheezy-backports main contrib non-free
EOF
fi

export DEBIAN_FRONTEND=noninteractive

apt-get update

# /dev/disk/by-partuuid is broken in Wheezy. Install udev from backports to fix
# that.

apt-get install -y linux-{image,headers}-amd64 \
 gdisk dosfstools e2fsprogs udev/wheezy-backports

udevadm trigger

apt-get install -y debian-zfs

# Check ZFS

modprobe zfs
if dmesg | grep -q 'ZFS:'; then
    echo 'ZFS OK.'
else
    echo 'ZFS module not running, check errors.'
    exit 1
fi