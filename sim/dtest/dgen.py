#!/usr/bin/env python3
"""Random test for the DMA engine (spec 14): SRAM contents and job chains
for the 4 channels, for dtest.asm to start and dmodel.py to check.
retro68k's sim/dtest/dgen.py (ac7b75a), for spec 14: 32-byte descriptors,
all in SRAM (no descriptor RAM), a control table the Z80 can see, and a
chain of all 256 minterms.

    dgen.py OUTDIR [SEED]

Writes OUTDIR/ram.hex (the SRAM at the start, $readmemh of 16-bit words,
the even byte in bits 7-0) and OUTDIR/jobs.json (each channel's jobs in
order, for dmodel.py).

Each channel works in its own 256 KB of SRAM (sources in the first half:
B in the first 64 KB, mask images in the next; destinations in the second
half, and the overlapping copies), so the channels can run in any order.
Channel 0's chain ends with 256 jobs, one per minterm, each on two pixels
that between them have every combination of A, B and C.

The control table at physical 0x00A000 (Z80 0xE000 in the map after
reset) tells dtest.asm what to start (keep in step with dtest.asm):
  +0x00  channel 0's first descriptor (3 bytes; +0x03 spare)
  +0x04  channel 1's, +0x08 channel 2's
  +0x0C  the DMXINT bits to expect at the end
  +0x10  channel 3's first job (32 bytes), written into its job registers
         and started with RUN
"""
import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dmodel import encode  # noqa: E402

CTL = 0x00A000
DESCS = 0x0F1000                     # descriptors
MTDATA = 0x0FC000                    # the minterm jobs' A and B
MTDEST = 0x0FD000                    # ... and their destinations, 2 bytes each
REGION = 0x100000                    # channel n at REGION + n x 0x40000
CHECK = [0x0F0000, 0x200000]


def place(rng, lo, size, rows, stride, rowbytes):
    """A first-row address so every row lies in [lo, lo + size)."""
    span_lo = min(0, (rows - 1) * stride)
    span_hi = max(0, (rows - 1) * stride) + rowbytes
    a_lo = lo - span_lo
    a_hi = lo + size - span_hi
    return rng.randrange(a_lo, a_hi)


MINTERMS = [0xCC, 0xCC, 0xCA, 0xEE, 0x88, 0x66, 0x22, 0x55, 0x00, 0xFF, 0x0A]


def make_job(rng, area, kind=None):
    """A random job. kind: None, 'KEY' (cookie-cut with a key colour),
    'MASK' (a 1 bpp mask image), 'ADD' or 'C' (a minterm that reads C)."""
    b = rng.choice([1, 2, 4, 8, 8])
    ppb = 8 // b
    if b == 8 and rng.random() < 0.25:
        w, h = rng.randrange(1, 700), 1                    # a linear job
    else:
        w = rng.randrange(1, 90 if b == 8 else 200)
        h = rng.randrange(1, 9)
    bbit = rng.randrange(ppb) if b < 8 else 0
    dbit = rng.randrange(ppb) if b < 8 else 0
    abit = rng.randrange(8)
    brow = (bbit * b + w * b + 7) // 8
    drow = (dbit * b + w * b + 7) // 8
    arow = (abit + w + 7) // 8
    j = {"op": "BLIT", "bpp": b, "width": w, "height": h, "abit": abit, "bbit": bbit, "dbit": dbit,
         "desc": int(rng.random() < 0.3), "value": rng.getrandbits(32), "sat": 0, "signed": 0,
         "minterm": rng.choice(MINTERMS) if rng.random() < 0.7 else rng.getrandbits(8),
         "mask": rng.choice([0, 0, 1, 2]), "bkind": "value" if rng.random() < 0.25 else "mem"}
    if kind == "ADD" or (kind is None and rng.random() < 0.15):
        j["op"] = "ADD"
        j["sat"], j["signed"] = rng.randrange(2), rng.randrange(2)
    if kind == "KEY":
        j["mask"], j["minterm"], j["bkind"] = 2, 0xCA, "mem"
    if kind == "MASK":
        j["mask"] = 1
        j["minterm"] = rng.choice([0xCA, 0x0A, 0xE2, rng.getrandbits(8)])
    if kind == "C":
        j["minterm"] = rng.choice([0x66, 0x88, 0xEE, 0x55])
    if j["mask"] == 2:
        j["value"] = 0 if rng.random() < 0.7 else rng.getrandbits(8)
    ss = rng.choice([1, 1, 1, -1]) * (max(brow, arow) + rng.randrange(0, 24))
    if rng.random() < 0.1:
        ss = 0                                             # the same source row every time
    ds = rng.choice([1, 1, 1, -1]) * (drow + rng.randrange(0, 24))
    j["abstride"], j["cdstride"] = ss, ds
    j["bpt"] = place(rng, area, 0x10000, h, ss, brow)
    j["apt"] = place(rng, area + 0x10000, 0x10000, h, ss, arow)
    j["dpt"] = place(rng, area + 0x20000, 0x20000, h, ds, drow)
    return j


def make_overlap(rng, area):
    """A copy whose source and destination overlap: DESC when the
    destination is after the source, forwards when before."""
    b = rng.choice([1, 2, 4, 8])
    ppb = 8 // b
    w = rng.randrange(8, 120)
    h = rng.randrange(1, 6)
    bit = rng.randrange(ppb) if b < 8 else 0
    row = (bit * b + w * b + 7) // 8
    stride = row + rng.randrange(0, 8)
    delta_px = rng.choice([1, 2, 3, 5, 17, 40]) * rng.choice([1, -1])
    src = area + 0x30000 + rng.randrange(0, 0x1000)
    dpix = bit + delta_px
    dst = src + (dpix * b) // 8
    dbit = (dpix * b % 8) // b
    if delta_px > 0 and rng.random() < 0.5:                # a whole row down, too
        dst += stride
    after = (dst, dbit) > (src, bit)
    return {"op": "BLIT", "minterm": 0xCC, "mask": 0, "bpp": b, "width": w, "height": h,
            "abit": 0, "bbit": bit, "dbit": dbit, "desc": int(after), "bkind": "mem", "value": 0,
            "abstride": stride, "cdstride": stride, "apt": 0, "bpt": src, "dpt": dst}


def minterm_jobs():
    """One 8 bpp job per minterm on two pixels: A = 1, 0 (the mask byte
    0x80 at MTDATA), B = 0xCC, 0xCC, C = 0xAA, 0xAA (written by dgen), so
    each pixel's 8 bits see B and C as 11, 10, 01, 00 twice over."""
    return [{"op": "BLIT", "minterm": m, "mask": 1, "bpp": 8, "width": 2, "height": 1,
             "abit": 0, "bbit": 0, "dbit": 0, "desc": 0, "bkind": "mem", "value": 0,
             "sat": 0, "signed": 0, "abstride": 0, "cdstride": 0,
             "apt": MTDATA, "bpt": MTDATA + 2, "dpt": MTDEST + 2 * m} for m in range(256)]


def main():
    out = sys.argv[1]
    rng = random.Random(int(sys.argv[2]) if len(sys.argv) > 2 else 11)
    mem = bytearray(0x200000)
    for a in range(CHECK[0], CHECK[1]):
        mem[a] = 0 if rng.random() < 0.25 else rng.getrandbits(8)
    for a in range(DESCS, MTDATA):
        mem[a] = 0
    mem[MTDATA:MTDATA + 4] = bytes([0x80, 0x00, 0xCC, 0xCC])
    for m in range(256):
        mem[MTDEST + 2 * m:MTDEST + 2 * m + 2] = b"\xAA\xAA"

    channels = []
    for ch in range(4):
        area = REGION + ch * 0x40000
        jobs = [make_job(rng, area) for _ in range(7)]
        jobs.insert(rng.randrange(1, 7), make_overlap(rng, area))
        for kind in ("KEY", "MASK", "MASK", "ADD", "C"):
            jobs.insert(rng.randrange(1, len(jobs)), make_job(rng, area, kind))
        z = make_job(rng, area)
        z["width"] = 0                                     # a job that does nothing
        jobs.insert(rng.randrange(1, len(jobs)), z)
        if ch == 0:
            jobs += minterm_jobs()
        channels.append(jobs)

    nxt_slot = [DESCS]

    def slot():
        a = nxt_slot[0]
        nxt_slot[0] += 32
        return a

    ctl = bytearray(0x30)
    expect = 0
    for ch, jobs in enumerate(channels):
        # channel 3's first job goes into its job registers
        homes = [None if (ch == 3 and i == 0) else slot() for i in range(len(jobs))]
        mid = rng.randrange(1, len(jobs) - 1)
        for i, j in enumerate(jobs):
            nxt = homes[i + 1] if i + 1 < len(jobs) else 0
            irq = int(i == len(jobs) - 1 or i == mid)
            d = encode(j, nxt, irq)
            if homes[i] is None:
                ctl[0x10:0x30] = d
            else:
                mem[homes[i]:homes[i] + 32] = d
        expect |= 1 << ch
        if ch < 3:
            ctl[4 * ch:4 * ch + 3] = homes[0].to_bytes(3, "little")
    ctl[0x0C] = expect
    assert nxt_slot[0] <= MTDATA

    def words(f, lo, data):
        f.write("@%x\n" % (lo // 2))
        for k in range(0, len(data), 2):
            f.write("%04x\n" % (data[k] | (data[k + 1] << 8)))

    with open(os.path.join(out, "ram.hex"), "w", newline="\n") as f:
        words(f, CTL, ctl)
        words(f, CHECK[0], mem[CHECK[0]:CHECK[1]])
    with open(os.path.join(out, "jobs.json"), "w", newline="\n") as f:
        json.dump({"check": CHECK, "channels": channels}, f, indent=1)
    print("dgen: %d jobs on 4 channels" % sum(len(c) for c in channels))


if __name__ == "__main__":
    main()
