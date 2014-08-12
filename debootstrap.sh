#!/bin/bash

set -e

DEFAULT_PACKAGES=(locales
 ifupdown netbase net-tools iproute isc-dhcp-client
 openssh-server vim)

###

print_help()
{
    local program=$(basename "$0")
    cat >&2 <<EOF
Usage: ${program} [-h] -n hostname 
    [-b boot-uuid] [-e efi-uuid] [-w swap-uuid] [-c]
    [-p pkg1,pkg2,pkgN] [-p ...] [-l locale1,locale2,localeN]
    [-i host|(iface1,iface2,ifaceN)]
    suite target [mirror [script]] [debootstrap-options ...]
Details:
    Options to be passed to deboostrap must come after the positional arguments,
    unlike in the original command. This is necessary to distinguish them from
    the arguments to this script. 
EOF
}

read_array_opt()
{
    if ! IFS=',' read -ra "$1" <<< "$OPTARG"; then
        echo "Invalid value for -${opt}: '${OPTARG}'" >&2
        return 1
    fi
    return 0
}

declare -a packages=("${DEFAULT_PACKAGES[@]}")
declare -a locales interfaces

while getopts "hn:b:e:w:c:p:l:i:" opt; do
    case $opt in
    h) print_help; exit 1 ;;
    n) target_fqdn="$OPTARG" ;;
    b) boot_uuid="$OPTARG" ;;
    e) efi_uuid="$OPTARG" ;;
    w) swap_uuid="$OPTARG" ;;
    c) cgroup_mount=1 ;;
    p)
        read_array_opt extra_packages || exit 1
        packages+=("${extra_packages[@]}")
    ;;
    l) 
        read_array_opt locales || exit 1
    ;;
    i)
        if [[ "$OPTARG" == "host" ]]; then
            network_copy_host=1
        else
            read_array_opt interfaces || exit 1
        fi
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

if [[ -z "$suite" || -z "$target" || -z "$target_fqdn" ]] \
   || [[ -z "$boot_uuid" || -z "$efi_uuid" || -z "$swap_uuid" ]]
then
    print_help
    exit 1
fi

case "$suite" in
wheezy|jessie) debian=1 ;;
trusty) ubuntu=1 ;;
*)
    echo "Error: Unsupported suite $suite" >&2
    exit 1
esac

if ! [[ -d "$target" ]]; then
    echo "Error: '$target' is not a valid directory." >&2
    exit 1
fi

if [[ -z "$mirror" ]]; then
    if (( debian )); then
        mirror="http://cdn.debian.net/debian/"
    elif (( ubuntu )); then
        mirror="http://ubuntu.c3sl.ufpr.br/ubuntu/"
    fi
else
    mirror="${mirror%/}/"
fi

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

[[ -z "$boot_uuid" ]] || boot_dev=$(check_dev_uuid boot "$boot_uuid")
[[ -z "$efi_uuid" ]] || efi_dev=$(check_dev_uuid efi "$efi_uuid")
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
 echo "127.0.1.1 ${target_hostname}"; \
 sed -e '/^127\.0\./d' "$hosts") > "${hosts}.tmp"
mv "${hosts}.tmp" "$hosts"

###

fstab="${target}/etc/fstab"

fstab_entry()
{
    printf '%-41s %-16s %-8s %-32s %d %d\n' "$@" >> "$fstab"
}

[[ -z "$boot_uuid" ]] || fstab_entry "UUID=${boot_uuid}" /boot ext2 \
 defaults 0 1
[[ -z "$efi_uuid" ]] || fstab_entry "UUID=${efi_uuid}" /boot/efi vfat \
 umask=0077,shortname=winnt 0 1
[[ -z "$swap_uuid" ]] || fstab_entry "UUID=${swap_uuid}" none swap \
 defaults 0 0
! (( cgroup_mount )) || fstab_entry cgroup /sys/fs/cgroup cgroup \
 defaults 0 0

###

interfaces_file="${target}/etc/network/interfaces"

if (( network_copy_host )); then
    cp /etc/network/interfaces "$interfaces_file"
elif (( ${#interfaces[@]} )); then
    cat > "$interfaces_file" <<EOF
auto lo
iface lo inet loopback

EOF
    for iface in "${interfaces[@]}"; do
        cat >> "$interfaces_file" <<EOF
allow-hotplug ${iface}
iface ${iface} inet dhcp

EOF
    done
fi

###

sources_list="${target}/etc/apt/sources.list"
sources_list_d="${sources_list}.d"

if (( debian )); then
    cat > "$sources_list" <<EOF
deb ${mirror} ${suite} main contrib non-free
deb-src ${mirror} ${suite} main contrib non-free

deb http://security.debian.org/ ${suite}/updates main
deb-src http://security.debian.org/ ${suite}/updates main
EOF

    cat > "${sources_list_d}/${suite}-backports.list" <<EOF
deb ${mirror} ${suite}-backports main contrib non-free
deb-src ${mirror} ${suite}-backports main contrib non-free
EOF
elif (( ubuntu )); then
    cat > "$sources_list" <<EOF
deb ${mirror} ${suite} main restricted
deb-src ${mirror} ${suite} main restricted

deb http://security.ubuntu.com/ubuntu/ ${suite}-security main restricted
deb-src http://security.ubuntu.com/ubuntu/ ${suite}-security main restricted

deb ${mirror} ${suite}-updates main restricted
deb-src ${mirror} ${suite}-updates main restricted
EOF
fi

###

if (( debian )); then
    (IFS=$'\n'; echo "$LANG"; echo "${locales[*]}") | uniq | sort \
     > "${target}/etc/locale.gen"
fi

echo "LANG=${LANG}" > "${target}/etc/default/locale"

mtab="${target}/etc/mtab"
if ! [[ -e "$mtab" ]]; then
    ln -s /proc/mounts "$mtab"
fi
