"""Figures for Chapter 6, Blitter and Rasteriser Hardware (docs/guide/blitter.md).

Run as `python blitter.py` from this directory. Everything the hardware works
out (minterm results, the cookie-cut, Bresenham's pixels, the pattern, the
triangle's spans) is worked out here from the rules in specs 14 and 19, not
drawn by hand.
"""

import math

from svgfig import (Fig, TXT, TXT2, LINE, DIM, BLANK, PICTURE, CPU, DISPLAY, POOL,
                    SPRITE, HILITE, UNSHOWN, WHITE)

# Spectrum-style colours for pixel pictures
BLACK = "#000000"
BLUE = "#0000d7"
RED = "#d70000"
MAGENTA = "#d700d7"
GREEN = "#00d700"
CYAN = "#00d7d7"
YELLOW = "#d7d700"
SWHITE = "#d7d7d7"
BRIGHTWHITE = "#ffffff"
KEYFILL = "url(#hatch)"


def add_hatch(f):
    f.defs.append(
        '<pattern id="hatch" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">'
        f'<rect width="6" height="6" fill="{UNSHOWN}"/><line x1="0" y1="0" x2="0" y2="6" stroke="#bbbbbb" stroke-width="2"/></pattern>'
    )


def arrowhead(f, x1, y1, x2, y2, fill=LINE, size=8):
    """A filled arrowhead at (x2, y2), pointing from (x1, y1)."""
    a = math.atan2(y2 - y1, x2 - x1)
    p1 = (x2 - size * math.cos(a - 0.4), y2 - size * math.sin(a - 0.4))
    p2 = (x2 - size * math.cos(a + 0.4), y2 - size * math.sin(a + 0.4))
    f.poly([(x2, y2), p1, p2], fill=fill, stroke="none")


# ---------------------------------------------------------------- 6-3: minterm
def fig_minterm():
    f = Fig(760, 330)
    f.text(20, 22, "Each bit of MINTERM is one region: bit = A × 4 + B × 2 + C", bold=True)
    R = 78
    centres = {"A": (118, 128), "B": (212, 128), "C": (165, 208)}
    box = (10, 40, 310, 280)

    def inside(name, x, y):
        cx, cy = centres[name]
        return (x - cx) ** 2 + (y - cy) ** 2 < R * R

    def bitof(x, y):
        return inside("A", x, y) * 4 + inside("B", x, y) * 2 + inside("C", x, y)

    def name(bit):
        return "".join(L if bit & m else L.lower() for L, m in (("A", 4), ("B", 2), ("C", 1)))

    cookie = (0xF0 & 0xCC) | (~0xF0 & 0xAA & 0xFF)

    # shade the regions where cookie-cut (A ? B : C) gives 1, with clip paths and masks
    bx, by, bw, bh = box
    for L, (cx, cy) in centres.items():
        f.defs.append(f'<clipPath id="in{L}"><circle cx="{cx}" cy="{cy}" r="{R}"/></clipPath>')
    for bit in range(8):
        if not (cookie >> bit) & 1:
            continue
        ins = [L for L, m in (("A", 4), ("B", 2), ("C", 1)) if bit & m]
        outs = [L for L, m in (("A", 4), ("B", 2), ("C", 1)) if not bit & m]
        # chain the clip paths for the circles it is inside
        clip = None
        for i, L in enumerate(ins):
            cid = f"r{bit}c{i}"
            cx, cy = centres[L]
            chain = f' clip-path="url(#{clip})"' if clip else ""
            f.defs.append(f'<clipPath id="{cid}"{chain}><circle cx="{cx}" cy="{cy}" r="{R}"/></clipPath>')
            clip = cid
        m = f'<mask id="r{bit}m"><rect x="{bx}" y="{by}" width="{bw}" height="{bh}" fill="#fff"/>'
        for L in outs:
            cx, cy = centres[L]
            m += f'<circle cx="{cx}" cy="{cy}" r="{R}" fill="#000"/>'
        f.defs.append(m + "</mask>")
        cp = f' clip-path="url(#{clip})"' if clip else ""
        f.raw(f'<rect x="{bx}" y="{by}" width="{bw}" height="{bh}" fill="{HILITE}" mask="url(#r{bit}m)"{cp}/>')
    f.rect(*box, fill="none")
    for L, (cx, cy) in centres.items():
        f.circle(cx, cy, R, fill="none", sw=1.5)
    for L, (lx, ly) in (("A", (50, 66)), ("B", (280, 66)), ("C", (165, 302))):
        f.text(lx, ly, L, size=17, bold=True, anchor="middle")

    # label each region at the centre of its points (worked out by sampling)
    acc = {b: [0, 0, 0] for b in range(8)}
    for y in range(by + 4, by + bh - 4, 2):
        for x in range(bx + 4, bx + bw - 4, 2):
            b = bitof(x, y)
            acc[b][0] += x
            acc[b][1] += y
            acc[b][2] += 1
    for b in range(8):
        sx, sy, n = acc[b]
        x, y = sx / n, sy / n
        if b == 0:
            x, y = bx + 34, by + bh - 26
        f.text(x, y - 1, str(b), size=15, bold=True, anchor="middle")
        f.text(x, y + 13, name(b), size=11, anchor="middle", fill=TXT2)

    # the strip: A, B, C and the cookie-cut as 8-bit rows
    SX, SY, CW, RH = 404, 70, 36, 26
    f.text(SX - 70, SY - 22, "The quick rule, bit 7 on the left:", size=13)
    rows = [("bit", None), ("", None), ("A", 0xF0), ("B", 0xCC), ("C", 0xAA), ("A ? B : C", cookie)]
    for c in range(8):
        bit = 7 - c
        x = SX + c * CW
        f.text(x + CW / 2, SY + 4, str(bit), size=13, bold=True, anchor="middle")
        f.text(x + CW / 2, SY + 22, name(bit), size=11, anchor="middle", fill=TXT2)
    y0 = SY + 34
    for r, (lab, v) in enumerate(rows[2:]):
        y = y0 + r * RH + (10 if r == 3 else 0)
        f.text(SX - 8, y + 18, lab, size=13, anchor="end", bold=(r == 3))
        for c in range(8):
            bit = (v >> (7 - c)) & 1
            fill = (HILITE if r == 3 else PICTURE) if bit else WHITE
            f.rect(SX + c * CW, y, CW, RH, fill)
            f.text(SX + c * CW + CW / 2, y + 18, str(bit), size=13, anchor="middle")
        f.text(SX + 8 * CW + 8, y + 18, f"0x{v:02X}", size=13, bold=(r == 3))
    yl = y0 + 3 * RH + 4
    f.line(SX - 70, yl + 1, SX + 8 * CW + 46, yl + 1, stroke=DIM)
    yb = y0 + 4 * RH + 30
    f.text(SX - 80, yb, "Each column is one region of the circles: the column's", size=11, fill=TXT2)
    f.text(SX - 80, yb + 15, "A, B and C bits say which circles it is inside.", size=11, fill=TXT2)
    f.text(SX - 80, yb + 37, "Shaded: the regions where A ? B : C (0xCA) gives 1.", size=11, fill=TXT2)
    f.text(SX - 80, yb + 52, "(0xF0 & 0xCC) | (~0xF0 & 0xAA) = 0xC0 | 0x0A = 0xCA", size=11, fill=TXT2)
    return f.save("blitter-6-3-minterm.svg")


# ---------------------------------------------------------------- 6-4: cookie-cut
def fig_cookiecut():
    f = Fig(760, 300)
    add_hatch(f)
    N, P = 8, 15
    KEY = 0
    pal = {0: KEYFILL, 1: BLUE, 2: RED, 3: MAGENTA, 4: GREEN, 5: CYAN, 6: YELLOW, 7: BRIGHTWHITE}
    # B: a ball, colour 0 (the key) round it
    B = [[0] * N for _ in range(N)]
    for y in range(N):
        for x in range(N):
            d = math.hypot(x - 3.5, y - 3.5)
            if d < 2.2:
                B[y][x] = 2  # red
            elif d < 3.1:
                B[y][x] = 6  # yellow rim
    B[2][2] = 7
    B[2][3] = 7
    B[3][2] = 7
    # A: compare B with the key colour (MASK = 2)
    A = [[1 if B[y][x] != KEY else 0 for x in range(N)] for y in range(N)]
    # C: the background, stripes two rows deep
    C = [[1 if (y // 2) % 2 == 0 else 5 for x in range(N)] for y in range(N)]
    # D: the minterm 0xCA, bit by bit on 8-bit pixels (A widened to 8 bits)
    MT = 0xCA

    def minterm(m, a, b, c):
        d = 0
        for i in range(8):
            ai, bi, ci = (a >> i) & 1, (b >> i) & 1, (c >> i) & 1
            d |= ((m >> (ai * 4 + bi * 2 + ci)) & 1) << i
        return d

    D = [[minterm(MT, 0xFF if A[y][x] else 0, B[y][x], C[y][x]) for x in range(N)] for y in range(N)]
    for y in range(N):
        for x in range(N):
            assert D[y][x] == (B[y][x] if A[y][x] else C[y][x])

    G = N * P
    xs = [30, 214, 398, 582]
    T = 74

    def grid(x0, img, colours):
        for y in range(N):
            for x in range(N):
                f.rect(x0 + x * P, T + y * P, P, P, colours(img[y][x]), stroke="#999", sw=0.5)
        f.rect(x0, T, G, G, "none", sw=1.5)

    f.text(20, 22, "MASK = 2 and MINTERM 0xCA: draw B except where it is the key colour", bold=True)
    grid(xs[0], B, lambda v: pal[v])
    grid(xs[1], A, lambda v: BLACK if v else WHITE)
    grid(xs[2], C, lambda v: pal[v])
    grid(xs[3], D, lambda v: pal[v])
    heads = [("B", "the image (BLTBPT)"), ("A", "the mask"), ("C", "the background (BLTDPT)"), ("D = A ? B : C", "written to BLTDPT")]
    for x0, (h, s) in zip(xs, heads):
        f.text(x0 + G / 2, T - 24, h, size=15, bold=True, anchor="middle")
        f.text(x0 + G / 2, T - 9, s, size=11, anchor="middle", fill=TXT2)
    # arrows between
    ya = T + G / 2
    f.line(xs[0] + G + 6, ya, xs[1] - 6, ya, stroke=DIM, arrow="end")
    f.text((xs[0] + G + xs[1]) / 2, ya - 8, "compare", size=11, anchor="middle")
    f.text((xs[0] + G + xs[1]) / 2, ya + 16, "with key", size=11, anchor="middle")
    f.text((xs[2] + G + xs[3]) / 2, ya + 6, "→", size=22, anchor="middle")
    # notes
    yb = T + G + 26
    f.text(xs[0], yb, "MASK = 2 (the key colour in KEY):", size=13)
    f.text(xs[0], yb + 17, "A is 1 where B ≠ KEY, 0 where B = KEY", size=11, fill=TXT2)
    f.text(xs[3] + G / 2, yb, "MINTERM 0xCA", size=13, anchor="middle")
    f.text(xs[3] + G / 2, yb + 17, "where A is 0, the old", size=11, anchor="middle", fill=TXT2)
    f.text(xs[3] + G / 2, yb + 31, "pixel C is written back", size=11, anchor="middle", fill=TXT2)
    # legend
    yl = yb + 56
    f.rect(xs[0], yl - 11, 14, 14, KEYFILL, stroke="#999")
    f.text(xs[0] + 20, yl, "the key colour, 0 (KEY = 0)", size=11)
    f.rect(xs[1] + 60, yl - 11, 14, 14, BLACK)
    f.text(xs[1] + 80, yl, "A = 1", size=11)
    f.rect(xs[1] + 130, yl - 11, 14, 14, WHITE)
    f.text(xs[1] + 150, yl, "A = 0", size=11)
    return f.save("blitter-6-4-cookiecut.svg")


# ---------------------------------------------------------------- 6-5: shift
def fig_shift():
    f = Fig(760, 372)
    BPP = 4
    PPB = 8 // BPP           # pixels a byte
    X = 101                  # where the image goes
    NPIX = 8                 # the image's pixels in a row
    DPT, DBIT = X // PPB, X % PPB
    last = X + NPIX - 1
    first_b, last_b = DPT, last // PPB
    BW = 84                  # a byte's width in the drawing
    PW = BW / PPB
    f.text(20, 22, f"An image of {NPIX} pixels drawn at x = {X}, at {BPP} bpp (two pixels a byte)", bold=True)

    # source row
    SL, ST = 200, 66
    f.text(SL - 12, ST + 24, "the image:", anchor="end")
    f.text(SL - 12, ST + 39, "BLTBPT, BBIT = 0", size=11, anchor="end", fill=TXT2)
    for b in range(NPIX // PPB):
        for p in range(PPB):
            i = b * PPB + p
            f.rect(SL + b * BW + p * PW, ST, PW, 34, HILITE, stroke="#999", sw=0.5)
            f.text(SL + b * BW + p * PW + PW / 2, ST + 22, f"i{i}", size=13, anchor="middle")
        f.rect(SL + b * BW, ST, BW, 34, "none", sw=1.5)
        f.text(SL + b * BW + BW / 2, ST - 6, f"BLTBPT + {b}", size=11, anchor="middle", fill=TXT2)

    # screen row
    DL, DT = 40, 214
    bytes_shown = range(first_b - 1, last_b + 2)
    for k, b in enumerate(bytes_shown):
        x0 = DL + k * BW
        for p in range(PPB):
            x = b * PPB + p
            img = X <= x <= last
            f.rect(x0 + p * PW, DT, PW, 34, HILITE if img else PICTURE, stroke="#999", sw=0.5)
            f.text(x0 + p * PW + PW / 2, DT + 22, f"i{x - X}" if img else "", size=13, anchor="middle")
            f.text(x0 + p * PW + PW / 2, DT - 8, str(x), size=11, anchor="middle", fill=TXT2)
        f.rect(x0, DT, BW, 34, "none", sw=1.5)
        f.text(x0 + BW / 2, DT + 52, f"byte {b}", size=11, anchor="middle")
        # what happens to the byte
        if b < first_b or b > last_b:
            what = "untouched"
        elif b in (first_b, last_b):
            what = "edge"
        else:
            what = "whole"
        if what == "untouched":
            f.text(x0 + BW / 2, DT + 68, "untouched", size=11, anchor="middle", fill=TXT2)
    f.text(DL - 4, DT - 24, "pixel x:", size=11, fill=TXT2)
    # lines from image pixels to screen pixels
    for i in range(NPIX):
        sx = SL + (i // PPB) * BW + (i % PPB) * PW + PW / 2
        x = X + i
        k = x // PPB - (first_b - 1)
        dx = DL + k * BW + (x % PPB) * PW + PW / 2
        f.line(sx, ST + 36, dx, DT - 20, stroke=DIM, sw=0.8)
    # brackets for the edge bytes and the middle bytes
    yb = DT + 80
    kf, kl = 1, last_b - first_b + 1
    for k in (kf, kl):
        x0 = DL + k * BW
        f.line(x0 + 2, yb, x0 + BW - 2, yb, stroke=RED, sw=2)
    f.line(DL + (kf + 1) * BW + 2, yb, DL + kl * BW - 2, yb, stroke=LINE, sw=2)
    f.text(DL + (kf + 0.5) * BW, yb + 17, "read, merged,", size=11, anchor="middle")
    f.text(DL + (kf + 0.5) * BW, yb + 31, "written back", size=11, anchor="middle")
    f.text(DL + (kl + 0.5) * BW, yb + 17, "read, merged,", size=11, anchor="middle")
    f.text(DL + (kl + 0.5) * BW, yb + 31, "written back", size=11, anchor="middle")
    f.text(DL + (kf + 1 + kl) / 2 * BW, yb + 17, "written whole", size=11, anchor="middle")
    f.text(DL + (kf + 1 + kl) / 2 * BW, yb + 31, "(not read)", size=11, anchor="middle", fill=TXT2)
    # DPT, DBIT
    xd = DL + kf * BW + DBIT * PW
    f.text(DL + kf * BW - 30, DT - 70, f"BLTDPT = byte {DPT}, DBIT = {DBIT}", size=13, anchor="middle", bold=True, halo=True)
    f.line(DL + kf * BW - 30, DT - 64, xd + 2, DT - 36, stroke=DIM, arrow="end")
    f.text(20, 362, f"x = {X}: BLTDPT = SCREEN + {X} / 2, with DBIT = {X} mod 2 in bits 26–24. WIDTH = {NPIX}. High nibble = left pixel.", size=11, fill=TXT2)
    return f.save("blitter-6-5-shift.svg")


# ---------------------------------------------------------------- 6-6: stride
def fig_stride():
    f = Fig(760, 420)
    f.text(20, 22, "8 bpp, drawn to scale: one square = one byte = one pixel", bold=True)
    # sprite sheet: 128 bytes a row, 3 rows of 32 x 32 images
    SL, ST, SW, SH = 40, 96, 128, 96
    f.rect(SL, ST, SW, SH, UNSHOWN)
    for c in range(1, 4):
        f.line(SL + c * 32, ST, SL + c * 32, ST + SH, stroke="#ccc")
    for r in range(1, 3):
        f.line(SL, ST + r * 32, SL + SW, ST + r * 32, stroke="#ccc")
    IX, IY = SL + 64, ST + 32
    f.rect(IX, IY, 32, 32, HILITE, sw=1.5)
    f.rect(SL, ST, SW, SH, "none", sw=1.5)
    f.text(SL + SW / 2, ST - 46, "a sprite sheet", anchor="middle", bold=True)
    f.dim(SL, SL + SW, ST - 10, "BSTRIDE = 128")
    f.circle(IX, IY, 3, fill=LINE)
    f.line(IX - 4, IY - 4, SL + 30, ST + SH + 30, stroke=DIM)
    f.text(SL + 26, ST + SH + 44, "BLTBPT: the image's first pixel", size=11)
    f.text(SL, ST + SH + 64, "row r + 1 of the image starts", size=11, fill=TXT2)
    f.text(SL, ST + SH + 78, "BSTRIDE bytes after row r", size=11, fill=TXT2)

    # screen: 360 x 288
    L, T, W, H = 290, 96, 360, 288
    f.rect(L, T, W, H, PICTURE, sw=1.5)
    f.text(L + W / 2, T - 46, "the screen", anchor="middle", bold=True)
    f.dim(L, L + W, T - 10, "DSTRIDE = 360")
    DX, DY = 200, 56
    f.rect(L + DX, T + DY, 32, 32, HILITE, sw=1.5)
    f.circle(L + DX, T + DY, 3, fill=LINE)
    f.text(L + DX - 6, T + DY - 6, "BLTDPT", size=11, anchor="end", halo=True)
    f.dim(L + DX, L + DX + 32, T + DY + 46, "WIDTH = 32", above=False, fill=TXT)
    f.line(L + DX, T + DY + 34, L + DX, T + DY + 50, stroke=DIM)
    f.line(L + DX + 32, T + DY + 34, L + DX + 32, T + DY + 50, stroke=DIM)
    f.vdim(L + DX + 46, T + DY, T + DY + 32, "HEIGHT = 32", left=False, fill=TXT)
    f.line(L + DX + 34, T + DY, L + DX + 50, T + DY, stroke=DIM)
    f.line(L + DX + 34, T + DY + 32, L + DX + 50, T + DY + 32, stroke=DIM)
    f.line(IX + 32, IY + 16, L + DX - 2, T + DY + 16, stroke=DIM, dash="4 3", arrow="end")
    # clipping at the left edge
    K = 12
    CX, CY = -K, 190
    f.rect(L + CX, T + CY, K, 32, WHITE, dash="4 3")
    f.rect(L, T + CY, 32 - K, 32, HILITE, sw=1.5)
    f.circle(L, T + CY, 3, fill=LINE)
    f.text(L + 26, T + CY + 14, "new BLTDPT", size=11, halo=True)
    f.text(L + 26, T + CY + 28, f"WIDTH = 32 − k = {32 - K}", size=11, halo=True)
    f.line(L + CX, T + CY + 40, L, T + CY + 40, stroke=DIM, arrow="both")
    f.text(L + CX - 4, T + CY + 44, f"k = {K}", size=11, anchor="end")
    f.text(L - 18, T + CY + 4, "off the left edge", size=11, anchor="end")
    f.text(L - 18, T + CY + 18, "by k pixels:", size=11, anchor="end")
    f.text(L - 18, T + CY + 66, "BLTBPT, BLTDPT + k,", size=11, anchor="end")
    f.text(L - 18, T + CY + 80, "WIDTH − k", size=11, anchor="end")
    f.text(L + W + 6, T + H, "288", size=11, fill=TXT2)
    return f.save("blitter-6-6-stride.svg")


# ---------------------------------------------------------------- 6-7: overlap
def fig_desc():
    f = Fig(760, 410)
    ROWS, SRC, DST, NR = 7, 0, 2, 4      # rows shown; source rows 0-3 copied to rows 2-5
    names = ["a", "b", "c", "d"]
    cols = {"a": "#f4b183", "b": "#ffe599", "c": "#b6d7a8", "d": "#9fc5e8", ".": UNSHOWN}
    RH, CW = 32, 60

    def run(desc):
        mem = names + ["."] * (ROWS - NR)
        order = list(range(NR))[::-1] if desc else list(range(NR))
        steps = []
        for i in order:
            mem[DST + i] = mem[SRC + i]
            steps.append(i)
        return mem, steps

    def panel(x0, desc):
        before = names + ["."] * (ROWS - NR)
        after, steps = run(desc)
        T = 112
        head = "rows bottom-up (strides < 0)" if desc else "rows top-down (strides > 0)"
        f.text(x0, 50, head, size=15, bold=True)
        sub = (["the pointers name the last row;", "every row is read before it is written: correct"] if desc else
               ["rows already written are read again:", "the top two rows smear down"])
        f.text(x0, 67, sub[0], size=11, fill=TXT2)
        f.text(x0, 81, sub[1], size=11, fill=TXT2)
        bx = x0 + 118
        ax = bx + CW + 100
        f.text(bx + CW / 2, T - 8, "before", size=11, anchor="middle")
        f.text(ax + CW / 2, T - 8, "after", size=11, anchor="middle")
        ok = after[DST:DST + NR] == names
        for r in range(ROWS):
            y = T + r * RH
            f.text(bx - 82 - 6, y + 20, f"row {r}", size=11, anchor="end", fill=TXT2)
            for x, v, a in ((bx, before[r], False), (ax, after[r], True)):
                f.rect(x, y, CW, RH, cols[v])
                wrong = a and DST <= r < DST + NR and v != names[r - DST]
                if wrong:
                    f.rect(x + 1.5, y + 1.5, CW - 3, RH - 3, "none", stroke=RED, sw=2)
                    f.text(x + CW / 2, y + 20, f"{v}, not {names[r - DST]}", size=12, anchor="middle", fill=RED)
                else:
                    f.text(x + CW / 2, y + 21, v if v != "." else "", size=14, anchor="middle")
        # brackets: source and destination
        def bracket(x, r0, r1, lab):
            y0, y1 = T + r0 * RH + 3, T + (r1 + 1) * RH - 3
            f.line(x, y0, x, y1, stroke=LINE, sw=1.5)
            f.line(x - 5, y0, x, y0, stroke=LINE, sw=1.5)
            f.line(x - 5, y1, x, y1, stroke=LINE, sw=1.5)
            f.text(x + 5, (y0 + y1) / 2 + 4, lab, size=11)
        bracket(bx + CW + 12, SRC, SRC + NR - 1, "source")
        bracket(bx + CW + 62, DST, DST + NR - 1, "dest.")
        # copy steps on the left: arrows from source row to destination row, numbered in order
        for n, i in enumerate(steps):
            x = bx - 12 - 16 * (NR - 1 - i)
            y1 = T + (SRC + i) * RH + RH / 2
            y2 = T + (DST + i) * RH + RH / 2 - 2
            y2 += 2
            f.line(x, y1, bx - 2, y1, stroke=DIM)
            f.line(x, y1, x, y2, stroke=DIM)
            f.line(x, y2, bx - 2, y2, stroke=DIM, arrow="end")
            f.text(x - 3, y1 + RH / 2 + 4, str(n + 1), size=11, anchor="end", bold=True)
        f.text(bx - 46, T + ROWS * RH + 20, "copy order", size=11, anchor="middle", fill=TXT2)
        return ok

    assert not panel(30, False)
    assert panel(404, True)
    f.line(388, 40, 388, 370, stroke="#ccc")
    f.text(20, 22, "Copying rows 0–3 two rows down, onto themselves", bold=True)
    f.text(20, 398, "Within a row it is the same: a destination to the right of its source, in the same rows, needs RTL.", size=11, fill=TXT2)
    return f.save("blitter-6-7-overlap.svg")


# ---------------------------------------------------------------- 6-2: chain
def fig_chain():
    f = Fig(760, 360)
    f.text(20, 22, "A chain of descriptors (Example 6-2): restore, save, draw", bold=True)
    jobs = [
        ("restore", [("BLTCTRL", "0xCC, 8 bpp"), ("BLTBPT", "SAVE"), ("BLTDPT", "oldpos"), ("…", "SIZE … VALUE"), ("BLTNEXT", "save")]),
        ("save", [("BLTCTRL", "0xCC, 8 bpp"), ("BLTBPT", "newpos1"), ("BLTDPT", "SAVE"), ("…", "SIZE … VALUE"), ("BLTNEXT", "draw")]),
        ("draw", [("BLTCTRL", "0xCA, MASKKEY"), ("BLTBPT", "ball"), ("BLTDPT", "newpos2"), ("…", "SIZE … VALUE"), ("BLTNEXT", "0")]),
    ]
    offs = ["+0x00", "+0x04", "+0x08", "+0x0C", "+0x1C"]
    BW, RH = 222, 28
    xs = [20, 269, 518]
    T = 140
    f.rect(30, 48, 170, 52, POOL)
    f.text(40, 66, "the blitter", size=11, fill=TXT2)
    f.text(40, 88, "BLTDESC = restore", size=13, bold=True)
    f.text(214, 70, "then START", size=11)
    f.text(214, 84, "in BLTCMD", size=11)
    f.line(90, 100, 90, T - 22, stroke=DIM, arrow="end")
    for k, (lab, rows) in enumerate(jobs):
        x = xs[k]
        f.text(x, T - 8, f"{lab}:", size=13, bold=True)
        f.text(x + BW, T - 8, "32 bytes", size=11, anchor="end", fill=TXT2)
        for r, (n, v) in enumerate(rows):
            y = T + r * RH
            last = r == len(rows) - 1
            f.rect(x, y, BW, RH, HILITE if last else (UNSHOWN if n == "…" else WHITE))
            f.text(x + 5, y + 18, offs[r], size=11, fill=TXT2)
            f.text(x + 48, y + 18, n if n != "…" else "", size=11)
            f.text(x + 112 if n != "…" else x + 48, y + 18, v, size=11, bold=last)
        f.rect(x, T, BW, len(rows) * RH, "none", sw=1.5)
        if k < 2:
            yn = T + (len(rows) - 0.5) * RH
            f.line(x + BW, yn, x + BW + 18, yn, stroke=DIM)
            f.line(x + BW + 18, yn, x + BW + 18, T - 30, stroke=DIM)
            f.line(x + BW + 18, T - 30, xs[k + 1] + 30, T - 30, stroke=DIM)
            f.line(xs[k + 1] + 30, T - 30, xs[k + 1] + 30, T - 22, stroke=DIM, arrow="end")
    yb = T + 5 * RH + 30
    f.text(xs[2], yb, "BLTNEXT = 0: the end.", size=13)
    f.text(xs[2], yb + 17, "BUSY clears, DMXINT.BLT sets", size=11, fill=TXT2)
    f.text(30, yb, "Each descriptor is 32 bytes at an even address in SRAM;", size=11, fill=TXT2)
    f.text(30, yb + 15, "loading one costs 16 memory reads.", size=11, fill=TXT2)
    f.text(30, yb + 37, "The blitter loads each into its job registers, runs it,", size=11, fill=TXT2)
    f.text(30, yb + 52, "then loads the one at BLTNEXT.", size=11, fill=TXT2)
    return f.save("blitter-6-2-chain.svg")


# ---------------------------------------------------------------- 6-8: Bresenham
def line_pixels(x0, y0, x1, y1):
    """A LINE job's pixels (spec 19, section 5.3), with err at each one."""
    dx, dy = abs(x1 - x0), abs(y1 - y0)
    sx = 1 if x1 >= x0 else -1
    sy = 1 if y1 >= y0 else -1
    xmajor = dx >= dy
    major, minor = max(dx, dy), min(dx, dy)
    err = major // 2
    x, y = x0, y0
    out = []
    for i in range(major + 1):
        out.append((x, y, err))
        err -= minor
        if err < 0:
            err += major
            if xmajor:
                y += sy
            else:
                x += sx
        if xmajor:
            x += sx
        else:
            y += sy
    assert out[-1][:2] == (x1, y1)
    return out, major, minor


# the spec's worked line (spec 19, section 5.4)
assert [p[:2] for p in line_pixels(2, 1, 9, 4)[0]] == [(2, 1), (3, 1), (4, 2), (5, 2), (6, 3), (7, 3), (8, 4), (9, 4)]


def fig_bresenham():
    f = Fig(760, 430)
    pix, major, minor = line_pixels(0, 0, 10, 4)
    f.text(20, 22, f"A LINE from (0, 0) to (10, 4): x is the longer axis, major = {major}, minor = {minor}", bold=True)
    P = 46
    L, T = 70, 70
    cols, rows = 11, 5
    for y in range(rows):
        for x in range(cols):
            f.rect(L + x * P, T + y * P, P, P, WHITE, stroke="#ccc")
    for n, (x, y, e) in enumerate(pix):
        f.rect(L + x * P, T + y * P, P, P, HILITE, stroke=LINE)
        f.text(L + x * P + 5, T + y * P + 15, str(n + 1), size=12, bold=True)
    for x in range(cols):
        f.text(L + x * P + P / 2, T - 8, str(x), size=11, anchor="middle", fill=TXT2)
    for y in range(rows):
        f.text(L - 8, T + y * P + P / 2 + 4, str(y), size=11, anchor="end", fill=TXT2)
    f.text(L - 8, T - 8, "y \\ x", size=11, anchor="end", fill=TXT2)
    f.line(L + P / 2, T + P / 2, L + 10.5 * P, T + 4.5 * P, stroke=BLUE, sw=1)
    ye = T + rows * P + 22
    f.text(L - 8, ye, "err", size=13, anchor="end", bold=True)
    for n, (x, y, e) in enumerate(pix):
        f.text(L + x * P + P / 2, ye, str(e).replace("-", "−"), size=13, anchor="middle")
        if n < len(pix) - 1:
            f.text(L + x * P + P / 2, ye + 16, "+y" if e - minor < 0 else "", size=11, anchor="middle", fill=RED)
    f.text(L + cols * P + 8, ye + 16, "a step in y too", size=11, fill=RED)
    yb = ye + 48
    f.text(L, yb, f"err starts at major ÷ 2 = {major // 2}", size=13)
    f.text(L, yb + 18, f"{major + 1} pixels: both ends are written", size=13)
    f.text(L, yb + 36, "(NOLAST leaves out the last)", size=13)
    f.text(L + 330, yb, "After each pixel:", size=11, fill=TXT2)
    f.text(L + 330, yb + 15, f"err − minor (err − {minor});", size=11, fill=TXT2)
    f.text(L + 330, yb + 30, f"below 0: err + major (+ {major}), and step y;", size=11, fill=TXT2)
    f.text(L + 330, yb + 45, "then step x", size=11, fill=TXT2)
    return f.save("blitter-6-8-bresenham.svg")


# ---------------------------------------------------------------- 6-9: clip and pattern
def fig_clip():
    f = Fig(760, 460)
    GW, GH, P = 40, 16, 15
    L, T = 116, 100
    XMIN, XMAX, YMIN, YMAX = 3, 26, 2, 11
    PATTERN = 0xF0F0
    pix, major, minor = line_pixels(6, 4, 37, 14)
    f.text(20, 22, f"A dashed line (RASPAT 0x{PATTERN:04X}, MINTERM 0xCA) that leaves the clip window", bold=True)
    for y in range(GH):
        for x in range(GW):
            f.rect(L + x * P, T + y * P, P, P, WHITE, stroke="#e3e3e3")
    for i, (x, y, e) in enumerate(pix):
        a = (PATTERN >> (15 - i % 16)) & 1
        inside = XMIN <= x <= XMAX and YMIN <= y <= YMAX
        px, py = L + x * P, T + y * P
        if inside:
            if a:
                f.rect(px, py, P, P, BLUE, stroke=LINE)
            else:
                f.rect(px + 1, py + 1, P - 2, P - 2, WHITE, stroke=LINE)
        else:
            f.rect(px + 1, py + 1, P - 2, P - 2, "#c9c9f0" if a else WHITE, stroke=DIM, dash="2 2")
        if i % 4 == 0:
            f.text(px + P / 2, py - 4, str(i), size=9, anchor="middle", fill=TXT2, halo=True)
    f.rect(L + XMIN * P, T + YMIN * P, (XMAX - XMIN + 1) * P, (YMAX - YMIN + 1) * P, "none", stroke=RED, dash="4 3", sw=1.5)
    f.text(L + XMIN * P, T + (YMAX + 1) * P + 14, f"XMIN = {XMIN}", size=11, anchor="middle", fill=RED)
    f.text(L + (XMAX + 1) * P, T + (YMAX + 1) * P + 14, f"XMAX = {XMAX}", size=11, anchor="middle", fill=RED)
    f.text(L - 4, T + YMIN * P + 12, f"YMIN = {YMIN}", size=11, anchor="end", fill=RED)
    f.text(L - 4, T + YMAX * P + 12, f"YMAX = {YMAX}", size=11, anchor="end", fill=RED)
    f.text(L + XMIN * P + 4, T + (YMAX + 1) * P + 30, "inclusive: the edge pixels are written", size=11, fill=RED)
    x0, y0, _ = pix[0]
    x1, y1, _ = pix[-1]
    SY = 48
    f.text(L, SY - 6, "RASPAT, the pattern: A for one pixel at a time, from bit 15, round again after 16", size=11, fill=TXT2)
    for i in range(16):
        b = (PATTERN >> (15 - i)) & 1
        f.rect(L + i * 22, SY, 22, 20, BLUE if b else WHITE)
        f.text(L + i * 22 + 11, SY + 14, str(b), size=11, anchor="middle", fill=WHITE if b else TXT)
    f.text(L + 16 * 22 + 8, SY + 14, f"= 0x{PATTERN:04X}", size=11)
    yl = T + GH * P + 30
    f.rect(L, yl - 11, 14, 14, BLUE)
    f.text(L + 20, yl, "inside, A = 1: the colour", size=11)
    f.rect(L + 180, yl - 11, 14, 14, WHITE)
    f.text(L + 200, yl, "inside, A = 0: C written back", size=11)
    f.rect(L + 390, yl - 11, 14, 14, "#c9c9f0", stroke=DIM, dash="2 2")
    f.rect(L + 410, yl - 11, 14, 14, WHITE, stroke=DIM, dash="2 2")
    f.text(L + 430, yl, "outside: stepped, not written,", size=11)
    f.text(L + 430, yl + 14, "no memory cycle", size=11)
    f.text(L, yl + 40, f"From ({x0}, {y0}) to ({x1}, {y1}). Small numbers: the pixel's step number;", size=11, fill=TXT2)
    f.text(L, yl + 54, "the pattern moves on for every pixel stepped, so the dashes stay where they were.", size=11, fill=TXT2)
    return f.save("blitter-6-9-clip.svg")


# ---------------------------------------------------------------- 6-10: triangle
def tri_spans(p0, p1, p2):
    """A TRI job's rows (spec 19, section 5.3): {y: (left, right)}, right exclusive."""
    (xt, yt), (xm, ym), (xb, yb) = sorted((p0, p1, p2), key=lambda p: p[1])

    def slope(xa, ya, xc, yc):
        return ((xc - xa) * 65536) // (yc - ya)

    def ceil16(v):
        return -((-v) // 65536)

    rows = {}
    for y in range(yt, yb):
        XL = xt * 65536 + slope(xt, yt, xb, yb) * (y - yt)
        if y < ym:
            XS = xt * 65536 + slope(xt, yt, xm, ym) * (y - yt)
        else:
            XS = xm * 65536 + slope(xm, ym, xb, yb) * (y - ym)
        rows[y] = (ceil16(min(XL, XS)), ceil16(max(XL, XS)))
    return rows


# the spec's worked triangle (spec 19, section 5.4)
assert {y: (l, r - 1) for y, (l, r) in tri_spans((10, 2), (3, 6), (14, 9)).items() if r > l} == {
    3: (9, 10), 4: (7, 11), 5: (5, 11), 6: (3, 12), 7: (7, 12), 8: (11, 13)}


def fig_triangle():
    f = Fig(760, 420)
    pts = [(10, 2), (3, 6), (14, 9)]
    rows = tri_spans(*pts)
    f.text(20, 22, "A TRI job with points (10, 2), (3, 6) and (14, 9): the pixels it writes", bold=True)
    P = 28
    L, T = 60, 60
    cols, nrows = 17, 11
    for y in range(nrows):
        for x in range(cols):
            filled = y in rows and rows[y][0] <= x < rows[y][1]
            f.rect(L + x * P, T + y * P, P, P, HILITE if filled else WHITE, stroke="#ccc")
    for x in range(cols):
        f.text(L + x * P + P / 2, T - 8, str(x), size=11, anchor="middle", fill=TXT2)
    for y in range(nrows):
        f.text(L - 8, T + y * P + P / 2 + 4, str(y), size=11, anchor="end", fill=TXT2)
    corners = [(L + x * P, T + y * P) for x, y in pts]
    f.poly(corners, stroke=BLUE, sw=1.5)
    for (x, y), (cx, cy) in zip(pts, corners):
        f.circle(cx, cy, 3.5, fill=BLUE, stroke="none")
        f.text(cx + (8 if x > 5 else -8), cy - 6, f"({x}, {y})", size=11, anchor="start" if x > 5 else "end", fill=BLUE, halo=True)
    TX = L + cols * P + 30
    f.text(TX, T + 10, "Row y: pixels x", size=13, bold=True)
    yy = T + 34
    for y in range(2, 10):
        if y in rows and rows[y][1] > rows[y][0]:
            s, c = f"{y}: {rows[y][0]} to {rows[y][1] - 1}", TXT
        elif y in rows:
            s, c = f"{y}: none (both edges at x = 10)", TXT2
        else:
            s, c = f"{y}: not written (the bottom row)", TXT2
        f.text(TX, yy, s, size=11, fill=c)
        yy += 18
    for k, s in enumerate(("A pixel is written when its top", "left corner is on or right of the",
                           "left edge and left of the right", "edge, in the rows from the top",
                           "point's y up to, not including,", "the bottom point's.")):
        f.text(TX, yy + 14 + 14 * k, s, size=11, fill=TXT2)
    f.text(L, T + nrows * P + 26, "The bottom row and the right-hand edge are left for neighbouring triangles,", size=11, fill=TXT2)
    f.text(L, T + nrows * P + 40, "so triangles that share an edge write each pixel along it exactly once.", size=11, fill=TXT2)
    return f.save("blitter-6-10-triangle.svg")


if __name__ == "__main__":
    for fn in (fig_chain, fig_minterm, fig_cookiecut, fig_shift, fig_stride, fig_desc,
               fig_bresenham, fig_clip, fig_triangle):
        print(fn())
