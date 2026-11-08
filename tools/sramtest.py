#!/usr/bin/env python3
"""sramtest.py: the PC end of the KS2's SRAM timing tester (issue #90).

Load the tester first (fpga/ks2/build.sh --sramtest --program-only); it
talks over the FT232H, as the computer does.

    python3 tools/sramtest.py              the whole sweep; writes docs/notes/sram-ks2.md
    python3 tools/sramtest.py check        one run at the 20 ns defaults, over all 2 MB
    python3 tools/sramtest.py scope        the samples of one write and one read cycle

Options:
    --port COM3      the FT232H's serial port
    --words 65536    the region each sweep run writes and reads (words; the
                     full checks always use all 1M words)
    --cycles 16,12,10,8
                     the cycle lengths to sweep, in 1.25 ns steps
    --out FILE       where the sweep writes its results

What the sweep does, for the 35 ns reference cycle first (28 steps, the
retro-spectrum build's speed, to show the rig itself is sound) and then each
cycle length: the loopback (when the FPGA sees its own DQ drive), the read
capture point (sample step and IDELAY taps), the /WE falling and rising
steps, the data set-up (drive start), the write-after-read turnaround and the
read-after-write turnaround, each swept alone around the cycle's defaults;
then a full check of all 2 MB with each setting at the middle of its window.
Each sweep is printed as a map: one row a setting, the error count, a bar
(one # per doubling) and which DQ bits failed.

Needs Python 3.8 or newer and pyserial.
"""

import argparse
import datetime
import math
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STEP = 1.25          # ns
TAP = 0.078          # ns per IDELAY tap

# Settings (fpga/rtl/sramtest/sramt_engine.v)
NAMES = ["nstep", "oe_lo", "oe_hi", "cap", "taps", "we_lo", "we_hi", "d_lo", "d_hi",
         "war_lo", "wchk", "seq", "data", "addr", "base_lo", "base_hi", "count_lo",
         "count_hi", "seed_lo", "seed_hi", "repeat", "scope_lo", "scope_hi"]
IDX = {n: i for i, n in enumerate(NAMES)}
SEQ_WR, SEQ_W, SEQ_R, SEQ_ALT = 0, 1, 2, 3
DATA_RANDOM, DATA_FLIP, DATA_WALK = 0, 1, 2
ALL_WORDS = 1 << 20


def timing(n):
    """The cycle's own settings for n steps: sram_ctl's 20 ns cycle (n = 16)
    scaled: /OE and /WE fall a quarter in, /WE rises at three quarters, the
    data is driven from a quarter in to the end, the capture is at the end."""
    q = max(1, round(n / 4))
    return dict(nstep=n, oe_lo=q, oe_hi=n, cap=n, taps=0, we_lo=q, we_hi=n - q,
                d_lo=q, d_hi=n, war_lo=q, wchk=n - q)


# ---------------------------------------------------------------- the link

class Tester:
    def __init__(self, port):
        import serial
        self.port = serial.Serial(port, 3000000, timeout=2.0)
        time.sleep(0.03)                  # an unfinished command is dropped after 10 ms
        self.port.reset_input_buffer()
        magic = self.dump(0, 4)
        if magic != b"SRT1":
            sys.exit("sramtest.py: no SRAM tester on %s (read %r); load it with "
                     "fpga/ks2/build.sh --sramtest --program-only" % (port, magic))

    def read(self, n, timeout=2.0):
        self.port.timeout = timeout
        b = self.port.read(n)
        if len(b) != n:
            sys.exit("sramtest.py: the tester stopped answering (%d of %d bytes)" % (len(b), n))
        return b

    def set(self, **kw):
        cmd = bytearray()
        for k, v in kw.items():
            v &= 0xFFFF
            cmd += bytes([ord("W"), IDX[k], v & 0xFF, v >> 8])
        self.port.write(cmd)
        if self.read(len(kw)) != b"w" * len(kw):
            sys.exit("sramtest.py: a setting was not taken")

    def region(self, base, words):
        self.set(base_lo=base & 0xFFFF, base_hi=base >> 16,
                 count_lo=words & 0xFFFF, count_hi=words >> 16)

    def run(self, cycles):
        """One run; cycles is roughly how many memory cycles it makes."""
        self.port.write(b"R")
        if self.read(1, timeout=2.0 + cycles * 40e-9) != b"r":
            sys.exit("sramtest.py: no end to the run")

    def dump(self, addr, n):
        self.port.write(bytes([ord("D"), addr & 0xFF, addr >> 8, n & 0xFF]))
        return self.read(n)

    def results(self):
        b = self.dump(0, 0x60)
        w = [int.from_bytes(b[i:i + 4], "little") for i in range(0, 0x60, 4)]
        return dict(err=w[1], bus=w[2], reads=w[3], first=w[4], got=w[5] & 0xFFFF,
                    exp=w[5] >> 16, writes=w[6], bits=w[8:24])

    def scope(self):
        b = self.dump(0x1C, 4)
        kind, j = b[0] & 3, b[1] & 0x3F
        s = self.dump(0x60, 96)
        samples = [s[2 * i] | (s[2 * i + 1] << 8) for i in range(48)]
        return kind, j, samples


# ---------------------------------------------------------------- runs and maps

def bar(errors):
    return "" if errors == 0 else "#" * min(40, 1 + int(math.log2(errors)))


def bitmap(bits):
    return "".join("x" if bits[15 - i] else "." for i in range(16))   # D15 .. D0


class Sweeper:
    def __init__(self, t, words, out):
        self.t, self.words, self.lines = t, words, []
        self.out = out
        self.cfg = {}
        self.seed = 1

    def say(self, s=""):
        print(s)
        sys.stdout.flush()
        self.lines.append(s)

    def apply(self, **kw):
        self.cfg.update(kw)
        self.t.set(**kw)

    def go(self, seq, data=DATA_RANDOM, words=None, base=0x10000, addr=0, **kw):
        """A run with the cycle settings in kw on top of self.cfg."""
        words = words or self.words
        self.seed = (self.seed * 1103515245 + 12345) & 0xFFFFFFFF
        s = dict(self.cfg)
        s.update(kw)
        s.update(seq=seq, data=data, addr=addr, seed_lo=self.seed & 0xFFFF,
                 seed_hi=self.seed >> 16, repeat=1, scope_lo=0, scope_hi=0)
        self.t.set(**s)
        if seq in (SEQ_WR, SEQ_W, SEQ_ALT):
            self.t.region(base, words)
            self.wseed = self.seed
        else:
            self.t.region(base, words)
            self.t.set(seed_lo=self.wseed & 0xFFFF, seed_hi=self.wseed >> 16)
        self.t.run(2 * words * s["nstep"] // 8)
        return self.t.results()

    def table(self, title, rows, unit_note):
        """rows: (label, ns, results, is_default)"""
        self.say("```")
        self.say("%s  (%s)" % (title, unit_note))
        self.say("  %-16s %8s %9s %9s  %-16s" % ("setting", "ns", "wrong", "bus", "D15..D0"))
        for label, ns, r, mark in rows:
            self.say("  %-16s %8.2f %9d %9d  %-16s  %s%s" % (
                label, ns, r["err"], r["bus"], bitmap(r["bits"]), bar(r["err"] + r["bus"]),
                "   <- default" if mark else ""))
        self.say("```")
        self.say()

    # ---- window helpers: the run of passing rows round the default
    @staticmethod
    def window(rows):
        """rows: list of (ns, ok, is_default). Returns (lo, hi) of the passing run
        that holds the default, or the longest one, or None."""
        runs, cur = [], []
        for ns, ok, d in rows:
            if ok:
                cur.append((ns, d))
            elif cur:
                runs.append(cur)
                cur = []
        if cur:
            runs.append(cur)
        if not runs:
            return None
        pick = [r for r in runs if any(d for _, d in r)]
        r = pick[0] if pick else max(runs, key=len)
        return (min(x for x, _ in r), max(x for x, _ in r), bool(pick))

    def summary_row(self, name, rows, default_ns):
        w = self.window(rows)
        if w is None:
            return (name, "none", "%.2f" % default_ns, "fails")
        lo, hi, holds = w
        if holds:
            margin = "%.2f / %.2f" % (default_ns - lo, hi - default_ns)
        else:
            margin = "default fails"
        return (name, "%.2f to %.2f" % (lo, hi), "%.2f" % default_ns, margin)

    # ---- the sweeps for one cycle length
    def cycle(self, n, title=None, note=None):
        ns = n * STEP
        base = timing(n)
        self.cfg = dict(base)
        self.t.set(**base)
        self.say(title or "## %.2f ns cycle (%d steps)" % (ns, n))
        self.say()
        if note:
            self.say(note)
            self.say()
        self.say("Defaults: /OE low %d-%d, capture at step %d, /WE low %d-%d, data driven %d-%d "
                 "(after a read from %d). Steps are 1.25 ns from the address leaving the FPGA."
                 % (base["oe_lo"], base["oe_hi"], base["cap"], base["we_lo"], base["we_hi"],
                    base["d_lo"], base["d_hi"], base["war_lo"]))
        self.say()
        summary = []
        best = dict(base)

        # Loopback: when does the FPGA see its own drive? (write, 0x0000 after 0xFFFF)
        self.t.set(**base)
        self.t.set(seq=SEQ_W, data=DATA_FLIP, addr=0, scope_lo=4, scope_hi=0, repeat=1)
        self.t.region(0x10000, 16)
        self.t.run(32)
        kind, j, smp = self.t.scope()
        first = []
        for b in range(16):
            s = next((k for k in range(j + base["d_lo"], 48) if not (smp[k] >> b) & 1), None)
            first.append(None if s is None else s - j)
        seen = [f for f in first if f is not None]
        loop = (max(seen) - base["d_lo"]) if seen else None
        self.say("Loopback: driven from step %d, seen by the FPGA from step %s (per DQ bit, "
                 "D15..D0: %s), so the pads' out-and-in delay is about %s steps."
                 % (base["d_lo"], max(seen) if seen else "never",
                    " ".join("-" if f is None else str(f) for f in reversed(first)),
                    loop if loop is not None else "?"))
        self.say()
        self.loop = loop if loop is not None else 3

        # Write once, then read it back at each capture point
        r = self.go(SEQ_W)
        rows, wrow = [], []
        for cap in range(max(0, n // 2), n + 8):
            for taps in (0, 8, 16, 24):
                r = self.go(SEQ_R, cap=cap, taps=taps)
                t_ns = cap * STEP - taps * TAP
                d = (cap == base["cap"] and taps == 0)
                rows.append(("cap %2d taps %2d" % (cap, taps), t_ns, r, d))
        rows.sort(key=lambda x: x[1])
        self.table("Read capture: the sample's time from the address leaving (more taps "
                   "sample earlier)", rows, "%d words a row" % self.words)
        cw = [(x[1], x[2]["err"] == 0, x[3]) for x in rows]
        summary.append(self.summary_row("Read capture", cw, base["cap"] * STEP))
        w = self.window(cw)
        if w:
            mid = (w[0] + w[1]) / 2
            c = min(rows, key=lambda x: abs(x[1] - mid) if x[2]["err"] == 0 else 1e9)
            best["cap"], best["taps"] = [int(v) for v in c[0].split()[1::2]]

        def sweep(name, key, values, seq, data=DATA_RANDOM, label=None, nsf=None, extra=None):
            rows = []
            for v in values:
                kw = {key: v}
                if extra:
                    kw.update(extra(v))
                r = self.go(seq, data=data, **kw)
                rows.append((label(v) if label else "%s %d" % (key, v),
                             nsf(v) if nsf else v * STEP, r, v == base[key]))
            self.table(name, rows, "%d words a row" % self.words)
            ok = [(x[1], x[2]["err"] == 0 and x[2]["bus"] == 0, x[3]) for x in rows]
            summary.append(self.summary_row(name.split(":")[0], ok,
                                            nsf(base[key]) if nsf else base[key] * STEP))
            w = self.window(ok)
            if w:
                mid = (w[0] + w[1]) / 2
                good = [(abs(x[1] - mid), v) for x, v in zip(rows, values) if x[2]["err"] == 0 and x[2]["bus"] == 0]
                if good:
                    best[key] = min(good)[1]
            return rows

        sweep("/WE falls: write then read, /WE rising at step %d" % base["we_hi"], "we_lo",
              range(0, base["we_hi"]), SEQ_WR,
              label=lambda v: "/WE low %d-%d" % (v, base["we_hi"]))
        sweep("/WE rises: write then read, /WE falling at step %d" % base["we_lo"], "we_hi",
              range(base["we_lo"] + 1, n + 1), SEQ_WR,
              label=lambda v: "/WE low %d-%d" % (base["we_lo"], v))
        sweep("Data set-up: write then read, the drive starting at this step "
              "(ns: set-up before /WE rises)", "d_lo", range(0, base["we_hi"]), SEQ_WR,
              label=lambda v: "drive from %d" % v,
              nsf=lambda v: (base["we_hi"] - v) * STEP, extra=lambda v: {"war_lo": v})
        sweep("Write after read: each word written then read, 0x0000 and 0xFFFF in turn, the "
              "drive starting at this step after /OE rose at the cycle's start (bus errors: "
              "the FPGA's own sample 1 step after its drive reached the pad differed)",
              "war_lo", range(0, base["we_hi"]), SEQ_ALT, data=DATA_FLIP,
              label=lambda v: "drive from %d" % v,
              extra=lambda v: {"wchk": min(base["we_hi"], v + self.loop + 1)})
        sweep("Read after write: each word written then read, 0x0000 and 0xFFFF in turn, /OE "
              "falling at this step after the FPGA let go at the cycle's start",
              "oe_lo", range(0, n - 1), SEQ_ALT, data=DATA_FLIP,
              label=lambda v: "/OE low from %d" % v)

        self.say("| Setting | Pass window (ns) | Default (ns) | Margin below / above (ns) |")
        self.say("|---------|------------------|--------------|---------------------------|")
        for row in summary:
            self.say("| %s | %s | %s | %s |" % row)
        self.say()

        if True:
            self.cfg = dict(best)
            self.t.set(**best)
            self.say("Full check, all 2 MB, each setting at the middle of its window: "
                     "capture %d with %d taps, /WE low %d-%d, drive from %d (after a read %d)."
                     % (best["cap"], best["taps"], best["we_lo"], best["we_hi"], best["d_lo"],
                        best["war_lo"]))
            self.say()
            res = []
            for name, seq, data, addr in (("write then read, random", SEQ_WR, DATA_RANDOM, 0),
                                          ("each word written then read, 0000/FFFF", SEQ_ALT, DATA_FLIP, 0),
                                          ("walking ones on address and data", SEQ_WR, DATA_WALK, 1)):
                r = self.go(seq, data=data, words=ALL_WORDS if addr == 0 else 21, base=0, addr=addr)
                res.append(r["err"] == 0 and r["bus"] == 0)
                extra = ""
                if r["first"] >> 31:
                    extra = "; first at word 0x%05X: read 0x%04X, expected 0x%04X" % (
                        r["first"] & 0xFFFFF, r["got"], r["exp"])
                self.say("- %s: %d words read, %d wrong, %d bus errors%s" % (
                    name, r["reads"], r["err"], r["bus"], extra))
            clean = all(res)
            self.say()
            self.say("**%s**" % ("Clean." if clean else "Errors."))
            self.say()
        return summary, clean


# ---------------------------------------------------------------- commands

def cmd_check(t):
    s = Sweeper(t, ALL_WORDS, None)
    s.cfg = timing(16)
    for name, seq, data in (("write then read, random", SEQ_WR, DATA_RANDOM),
                            ("each word written then read, 0000/FFFF", SEQ_ALT, DATA_FLIP)):
        r = s.go(seq, data=data, base=0)
        print("%-40s %7d read %7d wrong %7d bus errors   D15..D0 %s" % (
            name, r["reads"], r["err"], r["bus"], bitmap(r["bits"])))


def cmd_scope(t):
    s = Sweeper(t, 16, None)
    s.cfg = timing(16)
    for name, seq, cyc in (("write (0x0000 after 0xFFFF)", SEQ_W, 4), ("read (0x0000)", SEQ_R, 4)):
        t.set(**s.cfg)
        t.set(seq=seq, data=DATA_FLIP, addr=0, scope_lo=cyc, scope_hi=0, repeat=1)
        t.region(0x10000, 16)
        t.run(64)
        kind, j, smp = t.scope()
        print("%s, cycle %d: step 0 at sample %d. One row a step, D15..D0:" % (name, cyc, j))
        for k in range(48):
            print("  step %3d  %s" % (k - j, "".join(str((smp[k] >> b) & 1) for b in range(15, -1, -1))))


def cmd_sweep(t, a):
    s = Sweeper(t, a.words, a.out)
    s.say("# SRAM timing on the KS2")
    s.say()
    s.say("Measured with the SRAM tester (issue #90; `fpga/ks2/top_ks2_sramtest.v`, "
          "`tools/sramtest.py`) on %s. The KS2's SRAM is an IS61WV102416FBLL-8 (8 ns), "
          "so these are a best case: the KS3's 10 ns part is to be measured again." %
          datetime.date.today().isoformat())
    s.say()
    s.say("Each pin changes in 1.25 ns steps (OSERDESE2 at 800 Mb/s); DQ is sampled every "
          "1.25 ns (ISERDESE2), 78 ps finer with the IDELAY taps. Step 0 is where a cycle's "
          "address leaves the FPGA; a capture at step c samples DQ at the moment step c leaves, "
          "as sram_ctl's input flip-flops do. Each sweep moves one setting, the others at the "
          "cycle's defaults, over %d words of random data a row." % a.words)
    s.say()
    results = []
    summary, clean = s.cycle(28, title="## Reference: 35 ns (28 steps)",
                             note="About the retro-spectrum build's 35.7 ns cycle, which has run "
                                  "for days without errors on the same pads: if this fails, "
                                  "suspect the rig, not the timing.")
    results.append((28, summary, clean))
    for n in a.cycles:
        summary, clean = s.cycle(n)
        results.append((n, summary, clean))

    s.say("## Summary")
    s.say()
    s.say("Margins at each cycle's defaults, below / above, in ns (\"fails\": no window; "
          "\"default fails\": a window, but not round the default):")
    s.say()
    s.say("| Cycle | " + " | ".join(r[0] for r in results[0][1]) + " | Full check |")
    s.say("|-------|" + "|".join("---" for _ in results[0][1]) + "|------------|")
    for n, summary, clean in results:
        s.say("| %.2f ns | %s | %s |" % (n * STEP, " | ".join(r[3] for r in summary),
                                         "clean" if clean else "errors"))
    s.say()
    s.say("Read capture windows (ns after the address leaves): " + "; ".join(
        "%.2f ns cycle %s" % (n * STEP, summary[0][1]) for n, summary, _ in results) + ".")
    s.say()
    good = [n for n, _, clean in results if clean]
    if good:
        s.say("The shortest cycle with a clean window: **%.2f ns** (%d steps)." % (
            min(good) * STEP, min(good)))
    else:
        s.say("No cycle length passed its full check.")
    s.say()
    if a.out:
        os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
        with open(a.out, "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(s.lines) + "\n")
        print("\nWritten: %s" % a.out)


def main():
    ap = argparse.ArgumentParser(description="The KS2's SRAM timing tester (issue #90).")
    ap.add_argument("command", nargs="?", default="sweep", choices=["sweep", "check", "scope"])
    ap.add_argument("--port", default="COM3", help="the FT232H's serial port (default COM3)")
    ap.add_argument("--words", type=int, default=65536, help="words per sweep run (default 65536)")
    ap.add_argument("--cycles", default="16,12,10,8",
                    help="cycle lengths to sweep, in 1.25 ns steps (default 16,12,10,8)")
    ap.add_argument("--out", default=os.path.join(ROOT, "docs", "notes", "sram-ks2.md"),
                    help="the results file (default docs/notes/sram-ks2.md)")
    a = ap.parse_args()
    a.cycles = [int(x) for x in a.cycles.split(",")]
    for n in a.cycles:
        if not 8 <= n <= 32:
            ap.error("cycle lengths are 8 to 32 steps")
    if not 1 <= a.words <= ALL_WORDS - 0x10000:
        ap.error("--words is 1 to %d" % (ALL_WORDS - 0x10000))
    t = Tester(a.port)
    {"sweep": lambda: cmd_sweep(t, a), "check": lambda: cmd_check(t),
     "scope": lambda: cmd_scope(t)}[a.command]()


if __name__ == "__main__":
    main()
