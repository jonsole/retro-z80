"""Small helper for the programmer's guide figures (docs/guide/img).

Each figure is an SVG drawn to the style in docs/guide/img/README.md:
white background, Helvetica/Arial, the shared fill colours below.
"""

import os
from xml.sax.saxutils import escape

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "docs", "guide", "img")

TXT = "#1a1a1a"
TXT2 = "#555"
LINE = "#333"
DIM = "#777"
BLANK = "#d9d9d9"
PICTURE = "#cfe2f3"
CPU = "#b6d7a8"
DISPLAY = "#f9cb9c"
POOL = "#ffe599"
SPRITE = "#d5a6bd"
HILITE = "#f4b183"
UNSHOWN = "#f3f3f3"
WHITE = "#ffffff"


def fmt(v):
    """Coordinates with at most two decimals."""
    if isinstance(v, float):
        s = f"{v:.2f}".rstrip("0").rstrip(".")
        return s if s != "-0" else "0"
    return str(v)


class Fig:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.parts = []

    def _attrs(self, **kw):
        out = []
        for k, v in kw.items():
            if v is None:
                continue
            k = k.rstrip("_").replace("_", "-")
            out.append(f'{k}="{fmt(v)}"')
        return " ".join(out)

    def rect(self, x, y, w, h, fill=WHITE, stroke=LINE, dash=None, sw=1, rx=None):
        self.parts.append(
            f"<rect {self._attrs(x=x, y=y, width=w, height=h, rx=rx, fill=fill, stroke=stroke, stroke_width=sw if stroke != 'none' else None, stroke_dasharray=dash)}/>"
        )

    def line(self, x1, y1, x2, y2, stroke=LINE, sw=1, dash=None, arrow=None):
        marker = {None: None, "end": "url(#ah)", "both": "url(#ah)"}[arrow]
        start = "url(#ahs)" if arrow == "both" else None
        self.parts.append(
            f"<line {self._attrs(x1=x1, y1=y1, x2=x2, y2=y2, stroke=stroke, stroke_width=sw, stroke_dasharray=dash, marker_end=marker, marker_start=start)}/>"
        )

    def poly(self, pts, fill="none", stroke=LINE, sw=1, dash=None, closed=True):
        p = " ".join(f"{fmt(x)},{fmt(y)}" for x, y in pts)
        tag = "polygon" if closed else "polyline"
        self.parts.append(
            f'<{tag} points="{p}" {self._attrs(fill=fill, stroke=stroke, stroke_width=sw, stroke_dasharray=dash)}/>'
        )

    def text(self, x, y, s, size=13, anchor="start", fill=TXT, bold=False, italic=False, rotate=None, halo=False):
        if not s:
            return
        tr = f' transform="rotate({rotate} {fmt(x)} {fmt(y)})"' if rotate else ""
        h = ' stroke="#ffffff" stroke-width="4" stroke-linejoin="round" paint-order="stroke"' if halo else ""
        self.parts.append(
            f"<text {self._attrs(x=x, y=y, font_size=size, text_anchor=anchor, fill=fill, font_weight='bold' if bold else None, font_style='italic' if italic else None)}{h}{tr}>{escape(s)}</text>"
        )

    def dim(self, x1, x2, y, label, size=11, above=True, fill=TXT2):
        """A horizontal dimension line with arrows at both ends."""
        self.line(x1, y, x2, y, stroke=DIM, arrow="both")
        self.text((x1 + x2) / 2, y - 4 if above else y + 13, label, size=size, anchor="middle", fill=fill)

    def vdim(self, x, y1, y2, label, size=11, left=True, fill=TXT2):
        self.line(x, y1, x, y2, stroke=DIM, arrow="both")
        self.text(x - 5 if left else x + 5, (y1 + y2) / 2 + 4, label, size=size, anchor="end" if left else "start", fill=fill)

    def svg(self):
        head = (
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.w}" height="{self.h}" '
            f'viewBox="0 0 {self.w} {self.h}" font-family="Helvetica, Arial, sans-serif" font-size="13">\n'
            "<defs>"
            '<marker id="ah" viewBox="0 0 10 10" refX="10" refY="5" markerWidth="7" markerHeight="7" orient="auto">'
            f'<path d="M0,0 L10,5 L0,10 z" fill="{DIM}"/></marker>'
            '<marker id="ahs" viewBox="0 0 10 10" refX="0" refY="5" markerWidth="7" markerHeight="7" orient="auto">'
            f'<path d="M10,0 L0,5 L10,10 z" fill="{DIM}"/></marker>'
            "</defs>\n"
            f'<rect width="{self.w}" height="{self.h}" fill="{WHITE}"/>\n'
        )
        return head + "\n".join(self.parts) + "\n</svg>\n"

    def save(self, name):
        path = os.path.join(OUT, name)
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(self.svg())
        return path
