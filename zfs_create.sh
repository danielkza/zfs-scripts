#!/bin/bash

set -e

### Utility functions ###

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
    echo 'I:' "$@" >&2
}

msg_n()
{
    echo -n 'I:' "$@" >&2
}

err()
{
    echo 'E: '"$@" >&2
}

confirm()
{
    if (( yes == 1 )); then
        return 0
    elif ! [[ -t 1 ]]; then
        err "confirmation needed but input is not a terminal."
        return 1
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

### Input parameters ###

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
    local program=$(basename "$0")
    cat >&2 <<EOF
Usage: ${program} [-h] -n hostname -d hdd-disk-id [-d ...] -s ssd-disk-id [-s ...]
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
        err "Invalid option: -$OPTARG"
        exit 1
    ;;
    :)
        err "Option -$OPTARG requires an argument."
        exit 1
    ;;
    esac
done

### Parameter verification ###

if [[ -z "$target_hostname" || -z "$slog_size" || -z "$swap_size" \
      || -z "$boot_size" || -z "$efi_size" ]]
then
    print_help
    exit 1
fi

if [[ -z "$pool_name" ]]; then
    pool_name="${target_hostname%%.*}"
fi

hdd_count="${#hdds[@]}" 
ssd_count="${#ssds[@]}"

if (( hdd_count < 2 || hdd_count % 2 != 0 )); then
    err "invalid HDD count ${hdd_count}: must be multiple of 2, non-zero"
    exit 1
fi

if (( ssd_count == 1 )); then
    err "only one SSD selected. Your boot, swap and SLOG will not be mirrored."
    if ! confirm "Disk failures will cause data and availability loss. Proceed?"; then
        exit 1
    fi
elif (( ssd_count < 1 || ssd_count % 2 != 0 )); then
    err "invalid SSD count ${ssd_count}: must be 1 or a multiple of 2"
    exit 1
fi

### Check for presence of needed programs ###

clean_var_name()
{
    sed 's/[^[:alnum:]_]/_/g'
}

find_executable()
{
    local name="$(echo "$1" | clean_var_name)"
    local path=$(which "$1")

    if ! [[ -x "$path" ]]; then
        err "'$1' executable not found in PATH"
        return 1
    fi
        
    msg "Using ${path} as $1"
    eval "${name}_bin=${path}"
}

for exe in hostname \
           mdadm blockdev sgdisk \
           mkfs.vfat mkfs.ext2 mkswap \
           zfs zpool \
           udevadm; do
    find_executable "$exe"
done

### Update hostname ###

msg "Using hostname '${target_hostname}'"

if (( test_only != 0 )); then
    old_hostname=$(hostname)
    trap "'$hostname_bin' '${old_hostname}'" EXIT
fi
cmd "$hostname_bin" "$target_hostname"

### Check and print disk information ###

check_disks()
{
    dest_var="$1"
    shift

    local -a disks
    disks=("$@")

    local -A disk_devs
    for disk in "${disks[@]}"; do
        msg_n "  $disk => "
        if ! [[ -b "${disk}" ]]; then
            echo "NOT FOUND" >&2
            exit 1
        fi

        dev=$(readlink -f "${disk}")
        if ! [[ -b "${dev}" ]]; then
            echo "NOT FOUND" >&2
            exit 1
        fi

        echo "$dev" >&2
        eval "${dest_var}[$disk]=\"$dev\""

        "$blockdev_bin" --report "$disk" >&2
        echo >&2
    done
}

msg "Using pool name '${pool_name}'"

msg "Using ${hdd_count} HDDs: "
declare -A hdd_devs
check_disks "hdd_devs" "${hdds[@]}"

msg "Using ${ssd_count} SSDs: "
declare -A ssd_devs
check_disks "ssd_devs" "${ssds[@]}"

### Confirm with user before real actions ###

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

    msg "Destroying existing pool" >&2
    cmd "$zpool_bin" destroy "$pool_name" 
fi

### Partition SSDs ###

msg "Partitioning SSDs" 

# Guarantee partition alignment
sgdisk_bin="${sgdisk_bin} -a 2048"

refresh_disk()
{
    if (( test_only )); then
        return 0
    fi

    sleep 1
    cmd "$blockdev_bin" --rereadpt "$1"
}

# Queue partition creation so it can all be done at once and avoid multiple
# partition refreshes
part_queue_start()
{ 
    _part_queue_cmd="$sgdisk_bin '$1'"
    _part_queue_num=0
}

rand_uuid()
{
    cat /proc/sys/kernel/random/uuid
}

part_queue_add()
{
    local size="$1" label="$2" type="$3" uuid_var="$4"
    local num=$(( ++_part_queue_num )) uuid=$(rand_uuid)
    local flags=\
"--new='${num}:0:${size}' -c '${num}:${label}' -t '${num}:${type}' -u '${num}:${uuid}'"

    msg "    partition ${num}"
    local prop
    for prop in size label type uuid; do
        msg "      ${prop} = ${!prop}"
    done

    _part_queue_cmd="${_part_queue_cmd} ${flags}"
    eval "$uuid_var"="$uuid"
}

part_queue_apply()
{
    eval "cmd ${_part_queue_cmd}"
    unset _part_queue_cmd _part_queue_num
}

# Gather up create partitions of each type so they can be mirroed together later
declare -a efi_uuids boot_uuids swap_uuids slog_uuids l2arc_uuids

for ssd in "${ssds[@]}"; do
    msg "  ${ssd}" 

    cmd "$zpool_bin" labelclear -f "$ssd"
    refresh_disk "$ssd"

    cmd $sgdisk_bin "$ssd" --clear
    refresh_disk "$ssd"
    
    part_queue_start "$ssd"

    part_queue_add "+${efi_size}" "EFI System Partition" ef00 efi_uuid
    efi_uuids+=("$efi_uuid")

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

    # Clear any possibly existing ZFS metadata to make sure zpool creation will
    # succeed later
    for uuid in $efi_uuid $boot_uuid $swap_uuid $slog_uuid $l2arc_uuid; do
        cmd "$zpool_bin" labelclear -f "/dev/disk/by-partuuid/${uuid}"
    done

    refresh_disk "$ssd"
done

# Wait for partitions again just to be sure
cmd "$udevadm_bin" settle

# Generate a sequence of partition names, possibly with a prefix and/or
# interleaved with mirror specifications (for ZFS)
dev_refs()
{
    local prefix="$1" mirror="$2"
    case "$mirror" in
    mirror)    mirror=1 ;;
    no-mirror) mirror=0 ;;
    *) return 1
    esac

    shift 2

    if (( $# < 2 )); then
        mirror=0
    fi

    local i=0
    for dev in "$@"; do
        if (( mirror && i % 2 == 0 )); then
            echo -n "mirror "
        fi
        
        echo -n "${prefix}${dev} "
        (( ++i ))
    done

    return 0
}

mdadm_create()
{
    local name="$1" level="$2"
    if [[ -z "$name" || -z "$level" ]]; then
        return 1
    fi

    shift 2
    if (( $# < 1 )); then
        return 2
    fi

    local dev md_dev="/dev/md/${name}"
    msg "  create ${md_dev} ${level}"
    for dev in "$@"; do
        msg "    using ${dev}"
    done

    yes | cmd "$mdadm_bin" --create "$md_dev" \
     --homehost="$target_hostname" \
     --assume-clean --level="$level" --raid-devices="$#" --metadata=1.0 \
     "$@" >&2

    local ret=$?
    if (( ret == 0 )); then
        eval "${name}_dev"="$md_dev"
    fi

    return $ret
}

# Create RAID devices if using more than one SSD
check_dev_exists()
{
    if [[ -z "$1" ]]; then
        err "Empty device"
    elif (( test_only == 0 )) && ! [[ -b "$1" ]]; then
        err "Failed to create or start device '$1'"
    else
        return 0
    fi

    return 1
}

if (( ssd_count > 1 )); then
    msg "Creating MDADM devices" 

    # Commands set efi_dev, boot_dev and swap_dev
    mdadm_create efi mirror \
     $(dev_refs /dev/disk/by-partuuid/ no-mirror "${efi_uuids[@]}")
    check_dev_exists "$efi_dev"

    mdadm_create boot mirror \
     $(dev_refs /dev/disk/by-partuuid/ no-mirror "${boot_uuids[@]}")
    check_dev_exists "$boot_dev"

    mdadm_create swap mirror \
     $(dev_refs /dev/disk/by-partuuid/ no-mirror "${swap_uuids[@]}")
    check_dev_exists "$swap_dev"

    cmd "$udevadm_bin" settle
else
    efi_dev="/dev/disk/by-partuuid/${efi_uuids[0]}"
    boot_dev="/dev/disk/by-partuuid/${boot_uuids[0]}"
    swap_dev="/dev/disk/by-partuuid/${swap_uuids[0]}"
fi

### Create filesystems on SSD ###

msg "Creating filesystems"

msg "  /boot/efi"
cmd "$mkfs_vfat_bin" -n "EFI System Partition" "$efi_dev"

msg "  /boot"
cmd "$mkfs_ext2_bin" -L "/boot" "$boot_dev"

msg "  swap"
cmd "$mkswap_bin" --label "${target_hostname}-swap" "$swap_dev"

### Prepare HDDs ###

msg "Clearing HDDs" 

for hdd in "${hdds[@]}"; do
    msg "  ${hdd}" 
    
    cmd "$zpool_bin" labelclear -f "$hdd"
    refresh_disk "$hdd"
    
    cmd $sgdisk_bin "$hdd" --clear
    refresh_disk "$hdd"
done

msg "Creating pool" 
cmd "$zpool_bin" create -m none -R "$mount_path" -o ashift=12 "$pool_name" \
 $(dev_refs '' mirror "${hdds[@]}")

msg "Adding SLOG to pool" 
cmd "$zpool_bin" add "$pool_name" log \
 $(dev_refs /dev/disk/by-partuuid/ mirror "${slog_uuids[@]}")


msg "Adding caches to pool" 
cmd "$zpool_bin" add "$pool_name" cache \
 $(dev_refs /dev/disk/by-partuuid/ no-mirror "${l2arc_uuids[@]}")

zpool_create()
{
    local fs="${pool_name}/$1"
    msg "  ${fs}" >&2
    cmd "$zfs_bin" create "$fs" -o mountpoint="$2"
}

msg "Creating ZFS filesystems on ${pool_name}"
zpool_create "root" none
zpool_create "root/debian" /

zpool_set()
{
    msg "  $1 = $2" >&2
    cmd "$zpool_bin" set "$1"="$2" "$pool_name"
}

msg "Setting ZFS pool options on ${pool_name}" 
zpool_set bootfs "${pool_name}/root/debian"