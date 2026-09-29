#!/bin/bash
# Reboot a Pi running the debug image and show where the boot time goes.
#
#   scripts/boottime.sh root@vhusb [runs]
#
# "total" runs from the Pi dropping off the network (reset) until vhusbd
# accepts connections on port 7575. Kernel milestones come from dmesg,
# including the "vhusb:" marks written by the boot scripts; whatever is left
# before the kernel's first timestamp is the GPU firmware loading it.

set -eu
host=${1:?usage: $0 user@host [runs]}
runs=${2:-1}
addr=${host#*@}
ssh_() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "$@" </dev/null; }
now() { date +%s.%N; }
port_open() { timeout 0.3 bash -c "echo > /dev/tcp/$addr/$1" 2>/dev/null; }

for run in $(seq "$runs"); do
	# Retry the reboot if the Pi is still up after 15s.
	while :; do
		ssh_ reboot >/dev/null 2>&1 || true
		for i in $(seq 300); do
			ping -c1 -W0.2 "$addr" >/dev/null 2>&1 || break 2
			sleep 0.05
		done
	done
	down=$(now)
	until port_open 7575; do sleep 0.05; done
	up=$(now)
	until port_open 22; do sleep 0.2; done
	sleep 1

	ssh_ 'dmesg' | awk -v total="$(echo "$up - $down" | bc)" '
		function t(line) { match(line, /\[ *[0-9.]+\]/); return substr(line, RSTART + 1, RLENGTH - 2) + 0 }
		/Run \/init/            { init = t($0) }
		/ eth0: v[0-9]/         { eth = t($0) }
		/carrier on/ && !link   { link = t($0) }
		/vhusb: dhcp bound/     { lease = t($0) }
		/vhusb: starting vhusbd/ { vh = t($0) }
		END {
			printf "total %.2fs = firmware %.2fs + kernel %.2fs\n", total, total - vh, vh
			printf "  kernel start -> /init      %6.2fs\n", init
			printf "  /init -> eth0 registered   %6.2fs\n", eth - init
			printf "  eth0 -> link up            %6.2fs\n", link - eth
			printf "  link up -> DHCP lease      %6.2fs\n", lease - link
			printf "  DHCP lease -> vhusbd       %6.2fs\n", vh - lease
		}'
done
