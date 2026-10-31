"""Tables for the geometry examples (docs/guide/geometry.md), written as
sine.inc beside this file:

    sine    256 words, sin(2 pi a / 256) in 2.14 (16384 = 1.0), a = 0..255.
            cos a = sin (a + 64).

    python tables.py
"""

import math
from pathlib import Path


def main():
    out = ["; sine.inc: made by tables.py, do not edit. sin(2 pi a / 256) in 2.14",
           "; (0x4000 = 1.0) for a = 0..255; cos a is sine + 2 * ((a + 64) & 255).",
           "        align   2",
           "sine:"]
    vals = [round(math.sin(2 * math.pi * a / 256) * 16384) for a in range(256)]
    for i in range(0, 256, 8):
        out.append("        dw      " + ", ".join(str(v) for v in vals[i:i + 8]))
    Path(__file__).with_name("sine.inc").write_text("\n".join(out) + "\n", newline="\n")


if __name__ == "__main__":
    main()
