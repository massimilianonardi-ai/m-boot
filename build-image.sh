#!/bin/sh
# Build ONE boot-only GPT disk for BIOS, x86_64 UEFI and ARM64 UEFI.
set -eu

usage()
{
  cat <<'HELP'
Usage: build-image.sh --stages DIR --output DIR [--bios-modules-dir DIR]

DIR must contain build.sh stages: i386-pc/, x86_64-efi/, arm64-efi/.
Creates a new 576 MiB output/m-boot-combined.raw; refuses overwrite.
Uses only a temporary raw file/loop device, never a physical disk operand.
GPT layout: 10 MiB BIOS Boot (EF02), 512 MiB FAT32 ESP (both UEFI
architectures), with NO partition 3. The installer creates ext4 later.
Requires Linux x86_64 and root to create the FAT32 ESP in a raw image.
BIOS modules: --bios-modules-dir > verified tracked archive > host directory.
HELP
}

fail()
{
  printf 'm-boot build-image: error: %s\n' "$1" >&2
  exit "$2"
}

[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || fail 'Linux x86_64 build host required' 1
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || fail 'cannot resolve project root' 2
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

bios_setup=grub-bios-setup
case "$(uname -m)" in
  x86_64|aarch64)
    host_arch=$(uname -m)
    tool_archive="$root/prebuilt/m-boot-grub-tools-linux-$host_arch.tar.xz"
    if [ -e "$tool_archive" ] || [ -L "$tool_archive" ] || [ -e "$tool_archive.sha256" ] || [ -L "$tool_archive.sha256" ]
    then
      bios_setup="$root/tools/grub-bios-setup"
    fi ;;
esac
bios_from_archive=no
if [ -z "$bios_modules" ]
then
  archive="$root/prebuilt/m-boot-i386-pc.tar.xz"
  manifest="$archive.sha256"
  if [ -e "$archive" ] || [ -e "$manifest" ] || [ -L "$archive" ] || [ -L "$manifest" ]
  then
    [ -f "$archive" ] && [ ! -L "$archive" ] || fail "missing or invalid bundled BIOS archive: $archive" 47
    [ -f "$manifest" ] && [ ! -L "$manifest" ] || fail "missing or invalid BIOS checksum: $manifest" 48
    command -v sha256sum >/dev/null 2>&1 || fail 'sha256sum required for bundled BIOS modules' 49
    (CDPATH= cd -- "$root" && sha256sum -c prebuilt/m-boot-i386-pc.tar.xz.sha256) || fail "BIOS archive integrity check failed: $archive" 50
    bios_from_archive=yes
  else
    for candidate in /usr/lib/grub/i386-pc /usr/local/lib/grub/i386-pc /usr/lib64/grub/i386-pc
    do
      if [ -f "$candidate/boot.img" ]
      then
        bios_modules=$candidate
        break
      fi
    done
  fi
fi
if [ "$bios_from_archive" = no ]
then
  [ -n "$bios_modules" ] && [ -f "$bios_modules/boot.img" ] || fail 'BIOS boot.img absent; pass --bios-modules-dir or use tracked archive' 15
fi
for program in qemu-img sgdisk losetup mkfs.vfat mount umount findmnt
do
  command -v "$program" >/dev/null 2>&1 || fail "missing command: $program" 16
done
command -v "$bios_setup" >/dev/null 2>&1 || fail "GRUB BIOS setup utility unavailable: $bios_setup" 57
[ -d "$output" ] || mkdir -p -- "$output" || fail "cannot create output directory: $output" 17
output=$(CDPATH= cd -- "$output" && pwd -P) || fail 'cannot resolve output directory' 18
[ "$output" != / ] && [ "$output" != "$stages" ] || fail 'invalid output directory' 19
case "$output/" in "$stages/"*) fail 'output nested in stages' 20 ;; esac
image="$output/m-boot-combined.raw"
[ ! -e "$image" ] && [ ! -L "$image" ] || fail "image exists: $image" 21

work=$(mktemp -d "$output/.m-boot-combined.XXXXXXXX") || fail 'cannot create private workspace' 22
loop=
esp_mounted=no
cleanup()
{
  ok=yes
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
    printf 'm-boot build-image: incomplete cleanup; inspect %s (loop %s)\n' "$work" "$loop" >&2
  fi
}
trap cleanup 0
trap 'exit 130' 1 2 3 15

if [ "$bios_from_archive" = yes ]
then
  tar -xJf "$archive" -C "$work" grub-modules/i386-pc i386-pc-build-info.txt || fail 'cannot extract verified BIOS boot.img and provenance' 51
  bios_modules="$work/grub-modules/i386-pc"
  [ -s "$bios_modules/boot.img" ] || fail 'bundled BIOS boot.img is missing' 52
  archive_version=$(awk '$1 == "grub-common" { print $2 }' "$work/i386-pc-build-info.txt")
  bios_setup_version=$("$bios_setup" --version | awk 'END { print $NF }')
  [ -n "$archive_version" ] && [ "$bios_setup_version" = "$archive_version" ] || fail "GRUB BIOS setup version mismatch: archive=$archive_version, host=$bios_setup_version" 53
  printf 'm-boot build-image: verified bundled BIOS boot.img version=%s\n' "$archive_version"
fi

mkdir "$work/esp" || fail 'cannot create mountpoints' 23
raw="$work/disk.raw"
qemu-img create -f raw "$raw" 576M || fail 'qemu-img create failed' 24
sgdisk --clear --new=1:2048:+10M --typecode=1:EF02 \
  --new=2:0:+512M --typecode=2:EF00 "$raw" || fail 'GPT partitioning failed' 25
sgdisk --verify "$raw" || fail 'GPT verification failed' 26
loop=$(losetup --find --show --partscan "$raw") || fail 'loop attach failed' 27
case "$loop" in /dev/loop[0-9]*) ;; *) fail "unexpected loop: $loop" 28 ;; esac
[ "$(losetup -n -O BACK-FILE "$loop")" = "$raw" ] || fail 'loop backing-file check failed' 29
esp_dev="${loop}p2"
n=0
while { [ ! -b "$esp_dev" ]; } && [ "$n" -lt 10 ]
do
  sleep 1
  n=$((n + 1))
done
[ -b "$esp_dev" ] && [ ! -b "${loop}p3" ] || fail 'loop partitions unavailable' 30
mkfs.vfat -F 32 -n MBOOTESP "$esp_dev" || fail 'virtual FAT32 formatting failed' 31
mount -t vfat "$esp_dev" "$work/esp" || fail 'cannot mount virtual ESP' 33
esp_mounted=yes

# The second ESP installation adds BOOTAA64.EFI without replacing its loader.
"$root/install.sh" --stage "$stages/x86_64-efi" --esp "$work/esp" --apply || fail 'x86_64 UEFI install failed' 35
"$root/install.sh" --stage "$stages/arm64-efi" --esp "$work/esp" --apply || fail 'ARM64 UEFI install failed' 36
[ -s "$work/esp/EFI/BOOT/BOOTX64.EFI" ] || fail 'x86_64 UEFI image not installed' 37
[ -s "$work/esp/EFI/BOOT/BOOTAA64.EFI" ] || fail 'ARM64 UEFI image not installed' 38
[ -f "$work/esp/m/boot/loader/init" ] || fail 'common external ESP loader missing' 39
[ -s "$work/esp/m/boot/loader/i386-pc/normal.mod" ] || fail 'BIOS modules absent from ESP loader' 58
[ -s "$work/esp/m/boot/loader/x86_64-efi/normal.mod" ] || fail 'x86_64 modules absent from ESP loader' 59
[ -s "$work/esp/m/boot/loader/arm64-efi/normal.mod" ] || fail 'ARM64 modules absent from ESP loader' 60
sync
umount "$work/esp" || fail 'ESP unmount failed' 41
esp_mounted=no
[ "$(losetup -n -O BACK-FILE "$loop")" = "$raw" ] || fail 'loop backing changed before BIOS setup' 42
# grub-bios-setup resolves --boot-image and --core-image relative to --directory.
# Stage both images in our disposable workspace; never mutate host module trees.
mkdir "$work/bios-setup" || fail 'cannot create BIOS setup workspace' 54
cp -- "$bios_modules/boot.img" "$work/bios-setup/boot.img" || fail 'cannot stage BIOS boot.img' 55
cp -- "$stages/i386-pc/bios/core.img" "$work/bios-setup/core.img" || fail 'cannot stage BIOS core.img' 56
"$bios_setup" --directory="$work/bios-setup" \
  --boot-image=boot.img --core-image=core.img "$loop" || fail 'BIOS embedding in virtual image failed' 43
losetup -d "$loop" || fail 'loop detach failed' 44
loop=
[ ! -e "$image" ] && [ ! -L "$image" ] || fail 'output image appeared during preparation' 45
mv -- "$raw" "$image" || fail 'cannot publish combined image' 46
printf 'm-boot build-image: created %s\n' "$image"
