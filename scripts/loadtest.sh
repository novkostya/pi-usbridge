#!/bin/bash
# Load a Pi's USB and network like a game streaming to a DualSense does, and
# report whether it held up. Use it to check kernel/firmware updates.
#
#   ./build.sh loadtest && scripts/loadtest.sh root@usbridge [minutes] [storm]
#
# Needs the debug image on the Pi and a DualSense plugged into it. It stays
# silent: the reports turn the motors and trigger effects off and the audio
# is silence; the USB traffic is the same as a game's. For the duration, the
# USB server (usbipd or vhusbd) is stopped and the controller taken back from
# any client (nothing is saved to the SD card). The Pi is rebooted when the
# test ends or is interrupted, which restores everything. On the Pi:
#  - dsload: output reports (rumble, triggers, lightbar) at 250 Hz via hidraw,
#    counting the controller's input reports. With "storm": urbstorm instead,
#    the same over raw usbfs, cancelling pending transfers like vhusbd does.
#  - hapload: 4-channel 48 kHz audio, the stream the DualSense's speaker and
#    haptics run on.
# From here: a TCP stream into the Pi (~6 MB/s, half the link, so pings
# measure the Pi rather than a full link's queue), and a ping every 200 ms.

set -eu
TOP=$(cd "$(dirname "$0")/.." && pwd)
host=${1:?usage: $0 user@host [minutes] [storm]}
minutes=${2:-10}
mode=${3:-}
addr=${host#*@}
kit=$TOP/out/loadtest
log=$TOP/out/loadtest-$(date +%Y%m%d-%H%M%S)
[ -x "$kit/dsload" ] || { echo "build the kit first: ./build.sh loadtest" >&2; exit 1; }
ssh_() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "$@"; }

ssh_ 'lsusb | grep -q -E " 054c:(0ce6|0df2) "' </dev/null ||
	{ echo "no DualSense plugged into the Pi" >&2; exit 1; }

# From here on, whatever happens: stop the local load and reboot the Pi.
pinger='' sender='' pi_touched=''
# shellcheck disable=SC2317 # called from the EXIT trap
cleanup() {
	[ -n "$sender" ] && { pkill -P "$sender" 2>/dev/null; kill "$sender" 2>/dev/null; }
	[ -n "$pinger" ] && kill "$pinger" 2>/dev/null
	if [ -n "$pi_touched" ]; then
		echo "rebooting the Pi to restore it"
		ssh_ reboot </dev/null || true
	fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "uploading the kit"
ssh_ 'mkdir -p /tmp/lt/mods' </dev/null
for f in dsload hapload urbstorm modules $(cd "$kit" && echo mods/*.ko); do
	ssh_ "cat > /tmp/lt/$f" < "$kit/$f"
done

echo "starting the load"
pi_touched=1
ssh_ "sh -s $mode" <<'EOF'
cd /tmp/lt && chmod +x dsload hapload urbstorm
# Keep clients away from the controller: stop the USB server (init restarts
# its script, which then idles) and take the controller back from usbip-host.
echo none > /run/server
killall usbipd vhusbd 2>/dev/null
# Like "usbip unbind"; usbip-host's files take the bus ID without a newline.
h=/sys/bus/usb/drivers/usbip-host
for d in "$h"/[0-9]*; do
	[ -e "$d" ] || continue
	b=${d##*/}
	printf %s "$b" > "$h/unbind"
	printf 'del %s' "$b" > "$h/match_busid"
	printf %s "$b" > "$h/rebind"
done
for m in $(cat modules); do insmod "mods/$m.ko" 2>/dev/null; done
i=0; while { [ ! -e /dev/hidraw0 ] || [ ! -e /dev/snd/pcmC0D0p ]; } && [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); done
[ -e /dev/hidraw0 ] && [ -e /dev/snd/pcmC0D0p ] || { echo "no DualSense found"; exit 1; }
dev=$(lsusb | while read -r _ bus _ dev id _; do [ "$id" = 054c:0ce6 ] && echo "/dev/bus/usb/$bus/${dev%:}"; done)
if [ "${1:-}" = storm ]; then
	(./urbstorm "$dev" 20 > hid.log 2>&1 &)
else
	(./dsload /dev/hidraw0 250 > hid.log 2>&1 &)
fi
(./hapload > audio.log 2>&1 &)
(while :; do nc -l -p 5001 > /dev/null 2>&1 || sleep 1; done </dev/null >/dev/null 2>&1 &)
dmesg | wc -l > dmesg.start
sleep 3
echo "  controller: $(tail -n 1 hid.log)"
echo "  audio:      $(tail -n 1 audio.log)"
EOF

ping -D -O -i 0.2 -W 2 "$addr" > "$log.ping" 2>&1 &
pinger=$!
( while :; do
	timeout 60 bash -c "exec 3>/dev/tcp/$addr/5001; while head -c 60000 /dev/zero >&3; do sleep 0.01; done" 2>/dev/null || sleep 1
done ) &
sender=$!

echo "running for $minutes minutes (samples in $log)"
end=$(( $(date +%s) + minutes * 60 ))
while [ "$(date +%s)" -lt "$end" ]; do
	sleep 10
	sample=$(ssh_ 'cd /tmp/lt; set -- $(tail -n 1 hid.log); hid="$2 $3"; set -- $(tail -n 1 audio.log); echo "$hid $2 $3 $(cat /sys/class/net/eth0/statistics/rx_bytes) $(cat /sys/class/thermal/thermal_zone0/temp)"' </dev/null 2>/dev/null) || sample="unreachable"
	echo "$(date +%s) $sample" >> "$log"
	printf '\r  %s  %s' "$(date +%T)" "$sample"
done
echo
pkill -P "$sender" 2>/dev/null; kill "$pinger" "$sender" 2>/dev/null; pinger='' sender=''
ssh_ 'dmesg | tail -n +$(( $(cat /tmp/lt/dmesg.start) + 1 ))' </dev/null > "$log.dmesg" 2>/dev/null || true
# vhusbd asks the root hub for a BOS descriptor it doesn't have: harmless.
grep -i -E "error|fail|stall|disconnect|timeout" "$log.dmesg" |
	grep -v "USBDEVFS_CONTROL failed cmd vhusbd rqt 128 rq 6" > "$log.errors" || true
new_errors=$(wc -l < "$log.errors")

# Verdict. Lines: time in=N out=N frames=N xruns=N rx_bytes temp
awk -v errs="$new_errors" -v pinglog="$log.ping" '
	$2 == "unreachable" { unreachable++; next }
	{
		split($2, a, "="); in_rate = a[2] + 0
		split($4, b, "="); fr = b[2] + 0
		split($5, c, "="); xr += c[2]
		n++; if (n == 1 || in_rate < min_in) min_in = in_rate
		if (n == 1 || fr < min_fr) min_fr = fr
		if (n == 1) rx0 = $6; rx1 = $6; if ($7 > temp) temp = $7
	}
	END {
		while ((getline l < pinglog) > 0) {
			if (l ~ /no answer/) lost++
			else if (split(l, p, "time=") == 2) { t = p[2] + 0; sum += t; np++; if (t > worst) worst = t }
		}
		printf "controller input: min %d/s   audio: min %d frames/s, %d underruns\n", min_in, min_fr, xr
		printf "network in: %.1f MB/s   ping: avg %.1f ms, worst %.0f ms, %d lost\n", (rx1 - rx0) / ((n - 1) * 10) / 1e6, sum / np, worst, lost
		printf "max temperature: %.1f C   new kernel errors: %s   unreachable samples: %d\n", temp / 1000, errs, unreachable
		ok = min_in >= 190 && min_fr >= 47000 && xr == 0 && lost == 0 && worst < 50 && unreachable == 0 && errs == 0
		print ok ? "PASS" : "FAIL"
	}' "$log"

[ -s "$log.errors" ] && { echo "new kernel errors:"; head -n 20 "$log.errors"; }
exit 0  # the EXIT trap reboots the Pi
