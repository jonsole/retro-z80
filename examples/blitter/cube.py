"""Points for Example 6-6 (docs/guide/blitter.md): a cube turning and
drifting across the screen, projected for 64 frames, written as cube.inc.

Each frame is the cube's 8 points as EDGES wants them: x, then y, signed
16-bit words, in pixels from the screen's top left corner.

    python cube.py          (writes cube.inc beside this file)
"""

import math
from pathlib import Path

FRAMES = 64
SIZE = 60          # half the cube's side
DIST = 300         # the eye's distance from the cube's centre
SCALE = 330        # the projection's scale
CENTRE_Y = 144


def frame_points(f):
    t = 2 * math.pi * f / FRAMES
    ay, ax = t, 2 * t          # turns about y once and about x twice a loop
    cx = 180 + 150 * math.sin(t)   # drifts beyond the clip rectangle's sides
    pts = []
    for i in range(8):
        x = SIZE if i & 1 else -SIZE
        y = SIZE if i & 2 else -SIZE
        z = SIZE if i & 4 else -SIZE
        x, z = x * math.cos(ay) + z * math.sin(ay), -x * math.sin(ay) + z * math.cos(ay)
        y, z = y * math.cos(ax) - z * math.sin(ax), y * math.sin(ax) + z * math.cos(ax)
        k = SCALE / (z + DIST)
        pts.append((round(cx + x * k), round(CENTRE_Y + y * k)))
    return pts


def main():
    out = ["; cube.inc: made by cube.py, do not edit. 64 frames of a cube's 8",
           "; points: x, y as signed words, 4 bytes a point, 32 bytes a frame.",
           "cube_pts:"]
    for f in range(FRAMES):
        pts = frame_points(f)
        out.append("        dw      " + ", ".join(f"{x}, {y}" for x, y in pts)
                   + f"   ; frame {f}")
    out.append("cube_pts_end:")
    Path(__file__).with_name("cube.inc").write_text("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
