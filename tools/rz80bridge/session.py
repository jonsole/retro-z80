"""The bridge's shared session (debug.md, sections 3.5 and 3.6).

One Session owns the link to one board. A reader thread hands what the
board sends to the console, to an upload under way, or to the debug
channel. VS Code (DAP) and MCP drive the same Session: they share its
stops, its breakpoint pool and its console.
"""

import os
import queue
import re
import struct
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import rlink  # noqa: E402
from rz80bridge import protocol as P  # noqa: E402
from rz80bridge import disasm  # noqa: E402
from rz80bridge import ps2keys  # noqa: E402

CONSOLE_LINES = 2000
STEP_WAIT = 2.0          # a STEP's STOP comes at once; after this, QUERY
MAX_STEPS = 20000        # a step over or out done with single steps gives up here

CALL_OPS = {0xCD} | {0xC4 + 8 * i for i in range(8)}
RST_OPS = {0xC7 + 8 * i for i in range(8)}
REPEAT_ED = {0xB0, 0xB1, 0xB2, 0xB3, 0xB8, 0xB9, 0xBA, 0xBB}

HALVES = {  # 8-bit names -> (pair, high byte?)
    "A": ("AF", True), "F": ("AF", False), "B": ("BC", True), "C": ("BC", False),
    "D": ("DE", True), "E": ("DE", False), "H": ("HL", True), "L": ("HL", False),
    "IXH": ("IX", True), "IXL": ("IX", False), "IYH": ("IY", True), "IYL": ("IY", False),
    "A'": ("AF'", True), "F'": ("AF'", False), "B'": ("BC'", True), "C'": ("BC'", False),
    "D'": ("DE'", True), "E'": ("DE'", False), "H'": ("HL'", True), "L'": ("HL'", False),
}
FLAG_BITS = [("S", 7), ("Z", 6), ("5", 5), ("H", 4), ("3", 3), ("P/V", 2), ("N", 1), ("C", 0)]


class BridgeError(Exception):
    """A request the session cannot do; the message is for the user."""


class PoolFull(BridgeError):
    pass


class Slot:
    """A hardware breakpoint or watchpoint, and who asked for it."""

    def __init__(self, n, key, owners):
        self.n = n
        self.key = key            # bp: (addr, page); wp: (kind, addr, mask)
        self.owners = owners      # {(owner, tag)}

    def owner_names(self):
        return sorted({o for o, _ in self.owners})


class ByteFeed:
    """Bytes the reader hands to an upload: write() goes to the link, read_some() takes them."""

    def __init__(self, link):
        self.link = link
        self.q = queue.Queue()

    def write(self, data):
        self.link.write(data)

    def read_some(self, timeout):
        try:
            data = self.q.get(timeout=max(0.0, timeout))
        except queue.Empty:
            return b""
        parts = [data]
        while not self.q.empty():
            parts.append(self.q.get_nowait())
        return b"".join(parts)


class Console:
    """The monitor console's output: the last lines, and live listeners."""

    def __init__(self):
        self.lines = []          # finished lines
        self.first = 0           # number of the first line kept
        self.partial = ""
        self.cr = False
        self.listeners = []
        self.lock = threading.Lock()

    def add(self, text):
        if not text:
            return
        with self.lock:
            if self.cr and text.startswith("\n"):
                text_n = text[1:]          # the LF of a CR LF split across two reads
            else:
                text_n = text
            self.cr = text.endswith("\r")
            buf = self.partial + text_n.replace("\r\n", "\n").replace("\r", "\n")
            parts = buf.split("\n")
            self.partial = parts.pop()
            self.lines.extend(parts)
            if len(self.lines) > CONSOLE_LINES:
                drop = len(self.lines) - CONSOLE_LINES
                del self.lines[:drop]
                self.first += drop
            # under the lock, so a listener joining with a backlog misses nothing;
            # listeners must only queue the text, never block
            for fn in self.listeners:
                try:
                    fn(text)
                except Exception:
                    pass

    def join(self, fn, backlog=50):
        """Adds a listener and returns the backlog text, with nothing lost or doubled between."""
        with self.lock:
            lines = self.lines[-backlog:] if backlog else []
            self.listeners.append(fn)
            return "\r\n".join(lines) + ("\r\n" if lines else "") + self.partial

    def leave(self, fn):
        with self.lock:
            if fn in self.listeners:
                self.listeners.remove(fn)

    def read(self, since=None, limit=200):
        """Lines from number `since` on: (lines, next number, partial line)."""
        with self.lock:
            end = self.first + len(self.lines)
            if since is None:
                since = max(self.first, end - limit)
            since = max(since, self.first)
            lines = self.lines[since - self.first:since - self.first + limit]
            return lines, since + len(lines), self.partial


class Session:
    def __init__(self, link, serial_name="", log=None):
        self.link = link
        self.serial_name = serial_name
        self.log = log or (lambda s: None)
        self.console = Console()
        self.mode = "console"           # console, upload, debug
        self.held_keys = set()          # KeyboardEvent.codes sent down and not yet up
        self.feed = None
        self.parser = rlink.FrameParser(syncs=(rlink.SYNC_MACHINE,))
        self.client = P.DebugClient(self.link.write, self._on_stop)
        self.cond = threading.Condition()
        self.op_lock = threading.RLock()
        self.busy = 0
        self.attached = False
        self.running = False
        self.ended = False
        self.target = None
        self.last_stop = None
        self.stop_count = 0
        self.run_owner = None
        self.stop_owner = None
        self.pause_requested = False
        self.bps = []
        self.wps = []
        self.symbols = None
        self.program = None
        self.program_path = None
        self.listeners = []
        self.events = queue.Queue()
        self.closed = threading.Event()
        self._reader = threading.Thread(target=self._read_loop, daemon=True, name="link-reader")
        self._events = threading.Thread(target=self._event_loop, daemon=True, name="events")
        self._reader.start()
        self._events.start()

    # ------------------------------------------------------------ events
    def add_listener(self, fn):
        self.listeners.append(fn)

    def remove_listener(self, fn):
        if fn in self.listeners:
            self.listeners.remove(fn)

    def _emit(self, kind, **data):
        self.events.put((kind, data))

    def _event_loop(self):
        while not self.closed.is_set():
            try:
                kind, data = self.events.get(timeout=0.2)
            except queue.Empty:
                continue
            for fn in list(self.listeners):
                try:
                    fn(kind, data)
                except Exception as e:  # a broken listener must not stop the others
                    self.log("listener: %s" % e)

    def close(self):
        self.closed.set()
        try:
            self.link.close()
        except Exception:
            pass

    # ------------------------------------------------------------ the reader
    def _read_loop(self):
        while not self.closed.is_set():
            try:
                data = self.link.read_some(0.1)
            except Exception as e:
                self.log("link: %s" % e)
                time.sleep(0.5)
                continue
            mode = self.mode
            if mode == "upload" and self.feed is not None:
                if data:
                    self.feed.q.put(data)
                    # the loader's text for the console; its binary replies left out,
                    # even when one is split across reads
                    text = b"".join(i for i in self.upload_text.feed(data) if isinstance(i, bytes))
                    self.console.add(text.decode("latin-1"))
                continue
            if mode == "debug":
                items = self.parser.feed(data) if data else self.parser.poll()
                for item in items:
                    if isinstance(item, rlink.Frame):
                        self.client.frame(item)
                        if item.error and self.attached and self.running:
                            threading.Thread(target=self._recover, daemon=True).start()
                    elif item:
                        text = item.decode("latin-1")
                        if self.attached:
                            self._emit("output", text=text)
                        self.console.add(text)
                continue
            if data:
                self.console.add(data.decode("latin-1"))

    def _recover(self):
        """A damaged frame while running may have been the STOP: ask (debug.md 4.6)."""
        time.sleep(0.1)
        if not self.running:
            return
        try:
            state, stop = self.client.query()
        except (P.LinkLost, P.Refused):
            return
        if state == 1 and stop is not None and self.running:
            self._on_stop(stop)

    # ------------------------------------------------------------ stops
    def _on_stop(self, stop):
        with self.cond:
            self.stop_count += 1
            self.last_stop = stop
            self.running = False
            if stop.reason == P.R_EXIT:
                self.ended = True
            busy = self.busy > 0
            self.cond.notify_all()
        if not busy:
            self._publish_stop(stop, self.run_owner)

    def _publish_stop(self, stop, owner, reason=None):
        self.stop_owner = owner
        if stop.reason == P.R_EXIT:
            self._emit("exited", stop=stop)
            return
        self._emit("stopped", stop=stop, owner=owner, reason=reason or stop.name, text=self.describe_stop(stop))

    def _wait_stop(self, count_before, timeout=None):
        """Waits for a stop after `count_before`. None on timeout."""
        deadline = None if timeout is None else time.monotonic() + timeout
        with self.cond:
            while self.stop_count == count_before:
                if self.closed.is_set():
                    return None
                left = None if deadline is None else deadline - time.monotonic()
                if left is not None and left <= 0:
                    return None
                self.cond.wait(0.2 if left is None else min(0.2, left))
            return self.last_stop

    class _Op:
        def __init__(self, s):
            self.s = s

        def __enter__(self):
            self.s.op_lock.acquire()
            with self.s.cond:
                self.s.busy += 1
            return self

        def __exit__(self, *exc):
            with self.s.cond:
                self.s.busy -= 1
            self.s.op_lock.release()

    def _op(self):
        return Session._Op(self)

    def describe_stop(self, stop):
        where = self.format_address(stop.pc)
        if stop.reason == P.R_WATCHPOINT:
            what = "write" if stop.akind & 1 else "read"
            space = "port" if stop.akind & 2 else ""
            return "Watchpoint %d at %s (%s %s%04X: %02X)" % (stop.n, where, what, space + " " if space else "",
                                                            stop.aaddr & 0xFFFF, stop.adata & 0xFF)
        if stop.reason == P.R_BREAKPOINT:
            return "Breakpoint %d at %s" % (stop.n, where)
        if stop.reason == P.R_EXIT:
            return "Program ended."
        return "%s at %s" % ({"entry": "Entry", "pause": "Paused", "button": "NMI button", "step": "Step",
                              "break": "Break", "trap": "Trap"}.get(stop.name, stop.name), where)

    # ------------------------------------------------------------ attaching
    def require_attached(self):
        if not self.attached:
            raise BridgeError("not attached: launch or attach first")

    def require_stopped(self):
        self.require_attached()
        if self.running:
            raise BridgeError("the program is running: pause it first")

    def _enter_debug(self):
        self.parser = rlink.FrameParser(syncs=(rlink.SYNC_MACHINE,))
        self.mode = "debug"

    def _hello(self, owner):
        count = self.stop_count
        with self.cond:
            self.busy += 1
        try:
            self.target = self.client.hello()
            self.attached = True
            self.ended = False
            stop = self._wait_stop(count, timeout=STEP_WAIT)
            if stop is None:
                state, stop = self.client.query()
                if stop is not None:
                    self.last_stop = stop
            self.running = False
            self.bps = [None] * self.target.nbp
            self.wps = [None] * self.target.nwp
        finally:
            with self.cond:
                self.busy -= 1
        self.run_owner = owner
        return self.last_stop

    def launch(self, image, owner="vscode", symbols=None):
        """Upload and attach, stopped at ENTRY (debug.md 4.1)."""
        with self._op():
            if self.attached:
                self._end_session()
            self.feed = ByteFeed(self.link)
            self.upload_text = rlink.FrameParser(syncs=(), replies=True)
            self.mode = "upload"
            try:
                rlink.upload(self.feed, image, action=0, reset=True, log=self.log)
            except (rlink.Refused, rlink.LinkError) as e:
                self.mode = "console"
                raise BridgeError("upload: %s" % e)
            finally:
                self.feed = None
            time.sleep(0.05)
            self._enter_debug()
            self.program = image
            self.program_path = getattr(image, "path", None)
            if symbols is not None:
                self.symbols = symbols
            stop = self._hello(owner)
        self._emit("attached", owner=owner)
        self._publish_stop(stop, owner)
        return stop

    def attach(self, owner="vscode"):
        """BREAK, then HELLO: the program stops where it was (debug.md 4.2)."""
        with self._op():
            if self.attached:
                return self.last_stop
            self._enter_debug()
            self.link.write(rlink.control(rlink.CTL_BREAK))
            time.sleep(0.3)        # the monitor's NMI line: dropped to the console
            try:
                stop = self._hello(owner)
            except P.LinkLost:
                self.mode = "console"
                raise BridgeError("the board did not answer HELLO (is the boot ROM's stub there?)")
        self._emit("attached", owner=owner)
        self._publish_stop(stop, owner)
        return stop

    def _end_session(self):
        self.attached = False
        self.running = False
        self.bps = []
        self.wps = []
        self.mode = "console"

    def detach(self, run=False, owner="vscode"):
        with self._op():
            if not self.attached:
                return
            if self.running:
                self._pause_quietly()
            try:
                if run and not self.ended:
                    self.client.cont(detach=True)
                else:
                    self.client.detach()
            except (P.LinkLost, P.Refused) as e:
                self.log("detach: %s" % e)
            self._end_session()
        self._emit("detached", owner=owner, running=run)

    def reset(self):
        with self._op():
            self.link.write(rlink.control(rlink.CTL_RESET))
            was = self.attached
            self._end_session()
        if was:
            self._emit("detached", owner=None, running=False, reset=True)

    def held_by(self, owner):
        """Does `owner` hold any breakpoint or watchpoint?"""
        return any(s and any(o == owner for o, _ in s.owners) for s in self.bps + self.wps)

    # ------------------------------------------------------------ running
    def cont(self, owner="vscode"):
        with self._op():
            self.require_stopped()
            if self.ended:
                raise BridgeError("the program has ended")
            self.run_owner = owner
            count = self.stop_count
            self.running = True
            self._emit("continued", owner=owner)
            self.client.cont()
        self._late_stop(count)

    def _late_stop(self, count):
        """A stop that came while an op still held the session (before CONTINUE's reply was read)."""
        with self.cond:
            late = self.stop_count != count and not self.running
            stop = self.last_stop
        if late:
            self._publish_stop(stop, self.run_owner)

    def pause(self, owner="vscode"):
        self.require_attached()
        self.pause_requested = True
        if self.running:
            self.run_owner = owner
            self.link.write(rlink.control(rlink.CTL_BREAK))

    def _pause_quietly(self):
        """Stops a running program for a moment. Returns the stop, or None if it was a plain PAUSE."""
        count = self.stop_count
        self.link.write(rlink.control(rlink.CTL_BREAK))
        stop = self._wait_stop(count, timeout=STEP_WAIT)
        if stop is None:
            state, stop = self.client.query()
            self.running = False
            self.last_stop = stop
        return None if stop is None or stop.reason == P.R_PAUSE else stop

    def _while_stopped(self, fn):
        """Runs fn with the program stopped: a running one is paused and goes on after."""
        count = None
        with self._op():
            if not self.running:
                return fn()
            other = self._pause_quietly()
            try:
                return fn()
            finally:
                if other is None:
                    count = self.stop_count
                    self.running = True
                    self.client.cont()
                else:
                    self._publish_stop(other, self.run_owner)
                if count is not None:
                    threading.Thread(target=self._late_stop_soon, args=(count,), daemon=True).start()

    def _late_stop_soon(self, count):
        time.sleep(0.01)
        with self.op_lock:
            pass
        self._late_stop(count)

    def _step_raw(self, into=False):
        count = self.stop_count
        self.running = True
        self.client.step(into)
        stop = self._wait_stop(count, timeout=STEP_WAIT)
        if stop is None:
            state, stop = self.client.query()
            self.running = False
            self.last_stop = stop
        return stop

    def _continue_to(self, count_before=None):
        count = self.stop_count if count_before is None else count_before
        self.running = True
        self.client.cont()
        return self._wait_stop(count)

    def step(self, kind="into", owner="vscode", granularity="instruction", count=1):
        """kind: into, over or out. Publishes one stop at the end."""
        with self._op():
            self.require_stopped()
            if self.ended:
                raise BridgeError("the program has ended")
            self.run_owner = owner
            self.pause_requested = False
            self._emit("continued", owner=owner, step=True)
            stop = self.last_stop
            for _ in range(count):
                stop, done = self._step_once(kind, granularity)
                if not done:
                    break
            if stop is None:
                raise BridgeError("no stop came back from the board")
            done_reason = "step" if done else None
        self._publish_stop(stop, owner, reason=done_reason)
        return stop

    def _line_of(self, pc):
        if not self.symbols:
            return None
        return self.symbols.location(pc)

    def _step_once(self, kind, granularity):
        """One step of `kind`. Returns (stop, finished as a step)."""
        regs = self._regs_now()
        pc, sp = regs["PC"], regs["SP"]
        if kind == "out":
            return self._step_out(pc, sp)
        start_line = self._line_of(pc) if granularity != "instruction" else None
        for _ in range(MAX_STEPS):
            if kind == "over":
                stop, done = self._step_over_one()
            else:
                stop = self._step_raw()
                done = stop is not None and stop.reason == P.R_STEP
            if not done or start_line is None:
                return stop, done
            line = self._line_of(stop.pc)
            if line != start_line:
                return stop, True
            if self.pause_requested:
                return stop, True
        return stop, True

    def _instruction_at(self, pc):
        data = self.client.read_mem(pc, 4)
        inst = disasm.disassemble_one(lambda a: data[(a - pc) & 0xFFFF] if ((a - pc) & 0xFFFF) < 4 else 0, pc)
        return data, inst

    def _step_over_one(self):
        regs = self._regs_now()
        pc, sp = regs["PC"], regs["SP"]
        data, inst = self._instruction_at(pc)
        op = data[0]
        length = inst.length
        if op == 0xEF:
            length = 2          # RST 28h takes its function number
        over = op in CALL_OPS or op in RST_OPS or (op == 0xED and data[1] in REPEAT_ED)
        if not over or op in (0xF7, 0xFF):
            stop = self._step_raw()
            return stop, stop is not None and stop.reason == P.R_STEP
        nxt = (pc + length) & 0xFFFF
        return self._run_until(nxt, lambda s: s >= sp)

    def _step_out(self, pc, sp):
        frames = self.call_stack(limit=2)
        if len(frames) < 2:
            # no frame known: one instruction instead
            stop = self._step_raw()
            return stop, stop is not None and stop.reason == P.R_STEP
        ret = frames[1]["pc"]
        slot = frames[1]["slot"]
        return self._run_until(ret, lambda s: s > slot)

    def _run_until(self, addr, sp_ok):
        """Runs until PC = addr with sp_ok(SP); a spare breakpoint if there is one, else single steps."""
        n = self._spare()
        if n is not None:
            self.client.set_bp(n, addr)
            try:
                while True:
                    stop = self._continue_to()
                    if stop is None:
                        return None, False
                    ours = stop.reason == P.R_BREAKPOINT and stop.n == n
                    if not ours:
                        # another breakpoint at the same address counts as ours too
                        if stop.reason == P.R_BREAKPOINT and stop.pc == addr and sp_ok(self._regs_now()["SP"]):
                            return stop, True
                        return stop, False
                    if sp_ok(self._regs_now()["SP"]):
                        return stop, True
                    if self.pause_requested:
                        return stop, True
            finally:
                try:
                    self.client.clear_bp(n)
                except (P.LinkLost, P.Refused):
                    pass
        for _ in range(MAX_STEPS):
            stop = self._step_raw()
            if stop is None or stop.reason != P.R_STEP:
                return stop, False
            if stop.pc == addr and sp_ok(self._regs_now()["SP"]):
                return stop, True
            if self.pause_requested:
                return stop, True
        return stop, True

    def _spare(self):
        for i, s in enumerate(self.bps):
            if s is None:
                return i
        return None

    # ------------------------------------------------------------ registers
    def _regs_now(self):
        return self.target.decode(self.client.read_regs())

    def registers(self):
        with self._op():
            self.require_stopped()
            return self._regs_now()

    def set_register(self, name, value):
        name = name.upper().strip()
        with self._op():
            self.require_stopped()
            regs = self._regs_now()
            if name in HALVES:
                pair, high = HALVES[name]
                old = regs[pair]
                value = ((value & 0xFF) << 8) | (old & 0xFF) if high else (old & 0xFF00) | (value & 0xFF)
                name = pair
            r = self.target.reg(name)
            if r is None:
                raise BridgeError("no register %s" % name)
            if r.flags & P.F_RO:
                raise BridgeError("%s is read only" % name)
            value &= (1 << (8 * r.size)) - 1
            self.client.write_regs(r.offset, value.to_bytes(r.size, "big"))
            return value

    def flags(self, f):
        return {name: bool(f >> bit & 1) for name, bit in FLAG_BITS}

    # ------------------------------------------------------------ memory
    def read_memory(self, addr, count, space=0, side_effects=False):
        """Reads count bytes; pieces the board refuses come back as None bytes."""
        with self._op():
            self.require_stopped()
            out = []
            maxd = self.target.maxdata if self.target else 2048
            limit = 0x10000 if space == 0 else (1 << self.target.physbits)
            a = addr
            while count > 0:
                if a >= limit:
                    out.extend([None] * count)
                    break
                n = min(count, maxd, limit - a)
                try:
                    out.extend(self.client.read_mem(a, n, space, side_effects))
                except P.Refused:
                    out.extend([None] * n)
                a += n
                count -= n
            return out

    def write_memory(self, addr, data, space=0):
        with self._op():
            self.require_stopped()
            maxd = self.target.maxdata
            for i in range(0, len(data), maxd):
                try:
                    self.client.write_mem(addr + i, data[i:i + maxd], space)
                except P.Refused as e:
                    raise BridgeError(str(e))

    def mmu(self):
        with self._op():
            self.require_stopped()
            return self.client.read_mmu()

    def monitor(self, line):
        with self._op():
            self.require_stopped()
            try:
                return self.client.console(line)
            except P.Refused as e:
                raise BridgeError(str(e))

    def disassemble(self, addr, count):
        """count instructions from addr: [(addr, bytes, text)]."""
        span = count * 4 + 4
        data = self.read_memory(addr, min(span, 0x10000 - addr) if addr < 0x10000 else 0)
        base = addr

        def rd(a):
            i = (a - base) & 0xFFFF
            if i < len(data) and data[i] is not None:
                return data[i]
            return 0xFF
        out = []
        a = addr
        for _ in range(count):
            inst = disasm.disassemble_one(rd, a)
            text = inst.text
            if self.symbols:
                text = disasm.annotate_symbols(text, lambda v: self.symbols.symbol_at(v, 0x100))
            out.append((a, bytes(inst.raw), text))
            a = (a + inst.length) & 0xFFFF
        return out

    # ------------------------------------------------------------ the call stack
    def call_stack(self, limit=16, depth=64):
        """Frame 0 at PC, then each word on the stack that is a return address."""
        with self._op():
            self.require_stopped()
            regs = self._regs_now()
            pc, sp = regs["PC"], regs["SP"]
            frames = [{"pc": pc, "slot": None}]
            n = min(depth * 2, 0x10000 - sp)
            if n <= 0:
                return frames
            raw = self.read_memory(sp, n)
            for k in range(0, n - 1, 2):
                if len(frames) >= limit:
                    break
                lo, hi = raw[k], raw[k + 1]
                if lo is None or hi is None:
                    continue
                w = lo | (hi << 8)
                if w < 4:
                    continue
                if self.symbols and self.symbols.location(w) is None:
                    continue
                code = self.read_memory(w - 3, 3)
                if None in code:
                    continue
                if code[0] in CALL_OPS or (code[2] in RST_OPS and code[2] != 0xFF) or code[1] == 0xEF:
                    frames.append({"pc": w, "slot": sp + k})
            return frames

    # ------------------------------------------------------------ breakpoints
    def _apply_bp(self, n):
        s = self.bps[n]
        if s is None:
            self.client.clear_bp(n)
        else:
            addr, page = s.key
            self.client.set_bp(n, addr, page)

    def _apply_wp(self, n):
        s = self.wps[n]
        if s is None:
            self.client.clear_wp(n)
        else:
            kind, addr, mask = s.key
            self.client.set_wp(n, kind, addr, mask)

    def set_breakpoints(self, owner, tag, wanted):
        """Replaces owner's breakpoints with tag by `wanted` [(addr, page)].
        Returns [(n or None, message or None)] for each, in order."""
        self.require_attached()

        def work():
            changed = set()
            want = [(a & 0xFFFF, p) for a, p in wanted]
            for s in list(self.bps):
                if s and (owner, tag) in s.owners and s.key not in want:
                    s.owners.discard((owner, tag))
                    if not s.owners:
                        self.bps[s.n] = None
                        changed.add(s.n)
            results = []
            for key in want:
                slot = next((s for s in self.bps if s and s.key == key), None)
                if slot:
                    slot.owners.add((owner, tag))
                    results.append((slot.n, None))
                    continue
                n = self._spare()
                if n is None:
                    holders = sorted({o for s in self.bps if s for o in s.owner_names()})
                    results.append((None, "only %d hardware breakpoints (held by %s)" % (len(self.bps), ", ".join(holders))))
                    continue
                self.bps[n] = Slot(n, key, {(owner, tag)})
                changed.add(n)
                results.append((n, None))
            for n in sorted(changed):
                self._apply_bp(n)
            return results
        results = self._while_stopped(work)
        self._emit("breakpoints", owner=owner)
        return results

    def add_breakpoint(self, owner, addr, page=None, tag=None):
        tag = tag or "%04X" % addr
        n, msg = self.set_breakpoints(owner, tag, [(addr, page)])[0]
        if n is None:
            raise PoolFull(msg)
        return n

    def remove_breakpoint(self, owner, addr, page=None):
        found = False
        for s in list(self.bps):
            if s and s.key[0] == (addr & 0xFFFF) and (page is None or s.key[1] == page):
                for o, t in list(s.owners):
                    if o == owner:
                        found = True
                        self.set_breakpoints(owner, t, [])
        return found

    def list_breakpoints(self):
        out = []
        for s in self.bps:
            if s:
                addr, page = s.key
                out.append({"id": s.n, "address": addr, "page": page, "symbol": self.symbol_text(addr),
                            "owners": s.owner_names()})
        return out

    def set_watchpoints(self, owner, tag, wanted):
        """Like set_breakpoints, for [(kind, addr, mask)]."""
        self.require_attached()

        def work():
            changed = set()
            # the address as the hardware compares it: under the mask
            want = [(k, a & m & 0xFFFF, m & 0xFFFF) for k, a, m in wanted]
            for s in list(self.wps):
                if s and (owner, tag) in s.owners and s.key not in want:
                    s.owners.discard((owner, tag))
                    if not s.owners:
                        self.wps[s.n] = None
                        changed.add(s.n)
            results = []
            for key in want:
                if self.target and key[0] & ~self.target.wpkinds & 0x07:
                    results.append((None, "the hardware has no such watchpoint kind"))
                    continue
                slot = next((s for s in self.wps if s and s.key == key), None)
                if slot:
                    slot.owners.add((owner, tag))
                    results.append((slot.n, None))
                    continue
                n = next((i for i, s in enumerate(self.wps) if s is None), None)
                if n is None:
                    holders = sorted({o for s in self.wps if s for o in s.owner_names()})
                    results.append((None, "only %d hardware watchpoints (held by %s)" % (len(self.wps), ", ".join(holders))))
                    continue
                self.wps[n] = Slot(n, key, {(owner, tag)})
                changed.add(n)
                results.append((n, None))
            for n in sorted(changed):
                self._apply_wp(n)
            return results
        results = self._while_stopped(work)
        self._emit("watchpoints", owner=owner)
        return results

    def list_watchpoints(self):
        out = []
        for s in self.wps:
            if s:
                kind, addr, mask = s.key
                length = ((~mask) & 0xFFFF) + 1
                access = {1: "read", 2: "write", 3: "readwrite"}[kind & 3]
                out.append({"id": s.n, "address": addr, "length": length, "mask": mask, "access": access,
                            "io": bool(kind & P.WP_IO), "symbol": self.symbol_text(addr), "owners": s.owner_names()})
        return out

    @staticmethod
    def mask_for(length):
        """A watched length -> the mask; length must be a power of two."""
        if length < 1 or length & (length - 1) or length > 0x10000:
            raise BridgeError("a watched length must be a power of two (1, 2, 4 ... ): the hardware compares under a mask")
        return (~(length - 1)) & 0xFFFF

    # ------------------------------------------------------------ console
    # ------------------------------------------------------------ keys (ticket #44)
    # PS/2 bytes through the KEY control command: decoded in hardware, so
    # they reach the board attached or not, running or stopped.
    def key_down(self, name):
        code = ps2keys.lookup(name)
        self.link.write(rlink.key(ps2keys.make(code)))
        self.held_keys.add(code)
        return code

    def key_up(self, name=None):
        """One key up; with no name, every key held."""
        codes = [ps2keys.lookup(name)] if name is not None else sorted(self.held_keys)
        for code in codes:
            self.link.write(rlink.key(ps2keys.brk(code)))
            self.held_keys.discard(code)
        return codes

    def type_text(self, text, hold=0.04, gap=0.02):
        """Each character down for hold seconds, then gap before the next:
        long enough for a program that polls the keys once a frame."""
        steps = ps2keys.type_text(text)
        for down, up, _ in steps:
            self.link.write(rlink.key(down))
            time.sleep(hold)
            self.link.write(rlink.key(up))
            time.sleep(gap)
        return len(steps)

    def send_console(self, text):
        if self.attached:
            raise BridgeError("attached: the console is on the board's screen only (debug.md 4.3)")
        self.link.write(text.replace("\r\n", "\n").replace("\n", "\r").encode("latin-1"))

    # ------------------------------------------------------------ symbols and addresses
    def symbol_text(self, addr):
        if not self.symbols:
            return None
        hit = self.symbols.symbol_at(addr, 0x400)
        if not hit:
            return None
        return hit[0] + ("+%d" % hit[1] if hit[1] else "")

    def format_address(self, addr):
        sym = self.symbol_text(addr)
        return "%04X" % addr + (" (%s)" % sym if sym else "")

    _NUM = re.compile(r"^(?:\$|&|0x|#)?([0-9a-fA-F]+)h?$")

    def parse_number(self, text, bare_hex=True):
        if isinstance(text, int):
            return text
        t = text.strip()
        low = t.lower()
        for pre in ("0x", "$", "&", "#"):
            if low.startswith(pre):
                return int(t[len(pre):], 16)
        if low.endswith("h") and re.fullmatch(r"[0-9a-f]+h", low):
            return int(t[:-1], 16)
        if low.startswith("0b"):
            return int(t[2:], 2)
        if re.fullmatch(r"[0-9a-f]+", low):
            return int(t, 16) if bare_hex else int(t, 10)
        raise ValueError(t)

    def parse_address(self, value, bare_hex=True):
        """A number or a string -> (space, address, page).

        "$8000", "0x8000", "&8000", "8000" (hex), "loop+3", "P012000" (physical),
        "0x0A3:$4000" (a page, for breakpoints)."""
        if isinstance(value, int):
            return 0, value, None
        text = str(value).strip()
        if not text:
            raise BridgeError("no address")
        if text[0] in "pP" and re.fullmatch(r"[pP][0-9a-fA-F]+", text):
            return 1, int(text[1:], 16), None
        page = None
        if ":" in text:
            ptext, text = text.split(":", 1)
            try:
                page = self.parse_number(ptext)
            except ValueError:
                raise BridgeError("bad page: %s" % ptext)
        return 0, self.eval_expression(text, bare_hex), page

    _TOKEN = re.compile(r"\s*([+-])?\s*([A-Za-z_.@][\w.@']*|\$[0-9a-fA-F]+|0x[0-9a-fA-F]+|&[0-9a-fA-F]+|[0-9][0-9a-fA-F]*h?)")

    def eval_expression(self, text, bare_hex=True):
        total = 0
        pos = 0
        first = True
        text = text.strip()
        while pos < len(text):
            m = self._TOKEN.match(text, pos)
            if not m or (not first and not m.group(1)):
                raise BridgeError("cannot read %r" % text)
            sign, tok = m.group(1), m.group(2)
            v = None
            if re.fullmatch(r"[A-Za-z_.@][\w.@']*", tok):
                if self.symbols:
                    v = self.symbols.resolve(tok)
                if v is None:
                    try:
                        v = self.parse_number(tok, bare_hex) if re.fullmatch(r"[0-9a-fA-F]+", tok) else None
                    except ValueError:
                        v = None
                if v is None:
                    raise BridgeError("no symbol %s%s" % (tok, "" if self.symbols else " (no debug info loaded)"))
            else:
                try:
                    v = self.parse_number(tok, bare_hex)
                except ValueError:
                    raise BridgeError("cannot read %r" % tok)
            total = total - v if sign == "-" else total + v
            pos = m.end()
            first = False
        if first:
            raise BridgeError("no address")
        return total

    def state(self):
        s = {"attached": self.attached, "running": self.running, "ended": self.ended,
             "serial_port": self.serial_name}
        if self.last_stop is not None and self.attached:
            st = self.last_stop
            s["stop"] = {"reason": st.name, "pc": "%04X" % st.pc, "symbol": self.symbol_text(st.pc),
                         "text": self.describe_stop(st)}
            if st.reason == P.R_WATCHPOINT:
                s["stop"]["access"] = {"address": "%04X" % (st.aaddr & 0xFFFF), "data": "%02X" % (st.adata & 0xFF),
                                       "write": bool(st.akind & 1), "io": bool(st.akind & 2)}
        s["breakpoints"] = self.list_breakpoints() if self.attached else []
        s["watchpoints"] = self.list_watchpoints() if self.attached else []
        return s
