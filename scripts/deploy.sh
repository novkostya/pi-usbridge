#!/bin/sh
# Update a running Pi over SSH instead of reflashing the SD card, safely:
#
# 1. The new version goes into /boot/next, next to the current one. Files
#    the firmware loads with os_prefix (kernel, initramfs, cmdline.txt,
#    device tree, overlays) and config.txt always; other files only when
#    they changed. Unchanged files are copied on the Pi, not uploaded, and
#    everything is checksummed.
# 2. The Pi reboots into it once, using the firmware's one-shot tryboot flag
#    (tryboot.txt = the new config.txt + os_prefix=next/).
# 3. The new system makes itself permanent once it's healthy: its USB server
#    running, network up (see /etc/init.d/trial). If it isn't within 90s, or it
#    crashes or hangs, the next boot is the current version again.
#
#   ./build.sh debug && scripts/deploy.sh root@vhusb [debug|prod]
#
# The Pi must run the debug image (prod has no SSH). After deploying prod,
# updates need the SD card again. Your settings on the card (vhusb.txt,
# config.ini, authorized_keys, SSH host key) are kept.
# Extra ssh options go in SSH_OPTS, e.g. SSH_OPTS="-p 2222".

set -eu
TOP=$(cd "$(dirname "$0")/.." && pwd)
host=${1:?usage: $0 user@host [debug|prod]}
variant=${2:-debug}
boot=$TOP/out/$variant/boot
[ -f "$boot/initramfs.cpio.gz" ] || { echo "build it first: ./build.sh $variant" >&2; exit 1; }

# shellcheck disable=SC2086 # SSH_OPTS holds several options
ssh_() { ssh ${SSH_OPTS:-} -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 "$host" "$@"; }
port_open() { timeout 1 bash -c "echo > /dev/tcp/${host#*@}/$1" 2>/dev/null; }
die() { echo "error: $*" >&2; exit 1; }

files=$(cd "$boot" && find . -type f | sed 's|^\./||' | grep -v -x -e vhusb.txt -e config.ini | sort)
manifest=$(cd "$boot" && for f in $files; do md5sum "$f"; done)

# While /boot is writable, pause the Pi's only other writer during a deploy
# (persist-config) so it can't make /boot read-only under us.
pause='kill -STOP $(pidof persist-config) 2>/dev/null'
resume='sync; mount -o remount,ro /boot; kill -CONT $(pidof persist-config) 2>/dev/null; true'

echo "staging in /boot/next"
ssh_ "$pause; mount -o remount,rw /boot && rm -rf /boot/next /boot/tryboot.txt && mkdir -p /boot/next/overlays" </dev/null ||
	die "couldn't make /boot writable"
trap 'ssh_ "rm -rf /boot/next /boot/tryboot.txt; $resume" </dev/null || true' EXIT

# Copy what the card already has, list what needs uploading.
upload=$(echo "$manifest" | ssh_ 'while read -r sum f; do
	set -- $(md5sum "/boot/$f" 2>/dev/null)
	if [ "${1:-}" != "$sum" ]; then
		echo "$f"
	else
		case $f in
			kernel8.img|initramfs.cpio.gz|cmdline.txt|config.txt|*.dtb|overlays/*)
				cp "/boot/$f" "/boot/next/$f" ;;
		esac
	fi
done')
for f in $upload; do
	printf '  upload %s\n' "$f"
	ssh_ "cat > \"/boot/next/$f\"" < "$boot/$f"
done
# Every file as the trial will see it: from /boot/next if staged, else /boot.
staged=$(echo "$files" | ssh_ 'while read -r f; do
	p=/boot/$f; [ -e "/boot/next/$f" ] && p=/boot/next/$f
	set -- $(md5sum "$p" 2>/dev/null); echo "${1:-missing}  $f"
done')
[ "$staged" = "$manifest" ] || die "staged files don't match the build, nothing changed"

{ cat "$boot/config.txt"; printf '\n# Trial boot of /boot/next (scripts/deploy.sh)\nos_prefix=next/\n'; } |
	ssh_ "cat > /boot/tryboot.txt && $resume"
trap - EXIT

# Older images don't have reboot-arg; bring one along.
if ! ssh_ '[ -x /usr/sbin/reboot-arg ]' </dev/null; then
	helper=$TOP/build/rootfs-debug/usr/sbin/reboot-arg
	[ -x "$helper" ] || die "build the debug image first (for reboot-arg)"
	ssh_ 'cat > /tmp/reboot-arg && chmod 755 /tmp/reboot-arg' < "$helper"
fi
echo "rebooting into the new version (trial)"
ssh_ 'PATH=$PATH:/tmp; (sleep 1; reboot-arg "0 tryboot") >/dev/null 2>&1 &' </dev/null
i=0; while port_open 22 && [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); done

# Wait for the verdict. Healthy: the trial moves /boot/next into place.
# Failed: it reboots, and the previous (debug) version comes back.
result() {
	ssh_ '[ -e /boot/next ] || { echo permanent; exit; }
		[ "$(cat /proc/device-tree/chosen/os_prefix)" = next/ ] && echo trial || echo failed' </dev/null 2>/dev/null
}
i=0
while [ $i -lt 240 ]; do
	sleep 2; i=$((i + 2))
	port_open 22 || continue  # prod trial has no SSH: keep waiting for a fallback
	case $(result) in
		permanent) echo "done: the new version is running and permanent"; exit 0 ;;
		failed)
			echo "the trial failed, the previous version is running again:"
			ssh_ 'cat /boot/next/trial-failed.log 2>/dev/null' </dev/null > "$TOP/out/trial-failed.log" || true
			head -n 3 "$TOP/out/trial-failed.log"
			echo "(full log with dmesg: out/trial-failed.log)"
			ssh_ "$pause; mount -o remount,rw /boot && rm -rf /boot/next /boot/tryboot.txt; $resume" </dev/null || true
			exit 1 ;;
	esac
done
if [ "$variant" = prod ] && { port_open 3240 || port_open 7575; }; then
	echo "done: prod is running (no SSH to confirm; it didn't fall back)"
	exit 0
fi
die "no verdict after 4 minutes, check the Pi"
