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

if [ -f /etc/mdadm/mdadm.conf ] && [ -f /var/lib/mdadm/CONF-UNCHECKED ]; then
    rm -f /var/lib/mdadm/CONF-UNCHECKED
fi

# Update grub configuration

shell_var_replace()
{
    local option="$1" value="$2" file="$3"
    sed -i -e \
"s|^\\([[:blank:]]*\\)${option}=.*|"\
"\\1${option}=\"${value}\"|;"\
"t; q 1" \
     "$file"
}

shell_var_set()
{
    local option="$1" value="$2" file="$3"
    if ! shell_var_replace "$option" "$value" "$file"; then
        echo "${option}=\"$value\"" >> "$file"
    fi
}

shell_line_split_value()
{
    sed -e 's/^[^=]*=//' 
}

unquote()
{
    sed -e $'s/^["\']//' -e $'s/["\']$//'
}

shell_var_get()
{
    local option="$1" file="$2"
    grep "^[[:blank:]]*${option}=" "$file" | head -n1 | env_line_split_value | unquote
}

grub_def=/etc/default/grub

if ! cmdline=$(shell_var_get GRUB_CMDLINE_LINUX "$grub_def"); then
    err "Failed to parse cmdline from ${grub_def}"
    exit 1
fi

old_cmdline="$cmdline"

if [[ "$cmdline" != *boot=zfs* ]]; then
    cmdline="boot=zfs ${cmdline}"
    shell_var_set GRUB_CMDLINE_LINUX "${cmdline}"  "$grub_def"
fi

shell_var_set GRUB_HIDDEN_TIMEOUT '' "$grub_def"
shell_var_set GRUB_TIMEOUT 10 "$grub_def"
shell_var_set GRUB_DISABLE_LINUX_UUID true "$grub_def"
#shell_var_replace quick_boot 0 /etc/grub.d/00_header

grub-install --target=x86_64-efi --efi-directory=/boot/efi
update-grub

# Install base packages

tasksel install standard ssh-server
apt-get install -y vim

# Just to be sure

update-initramfs -u -k all
