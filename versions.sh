# shellcheck disable=SC2034 # sourced by build.sh
# Pinned inputs. Everything the build downloads is listed here (plus
# config/firmware.sha256) and verified by checksum, except vhusbd, which
# VirtualHere publishes at a fixed URL without versioning.

# Raspberry Pi firmware + prebuilt kernel (https://github.com/raspberrypi/firmware)
FIRMWARE_TAG=1.20260915
KERNEL_VERSION=6.18.50-v8+

# Prebuilt musl cross toolchain (https://toolchains.bootlin.com)
TOOLCHAIN=aarch64--musl--stable-2026.08-1
TOOLCHAIN_URL=https://toolchains.bootlin.com/downloads/releases/toolchains/aarch64/tarballs/$TOOLCHAIN.tar.xz
TOOLCHAIN_SHA256=b388c480a48e8e9f9b99e3d14e69219c4d61e5a2424a82faecb88a015b781a60
TOOLCHAIN_PREFIX=aarch64-buildroot-linux-musl-

BUSYBOX_VERSION=1.37.0
BUSYBOX_URL=https://busybox.net/downloads/busybox-$BUSYBOX_VERSION.tar.bz2
BUSYBOX_SHA256=3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4

# Debug image only
DROPBEAR_VERSION=2026.94
DROPBEAR_URL=https://matt.ucc.asn.au/dropbear/releases/dropbear-$DROPBEAR_VERSION.tar.bz2
DROPBEAR_SHA256=e098034a843699200c8c977a991fff73159735bf795d5f72ef672c41a6b1ae81

# VirtualHere USB server (closed source, see README "Licensing")
VHUSBD_URL=https://www.virtualhere.com/sites/default/files/usbserver/vhusbdarm64
