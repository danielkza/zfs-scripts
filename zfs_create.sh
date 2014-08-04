#!/bin/bash

set -e

DO=''

hostname=''
declare -a hdds
declare -a ssds
zlogsize='1024MiB'
test_only=''
pool_name=''
mount_path='/mnt/rl-zfs-inst'

print_help()
{
    echo "Usage: $0 -h hostname -d (hdd-id ...) -s (ssd-id ...) [-l zlogsize] [-t]" 1>&2
}

while getopts "h:d:s:l:tp:m:" opt; do
    case $opt in
    h)
        hostname=$OPTARG
    ;;
    d)
        hdds+=("$OPTARG")
    ;;
    s)
        ssds+=("$OPTARG")
    ;;
    l)
        zlogsize="$OPTARG"
    ;;
    p)
        pool_name="$OPTARG"
    ;;
    m)
        mount_path="$OPTARG"
    ;;
    t)
        test_only=1
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

if [ -z "$hostname" ] || [ -z "$zlogsize" ]; then
    print_help
    exit 1
fi

if [ -z "$pool_name" ]; then
    pool_name="$hostname"
fi

if [ -n "$test_only" ]; then
    DO='echo '
fi

echo "Using hostname '$hostname'"
old_hostname=$(hostname)
trap 'hostname ${old_hostname}' EXIT 
hostname ${hostname}

hdd_count="${#hdds[@]}" 
ssd_count="${#ssds[@]}"

if (( $hdd_count < 2 )) || (( $hdd_count % 2 != 0 )); then
    echo "Invalid HDD count ${hdd_count}: must be multiple of 2, non-zero"
    exit 1
fi

if (( $ssd_count < 2 )) || (( $ssd_count % 2 != 0 )); then
    echo "Invalid SSD count ${ssd_count}: must be multiple of 2, non-zero"
    exit 1
fi

check_disks()
{
    dest_var=$1
    shift

    local -a disks
    disks=("$@")

    local -A disk_devs
    for disk in "${disks[@]}"; do
        echo -n "- $disk => "
        if ! [ -e "/dev/disk/by-id/${disk}" ]; then
            echo "NOT FOUND"
            exit 1
        fi

        dev=$(readlink -f "/dev/disk/by-id/${disk}")
        echo "$dev"

        eval "${dest_var}[$disk]=\"$dev\""
    done
}

echo "Using ${hdd_count} HDDs: "
declare -A hdd_devs
check_disks "hdd_devs" "${hdds[@]}"
echo

echo "Using ${ssd_count} SSDs: "
declare -A ssd_devs
check_disks "ssd_devs" "${ssds[@]}"
echo

boot_ssd="${ssds[0]}"
echo "Using disk ${boot_ssd} for boot"

swap_ssd="${ssds[1]}"
echo "Using disk ${swap_ssd} for swap"

slog_ssds=("${boot_ssd}" "${swap_ssd}")
echo "Using ZIL SLOG size of ${zlogsize} on disks:"
for ssd in "${slog_ssds[@]}"; do
    echo "- ${ssd}"
done

echo 
read -p "Is everything right? Type YES to proceeed: " -r
if ! [ "$REPLY" == "YES" ]; then
    exit 1
fi

read -p "Are you sure? Type IAMSURE to proceeed: " -r
if ! [ "$REPLY" == "IAMSURE" ]; then
    exit 1
fi

echo "* Formatting SSDs"

SGDISK="$DO sgdisk -a 2048"

array_contains() {
  local e
  for e in "${@:2}"; do [[ "$e" == "$1" ]] && return 0; done
  return 1
}

for ssd in "${ssds[@]}"; do
    echo "** Formatting ${ssd}"

    SGDISK_SSD="${SGDISK} /dev/disk/by-id/${ssd}"

    $SGDISK_SSD --clear

    if [ "$ssd" = "$boot_ssd" ]; then
        echo "** Creating boot partitions"
        
        $SGDISK_SSD --new=1:1M:256M \
          -c 1:"EFI System Partition" \
          -t 1:"ef00"
        $SGDISK_SSD --new=2:0:512M \
          -c 2:"/boot" \
          -t 2:"8300"

        sleep 1

        $DO mkfs.vfat "/dev/disk/by-id/${ssd}-part1"
        $DO mkfs.ext2 -m 0 -L /boot -j "/dev/disk/by-id/${ssd}-part2"
    elif [ "$ssd" = "$swap_ssd" ]; then
        echo "** Creating swap partitions"
        
        $SGDISK_SSD --new=1:1M:512M \
          -c 1:"Linux Swap" \
          -t 1:"8200"

        sleep 1

        $DO mkswap "/dev/disk/by-id/${ssd}-part1"
    fi

    if array_contains "$ssd" "${slog_ssds[@]}"; then
        echo "** Creating ZIL SLOG partition"
        $SGDISK_SSD --new=3:0:"${zlogsize}" \
          -c 3:"ZFS SLOG" \
          -t 3:"bf01"

        echo "** Creating L2ARC partition"
        $SGDISK_SSD --new=4:0:0 \
          -c:4:"ZFS L2ARC" \
          -t 4:"bf01"
    else
        echo "** Skipping partitioning, to be used as whole disk"
    fi

    echo
done

echo "* Creating pool"
hdds_pool_spec=""
for (( i = 0; i < ${#hdds[@]}; i+=2 )); do
    hdd0="${hdds[$i]}"
    hdd1="${hdds[$((i+1))]}"

    hdds_pool_spec="${hdds_pool_spec} mirror ${hdd0} ${hdd1}"
done

$DO zpool create -o ashift=12 "$pool_name" ${hdds_pool_spec}

echo "* Adding SSDs to pool"

ssds_slog_spec="log"
for (( i = 0; i < ${#slog_ssds[@]}; i+=2 )); do
    ssd0="${slog_ssds[$i]}"
    ssd1="${slog_ssds[$((i+1))]}"

    ssds_slog_spec="${ssds_slog_spec} mirror ${ssd0} ${ssd1}"
done

ssds_cache_spec="cache"
for ssd in "${ssds[@]}"; do
    if array_contains "$ssd" "${slog_ssds[@]}"; then
        ssds_cache_spec="${ssds_cache_spec} /dev/disk/by-id/${ssd}-part4"
    else
        ssds_cache_spec="${ssds_cache_spec} /dev/disk/by-id/${ssd}"
    fi
done

$DO zpool add "$pool_name" ${ssds_slog_spec} ${ssds_cache_spec}

echo "* Creating filesystems"

$DO zfs create "${pool_name}/root" -o mountpoint=none
$DO zfs create "${pool_name}/root/debian" -o mountpoint=/

echo "* Setting options and unmounting"

$DO zpool set bootfs="${pool_name}/root/debian"
$DO zpool export "$pool_name"

! [ -d "$mount_path" ] && mkdir -p "$mount_path"
zpool import -d /dev/disk/by-id -R "$mount_path"