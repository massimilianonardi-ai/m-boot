#!/bin/sh
# Build all three GRUB targets and one boot-only GPT disk on Linux x86_64.
set -eu

usage()
{
  cat <<'HELP'
Usage: ./build-all.sh --output DIR [--modules-bios DIR] [--modules-x64 DIR]
                             [--modules-arm64 DIR] [--bios-modules-dir DIR]

Build the three GRUB images and the common external m-loader from CURRENT
repository sources. Produce one 576 MiB GPT disk with BIOS Boot and FAT32 ESP.
No third partition, ext4 filesystem or real disk is touched.
Run as root only because the staging ESP needs a temporary loopback mount.
Existing target stages and disk outputs are never overwritten.
HELP
}
fail()
{
  printf 'm-boot build-all: error: %s\n' "$1" >&2
  exit "$2"
}
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] ||
  fail 'Linux x86_64 build host required' 1
[ "$(id -u)" -eq 0 ] || fail 'run as root for temporary image/ESP mounting' 2
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) ||
  fail 'cannot resolve repository root' 3
output=
bios_modules=
modules_bios=
modules_x64=
modules_arm64=
while [ "$#" -gt 0 ]
do
  case "$1" in
    --output|--bios-modules-dir|--modules-bios|--modules-x64|--modules-arm64)
      [ "$#" -ge 2 ] && [ -n "$2" ] || fail "missing value for $1" 4
      case "$1" in
        --output) output=$2 ;;
        --bios-modules-dir) bios_modules=$2 ;;
        --modules-bios) modules_bios=$2 ;;
        --modules-x64) modules_x64=$2 ;;
        --modules-arm64) modules_arm64=$2 ;;
      esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unrecognized argument: $1" 5 ;;
  esac
done
[ -n "$output" ] || fail '--output DIR is required' 6
[ -d "$output" ] || mkdir -p -- "$output" ||
  fail 'cannot create output directory' 7
output=$(CDPATH= cd -- "$output" && pwd -P) ||
  fail 'cannot resolve output directory' 8
[ "$output" != / ] && [ "$output" != "$root" ] ||
  fail 'invalid output directory' 9
[ ! -e "$output/m-boot-combined.raw" ] &&
  [ ! -L "$output/m-boot-combined.raw" ] ||
  fail 'disk image already exists; refusing overwrite' 10
stages="$output/stages"
for target in i386-pc x86_64-efi arm64-efi
do
  case "$target" in
    i386-pc) mod=$modules_bios ;;
    x86_64-efi) mod=$modules_x64 ;;
    arm64-efi) mod=$modules_arm64 ;;
  esac
  set -- --target "$target" --output "$stages"
  if [ -n "$mod" ]; then set -- "$@" --modules-dir "$mod"; fi
  "$root/build.sh" "$@" || fail "GRUB stage failed for $target" 11
done
set -- --stages "$stages" --output "$output"
if [ -n "$bios_modules" ]; then set -- "$@" --bios-modules-dir "$bios_modules"; fi
"$root/build-image.sh" "$@" || fail 'boot-only GPT assembly failed' 12
printf 'm-boot build-all: boot-only disk ready: %s\n' "$output/m-boot-combined.raw"
