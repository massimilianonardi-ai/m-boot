#!/bin/sh
# macOS-specific operations sourced by usb-install.sh; no independent CLI.
usb_require()
{
  PATH="/opt/homebrew/sbin:/usr/local/sbin:$PATH"
  export PATH
  for cmd in diskutil plutil
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
  # ext4 is not mountable on macOS. Homebrew e2fsprogs formats/checks
  # the raw volume without attempting to mount its payload filesystem.
  command -v brew >/dev/null 2>&1 ||
    usb_fail 'Homebrew is required for ext4 provisioning on macOS'
  if [ -z "$(brew list --versions e2fsprogs 2>/dev/null)" ]
  then
    usb_info 'installing e2fsprogs before disk write'
    brew install e2fsprogs || usb_fail 'e2fsprogs installation failed before disk write'
  fi
  usb_e2fs_sbin="$(brew --prefix e2fsprogs)/sbin"
  [ -x "$usb_e2fs_sbin/mkfs.ext4" ] &&
    [ -x "$usb_e2fs_sbin/e2fsck" ] ||
    usb_fail 'Homebrew e2fsprogs tools unavailable'
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
  # Some physical macOS disks report VirtualOrPhysical=Unknown in info -plist.
  # diskutil's physical-only enumeration is the authoritative membership test.
  diskutil list physical |
    awk '/^\/dev\/disk[0-9]+ \(.*physical\)/ { print $1 }' |
    grep -Fx "$1" >/dev/null
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
  usb_eligible "$usb_disk" || usb_fail 'selected device is no longer a physical disk'
  [ "$(usb_size "$usb_disk")" = "$usb_bytes" ] || usb_fail 'disk size changed'
  [ "$(usb_identity "$usb_disk")" = "$usb_id" ] || usb_fail 'disk identity changed'
  sudo diskutil unmountDisk "$usb_disk" || usb_fail 'cannot unmount selected disk'
}
usb_write()
{
  rawdisk=$(printf '%s\n' "$usb_disk" | sed 's@^/dev/disk@/dev/rdisk@')
  sudo dd of="$rawdisk" bs=4m
}
usb_readback()
{
  rawdisk=$(printf '%s\n' "$usb_disk" | sed 's@^/dev/disk@/dev/rdisk@')
  sudo dd if="$rawdisk" bs=4m count=512 2>/dev/null
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
  sudo "$usb_e2fs_sbin/mkfs.ext4" -F -L MBOOTDATA "$rawpart" ||
    usb_fail 'ext4 formatting failed'
  # No native ext4 mount on macOS; payload remains empty.
  usb_mounted=
}
usb_unmount()
{
  [ -z "$usb_mounted" ] || usb_fail 'unexpected mounted ext4 partition'
}
usb_check_fs()
{
  rawpart=$(printf '%s\n' "$usb_partition" | sed 's@^/dev/disk@/dev/rdisk@')
  sudo "$usb_e2fs_sbin/e2fsck" -fn "$rawpart" || usb_fail 'ext4 integrity check failed'
}
