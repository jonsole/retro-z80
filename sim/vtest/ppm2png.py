#!/usr/bin/env python3
"""A frame the testbench grabbed (P3 PPM) as a PNG, to look at.

    ppm2png.py FRAME.ppm OUT.png
"""
import sys

from PIL import Image


def main():
    t = open(sys.argv[1]).read().split()
    assert t[0] == "P3"
    w, h = int(t[1]), int(t[2])
    v = list(map(int, t[4:]))
    im = Image.new("RGB", (w, h))
    im.putdata([tuple(v[i:i + 3]) for i in range(0, len(v), 3)])
    im.save(sys.argv[2])


if __name__ == "__main__":
    main()
