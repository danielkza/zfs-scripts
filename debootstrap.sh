#!/bin/bash

set -e

DEFAULT_PACKAGES=(ifupdown netbase net-tools iproute openssh-server)
DEFAULT_MIRROR='http://http.debian.net/debian'

###

print_help()
{
    local program=$(basename "$0")
    cat >&2 <<EOF
Usage: ${program} [-h] -n hostname -b boot-uuid -e efi-uuid -w swap-uuid
    [-p pkg1,pkg2,...] suite target [mirror [script]] [debootstrap-options ...]
Details:
    Options to be passed to deboostrap must come after the positional arguments,
    unlike in the original command. This is necessary to distinguish them from
    the arguments to this script. 
EOF
}

declare -a packages=("${DEFAULT_PACKAGES[@]}")

while getopts "hn:b:e:w:p:" opt; do
    case $opt in
    h) print_help; exit 1 ;;
    n) target_fqdn="$OPTARG" ;;
    b) boot_uuid="$OPTARG" ;;
    e) efi_uuid="$OPTARG" ;;
    w) swap_uuid="$OPTARG" ;;
    p)
        declare -a extra_packages
        if ! IFS=',' read -ra extra_packages <<< "$OPTARG" \
           || ! (( ${#extra_packages[@]} ))
        then
            echo "Invalid value for -${opt}: '${OPTARG}'" >&2
            exit 1
        fi

        packages=("${packages[@]}" "${extra_packages[@]}")
    ;;
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

shift $(( OPTIND - 1 ))

for (( i = 1; i <= 4; ++i )); do
    [[ "${!i}" != -* ]] || break
    case $i in
    1) suite="${!i}" ;;
    2) target="${!i}" ;;
    3) mirror="${!i}" ;;
    4) script="${!i}"
    esac
done

shift $(( i - 1 ))

###

if [[ -z "$suite" || -z "$target" || -z "$target_fqdn" ]] \
   || [[ -z "$boot_uuid" || -z "$efi_uuid" || -z "$swap_uuid" ]]
then
    print_help
    exit 1
fi

if ! [[ -d "$target" ]]; then
    echo "Error: '$target' is not a valid directory." >&2
    exit 1
fi

[[ -n "$mirror" ]] || mirror="$DEFAULT_MIRROR"

target_fqdn="$target_hostname"
target_hostname="${target_hostname%%.*}"

###

check_dev_uuid()
{
    local name="$1" uuid="$2"
    local dev=$(blkid -U "$uuid")
    if (( $? != 0 )) || ! [[ -b "$dev" ]]; then
        echo "Error: No '${name}' device found with UUID '${uuid}'" >&2
        return 1
    fi

    echo "Found ${dev} for '${name}' device" >&2
    echo -n "$dev"
    return 0
}

efi_dev=$(check_dev_uuid efi "$efi_uuid") \
boot_dev=$(check_dev_uuid boot "$boot_uuid")
[[ -z "$swap_uuid" ]] || swap_dev=$(check_dev_uuid swap "$swap_uuid")

###

[[ -n "$LANG" ]] || LANG='en_US.UTF-8'
export LANG
export DEBIAN_FRONTEND=noninteractive

###

apt-get install -y debootstrap

debootstrap --arch=amd64 \
 --include=$(IFS=',' echo "${packages[*]}") \
 wheezy "$mount_path" "$mirror"

echo "$target_hostname" > "${mount_path}/etc/hostname"

if ! [ -f "${mount_path}/etc/hosts" ]; then
    cp /etc/hosts "${mount_path}/etc/hosts"
fi

(echo "127.0.0.1 localhost ${target_hostname}"; \
 sed -e '/127.0.0.1/d' "${mount_path}/etc/hosts") > "${mount_path}/etc/hosts"

cat > "${mount_path}/etc/fstab" <<EOF
UUID=${boot_uuid}  /boot      ext2  defaults  0  1
UUID=${efi_uuid}   /boot/efi  vfat  defaults  0  1
UUID=${swap_uuid}  none       swap  defaults  0  0
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