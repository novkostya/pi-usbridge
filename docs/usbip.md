# USB/IP

The Pi runs `usbipd` ([tools/usbipd.c](../tools/usbipd.c)), which answers a
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

## Windows

[windows/setup.ps1](../windows/setup.ps1) installs usbip-win2 (pinned version,
checked against its checksum) and a startup task that attaches everything the
Pi shares. In PowerShell as administrator, in the folder with both scripts:

```powershell
powershell -ExecutionPolicy Bypass -File setup.ps1
```

It finds the Pi as `usbridge.local`; if you changed its hostname, or use an
address, add `-Server <name or address>`. usbip-win2 reattaches devices by
itself, but waits a fixed 30 s after every disconnect; the task
([usbip-attach.ps1](../windows/usbip-attach.ps1)) attaches a device within ~2 s
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
this PC with Moonlight USBridge,
a Moonlight fork that forwards its USB controllers over USB/IP while it
streams. The fork advertises `_usbip._tcp` over mDNS, naming the PC it
streams from; the task asks for that service every 2 s and attaches from the
ones that name this PC.

## Linux

Linux has the client built in (`vhci-hcd` and the `usbip` tool, from your
distribution's `usbip` or `linux-tools` package):
`usbip attach -r usbridge.local -b 1-1.3` (`.local` names need nss-mdns,
which most desktop distributions have). Not tested with this server yet.

## The usbip-host patches

Out of the box, Linux's `usbip-host` can't serve a Zero 2 W to usbip-win2.
The protocol has clients send `number_of_packets = 0xffffffff` on ordinary
(non-isochronous) transfers; `usbip-host` passes that on to the USB driver;
and `dwc2`, the Pi's USB controller driver, sizes a buffer by it, so every
transfer fails with `-ENOMEM` and a kernel warning. Linux's own client sends 0
there, and most other USB controllers ignore the field, so this only shows up
on Pis with this controller (Zero, Zero 2, 3) serving usbip-win2.
[patches/linux/0001](../patches/linux/0001-usbip-stub_rx-zero-number_of_packets-of-non-isochron.patch)
fixes it in `usbip-host`, in a form that could go upstream.

The second fix is for isochronous and interrupt endpoints: usbip-win2 sends
an endpoint's `bInterval` as the URB's interval, which for high-speed devices
is an exponent, and `usbip-host` took it as a number of microframes. A
DualSense's audio endpoint (haptics and speaker, 1 ms) was served every
0.5 ms, playing its haptics in bursts at double speed, which felt like plain
rumble. [patches/linux/0003](../patches/linux/0003-usbip-stub_rx-take-the-interval-of-periodic-URBs-fro.patch)
takes the interval from the endpoint instead, as the kernel does for programs
using USB directly (and VirtualHere).

So this is the one kernel module the build compiles. `build.sh` builds it from
the prebuilt kernel's own source (`KERNEL_COMMIT`, the firmware's
`extra/git_hash`), its own config (extracted from its `configs.ko`) and its
symbol versions (`extra/Module8.symvers`), and stops unless the result has
the same vermagic and symbol CRCs as the stock module, so the running kernel
takes it like one of its own. The CRCs are computed from type definitions,
which include compiler-dependent attributes; [patches/linux/0002](../patches/linux/0002-kconfig-compiler-features-of-gcc-11.4.patch)
makes the build see the features of gcc 11.4, which built the Pi's kernel.

`scripts/usbip-probe.py HOST --attach` sends exactly the kind of request that
broke; in QEMU ([development.md](development.md#testing-in-qemu)) it fails
with the stock module and passes with ours.
