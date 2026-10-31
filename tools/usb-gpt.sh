#!/bin/sh
# Shared GPT verification and creation of the new full-device ext4 partition.
# Sourced by usb-install.sh only, AFTER a separately authorized disk flash.
usb_gpt_info()
{
  sudo sgdisk -i "$1" "$usb_disk" > "$usb_work/part-$1"
}
usb_gpt_field()
{
  case "$2" in
    first) awk '/^First sector:/ { print $3 }' "$usb_work/part-$1" ;;
    last) awk '/^Last sector:/ { print $3 }' "$usb_work/part-$1" ;;
    type) awk '/^Partition GUID code:/ { print $4 }' "$usb_work/part-$1" ;;
  esac
}
usb_verify_boot_layout()
{
  usb_gpt_info 1 && usb_gpt_info 2 ||
    usb_fail 'cannot inspect BIOS/ESP GPT partitions'
  [ "$(usb_gpt_field 1 first)" = 2048 ] &&
    [ "$(usb_gpt_field 1 last)" = 22527 ] &&
    [ "$(usb_gpt_field 1 type)" = 21686148-6449-6E6F-744E-656564454649 ] ||
    usb_fail 'unexpected BIOS partition layout/type'
  [ "$(usb_gpt_field 2 first)" = 22528 ] &&
    [ "$(usb_gpt_field 2 last)" = 1071103 ] &&
    [ "$(usb_gpt_field 2 type)" = C12A7328-F81F-11D2-BA4B-00A0C93EC93B ] ||
    usb_fail 'unexpected EFI partition layout/type'
}
usb_require_no_data_partition()
{
  sudo sgdisk --print "$usb_disk" > "$usb_work/layout" ||
    usb_fail 'cannot read partition table for boot-only guard'
  if awk '$1 ~ /^[0-9]+$/ && $1 >= 3 { present=1 } END { exit !present }' "$usb_work/layout"
  then
    usb_fail 'boot-only image contains unexpected data/extra partitions; refusing mutation'
  fi
}
usb_expand_gpt()
{
  # Image has exactly two partitions and GPT backup at its own end.
  # Move the backup GPT to the real disk end before allocating data space.
  sudo sgdisk -e "$usb_disk" || usb_fail 'cannot relocate backup GPT'
  sudo sgdisk --verify "$usb_disk" || usb_fail 'invalid GPT after relocation'
  usb_verify_boot_layout
  usb_require_no_data_partition
  sudo sgdisk -n 3:1071104:0 -t 3:8300 -c 3:MBOOTDATA "$usb_disk" ||
    usb_fail 'cannot create ext4 payload partition'
  sudo sgdisk -G "$usb_disk" || usb_fail 'cannot randomize cloned GPT identifiers'
  sudo sgdisk --verify "$usb_disk" || usb_fail 'invalid GPT after adding data partition'
  usb_verify_boot_layout
  usb_gpt_info 3 || usb_fail 'missing new data partition'
  [ "$(usb_gpt_field 3 first)" = 1071104 ] &&
    [ "$(usb_gpt_field 3 type)" = 0FC63DAF-8483-4772-8E79-3D69D8477DE4 ] ||
    usb_fail 'unexpected data partition layout/type'
  last=$(usb_gpt_field 3 last)
  expected=$((usb_bytes / 512 - 34))
  [ "$last" = "$expected" ] ||
    usb_fail 'third partition does not occupy remaining usable disk'
}
