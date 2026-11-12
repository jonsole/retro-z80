#!/usr/bin/env python3
"""Sample data for the sound test (atest.asm; spec 13): random signed bytes
and words. retro68k's sim/atest/agen.py (hw-audio, d706cd2): the same data.

    agen.py OUT.hex

Writes a $readmemh file of 16-bit words with @word-address lines, for the
testbench's +ram= option. 8-bit samples at physical 0x40000 (4 KB),
16-bit at 0x41000. The SRAM is little-endian: of two 8-bit samples in a
word, the first (at the even address) is the low byte.
"""
import random
import sys

rnd = random.Random(6)
mem = {}
for a in range(0x40000, 0x41000, 2):
    mem[a // 2] = rnd.randrange(65536)
for a in range(0x41000, 0x42000, 2):
    mem[a // 2] = rnd.randrange(65536)
mem[0x41000 // 2] = 0x8000                 # extremes, for the interpolation's corners
mem[0x41002 // 2] = 0x7FFF
with open(sys.argv[1], "w") as f:
    last = None
    for wa in sorted(mem):
        if last is None or wa != last + 1:
            f.write("@%06x\n" % wa)
        f.write("%04x\n" % mem[wa])
        last = wa
