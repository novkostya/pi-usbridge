#!/bin/sh
# Build an SD card image. Usage: ./build.sh [prod|debug]...  (default: both)
#
# Nothing is compiled except BusyBox (and Dropbear for debug): the kernel and
# firmware are the official prebuilt ones from raspberrypi/firmware.
#
# Environment:
#   VHUSBD=0       don't download vhusbd into the image (see README "Licensing")
#   EXTRA_MODULES  more kernel modules for the initramfs, e.g. "cdc_ether" (QEMU test)
#   JOBS           parallel make jobs (default: nproc)

set -eu

TOP=$(cd "$(dirname "$0")" && pwd)
. "$TOP/versions.sh"
DL=$TOP/dl
BUILD=$TOP/build
OUT=$TOP/out
JOBS=${JOBS:-$(nproc)}
VHUSBD=${VHUSBD:-1}
EXTRA_MODULES=${EXTRA_MODULES:-}
FW=$DL/firmware-$FIRMWARE_TAG

msg() { printf '\033[1m>>> %s\033[0m\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

for t in curl tar bzip2 xz gzip cpio make gcc mkfs.vfat mcopy sfdisk; do
	command -v $t >/dev/null || die "missing host tool: $t (see README)"
done

# fetch URL SHA256 [DEST]: download once into dl/, verify checksum.
fetch() {
	dest=${3:-$DL/$(basename "$1")}
	if [ ! -f "$dest" ]; then
		mkdir -p "$(dirname "$dest")"
		curl -fL --retry 3 -o "$dest.part" "$1"
		mv "$dest.part" "$dest"
	fi
	echo "$2  $dest" | sha256sum -c --quiet - || { rm -f "$dest"; die "checksum mismatch: $1"; }
}

# firmware PATH: fetch a file from raspberrypi/firmware, checksum from config/firmware.sha256.
firmware() {
	sum=$(awk -v p="$1" '$2 == p { print $1 }' "$TOP/config/firmware.sha256")
	[ -n "$sum" ] || die "$1 is not listed in config/firmware.sha256"
	fetch "https://raw.githubusercontent.com/raspberrypi/firmware/$FIRMWARE_TAG/$1" "$sum" "$FW/$1"
}

toolchain() {
	[ -x "$BUILD/$TOOLCHAIN/bin/${TOOLCHAIN_PREFIX}gcc" ] && return
	msg "toolchain $TOOLCHAIN"
	fetch "$TOOLCHAIN_URL" "$TOOLCHAIN_SHA256"
	mkdir -p "$BUILD"
	tar -xJf "$DL/$TOOLCHAIN.tar.xz" -C "$BUILD"
	(cd "$BUILD/$TOOLCHAIN" && ./relocate-sdk.sh >/dev/null)
}
cross() { echo "$BUILD/$TOOLCHAIN/bin/$TOOLCHAIN_PREFIX"; }

# busybox VARIANT: build a static busybox from config/busybox-*.config.
busybox() {
	src=$BUILD/busybox-$BUSYBOX_VERSION-$1
	frag=$BUILD/busybox-$1.fragment
	cat "$TOP/config/busybox-prod.config" > "$frag"
	[ "$1" = debug ] && cat "$TOP/config/busybox-debug.config" >> "$frag"
	if [ -x "$src/busybox" ] && cmp -s "$frag" "$src/.fragment"; then return; fi

	msg "busybox $BUSYBOX_VERSION ($1)"
	fetch "$BUSYBOX_URL" "$BUSYBOX_SHA256"
	rm -rf "$src" && mkdir -p "$src"
	tar -xjf "$DL/busybox-$BUSYBOX_VERSION.tar.bz2" -C "$src" --strip-components=1
	make -C "$src" -s allnoconfig >/dev/null
	# Replace allnoconfig's "# CONFIG_FOO is not set" with our lines.
	awk -F'[ =]' 'NR == FNR { if (/^CONFIG_/) set[$1] = 1; next }
		!(($1 in set) || ($2 in set))' "$frag" "$src/.config" > "$src/.config.new"
	cat "$src/.config.new" "$frag" > "$src/.config"
	yes '' | make -C "$src" -s oldconfig >/dev/null
	# kconfig silently drops options with unmet dependencies; catch that.
	grep '^CONFIG_' "$frag" | while read -r opt; do
		grep -qxF "$opt" "$src/.config" || die "busybox: '$opt' was not applied"
	done
	make -C "$src" -s -j"$JOBS" CROSS_COMPILE="$(cross)" busybox
	cp "$frag" "$src/.fragment"
}

dropbear() {
	src=$BUILD/dropbear-$DROPBEAR_VERSION
	[ -x "$src/dropbearmulti" ] && return
	msg "dropbear $DROPBEAR_VERSION"
	fetch "$DROPBEAR_URL" "$DROPBEAR_SHA256"
	rm -rf "$src" && mkdir -p "$src"
	tar -xjf "$DL/dropbear-$DROPBEAR_VERSION.tar.bz2" -C "$src" --strip-components=1
	(
		cd "$src"
		./configure -q --host=aarch64-buildroot-linux-musl CC="$(cross)gcc" \
			--enable-static --disable-zlib --disable-lastlog --disable-utmp \
			--disable-utmpx --disable-wtmp --disable-wtmpx --disable-pututline \
			--disable-pututxline
		make -s -j"$JOBS" PROGRAMS="dropbear dropbearkey scp" MULTI=1 STATIC=1
		"$(cross)strip" dropbearmulti
	)
}

vhusbd() {
	[ -f "$DL/vhusbdarm64" ] && return
	msg "vhusbd (from virtualhere.com)"
	curl -fL --retry 3 -o "$DL/vhusbdarm64.part" "$VHUSBD_URL"
	mv "$DL/vhusbdarm64.part" "$DL/vhusbdarm64"
}

# cpio_node NAME MODE MAJOR MINOR: a newc archive with one device node, so
# /dev/console exists before devtmpfs is mounted, without needing root.
cpio_node() {
	name=$1; namesize=$((${#1} + 1))
	printf '070701%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X' \
		1 "$2" 0 0 1 0 0 0 0 "$3" "$4" $namesize 0
	printf '%s\0' "$name"
	pad=$(( (4 - (110 + namesize) % 4) % 4 )); head -c $pad /dev/zero
	printf '070701%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X' \
		0 0 0 0 1 0 0 0 0 0 0 11 0
	printf 'TRAILER!!!\0'; head -c 3 /dev/zero
}

initramfs() {
	variant=$1
	root=$BUILD/rootfs-$variant
	msg "initramfs ($variant)"
	rm -rf "$root"
	mkdir -p "$root"
	(cd "$root" && mkdir -p -m 1777 tmp && mkdir -p bin sbin usr/bin usr/sbin dev proc sys run tmp boot root \
		etc/vhusbd lib/modules var/log && ln -s ../run var/run)
	make -C "$BUILD/busybox-$BUSYBOX_VERSION-$variant" -s CROSS_COMPILE="$(cross)" \
		CONFIG_PREFIX="$root" install >/dev/null
	ln -s bin/busybox "$root/init"
	cp -a "$TOP/rootfs/common/." "$root/"
	if [ "$variant" = debug ]; then
		cp -a "$TOP/rootfs/debug/." "$root/"
		cp "$BUILD/dropbear-$DROPBEAR_VERSION/dropbearmulti" "$root/usr/sbin/"
		"$(cross)gcc" -static -Os -s -o "$root/usr/bin/get_throttled" "$TOP/tools/get_throttled.c"
		for p in dropbear dropbearkey scp; do ln -s dropbearmulti "$root/usr/sbin/$p"; done
	fi
	# r8152: the HAT's Ethernet. raspberrypi-hwmon: logs "Undervoltage detected!".
	# usbmon (debug): USB traffic capture, /sys/kernel/debug/usb/usbmon.
	modules="r8152 raspberrypi-hwmon"
	[ "$variant" = debug ] && modules="$modules usbmon"
	for m in $modules $EXTRA_MODULES; do
		ko=$(awk -v m="/$m.ko.xz" 'index($2, m) { print $2 }' "$TOP/config/firmware.sha256")
		[ -n "$ko" ] || die "module $m is not listed in config/firmware.sha256"
		firmware "$ko"
		xz -dc "$FW/$ko" > "$root/lib/modules/$m.ko"
	done

	# Deterministic archive: fixed timestamps and ownership.
	find "$root" -exec touch -h -d @0 {} +
	{
		(cd "$root" && find . | LC_ALL=C sort | cpio -o -H newc -R 0:0 --reproducible --quiet)
		cpio_node dev/console $((0020600)) 5 1
	} | gzip -9n > "$OUT/$variant/boot/initramfs.cpio.gz"
}

image() {
	variant=$1
	boot=$OUT/$variant/boot
	img=$OUT/vhusb-zero-$variant.img
	msg "image ($variant)"

	for f in bootcode.bin start_cd.elf fixup_cd.dat kernel8.img \
		bcm2710-rpi-zero-2-w.dtb overlays/overlay_map.dtb \
		overlays/disable-bt.dtbo overlays/disable-wifi.dtbo overlays/dwc2.dtbo \
		LICENCE.broadcom COPYING.linux; do
		firmware "boot/$f"
		mkdir -p "$(dirname "$boot/$f")"
		cp "$FW/boot/$f" "$boot/$f"
	done
	cp "$TOP/boot/config.txt" "$TOP/boot/vhusb.txt" "$TOP/boot/config.ini" "$boot/"
	if [ "$variant" = debug ]; then
		cat "$TOP/boot/config-debug.txt" >> "$boot/config.txt"
		cp "$TOP/boot/cmdline-debug.txt" "$boot/cmdline.txt"
	else
		cp "$TOP/boot/cmdline.txt" "$boot/cmdline.txt"
	fi
	[ "$VHUSBD" = 1 ] && cp "$DL/vhusbdarm64" "$boot/vhusbdarm64"

	# 64 MiB image: MBR + one FAT partition starting at 1 MiB.
	size_mb=64
	rm -f "$img" "$img.vfat"
	mkfs.vfat -C -n VHUSB "$img.vfat" $(( (size_mb - 1) * 1024 )) >/dev/null
	mcopy -s -i "$img.vfat" "$boot"/* ::/
	truncate -s ${size_mb}M "$img"
	echo 'start=2048, type=c, bootable' | sfdisk -q "$img"
	dd if="$img.vfat" of="$img" bs=1M seek=1 conv=notrunc status=none
	rm "$img.vfat"
	echo "    $img"
}

variants=${*:-prod debug}
for v in $variants; do
	case $v in prod|debug) ;; *) die "unknown variant '$v' (prod or debug)" ;; esac
done

toolchain
[ "$VHUSBD" = 1 ] && vhusbd
for v in $variants; do
	busybox "$v"
	[ "$v" = debug ] && dropbear
	rm -rf "$OUT/$v" && mkdir -p "$OUT/$v/boot"
	initramfs "$v"
	image "$v"
done
