#!/bin/sh

#EFI/BOOT/bootarch.efi
#EFI/BOOT/bootx64.efi
#EFI/BOOT/bootia32.efi
#EFI/BOOT/bootia64.efi
#EFI/BOOT/bootarm.efi
#EFI/Microsoft/Boot/bootmgfw.efi

#	loadenv biosdisk part_msdos part_gpt fat ntfs ext2 ntfscomp iso9660 loopback search linux boot minicmd cat cpuid chain halt help ls reboot \
#	echo test configfile gzio normal sleep memdisk tar font gfxterm gettext true vbe vga video_bochs video_cirrus



BOOTLOADER_FILENAME="loader"
PREFIX_BIOS_DIR="/m/boot/loader"
PREFIX_EFI_DIR="/m/boot/loader"

#BOOT_PART_LABEL="BOOT"
#BOOT_PART_UUID="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
BOOT_PART_FILE="/m/boot/loader/id_$(date +%Y-%m-%d_%H-%M-%S_%N)_$RANDOM"
#BOOT_PART_PATH="(hd0,1)"

BOOTLOADER_FILE="$DIST_DIR/$BOOTLOADER_FILENAME"
BOOTSTRAP_FILE="$SOURCE_DIR/bootstrap"
MEMDISK_FILE="$BUILD_DIR/memdisk"
ROOTCONF_FILENAME="root.conf"
GRUB_DIR="$(dirname "$(which grub-mkimage)")"

GRUB_MODULES_BIOS="$(cat "$SOURCE_DIR/grub-modules-bios.cfg" | tr '\n' ' ')"
GRUB_MODULES_EFI="$(cat "$SOURCE_DIR/grub-modules-efi.cfg" | tr '\n' ' ')"

[ -n "$BOOT_PART_LABEL" ] && echo "search --no-floppy --label --set root \"$BOOT_PART_LABEL\"" > "$BUILD_DIR/$ROOTCONF_FILENAME"
[ -n "$BOOT_PART_UUID" ] && echo "search --no-floppy --fs-uuid --set root \"$BOOT_PART_UUID\"" > "$BUILD_DIR/$ROOTCONF_FILENAME"
[ -n "$BOOT_PART_FILE" ] && echo "search --no-floppy --file --set root \"$BOOT_PART_FILE\"" > "$BUILD_DIR/$ROOTCONF_FILENAME"
[ -n "$BOOT_PART_PATH" ] && echo "set root=\"$BOOT_PART_PATH\"" > "$BUILD_DIR/$ROOTCONF_FILENAME"

(
cd "$SOURCE_DIR/script"
tar cf "$MEMDISK_FILE"-bios-x86.tar *
tar cf "$MEMDISK_FILE"-efi-x86.tar *
tar cf "$MEMDISK_FILE"-efi-x86_64.tar *
if [ -f "$BUILD_DIR/$ROOTCONF_FILENAME" ]
then
  cd "$BUILD_DIR"
  tar rf "$MEMDISK_FILE"-bios-x86.tar "$ROOTCONF_FILENAME"
  tar rf "$MEMDISK_FILE"-efi-x86.tar "$ROOTCONF_FILENAME"
  tar rf "$MEMDISK_FILE"-efi-x86_64.tar "$ROOTCONF_FILENAME"
fi
cd "$SOURCE_DIR"
tar rf "$MEMDISK_FILE"-efi-x86.tar "theme"
tar rf "$MEMDISK_FILE"-efi-x86_64.tar "theme"
cd "$GRUB_DIR"
tar rf "$MEMDISK_FILE"-efi-x86.tar "i386-efi"
tar rf "$MEMDISK_FILE"-efi-x86_64.tar "x86_64-efi"
)

#BOOT_DIR="$DIST_DIR/direct"
BOOT_DIR="$DIST_DIR"

mkdir -p "$BOOT_DIR"

cp -R -f "$GRUB_DIR/i386-pc" "$BOOT_DIR"
cp -R -f "$GRUB_DIR/i386-efi" "$BOOT_DIR"
cp -R -f "$GRUB_DIR/x86_64-efi" "$BOOT_DIR"

cp -R -f "$SOURCE_DIR/theme" "$BOOT_DIR"
cp -R -f "$SOURCE_DIR/environment" "$BOOT_DIR"
#cp -R -f "$SOURCE_DIR/script"/* "$BOOT_DIR"
#[ -f "$BUILD_DIR/$ROOTCONF_FILENAME" ] && cp -R -f "$BUILD_DIR/$ROOTCONF_FILENAME" "$BOOT_DIR"

touch "$BOOT_DIR/${BOOT_PART_FILE##*/}"

if [ "$SYS_OS_TYPE" = "windows" ]
then
  BOOTLOADER_FILE="$(cygpath -w "$BOOTLOADER_FILE")"
  BOOTSTRAP_FILE="$(cygpath -w "$BOOTSTRAP_FILE")"
  MEMDISK_FILE="$(cygpath -w "$MEMDISK_FILE")"
fi

#grub-mkimage $GRUB_OPTIONS -O i386-pc -c "$BOOTSTRAP_FILE"-direct-bios.sh -p "$PREFIX_BIOS_DIR" -o "$BOOTLOADER_FILE"-direct-x86.bios $GRUB_MODULES_BIOS
#grub-mkimage $GRUB_OPTIONS -O i386-efi -c "$BOOTSTRAP_FILE"-direct-efi.sh -p "$PREFIX_EFI_DIR" -o "$BOOTLOADER_FILE"-direct-x86.efi $GRUB_MODULES_EFI
#grub-mkimage $GRUB_OPTIONS -O x86_64-efi -c "$BOOTSTRAP_FILE"-direct-efi.sh -p "$PREFIX_EFI_DIR" -o "$BOOTLOADER_FILE"-direct-x86_64.efi $GRUB_MODULES_EFI
#
#cat "$GRUB_DIR/i386-pc/lnxboot.img" "$BOOTLOADER_FILE"-direct-x86.bios > "$BOOTLOADER_FILE"-direct-x86.bios.img
#
#sed -i -b "s/Welcome to GRUB!/\x00               /g" "$BOOTLOADER_FILE"-direct-x86.efi
#sed -i -b "s/Welcome to GRUB!/\x00               /g" "$BOOTLOADER_FILE"-direct-x86_64.efi

grub-mkimage $GRUB_OPTIONS -O i386-pc -c "$BOOTSTRAP_FILE"-memdisk.sh -m "$MEMDISK_FILE"-bios-x86.tar -p "$PREFIX_BIOS_DIR" -o "$BOOTLOADER_FILE"-x86.bios $GRUB_MODULES_BIOS
grub-mkimage $GRUB_OPTIONS -O i386-efi -c "$BOOTSTRAP_FILE"-memdisk.sh -m "$MEMDISK_FILE"-efi-x86.tar -p "$PREFIX_EFI_DIR" -o "$BOOTLOADER_FILE"-x86.efi $GRUB_MODULES_EFI
grub-mkimage $GRUB_OPTIONS -O x86_64-efi -c "$BOOTSTRAP_FILE"-memdisk.sh -m "$MEMDISK_FILE"-efi-x86_64.tar -p "$PREFIX_EFI_DIR" -o "$BOOTLOADER_FILE"-x86_64.efi $GRUB_MODULES_EFI

cat "$GRUB_DIR/i386-pc/lnxboot.img" "$BOOTLOADER_FILE"-x86.bios > "$BOOTLOADER_FILE"-x86.bios.img

sed -i -b "s/Welcome to GRUB!/\x00               /g" "$BOOTLOADER_FILE"-x86.efi
sed -i -b "s/Welcome to GRUB!/\x00               /g" "$BOOTLOADER_FILE"-x86_64.efi

#sed -b "s/Welcome to GRUB!/\x00               /g" "$BOOTLOADER_FILE"-direct-x86.efi > "$BOOTLOADER_FILE"-direct-quiet-x86.efi
#sed -b "s/Welcome to GRUB!/\x00               /g" "$BOOTLOADER_FILE"-direct-x86_64.efi > "$BOOTLOADER_FILE"-direct-quiet-x86_64.efi
#
#sed -b "s/Welcome to GRUB!/\x00               /g" "$BOOTLOADER_FILE"-x86.efi > "$BOOTLOADER_FILE"-quiet-x86.efi
#sed -b "s/Welcome to GRUB!/\x00               /g" "$BOOTLOADER_FILE"-x86_64.efi > "$BOOTLOADER_FILE"-quiet-x86_64.efi
