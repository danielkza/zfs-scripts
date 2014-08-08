#!/bin/bash

set -e

target_hostname=''
declare -a hdds
declare -a ssds
zlog_hsize='1024M'
swap_size='1024M'
boot_size='256M'
efi_size='256M'
test_only=1
non_interactive=0
pool_name=''
mount_path=''

print_help()
{
    cat >&2 <<EOF
Usage: $0 [-h] -n hostname -d hdd-disk-id [-d ...] -s ssd-disk-id [-s ...]
    -m mount-path [-l zlog-size] [-w swap-size] [-p pool-name] [-T]
Options:
    -h                
                      Print help and exit
    -n hostname       
                      Specify the hostname to use temporarily. Will possibly be
                      used to generate the hostid by ZFS
    -d hdd-disk-path    
                      Specify the path to a disk to include in the main storage
                      pool. Should be something that exists in /dev/disk/by-id,
                      without the folder name. e.g. wwn-********, scsi-********
                      Repeat for multiple disks. Number of disks must be even.
    -s ssd-disk-path    
                      Specify the path to a disk to use as utility, ZFS SLOG and
                      cache disks. Should be an SSD. Repeat for multiple disks.
                      Number of disks must be 1 or a multiple of two
    -m mount-path
                      Where to mount the root FS created from the pool after
                      everything is done.
    -e efi-size
                      Size of the EFI partition on the first SSD.
                      Defaults to ${efi_size}. Should be specified in units of
                      'M' for MiB.
    -b boot-size
                      Size of the boot partitions. Will be mirrored on
                      all provided SSDs. Defaults to ${boot_size}.
    -w swap-size      
                      Size of the swap partitions. Will be mirrored on
                      all provided SSDs. Defaults to ${swap_size}.
    -l zlog-size      
                      Size of the ZFS SLOG partitions. Will be mirrored
                      on all provided SSDs. Defaults to ${slogsize}.
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

msg()
{
    echo >&2
    echo "$@" >&2
}

clean_var_name()
{
    sed 's/[^[:alnum:]_]/_/g'
}

find_executable()
{
    local name="$(echo "$1" | clean_var_name)"
    local path=$(which "$1")

    if ! [ -x "$path" ]; then
        echo "'$1' executable not found in PATH" >&2
        return 1
    fi
        
    echo "Using ${path} as $1" >&2
    declare -g "${name}_bin=${path}"
}

confirm()
{
    if (( yes == 1 )); then
        return 0
    else
        read -p "$1 [y/n] " -r
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

rand_uuid()
{
    cat /proc/sys/kernel/random/uuid
}

while getopts "hn:d:s:m:e:b:w:l:p:ty" opt; do
    case $opt in
    h) print_help; exit 1 ;;
    n) target_hostname="$OPTARG" ;;
    d) hdds+=("$OPTARG") ;;
    s) ssds+=("$OPTARG") ;;
    m) mount_path="$OPTARG" ;;
    l) slog_size="$OPTARG" ;;
    w) swap_size="$OPTARG" ;;
    b) boot_size="$OPTARG" ;;
    e) efi_size="$OPTARG" ;;
    p) pool_name="$OPTARG" ;;
    t) test_only=0 ;;
    y) yes=1 ;;
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

if [ -z "$target_hostname" ] || [ -z "$slog_size" ] || [ -z "$swap_size" ] \
   || [ -z "$boot_size" ] || [ -z "$efi_size" ]
then
    print_help
    exit 1
fi

if [ -z "$pool_name" ]; then
    pool_name="${target_hostname%%.*}"
fi

hdd_count="${#hdds[@]}" 
ssd_count="${#ssds[@]}"

if (( hdd_count < 2 )) || (( hdd_count % 2 != 0 )); then
    echo "Invalid HDD count ${hdd_count}: must be multiple of 2, non-zero" >&2
    exit 1
fi

if (( ssd_count < 1 )) || (( ssd_count == 1 || ssd_count % 2 != 0 )); then
    echo "Invalid SSD count ${ssd_count}: must be 1 or a multiple of 2" >&2
    exit 1
fi

if (( ssd_count == 1 )); then
    echo "Only one SSD selected. Your boot, swap and SLOG will not be mirrored." >&2
    if ! confirm "Disk failures will cause data and availability loss. Proceed?"; then
        exit 1
    fi
fi

for exe in hostname \
           mdadm hdparm sgdisk \
           mkfs.vfat mkfs.ext2 mkswap \
           zfs zpool \
           udevadm; do
    find_executable "$exe"
done


echo "Using hostname '${target_hostname}'" >&2

if (( test_only != 0 )); then
    old_hostname=$(hostname)
    trap "'$hostname_bin' '${old_hostname}'" EXIT
fi
cmd "$hostname_bin" "$target_hostname"


echo "Using pool name '${pool_name}'" >&2

check_disks()
{
    dest_var="$1"
    shift

    local -a disks
    disks=("$@")

    local -A disk_devs
    for disk in "${disks[@]}"; do
        echo -n "- $disk => "
        if ! [ -e "${disk}" ]; then
            echo "NOT FOUND"
            exit 1
        fi

        dev=$(readlink -f "${disk}")
        if ! [ -e "${dev}" ]; then
            echo "NOT FOUND"
            exit 1
        fi

        echo "$dev"
        eval "${dest_var}[$disk]=\"$dev\""
    done
}

echo "Using ${hdd_count} HDDs: " >&2
declare -A hdd_devs
check_disks "hdd_devs" "${hdds[@]}" >&2

echo >&2

echo "Using ${ssd_count} SSDs: " >&2
declare -A ssd_devs
check_disks "ssd_devs" "${ssds[@]}" >&2

if (( test_only == 0 )); then
    if ! confirm "Verify all information for correctness. Proceed?"; then
        exit 1
    fi

    if ! confirm "Destructive actions will be performed. Are you sure?"; then
        exit 1
    fi
fi

if (( test_only == 0 )) && cmd "$zpool_bin" list -H -o name "$pool_name" 2>&1 >/dev/null; then
    if ! confirm "A zpool named ${pool_name} already exists. Destroy it and proceed?"; then
        exit 1
    fi

    msg "* Destroying existing pool" >&2
    cmd "$zpool_bin" destroy "$pool_name" 
fi


msg "* Formatting SSDs" 

refresh_disk()
{
    if (( test_only )); then
        return 0
    fi

    sleep 1
    cmd "$hdparm_bin" -z "$1"
}

sgdisk_bin="${sgdisk_bin} -a 2048"

part_queue_start()
{ 
    _part_queue_cmd="$sgdisk_bin '$1'"
    _part_queue_num=0
}

part_queue_add()
{
    local size="$1" label="$2" type="$3" uuid_var="$4"
    local num=$(( ++_part_queue_num )) uuid=$(rand_uuid)
    local flags=\
"--new='${num}:0:${size}' -c '${num}:${label}' -t '${num}:${type}' -u '${num}:${uuid}'"

    _part_queue_cmd="${_part_queue_cmd} ${flags}"
    eval "$uuid_var"="$uuid"
}

part_queue_apply()
{
    eval "cmd ${_part_queue_cmd}"
    unset _part_queue_cmd _part_queue_num
}

efi_uuid=''
declare -a boot_uuids swap_uuids slog_uuids l2arc_uuids


for ssd in "${ssds[@]}"; do
    msg "** Formatting ${ssd}" 

    cmd "$zpool_bin" labelclear -f "$ssd"
    refresh_disk "$ssd"

    cmd $sgdisk_bin "$ssd" --clear
    refresh_disk "$ssd"
    
    part_queue_start "$ssd"

    efi_clear_uuid=''
    if [ -z "$efi_uuid" ]; then
        part_queue_add "+${efi_size}" EFI ef00 efi_uuid
        efi_clear_uuid="$efi_uuid"
    fi

    part_queue_add "+${boot_size}" "/boot" 8300 boot_uuid
    boot_uuids+=("$boot_uuid")
    
    part_queue_add "+${swap_size}" "Linux swap" 8200 swap_uuid
    swap_uuids+=("$swap_uuid")

    part_queue_add "+${slog_size}" "ZFS SLOG" bf01 slog_uuid
    slog_uuids+=("$slog_uuid")

    part_queue_add "0" "ZFS L2ARC" bf01 l2arc_uuid
    l2arc_uuids+=("$l2arc_uuid")

    part_queue_apply

    # Wait for partitions to show up in /dev
    cmd "$udevadm_bin" settle

    for uuid in $boot_uuid $swap_uuid $slog_uuid $l2arc_uuid $efi_clear_uuid; do
        cmd "$zpool_bin" labelclear -f "/dev/disk/by-partuuid/${uuid}"
    done

    refresh_disk "$ssd"
done

cmd "$udevadm_bin" settle

dev_refs()
{
    local var="${1}[@]"
    local devs=("${!var}") prefix="$2" mirror
    [ "$3" != "mirror" ] || mirror=1

    
    for (( i = 0; i < ${#devs[@]}; ++i )); do
        if (( mirror && i % 2 == 0 )); then
            echo -n "mirror "
        fi
        
        echo -n "${prefix}${devs[i]} "  
    done
}

if (( ssd_count > 1 )); then
    mdadm_copy_config=1

    msg "* Creating MDADM devices" 

    boot_dev=/dev/md/boot
    yes | cmd "$mdadm_bin" --verbose --create "$boot_dev" --homehost="$target_hostname" \
     --assume-clean --level=mirror --raid-devices="${ssd_count}" --metadata=0.90 \
     $(dev_refs boot_uuids /dev/disk/by-partuuid/)

    swap_dev=/dev/md/swap
    yes | cmd "$mdadm_bin" --verbose --create "$swap_dev" --homehost="$target_hostname" \
     --assume-clean --level=mirror --raid-devices="${ssd_count}" \
     $(dev_refs swap_uuids /dev/disk/by-partuuid/)
else
    boot_dev="/dev/disk/by-partuuid/${boot_uuids[0]}"
    swap_dev="/dev/disk/by-partuuid/${swap_uuids[0]}"
fi


msg "* Formatting EFI partition" 
efi_dev="/dev/disk/by-partuuid/${efi_uuid}"
cmd "$mkfs_vfat_bin" -n "EFI System Partition" "$efi_dev"


msg "* Formatting boot partition" 
cmd "$mkfs_ext2_bin" -L "/boot" "$boot_dev"


msg "* Formatting swap partition" 

cmd "$mkswap_bin" "$swap_dev"


msg "* Clearing HDDs" 

for hdd in "${hdds[@]}"; do
    msg "** Clearing ${hdd}" 
    
    cmd "$zpool_bin" labelclear -f "$hdd"
    refresh_disk "$hdd"
    
    cmd $sgdisk_bin "$hdd" --clear
    refresh_disk "$hdd"
done

msg "* Creating pool" 

cmd "$zpool_bin" create -m none -R "$mount_path" -o ashift=12 "$pool_name" \
 $(dev_refs hdds '' mirror)


msg "* Adding SLOG to pool" 

cmd "$zpool_bin" add "$pool_name" log \
 $(dev_refs slog_uuids /dev/disk/by-partuuid/ mirror)


msg "* Adding caches to pool" 

cmd "$zpool_bin" add "$pool_name" cache \
 $(dev_refs l2arc_uuids /dev/disk/by-partuuid/)


msg "* Creating ZFS filesystems" 

cmd "$zfs_bin" create "${pool_name}/root" -o mountpoint=none
cmd "$zfs_bin" create "${pool_name}/root/debian" -o mountpoint=/


msg "* Setting ZFS pool options" 

cmd "$zpool_bin" set bootfs="${pool_name}/root/debian" "$pool_name"
cmd mkdir -p "${mount_path}/etc/zfs"
cmd "$zpool_bin" set cachefile="${mount_path}/etc/zfs/zpool.cache" "$pool_name"


if (( mdadm_copy_config )); then
    msg "* Copying MDADM configuration to target"     

    cmd mkdir -p "${mount_path}/etc/mdadm"
    cmd sh -c "${mdadm_bin} --examine --scan > '${mount_path}/etc/mdadm/mdadm.conf'"
fi