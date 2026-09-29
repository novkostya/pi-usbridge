# vhusb-zero

A tiny, single-purpose SD card image that turns a **Raspberry Pi Zero 2 W** into a
[VirtualHere](https://www.virtualhere.com) USB server: a network USB hub.

I use it to plug a DualSense controller into a Pi next to the TV and play on a
headless gaming VM through Moonlight. Because the whole USB device goes over the
network, everything works: adaptive triggers, haptics, touchpad, speaker and mic.

- **Runs from RAM.** The whole system is a ~250 KB initramfs. The SD card is only
  read at boot, so pulling the power is safe and the card doesn't wear out.
- **Boots fast.** About 9 seconds from power-on to serving (see
  [Boot time](#boot-time)).
- **Just works on any network.** Gets its address over DHCP and sends its
  hostname, so your router's DNS knows it as `vhusb`. Plugged straight into a
  PC without a router, it takes a link-local 169.254.x.x address like the PC
  does. Static IP is one line in a text file.
- **Built for low latency.** CPU pinned at full speed, USB autosuspend off.
  That costs about 4 °C at idle (56 °C vs 52 °C with on-demand scaling, in
  the PoE HAT).
- **Stable under load.** Uses the mainline `dwc2` USB driver: with the Pi's
  default `dwc_otg`, a game driving the DualSense's triggers and haptics
  stalled the whole USB bus, Ethernet included. `dwc2` also polls the
  controller at its native 250 Hz, where `dwc_otg` managed 200 Hz.
- **Two variants from the same source.** `prod` has only what's needed. `debug`
  adds SSH, a serial console, logs and troubleshooting tools.
- **Heals itself, updates safely.** Hardware watchdog, reboot on network
  loss, and remote updates that roll back if the new version doesn't come up.
- **Easy to read.** One shell script builds everything in about a minute.
  The kernel and firmware are prebuilt; only BusyBox (plus Dropbear and two
  small tools for debug) is compiled.

## Hardware

- Raspberry Pi Zero 2 W
- Waveshare [PoE/ETH/USB HUB HAT](https://www.waveshare.com/wiki/PoE/ETH/USB_HUB_HAT)
  (RTL8152B 100 Mbit Ethernet + 3-port USB hub, powered over Ethernet)

Other Ethernet setups should work too: the image uses whichever network
interface appears first. Only the RTL8152 driver is included, though (add more
with `EXTRA_MODULES`, see [Building](#building)).

## Quick start

1. Build (or download from Releases, see [Licensing](#licensing)):
   ```sh
   ./build.sh prod        # or: ./build.sh debug, or ./build.sh for both
   ```
2. Flash `out/vhusb-zero-prod.img` to an SD card with Raspberry Pi Imager,
   balenaEtcher or `dd`.
3. Optional: edit files on the SD card's `VHUSB` partition:
   - `vhusb.txt`: hostname, static IP, MAC address (see [Settings](#settings))
   - `config.ini`: VirtualHere server settings. Add your license here as
     `License=...`, or enter it from the VirtualHere client (it gets saved).
   - `vhusbdarm64`: the VirtualHere server binary. It's already there unless
     you built with `VHUSBD=0` or used a release image. In that case,
     download [vhusbdarm64](https://www.virtualhere.com/sites/default/files/usbserver/vhusbdarm64)
     and copy it here.
4. Boot the Pi. When the green LED stops blinking and stays on, it has an IP
   address and the server is up. It shows up in the VirtualHere client
   automatically (Bonjour), or you can add `vhusb:7575` by hand.

## Settings

`vhusb.txt` on the SD card:

```ini
hostname=vhusb             # sent to the DHCP server; shown in the VirtualHere client
ip=dhcp                    # or a static address: 192.168.1.50/24 (/24 if left out)
gateway=192.168.1.1        # static only
dns=192.168.1.1            # static only
mac=                       # empty: adapter's own; "serial": stable MAC derived from the Pi's serial; or 02:12:34:56:78:9a
netwatch=60                # reboot if the gateway is (mostly) unreachable/slow this long (seconds, 0 = off)
```

For a reliable address, prefer DHCP with a static lease on your router over a
static IP in the image. The image keeps working when you move it to another
network, and there's no risk of an address conflict when the router's pool
changes.

VirtualHere's own settings live in `config.ini` (see the
[VirtualHere docs](https://www.virtualhere.com/configuration_faq)). The default
one hides the HAT's Ethernet adapter (`IgnoredDevices=bda/8152`) so a client
can't take the Pi's network away. When the server changes `config.ini` (license,
device nicknames, ...), the image copies it back to the SD card within a few
seconds. Apart from updates, that's the only time the card is written to.

## Self-healing

An appliance nobody logs into should recover by itself. Each of these was
tested on the hardware:

| Failure                                         | Recovery                         | Serving again |
| ----------------------------------------------- | -------------------------------- | ------------- |
| Network dead or very slow (gateway ARP >200 ms) | reboot after ~1 min (`netwatch`) | ~70 s         |
| System hangs                                    | hardware watchdog, 15 s          | ~25 s         |
| Kernel panic                                    | reboot after 5 s (`panic=5`)     | ~14 s         |

`netwatch` checks the gateway every 5 s and reboots when 3 out of 4 checks
in the last minute failed, so a stall where the odd reply still gets through
counts too, and a few slow replies on a healthy network don't. It only acts
while the cable is connected and a gateway is known, so a Pi plugged straight
into a laptop without a router is left alone.

## Status LED

| Green ACT LED | Meaning                                  |
| ------------- | ---------------------------------------- |
| blinking      | booting, or waiting for a DHCP lease     |
| solid         | has an IP address, server is up          |

## Debug image

The debug image boots the same way and adds:

- **SSH** as root. Put your public key(s) in `authorized_keys` on the SD card.
  Without that file, root can log in with **no password**, so don't leave a
  keyless debug image on an untrusted network. The host key is generated on
  first boot and saved to the SD card.
- **Serial console** with a root shell on GPIO14 (TX) / GPIO15 (RX), 115200 8N1.
  Kernel messages are shown there too.
- **Logs**: `logread` (`-f` to follow) for vhusbd, DHCP and kernel messages, plus `dmesg`.
- **Tools**: `ps`, `top`, `ping`, `nslookup`, `wget`, `netstat`, `nc`, `lsusb`,
  `vi`, `less`, ... and `get_throttled` (the firmware's under-voltage and
  throttling flags, like `vcgencmd get_throttled`).

Some useful commands:

```sh
logread | grep -E 'vhusbd|udhcpc'   # server and DHCP events
lsusb                               # what's plugged in
ip addr; cat /etc/resolv.conf       # network state
dmesg | grep -i usb                 # USB enumeration problems
```

## Updating a running Pi

With the debug image, you can update the Pi over SSH instead of reflashing
the card:

```sh
./build.sh debug && scripts/deploy.sh root@vhusb
```

A broken update can't brick it:

1. The new version is uploaded to `/boot/next`, next to the current one.
   Only changed files cross the network, and everything is checksummed.
2. The Pi reboots into it once, using the firmware's one-shot `tryboot`
   flag (`tryboot.txt` is the new `config.txt` plus `os_prefix=next/`).
3. The new system checks itself: vhusbd listening, an IP address, gateway
   answering. If it's healthy, it moves `/boot/next` into place and becomes
   permanent. If it isn't within 90 s, it reboots. If it crashes or hangs, the
   hardware watchdog or `panic=5` reboots it. Any reboot, or a power cut,
   brings back the previous version, and `deploy.sh` shows why the trial
   failed.

Your settings on the card (`vhusb.txt`, `config.ini`, `authorized_keys`, SSH
host key) are kept. `scripts/deploy.sh root@vhusb prod` switches to the prod
image the same way. Prod has no SSH, so after that, updates need the SD card
again.

## Boot time

About 8.9 s from power-on to vhusbd accepting connections (Zero 2 W +
PoE HAT, measured with `scripts/boottime.sh`):

| Stage                                  | Time   |
| -------------------------------------- | ------ |
| GPU firmware loads the kernel          | 3.5 s  |
| kernel until `/init`                   | 1.5 s  |
| USB hub + RTL8152 enumerate            | 1.3 s  |
| Ethernet auto-negotiation (link up)    | 2.2 s  |
| DHCP lease                             | 0.2 s  |
| vhusbd starts                          | <0.1 s |

What got it there (from ~17.5 s):

- **Uncompressed kernel.** The GPU firmware reads the 29 MB kernel faster
  than it decompresses the 10 MB gzipped one: -1.7 s.
- **`initcall_blacklist=init_kprobe_trace,init_blk_tracer`.** At boot the
  kernel updates all trace events in the background (~1.4 s on this CPU);
  these two tracers waited for it and held up everything after them,
  including USB. Neither is needed here: -0.8 s to `/init`, -1.4 s to Ethernet.
- **Keep the DHCP lease.** Releasing it at shutdown made dnsmasq treat the
  Pi as a new client every boot and ping the address for ~3 s before
  answering. udhcpc also starts the moment the link comes up.
- **No restart delay** before the first vhusbd start.

The remaining time is mostly hardware: the GPU boot stage, USB enumeration
and Ethernet link negotiation.

## How it works

```
firmware (bootcode.bin, start_cd.elf)
  └─ kernel8.img + initramfs.cpio.gz (stock Raspberry Pi kernel, busybox userland)
       └─ /init = busybox init, reads /etc/inittab
            ├─ /etc/rc (once): mount, load drivers, read /boot/vhusb.txt, start DHCP
            ├─ /etc/init.d/vhusbd          (restarted if it exits)
            ├─ /etc/init.d/persist-config  (saves config.ini changes to the SD card)
            ├─ /etc/init.d/watchdog        (hardware watchdog, reboots on hang)
            ├─ /etc/init.d/netwatch        (reboots if the gateway stops answering)
            └─ /etc/init.d/trial           (after an update: keep it if healthy, else roll back)
```

| Path                      | What                                                   |
| ------------------------- | ------------------------------------------------------ |
| `build.sh`                | the whole build                                        |
| `versions.sh`             | pinned versions and checksums of everything downloaded |
| `config/firmware.sha256`  | checksums of the firmware/kernel files used            |
| `config/busybox-*.config` | exactly which BusyBox applets each variant gets        |
| `rootfs/common`, `rootfs/debug` | files copied into the initramfs                  |
| `boot/`                   | files copied onto the SD card                          |
| `scripts/deploy.sh`       | update a running Pi, with automatic rollback           |
| `scripts/boottime.sh`     | reboot a Pi and show where the boot time goes          |
| `scripts/loadtest.sh`     | drive USB and network like a game, PASS/FAIL           |
| `scripts/qemu-test.sh`    | boot an image in QEMU (`QEMU_TRIAL=1`: as a trial boot) |

### Why not Buildroot?

Buildroot works fine for this, but it's a lot of machinery for a system this
small: thousands of options, a from-source kernel and toolchain, and 30+
minute builds. Here the kernel and firmware are the official prebuilt ones,
the same ones Raspberry Pi OS uses. So the hardware support is well tested,
and updating the kernel is a one-line change in `versions.sh`. The only things
we compile are BusyBox and Dropbear, with a prebuilt musl toolchain.

## Building

Needs an x86_64 Linux host. On Debian/Ubuntu:

```sh
sudo apt install build-essential curl cpio bzip2 xz-utils dosfstools mtools fdisk
./build.sh            # both variants -> out/vhusb-zero-{prod,debug}.img
```

No root needed: it works in an unprivileged container. Downloads are cached in
`dl/` and checked against the checksums in `versions.sh` and
`config/firmware.sha256`.

Builds are reproducible: building the same commit gives byte-identical
images, so anyone can check a release image against the source. Images that
include vhusbd are the exception: VirtualHere publishes it at an unversioned
URL.

Environment variables:

- `VHUSBD=0`: don't put the VirtualHere binary on the image.
- `EXTRA_MODULES="cdc_ether ..."`: add more kernel modules to the initramfs.
  They must be listed in `config/firmware.sha256`.

### Testing in QEMU

QEMU's `raspi3b` machine has the same SoC family. The test swaps in an emulated
USB network adapter for the HAT:

```sh
sudo apt install qemu-system-arm device-tree-compiler
EXTRA_MODULES=cdc_ether ./build.sh debug
scripts/qemu-test.sh debug        # Ctrl-a x to quit
ssh -p 2222 root@localhost        # from another terminal
```

`QEMU_TRIAL=1 scripts/qemu-test.sh debug` boots it as if it were the trial
boot of an update, to test `/etc/init.d/trial` (stage a version in
`/boot/next` of the image first).

### Load test

Before trusting a new kernel or firmware, drive the USB and network the way a
game does, with a DualSense plugged into a Pi running the debug image:

```sh
./build.sh loadtest && scripts/loadtest.sh root@vhusb 15
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

### Updating versions

- **Kernel/firmware**: set `FIRMWARE_TAG` and `KERNEL_VERSION` in `versions.sh`
  (see the [firmware tags](https://github.com/raspberrypi/firmware/tags);
  `extra/uname_string8` in the tag has the kernel version). Then regenerate
  `config/firmware.sha256` for the files listed there.
- **BusyBox, Dropbear, toolchain**: bump the version and checksum in `versions.sh`.

## Licensing

The scripts in this repository are MIT licensed. The images contain:

- Linux kernel and BusyBox (GPL-2.0), Dropbear (MIT). Built from unmodified
  upstream sources pinned in `versions.sh`.
- Raspberry Pi firmware (`LICENCE.broadcom`, redistributable).
- The VirtualHere USB server, which is proprietary. Release images are built
  with `VHUSBD=0` and don't include it, so you copy `vhusbdarm64` onto the SD
  card yourself. The free version shares one device at a time; a
  [license](https://www.virtualhere.com/purchase) removes that limit.

This project isn't affiliated with VirtualHere, Raspberry Pi or Waveshare.
