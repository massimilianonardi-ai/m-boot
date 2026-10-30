#!/bin/sh
# macOS-specific operations sourced by usb-install.sh; no independent CLI.
usb_require()
{
  PATH="/opt/homebrew/sbin:/usr/local/sbin:$PATH"
  export PATH
  for cmd in diskutil plutil newfs_exfat fsck_exfat
  do
    command -v "$cmd" >/dev/null 2>&1 || usb_fail "missing macOS tool: $cmd"
  done
  if ! command -v sgdisk >/dev/null 2>&1
  then
    if command -v brew >/dev/null 2>&1
    then
      usb_info 'installing required gdisk tools through Homebrew'
      brew install gdisk || usb_fail 'automatic gdisk installation failed'
    elif [ -x /opt/homebrew/bin/brew ]
    then
      usb_info 'installing required gdisk tools through Homebrew'
      /opt/homebrew/bin/brew install gdisk || usb_fail 'automatic gdisk installation failed'
    else
      usb_fail 'sgdisk is absent and Homebrew is unavailable; no disk changes'
    fi
  fi
  command -v sgdisk >/dev/null 2>&1 || usb_fail 'sgdisk remains unavailable'
}
usb_plist_value()
{
  plutil -extract "$2" raw -o - "$1" 2>/dev/null || :
}
usb_plist()
{
  diskutil info -plist "$1" > "$usb_work/info.plist"
}
usb_eligible()
{
  usb_plist "$1" || return 1
  [ "$(usb_plist_value "$usb_work/info.plist" WholeDisk)" = true ] || return 1
  [ "$(usb_plist_value "$usb_work/info.plist" VirtualOrPhysical)" = Physical ]
}
usb_list()
{
  diskutil list physical |
    awk '/^\/dev\/disk[0-9]+ / { print $1 }' |
    while IFS= read -r device
    do
      usb_eligible "$device" && printf '%s\n' "$device"
    done
}
usb_brief()
{
  usb_plist "$1" || return 1
  printf '%s bytes  %s  %s\n' \
    "$(usb_plist_value "$usb_work/info.plist" TotalSize)" \
    "$(usb_plist_value "$usb_work/info.plist" MediaName)" \
    "$(usb_plist_value "$usb_work/info.plist" BusProtocol)"
}
usb_describe()
{
  diskutil info "$1" && diskutil list "$1"
}
usb_size()
{
  usb_plist "$1" || return 1
  usb_plist_value "$usb_work/info.plist" TotalSize
}
usb_sector()
{
  usb_plist "$1" || return 1
  usb_plist_value "$usb_work/info.plist" DeviceBlockSize
}
usb_identity()
{
  usb_plist "$1" || return 1
  usb_plist_value "$usb_work/info.plist" DeviceIdentifier
}
usb_prepare()
{
  usb_eligible "$usb_disk" || usb_fail 'disk is not external and physical'
  [ "$(usb_size "$usb_disk")" = "$usb_bytes" ] || usb_fail 'disk size changed'
  [ "$(usb_identity "$usb_disk")" = "$usb_id" ] || usb_fail 'disk identity changed'
  sudo diskutil unmountDisk "$usb_disk" || usb_fail 'cannot unmount selected disk'
}
usb_write()
{
  rawdisk=$(printf '%s\n' "$usb_disk" | sed 's@^/dev/disk@/dev/rdisk@')
  sudo dd if="$usb_work/m-boot-combined.raw" of="$rawdisk" bs=4m
}
usb_refresh()
{
  sudo diskutil unmountDisk "$usb_disk" || usb_fail 'cannot unmount disk after GPT update'
  usb_partition="$usb_disk"s3
  usb_plist "$usb_partition" || usb_fail 'macOS has not recognized partition 3; reconnect before formatting'
  observed=$(usb_plist_value "$usb_work/info.plist" TotalSize)
  expected=$(( (usb_bytes / 512 - 33 - 1071104) * 512 ))
  [ "$observed" = "$expected" ] ||
    usb_fail 'macOS kernel still has stale partition geometry; reconnect before formatting'
}
usb_format_mount()
{
  rawpart=$(printf '%s\n' "$usb_partition" | sed 's@^/dev/disk@/dev/rdisk@')
  sudo newfs_exfat -R -v MBOOTDATA "$rawpart" || usb_fail 'exFAT formatting failed'
  sudo diskutil mount "$usb_partition" || usb_fail 'cannot mount new exFAT filesystem'
  usb_mounted="$usb_partition"
  usb_plist "$usb_partition" || usb_fail 'cannot inspect mounted partition'
  usb_mountpoint=$(usb_plist_value "$usb_work/info.plist" MountPoint)
  [ -n "$usb_mountpoint" ] && [ -d "$usb_mountpoint" ] ||
    usb_fail 'no valid mounted exFAT path'
}
usb_unmount()
{
  sudo diskutil unmount "$usb_mounted" || usb_fail 'cannot unmount restored exFAT'
  usb_mounted=
}
usb_check_fs()
{
  rawpart=$(printf '%s\n' "$usb_partition" | sed 's@^/dev/disk@/dev/rdisk@')
  sudo fsck_exfat -n "$rawpart" || usb_fail 'exFAT integrity check failed'
}
