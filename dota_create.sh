#!/bin/bash

src_dir=$(dirname "{BASH_SOURCE[0]}")
"${src_dir}/zfs_create.sh" \
  -h dota.linux.ime.usp.br -m /mnt/dota -e 256M -b 256M -w 1024M -l 1024M \
  -d wwn-0x6c81f660db7624001a82f0de0f68e96b \
  -d wwn-0x6c81f660db7624001a82f0f710de325c \
  -d wwn-0x6c81f660db7624001a82f10711d5e9a5 \
  -d wwn-0x6c81f660db7624001a82f11712d2fe80 \
  -d wwn-0x6c81f660db7624001a82f12713c26bcc \
  -d wwn-0x6c81f660db7624001a82f13614a1c590 \
  -s wwn-0x6c81f660db7624001a82f16017237ae7 \
  -s wwn-0x6c81f660db7624001a82f171182cc38b "$@"