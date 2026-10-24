#!/usr/bin/env python3
"""Video test generator (spec 4; ticket #13): bands of L0 settings, palettes
and random picture data for vtest.asm.

    vgen.py VARIANT OUTDIR

VARIANT is a fixed set of bands ("a": every depth and scale, windows off
the edges, fine scroll, negative and zero stride, pointer wrap within a
line, TRANSP, PALOFS) or a seed for random bands ("b", "c", ...: the same
kinds of settings at random, with PRIO and BGCOLOR changed between bands).
Writes OUTDIR/vbands.inc (the band code, timed from the start of each
frame, and the palette data for vtest.asm) and OUTDIR/ram.hex (16-bit
words for the testbench's +ram=).

Each band is written in the lines between the band before and itself: L0
off first (CTRL0 = 0), then its settings, then CTRL0 with EN. The code is
straight-line, so its timing is known to the T-state (20 MHz: a line is 640
T-states, a frame 400,000). Writes are kept away from the moments the
video unit copies its settings (beam pixel 0 for line settings, beam pixel
144 for PRIO and BGCOLOR), so the model knows which line each one acts on;
vmodel.py checks that they were.
"""
import random
import sys

LINE_T = 640                     # T-states per line at 20 MHz
FRAME_T = 625 * LINE_T
T_START = 25 + 17                # the VBLANK poll's exit (nominal) and the CALL
DATA_LO, DATA_HI = 0x020000, 0x0C0000   # random picture data, bytes

CUSTOM = 0x10                    # the custom block's first page
L0 = 0x90                        # L0's registers (custom offsets)
PRIO, BGCOLOR0 = 0x03, 0x04


def port(off):
    return ((off & 0xFF) << 8) | (CUSTOM + (off >> 8))


def bands_a():
    """Hand-picked: one band per kind of setting."""
    B = []
    def band(**k):
        d = dict(bpp=0, hs=0, vs=0, transp=0, palofs=0, wrap=0, xs=144, xe=864, sx=0, stride=0, off=0)
        d.update(k)
        B.append(d)
    band(ys=53,  ye=113, bpp=3, stride=720)                                         # 8 bits, 1x, full width
    band(ys=117, ye=177, bpp=2, hs=1, vs=1, xs=200, xe=700, sx=5, stride=200, transp=1, palofs=3)
    band(ys=181, ye=241, bpp=1, hs=2, vs=2, xs=100, xe=600, sx=0x10D, stride=-64, palofs=9, off=0xF000)
    band(ys=245, ye=285, bpp=0, hs=3, vs=1, xs=300, xe=900, stride=0, palofs=14, transp=1)
    band(ys=289, ye=349, bpp=3, hs=1, xs=160, xe=860, sx=7, wrap=1, stride=352, transp=1, off=0x3E8)
    band(ys=353, ye=413, bpp=2, vs=3, xs=400, xe=417, sx=15, stride=10, palofs=15)
    band(ys=417, ye=477, bpp=1, sx=3, wrap=3, stride=182, transp=1, off=0xF00)
    band(ys=481, ye=541, bpp=0, vs=2, xs=150, xe=851, sx=9, stride=90, palofs=1)
    band(ys=545, ye=625, bpp=3, hs=3, vs=3, sx=0x3F1, stride=92)                     # 8 bits, 8x, to the last line
    return B


def bands_random(rnd):
    """Random bands with gaps of 4-9 lines, PRIO and BGCOLOR now and then."""
    B = []
    y = 49 + rnd.randrange(4, 20)
    while True:
        h = rnd.randrange(12, 90)
        if y + h > 625:
            break
        xs = rnd.choice([rnd.randrange(100, 700), 144, rnd.randrange(144, 400)])
        xe = rnd.choice([rnd.randrange(xs + 1, 950), 864, rnd.randrange(xs + 1, xs + 120)])
        d = dict(ys=y, ye=y + h, bpp=rnd.randrange(4), hs=rnd.randrange(4), vs=rnd.randrange(4),
                 transp=rnd.randrange(2), palofs=rnd.randrange(16), wrap=rnd.choice([0, 0, 0, 1, 2, 4, 7]),
                 xs=xs, xe=xe, sx=rnd.randrange(1024), stride=2 * rnd.randrange(-200, 400),
                 off=2 * rnd.randrange(0, 0x7000))
        if rnd.random() < 0.3:
            d["prio"] = rnd.choice([0x24, 0x24, 0x39, 0x1E, 0x3F, 0x0F])
        if rnd.random() < 0.4:
            d["bg"] = rnd.randrange(1 << 24)
        B.append(d)
        y += h + rnd.randrange(4, 10)
    return B


class Code:
    """Straight-line Z80 code with its T-state count from the frame's start."""
    def __init__(self):
        self.t = T_START
        self.lines = ["bands:"]

    def px(self, t):
        return ((t % LINE_T) * 27) // 20           # beam pixel: 864 per 640 T-states

    def wait_until(self, t):
        need = t - self.t
        if need >= 72:
            n = (need - 32) // 40
            self.lines.append("        ld      de,%d" % n)
            self.lines.append("        call    dly")
            self.t += 40 * n + 32
        while self.t + 4 <= t:
            self.lines.append("        nop")
            self.t += 4

    def write(self, off, val, kind, comment=""):
        # The write lands about 27 T-states into LD BC / LD A / OUT (C),A (29)
        while True:
            p = self.px(self.t + 27)
            if kind == "line" and (p >= 815 or p <= 50):
                pass                                # near beam pixel 0: the line settings' copy
            elif kind == "pic" and 105 <= p <= 185:
                pass                                # near beam pixel 144: PRIO and BGCOLOR
            else:
                break
            self.lines.append("        nop")
            self.t += 4
        self.lines.append("        ld      bc,0x%04X\n        ld      a,0x%02X\n        out     (c),a%s"
                          % (port(off), val & 0xFF, ("            ; " + comment) if comment else ""))
        self.t += 29


def main():
    variant, out = sys.argv[1], sys.argv[2]
    rnd = random.Random("retro-z80 vtest " + variant)
    B = bands_a() if variant == "a" else bands_random(rnd)

    # Each band's data in the random area: its own 64 KB for the fixed bands;
    # random bands start in the middle (0x060000-0x09FFFF), so 90 lines at
    # any stride stay inside it
    for k, b in enumerate(B):
        b["ptr"] = (DATA_LO + k * 0x10000 if variant == "a" else 0x060000 + (k % 4) * 0x10000) + b["off"]

    code = Code()
    prev_end = 0
    for k, b in enumerate(B):
        code.wait_until(prev_end * LINE_T + 45)
        assert code.px(code.t) < 200
        code.lines.append("        ; band %d: %s" % (k, b))
        ctrl0 = 1 | (b["bpp"] << 2) | (b["transp"] << 4) | (b["hs"] << 6)
        code.write(L0 + 0x00, 0, "line", "L0 off")
        code.write(L0 + 0x01, b["vs"] | (b["palofs"] << 4), "line")
        code.write(L0 + 0x02, b["wrap"] << 4, "line")
        for i, v in enumerate([b["xe"], b["xs"], b["ye"], b["ys"]]):
            code.write(L0 + 0x04 + 2 * i, v & 0xFF, "line")
            code.write(L0 + 0x05 + 2 * i, v >> 8, "line")
        code.write(L0 + 0x0C, b["sx"] & 0xFF, "line")
        code.write(L0 + 0x0D, b["sx"] >> 8, "line")
        code.write(L0 + 0x10, b["stride"] & 0xFF, "line")
        code.write(L0 + 0x11, (b["stride"] >> 8) & 0xFF, "line")
        for i in range(3):
            code.write(L0 + 0x14 + i, (b["ptr"] >> (8 * i)) & 0xFF, "line")
        if "prio" in b:
            code.write(PRIO, b["prio"], "pic")
        if "bg" in b:
            for i in range(3):
                code.write(BGCOLOR0 + i, (b["bg"] >> (8 * i)) & 0xFF, "pic")
        code.write(L0 + 0x00, ctrl0, "line", "L0 on")
        last = (code.t - 2) // LINE_T + (1 if code.px(code.t) >= 815 else 0)
        assert last < b["ys"] - 1, "band %d: its writes end in line %d, it starts at %d" % (k, last, b["ys"])
        prev_end = b["ye"]
    code.lines.append("        ret")
    assert code.t < FRAME_T - 3 * LINE_T

    pal = [rnd.randrange(256) for _ in range(912)]           # vtest.asm's palette writes, in order
    bg = [rnd.randrange(256) for _ in range(3)]
    with open(out + "/vbands.inc", "w") as f:
        f.write("; Made by vgen.py %s: do not edit\n" % variant)
        f.write("\n".join(code.lines) + "\n")
        for name, data in (("paltab", pal), ("bgtab", bg)):
            f.write("%s:\n" % name)
            for i in range(0, len(data), 16):
                f.write("        db      %s\n" % ",".join("0x%02X" % v for v in data[i:i + 16]))

    # Random picture data, 30% zero bytes (for TRANSP)
    with open(out + "/ram.hex", "w") as f:
        f.write("@%x\n" % (DATA_LO // 2))
        for _ in range(DATA_LO, DATA_HI, 2):
            lo = 0 if rnd.random() < 0.3 else rnd.randrange(256)
            hi = 0 if rnd.random() < 0.3 else rnd.randrange(256)
            f.write("%04x\n" % ((hi << 8) | lo))
    print("vgen: variant %s, %d bands" % (variant, len(B)))


if __name__ == "__main__":
    main()
