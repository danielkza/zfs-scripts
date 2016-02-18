#!/bin/bash

set -e

src_dir=$(readlink -f $(dirname "${BASH_SOURCE[0]}"))

mkdir -p /mnt/example

b=/dev/disk/by-id
"${src_dir}/zfs_create.sh" \
  -n dota -m /mnt/example -e 256M -b 256M -w 1024M -l 1024M \
  -d $b/wwn-0x6c81f660db7624001a82f0de0f68e96b \
  -d $b/wwn-0x6c81f660db7624001a82f0f710de325c \
  -d $b/wwn-0x6c81f660db7624001a82f10711d5e9a5 \
  -d $b/wwn-0x6c81f660db7624001a82f11712d2fe80 \
  -d $b/wwn-0x6c81f660db7624001a82f12713c26bcc \
  -d $b/wwn-0x6c81f660db7624001a82f13614a1c590 \
  -s $b/wwn-0x6c81f660db7624001a82f16017237ae7 \
  -s $b/wwn-0x6c81f660db7624001a82f171182cc38b \
  "$@"
