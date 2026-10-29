# GRUB UEFI modules and prebuilt boot stages

This directory contains **two Git-tracked, complete GRUB UEFI module sets**.
They are not part of the RumiAI-authored GRUB scripts and do not replace
`build.sh`. Each archive also includes the boot-stage output built by
`build.sh` from the repository revision recorded in its metadata.

| Target | Git archive | Native builder |
| --- | --- | --- |
| x86_64-efi | `m-boot-x86_64-efi.tar.xz` | `ubuntu-24.04` / `grub-efi-amd64-bin` |
| arm64-efi | `m-boot-arm64-efi.tar.xz` | `ubuntu-24.04-arm` / `grub-efi-arm64-bin` |

Each `.tar.xz` has a corresponding `.tar.xz.sha256` manifest committed next
to it. The archives contain **all files** distributed under
`/usr/lib/grub/<target>/`, not just the bootstrap subset.

Archive structure:

```text
<TARGET>/                        complete m-boot stage
  stage-info
  esp/EFI/BOOT/BOOT*.EFI
  data/m/boot/loader/
grub-modules/<TARGET>/           complete Ubuntu GRUB target directory
<architecture>-build-info.txt   source_commit, runner architecture, package versions
BOOT*.EFI.sha256                 checksum of the compiled EFI image
```

Usage from the repository root:

```sh
sha256sum -c prebuilt/m-boot-x86_64-efi.tar.xz.sha256
sha256sum -c prebuilt/m-boot-arm64-efi.tar.xz.sha256
mkdir -p qemu-combined/stages
tar -xJf prebuilt/m-boot-x86_64-efi.tar.xz -C qemu-combined/stages
tar -xJf prebuilt/m-boot-arm64-efi.tar.xz -C qemu-combined/stages
```

The unpacked GRUB modules may also be supplied explicitly to `build.sh`
using `--modules-dir ./qemu-combined/stages/grub-modules/<TARGET>`.
Use a compatible `grub-mkimage` version. Keep the source commit from the
`*-build-info.txt` file when comparing test evidence; a later archive-commit
SHA is not the binary's source revision.

The workflow files under `.github/workflows/` reproduce these archives on
native Linux runners. Workflow runs also upload 30-day Actions artifacts, but
the Git-tracked archives do not expire. A manually dispatched workflow does
not replace tracked binaries.

**Third-party software.** GRUB and its binary modules are third-party
software distributed under the GNU General Public License (GPL), not
authored by RumiAI. The GRUB source package corresponding to each Ubuntu
binary package is `grub2`; the exact installed Ubuntu package revisions are
recorded in each archive's `*-build-info.txt`. Retrieve the corresponding
Ubuntu source package from Ubuntu's source package archive (or using
`apt source grub2` with source repositories configured), and retain the
appropriate GRUB copyright and licensing notices when redistributing.
The GRUB project source is also published at
https://www.gnu.org/software/grub/.

A generated EFI executable or module archive is **not** evidence of
successful firmware boot. BIOS/i386-pc is a separate target and is not
included in these two UEFI packages.
