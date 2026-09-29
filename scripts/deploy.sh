#!/bin/sh
# Update a running Pi over SSH instead of reflashing the SD card, then reboot
# it. Needs the debug image on the Pi (prod has no SSH). Your settings on the
# card (vhusb.txt, config.ini, authorized_keys, SSH host key) are kept.
#
#   ./build.sh debug && scripts/deploy.sh root@vhusb [debug|prod]
#
# Every file is uploaded next to the old one and only replaces it once its
# checksum on the Pi matches, so a failed upload leaves the card bootable.
# Deploying prod removes SSH: after that, updates need the SD card again.
# Extra ssh options go in SSH_OPTS, e.g. SSH_OPTS="-p 2222" for the QEMU test.

set -eu
TOP=$(cd "$(dirname "$0")/.." && pwd)
host=${1:?usage: $0 user@host [debug|prod]}
variant=${2:-debug}
boot=$TOP/out/$variant/boot
[ -f "$boot/initramfs.cpio.gz" ] || { echo "build it first: ./build.sh $variant" >&2; exit 1; }

# shellcheck disable=SC2086 # SSH_OPTS holds several options
ssh_() { ssh ${SSH_OPTS:-} -o BatchMode=yes -o ServerAliveInterval=5 -o ServerAliveCountMax=3 "$host" "$@"; }
files=$(cd "$boot" && find . -type f | sed 's|^\./||' | grep -v -x -e vhusb.txt -e config.ini)

ssh_ 'mount -o remount,rw /boot' </dev/null
trap 'ssh_ "rm -f /boot/*.new /boot/overlays/*.new; sync; mount -o remount,ro /boot" </dev/null || true' EXIT

# 1. Upload everything as *.new and verify it.
for f in $files; do
	sum=$(md5sum < "$boot/$f" | cut -d' ' -f1)
	printf '  %-32s' "$f"
	ssh_ "mkdir -p \"/boot/$(dirname "$f")\" && cat > \"/boot/$f.new\" && md5sum \"/boot/$f.new\"" \
		< "$boot/$f" | grep -q "^$sum " || { echo "upload failed, nothing replaced"; exit 1; }
	echo ok
done

# 2. All uploads verified: swap them in.
for f in $files; do printf 'mv "/boot/%s.new" "/boot/%s"\n' "$f" "$f"; done | ssh_ 'sh -e && sync'
trap - EXIT
ssh_ 'mount -o remount,ro /boot' </dev/null

echo "rebooting $host"
ssh_ 'reboot' </dev/null || true
