#!/usr/bin/env python3
"""List a USB/IP server's devices; with --attach, import one and read its
device descriptor the way usbip-win2 asks for it (number_of_packets
0xffffffff on a control transfer), then let it go again.

    scripts/usbip-probe.py HOST [--port 3240] [--attach [BUSID]]

--attach takes the device away from whichever client is using it for a
moment only if the server allows that (usbipd refuses while it's in use).
Reading a descriptor doesn't make a controller do anything.
"""
import argparse
import socket
import struct
import sys

VERSION = 0x0111
OP_REQ_DEVLIST, OP_REP_DEVLIST = 0x8005, 0x0005
OP_REQ_IMPORT, OP_REP_IMPORT = 0x8003, 0x0003
CMD_SUBMIT, RET_SUBMIT = 1, 3
SPEEDS = ["unknown", "low", "full", "high", "wireless", "super", "super+"]


def recv_all(s, n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise EOFError("server closed the connection")
        buf += chunk
    return buf


def device(s):
    d = recv_all(s, 312)
    path, busid = d[:256].split(b"\0")[0].decode(), d[256:288].split(b"\0")[0].decode()
    busnum, devnum, speed, vid, pid, bcd = struct.unpack(">IIIHHH", d[288:306])
    cls, sub, proto, cfg, ncfg, nif = d[306:312]
    return dict(path=path, busid=busid, busnum=busnum, devnum=devnum,
                speed=SPEEDS[speed] if speed < len(SPEEDS) else speed,
                id=f"{vid:04x}:{pid:04x}", nif=nif)


def devlist(host, port):
    with socket.create_connection((host, port), timeout=5) as s:
        s.sendall(struct.pack(">HHI", VERSION, OP_REQ_DEVLIST, 0))
        _, code, status = struct.unpack(">HHI", recv_all(s, 8))
        if code != OP_REP_DEVLIST or status:
            sys.exit(f"devlist failed: code {code:#x} status {status}")
        (n,) = struct.unpack(">I", recv_all(s, 4))
        devs = []
        for _ in range(n):
            d = device(s)
            d["interfaces"] = [recv_all(s, 4)[:3].hex() for _ in range(d["nif"])]
            devs.append(d)
        return devs


def attach(host, port, busid):
    with socket.create_connection((host, port), timeout=5) as s:
        s.sendall(struct.pack(">HHI", VERSION, OP_REQ_IMPORT, 0) + busid.encode().ljust(32, b"\0"))
        _, code, status = struct.unpack(">HHI", recv_all(s, 8))
        if code != OP_REP_IMPORT or status:
            sys.exit(f"import of {busid} refused: status {status}")
        d = device(s)
        print(f"attached {d['busid']} ({d['id']}, {d['speed']} speed)")
        devid = d["busnum"] << 16 | d["devnum"]
        # GET_DESCRIPTOR(DEVICE), 18 bytes, as a non-isochronous CMD_SUBMIT with
        # number_of_packets 0xffffffff like the protocol spec says.
        setup = bytes([0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 18, 0x00])
        s.sendall(struct.pack(">IIIII", CMD_SUBMIT, 1, devid, 1, 0)
                  + struct.pack(">IiiIi", 0, 18, 0, 0xFFFFFFFF, 0) + setup)
        try:
            hdr = recv_all(s, 48)
        except EOFError:
            sys.exit("GET_DESCRIPTOR failed: the server dropped the connection (see its dmesg)")
        cmd, seq, _, _, _, st, length = struct.unpack(">IIIIIii", hdr[:28])
        if cmd != RET_SUBMIT or seq != 1:
            sys.exit(f"unexpected reply: command {cmd} seqnum {seq}")
        data = recv_all(s, length) if length > 0 else b""
        if st or length != 18 or data[1] != 1:
            sys.exit(f"GET_DESCRIPTOR failed: status {st}, {length} bytes")
        vid, pid = struct.unpack("<HH", data[8:12])
        print(f"device descriptor OK: USB {data[3]}.{data[2]:02x}, {vid:04x}:{pid:04x}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("host")
    ap.add_argument("--port", type=int, default=3240)
    ap.add_argument("--attach", nargs="?", const="", metavar="BUSID",
                    help="import BUSID (default: the first listed device) and read its descriptor")
    a = ap.parse_args()
    devs = devlist(a.host, a.port)
    for d in devs:
        print(f"{d['busid']:8} {d['id']}  {d['speed']:5} speed  interfaces {' '.join(d['interfaces']) or '-'}")
    if not devs:
        print("no exported devices")
    if a.attach is not None:
        busid = a.attach or (devs[0]["busid"] if devs else sys.exit("nothing to attach"))
        attach(a.host, a.port, busid)


if __name__ == "__main__":
    main()
