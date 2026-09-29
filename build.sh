#!/bin/sh
# Build an SD card image. Usage: ./build.sh [prod|debug]...  (default: both)
# ./build.sh loadtest builds the kit for scripts/loadtest.sh instead.
#
# The kernel and firmware are the official prebuilt ones from
# raspberrypi/firmware. Compiled here: BusyBox, our small tools, Dropbear
# (debug), and one kernel module, usbip-host, to carry a fix (patches/linux/).
#
# Environment:
#   VIRTUALHERE=1  build images that run the VirtualHere server instead of
#                  USB/IP; downloads vhusbd from virtualhere.com (see README)
#   EXTRA_MODULES  more kernel modules for the initramfs, e.g. "cdc_ether" (QEMU test)
#   JOBS           parallel make jobs (default: nproc)

set -eu

TOP=$(cd "$(dirname "$0")" && pwd)
. "$TOP/versions.sh"
DL=$TOP/dl
BUILD=$TOP/build
OUT=$TOP/out
JOBS=${JOBS:-$(nproc)}
VIRTUALHERE=${VIRTUALHERE:-0}
EXTRA_MODULES=${EXTRA_MODULES:-}
FW=$DL/firmware-$FIRMWARE_TAG

# Reproducible builds: the same commit gives byte-identical images.
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$TOP" log -1 --format=%ct 2>/dev/null || echo 0)}
export SOURCE_DATE_EPOCH

msg() { printf '\033[1m>>> %s\033[0m\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

for t in curl tar bzip2 xz gzip cpio make gcc patch flex bison bc perl mkfs.vfat mcopy sfdisk; do
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
	echo "# SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH (build date in the banner)" >> "$frag"
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

# fingerprint KO: what the kernel checks before loading a module: its vermagic
# and the CRC of every symbol it uses (one line each).
fingerprint() {
	"$(cross)objcopy" -O binary --only-section=.modinfo "$1" "$1.modinfo"
	"$(cross)objcopy" -O binary --only-section=__versions "$1" "$1.versions"
	tr '\0' '\n' < "$1.modinfo" | grep '^vermagic='
	od -An -v -tx1 -w64 "$1.versions" | LC_ALL=C sort
	rm -f "$1.modinfo" "$1.versions"
}

# usbip_host: the one kernel module we build, usbip-host with patches/linux/,
# against the prebuilt kernel: its source, its config (from configs.ko) and its
# symbol versions. Fails unless the result has the stock module's vermagic and
# symbol CRCs, i.e. the running kernel will accept it.
usbip_host() {
	ko=$BUILD/usbip-host.ko
	stamp="$KERNEL_COMMIT $(cat "$TOP"/patches/linux/*.patch | sha256sum)"
	[ -f "$ko" ] && [ "$(cat "$ko.stamp" 2>/dev/null)" = "$stamp" ] && return
	msg "usbip-host module (patched)"
	mods=modules/$KERNEL_VERSION/kernel
	for f in extra/git_hash extra/Module8.symvers $mods/kernel/configs.ko.xz \
		$mods/drivers/usb/usbip/usbip-host.ko.xz; do
		firmware "$f"
	done
	[ "$(cat "$FW/extra/git_hash")" = "$KERNEL_COMMIT" ] ||
		die "KERNEL_COMMIT doesn't match the firmware's extra/git_hash"
	fetch "$KERNEL_SRC_URL" "$KERNEL_SRC_SHA256" "$DL/linux-$KERNEL_COMMIT.tar.gz"
	src=$BUILD/linux-$KERNEL_COMMIT
	rm -rf "$src" && mkdir -p "$src"
	tar -xzf "$DL/linux-$KERNEL_COMMIT.tar.gz" -C "$src" --strip-components=1
	for p in "$TOP"/patches/linux/*.patch; do patch -s -p1 -d "$src" < "$p"; done
	xz -dc "$FW/$mods/kernel/configs.ko.xz" > "$BUILD/configs.ko"
	"$src/scripts/extract-ikconfig" "$BUILD/configs.ko" > "$src/.config"
	"$src/scripts/config" --file "$src/.config" --disable GCC_PLUGINS
	cp "$FW/extra/Module8.symvers" "$src/Module.symvers"
	# LOCALVERSION=+: the "+" the Pi's kernel got from being built past a tag.
	kmake() { make -C "$src" -s ARCH=arm64 CROSS_COMPILE="$(cross)" LOCALVERSION=+ "$@"; }
	kmake olddefconfig
	kmake -j"$JOBS" modules_prepare
	release=$(cat "$src/include/config/kernel.release")
	[ "$release" = "$KERNEL_VERSION" ] || die "kernel release $release, expected $KERNEL_VERSION"
	kmake -j"$JOBS" M=drivers/usb/usbip modules
	"$(cross)strip" --strip-debug -o "$ko" "$src/drivers/usb/usbip/usbip-host.ko"

	stock=$BUILD/usbip-host.stock.ko
	xz -dc "$FW/$mods/drivers/usb/usbip/usbip-host.ko.xz" > "$stock"
	ours=$(fingerprint "$ko") theirs=$(fingerprint "$stock")
	case $ours in *vermagic=*) ;; *) die "usbip-host.ko: no vermagic" ;; esac
	[ "$ours" = "$theirs" ] || die "usbip-host.ko: vermagic or symbol CRCs differ from the stock module"
	echo "$stamp" > "$ko.stamp"
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
	server=usbip
	[ "$VIRTUALHERE" = 1 ] && server=virtualhere
	printf '# The USB server when usbridge.txt sets none (build.sh)\nSERVER_DEFAULT=%s\n' "$server" > "$root/etc/build.env"
	if [ "$variant" = debug ]; then
		cp -a "$TOP/rootfs/debug/." "$root/"
		cp "$BUILD/dropbear-$DROPBEAR_VERSION/dropbearmulti" "$root/usr/sbin/"
		"$(cross)gcc" -static -Os -s -o "$root/usr/bin/get_throttled" "$TOP/tools/get_throttled.c"
		"$(cross)gcc" -static -Os -s -o "$root/usr/sbin/reboot-arg" "$TOP/tools/reboot-arg.c"
		for p in dropbear dropbearkey scp; do ln -s dropbearmulti "$root/usr/sbin/$p"; done
	fi
	"$(cross)gcc" -static -Os -s -Wall -o "$root/usr/sbin/usbipd" "$TOP/tools/usbipd.c"
	# r8152: the HAT's Ethernet. raspberrypi-hwmon: logs "Undervoltage detected!".
	# usbip-core, and usbip-host built with our fix (usbip_host above): USB/IP.
	# usbmon (debug): USB traffic capture, /sys/kernel/debug/usb/usbmon.
	modules="r8152 raspberrypi-hwmon usbip-core"
	[ "$variant" = debug ] && modules="$modules usbmon"
	for m in $modules $EXTRA_MODULES; do
		ko=$(awk -v m="/$m.ko.xz" 'index($2, m) { print $2 }' "$TOP/config/firmware.sha256")
		[ -n "$ko" ] || die "module $m is not listed in config/firmware.sha256"
		firmware "$ko"
		xz -dc "$FW/$ko" > "$root/lib/modules/$m.ko"
	done
	cp "$BUILD/usbip-host.ko" "$root/lib/modules/usbip-host.ko"

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
	name=pi-usbridge
	[ "$VIRTUALHERE" = 1 ] && name=$name-virtualhere
	img=$OUT/$name-$variant.img
	msg "image ($variant)"

	for f in bootcode.bin start_cd.elf fixup_cd.dat \
		bcm2710-rpi-zero-2-w.dtb overlays/overlay_map.dtb \
		overlays/disable-bt.dtbo overlays/disable-wifi.dtbo overlays/dwc2.dtbo \
		LICENCE.broadcom COPYING.linux; do
		firmware "boot/$f"
		mkdir -p "$(dirname "$boot/$f")"
		cp "$FW/boot/$f" "$boot/$f"
	done
	# The kernel ships gzipped; store it uncompressed. The GPU firmware reads
	# the bigger file faster than it can decompress the small one (-1.7s).
	firmware boot/kernel8.img
	gzip -dc "$FW/boot/kernel8.img" > "$boot/kernel8.img"
	cp "$TOP/boot/config.txt" "$TOP/boot/usbridge.txt" "$boot/"
	if [ "$variant" = debug ]; then
		cat "$TOP/boot/config-debug.txt" >> "$boot/config.txt"
		cp "$TOP/boot/cmdline-debug.txt" "$boot/cmdline.txt"
	else
		cp "$TOP/boot/cmdline.txt" "$boot/cmdline.txt"
	fi
	if [ "$VIRTUALHERE" = 1 ]; then
		cp "$TOP/boot/config.ini" "$boot/"
		cp "$DL/vhusbdarm64" "$boot/vhusbdarm64"
	fi

	# 128 MiB image: MBR + one FAT partition starting at 1 MiB. Room for
	# scripts/deploy.sh to upload a second copy of the 29 MiB kernel.
	size_mb=128
	rm -f "$img" "$img.vfat"
	mkfs.vfat --invariant -C -n USBRIDGE "$img.vfat" $(( (size_mb - 1) * 1024 )) >/dev/null
	# One by one in a fixed order and with fixed times: reproducible layout.
	find "$boot" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
	(cd "$boot" && find . -mindepth 1 -type d | LC_ALL=C sort) | while read -r d; do
		mmd -i "$img.vfat" "::/${d#./}"
	done
	(cd "$boot" && find . -type f | LC_ALL=C sort) | while read -r f; do
		mcopy -m -i "$img.vfat" "$boot/${f#./}" "::/${f#./}"
	done
	truncate -s ${size_mb}M "$img"
	printf 'label: dos\nlabel-id: 0x55534252\nstart=2048, type=c, bootable\n' | sfdisk -q "$img"
	dd if="$img.vfat" of="$img" bs=1M seek=1 conv=notrunc status=none
	rm "$img.vfat"
	echo "    $img"
}

# Kit for scripts/loadtest.sh: load generators and the modules they need.
loadtest() {
	kit=$OUT/loadtest
	msg "load-test kit"
	rm -rf "$kit" && mkdir -p "$kit/mods"
	for t in dsload hapload urbstorm; do
		"$(cross)gcc" -static -O2 -s -Wall -o "$kit/$t" "$TOP/tools/loadtest/$t.c" -lm -lpthread
	done
	grep -v '^#' "$TOP/tools/loadtest/modules" | tr ' ' '\n' | grep . > "$kit/modules"
	while read -r m; do
		ko=$(awk -v m="/$m.ko.xz" 'index($2, m) { print $2 }' "$TOP/config/firmware.sha256")
		[ -n "$ko" ] || die "module $m is not listed in config/firmware.sha256"
		firmware "$ko"
		xz -dc "$FW/$ko" > "$kit/mods/$m.ko"
	done < "$kit/modules"
}

if [ "${1:-}" = loadtest ]; then
	toolchain
	loadtest
	exit 0
fi

variants=${*:-prod debug}
for v in $variants; do
	case $v in prod|debug) ;; *) die "unknown variant '$v' (prod, debug or loadtest)" ;; esac
done

toolchain
usbip_host
[ "$VIRTUALHERE" = 1 ] && vhusbd
for v in $variants; do
	busybox "$v"
	[ "$v" = debug ] && dropbear
	rm -rf "${OUT:?}/$v" && mkdir -p "$OUT/$v/boot"
	initramfs "$v"
	image "$v"
done
