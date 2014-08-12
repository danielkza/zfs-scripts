#!/bin/bash

set -e

APT_GET_INSTALL='apt-get install -y --no-install-suggests'

err()
{
    echo 'Error:' "$@" >&2
}

###

src_dir=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")")
zfs_prereqs="${src_dir}/zfs_prerequisites.sh"

if ! [[ -x "$zfs_prereqs" ]]; then
    err "Missing prerequisites script"
    exit 1
fi

os_codename=$(lsb_release -s -c)

case "$os_codename" in
wheezy|jessie) debian=1 ;;
trusty) ubuntu=1 ;;
*)
    err "Unknown OS codename '${os_codename}'"
    exit 1
esac

print_help()
{
    program=$(basename "$0")
    echo "Usage: ${program} [pool_name]" >&2    
}

if [[ "$1" == -h* ]]; then
    print_help
    exit 1
fi

pool_name="$1"

###

old_hostname=$(hostname)
hostname "$(cat /etc/hostname)"
trap "hostname '${old_hostname}'" EXIT

###

mkdir -p /boot
(mount | grep -q '/boot ') || mount /boot

mkdir -p /boot/efi
(mount | grep -q '/boot/efi ') || mount /boot/efi

[[ -n "$LANG" ]] || export LANG=en_US.UTF-8
export DEBIAN_FRONTEND=noninteractive

apt-get update

$APT_GET_INSTALL -y locales
locale-gen en_US.UTF-8 UTF-8
locale-gen

if [[ "$os_codename" == "wheezy" ]]; then
    # Install kernels before ZFS so module is correctly built
    $APT_GET_INSTALL linux-{image,headers}-amd64

    # Needed by 3.14
    $APT_GET_INSTALL perl-modules
    $APT_GET_INSTALL -t wheezy-backports linux-{image,headers}-amd64
fi

if ! "$zfs_prereqs"; then
    echo "ZFS prereqs failed"
    exit 1
fi

# Autodetect pool if needed
if [[ -z "$pool_name" ]]; then
    zpool list -H -o name 2>/dev/null | read -ra zpools

    if (( ${#zpools[@]} > 1 )); then
        err "more than one zpool mounted, specify which to use manually" >&2
        exit 1
    fi

    pool_name="${zpools[0]}"
fi

# Install GRUB

$APT_GET_INSTALL grub-efi-amd64 zfs-initramfs

# Make sure mdadm configuration is used

if [ -f /etc/mdadm/mdadm.conf ] && [ -f /var/lib/mdadm/CONF-UNCHECKED ]; then
    rm -f /var/lib/mdadm/CONF-UNCHECKED
fi

# Update grub configuration

extract_value() {
    sed -e 's/^[^=]*=//' 
}

unquote() {
    sed -e 's/^"//' -e 's/"$//'
}

cmdline=$(grep '^GRUB_CMDLINE_LINUX=' /etc/default/grub | head -n1 | extract_value)

if (( $? != 0 )); then
    err "Failed to parse cmdline from /etc/default/grub"
    exit 1
fi

cmdline=$(echo "$cmdline" | unquote)
old_cmdline="$cmdline"

if [[ "$cmdline" != *bootfs=* ]]; then
    bootfs=$(zpool get bootfs "${pool_name}" | tail -n1 | awk '{ print $3 }')
    if (( $? != 0 )); then
        err "Failed to read bootfs from zpool"
        exit 1
    fi

    cmdline="rpool=${pool_name} bootfs=${bootfs} ${cmdline}"
fi

if [[ "$cmdline" != *boot=zfs* ]]; then
    cmdline="boot=zfs ${cmdline}"
fi

if [[ "$cmdline" != "$old_cmdline" ]]; then
    cmdline="GRUB_CMDLINE_LINUX=\"${cmdline}\""
    sed -i -e "s#^GRUB_CMDLINE_LINUX=.*#${cmdline}#" /etc/default/grub
fi

grub-install --target=x86_64-efi --efi-directory=/boot/efi
update-grub

# Install base packages

tasksel install standard ssh-server
apt-get install -y vim

# Just to be sure

update-initramfs -u -k all
