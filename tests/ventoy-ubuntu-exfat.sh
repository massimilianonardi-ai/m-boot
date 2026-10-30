#!/bin/sh
# Differential Ubuntu ISO boot experiment against official Ventoy on an
# isolated, newly created raw disk. Never accepts a physical disk argument.
set -eu

VERSION=1.1.18
VENTOY_SHA256=d86ff9de63d94c8b8f1f6b14d23c55af4b88e8207bf2893890892a6a97b1ad54
UBUNTU_SHA256=601e30fbf5d97759367c632e2c33630665039b7e2158fd068403da3ccf1bda1f
UBUNTU_NAME=ubuntu-26.04.1-desktop-amd64.iso

usage()
{
  cat <<'HELP'
Usage:
  tests/ventoy-ubuntu-exfat.sh prepare --iso ISO --ventoy-tar ARCHIVE --output DIR
  tests/ventoy-ubuntu-exfat.sh boot --disk DISPOSABLE_RAW --mode normal|grub2

prepare creates a NEW 12 GiB sparse image in DIR and installs official Ventoy
1.1.18 through a checked, image-backed /dev/loopN only. The installer will
DESTROY THE NEW IMAGE; it never receives a physical disk or external path.
The input ISO and Ventoy archive must match their official SHA256 values.
The ISO is copied to exFAT at /m/boot/iso/ and readback-verified.

boot uses x86_64 BIOS, i440fx pc, TCG, 2048 MiB, two vCPUs, IDE and QEMU
snapshot mode. In normal mode, select the ISO then Normal mode. Only if it
fails, rerun with --mode grub2 and select GRUB2 mode in the Ventoy secondary
menu (or press Ctrl+r before choosing the ISO). Verify Ubuntu live desktop,
not just the bootloader, splash, initramfs or BusyBox shell.
HELP
}
fail()
{
  printf 'ventoy-ubuntu-exfat: %s\n' "$1" >&2
  exit "$2"
}
require()
{
  command -v "$1" >/dev/null 2>&1 || fail "missing command: $1" 2
}
check_hash()
{
  actual=$(sha256sum "$1" | awk '{print $1}') || fail "cannot hash $1" 3
  [ "$actual" = "$2" ] || fail "SHA256 mismatch: $1 (observed $actual)" 4
}

[ "$(uname -s)" = Linux ] || fail 'Linux host required' 1
[ "$#" -gt 0 ] || { usage; exit 2; }
command=$1
shift
case "$command" in
  prepare)
    iso=
    archive=
    output=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --iso|--ventoy-tar|--output)
          [ "$#" -ge 2 ] && [ -n "$2" ] || fail "missing value: $1" 5
          case "$1" in
            --iso) iso=$2 ;;
            --ventoy-tar) archive=$2 ;;
            --output) output=$2 ;;
          esac
          shift 2 ;;
        *) fail "unknown prepare option: $1" 6 ;;
      esac
    done
    [ -n "$iso" ] && [ -n "$archive" ] && [ -n "$output" ] || fail 'prepare needs --iso, --ventoy-tar and --output' 7
    [ -f "$iso" ] && [ ! -L "$iso" ] || fail 'ISO must be a regular non-symlink file' 8
    [ -f "$archive" ] && [ ! -L "$archive" ] || fail 'Ventoy archive must be a regular non-symlink file' 9
    [ -d "$output" ] && [ ! -L "$output" ] || fail 'output must be an existing non-symlink directory' 10
    [ "$(basename "$iso")" = "$UBUNTU_NAME" ] || fail "expected ISO basename: $UBUNTU_NAME" 11
    for tool in sha256sum awk tar truncate mktemp sudo losetup mount umount blkid partprobe lsblk; do require "$tool"; done
    check_hash "$iso" "$UBUNTU_SHA256"
    check_hash "$archive" "$VENTOY_SHA256"
    iso=$(CDPATH= cd -- "$(dirname -- "$iso")" && pwd -P)/$(basename -- "$iso")
    archive=$(CDPATH= cd -- "$(dirname -- "$archive")" && pwd -P)/$(basename -- "$archive")
    output=$(CDPATH= cd -- "$output" && pwd -P)
    sudo -v || fail 'sudo authorization needed for image-backed loop device' 12
    umask 077
    work=$(mktemp -d "$output/ventoy-ubuntu.XXXXXXXX") || fail 'cannot create private experiment directory' 13
    disk="$work/ventoy-bios.raw"
    mountpoint="$work/exfat"
    loop=
    mounted=no
    cleanup()
    {
      if [ "$mounted" = yes ]; then sudo -n umount -- "$mountpoint" || :; fi
      if [ -n "$loop" ]; then sudo -n losetup -d -- "$loop" || :; fi
    }
    trap cleanup 0
    trap 'exit 130' 1 2 3 15
    truncate -s 12G -- "$disk" || fail 'cannot create sparse disk' 14
    mkdir -p -- "$work/package" "$mountpoint"
    tar -xzf "$archive" -C "$work/package" || fail 'cannot extract official Ventoy package' 15
    package="$work/package/ventoy-$VERSION"
    [ -f "$package/Ventoy2Disk.sh" ] && [ -f "$package/boot/boot.img" ] || fail 'unexpected official archive layout' 16
    loop=$(sudo -n losetup --find --show --partscan -- "$disk") || fail 'cannot attach disposable loop image' 17
    case "$loop" in
      /dev/loop*)
        number=${loop#/dev/loop}
        case "$number" in ''|*[!0-9]*) fail "unexpected loop identity: $loop" 18 ;; esac ;;
      *) fail "non-loop device returned: $loop" 19 ;;
    esac
    backing=$(sudo -n cat "/sys/class/block/loop$number/loop/backing_file") || fail 'cannot confirm loop backing file' 20
    [ "$backing" = "$disk" ] || fail "loop backing-file mismatch: $backing" 21
    [ "$(lsblk -dn -o TYPE -- "$loop" | tr -d '[:space:]')" = loop ] || fail 'backing block device is not loop type' 22
    printf 'Installing official Ventoy %s to disposable disk %s (loop %s)\n' "$VERSION" "$disk" "$loop"
    (
      cd -- "$package" || exit 1
      printf 'y\ny\n' | sudo -n sh ./Ventoy2Disk.sh -i -g "$loop"
    ) || fail 'Ventoy installer returned failure' 23
    sudo -n partprobe -- "$loop" || fail 'cannot rescan disposable disk partitions' 24
    part="${loop}p1"
    [ -b "$part" ] || fail "Ventoy partition not found: $part" 25
    fstype=$(sudo -n blkid -s TYPE -o value -- "$part") || fail 'cannot determine partition filesystem' 26
    [ "$fstype" = exfat ] || fail "expected exFAT, got: $fstype" 27
    sudo -n mount -t exfat -- "$part" "$mountpoint" || fail 'cannot mount disposable exFAT' 28
    mounted=yes
    sudo -n mkdir -p -- "$mountpoint/m/boot/iso" || fail 'cannot create ISO collection' 29
    sudo -n cp -- "$iso" "$mountpoint/m/boot/iso/$UBUNTU_NAME" || fail 'cannot copy ISO' 30
    sudo -n sync || fail 'cannot flush copied ISO' 31
    copied=$(sudo -n sha256sum "$mountpoint/m/boot/iso/$UBUNTU_NAME" | awk '{print $1}') || fail 'cannot read back copied ISO' 32
    [ "$copied" = "$UBUNTU_SHA256" ] || fail 'ISO readback SHA256 mismatch' 33
    sudo -n umount -- "$mountpoint" || fail 'cannot unmount copied ISO partition' 34
    mounted=no
    sudo -n losetup -d -- "$loop" || fail 'cannot detach disposable disk' 35
    loop=
    {
      printf 'experiment=ventoy-ubuntu-exfat-1.1.18\n'
      printf 'ventoy_sha256=%s\n' "$VENTOY_SHA256"
      printf 'ubuntu_sha256=%s\n' "$UBUNTU_SHA256"
      printf 'ubuntu_iso_source=%s\n' "$iso"
      printf 'filesystem=exfat\npartition_style=gpt\nfirmware=bios\n'
      printf 'qemu_machine=pc\nqemu_accel=tcg\nqemu_mem_mib=2048\nqemu_vcpus=2\nqemu_disk=ide-hd\n'
      printf 'guest_iso=/m/boot/iso/%s\n' "$UBUNTU_NAME"
    } > "$work/experiment.txt"
    cat > "$work/results.md" <<'RESULTS'
# Ventoy Ubuntu 26.04.1 exFAT boot observations

- Normal mode: NOT EXECUTED / PASS / FAIL (select one)
- GRUB2 mode: NOT EXECUTED / PASS / FAIL (select one; run only after normal failure)
- Success requires Ubuntu live root/desktop, not splash, kernel or initramfs.
- For each run: capture GRUB/menu, kernel messages, BusyBox errors or live terminal.
- Live diagnostics: `cat /proc/cmdline`, `findmnt /`, `lsblk -f`, `mount`, `ls -l /dev/mapper/`, `sudo vtoydump -l` (if available).
- Failed initramfs diagnostics: `cat /proc/cmdline`, `cat /proc/filesystems`, `blkid`, `ls /dev/mapper`, `dmesg | tail`.
- Compare the ISO mapping with the m-boot ash baseline; classify mechanism only from observed evidence.
RESULTS
    printf '\nPREPARED: %s\n' "$disk"
    printf 'Manifest: %s\nResults: %s\n' "$work/experiment.txt" "$work/results.md"
    printf 'Boot: %s boot --disk "%s" --mode normal\n' "$0" "$disk"
    ;;
  boot)
    disk=
    mode=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --disk|--mode)
          [ "$#" -ge 2 ] && [ -n "$2" ] || fail "missing value: $1" 36
          case "$1" in --disk) disk=$2 ;; --mode) mode=$2 ;; esac
          shift 2 ;;
        *) fail "unknown boot option: $1" 37 ;;
      esac
    done
    [ -n "$disk" ] && [ -n "$mode" ] || fail 'boot needs --disk and --mode' 38
    case "$mode" in normal|grub2) ;; *) fail 'mode must be normal or grub2' 39 ;; esac
    [ -f "$disk" ] && [ ! -L "$disk" ] || fail 'disk must be a regular non-symlink file' 40
    [ "$(basename -- "$disk")" = ventoy-bios.raw ] || fail 'unexpected experiment image name' 41
    [ -f "$(dirname -- "$disk")/experiment.txt" ] || fail 'experiment manifest missing' 42
    grep -Fx 'experiment=ventoy-ubuntu-exfat-1.1.18' "$(dirname -- "$disk")/experiment.txt" >/dev/null || fail 'experiment manifest identity mismatch' 43
    require qemu-system-x86_64
    disk=$(CDPATH= cd -- "$(dirname -- "$disk")" && pwd -P)/$(basename -- "$disk")
    printf '\nVENTOY %s MODE: select %s for the Ubuntu ISO in the GUI.\n' "$VERSION" "$mode"
    printf 'To use GRUB2 mode, select it in the secondary menu or press Ctrl+r.\n'
    printf 'This QEMU session uses disk snapshot mode; no guest writes persist.\n'
    qemu-system-x86_64 -machine pc -accel tcg -m 2048 -smp 2 \
      -drive "if=none,id=ventoy,format=raw,file=$disk" -device ide-hd,drive=ventoy \
      -boot c -snapshot -serial mon:stdio
    ;;
  --help|-h) usage ;;
  *) usage; fail "unknown subcommand: $command" 44 ;;
esac
