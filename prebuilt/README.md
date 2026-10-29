# GRUB target modules and prebuilt boot stages

This directory contains **three Git-tracked, complete GRUB target module sets**,
plus separately versioned host-native GRUB utility archives for Linux
x86_64 and aarch64. The host tool packages are built on native Ubuntu 24.04
GitHub Actions runners, and contain grub-mkimage and grub-script-check with
non-glibc shared library dependencies and package provenance. The x86_64
bundle also includes grub-bios-setup; no native ARM64 BIOS installer has
yet been validated. The thin tools/grub-tool launcher validates SHA256
then extracts/executes the matching host binary in a private temporary
directory, leaving host GRUB unchanged. The host's glibc must be at least
as recent as Ubuntu 24.04.

Host-native tool package names:
- m-boot-grub-tools-linux-x86_64.tar.xz
- m-boot-grub-tools-linux-aarch64.tar.xz

Every package has a sidecar .sha256. No GRUB installation or downgrade is
necessary when building with these packages.


They are not part of the RumiAI-authored GRUB scripts and do not replace
`build.sh`. Each archive also includes the boot-stage output built by
`build.sh` from the repository revision recorded in its metadata.

| Target | Git archive | Native builder |
| --- | --- | --- |
| x86_64-efi | `m-boot-x86_64-efi.tar.xz` | `ubuntu-24.04` / `grub-efi-amd64-bin` |
| arm64-efi | `m-boot-arm64-efi.tar.xz` | `ubuntu-24.04-arm` / `grub-efi-arm64-bin` |
| i386-pc | `m-boot-i386-pc.tar.xz` | `ubuntu-24.04` / `grub-pc-bin` |

Each `.tar.xz` has a corresponding `.tar.xz.sha256` manifest committed next
to it. The archives contain **all files** distributed under
`/usr/lib/grub/<target>/`, not just the bootstrap subset.

Archive structure:

```text
<TARGET>/                        complete m-boot stage
  stage-info
  esp/EFI/BOOT/BOOT*.EFI (UEFI targets)
  bios/core.img (i386-pc target)
  data/m/boot/loader/
grub-modules/<TARGET>/           complete Ubuntu GRUB target directory
<architecture>-build-info.txt   source_commit, runner architecture, package versions
BOOT*.EFI.sha256 (UEFI targets)  checksum of the compiled EFI image
core.img.sha256 (i386-pc)       checksum of the compiled BIOS core image
                               (BIOS boot.img is in grub-modules/i386-pc/)
```

Usage from the repository root:

```sh
sha256sum -c prebuilt/m-boot-x86_64-efi.tar.xz.sha256
sha256sum -c prebuilt/m-boot-arm64-efi.tar.xz.sha256
sha256sum -c prebuilt/m-boot-i386-pc.tar.xz.sha256
mkdir -p qemu-combined/stages
tar -xJf prebuilt/m-boot-x86_64-efi.tar.xz -C qemu-combined/stages
tar -xJf prebuilt/m-boot-arm64-efi.tar.xz -C qemu-combined/stages
tar -xJf prebuilt/m-boot-i386-pc.tar.xz -C qemu-combined/stages
```

For the combined QEMU disk test the BIOS image also requires
`grub-bios-setup`, supplied by the host GRUB utilities; the complete BIOS
module directory includes `boot.img` and may be passed explicitly as
`--bios-modules-dir ./qemu-combined/stages/grub-modules/i386-pc`.
`core.img` is not bootable merely by copying it to a filesystem: BIOS
installation requires boot-sector and GPT BIOS Boot Partition embedding.

Normal builds use the tracked archives automatically: `./build.sh --target
<TARGET> --output DIR` verifies the SHA256, checks its recorded GRUB
version against `grub-mkimage`, extracts only the module directory to a
temporary location, then regenerates the boot stage from the CURRENT
project source files. Explicit `--modules-dir` bypasses archive selection.
A corrupt or incomplete archive is an error, not a request for host fallback.

`tests/qemu-combined-test.sh --output DIR` builds all three target stages
this way; `tests/qemu-combined-image.sh` independently resolves and verifies
the bundled BIOS `boot.img` for installation into its disposable disk
image. The host still needs `grub-bios-setup` and compatible GRUB tools.
Manual extraction below remains useful for precompiled-stage inspection and
explicitly chosen overrides.

The build uses the archive's target modules to compile the essential core
image, then stages the complete module directories for **all three** GRUB
targets at `data/m/boot/loader/<TARGET>/`. When the embedded init finds
the loader, it changes `prefix` to `(<device>)/m/boot/loader`; subsequent
`insmod` requests are served from its `<TARGET>/` subdirectory. The
existing GUI and future OS boot functionality are intentionally dynamic.

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

Generated EFI executables, BIOS core images and module archives are **not**
evidence of successful firmware boot. The i386-pc stage targets legacy x86 BIOS,
not ARM64 BIOS or UEFI.
