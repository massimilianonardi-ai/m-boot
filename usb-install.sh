#!/bin/sh
# One-command, operator-confirmed installation of the published m-boot image.
set -eu

usb_fail()
{
  printf 'm-boot usb-install: error: %s\n' "$1" >&2
  exit 1
}
usb_info()
{
  printf 'm-boot usb-install: %s\n' "$1"
}
usb_need()
{
  command -v "$1" >/dev/null 2>&1 || usb_fail "missing utility: $1"
}
usb_usage()
{
  printf 'Usage: ./usb-install.sh\n'
  printf 'Select a physical disk, inspect it, confirm full erase.\n'
  printf 'The installer writes BIOS+dual UEFI and fills remaining space with exFAT.\n'
}
case "$#" in
  0) ;;
  1) if [ "$1" = --help ]; then usb_usage; exit 0; fi
     usb_fail 'unrecognized option' ;;
  *) usb_fail 'this installer takes no device operands' ;;
esac
[ -t 0 ] || usb_fail 'interactive terminal required'
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) ||
  usb_fail 'cannot locate repository'
dist="$root/images"
os=$(uname -s)
case "$os" in
  Linux) adapter="$root/tools/usb-target-linux.sh" ;;
  Darwin) adapter="$root/tools/usb-target-macos.sh" ;;
  *) usb_fail "unsupported host: $os" ;;
esac
[ -f "$adapter" ] || usb_fail 'platform adapter missing'
. "$adapter"
. "$root/tools/usb-gpt.sh"
for cmd in gzip unzip dd sudo awk sed grep tr mktemp cp sync stat
do
  usb_need "$cmd"
done
usb_require
for file in m-boot-combined.raw.gz m-boot-loader.zip SHA256SUMS RAW-SHA256SUMS
do
  [ -f "$dist/$file" ] || usb_fail "published file missing: images/$file (git pull first)"
done
usb_work=$(mktemp -d /tmp/m-boot-usb.XXXXXXXX) ||
  usb_fail 'cannot allocate private workspace'
usb_mounted=
usb_cleanup()
{
  if [ -n "$usb_mounted" ]
  then
    if [ "$os" = Linux ]
    then
      sudo umount "$usb_mounted" >&2 || :
    else
      sudo diskutil unmount "$usb_mounted" >&2 || :
    fi
  fi
  rm -rf -- "$usb_work"
}
trap usb_cleanup 0
trap 'exit 130' 1 2 3 15
usb_checksum()
{
  if [ "$os" = Linux ]
  then
    sha256sum "$@"
  else
    shasum -a 256 "$@"
  fi
}
usb_image_hash()
{
  # Inspect the raw image in a stream; avoid a 2 GiB temporary file.
  gzip -dc "$dist/m-boot-combined.raw.gz" | usb_checksum | awk '{ print $1 }'
}
usb_write_stream()
{
  # POSIX sh has no pipefail: record decompressor status independently
  # from dd, so neither failure can be mistaken for a successful flash.
  stream_status="$usb_work/decompress-status"
  if
    (
      if gzip -dc "$dist/m-boot-combined.raw.gz"
      then
        printf 'ok\n' > "$stream_status"
      else
        printf 'failed\n' > "$stream_status"
      fi
    ) | usb_write
  then
    :
  else
    usb_fail 'dd failed: selected disk may be partially written'
  fi
  [ -f "$stream_status" ] && [ "$(cat "$stream_status")" = ok ] ||
    usb_fail 'gzip failed while writing: selected disk may be partially written'
}
usb_verify_disk()
{
  # Authenticate the first 2 GiB actually written before changing GPT.
  written_hash=$(usb_readback | usb_checksum | awk '{ print $1 }')
  [ "$written_hash" = "$expected_hash" ] ||
    usb_fail 'disk readback SHA256 mismatch; refusing GPT/format operations'
}

# Verify compressed distribution and raw image BEFORE selection.
# Only small metadata and the loader ZIP use temporary disk space.
usb_info 'verifying published image and loader checksums'
(cd "$dist" && usb_checksum -c SHA256SUMS) ||
  usb_fail 'published artifact checksum mismatch'
unzip -tqq "$dist/m-boot-loader.zip" ||
  usb_fail 'published loader ZIP is corrupt'
cp "$dist/m-boot-loader.zip" "$usb_work/loader.zip" ||
  usb_fail 'cannot stage loader archive'
gzip -t "$dist/m-boot-combined.raw.gz" ||
  usb_fail 'compressed image has a CRC/decompression error'
expected_hash=$(awk '$2 == "m-boot-combined.raw" { print $1 }' "$dist/RAW-SHA256SUMS")
[ "${#expected_hash}" -eq 64 ] ||
  usb_fail 'raw disk checksum metadata is invalid'
raw_hash=$(usb_image_hash)
[ "$raw_hash" = "$expected_hash" ] ||
  usb_fail 'decompressed image SHA256 mismatch'

usb_list > "$usb_work/disks"
count=$(wc -l < "$usb_work/disks" | tr -d '[:space:]')
[ "$count" -gt 0 ] || usb_fail 'no physical disks detected'
printf '\nAvailable physical disks (system disks in active use are refused):\n'
number=0
while IFS= read -r candidate
do
  number=$((number + 1))
  printf '  %s) %s  ' "$number" "$candidate"
  usb_brief "$candidate"
done < "$usb_work/disks"

printf '\nSelect a disk number (q cancels): '
IFS= read -r number || usb_fail 'no selection'
[ "$number" != q ] || exit 0
case "$number" in ''|*[!0-9]*) usb_fail 'enter a numeric choice' ;; esac
[ "$number" -ge 1 ] && [ "$number" -le "$count" ] ||
  usb_fail 'choice outside the list'
usb_disk=$(sed -n "$number"p "$usb_work/disks")
[ -n "$usb_disk" ] && usb_eligible "$usb_disk" ||
  usb_fail 'selected disk has disappeared or changed'
printf '\nSelected disk %s:\n' "$usb_disk"
usb_describe "$usb_disk" || usb_fail 'cannot inspect all partitions'
usb_bytes=$(usb_size "$usb_disk")
usb_sector_size=$(usb_sector "$usb_disk")
usb_id=$(usb_identity "$usb_disk")
[ "$usb_sector_size" = 512 ] || usb_fail 'only 512-byte logical-sector disks are supported'
[ "$usb_bytes" -ge 2147483648 ] || usb_fail 'disk smaller than image'

printf '\nALL DATA AND PARTITIONS ON %s WILL BE DESTROYED.\n' "$usb_disk"
printf 'The disk will be flashed and partition 3 recreated as full-size exFAT.\n'
printf 'Type exactly "ERASE %s" to confirm: ' "$usb_disk"
IFS= read -r answer || usb_fail 'no confirmation'
[ "$answer" = "ERASE $usb_disk" ] ||
  usb_fail 'confirmation rejected; no changes'
usb_eligible "$usb_disk" || usb_fail 'disk changed before write'
sudo -v || usb_fail 'administrator authorization failed'
usb_prepare

usb_info "streaming verified 2 GiB GPT image onto $usb_disk"
usb_write_stream
sync
usb_info 'verifying written image against raw SHA256'
usb_verify_disk
usb_info 'relocating GPT and extending partition 3'
usb_expand_gpt
usb_refresh
usb_info 'formatting expanded exFAT and restoring loader'
usb_format_mount
if [ "$os" = Linux ]
then
  unzip -oq "$usb_work/loader.zip" -d "$usb_mountpoint" ||
    usb_fail 'loader ZIP extraction failed'
else
  sudo unzip -oq "$usb_work/loader.zip" -d "$usb_mountpoint" ||
    usb_fail 'loader ZIP extraction failed'
fi
for path in init i386-pc/normal.mod x86_64-efi/normal.mod arm64-efi/normal.mod
do
  if [ "$os" = Linux ]
  then
    [ -s "$usb_mountpoint/m/boot/loader/$path" ] ||
      usb_fail "loader file missing: $path"
  else
    sudo test -s "$usb_mountpoint/m/boot/loader/$path" ||
      usb_fail "loader file missing: $path"
  fi
done
sync
usb_unmount
usb_check_fs
usb_info "SUCCESS: $usb_disk contains BIOS, x86_64/ARM64 UEFI and expanded exFAT"
