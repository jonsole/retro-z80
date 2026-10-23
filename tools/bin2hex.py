#!/usr/bin/env python3
"""Turn a binary into a $readmemh file of 16-bit little-endian words.

    bin2hex.py in.bin out.hex [words]

The SRAM and the boot ROM are 16 bits wide and little-endian (spec 2): the
byte at an even address is the low half of its word. Pads with zeros to
`words` (default 16384, the 32 KB boot ROM).

Adapted from retro68k's tools/bin2hex.py (which writes big-endian words).
"""
import sys


def main():
    src, dst = sys.argv[1], sys.argv[2]
    words = int(sys.argv[3]) if len(sys.argv) > 3 else 16384
    data = open(src, "rb").read()
    if len(data) % 2:
        data += b"\0"
    if len(data) > 2 * words:
        sys.exit(f"bin2hex: {src} is {len(data)} bytes, more than {2 * words}")
    data += b"\0" * (2 * words - len(data))
    with open(dst, "w") as f:
        for i in range(0, len(data), 2):
            f.write(f"{data[i + 1]:02x}{data[i]:02x}\n")


if __name__ == "__main__":
    main()
