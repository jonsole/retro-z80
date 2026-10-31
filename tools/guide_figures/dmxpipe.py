"""Figures for spec 14 (docs/spec/dma-engine.md), section 6: how the DMA
engine's groups use their memory cycles, and the ways to speed them up
(open point D2).

Run as `python dmxpipe.py` from this directory; the SVGs go to
docs/spec/img. Drawn to scale in 10 ns clocks. The phase lengths are the
model in spec 14, section 6.1, which matches the simulation's 22 clocks
for an 8-word fill group and 44 for a copy group.
"""

import os

import svgfig
from svgfig import Fig, TXT, TXT2, LINE, DIM, POOL, CPU, HILITE, UNSHOWN, WHITE

svgfig.OUT = os.path.join(os.path.dirname(__file__), "..", "..", "docs", "spec", "img")
os.makedirs(svgfig.OUT, exist_ok=True)

READ = "#9fc5e8"       # a read cycle
WRITE = HILITE         # a write cycle
IDLE = "#e06666"       # a clock the engine could have used and did not
BOOK = UNSHOWN         # bookkeeping states (no memory cycle)

# One 8-word group today, as phases of (label, clocks, kind). Kinds: "book"
# (no memory), "rd" (reads, 2 clocks each), "wr" (writes), "idle" (waiting).
COPY = [("set-up", 1, "idle"), ("8 reads", 16, "rd"), ("wait for data", 6, "idle"),
        ("C step", 1, "idle"), ("fill pipe", 2, "idle"), ("8 writes", 16, "wr"),
        ("drain", 2, "idle")]
FILL = [("set-up", 1, "idle"), ("C step", 1, "idle"), ("fill pipe", 2, "idle"),
        ("8 writes", 16, "wr"), ("drain", 2, "idle")]


def cycles(f, x, y, n, kind, px, h=22):
    """n memory cycles of 2 clocks each, numbered."""
    fill = READ if kind == "rd" else WRITE
    tag = "R" if kind == "rd" else "W"
    for i in range(n):
        f.rect(x + i * 2 * px, y, 2 * px, h, fill=fill)
        f.text(x + i * 2 * px + px, y + h / 2 + 4, f"{tag}{i + 1}", size=9, anchor="middle")


def idle(f, x, y, clocks, px, h=22):
    f.rect(x, y, clocks * px, h, fill=IDLE, stroke=LINE)


def timeline(f, x0, y, phases, px, label, total_label):
    f.text(x0 - 10, y + 15, label, anchor="end", bold=True)
    x = x0
    for name, n, kind in phases:
        if kind == "rd" or kind == "wr":
            cycles(f, x, y, n // 2, kind, px)
        else:
            idle(f, x, y, n, px)
        x += n * px
    # phase names under the bar
    x = x0
    for name, n, kind in phases:
        w = n * px
        if kind in ("rd", "wr"):
            f.text(x + w / 2, y - 5, name, size=11, anchor="middle", fill=TXT2)
        x += n * px
    total = sum(n for _, n, _ in phases)
    f.text(x0 + total * px + 8, y + 15, total_label, size=12)
    return total


def fig_today():
    px = 13
    x0 = 90
    f = Fig(760, 300)
    f.text(20, 24, "One 8-word group today, clock by clock (10 ns a clock; a memory cycle is 2 clocks)",
           size=15, bold=True)
    # clock ruler
    ry = 52
    for c in range(0, 45, 2):
        xx = x0 + c * px
        f.line(xx, ry, xx, ry + (6 if c % 4 else 9), stroke=DIM)
        if c % 4 == 0:
            f.text(xx, ry - 4, str(c), size=10, anchor="middle", fill=TXT2)
    f.line(x0, ry, x0 + 44 * px, ry, stroke=DIM)
    f.text(x0 - 10, ry + 4, "clock", size=11, anchor="end", fill=TXT2)

    t = timeline(f, x0, 74, COPY, px, "Copy", "44 clocks")
    # read data coming back 4 clocks after each read's grant
    x = x0 + 1 * px
    for i in range(8):
        sx = x + i * 2 * px + px
        dx = x + (i * 2 + 4) * px + px
        f.line(sx, 97, dx, 120, stroke=DIM, arrow="end")
    f.text(x0 + 13 * px, 134, "each read's data comes back 40 ns after its cycle",
           size=11, anchor="middle", fill=TXT2)
    f.text(x0, 150, "Idle: set-up 1, waiting for the last read's data 6, the C step 1, filling the write pipeline 2, draining it 2.",
           size=11, fill=TXT2)
    f.text(x0, 166, "16 of 22 memory cycles used: 6 lost.", size=12)

    timeline(f, x0, 202, FILL, px, "Fill", "22 clocks")
    f.text(x0, 240, "Idle: set-up 1, the C step 1, filling the write pipeline 2, draining it 2. 8 of 11 memory cycles used: 3 lost.",
           size=11, fill=TXT2)

    # legend
    ly = 270
    f.rect(x0, ly, 22, 14, fill=READ); f.text(x0 + 28, ly + 11, "read cycle", size=11)
    f.rect(x0 + 110, ly, 22, 14, fill=WRITE); f.text(x0 + 138, ly + 11, "write cycle", size=11)
    f.rect(x0 + 225, ly, 22, 14, fill=IDLE)
    f.text(x0 + 253, ly + 11, "idle clocks: a free memory cycle here is lost", size=11)
    f.save("dma-engine-1-group-today.svg")


def fig_options():
    """16 words of a copy in the middle of a long row, five ways."""
    px = 5.2
    x0 = 180
    f = Fig(760, 372)
    f.text(20, 24, "16 words of a copy in the middle of a long row, five ways (to scale)", size=15, bold=True)

    def grp(words, wait, setup, cstep, fillp, drain):
        return [("", setup, "idle"), ("", words * 2, "rd"), ("", wait, "idle"), ("", cstep, "idle"),
                ("", fillp, "idle"), ("", words * 2, "wr"), ("", drain, "idle")]

    def row(y, label, sub, phases, total, pct):
        f.text(x0 - 10, y + 12, label, anchor="end", bold=True, size=12)
        f.text(x0 - 10, y + 26, sub, anchor="end", size=10, fill=TXT2)
        x = x0
        for _, n, kind in phases:
            if n == 0:
                continue
            if kind == "rd":
                f.rect(x, y, n * px, 22, fill=READ)
            elif kind == "wr":
                f.rect(x, y, n * px, 22, fill=WRITE)
            elif kind == "mix":
                for i in range(n // 2):
                    f.rect(x + i * 2 * px, y, 2 * px, 22, fill=READ if i % 2 == 0 else WRITE)
            else:
                f.rect(x, y, n * px, 22, fill=IDLE)
            x += n * px
        f.text(x + 8, y + 15, f"{total} clocks: {pct}", size=12)

    today = grp(8, 6, 1, 1, 2, 2)
    row(50, "Today", "two 8-word groups", today + today, 88, "73%")
    trim = grp(8, 3, 1, 0, 1, 1)   # 38 clocks a group
    row(110, "A. Less bookkeeping", "two 8-word groups", trim + trim, 76, "84%")
    big = grp(16, 6, 1, 1, 2, 2)
    row(170, "B. 16-word groups", "one group", big, 76, "84%")
    both = grp(16, 3, 1, 0, 1, 1)
    row(230, "A and B", "one group", both, 70, "91%")
    row(290, "C. Overlapped groups", "reads of the next group", [("", 64, "mix")], 64, "about 100%")
    f.text(x0 - 10, 290 + 40, "between this one's writes", anchor="end", size=10, fill=TXT2)

    ly = 346
    f.rect(x0, ly, 22, 14, fill=READ); f.text(x0 + 28, ly + 11, "read", size=11)
    f.rect(x0 + 80, ly, 22, 14, fill=WRITE); f.text(x0 + 108, ly + 11, "write", size=11)
    f.rect(x0 + 165, ly, 22, 14, fill=IDLE); f.text(x0 + 193, ly + 11, "idle clocks", size=11)
    f.save("dma-engine-2-options.svg")


if __name__ == "__main__":
    fig_today()
    fig_options()
