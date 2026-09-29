#!/usr/bin/env python3
"""Timing of a USB/IP connection, from a packet capture made on the client.

  usbip-timing.py CAPTURE [--server IP] [--port 3240]

For each endpoint it reports how long the server takes to answer (CMD_SUBMIT
sent until RET_SUBMIT received: network round trip plus the device), how long
the client takes to send the next transfer after one comes back, and how many
transfers it keeps in flight: when that reaches 0 on an isochronous endpoint,
the stream has run dry. It also counts endpoint resets (CLEAR_FEATURE
ENDPOINT_HALT, what Windows' audio driver sends after a glitch) and interface
changes.

On Windows, capture with the built-in pktmon, as administrator:

  pktmon filter add usbip -i SERVER_IP -t TCP -p 3240
  pktmon start --capture --comp nics --pkt-size 0 --file-name C:\\cap.etl
  (use the device for a while)
  pktmon stop
  pktmon etl2pcap C:\\cap.etl --out C:\\cap.pcapng
  pktmon filter remove

Reads pcap and pcapng. The busiest TCP connection on the port is the device's;
the capture may start and end in the middle of it.
"""
import argparse
import struct
import sys
from collections import defaultdict

CMD_SUBMIT, CMD_UNLINK, RET_SUBMIT, RET_UNLINK = 1, 2, 3, 4


def packets(path):
    """(time in s, link type, frame) of each packet of a pcap or pcapng file."""
    data = open(path, 'rb').read()
    if data[:4] in (b'\xd4\xc3\xb2\xa1', b'\xa1\xb2\xc3\xd4'):
        e = '<' if data[:4] == b'\xd4\xc3\xb2\xa1' else '>'
        linktype = struct.unpack(e + 'I', data[20:24])[0]
        pos = 24
        while pos + 16 <= len(data):
            sec, usec, incl, _ = struct.unpack(e + 'IIII', data[pos:pos + 16])
            yield sec + usec / 1e6, linktype, data[pos + 16:pos + 16 + incl]
            pos += 16 + incl
        return
    pos, e, linktypes = 0, '<', {}
    while pos + 12 <= len(data):
        btype = struct.unpack(e + 'I', data[pos:pos + 4])[0]
        if btype == 0x0a0d0d0a:  # section header: sets the byte order
            e = '<' if data[pos + 8:pos + 12] == b'\x4d\x3c\x2b\x1a' else '>'
            linktypes = {}
        blen = struct.unpack(e + 'I', data[pos + 4:pos + 8])[0]
        if blen < 12:
            break
        body = data[pos + 8:pos + blen - 4]
        if btype == 1:  # interface description
            linktypes[len(linktypes)] = struct.unpack(e + 'H', body[:2])[0]
        elif btype == 6:  # enhanced packet (timestamps in microseconds)
            iface, hi, lo, cap, _ = struct.unpack(e + 'IIIII', body[:20])
            yield ((hi << 32) | lo) / 1e6, linktypes.get(iface, 1), body[20:20 + cap]
        pos += blen


def segments(path, port):
    """TCP segments to or from PORT: (time, src ip, sport, dst ip, dport, seq, payload)."""
    for t, lt, f in packets(path):
        if lt == 1:  # Ethernet
            off = 14
            et = struct.unpack('>H', f[12:14])[0]
            if et == 0x8100:
                et = struct.unpack('>H', f[16:18])[0]
                off = 18
            if et != 0x0800:
                continue
            ip = f[off:]
        elif lt in (101, 228):  # raw IPv4
            ip = f
        else:
            continue
        if len(ip) < 20 or ip[0] >> 4 != 4 or ip[9] != 6:
            continue
        ihl = (ip[0] & 15) * 4
        total = struct.unpack('>H', ip[2:4])[0] or len(ip)
        tcp = ip[ihl:total]
        if len(tcp) < 20:
            continue
        sport, dport, seq = struct.unpack('>HHI', tcp[:8])
        if port not in (sport, dport):
            continue
        payload = tcp[(tcp[12] >> 4) * 4:]
        if payload:
            yield t, '.'.join(map(str, ip[12:16])), sport, '.'.join(map(str, ip[16:20])), dport, seq, payload


def reassemble(segs):
    """One direction's bytes, and (offset, time) for each segment's first byte."""
    first = {}
    for t, seq, p in segs:
        first.setdefault(seq, (t, p))  # the first copy; retransmissions add nothing
    if not first:
        return b'', []
    base = min(first)  # (a capture shorter than the 4 GB sequence wrap)
    data, marks = bytearray(), []
    for seq in sorted(first):
        t, p = first[seq]
        off = seq - base
        if off > len(data):
            print(f'  capture lost {off - len(data)} bytes; stopping there', file=sys.stderr)
            break
        new = p[len(data) - off:]
        if new:
            marks.append((len(data), t))
            data += new
    return bytes(data), marks


class Clock:
    """Capture time of a stream offset: when the segment carrying it passed."""
    def __init__(self, marks):
        self.marks, self.i = marks, 0

    def at(self, off):
        while self.i + 1 < len(self.marks) and self.marks[self.i + 1][0] <= off:
            self.i += 1
        return self.marks[self.i][1]


def sync(data, pos, length):
    """First offset from POS where 8 messages in a row parse (the capture may
    start mid-message)."""
    while pos < len(data):
        p, n = pos, 0
        while n < 8 and (m := length(data, p)):
            p += m
            n += 1
        if n == 8:
            return pos
        pos += 1
    return len(data)


def cmd_length(data, p):
    if p + 48 > len(data):
        return None
    cmd, _, _, direction, ep = struct.unpack('>IIIII', data[p:p + 20])
    if cmd == CMD_UNLINK:
        return 48
    if cmd != CMD_SUBMIT or direction > 1 or ep > 15:
        return None
    length, _, np = struct.unpack('>IiI', data[p + 24:p + 36])
    iso = 0 if np in (0, 0xffffffff) else np
    if length > 1 << 24 or iso > 1024:
        return None
    return 48 + (length if direction == 0 else 0) + 16 * iso


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('capture')
    ap.add_argument('--server', help="the server's IPv4 address (default: guess)")
    ap.add_argument('--port', type=int, default=3240)
    a = ap.parse_args()

    # Group segments by connection; the busiest is the device's
    conns = defaultdict(lambda: {'up': [], 'down': []})
    for t, src, sport, dst, dport, seq, p in segments(a.capture, a.port):
        if dport == a.port and (not a.server or dst == a.server):
            conns[(src, sport, dst)]['up'].append((t, seq, p))
        elif sport == a.port and (not a.server or src == a.server):
            conns[(dst, dport, src)]['down'].append((t, seq, p))
    if not conns:
        sys.exit('no USB/IP traffic in the capture')
    key = max(conns, key=lambda k: sum(len(p) for _, _, p in conns[k]['down'] + conns[k]['up']))
    client, cport, server = key
    up, up_marks = reassemble(conns[key]['up'])
    down, down_marks = reassemble(conns[key]['down'])
    print(f'{client}:{cport} -> {server}:{a.port}: {len(up)} bytes up, {len(down)} down')

    # Client commands, in order: seqnum -> (time sent, direction, ep, packets)
    clock = Clock(up_marks)
    cmds, events = {}, []  # events: (time, kind, ep key, seqnum)
    resets, altsets = [], []
    pos = sync(up, 0, cmd_length)
    while (n := cmd_length(up, pos)):
        cmd, seq, _, direction, ep = struct.unpack('>IIIII', up[pos:pos + 20])
        t = clock.at(pos)
        if cmd == CMD_SUBMIT:
            np = struct.unpack('>I', up[pos + 32:pos + 36])[0]
            setup = up[pos + 40:pos + 48]
            k = (ep, 'in' if direction else 'out', 'iso' if np not in (0, 0xffffffff) else '')
            cmds[seq] = (t, k, 0 if np == 0xffffffff else np)
            events.append((t, 'submit', k, seq))
            if ep == 0 and setup[:2] == b'\x02\x01' and setup[2:4] == b'\x00\x00':
                resets.append((t, setup[4]))
            elif ep == 0 and setup[:2] == b'\x01\x0b':
                altsets.append((t, setup[4], setup[2]))
        pos += n

    # Server replies
    clock = Clock(down_marks)

    def ret_length(data, p):
        if p + 48 > len(data):
            return None
        cmd, seq = struct.unpack('>II', data[p:p + 8])
        if cmd == RET_UNLINK:
            return 48
        if cmd != RET_SUBMIT:
            return None
        c = cmds.get(seq)
        actual, _, np = struct.unpack('>IiI', data[p + 24:p + 36])
        if not c:  # submitted before the capture: guess from the reply
            iso = 0 if np in (0, 0xffffffff) else np
            return None if iso > 1024 else 48 + 16 * iso + (actual if not iso else 0)
        t, k, _ = c
        iso = 0 if np in (0, 0xffffffff) else np
        return 48 + (actual if k[1] == 'in' else 0) + 16 * iso

    pos = sync(down, 0, ret_length)
    while (n := ret_length(down, pos)):
        cmd, seq = struct.unpack('>II', down[pos:pos + 8])
        t = clock.at(pos + n - 1)  # when the whole reply was in
        if cmd == RET_SUBMIT and seq in cmds:
            events.append((t, 'return', cmds[seq][1], seq))
        pos += n

    events.sort()
    t0 = events[0][0] if events else 0
    span = events[-1][0] - t0 if events else 0
    print(f'{span:.1f} s of traffic\n')

    stats = defaultdict(lambda: {'n': 0, 'server': [], 'turn': [], 'depth': 0, 'min': None, 'dry': 0, 'dry_ms': 0.0})
    sent = {}
    last_return = {}
    dry_since = {}
    for t, kind, k, seq in events:
        s = stats[k]
        if kind == 'submit':
            s['n'] += 1
            sent[seq] = t
            if k in last_return:
                s['turn'].append((t - last_return.pop(k)) * 1000)
            s['depth'] += 1
            if k in dry_since:
                s['dry_ms'] += (t - dry_since.pop(k)) * 1000
        else:
            if seq in sent:
                s['server'].append((t - sent.pop(seq)) * 1000)
            last_return[k] = t
            s['depth'] -= 1
            if s['depth'] <= 0 and k[2] == 'iso':
                s['dry'] += 1
                dry_since[k] = t
        s['min'] = s['depth'] if s['min'] is None else min(s['min'], s['depth'])

    def pct(v, q):
        v = sorted(v)
        return v[min(len(v) - 1, int(q * len(v)))] if v else float('nan')

    print('endpoint        transfers   server ms (p50 p99 max)   client turnaround ms (p50 p99 max)   ran dry')
    for k in sorted(stats, key=lambda k: (k[0], k[1])):
        s = stats[k]
        name = f"ep{k[0]} {k[1]} {k[2]}".strip()
        sv, tu = s['server'], s['turn']
        dry = f"{s['dry']}x, {s['dry_ms']:.0f} ms" if k[2] == 'iso' else ''
        print(f"{name:14} {s['n']:10}   {pct(sv, .5):6.1f} {pct(sv, .99):6.1f} {max(sv, default=float('nan')):6.1f}"
              f"           {pct(tu, .5):6.1f} {pct(tu, .99):6.1f} {max(tu, default=float('nan')):6.1f}      {dry}")
    minutes = span / 60 if span else 1
    print(f'\nendpoint resets (CLEAR_FEATURE ENDPOINT_HALT): {len(resets)}, {len(resets) / minutes:.1f}/min')
    for t, ep in resets[:10]:
        print(f'  {t - t0:8.3f} s  endpoint {ep:#04x}')
    if altsets:
        print(f'interface changes (SET_INTERFACE): {len(altsets)}')
        for t, iface, alt in altsets[:10]:
            print(f'  {t - t0:8.3f} s  interface {iface} alt {alt}')


if __name__ == '__main__':
    main()
