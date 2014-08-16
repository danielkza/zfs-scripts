#!/bin/bash

set -e

src_dir=$(readlink -f $(dirname "${BASH_SOURCE[0]}"))

hostname="$1"
if [[ -z "$hostname" ]]; then
    echo "Invalid hostname" >&2
    exit 1
fi

get_uuid()
{
    blkid -o value -s UUID "$@"
}

export LANG=en_US.UTF-8
unset "${!LC_@}"

"${src_dir}/${hostname}_create.sh" -t

efi_uuid=$(get_uuid -t LABEL="EFI System")
boot_uuid=$(get_uuid -t LABEL=/boot)
swap_uuid=$(get_uuid -t LABEL=${hostname}-swap)

"${src_dir}/debootstrap.sh" -n "$hostname" \
 -e "$efi_uuid" -b "$boot_uuid" -w "$swap_uuid" \
 -l pt_BR.UTF-8 \
 -i $(ls /sys/class/net/ -1 | grep -v lo | tr '\n' ',') \
 trusty "/mnt/${hostname}" 'http://ubuntu.c3sl.ufpr.br/ubuntu'

"${src_dir}/post_debootstrap_prepare.sh" "/mnt/${hostname}"
chroot "/mnt/${hostname}" /root/post_debootstrap.sh

#"${src_dir}/post_debootstrap_cleanup.sh" "/mnt/${hostname}"
