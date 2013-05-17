#!/bin/bash
#Author: Peter M. Petrakis <peter.petrakis@gmail.com>

raid_chunk=32

echo "WARNING: proceeding will nuke the SAS disks and create RAID from scratch: [y/n]"
read -p "Continue (y/n)?" choice

case "$choice" in 
  y|Y ) : ;;
  n|N ) exit;;
  * ) echo "invalid"; exit;;
esac

for disk in $(ls /dev/disk/by-path/pci-0000:03:00.0-sas*lun-0);
do
  echo "Clearing $disk"
  echo -e "\t zapping mdadm superblock"
  mdadm --zero-superblock $disk > /dev/null 2>&1

  echo -e "\t use dd to zero disk"
  dd if=/dev/zero of=$disk bs=1M count=10 > /dev/null 2>&1
  sync

  echo -e "\t creating RAID partition that spans whole disk"
  (echo n; echo p; echo 1; echo ; echo; echo t; echo fd; echo w) | fdisk $disk > /dev/null 2>&1

  #echo "verifying..."
  #(echo p; echo q) | fdisk $disk 2> /dev/null

  sleep 1
done

echo "prepare to assemble array"

members=
let count=0
# NOTE, we're using partitions
for disk in $(ls /dev/disk/by-path/pci-0000:03:00.0-sas*lun-0-part1);
do  
  (( count += 1 ))
  members+=$disk
  members+=' '
  # I know it's redundant, but it can't hurt
  mdadm --zero-superblock $disk > /dev/null 2>&1
done

echo "creating md0 device"
mknod /dev/md0 b 9 0
echo "executiing mdadm"

set -x
mdadm --create /dev/md0 -v --raid-devices=$count \
      --level=raid10 \
      --bitmap=internal \
      --chunk=$raid_chunk \
      ${members}
set +x

sleep 5

conf=/etc/mdadm/mdadm.conf
echo "building $conf"
uuid=$(mdadm -D /dev/md0  | sed -En 's/UUID : (.+)/\1/p' | head -n1 | tr -d ' ')
cat > $conf << EOF
# mdadm.conf
#
# Please refer to mdadm.conf(5) for information about this file.
#
 
# by default, scan all partitions (/proc/partitions) for MD superblocks.
# alternatively, specify devices to scan, using wildcards if desired.
DEVICE partitions
 
# auto-create devices with Debian standard permissions
CREATE owner=root group=disk mode=0660 auto=yes
 
# automatically tag new arrays as belonging to the local system
HOMEHOST 
 
# instruct the monitoring daemon where to send mail alerts
MAILADDR root
 
# definitions of existing MD arrays
ARRAY /dev/md0 level=raid10 num-devices=$count UUID=$uuid
EOF
echo "please review $conf"

# XXX need sed magic for /etc/defaults/grub.conf to append arg
echo "XXX add scsi_mod.scan=sync to grub.conf and update-grub"

echo "copying mdadm config to initrd"
update-initramfs -u -k all

echo "done."
