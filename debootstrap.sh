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
    [-p pkg1,pkg2,pkgN] [-p ...] [-l locale1,locale2,localeN]
    suite target [mirror [script]] [debootstrap-options ...]
Details:
    Options to be passed to deboostrap must come after the positional arguments,
    unlike in the original command. This is necessary to distinguish them from
    the arguments to this script. 
EOF
}

read_array_param()
{
    if ! IFS=',' read -ra "$1" <<< "$OPTARG"; then
        echo "Invalid value for -${opt}: '${OPTARG}'" >&2
        return 1
    fi
    return 0
}

declare -a packages=("${DEFAULT_PACKAGES[@]}")
declare -a locales

while getopts "hn:b:e:w:p:l:" opt; do
    case $opt in
    h) print_help; exit 1 ;;
    n) target_fqdn="$OPTARG" ;;
    b) boot_uuid="$OPTARG" ;;
    e) efi_uuid="$OPTARG" ;;
    w) swap_uuid="$OPTARG" ;;
    p)
        read_array_param extra_packages || exit 1
        packages+=("${extra_packages[@]}")
    ;;
    l) 
        read_array_param locales || exit 1
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
    if (( i > $# )) || [[ "${!i}" == -* ]]; then
        break
    fi

    case $i in
    1) suite="${!i}" ;;
    2) target="${!i}" ;;
    3) mirror="${!i}" ;;
    4) script="${!i}"
    esac
done

shift $(( i - 1 ))

###

echo "$suite $target $mirror $script"


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

target_hostname="${target_fqdn%%.*}"

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

[[ -n "$LANG" ]] || export LANG='en_US.UTF-8'
export DEBIAN_FRONTEND=noninteractive

###

apt-get install -y debootstrap

[[ -n "$DEBOOTSTRAP" ]] || DEBOOTSTRAP=debootstrap

"$DEBOOTSTRAP" --include="$(IFS=','; echo "${packages[*]}")" \
 "$suite" "$target" ${mirror:+"$mirror"} ${script:+"$script"} \
 "$@"

###

echo "$target_hostname" > "${target}/etc/hostname"

hosts="${target}/etc/hosts"

if ! [[ -f "$hosts" ]]; then
    cp /etc/hosts "$hosts" 
fi

(echo "127.0.0.1 localhost"; \
 sed -e '/^127\.0\./d' "$hosts") > "${hosts}.tmp"
mv "${hosts}.tmp" "$hosts"

###

fstab="${target}/etc/fstab"

cat > "$fstab" <<EOF
UUID=${boot_uuid}  /boot      ext2  defaults  0  1
UUID=${efi_uuid}   /boot/efi  vfat  defaults  0  1
EOF

if [[ -n "$swap_uuid" ]]; then
    cat >> "$fstab" <<EOF
UUID=${swap_uuid}  none       swap  defaults  0  0
EOF
fi

###

interfaces="${target}/etc/network/interfaces"

if ! [[ -f "$interfaces"  ]]; then
    cp /etc/network/interfaces "$interfaces"
fi

###

cat > "${target}/etc/apt/sources.list" <<EOF
deb ${mirror} ${suite} main contrib non-free
deb-src ${mirror} ${suite} main contrib non-free
deb http://security.debian.org/ ${suite}/updates main
deb-src http://security.debian.org/ ${suite}/updates main
EOF

cat > "${target}/etc/apt/sources.list.d/${suite}-backports.list" <<EOF
deb ${mirror} ${suite}-backports main contrib non-free
deb-src ${mirror} ${suite}-backports main contrib non-free
EOF

###

echo "LANG=${LANG}" > "${target}/etc/default/locale"
(IFS=$'\n'; echo "$LANG"; echo "${locales[*]}") \
 | uniq | sort > "${target}/etc/locale.gen"

ln -sf /proc/mounts "${target}/etc/mtab"