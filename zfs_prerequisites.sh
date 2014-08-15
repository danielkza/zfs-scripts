#!/bin/bash

set -e

# Add ZFS repo

APT_GET_INSTALL='apt-get install -y --no-install-suggests --no-install-recommends'

os_codename=$(lsb_release -s -c)

case "$os_codename" in
wheezy|jessie) debian=1 ;;
trusty) ubuntu=1 ;;
*)
    echo "Error: Unsupported OS codename ${release}" >&2
    exit 1
esac 

mirror="$1"

export DEBIAN_FRONTEND=noninteractive

if (( debian )); then
    if [[ -z "$mirror" ]]; then
        mirror='http://cdn.debian.net/debian'
    fi

    zfs_url=\
"http://archive.zfsonlinux.org/debian/pool/main/z/zfsonlinux/zfsonlinux_2~${os_codename}_all.deb"

    wget "$zfs_url" -O /tmp/zfsonlinux.deb
    dpkg -i /tmp/zfsonlinux.deb
    
    # Add backports for udev to fix /dev/disk/by-partuuid
    if [[ "$os_codename" == "wheezy" ]]; then
        backports_list="/etc/apt/sources.list.d/wheezy-backports.list"
        if ! [ -f "$backports_list" ]; then
            cat > "$backports_list" <<EOF
deb ${mirror} wheezy-backports main contrib non-free
deb-src ${mirror} wheezy-backports main contrib non-free
EOF
    fi
        apt-get update
        $APT_GET_INSTALL -t wheezy-backports udev

        udevadm trigger
        udevadm settle
    fi
elif (( ubuntu )); then
    apt-get update
    $APT_GET_INSTALL software-properties-common

    apt-add-repository -y ppa:zfs-native/stable
    apt-get update
fi

$APT_GET_INSTALL mdadm gdisk dosfstools e2fsprogs

if (( debian )); then
    $APT_GET_INSTALL linux-{image,headers}-amd64 debian-zfs
elif (( ubuntu )); then
    $APT_GET_INSTALL spl-dkms zfs-dkms linux-{image,headers}-generic ubuntu-zfs
fi

# Check ZFS

modprobe zfs
if dmesg | grep -q 'ZFS:'; then
    echo 'ZFS OK.'
else
    echo 'ZFS module not running, check errors.'
    exit 1
fi