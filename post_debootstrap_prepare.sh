#!/bin/bash

set -e

target="$1"

if [[ -z "$target" ]]; then
    program=$(basename "$0")
    echo "Usage: ${program} target_path"
    exit 1
fi

if ! [[ -d "$target" ]]; then
    echo "Invalid target dir '${target}'"
    exit 1
fi

src_dir=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")")
post_strap="${src_dir}/post_debootstrap.sh"
zfs_prereqs="${src_dir}/zfs_prerequisites.sh"

if ! [[ -f "$post_strap" && -f "$zfs_prereqs" ]]; then
    echo "Missing scripts"
    exit 1
fi

cp "$post_strap" "$zfs_prereqs" "${target}/root/"
chmod +x "${target}"/root/*.sh

mkdir -p "${target}"/{boot,boot/efi,dev,proc,sys} 

mount --bind /dev "${target}/dev"
mount --bind /dev/pts "${target}/dev/pts"
mount --bind /proc "${target}/proc"
mount --bind /sys  "${target}/sys"

cat > "${target}/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF

chmod +x "${target}/usr/sbin/policy-rc.d"