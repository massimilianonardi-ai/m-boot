#!/bin/sh
# Build a standalone m-boot image and its external-loader staging tree.
set -eu

usage()
{
  cat <<'HELP'
Usage: build.sh --target x86_64-efi|arm64-efi|i386-pc --output DIR [--modules-dir DIR] [--grub-mkimage FILE]

Build one GRUB target into DIR/TARGET without changing an existing stage.
UEFI stages contain esp/EFI/BOOT/BOOT*.EFI and data/m/boot/loader/.
BIOS stages contain bios/core.img and data/m/boot/loader/; BIOS installation
requires a separate, explicitly authorized disk-boot procedure.
HELP
}

fail()
{
  printf 'm-boot build: error: %s\n' "$1" >&2
  exit "$2"
}

[ "$(uname -s)" = Linux ] || fail 'this build entrypoint currently requires Linux' 2

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || fail 'cannot resolve source directory' 3

target=
output=
modules_dir=
mkimage=grub-mkimage

while [ "$#" -gt 0 ]
do
  case "$1" in
    --target|--output|--modules-dir|--grub-mkimage)
      [ "$#" -ge 2 ] && [ -n "$2" ] || fail "missing value for $1" 4
      case "$1" in
        --target) target=$2 ;;
        --output) output=$2 ;;
        --modules-dir) modules_dir=$2 ;;
        --grub-mkimage) mkimage=$2 ;;
      esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown argument: $1" 5 ;;
  esac
done

[ -n "$target" ] && [ -n "$output" ] || { usage >&2; fail 'target and output are required' 6; }

case "$target" in
  x86_64-efi) image=BOOTX64.EFI ;;
  arm64-efi) image=BOOTAA64.EFI ;;
  i386-pc) image=core.img ;;
  *) fail "unsupported GRUB target: $target" 7 ;;
esac

for file in "$root/boot/init" "$root/boot/recovery" "$root/boot/bootstrap-memdisk.sh" "$root/loader/init"
do
  [ -f "$file" ] || fail "missing source file: $file" 8
done

command -v tar >/dev/null 2>&1 || fail 'tar is required' 9
command -v "$mkimage" >/dev/null 2>&1 || fail "GRUB image builder is unavailable: $mkimage" 10

if [ -z "$modules_dir" ]
then
  for candidate in "/usr/lib/grub/$target" "/usr/local/lib/grub/$target" "/usr/lib64/grub/$target"
  do
    if [ -d "$candidate" ]
    then
      modules_dir=$candidate
      break
    fi
  done
fi
[ -n "$modules_dir" ] && [ -d "$modules_dir" ] || fail "GRUB $target modules not installed; provide --modules-dir" 11

if command -v grub-script-check >/dev/null 2>&1
then
  for script in "$root/boot/bootstrap-memdisk.sh" "$root/boot/init" "$root/boot/recovery" "$root/loader/init"
  do
    grub-script-check "$script" || fail "GRUB script syntax check failed: $script" 28
  done
else
  printf 'm-boot build: warning: grub-script-check unavailable; GRUB script syntax was not checked\n' >&2
fi

# Keep bootstrap/recovery independent of modules on the data filesystem.
set -- normal memdisk tar configfile regexp test search search_fs_file \
  search_fs_uuid search_label echo ls sleep reboot halt terminal \
  part_gpt part_msdos fat exfat ext2 ntfs iso9660
if [ "$target" = i386-pc ]
then
  set -- "$@" biosdisk
fi

for module
do
  [ -f "$modules_dir/$module.mod" ] || fail "missing $target module: $modules_dir/$module.mod" 12
done

mkdir -p -- "$output" || fail "cannot create output directory: $output" 13
output=$(CDPATH= cd -- "$output" && pwd -P) || fail 'cannot resolve output directory' 14
[ ! -e "$output/$target" ] && [ ! -L "$output/$target" ] || fail "stage already exists (will not overwrite): $output/$target" 15

stage=$(mktemp -d "$output/.m-boot-build.XXXXXXXX") || fail 'cannot create temporary staging directory' 16
trap 'rm -rf -- "$stage"' 0
trap 'exit 130' 1 2 3 15
mkdir -p "$stage/data/m/boot/loader" || fail 'cannot create data staging tree' 17
cp -R -- "$root/loader/." "$stage/data/m/boot/loader/" || fail 'cannot stage external loader' 18

# The memdisk contains ONLY the embedded boot scripts, not the external loader.
(CDPATH= cd -- "$root/boot" && tar -cf "$stage/memdisk.tar" init recovery) || fail 'cannot create embedded memdisk TAR' 19

if [ "$target" = i386-pc ]
then
  mkdir -p "$stage/bios" || fail 'cannot stage BIOS core image' 20
  destination="$stage/bios/core.img"
else
  mkdir -p "$stage/esp/EFI/BOOT" || fail 'cannot stage EFI boot image' 21
  destination="$stage/esp/EFI/BOOT/$image"
fi

printf 'm-boot build: GRUB target=%s modules=%s\n' "$target" "$modules_dir"
# The order of -m and -p is intentional: -m may set its own default prefix.
"$mkimage" -O "$target" -d "$modules_dir" \
  -c "$root/boot/bootstrap-memdisk.sh" -m "$stage/memdisk.tar" \
  -p '(memdisk)' -o "$destination" "$@" || fail "grub-mkimage failed for $target" 22
[ -s "$destination" ] || fail "grub-mkimage returned an empty image: $destination" 23

printf 'm-boot-stage-v1\ntarget=%s\n' "$target" > "$stage/stage-info" || fail 'cannot write stage metadata' 24
rm -f "$stage/memdisk.tar" || fail 'cannot clean build TAR from stage' 25
[ ! -e "$output/$target" ] && [ ! -L "$output/$target" ] || fail 'stage destination appeared during build' 26
mv -- "$stage" "$output/$target" || fail 'cannot publish build stage' 27
trap - 0 1 2 3 15
printf 'm-boot build: staged %s in %s\n' "$target" "$output/$target"
