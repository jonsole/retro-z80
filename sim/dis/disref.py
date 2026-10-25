#!/usr/bin/env python3
"""The disassembler's test (ticket #23): a table of every Z80 opcode and a
reference disassembler in Python, in the monitor's format (spec 16, section
8.4).

    disref.py make DIR    write DIR/distab.bin (the table, for distest.asm),
                          DIR/dis_expect.txt (what the ROM must print) and
                          DIR/dis_sj.asm (the same text in sjasmplus's
                          number syntax, with the bytes it must give)
    disref.py sj DIR      compare DIR/dis_sj.bin, sjasmplus's bytes for
                          dis_sj.asm, with the table: the reference's text is
                          sjasmplus's syntax for those bytes
    disref.py check DIR   compare DIR/dis.out (distest.com's output in the
                          ZEX testbench) with dis_expect.txt

The table: each entry is a header byte (the number of bytes after it, plus
0x80 when the entry follows an RST 28h, so its byte is a function number)
and the bytes. Every entry is disassembled at address 8000. The monitor's
numbers are bare hex (8006, (IX+05)); sjasmplus's text writes them 0x8006,
(IX+0x05). A few undocumented forms are other encodings of an instruction
sjasmplus knows (NEG, RETN, IM, LD (nn),HL, BIT n,(IX+d)): there the
check takes sjasmplus's own encoding (CANON).
"""
import sys

ADDR = 0x8000
N8, NN, D = 0x3C, 0x1234, 0x05          # the operands most entries use
E = 0x10                                # a relative jump: 8012

R = ["B", "C", "D", "E", "H", "L", "(HL)", "A"]
RP = ["BC", "DE", "HL", "SP"]
RP2 = ["BC", "DE", "HL", "AF"]
CC = ["NZ", "Z", "NC", "C", "PO", "PE", "P", "M"]
ALU = ["ADD  A,", "ADC  A,", "SUB  ", "SBC  A,", "AND  ", "XOR  ", "OR   ", "CP   "]
ROT = ["RLC", "RRC", "RL", "RR", "SLA", "SRA", "SLL", "SRL"]
IM = ["0", "0", "1", "2", "0", "0", "1", "2"]
BLI = [["LDI", "CPI", "INI", "OUTI"], ["LDD", "CPD", "IND", "OUTD"],
       ["LDIR", "CPIR", "INIR", "OTIR"], ["LDDR", "CPDR", "INDR", "OTDR"]]
FNAMES = ["VERSION", "PUTC", "GETC", "POLLC", "PUTS", "GETLINE", "PUTHEX", "PUTHEX16",
          "PUTDEC", "CLS", "SETPOS", "GETPOS", "SETPAIR", "PUTRAW", "CONMODE", "EXIT",
          "BREAK", "RESET", "LOADFILE", "READBLOCK", "WRITEBLOCK"]


class Dis:
    """One instruction from the bytes b at ADDR. sj: numbers as sjasmplus
    takes them. Gives (length, text)."""

    def __init__(self, b, sj=False):
        self.b, self.sj, self.i = b, sj, 0

    def get(self):
        v = self.b[self.i]
        self.i += 1
        return v

    def h2(self, v):
        return ("0x%02X" if self.sj else "%02X") % v

    def h4(self, v):
        return ("0x%04X" if self.sj else "%04X") % v

    def run(self, after_rst28=False):
        if after_rst28:
            n = self.get()
            t = "DB   " + self.h2(n)
            if n < len(FNAMES):
                t = t.ljust(15) + "; " + FNAMES[n]
            return 1, t
        op = self.get()
        if op in (0xDD, 0xFD):
            ix = "IX" if op == 0xDD else "IY"
            op2 = self.get()
            if op2 == 0xCB:
                d = self.get()
                return 4, self.cb(self.get(), ix, d)
            if op2 in (0xDD, 0xED, 0xFD):
                return 1, "DB   " + self.h2(op)
            self.used = False
            t = self.main(op2, ix)
            if not self.used:
                return 1, "DB   " + self.h2(op)
            return self.i, t
        if op == 0xCB:
            return 2, self.cb(self.get())
        if op == 0xED:
            return self.ed()
        t = self.main(op)
        return self.i, t

    def m(self, mn, ops=""):
        return mn.ljust(5) + ops if ops else mn

    # The operands, with IX or IY in place of HL
    def r(self, k, ix=None, plain=False):
        if k == 6:
            return self.mem(ix)
        if ix and not plain and k in (4, 5):
            self.used = True
            return ix + ("H" if k == 4 else "L")
        return R[k]

    def mem(self, ix):
        if not ix:
            return "(HL)"
        self.used = True
        return self.idx(ix, self.get())

    def idx(self, ix, d):
        if d < 0x80:
            return "(%s+%s)" % (ix, self.h2(d))
        return "(%s-%s)" % (ix, self.h2(0x100 - d))

    def hl(self, ix):
        if ix:
            self.used = True
            return ix
        return "HL"

    def rp(self, p, ix, tab=RP):
        return self.hl(ix) if p == 2 else tab[p]

    def n(self):
        return self.h2(self.get())

    def nn(self):
        lo = self.get()
        return self.h4(lo | self.get() << 8)

    def rel(self):
        e = self.get()
        return self.h4((ADDR + self.i + e - (0x100 if e >= 0x80 else 0)) & 0xFFFF)

    def main(self, op, ix=None):
        x, y, z, p, q = op >> 6, op >> 3 & 7, op & 7, op >> 4 & 3, op >> 3 & 1
        m = self.m
        if x == 1:
            if op == 0x76:
                return "HALT"
            plain = y == 6 or z == 6
            dst = self.r(y, ix, plain)
            return m("LD", dst + "," + self.r(z, ix, plain))
        if x == 2:
            return ALU[y] + self.r(z, ix)
        if x == 0:
            if z == 0:
                if y == 0:
                    return "NOP"
                if y == 1:
                    return m("EX", "AF,AF'")
                if y == 2:
                    return m("DJNZ", self.rel())
                if y == 3:
                    return m("JR", self.rel())
                return m("JR", CC[y - 4] + "," + self.rel())
            if z == 1:
                if q == 0:
                    a = self.rp(p, ix)
                    return m("LD", a + "," + self.nn())
                a = self.hl(ix)
                return m("ADD", a + "," + self.rp(p, ix))
            if z == 2:
                if y == 4:
                    a = self.nn()
                    return m("LD", "(" + a + ")," + self.hl(ix))
                if y == 5:
                    a = self.hl(ix)
                    return m("LD", a + ",(" + self.nn() + ")")
                if y == 6:
                    return m("LD", "(" + self.nn() + "),A")
                if y == 7:
                    return m("LD", "A,(" + self.nn() + ")")
                return m("LD", ["(BC),A", "A,(BC)", "(DE),A", "A,(DE)"][y])
            if z == 3:
                return m(["INC", "DEC"][q], self.rp(p, ix))
            if z == 4:
                return m("INC", self.r(y, ix))
            if z == 5:
                return m("DEC", self.r(y, ix))
            if z == 6:
                a = self.r(y, ix)
                return m("LD", a + "," + self.n())
            return ["RLCA", "RRCA", "RLA", "RRA", "DAA", "CPL", "SCF", "CCF"][y]
        # x == 3
        if z == 0:
            return m("RET", CC[y])
        if z == 1:
            if q == 0:
                return m("POP", self.rp(p, ix, RP2))
            if p == 0:
                return "RET"
            if p == 1:
                return "EXX"
            if p == 2:
                return m("JP", "(" + self.hl(ix) + ")")
            return m("LD", "SP," + self.hl(ix))
        if z == 2:
            return m("JP", CC[y] + "," + self.nn())
        if z == 3:
            if y == 0:
                return m("JP", self.nn())
            if y == 2:
                return m("OUT", "(" + self.n() + "),A")
            if y == 3:
                return m("IN", "A,(" + self.n() + ")")
            if y == 4:
                return m("EX", "(SP)," + self.hl(ix))
            if y == 5:
                return m("EX", "DE,HL")
            return ["", "", "", "", "", "", "DI", "EI"][y]
        if z == 4:
            return m("CALL", CC[y] + "," + self.nn())
        if z == 5:
            if q == 0:
                return m("PUSH", self.rp(p, ix, RP2))
            return m("CALL", self.nn())
        if z == 6:
            return ALU[y] + self.n()
        return m("RST", "%02Xh" % (y * 8))

    def cb(self, op, ix=None, d=None):
        x, y, z = op >> 6, op >> 3 & 7, op & 7
        if ix:
            a = self.idx(ix, d)
            if z != 6 and x != 1:
                a += "," + R[z]
        else:
            a = R[z]
        if x == 0:
            return self.m(ROT[y], a)
        return self.m(["BIT", "RES", "SET"][x - 1], "%d," % y + a)

    def ed(self):
        op = self.get()
        x, y, z, p, q = op >> 6, op >> 3 & 7, op & 7, op >> 4 & 3, op >> 3 & 1
        m = self.m
        t = None
        if x == 1:
            if z == 0:
                t = m("IN", ("F" if y == 6 else R[y]) + ",(C)")
            elif z == 1:
                t = m("OUT", "(C)," + ("0" if y == 6 else R[y]))
            elif z == 2:
                t = m(["SBC", "ADC"][q], "HL," + RP[p])
            elif z == 3:
                a = self.nn()
                t = m("LD", "(" + a + ")," + RP[p]) if q == 0 else m("LD", RP[p] + ",(" + a + ")")
            elif z == 4:
                t = "NEG"
            elif z == 5:
                t = "RETI" if y == 1 else "RETN"
            elif z == 6:
                t = m("IM", IM[y])
            elif y < 6:
                t = ["LD   I,A", "LD   R,A", "LD   A,I", "LD   A,R", "RRD", "RLD"][y]
        elif x == 2 and z <= 3 and y >= 4:
            t = BLI[y - 4][z]
        if t is None:
            return 2, "DB   " + self.h2(0xED) + "," + self.h2(op)
        return self.i, t


def operands(pre, op):
    """The bytes after the opcode for an entry: what it reads, in order"""
    if pre == 0xED:
        return [NN & 0xFF, NN >> 8] if (op & 0xC7) == 0x43 else []
    x, y, z, q = op >> 6, op >> 3 & 7, op & 7, op >> 3 & 1
    out = []
    if pre and ((x == 1 and (y == 6 or z == 6) and op != 0x76) or (x == 2 and z == 6)
                or (x == 0 and z in (4, 5, 6) and y == 6)):
        out.append(D)                   # (IX+d)
    if x == 0 and z == 0 and y >= 2:
        out.append(E)
    elif (x == 0 and z == 1 and q == 0) or (x == 0 and z == 2 and y >= 4) or \
            (x == 3 and z in (2, 4)) or op in (0xC3, 0xCD):
        out += [NN & 0xFF, NN >> 8]
    elif (x == 0 and z == 6) or (x == 3 and z == 6) or op in (0xD3, 0xDB):
        out.append(N8)
    return out


def table():
    """The entries: (bytes, after RST 28h)"""
    t = []
    for op in range(256):
        if op not in (0xCB, 0xDD, 0xED, 0xFD):
            t.append(([op] + operands(0, op), False))
    for op in range(256):
        t.append(([0xCB, op], False))
    for op in range(256):
        t.append(([0xED, op] + operands(0xED, op), False))
    for pre in (0xDD, 0xFD):
        for op in range(256):
            if op != 0xCB:
                t.append(([pre, op] + operands(pre, op), False))
    for pre in (0xDD, 0xFD):
        for op in range(256):
            t.append(([pre, 0xCB, (D + op) & 0xFF, op], False))   # every displacement once
    # Displacements and jumps at their limits, and RST 28h's function numbers
    for d in (0x00, 0x7F, 0x80, 0xFF):
        t.append(([0xDD, 0x7E, d], False))
        t.append(([0xFD, 0x36, d, 0xA5], False))
    for e in (0x00, 0x7F, 0x80, 0xFE):
        t.append(([0x18, e], False))
        t.append(([0x10, e], False))
    for n in list(range(len(FNAMES) + 1)) + [0xEF, 0xFF]:
        t.append(([n], True))
    t.append(([0xEF], False))
    t.append(([0xDD, 0x00], False))     # a prefix on its own: DB DD
    return t


# Undocumented encodings that sjasmplus writes another way: its encoding
def canon(b):
    if b[0] == 0xED:
        if b[1] in (0x4C, 0x54, 0x5C, 0x64, 0x6C, 0x74, 0x7C):
            return [0xED, 0x44]
        if b[1] in (0x55, 0x5D, 0x65, 0x6D, 0x75, 0x7D):
            return [0xED, 0x45]
        if b[1] in (0x4E, 0x66, 0x6E):
            return [0xED, 0x46]
        if b[1] == 0x76:
            return [0xED, 0x56]
        if b[1] == 0x7E:
            return [0xED, 0x5E]
        if b[1] in (0x63, 0x6B):
            return [0x22 if b[1] == 0x63 else 0x2A] + b[2:]
    if b[0] in (0xDD, 0xFD) and len(b) == 4 and b[1] == 0xCB and b[3] >> 6 == 1:
        return b[:3] + [b[3] & 0xF8 | 6]
    return b


def make(d):
    tab = table()
    with open(d + "/distab.bin", "wb") as f:
        for b, rst in tab:
            f.write(bytes([len(b) | (0x80 if rst else 0)] + b))
        f.write(bytes([0]))
    with open(d + "/dis_expect.txt", "w", newline="\n") as f:
        for b, rst in tab:
            n, text = Dis(b).run(rst)
            f.write("%d %s\n" % (n, text))
    with open(d + "/dis_sj.asm", "w", newline="\n") as f, open(d + "/dis_sj.want", "wb") as w:
        f.write("; sjasmplus's bytes for the reference's text (disref.py)\n"
                "        DEVICE NOSLOT64K\n        ORG 0\n")
        for b, rst in tab:
            n, text = Dis(b, sj=True).run(rst)
            f.write("        DISP 0x%04X\n        %s\n        ENT\n" % (ADDR, text))
            rest = b[n:]
            if rest:
                f.write("        DB %s\n" % ",".join("0x%02X" % v for v in rest))
            w.write(bytes(canon(b[:n]) + rest))
    print("%d entries" % len(tab))


def sj(d):
    got = open(d + "/dis_sj.bin", "rb").read()
    want = open(d + "/dis_sj.want", "rb").read()
    if got == want:
        print("sjasmplus: the reference's text gives the table's bytes")
        return True
    for i, (g, w) in enumerate(zip(got, want)):
        if g != w:
            print("sjasmplus: byte %d differs: %02X, want %02X" % (i, g, w))
            break
    else:
        print("sjasmplus: %d bytes, want %d" % (len(got), len(want)))
    return False


def check(d):
    want = open(d + "/dis_expect.txt").read().split("\n")[:-1]
    got = [l.rstrip("\r") for l in open(d + "/dis.out", encoding="latin-1").read().split("\n")]
    got = [l for l in got if l.startswith("|")]
    got = [l[1:] for l in got]
    tab = table()
    errors = 0
    for k, w in enumerate(want):
        g = got[k] if k < len(got) else "<none>"
        if g != w:
            errors += 1
            if errors <= 20:
                print("entry %d (%s): got %r, want %r" % (k, " ".join("%02X" % v for v in tab[k][0]), g, w))
    if len(got) != len(want):
        print("%d lines, want %d" % (len(got), len(want)))
        errors += 1
    print("%d entries checked" % len(want))
    print("TEST PASSED" if errors == 0 else "TEST FAILED: %d entries differ" % errors)
    return errors == 0


if __name__ == "__main__":
    cmd, d = sys.argv[1], sys.argv[2]
    ok = {"make": lambda: make(d) or True, "sj": lambda: sj(d), "check": lambda: check(d)}[cmd]()
    sys.exit(0 if ok else 1)
