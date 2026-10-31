#!/bin/sh
# Install a staged UEFI m-boot image and its loader on the FAT32 ESP.
set -eu

usage()
{
  cat <<'HELP'
Usage: install.sh --stage DIR --esp DIR --data DIR [--apply] [--allow-directory]

Without --apply: show an installation plan, make NO changes.
--apply: copy only into missing EFI/BOOT/BOOT*.EFI and ESP m/boot/loader paths.
         Existing EFI files are NEVER overwritten. An existing external
         loader directory is reused only when its content is identical.
--allow-directory: allow ordinary directories rather than mounted vfat/ext4
         filesystems (for disposable staging/tests only, not a bootable install).

No partitioning, formatting, raw device writes, or BIOS boot-sector changes.
HELP
}

fail()
{
  printf 'm-boot install: error: %s\n' "$1" >&2
  exit "$2"
}

[ "$(uname -s)" = Linux ] || fail 'this installer currently requires Linux' 2

stage=
esp=
data=
apply=no
allow_dir=no
while [ "$#" -gt 0 ]
do
  case "$1" in
    --stage|--esp|--data)
      [ "$#" -ge 2 ] && [ -n "$2" ] || fail "missing value for $1" 3
      case "$1" in
        --stage) stage=$2 ;;
        --esp) esp=$2 ;;
        --data) data=$2 ;;
      esac
      shift 2 ;;
    --apply) apply=yes; shift ;;
    --allow-directory) allow_dir=yes; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown argument: $1" 4 ;;
  esac
done

[ -n "$stage" ] && [ -n "$esp" ] && [ -n "$data" ] || { usage >&2; fail 'stage, esp, data are required' 5; }
for name in "$stage" "$esp" "$data"
do
  [ -d "$name" ] || fail "directory does not exist: $name" 6
done
stage=$(CDPATH= cd -- "$stage" && pwd -P) || fail 'cannot resolve stage directory' 7
esp=$(CDPATH= cd -- "$esp" && pwd -P) || fail 'cannot resolve ESP directory' 8
data=$(CDPATH= cd -- "$data" && pwd -P) || fail 'cannot resolve data directory' 9

[ "$esp" != / ] && [ "$data" != / ] || fail 'refusing to install into filesystem root' 10
[ "$esp" != "$data" ] || fail 'ESP and data must be distinct directories' 11
case "$esp/" in "$data/"*) fail 'ESP nested inside data directory' 12 ;; esac
case "$data/" in "$esp/"*) fail 'data nested inside ESP directory' 13 ;; esac
case "$stage/" in "$esp/"*|"$data/"*) fail 'stage is inside installation destination' 14 ;; esac
case "$esp/" in "$stage/"*) fail 'ESP is inside build stage' 15 ;; esac
case "$data/" in "$stage/"*) fail 'data is inside build stage' 16 ;; esac

info=$stage/stage-info
[ -f "$info" ] && [ ! -L "$info" ] || fail 'invalid stage: missing stage-info' 17
magic=$(sed -n '1p' "$info")
targetline=$(sed -n '2p' "$info")
[ "$magic" = m-boot-stage-v1 ] || fail 'invalid stage identity' 18
case "$targetline" in
  target=x86_64-efi) efi=BOOTX64.EFI ;;
  target=arm64-efi) efi=BOOTAA64.EFI ;;
  target=i386-pc) fail 'BIOS core image cannot be installed by copying files; boot-sector setup is not implemented' 19 ;;
  *) fail "unsupported stage target: $targetline" 20 ;;
esac

source_efi="$stage/esp/EFI/BOOT/$efi"
source_loader="$stage/esp/m/boot/loader"
[ -s "$source_efi" ] && [ ! -L "$source_efi" ] || fail "missing staged EFI image: $source_efi" 21
[ -f "$source_loader/init" ] && [ ! -L "$source_loader/init" ] || fail 'missing external loader init in stage' 22
[ -z "$(find "$source_loader" -type l -print -quit)" ] || fail 'staged external loader contains symlinks' 23

if [ "$allow_dir" = no ]
then
  command -v findmnt >/dev/null 2>&1 || fail 'findmnt required to validate mountpoints' 24
  esp_type=$(findmnt -n -M "$esp" -o FSTYPE) || fail "ESP is not a mountpoint: $esp" 25
  data_type=$(findmnt -n -M "$data" -o FSTYPE) || fail "data is not a mountpoint: $data" 26
  [ "$esp_type" = vfat ] || fail "ESP must be mounted vfat/FAT32; found $esp_type" 27
  [ "$data_type" = ext4 ] || fail "data must be mounted ext4; found $data_type" 28
fi

# A legacy installation may still contain the loader on the data filesystem. Never
# silently leave two executable loader copies or delete existing user data.
if [ -e "$data/m/boot/loader" ] || [ -L "$data/m/boot/loader" ]
then
  fail 'legacy loader detected on the data filesystem; migrate explicitly before installing an ESP loader' 39
fi

# Never follow an installed-directory symlink or replace an existing boot entry.
for item in "$esp/EFI" "$esp/EFI/BOOT" "$esp/m" "$esp/m/boot" "$esp/m/boot/loader"
do
  [ ! -L "$item" ] || fail "destination contains a symlink: $item" 29
done
boot_file="$esp/EFI/BOOT/$efi"
loader_dir="$esp/m/boot/loader"
[ ! -e "$boot_file" ] && [ ! -L "$boot_file" ] || fail "existing EFI boot file will not be overwritten: $boot_file" 30

# A second UEFI architecture may share an identical external loader.
# Never overwrite, merge or silently replace an existing loader.
install_loader=yes
if [ -e "$loader_dir" ] || [ -L "$loader_dir" ]
then
  [ -d "$loader_dir" ] && [ ! -L "$loader_dir" ] || fail "external loader target is not a real directory: $loader_dir" 31
  [ -z "$(find "$loader_dir" -type l -print -quit)" ] || fail "installed external loader contains symlinks: $loader_dir" 36
  command -v diff >/dev/null 2>&1 || fail 'diff is required to compare an installed loader' 37
  diff -r "$source_loader" "$loader_dir" >/dev/null 2>&1 || fail "external loader differs from the staged loader; refusing to merge: $loader_dir" 38
  install_loader=no
fi

printf 'm-boot install: stage=%s\n' "$stage"
printf 'm-boot install: EFI image -> %s\n' "$boot_file"
if [ "$install_loader" = yes ]
then
  printf 'm-boot install: new loader -> %s\n' "$loader_dir"
else
  printf 'm-boot install: existing loader verified identical (no copy): %s\n' "$loader_dir"
fi
if [ "$allow_dir" = yes ]
then
  printf 'm-boot install: WARNING: unmounted-directory test mode; NOT a bootable-media validation\n'
fi

if [ "$apply" = no ]
then
  printf 'm-boot install: DRY RUN ONLY. Repeat with --apply to copy files.\n'
  exit 0
fi

mkdir -p -- "$esp/EFI/BOOT" || fail 'cannot create EFI/BOOT destination' 32
mkdir -p -- "$esp/m/boot" || fail 'cannot create ESP loader parent directory' 33
if [ "$install_loader" = yes ]
then
  cp -R -- "$source_loader" "$loader_dir" || fail "failed to stage external loader at $loader_dir (may be partial)" 34
fi
cp -- "$source_efi" "$boot_file" || fail "failed to write EFI boot image at $boot_file (loader may be present)" 35
printf 'm-boot install: installed new EFI image; external loader copied or verified unchanged; no sectors written\n'
