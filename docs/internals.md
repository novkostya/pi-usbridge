# Internals

## Boot sequence

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

## Why not Buildroot?

Buildroot works fine for this, but it's a lot of machinery for a system this
small: thousands of options, a from-source kernel and toolchain, and 30+
minute builds. Here the kernel and firmware are the official prebuilt ones,
the same ones Raspberry Pi OS uses. So the hardware support is well tested,
and updating the kernel is a few lines in `versions.sh`. We compile BusyBox,
Dropbear and our small tools with a prebuilt musl toolchain, plus the one
patched kernel module, checked to fit the prebuilt kernel exactly.

## USB and CPU

The image uses the mainline `dwc2` USB driver instead of the Pi's default
`dwc_otg`. With `dwc_otg`, a game driving the DualSense's triggers and
haptics stalled the whole USB bus, Ethernet included; `dwc2` also polls the
controller at its native 250 Hz, where `dwc_otg` managed 200 Hz.

The CPU is pinned at full speed and USB autosuspend is off, for latency. That
costs about 4 °C at idle (56 °C vs 52 °C with on-demand scaling, in the PoE
HAT).

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
