#!/bin/sh
# Read-only inspection of the actual ISO payloads on MBOOTDATA.
# Reports boot catalogs and source paths, never claims a usable live boot.
set -eu

usage()
{
  cat <<'HELP'
Usage: ./tests/iso-boot-report.sh --data-root DIRECTORY

Inspect DIRECTORY/m/boot/iso/*.iso and optional native Memtest binaries
under DIRECTORY/m/boot/efi/memtest/. Requires xorriso and file.
The inspection never mounts images, opens a raw disk, or writes to the USB.
All output goes to stdout; redirect it to a host file to share the report.
This identifies potential boot routes, NOT successful ISO boot.
HELP
}

fail()
{
  printf 'm-boot ISO report: error: %s\n' "$1" >&2
  exit "$2"
}

root=
while [ "$#" -gt 0 ]
do
  case "$1" in
    --data-root)
      [ "$#" -ge 2 ] && [ -n "$2" ] || fail 'missing --data-root operand' 1
      root=$2
      shift 2 ;;
    --help|-h)
      usage
      exit 0 ;;
    *)
      fail "unknown argument: $1" 2 ;;
  esac
done

[ -n "$root" ] || fail '--data-root is required' 3
[ -d "$root" ] || fail "data root does not exist: $root" 4
root=$(CDPATH= cd -- "$root" && pwd -P) || fail 'cannot resolve data root' 5
iso_dir="$root/m/boot/iso"
[ -d "$iso_dir" ] || fail "ISO directory does not exist: $iso_dir" 6
command -v xorriso >/dev/null 2>&1 || fail 'xorriso is required (apt install xorriso)' 7
command -v file >/dev/null 2>&1 || fail 'file is required (apt install file)' 8
command -v mktemp >/dev/null 2>&1 || fail 'mktemp is required' 9

work=$(mktemp -d) || fail 'cannot allocate temporary report directory' 10
trap 'rm -rf -- "$work"' 0
trap 'exit 130' 1 2 3 15

printf 'm-boot ISO boot inventory\nData root: %s\n' "$root"
printf 'Read-only report: file discovery is NOT a boot PASS.\n'
printf '\nNative Memtest binaries:\n'
found_native=no
for name in mt86p_900_x86_64 mt86p_900_i586 mt86p_900_arm64 mt86p_900_la64
do
  binary="$root/m/boot/efi/memtest/$name"
  if [ -f "$binary" ]
  then
    found_native=yes
    printf '  %s: ' "$name"
    file -b -- "$binary"
  fi
done
if [ "$found_native" = no ]
then
  printf '  None at the expected path (verify copied /m/boot/efi/memtest).\n'
fi

count=0
failed=0
for iso in "$iso_dir"/*.iso
do
  [ -f "$iso" ] || continue
  count=$((count + 1))
  printf '\n===== %s =====\n' "${iso##*/}"
  if xorriso -indev "$iso" -report_el_torito plain -report_system_area plain \
    > "$work/catalog" 2> "$work/catalog.err"
  then
    grep -E '^(Volume id|Boot record|El Torito (catalog|cat path|images|boot img)|System area summary|ISO image size)' \
      "$work/catalog" || :
    if ! grep -Eq '^El Torito boot img' "$work/catalog"
    then
      printf '  No El Torito boot image reported; verify the source format.\n'
    fi
  else
    printf '  ERROR: cannot inspect the ISO boot catalog.\n'
    cat "$work/catalog.err"
    failed=$((failed + 1))
    continue
  fi

  if xorriso -indev "$iso" -find / -type f -exec echo -- \
    > "$work/paths" 2> "$work/paths.err"
  then
    printf 'Boot-related ISO paths (up to 90):\n'
    # xorriso quotes each reported pathname; remove surrounding quotes
    # before matching the actual ISO basename.
    sed -e "s/^'//" -e "s/'$//" "$work/paths" > "$work/clean-paths"
    grep -Ei '/(loopback[.]cfg|grub[.]cfg|boot(x64|aa64)[.]efi|grub(x64|aa64)[.]efi|bootmgr|boot[.]wim|boot[.]sdi|vmlinuz[^/]*|initrd[^/]*|initram[^/]*|isolinux[.]cfg|syslinux[.]cfg|memtest[^/]*)' "$work/clean-paths" | head -n 90 || :
    printf '  (Absence from this filtered list does not prove absence of a boot route.)\n'
  else
    printf '  ERROR: cannot inspect ISO file paths.\n'
    cat "$work/paths.err"
    failed=$((failed + 1))
  fi
done

printf '\nSummary: %s ISO file(s) inspected; %s inspection error(s).\n' "$count" "$failed"
printf 'Only successful firmware/kernel/live-root testing can establish boot compatibility.\n'
[ "$count" -gt 0 ] || fail "no ISO files under $iso_dir" 11
[ "$failed" -eq 0 ] || fail "$failed ISO inspection errors occurred" 12
