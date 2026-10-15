#!/usr/bin/env python3
"""Write an alsaequal (CAPS Eq4p) controls file.

The S/PDIF branch's tone uses the ALSA 'equal' plugin with CAPS Eq4p, wired as
a low shelf (band a -> bass) and a high shelf (band d -> treble); bands b/c are
off. jukebox-pots rewrites this file live when the tone pots move (the 'equal'
plugin reads the mmap'd controls on every process cycle, so the device is not
reopened).

The layout is the same alsaequal LADSPA_Control blob jukebox-audio already uses
for the analyser trim: 6xuint32 header, one 72-byte record per control port
{int32 index; float data[16]; int32 type}, then a trailing float[16] per port.

usage: eq-write.py PATH UID LOW_FREQ LOW_GAIN LOW_Q HIGH_FREQ HIGH_GAIN HIGH_Q
"""
import struct
import sys

EQ_CAPS_ID = 2608  # CAPS Eq4p LADSPA unique id (default when UID omitted)


def write(path, low_freq, low_gain, low_q, high_freq, high_gain, high_q,
          uid=EQ_CAPS_ID, channels=2):
    # Eq4p control ports, in order: a.mode,a.f,a.Q,a.gain, b.*, c.*, d.*, _latency
    # mode: 0 = low shelf, 1 = peak, 2 = high shelf, -1 = off.
    spec = [
        (0, 0.0, 0), (1, low_freq, 0), (2, low_q, 0), (3, low_gain, 0),   # a: bass
        (4, -1.0, 0), (5, 529.161, 0), (6, 0.5, 0), (7, 0.0, 0),          # b: off
        (8, -1.0, 0), (9, 529.161, 0), (10, 0.25, 0), (11, 0.0, 0),       # c: off
        (12, 2.0, 0), (13, high_freq, 0), (14, high_q, 0), (15, high_gain, 0),  # d: treble
        (16, 3.0, 1),                                                     # _latency (out)
    ]
    body = bytearray()
    for idx, val, typ in spec:
        rec = bytearray(72)
        struct.pack_into("<i", rec, 0, idx)
        for c in range(channels):
            struct.pack_into("<f", rec, 4 + c * 4, val)
        struct.pack_into("<i", rec, 68, typ)
        body += rec
    tail = bytearray()
    for _idx, val, _typ in spec:
        for _c in range(channels):
            tail += struct.pack("<f", val)
    length = 24 + len(body) + len(tail)
    hdr = struct.pack("<6I", length, uid, channels, len(spec), 17, 18)
    with open(path, "wb") as fh:
        fh.write(hdr + bytes(body) + bytes(tail))


def main():
    # PATH LOW_FREQ LOW_GAIN LOW_Q HIGH_FREQ HIGH_GAIN HIGH_Q  [UID]
    if len(sys.argv) not in (8, 9):
        sys.stderr.write(__doc__)
        return 2
    path = sys.argv[1]
    low_freq, low_gain, low_q, high_freq, high_gain, high_q = (
        float(x) for x in sys.argv[2:8])
    uid = int(sys.argv[8]) if len(sys.argv) == 9 else EQ_CAPS_ID
    write(path, low_freq, low_gain, low_q, high_freq, high_gain, high_q, uid)
    return 0


if __name__ == "__main__":
    sys.exit(main())
