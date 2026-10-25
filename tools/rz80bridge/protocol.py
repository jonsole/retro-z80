"""The debug channel (debug.md, sections 4-7): constants, parsers, and the
client that sends commands and waits for their replies."""

import queue
import struct
import threading
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import rlink  # noqa: E402

CH_DEBUG, CH_CONSOLE, CH_VIDEO, CH_GDB = 1, 2, 3, 4

# Commands (debug.md, section 5)
HELLO, QUERY, READREGS, WRITEREGS, READMEM, WRITEMEM, READMMU = 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16
SETBP, CLEARBP, SETWP, CLEARWP, CONTINUE, STEP, DETACH, CONSOLE = 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E
READ_ONLY_COMMANDS = {HELLO, QUERY, READREGS, READMEM, READMMU}
COMMAND_NAMES = {HELLO: "HELLO", QUERY: "QUERY", READREGS: "READREGS", WRITEREGS: "WRITEREGS",
                 READMEM: "READMEM", WRITEMEM: "WRITEMEM", READMMU: "READMMU", SETBP: "SETBP",
                 CLEARBP: "CLEARBP", SETWP: "SETWP", CLEARWP: "CLEARWP", CONTINUE: "CONTINUE",
                 STEP: "STEP", DETACH: "DETACH", CONSOLE: "CONSOLE"}

T_REPLY, T_STOP = 0x80, 0x81

# Refusal codes (debug.md, section 4.6)
E_UNKNOWN, E_LENGTH, E_ADDRESS, E_NUMBER, E_KIND, E_REGISTER, E_CONSOLE, E_VERSION = 1, 2, 3, 4, 5, 6, 7, 8
REFUSALS = {
    E_UNKNOWN: "unknown command",
    E_LENGTH: "a length or field is wrong for the command",
    E_ADDRESS: "the address or range is not allowed",
    E_NUMBER: "no such breakpoint or watchpoint number",
    E_KIND: "a watchpoint kind or mask the machine does not offer",
    E_REGISTER: "outside the register block, or a read-only register",
    E_CONSOLE: "that monitor command runs code or leaves the monitor: use the debugger's buttons",
    E_VERSION: "the protocol version is not one the stub speaks",
}

# Stop reasons (debug.md, section 6)
R_ENTRY, R_PAUSE, R_BUTTON, R_BREAKPOINT, R_WATCHPOINT, R_STEP, R_BREAK, R_TRAP, R_EXIT = range(9)
REASON_NAMES = ["entry", "pause", "button", "breakpoint", "watchpoint", "step", "break", "trap", "exit"]

WP_READ, WP_WRITE, WP_IO = 1, 2, 4

# The Z80's register block (debug.md, section 5.2): name, offset, size, flags
F_PC, F_SP, F_FLAGS, F_RO = 1, 2, 4, 8
Z80_REGS = [
    ("AF", 0, 2, F_FLAGS), ("BC", 2, 2, 0), ("DE", 4, 2, 0), ("HL", 6, 2, 0),
    ("IX", 8, 2, 0), ("IY", 10, 2, 0), ("SP", 12, 2, F_SP), ("PC", 14, 2, F_PC),
    ("AF'", 16, 2, F_FLAGS), ("BC'", 18, 2, 0), ("DE'", 20, 2, 0), ("HL'", 22, 2, 0),
    ("I", 24, 1, 0), ("R", 25, 1, 0), ("IFF", 26, 1, 0), ("IM", 27, 1, 0),
]

REPLY_WAIT = 2.0
TRIES = 5


class Refused(Exception):
    def __init__(self, command, code):
        self.command = command
        self.code = code
        super().__init__("%s refused: %s" % (COMMAND_NAMES.get(command, hex(command)),
                                             REFUSALS.get(code, "code %d" % code)))


class LinkLost(Exception):
    pass


class Register:
    __slots__ = ("name", "offset", "size", "flags")

    def __init__(self, name, offset, size, flags):
        self.name, self.offset, self.size, self.flags = name, offset, size, flags


class Target:
    """The target description (debug.md, section 5.2)."""

    def __init__(self, data):
        (self.version, machine, self.addrbits, self.physbits, self.nbp, self.nwp, self.wpkinds,
         self.nwin, self.steps, self.maxdata, self.blocklen, nreg) = struct.unpack(">B4sBBBBBBBHBB", data[:16])
        self.machine = machine.decode("ascii", "replace")
        self.registers = []
        i = 16
        for _ in range(nreg):
            n = data[i]
            name = data[i + 1:i + 1 + n].decode("ascii")
            off, size, flags = data[i + 1 + n:i + 4 + n]
            self.registers.append(Register(name, off, size, flags))
            i += 4 + n

    def reg(self, name):
        for r in self.registers:
            if r.name.upper() == name.upper():
                return r
        return None

    def decode(self, block):
        """The register block -> {name: value}."""
        out = {}
        for r in self.registers:
            out[r.name] = int.from_bytes(block[r.offset:r.offset + r.size], "big")
        return out

    @property
    def pc(self):
        return next(r for r in self.registers if r.flags & F_PC)

    @property
    def sp(self):
        return next(r for r in self.registers if r.flags & F_SP)


class Stop:
    """A STOP frame's payload (debug.md, section 6)."""
    __slots__ = ("reason", "n", "pc", "aaddr", "adata", "akind")

    def __init__(self, payload):
        self.reason, self.n, self.pc, self.aaddr, self.adata, self.akind = struct.unpack(">BBIIIB", payload[:15])

    @property
    def name(self):
        return REASON_NAMES[self.reason] if self.reason < len(REASON_NAMES) else "reason %d" % self.reason

    def __repr__(self):
        return "Stop(%s, n=%d, pc=%04X)" % (self.name, self.n, self.pc)


class DebugClient:
    """Sends commands on the debug channel and matches their replies.

    `send(bytes)` writes to the link. The owner of the link feeds every
    frame from the machine to `frame()`; replies are matched here, STOP
    frames go to `on_stop(Stop)`.
    """

    def __init__(self, send, on_stop, reply_wait=REPLY_WAIT, tries=TRIES):
        self.send = send
        self.on_stop = on_stop
        self.reply_wait = reply_wait
        self.tries = tries
        self.seq = 0
        self.replies = queue.Queue()
        self.lock = threading.Lock()
        self.last_stop_count = None
        self.damaged = threading.Event()   # a damaged frame from the machine was seen
        self.resends = 0

    def frame(self, f):
        if f.channel != CH_DEBUG:
            return
        if f.error:
            self.damaged.set()
            return
        if f.type == T_REPLY:
            self.replies.put(f)
        elif f.type == T_STOP:
            self.last_stop_count = f.seq
            self.on_stop(Stop(f.payload))

    def command(self, ctype, payload=b""):
        """Sends a command and returns its reply data. Raises Refused or LinkLost."""
        with self.lock:
            self.seq = (self.seq + 1) & 0xFF
            seq = self.seq
            frame = rlink.transport_frame(ctype, seq, CH_DEBUG, payload)
            while not self.replies.empty():
                self.replies.get_nowait()
            for _ in range(self.tries):
                self.send(frame)
                reply = self._wait(seq)
                if reply is None:
                    self.resends += 1
                    continue
                status, code = chr(reply.payload[0]), reply.payload[1]
                if status in "CF":
                    self.resends += 1
                    continue
                if status == "R":
                    raise Refused(ctype, code)
                return reply.payload[2:]
            raise LinkLost("no answer from the machine to %s after %d tries" % (COMMAND_NAMES.get(ctype, hex(ctype)), self.tries))

    def _wait(self, seq):
        import time
        deadline = time.monotonic() + self.reply_wait
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                return None
            try:
                f = self.replies.get(timeout=left)
            except queue.Empty:
                return None
            if f.seq == seq:
                return f

    # ------------------------------------------------------------ the commands
    def hello(self):
        return Target(self.command(HELLO, bytes([1])))

    def query(self):
        d = self.command(QUERY)
        return d[0], (Stop(d[1:16]) if len(d) >= 16 else None)

    def read_regs(self):
        return self.command(READREGS)

    def write_regs(self, start, data):
        self.command(WRITEREGS, bytes([start]) + bytes(data))

    def read_mem(self, addr, count, space=0, side_effects=False):
        return self.command(READMEM, struct.pack(">BBIH", space, 1 if side_effects else 0, addr, count))

    def write_mem(self, addr, data, space=0):
        self.command(WRITEMEM, struct.pack(">BBI", space, 0, addr) + bytes(data))

    def read_mmu(self):
        d = self.command(READMMU)
        return [struct.unpack(">HH", d[i:i + 4]) for i in range(0, len(d), 4)]

    def set_bp(self, n, addr, page=None):
        self.command(SETBP, struct.pack(">BBIH", n, 1 if page is not None else 0, addr, page or 0))

    def clear_bp(self, n):
        self.command(CLEARBP, bytes([n]))

    def set_wp(self, n, kind, addr, mask):
        self.command(SETWP, struct.pack(">BBII", n, kind, addr, mask))

    def clear_wp(self, n):
        self.command(CLEARWP, bytes([n]))

    def cont(self, detach=False):
        self.command(CONTINUE, bytes([1 if detach else 0]))

    def step(self, into=False):
        self.command(STEP, bytes([1 if into else 0]))

    def detach(self):
        self.command(DETACH)

    def console(self, line):
        return self.command(CONSOLE, line.encode("latin-1")).decode("latin-1")
