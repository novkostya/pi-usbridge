#!/bin/sh
# Boot an image in QEMU's raspi3b machine (same SoC family as the Zero 2 W),
# with an emulated USB NIC standing in for the HAT's RTL8152, and a USB
# keyboard (0627:0001) to export over USB/IP. The initramfs must include
# cdc_ether:
#
#   EXTRA_MODULES=cdc_ether ./build.sh debug && scripts/qemu-test.sh debug
#
# scripts/usbip-probe.py localhost --attach tests USB/IP end to end with the
# keyboard (the emulated network adapter must not be listed).
# VIRTUALHERE=1: boot the VirtualHere image (VIRTUALHERE=1 ./build.sh debug).
#
# SSH: ssh -p 2222 root@localhost    USB/IP: localhost:3240
# vhusbd (server=virtualhere): localhost:7575    Quit: Ctrl-a x

set -eu
TOP=$(cd "$(dirname "$0")/.." && pwd)
. "$TOP/versions.sh"
variant=${1:-debug}
boot=$TOP/out/$variant/boot
fw=$TOP/dl/firmware-$FIRMWARE_TAG

dtb=boot/bcm2710-rpi-3-b.dtb
sum=$(awk -v p="$dtb" '$2 == p { print $1 }' "$TOP/config/firmware.sha256")
[ -f "$fw/$dtb" ] || curl -fL -o "$fw/$dtb" "https://raw.githubusercontent.com/raspberrypi/firmware/$FIRMWARE_TAG/$dtb"
echo "$sum  $fw/$dtb" | sha256sum -c --quiet -

# QEMU's USB controller model crashes the Pi's downstream dwc_otg driver, so
# switch the test DTB to the mainline dwc2 driver (as config.txt does on the
# real hardware with dtoverlay=dwc2).
test_dtb=$TOP/build/qemu.dtb
cp "$fw/$dtb" "$test_dtb"
fdtput -t s "$test_dtb" /soc/usb@7e980000 compatible brcm,bcm2835-usb
fdtput -t s "$test_dtb" /soc/usb@7e980000 dr_mode host
# QEMU's watchdog model resets as soon as it is armed.
fdtput -t s "$test_dtb" /soc/watchdog@7e100000 status disabled
# Free the PL011 UART from Bluetooth (the image uses disable-bt on the Zero).
fdtput -t s "$test_dtb" /soc/serial@7e201000/bluetooth status disabled
# The firmware normally fills in the board serial number; vhusbd needs it.
fdtput -t s "$test_dtb" / serial-number 00000000c0ffee42
# QEMU_TRIAL=1: pretend this is a trial boot of /boot/next (see
# /etc/init.d/trial); the firmware would set this from tryboot.txt.
[ "${QEMU_TRIAL:-}" = 1 ] && fdtput -t s "$test_dtb" /chosen os_prefix next/

# QEMU wants a copy of the SD image it can write to. There's no firmware to
# expand serial0; with Bluetooth enabled in the Pi 3 DTB the PL011 UART is
# ttyAMA1.
img=$TOP/build/qemu-$variant.img
name=pi-usbridge
[ "${VIRTUALHERE:-0}" = 1 ] && name=$name-virtualhere
cp "$TOP/out/$name-$variant.img" "$img"
cmdline=$(sed 's/serial0/ttyAMA1/' "$boot/cmdline.txt")
case $cmdline in *console=*) ;; *) cmdline="$cmdline console=ttyAMA1,115200" ;; esac

exec qemu-system-aarch64 -M raspi3b -nographic \
	-kernel "$boot/kernel8.img" -dtb "$test_dtb" -initrd "$boot/initramfs.cpio.gz" \
	-append "$cmdline earlycon=pl011,0x3f201000" \
	-drive file="$img",if=sd,format=raw \
	-usb -device usb-net,netdev=n0 -device usb-kbd \
	-netdev user,id=n0,hostfwd=tcp::2222-:22,hostfwd=tcp::7575-:7575,hostfwd=tcp::3240-:3240
