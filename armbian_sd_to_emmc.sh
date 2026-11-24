#!/usr/bin/env bash
# Clone the running Armbian SD installation to the G280/PX30 eMMC.
# Fixed devices: SD=/dev/mmcblk0, eMMC=/dev/mmcblk2
# This is the tested sgdisk + partprobe + rsync method.
set -Eeuo pipefail

SRC=/dev/mmcblk0
DST=/dev/mmcblk2
SRC_BOOT=${SRC}p1
SRC_ROOT=${SRC}p2
DST_BOOT=${DST}p1
DST_ROOT=${DST}p2
M=/mnt/g280-emmc

cleanup() {
  sync || true
  umount "$M/boot" 2>/dev/null || true
  umount "$M" 2>/dev/null || true
  rmdir "$M" 2>/dev/null || true
}
trap cleanup EXIT

die() { echo "ERROR: $*" >&2; exit 1; }

echo "Checking SD and eMMC layout ..."
[[ $EUID -eq 0 ]] || die "run with sudo"
[[ -b $SRC && -b $DST ]] || die "expected /dev/mmcblk0 and /dev/mmcblk2"
[[ -e /sys/block/mmcblk2/mmcblk2boot0 && -e /sys/block/mmcblk2/mmcblk2boot1 ]] || die "/dev/mmcblk2 is not eMMC"
findmnt -rn -S "$SRC_BOOT" -o TARGET | grep -qx /boot || die "SD p1 is not mounted at /boot"
findmnt -rn -S "$SRC_ROOT" -o TARGET | grep -qx / || die "SD p2 is not the running root"

SRC_BOOT_START=$(cat /sys/block/mmcblk0/mmcblk0p1/start)
[[ $SRC_BOOT_START == 32768 ]] || die "SD p1 must start at LBA 32768 (got $SRC_BOOT_START)"
[[ $(blockdev --getsize64 "$SRC_BOOT") -le $((512*1024*1024)) ]] || die "SD /boot is larger than 512 MiB"
[[ -z $(lsblk -nrno PATH,MOUNTPOINTS "$DST" | awk 'NF>1') ]] || die "eMMC or one of its partitions is mounted"

used=$(df -B1 -P / | awk 'NR==2 {print $3}')
available=$(( ($(cat /sys/block/mmcblk2/size) - 1081472) * 512 ))
(( used + (512*1024*1024) < available )) || die "not enough space on eMMC"

# Install the four optional tools if they are missing. Package names:
#   sgdisk     -> gdisk
#   partprobe  -> parted
#   rsync      -> rsync
#   mkfs.ext4  -> e2fsprogs
missing_pkgs=""
add_missing_pkg() {
  local cmd=$1 pkg=$2
  if ! command -v "$cmd" >/dev/null 2>&1; then
    case " $missing_pkgs " in
      *" $pkg "*) ;;
      *) missing_pkgs+=" $pkg" ;;
    esac
  fi
}
add_missing_pkg sgdisk gdisk
add_missing_pkg partprobe parted
add_missing_pkg rsync rsync
add_missing_pkg mkfs.ext4 e2fsprogs

if [[ -n "${missing_pkgs# }" ]]; then
  echo "Missing tools; installing packages:${missing_pkgs}"
  command -v apt >/dev/null 2>&1 || die "apt not found; install manually:${missing_pkgs}"
  export DEBIAN_FRONTEND=noninteractive
  apt update
  # shellcheck disable=SC2086
  apt install -y --no-install-recommends $missing_pkgs
fi

for cmd in sgdisk partprobe rsync mkfs.ext4 blkid findmnt lsblk blockdev dd sed grep install df awk udevadm; do
  command -v "$cmd" >/dev/null 2>&1 || die "missing command after package installation: $cmd"
done

echo "Creating GPT with sgdisk on $DST ..."
sgdisk --zap-all "$DST"
sgdisk --clear \
  --new=1:32768:+512M \
  --typecode=1:8300 \
  --change-name=1:boot \
  --new=2:0:0 \
  --typecode=2:8300 \
  --change-name=2:root \
  "$DST"

echo "Refreshing partition table ..."
partprobe "$DST"
udevadm settle --timeout=30

for i in {1..50}; do
  [[ -b $DST_BOOT && -b $DST_ROOT ]] && break
  sleep 0.1
done
[[ -b $DST_BOOT && -b $DST_ROOT ]] || die "new eMMC partition nodes did not appear"
udevadm settle --timeout=30
[[ -b $DST_BOOT && -b $DST_ROOT ]] || die "eMMC partition nodes disappeared after udev settle"
[[ $(blockdev --getsize64 "$DST_BOOT") == 536870912 ]] || die "unexpected eMMC boot partition size"

echo "Copying Rockchip bootloader raw area ..."
dd if="$SRC" of="$DST" bs=512 skip=64 seek=64 \
  count=$((SRC_BOOT_START-64)) conv=nocreat,fsync status=progress

echo "Cloning SD /boot partition ..."
dd if="$SRC_BOOT" of="$DST_BOOT" bs=4M conv=nocreat,fsync status=progress iflag=fullblock

echo "Creating ext4 root filesystem ..."
mkfs.ext4 -F -L armbi_root "$DST_ROOT"

echo "Mounting eMMC filesystems ..."
mkdir -p "$M" "$M/boot"
mount "$DST_ROOT" "$M"
mount "$DST_BOOT" "$M/boot"

echo "Copying SD root filesystem with rsync ..."
rsync -aHAXx --numeric-ids --delete --info=progress2 \
  --exclude='/proc/*' \
  --exclude='/sys/*' \
  --exclude='/dev/*' \
  --exclude='/run/*' \
  --exclude='/tmp/*' \
  --exclude='/mnt/*' \
  --exclude='/media/*' \
  --exclude='/boot/*' \
  --exclude='/var/log.hdd/*' \
  --exclude='/lost+found' \
  / "$M/"

install -d -m 0755 \
  "$M"/proc "$M"/sys "$M"/dev "$M"/run "$M"/tmp \
  "$M"/mnt "$M"/media "$M"/var/log.hdd
chmod 1777 "$M/tmp"

echo "Updating root UUID and PARTUUID references ..."
old_uuid=$(blkid -s UUID -o value "$SRC_ROOT")
new_uuid=$(blkid -s UUID -o value "$DST_ROOT")
old_rpart=$(blkid -s PARTUUID -o value "$SRC_ROOT")
new_rpart=$(blkid -s PARTUUID -o value "$DST_ROOT")
old_bpart=$(blkid -s PARTUUID -o value "$SRC_BOOT")
new_bpart=$(blkid -s PARTUUID -o value "$DST_BOOT")
[[ -n $old_uuid && -n $new_uuid ]] || die "cannot read root UUIDs"

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

# PX30 eMMC can enumerate slightly later than SD. Ensure the kernel waits.
extlinux="$M/boot/extlinux/extlinux.conf"
if [[ -f "$extlinux" ]]; then
  echo "Boot root command line before fixes:"
  grep -i 'root=' "$extlinux" || true

  if ! grep -Eqi 'root=.*rootwait|rootwait.*root=' "$extlinux"; then
    echo "Adding rootwait ..."
    sed -i '/root=/ s/$/ rootwait/' "$extlinux"
  fi
  if ! grep -Eqi 'root=.*rootdelay=|rootdelay=.*root=' "$extlinux"; then
    echo "Adding rootdelay=5 ..."
    sed -i '/root=/ s/$/ rootdelay=5/' "$extlinux"
  fi

  echo "Boot root command line after fixes:"
  grep -i 'root=' "$extlinux" || true
  grep -Eqi 'root=.*rootwait|rootwait.*root=' "$extlinux" || die "failed to add rootwait"
  grep -Eqi 'root=.*rootdelay=|rootdelay=.*root=' "$extlinux" || die "failed to add rootdelay"
fi

echo "Syncing and unmounting ..."
sync
umount "$M/boot"
umount "$M"
rmdir "$M"

echo "Done. Power off, remove the micro SD card, then boot from eMMC."
