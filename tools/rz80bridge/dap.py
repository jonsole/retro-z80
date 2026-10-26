"""The bridge's DAP server: VS Code connects to it by TCP (`debugServer`).

The requests and their behaviour follow the zx emulator's DAP (its
docs/vscode-debugging.md), on the shared Session: launch and attach,
source, instruction and data breakpoints (the hardware's 4 and 2),
stepping by instruction or line, a call stack from return addresses,
Registers, Flags and MMU scopes, memory, disassembly, and the debug
console as the monitor's command line (debug.md, sections 3.4 and 5.9).
"""

import base64
import json
import os
import socket
import sys
import threading

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import rlink  # noqa: E402
from rz80bridge import protocol as P  # noqa: E402
from rz80bridge.session import BridgeError, FLAG_BITS  # noqa: E402
from rz80bridge.sld import Symbols  # noqa: E402

THREAD = 1
REF_REGS, REF_FLAGS, REF_MMU = 1, 2, 3

STOP_REASONS = {"entry": "entry", "pause": "pause", "button": "pause", "breakpoint": "breakpoint",
                "watchpoint": "data breakpoint", "step": "step", "break": "breakpoint", "trap": "exception"}

CAPABILITIES = {
    "supportsConfigurationDoneRequest": True,
    "supportsSetVariable": True,
    "supportsReadMemoryRequest": True,
    "supportsWriteMemoryRequest": True,
    "supportsDisassembleRequest": True,
    "supportsInstructionBreakpoints": True,
    "supportsDataBreakpoints": True,
    "supportsDataBreakpointBytes": True,
    "supportsSteppingGranularity": True,
    "supportsEvaluateForHovers": True,
    "supportTerminateDebuggee": True,
    "supportsLoadedSourcesRequest": False,
}

MONITOR_LETTERS = set("DEFCVSGRPITULBXHN")


def load_program(args, cwd):
    """launch.json's program -> an rlink.Image."""
    path = args.get("program")
    if not path:
        raise BridgeError("launch needs \"program\": a .rimg image, or a raw binary with \"load\"")
    if not os.path.isabs(path):
        path = os.path.join(cwd, path)
    try:
        with open(path, "rb") as f:
            blob = f.read()
    except OSError as e:
        raise BridgeError("cannot read the program: %s" % e)
    if blob[:4] == rlink.MAGIC and "load" not in args:
        img, problems = rlink.Image.parse(blob)
        if problems:
            raise BridgeError("%s: %s" % (path, "; ".join(problems)))
        img.path = path
        return img
    if "load" not in args:
        raise BridgeError("%s is a raw binary: give \"load\" (and \"entry\")" % path)
    num = lambda v: v if isinstance(v, int) else int(str(v).lstrip("$&").replace("0x", ""), 16)
    load = num(args["load"])
    img = rlink.Image(blob, "z80", load, num(args.get("entry", load)))
    img.path = path
    return img


def load_symbols(args, cwd):
    sld = args.get("sld")
    if not sld:
        return None
    if not os.path.isabs(sld):
        sld = os.path.join(cwd, sld)
    try:
        return Symbols.load(sld, bases=[cwd])
    except OSError as e:
        raise BridgeError("cannot read the SLD file: %s" % e)


class DapConnection(threading.Thread):
    def __init__(self, server, sock):
        super().__init__(daemon=True)
        self.server = server
        self.session = server.session
        self.sock = sock
        self.owner = "vscode"
        self.seq = 0
        self.send_lock = threading.Lock()
        self.configured = False
        self.pending_stop = None
        self.request = None
        self.stop_on_entry = True
        self.closed = False
        self.step_thread = None
        self.last_sent_stop = None

    # ------------------------------------------------------------ wire
    def send(self, msg):
        with self.send_lock:
            self.seq += 1
            msg["seq"] = self.seq
            body = json.dumps(msg).encode("utf-8")
            try:
                self.sock.sendall(b"Content-Length: %d\r\n\r\n" % len(body) + body)
            except OSError:
                self.closed = True

    def event(self, name, body=None):
        msg = {"type": "event", "event": name}
        if body is not None:
            msg["body"] = body
        self.send(msg)

    def respond(self, req, body=None, error=None):
        msg = {"type": "response", "request_seq": req["seq"], "command": req["command"], "success": error is None}
        if error is not None:
            msg["message"] = error
            msg["body"] = {"error": {"id": 1, "format": error, "showUser": True}}
        elif body is not None:
            msg["body"] = body
        self.send(msg)

    def output(self, text, category="console"):
        self.event("output", {"category": category, "output": text})

    def run(self):
        self.session.add_listener(self.on_session)
        buf = b""
        try:
            while not self.closed:
                data = self.sock.recv(65536)
                if not data:
                    break
                buf += data
                while True:
                    head_end = buf.find(b"\r\n\r\n")
                    if head_end < 0:
                        break
                    length = None
                    for line in buf[:head_end].split(b"\r\n"):
                        k, _, v = line.partition(b":")
                        if k.strip().lower() == b"content-length":
                            length = int(v.strip())
                    if length is None or len(buf) < head_end + 4 + length:
                        break
                    body = buf[head_end + 4:head_end + 4 + length]
                    buf = buf[head_end + 4 + length:]
                    self.dispatch(json.loads(body.decode("utf-8")))
        except (OSError, ValueError):
            pass
        finally:
            self.closed = True
            self.session.remove_listener(self.on_session)
            try:
                self.sock.close()
            except OSError:
                pass

    def dispatch(self, req):
        if req.get("type") != "request":
            return
        handler = getattr(self, "req_" + req["command"], None)
        if handler is None:
            self.respond(req, error="%s is not supported" % req["command"])
            return
        try:
            handler(req, req.get("arguments") or {})
        except BridgeError as e:
            self.respond(req, error=str(e))
        except (P.LinkLost, P.Refused) as e:
            self.respond(req, error=str(e))
        except Exception as e:   # keep the connection up
            self.respond(req, error="%s: %s" % (type(e).__name__, e))

    # ------------------------------------------------------------ session events
    def on_session(self, kind, data):
        if kind == "stopped":
            if not self.configured:
                self.pending_stop = data
                return
            self.send_stopped(data)
        elif kind == "continued" and data.get("owner") != self.owner:
            self.event("continued", {"threadId": THREAD, "allThreadsContinued": True})
        elif kind == "output":
            self.output(data["text"], "stdout")
        elif kind == "exited":
            self.output("Program ended.\n")
            self.event("exited", {"exitCode": 0})
            self.event("terminated")
        elif kind == "detached" and (data.get("owner") != self.owner or data.get("reset")):
            self.output("The board was %s.\n" % ("reset" if data.get("reset") else "detached by %s" % data.get("owner")))
            self.event("terminated")

    def send_stopped(self, data):
        stop = data["stop"]
        if stop is self.last_sent_stop:
            return
        self.last_sent_stop = stop
        reason = data.get("reason") or stop.name
        body = {"reason": STOP_REASONS.get(reason, reason), "threadId": THREAD, "allThreadsStopped": True,
                "description": data["text"], "text": data["text"]}
        if data.get("owner") not in (None, self.owner):
            body["preserveFocusHint"] = True     # a stop VS Code did not ask for (the zx rule)
        if stop.reason == P.R_BREAKPOINT and stop.n < len(self.session.bps) and self.session.bps[stop.n]:
            body["hitBreakpointIds"] = [stop.n + 1]
        self.event("stopped", body)

    # ------------------------------------------------------------ start and end
    def req_initialize(self, req, args):
        self.respond(req, CAPABILITIES)

    def _check_port(self, args):
        want = args.get("port")
        have = self.session.serial_name
        if want and have and want != have and not (want == "model" and have == "model"):
            raise BridgeError("this bridge has %s open, not %s: stop it, or give other bridgePorts" % (have, want))

    def req_launch(self, req, args):
        self._check_port(args)
        cwd = args.get("cwd") or os.getcwd()
        self.request = "launch"
        self.stop_on_entry = args.get("stopOnEntry", True)
        img = load_program(args, cwd)
        syms = load_symbols(args, cwd)
        self.output("Uploading %s\n" % img.describe())
        self.session.launch(img, owner=self.owner, symbols=syms)
        self.respond(req)
        self.event("initialized")

    def req_attach(self, req, args):
        self._check_port(args)
        cwd = args.get("cwd") or os.getcwd()
        self.request = "attach"
        self.stop_on_entry = True
        syms = load_symbols(args, cwd)
        if syms is not None:
            self.session.symbols = syms
        self.session.attach(owner=self.owner)
        self.respond(req)
        self.event("initialized")

    def req_configurationDone(self, req, args):
        self.configured = True
        self.respond(req)
        pending, self.pending_stop = self.pending_stop, None
        if self.request == "launch" and not self.stop_on_entry:
            self.session.cont(owner=self.owner)
        elif pending is not None:
            self.send_stopped(pending)
        elif self.session.attached and not self.session.running and self.session.last_stop:
            st = self.session.last_stop
            self.send_stopped({"stop": st, "owner": self.owner, "text": self.session.describe_stop(st)})

    def req_disconnect(self, req, args):
        s = self.session
        if s.attached:
            if s.held_by("mcp"):
                # DB15: MCP still holds breakpoints; leave the session to it
                for tag in {t for sl in s.bps if sl for o, t in sl.owners if o == self.owner}:
                    s.set_breakpoints(self.owner, tag, [])
                for tag in {t for sl in s.wps if sl for o, t in sl.owners if o == self.owner}:
                    s.set_watchpoints(self.owner, tag, [])
            else:
                run = not args.get("terminateDebuggee", self.request == "launch")
                s.detach(run=run, owner=self.owner)
        self.respond(req)
        self.closed = True

    def req_terminate(self, req, args):
        self.req_disconnect(req, {"terminateDebuggee": True})

    # ------------------------------------------------------------ breakpoints
    def req_setBreakpoints(self, req, args):
        src = args.get("source", {})
        path = src.get("path") or src.get("name") or ""
        lines = [b["line"] for b in args.get("breakpoints", [])] or args.get("lines", [])
        syms = self.session.symbols
        wanted, where = [], []
        for ln in lines:
            hit = syms.line_address(path, ln) if syms else None
            where.append(hit)
            if hit:
                wanted.append((hit[0], hit[1]))
        results = self.session.set_breakpoints(self.owner, "src:" + path.lower(), wanted) if self.session.attached else []
        out = []
        k = 0
        for ln, hit in zip(lines, where):
            if hit is None:
                out.append({"verified": False, "line": ln,
                            "message": "no code at this line" if syms else "no debug info (give \"sld\")"})
                continue
            n, msg = results[k] if k < len(results) else (None, "not attached")
            k += 1
            bp = {"verified": n is not None, "line": hit[2], "instructionReference": "0x%04X" % hit[0]}
            if n is not None:
                bp["id"] = n + 1
            else:
                bp["message"] = msg
            out.append(bp)
        self.respond(req, {"breakpoints": out})

    def req_setInstructionBreakpoints(self, req, args):
        wanted = []
        for b in args.get("breakpoints", []):
            addr = int(b["instructionReference"], 0) + int(b.get("offset", 0))
            wanted.append((addr & 0xFFFF, None))
        results = self.session.set_breakpoints(self.owner, "instr", wanted)
        out = []
        for (addr, _), (n, msg) in zip(wanted, results):
            bp = {"verified": n is not None, "instructionReference": "0x%04X" % addr}
            if n is not None:
                bp["id"] = n + 1
            else:
                bp["message"] = msg
            out.append(bp)
        self.respond(req, {"breakpoints": out})

    def req_setExceptionBreakpoints(self, req, args):
        self.respond(req, {"breakpoints": []})

    def req_dataBreakpointInfo(self, req, args):
        name = args.get("name", "")
        size = int(args.get("bytes") or 1)
        try:
            if args.get("variablesReference") == REF_REGS:
                value = self.session.registers().get(name.upper())
                if value is None or name.upper() in ("I", "R", "IFF", "IM"):
                    raise BridgeError("not an address")
                addr, desc = value, "memory at %s (%04X)" % (name.upper(), value)
            else:
                _, addr, _ = self.session.parse_address(name)
                desc = "memory at %s" % self.session.format_address(addr)
            self.session.mask_for(size)
        except (BridgeError, ValueError) as e:
            self.respond(req, {"dataId": None, "description": str(e)})
            return
        if size > 1:
            desc += ", %d bytes" % size
        self.respond(req, {"dataId": "%04X/%d" % (addr & 0xFFFF, size), "description": desc,
                           "accessTypes": ["read", "write", "readWrite"], "canPersist": False})

    def req_setDataBreakpoints(self, req, args):
        kinds = {"read": P.WP_READ, "write": P.WP_WRITE, "readWrite": P.WP_READ | P.WP_WRITE}
        wanted = []
        for b in args.get("breakpoints", []):
            a, _, n = b["dataId"].partition("/")
            wanted.append((kinds.get(b.get("accessType", "write"), P.WP_WRITE), int(a, 16), self.session.mask_for(int(n or 1))))
        results = self.session.set_watchpoints(self.owner, "data", wanted)
        out = []
        for n, msg in results:
            bp = {"verified": n is not None}
            if n is not None:
                bp["id"] = 100 + n
            else:
                bp["message"] = msg
            out.append(bp)
        self.respond(req, {"breakpoints": out})

    # ------------------------------------------------------------ the watchpoint panel
    # Custom requests, as the zx extension's panel makes (its watchpoint_view.js):
    # what the board watches, whoever set it, and setting or clearing one by address.
    def _watchpoints_body(self):
        return {"watchpoints": self.session.list_watchpoints() if self.session.attached else []}

    def req_watchpoints(self, req, args):
        self.respond(req, self._watchpoints_body())

    def req_setWatchpoint(self, req, args):
        s = self.session
        space, addr, _ = s.parse_address(args.get("address", ""))
        if space:
            raise BridgeError("a watchpoint takes a CPU address or a port, not a physical address")
        length = int(args.get("length", 1))
        mask = s.mask_for(length)
        if addr & ~mask & 0xFFFF:
            raise BridgeError("a range of %d must start at a multiple of %d" % (length, length))
        kind = {"read": P.WP_READ, "write": P.WP_WRITE, "readWrite": P.WP_READ | P.WP_WRITE,
                "readwrite": P.WP_READ | P.WP_WRITE}.get(args.get("access", "write"))
        if kind is None:
            raise BridgeError("access is read, write or readWrite")
        if args.get("io"):
            kind |= P.WP_IO
        n, msg = s.set_watchpoints(self.owner, "panel:%04X/%d/%d" % (addr, length, kind), [(kind, addr, mask)])[0]
        if n is None:
            raise BridgeError(msg)
        self.respond(req, self._watchpoints_body())

    def req_clearWatchpoint(self, req, args):
        """One watchpoint by id, whoever set it (a person asked), or with no id all of them."""
        s = self.session
        ident = args.get("id")
        for sl in list(s.wps):
            if sl and ("id" not in args or str(sl.n) == str(ident)):
                for owner, tag in list(sl.owners):
                    s.set_watchpoints(owner, tag, [])
        self.respond(req, self._watchpoints_body())

    # ------------------------------------------------------------ running
    def req_threads(self, req, args):
        self.respond(req, {"threads": [{"id": THREAD, "name": "Z80"}]})

    def req_continue(self, req, args):
        self.session.cont(owner=self.owner)
        self.respond(req, {"allThreadsContinued": True})

    def _step(self, req, args, kind):
        gran = args.get("granularity", "statement")
        s = self.session
        s.require_stopped()
        self.respond(req)

        def work():
            try:
                s.step(kind, owner=self.owner, granularity="instruction" if gran == "instruction" else "line")
            except (BridgeError, P.LinkLost, P.Refused) as e:
                self.output("step: %s\n" % e)
                if s.last_stop is not None and not s.running:
                    self.send_stopped({"stop": s.last_stop, "owner": self.owner, "text": str(e)})
        self.step_thread = threading.Thread(target=work, daemon=True)
        self.step_thread.start()

    def req_next(self, req, args):
        self._step(req, args, "over")

    def req_stepIn(self, req, args):
        self._step(req, args, "into")

    def req_stepOut(self, req, args):
        self._step(req, args, "out")

    def req_pause(self, req, args):
        self.session.pause(owner=self.owner)
        self.respond(req)

    # ------------------------------------------------------------ views
    def req_stackTrace(self, req, args):
        s = self.session
        frames = s.call_stack()
        out = []
        for i, fr in enumerate(frames):
            pc = fr["pc"]
            sym = s.symbol_text(pc)
            name = sym or "%04X" % pc
            if i == 0 and s.last_stop is not None:
                name = "%s  %04X" % (sym, pc) if sym else "%04X" % pc
            f = {"id": i + 1, "name": name, "line": 0, "column": 0, "instructionPointerReference": "0x%04X" % pc}
            loc = s.symbols.location(pc) if s.symbols else None
            if loc and os.path.exists(loc[0]):
                f["source"] = {"name": os.path.basename(loc[0]), "path": loc[0]}
                f["line"] = loc[1]
                f["column"] = 1
            else:
                f["presentationHint"] = "subtle" if i else "normal"
            out.append(f)
        start = args.get("startFrame", 0)
        levels = args.get("levels") or len(out)
        self.respond(req, {"stackFrames": out[start:start + levels], "totalFrames": len(out)})

    def req_scopes(self, req, args):
        self.respond(req, {"scopes": [
            {"name": "Registers", "variablesReference": REF_REGS, "expensive": False, "presentationHint": "registers"},
            {"name": "Flags", "variablesReference": REF_FLAGS, "expensive": False},
            {"name": "MMU windows", "variablesReference": REF_MMU, "expensive": False},
        ]})

    def req_variables(self, req, args):
        ref = args.get("variablesReference")
        s = self.session
        out = []
        if ref == REF_REGS:
            regs = s.registers()
            for r in s.target.registers:
                v = regs[r.name]
                item = {"name": r.name, "value": ("%04X" % v if r.size == 2 else "%02X" % v), "variablesReference": 0}
                if r.size == 2:
                    item["memoryReference"] = "0x%04X" % v
                    sym = s.symbol_text(v) if r.name in ("PC", "SP", "HL", "DE", "BC", "IX", "IY") else None
                    if sym and r.name == "PC":
                        item["value"] += "  " + sym
                if r.name == "IM" and v == 0xFF:
                    item["value"] = "?"
                out.append(item)
        elif ref == REF_FLAGS:
            f = s.registers()["AF"] & 0xFF
            for name, on in s.flags(f).items():
                out.append({"name": name, "value": "1" if on else "0", "variablesReference": 0})
        elif ref == REF_MMU:
            for i, (rp, wp) in enumerate(s.mmu()):
                out.append({"name": "W%d %04X" % (i, i * 0x2000),
                            "value": "read %03X  write %03X" % (rp, wp), "variablesReference": 0})
        self.respond(req, {"variables": out})

    def req_setVariable(self, req, args):
        ref = args.get("variablesReference")
        s = self.session
        name, text = args["name"], str(args["value"]).strip()
        if ref == REF_REGS:
            value = s.eval_expression(text) if text not in ("?",) else 0xFF
            v = s.set_register(name, value)
            r = s.target.reg(name)
            self.respond(req, {"value": "%04X" % v if r and r.size == 2 else "%02X" % v})
        elif ref == REF_FLAGS:
            on = text.lower() in ("1", "true", "on", "yes")
            bit = dict(FLAG_BITS)[name]
            f = s.registers()["AF"] & 0xFF
            f = (f | (1 << bit)) if on else (f & ~(1 << bit))
            s.set_register("F", f)
            self.respond(req, {"value": "1" if on else "0"})
        else:
            raise BridgeError("not changeable here")

    def req_evaluate(self, req, args):
        s = self.session
        expr = args.get("expression", "").strip()
        ctx = args.get("context")
        if ctx == "repl" and expr and expr.split()[0].upper()[:1] in MONITOR_LETTERS and len(expr.split()[0]) == 1:
            out = s.monitor(expr)
            self.respond(req, {"result": out.rstrip("\r\n").replace("\r\n", "\n"), "variablesReference": 0})
            return
        name = expr.upper()
        regs = s.registers() if s.attached and not s.running else {}
        if name in regs:
            v = regs[name]
            self.respond(req, {"result": "%04X (%d)" % (v, v), "variablesReference": 0, "memoryReference": "0x%04X" % v})
            return
        space, addr, page = s.parse_address(expr)
        b = s.read_memory(addr, 2, space) if regs else [None, None]
        text = "%04X" % addr if space == 0 else "P%06X" % addr
        sym = s.symbol_text(addr) if space == 0 else None
        if sym and sym != expr:
            text += " (%s)" % sym
        if None not in b:
            text += "  byte %02X  word %04X" % (b[0], b[0] | (b[1] << 8))
        self.respond(req, {"result": text, "variablesReference": 0, "memoryReference": "0x%04X" % addr})

    # ------------------------------------------------------------ memory
    def req_readMemory(self, req, args):
        addr = int(args["memoryReference"], 0) + int(args.get("offset", 0))
        count = int(args.get("count", 0))
        if addr < 0 or addr > 0xFFFF:
            self.respond(req, {"address": "0x%04X" % (addr & 0xFFFFFFFF), "unreadableBytes": count})
            return
        n = min(count, 0x10000 - addr)
        data = self.session.read_memory(addr, n)
        good = 0
        while good < len(data) and data[good] is not None:
            good += 1
        body = {"address": "0x%04X" % addr, "data": base64.b64encode(bytes(data[:good])).decode("ascii")}
        if good < count:
            body["unreadableBytes"] = count - good
        self.respond(req, body)

    def req_writeMemory(self, req, args):
        addr = int(args["memoryReference"], 0) + int(args.get("offset", 0))
        data = base64.b64decode(args.get("data", ""))
        self.session.write_memory(addr, data)
        self.respond(req, {"bytesWritten": len(data)})

    def req_disassemble(self, req, args):
        s = self.session
        base = int(args["memoryReference"], 0) + int(args.get("offset", 0))
        ioff = int(args.get("instructionOffset", 0))
        count = int(args["instructionCount"])
        before = []
        if ioff < 0:
            k = -ioff
            start = max(0, base - 4 * k - 8)
            if start < base:
                run = s.disassemble(start, 4 * k + 8)
                before = [i for i in run if i[0] < base]
                # an instruction that runs into base: drop it and pad
                before = [i for i in before if i[0] + len(i[1]) <= base]
            before = before[-k:]
            pad = k - len(before)
            insts = [None] * pad + before
            rest = count - k
        else:
            insts = []
            rest = count
        start = base
        if ioff > 0:
            skip = s.disassemble(base, ioff) if base <= 0xFFFF else []
            start = (skip[-1][0] + len(skip[-1][1])) if skip else base
        if rest > 0:
            if start <= 0xFFFF:
                fwd = s.disassemble(start, rest)
                last = start
                for i in fwd:
                    if i[0] < last:     # wrapped past 0xFFFF
                        break
                    insts.append(i)
                    last = i[0]
            insts += [None] * (count - len(insts))
        out = []
        for i in insts[:count]:
            if i is None:
                out.append({"address": "0x0000", "instruction": "", "presentationHint": "invalid"})
                continue
            addr, raw, text = i
            item = {"address": "0x%04X" % addr, "instructionBytes": " ".join("%02X" % b for b in raw), "instruction": text}
            sym = s.symbols.symbol_at(addr) if s.symbols else None
            if sym and sym[1] == 0:
                item["symbol"] = sym[0]
            loc = s.symbols.location(addr) if s.symbols else None
            if loc:
                item["location"] = {"name": os.path.basename(loc[0]), "path": loc[0]}
                item["line"] = loc[1]
            out.append(item)
        self.respond(req, {"instructions": out})


class DapServer(threading.Thread):
    def __init__(self, session, port=4780, host="127.0.0.1"):
        super().__init__(daemon=True)
        self.session = session
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind((host, port))
        self.sock.listen(4)
        self.port = self.sock.getsockname()[1]

    def run(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            DapConnection(self, conn).start()

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass
