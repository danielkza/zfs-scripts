#!/bin/sh

set -e

APT_GET_INSTALL='apt-get install -y --no-install-suggests'

os_codename=$(lsb_release -s -c)
case "$os_codename" in
wheezy) : ;;
lucid|precise|trusty) : ;;
*)
    echo "Error: Unsupported OS codename ${os_codename}" >&2
    exit 1
esac 

echo "deb http://linux.dell.com/repo/community/ubuntu ${os_codename} openmanage" \
 > /etc/apt/sources.list.d/dell-openmanage.list 
sudo apt-key adv --keyserver pool.sks-keyservers.net --recv 1285491434D8786F

apt-get update

$APT_GET_INSTALL srvadmin-idrac7 srvadmin-storageservices dcism
$APT_GET_INSTALL acpid

bl_nv=/etc/modprobe.d/blacklist-nouveau.conf
if ! [ -f "$bl_nv" ]; then
    echo 'blacklist nouveau' > "$bl_nv"
fi