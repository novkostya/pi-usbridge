# pi-usbridge

A tiny, single-purpose SD card image that turns a **Raspberry Pi Zero 2 W** into a
network USB hub: whatever you plug into it shows up on your PC. It speaks
**USB/IP**, the open protocol built into Linux, with a small server of its
own; or, built with one option, runs the [VirtualHere](https://www.virtualhere.com)
server instead.

I use it to plug a DualSense controller into a Pi next to the TV and play on a
headless gaming VM through Moonlight. Because the whole USB device goes over the
network, everything works: adaptive triggers, haptics, touchpad, speaker and mic.

- **Open by default.** USB/IP with Linux's own `usbip-host` driver doing the
  work, a ~90 KB server, and [usbip-win2](https://github.com/vadimgrn/usbip-win2)
  on Windows (Microsoft-signed drivers, so no test mode, and anti-cheat is
  fine). Shares everything plugged in, like VirtualHere, except the Pi's own
  hub and network adapter. See [USB/IP](#usbip).
- **Runs from RAM.** The whole system is a ~250 KB initramfs. The SD card is only
  read at boot, so pulling the power is safe and the card doesn't wear out.
- **Boots fast.** About 9 seconds from power-on to serving (see
  [Boot time](#boot-time)).
- **Just works on any network.** Gets its address over DHCP and answers
  multicast DNS, so PCs find it as `usbridge.local` whatever the router
  (many routers' DNS also knows it as `usbridge`). Plugged straight into a PC
  without a router, it takes a link-local 169.254.x.x address like the PC
  does, and `usbridge.local` still works. Static IP is one line in a text
  file.
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
  The kernel and firmware are prebuilt. Compiled: BusyBox, a few small tools,
  Dropbear for debug, and one kernel module that carries a fix (see
  [The usbip-host fix](#the-usbip-host-fix)).

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
2. Flash `out/pi-usbridge-prod.img` to an SD card with Raspberry Pi Imager,
   balenaEtcher or `dd`.
3. Optional: edit `usbridge.txt` on the SD card's `USBRIDGE` partition: hostname,
   static IP, which PCs may connect, ... (see [Settings](#settings)).
4. Boot the Pi. When the green LED stops blinking and stays on, it has an IP
   address and the server is up.
5. On the Windows PC, run [windows/setup.ps1](windows/setup.ps1) once as
   administrator (see [Windows](#windows)). From then on, whatever you plug
   into the Pi shows up on the PC by itself.

For VirtualHere instead, see [VirtualHere](#virtualhere).

## Settings

`usbridge.txt` on the SD card:

```ini
hostname=usbridge          # sent to the DHCP server, so the router's DNS knows the Pi as "usbridge"
ip=dhcp                    # or a static address: 192.168.1.50/24 (/24 if left out)
gateway=192.168.1.1        # static only
dns=192.168.1.1            # static only
mac=                       # empty: adapter's own; "serial": stable MAC derived from the Pi's serial; or 02:12:34:56:78:9a
server=usbip               # or "virtualhere" (the default in VIRTUALHERE=1 builds)
allow=                     # usbip: PCs that may connect, e.g. "192.168.1.20 192.168.1.0/24"; empty: anyone
devices=                   # usbip: share only these vendor:product IDs, e.g. "054c:0ce6"; empty: everything
netwatch=60                # reboot if the gateway is (mostly) unreachable/slow this long (seconds, 0 = off)
```

For a reliable address, prefer DHCP with a static lease on your router over a
static IP in the image. The image keeps working when you move it to another
network, and there's no risk of an address conflict when the router's pool
changes.

## USB/IP

The Pi runs `usbipd` ([tools/usbipd.c](tools/usbipd.c)), which answers a
client's two questions, "what do you have?" and "give me that one", and then
hands the connection to Linux's `usbip-host` driver, which carries all the
USB traffic from then on. The server:

- shares every USB device plugged into the Pi, or only those in `devices=`,
  but never a hub or a network adapter, so no client can take the Pi's own
  network away;
- lets anyone who can reach it connect, like VirtualHere, or only the PCs in
  `allow=`. USB/IP has no passwords or encryption of its own, so that's an IP
  check; keep the Pi on a network you trust;
- serves the one shared device whatever bus ID a client asks for, so moving
  the controller to another USB port of the Pi doesn't break anything;
- drops a PC that goes away without saying so (VM powered off, cable pulled)
  within about 10 s, so the controller is free again.

It logs to the kernel log: `dmesg | grep usbipd` on the debug image.

### Windows

[windows/setup.ps1](windows/setup.ps1) installs usbip-win2 (pinned version,
checked against its checksum) and a startup task that attaches everything the
Pi shares. In PowerShell as administrator, in the folder with both scripts:

```powershell
powershell -ExecutionPolicy Bypass -File setup.ps1
```

It finds the Pi as `usbridge.local`; if you changed its hostname, or use an
address, add `-Server <name or address>`. usbip-win2 reattaches devices by
itself, but waits a fixed 30 s after every disconnect; the task
([usbip-attach.ps1](windows/usbip-attach.ps1)) attaches a device within ~2 s
of the Pi offering it instead. Measured with a DualSense: unplugged and
plugged back in, working again after 1.5–2 s; Pi rebooted, 12 s from the
reboot command. A device another PC is using is retried until it's free.

By hand (`usbip.exe` is in `C:\Program Files\USBip`): `usbip list -r
usbridge.local` shows what the Pi shares, and `usbip attach -r 192.168.1.50 -b
1-1.3` attaches a device. `attach` needs the address or a name your DNS
server knows (e.g. `usbridge.lan`): usbip-win2's driver looks names up with
plain DNS only, not `.local`. The task looks the name up itself for that
reason.

A `.local` lookup takes Windows ~2.7 s when it isn't cached: it waits for an
IPv6 address, which the Pi doesn't have, and ignores the Pi's answer saying
so. The task keeps the address once it has it.

usbip-win2's release drivers are signed by Microsoft, so they load with
Secure Boot on and without test mode, which games with anti-cheat
(EasyAntiCheat and others) refuse.

The task also attaches the controllers of a phone or tablet streaming from
this PC with [Moonlight USBridge](https://github.com/novkostya/moonlight-usbridge),
a Moonlight fork that forwards its USB controllers over USB/IP while it
streams. The fork advertises `_usbip._tcp` over mDNS, naming the PC it
streams from; the task asks for that service every 2 s and attaches from the
ones that name this PC.

### Linux

Linux has the client built in (`vhci-hcd` and the `usbip` tool, from your
distribution's `usbip` or `linux-tools` package):
`usbip attach -r usbridge.local -b 1-1.3` (`.local` names need nss-mdns,
which most desktop distributions have). Not tested with this server yet.

### The usbip-host fix

Out of the box, Linux's `usbip-host` can't serve a Zero 2 W to usbip-win2.
The protocol has clients send `number_of_packets = 0xffffffff` on ordinary
(non-isochronous) transfers; `usbip-host` passes that on to the USB driver;
and `dwc2`, the Pi's USB controller driver, sizes a buffer by it, so every
transfer fails with `-ENOMEM` and a kernel warning. Linux's own client sends 0
there, and most other USB controllers ignore the field, so this only shows up
on Pis with this controller (Zero, Zero 2, 3) serving usbip-win2.
[patches/linux/0001](patches/linux/0001-usbip-stub_rx-zero-number_of_packets-of-non-isochron.patch)
fixes it in `usbip-host`, in a form that could go upstream.

The second fix is for isochronous and interrupt endpoints: usbip-win2 sends
an endpoint's `bInterval` as the URB's interval, which for high-speed devices
is an exponent, and `usbip-host` took it as a number of microframes. A
DualSense's audio endpoint (haptics and speaker, 1 ms) was served every
0.5 ms, playing its haptics in bursts at double speed, which felt like plain
rumble. [patches/linux/0003](patches/linux/0003-usbip-stub_rx-take-the-interval-of-periodic-URBs-fro.patch)
takes the interval from the endpoint instead, as the kernel does for programs
using USB directly (and VirtualHere).

So this is the one kernel module the build compiles. `build.sh` builds it from
the prebuilt kernel's own source (`KERNEL_COMMIT`, the firmware's
`extra/git_hash`), its own config (extracted from its `configs.ko`) and its
symbol versions (`extra/Module8.symvers`), and stops unless the result has
the same vermagic and symbol CRCs as the stock module, so the running kernel
takes it like one of its own. The CRCs are computed from type definitions,
which include compiler-dependent attributes; [patches/linux/0002](patches/linux/0002-kconfig-compiler-features-of-gcc-11.4.patch)
makes the build see the features of gcc 11.4, which built the Pi's kernel.

`scripts/usbip-probe.py HOST --attach` sends exactly the kind of request that
broke; in QEMU (below) it fails with the stock module and passes with ours.

## VirtualHere

The Pi can run the [VirtualHere](https://www.virtualhere.com) server instead
of `usbipd`. VirtualHere's server is proprietary, so release images don't
include it; build your own:

```sh
VIRTUALHERE=1 ./build.sh   # -> out/pi-usbridge-virtualhere-{prod,debug}.img
```

That downloads `vhusbdarm64` from VirtualHere's site onto your machine, puts
it on the image and makes `server=virtualhere` the default. (Or, on any
image: copy [vhusbdarm64](https://www.virtualhere.com/sites/default/files/usbserver/vhusbdarm64)
onto the SD card and set `server=virtualhere` in `usbridge.txt`.) Clients find
the server by themselves (Bonjour), or add `usbridge:7575` by hand. The free
version shares one device at a time; a
[license](https://www.virtualhere.com/purchase) removes that limit.

Its settings live in `config.ini` on the card (see the
[VirtualHere docs](https://www.virtualhere.com/configuration_faq)); add a
license as `License=...` there or from the client. The default hides the
HAT's Ethernet adapter (`IgnoredDevices=bda/8152`) so a client can't take the
Pi's network away. When the server changes `config.ini` (license, device
nicknames, ...), the image copies it back to the SD card within a few
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

## Boot time

About 8.9 s from power-on to the server accepting connections (Zero 2 W +
PoE HAT, measured with `scripts/boottime.sh`; the same for usbipd and
vhusbd):

| Stage                                  | Time   |
| -------------------------------------- | ------ |
| GPU firmware loads the kernel          | 3.5 s  |
| kernel until `/init`                   | 1.5 s  |
| USB hub + RTL8152 enumerate            | 1.3 s  |
| Ethernet auto-negotiation (link up)    | 2.2 s  |
| DHCP lease                             | 0.2 s  |
| server reachable                       | <0.1 s |

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
- **No restart delay** before the first vhusbd start. usbipd starts before
  the network is up and is reachable the moment the Pi has an address.

The remaining time is mostly hardware: the GPU boot stage, USB enumeration
and Ethernet link negotiation.

## How it works

```
firmware (bootcode.bin, start_cd.elf)
  └─ kernel8.img + initramfs.cpio.gz (stock Raspberry Pi kernel, busybox userland)
       └─ /init = busybox init, reads /etc/inittab
            ├─ /etc/rc (once): mount, load drivers, read /boot/usbridge.txt, start DHCP
            ├─ /etc/init.d/usbipd          (server=usbip; restarted if it exits)
            ├─ /etc/init.d/mdnsd           (server=usbip: answers for usbridge.local)
            ├─ /etc/init.d/vhusbd          (server=virtualhere; restarted if it exits)
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
| `tools/usbipd.c`          | the USB/IP server                                      |
| `tools/mdnsd.c`           | answers mDNS queries for `<hostname>.local`            |
| `patches/linux/`          | the usbip-host fix, and the build-only kconfig patch   |
| `windows/`                | Windows client setup and the attach task               |
| `rootfs/common`, `rootfs/debug` | files copied into the initramfs                  |
| `boot/`                   | files copied onto the SD card                          |
| `scripts/deploy.sh`       | update a running Pi, with automatic rollback           |
| `scripts/boottime.sh`     | reboot a Pi and show where the boot time goes          |
| `scripts/loadtest.sh`     | drive USB and network like a game, PASS/FAIL           |
| `scripts/qemu-test.sh`    | boot an image in QEMU (`QEMU_TRIAL=1`: as a trial boot) |
| `scripts/usbip-probe.py`  | list a USB/IP server's devices, test one end to end    |

### Why not Buildroot?

Buildroot works fine for this, but it's a lot of machinery for a system this
small: thousands of options, a from-source kernel and toolchain, and 30+
minute builds. Here the kernel and firmware are the official prebuilt ones,
the same ones Raspberry Pi OS uses. So the hardware support is well tested,
and updating the kernel is a few lines in `versions.sh`. We compile BusyBox,
Dropbear and our small tools with a prebuilt musl toolchain, plus the one
patched kernel module, checked to fit the prebuilt kernel exactly.

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

- `VIRTUALHERE=1`: images that run VirtualHere's server (see [VirtualHere](#virtualhere)).
- `EXTRA_MODULES="cdc_ether ..."`: add more kernel modules to the initramfs.
  They must be listed in `config/firmware.sha256`.

### Testing in QEMU

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

### Load test

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

### Updating versions

- **Kernel/firmware**: set `FIRMWARE_TAG` and `KERNEL_VERSION` in `versions.sh`
  (see the [firmware tags](https://github.com/raspberrypi/firmware/tags);
  `extra/uname_string8` in the tag has the kernel version), and
  `KERNEL_COMMIT` (`extra/git_hash`) with the source tarball's checksum. Then
  regenerate `config/firmware.sha256` for the files listed there. The build
  checks that the usbip-host module still fits; if the patches stop
  applying, they need updating.
- **BusyBox, Dropbear, toolchain**: bump the version and checksum in `versions.sh`.

## Licensing

The scripts in this repository are MIT licensed. The images contain:

- Linux kernel and BusyBox (GPL-2.0), Dropbear (MIT), from the upstream
  sources pinned in `versions.sh`. The kernel is Raspberry Pi's prebuilt one;
  its `usbip-host` module is rebuilt with the patch in `patches/linux/`.
- Raspberry Pi firmware (`LICENCE.broadcom`, redistributable).
- With `VIRTUALHERE=1` only: the VirtualHere USB server, which is
  proprietary, downloaded from its site at build time. Release images never
  include it; see [VirtualHere](#virtualhere).

On Windows, [usbip-win2](https://github.com/vadimgrn/usbip-win2) (GPL-3.0) is
downloaded from its own releases by `windows/setup.ps1`.

This project isn't affiliated with VirtualHere, Raspberry Pi or Waveshare.
