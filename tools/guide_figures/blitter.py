"""Figures for Chapter 6, Blitter and DMA Hardware (docs/guide/blitter.md).

Run as `python blitter.py` from this directory. Everything the hardware works
out (minterm results, the cookie-cut, Bresenham's pixels, the pattern, the
octants) is worked out here from the rules in spec 14, not drawn by hand.
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
    heads = [("B", "the image (BPT)"), ("A", "the mask"), ("C", "the background (DPT)"), ("D = A ? B : C", "written to DPT")]
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
    f.text(xs[0], yb, "MASK = 2 (key colour in VALUE):", size=13)
    f.text(xs[0], yb + 17, "A is 1 where B ≠ VALUE, 0 where B = VALUE", size=11, fill=TXT2)
    f.text(xs[3] + G / 2, yb, "MINTERM 0xCA", size=13, anchor="middle")
    f.text(xs[3] + G / 2, yb + 17, "where A is 0 at 8 bpp", size=11, anchor="middle", fill=TXT2)
    f.text(xs[3] + G / 2, yb + 31, "the byte is not written", size=11, anchor="middle", fill=TXT2)
    # legend
    yl = yb + 56
    f.rect(xs[0], yl - 11, 14, 14, KEYFILL, stroke="#999")
    f.text(xs[0] + 20, yl, "the key colour, 0 (VALUE = 0)", size=11)
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
    f.text(SL - 12, ST + 39, "BPT, BBIT = 0", size=11, anchor="end", fill=TXT2)
    for b in range(NPIX // PPB):
        for p in range(PPB):
            i = b * PPB + p
            f.rect(SL + b * BW + p * PW, ST, PW, 34, HILITE, stroke="#999", sw=0.5)
            f.text(SL + b * BW + p * PW + PW / 2, ST + 22, f"i{i}", size=13, anchor="middle")
        f.rect(SL + b * BW, ST, BW, 34, "none", sw=1.5)
        f.text(SL + b * BW + BW / 2, ST - 6, f"BPT + {b}", size=11, anchor="middle", fill=TXT2)

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
    f.text(DL + kf * BW - 30, DT - 70, f"DPT = byte {DPT}, DBIT = {DBIT}", size=13, anchor="middle", bold=True, halo=True)
    f.line(DL + kf * BW - 30, DT - 64, xd + 2, DT - 36, stroke=DIM, arrow="end")
    f.text(20, 362, f"x = {X}: DPT = SCREEN + {X} / 2, DBIT = {X} mod 2. WIDTH = {NPIX}. High nibble = left pixel.", size=11, fill=TXT2)
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
    f.dim(SL, SL + SW, ST - 10, "ABSTRIDE = 128")
    f.circle(IX, IY, 3, fill=LINE)
    f.line(IX - 4, IY - 4, SL + 30, ST + SH + 30, stroke=DIM)
    f.text(SL + 26, ST + SH + 44, "BPT: the image's first pixel", size=11)
    f.text(SL, ST + SH + 64, "row r + 1 of the image starts", size=11, fill=TXT2)
    f.text(SL, ST + SH + 78, "ABSTRIDE bytes after row r", size=11, fill=TXT2)

    # screen: 360 x 288
    L, T, W, H = 290, 96, 360, 288
    f.rect(L, T, W, H, PICTURE, sw=1.5)
    f.text(L + W / 2, T - 46, "the screen", anchor="middle", bold=True)
    f.dim(L, L + W, T - 10, "CDSTRIDE = 360")
    DX, DY = 200, 56
    f.rect(L + DX, T + DY, 32, 32, HILITE, sw=1.5)
    f.circle(L + DX, T + DY, 3, fill=LINE)
    f.text(L + DX - 6, T + DY - 6, "DPT", size=11, anchor="end", halo=True)
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
    f.text(L + 26, T + CY + 14, "new DPT", size=11, halo=True)
    f.text(L + 26, T + CY + 28, f"WIDTH = 32 − k = {32 - K}", size=11, halo=True)
    f.line(L + CX, T + CY + 40, L, T + CY + 40, stroke=DIM, arrow="both")
    f.text(L + CX - 4, T + CY + 44, f"k = {K}", size=11, anchor="end")
    f.text(L - 18, T + CY + 4, "off the left edge", size=11, anchor="end")
    f.text(L - 18, T + CY + 18, "by k pixels:", size=11, anchor="end")
    f.text(L - 18, T + CY + 66, "BPT and DPT + k,", size=11, anchor="end")
    f.text(L - 18, T + CY + 80, "WIDTH − k", size=11, anchor="end")
    f.text(L + W + 6, T + H, "288", size=11, fill=TXT2)
    return f.save("blitter-6-6-stride.svg")


# ---------------------------------------------------------------- 6-7: DESC
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
        head = "backwards (DESC = 1)" if desc else "forwards (DESC = 0)"
        f.text(x0, 50, head, size=15, bold=True)
        sub = (["starts at the last pixel of the last row;", "every row is read before it is written: correct"] if desc else
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
    f.text(20, 398, "Within a row it is the same: a job reads up to 16 bytes ahead of what it writes.", size=11, fill=TXT2)
    return f.save("blitter-6-7-desc.svg")


# ---------------------------------------------------------------- 6-2: chain
def fig_chain():
    f = Fig(760, 400)
    f.text(20, 22, "A chain of descriptors (Example 6-2): restore, save, draw", bold=True)
    jobs = [
        ("restore", [("CTRL", "BLIT, BPP8"), ("MINTERM", "0xCC"), ("APT", "0"), ("BPT", "SAVE"), ("DPT", "oldpos"), ("…", "WIDTH … VALUE"), ("NEXT", "save")]),
        ("save", [("CTRL", "BLIT, BPP8"), ("MINTERM", "0xCC"), ("APT", "0"), ("BPT", "newpos"), ("DPT", "SAVE"), ("…", "WIDTH … VALUE"), ("NEXT", "draw")]),
        ("draw", [("CTRL", "BLIT, BPP8|MASKKEY"), ("MINTERM", "0xCA"), ("APT", "0"), ("BPT", "ball"), ("DPT", "newpos"), ("…", "WIDTH … VALUE"), ("NEXT", "0")]),
    ]
    offs = ["+0x00", "+0x03", "+0x04", "+0x07", "+0x0A", "+0x0D", "+0x1C"]
    BW, RH = 222, 24
    xs = [20, 269, 518]
    T = 140
    # the channel
    f.rect(30, 48, 170, 52, POOL)
    f.text(40, 66, "channel 2", size=11, fill=TXT2)
    f.text(40, 88, "CHDESC = restore", size=13, bold=True)
    f.text(214, 70, "then START", size=11)
    f.text(214, 84, "in CHCTRL", size=11)
    f.line(90, 100, 90, T - 22, stroke=DIM, arrow="end")
    for k, (lab, rows) in enumerate(jobs):
        x = xs[k]
        f.text(x, T - 8, f"{lab}:", size=13, bold=True)
        f.text(x + BW, T - 8, "32 bytes", size=11, anchor="end", fill=TXT2)
        for r, (n, v) in enumerate(rows):
            y = T + r * RH
            last = r == len(rows) - 1
            f.rect(x, y, BW, RH, HILITE if last else (UNSHOWN if n == "…" else WHITE))
            f.text(x + 5, y + 16, offs[r], size=11, fill=TXT2)
            f.text(x + 48, y + 16, n if n != "…" else "", size=11)
            f.text(x + 106 if n != "…" else x + 48, y + 16, v, size=11, bold=last)
        f.rect(x, T, BW, len(rows) * RH, "none", sw=1.5)
        if k < 2:
            yn = T + (len(rows) - 0.5) * RH
            f.line(x + BW, yn, x + BW + 18, yn, stroke=DIM)
            f.line(x + BW + 18, yn, x + BW + 18, T - 30, stroke=DIM)
            f.line(x + BW + 18, T - 30, xs[k + 1] + 30, T - 30, stroke=DIM)
            f.line(xs[k + 1] + 30, T - 30, xs[k + 1] + 30, T - 22, stroke=DIM, arrow="end")
    yb = T + 7 * RH + 26
    f.text(xs[2], yb, "NEXT = 0: the end.", size=13)
    f.text(xs[2], yb + 17, "DONE sets, BUSY clears", size=11, fill=TXT2)
    f.text(30, yb, "Each descriptor is 32 bytes at a multiple of 4 in SRAM;", size=11, fill=TXT2)
    f.text(30, yb + 15, "loading one costs 16 memory reads.", size=11, fill=TXT2)
    f.text(30, yb + 37, "The channel loads each into its job registers, runs it,", size=11, fill=TXT2)
    f.text(30, yb + 52, "then loads the one at NEXT.", size=11, fill=TXT2)
    return f.save("blitter-6-2-chain.svg")


# ---------------------------------------------------------------- 6-8: octants
def octant(dx, dy):
    """The LINE job's octant bits for a line of (dx, dy), y growing down the screen."""
    return int(abs(dy) > abs(dx)), int(dx < 0), int(dy < 0)


def fig_octants():
    f = Fig(760, 470)
    f.text(20, 22, "The octant bits for a line from the centre, screen coordinates (y grows down)", bold=True)
    CX, CY, R = 240, 250, 190
    # axes and diagonals (the octant boundaries)
    f.line(CX - R, CY, CX + R + 14, CY, stroke=LINE, sw=1.5, arrow="end")
    f.line(CX, CY - R, CX, CY + R + 14, stroke=LINE, sw=1.5, arrow="end")
    f.text(CX + R + 14, CY - 8, "x", size=15, bold=True, anchor="end")
    f.text(CX + 10, CY + R + 12, "y", size=15, bold=True)
    for a in (45, 135, 225, 315):
        t = math.radians(a)
        f.line(CX, CY, CX + R * math.cos(t), CY + R * math.sin(t), stroke=DIM, dash="4 3")
    f.text(CX + R * 0.71 + 6, CY + R * 0.71 + 10, "|dy| = |dx|: YMAJOR = 0", size=11, fill=TXT2, halo=True)
    f.text(CX - 6, CY - R + 10, "up the screen", size=11, fill=TXT2, anchor="end")
    f.text(CX - 6, CY + R - 4, "down the screen", size=11, fill=TXT2, anchor="end")
    for k in range(8):
        t = math.radians(22.5 + 45 * k)
        dx, dy = math.cos(t), math.sin(t)
        ym, xn, yn = octant(dx, dy)
        x, y = CX + 132 * dx, CY + 132 * dy
        fill = HILITE if ym else PICTURE
        f.rect(x - 44, y - 26, 88, 50, fill, stroke="none", rx=6)
        f.text(x, y - 11, f"YMAJOR {ym}", size=11, anchor="middle")
        f.text(x, y + 4, f"XNEG {xn}", size=11, anchor="middle")
        f.text(x, y + 19, f"YNEG {yn}", size=11, anchor="middle")
    # an example line
    ex, ey = 80, -32
    f.line(CX, CY, CX + ex, CY + ey, stroke=RED, sw=2)
    arrowhead(f, CX, CY, CX + ex, CY + ey, fill=RED)
    f.circle(CX, CY, 3, fill=LINE)
    ym, xn, yn = octant(ex, ey)
    # legend
    LX = 486
    y = 80
    for s, b in (("YMAJOR = |dy| > |dx|", True), ("the line is longer in y", False),
                 ("", False),
                 ("XNEG = dx < 0", True), ("the line goes left", False),
                 ("", False),
                 ("YNEG = dy < 0", True), ("the line goes up the screen", False),
                 ("", False),
                 ("A tie, |dy| = |dx| (a diagonal),", True), ("counts as YMAJOR = 0.", False),
                 ("On an axis, dx = 0 or dy = 0", False), ("gives XNEG = 0 or YNEG = 0.", False),
                 ("", False),
                 ("The red line: dx = 5, dy = −2", True),
                 (f"YMAJOR {ym}, XNEG {xn}, YNEG {yn}", False),
                 (f"WIDTH 6, HEIGHT 2", False)):
        if s:
            f.text(LX, y, s, size=13 if b else 11, fill=TXT if b else TXT2)
        y += 17 if s else 10
    assert (ym, xn, yn) == octant(5, -2)
    yl = y + 14
    f.rect(LX, yl - 11, 14, 14, HILITE, stroke="none")
    f.text(LX + 20, yl, "YMAJOR = 1", size=11)
    f.rect(LX + 110, yl - 11, 14, 14, PICTURE, stroke="none")
    f.text(LX + 130, yl, "YMAJOR = 0", size=11)
    return f.save("blitter-6-8-octants.svg")


# ---------------------------------------------------------------- 6-9: Bresenham
def line_pixels(x0, y0, x1, y1):
    """LINE's stepping (spec 14, section 3.4): the pixels and E at each one."""
    dx, dy = x1 - x0, y1 - y0
    ym, xn, yn = octant(dx, dy)
    M, N = (abs(dy), abs(dx)) if ym else (abs(dx), abs(dy))
    width, height = M + 1, N
    sx, sy = (-1 if xn else 1), (-1 if yn else 1)
    E = 2 * N - M
    x, y = x0, y0
    out = []
    for i in range(width):
        out.append((x, y, E))
        if i == width - 1:
            break
        if E > 0:
            if ym:
                x += sx
            else:
                y += sy
            E += 2 * (N - M)
        else:
            E += 2 * N
        if ym:
            y += sy
        else:
            x += sx
    assert (x, y) == (x1, y1)
    return out, width, height, M, N


def fig_bresenham():
    f = Fig(760, 430)
    pix, width, height, M, N = line_pixels(0, 0, 10, 4)
    f.text(20, 22, f"A LINE from (0, 0) to (10, 4): M = {M}, N = {N}", bold=True)
    P = 46
    L, T = 70, 70
    cols, rows = 11, 5
    for y in range(rows):
        for x in range(cols):
            f.rect(L + x * P, T + y * P, P, P, WHITE, stroke="#ccc")
    for n, (x, y, E) in enumerate(pix):
        f.rect(L + x * P, T + y * P, P, P, HILITE, stroke=LINE)
        f.text(L + x * P + 5, T + y * P + 15, str(n + 1), size=12, bold=True)
    for x in range(cols):
        f.text(L + x * P + P / 2, T - 8, str(x), size=11, anchor="middle", fill=TXT2)
    for y in range(rows):
        f.text(L - 8, T + y * P + P / 2 + 4, str(y), size=11, anchor="end", fill=TXT2)
    f.text(L - 8, T - 8, "y \\ x", size=11, anchor="end", fill=TXT2)
    f.line(L + P / 2, T + P / 2, L + 10.5 * P, T + 4.5 * P, stroke=BLUE, sw=1)
    # E under each column, and where the line steps in y
    ye = T + rows * P + 22
    f.text(L - 8, ye, "E", size=13, anchor="end", bold=True)
    for n, (x, y, E) in enumerate(pix):
        f.text(L + x * P + P / 2, ye, str(E).replace("-", "−"), size=13, anchor="middle")
        if n < len(pix) - 1:
            f.text(L + x * P + P / 2, ye + 16, "+y" if E > 0 else "", size=11, anchor="middle", fill=RED)
    f.text(L + cols * P + 8, ye + 16, "E > 0: a step in y too", size=11, fill=RED)
    yb = ye + 48
    f.text(L, yb, f"WIDTH = longer length + 1 = {width}", size=13)
    f.text(L, yb + 18, f"HEIGHT = shorter length = {height}", size=13)
    f.text(L, yb + 36, f"E starts at 2N − M = {2 * N - M}".replace("-", "−"), size=13)
    f.text(L + 330, yb, "After each pixel but the last:", size=11, fill=TXT2)
    f.text(L + 330, yb + 15, f"E > 0: step y, E + 2(N − M) = E − {2 * (M - N)}", size=11, fill=TXT2)
    f.text(L + 330, yb + 30, f"otherwise: E + 2N = E + {2 * N}", size=11, fill=TXT2)
    f.text(L + 330, yb + 45, "then step x", size=11, fill=TXT2)
    return f.save("blitter-6-9-bresenham.svg")


# ---------------------------------------------------------------- 6-10: clip and pattern
def fig_clip():
    f = Fig(760, 460)
    add_hatch(f)
    GW, GH, P = 40, 16, 15
    L, T = 116, 100
    XMIN, XMAX, YMIN, YMAX = 3, 26, 2, 11
    PATTERN = 0xF0F0
    VALUE = PATTERN << 16
    pix, width, height, M, N = line_pixels(6, 4, 37, 14)
    f.text(20, 22, f"A dashed LINE (pattern 0x{PATTERN:04X}) that leaves the clip rectangle", bold=True)
    for y in range(GH):
        for x in range(GW):
            f.rect(L + x * P, T + y * P, P, P, WHITE, stroke="#e3e3e3")
    for i, (x, y, E) in enumerate(pix):
        bit = 31 - (i % 16)
        a = (VALUE >> bit) & 1
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
    # the clip rectangle (inclusive)
    f.rect(L + XMIN * P, T + YMIN * P, (XMAX - XMIN + 1) * P, (YMAX - YMIN + 1) * P, "none", stroke=RED, dash="4 3", sw=1.5)
    f.text(L + XMIN * P, T + (YMAX + 1) * P + 14, f"CLIPXMIN = {XMIN}", size=11, anchor="middle", fill=RED)
    f.text(L + (XMAX + 1) * P, T + (YMAX + 1) * P + 14, f"CLIPXMAX = {XMAX}", size=11, anchor="middle", fill=RED)
    f.text(L - 4, T + YMIN * P + 12, f"CLIPYMIN = {YMIN}", size=11, anchor="end", fill=RED)
    f.text(L - 4, T + YMAX * P + 12, f"CLIPYMAX = {YMAX}", size=11, anchor="end", fill=RED)
    f.text(L + XMIN * P + 4, T + (YMAX + 1) * P + 30, "inclusive: the edge pixels are drawn", size=11, fill=RED)
    x0, y0, _ = pix[0]
    x1, y1, _ = pix[-1]
    # pattern strip on top
    SY = 48
    f.text(L, SY - 6, "VALUE bits 31–16, the pattern: one bit a pixel, from bit 31, round again after 16", size=11, fill=TXT2)
    for i in range(16):
        b = (PATTERN >> (15 - i)) & 1
        f.rect(L + i * 22, SY, 22, 20, BLUE if b else WHITE)
        f.text(L + i * 22 + 11, SY + 14, str(b), size=11, anchor="middle", fill=WHITE if b else TXT)
    f.text(L + 16 * 22 + 8, SY + 14, f"= 0x{PATTERN:04X}", size=11)
    # legend
    yl = T + GH * P + 30
    f.rect(L, yl - 11, 14, 14, BLUE)
    f.text(L + 20, yl, "inside, pattern 1: drawn", size=11)
    f.rect(L + 180, yl - 11, 14, 14, WHITE)
    f.text(L + 200, yl, "pattern 0: not read or written", size=11)
    f.rect(L + 390, yl - 11, 14, 14, "#c9c9f0", stroke=DIM, dash="2 2")
    f.rect(L + 410, yl - 11, 14, 14, WHITE, stroke=DIM, dash="2 2")
    f.text(L + 430, yl, "outside: stepped, not drawn,", size=11)
    f.text(L + 430, yl + 14, "no memory cycle", size=11)
    f.text(L, yl + 40, f"From ({x0}, {y0}) to ({x1}, {y1}): WIDTH {width}, HEIGHT {height}. Small numbers: the pixel's place in the line;", size=11, fill=TXT2)
    f.text(L, yl + 54, "the pattern keeps counting through clipped pixels, so the dashes stay where they were.", size=11, fill=TXT2)
    return f.save("blitter-6-10-clip.svg")


# ---------------------------------------------------------------- 6-11: EDGES
def cube_points():
    """A cube, turned and seen in perspective: its 8 points on a 1 bpp screen."""
    pts = []
    ay, ax = math.radians(30), math.radians(20)
    for i in range(8):
        x = 1 if i & 1 else -1
        y = 1 if i & 2 else -1
        z = 1 if i & 4 else -1
        x, z = x * math.cos(ay) + z * math.sin(ay), -x * math.sin(ay) + z * math.cos(ay)
        y, z = y * math.cos(ax) - z * math.sin(ax), y * math.sin(ax) + z * math.cos(ax)
        d = 5 + z
        pts.append((round(180 + 260 * x / d), round(110 + 260 * y / d)))
    return pts


CUBE_EDGES = [(0, 1), (1, 3), (3, 2), (2, 0), (4, 5), (5, 7), (7, 6), (6, 4), (0, 4), (1, 5), (2, 6), (3, 7)]


def fig_edges():
    f = Fig(760, 440)
    pts = cube_points()
    f.text(20, 22, "An EDGES job: a table of points, a table of edges, one job", bold=True)
    T, RH = 80, 22
    # POINTS
    PL = 20
    f.text(PL, T - 30, "POINTS (APT)", size=13, bold=True)
    f.text(PL, T - 12, "point n at POINTS + 4n", size=11, fill=TXT2)
    for c, (h, w) in enumerate((("", 0), ("n", 48), ("x", 100), ("y", 150))):
        if h:
            f.text(PL + w + 18, T + 14, h, size=11, anchor="middle", fill=TXT2)
    for n in range(9):
        y = T + 20 + n * RH
        ghost = n == 8
        f.text(PL + 40, y + 15, f"+{4 * n}", size=11, anchor="end", fill=TXT2)
        f.text(PL + 66, y + 15, str(n), size=11, anchor="middle", fill=TXT2 if ghost else TXT)
        xv, yv = ("0x8000", "…") if ghost else (str(pts[n][0]), str(pts[n][1]))
        for k, v in enumerate((xv, yv)):
            f.rect(PL + 94 + k * 50, y, 50, RH, UNSHOWN if ghost else (HILITE if n in CUBE_EDGES[0] else WHITE),
                   stroke=DIM if ghost else LINE, dash="4 3" if ghost else None)
            f.text(PL + 119 + k * 50, y + 15, v, size=11, anchor="middle", fill=TXT2 if ghost else TXT)
    f.text(PL + 94, T + 20 + 9 * RH + 16, "x and y: 2 bytes each, signed", size=11, fill=TXT2)
    f.text(PL + 10, T + 20 + 9 * RH + 36, "point 8: x = 0x8000, behind the eye:", size=11, fill=TXT2)
    f.text(PL + 10, T + 20 + 9 * RH + 50, "edges to it are left out", size=11, fill=TXT2)
    # EDGES
    EL = 260
    f.text(EL, T - 30, "EDGES (BPT)", size=13, bold=True)
    f.text(EL, T - 12, "edge k at EDGES + 2k", size=11, fill=TXT2)
    f.text(EL + 66, T + 14, "k", size=11, anchor="middle", fill=TXT2)
    f.text(EL + 105, T + 14, "a", size=11, anchor="middle", fill=TXT2)
    f.text(EL + 145, T + 14, "b", size=11, anchor="middle", fill=TXT2)
    for k, (a, b) in enumerate(CUBE_EDGES):
        y = T + 20 + k * RH
        f.text(EL + 44, y + 15, f"+{2 * k}", size=11, anchor="end", fill=TXT2)
        f.text(EL + 66, y + 15, str(k), size=11, anchor="middle")
        for j, v in enumerate((a, b)):
            f.rect(EL + 85 + j * 40, y, 40, RH, HILITE if k == 0 else WHITE)
            f.text(EL + 105 + j * 40, y + 15, str(v), size=11, anchor="middle")
    f.text(EL + 85, T + 20 + 12 * RH + 16, "1 byte each", size=11, fill=TXT2)
    # the drawing
    DL, DT, s = 450, 60, 1.0
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    ox, oy = DL + 10, DT + 10
    W, H = 290, 260
    f.rect(ox, oy, W, H, PICTURE)
    f.circle(ox, oy, 3, fill=LINE)
    f.text(ox + 6, oy + 14, "(0, 0): DPT, the origin", size=11)
    sx = lambda x: ox + (x - 40) * s
    sy = lambda y: oy + (y + 0) * s
    assert all(0 <= sx(x) - ox <= W for x in xs) and all(0 <= sy(y) - oy <= H for y in ys)
    for k, (a, b) in enumerate(CUBE_EDGES):
        f.line(sx(xs[a]), sy(ys[a]), sx(xs[b]), sy(ys[b]), stroke=RED if k == 0 else LINE, sw=2.5 if k == 0 else 1.5)
    a, b = CUBE_EDGES[0]
    mx, my = (sx(xs[a]) + sx(xs[b])) / 2, (sy(ys[a]) + sy(ys[b])) / 2
    ux, uy = sx(xs[b]) - sx(xs[a]), sy(ys[b]) - sy(ys[a])
    ln = math.hypot(ux, uy)
    arrowhead(f, mx - ux / ln, my - uy / ln, mx + 6 * ux / ln, my + 6 * uy / ln, fill=RED, size=12)
    for n in range(8):
        f.circle(sx(xs[n]), sy(ys[n]), 3, fill=LINE)
    cx, cy = sum(xs) / 8, sum(ys) / 8
    for n in range(8):
        dx, dy = xs[n] - cx, ys[n] - cy
        d = math.hypot(dx, dy) or 1
        f.text(sx(xs[n]) + 13 * dx / d, sy(ys[n]) + 13 * dy / d + 4, str(n), size=13, bold=True, anchor="middle", halo=True)
    f.text(ox, oy + H + 20, f"edge 0 is drawn from a = {a} to b = {b}", size=11, fill=RED)
    f.text(ox, oy + H + 40, "WIDTH = 12 edges; DPT = the origin, pixel (0, 0)", size=13)
    f.text(ox, oy + H + 56, "x grows right, y grows down", size=11, fill=TXT2)
    return f.save("blitter-6-11-edges.svg")


if __name__ == "__main__":
    for fn in (fig_minterm, fig_cookiecut, fig_shift, fig_stride, fig_desc, fig_chain,
               fig_octants, fig_bresenham, fig_clip, fig_edges):
        print(fn())
