#!/usr/bin/env python3
"""The geometry unit (spec 15) bit for bit, and test vectors for sim/geom/tb_geom.v.

    python3 tools/geom_model.py --vectors sim/build/geom_vec.txt [--seed N] [--count N]
    python3 tools/geom_model.py --board examples/geometry/build/geomvec.bin --count 120

--board writes the same checks as a table for the board test
(examples/geometry/geomtest.asm), two bytes an operation (see write_board).

The model is the definition: the RTL (fpga/rtl/geom.v) must give the same
results, NEAR, SAT, DIVZ, FRONT and SATS for every job. The vector file is a
script of bus operations the testbench runs (see write_vectors).
"""
import argparse
import math
import random

# Register numbers in the system page (spec 15, section 5)
W0, VX, VY, VZ, CTL, STAT = 0xA0, 0xB8, 0xBA, 0xBC, 0xBE, 0xBF
BANK_CAM, BANK_OBJ, BANK_VIEW, BANK_OPS, BANK_PROD = 0, 1, 2, 3, 4
PROJ, CAM, INV = 0x08, 0x10, 0x20
BUSY, NEAR, SAT, DIVZ, FRONT, SATS = 0x01, 0x02, 0x04, 0x08, 0x10, 0x80


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def wrap16(v):
    return s16(v)


def sat(v, bits):
    lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    if v < lo:
        return lo, True
    if v > hi:
        return hi, True
    return v, False


def turn(acc):
    """A row's exact sum, with 0x2000 already added, shifted down 14 bits and saturated."""
    return sat(acc >> 14, 16)


class Geom:
    def __init__(self):
        self.cam = [0] * 12      # Mc row by row, then C
        self.obj = [0] * 12      # Mo, then P
        self.view = [0] * 5      # DX, DY, SCX, SCY, ZMIN
        self.ops = [0] * 11      # F0X..F2Y, MA, MB, DVD lo, DVD hi, DVS
        self.ctl = 0
        self.r = [0, 0, 0]
        self.stat = 0            # NEAR, SAT, DIVZ, FRONT (job bits)
        self.sats = False
        self.combine()

    # ------------------------------------------------------------ the combined matrix
    def combine(self):
        mc, mo = self.cam[:9], self.obj[:9]
        c, p = self.cam[9:], self.obj[9:]
        self.m, self.msat = [0] * 9, False
        for r in range(3):
            for col in range(3):
                v, s = turn(sum(mc[3 * r + k] * mo[3 * k + col] for k in range(3)) + 0x2000)
                self.m[3 * r + col] = v
                self.msat |= s
        d = [wrap16(p[k] - c[k]) for k in range(3)]
        self.t = [0, 0, 0]
        for r in range(3):
            v, s = turn(sum(mc[3 * r + k] * d[k] for k in range(3)) + 0x2000)
            self.t[r] = v
            self.msat |= s

    # ------------------------------------------------------------ jobs
    def vertex(self, v):
        cam, inv, proj = bool(self.ctl & CAM), bool(self.ctl & INV), bool(self.ctl & PROJ)
        mc, c = self.cam[:9], self.cam[9:]
        m, t = self.m, self.t
        res, satf = [0, 0, 0], False
        for r in range(3):
            if not cam and not inv:
                acc = sum(m[3 * r + k] * v[k] for k in range(3)) + (t[r] << 14) + 0x2000
            elif cam and not inv:
                acc = sum(mc[3 * r + k] * wrap16(v[k] - c[k]) for k in range(3)) + 0x2000
            elif not cam and inv:
                acc = sum(m[3 * k + r] * (v[k] - t[k]) for k in range(3)) + 0x2000
            else:
                acc = sum(mc[3 * k + r] * v[k] for k in range(3)) + 0x2000
            res[r], s = turn(acc)
            satf |= s
            if cam and inv:
                res[r] = wrap16(res[r] + c[r])
        if not cam:
            satf |= self.msat
        near = False
        if proj:
            x, y, z = res
            zmin = max(self.view[4], 1)
            if z < zmin:
                near = True
            else:
                dx, dy, scx, scy = self.view[:4]
                rx, s1 = sat(scx + (dx * x) // z, 16)
                ry, s2 = sat(scy - (dy * y) // z, 16)
                res = [rx, ry, z]
                satf |= s1 or s2
        self.r = res
        self.stat = (NEAR if near else 0) | (SAT if satf else 0)
        self.sats |= satf

    def face(self):
        x0, y0, x1, y1, x2, y2 = self.ops[:6]
        s = (x1 - x0) * (y2 - y0) - (y1 - y0) * (x2 - x0)
        v, satf = sat(s, 32)
        self.r[0], self.r[1] = s16(v), s16(v >> 16)
        self.stat = (FRONT if s >= 0 else 0) | (SAT if satf else 0)
        self.sats |= satf

    def mul(self):
        p = self.ops[6] * self.ops[7]
        self.r[0], self.r[1] = s16(p), s16(p >> 16)
        self.stat = 0

    def div(self):
        dvd = ((self.ops[9] & 0xFFFF) << 16) | (self.ops[8] & 0xFFFF)
        if dvd & 0x80000000:
            dvd -= 1 << 32
        dvs = self.ops[10]
        if dvs == 0:
            self.r[0], self.r[1] = (32767 if dvd >= 0 else -32768), 0
            self.stat = DIVZ
            return
        q = abs(dvd) // abs(dvs)
        if (dvd < 0) != (dvs < 0):
            q = -q
        rem = dvd - q * dvs
        if q > 32767 or q < -32768:
            self.r[0], self.r[1] = (32767 if q > 0 else -32768), 0
            self.stat = SAT
            self.sats = True
        else:
            self.r[0], self.r[1] = q, rem
            self.stat = 0

    def status(self):
        return self.stat | (SATS if self.sats else 0)


# ---------------------------------------------------------------- test vectors
#
# One operation a line, hex numbers:
#   W rr dd    write byte dd to register rr (then one idle clock)
#   S rr dd    the same, a write that starts a job: the deadline counts from it
#   G nn       nn idle clocks
#   E          wait until the deadline (the testbench's LIMIT clocks after the last S)
#   R rr dd    read register rr, expect dd
#   C text     a comment, shown when a check fails

def rot(a, b, c, scale=1.0):
    ca, sa, cb, sb, cc, sc = math.cos(a), math.sin(a), math.cos(b), math.sin(b), math.cos(c), math.sin(c)
    rx = [[1, 0, 0], [0, ca, -sa], [0, sa, ca]]
    ry = [[cb, 0, sb], [0, 1, 0], [-sb, 0, cb]]
    rz = [[cc, -sc, 0], [sc, cc, 0], [0, 0, 1]]

    def mm(p, q):
        return [[sum(p[i][k] * q[k][j] for k in range(3)) for j in range(3)] for i in range(3)]
    m = mm(rz, mm(ry, rx))
    return [max(-32768, min(32767, round(m[i][j] * scale * 16384))) for i in range(3) for j in range(3)]


class Script:
    def __init__(self):
        self.lines = []

    def w(self, reg, val):
        self.lines.append(f"W {reg:02X} {val & 0xFF:02X}")

    def word(self, reg, val):
        self.w(reg, val)
        self.w(reg + 1, val >> 8)

    def start(self, reg, val):
        self.lines.append(f"S {reg:02X} {val & 0xFF:02X}")

    def gap(self, n):
        self.lines.append(f"G {n:02X}")

    def read(self, reg, val):
        self.lines.append(f"R {reg:02X} {val & 0xFF:02X}")

    def note(self, text):
        self.lines.append("C " + text)


def write_vectors(path, seed, count, board=None):
    rnd = random.Random(seed)
    g, sc = Geom(), Script()

    def set_ctl(v):
        g.ctl = v
        sc.w(CTL, v)

    def load(bank, words, store):
        set_ctl((g.ctl & ~7) | bank)
        for i, w in enumerate(words):
            store[i] = s16(w)
            sc.word(W0 + 2 * i, w)
        if bank in (BANK_CAM, BANK_OBJ):
            g.combine()
            sc.gap(0x28)  # the CPU cannot start a vertex sooner after a matrix byte

    def results(regs):
        sc.lines.append("E")
        for reg in regs:
            val = g.r[(reg - VX) // 2]
            sc.read(reg, val)
            sc.read(reg + 1, val >> 8)
        sc.read(STAT, g.status())

    def vertex(v, ctl_bits):
        set_ctl((g.ctl & 7) | ctl_bits)
        sc.note(f"vertex {v} ctl {ctl_bits:02X}")
        sc.word(VX, v[0])
        sc.word(VY, v[1])
        sc.w(VZ, v[2])
        sc.start(VZ + 1, v[2] >> 8)
        g.vertex([s16(x) for x in v])
        results([VX, VY, VZ])

    def opjob(kind, words):
        set_ctl((g.ctl & ~7) | BANK_OPS)
        for i, w in words:
            g.ops[i] = s16(w)
        last = {"face": 5, "mul": 7, "div": 10}[kind]
        sc.note(f"{kind} {[(i, s16(w)) for i, w in words]}")
        for i, w in words:
            if i == last:
                sc.w(W0 + 2 * i, w)
                sc.start(W0 + 2 * i + 1, w >> 8)
            else:
                sc.word(W0 + 2 * i, w)
        getattr(g, kind)()
        results([VX, VY])

    def rnd16():
        return rnd.choice([rnd.randint(-32768, 32767), rnd.randint(-300, 300),
                           rnd.choice([-32768, -32767, -1, 0, 1, 32767])])

    def rnd_matrix():
        k = rnd.random()
        if k < 0.6:
            return rot(rnd.uniform(0, 7), rnd.uniform(0, 7), rnd.uniform(0, 7), rnd.choice([1.0, 1.0, 0.5, 1.9]))
        if k < 0.8:
            return [rnd.choice([0x7FFF, -0x8000, 0x4000, -0x4000, 0]) for _ in range(9)]
        return [rnd.randint(-32768, 32767) for _ in range(9)]

    def rnd_pos():
        return [rnd16() for _ in range(3)]

    # Reset state: everything 0, so a vertex gives 0
    sc.note("after reset")
    vertex([1000, -2000, 3000], 0)

    views = [[256, 256, 180, 144, 16], [256, 213, 128, 96, 1], [32767, -32768, 0, 0, 0],
             [1, 1, -32768, 32767, -5], [300, 300, 180, 144, 32767]]
    for n in range(count):
        if n % 8 == 0:
            load(BANK_VIEW, rnd.choice(views) if rnd.random() < 0.6 else [rnd16() for _ in range(5)], g.view)
        if n % 4 == 0:
            load(BANK_CAM, rnd_matrix() + rnd_pos(), g.cam)
        if n % 2 == 0:
            load(BANK_OBJ, rnd_matrix() + rnd_pos(), g.obj)
        if n % 16 == 1:
            sc.note("product bank")
            set_ctl((g.ctl & ~7) | BANK_PROD)
            for i, w in enumerate(g.m + g.t):
                sc.read(W0 + 2 * i, w)
                sc.read(W0 + 2 * i + 1, w >> 8)
            sc.w(W0, 0x55)  # read only: ignored
            sc.read(W0, g.m[0])
        if n % 50 == 0 and g.sats:
            sc.w(STAT, SATS)
            g.sats = False
        bits = rnd.choice([0, PROJ, CAM, CAM | PROJ, INV, CAM | INV, PROJ, PROJ])
        if rnd.random() < 0.5:
            v = [rnd.randint(-200, 200) for _ in range(3)]
        else:
            v = [rnd16() for _ in range(3)]
        vertex(v, bits)
        k = rnd.random()
        if k < 0.15:
            opjob("face", [(i, rnd16() if rnd.random() < 0.3 else rnd.randint(-400, 400)) for i in range(6)])
        elif k < 0.25:
            opjob("mul", [(6, rnd16()), (7, rnd16())])
        elif k < 0.4:
            dvs = rnd.choice([0, 1, -1, -32768, 32767, rnd16(), rnd.randint(-100, 100)])
            dvd = rnd.choice([rnd.randint(-2**31, 2**31 - 1), rnd.randint(-2**20, 2**20),
                              -2**31, 2**31 - 1, 32768 * 32767, -32768 * 32768, 0])
            opjob("div", [(8, dvd & 0xFFFF), (9, (dvd >> 16) & 0xFFFF), (10, dvs & 0xFFFF)])

    # Directed edges
    sc.note("face: s = 0 counts as towards the eye")
    opjob("face", [(0, 0), (1, 0), (2, 10), (3, 10), (4, 20), (5, 20)])
    sc.note("face: the largest s saturates")
    opjob("face", [(0, -32768), (1, -32768), (2, 32767), (3, -32768), (4, -32768), (5, 32767)])
    sc.note("divide: -32768 fits, 32768 does not")
    opjob("div", [(8, (-65536) & 0xFFFF), (9, ((-65536) >> 16) & 0xFFFF), (10, 2)])
    opjob("div", [(8, 65536 & 0xFFFF), (9, 1), (10, 2)])

    if board is None:
        with open(path, "w") as f:
            f.write("\n".join(sc.lines) + "\nX\n")
    else:
        write_board(path, sc.lines, board)
    return len(sc.lines)


def write_board(path, lines, vertices):
    """The script as a table for the Z80: two bytes an operation, op << 5 | (register & 0x1F), value.
    Ops: 0 end, 1 write, 2 read and check, 3 a start whose next operation, a read, is done at once
    (LD (HL),r then LD A,(DE)), 4 the next case (value 0). Gaps and deadlines are left out: the
    Z80 is slower than any of them. Then the timing loop's vertices: x, y, z words."""
    out = bytearray()
    for line in lines:
        op, *args = line.split(" ", 1)
        if op == "C":
            out += bytes([4 << 5, 0])
        elif op in ("W", "S", "R"):
            reg, val = (int(t, 16) for t in args[0].split())
            code = {"W": 1, "S": 3, "R": 2}[op]
            out += bytes([(code << 5) | (reg & 0x1F), val])
    out += bytes([0, 0])
    for x, y, z in vertices:
        for w in (x, y, z):
            out += (w & 0xFFFF).to_bytes(2, "little")
    with open(path, "wb") as f:
        f.write(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--vectors")
    ap.add_argument("--board")
    ap.add_argument("--seed", type=int, default=15)
    ap.add_argument("--count", type=int, default=3000)
    a = ap.parse_args()
    if a.board:
        rnd = random.Random(a.seed + 1)
        verts = [(rnd.randint(-120, 120), rnd.randint(-120, 120), rnd.randint(-120, 120)) for _ in range(128)]
        n = write_vectors(a.board, a.seed, a.count, board=verts)
        print(f"geom_model: {n} operations in {a.board}")
    else:
        n = write_vectors(a.vectors, a.seed, a.count)
        print(f"geom_model: {n} operations in {a.vectors}")


if __name__ == "__main__":
    main()
