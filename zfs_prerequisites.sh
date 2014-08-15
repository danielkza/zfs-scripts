#!/bin/bash

set -e

# Add ZFS repo

APT_GET_INSTALL='apt-get install -y --no-install-recommends --no-install-suggests'

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
    # We need the grub and zfs-initramfs packages from Wheezy, at least for now.
    # But pin everything we don't need away so it doesn't interfere with the 
    # Ubuntu packages.

    zfs_url=\
"http://archive.zfsonlinux.org/debian/pool/main/z/zfsonlinux/zfsonlinux_2~wheezy_all.deb"

    wget "$zfs_url" -O /tmp/zfsonlinux.deb
    dpkg -i /tmp/zfsonlinux.deb

    cat > '/etc/apt/preferences.d/pin-zfsonlinux' <<EOF
Package: *
Pin: release o=archive.zfsonlinux.org
Pin-Priority: 450

Package: *grub* zfs-initramfs
Pin: release o=archive.zfsonlinux.org
Pin-Priority: 1002
EOF
    apt-get update
    $APT_GET_INSTALL software-properties-common

    apt-add-repository -y ppa:zfs-native/stable
    apt-get update
fi

# Install tools
$APT_GET_INSTALL mdadm gdisk dosfstools e2fsprogs

# Install kernel and ZFS
if (( debian )); then
    $APT_GET_INSTALL linux-{image,headers}-amd64 debian-zfs
elif (( ubuntu )); then
    $APT_GET_INSTALL linux-{image,headers}-generic spl-dkms zfs-dkms ubuntu-zfs
fi

# Check ZFS

modprobe zfs
if dmesg | grep -q 'ZFS:'; then
    echo 'ZFS OK.'
else
    echo 'ZFS module not running, check errors.'
    exit 1
fi