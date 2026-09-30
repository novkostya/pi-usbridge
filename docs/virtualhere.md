# VirtualHere

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
