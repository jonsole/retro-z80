#!/usr/bin/env python3
"""The monitor's scripted session (ticket #22): what to type and what must come back.

    check.py make DIR    write DIR/session.in, the lines tb_mon.v types
    check.py check DIR   compare DIR/mon.log with the transcript below

The transcript is the start-up lines, then for each line typed the output
expected after its echo. An expected line is matched exactly, or as a
regular expression when it is an re.Pattern; ANY matches any lines up to
the next expected one. A line marked RAW is typed at a prompt of its own
(E's "addr: old "), so its echo is part of the output given.
"""
import re
import sys

ANY = object()
RAW = "raw"
R = re.compile


def dump(addr, data, size=1, phys=False):
    """A D line as the shared spec gives it: the address, the items (2 x
    size + 1 characters each, an extra space after 8 bytes) padded to a
    full line's width, a space, the characters (two spaces after a full
    line's last item). data: bytes, None for a side-effect byte."""
    s = ("P%06X" % addr if phys else "%04X" % addr) + "  "
    items = ""
    for i in range(0, len(data), size):
        part = data[i:i + size]
        if any(b is None for b in part):
            items += "--" * size
        else:
            items += "".join("%02X" % b for b in reversed(part))
        items += " "
        if i + size == 8:
            items += " "
    s += items.ljust(33 + 16 // size) + " "
    s += "".join("." if b is None or b < 32 or b > 126 else chr(b) for b in data)
    return s


REGS1 = R(r"AF=[0-9A-F]{4} BC=[0-9A-F]{4} DE=[0-9A-F]{4} HL=[0-9A-F]{4} IX=[0-9A-F]{4} "
          r"IY=[0-9A-F]{4} SP=[0-9A-F]{4} PC=[0-9A-F]{4}")
REGS2 = R(r"AF'=[0-9A-F]{4} BC'=[0-9A-F]{4} DE'=[0-9A-F]{4} HL'=[0-9A-F]{4} I=[0-9A-F]{2} "
          r"R=[0-9A-F]{2} IFF=[01] IM=[012]\??( ( [SZHPNC])+)?")


def regs(pc=None, sp=None, extra1=None, extra2=None):
    """The two register lines, with some values given"""
    l1 = r"AF=%s BC=%s DE=%s HL=%s IX=%s IY=%s SP=%s PC=%s"
    l2 = r"AF'=%s BC'=%s DE'=%s HL'=%s I=1F R=[0-9A-F]{2} IFF=0 IM=%s( ( [SZHPNC])+)?"
    w = "[0-9A-F]{4}"
    v1 = dict(AF=w, BC=w, DE=w, HL=w, IX=w, IY=w, SP=w, PC=w)
    if pc:
        v1["PC"] = pc
    if sp:
        v1["SP"] = sp
    v1.update(extra1 or {})
    v2 = dict(AF=w, BC=w, DE=w, HL=w, IM=r"2\?")
    v2.update(extra2 or {})
    return [R(l1 % tuple(v1[k] for k in ("AF", "BC", "DE", "HL", "IX", "IY", "SP", "PC"))),
            R(l2 % tuple(v2[k] for k in ("AF", "BC", "DE", "HL", "IM")))]


START = [
    "retro-z80 boot ROM 0.1  Z80 at 20 MHz, 2 MB SRAM",
    "Reset: power-on.  Self-test ok.",
    "Monitor.  H for help.",
]

SESSION = [
    # Ports: SYSID, and the program's MMU copy (window 4 = SRAM page 4)
    ("P 7000", ["7000: 5A"]),
    ("P 8800", ["8800: 04"]),
    # A program typed in: LD A,'A' / RST 08h / RET
    ("E 8000 3E 41 CF C9", []),
    ("D 8000 4", [dump(0x8000, [0x3E, 0x41, 0xCF, 0xC9])]),
    ("D P008000 4", [dump(0x8000, [0x3E, 0x41, 0xCF, 0xC9], phys=True)]),
    ("G 8000", ["A", "Program ended."] + regs(pc="0040", sp="0000", extra1={"AF": "41[0-9A-F]{2}"})),
    ("R", regs(pc="0040", sp="0000")),
    # G again after the end: from ENTRY
    ("G", ["A", "Program ended."] + regs(pc="0040")),
    # The registers a program leaves, kept across RST 08h: IX, IY, BC, DE, HL'
    ("E 8100 DD 21 34 12 FD 21 78 56 01 BC 9A 11 F0 DE D9 21 11 11 D9 3E 58 CF C9", []),
    ("G 8100", ["X", "Program ended."] +
     regs(pc="0040", extra1={"AF": "58[0-9A-F]{2}", "BC": "9ABC", "DE": "DEF0", "IX": "1234", "IY": "5678"},
          extra2={"HL": "1111"})),
    # Setting registers
    ("R HL 4321", []),
    ("R HL", ["HL=4321"]),
    ("R IM 1", []),
    ("R IM", ["IM=1"]),
    ("R A 7", []),
    ("R A", ["A=07"]),
    ("R AF", [R(r"AF=07[0-9A-F]{2}( ( [SZHPNC])+)?")]),
    ("R", regs(extra1={"HL": "4321", "AF": "07[0-9A-F]{2}"}, extra2={"IM": "1"})),
    ("R IM 2", []),
    ("R QQ 1", ["? syntax"]),
    # A breakpoint: LD A,'B' / RST 08h / LD A,'C' / RST 08h / RET, stopped at 8203
    ("E 8200 3E 42 CF 3E 43 CF C9", []),
    ("G 8200 8203", ["B", "Breakpoint at 8203"] + regs(pc="8203")),
    ("D 8203 1", [dump(0x8203, [0x3E])]),
    ("G", ["C", "Program ended."] + regs(pc="0040")),
    # RST 30h: break, then G goes on after it
    ("E 8300 F7 3E 44 CF C9", []),
    ("G 8300", ["Break at 8300"] + regs(pc="8301")),
    ("G", ["D", "Program ended."] + regs(pc="0040")),
    # RST 18h PUTS and RST 28h PUTHEX: LD HL,830A / RST 18h / LD A,5A / RST 28h, 6 / RET
    ("E 8300 21 0A 83 DF 3E 5A EF 06 C9 00", []),
    ('E 830A "Hi" 0D 0A 00', []),
    ("G 8300", ["Hi", "5A", "Program ended."] + regs(pc="0040")),
    # The trap: a byte 0xFF
    ("E 8400 FF", []),
    ("G 8400", ["Trap RST 38h at 8400"] + regs(pc="8400")),
    # The stack near window 4 (a ROM call borrows window 2), then in window 3 at a break (the
    # monitor's entry puts the workspace in window 5 first), and EXIT by a jump
    ("E 8600 31 00 90 3E 57 CF 31 00 70 F7 3E 56 CF C3 40 00", []),
    ("G 8600", ["W", "Break at 8609"] + regs(pc="860A", sp="7000")),
    ("G", ["V", "Program ended."] + regs(pc="0040", sp="7000")),
    # A ROM call with interrupts on gives them back on: IFF=1 at the end
    ("E 8600 FB 3E 49 CF C9", []),
    ("G 8600", ["I", "Program ended.", REGS1, R(r"AF'=.* IFF=1 IM=2\?.*")]),
    ("R IFF 0", []),
    # RST 28h: VERSION (A = 01, B = 11, HL = 0048), PUTDEC, a function that is not there (carry, A = 1)
    ("E 8500 EF 00 C9", []),
    ("G 8500", ["Program ended."] + regs(extra1={"AF": "01[0-9A-F]{2}", "BC": "11[0-9A-F]{2}", "HL": "0048"})),
    ("E 8500 21 34 12 EF 08 C9", []),
    ("G 8500", ["4660", "Program ended."] + regs()),
    ("E 8500 EF 50 C9", []),
    ("G 8500", ["Program ended.", REGS1, R(r"AF'=.* IM=2\?  .*C")]),
    # GETLINE from a program: "? ", then a line into 9100 (B = 10): B = its length
    ("E 8500 3E 3F CF 3E 20 CF 21 00 91 06 0A EF 05 C9", []),
    ("G 8500", []),
    ("hello", ["? hello", "Program ended."] + regs(extra1={"BC": "05[0-9A-F]{2}", "HL": "9100"}), RAW),
    ("D 9100 6", [dump(0x9100, b"hello\0")]),
    # Fill, sizes, copy, compare, search
    ("F 9000 100 0", []),
    ("F 9000 10 AA", []),
    ("D 9000 10", [dump(0x9000, [0xAA] * 16)]),
    ("F.W 9010 10 1234", []),
    ("D.W 9010 10", [dump(0x9010, [0x34, 0x12] * 8, 2)]),
    ("D.L 9010 8", [dump(0x9010, [0x34, 0x12] * 4, 4)]),
    ('F 9020 6 "ab"', []),
    ("D 9020 6", [dump(0x9020, b"ababab")]),
    ("C 9000 8 9030", []),
    ("V 9000 8 9030", ["Differences: 0000"]),
    ("V 9000 4 9010", ["9000: AA  9010: 34", "9001: AA  9011: 12", "9002: AA  9012: 34",
                       "9003: AA  9013: 12", "Differences: 0004"]),
    ("C 9010 8 9012", []),
    ("D 9010 A", [dump(0x9010, [0x34, 0x12, 0x34, 0x12, 0x34, 0x12, 0x34, 0x12, 0x34, 0x12])]),
    ("S 9000 40 34 12", ["9010  9012  9014  9016  9018  901A  901C  901E  "]),
    ('S 8000 400 "Hi"', ["830A  "]),
    ("S 9000 40 77", ["Not found."]),
    # Enter carries on after D
    ("D 9000 10", [dump(0x9000, [0xAA] * 16)]),
    ("", [dump(0x9010, [0x34, 0x12] * 8), dump(0x9020, b"ababab" + bytes(10)),
          dump(0x9030, [0xAA] * 8 + [0] * 8)] + [dump(a, [0] * 16) for a in range(0x9040, 0x9090, 16)]),
    # E, one value at a time: change 9000, back, end
    ("E 9000", []),
    ("55", ["9000: AA 55"], RAW),
    ("-", ["9001: AA -"], RAW),
    (".", ["9000: 55 ."], RAW),
    # The register page: side effects shown as --
    ("D P7F0020 4", [R(r"P7F0020  -- [0-9A-F]{2} [0-9A-F]{2} [0-9A-F]{2} +\..{3}")]),
    ("D P7F0070 1", [dump(0x7F0070, [0x5A], phys=True)]),
    # Errors
    ("D 10000", ["? address"]),
    ("D P800000", ["? address"]),
    ("D.W 8000 3", ["? size"]),
    ("P.W 7000", ["? size"]),
    ("Q", ["? syntax"]),
    ("I 8000", ["? not yet: a later ticket"]),
    ("E 0000 00", ["? address"]),
    ("G 8000 0010", ["? address"]),
    ("H", [ANY]),
]


def make(d):
    with open(d + "/session.in", "w", newline="\n") as f:
        for line, *_ in SESSION:
            f.write(line + "\n")


def check(d):
    log = open(d + "/mon.log", "rb").read().decode("latin-1")
    got = log.replace("\r", "").split("\n")
    want = list(START)
    for line, out, *raw in SESSION:
        if not raw:
            want.append("> " + line)
        want.extend(out)
    want.append("> ")
    i = 0
    errors = 0
    w = 0
    while w < len(want):
        e = want[w]
        if e is ANY:
            nxt = want[w + 1] if w + 1 < len(want) else None
            while i < len(got) and not match(nxt, got[i]):
                i += 1
            w += 1
            continue
        g = got[i] if i < len(got) else "<end>"
        if not match(e, g):
            print("line %d: expected %r" % (i + 1, e.pattern if isinstance(e, re.Pattern) else e))
            print("         got      %r" % g)
            errors += 1
            if errors > 10:
                break
        i += 1
        w += 1
    if i < len(got):
        print("extra output from line %d: %r" % (i + 1, got[i]))
        errors += 1
    errors += screen(d, got)
    print("TEST PASSED" if errors == 0 else "TEST FAILED: %d lines differ" % errors)
    return errors == 0


def screen(d, got):
    """The console's 30 rows, read back from its map (con.hex: page 0x0FE as
    16-bit words, an entry's low byte its character), must show the last 30
    lines sent over the serial link. Returns the number of rows that differ."""
    words = []
    for line in open(d + "/con.hex"):
        line = line.strip()
        if line and not line.startswith(("@", "//")):
            words.extend(int(w, 16) for w in line.split())
    def byte(off):
        w = words[off >> 1]
        return (w >> 8) if off & 1 else (w & 0xFF)
    if byte(0xC0) != 0x5A:
        print("screen: no console state marker")
        return 1
    row, col, top = byte(0xC1), byte(0xC2), byte(0xC3)
    rows = []
    for k in range(30):
        r = (top + k) % 32
        text = "".join(chr(byte(r * 256 + 2 * c)) for c in range(80))
        if k == row and text[col] == "_":
            text = text[:col] + " " + text[col + 1:]        # the cursor
        rows.append(text.rstrip())
    tail = [g.rstrip() for g in got[-(row + 1):]]
    errors = 0
    for k, t in enumerate(tail):
        if rows[k] != t:
            print("screen row %d: %r, sent %r" % (k, rows[k], t))
            errors += 1
    print("screen: rows 0-%d as sent, the cursor at row %d column %d, map row %d at the top" % (row, row, col, top))
    return errors


def match(e, g):
    if e is None:
        return False
    if isinstance(e, re.Pattern):
        return e.fullmatch(g) is not None
    return e == g


if __name__ == "__main__":
    if sys.argv[1] == "make":
        make(sys.argv[2])
    else:
        sys.exit(0 if check(sys.argv[2]) else 1)
