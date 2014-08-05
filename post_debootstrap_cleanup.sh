#!/bin/bash

if [ $# -lt 1 ]; then
    echo "Usage: $0 target_path"
    exit 1
fi

target="$1"

if [ -z "$target" ] || ! [ -d "$target" ]; then
    echo "Invalid target dir '$target'"
    exit 1
fi

rm "${target}/usr/sbin/policy-rc.d"

for path in boot/efi boot sys proc dev/pts dev; do
	umount "${target}/${path}"
done