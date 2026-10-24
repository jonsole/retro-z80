"""Figures for Chapter 3, Playfield Hardware (docs/guide/playfields.md)."""

from svgfig import (Fig, TXT, TXT2, LINE, DIM, BLANK, PICTURE, CPU, DISPLAY, POOL,
                    SPRITE, HILITE, UNSHOWN, WHITE)
import timing

VID_X0, VID_Y0, VID_W, VID_H = 144, 49, 720, 576


# ---------------------------------------------------------------- 3-1
def fig_beam():
    return timing.fig_beam("playfields-3-1-beam.svg")


# ---------------------------------------------------------------- 3-3
def fig_window():
    s = 0.62
    f = Fig(760, int(VID_H * s) + 100)
    L, T = 150, 50
    f.text(20, 22, "A layer's display window, inside the picture", bold=True)
    f.rect(L, T, VID_W * s, VID_H * s, PICTURE)
    # window 184-824 x 97-577 as the example -> picture coords
    x0, x1, y0, y1 = 248, 760, 145, 529
    X = lambda b: L + (b - VID_X0) * s
    Y = lambda b: T + (b - VID_Y0) * s
    f.rect(X(x0), Y(y0), (x1 - x0) * s, (y1 - y0) * s, HILITE, sw=2)
    f.text((X(x0) + X(x1)) / 2, (Y(y0) + Y(y1)) / 2 - 6, "the layer's pixels", size=14, anchor="middle", bold=True)
    f.text((X(x0) + X(x1)) / 2, (Y(y0) + Y(y1)) / 2 + 12, "XSTART ≤ hpixel < XEND", size=12, anchor="middle")
    f.text((X(x0) + X(x1)) / 2, (Y(y0) + Y(y1)) / 2 + 28, "YSTART ≤ vline < YEND", size=12, anchor="middle")
    f.text(L + 8, T + 18, "outside the window the layer is transparent and fetches nothing", size=11, fill=TXT2)
    # labels
    for b, lab in ((x0, "XSTART 248"), (x1, "XEND 760")):
        f.line(X(b), T + VID_H * s, X(b), T + VID_H * s + 14, stroke=DIM, dash="3 3")
        f.line(X(b), Y(y1), X(b), T + VID_H * s, stroke=DIM, dash="3 3")
        f.text(X(b), T + VID_H * s + 27, lab, size=11, anchor="middle")
    for b, lab in ((y0, "YSTART 145"), (y1, "YEND 529")):
        f.line(L - 14, Y(b), X(x0), Y(b), stroke=DIM, dash="3 3")
        f.text(L - 18, Y(b) + 4, lab, size=11, anchor="end")
    f.text(L, T - 6, "(144, 49)", size=11, anchor="middle", fill=TXT2)
    f.text(L + VID_W * s, T - 6, "864", size=11, anchor="middle", fill=TXT2)
    f.text(L + VID_W * s + 6, T + VID_H * s, "625", size=11, fill=TXT2)
    f.text(L + VID_W * s / 2, T + VID_H * s + 48, "XEND and YEND are the first pixel and line after the window", size=11, anchor="middle", fill=TXT2)
    return f.save("playfields-3-3-window.svg")


# ---------------------------------------------------------------- 3-4 (new): scaling
def fig_scaling():
    f = Fig(760, 300)
    f.text(20, 22, "Scaling: four source pixels at HSCALE 1×, 2×, 4× and 8×", bold=True)
    cols = ["#6fa8dc", "#f6b26b", "#93c47d", "#c27ba0"]
    L, px = 80, 18
    for i, sc in enumerate((1, 2, 4, 8)):
        y = 50 + i * 52
        f.text(L - 12, y + 18, f"{sc}×", size=13, anchor="end", bold=True)
        for p in range(4):
            for r in range(sc):
                x = L + (p * sc + r) * px
                f.rect(x, y, px, 26, cols[p], stroke=WHITE)
            f.rect(L + p * sc * px, y, sc * px, 26, "none", stroke=LINE, sw=1.5)
        f.text(L + 4 * sc * px + 8, y + 18, f"{4 * sc} beam pixels", size=11, fill=TXT2)
    yb = 50 + 4 * 52 + 22
    f.text(20, yb, "Each square is one beam pixel. Vertical scaling (VSCALE) repeats each source line the same way;", size=11, fill=TXT2)
    f.text(20, yb + 15, "the hardware fetches the line again for every copy, so it saves memory and drawing time, not bandwidth.", size=11, fill=TXT2)
    return f.save("playfields-3-4-scaling.svg")


# ---------------------------------------------------------------- 3-5: stride
def fig_stride():
    f = Fig(760, 370)
    f.text(20, 22, "A window narrower than the picture: the stride is still the picture's", bold=True)
    # 2D view
    L, T, w, h = 40, 50, 320, 130
    f.rect(L, T, w, h, UNSHOWN)
    f.rect(L + 40, T + 20, w / 2, h - 50, HILITE)
    f.text(L + 40 + w / 4, T + 20 + (h - 50) / 2 + 4, "shown", size=12, anchor="middle")
    f.text(L + w / 2, T - 6, "the picture: 640 pixels at 1 bpp = 80 bytes a line", size=11, anchor="middle")
    f.text(L + w / 2, T + h + 16, "the window shows 320 of them", size=11, anchor="middle", fill=TXT2)
    # memory strip
    ML, MT = 400, 70
    f.text(ML, MT - 16, "in memory, line after line:", size=11)
    bw = 3.4
    y = MT
    for line in range(3):
        x = ML
        # 5 bytes unshown, 40 shown, 35 unshown, scaled to 80 bytes total
        segs = [(5, UNSHOWN), (40, HILITE), (35, UNSHOWN)]
        for n, col in segs:
            f.rect(x, y, n * bw, 24, col)
            x += n * bw
        f.text(ML - 6, y + 16, f"y+{line}" if line else "y", size=11, anchor="end")
        y += 34
    f.dim(ML, ML + 80 * bw, MT + 3 * 34 + 10, "BPLSTRIDE = 80 bytes", above=False)
    f.text(ML, MT + 3 * 34 + 44, "next line's start = this line's start + BPLSTRIDE,", size=11, fill=TXT2)
    f.text(ML, MT + 3 * 34 + 58, "whatever the window width, scale or fine scroll", size=11, fill=TXT2)
    # bottom: one line in detail
    yb = 295
    f.text(20, yb - 14, "One line: the pointer walks through the shown part, then jumps by BPLSTRIDE from the line's start", size=11)
    x = 40
    segs = [(5, UNSHOWN, ""), (40, HILITE, "fetched: the pointer + 2 per word"), (35, UNSHOWN, "not fetched")]
    for n, col, lab in segs:
        f.rect(x, yb, n * 8, 26, col)
        if lab:
            f.text(x + n * 4, yb + 17, lab, size=11, anchor="middle")
        x += n * 8
    f.rect(x, yb, 10 * 8, 26, UNSHOWN, dash="4 3")
    f.text(x + 40, yb + 17, "line y+1 …", size=11, anchor="middle")
    f.line(40 + 5 * 8, yb + 40, 40 + 5 * 8 + 80 * 8, yb + 40, stroke=DIM, arrow="end")
    f.text(40 + 5 * 8, yb + 54, "start of line y (saved at the first fetch)", size=10, fill=TXT2)
    f.text(40 + 85 * 8, yb + 54, "start of line y+1", size=10, anchor="end", fill=TXT2)
    return f.save("playfields-3-5-stride.svg")


# ---------------------------------------------------------------- 3-9: map wrap
def fig_mapwrap():
    f = Fig(760, 360)
    f.text(20, 22, "The view wraps round the map", bold=True)
    L, T, W, H = 60, 50, 400, 260
    f.rect(L, T, W, H, UNSHOWN)
    for c in range(1, 16):
        f.line(L + c * W / 16, T, L + c * W / 16, T + H, stroke="#e0e0e0")
    for r in range(1, 10):
        f.line(L, T + r * H / 10, L + W, T + r * H / 10, stroke="#e0e0e0")
    f.rect(L, T, W, H, "none", sw=2)
    f.text(L, T - 6, "(0, 0)", size=11, anchor="middle", fill=TXT2)
    f.text(L + W, T - 6, "8 × MW", size=11, anchor="middle", fill=TXT2)
    f.text(L - 6, T + H + 4, "8 × MH", size=11, anchor="end", fill=TXT2)
    # view starting at (sx, sy), size vw x vh, crossing right and bottom edges
    sx, sy, vw, vh = 300, 170, 170, 130
    parts = [
        (sx, sy, W - sx, H - sy, "A"),
        (0, sy, vw - (W - sx), H - sy, "B"),
        (sx, 0, W - sx, vh - (H - sy), "C"),
        (0, 0, vw - (W - sx), vh - (H - sy), "D"),
    ]
    for x, y, w, h, lab in parts:
        f.rect(L + x, T + y, w, h, HILITE, sw=1.5)
        f.text(L + x + w / 2, T + y + h / 2 + 5, lab, size=15, anchor="middle", bold=True)
    f.rect(L + sx - 3, T + sy - 3, 6, 6, LINE)
    f.text(L + sx - 6, T + sy - 6, "(SCROLLX, SCROLLY)", size=11, anchor="end", halo=True)
    # assembled view on the right
    R = 520
    f.text(R, T + 4, "what the window shows:", size=12)
    k = 1.0
    ox, oy = R, T + 20
    a_w, a_h = W - sx, H - sy
    for x, y, w, h, lab in ((0, 0, a_w, a_h, "A"), (a_w, 0, vw - a_w, a_h, "B"), (0, a_h, a_w, vh - a_h, "C"), (a_w, a_h, vw - a_w, vh - a_h, "D")):
        f.rect(ox + x * k, oy + y * k, w * k, h * k, HILITE, sw=1.5)
        f.text(ox + (x + w / 2) * k, oy + (y + h / 2) * k + 5, lab, size=15, anchor="middle", bold=True)
    f.text(R, oy + vh + 20, "window width ÷ HS source pixels", size=11, fill=TXT2)
    f.text(R, oy + vh + 34, "by window height ÷ VS lines", size=11, fill=TXT2)
    f.text(L, T + H + 30, "Off the right edge the view carries on at the left; off the bottom, at the top.", size=11, fill=TXT2)
    return f.save("playfields-3-9-mapwrap.svg")


# ---------------------------------------------------------------- 3-10: split screen
def fig_split():
    s = 0.5
    f = Fig(760, int(625 * s) + 60)
    L, T = 40, 40
    f.text(20, 22, "A split screen from two layers, to scale", bold=True)
    f.rect(L, T, 864 * s, 625 * s, BLANK)
    f.rect(L + 144 * s, T + 49 * s, 720 * s, 576 * s, PICTURE)
    f.rect(L + 144 * s, T + 81 * s, 720 * s, (529 - 81) * s, HILITE)
    f.text(L + 504 * s, T + 290 * s, "layer 1: game area", size=13, anchor="middle", bold=True)
    f.text(L + 504 * s, T + 290 * s + 16, "tile map, 4 bpp, 2×, scrolling", size=11, anchor="middle")
    f.rect(L + 144 * s, T + 529 * s, 720 * s, 64 * s, CPU)
    f.text(L + 504 * s, T + 565 * s, "layer 0: status panel, text", size=11, anchor="middle")
    R = L + 864 * s + 20
    for v, lab in ((49, "49: picture starts"), (81, "81: layer 1's YSTART"), (529, "529: layer 1's YEND = layer 0's YSTART"), (593, "593: layer 0's YEND"), (625, "625")):
        f.line(L + 864 * s, T + v * s, R - 4, T + v * s, stroke=DIM, dash="3 3")
        f.text(R, T + v * s + 4, lab, size=11)
    f.text(R, T + 340 * s, "Bands that do not overlap", size=11, fill=TXT2)
    f.text(R, T + 340 * s + 14, "cost no extra bandwidth: each", size=11, fill=TXT2)
    f.text(R, T + 340 * s + 28, "layer fetches only on its own lines.", size=11, fill=TXT2)
    return f.save("playfields-3-10-split.svg")


# ---------------------------------------------------------------- 3-11: choosing a pixel
def fig_priority():
    f = Fig(760, 330)
    f.text(20, 22, "Choosing a pixel: looking from the front, the first one that is not transparent is shown", bold=True)
    planes = [
        ("sprites", "DEPTH 0", SPRITE),
        ("PRI tiles", "any layer", "#ea9999"),
        ("FRONT", "here L1", HILITE),
        ("sprites", "DEPTH 1", SPRITE),
        ("MIDDLE", "here L0", HILITE),
        ("sprites", "DEPTH 2", SPRITE),
        ("BACK", "here L2", HILITE),
        ("sprites", "DEPTH 3", SPRITE),
        ("BGCOLOR", "background", BLANK),
    ]
    L, gap, pw, ph, skew = 90, 70, 34, 150, 30
    y0 = 70
    # eye
    f.text(30, y0 + ph / 2 + 30, "front", size=11, anchor="middle", fill=TXT2)
    f.parts.append(f'<ellipse cx="30" cy="{y0 + ph / 2 + 4}" rx="12" ry="7" fill="#fff" stroke="{LINE}"/>')
    f.parts.append(f'<circle cx="32" cy="{y0 + ph / 2 + 4}" r="4" fill="{LINE}"/>')
    f.line(40, y0 + ph / 2 + 4, L + 8 * gap + pw + 30, y0 + ph / 2 + 4, stroke=DIM, dash="5 4", arrow="end")
    for i, (a, b, col) in enumerate(planes):
        x = L + i * gap
        f.poly([(x, y0 + skew), (x + pw, y0), (x + pw, y0 + ph - skew), (x, y0 + ph)], fill=col, stroke=LINE)
        f.text(x + pw / 2, y0 + ph + 22, a, size=12, anchor="middle", bold=True)
        f.text(x + pw / 2, y0 + ph + 37, b, size=11, anchor="middle", fill=TXT2)
    f.text(L + 8 * gap + pw / 2, y0 - 12, "back", size=11, anchor="middle", fill=TXT2)
    f.text(20, y0 + ph + 70, "Layers take the places PRIO gives them (here PRIO = L1, L0, L2). A layer is transparent outside its window,", size=11, fill=TXT2)
    f.text(20, y0 + ph + 84, "where its data was late, and where its pixel is 0 if CTRL0.TRANSP is set.", size=11, fill=TXT2)
    return f.save("playfields-3-11-priority.svg")


# ---------------------------------------------------------------- 3-12: palette offsets
def fig_palofs():
    f = Fig(760, 240)
    f.text(20, 22, "Palette offsets: PALOFS picks one of 16 blocks of 16 entries", bold=True)
    L, T, W = 40, 90, 680
    bw = W / 16
    for b in range(16):
        col = PICTURE if b not in (0, 1, 2) else HILITE
        f.rect(L + b * bw, T, bw, 34, col)
        f.text(L + b * bw + bw / 2, T + 21, str(b), size=11, anchor="middle")
        f.text(L + b * bw, T + 50, str(b * 16), size=10, anchor="middle", fill=TXT2)
    f.text(L + W, T + 50, "256", size=10, anchor="middle", fill=TXT2)
    f.text(L, T - 30, "", size=1)
    ex = [(0, 4, "2 bpp, PALOFS 0: entries 0-3"), (1, 2, "1 bpp, PALOFS 1: 16-17"), (2, 16, "4 bpp, PALOFS 2: 32-47")]
    for i, (b, n, lab) in enumerate(ex):
        x0 = L + b * bw
        x1 = x0 + bw * n / 16
        f.rect(x0, T - 10, x1 - x0, 6, LINE, stroke="none")
        f.line((x0 + x1) / 2, T - 10, (x0 + x1) / 2 + 30 + i * 120, T - 32 - i * 0, stroke=DIM)
        f.text((x0 + x1) / 2 + 32 + i * 120, T - 36, lab, size=11)
    f.text(L, T + 80, "An 8 bpp layer uses all 256 entries directly; PALOFS does not apply.", size=11, fill=TXT2)
    f.text(L, T + 95, "A tile's PAL is added to PALOFS (mod 16), so each tile can pick its own block.", size=11, fill=TXT2)
    return f.save("playfields-3-12-palofs.svg")


# ---------------------------------------------------------------- 3-13: the fetch budget across a line
def fig_budget():
    f = Fig(760, 440)
    f.text(20, 22, "The budget applies at every point across the screen", bold=True)
    L, W = 90, 640
    k = W / 720
    scale = 80  # px per byte/pixel

    def panel(T, title, layers):
        f.text(L, T - 8, title, size=12, bold=True)
        base = T + 1.7 * scale
        f.line(L, base, L + W, base, stroke=LINE)
        f.line(L, T, L, base, stroke=LINE)
        for v in (0.5, 1.0, 1.5):
            f.line(L - 4, base - v * scale, L, base - v * scale, stroke=DIM)
            f.text(L - 8, base - v * scale + 4, f"{v}", size=10, anchor="end", fill=TXT2)
        f.text(L - 8, base + 4, "0", size=10, anchor="end", fill=TXT2)
        acc = {}
        xs = sorted({144, 864} | {x for l in layers for x in l[1:3]})
        for name, x0, x1, cost, col in layers:
            for a, b in zip(xs, xs[1:]):
                if a >= x0 and b <= x1:
                    h = acc.get(a, 0)
                    f.rect(L + (a - 144) * k, base - (h + cost) * scale, (b - a) * k, cost * scale, col)
                    acc[a] = h + cost
            f.text(L + ((x0 + x1) / 2 - 144) * k, base - (acc[x0] - cost / 2) * scale + 4, f"{name}: {cost}", size=11, anchor="middle")
        tot = max(acc.values())
        f.text(L + (504 - 144) * k, base - tot * scale - 6, f"total {tot}", size=11, anchor="middle", bold=True)
        y = base - 1.48 * scale
        f.line(L, y, L + W, y, stroke="#c00000", sw=1.5, dash="6 3")
        f.text(L + W, y - 5, "budget 1.48", size=11, anchor="end", fill="#c00000")
        for p in (144, 184, 824, 864):
            f.text(L + (p - 144) * k, base + 14, str(p), size=10, anchor="middle", fill=TXT2)
        return base

    panel(60, "Example 3-7: 4 bpp tiles at 2× (whole picture) + 1 bpp text at 1× (window 184-824): 0.875 at most. Fits",
          [("tiles", 144, 864, 0.375, PICTURE), ("text", 184, 824, 0.5, CPU)])
    panel(240, "8 bpp bitmap at 1× + 1 bpp text at 1× in the same window: 1.5 inside 184-824. Just over",
          [("8 bpp bitmap", 144, 864, 1.0, HILITE), ("text", 184, 824, 0.5, CPU)])
    f.text(20, 60 + 70, "bytes per", size=10, fill=TXT2)
    f.text(20, 60 + 82, "pixel", size=10, fill=TXT2)
    f.text(L, 420, "beam pixel across the picture; the sum must stay under the budget at every point", size=11, fill=TXT2)
    return f.save("playfields-3-13-budget.svg")


if __name__ == "__main__":
    for fn in (fig_beam, fig_window, fig_scaling, fig_stride, fig_mapwrap, fig_split, fig_priority, fig_palofs, fig_budget):
        print(fn())
