#!/usr/bin/env bash
# Offline G280/PX30 installer: clone running Armbian from micro SD to eMMC.
set -Eeuo pipefail

SRC=/dev/mmcblk0
DST=/dev/mmcblk2
SRC_BOOT=${SRC}p1
SRC_ROOT=${SRC}p2
DST_BOOT=${DST}p1
DST_ROOT=${DST}p2
M=/mnt/g280-emmc
S=/mnt/g280-source
NODE_P1=""
NODE_P2=""

cleanup() {
  sync || true
  umount "$M/boot" 2>/dev/null || true
  umount "$M" 2>/dev/null || true
  umount "$S" 2>/dev/null || true
  rmdir "$M" "$S" 2>/dev/null || true
  rm -f "$NODE_P1" "$NODE_P2" 2>/dev/null || true
}
trap cleanup EXIT

die() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run with sudo"
[[ -b $SRC && -b $DST ]] || die "expected /dev/mmcblk0 and /dev/mmcblk2"
[[ -e /sys/block/mmcblk2/mmcblk2boot0 && -e /sys/block/mmcblk2/mmcblk2boot1 ]] || die "/dev/mmcblk2 is not eMMC"
findmnt -rn -S "$SRC_BOOT" -o TARGET | grep -qx /boot || die "SD p1 is not mounted at /boot"
findmnt -rn -S "$SRC_ROOT" -o TARGET | grep -qx / || die "SD p2 is not the running root"
[[ $(cat /sys/block/mmcblk0/mmcblk0p1/start) == 32768 ]] || die "SD p1 must start at LBA 32768"
[[ $(blockdev --getsize64 "$SRC_BOOT") -le $((512*1024*1024)) ]] || die "SD /boot is larger than 512 MiB"
[[ -z $(lsblk -nrno PATH,MOUNTPOINTS "$DST" | awk 'NF>1') ]] || die "eMMC or one of its partitions is mounted"

used=$(df -B1 -P / | awk 'NR==2 {print $3}')
available=$(( ($(cat /sys/block/mmcblk2/size) - 1081472) * 512 ))
(( used + (512*1024*1024) < available )) || die "not enough space on eMMC"

echo "Erasing and installing Armbian to $DST ..."
sfdisk --force "$DST" <<'PART'
label: gpt
unit: sectors
start=32768, size=1048576, type=linuxfilesystem, name=boot
start=1081344, type=linuxfilesystem, name=root
PART
blockdev --rereadpt "$DST"

# Wait for kernel partition objects. Do not depend on udev's /dev names:
# udev can briefly remove/recreate /dev/mmcblk2pN while this script continues.
for i in {1..100}; do
  [[ -r /sys/block/mmcblk2/mmcblk2p1/dev && -r /sys/block/mmcblk2/mmcblk2p2/dev ]] && break
  sleep 0.1
done
[[ -r /sys/block/mmcblk2/mmcblk2p1/dev && -r /sys/block/mmcblk2/mmcblk2p2/dev ]] || \
  die "kernel partition objects did not appear in sysfs"

p1dev=$(cat /sys/block/mmcblk2/mmcblk2p1/dev)
p2dev=$(cat /sys/block/mmcblk2/mmcblk2p2/dev)
p1major=${p1dev%:*}; p1minor=${p1dev#*:}
p2major=${p2dev%:*}; p2minor=${p2dev#*:}
[[ $p1major =~ ^[0-9]+$ && $p1minor =~ ^[0-9]+$ ]] || die "invalid eMMC p1 major/minor: $p1dev"
[[ $p2major =~ ^[0-9]+$ && $p2minor =~ ^[0-9]+$ ]] || die "invalid eMMC p2 major/minor: $p2dev"

# Private block nodes are created from the kernel major/minor and are not
# removed by udev. All later writes and mounts use these stable nodes.
NODE_P1=/tmp/g280-emmc-p1.$$
NODE_P2=/tmp/g280-emmc-p2.$$
rm -f "$NODE_P1" "$NODE_P2"
mknod -m 660 "$NODE_P1" b "$p1major" "$p1minor"
mknod -m 660 "$NODE_P2" b "$p2major" "$p2minor"
[[ -b $NODE_P1 && -b $NODE_P2 ]] || die "failed to create private eMMC block nodes"
[[ $(cat /sys/block/mmcblk2/mmcblk2p1/size) == 1048576 ]] || die "unexpected eMMC p1 size"
(( $(cat /sys/block/mmcblk2/mmcblk2p2/size) > 0 )) || die "unexpected eMMC p2 size"
DST_BOOT=$NODE_P1
DST_ROOT=$NODE_P2

# Copy Rockchip IDBlock/loader area, then the complete boot filesystem.
dd if=$SRC of=$DST bs=512 skip=64 seek=64 count=32704 conv=nocreat,fsync status=progress
dd if=$SRC_BOOT of=$DST_BOOT bs=4M conv=nocreat,fsync status=progress iflag=fullblock
mkfs.ext4 -F -m 0 -L armbi_root "$DST_ROOT"

echo "Mounting eMMC root filesystem ..."
mkdir -p "$M" "$S"
mount "$DST_ROOT" "$M"

# Non-recursive bind exposes only the root mount, not /proc, /sys, /boot, zram,
# or the destination mount. cp -a preserves permissions, links, timestamps, ACL/xattrs.
echo "Binding live SD root filesystem for offline copy ..."
mount --bind / "$S"

echo "Copying SD root filesystem to eMMC; this can take several minutes ..."
if ! cp -a "$S"/. "$M"/; then
  echo "First copy pass failed; retrying once ..."
  cp -a "$S"/. "$M"/
fi

echo "Root filesystem copy finished; unbinding SD root ..."
umount "$S"
rmdir "$S"

install -d -m 0755 "$M"/{proc,sys,dev,run,tmp,mnt,media,var/log,var/log.hdd}
chmod 1777 "$M/tmp"

echo "Mounting cloned eMMC boot partition ..."
mkdir -p "$M/boot"
mount "$DST_BOOT" "$M/boot"

# Replace all SD root references with the new eMMC root UUID.
old_uuid=$(blkid -s UUID -o value "$SRC_ROOT")
new_uuid=$(blkid -s UUID -o value "$DST_ROOT")
old_rpart=$(blkid -s PARTUUID -o value "$SRC_ROOT")
new_rpart=$(blkid -s PARTUUID -o value "$DST_ROOT")
old_bpart=$(blkid -s PARTUUID -o value "$SRC_BOOT")
new_bpart=$(blkid -s PARTUUID -o value "$DST_BOOT")
[[ -n $old_uuid && -n $new_uuid ]] || die "cannot read filesystem UUIDs"

replace() {
  grep -RIlZ -- "$1" "$M/boot" "$M/etc" 2>/dev/null |
  while IFS= read -r -d '' f; do
    echo "Updating $f"
    sed -i "s|$1|$2|g" "$f"
  done || true
}
replace "$SRC_ROOT" "UUID=$new_uuid"
replace "$old_uuid" "$new_uuid"
replace "$old_rpart" "$new_rpart"
replace "$old_bpart" "$new_bpart"

# eMMC enumeration can finish slightly later than the SD card used by the
# source image. Make the kernel wait for the root device before mounting it.
extlinux="$M/boot/extlinux/extlinux.conf"
[[ -f "$extlinux" ]] || die "missing extlinux.conf on cloned eMMC boot partition"
grep -q "UUID=$new_uuid" "$extlinux" || die "extlinux.conf does not reference the new eMMC root UUID"
echo "Boot root command line before fixes:"
grep -i 'root=' "$extlinux" || true

if ! grep -Eqi 'root=.*rootwait|rootwait.*root=' "$extlinux"; then
  echo "Adding rootwait to the line containing root= ..."
  sed -i '/root=/ s/$/ rootwait/' "$extlinux"
fi
if ! grep -Eqi 'root=.*rootdelay=|rootdelay=.*root=' "$extlinux"; then
  echo "Adding rootdelay=5 to the line containing root= ..."
  sed -i '/root=/ s/$/ rootdelay=5/' "$extlinux"
fi

echo "Boot root command line after fixes:"
grep -i 'root=' "$extlinux" || true
grep -Eqi 'root=.*rootwait|rootwait.*root=' "$extlinux" || die "failed to add rootwait"
grep -Eqi 'root=.*rootdelay=|rootdelay=.*root=' "$extlinux" || die "failed to add rootdelay"

sync
umount "$M/boot"
umount "$M"
rmdir "$M"
echo "Done. Power off, remove the micro SD card, then boot from eMMC."
