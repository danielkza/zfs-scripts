#!/bin/bash

set -e

hostname=''
declare -a hdds
declare -a ssds
zlog_hsize='1024MiB'
swap_size='512MiB'
boot_size='256MiB'
efi_size='256MiB'
test_only=1
non_interactive=0
pool_name=''
mount_path=''

print_help()
{
    cat 1>&2 <<EOF
Usage: $0 -h hostname -d hdd-disk-id [-d ...] -s ssd-disk-id [-s ...]
    -m mount-path [-l zlog-size] [-w swap-size] [-p pool-name] [-T]
Options:
    -h hostname       
                      Specify the hostname to use temporarily. Will possibly be
                      used to generate the hostid by ZFS
    -d hdd-disk-id    
                      Specify the ID of a disk to include in the main storage
                      pool. Should be something that exists in /dev/disk/by-id,
                      without the folder name. e.g. wwn-********, scsi-********
                      Repeat for multiple disks. Number of disks must be even.
    -s ssd-disk-id    
                      Specify the ID of a disk to use as utility, ZFS SLOG and
                      cache disks. Should be an SSD. Repeat for multiple disks.
                      Number of disks must be 1 or a multiple of two
    -m mount-path
                      Where to mount the root FS created from the pool after
                      everything is done.
    -l zlog-size      
                      Size to use for the ZFS SLOG partitions. Will be mirrored
                      on all provided SSDs. Defaults to ${slogsize} if not
                      specified. Should usually be expresed as '{num}MiB'.
    -w swap-size      
                      Size to use for the swap partitions. Will be mirrored on
                      all provided SSDs. Defaults to ${swap_size}.
    -b boot-size
                      Size to use for the boot partitions. Will be mirrored on
                      all provided SSDs. Defaults to ${boot_size}.
    -e efi-size
                      Size to use for the EFI partition on the first SSD.
                      Defaults to ${efi_size}
    -p pool-name
                      Use an specific pool name instead of defaulting to the
                      host name (without domain)
    -t
                      Actually perform all the actions instead of doing a
                      dry-run as per default. Will ask you to confirm setup
                    before proceding
    -y
                      Answer yes to all prompts by default (be careful!)
EOF
}

cmd()
{
    echo + "$@"
    if (( test_only == 0 )); then
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

confirm()
{
    if (( yes == 1 )); then
        return 0
    else
        read -p "$1" -r
        case "$REPLY" in
            [Yy])
                return 0
            ;;
            [Yy][Ee][Ss])
                return 0
        esac

        return 1
    fi
}

while getopts "h:d:s:m:l:w:b:p:tT" opt; do
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
    m)
        mount_path="$OPTARG"
    ;;
    l)
        slog_size="$OPTARG"
    ;;
    w)
        swap_size="$OPTARG"
    ;;
    b)
        boot_size="$OPTARG"
    ;;
    e)
        efi_size="$OPTARG"
    ;;
    p)
        pool_name="$OPTARG"
    ;;
    t)
        test_only=0
    ;;
    y)
        yes=1
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

if [ -z "$hostname" ] || [ -z "$slog_size" ] || [ -z "$swap_size" ] \
   || [ -z "$boot_size" ] || [ -z "$efi_size" ]
then
    print_help
    exit 1
fi

if [ -z "$pool_name" ]; then
    pool_name="${hostname%%.*}"
fi

hdd_count="${#hdds[@]}" 
ssd_count="${#ssds[@]}"

if (( hdd_count < 2 )) || (( hdd_count % 2 != 0 )); then
    echo "Invalid HDD count ${hdd_count}: must be multiple of 2, non-zero"
    exit 1
fi

if (( ssd_count < 1 )) || (( ssd_count == 1 || ssd_count % 2 != 0 )); then
    echo "Invalid SSD count ${ssd_count}: must be 1 or a multiple of 2"
    exit 1
fi

echo "Using hostname '${hostname}'"
old_hostname=$(hostname)
trap "hostname '${old_hostname}'" EXIT 
hostname "$hostname"

echo "Using pool name '${pool_name}'"

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

echo 

if (( ssd_count == 1 )); then
    echo "Only one SSD selected. Your boot, swap and SLOG will not be mirrored."
    if ! confirm "Disk failures will cause data and availability loss. Proceed? [y/n]"; then
        exit 1
    fi
fi

if (( test_only == 0 )); then
    if ! confirm "Verify all information for correctness. Proceed? [y/n]"; then
        exit 1
    fi

    if ! confirm "Destructive actions will be performed. Are you sure? [y/n]"; then
        exit 1
    fi
fi

echo "* Destroying existing pool"

if (( test_only == 0 )) && zpool status "$pool_name"; then
    if ! confirm "A zpool named ${pool_name} already exists. Destroy it and proceed? [y/n]"; then
        exit 1
    fi
    cmd zpool destroy "$pool_name" 
fi

echo "* Formatting SSDs"

SGDISK="sgdisk -a 2048"
efi_created=0

for ssd in "${ssds[@]}"; do
    echo "** Formatting ${ssd}"

    SGDISK_SSD="${SGDISK} /dev/disk/by-id/${ssd}"

    cmd zpool labelclear -f "/dev/disk/by-id/${ssd}"
    cmd hdparm -z "/dev/disk/by-id/${ssd}"
    cmd $SGDISK_SSD --clear

    if (( efi_created == 0 )); then
        echo "** Creating EFI partition"
            
        cmd $SGDISK_SSD --new="1:0:+${efi_size}" \
          -c 1:"EFI System Partition" \
          -t 1:"ef00"

        cmd zpool labelclear -f "/dev/disk/by-id/${ssd}-part1"

        efi_created=1
        boot_start=0
    else
        echo "** Skipping size of EFI partition in secondary disk"
        boot_start="$efi_size"
    fi

    echo "** Creating boot partition"
    cmd $SGDISK_SSD --new="2:${boot_start}:+${boot_size}" \
     -c 2:"/boot" \
     -t 2:"8300"
    cmd zpool labelclear -f "/dev/disk/by-id/${ssd}-part2"

    echo "** Creating swap partition"
    cmd $SGDISK_SSD --new="3:0:+${swap_size}" \
     -c 1:"Linux Swap" \
     -t 1:"8200"
    cmd zpool labelclear -f "/dev/disk/by-id/${ssd}-part3"

    echo "** Creating SLOG partition"
    cmd $SGDISK_SSD --new="4:0:+${slog_size}" \
     -c 3:"ZFS SLOG" \
     -t 3:"bf01"
    cmd zpool labelclear -f "/dev/disk/by-id/${ssd}-part4"

    echo "** Creating L2ARC partition in remaining space"
    cmd $SGDISK_SSD --new=5:0:0 \
     -c:4:"ZFS L2ARC" \
     -t 4:"bf01"
    cmd zpool labelclear -f "/dev/disk/by-id/${ssd}-part5"

    echo
done

ssd_partition_refs()
{
    part_num="$1"
    for ssd in "${ssds[@]}"; do
        echo -n "/dev/disk/by-id/${ssd}-part${part_num} "
    fi
}

if (( ssd_count > 1 )); then
    echo "* Creating MDADM devices"
    boot_dev=/dev/md/boot
    cmd mdadm --create --verbose "$boot_dev" --level=mirror --raid-devices="${ssd_count}" \
     $(ssd_partitition_refs 2)

    swap_dev=/dev/md/swap
    cmd mdadm --create --verbose "$swap_dev" --level=mirror --raid-devices="${ssd_count}" \
     $(ssd_partitition_refs 3)
else
    boot_dev="/dev/disk/by-id/${ssds[0]}-part2"
    swap_dev="/dev/disk/by-id/${ssds[0]}-part3"
fi

echo "* Formatting SSD partitions"

efi_dev="/dev/disk/by-id/${ssds[0]}-part1"
cmd mkfs.vfat -n "EFI System Partition" "$efi_dev"

cmd mkfs.ext2 -L "/boot" "$boot_dev"

cmd mkswap "$swap_dev"

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

cmd zpool create -m none -R "$mount_path" -o ashift=12 "$pool_name" ${hdds_pool_spec}

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
        ssds_cache_spec="${ssds_cache_spec} ${ssd}-part4"
    else
        ssds_cache_spec="${ssds_cache_spec} ${ssd}"
    fi
done

cmd zpool add "$pool_name" ${ssds_slog_spec} ${ssds_cache_spec}

echo "* Creating filesystems"

cmd zfs create "${pool_name}/root" -o mountpoint=none
cmd zfs create "${pool_name}/root/debian" -o mountpoint=/

echo "* Setting options"

cmd zpool set bootfs="${pool_name}/root/debian" "$pool_name"