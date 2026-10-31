#!/bin/sh
# Build three target stages, create one disk, then boot that SAME disk with QEMU.
set -eu

usage()
{
  cat <<'HELP'
Usage: qemu-combined-test.sh --output DIR [--stages DIR]
                             [--bios-modules-dir DIR]
                             [--modules-bios DIR] [--modules-x64 DIR]
                             [--modules-arm64 DIR] [--prepare-only]
                             [--target all|i386-pc|x86_64-efi|arm64-efi]

Without --stages, builds all three target images in DIR/stages/.
With --stages, uses three existing build.sh stages from the supplied dir.
Prepares exactly one boot-only GPT disk DIR/m-boot-combined.raw, then boots the same
image in BIOS x86_64, UEFI x86_64 and UEFI ARM64 (one QEMU window at a time).
No physical disk is opened. Run as root for the image loop mounts.
--prepare-only creates the disk without starting QEMU; qemu-run.sh can then
run it unprivileged. Actual success is judged by the displayed GRUB menu.
HELP
}
fail()
{
  printf 'm-boot qemu-combined-test: error: %s\n' "$1" >&2
  exit "$2"
}
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || fail 'Linux x86_64 required' 1
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P) || fail 'cannot find repository root' 2
output=
stages=
bios_modules=
modules_bios=
modules_x64=
modules_arm64=
prepare_only=no
target=all
while [ "$#" -gt 0 ]
do
  case "$1" in
    --output|--stages|--bios-modules-dir|--modules-bios|--modules-x64|--modules-arm64|--target)
      [ "$#" -ge 2 ] && [ -n "$2" ] || fail "missing $1 operand" 3
      case "$1" in
        --output) output=$2 ;;
        --stages) stages=$2 ;;
        --bios-modules-dir) bios_modules=$2 ;;
        --modules-bios) modules_bios=$2 ;;
        --modules-x64) modules_x64=$2 ;;
        --modules-arm64) modules_arm64=$2 ;;
        --target) target=$2 ;;
      esac
      shift 2 ;;
    --prepare-only) prepare_only=yes; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown argument: $1" 4 ;;
  esac
done
[ -n "$output" ] || fail '--output required' 5
case "$target" in all|i386-pc|x86_64-efi|arm64-efi) ;; *) fail "invalid target: $target" 6 ;; esac
[ "$(id -u)" -eq 0 ] || fail 'root required to create temporary GPT/loop filesystems' 7
[ -d "$output" ] || mkdir -p -- "$output" || fail "cannot create output: $output" 8
output=$(CDPATH= cd -- "$output" && pwd -P) || fail 'cannot resolve output directory' 9
[ ! -e "$output/m-boot-combined.raw" ] && [ ! -L "$output/m-boot-combined.raw" ] || fail 'combined image exists (refuse overwrite)' 10
if [ -z "$stages" ]
then
  stages="$output/stages"
  for boot_target in i386-pc x86_64-efi arm64-efi
  do
    set -- --target "$boot_target" --output "$stages"
    case "$boot_target" in
      i386-pc) chosen_modules=$modules_bios ;;
      x86_64-efi) chosen_modules=$modules_x64 ;;
      arm64-efi) chosen_modules=$modules_arm64 ;;
    esac
    if [ -n "$chosen_modules" ]
    then
      set -- "$@" --modules-dir "$chosen_modules"
    fi
    "$root/build.sh" "$@" || fail "build failed for $boot_target" 11
  done
fi
set -- --stages "$stages" --output "$output"
if [ -n "$bios_modules" ]
then
  set -- "$@" --bios-modules-dir "$bios_modules"
fi
"$root/build-image.sh" "$@" || fail 'combined GPT image creation failed' 12
disk="$output/m-boot-combined.raw"
printf 'm-boot qemu-combined-test: one shared GPT image: %s\n' "$disk"
if [ "$prepare_only" = yes ]
then
  printf 'm-boot qemu-combined-test: prepared only; run tests/qemu-run.sh with --target and --image\n'
  exit 0
fi
if [ "$target" = all ]
then
  targets='i386-pc x86_64-efi arm64-efi'
else
  targets=$target
fi
for boot_target in $targets
do
  printf 'm-boot qemu-combined-test: starting %s against SAME image; inspect the menu, then close QEMU\n' "$boot_target"
  "$root/tests/qemu-run.sh" --target "$boot_target" --image "$disk" || fail "QEMU failed for $boot_target" 13
done
printf 'm-boot qemu-combined-test: runs finished; user must verify boot menus for PASS\n'
