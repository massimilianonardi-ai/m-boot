#!/bin/sh
# Run an already-created raw m-boot test disk with QEMU.
set -eu

usage()
{
  cat <<'HELP'
Usage: qemu-run.sh --target x86_64-efi|arm64-efi|i386-pc --image FILE
                   [--firmware-code FILE --firmware-vars FILE] [--headless]

The disk is run in snapshot mode (guest writes are discarded).
For UEFI, matching OVMF/AAVMF CODE and VARS firmware files are required.
Firmware VARS is copied to a temporary file before QEMU starts.
With --headless the GRUB graphical menu is not visible on the serial console.
HELP
}
fail()
{
  printf 'm-boot qemu-run: error: %s\n' "$1" >&2
  exit "$2"
}

[ "$(uname -s)" = Linux ] || fail 'Linux is required' 1
target=
image=
code=
vars=
headless=no
while [ "$#" -gt 0 ]
do
  case "$1" in
    --target|--image|--firmware-code|--firmware-vars)
      [ "$#" -ge 2 ] && [ -n "$2" ] || fail "missing $1 operand" 2
      case "$1" in
        --target) target=$2 ;;
        --image) image=$2 ;;
        --firmware-code) code=$2 ;;
        --firmware-vars) vars=$2 ;;
      esac
      shift 2 ;;
    --headless) headless=yes; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown argument: $1" 3 ;;
  esac
done
[ -n "$target" ] && [ -n "$image" ] || fail 'target and image required' 4
[ -f "$image" ] && [ ! -L "$image" ] || fail "missing regular disk image: $image" 5
image=$(CDPATH= cd -- "$(dirname -- "$image")" && pwd -P)/$(basename -- "$image") || fail 'cannot resolve image path' 6
case "$target" in
  x86_64-efi|i386-pc) qemu=qemu-system-x86_64 ;;
  arm64-efi) qemu=qemu-system-aarch64 ;;
  *) fail "invalid QEMU target: $target" 7 ;;
esac
command -v "$qemu" >/dev/null 2>&1 || fail "missing emulator: $qemu" 8
if [ "$target" != i386-pc ]
then
  if [ -z "$code" ] && [ -z "$vars" ]
  then
    case "$target" in
      x86_64-efi)
        for prefix in /usr/share/OVMF /usr/share/edk2/ovmf
        do
          for suffix in '' _4M
          do
            if [ -f "$prefix/OVMF_CODE$suffix.fd" ] && [ -f "$prefix/OVMF_VARS$suffix.fd" ]
            then
              code="$prefix/OVMF_CODE$suffix.fd"
              vars="$prefix/OVMF_VARS$suffix.fd"
              break 2
            fi
          done
        done ;;
      arm64-efi)
        for prefix in /usr/share/AAVMF /usr/share/qemu
        do
          if [ -f "$prefix/AAVMF_CODE.fd" ] && [ -f "$prefix/AAVMF_VARS.fd" ]
          then
            code="$prefix/AAVMF_CODE.fd"
            vars="$prefix/AAVMF_VARS.fd"
            break
          fi
          if [ -f "$prefix/edk2-aarch64-code.fd" ] && [ -f "$prefix/edk2-aarch64-vars.fd" ]
          then
            code="$prefix/edk2-aarch64-code.fd"
            vars="$prefix/edk2-aarch64-vars.fd"
            break
          fi
        done ;;
    esac
  fi
  [ -f "$code" ] && [ -f "$vars" ] || fail 'matching UEFI CODE/VARS firmware files required; pass --firmware-code and --firmware-vars' 9
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/m-boot-qemu-run.XXXXXXXX") || fail 'cannot create temporary run directory' 10
trap 'rm -rf -- "$work"' 0
trap 'exit 130' 1 2 3 15
if [ "$target" != i386-pc ]
then
  cp -- "$vars" "$work/vars.fd" || fail 'cannot create private firmware variable store' 11
fi
printf 'm-boot qemu-run: starting %s with %s (snapshot: disk changes discarded)\n' "$target" "$image"
if [ "$headless" = yes ]
then
  set -- -display none -serial mon:stdio
else
  set -- -serial mon:stdio
fi
case "$target" in
  x86_64-efi)
    "$qemu" -machine q35 -accel tcg -m 1024 -smp 2 \
      -drive "if=pflash,format=raw,readonly=on,file=$code" \
      -drive "if=pflash,format=raw,file=$work/vars.fd" \
      -drive "if=none,format=raw,file=$image,id=mboot" -device virtio-blk-pci,drive=mboot \
      -snapshot "$@" ;;
  arm64-efi)
    "$qemu" -machine virt -cpu cortex-a72 -accel tcg -m 1024 -smp 2 \
      -drive "if=pflash,format=raw,readonly=on,file=$code" \
      -drive "if=pflash,format=raw,file=$work/vars.fd" \
      -drive "if=none,format=raw,file=$image,id=mboot" -device virtio-blk-device,drive=mboot \
      -device ramfb -snapshot "$@" ;;
  i386-pc)
    "$qemu" -machine pc -accel tcg -m 1024 -smp 2 \
      -drive "if=none,format=raw,file=$image,id=mboot" -device ide-hd,drive=mboot \
      -boot c -snapshot "$@" ;;
esac
