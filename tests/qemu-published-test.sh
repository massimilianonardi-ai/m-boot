#!/bin/sh
# Interactive three-firmware QEMU check of the exact published USB image.
# Never opens physical disks; snapshot mode is owned by tests/qemu-run.sh.
set -eu

usage()
{
  cat <<'HELP'
Usage: tests/qemu-published-test.sh [--target all|i386-pc|x86_64-efi|arm64-efi]
                                    [--output DIR] [--verify-only]

Runs the same published BIOS + dual-UEFI 576 MiB boot-only image under all three QEMU
firmwares by default, showing one graphical window at a time. After closing
each QEMU window, type PASS or FAIL according to the displayed m-loader menu.
The script does not infer a successful boot from the QEMU exit status.
The raw image is prepared as a sparse, private temporary file and removed
on exit. --output chooses the filesystem for that file (default: current
directory, NOT /tmp). --verify-only checks the real distribution and raw
image without launching QEMU, for noninteractive preflight and CI.
No root access, host block device or GRUB rebuild is required.
HELP
}

fail()
{
  printf 'm-boot qemu-published-test: error: %s\n' "$1" >&2
  exit "$2"
}

info()
{
  printf 'm-boot qemu-published-test: %s\n' "$1"
}

[ "$(uname -s)" = Linux ] || fail 'Linux is required' 1
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P) ||
  fail 'cannot locate repository root' 2
target=all
output=$(pwd -P) || fail 'cannot resolve current working directory' 3
verify_only=no
while [ "$#" -gt 0 ]
do
  case "$1" in
    --target|--output)
      [ "$#" -ge 2 ] && [ -n "$2" ] ||
        fail "missing operand for $1" 4
      case "$1" in
        --target) target=$2 ;;
        --output) output=$2 ;;
      esac
      shift 2 ;;
    --verify-only)
      verify_only=yes
      shift ;;
    --help|-h)
      usage
      exit 0 ;;
    *)
      fail "unknown argument: $1" 5 ;;
  esac
done
case "$target" in
  all|i386-pc|x86_64-efi|arm64-efi) ;;
  *) fail "unsupported target: $target" 6 ;;
esac
if [ "$verify_only" = no ]
then
  [ -t 0 ] || fail 'interactive terminal required for visual boot results' 7
fi

for tool in sha256sum gzip dd wc awk grep mktemp
do
  command -v "$tool" >/dev/null 2>&1 ||
    fail "missing host utility: $tool" 8
done
if [ "$verify_only" = no ]
then
  [ -x "$root/tests/qemu-run.sh" ] ||
    fail 'existing QEMU launcher unavailable or not executable' 9
  case "$target" in
    all)
      for emulator in qemu-system-x86_64 qemu-system-aarch64
      do
        command -v "$emulator" >/dev/null 2>&1 ||
          fail "missing emulator: $emulator" 10
      done ;;
    arm64-efi)
      command -v qemu-system-aarch64 >/dev/null 2>&1 ||
        fail 'missing emulator: qemu-system-aarch64' 11 ;;
    *)
      command -v qemu-system-x86_64 >/dev/null 2>&1 ||
        fail 'missing emulator: qemu-system-x86_64' 12 ;;
  esac
fi

dist="$root/images"
archive="$dist/m-boot-combined.raw.gz"
[ -f "$archive" ] && [ ! -L "$archive" ] &&
  [ -f "$dist/SHA256SUMS" ] && [ -f "$dist/RAW-SHA256SUMS" ] &&
  [ -f "$dist/BUILD-INFO.txt" ] ||
  fail 'published image or checksums absent; git pull first' 13
grep -Fx 'loader_location=esp' "$dist/BUILD-INFO.txt" >/dev/null &&
grep -Fx 'partition_count=2' "$dist/BUILD-INFO.txt" >/dev/null &&
grep -Fx 'disk_image_role=boot-only' "$dist/BUILD-INFO.txt" >/dev/null &&
grep -Fx 'image_bytes=603979776' "$dist/BUILD-INFO.txt" >/dev/null ||
  fail 'published image is not the compact two-partition ESP-loader revision' 14

expected_compressed=$(awk '$2 == "m-boot-combined.raw.gz" { print $1 }' "$dist/SHA256SUMS")
expected_raw=$(awk '$2 == "m-boot-combined.raw" { print $1 }' "$dist/RAW-SHA256SUMS")
[ "${#expected_compressed}" -eq 64 ] && [ "${#expected_raw}" -eq 64 ] ||
  fail 'incomplete distribution SHA256 metadata' 15
compressed_hash=$(sha256sum "$archive" | awk '{ print $1 }') ||
  fail 'cannot hash compressed distribution' 16
[ "$compressed_hash" = "$expected_compressed" ] ||
  fail 'compressed published image SHA256 mismatch' 17

[ -d "$output" ] || fail "output directory absent: $output" 18
output=$(CDPATH= cd -- "$output" && pwd -P) ||
  fail 'cannot resolve output directory' 19
umask 077
work=$(mktemp -d "$output/.m-boot-qemu-published.XXXXXXXX") ||
  fail 'cannot create private image directory in selected output' 20
cleanup()
{
  rm -rf -- "$work"
}
trap cleanup 0
trap 'exit 130' 1 2 3 15
image="$work/m-boot-combined.raw"
status_file="$work/decompress-status"

info "preparing one disposable sparse raw image under $output"
# No pipefail in POSIX sh: capture the gzip producer status separately
# from dd. GNU dd full blocks permit sparse holes for zero-filled regions.
if
  (
    if gzip -dc "$archive"
    then
      printf 'ok\n' > "$status_file"
    else
      printf 'failed\n' > "$status_file"
    fi
  ) | dd of="$image" bs=4M iflag=fullblock conv=sparse,fsync status=none
then
  :
else
  fail 'cannot materialize sparse raw image (disk space/quota or dd failure)' 21
fi
[ -f "$status_file" ] && [ "$(cat "$status_file")" = ok ] ||
  fail 'gzip decompression failed' 22
bytes=$(wc -c < "$image" | tr -d '[:space:]') ||
  fail 'cannot inspect raw image length' 23
[ "$bytes" = 603979776 ] ||
  fail "unexpected raw image length: $bytes" 24
raw_hash=$(sha256sum "$image" | awk '{ print $1 }') ||
  fail 'cannot hash raw disk image' 25
[ "$raw_hash" = "$expected_raw" ] ||
  fail 'decompressed raw image SHA256 mismatch' 26
info "verified one immutable 576 MiB boot-only raw image (SHA256=$raw_hash)"

if [ "$verify_only" = yes ]
then
  info 'PASS: published image verified; no QEMU run requested'
  exit 0
fi
if [ "$target" = all ]
then
  targets='i386-pc x86_64-efi arm64-efi'
else
  targets=$target
fi

failed=no
for firmware in $targets
do
  printf '\n=== QEMU %s ===\n' "$firmware"
  printf 'Inspect the graphical m-loader menu, including "Inspect boot context".\n'
  printf 'Close the QEMU window after inspection; disk writes are discarded.\n'
  if "$root/tests/qemu-run.sh" --target "$firmware" --image "$image"
  then
    printf 'Did the external m-loader menu appear and work? Type PASS or FAIL: '
    IFS= read -r observed || observed=FAIL
    case "$observed" in
      PASS) info "$firmware: operator-confirmed PASS" ;;
      *) info "$firmware: NOT VERIFIED (input=$observed)"; failed=yes ;;
    esac
  else
    info "$firmware: QEMU launch/exit failure"
    failed=yes
  fi
  # The single shared raw image must remain unmodified after every run.
  after_hash=$(sha256sum "$image" | awk '{ print $1 }') ||
    fail "cannot verify disk image after $firmware" 27
  [ "$after_hash" = "$expected_raw" ] ||
    fail "raw disk image changed after $firmware; snapshot isolation failed" 28
done

if [ "$failed" = yes ]
then
  fail 'one or more firmware boots failed or were not confirmed' 29
fi
info 'PASS: operator confirmed the m-loader menu on every requested firmware'
