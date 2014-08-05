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

umount "${target}/sys"
umount "${target}/proc"
umount "${target}/dev/pts"
umount "${target}/dev"