#!/bin/sh
# Update a running Pi over SSH instead of reflashing the SD card, then reboot
# it. Needs the debug image on the Pi (prod has no SSH). Your settings on the
# card (vhusb.txt, config.ini, authorized_keys, SSH host key) are kept.
#
#   ./build.sh debug && scripts/deploy.sh root@vhusb [debug|prod]
#
# Deploying prod removes SSH: after that, updates need the SD card again.
# Extra ssh options go in SSH_OPTS, e.g. SSH_OPTS="-p 2222" for the QEMU test.

set -eu
TOP=$(cd "$(dirname "$0")/.." && pwd)
host=${1:?usage: $0 user@host [debug|prod]}
variant=${2:-debug}
boot=$TOP/out/$variant/boot
[ -f "$boot/initramfs.cpio.gz" ] || { echo "build it first: ./build.sh $variant" >&2; exit 1; }

ctl=$(mktemp -u)
ssh_() { ssh ${SSH_OPTS:-} -o ControlMaster=auto -o ControlPath="$ctl" -o ControlPersist=60 "$host" "$@"; }
trap 'ssh ${SSH_OPTS:-} -o ControlPath="$ctl" -O exit "$host" 2>/dev/null || true' EXIT

ssh_ 'mount -o remount,rw /boot' </dev/null
(cd "$boot" && find . -type f | sed 's|^\./||') | while read -r f; do
	case $f in vhusb.txt|config.ini) continue ;; esac  # user-editable
	echo "  $f"
	ssh_ "mkdir -p \"/boot/$(dirname "$f")\" && cat > \"/boot/$f.new\" && mv \"/boot/$f.new\" \"/boot/$f\"" < "$boot/$f"
done
ssh_ 'sync; mount -o remount,ro /boot' </dev/null

echo "rebooting $host"
ssh_ 'reboot || kill -TERM 1' </dev/null || true
