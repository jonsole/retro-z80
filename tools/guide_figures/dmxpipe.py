"""Figure 6-12 for Chapter 6 (docs/guide/blitter.md): what one destination
word of a blitter job, and one pixel of a line, costs in memory accesses and
time.

Run as `python dmxpipe.py` from this directory; the SVG goes to
docs/guide/img. The bars are drawn to scale in 10 ns clocks, at the times
the cores' design gives (spec 14, section 7; spec 19, section 9). Where in
the bar each memory access falls is schematic. The right-hand column is
what the KS2 measured with the screen off (Example 6-8, Table 6-21).
"""

import os

import svgfig
from svgfig import Fig, TXT, TXT2, LINE, DIM, HILITE, UNSHOWN, WHITE

svgfig.OUT = os.path.join(os.path.dirname(__file__), "..", "..", "docs", "guide", "img")
os.makedirs(svgfig.OUT, exist_ok=True)

READ = "#9fc5e8"       # a read cycle
WRITE = HILITE         # a write cycle
STEP = UNSHOWN         # the core's own clocks

# (name, minterm and options, accesses in order, design time in ns, measured ns)
ROWS = [
    ("Fill", "0xCC, BCONST", ["W"], 80, "80"),
    ("Copy", "0xCC", ["R B", "W"], 120, "120"),
    ("XOR with a constant", "0x66, BCONST", ["R C", "W"], 120, "120"),
    ("Cookie-cut, key colour", "0xCA, MASK = 2", ["R B", "R C", "W"], 160, "180*"),
    ("Line pixel", "0xCC", ["W"], 100, "110"),
    ("Line pixel, XOR", "0x66", ["R C", "W"], 150, "177"),
]


def fig_accesses():
    f = Fig(760, 380)
    f.text(20, 22, "One destination word of a blit, or one pixel of a line: memory accesses and time", bold=True)
    L = 230                 # where time 0 is
    PX = 2.1                # pixels a nanosecond
    T, RH = 78, 36
    # the time axis
    for ns in range(0, 201, 20):
        x = L + ns * PX
        f.line(x, T - 14, x, T + len(ROWS) * RH - 6, stroke="#e3e3e3")
        f.text(x, T - 18, str(ns), size=11, anchor="middle", fill=TXT2)
    f.text(L + 200 * PX + 16, T - 18, "ns", size=11, fill=TXT2)
    f.text(L + 200 * PX + 70, T - 18, "KS2", size=11, anchor="middle", fill=TXT2)
    for r, (name, opts, acc, ns, meas) in enumerate(ROWS):
        y = T + r * RH
        f.text(20, y + 12, name, size=13)
        f.text(20, y + 26, opts, size=11, fill=TXT2)
        f.rect(L, y, ns * PX, 24, STEP, stroke=DIM)
        # the accesses, 20 ns each, spread over the bar
        gap = (ns - 20 * len(acc)) / len(acc)
        x = L + gap * PX / 2
        for a in acc:
            f.rect(x, y + 2, 20 * PX, 20, WRITE if a == "W" else READ, stroke=LINE)
            f.text(x + 10 * PX, y + 16, a, size=11, anchor="middle")
            x += (20 + gap) * PX
        f.text(L + ns * PX + 6, y + 16, f"{ns}", size=11, fill=TXT2)
        f.text(L + 200 * PX + 70, y + 16, meas, size=11, anchor="middle")
    yl = T + len(ROWS) * RH + 18
    f.rect(L, yl - 11, 14, 14, READ)
    f.text(L + 20, yl, "a read: 20 ns", size=11)
    f.rect(L + 120, yl - 11, 14, 14, WRITE)
    f.text(L + 140, yl, "a write: 20 ns", size=11)
    f.rect(L + 240, yl - 11, 14, 14, STEP, stroke=DIM)
    f.text(L + 260, yl, "the core's own steps", size=11)
    f.text(20, yl + 28, "A word is 2 bytes: two pixels at 8 bpp. The bars are the design's times, to scale; where each access falls is schematic.", size=11, fill=TXT2)
    f.text(20, yl + 44, "KS2: measured with the screen off. * A 32 × 32 job, its start included.", size=11, fill=TXT2)
    return f.save("blitter-6-12-accesses.svg")


if __name__ == "__main__":
    print(fig_accesses())
