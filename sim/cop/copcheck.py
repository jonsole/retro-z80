#!/usr/bin/env python3
"""Check the copper unit test (tb_cop.v) against a model of spec 6.

Usage: copcheck.py coptest.bin cop_hi.bin cop.log

The model runs each list from the table at the start of coptest.bin (as the
testbench does) and gives the register writes it makes, in order, and its
state when it stops. The beam is not simulated: a WAIT moves the model's
beam to its position, and the lists keep each SKIP well clear of where the
beam really is. Timing is checked on the log itself:
  - a write that follows a WAIT the copper really waited for (its position
    at least 20 pixels after the write before) lands on that position or
    the next pixel, for the first and second instruction after the WAIT
    (spec 6, sections 1 and 5.4: the two-word prefetch);
  - the rate tests: at PRI 1, with the CPU and the layers taking all the
    cycles they own, one MOVE every slot (10 clocks); at PRI 0 none until
    those channels let go.
Tests that run over several frames (WAITs that never end, RESUME, STKKEEP)
have checks of their own.
"""
import sys

HTOT, VTOT = 864, 625
M = 0x0E0
COPX, COPY, COPFLAGS, COPSP = 0x10E, 0x10F, 0x110, 0x111
COPJMP1, COPJMP2, COPINT, COPR0 = 0x107, 0x108, 0x109, 0x118

TESTS = ["move", "wait", "never1", "never2", "skip", "jump", "call", "callov", "retun",
         "movr", "alu", "skipc", "copint", "jmp2", "res", "nores", "cut", "stk", "nostk",
         "rate1", "rate0"] + ["bad%d" % i for i in range(19)]


class Mem:
    def __init__(self, lo, hi):
        self.lo, self.hi = lo, hi

    def word(self, byte_addr):
        a = byte_addr & 0x3FFFFE
        if a >= 0x2F0000 and a - 0x2F0000 + 1 < len(self.hi):
            o = a - 0x2F0000
            return self.hi[o] | self.hi[o + 1] << 8
        if a + 1 < len(self.lo):
            return self.lo[a] | self.lo[a + 1] << 8
        return 0xFFFF


def length(w0):
    code, lo = w0 >> 8, w0 & 0xFF
    if code < 0xF0:
        return 1
    c = code & 0xF
    if c in (0x0, 0x1, 0x2, 0xC):
        return 2
    if c == 0x9 and lo & 0xF == 10:
        return 2
    if c == 0xB and not lo & 0x80:
        return 2
    return 1


def reserved(w0, w1):
    code, lo = w0 >> 8, w0 & 0xFF
    if code < 0xF0:
        return False
    c = code & 0xF
    fn, src, d = lo >> 5, lo & 0xF, (lo >> 4) & 1
    if c == 0x0: return bool(lo & 0x30)
    if c == 0x1: return bool(lo & 0x70)
    if c == 0x2: return bool(lo & 0xC0) or bool(w1 & 1)
    if c == 0x3: return lo != 0
    if c == 0x8: return bool(lo & 0xFC)
    if c == 0x9:
        return src > 10 or ((fn == 1 or (fn == 7 and d)) and src >= 8) or (src == 10 and w1 >> 8 != 0)
    if c == 0xA: return bool(lo & 0xF8)
    if c == 0xB: return (lo & 0x7F) != 0 if lo & 0x80 else (bool(lo & 0x40) or bool(w1 & 1))
    if c == 0xC: return bool(lo & 0xFC)
    if c in (0xD, 0xE, 0xF): return True
    return False


def cond(cc, f):
    z, n, c = f & 1, (f >> 1) & 1, (f >> 2) & 1
    return [z, not z, c, not c, n, not n, not c and not z, c or z][cc]


def run(mem, lc1, lc2):
    """Run a list until it stops. Returns (writes, state); writes are
    (offset, data, wait) with wait = (position, k) for the k-th instruction
    after a WAIT (k = 0, 1), else None."""
    pc, x, y, f, r, stk = lc1, 0, 0, 0, [0] * 8, []
    beam, skip, err, irq, writes = 0, False, False, False, []
    after = None                       # (WAIT position, instructions, words since it)
    for _ in range(100000):
        w0 = mem.word(pc)
        w1 = mem.word(pc + 2)
        n = length(w0)
        nxt = (pc + 2 * n) & 0x3FFFFE
        code, lo = w0 >> 8, w0 & 0xFF
        # Within the two words prefetched during the WAIT?
        wait = None
        if after is not None:
            tgt, k, used = after
            if used + n <= 2:
                wait = (tgt, k)
            after = (tgt, k + 1, used + n) if used + n < 2 else None
        if skip:
            skip = False
            pc = nxt
            continue

        def write(off, data):
            nonlocal x, y, f, pc, irq
            writes.append((off, data & 0xFF, wait))
            if off == COPX: x = data
            elif off == COPY: y = data
            elif off == COPFLAGS: f = data & 7
            elif COPR0 <= off < COPR0 + 8: r[off - COPR0] = data
            elif off == COPINT: irq = True
            elif off == COPSP: stk.clear()
            elif off == COPJMP1: return lc1
            elif off == COPJMP2: return lc2
            return None

        if code < 0xF0:
            j = write(code, lo)
            pc = j if j is not None else nxt
            continue
        if reserved(w0, w1):
            err = True
            break
        c = code & 0xF
        line, px = ((lo >> 2) & 3) << 8 | w1 >> 8, (lo & 3) << 8 | w1 & 0xFF
        p = bool(lo & 0x80)
        if c == 0x0:                                           # WAIT
            if not p and line == 1023:
                break
            if p:
                if px >= HTOT:
                    return writes, None                        # never: the frame ends
                l = beam // HTOT + (1 if beam % HTOT >= px else 0)
                tgt = l * HTOT + px
            else:
                if line >= VTOT or px >= HTOT:
                    return writes, None
                tgt = line * HTOT + px
            beam = max(beam, tgt)
            after = (tgt, 0, 0)
            pc = nxt
            continue
        if c == 0x1:                                           # SKIP
            if p:
                skip = px < HTOT and beam % HTOT >= px
            else:
                skip = line < VTOT and px < HTOT and beam >= line * HTOT + px
            pc = nxt
            continue
        if c == 0x2:                                           # JUMP
            pc = (lo & 0x3F) << 16 | w1 & 0xFFFE
            continue
        if c == 0x3:                                           # STOP
            break
        if c in (0x4, 0x5, 0x6, 0x7, 0x8):                     # MOVR
            if c == 0x4: j = write(x, lo)
            elif c == 0x5:
                j = write(x, lo)
                x = (x + 1) & 0xFF
            elif c == 0x6: j = write(lo, x)
            elif c == 0x7: j = write(lo, y)
            else:
                j = write(x, x if lo & 1 else y)
                if lo & 2: x = (x + 1) & 0xFF
            pc = j if j is not None else nxt
            continue
        if c == 0x9:                                           # ALU
            fn, d, src = lo >> 5, (lo >> 4) & 1, lo & 0xF
            s = w1 & 0xFF if src == 10 else x if src == 8 else y if src == 9 else r[src & 7]
            dv = y if d else x
            if fn == 0:
                if d: y = s
                else: x = s
            elif fn == 1:
                r[src] = dv
            elif fn == 7:
                if d: r[src] = f
                else: f = s & 7
            else:
                if fn == 2: res = dv + s
                elif fn in (3, 6): res = dv - s
                elif fn == 4: res = dv & s
                else: res = dv | s
                cy = 1 if (fn == 2 and res > 0xFF) or (fn in (3, 6) and res < 0) else 0
                res &= 0xFF
                f = cy << 2 | (res >> 7) << 1 | (1 if res == 0 else 0)
                if fn != 6:
                    if d: y = res
                    else: x = res
            pc = nxt
            continue
        if c == 0xA:                                           # SKIPC
            skip = cond(lo & 0xF, f)
            pc = nxt
            continue
        if c == 0xB:
            if lo & 0x80:                                      # RET
                if not stk:
                    err = True
                    break
                pc = stk.pop()
            else:                                              # CALL
                if len(stk) == 8:
                    err = True
                    break
                stk.append(nxt)
                pc = (lo & 0x3F) << 16 | w1 & 0xFFFE
            continue
        if c == 0xC:                                           # MOVEF
            j = write((lo & 3) << 8 | w1 >> 8, w1 & 0xFF)
            pc = j if j is not None else nxt
            continue
    else:
        raise RuntimeError("the model ran away")
    stat = 0x02 | (4 if err else 0) | (8 if irq else 0)
    return writes, dict(stat=stat, pc=pc, x=x, y=y, f=f, sp=len(stk), r=r, irq=irq)


def parse(path):
    tests = {}
    cur = None
    for ln in open(path):
        t = ln.split()
        if not t:
            continue
        if t[0] == "T":
            cur = tests.setdefault(int(t[1]), {"w": [], "f": [], "s": None})
        elif t[0] == "W":
            cur["w"].append((int(t[1]), int(t[2]), int(t[3]), int(t[4], 16), int(t[5], 16)))
        elif t[0] == "F":
            cur["f"].append((int(t[1]), len(cur["w"])))
        elif t[0] == "S":
            v = [int(a, 16) for a in t[1:16]]
            cur["s"] = dict(stat=v[0], pc=v[1], x=v[2], y=v[3], f=v[4], sp=v[5], r=v[6:14],
                            lc2=v[14], irq=int(t[16]))
    return tests


def main():
    lo = open(sys.argv[1], "rb").read()
    hi = open(sys.argv[2], "rb").read()
    log = parse(sys.argv[3])
    mem = Mem(lo, hi)
    errors, checks = [], 0

    def err(n, msg):
        errors.append("test %d (%s): %s" % (n, TESTS[n] if n < len(TESTS) else "?", msg))

    n = 0
    while True:
        e = lo[n * 8:n * 8 + 8]
        if e[3] == 0xFF:
            break
        lc1, lc2 = e[0] | e[1] << 8 | e[2] << 16, e[4] | e[5] << 8 | e[6] << 16
        flags, frames = e[3], e[7]
        name = TESTS[n]
        t = log.get(n)
        if t is None or t["s"] is None:
            err(n, "not in the log")
            n += 1
            continue
        w = t["w"]
        ws = [(o, d) for (_, _, _, o, d) in w]
        checks += 1
        if frames == 0 and not name.startswith("rate"):
            exp, st = run(mem, lc1, lc2)
            if [(o, d) for (o, d, _) in exp] != ws:
                err(n, "writes %s, expected %s" % (fmt(ws), fmt([(o, d) for (o, d, _) in exp])))
            got = t["s"]
            for k in ("stat", "pc", "x", "y", "f", "sp", "r"):
                if got[k] != st[k]:
                    err(n, "%s %s, expected %s" % (k, got[k], st[k]))
            # Timing: writes after a WAIT really waited for
            prev = 0
            for i, (o, d, wt) in enumerate(exp):
                if i >= len(w):
                    break
                pos = w[i][0] * HTOT + w[i][1]
                if wt is not None and wt[0] - prev >= 20:
                    checks += 1
                    if not (wt[0] <= pos <= wt[0] + 1):
                        err(n, "write %d (%03x %02x) at line %d pixel %d, %s after the WAIT for line %d pixel %d"
                            % (i, o, d, w[i][0], w[i][1], "instruction %d" % (wt[1] + 1),
                               wt[0] // HTOT, wt[0] % HTOT))
                prev = pos
        elif name in ("never1", "never2"):
            if not ws or any(x != (M, 1) for x in ws):
                err(n, "writes %s, expected only M = 1 (the WAIT never ends)" % fmt(ws))
            if len(t["f"]) < 2:
                err(n, "no second frame restart")
        elif name in ("res", "nores"):
            cnt = [d for (o, d) in ws if o == M + 1]
            starts = [d for (o, d) in ws if o == M]
            if len(starts) < 3:
                err(n, "list 1 ran %d times" % len(starts))
            if name == "res":
                if cnt != [(i + 1) & 0xFF for i in range(len(cnt))]:
                    err(n, "list 2 did not carry on across the frame restarts: %s" % cnt[:8])
                if t["s"]["lc2"] == lc2:
                    err(n, "COP2LC not changed by RESUME")
            else:
                if cnt.count(1) < 3:
                    err(n, "list 2 did not start again each frame")
                if t["s"]["lc2"] != lc2:
                    err(n, "COP2LC changed without RESUME")
            if len(cnt) < 600:
                err(n, "list 2 counted only %d lines" % len(cnt))
        elif name == "cut":
            bad = [x for x in ws if x[0] in (M + 2, M + 3)]
            cnt = [d for (o, d) in ws if o == M + 1]
            if bad:
                err(n, "a skipped instruction ran after RESUME: %s" % fmt(bad))
            if cnt != [(i + 1) & 0xFF for i in range(len(cnt))]:
                err(n, "list 2 did not carry on across the restarts: %s" % cnt[:8])
            if len(t["f"]) < 5:
                err(n, "only %d frame restarts" % len(t["f"]))
            if len(cnt) < 100:
                err(n, "list 2 ran only %d times" % len(cnt))
        elif name in ("stk", "nostk"):
            want = 3 if name == "stk" else 1
            if t["s"]["sp"] != want:
                err(n, "COPSP %d after three frames, expected %d" % (t["s"]["sp"], want))
        elif name.startswith("rate"):
            if ws != [(M, i) for i in range(1, 41)]:
                err(n, "writes %s" % fmt(ws))
            elif name == "rate1":
                for i in range(2, 40):
                    checks += 1
                    if w[i + 0][2] - w[i - 1][2] != 10 and i > 2:
                        err(n, "MOVE %d %d clocks after the one before, not 10" % (i + 1, w[i][2] - w[i - 1][2]))
                        break
                if w[39][0] != 200:
                    err(n, "the 40 MOVEs not on line 200")
            else:
                checks += 1
                if [x[0] for x in w[:2]] != [200, 200] or w[2][0] < 400:
                    err(n, "at PRI 0 the copper got cycles it should not: %s"
                        % [(x[0], x[1]) for x in w[:4]])
        n += 1

    print("copcheck: %d tests, %d checks" % (n, checks))
    for e in errors:
        print("ERROR:", e)
    print("TEST PASSED" if not errors else "TEST FAILED")
    sys.exit(1 if errors else 0)


def fmt(ws):
    s = " ".join("%03x=%02x" % (o, d) for (o, d) in ws[:24])
    return s + (" ..." if len(ws) > 24 else "")


if __name__ == "__main__":
    main()
