"""Figures for Appendix A, Timing and Screen Reference (docs/guide/timing.md)."""

from svgfig import (Fig, TXT, TXT2, LINE, DIM, BLANK, PICTURE, CPU, DISPLAY, POOL,
                    HILITE, UNSHOWN, WHITE)

# The machine's numbers (spec 2, spec 4)
BEAM_W, BEAM_H = 864, 625
VID_X0, VID_Y0 = 144, 49
VID_W, VID_H = 720, 576
LINE_T20 = 640          # T-states per line at 20 MHz
VBL_T20 = 49 * 640      # 31,360


def zoom(f, x1, x2, y1, X1, X2, y2):
    """Dashed lines from a slice [x1, x2] at y1 to a full row [X1, X2] at y2."""
    f.line(x1, y1, X1, y2, stroke=DIM, dash="4 3")
    f.line(x2, y1, X2, y2, stroke=DIM, dash="4 3")


# ---------------------------------------------------------------- A-1
def fig_scales():
    f = Fig(760, 350)
    L, W = 40, 680
    # Frame
    y = 38
    f.text(L, y - 10, "Frame: 20 ms = 625 lines = 400,000 T-states at 20 MHz", bold=True)
    vb = W * 49 / 625
    f.rect(L, y, vb, 34, BLANK)
    f.rect(L + vb, y, W - vb, 34, PICTURE)
    f.text(L + vb / 2, y + 21, "vblank", size=11, anchor="middle")
    f.text(L + vb + (W - vb) / 2, y + 21, "576 picture lines", anchor="middle")
    sl = L + vb + 520
    f.rect(sl, y - 3, 3, 40, HILITE)
    # Line
    y2 = 148
    zoom(f, sl, sl + 3, y + 37, L, L + W, y2)
    f.text(L, y2 - 10, "", size=1)
    hb = W * 144 / 864
    f.rect(L, y2, hb, 34, BLANK)
    f.rect(L + hb, y2, W - hb, 34, PICTURE)
    f.text(L + hb / 2, y2 + 21, "hblank", size=11, anchor="middle")
    f.text(L + hb + (W - hb) / 2, y2 + 21, "720 picture pixels", anchor="middle")
    f.text(L, y2 - 10, "Line: 32 µs = 864 beam pixels = 320 slots = 640 T-states at 20 MHz", bold=True, halo=True)
    s2 = L + hb + 470
    sw = W / 320
    f.rect(s2, y2 - 3, sw + 1, 40, HILITE)
    # Slot
    y3 = 258
    zoom(f, s2, s2 + sw + 1, y2 + 37, L, L + W, y3)
    cw = W / 5
    owners = [("0: CPU", CPU), ("1: display", DISPLAY), ("2: CPU", CPU), ("3: display", DISPLAY), ("4: free pool", POOL)]
    for i, (name, col) in enumerate(owners):
        f.rect(L + i * cw, y3, cw, 34, col)
        f.text(L + i * cw + cw / 2, y3 + 21, name, anchor="middle")
    f.dim(L, L + cw, y3 + 48, "memory cycle: 20 ns, one 16-bit word", above=False)
    f.dim(L, L + W / 2, y3 + 70, "Z80 T-state at 20 MHz: 50 ns", above=False)
    f.dim(L + W / 2, L + W, y3 + 70, "Z80 T-state at 20 MHz: 50 ns", above=False)
    f.text(L, y3 - 10, "Slot: 100 ns = 5 memory cycles = 10 system clocks", bold=True, halo=True)
    return f.save("timing-A-1-scales.svg")


# ---------------------------------------------------------------- A-2
def fig_frame():
    f = Fig(760, 330)
    L, W = 40, 680
    k = W / 625
    y = 60
    f.text(L, 24, "One frame: 625 beam lines, 20 ms", bold=True)
    f.rect(L, y, 49 * k, 40, BLANK)
    f.rect(L + 49 * k, y, 576 * k, 40, PICTURE)
    f.text(L + 49 * k + 288 * k, y + 25, "picture: lines 49-624 (576 lines, 18.43 ms)", anchor="middle")
    for v in (0, 49, 337, 625):
        x = L + v * k
        f.line(x, y + 40, x, y + 48, stroke=DIM)
        f.text(x, y + 61, str(v), size=11, anchor="middle", fill=TXT2)
    f.text(L + 337 * k, y + 75, "(centre)", size=11, anchor="middle", fill=TXT2)
    f.line(L, y - 4, L, y - 16, stroke=LINE)
    f.text(L, y - 20, "line 0: VBLANK", size=11)
    # zoom of the vertical blank: lines 0-60
    y2 = 210
    Z = W / 60
    zoom(f, L, L + 60 * k, y + 40, L, L + W, y2)
    segs = [(0, 5, "porch", BLANK), (5, 10, "sync 5-9", "#bfbfbf"), (10, 49, "back porch 10-48", BLANK), (49, 60, "picture", PICTURE)]
    for a, b, name, col in segs:
        f.rect(L + a * Z, y2, (b - a) * Z, 40, col)
        f.text(L + (a + b) / 2 * Z, y2 + 25, name, size=11, anchor="middle")
    for v in (0, 5, 10, 20, 30, 40, 49, 60):
        x = L + v * Z
        f.line(x, y2 + 40, x, y2 + 46, stroke=DIM)
        f.text(x, y2 + 58, str(v), size=11, anchor="middle", fill=TXT2)
    f.dim(L, L + 49 * Z, y2 + 78, "vertical blank: 49 lines = 1.57 ms = 31,360 T at 20 MHz (VIDSTAT.INVBLANK = 1)", above=False)
    # events
    ev = [
        (0, "VBLANK flag and interrupt; copper restarts at COP1LC;"),
        (0, "FRAMECOUNT + 1; every sprite stops; timer frame tick"),
        (49, "first picture line: fetched from beam (49, 0)"),
    ]
    f.line(L, y2, L, y2 - 30, stroke=LINE)
    f.text(L + 4, y2 - 34, ev[0][1], size=11, halo=True)
    f.text(L + 4, y2 - 20, ev[1][1], size=11, halo=True)
    x49 = L + 49 * Z
    f.line(x49, y2, x49, y2 - 8, stroke=LINE)
    f.text(x49, y2 - 6, "", size=1)
    f.text(L + W, y2 - 6, ev[2][1], size=11, anchor="end", halo=True)
    return f.save("timing-A-2-frame.svg")


# ---------------------------------------------------------------- A-3
def fig_line():
    f = Fig(760, 380)
    L, W = 40, 680
    k = W / 864
    y = 110
    f.text(L, 22, "One line: 864 beam pixels, 32 µs", bold=True)
    segs = [(0, 12, "", BLANK), (12, 76, "sync", "#bfbfbf"), (76, 144, "", BLANK), (144, 864, "picture: pixels 144-863", PICTURE)]
    for a, b, name, col in segs:
        f.rect(L + a * k, y, (b - a) * k, 40, col)
        if name:
            f.text(L + (a + b) / 2 * k, y + 25, name, size=11 if b - a < 100 else 13, anchor="middle")
    f.dim(L, L + 144 * k, y - 8, "horizontal blank")
    # events at pixel 0 and 144
    f.line(L, y, L, 40, stroke=LINE)
    f.text(L + 5, 44, "pixel 0: LINE interrupt (line LINECMP); line settings copied", size=11)
    f.text(L + 5, 58, "(CTRL, WINX, WINY, SCROLLX/Y, MAPPT, PATPT); each layer starts its fetch", size=11)
    x144 = L + 144 * k
    f.line(x144, y, x144, 70, stroke=LINE)
    f.text(x144 + 5, 82, "pixel 144: PRIO and BGCOLOR taken; the picture starts", size=11)
    # rulers
    rows = [
        ("beam pixels", [(p, str(p)) for p in (0, 144, 288, 432, 576, 720, 864)]),
        ("µs", [(0, "0"), (144, "5.33"), (432, "16"), (864, "32")]),
        ("slots", [(0, "0"), (144, "53.3"), (432, "160"), (864, "320")]),
        ("T at 20 MHz", [(0, "0"), (144, "107"), (432, "320"), (864, "640")]),
        ("T at 3.57 MHz", [(0, "0"), (144, "19"), (432, "57"), (864, "114")]),
    ]
    ry = y + 64
    for name, ticks in rows:
        f.line(L, ry, L + W, ry, stroke=DIM)
        for p, lab in ticks:
            x = L + p * k
            f.line(x, ry - 4, x, ry + 4, stroke=DIM)
            f.text(x, ry + 16, lab, size=11, anchor="middle" if 0 < p < 864 else ("start" if p == 0 else "end"), fill=TXT2)
        f.text(L + W / 2 + 50, ry - 5, name, size=11, anchor="middle", fill=TXT2)
        ry += 40
    f.text(L, ry + 2, "Beam pixel p is p × 37.04 ns after the line starts. 27 beam pixels = 1 µs.", size=11, fill=TXT2)
    return f.save("timing-A-3-line.svg")


# ---------------------------------------------------------------- A-4
def fig_slot():
    f = Fig(760, 450)
    L, W = 40, 700
    ns = W / 200     # two slots, 200 ns
    f.text(L, 22, "Two slots: who owns each memory cycle, and two Z80 reads at 20 MHz", bold=True)
    y = 52
    f.text(L - 4, y + 12, "", size=1)
    # clock edges
    for e in range(21):
        x = L + e * 10 * ns
        f.line(x, y, x, y + 10, stroke=DIM)
        if e < 20:
            f.text(x + 2, y - 4, str(e % 10), size=10, fill=TXT2)
    f.text(L + W, y - 4, "", size=1)
    f.text(L, y + 26, "", size=1)
    # slot boxes labels
    f.dim(L, L + 100 * ns, y + 22, "slot k: edges 0-9, 100 ns", above=False)
    f.dim(L + 100 * ns, L + W, y + 22, "slot k + 1", above=False)
    # cycles
    yc = y + 46
    names = [("0 CPU", CPU), ("1 display", DISPLAY), ("2 CPU", CPU), ("3 display", DISPLAY), ("4 pool", POOL)]
    for s in range(2):
        for i, (n, c) in enumerate(names):
            x = L + (s * 100 + i * 20) * ns
            f.rect(x, yc, 20 * ns, 30, c)
            f.text(x + 10 * ns, yc + 19, n, size=11, anchor="middle")
    f.text(L, yc + 46, "memory cycle k is issued at slot edge 2k (0, 20, 40, 60, 80 ns); its data is usable 40 ns later", size=11, fill=TXT2)
    # T-states
    yt = yc + 64
    for i in range(4):
        x = L + i * 50 * ns
        f.rect(x, yt, 50 * ns, 26, WHITE)
        f.text(x + 25 * ns, yt + 17, f"T-state ({i * 50}-{i * 50 + 50} ns)", size=11, anchor="middle")
    f.text(L, yt + 42, "at 20 MHz every T-state starts on slot edge 0 or 5", size=11, fill=TXT2)

    def read(yy, t1, issue, label):
        x0 = L + t1 * ns
        f.text(L, yy - 6, label, size=12, bold=True)
        f.rect(x0, yy, 100 * ns, 22, "#eef5ea")
        f.text(x0 + 4, yy + 15, "T1", size=11)
        f.text(x0 + 50 * ns + 4, yy + 15, "T2", size=11)
        xi = L + issue * ns
        f.rect(xi, yy + 28, 20 * ns, 18, CPU, sw=2)
        f.text(xi + 10 * ns, yy + 41, "read", size=10, anchor="middle")
        f.line(x0, yy + 56, x0, yy + 64, stroke=LINE)
        f.text(x0, yy + 77, "address", size=10, anchor="middle")
        xd = xi + 40 * ns
        f.line(xd, yy + 56, xd, yy + 64, stroke=LINE)
        f.text(xd, yy + 77, "byte at di", size=10, anchor="middle")
        xe = x0 + 100 * ns
        f.line(xe, yy, xe, yy + 64, stroke=LINE, sw=2)
        f.text(xe + 4, yy + 77, "core takes it", size=10)
        f.dim(xd, xe, yy + 52, f"{int(t1 + 100 - issue - 40)} ns spare", size=10)

    read(yt + 78, 0, 40, "Read, T1 on edge 0: uses cycle 2")
    read(yt + 190, 50, 100, "Read, T1 on edge 5: uses cycle 0 of the next slot")
    return f.save("timing-A-4-slot.svg")


# ---------------------------------------------------------------- A-5
def fig_vblank_jobs():
    jobs = [
        ("Set up a layer from a 32-byte table (LDIR)", 667, CPU),
        ("Load 16 colours (LDIR, 48 bytes)", 1003, CPU),
        ("Load 256 colours (unrolled LDI, 768 bytes)", 12288, CPU),
        ("Load 256 colours (OUTI loop)", 19456, CPU),
        ("Copy 1 KB with LDIR", 21499, CPU),
        ("Clear 8 KB with unrolled PUSH", 45056, CPU),
        ("DMA engine: copy 1 KB (about 45 MB/s)", 23e-6 / 50e-9, POOL, "about 23 µs, 1.5%"),
        ("DMA engine: clear 8 KB (about 89 MB/s)", 92e-6 / 50e-9, POOL, "about 92 µs, 6%"),
    ]
    f = Fig(760, 70 + 34 * len(jobs) + 56)
    L, W = 300, 400
    k = W / VBL_T20
    f.text(20, 24, "What fits in the vertical blank (31,360 T-states, 1.57 ms, at 20 MHz)", bold=True)
    y0 = 50
    f.rect(L, y0 - 6, W, 34 * len(jobs) + 6, "none", stroke=DIM, dash="4 3")
    for i, job in enumerate(jobs):
        name, t, col = job[:3]
        y = y0 + i * 34
        f.text(L - 8, y + 16, name, size=12, anchor="end")
        w = min(t * k, W + 40)
        f.rect(L, y, w, 22, col)
        pct = 100 * t / VBL_T20
        lab = job[3] if len(job) > 3 else f"{t:,.0f} T, {pct:.0f}%"
        if t * k > W:
            f.poly([(L + W + 40, y), (L + W + 50, y + 11), (L + W + 40, y + 22)], fill=col)
            f.text(L + W + 54, y + 16, "", size=1)
            f.text(L + W - 6, y + 16, f"{lab}: does not fit", size=11, anchor="end")
        elif w > 170:
            f.text(L + w - 6, y + 16, lab, size=11, anchor="end")
        else:
            f.text(L + w + 6, y + 16, lab, size=11)
    yb = y0 + 34 * len(jobs) + 8
    for frac, lab in ((0, "0"), (0.5, "15,680"), (1, "31,360 T")):
        x = L + frac * W
        f.line(x, yb - 6, x, yb, stroke=DIM)
        f.text(x, yb + 13, lab, size=11, anchor="middle" if 0 < frac < 1 else ("start" if frac == 0 else "end"), fill=TXT2)
    f.rect(20, yb + 24, 12, 12, CPU)
    f.text(36, yb + 34, "the Z80", size=11)
    f.rect(100, yb + 24, 12, 12, POOL)
    f.text(116, yb + 34, "the DMA engine (the Z80 carries on meanwhile)", size=11)
    return f.save("timing-A-5-vblank-jobs.svg")


# ---------------------------------------------------------------- A-6
def fig_beam(name="timing-A-6-beam.svg"):
    s = 0.72
    f = Fig(760, int(BEAM_H * s) + 90)
    L, T = 90, 40
    f.text(20, 22, "The beam and the picture, to scale (beam coordinates)", bold=True)
    f.rect(L, T, BEAM_W * s, BEAM_H * s, BLANK)
    f.rect(L + VID_X0 * s, T + VID_Y0 * s, VID_W * s, VID_H * s, PICTURE)
    f.text(L + 72 * s, T + 337 * s, "horizontal", size=11, anchor="middle")
    f.text(L + 72 * s, T + 337 * s + 14, "blank", size=11, anchor="middle")
    f.text(L + 72 * s, T + 337 * s + 28, "0-143", size=11, anchor="middle", fill=TXT2)
    f.text(L + 504 * s, T + 24 * s + 4, "vertical blank: lines 0-48", size=11, anchor="middle")
    f.text(L + 504 * s, T + 337 * s - 8, "picture 720 × 576", size=15, anchor="middle", bold=True)
    f.text(L + 504 * s, T + 337 * s + 12, "pixels 144-863, lines 49-624", size=12, anchor="middle")
    # centre cross
    cx, cy = L + 504 * s, T + 337 * s
    f.line(cx - 8, cy + 30, cx + 8, cy + 30, stroke=LINE)
    f.line(cx, cy + 22, cx, cy + 38, stroke=LINE)
    f.text(cx + 12, cy + 34, "centre (504, 337)", size=11)
    pts = [((0, 0), "(0, 0)", "end", -6, -4), ((144, 49), "(144, 49) = (VID_X0, VID_Y0)", "start", 6, 14),
           ((864, 625), "(864, 625) = (BEAM_W, BEAM_H)", "end", 0, 18)]
    for (bx, by), lab, anc, dx, dy in pts:
        x, y = L + bx * s, T + by * s
        f.rect(x - 3, y - 3, 6, 6, LINE)
        f.text(x + dx, y + dy, lab, size=11, anchor=anc)
    f.dim(L + VID_X0 * s, L + BEAM_W * s, T + BEAM_H * s + 30, "VID_W = 720", above=False)
    f.dim(L, L + VID_X0 * s, T + BEAM_H * s + 30, "144", above=False)
    f.vdim(L - 14, T + VID_Y0 * s, T + BEAM_H * s, "VID_H = 576")
    f.vdim(L - 14, T, T + VID_Y0 * s, "49")
    return f.save(name)


# ---------------------------------------------------------------- A-7
def fig_windows():
    wins = [
        ("Spectrum size: 256 × 192 at 2 × 2", (248, 760, 145, 529)),
        ("Amiga PAL lores: 320 × 256 at 2 × 2", (184, 824, 81, 593)),
        ("640 × 480 (boot console, 80 × 30)", (184, 824, 97, 577)),
        ("640 × 400 (80 × 25 text at 1 × 2)", (184, 824, 137, 537)),
    ]
    s = 0.4
    pw, ph = BEAM_W * s, BEAM_H * s
    f = Fig(760, int(2 * ph + 140))
    f.text(20, 22, "Common windows, to scale (beam coordinates: XSTART-XEND × YSTART-YEND)", bold=True)
    for i, (name, (x0, x1, y0, y1)) in enumerate(wins):
        L = 20 + (i % 2) * (pw + 40)
        T = 50 + (i // 2) * (ph + 56)
        f.text(L, T - 6, name, size=12, bold=True)
        f.rect(L, T, pw, ph, BLANK)
        f.rect(L + VID_X0 * s, T + VID_Y0 * s, VID_W * s, VID_H * s, PICTURE)
        f.rect(L + x0 * s, T + y0 * s, (x1 - x0) * s, (y1 - y0) * s, HILITE)
        f.text(L + (x0 + x1) / 2 * s, T + (y0 + y1) / 2 * s + 4, f"{x0}-{x1} × {y0}-{y1}", size=11, anchor="middle")
        f.text(L + pw, T + ph + 15, f"border: {x0 - 144} px left, {y0 - 49} lines top", size=11, anchor="end", fill=TXT2)
    return f.save("timing-A-7-windows.svg")


# ---------------------------------------------------------------- A-8
def fig_spectrum():
    s = 0.95
    f = Fig(760, int(384 * s) + 120)
    L, T = 100, 56
    f.text(20, 22, "The Spectrum screen in beam coordinates (256 × 192 at 2 × 2)", bold=True)
    W, H = 512 * s, 384 * s
    thirds = ["#dbe8f5", "#cfe2f3", "#c3dbf0"]
    for t in range(3):
        f.rect(L, T + t * 128 * s, W, 128 * s, thirds[t], stroke="none")
    for c in range(33):
        x = L + c * 16 * s
        f.line(x, T, x, T + H, stroke="#9fb8d0" if c % 8 else LINE, sw=1)
    for r in range(25):
        y = T + r * 16 * s
        f.line(L, y, L + W, y, stroke="#9fb8d0" if r % 8 else LINE, sw=1)
    f.rect(L, T, W, H, "none", stroke=LINE, sw=2)
    for t, lab in enumerate(["rows 0-7: pixels at +0x0000", "rows 8-15: pixels at +0x0800", "rows 16-23: pixels at +0x1000"]):
        f.text(L + W / 2, T + (t * 128 + 64) * s + 4, lab, size=12, anchor="middle")
    # labels
    f.text(L, T - 6, "248", size=11, anchor="middle", fill=TXT2)
    f.text(L + W, T - 6, "760", size=11, anchor="middle", fill=TXT2)
    f.text(L - 6, T + 4, "145", size=11, anchor="end", fill=TXT2)
    f.text(L - 6, T + H + 4, "529", size=11, anchor="end", fill=TXT2)
    f.text(L - 40, T + H / 2, "row r: lines 145 + 16r to 160 + 16r", size=11, anchor="middle", rotate=-90)
    f.text(L + W / 2, T + H + 20, "column c: pixels 248 + 16c to 263 + 16c. One cell = 8 × 8 source = 16 × 16 beam pixels", size=11, anchor="middle")
    f.text(L + W / 2, T + H + 36, "attribute of cell (c, r) at screen + 6144 + 32r + c", size=11, anchor="middle", fill=TXT2)
    # copper waits
    xc = L + 520 * s
    for r in (0, 1, 2, 8, 16):
        y = T + 16 * r * s - 1 * s
        f.rect(xc - 3, y - 3, 6, 6, HILITE)
    f.text(xc + 10, T + 8, "copper WAIT (144 + 16r, 768),", size=11)
    f.text(xc + 10, T + 22, "then 3 MOVEs to BPL0PT:", size=11)
    f.text(xc + 10, T + 36, "one per character row (24)", size=11)
    f.text(xc + 10, T + 50, "with BPLSTRIDE = 256", size=11)
    return f.save("timing-A-8-spectrum.svg")


# ---------------------------------------------------------------- A-9
def fig_fetch():
    f = Fig(760, 280)
    L, W = 40, 690
    k = W / 864
    f.text(20, 22, "One layer's fetch in a line: window 248-760, 1 bpp at 2× (a group = 32 beam pixels)", bold=True)
    y = 70
    f.rect(L, y, 144 * k, 30, BLANK)
    f.rect(L + 144 * k, y, 720 * k, 30, PICTURE)
    f.rect(L + 248 * k, y, 512 * k, 30, HILITE)
    for g in range(17):
        x = L + (248 + 32 * g) * k
        f.line(x, y, x, y + 30, stroke=LINE)
    f.text(L + 504 * k, y - 8, "the window shows 16 groups (0-15)", size=11, anchor="middle")
    for p in (0, 144, 248, 760, 864):
        f.text(L + p * k, y + 44, str(p), size=11, anchor="middle", fill=TXT2)
    # fetch marks
    yf = y + 66
    f.text(L, yf - 6, "fetches", size=11, fill=TXT2)
    marks = [(2, "0"), (12, "1")] + [(248 + 32 * (g - 1), str(g)) for g in range(2, 16)]
    for p, lab in marks:
        x = L + p * k
        f.rect(x, yf, 14 * k * 2, 16, DISPLAY)
        f.text(x + 14 * k, yf + 12, lab, size=9, anchor="middle")
    f.text(L + 30 * k, yf + 32, "groups 0 and 1 in the", size=11)
    f.text(L + 30 * k, yf + 46, "horizontal blank", size=11)
    f.text(L + 450 * k, yf + 32, "then one group each time the shifters take one:", size=11, anchor="middle")
    f.text(L + 450 * k, yf + 46, "always one group of time (32 beam pixels here) in hand", size=11, anchor="middle")
    # safe gap
    yg = yf + 70
    last = 248 + 32 * 14 + 28
    f.rect(L + last * k, yg, (864 - last) * k, 22, POOL)
    f.text(L + last * k - 6, yg + 15, "BPL0PT for the next line can be written here:", size=11, anchor="end")
    f.text(L + (last + 864) / 2 * k, yg + 15, "after last fetch", size=10, anchor="middle")
    xc = L + 768 * k
    f.line(xc, yg + 22, xc, yg + 34, stroke=LINE)
    f.text(xc, yg + 46, "copper WAIT at 768", size=11, anchor="middle")
    return f.save("timing-A-9-fetch.svg")


# ---------------------------------------------------------------- A-10
def fig_writes():
    f = Fig(760, 330)
    L, W = 200, 540
    k = W / (2 * 864)
    f.text(20, 22, "When a write changes line L", bold=True)
    y = 46
    for i, name in enumerate(("line L - 1", "line L")):
        x = L + i * 864 * k
        f.rect(x, y, 144 * k, 24, BLANK)
        f.rect(x + 144 * k, y, 720 * k, 24, PICTURE)
        f.text(x + 504 * k, y + 16, name, size=12, anchor="middle")
    for p, lab in ((0, "0"), (144, "144"), (864, "0"), (1008, "144"), (1728, "")):
        f.text(L + p * k, y + 38, lab, size=10, anchor="middle", fill=TXT2)
    rows = [
        ("CTRL0-3, WINX, WINY, SCROLLX, SCROLLY, MAPPT, PATPT, ATCTL ...", 0, 864, "copied at pixel 0 of line L"),
        ("PRIO, BGCOLOR", 144, 1008, "taken at pixel 144 of line L"),
        ("BPL0PT, BPLSTRIDE (live)", 730, 864, "after the layer's last fetch on line L - 1"),
        ("Palette entries, VIDCON, port 0xFE border", 1100, 1100, "at once: from the next pixel after the write"),
    ]
    yr = y + 64
    for name, a, b, note in rows:
        words = name.split(", ")
        # wrap the name into lines of up to ~28 characters
        lines, cur = [], ""
        for w_ in words:
            nxt = (cur + ", " + w_) if cur else w_
            if len(nxt) > 30:
                lines.append(cur + ",")
                cur = w_
            else:
                cur = nxt
        lines.append(cur)
        for j, ln in enumerate(lines):
            f.text(L - 10, yr + 12 + j * 14 - (len(lines) - 1) * 7, ln, size=11, anchor="end")
        f.rect(L, yr - 2, W, 28, UNSHOWN, stroke="none")
        if b > a:
            f.rect(L + a * k, yr + 2, (b - a) * k, 20, POOL)
        if b < 1728:
            f.line(L + b * k, yr - 2, L + b * k, yr + 26, stroke=LINE, sw=2)
        f.text(L + b * k + 6, yr + 16, note, size=10, fill=TXT2)
        yr += 52
    f.rect(L, yr - 8, 12, 12, POOL)
    f.text(L + 18, yr + 2, "write in this stretch to change line L", size=11)
    return f.save("timing-A-10-writes.svg")


# ---------------------------------------------------------------- A-11
def fig_irq():
    f = Fig(760, 250)
    L, W = 40, 690
    k = W / 864
    f.text(20, 22, "A LINE interrupt at 20 MHz, worst case, to scale", bold=True)
    y = 50
    f.rect(L, y, 144 * k, 24, BLANK)
    f.rect(L + 144 * k, y, 720 * k, 24, PICTURE)
    f.text(L + 504 * k, y + 16, "line LINECMP", size=12, anchor="middle")
    f.line(L, y - 6, L, y + 120, stroke=LINE, sw=2)
    f.text(L + 4, y - 8, "LINE flag set at pixel 0", size=11)
    f.line(L + W, y - 6, L + W, y + 120, stroke=LINE, sw=2)
    f.text(L + W - 4, y - 8, "next line's settings copied", size=11, anchor="end")
    # latency: up to 23 T finish instruction + 19 T IM 2 = 42 T = 2.1 us = 56.7 px
    lat = 42 / 640 * 864
    yb = y + 40
    f.rect(L, yb, 23 / 640 * 864 * k, 24, "#e6e6e6")
    f.rect(L + 23 / 640 * 864 * k, yb, 19 / 640 * 864 * k, 24, "#c9c9c9")
    f.rect(L + lat * k, yb, (864 - lat) * k, 24, CPU)
    f.text(L + (lat + 864) / 2 * k, yb + 16, "the handler: up to 598 T-states to make its writes for the next line", size=11, anchor="middle")
    f.line(L, yb + 34, L + lat * k, yb + 34, stroke=DIM, arrow="both")
    f.text(L + lat * k + 6, yb + 38, "42 T, 2.1 µs: the worst case before the handler's first instruction", size=11, fill=TXT2)
    f.text(L + 10, yb + 70, "up to 23 T to finish the current instruction, then 19 T for the IM 2 acknowledge.", size=11, fill=TXT2)
    f.text(L + 10, yb + 84, "A handler starts at most 57 beam pixels into the line: still inside the horizontal blank.", size=11, fill=TXT2)
    f.text(L + 10, yb + 98, "At 3.57 MHz the same 42 T take 11.8 µs, 318 beam pixels: past the start of the picture.", size=11, fill=TXT2)
    return f.save("timing-A-11-irq.svg")


if __name__ == "__main__":
    for fn in (fig_scales, fig_frame, fig_line, fig_slot, fig_vblank_jobs, fig_beam, fig_windows,
               fig_spectrum, fig_fetch, fig_writes, fig_irq):
        print(fn())
