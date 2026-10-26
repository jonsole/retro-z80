#!/usr/bin/env python3
"""A whole debug session over the simulated USB link (ticket #29).

    session.py BUILD          the session against the simulation, then the model, compared
    session.py BUILD sim      the simulation only
    session.py BUILD model    the stub model only

With RZ80_TOOLS=DIR in the environment the bridge and the model are taken
from DIR in place of this repo's tools/ (to try another version of them).

The real bridge drives it: tools/rz80bridge's Session, unchanged, on a
SimLink (simlink.py) to the boot ROM's debug stub in tb_link.v, as on the
board. It launches link/linkprog.asm (UPLOAD, the upload with ACTION 0,
HELLO), reads the target description, registers, memory and the MMU
windows, sets a breakpoint in RAM and one in ROM, continues, steps, stops
on a read watchpoint, writes memory and a register, runs the monitor's
commands over CONSOLE, pauses a running program, detaches, attaches to
the stopped program and to a running one, and detaches again.

Then it runs the same session against the bridge's stub model
(tools/rz80bridge/model.py) and compares what both gave, step by step.
Known differences between the boot ROM and the model are listed in KNOWN
(each one is reported); any other difference fails the test.
"""

import os
import queue
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.environ.get("RZ80_TOOLS") or os.path.join(ROOT, "tools"))
sys.path.insert(0, HERE)

import rlink  # noqa: E402
from rz80bridge import protocol as P  # noqa: E402
from rz80bridge.session import Session  # noqa: E402
from simlink import SimLink, start_sim  # noqa: E402

WAIT = 120          # seconds for a stop: the simulation runs about 30 times slower than the board

# Where the ROM and the model may differ, and why: a field of a step's
# result (a register), or a whole step, -> the reason. Each is reported on
# every run; the model is to change (debug.md and spec 16 are as the ROM).
ALT0 = "spec 16, section 6: the alternate registers are 0 at entry; the model starts them at FFFF"
KNOWN = {
    "AF'": ALT0, "BC'": ALT0, "DE'": ALT0, "HL'": ALT0,
    "I": "spec 16, section 6: I = 1F at entry (the ROM's IM 2 table); the model has 0",
    "IM": "debug.md, section 5.2: IM is FF once the program has run; the model on main still gives 2 (8e732c0 has FF)",
    "console D": "the model's D has its own layout; the ROM's is the shared spec's (the characters column padded)",
}


class Run:
    def __init__(self, session, log):
        self.s = session
        self.log = log
        self.events = queue.Queue()
        self.s.add_listener(lambda kind, data: self.events.put((kind, data)))
        self.out = []

    def rec(self, name, value):
        self.out.append((name, value))
        self.log("  %-22s %s" % (name, fmt(value)))

    def drain(self):
        while not self.events.empty():
            self.events.get_nowait()

    def stop_event(self):
        deadline = time.monotonic() + WAIT
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                raise AssertionError("no stop came")
            kind, data = self.events.get(timeout=left)
            if kind in ("stopped", "exited"):
                return data["stop"]

    def regs(self):
        r = dict(self.s.registers())
        r.pop("R")                      # counts as the monitor runs: only roughly kept
        return r


def stopinfo(st):
    d = {"reason": P.REASON_NAMES[st.reason] if st.reason < len(P.REASON_NAMES) else st.reason,
         "n": st.n, "pc": "%04X" % st.pc}
    if st.reason == P.R_WATCHPOINT:
        d.update(aaddr="%04X" % st.aaddr, adata="%02X" % st.adata, akind=st.akind)
    return d


def fmt(v):
    if isinstance(v, (bytes, bytearray)):
        return v.hex(" ").upper()
    if isinstance(v, list) and v and all(isinstance(x, int) for x in v):
        return " ".join("%02X" % x for x in v)
    if isinstance(v, dict):
        return ", ".join("%s=%s" % (k, ("%04X" % x) if isinstance(x, int) else x) for k, x in v.items())
    return repr(v)


def script(r, image, sym):
    s = r.s
    r.log("launch")
    st = s.launch(image, owner="test")
    r.rec("launch", stopinfo(st))
    t = s.target
    r.rec("target", (t.version, t.machine, t.addrbits, t.physbits, t.nbp, t.nwp, t.wpkinds, t.nwin,
                     t.steps, t.maxdata, t.blocklen,
                     [(g.name, g.offset, g.size, g.flags) for g in t.registers]))
    r.rec("regs at entry", r.regs())
    r.rec("program", s.read_memory(0x8000, len(image.data)))
    r.rec("mmu", s.mmu())

    r.log("a breakpoint in RAM, continue")
    s.set_breakpoints("test", "b", [(sym["bkpt"], None)])
    r.drain()
    s.cont("test")
    r.rec("breakpoint", stopinfo(r.stop_event()))
    r.rec("regs at breakpoint", r.regs())

    r.log("step")
    r.rec("step", stopinfo(s.step("into", owner="test")))
    r.rec("C100 after the step", s.read_memory(0xC100, 1))

    r.log("a breakpoint in ROM (RST 08h), continue")
    s.set_breakpoints("test", "rom", [(0x0008, None)])
    r.drain()
    s.cont("test")
    r.rec("ROM breakpoint", stopinfo(r.stop_event()))
    regs = r.regs()
    r.rec("PC, SP, A in ROM", {"PC": regs["PC"], "SP": regs["SP"], "A": regs["AF"] >> 8})
    r.rec("return address", s.read_memory(regs["SP"], 2))
    s.set_breakpoints("test", "rom", [])
    s.set_breakpoints("test", "b", [])

    r.log("a read watchpoint, and a breakpoint whose page does not match, continue")
    s.set_watchpoints("test", "w", [(P.WP_READ, 0xC100, 0xFFFF)])
    s.set_breakpoints("test", "page", [(sym["put"], 5)])     # window 4 holds page 4
    r.drain()
    s.cont("test")
    r.rec("watchpoint", stopinfo(r.stop_event()))
    s.set_watchpoints("test", "w", [])
    s.set_breakpoints("test", "page", [])
    r.rec("query", stopinfo(s.client.query()[1]))

    r.log("refusals, a damaged frame, a repeated SEQ")
    c = s.client
    refused = {}
    for name, fn in (("SETBP 4", lambda: c.set_bp(4, 0x8000)),
                     ("SETWP no direction", lambda: c.set_wp(0, 0, 0xC100, 0xFFFF)),
                     ("SETWP kind 9", lambda: c.set_wp(0, 9, 0xC100, 0xFFFF)),
                     ("CLEARWP 2", lambda: c.clear_wp(2)),
                     ("WRITEREGS 27, 2 bytes", lambda: c.write_regs(27, bytes(2))),
                     ("READMEM P200000", lambda: c.read_mem(0x200000, 4, space=1)),
                     ("READMEM FFFF, 2", lambda: c.read_mem(0xFFFF, 2)),
                     ("READMEM 0 bytes", lambda: c.read_mem(0x8000, 0)),
                     ("HELLO version 2", lambda: c.command(P.HELLO, bytes([2]))),
                     ("TYPE 1F", lambda: c.command(0x1F)),
                     ("CONSOLE 81 bytes", lambda: c.console("R" + " " * 80))):
        try:
            fn()
            refused[name] = "done"
        except P.Refused as e:
            refused[name] = e.code
    r.rec("refusals", refused)
    orig, sent = c.send, []

    def damage_first(frame):
        if not sent:
            frame = frame[:-1] + bytes([frame[-1] ^ 0xFF])
        sent.append(frame)
        orig(frame)
    c.send = damage_first
    r.rec("damaged READREGS", {"bytes": len(c.read_regs()), "sent": len(sent)})
    c.send = orig
    frame = rlink.transport_frame(P.WRITEMEM, 50, P.CH_DEBUG, bytes([0, 0, 0, 0, 0xC3, 0x00, 0x07]))
    c.seq = 49
    c.command(P.WRITEMEM, bytes([0, 0, 0, 0, 0xC3, 0x00, 0x06]))     # SEQ 50: C300 = 06
    s.link.write(frame)                                               # SEQ 50 again: not done
    time.sleep(1.0)
    r.rec("repeated WRITEMEM", s.read_memory(0xC300, 1))

    r.log("memory, registers, the monitor's commands")
    s.write_memory(0xC200, b"\x11\x22\x33")
    r.rec("C200 written", s.read_memory(0xC1FF, 5))
    s.set_register("HL", 0xBEEF)
    r.rec("HL written", r.regs()["HL"])
    r.rec("console D", s.monitor("D C200 4"))
    for line in ("G", "N", "T 9000 10"):
        try:
            s.monitor(line)
            r.rec("console " + line, "done")
        except Exception as e:  # noqa: BLE001 (BridgeError: refused, 7)
            r.rec("console " + line, "refused" if "runs code" in str(e) else str(e))

    r.log("continue, then pause")
    r.drain()
    s.cont("test")
    time.sleep(1.0)
    s.pause("test")
    st = r.stop_event()
    r.rec("pause", {"reason": P.REASON_NAMES[st.reason], "in spin": st.pc in (sym["spin"], sym["spin"] + 1)})

    r.log("detach, attach to the stopped program")
    s.detach(owner="test")
    time.sleep(0.5)
    st = s.attach(owner="test")
    r.rec("attach (stopped)", {"reason": P.REASON_NAMES[st.reason], "in spin": st.pc in (sym["spin"], sym["spin"] + 1)})

    r.log("detach running, attach to the running program")
    s.detach(run=True, owner="test")
    time.sleep(1.0)
    st = s.attach(owner="test")
    r.rec("attach (running)", {"reason": P.REASON_NAMES[st.reason], "in spin": st.pc in (sym["spin"], sym["spin"] + 1)})
    r.rec("regs at attach", {k: v for k, v in r.regs().items() if k in ("AF", "BC", "HL", "SP", "IX", "IY")})
    s.detach(owner="test")
    time.sleep(0.5)
    r.rec("console after detach", "> " in "".join(s.console.read(None, 50)[0]) + s.console.read()[2])


def load(build):
    with open(os.path.join(build, "linkprog.bin"), "rb") as f:
        data = f.read()
    sym = {}
    with open(os.path.join(build, "linkprog.sym")) as f:
        for line in f:
            name, _, value = line.partition(": EQU ")
            if value:
                sym[name.strip()] = int(value, 16)
    return rlink.Image(data, b"Z80 ", 0x8000), sym


def run_sim(build, image, sym, log):
    sim = start_sim(build)
    link = SimLink(sim.port)
    s = Session(link, "sim", log=lambda m: None)
    t0 = time.monotonic()
    try:
        r = Run(s, log)
        script(r, image, sym)
        return r.out
    finally:
        s.close()
        link.close()
        lines = sim.wait()
        log("  (%.0f s; %s)" % (time.monotonic() - t0, lines[-1] if lines else "no output"))
        with open(os.path.join(build, "link.console"), "w", encoding="latin-1") as f:
            f.write("\n".join(s.console.read(0, 2000)[0]) + "\n" + s.console.read()[2])


def run_model(image, sym, log):
    from rz80bridge.model import ModelLink, StubModel
    model = StubModel()
    model.start()
    s = Session(ModelLink(model), "model")
    try:
        r = Run(s, log)
        script(r, image, sym)
        return r.out
    finally:
        s.close()
        model.shutdown()


def main():
    build = sys.argv[1]
    which = sys.argv[2] if len(sys.argv) > 2 else "both"
    image, sym = load(build)
    results = {}
    if which in ("both", "sim"):
        print("The session against the simulation (the boot ROM's stub):", flush=True)
        results["sim"] = run_sim(build, image, sym, lambda m: print(m, flush=True))
    if which in ("both", "model"):
        print("The session against the stub model:", flush=True)
        results["model"] = run_model(image, sym, lambda m: print(m, flush=True))
    if which != "both":
        print("TEST PASSED")
        return 0
    errors = 0
    for (name, a), (_, b) in zip(results["sim"], results["model"]):
        if a == b:
            continue
        if isinstance(a, dict) and isinstance(b, dict):
            fields = sorted(k for k in set(a) | set(b) if a.get(k) != b.get(k))
        else:
            fields = [None]
        for k in fields:
            what = "%s%s" % (name, "" if k is None else "." + k)
            va = a if k is None else a.get(k)
            vb = b if k is None else b.get(k)
            why = KNOWN.get(k) if k is not None else KNOWN.get(name)
            print("%s: %s: ROM %s, model %s" % ("known" if why else "DIFFERENT", what, fmt(va), fmt(vb))
                  + (" (%s)" % why if why else ""))
            if not why:
                errors += 1
    print("TEST PASSED" if errors == 0 else "TEST FAILED: %d differences" % errors)
    return 0 if errors == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
