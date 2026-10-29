#!/bin/sh
# Prepare ONE disposable GPT disk for BIOS, x86_64 UEFI and ARM64 UEFI.
set -eu

usage()
{
  cat <<'HELP'
Usage: qemu-combined-image.sh --stages DIR --output DIR [--bios-modules-dir DIR]

DIR must contain build.sh stages: i386-pc/, x86_64-efi/, arm64-efi/.
Creates a new output/m-boot-combined.raw; refuses to overwrite it.
Uses only a temporary raw file/loop device, never a physical disk operand.
GPT layout: 10 MiB BIOS Boot (EF02), 512 MiB FAT32 ESP (both UEFI
architectures), remainder exFAT (one shared external loader).
Requires Linux root to mount the two image filesystems.
HELP
}

fail()
{
  printf 'm-boot qemu-combined-image: error: %s\n' "$1" >&2
  exit "$2"
}

[ "$(uname -s)" = Linux ] || fail 'Linux required' 1
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P) || fail 'cannot resolve project root' 2
stages=
output=
bios_modules=
while [ "$#" -gt 0 ]
do
  case "$1" in
    --stages|--output|--bios-modules-dir)
      [ "$#" -ge 2 ] && [ -n "$2" ] || fail "missing $1 operand" 3
      case "$1" in
        --stages) stages=$2 ;;
        --output) output=$2 ;;
        --bios-modules-dir) bios_modules=$2 ;;
      esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown argument: $1" 4 ;;
  esac
done
[ -n "$stages" ] && [ -n "$output" ] || fail 'stages and output required' 5
[ -d "$stages" ] || fail "stages directory absent: $stages" 6
stages=$(CDPATH= cd -- "$stages" && pwd -P) || fail 'cannot resolve stages directory' 7
for target in i386-pc x86_64-efi arm64-efi
do
  stage="$stages/$target"
  [ -d "$stage" ] && [ -f "$stage/stage-info" ] || fail "missing stage: $stage" 8
  [ "$(sed -n '1p' "$stage/stage-info")" = m-boot-stage-v1 ] || fail "invalid stage: $stage" 9
  [ "$(sed -n '2p' "$stage/stage-info")" = "target=$target" ] || fail "stage target mismatch: $stage" 10
done
[ -s "$stages/i386-pc/bios/core.img" ] || fail 'BIOS core.img absent' 11
[ -s "$stages/x86_64-efi/esp/EFI/BOOT/BOOTX64.EFI" ] || fail 'BOOTX64.EFI absent' 12
[ -s "$stages/arm64-efi/esp/EFI/BOOT/BOOTAA64.EFI" ] || fail 'BOOTAA64.EFI absent' 13
[ "$(id -u)" -eq 0 ] || fail 'root required for loopback filesystems only' 14
if [ -z "$bios_modules" ]
then
  for candidate in /usr/lib/grub/i386-pc /usr/local/lib/grub/i386-pc /usr/lib64/grub/i386-pc
  do
    if [ -f "$candidate/boot.img" ]
    then
      bios_modules=$candidate
      break
    fi
  done
fi
[ -n "$bios_modules" ] && [ -f "$bios_modules/boot.img" ] || fail 'BIOS boot.img absent; pass --bios-modules-dir' 15
for program in qemu-img sgdisk losetup mkfs.vfat mkfs.exfat mount umount findmnt grub-bios-setup
do
  command -v "$program" >/dev/null 2>&1 || fail "missing command: $program" 16
done
[ -d "$output" ] || mkdir -p -- "$output" || fail "cannot create output directory: $output" 17
output=$(CDPATH= cd -- "$output" && pwd -P) || fail 'cannot resolve output directory' 18
[ "$output" != / ] && [ "$output" != "$stages" ] || fail 'invalid output directory' 19
case "$output/" in "$stages/"*) fail 'output nested in stages' 20 ;; esac
image="$output/m-boot-combined.raw"
[ ! -e "$image" ] && [ ! -L "$image" ] || fail "image exists: $image" 21

work=$(mktemp -d "$output/.m-boot-combined.XXXXXXXX") || fail 'cannot create private workspace' 22
loop=
esp_mounted=no
data_mounted=no
cleanup()
{
  ok=yes
  if [ "$data_mounted" = yes ]
  then
    umount "$work/data" || ok=no
  fi
  if [ "$esp_mounted" = yes ]
  then
    umount "$work/esp" || ok=no
  fi
  if [ -n "$loop" ]
  then
    losetup -d "$loop" || ok=no
  fi
  if [ "$ok" = yes ]
  then
    rm -rf -- "$work"
  else
    printf 'm-boot qemu-combined-image: incomplete cleanup; inspect %s (loop %s)\n' "$work" "$loop" >&2
  fi
}
trap cleanup 0
trap 'exit 130' 1 2 3 15
mkdir "$work/esp" "$work/data" || fail 'cannot create mountpoints' 23
raw="$work/disk.raw"
qemu-img create -f raw "$raw" 2G || fail 'qemu-img create failed' 24
sgdisk --clear --new=1:2048:+10M --typecode=1:EF02 \
  --new=2:0:+512M --typecode=2:EF00 \
  --new=3:0:0 --typecode=3:0700 "$raw" || fail 'GPT partitioning failed' 25
sgdisk --verify "$raw" || fail 'GPT verification failed' 26
loop=$(losetup --find --show --partscan "$raw") || fail 'loop attach failed' 27
case "$loop" in /dev/loop[0-9]*) ;; *) fail "unexpected loop: $loop" 28 ;; esac
[ "$(losetup -n -O BACK-FILE "$loop")" = "$raw" ] || fail 'loop backing-file check failed' 29
esp_dev="${loop}p2"
data_dev="${loop}p3"
n=0
while { [ ! -b "$esp_dev" ] || [ ! -b "$data_dev" ]; } && [ "$n" -lt 10 ]
do
  sleep 1
  n=$((n + 1))
done
[ -b "$esp_dev" ] && [ -b "$data_dev" ] || fail 'loop partitions unavailable' 30
mkfs.vfat -F 32 -n MBOOTESP "$esp_dev" || fail 'virtual FAT32 formatting failed' 31
mkfs.exfat -n MBOOTDATA "$data_dev" || fail 'virtual exFAT formatting failed' 32
mount -t vfat "$esp_dev" "$work/esp" || fail 'cannot mount virtual ESP' 33
esp_mounted=yes
mount -t exfat "$data_dev" "$work/data" || fail 'cannot mount virtual data' 34
data_mounted=yes

# The second installer pass adds BOOTAA64.EFI without replacing the common loader.
"$root/install.sh" --stage "$stages/x86_64-efi" --esp "$work/esp" --data "$work/data" --apply || fail 'x86_64 UEFI install failed' 35
"$root/install.sh" --stage "$stages/arm64-efi" --esp "$work/esp" --data "$work/data" --apply || fail 'ARM64 UEFI install failed' 36
[ -s "$work/esp/EFI/BOOT/BOOTX64.EFI" ] || fail 'x86_64 UEFI image not installed' 37
[ -s "$work/esp/EFI/BOOT/BOOTAA64.EFI" ] || fail 'ARM64 UEFI image not installed' 38
[ -f "$work/data/m/boot/loader/init" ] || fail 'common external loader missing' 39
sync
umount "$work/data" || fail 'data unmount failed' 40
data_mounted=no
umount "$work/esp" || fail 'ESP unmount failed' 41
esp_mounted=no
[ "$(losetup -n -O BACK-FILE "$loop")" = "$raw" ] || fail 'loop backing changed before BIOS setup' 42
grub-bios-setup --directory="$bios_modules" \
  --boot-image="$bios_modules/boot.img" \
  --core-image="$stages/i386-pc/bios/core.img" "$loop" || fail 'BIOS embedding in virtual image failed' 43
losetup -d "$loop" || fail 'loop detach failed' 44
loop=
[ ! -e "$image" ] && [ ! -L "$image" ] || fail 'output image appeared during preparation' 45
mv -- "$raw" "$image" || fail 'cannot publish combined image' 46
printf 'm-boot qemu-combined-image: created %s\n' "$image"
