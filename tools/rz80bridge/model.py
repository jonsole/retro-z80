"""A Python model of the board's link side: the monitor, the loader and
the debug stub (debug.md, section 3.8).

It answers the link exactly as the boot ROM should: the control commands,
the sign-on and the monitor's prompt, the upload protocol (monitor.md,
section 6), HELLO at the prompt and every debug command and STOP
(debug.md, sections 4-7). Programs run on the small interpreter in z80.py
with the program map of spec 16, section 5.1. The ROM's calls are done
here in Python when the program reaches their entry points.

ModelLink is the PC's end: write(bytes) and read_some(timeout), like
rlink.SerialLink. Tests can damage frames on the way with `corrupt`.
"""

import queue
import struct
import threading
import time

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import rlink  # noqa: E402
from rz80bridge.z80 import Z80  # noqa: E402
from rz80bridge import protocol as P  # noqa: E402

PAGE = 0x2000
ROM_PAGE0 = 0x3FC
NONE_PAGE = 0x3FB
REGS_PAGE = 0x3F8
SRAM_PAGES = 0x100            # a 2 MB board (the KS2)
STUB_PAGE = 0x0FC             # the stub's frame buffers (DB12)
SERDATA_LOW = 0x53

STATUS_LINE = "Monitor.  H for help."


class ModelLink:
    """The PC's end of a link to a StubModel."""

    def __init__(self, model):
        self.model = model
        self.closed = False

    def write(self, data):
        self.model.inbox.put(bytes(data))

    def read_some(self, timeout):
        try:
            data = self.model.outbox.get(timeout=max(0.0, timeout))
        except queue.Empty:
            return b""
        parts = [data]
        while True:
            try:
                parts.append(self.model.outbox.get_nowait())
            except queue.Empty:
                break
        return b"".join(parts)

    def close(self):
        self.closed = True


class StubModel(threading.Thread):
    """The board, as far as the link can see it."""

    def __init__(self, slice_instructions=2000):
        super().__init__(daemon=True)
        self.inbox = queue.Queue()
        self.outbox = queue.Queue()
        self.slice = slice_instructions
        self.lock = threading.Lock()
        self.stop_event = threading.Event()
        # test hooks
        self.corrupt_next_reply = None   # "crc" or "drop": damage the next REPLY or STOP sent
        self.drop_next_stop = False
        self.commands_seen = []
        self._power_on()

    # ------------------------------------------------------------ machine
    def _power_on(self):
        self.pages = {}
        rom = bytearray([0xFF]) * (4 * PAGE)
        for vec in (0x08, 0x10, 0x18, 0x20, 0x28, 0x30):
            rom[vec] = 0xC9           # stand-ins: the model does the call itself
        rom[0x40] = 0x76              # EXIT
        self.rom = rom
        self._reset("power-on")

    def _reset(self, why):
        self.cpu = Z80(self._read, self._write, self._in, self._out, m1=self._m1)
        self.mmu = [(ROM_PAGE0, ROM_PAGE0)] + [(n, n) for n in range(1, 8)]
        self.bps = [None] * 4         # (addr, page or None)
        self.wps = [None] * 2         # (kind, addr, mask)
        self.mode = "monitor"         # monitor, loader, running
        self.attached = False
        self.program = False          # a program is loaded and stopped at the monitor
        self.line = ""
        self.last_line = ""
        self.inparser = rlink.FrameParser(syncs=(rlink.SYNC_PC,))
        self.ctl_held = b""
        self.last_seq = None
        self.last_result = None
        self.stop_count = 0
        self.last_stop = None
        self.loader = None
        self.access = None
        self.step_pending = False
        self.resume = False
        self.ended = False
        self._after = None
        self._send_text("retro-z80 boot ROM model  Z80 at 20 MHz, 2 MB SRAM\r\n"
                        "Reset: %s.  Self-test ok.\r\n" % why)
        if why != "upload":
            self._send_text(STATUS_LINE + "\r\n> ")

    def page_of(self, addr):
        return self.mmu[(addr >> 13) & 7]

    def phys_read(self, page, off):
        if page < SRAM_PAGES:
            buf = self.pages.get(page)
            return buf[off] if buf else 0
        if ROM_PAGE0 <= page <= ROM_PAGE0 + 3:
            return self.rom[(page - ROM_PAGE0) * PAGE + off]
        return 0xFF

    def phys_write(self, page, off, v):
        if page < SRAM_PAGES:
            buf = self.pages.get(page)
            if buf is None:
                buf = self.pages[page] = bytearray(PAGE)
            buf[off] = v & 0xFF

    def _read(self, addr):
        v = self.phys_read(self.page_of(addr)[0], addr & 0x1FFF)
        self._watch(addr, v, write=False, io=False)
        return v

    def _m1(self, addr):
        return self.phys_read(self.page_of(addr)[0], addr & 0x1FFF)

    def _write(self, addr, v):
        self._watch(addr, v, write=True, io=False)
        self.phys_write(self.page_of(addr)[1], addr & 0x1FFF, v)

    def _in(self, port):
        self._watch(port, 0xFF, write=False, io=True)
        return 0xFF

    def _out(self, port, v):
        self._watch(port, v, write=True, io=True)
        if port & 0xFF == SERDATA_LOW:
            self._send(bytes([v]))     # SERDATA straight to the link, attached or not

    def _watch(self, addr, v, write, io):
        if self.access is not None:
            return
        for n, wp in enumerate(self.wps):
            if wp is None:
                continue
            kind, waddr, mask = wp
            if bool(kind & P.WP_IO) != io:
                continue
            if not kind & (P.WP_WRITE if write else P.WP_READ):
                continue
            if (addr & mask & 0xFFFF) == (waddr & mask & 0xFFFF):
                self.access = (n, addr, v, (1 if write else 0) | (2 if io else 0))
                return

    # ------------------------------------------------------------ link output
    def _send(self, data):
        self.outbox.put(bytes(data))

    def _send_text(self, text):
        self._send(text.encode("latin-1"))

    def _console(self, text):
        """The ROM's PUTC and friends: to the serial link unless attached."""
        if not self.attached:
            self._send_text(text)

    def _frame(self, ftype, seq, payload):
        f = rlink.transport_frame(ftype, seq, P.CH_DEBUG, payload, sync=rlink.SYNC_MACHINE)
        damage = self.corrupt_next_reply
        if damage:
            self.corrupt_next_reply = None
            if damage == "drop":
                return
            if damage == "crc":
                f = f[:-1] + bytes([f[-1] ^ 0xFF])
        self._send(f)

    def _reply(self, seq, status, code=0, data=b""):
        self._frame(P.T_REPLY, seq, bytes([ord(status), code]) + data)

    def _stop(self, reason, n=0, aaddr=0, adata=0, akind=0, pc=None):
        pc = self.cpu.pc if pc is None else pc
        self.last_stop = struct.pack(">BBIIIB", reason, n, pc, aaddr, adata, akind)
        self.mode = "monitor"
        if self.attached:
            if self.drop_next_stop:
                self.drop_next_stop = False
            else:
                self._frame(P.T_STOP, self.stop_count, self.last_stop)
            self.stop_count = (self.stop_count + 1) & 0xFF
        else:
            msg = {P.R_BREAKPOINT: "Breakpoint at %04X", P.R_WATCHPOINT: "Watchpoint %d at %%04X" % n,
                   P.R_STEP: "Step at %04X", P.R_BREAK: "Break at %04X", P.R_TRAP: "Trap at %04X",
                   P.R_PAUSE: "NMI (USB) at %04X", P.R_BUTTON: "NMI (button) at %04X",
                   P.R_EXIT: "Program ended."}.get(reason, "Stopped at %04X")
            if "%" in msg:
                msg = msg % pc
            self._send_text("\r\n" + msg + "\r\n" + self._regs_text() + "> ")

    # ------------------------------------------------------------ the thread
    def run(self):
        while not self.stop_event.is_set():
            if self.mode == "running":
                self._run_slice()
                try:
                    data = self.inbox.get_nowait()
                except queue.Empty:
                    continue
            else:
                try:
                    data = self.inbox.get(timeout=0.05)
                except queue.Empty:
                    self._idle()
                    continue
            with self.lock:
                self._input(data)

    def shutdown(self):
        self.stop_event.set()

    def _idle(self):
        with self.lock:
            if self.mode == "monitor" or self.mode == "loader":
                for item in self.inparser.poll():
                    self._take(item)

    def _input(self, data):
        """Every byte from the PC goes through the control-command matcher first (in hardware)."""
        data = self.ctl_held + data
        self.ctl_held = b""
        pre = rlink.CTL_PREFIX
        full = len(pre) + 2
        out = bytearray()
        i = 0
        while i < len(data):
            if data[i] == pre[0]:
                rest = data[i:i + full]
                head = rest[:len(pre)]
                if head == pre[:len(head)]:
                    if len(rest) < full:
                        self.ctl_held = bytes(rest)      # might still become a command
                        break
                    if rest[-1] == rest[-2] ^ 0xFF:
                        if out:
                            self._bytes(bytes(out))
                            out.clear()
                        self._control(rest[-2])
                        i += full
                        continue
            out.append(data[i])
            i += 1
        if out:
            self._bytes(bytes(out))

    def _control(self, c):
        if c == rlink.CTL_RESET:
            self._reset("USB")
        elif c == rlink.CTL_UPLOAD:
            self._reset("upload")
            self.mode = "loader"
            self.loader = {"hdr": None, "last": None}
            self._send_text("LOAD Z80 1\r\n")
        elif c == rlink.CTL_BREAK:
            if self.mode == "running":
                self._stop(P.R_PAUSE)
            elif self.mode == "monitor":
                # at the prompt: back to the prompt, the stopped program kept
                if self.attached:
                    pass
                else:
                    self._send_text("\r\n> ")

    def _bytes(self, data):
        if self.mode == "running":
            return       # nothing reads the link while a program runs
        for item in self.inparser.feed(data):
            self._take(item)

    def _take(self, item):
        if isinstance(item, rlink.Frame):
            if self.mode == "loader" and item.type <= rlink.ABORT:
                return self._loader_frame(item)
            if item.type >= 0x10 and item.channel == P.CH_DEBUG:
                if self.attached:
                    return self._debug_frame(item)
                if item.type == P.HELLO and item.error is None and self.mode == "monitor":
                    return self._debug_frame(item)
            return
        if isinstance(item, (bytes, bytearray)) and self.mode == "monitor" and not self.attached:
            for ch in item.decode("latin-1"):
                self._key(ch)

    # ------------------------------------------------------------ loader
    def _loader_reply(self, status, seq, code=0):
        self._send(b"LR" + bytes([ord(status), seq & 0xFF, code]))

    def _loader_frame(self, f):
        if f.error == "crc":
            return self._loader_reply("C", f.seq)
        if f.error:
            return self._loader_reply("F", f.seq)
        ld = self.loader
        if ld["last"] == f.seq and f.type != rlink.PING:
            return self._loader_reply("K", f.seq)
        if f.type == rlink.PING:
            self._loader_reply("K", f.seq, 1)
            self._send_text("LOAD Z80 1\r\n")
            return
        if f.type == rlink.HEADER:
            hdr = f.payload
            if len(hdr) != rlink.HEADER_LEN or hdr[:4] != rlink.MAGIC:
                return self._loader_reply("R", f.seq, 2)
            ver, target, flags, load, entry, size, icrc = struct.unpack(">BBHIIII", hdr[8:28])
            if hdr[4:8] != b"Z80 ":
                return self._loader_reply("R", f.seq, 1)
            if rlink.crc32(hdr[:28]) != struct.unpack(">I", hdr[28:32])[0] or ver != 1 or flags & 0xFFFE:
                return self._loader_reply("R", f.seq, 2)
            if target != 0:
                return self._loader_reply("R", f.seq, 5)
            if load < 0x2000 or load + size > 0x10000 or entry > 0xFFFF:
                return self._loader_reply("R", f.seq, 3)
            ld.update(hdr=(load, entry, size, icrc), got=0, last=f.seq)
            return self._loader_reply("K", f.seq)
        if ld["hdr"] is None:
            return self._loader_reply("R", f.seq, 7)
        load, entry, size, icrc = ld["hdr"]
        if f.type == rlink.DATA:
            if f.offset + len(f.payload) > size:
                return self._loader_reply("R", f.seq, 7)
            for i, b in enumerate(f.payload):
                a = load + f.offset + i
                self.phys_write(a >> 13, a & 0x1FFF, b)
            ld["got"] += len(f.payload)
            ld["last"] = f.seq
            return self._loader_reply("K", f.seq)
        if f.type == rlink.END:
            data = bytes(self.phys_read((load + i) >> 13, (load + i) & 0x1FFF) for i in range(size))
            if rlink.crc32(data) != icrc:
                return self._loader_reply("R", f.seq, 6)
            ld["last"] = f.seq
            self._loader_reply("K", f.seq)
            action = f.payload[0] if f.payload else 0
            self._program_start(entry)
            if action == 1:
                self.mode = "running"
                self.resume = True
            else:
                self.mode = "monitor"
                self._send_text("Loaded.  PC = %04X\r\n> " % entry)
            return
        if f.type == rlink.ABORT:
            ld["hdr"] = None
            return self._loader_reply("K", f.seq)

    def _program_start(self, entry):
        c = self.cpu
        c.reset()
        c.a = c.f = c.b = c.c = c.d = c.e = c.h = c.l = 0
        c.ix = c.iy = 0
        c.sp = 0xFFFE
        self.phys_write(7, 0x1FFE, 0x40)
        self.phys_write(7, 0x1FFF, 0x00)
        c.pc = entry
        c.im = 2
        self.last_stop = struct.pack(">BBIIIB", P.R_ENTRY, 0, entry, 0, 0, 0)
        self.program = True
        self.ended = False

    # ------------------------------------------------------------ running
    def _run_slice(self):
        for _ in range(self.slice):
            if self.mode != "running":
                return
            self._one(step=False)

    def _one(self, step):
        """Runs one instruction (or one ROM call); stops as the debug unit would."""
        c = self.cpu
        pc = c.pc
        if not self.resume:
            for n, bp in enumerate(self.bps):
                if bp and bp[0] == pc and (bp[1] is None or bp[1] == self.page_of(pc)[0]):
                    return self._stop(P.R_BREAKPOINT, n)
        self.resume = False
        self.access = None
        if not (pc < 0x2000 and self.page_of(pc)[0] == ROM_PAGE0 and self._rom_call(pc)):
            c.step()
        if self.access is not None:
            n, aaddr, adata, akind = self.access
            self.access = None
            return self._stop(P.R_WATCHPOINT, n, aaddr, adata, akind)
        if step and self.mode == "running":
            self._stop(P.R_STEP)

    def _rom_call(self, pc):
        """The ROM's entry points, done in Python. True if pc was one."""
        c = self.cpu
        if pc == 0x0040:
            self.ended = True
            self.program = False
            self._stop(P.R_EXIT)
            return True
        if pc == 0x0038:
            ret = c._pop()
            self._stop(P.R_TRAP, pc=(ret - 1) & 0xFFFF)
            c.pc = (ret - 1) & 0xFFFF
            return True
        if pc == 0x0030:
            ret = c._pop()
            c.pc = ret
            self._stop(P.R_BREAK, pc=ret)
            return True
        if pc == 0x0008:
            self._console(chr(c.a))
        elif pc == 0x0018:
            s = []
            while True:
                b = c.read(c.hl)
                c.hl = (c.hl + 1) & 0xFFFF
                if b == 0:
                    break
                s.append(chr(b))
            self._console("".join(s))
        elif pc in (0x0010, 0x0020):
            c.a = 0
            c.f = (c.f | 0x40)
        elif pc == 0x0028:
            ret = c._pop()
            fn = c.read(ret)
            c._push((ret + 1) & 0xFFFF)
            if fn == 0x01:
                self._console(chr(c.a))
            elif fn == 0x04:
                return self._rom_call_fn_puts()
            elif fn == 0x06:
                self._console("%02X" % c.a)
            elif fn == 0x07:
                self._console("%04X" % c.hl)
            elif fn == 0x0F:
                c._pop()
                c.pc = 0x0040
                return True
            elif fn == 0x10:
                c.pc = c._pop()
                self._stop(P.R_BREAK)
                return True
        else:
            return False
        c.pc = c._pop()
        return True

    def _rom_call_fn_puts(self):
        self.cpu.pc = 0x0018
        return self._rom_call(0x0018)

    # ------------------------------------------------------------ the monitor (typed)
    def _regs_text(self):
        c = self.cpu
        return ("AF=%04X BC=%04X DE=%04X HL=%04X IX=%04X IY=%04X SP=%04X PC=%04X\r\n"
                % (c.af, c.bc, c.de, c.hl, c.ix, c.iy, c.sp, c.pc))

    def _key(self, ch):
        if ch in "\r\n":
            if ch == "\n":
                return
            line = self.line
            self.line = ""
            self._send_text("\r\n")
            self._send_text(self.monitor_line(line, typed=True))
            if self.mode == "monitor":
                self._send_text("> ")
        elif ch in "\x08\x7f":
            if self.line:
                self.line = self.line[:-1]
                self._send_text("\x08 \x08")
        elif ch == "\x1b":
            self.line = ""
            self._send_text("\r\n> ")
        elif ch >= " ":
            self.line += ch
            self._send_text(ch)

    def monitor_line(self, line, typed=False):
        """A monitor command line -> its output. A few commands only."""
        parts = line.replace(",", " ").split()
        if not parts:
            return ""
        cmd, args = parts[0].upper(), parts[1:]
        try:
            nums = [int(a.lstrip("pP"), 16) for a in args]
        except ValueError:
            return "? syntax\r\n"
        if cmd == "H":
            return "D dump  R registers  G go  N step  H help (model)\r\n"
        if cmd == "R":
            return self._regs_text()
        if cmd == "D":
            start = nums[0] if nums else 0
            count = nums[1] if len(nums) > 1 else 0x40
            out = []
            for row in range(start, start + count, 16):
                bs = [self.phys_read(self.page_of(a & 0xFFFF)[0], a & 0x1FFF) for a in range(row, min(row + 16, start + count))]
                out.append("%04X  %s\r\n" % (row & 0xFFFF, " ".join("%02X" % b for b in bs)))
            return "".join(out)
        if cmd in ("G", "N") and typed:
            if not self.program:
                return "? no program\r\n"
            if nums:
                self.cpu.pc = nums[0] & 0xFFFF
            self.resume = True
            self.mode = "running"
            if cmd == "N":
                self._one(step=True)
            return ""
        return "? not yet\r\n"

    # ------------------------------------------------------------ the debug stub
    def _target_description(self):
        d = struct.pack(">B4sBBBBBBBHBB", 1, b"Z80 ", 16, 23, 4, 2, 0x0F, 8, 0x03, 2048, 28, len(P.Z80_REGS))
        for name, off, size, flags in P.Z80_REGS:
            d += bytes([len(name)]) + name.encode() + bytes([off, size, flags])
        return d

    def _regblock(self):
        c = self.cpu
        im = c.im if self.program or self.attached else 0xFF
        return struct.pack(">HHHHHHHHHHHHBBBB", c.af, c.bc, c.de, c.hl, c.ix, c.iy, c.sp, c.pc,
                           (c.a_ << 8) | c.f_, (c.b_ << 8) | c.c_, (c.d_ << 8) | c.e_, (c.h_ << 8) | c.l_,
                           c.i, c.r, c.iff1 | (c.iff2 << 1), im)

    def _set_regblock(self, blk):
        c = self.cpu
        (c.af, c.bc, c.de, c.hl, c.ix, c.iy, c.sp, c.pc, af_, bc_, de_, hl_,
         c.i, c.r, iff, im) = struct.unpack(">HHHHHHHHHHHHBBBB", blk)
        c.a_, c.f_ = af_ >> 8, af_ & 0xFF
        c.b_, c.c_ = bc_ >> 8, bc_ & 0xFF
        c.d_, c.e_ = de_ >> 8, de_ & 0xFF
        c.h_, c.l_ = hl_ >> 8, hl_ & 0xFF
        c.iff1, c.iff2 = iff & 1, (iff >> 1) & 1
        if im != 0xFF:
            c.im = im

    def _mem_ok(self, space, addr, count, write):
        if space == 0:
            return 0 <= addr and addr + count <= 0x10000
        page_end = (addr + count - 1) >> 13
        for page in range(addr >> 13, page_end + 1):
            if write and page >= SRAM_PAGES:
                return False
            if not (page < SRAM_PAGES or page == REGS_PAGE or ROM_PAGE0 <= page <= ROM_PAGE0 + 3):
                return False
            if page == STUB_PAGE:
                return False
        return True

    def _mem_rw(self, space, addr, data=None, count=0, side_effects=False):
        out = bytearray()
        n = len(data) if data is not None else count
        for i in range(n):
            a = addr + i
            if space == 0:
                page = self.page_of(a)[1 if data is not None else 0]
                off = a & 0x1FFF
            else:
                page, off = a >> 13, a & 0x1FFF
            if data is not None:
                self.phys_write(page, off, data[i])
            elif page == REGS_PAGE and not side_effects:
                out.append(0xFF)
            else:
                out.append(self.phys_read(page, off))
        return bytes(out)

    def _debug_frame(self, f):
        self.commands_seen.append(f.type)
        if f.error == "crc":
            return self._reply(f.seq, "C")
        if f.error:
            return self._reply(f.seq, "F")
        if self.mode == "running":
            return
        t, pl = f.type, f.payload
        # a repeated SEQ: reads are done again, writes answered as before
        if self.attached and f.seq == self.last_seq and self.last_result is not None:
            if t not in P.READ_ONLY_COMMANDS:
                st, code = self.last_result
                return self._reply(f.seq, st, code)
        self.last_seq = f.seq
        try:
            st, code, data = self._command(t, pl)
        except _Refuse as r:
            st, code, data = "R", r.code, b""
        except struct.error:
            st, code, data = "R", P.E_LENGTH, b""
        self.last_result = (st, code)
        if st is None:
            return
        self._reply(f.seq, st, code, data)
        after = getattr(self, "_after", None)
        self._after = None
        if after:
            after()

    def _command(self, t, pl):
        if t == P.HELLO:
            if len(pl) != 1:
                raise _Refuse(P.E_LENGTH)
            if pl[0] != 1:
                raise _Refuse(P.E_VERSION)
            self.attached = True
            self._after = self._resend_stop
            return "K", 0, self._target_description()
        if not self.attached:
            raise _Refuse(P.E_UNKNOWN)
        if t == P.QUERY:
            return "K", 0, bytes([1]) + (self.last_stop or bytes(15))
        if t == P.READREGS:
            return "K", 0, self._regblock()
        if t == P.WRITEREGS:
            if len(pl) < 2:
                raise _Refuse(P.E_LENGTH)
            start, vals = pl[0], pl[1:]
            if start + len(vals) > 28:
                raise _Refuse(P.E_REGISTER)
            blk = bytearray(self._regblock())
            blk[start:start + len(vals)] = vals
            self._set_regblock(bytes(blk))
            return "K", 0, b""
        if t == P.READMEM:
            space, flags, addr, count = struct.unpack(">BBIH", pl)
            if not 1 <= count <= 2048 or space > 1:
                raise _Refuse(P.E_LENGTH)
            addr &= 0xFFFF if space == 0 else 0x7FFFFF
            if not self._mem_ok(space, addr, count, False):
                raise _Refuse(P.E_ADDRESS)
            return "K", 0, self._mem_rw(space, addr, count=count, side_effects=bool(flags & 1))
        if t == P.WRITEMEM:
            space, flags, addr = struct.unpack(">BBI", pl[:6])
            data = pl[6:]
            if not 1 <= len(data) <= 2048 or space > 1:
                raise _Refuse(P.E_LENGTH)
            addr &= 0xFFFF if space == 0 else 0x7FFFFF
            if not self._mem_ok(space, addr, len(data), True):
                raise _Refuse(P.E_ADDRESS)
            self._mem_rw(space, addr, data=data)
            return "K", 0, b""
        if t == P.READMMU:
            return "K", 0, b"".join(struct.pack(">HH", r, w) for r, w in self.mmu)
        if t == P.SETBP:
            n, flags, addr, page = struct.unpack(">BBIH", pl)
            if n >= 4:
                raise _Refuse(P.E_NUMBER)
            self.bps[n] = (addr & 0xFFFF, page if flags & 1 else None)
            return "K", 0, b""
        if t == P.CLEARBP:
            n, = struct.unpack(">B", pl)
            if n >= 4:
                raise _Refuse(P.E_NUMBER)
            self.bps[n] = None
            return "K", 0, b""
        if t == P.SETWP:
            n, kind, addr, mask = struct.unpack(">BBII", pl)
            if n >= 2:
                raise _Refuse(P.E_NUMBER)
            if not kind & 3:
                raise _Refuse(P.E_LENGTH)
            if kind & ~0x07:
                raise _Refuse(P.E_KIND)
            self.wps[n] = (kind, addr & 0xFFFF, mask & 0xFFFF)
            return "K", 0, b""
        if t == P.CLEARWP:
            n, = struct.unpack(">B", pl)
            if n >= 2:
                raise _Refuse(P.E_NUMBER)
            self.wps[n] = None
            return "K", 0, b""
        if t == P.CONTINUE:
            flags, = struct.unpack(">B", pl)
            if self.ended:
                raise _Refuse(P.E_ADDRESS)
            if flags & 1:
                self._detach()

            def go():
                self.resume = True
                self.mode = "running"
            self._after = go
            return "K", 0, b""
        if t == P.STEP:
            flags, = struct.unpack(">B", pl)
            if self.ended:
                raise _Refuse(P.E_ADDRESS)

            def step():
                self.resume = True
                self.mode = "running"
                self._one(step=True)
            self._after = step
            return "K", 0, b""
        if t == P.DETACH:
            self._after = lambda: self._detach(say=True)
            return "K", 0, b""
        if t == P.CONSOLE:
            line = pl.decode("latin-1")
            if not 1 <= len(pl) <= 80:
                raise _Refuse(P.E_LENGTH)
            if line.strip()[:1].upper() in "GNULBXT" and line.strip():
                raise _Refuse(P.E_CONSOLE)
            return "K", 0, self.monitor_line(line).encode("latin-1")[:2048]
        raise _Refuse(P.E_UNKNOWN)

    def _resend_stop(self):
        if self.last_stop is None:
            self.last_stop = struct.pack(">BBIIIB", P.R_PAUSE, 0, self.cpu.pc, 0, 0, 0)
        if True:
            self._frame(P.T_STOP, self.stop_count, self.last_stop)
            self.stop_count = (self.stop_count + 1) & 0xFF

    def _detach(self, say=False):
        self.bps = [None] * 4
        self.wps = [None] * 2
        self.attached = False
        self.last_seq = None
        if say:
            self._send_text("\r\nDetached at %04X\r\n%s> " % (self.cpu.pc, self._regs_text()))


class _Refuse(Exception):
    def __init__(self, code):
        self.code = code
