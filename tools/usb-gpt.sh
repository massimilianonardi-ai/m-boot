#!/bin/sh
# Shared GPT verification and partition-3 expansion; sourced by usb-install.sh.
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
usb_verify_layout()
{
  usb_gpt_info 1 && usb_gpt_info 2 && usb_gpt_info 3 ||
    usb_fail 'cannot inspect all three GPT partitions'
  [ "$(usb_gpt_field 1 first)" = 2048 ] &&
    [ "$(usb_gpt_field 1 last)" = 22527 ] &&
    [ "$(usb_gpt_field 1 type)" = 21686148-6449-6E6F-744E-656564454649 ] ||
    usb_fail 'unexpected BIOS partition layout/type'
  [ "$(usb_gpt_field 2 first)" = 22528 ] &&
    [ "$(usb_gpt_field 2 last)" = 1071103 ] &&
    [ "$(usb_gpt_field 2 type)" = C12A7328-F81F-11D2-BA4B-00A0C93EC93B ] ||
    usb_fail 'unexpected EFI partition layout/type'
  [ "$(usb_gpt_field 3 first)" = 1071104 ] &&
    [ "$(usb_gpt_field 3 type)" = 0FC63DAF-8483-4772-8E79-3D69D8477DE4 ] ||
    usb_fail 'unexpected third partition layout/type'
}
usb_expand_gpt()
{
  sudo sgdisk -e "$usb_disk" || usb_fail 'cannot relocate GPT backup'
  sudo sgdisk --verify "$usb_disk" || usb_fail 'invalid GPT after relocating backup'
  usb_verify_layout
  sudo sgdisk -d 3 -n 3:1071104:0 -t 3:8300 "$usb_disk" ||
    usb_fail 'cannot expand third partition'
  sudo sgdisk -G "$usb_disk" || usb_fail 'cannot randomize cloned GPT identifiers'
  sudo sgdisk --verify "$usb_disk" || usb_fail 'invalid GPT after expansion'
  usb_verify_layout
  last=$(usb_gpt_field 3 last)
  expected=$((usb_bytes / 512 - 34))
  [ "$last" = "$expected" ] || usb_fail 'third partition does not occupy remaining usable disk'
}
