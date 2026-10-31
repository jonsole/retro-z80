#!/usr/bin/env python3
"""Reference model of the DMA engine and blitter (spec 14): what a job does
to the SRAM, pixel by pixel. retro68k's sim/dtest/dmodel.py (ac7b75a),
with spec 14's little-endian SRAM and VALUE and its 32-byte descriptor.

Used two ways:
  - as a library: dgen.py builds tests with run_job() and encode();
  - from the command line, to check a simulation:

        dmodel.py JOBS.json RAM_BEFORE.hex RAM_AFTER.hex

    JOBS.json lists each channel's jobs in order (the channels use separate
    memory, so the order between channels does not matter). RAM_BEFORE is
    the SRAM given to the simulation, RAM_AFTER what the testbench dumped at
    the end (both $readmemh files of 16-bit words, the even byte in bits
    7-0). Exits 1 on any difference.

A job is a dict with the descriptor's fields, decoded:
  op ('BLIT', 'ADD', 'LINE'), minterm, mask (0 none, 1 image at apt, 2 key
  compare), sat, signed (ADD), bpp (1, 2, 4, 8), desc, bkind ('mem',
  'value': BCONST), apt, abit, bpt, bbit, dpt, dbit, width, height,
  abstride, cdstride (signed), value. A LINE job (section 3.4) has ymaj,
  xneg, yneg, lx, ly (the first pixel's x and y) and uses the clip
  rectangle given to run_job.
"""
import json
import sys

OPS = {"BLIT": 0, "ADD": 1, "LINE": 2, "EDGES": 3}
FULL = (-32768, 32767, -32768, 32767)   # the clip rectangle after reset


def get_pix(mem, addr, pos, b):
    """Pixel pos (0 = most significant) of the byte at addr, b bits wide."""
    sh = 8 - b * (pos + 1)
    return (mem[addr] >> sh) & ((1 << b) - 1)


def put_pix(mem, addr, pos, b, v):
    sh = 8 - b * (pos + 1)
    m = ((1 << b) - 1) << sh
    mem[addr] = (mem[addr] & ~m & 0xFF) | ((v << sh) & m)


def locate(base, bit, i, b):
    """Byte address and pixel position of pixel i of a row starting at
    (base, bit)."""
    off = bit * b + i * b               # bits from the row's first byte
    return base + (off >> 3), (off & 7) // b


def value_pix(value, addr, b):
    """A constant B for the pixel at addr: at 8 bpp VALUE's byte addr mod 4,
    byte 0 its bits 7-0 (spec 14, section 3.1); below, its low b bits."""
    if b == 8:
        return (value >> (8 * (addr & 3))) & 0xFF
    return value & ((1 << b) - 1)


def add_pix(d, s, b, sat, signed):
    top = (1 << b) - 1
    if not sat:
        return (d + s) & top
    if not signed:
        return min(d + s, top)
    sx = lambda v: v - (1 << b) if v >> (b - 1) else v
    r = sx(d) + sx(s)
    r = max(-(1 << (b - 1)), min((1 << (b - 1)) - 1, r))
    return r & top


def minterm_pix(m, a, bv, c, b):
    """BLIT: each bit of the result is MINTERM's bit a*4 + b*2 + c, where a
    (the mask) is the same for every bit of the pixel."""
    r = 0
    for k in range(b):
        r |= ((m >> (a * 4 + ((bv >> k) & 1) * 2 + ((c >> k) & 1))) & 1) << k
    return r


def run_line(mem, j, clip=FULL):
    """A LINE job (spec 14, section 3.4): WIDTH pixels by Bresenham's rule
    from (lx, ly) at (dpt, dbit), each through the minterm with the pattern
    as A and the colour as B, unless outside the clip rectangle or left
    alone (A = 0 with D = C)."""
    b, w, n = j["bpp"], j["width"], j["height"]
    m = w - 1
    e = 2 * n - m
    x, y = j["lx"], j["ly"]
    wrap = (1 << 26) - 1                               # 23-bit byte addresses, wrapping
    bit = ((j["dpt"] & 0x7FFFFF) * 8 + j["dbit"] * b) & wrap
    xs = -b if j["xneg"] else b
    ys = -8 * j["cdstride"] if j["yneg"] else 8 * j["cdstride"]
    dx, dy = (-1 if j["xneg"] else 1), (-1 if j["yneg"] else 1)
    xmin, xmax, ymin, ymax = clip
    colour = j["value"] & ((1 << b) - 1)
    for i in range(w):
        a = (j["value"] >> (31 - i % 16)) & 1
        if xmin <= x <= xmax and ymin <= y <= ymax and not (a == 0 and j["minterm"] & 15 == 0xA):
            addr, pos = bit >> 3, (bit & 7) // b
            put_pix(mem, addr, pos, b, minterm_pix(j["minterm"], a, colour, get_pix(mem, addr, pos, b), b))
        if i == w - 1:
            break
        minor = e > 0
        e += 2 * (n - m) if minor else 2 * n
        if j["ymaj"]:
            y, bit = y + dy, bit + ys
            if minor:
                x, bit = x + dx, bit + xs
        else:
            x, bit = x + dx, bit + xs
            if minor:
                y, bit = y + dy, bit + ys
        bit &= wrap


def s16(v):
    return v - 0x10000 if v & 0x8000 else v


def run_edges(mem, j, clip=FULL):
    """An EDGES job (spec 14, section 3.5): each edge's two point numbers
    at EDGES (bpt) + 2k, the points' x and y words at POINTS (apt) + 4n,
    each edge a LINE from the first to the second, left out if an end is
    outside -16384..16383 (x = 0x8000 among them) or both ends are beyond
    the same side of the clip rectangle."""
    b = j["bpp"]
    xmin, xmax, ymin, ymax = clip
    origin = (j["dpt"] & 0x7FFFFF) * 8 + j["dbit"] * b
    word = lambda a: s16(mem[a] | mem[a + 1] << 8)
    for k in range(j["width"]):
        e = j["bpt"] + 2 * k
        pa, pb = mem[e], mem[e + 1]
        x0, y0 = word(j["apt"] + 4 * pa), word(j["apt"] + 4 * pa + 2)
        x1, y1 = word(j["apt"] + 4 * pb), word(j["apt"] + 4 * pb + 2)
        if any(not -16384 <= v <= 16383 for v in (x0, y0, x1, y1)):
            continue
        if ((x0 < xmin and x1 < xmin) or (x0 > xmax and x1 > xmax)
                or (y0 < ymin and y1 < ymin) or (y0 > ymax and y1 > ymax)):
            continue
        ax, ay = abs(x1 - x0), abs(y1 - y0)
        bit = (origin + 8 * y0 * j["cdstride"] + x0 * b) & ((1 << 26) - 1)
        run_line(mem, {"bpp": b, "width": max(ax, ay) + 1, "height": min(ax, ay),
                       "ymaj": int(ay > ax), "xneg": int(x1 < x0), "yneg": int(y1 < y0),
                       "lx": x0, "ly": y0, "dpt": bit >> 3, "dbit": (bit & 7) // b,
                       "cdstride": j["cdstride"], "minterm": j["minterm"], "value": j["value"]}, clip)


def run_job(mem, j, clip=FULL):
    if j["op"] == "LINE":
        run_line(mem, j, clip)
        return
    if j["op"] == "EDGES":
        run_edges(mem, j, clip)
        return
    """Apply one job to mem (a bytearray of the SRAM), in the engine's order:
    forwards, or with DESC from the last pixel of the last row back to the
    first. Each source pixel is read just before its destination pixel is
    written, which is what the hardware gives for every overlap a job is
    allowed (spec 14, section 3.3: DESC when the destination is after the
    source)."""
    b, w, h = j["bpp"], j["width"], j["height"]
    if w == 0 or h == 0:
        return
    rows = range(h - 1, -1, -1) if j["desc"] else range(h)
    cols = range(w - 1, -1, -1) if j["desc"] else range(w)
    key = j["value"] & ((1 << b) - 1)
    for r in rows:
        arow = j["apt"] + r * j["abstride"]
        brow = j["bpt"] + r * j["abstride"]
        drow = j["dpt"] + r * j["cdstride"]
        for i in cols:
            da, dp = locate(drow, j["dbit"], i, b)
            if j["bkind"] == "mem":
                sa, sp = locate(brow, j["bbit"], i, b)
                s = get_pix(mem, sa, sp, b)
            else:                                       # VALUE
                s = value_pix(j["value"], da, b)
            if j["mask"] == 1:
                aa, ap = locate(arow, j["abit"], i, 1)
                a = get_pix(mem, aa, ap, 1)
            elif j["mask"] == 2:
                a = int(s != key)
            else:
                a = 1
            c = get_pix(mem, da, dp, b)
            if j["op"] == "ADD":
                v = add_pix(c, s, b, j["sat"], j["signed"]) if a else c
            else:
                v = minterm_pix(j["minterm"], a, s, c, b)
            put_pix(mem, da, dp, b, v)


def encode(j, nxt=0, irq=0):
    """The job as a 32-byte descriptor (spec 14, section 3), low bytes first."""
    bppc = {1: 0, 2: 1, 4: 2, 8: 3}[j["bpp"]]
    le = lambda v, n: (v & ((1 << 8 * n) - 1)).to_bytes(n, "little")
    if j["op"] == "EDGES":
        ctrl1 = bppc | (irq << 3)
        d = (bytes([3, ctrl1, 0, j["minterm"]]) + le(j["apt"], 3) + le(j["bpt"], 3) + le(j["dpt"], 3)
             + le(j["width"], 3) + le(0, 2) + le(j["dbit"] << 8, 2) + le(0, 2)
             + le(j["cdstride"], 2) + le(j["value"], 4) + le(nxt, 3) + b"\0")
        assert len(d) == 32
        return d
    if j["op"] == "LINE":
        ctrl0 = 2 | (j["ymaj"] << 3) | (j["xneg"] << 6) | (j["yneg"] << 7)
        ctrl1 = bppc | (irq << 3) | (j.get("bconst", 0) << 4)
        d = (bytes([ctrl0, ctrl1, 0, j["minterm"]]) + le(j["lx"], 3) + le(j["ly"], 3) + le(j["dpt"], 3)
             + le(j["width"], 3) + le(j["height"], 2) + le(j["dbit"] << 8, 2) + le(0, 2)
             + le(j["cdstride"], 2) + le(j["value"], 4) + le(nxt, 3) + b"\0")
        assert len(d) == 32
        return d
    bconst = int(j["bkind"] == "value")
    ctrl0 = OPS[j["op"]] | (j.get("sat", 0) << 4) | (j.get("signed", 0) << 5)
    ctrl1 = bppc | (j["desc"] << 2) | (irq << 3) | (bconst << 4) | (j["mask"] << 5)
    apt = j["apt"] if j["mask"] == 1 else 0
    abit = j["abit"] if j["mask"] == 1 else 0
    bpt = j["bpt"] if not bconst else 0
    bbit = j["bbit"] if not bconst else 0
    shift = abit | (bbit << 4) | (j["dbit"] << 8)
    le = lambda v, n: (v & ((1 << 8 * n) - 1)).to_bytes(n, "little")
    d = (bytes([ctrl0, ctrl1, 0, j.get("minterm", 0)]) + le(apt, 3) + le(bpt, 3) + le(j["dpt"], 3)
         + le(j["width"], 3) + le(j["height"], 2) + le(shift, 2) + le(j["abstride"], 2)
         + le(j["cdstride"], 2) + le(j.get("value", 0), 4) + le(nxt, 3) + b"\0")
    assert len(d) == 32
    return d


def load_hex(path, size=0x400000):
    mem, a = bytearray(size), 0
    for line in open(path):
        line = line.split("//")[0].strip()
        if not line:
            continue
        if line[0] == "@":
            a = int(line[1:], 16) * 2
        else:
            w = int(line, 16) if "x" not in line.lower() else 0
            if a + 1 < size:
                mem[a], mem[a + 1] = w & 0xFF, w >> 8
            a += 2
    return mem


def main():
    jobs = json.load(open(sys.argv[1]))
    mem = load_hex(sys.argv[2])
    got = load_hex(sys.argv[3])
    clip = tuple(jobs.get("clip", FULL))
    for ch in jobs["channels"]:
        for j in ch:
            run_job(mem, j, clip)
    lo, hi = jobs.get("check", [0, len(mem)])
    errors = 0
    for a in range(lo, hi):
        if mem[a] != got[a]:
            if errors < 10:
                print("dmodel: byte %06x is %02x, expected %02x" % (a, got[a], mem[a]))
            errors += 1
    print("dmodel: %d jobs, %d differences in %06x-%06x"
          % (sum(len(c) for c in jobs["channels"]), errors, lo, hi))
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
