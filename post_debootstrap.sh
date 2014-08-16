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

if (( ubuntu )); then
    locale-gen en_US.UTF-8
else
    locale-gen
fi

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

if [[ -f /etc/mdadm/mdadm.conf && -f /var/lib/mdadm/CONF-UNCHECKED ]]; then
    rm -f /var/lib/mdadm/CONF-UNCHECKED
fi

# GRUB

grub-install --target=x86_64-efi --efi-directory=/boot/efi
update-grub

# Install base packages

$APT_GET_INSTALL tasksel
for task in standard ssh-server; do
    tasksel install "$task"
done
