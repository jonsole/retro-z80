#!/usr/bin/env python3
"""Video test generator (spec 4; tickets #13, #14 and #31): bands of L0 settings,
or the sprite screens, palettes and random picture data for vtest.asm.

    vgen.py VARIANT OUTDIR

VARIANT is a fixed set of bands ("a": bitmaps at every depth and scale,
windows off the edges, fine scroll, negative and zero stride, pointer wrap
within a line, TRANSP, PALOFS; "t": tile maps at every depth, scale and map
size, with X and Y scroll round the map, fine scroll, TRANSP, PALOFS; "s",
"h" and "q": the sprite screens, below) or a
seed for random bands ("b", "c", ...: the same kinds of settings at random,
bitmaps and tile maps, with PRIO and BGCOLOR changed between bands). A tile
band's map and patterns are random data too, so its entries have every
TILE, PAL, XFLIP, YFLIP and PRI.
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

The sprite screens (spec 5; ticket #31) are retro68k's "spr" screen
(sim/vtest/vtest.s, -DSPRITES) narrowed: L0 a transparent 4-bit bitmap at
2 x 2 over the top of the picture and a tile map with PRI tiles below it,
and the 8 sprites, every size, depth and format, scales bigger and
smaller, clipped at every edge, overlapping (collisions). In each vertical
blank the CPU writes every sprite's registers, CTL last; then, as
retro68k's copper list does, at set lines: a VSTOP made later and one made
earlier, an image switched part way down (a PT write), a sprite reused
lower down, a sprite made twice as wide (H and XSTEP) while it is drawn, a
wobble (H on every line), and PRIO moving L0 to the middle and the back.
retro68k's sprite fed by hand (manual mode) is not here: retro-z80 has
none; sprite 2 is started again with its DMA off instead, and shows
nothing. "s" is the screen; "h" the same with VIDCON.SHAREPAL (everything
on PALETTE0); "q" a quick one: four sprites (2, 4 and 8 bits, bigger and
smaller), set in the vertical blank only.
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


def bands_t():
    """Hand-picked tile maps: every depth, scale and map size."""
    B = []
    def band(**k):
        d = dict(bpp=0, hs=0, vs=0, transp=0, palofs=0, wrap=0, xs=144, xe=864, sx=0, sy=0, stride=0, off=0,
                 mode=1, mapw=0, maph=0, mapoff=0, patoff=0)
        d.update(k)
        B.append(d)
    band(ys=53,  ye=113, bpp=3)                                                     # 8 bits, 1x, full width: 1.25 bytes a pixel
    band(ys=117, ye=177, bpp=2, hs=1, vs=1, xs=200, xe=700, sx=5, sy=250, mapw=1, transp=1, palofs=3, mapoff=0x1234)
    band(ys=181, ye=241, bpp=1, hs=2, vs=2, xs=100, xe=600, sx=0x3FD, sy=0x3F0, mapw=2, maph=2, palofs=9, patoff=0x2A)
    band(ys=245, ye=285, bpp=0, xs=300, xe=900, sx=0x123, sy=77, maph=1, transp=1, palofs=14, patoff=0x16)
    band(ys=289, ye=349, bpp=3, hs=1, xs=160, xe=860, sx=7, sy=3, mapw=1, maph=2, transp=1, mapoff=0x3E)
    band(ys=353, ye=413, bpp=2, vs=3, xs=400, xe=417, sx=15, mapw=2, palofs=15, patoff=0x7FFE)
    band(ys=417, ye=477, bpp=1, sx=3, sy=0x2FF, mapw=3, maph=3, transp=1)            # MAPW and MAPH 3: as 128
    band(ys=481, ye=541, bpp=0, vs=2, xs=150, xe=851, sx=9, sy=0x105, palofs=1, mapoff=0x7FE)
    band(ys=545, ye=625, bpp=3, hs=3, vs=3, sx=0x3F1, sy=0x1FF, mapw=1, maph=1)      # 8 bits, 8x, to the last line
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
        if rnd.random() < 0.4:                      # a tile map
            d.update(mode=1, mapw=rnd.randrange(4), maph=rnd.randrange(4), sy=rnd.randrange(1024),
                     mapoff=2 * rnd.randrange(0x8000), patoff=2 * rnd.randrange(0x8000))
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


VID_X0, VID_Y0 = 144, 49
S_DATA = 0x0A0000                # the sprite images: random data
SL0_DATA = 0x020000              # the sprite screens' L0: rows of 180 bytes
SL0_MAP, SL0_PAT = 0x040000, 0x050000


def spr_regs(n, x0, x1, y0, y1, bpp, xstep, ystep, depth, pal, img):
    """Sprite n's 16 register bytes (custom 0x010 + 16n): PT, H, V, CTL, STEP"""
    pt = S_DATA + img
    h = (VID_X0 + x0) | ((VID_X0 + x1) << 16)
    v = (VID_Y0 + y0) | ((VID_Y0 + y1) << 16)
    ctl = bpp | (depth << 2) | (pal << 4)
    st = xstep | (ystep << 16)
    b = [pt & 0xFF, (pt >> 8) & 0xFF, pt >> 16]
    b += [(h >> (8 * i)) & 0xFF for i in range(4)] + [(v >> (8 * i)) & 0xFF for i in range(4)]
    b += [ctl] + [(st >> (8 * i)) & 0xFF for i in range(4)]
    return b


def spr_write(code, n, regs, which):
    """Write sprite n's bytes `which` (offsets 0-15) in that order"""
    for k in which:
        code.write(0x010 + 16 * n + k, regs[k], "line", "SPR%d +%X" % (n, k) if k == 11 else "")


def sprites_main(variant, out, rnd):
    code = Code()
    quick = variant == "q"
    # ---- the vertical blank: L0 as a bitmap, its pointer, PRIO; every sprite, CTL last
    l0 = [(0x00, 0), (0x01, 1), (0x02, 0), (0x03, 0),
          (0x04, 864 & 0xFF), (0x05, 864 >> 8), (0x06, 144), (0x07, 0),
          (0x08, 625 & 0xFF), (0x09, 625 >> 8), (0x0A, 49), (0x0B, 0),
          (0x0C, 0), (0x0D, 0), (0x10, 180), (0x11, 0),
          (0x14, SL0_DATA & 0xFF), (0x15, (SL0_DATA >> 8) & 0xFF), (0x16, SL0_DATA >> 16),
          (0x00, 1 | (2 << 2) | (1 << 4) | (1 << 6))]       # EN, 4 bits, TRANSP, 2x across
    for o, v in l0:
        code.write(L0 + o, v, "line")
    code.write(PRIO, 0x24, "pic")
    code.write(0x120, 0xFF, "line", "SPRDMA0")
    code.write(0x121, 0x80, "line", "SPRDMA1: all on")
    if quick:
        S = [spr_regs(0, -20, 44, 30, 70, 1, 0x0800, 0x0800, 0, 3, 0x0000),     # 4 bits, off the left edge
             spr_regs(1, 100, 172, 50, 110, 2, 0x0555, 0x0400, 1, 0, 0x1000),   # 8 bits, 1.5x and 2x, behind L0
             spr_regs(2, 690, 730, 100, 140, 0, 0x1000, 0x0C00, 0, 5, 0x2000),  # 2 bits, half and 2/3, off the right
             spr_regs(3, 120, 184, 80, 120, 1, 0x0200, 0x0200, 0, 7, 0x3000)]   # 4 bits, 4x, over sprite 1
    else:
        S = [spr_regs(0, -20, 12, -10, 20, 1, 0x0800, 0x0800, 0, 3, 0x0000),    # off the left edge and the top
             spr_regs(1, 100, 148, 50, 90, 2, 0x0555, 0x0400, 1, 0, 0x1000),    # 1.5x across, 2x down, behind sprite 4
             spr_regs(2, 690, 730, 100, 140, 0, 0x1000, 0x0C00, 2, 5, 0x2000),  # off the right edge; half across, 2/3 down
             spr_regs(3, 300, 364, 300, 340, 1, 0x0200, 0x0200, 3, 7, 0x3000),  # 4x by 4x, at the back
             spr_regs(4, 90, 154, 40, 100, 2, 0x0800, 0x1800, 0, 0, 0x4000),    # 64 pixels of 8 bits; lines skipped
             spr_regs(5, 400, 418, 200, 230, 1, 0x0123, 0x8000, 1, 9, 0x6000),  # an odd step across (about 7x), 1/16 down
             spr_regs(6, 200, 500, 400, 410, 0, 0x0080, 0x0000, 0, 2, 0x7000),  # 300 wide: 16x across (the limit); YSTEP 0
             spr_regs(7, 500, 504, 560, 590, 0, 0x8000, 0x0800, 2, 4, 0x8000)]  # off the bottom; 1/16 across
    order = [12, 13, 14, 15] + list(range(11)) + [11]     # STEP, then PT, H, V, CTL last
    for n, r in enumerate(S):
        spr_write(code, n, r, order)
    if not quick:
        def at(line, px=300):
            code.wait_until((VID_Y0 + line) * LINE_T + (px * 20) // 27)
            code.lines.append("        ; picture line %d" % line)
        # sprite 0 goes on to line 29 (VSTOP later)
        at(9)
        code.write(0x010 + 0x9, (VID_Y0 + 30) & 0xFF, "line", "SPR0 VSTOP later")
        code.write(0x010 + 0xA, (VID_Y0 + 30) >> 8, "line")
        # sprite 4 ends after line 79 (VSTOP earlier)
        at(59)
        code.write(0x050 + 0x9, (VID_Y0 + 80) & 0xFF, "line", "SPR4 VSTOP earlier")
        code.write(0x050 + 0xA, (VID_Y0 + 80) >> 8, "line")
        # sprite 1 switches image from line 70
        at(69)
        pt = S_DATA + 0x8800
        for i in range(3):
            code.write(0x020 + i, (pt >> (8 * i)) & 0xFF, "line", "SPR1PT: another image" if i == 0 else "")
        # sprite 2 again, lower down, with its DMA off: started, it shows nothing
        at(142)
        code.write(0x120, 1 << 2, "line", "SPRDMA0")
        code.write(0x121, 0x00, "line", "SPRDMA1: sprite 2 off")
        r2 = spr_regs(2, 600, 616, 160, 231, 0, 0x0800, 0x0800, 0, 5, 0x2000)
        spr_write(code, 2, r2, order)
        # PRIO: L0 in the middle (DEPTH 0 and 1 in front of it)
        at(200, 400)
        code.write(PRIO, 0x23, "pic", "PRIO: L0 in the middle")
        # sprite 5 again, lower down: 2x, lines 250-269
        at(232)
        r5 = spr_regs(5, 420, 460, 250, 270, 1, 0x0400, 0x0400, 0, 6, 0x1000)
        spr_write(code, 5, r5, order)
        # L0 a tile map from line 300 (PRI tiles), off on lines 298-299
        at(297, 600)
        tl = [(0x00, 0), (0x01, 1), (0x03, 1 | (0 << 2)), (0x0C, 0x23), (0x0D, 0), (0x0E, 0x45), (0x0F, 0),
              (0x18, SL0_MAP & 0xFF), (0x19, (SL0_MAP >> 8) & 0xFF), (0x1A, SL0_MAP >> 16),
              (0x1C, SL0_PAT & 0xFF), (0x1D, (SL0_PAT >> 8) & 0xFF), (0x1E, SL0_PAT >> 16)]
        for o, v in tl:
            code.write(L0 + o, v, "line", "L0: a tile map from line 300" if o == 0 and v == 0 else "")
        code.write(L0 + 0x00, 1 | (2 << 2) | (1 << 4) | (1 << 5) | (1 << 6), "line", "L0 on: tiles, 4 bits, TRANSP, 2x")
        # sprite 3 from line 320: 2x across, twice as wide, while it is drawn
        at(319)
        h = (VID_X0 + 300) | ((VID_X0 + 428) << 16)
        for i in range(4):
            code.write(0x040 + 3 + i, (h >> (8 * i)) & 0xFF, "line", "SPR3H: wider" if i == 0 else "")
        code.write(0x040 + 0xC, 0x00, "line", "SPR3 XSTEP 0x0400")
        code.write(0x040 + 0xD, 0x04, "line")
        # a wobble: sprite 6 three pixels further right on each line from 401
        for k in range(1, 10):
            at(399 + k, 200)
            h = (VID_X0 + 200 + 3 * k) | ((VID_X0 + 500 + 3 * k) << 16)
            for i in range(4):
                code.write(0x070 + 3 + i, (h >> (8 * i)) & 0xFF, "line", "SPR6H: wobble" if i == 0 else "")
        # PRIO: L0 at the back (DEPTH 0-2 in front of it, behind PRI tiles but for DEPTH 0)
        at(450, 400)
        code.write(PRIO, 0x0F, "pic", "PRIO: L0 at the back")
    code.lines.append("        ret")
    assert code.t < FRAME_T - 3 * LINE_T

    pal = [rnd.randrange(256) for _ in range(912)]           # vtest.asm's palette writes, in order
    spal = [rnd.randrange(256) for _ in range(240 * 3)]       # SPRPALETTE 16-255
    bg = [rnd.randrange(256) for _ in range(3)]
    with open(out + "/vbands.inc", "w") as f:
        f.write("; Made by vgen.py %s: do not edit\n" % variant)
        f.write("VIDCON_VAL equ 0x%02X\n" % (0x21 if variant == "h" else 0x01))
        f.write("setup:  ld      hl,spaltab\n        ld      de,W3+REGS_SPRPALETTE+16*3\n"
                "        ld      bc,240*3\n        ldir\n        ret\n")
        f.write("\n".join(code.lines) + "\n")
        for name, data in (("paltab", pal), ("spaltab", spal), ("bgtab", bg)):
            f.write("%s:\n" % name)
            for i in range(0, len(data), 16):
                f.write("        db      %s\n" % ",".join("0x%02X" % v for v in data[i:i + 16]))
    # Random picture data, 30% zero bytes (TRANSP, and transparent sprite pixels)
    with open(out + "/ram.hex", "w") as f:
        f.write("@%x\n" % (DATA_LO // 2))
        for _ in range(DATA_LO, DATA_HI, 2):
            lo = 0 if rnd.random() < 0.3 else rnd.randrange(256)
            hi = 0 if rnd.random() < 0.3 else rnd.randrange(256)
            f.write("%04x\n" % ((hi << 8) | lo))
    print("vgen: variant %s, the sprite screen" % variant)


def main():
    variant, out = sys.argv[1], sys.argv[2]
    rnd = random.Random("retro-z80 vtest " + variant)
    if variant in ("s", "h", "q"):
        sprites_main(variant, out, rnd)
        return
    B = bands_a() if variant == "a" else bands_t() if variant == "t" else bands_random(rnd)

    # Each band's data in the random area: its own 64 KB for the fixed bands;
    # random bands start in the middle (0x060000-0x09FFFF), so 90 lines at
    # any stride stay inside it
    for k, b in enumerate(B):
        b["ptr"] = (DATA_LO + k * 0x10000 if variant == "a" else 0x060000 + (k % 4) * 0x10000) + b["off"]
        # Tiles: a map of up to 32 KB and patterns of up to 32 KB, each in its own 64 KB
        if variant == "t":
            b["mappt"] = DATA_LO + k * 0x10000 + b.get("mapoff", 0)
            b["patpt"] = DATA_LO + k * 0x10000 + 0x8000 + b.get("patoff", 0)
        else:
            b["mappt"] = 0x040000 + b.get("mapoff", 0)
            b["patpt"] = 0x080000 + b.get("patoff", 0)

    code = Code()
    prev_end = 0
    for k, b in enumerate(B):
        code.wait_until(prev_end * LINE_T + 45)
        assert code.px(code.t) < 200
        code.lines.append("        ; band %d: %s" % (k, b))
        tile = b.get("mode", 0)
        ctrl0 = 1 | (b["bpp"] << 2) | (b["transp"] << 4) | (tile << 5) | (b["hs"] << 6)
        code.write(L0 + 0x00, 0, "line", "L0 off")
        code.write(L0 + 0x01, b["vs"] | (b["palofs"] << 4), "line")
        code.write(L0 + 0x02, b["wrap"] << 4, "line")
        if tile:
            code.write(L0 + 0x03, b["mapw"] | (b["maph"] << 2), "line")
        for i, v in enumerate([b["xe"], b["xs"], b["ye"], b["ys"]]):
            code.write(L0 + 0x04 + 2 * i, v & 0xFF, "line")
            code.write(L0 + 0x05 + 2 * i, v >> 8, "line")
        code.write(L0 + 0x0C, b["sx"] & 0xFF, "line")
        code.write(L0 + 0x0D, b["sx"] >> 8, "line")
        if tile:
            code.write(L0 + 0x0E, b["sy"] & 0xFF, "line")
            code.write(L0 + 0x0F, b["sy"] >> 8, "line")
            for i in range(3):
                code.write(L0 + 0x18 + i, (b["mappt"] >> (8 * i)) & 0xFF, "line")
            for i in range(3):
                code.write(L0 + 0x1C + i, (b["patpt"] >> (8 * i)) & 0xFF, "line")
        else:
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
        f.write("VIDCON_VAL equ 0x01\nsetup:  ret\n")
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
