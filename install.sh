#!/bin/bash

set -e
cd /root

# Fix base repos

sed -i -e 's/main$/main contrib non-free/' \
 -e 's/http\.debian\.net/sft.if.usp.br/' /etc/apt/sources.list

cat > /etc/apt/sources.list.d/wheezy-backports.list <<'EOF'
deb http://sft.if.usp.br/debian wheezy-backports main contrib non-free
deb-src http://sft.if.usp.br/debian wheezy-backports main contrib non-free
EOF

# Add ZFS repo

wget -N http://archive.zfsonlinux.org/debian/pool/main/z/zfsonlinux/zfsonlinux_2%7Ewheezy_all.deb
dpkg -i zfsonlinux_2~wheezy_all.deb

apt-get update

# Install base packages

tasksel install standard ssh-server
apt-get install -y locales nano vim

# Install kernel packages

apt-get install -y firmware-linux-nonfree linux-{image,headers}-amd64 \
 gdisk dosfstools e2fsprogs

apt-get install -y -t wheezy-backports linux-{image,headers}-3.12-0.bpo.1-amd64 
  
apt-get install -y debian-zfs

# Check ZFS

modprobe zfs
if dmesg | grep -q 'ZFS:'; then
	echo 'ZFS OK.'
else
	echo 'ZFS module not running, check errors.'
	exit 1
fi