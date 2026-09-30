# Development

## Building

Needs an x86_64 Linux host. On Debian/Ubuntu:

```sh
sudo apt install build-essential curl cpio bzip2 xz-utils dosfstools mtools fdisk \
  patch flex bison bc
./build.sh            # both variants -> out/pi-usbridge-{prod,debug}.img
```

No root needed: it works in an unprivileged container. Downloads are cached in
`dl/` and checked against the checksums in `versions.sh` and
`config/firmware.sha256`. The first build also downloads the kernel source
(260 MB) for the usbip-host module and needs ~1.5 GB for it in `build/`.

Builds are reproducible: building the same commit gives byte-identical
images, so anyone can check a release image against the source.
`VIRTUALHERE=1` images are the exception: VirtualHere publishes its server at
an unversioned URL.

Environment variables:

- `VIRTUALHERE=1`: images that run VirtualHere's server (see [virtualhere.md](virtualhere.md)).
- `EXTRA_MODULES="cdc_ether ..."`: add more kernel modules to the initramfs.
  They must be listed in `config/firmware.sha256`.

## Debug image

The debug image boots the same way and adds:

- **SSH** as root. Put your public key(s) in `authorized_keys` on the SD card.
  Without that file, root can log in with **no password**, so don't leave a
  keyless debug image on an untrusted network. The host key is generated on
  first boot and saved to the SD card.
- **Serial console** with a root shell on GPIO14 (TX) / GPIO15 (RX), 115200 8N1.
  Kernel messages are shown there too.
- **Logs**: `logread` (`-f` to follow) for DHCP, vhusbd and kernel messages,
  and `dmesg` (usbipd logs there).
- **Tools**: `ps`, `top`, `ping`, `nslookup`, `wget`, `netstat`, `nc`, `lsusb`,
  `vi`, `less`, ... and `get_throttled` (the firmware's under-voltage and
  throttling flags, like `vcgencmd get_throttled`).

Some useful commands:

```sh
dmesg | grep -E 'usbipd|usbip-host' # USB/IP: who attached what
logread | grep -E 'vhusbd|udhcpc'   # VirtualHere and DHCP events
lsusb                               # what's plugged in
ip addr; cat /etc/resolv.conf       # network state
dmesg | grep -i usb                 # USB enumeration problems
```

## Updating a running Pi

With the debug image, you can update the Pi over SSH instead of reflashing
the card:

```sh
./build.sh debug && scripts/deploy.sh root@usbridge
```

A broken update can't brick it:

1. The new version is uploaded to `/boot/next`, next to the current one.
   Only changed files cross the network, and everything is checksummed.
2. The Pi reboots into it once, using the firmware's one-shot `tryboot`
   flag (`tryboot.txt` is the new `config.txt` plus `os_prefix=next/`).
3. The new system checks itself: its USB server listening, an IP address, gateway
   answering. If it's healthy, it moves `/boot/next` into place and becomes
   permanent. If it isn't within 90 s, it reboots. If it crashes or hangs, the
   hardware watchdog or `panic=5` reboots it. Any reboot, or a power cut,
   brings back the previous version, and `deploy.sh` shows why the trial
   failed.

Your settings on the card (`usbridge.txt`, `config.ini`, `authorized_keys`, SSH
host key) are kept. `scripts/deploy.sh root@usbridge prod` switches to the prod
image the same way. Prod has no SSH, so after that, updates need the SD card
again.

## Testing in QEMU

QEMU's `raspi3b` machine has the same SoC family and the same `dwc2` USB
controller. The test swaps in an emulated USB network adapter for the HAT, and
shares an emulated USB keyboard over USB/IP:

```sh
sudo apt install qemu-system-arm device-tree-compiler
EXTRA_MODULES=cdc_ether ./build.sh debug
scripts/qemu-test.sh debug        # Ctrl-a x to quit
ssh -p 2222 root@localhost        # from another terminal
scripts/usbip-probe.py localhost --attach   # USB/IP end to end
```

`QEMU_TRIAL=1 scripts/qemu-test.sh debug` boots it as if it were the trial
boot of an update, to test `/etc/init.d/trial` (stage a version in
`/boot/next` of the image first).

## Load test

Before trusting a new kernel or firmware, drive the USB and network the way a
game does, with a DualSense plugged into a Pi running the debug image:

```sh
./build.sh loadtest && scripts/loadtest.sh root@usbridge 15
```

It sends output reports (rumble, triggers, lightbar) at 250 Hz and streams
4-channel audio, the stream the speaker and haptics run on, while pushing
TCP traffic into the Pi and pinging it, then prints PASS or FAIL with the
numbers. It stays silent: motors and trigger effects off, audio muted, but
the same USB traffic as a game. `storm` as a third argument drives the
controller over raw usbfs instead, cancelling pending transfers like vhusbd
does. The Pi is rebooted when the test ends or is interrupted.

On the Zero 2 W + PoE HAT, 15 minutes with `dwc2`: controller at its native
250 reports/s, audio at 48000 frames/s with no underruns, 7.2 MB/s in,
ping 1.4 ms average (3 ms worst). With `dwc_otg` the same load also ran
clean, but the controller only got 200 reports/s. This test hasn't
reproduced the game-triggered `dwc_otg` stall, so it can't prove a kernel
fixes that; it does catch regressions in everyday traffic.

## Updating versions

- **Kernel/firmware**: set `FIRMWARE_TAG` and `KERNEL_VERSION` in `versions.sh`
  (see the [firmware tags](https://github.com/raspberrypi/firmware/tags);
  `extra/uname_string8` in the tag has the kernel version), and
  `KERNEL_COMMIT` (`extra/git_hash`) with the source tarball's checksum. Then
  regenerate `config/firmware.sha256` for the files listed there. The build
  checks that the usbip-host module still fits; if the patches stop
  applying, they need updating.
- **BusyBox, Dropbear, toolchain**: bump the version and checksum in `versions.sh`.
