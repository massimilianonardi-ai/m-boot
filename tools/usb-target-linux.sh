#!/bin/sh
# Linux-specific operations sourced by usb-install.sh; no independent CLI.
usb_require()
{
  for cmd in lsblk blockdev sgdisk partprobe udevadm mkfs.exfat mount umount fsck.exfat findmnt
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
  [ "$(lsblk -dnro TYPE "$1" 2>/dev/null)" = disk ] || return 1
  transport=$(lsblk -dnro TRAN "$1" | tr -d '[:space:]')
  removable=$(lsblk -dnro RM "$1" | tr -d '[:space:]')
  hotplug=$(lsblk -dnro HOTPLUG "$1" | tr -d '[:space:]')
  [ "$transport" = usb ] || [ "$transport" = thunderbolt ] ||
    [ "$removable" = 1 ] || [ "$hotplug" = 1 ]
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
  # Reject active host resources rather than unmounting a system filesystem.
  if lsblk -nrpo MOUNTPOINT "$usb_disk" | grep -q '[^[:space:]]'
  then
    usb_fail 'selected disk has a mounted filesystem; no data written'
  fi
  if lsblk -nrpo FSTYPE "$usb_disk" | grep -q '^swap$'
  then
    usb_fail 'selected disk contains swap; no data written'
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
