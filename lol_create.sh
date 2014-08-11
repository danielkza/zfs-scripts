#!/bin/bash

set -e

b=/dev/disk/by-id
src_dir=$(readlink -f $(dirname "{BASH_SOURCE[0]}"))

"${src_dir}/zfs_create.sh" \
  -n dota.linux.ime.usp.br -m /mnt/dota -e 256M -b 256M -w 1024M -l 1024M \
  -d $b/wwn-0x6c81f660db761a001a8260d3b2b0bb01 \
  -d $b/wwn-0x6c81f660db761a001a8261a5bf31c4cd \
  -d $b/wwn-0x6c81f660db761a001a8261b8c04a279e \
  -d $b/wwn-0x6c81f660db761a001a8261cbc170ed49 \
  -d $b/wwn-0x6c81f660db761a001a8261f3c3cc9d80 \
  -d $b/wwn-0x6c81f660db761a001a826200c4a1b5ba \
  -s $b/wwn-0x6c81f660db761a001a8262ced0e83e95 \
  -s $b/wwn-0x6c81f660db761a001a826315d5220d35 \
  "$@"