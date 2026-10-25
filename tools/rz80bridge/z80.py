"""A small Z80 interpreter for the stub model (debug.md, section 3.8).

Every documented instruction (unprefixed, CB, ED, DD, FD, DD CB, FD CB),
decoded by the x/y/z/p/q fields of the opcode. Flags S, Z, H, P/V, N and C
are exact; bits 3 and 5 are copied from the result and not chased further.
No timing and no interrupts: the model steps whole instructions.

The machine around it gives four callables: read(addr), write(addr, v),
port_in(port) and port_out(port, v). Each instruction is one call to step().
"""


def _parity(v):
    v ^= v >> 4
    v ^= v >> 2
    v ^= v >> 1
    return (v & 1) == 0


SF, ZF, YF, HF, XF, PF, NF, CF = 0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01


def _szp(v):
    f = v & (SF | YF | XF)
    if v == 0:
        f |= ZF
    if _parity(v):
        f |= PF
    return f


class Z80:
    def __init__(self, read, write, port_in=None, port_out=None, m1=None):
        self.read = read
        self.m1 = m1 or read   # opcode fetches (watchpoints ignore them)
        self.write = write
        self.port_in = port_in or (lambda p: 0xFF)
        self.port_out = port_out or (lambda p, v: None)
        self.reset()

    def reset(self):
        self.a = self.f = self.b = self.c = self.d = self.e = self.h = self.l = 0xFF
        self.a_ = self.f_ = self.b_ = self.c_ = self.d_ = self.e_ = self.h_ = self.l_ = 0xFF
        self.ix = self.iy = 0xFFFF
        self.sp = 0xFFFF
        self.pc = 0
        self.i = self.r = 0
        self.iff1 = self.iff2 = 0
        self.im = 0
        self.halted = False

    # ------------------------------------------------------------ pairs
    @property
    def bc(self):
        return (self.b << 8) | self.c

    @bc.setter
    def bc(self, v):
        self.b, self.c = (v >> 8) & 0xFF, v & 0xFF

    @property
    def de(self):
        return (self.d << 8) | self.e

    @de.setter
    def de(self, v):
        self.d, self.e = (v >> 8) & 0xFF, v & 0xFF

    @property
    def hl(self):
        return (self.h << 8) | self.l

    @hl.setter
    def hl(self, v):
        self.h, self.l = (v >> 8) & 0xFF, v & 0xFF

    @property
    def af(self):
        return (self.a << 8) | self.f

    @af.setter
    def af(self, v):
        self.a, self.f = (v >> 8) & 0xFF, v & 0xFF

    # ------------------------------------------------------------ memory
    def _fetch(self):
        v = self.read(self.pc)
        self.pc = (self.pc + 1) & 0xFFFF
        return v

    def _fetch_m1(self):
        v = self.m1(self.pc)
        self.pc = (self.pc + 1) & 0xFFFF
        return v

    def _fetch16(self):
        lo = self._fetch()
        return lo | (self._fetch() << 8)

    def _rd16(self, a):
        return self.read(a) | (self.read((a + 1) & 0xFFFF) << 8)

    def _wr16(self, a, v):
        self.write(a, v & 0xFF)
        self.write((a + 1) & 0xFFFF, (v >> 8) & 0xFF)

    def _push(self, v):
        self.sp = (self.sp - 1) & 0xFFFF
        self.write(self.sp, (v >> 8) & 0xFF)
        self.sp = (self.sp - 1) & 0xFFFF
        self.write(self.sp, v & 0xFF)

    def _pop(self):
        v = self._rd16(self.sp)
        self.sp = (self.sp + 2) & 0xFFFF
        return v

    # ------------------------------------------------------------ registers by index
    # r: 0 B, 1 C, 2 D, 3 E, 4 H, 5 L, 6 (HL), 7 A. With an index prefix, H/L
    # mean IXH/IXL except where (HL) is also used (then H and L are plain).
    def _get_r(self, r, idx=None, addr=None):
        if r == 6:
            return self.read(addr)
        if r == 7:
            return self.a
        if r in (4, 5) and idx and addr is None:
            v = getattr(self, idx)
            return (v >> 8) if r == 4 else (v & 0xFF)
        return getattr(self, "bcdehl"[r])

    def _set_r(self, r, v, idx=None, addr=None):
        v &= 0xFF
        if r == 6:
            self.write(addr, v)
        elif r == 7:
            self.a = v
        elif r in (4, 5) and idx and addr is None:
            w = getattr(self, idx)
            w = (v << 8) | (w & 0xFF) if r == 4 else (w & 0xFF00) | v
            setattr(self, idx, w)
        else:
            setattr(self, "bcdehl"[r], v)

    def _get_rp(self, p, idx=None):
        if p == 0:
            return self.bc
        if p == 1:
            return self.de
        if p == 2:
            return getattr(self, idx) if idx else self.hl
        return self.sp

    def _set_rp(self, p, v, idx=None):
        v &= 0xFFFF
        if p == 0:
            self.bc = v
        elif p == 1:
            self.de = v
        elif p == 2:
            if idx:
                setattr(self, idx, v)
            else:
                self.hl = v
        else:
            self.sp = v

    def _get_rp2(self, p, idx=None):
        return self.af if p == 3 else self._get_rp(p, idx)

    def _set_rp2(self, p, v, idx=None):
        if p == 3:
            self.af = v & 0xFFFF
        else:
            self._set_rp(p, v, idx)

    def _cond(self, y):
        f = self.f
        return [not f & ZF, bool(f & ZF), not f & CF, bool(f & CF),
                not f & PF, bool(f & PF), not f & SF, bool(f & SF)][y]

    # ------------------------------------------------------------ ALU
    def _alu(self, op, v):
        a = self.a
        if op in (0, 1):  # ADD, ADC
            c = (self.f & CF) if op == 1 else 0
            r = a + v + c
            f = _szp(r & 0xFF) & ~PF
            if (a ^ v ^ r) & 0x10:
                f |= HF
            if (~(a ^ v) & (a ^ r)) & 0x80:
                f |= PF
            if r > 0xFF:
                f |= CF
            self.a, self.f = r & 0xFF, f
        elif op in (2, 3, 7):  # SUB, SBC, CP
            c = (self.f & CF) if op == 3 else 0
            r = a - v - c
            f = (_szp(r & 0xFF) & ~PF) | NF
            if (a ^ v ^ r) & 0x10:
                f |= HF
            if ((a ^ v) & (a ^ r)) & 0x80:
                f |= PF
            if r < 0:
                f |= CF
            if op == 7:
                f = (f & ~(YF | XF)) | (v & (YF | XF))
                self.f = f
            else:
                self.a, self.f = r & 0xFF, f
        elif op == 4:
            self.a = a & v
            self.f = _szp(self.a) | HF
        elif op == 5:
            self.a = a ^ v
            self.f = _szp(self.a)
        elif op == 6:
            self.a = a | v
            self.f = _szp(self.a)

    def _inc8(self, v):
        r = (v + 1) & 0xFF
        f = (self.f & CF) | (_szp(r) & ~PF)
        if (v & 0x0F) == 0x0F:
            f |= HF
        if v == 0x7F:
            f |= PF
        self.f = f
        return r

    def _dec8(self, v):
        r = (v - 1) & 0xFF
        f = (self.f & CF) | (_szp(r) & ~PF) | NF
        if (v & 0x0F) == 0:
            f |= HF
        if v == 0x80:
            f |= PF
        self.f = f
        return r

    def _add16(self, a, b):
        r = a + b
        f = self.f & (SF | ZF | PF)
        if (a ^ b ^ r) & 0x1000:
            f |= HF
        if r > 0xFFFF:
            f |= CF
        f |= (r >> 8) & (YF | XF)
        self.f = f
        return r & 0xFFFF

    def _adc16(self, a, b):
        c = self.f & CF
        r = a + b + c
        f = 0
        if (r & 0xFFFF) == 0:
            f |= ZF
        if r & 0x8000:
            f |= SF
        if (a ^ b ^ r) & 0x1000:
            f |= HF
        if (~(a ^ b) & (a ^ r)) & 0x8000:
            f |= PF
        if r > 0xFFFF:
            f |= CF
        f |= (r >> 8) & (YF | XF)
        self.f = f
        return r & 0xFFFF

    def _sbc16(self, a, b):
        c = self.f & CF
        r = a - b - c
        f = NF
        if (r & 0xFFFF) == 0:
            f |= ZF
        if r & 0x8000:
            f |= SF
        if (a ^ b ^ r) & 0x1000:
            f |= HF
        if ((a ^ b) & (a ^ r)) & 0x8000:
            f |= PF
        if r < 0:
            f |= CF
        f |= (r >> 8) & (YF | XF)
        self.f = f
        return r & 0xFFFF

    def _rot(self, y, v):
        c = self.f & CF
        if y == 0:    # RLC
            co = v >> 7
            r = ((v << 1) | co) & 0xFF
        elif y == 1:  # RRC
            co = v & 1
            r = (v >> 1) | (co << 7)
        elif y == 2:  # RL
            co = v >> 7
            r = ((v << 1) | c) & 0xFF
        elif y == 3:  # RR
            co = v & 1
            r = (v >> 1) | (c << 7)
        elif y == 4:  # SLA
            co = v >> 7
            r = (v << 1) & 0xFF
        elif y == 5:  # SRA
            co = v & 1
            r = (v >> 1) | (v & 0x80)
        elif y == 6:  # SLL
            co = v >> 7
            r = ((v << 1) | 1) & 0xFF
        else:         # SRL
            co = v & 1
            r = v >> 1
        self.f = _szp(r) | (CF if co else 0)
        return r

    def _daa(self):
        a = self.a
        f = self.f
        corr = 0
        carry = f & CF
        if (f & HF) or (a & 0x0F) > 9:
            corr |= 0x06
        if carry or a > 0x99:
            corr |= 0x60
            carry = CF
        if f & NF:
            h = HF if (f & HF) and (a & 0x0F) < 6 else 0
            a = (a - corr) & 0xFF
        else:
            h = HF if (a & 0x0F) > 9 else 0
            a = (a + corr) & 0xFF
        self.a = a
        self.f = _szp(a) | h | carry | (f & NF)

    # ------------------------------------------------------------ step
    def step(self):
        """Runs one instruction. HALT steps past itself (debug.md 5.8)."""
        self.r = (self.r & 0x80) | ((self.r + 1) & 0x7F)
        op = self._fetch_m1()
        if op == 0xCB:
            return self._cb(None, None)
        if op == 0xED:
            return self._ed()
        if op in (0xDD, 0xFD):
            idx = "ix" if op == 0xDD else "iy"
            # further prefixes: the last one counts
            while True:
                op = self._fetch_m1()
                if op in (0xDD, 0xFD):
                    idx = "ix" if op == 0xDD else "iy"
                    continue
                break
            if op == 0xED:
                return self._ed(fetched=True)
            if op == 0xCB:
                d = self._fetch()
                d = d - 256 if d & 0x80 else d
                addr = (getattr(self, idx) + d) & 0xFFFF
                return self._cb(idx, addr)
            return self._main(op, idx)
        return self._main(op, None)

    def _idx_addr(self, idx):
        d = self._fetch()
        d = d - 256 if d & 0x80 else d
        return (getattr(self, idx) + d) & 0xFFFF

    def _main(self, op, idx):
        x, y, z = op >> 6, (op >> 3) & 7, op & 7
        p, q = y >> 1, y & 1
        if x == 0:
            if z == 0:
                if y == 0:
                    pass
                elif y == 1:
                    self.af, (self.a_, self.f_) = (self.a_ << 8) | self.f_, (self.a, self.f)
                elif y == 2:
                    d = self._fetch()
                    self.b = (self.b - 1) & 0xFF
                    if self.b:
                        self.pc = (self.pc + (d - 256 if d & 0x80 else d)) & 0xFFFF
                elif y == 3:
                    d = self._fetch()
                    self.pc = (self.pc + (d - 256 if d & 0x80 else d)) & 0xFFFF
                else:
                    d = self._fetch()
                    if self._cond(y - 4):
                        self.pc = (self.pc + (d - 256 if d & 0x80 else d)) & 0xFFFF
            elif z == 1:
                if q == 0:
                    self._set_rp(p, self._fetch16(), idx)
                else:
                    hl = self._get_rp(2, idx)
                    self._set_rp(2, self._add16(hl, self._get_rp(p, idx)), idx)
            elif z == 2:
                if q == 0:
                    if p == 0:
                        self.write(self.bc, self.a)
                    elif p == 1:
                        self.write(self.de, self.a)
                    elif p == 2:
                        self._wr16(self._fetch16(), self._get_rp(2, idx))
                    else:
                        self.write(self._fetch16(), self.a)
                else:
                    if p == 0:
                        self.a = self.read(self.bc)
                    elif p == 1:
                        self.a = self.read(self.de)
                    elif p == 2:
                        self._set_rp(2, self._rd16(self._fetch16()), idx)
                    else:
                        self.a = self.read(self._fetch16())
            elif z == 3:
                v = self._get_rp(p, idx)
                self._set_rp(p, v + 1 if q == 0 else v - 1, idx)
            elif z in (4, 5):
                addr = None
                if y == 6:
                    addr = self._idx_addr(idx) if idx else self.hl
                v = self._get_r(y, idx, addr)
                self._set_r(y, self._inc8(v) if z == 4 else self._dec8(v), idx, addr)
            elif z == 6:
                addr = None
                if y == 6:
                    addr = self._idx_addr(idx) if idx else self.hl
                self._set_r(y, self._fetch(), idx, addr)
            else:
                if y == 0:    # RLCA
                    c = self.a >> 7
                    self.a = ((self.a << 1) | c) & 0xFF
                    self.f = (self.f & (SF | ZF | PF)) | c | (self.a & (YF | XF))
                elif y == 1:  # RRCA
                    c = self.a & 1
                    self.a = (self.a >> 1) | (c << 7)
                    self.f = (self.f & (SF | ZF | PF)) | c | (self.a & (YF | XF))
                elif y == 2:  # RLA
                    c = self.a >> 7
                    self.a = ((self.a << 1) | (self.f & CF)) & 0xFF
                    self.f = (self.f & (SF | ZF | PF)) | c | (self.a & (YF | XF))
                elif y == 3:  # RRA
                    c = self.a & 1
                    self.a = (self.a >> 1) | ((self.f & CF) << 7)
                    self.f = (self.f & (SF | ZF | PF)) | c | (self.a & (YF | XF))
                elif y == 4:
                    self._daa()
                elif y == 5:  # CPL
                    self.a ^= 0xFF
                    self.f = (self.f & (SF | ZF | PF | CF)) | HF | NF | (self.a & (YF | XF))
                elif y == 6:  # SCF
                    self.f = (self.f & (SF | ZF | PF)) | CF | (self.a & (YF | XF))
                else:         # CCF
                    c = self.f & CF
                    self.f = (self.f & (SF | ZF | PF)) | (HF if c else 0) | (0 if c else CF) | (self.a & (YF | XF))
        elif x == 1:
            if op == 0x76:
                self.halted = True   # the model steps past HALT
                return
            if y == 6 or z == 6:
                addr = (self._idx_addr(idx) if idx else self.hl)
                if y == 6:
                    self.write(addr, self._get_r(z))
                else:
                    self._set_r(y, self.read(addr))
            else:
                self._set_r(y, self._get_r(z, idx), idx)
        elif x == 2:
            addr = None
            if z == 6:
                addr = self._idx_addr(idx) if idx else self.hl
            self._alu(y, self._get_r(z, idx, addr))
        else:
            if z == 0:
                if self._cond(y):
                    self.pc = self._pop()
            elif z == 1:
                if q == 0:
                    self._set_rp2(p, self._pop(), idx)
                elif p == 0:
                    self.pc = self._pop()
                elif p == 1:  # EXX
                    for r in "bcdehl":
                        a, b = getattr(self, r), getattr(self, r + "_")
                        setattr(self, r, b)
                        setattr(self, r + "_", a)
                elif p == 2:
                    self.pc = self._get_rp(2, idx)
                else:
                    self.sp = self._get_rp(2, idx)
            elif z == 2:
                nn = self._fetch16()
                if self._cond(y):
                    self.pc = nn
            elif z == 3:
                if y == 0:
                    self.pc = self._fetch16()
                elif y == 2:
                    n = self._fetch()
                    self.port_out((self.a << 8) | n, self.a)
                elif y == 3:
                    n = self._fetch()
                    self.a = self.port_in((self.a << 8) | n) & 0xFF
                elif y == 4:  # EX (SP),HL
                    v = self._rd16(self.sp)
                    self._wr16(self.sp, self._get_rp(2, idx))
                    self._set_rp(2, v, idx)
                elif y == 5:  # EX DE,HL
                    d = self.de
                    self.de = self.hl
                    self.hl = d
                elif y == 6:
                    self.iff1 = self.iff2 = 0
                else:
                    self.iff1 = self.iff2 = 1
            elif z == 4:
                nn = self._fetch16()
                if self._cond(y):
                    self._push(self.pc)
                    self.pc = nn
            elif z == 5:
                if q == 0:
                    self._push(self._get_rp2(p, idx))
                else:
                    nn = self._fetch16()
                    self._push(self.pc)
                    self.pc = nn
            elif z == 6:
                self._alu(y, self._fetch())
            else:
                self._push(self.pc)
                self.pc = y * 8

    def _cb(self, idx, addr):
        op = self._fetch() if idx else self._fetch_m1()
        x, y, z = op >> 6, (op >> 3) & 7, op & 7
        if addr is None and z == 6:
            addr = self.hl
        if addr is not None:
            v = self.read(addr)
        else:
            v = self._get_r(z)
        if x == 0:
            r = self._rot(y, v)
        elif x == 1:
            f = (self.f & CF) | HF | (v & (YF | XF))
            if not v & (1 << y):
                f |= ZF | PF
            if y == 7 and v & 0x80:
                f |= SF
            self.f = f
            return
        elif x == 2:
            r = v & ~(1 << y) & 0xFF
        else:
            r = v | (1 << y)
        if addr is not None:
            self.write(addr, r)
            if idx and z != 6:
                self._set_r(z, r)   # the undocumented copy into a register
        else:
            self._set_r(z, r)

    def _ed(self, fetched=False):
        op = self._fetch_m1()
        x, y, z = op >> 6, (op >> 3) & 7, op & 7
        p, q = y >> 1, y & 1
        if x == 1:
            if z == 0:
                v = self.port_in(self.bc) & 0xFF
                if y != 6:
                    self._set_r(y, v)
                self.f = (self.f & CF) | _szp(v)
            elif z == 1:
                self.port_out(self.bc, 0 if y == 6 else self._get_r(y))
            elif z == 2:
                if q == 0:
                    self.hl = self._sbc16(self.hl, self._get_rp(p))
                else:
                    self.hl = self._adc16(self.hl, self._get_rp(p))
            elif z == 3:
                nn = self._fetch16()
                if q == 0:
                    self._wr16(nn, self._get_rp(p))
                else:
                    self._set_rp(p, self._rd16(nn))
            elif z == 4:   # NEG
                v = self.a
                self.a = 0
                self._alu(2, v)
            elif z == 5:   # RETN, RETI
                self.pc = self._pop()
                self.iff1 = self.iff2
            elif z == 6:
                self.im = [0, 0, 1, 2, 0, 0, 1, 2][y]
            else:
                if y == 0:
                    self.i = self.a
                elif y == 1:
                    self.r = self.a
                elif y in (2, 3):
                    self.a = self.i if y == 2 else self.r
                    self.f = (self.f & CF) | (_szp(self.a) & ~PF) | (PF if self.iff2 else 0)
                elif y == 4:  # RRD
                    m = self.read(self.hl)
                    self.write(self.hl, ((self.a << 4) | (m >> 4)) & 0xFF)
                    self.a = (self.a & 0xF0) | (m & 0x0F)
                    self.f = (self.f & CF) | _szp(self.a)
                elif y == 5:  # RLD
                    m = self.read(self.hl)
                    self.write(self.hl, ((m << 4) | (self.a & 0x0F)) & 0xFF)
                    self.a = (self.a & 0xF0) | (m >> 4)
                    self.f = (self.f & CF) | _szp(self.a)
        elif x == 2 and z <= 3 and y >= 4:
            self._block(y, z)
        # anything else: a NOP

    def _block(self, y, z):
        """LDI/CPI/INI/OUTI and friends. A repeating one does one iteration
        and steps PC back, so each step is one iteration (debug.md 5.8)."""
        dec = y in (5, 7)
        rep = y >= 6
        delta = -1 if dec else 1
        start = (self.pc - 2) & 0xFFFF
        if z == 0:   # LD
            v = self.read(self.hl)
            self.write(self.de, v)
            self.hl = self.hl + delta
            self.de = self.de + delta
            self.bc = self.bc - 1
            self.f = (self.f & (SF | ZF | CF)) | (PF if self.bc else 0)
            again = self.bc != 0
        elif z == 1:  # CP
            v = self.read(self.hl)
            r = (self.a - v) & 0xFF
            self.hl = self.hl + delta
            self.bc = self.bc - 1
            f = (self.f & CF) | NF | (_szp(r) & (SF | ZF))
            if (self.a ^ v ^ r) & 0x10:
                f |= HF
            if self.bc:
                f |= PF
            self.f = f
            again = self.bc != 0 and r != 0
        elif z == 2:  # IN
            v = self.port_in(self.bc) & 0xFF
            self.write(self.hl, v)
            self.hl = self.hl + delta
            self.b = (self.b - 1) & 0xFF
            self.f = (self.f & CF) | NF | (ZF if self.b == 0 else 0) | (self.b & SF)
            again = self.b != 0
        else:         # OUT
            v = self.read(self.hl)
            self.b = (self.b - 1) & 0xFF
            self.port_out(self.bc, v)
            self.hl = self.hl + delta
            self.f = (self.f & CF) | NF | (ZF if self.b == 0 else 0) | (self.b & SF)
            again = self.b != 0
        if rep and again:
            self.pc = start
