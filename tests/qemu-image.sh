#!/bin/sh
# Create an isolated, file-backed QEMU disk from one m-boot build stage.
set -eu

usage()
{
  cat <<'HELP'
Usage: qemu-image.sh --stage DIR --scenario loader|recovery --output DIR
                     [--bios-modules-dir DIR]

Creates a NEW raw GPT disk image in DIR; never overwrites existing images.
Requires Linux root and loopback/mount support. Only a temporary image file is
partitioned and formatted; no host disk/device operand is accepted.
For BIOS (i386-pc), --bios-modules-dir must contain a matching GRUB boot.img.
HELP
}

fail()
{
  printf 'm-boot qemu-image: error: %s\n' "$1" >&2
  exit "$2"
}

[ "$(uname -s)" = Linux ] || fail 'Linux is required' 1
stage=
scenario=
output=
bios_modules=
while [ "$#" -gt 0 ]
do
  case "$1" in
    --stage|--scenario|--output|--bios-modules-dir)
      [ "$#" -ge 2 ] && [ -n "$2" ] || fail "missing $1 operand" 2
      case "$1" in
        --stage) stage=$2 ;;
        --scenario) scenario=$2 ;;
        --output) output=$2 ;;
        --bios-modules-dir) bios_modules=$2 ;;
      esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown argument: $1" 3 ;;
  esac
done
[ -n "$stage" ] && [ -n "$scenario" ] && [ -n "$output" ] || fail 'stage, scenario and output are required' 4
case "$scenario" in loader|recovery) ;; *) fail "invalid scenario: $scenario" 5 ;; esac
[ -d "$stage" ] && [ -f "$stage/stage-info" ] || fail "invalid stage: $stage" 6
stage=$(CDPATH= cd -- "$stage" && pwd -P) || fail 'cannot resolve stage directory' 7
[ "$(sed -n '1p' "$stage/stage-info")" = m-boot-stage-v1 ] || fail 'invalid stage identity' 8
case "$(sed -n '2p' "$stage/stage-info")" in
  target=x86_64-efi) target=x86_64-efi; efi=BOOTX64.EFI ;;
  target=arm64-efi) target=arm64-efi; efi=BOOTAA64.EFI ;;
  target=i386-pc) target=i386-pc; efi= ;;
  *) fail 'invalid stage target' 9 ;;
esac
if [ "$target" = i386-pc ]
then
  [ -f "$stage/bios/core.img" ] || fail 'BIOS core.img missing from stage' 10
  [ -n "$bios_modules" ] && [ -f "$bios_modules/boot.img" ] || fail 'BIOS requires --bios-modules-dir containing boot.img' 11
else
  [ -s "$stage/esp/EFI/BOOT/$efi" ] || fail "EFI image missing: $efi" 12
fi
[ "$scenario" = recovery ] || [ -f "$stage/data/m/boot/loader/init" ] || fail 'external loader init missing from stage' 13
[ "$(id -u)" -eq 0 ] || fail 'must run as root (loopback, mkfs, mount); no physical device is used' 14
for tool in qemu-img sgdisk losetup mkfs.vfat mkfs.exfat mount umount findmnt
do
  command -v "$tool" >/dev/null 2>&1 || fail "missing required tool: $tool" 15
done
if [ "$target" = i386-pc ]
then
  command -v grub-bios-setup >/dev/null 2>&1 || fail 'missing grub-bios-setup for BIOS image' 16
fi
[ -d "$output" ] || mkdir -p -- "$output" || fail "cannot create output directory: $output" 17
output=$(CDPATH= cd -- "$output" && pwd -P) || fail 'cannot resolve output directory' 18
[ "$output" != / ] && [ "$output" != "$stage" ] || fail 'invalid output directory' 19
image="$output/m-boot-$target-$scenario.raw"
[ ! -e "$image" ] && [ ! -L "$image" ] || fail "image exists; refusing overwrite: $image" 20

# Temporary workspace and cleanup are scoped to the newly created image only.
work=$(mktemp -d "$output/.m-boot-qemu.XXXXXXXX") || fail 'cannot create temporary workspace' 21
loop=
esp_mounted=no
data_mounted=no
clean()
{
  ok=yes
  if [ "$data_mounted" = yes ]; then umount "$work/data" || ok=no; fi
  if [ "$esp_mounted" = yes ]; then umount "$work/esp" || ok=no; fi
  if [ -n "$loop" ]; then losetup -d "$loop" || ok=no; fi
  if [ "$ok" = yes ]
  then
    rm -rf -- "$work"
  else
    printf 'm-boot qemu-image: cleanup incomplete; inspect %s and %s\n' "$work" "$loop" >&2
  fi
}
trap clean 0
trap 'exit 130' 1 2 3 15
mkdir -- "$work/esp" "$work/data" || fail 'cannot create temporary mountpoints' 22
raw="$work/disk.raw"
qemu-img create -f raw "$raw" 768M || fail 'qemu-img could not create raw image' 23
if [ "$target" = i386-pc ]
then
  sgdisk --clear --new=1:2048:+10M --typecode=1:EF02 \
    --new=2:0:+256M --typecode=2:EF00 \
    --new=3:0:0 --typecode=3:0700 "$raw" || fail 'cannot create BIOS GPT partitions' 24
  esp_part=2
  data_part=3
else
  sgdisk --clear --new=1:2048:+256M --typecode=1:EF00 \
    --new=2:0:0 --typecode=2:0700 "$raw" || fail 'cannot create UEFI GPT partitions' 25
  esp_part=1
  data_part=2
fi
sgdisk --verify "$raw" || fail 'GPT verification failed' 26
loop=$(losetup --find --show --partscan "$raw") || fail 'cannot attach temporary raw file to loop device' 27
case "$loop" in /dev/loop[0-9]*) ;; *) fail "unexpected loop device: $loop" 28 ;; esac
[ "$(losetup -n -O BACK-FILE "$loop")" = "$raw" ] || fail 'loop backing file verification failed' 29
esp_dev="${loop}p${esp_part}"
data_dev="${loop}p${data_part}"
n=0
while { [ ! -b "$esp_dev" ] || [ ! -b "$data_dev" ]; } && [ "$n" -lt 10 ]
do
  sleep 1
  n=$((n + 1))
done
[ -b "$esp_dev" ] && [ -b "$data_dev" ] || fail 'kernel did not expose loop partitions' 30
mkfs.vfat -F 32 -n MBOOTESP "$esp_dev" || fail 'cannot format temporary EFI partition' 31
mkfs.exfat -n MBOOTDATA "$data_dev" || fail 'cannot format temporary exFAT partition' 32
mount -t vfat "$esp_dev" "$work/esp" || fail 'cannot mount temporary ESP' 33
esp_mounted=yes
mount -t exfat "$data_dev" "$work/data" || fail 'cannot mount temporary exFAT filesystem' 34
data_mounted=yes

if [ "$target" = i386-pc ]
then
  if [ "$scenario" = loader ]
  then
    mkdir -p "$work/data/m/boot" || fail 'cannot create external loader parent' 35
    cp -R "$stage/data/m/boot/loader" "$work/data/m/boot/" || fail 'cannot copy BIOS external loader fixture' 36
  fi
  # This is the ONLY boot-sector write, and only to the verified image loop.
  grub-bios-setup --directory="$bios_modules" \
    --boot-image="$bios_modules/boot.img" \
    --core-image="$stage/bios/core.img" "$loop" || fail 'GRUB BIOS embedding failed in temporary disk image' 37
else
  if [ "$scenario" = loader ]
  then
    root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P) || fail 'cannot locate installer' 38
    "$root/install.sh" --stage "$stage" --esp "$work/esp" --data "$work/data" --apply || fail 'safe UEFI install failed' 39
  else
    mkdir -p "$work/esp/EFI/BOOT" || fail 'cannot create UEFI firmware path' 40
    cp "$stage/esp/EFI/BOOT/$efi" "$work/esp/EFI/BOOT/$efi" || fail 'cannot copy EFI image for recovery scenario' 41
  fi
fi
sync
umount "$work/data" || fail 'cannot unmount data filesystem' 42
data_mounted=no
umount "$work/esp" || fail 'cannot unmount ESP filesystem' 43
esp_mounted=no
losetup -d "$loop" || fail 'cannot detach temporary loop disk' 44
loop=
[ ! -e "$image" ] && [ ! -L "$image" ] || fail 'destination appeared while preparing image' 45
mv -- "$raw" "$image" || fail 'cannot publish raw disk image' 46
printf 'm-boot qemu-image: created %s (%s, %s)\n' "$image" "$target" "$scenario"
