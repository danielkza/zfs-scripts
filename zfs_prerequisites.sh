#!/bin/bash

set -e

# Add ZFS repo

os_codename=$(lsb_release -s -c)

case "$os_codename" in
wheezy) ;;
trusty) ;;
*)
    echo "Error: Unsupported OS codename ${release}" >&2
    exit 1
esac 

mirror="$1"

export DEBIAN_FRONTEND=noninteractive

case "$os_codename" in)
wheezy)
    if [[ -z "$mirror" ]]; then
        mirror='http://cdn.debian.net/debian'
    fi

    wget -N 'http://archive.zfsonlinux.org/debian/pool/main/z/zfsonlinux/zfsonlinux_2%7Ewheezy_all.deb' \
     -O /tmp/zfsonlinux.deb
    dpkg -i /tmp/zfsonlinux.deb
    
    # Add backports for udev
    if ! [ -f /etc/apt/sources.list.d/wheezy-backports.list ]; then
        cat > /etc/apt/sources.list.d/wheezy-backports.list <<EOF
deb ${mirror} wheezy-backports main contrib non-free
deb-src ${mirror} wheezy-backports main contrib non-free
EOF
    fi

    apt-get update
    apt-get install -y -t wheezy-backports udev

    udevadm trigger
    udevadm settle
;;
trusty)
    apt-add-repository -y ppa:zfs-native/stable
    apt-get update
esac

apt-get install -y linux-{image,headers}-amd64 \
 mdadm gdisk dosfstools e2fsprogs

case "$os_release" in
wheezy) apt-get install -y debian-zfs ;;
trusty) apt-get install -y ubuntu-zfs ;;
esac

# Check ZFS

modprobe zfs
if dmesg | grep -q 'ZFS:'; then
    echo 'ZFS OK.'
else
    echo 'ZFS module not running, check errors.'
    exit 1
fi