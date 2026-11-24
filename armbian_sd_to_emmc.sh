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
if [[ -f /boot/boot.scr ]]; then
  add_missing_pkg mkimage u-boot-tools
fi

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
rsync_rc=0
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
  / "$M/" || rsync_rc=$?

# Exit 24 means some source files vanished while the live system was running.
# That is normal for a running Armbian root and must not abort the clone before
# UUID/boot configuration fixes are applied.
if (( rsync_rc != 0 && rsync_rc != 24 )); then
  die "rsync failed with exit code $rsync_rc"
elif (( rsync_rc == 24 )); then
  echo "rsync reported transient source-file changes (exit 24); continuing ..."
fi

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
boot_uuid=$(blkid -s UUID -o value "$DST_BOOT")
[[ -n $old_uuid && -n $new_uuid ]] || die "cannot read root UUIDs"
[[ -n $boot_uuid ]] || die "cannot read eMMC boot UUID"

# Some Armbian images ship only a binary boot.scr. A legacy U-Boot script
# image has a 64-byte header followed by the plain-text script, so extract it
# directly instead of relying on dumpimage (which rejects script images).
if [[ -f "$M/boot/boot.scr" && ! -f "$M/boot/boot.cmd" ]]; then
  echo "Extracting boot.cmd from existing boot.scr ..."
  dd if="$M/boot/boot.scr" of="$M/boot/boot.cmd" bs=64 skip=1 status=none
fi

# Make sure armbianEnv.txt explicitly points at the eMMC root and waits for it.
armbian_env="$M/boot/armbianEnv.txt"
if [[ -f "$armbian_env" ]]; then
  if grep -q '^rootdev=' "$armbian_env"; then
    sed -i "s|^rootdev=.*|rootdev=UUID=$new_uuid|" "$armbian_env"
  else
    echo "rootdev=UUID=$new_uuid" >> "$armbian_env"
  fi

  # boot.cmd usually expands ${extraargs}; put the wait flags there.
  if grep -q '^extraargs=' "$armbian_env"; then
    sed -i '/^extraargs=/ { /rootwait/! s/$/ rootwait/; /rootdelay=/! s/$/ rootdelay=5/ }' "$armbian_env"
  else
    echo "extraargs=rootwait rootdelay=5" >> "$armbian_env"
  fi
fi

replace() {
  grep -RIlZ -- "$1" "$M/boot" "$M/etc" 2>/dev/null |
  while IFS= read -r -d '' f; do
    echo "Updating $f"
    sed -i "s|$1|$2|g" "$f"
  done || true
}
replace "$SRC_ROOT" "UUID=$new_uuid"
replace "$SRC_BOOT" "UUID=$boot_uuid"
replace "$old_uuid" "$new_uuid"
replace "$old_rpart" "$new_rpart"
replace "$old_bpart" "$new_bpart"

# Armbian often boots via a binary boot.scr generated from boot.cmd. The text
# replacement above updates boot.cmd, so regenerate boot.scr when both exist.
if [[ -f "$M/boot/boot.cmd" ]]; then
  # Force the root device in boot.cmd itself. Do not rely on U-Boot's saved
  # environment or on armbianEnv.txt being imported by every boot.cmd variant.
  if grep -q '^setenv rootdev' "$M/boot/boot.cmd"; then
    sed -i "s|^setenv rootdev .*|setenv rootdev UUID=$new_uuid|" "$M/boot/boot.cmd"
  else
    sed -i "1i setenv rootdev UUID=$new_uuid" "$M/boot/boot.cmd"
  fi
  if ! grep -q '^setenv rootfstype' "$M/boot/boot.cmd"; then
    sed -i "1i setenv rootfstype ext4" "$M/boot/boot.cmd"
  fi

  # Put the root-device wait flags on the actual bootargs line. This works even
  # when boot.cmd builds bootargs from armbianEnv.txt variables.
  if ! grep -q 'rootwait' "$M/boot/boot.cmd"; then
    sed -i '/setenv bootargs/ s/"[[:space:]]*$/ rootwait rootdelay=5"/' "$M/boot/boot.cmd"
  fi
fi

if [[ -f "$M/boot/boot.cmd" && -f "$M/boot/boot.scr" ]]; then
  echo "Regenerating boot.scr from updated boot.cmd ..."
  mkimage -C none -T script -d "$M/boot/boot.cmd" "$M/boot/boot.scr"
fi

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

# Refuse to finish if the cloned boot configuration still points at the SD root.
for f in "$M/boot/extlinux/extlinux.conf" "$M/boot/armbianEnv.txt"          "$M/boot/boot.cmd" "$M/boot/boot.scr" "$M/etc/fstab"; do
  [[ -f "$f" ]] || continue
  if grep -a -q -e "$SRC_ROOT" -e "$SRC_BOOT" -e "$old_uuid" -e "$old_rpart" "$f"; then
    echo "ERROR: old SD root/boot reference remains in $f:"
    grep -a -n -e "$SRC_ROOT" -e "$SRC_BOOT" -e "$old_uuid" -e "$old_rpart" "$f" || true
    die "boot configuration still references the SD card"
  fi
done

echo "Final boot configuration summary:"
echo "  eMMC root UUID: $new_uuid"
echo "  eMMC boot UUID: $boot_uuid"
if [[ -f "$M/boot/extlinux/extlinux.conf" ]]; then
  echo "  extlinux root line:"
  grep -i 'root=' "$M/boot/extlinux/extlinux.conf" || true
fi
if [[ -f "$M/boot/armbianEnv.txt" ]]; then
  echo "  armbianEnv root/extraargs:"
  grep -E '^(rootdev|extraargs)=' "$M/boot/armbianEnv.txt" || true
fi
if [[ -f "$M/boot/boot.scr" ]]; then
  echo "  boot.scr root references:"
  strings "$M/boot/boot.scr" | grep -Ei 'root=|rootdev|mmcblk|UUID=' || true
fi

echo "Syncing and unmounting ..."
sync
umount "$M/boot"
umount "$M"
rmdir "$M"

echo "Done. Power off, remove the micro SD card, then boot from eMMC."
