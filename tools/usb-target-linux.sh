#!/bin/sh
# Linux-specific operations sourced by usb-install.sh; no independent CLI.
usb_require()
{
  for cmd in lsblk blockdev sgdisk partprobe udevadm mkfs.exfat mount umount fsck.exfat findmnt swapon
  do
    command -v "$cmd" >/dev/null 2>&1 || usb_fail "missing Linux tool: $cmd"
  done
}
usb_list()
{
  lsblk -dpno NAME,TYPE | awk '$2 == "disk" { print $1 }' |
    while IFS= read -r device
    do
      usb_eligible "$device" && printf '%s\n' "$device"
    done
}
usb_eligible()
{
  [ "$(lsblk -dnro TYPE "$1" 2>/dev/null)" = disk ]
}
usb_brief()
{
  lsblk -dnro SIZE,MODEL,TRAN "$1"
}
usb_describe()
{
  lsblk -o NAME,PATH,MODEL,SERIAL,SIZE,TYPE,TRAN,LOG-SEC,FSTYPE,LABEL,PARTLABEL,MOUNTPOINTS "$1"
}
usb_size()
{
  blockdev --getsize64 "$1"
}
usb_sector()
{
  blockdev --getss "$1"
}
usb_identity()
{
  stat -c '%t:%T' "$1"
}
usb_prepare()
{
  [ "$(usb_size "$usb_disk")" = "$usb_bytes" ] || usb_fail 'disk size changed'
  [ "$(usb_identity "$usb_disk")" = "$usb_id" ] || usb_fail 'disk identity changed'
  # Only after explicit confirmation: unmount ordinary data volumes. Never
  # unmount host system paths, active swap, or the checkout running this script.
  lsblk -pnro NAME "$usb_disk" > "$usb_work/children" ||
    usb_fail 'cannot inspect child devices'
  swapon --noheadings --show=NAME > "$usb_work/swaps" ||
    usb_fail 'cannot inspect active swap'
  while IFS= read -r node
  do
    if grep -Fx "$node" "$usb_work/swaps" >/dev/null
    then
      usb_fail "active swap prevents imaging: $node"
    fi
    findmnt -rn -S "$node" -o TARGET > "$usb_work/mounts" || :
    while IFS= read -r where
    do
      [ -n "$where" ] || continue
      case "$where" in
        /media/*|/run/media/*|/mnt/*) ;;
        *) usb_fail "refusing to unmount system or non-data location: $where" ;;
      esac
      case "$root/" in
        "$where/"*) usb_fail "repository is on selected disk: $where" ;;
      esac
      usb_info "unmounting selected disk filesystem: $where"
      sudo umount "$node" || usb_fail "cannot unmount $where on $node"
    done < "$usb_work/mounts"
  done < "$usb_work/children"
  if lsblk -nrpo MOUNTPOINT "$usb_disk" | grep -q '[^[:space:]]'
  then
    usb_fail 'some selected-disk filesystems remain mounted'
  fi
}
usb_write()
{
  sudo dd if="$usb_work/m-boot-combined.raw" of="$usb_disk" bs=4M conv=fsync status=progress
}
usb_refresh()
{
  sudo partprobe "$usb_disk" || usb_fail 'kernel did not reread GPT'
  sudo udevadm settle || usb_fail 'device events did not settle'
  usb_partition=$(lsblk -pnro PATH,PARTN "$usb_disk" | awk '$2 == "3" { print $1 }')
  [ -n "$usb_partition" ] && [ -b "$usb_partition" ] ||
    usb_fail 'partition 3 is not visible to the kernel'
  [ "$(lsblk -bnro START "$usb_partition")" = 1071104 ] ||
    usb_fail 'kernel has an unexpected third-partition start'
}
usb_format_mount()
{
  sudo mkfs.exfat -n MBOOTDATA "$usb_partition" || usb_fail 'exFAT formatting failed'
  mkdir "$usb_work/mount" || usb_fail 'cannot prepare mount directory'
  sudo mount -t exfat -o "uid=$(id -u),gid=$(id -g)" "$usb_partition" "$usb_work/mount" ||
    usb_fail 'cannot mount new exFAT filesystem'
  usb_mounted="$usb_work/mount"
  usb_mountpoint="$usb_mounted"
}
usb_unmount()
{
  sudo umount "$usb_mounted" || usb_fail 'cannot unmount data partition'
  usb_mounted=
}
usb_check_fs()
{
  sudo fsck.exfat -n "$usb_partition" || usb_fail 'exFAT integrity check failed'
}
