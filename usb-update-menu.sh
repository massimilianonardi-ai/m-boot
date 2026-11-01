#!/bin/sh
# Update only boot-media menu scripts on an already-provisioned FAT32 ESP.
# Never opens physical whole disks, rewrites firmware images or touches ext4.
set -eu

usage()
{
  cat <<'HELP'
Usage: ./usb-update-menu.sh --esp MOUNTPOINT [--apply]

Without --apply, validate the mounted MBOOTESP and GRUB scripts and show
the files to be updated. --apply backs up existing menus under $HOME,
stages every replacement on the ESP, verifies it, and then replaces
only loader/menu/boot-media* files. Mount the verified FAT32 MBOOTESP as
the normal user with write permission before running this command.
Never use usb-install.sh for a menu-only update: it erases the entire USB.
HELP
}
fail()
{
  printf 'm-boot menu update: error: %s\n' "$1" >&2
  exit 1
}
info()
{
  printf 'm-boot menu update: %s\n' "$1"
}
[ "$(uname -s)" = Linux ] || fail 'requires Linux'
esp=
apply=no
while [ "$#" -gt 0 ]
do
  case "$1" in
    --esp)
      [ "$#" -ge 2 ] && [ -n "$2" ] || fail 'missing ESP mountpoint'
      esp=$2
      shift 2 ;;
    --apply)
      apply=yes
      shift ;;
    --help|-h)
      usage
      exit 0 ;;
    *)
      fail "unexpected argument: $1" ;;
  esac
done
[ -n "$esp" ] || fail 'explicit --esp MOUNTPOINT is required'
[ -d "$esp" ] && [ ! -L "$esp" ] || fail 'ESP must be an existing real directory'
esp=$(CDPATH= cd -- "$esp" && pwd -P) || fail 'cannot resolve ESP mountpoint'
[ "$esp" != / ] || fail 'refusing filesystem root'

for cmd in findmnt lsblk mktemp cp cmp mv rm sync
do
  command -v "$cmd" >/dev/null 2>&1 || fail "missing tool: $cmd"
done
[ "$(findmnt -rn -M "$esp" -o FSTYPE)" = vfat ] ||
  fail 'ESP must be a mounted FAT32/vfat volume at the exact mountpoint'
source_device=$(findmnt -rn -M "$esp" -o SOURCE) ||
  fail 'cannot identify ESP source partition'
[ -b "$source_device" ] || fail "ESP source is not a block partition: $source_device"
[ "$(lsblk -dnro LABEL "$source_device")" = MBOOTESP ] ||
  fail "mounted partition is not MBOOTESP: $source_device"
[ -s "$esp/EFI/BOOT/BOOTX64.EFI" ] &&
[ -s "$esp/EFI/BOOT/BOOTAA64.EFI" ] &&
[ -f "$esp/m/boot/loader/init" ] ||
  fail 'this is not a complete m-boot ESP'
menu="$esp/m/boot/loader/menu"
[ -d "$menu" ] && [ ! -L "$menu" ] &&
[ -f "$menu/boot-media" ] && [ ! -L "$menu/boot-media" ] ||
  fail 'existing m-loader menu is missing or unsafe'

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) ||
  fail 'cannot locate m-boot checkout'
for file in boot-media boot-media-iso boot-media-recovery boot-media-install boot-media-diagnostics boot-media-network
do
  src="$root/loader/menu/$file"
  dest="$menu/$file"
  [ -s "$src" ] && [ ! -L "$src" ] || fail "missing source script: $src"
  [ ! -L "$dest" ] || fail "refusing destination symlink: $dest"
  "$root/tools/grub-script-check" "$src" || fail "GRUB syntax check failed: $src"
  info "$src -> $dest"
done
if [ "$apply" = no ]
then
  info 'DRY RUN: no filesystem changes; repeat with --apply'
  exit 0
fi

[ -n "${HOME:-}" ] && [ -d "$HOME" ] || fail 'normal user HOME required for backups'
case "$HOME/" in
  "$esp/"*) fail 'HOME must not be on the ESP' ;;
esac
backup=$(mktemp -d "$HOME/mboot-menu-backup.XXXXXXXX") ||
  fail 'cannot create private host backup'
info "backing up previous menu files under $backup"
for file in boot-media boot-media-iso boot-media-recovery boot-media-install boot-media-diagnostics boot-media-network
do
  dest="$menu/$file"
  if [ -f "$dest" ]
  then
    cp -- "$dest" "$backup/$file" || fail "backup failed: $dest"
  fi
done

# Stage *all* new menu scripts before replacing any existing entry.
work="$menu/.boot-media-update.$$"
[ ! -e "$work" ] && [ ! -L "$work" ] || fail 'temporary stage already exists'
mkdir -- "$work" || fail 'cannot create temporary ESP stage (write permission?)'
cleanup()
{
  if [ -d "$work" ]
  then
    rm -rf -- "$work" || :
  fi
}
trap cleanup 0
trap 'exit 130' 1 2 3 15
for file in boot-media boot-media-iso boot-media-recovery boot-media-install boot-media-diagnostics boot-media-network
do
  cp -- "$root/loader/menu/$file" "$work/$file" || fail "stage copy failed: $file"
  cmp -s -- "$root/loader/menu/$file" "$work/$file" || fail "stage verification failed: $file"
done
sync
for file in boot-media boot-media-iso boot-media-recovery boot-media-install boot-media-diagnostics boot-media-network
do
  mv -f -- "$work/$file" "$menu/$file" || fail "replacement failed: $file (backup $backup)"
  cmp -s -- "$root/loader/menu/$file" "$menu/$file" ||
    fail "post-update checksum mismatch: $file (backup $backup)"
done
sync
info "SUCCESS: updated six loader menu scripts only; backup: $backup"
info 'Unmount the ESP safely before booting the USB again.'
