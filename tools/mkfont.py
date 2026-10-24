#!/usr/bin/env python3
"""Make the boot console's font (spec 7, section 5.1) from font8x8.

    mkfont.py FONT8X8_DIR OUT.inc      write the font as sjasmplus DB lines
    mkfont.py FONT8X8_DIR --missing    list the code page 437 characters
                                       font8x8 lacks (drawn below)
    mkfont.py FONT8X8_DIR --show       print all 256 characters as text

FONT8X8_DIR is firmware/third_party/font8x8: Daniel Hepper's font8x8 headers
(public domain). The font is 256 characters of 8 x 8 pixels in code page 437
order, 8 bytes a character, row 0 first, the leftmost pixel in bit 7 (spec 4:
chunky pixels, leftmost in the highest bits). font8x8 keeps the leftmost
pixel in bit 0, so each row is mirrored.

Each code page 437 character is looked up by its Unicode code point in the
font8x8 tables. The ones font8x8 lacks are drawn here (DRAWN, below); they are
the project's own and public domain too (spec 7, open point SY12).
"""
import re
import sys

# font8x8 tables: header, array name, first code point (by position in the array)
TABLES = [
    ("font8x8_basic.h", 0x0000),
    ("font8x8_control.h", 0x0080),
    ("font8x8_ext_latin.h", 0x00A0),
    ("font8x8_greek.h", 0x0390),
    ("font8x8_box.h", 0x2500),
    ("font8x8_block.h", 0x2580),
]
# font8x8_misc.h has no regular layout: its entries by position
MISC = {0: 0x20A7, 1: 0x0192, 4: 0x2310, 5: 0x2264, 6: 0x2265}

# Code page 437 0x00-0x1F and 0x7F are graphics; 0x20-0x7E ASCII; 0x80-0xFF
# from Python's cp437 codec
LOW = [0x0000, 0x263A, 0x263B, 0x2665, 0x2666, 0x2663, 0x2660, 0x2022,
       0x25D8, 0x25CB, 0x25D9, 0x2642, 0x2640, 0x266A, 0x266B, 0x263C,
       0x25BA, 0x25C4, 0x2195, 0x203C, 0x00B6, 0x00A7, 0x25AC, 0x21A8,
       0x2191, 0x2193, 0x2192, 0x2190, 0x221F, 0x2194, 0x25B2, 0x25BC]


def cp437(c):
    if c < 0x20:
        return LOW[c]
    if c == 0x7F:
        return 0x2302
    return ord(bytes([c]).decode("cp437"))


# Characters drawn for the project: 8 rows of 8, '#' a pixel, leftmost first
DRAWN = {
    0x263A: [".######.", "#......#", "#.#..#.#", "#......#", "#.####.#", "#..##..#", "#......#", ".######."],  # white smiley
    0x263B: [".######.", "########", "##.##.##", "########", "##....##", "###..###", "########", ".######."],  # black smiley
    0x2665: [".##.##..", "#######.", "#######.", "#######.", ".#####..", "..###...", "...#....", "........"],  # heart
    0x2666: ["...#....", "..###...", ".#####..", "#######.", ".#####..", "..###...", "...#....", "........"],  # diamond
    0x2663: ["..###...", ".#####..", "..###...", "#######.", "#######.", "..#.#...", "..###...", "........"],  # club
    0x2660: ["...#....", "..###...", ".#####..", "#######.", "#######.", "..#.#...", "..###...", "........"],  # spade
    0x2022: ["........", "........", "...##...", "..####..", "..####..", "...##...", "........", "........"],  # bullet
    0x25D8: ["########", "########", "###..###", "##....##", "##....##", "###..###", "########", "########"],  # inverse bullet
    0x25CB: ["........", "..####..", ".##..##.", ".#....#.", ".#....#.", ".##..##.", "..####..", "........"],  # white circle
    0x25D9: ["########", "##....##", "#..##..#", "#.####.#", "#.####.#", "#..##..#", "##....##", "########"],  # inverse white circle
    0x2642: ["....####", "......##", ".....#.#", "..####..", ".##..##.", ".##..##.", "..####..", "........"],  # male
    0x2640: ["..####..", ".##..##.", ".##..##.", ".##..##.", "..####..", "...##...", ".######.", "...##..."],  # female
    0x266A: ["...####.", "...#..#.", "...####.", "...#....", "...#....", ".###....", "####....", ".##....."],  # note
    0x266B: [".######.", ".#....#.", ".######.", ".#....#.", ".#....#.", ".#...##.", "##..###.", "##...##."],  # beamed notes
    0x263C: ["#..##..#", ".#.##.#.", "..####..", "###..###", "###..###", "..####..", ".#.##.#.", "#..##..#"],  # sun
    0x25BA: ["#.......", "###.....", "#####...", "#######.", "#####...", "###.....", "#.......", "........"],  # right pointer
    0x25C4: [".......#", ".....###", "...#####", ".#######", "...#####", ".....###", ".......#", "........"],  # left pointer
    0x2195: ["...##...", "..####..", ".######.", "...##...", "...##...", ".######.", "..####..", "...##..."],  # up-down arrow
    0x203C: [".##..##.", ".##..##.", ".##..##.", ".##..##.", ".##..##.", "........", ".##..##.", "........"],  # double exclamation
    0x25AC: ["........", "........", "........", "........", "#######.", "#######.", "#######.", "........"],  # black rectangle
    0x21A8: ["...##...", "..####..", ".######.", "...##...", ".######.", "..####..", "...##...", "########"],  # up-down arrow with base
    0x2191: ["...##...", "..####..", ".######.", "...##...", "...##...", "...##...", "...##...", "........"],  # up arrow
    0x2193: ["...##...", "...##...", "...##...", "...##...", ".######.", "..####..", "...##...", "........"],  # down arrow
    0x2192: ["........", "...##...", "....##..", "#######.", "....##..", "...##...", "........", "........"],  # right arrow
    0x2190: ["........", "..##....", ".##.....", "#######.", ".##.....", "..##....", "........", "........"],  # left arrow
    0x221F: ["........", "........", "##......", "##......", "##......", "#######.", "........", "........"],  # right angle
    0x2194: ["........", "..#..#..", ".##..##.", "########", ".##..##.", "..#..#..", "........", "........"],  # left-right arrow
    0x25B2: ["........", "...#....", "..###...", ".#####..", "#######.", "#######.", "........", "........"],  # up triangle
    0x25BC: ["........", "#######.", "#######.", ".#####..", "..###...", "...#....", "........", "........"],  # down triangle
    0x2302: ["...#....", "..###...", ".##.##..", "##...##.", "##...##.", "##...##.", "#######.", "........"],  # house
    0x221E: ["........", "........", ".##.##..", "#..#..#.", "#..#..#.", ".##.##..", "........", "........"],  # infinity
    0x2229: ["........", "..####..", ".##..##.", ".##..##.", ".##..##.", ".##..##.", ".##..##.", "........"],  # intersection
    0x2261: ["........", "######..", "........", "######..", "........", "######..", "........", "........"],  # identical to
    0x2320: ["....###.", "...##.##", "...##.##", "...##...", "...##...", "...##...", "...##...", "...##..."],  # top half integral
    0x2321: ["...##...", "...##...", "...##...", "...##...", "##.##...", "##.##...", ".###....", "........"],  # bottom half integral
    0x2248: ["........", ".###.##.", "##.###..", "........", ".###.##.", "##.###..", "........", "........"],  # almost equal to
    0x2219: ["........", "........", "........", "...##...", "...##...", "........", "........", "........"],  # bullet operator
    0x221A: ["....####", "....##..", "....##..", "....##..", "###.##..", ".##.##..", "..####..", "...###.."],  # square root
    0x207F: [".####...", ".##.##..", ".##.##..", ".##.##..", "........", "........", "........", "........"],  # superscript n
    0x25A0: ["........", "........", "..####..", "..####..", "..####..", "..####..", "........", "........"],  # black square
}


def load_tables(d):
    glyphs = {}
    hexes = re.compile(r"\{([^}]*)\}")
    for name, base in TABLES + [("font8x8_misc.h", None)]:
        text = open(d + "/" + name).read()
        body = re.sub(r"//.*", "", text[text.index("= {") + 3:])     # comments may hold braces
        rows = [[int(v, 16) for v in m.split(",")] for m in hexes.findall(body)]
        for i, r in enumerate(rows):
            assert len(r) == 8, (name, i)
            cp = MISC.get(i) if base is None else base + i
            if cp is not None and cp not in glyphs:
                glyphs[cp] = r
    return glyphs


def mirror(b):
    return int("{:08b}".format(b)[::-1], 2)


def drawn(rows):
    assert len(rows) == 8 and all(len(r) == 8 for r in rows), rows
    return [mirror(int(r.replace("#", "1").replace(".", "0"), 2)) for r in rows]


def font(d):
    glyphs = load_tables(d)
    out, missing = [], []
    for c in range(256):
        cp = cp437(c)
        if cp in DRAWN:
            g = drawn(DRAWN[cp])
        elif cp in glyphs:
            g = glyphs[cp]
        else:
            missing.append((c, cp))
            g = [0] * 8
        out.append([mirror(b) for b in g])           # leftmost pixel in bit 7
    return out, missing


def main():
    d, arg = sys.argv[1], sys.argv[2]
    f, missing = font(d)
    if arg == "--missing":
        for c, cp in missing:
            print("0x%02X U+%04X %s" % (c, cp, chr(cp)))
        return
    if arg == "--show":
        for c in range(256):
            print("0x%02X U+%04X" % (c, cp437(c)))
            for b in f[c]:
                print("  " + "{:08b}".format(b).replace("1", "#").replace("0", "."))
        return
    if missing:
        sys.exit("mkfont: no glyph for " + ", ".join("0x%02X" % c for c, _ in missing))
    with open(arg, "w", newline="\n") as o:
        o.write("; The boot console's font, 256 characters of 8 x 8 pixels in code page 437\n"
                "; order, leftmost pixel in bit 7. Made by tools/mkfont.py from font8x8\n"
                "; (firmware/third_party/font8x8, public domain); do not edit\n")
        for c in range(256):
            o.write("        db      %s   ; 0x%02X\n" % (", ".join("0x%02X" % b for b in f[c]), c))


if __name__ == "__main__":
    main()
