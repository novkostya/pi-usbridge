# pi-usbridge

SD card image that turns a Raspberry Pi Zero 2 W into a network USB hub:
plug a device into the Pi and it shows up on your PC over USB/IP.

I use it with a DualSense next to the TV and a headless gaming VM streamed
with Moonlight. The whole USB device is forwarded, so adaptive triggers,
haptics, touchpad, speaker and mic all work.

- USB/IP, using Linux's own `usbip-host` driver and a small server
  ([tools/usbipd.c](tools/usbipd.c)). On Windows, the client is
  [usbip-win2](https://github.com/vadimgrn/usbip-win2), whose drivers are
  Microsoft-signed, so no test mode and no trouble with anti-cheat.
- Runs entirely from RAM (~250 KB initramfs). The SD card is only read at
  boot, so pulling the power is safe.
- Boots in about 9 s. Found as `usbridge.local` via mDNS, over DHCP or
  link-local.
- Recovers by itself: hardware watchdog, reboot on network loss, and updates
  over SSH that roll back if the new version doesn't come up.
- Can run the [VirtualHere](https://www.virtualhere.com) server instead
  (build option).

## Hardware

- Raspberry Pi Zero 2 W
- Waveshare [PoE/ETH/USB HUB HAT](https://www.waveshare.com/wiki/PoE/ETH/USB_HUB_HAT)
  (RTL8152 Ethernet + 3-port hub)

Other Ethernet adapters should work if you add their driver
(`EXTRA_MODULES`, see [docs/development.md](docs/development.md)).

## Quick start

1. Build the image (`./build.sh prod`) or download one from Releases.
2. Flash `pi-usbridge-prod.img` to an SD card and boot the Pi. The green LED
   blinks while booting and stays on once it's serving.
3. On the Windows PC, as administrator, in the `windows` folder:

   ```powershell
   powershell -ExecutionPolicy Bypass -File setup.ps1
   ```

   This installs usbip-win2 and a startup task that attaches whatever the Pi
   shares. Use `-Server <name or IP>` if you changed the hostname.

From then on, devices plugged into the Pi appear on the PC within a couple of
seconds.

On Linux, use the built-in client: `usbip attach -r usbridge.local -b 1-1.3`
(untested so far).

## Settings

`usbridge.txt` on the SD card's `USBRIDGE` partition:

```ini
hostname=usbridge   # also sent to the DHCP server
ip=dhcp             # or a static address, e.g. 192.168.1.50/24
gateway=            # static only
dns=                # static only
mac=                # empty: the adapter's; "serial": derived from the Pi's serial; or an address
server=usbip        # or "virtualhere"
allow=              # PCs that may connect, e.g. "192.168.1.20 192.168.1.0/24"; empty: anyone
devices=            # share only these vendor:product IDs, e.g. "054c:0ce6"; empty: everything
netwatch=60         # reboot after this many seconds without the gateway (0: off)
```

USB/IP has no authentication or encryption. `allow=` is only an IP check, so
keep the Pi on a network you trust. Hubs and network adapters are never
shared.

## Debug image

`./build.sh debug` builds the same system with SSH, a serial console
(GPIO14/15, 115200), logs (`logread`, `dmesg`) and the usual tools. Put your
public key in `authorized_keys` on the SD card; without it, root logs in with
no password.

A running debug Pi can be updated without touching the card:

```sh
./build.sh debug && scripts/deploy.sh root@usbridge
```

The Pi boots the new version once and keeps it only if it comes up healthy.
Otherwise it reverts to the previous one.

## Documentation

- [docs/usbip.md](docs/usbip.md): the server, the Windows client, and the
  usbip-host patches
- [docs/virtualhere.md](docs/virtualhere.md): running VirtualHere instead
- [docs/internals.md](docs/internals.md): boot sequence, self-healing, boot
  time
- [docs/development.md](docs/development.md): building, updating, QEMU, load
  test

## Building

On an x86_64 Linux host (Debian/Ubuntu):

```sh
sudo apt install build-essential curl cpio bzip2 xz-utils dosfstools mtools fdisk \
  patch flex bison bc
./build.sh          # -> out/pi-usbridge-{prod,debug}.img
```

The kernel and firmware are Raspberry Pi's prebuilt ones. The build compiles
BusyBox, Dropbear, the small tools in `tools/`, and a patched `usbip-host`
module. It takes about a minute (plus a one-time 260 MB kernel source
download), needs no root, and is reproducible.

## License

MIT for this repository. The images contain the Linux kernel and BusyBox
(GPL-2.0), Dropbear (MIT) and the Raspberry Pi firmware
(`LICENCE.broadcom`). `windows/setup.ps1` downloads usbip-win2 (GPL-3.0)
from its releases. VirtualHere is proprietary and never included in release
images.

Not affiliated with VirtualHere, Raspberry Pi or Waveshare.
