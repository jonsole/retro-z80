#!/usr/bin/env python3
"""The boot console's text (spec 7, section 5.1; ticket #15), read from the
SRAM at the end of vtest bootcon: vmodel.py has checked that the frame shows
the map and font as they are in the SRAM; this checks that they hold the
start-up text and the font the boot ROM should have put there.

    console_text.py RAM.hex FONT.inc [LINES]

LINES: the boot ROM was built with -DCON_LINES=LINES, so "line 01" ... follow
the start-up text and the console has scrolled (vtest bootscr).

Exits 1 on any difference.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vmodel import load_ram                     # noqa: E402

MAPPT, PATPT = 0x1FC000, 0x1FE000
CTOP = 0x1FE802                                 # the console's workspace: the map row at the top

# The text printed, line by line: text, PAL (pair + 1)
START = [
    ("retro-z80 0.1", 2),
    ("Z80 at 20 MHz, 2 MB SRAM", 1),
    ("selftest ok, 2 MB", 3),
    ("hello", 1),
    ("", 1),
    ("Characters typed on the USB serial link appear here.", 1),
]
CURSOR = ("_", 1)                               # shown while the background is bright
STATUS = (" retro-z80 boot console                      up 000000 s", 4)


def main():
    ram = load_ram(sys.argv[1])
    byte = lambda a: ram.get(a, 0)
    errors = []
    lines = START + [("line %02d" % (n + 1), 1) for n in range(int(sys.argv[3]) if len(sys.argv) > 3 else 0)]
    lines = (lines + [CURSOR])[-29:]
    expect = dict(enumerate(lines))
    expect[29] = STATUS
    top = byte(CTOP)
    if top != (len(START) + (int(sys.argv[3]) if len(sys.argv) > 3 else 0) + 1 - len(lines)) % 32:
        errors.append("the top row is map row %d" % top)
    font = [int(v, 16) for v in re.findall(r"0x([0-9A-F]{2})", "".join(
        l.split(";")[0] for l in open(sys.argv[2])))]
    if len(font) != 2048:
        errors.append("font.inc has %d bytes" % len(font))
    for i, b in enumerate(font):
        if byte(PATPT + i) != b:
            errors.append("font byte %d (character 0x%02X) is %02x, expected %02x"
                          % (i, i // 8, byte(PATPT + i), b))
            break
    for row in range(30):
        text, pal = expect.get(row, ("", 1))
        n = 80 if row == 29 else len(text)          # text rows are cleared in pair 0 beyond the text
        text = text.ljust(80)
        got = ""
        for col in range(80):
            a = MAPPT + (((top + row) % 32) * 128 + col) * 2
            code, hi = byte(a), byte(a + 1)
            got += chr(code) if 32 <= code < 127 else "?"
            p = pal if col < n else 1
            if code != ord(text[col]) or hi != p << 1:
                errors.append("row %d column %d: code %02x, high byte %02x; expected %02x, %02x"
                              % (row, col, code, hi, ord(text[col]), p << 1))
        print("console_text: %2d |%s|" % (row, got))
    for e in errors[:10]:
        print("console_text: " + e)
    print("console_text: %d differences" % len(errors))
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
