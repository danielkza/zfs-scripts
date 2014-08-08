#!/bin/bash

set -e

print_help()
{
    echo "Usage: $0 [-h] -m mount-path -n hostname -b boot-uuid -e efi-uuid [-i mirror] [extra-package ...]" >&2
    exit 1
}

while getopts "hm:n:b:e:i:" opt; do
    case $opt in
    h) print_help; exit 1 ;;
    m) mount_path="$OPTARG" ;;
    h) target_hostname="$OPTARG" ;;
    b) boot_uuid="$OPTARG" ;;
    e) efi_uuid="$OPTARG" ;;
    i) mirror="$OPTARG" ;;
    \?)
        echo "Invalid option: -$OPTARG" >&2
        exit 1
    ;;
    :)
        echo "Option -$OPTARG requires an argument." >&2
        exit 1
    ;;
    esac
done

shift $(( OPTIND-1 ))

[ -n "$LANG" ] || LANG='en_US.UTF-8'
export LANG

if ! [ -d "$mount_path" ]; then
    echo "Invalid mount-path" >&2
    exit 1
fi

if [ -z "$target_hostname" ] || [ -z "$boot_uuid" ] || [ -z "$efi_uuid" ]; then
    print_help
    exit 1
fi

if ! blkid -t UUID="$boot_uuid" 2>&1 >/dev/null; then
    echo "Invalid boot-uuid" >&2
    exit 1
fi

if ! blkid -t UUID="$efi_uuid" 2>&1 >/dev/null; then
    echo "Invalid efi-uuid" >&2
    exit 1
fi

[ -n "$mirror" ] || mirror='http://debian.c3sl.ufpr.br/debian'

extra_packages=("$@")

export DEBIAN_FRONTEND=noninteractive
apt-get install -y debootstrap

packages() {
    default_packages=ifupdown,netbase,net-tools,iproute,openssh-server
    echo -n "$default_packages"
    for pkg in "${extra_packages[@]}"; do
        echo -n ",${pkg}"
    done
}

debootstrap --arch=amd64 --include=$(packages) wheezy "$mount_path" "$mirror"

echo "$target_hostname" > "${mount_path}/etc/hostname"
sed "s/debian/${hostname}/" /etc/hosts > "${mount_path}/etc/hosts"

cat > "${mount_path}/etc/fstab" <<EOF
UUID=${boot_uuid} /boot auto defaults 0 1
UUID=${efi_uuid} /boot/efi auto defaults 0 1
EOF

cat > "${mount_path}/etc/network/interfaces" <<'EOF'
# interfaces(5) file used by ifup(8) and ifdown(8)
auto lo
iface lo inet loopback

auto eth0
allow-hotplug eth0
iface eth0 inet dhcp
    
auto eth1
allow-hotplug eth1
iface eth1 inet dhcp
EOF

echo "LANG=${LANG}" > "${mount_path}/etc/default/locale"

ln -s /proc/mounts "${mount_path}/etc/mtab"