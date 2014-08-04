#!/bin/bash

set -e

hostname=''
declare -a hdds
declare -a ssds
zlogsize='1024MiB'
test_only=1
pool_name=''
mount_path=''

print_help()
{
    echo "Usage: $0 -h hostname -d (hdd-id ...) -s (ssd-id ...) [-l zlogsize] [-m mount_path] [-r]" 1>&2
}

cmd()
{
    echo + "$@"
    if [ $test_only -eq 0 ]; then
        "$@"
        return $?
    else
        return 0
    fi
}

array_contains()
{
    local e
    for e in "${@:2}"; do
        [[ "$e" == "$1" ]] && return 0
    done
    return 1
}

while getopts "h:d:s:l:rp:m:" opt; do
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
    r)
        test_only=0
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

if [ -z "$mount_path" ]; then
    mount_path="/mnt/${pool_name}"
fi

echo "Using hostname '$hostname'"
old_hostname=$(hostname)
trap 'hostname ${old_hostname}' EXIT 
hostname ${hostname}

hdd_count="${#hdds[@]}" 
ssd_count="${#ssds[@]}"

if (( hdd_count < 2 )) || (( hdd_count % 2 != 0 )); then
    echo "Invalid HDD count ${hdd_count}: must be multiple of 2, non-zero"
    exit 1
fi

if (( ssd_count < 2 )) || (( ssd_count % 2 != 0 )); then
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

if [ $test_only -eq 0 ]; then
    read -p "Is everything right? Type YES to proceeed: " -r
    if ! [ "$REPLY" == "YES" ]; then
        exit 1
    fi

    read -p "Are you sure? Type IAMSURE to proceeed: " -r
    if ! [ "$REPLY" == "IAMSURE" ]; then
        exit 1
    fi
fi

echo "* Destroying existing pool"

cmd zpool status "$pool_name" && cmd zpool destroy "$pool_name" 

echo "* Formatting SSDs"

SGDISK="sgdisk -a 2048"

for ssd in "${ssds[@]}"; do
    echo "** Formatting ${ssd}"

    SGDISK_SSD="${SGDISK} /dev/disk/by-id/${ssd}"

    cmd zpool labelclear -f "/dev/disk/by-id/${ssd}"
    cmd hdparm -z "/dev/disk/by-id/${ssd}"
    cmd $SGDISK_SSD --clear

    if [ "$ssd" = "$boot_ssd" ]; then
        echo "** Creating boot partitions"
        
        cmd $SGDISK_SSD --new=1:1M:+255M \
          -c 1:"EFI System Partition" \
          -t 1:"ef00"
        cmd $SGDISK_SSD --new=2:0:+256M \
          -c 2:"/boot" \
          -t 2:"8300"

        cmd sleep 1

        cmd zpool labelclear -f "/dev/disk/by-id/${ssd}-part1"
        cmd zpool labelclear -f "/dev/disk/by-id/${ssd}-part2"

        cmd mkfs.vfat "/dev/disk/by-id/${ssd}-part1"
        cmd mkfs.ext2 -m 0 -L /boot -j "/dev/disk/by-id/${ssd}-part2"
    elif [ "$ssd" = "$swap_ssd" ]; then
        echo "** Creating swap partitions"
        
        cmd $SGDISK_SSD --new=1:1M:+511M \
          -c 1:"Linux Swap" \
          -t 1:"8200"

        cmd sleep 1

        cmd zpool labelclear -f "/dev/disk/by-id/${ssd}-part1"

        cmd mkswap "/dev/disk/by-id/${ssd}-part1"
    fi

    if array_contains "$ssd" "${slog_ssds[@]}"; then
        echo "** Creating ZIL SLOG partition"
        cmd $SGDISK_SSD --new=3:0:+"${zlogsize}" \
          -c 3:"ZFS SLOG" \
          -t 3:"bf01"

        echo "** Creating L2ARC partition"
        cmd $SGDISK_SSD --new=4:0:0 \
          -c:4:"ZFS L2ARC" \
          -t 4:"bf01"

        cmd sleep 1

        cmd zpool labelclear -f "/dev/disk/by-id/${ssd}-part3"
        cmd zpool labelclear -f "/dev/disk/by-id/${ssd}-part4"
    else
        echo "** Skipping partitioning, to be used as whole disk"
    fi

    echo
done

echo "* Clearing HDDs"
for hdd in "${hdds[@]}"; do
    echo "** Clearing ${hdd}"
    
    cmd zpool labelclear -f "/dev/disk/by-id/${hdd}"
    cmd hdparm -z "/dev/disk/by-id/${ssd}"
    cmd $SGDISK "/dev/disk/by-id/${hdd}" --clear
done

echo "* Creating pool"
hdds_pool_spec=""
for (( i = 0; i < ${#hdds[@]}; i+=2 )); do
    hdd0="${hdds[$i]}"
    hdd1="${hdds[$((i+1))]}"

    hdds_pool_spec="${hdds_pool_spec} mirror ${hdd0} ${hdd1}"
done

cmd zpool create -o ashift=12 "$pool_name" ${hdds_pool_spec}

echo "* Adding SSDs to pool"

ssds_slog_spec="log"
for (( i = 0; i < ${#slog_ssds[@]}; i+=2 )); do
    ssd0="${slog_ssds[$i]}"
    ssd1="${slog_ssds[$((i+1))]}"

    ssds_slog_spec="${ssds_slog_spec} mirror ${ssd0}-part3 ${ssd1}-part3"
done

ssds_cache_spec="cache"
for ssd in "${ssds[@]}"; do
    if array_contains "$ssd" "${slog_ssds[@]}"; then
        ssds_cache_spec="${ssds_cache_spec} /dev/disk/by-id/${ssd}-part4"
    else
        ssds_cache_spec="${ssds_cache_spec} /dev/disk/by-id/${ssd}"
    fi
done

cmd zpool add "$pool_name" ${ssds_slog_spec} ${ssds_cache_spec}

echo "* Reimporting pool at $mount_path"

cmd zpool export "$pool_name"
! [ -d "$mount_path" ] && cmd mkdir -p "$mount_path"
cmd zpool import "$pool_name" -N -d /dev/disk/by-id -R "$mount_path"

echo "* Creating filesystems"

cmd zfs create "${pool_name}/root" -o mountpoint=none
cmd zfs create "${pool_name}/root/debian" -o mountpoint=/

echo "* Setting options"

cmd zpool set bootfs="${pool_name}/root/debian"