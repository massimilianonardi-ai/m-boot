#!/bin/sh
# Build, prepare and interactively boot fresh QEMU-only m-boot test disks.
set -eu

usage()
{
  cat <<'HELP'
Usage: qemu-test.sh --target x86_64-efi|arm64-efi|i386-pc --output DIR
                    [--scenario loader|recovery|both] [--stage DIR]
                    [--modules-dir DIR] [--grub-mkimage PATH]
                    [--bios-modules-dir DIR] [--firmware-code FILE --firmware-vars FILE]
                    [--prepare-only] [--headless]

With no --stage, uses ../build.sh to create DIR/stages/TARGET.
Creates raw QEMU disk images with tests/qemu-image.sh, then runs each one
with tests/qemu-run.sh. Does not modify a host disk. Root is needed for the
temporary loop devices and disposable vfat/exFAT mounts.
For separate unprivileged builds, pass --stage DIR from an earlier build.

Expected menu in loader scenario: "m-loader TEST: inspect boot context".
Expected menu in recovery scenario: "Retry m-loader discovery".
Visual confirmation is required; invoking QEMU alone is not a PASS.
HELP
}

fail()
{
  printf 'm-boot qemu-test: error: %s\n' "$1" >&2
  exit "$2"
}

[ "$(uname -s)" = Linux ] || fail 'Linux is required' 1
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P) || fail 'cannot resolve project root' 2
target=
output=
scenario=both
stage=
modules_dir=
mkimage=
bios_modules=
firmware_code=
firmware_vars=
prepare_only=no
headless=no
while [ "$#" -gt 0 ]
do
  case "$1" in
    --target|--output|--scenario|--stage|--modules-dir|--grub-mkimage|--bios-modules-dir|--firmware-code|--firmware-vars)
      [ "$#" -ge 2 ] && [ -n "$2" ] || fail "missing $1 operand" 3
      case "$1" in
        --target) target=$2 ;;
        --output) output=$2 ;;
        --scenario) scenario=$2 ;;
        --stage) stage=$2 ;;
        --modules-dir) modules_dir=$2 ;;
        --grub-mkimage) mkimage=$2 ;;
        --bios-modules-dir) bios_modules=$2 ;;
        --firmware-code) firmware_code=$2 ;;
        --firmware-vars) firmware_vars=$2 ;;
      esac
      shift 2 ;;
    --prepare-only) prepare_only=yes; shift ;;
    --headless) headless=yes; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown argument: $1" 4 ;;
  esac
done
[ -n "$target" ] && [ -n "$output" ] || fail 'target and output are required' 5
case "$target" in x86_64-efi|arm64-efi|i386-pc) ;; *) fail "invalid target: $target" 6 ;; esac
case "$scenario" in loader|recovery|both) ;; *) fail "invalid scenario: $scenario" 7 ;; esac
[ "$(id -u)" -eq 0 ] || fail 'root required to prepare test loopback filesystems; no physical disks are used' 8
[ -d "$output" ] || mkdir -p -- "$output" || fail 'cannot create output directory' 9
output=$(CDPATH= cd -- "$output" && pwd -P) || fail 'cannot resolve output directory' 10
if [ -z "$stage" ]
then
  set -- --target "$target" --output "$output/stages"
  if [ -n "$modules_dir" ]; then set -- "$@" --modules-dir "$modules_dir"; fi
  if [ -n "$mkimage" ]; then set -- "$@" --grub-mkimage "$mkimage"; fi
  "$root/build.sh" "$@" || fail 'm-boot build failed' 11
  stage="$output/stages/$target"
fi
[ -f "$stage/stage-info" ] || fail "missing build stage: $stage" 12
[ "$(sed -n '2p' "$stage/stage-info")" = "target=$target" ] || fail 'stage target does not match requested QEMU target' 13
if [ "$scenario" = both ]
then
  scenarios='loader recovery'
else
  scenarios=$scenario
fi
for case_name in $scenarios
do
  set -- --stage "$stage" --scenario "$case_name" --output "$output"
  if [ -n "$bios_modules" ]; then set -- "$@" --bios-modules-dir "$bios_modules"; fi
  "$root/tests/qemu-image.sh" "$@" || fail "cannot create QEMU $case_name disk image" 14
  disk="$output/m-boot-$target-$case_name.raw"
  printf 'm-boot qemu-test: prepared %s\n' "$disk"
  if [ "$prepare_only" = no ]
  then
    set -- --target "$target" --image "$disk"
    if [ -n "$firmware_code" ]; then set -- "$@" --firmware-code "$firmware_code"; fi
    if [ -n "$firmware_vars" ]; then set -- "$@" --firmware-vars "$firmware_vars"; fi
    if [ "$headless" = yes ]; then set -- "$@" --headless; fi
    printf 'm-boot qemu-test: verify the %s menu manually; close QEMU to continue\n' "$case_name"
    "$root/tests/qemu-run.sh" "$@" || fail "QEMU returned an error for $case_name" 15
  fi
done
printf 'm-boot qemu-test: finished preparation/launch; boot success requires visual inspection\n'
