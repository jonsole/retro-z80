"""The bridge's MCP server (debug.md, section 3.7): streamable HTTP at
http://127.0.0.1:8780/mcp, tools only.

Tool names and arguments are the zx emulator's (its docs/mcp.md and
cpp-core/src/mcp_server.cpp) where they mean the same, so a client that
knows the emulator knows these; retro-z80 adds launch, attach, detach,
reset, get_mmu, monitor and the console tools. JSON-RPC by POST, answered
as application/json; GET is refused with 405, as the spec allows, since
the server never starts a message.
"""

import base64
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import rlink  # noqa: E402
from rz80bridge import protocol as P  # noqa: E402
from rz80bridge.session import BridgeError, FLAG_BITS, HALVES  # noqa: E402
from rz80bridge.sld import Symbols  # noqa: E402
from rz80bridge import screen  # noqa: E402

PROTOCOL_VERSION = "2025-06-18"
SERVER_NAME = "retro-z80"
OWNER = "mcp"
RUN_WAIT = 30.0

INSTRUCTIONS = (
    "The real retro-z80 board (a Z80 in a ZX Spectrum Next's FPGA) over its USB serial link, shared with a VS Code "
    "debugger: there are no sessions to create, and a person may be watching. Nothing stops the board until you "
    "ask: launch uploads a program and stops at its entry; attach stops the running program where it is; detach "
    "lets it go. Stopped, read and change it: get_state, get_registers, read_memory, get_mmu, monitor (a monitor "
    "command line). To run: set_breakpoint or set_watchpoint, then run (blocks until it stops; wait false leaves it "
    "running), step, pause. The board has 4 hardware breakpoints and 2 watchpoints, shared with VS Code: a fifth is "
    "refused. While not attached, send_console and read_console use the monitor's console. Addresses are numbers "
    "or strings: hex as $8000, 0x8000, &8000 or a bare 8000, symbols and expressions (\"loop+3\") once "
    "load_debug_info or launch has loaded an SLD file, P012000 for a physical address, and page:address "
    "(\"0A3:$4000\") for a breakpoint in a banked window. The board's HDMI picture, through a USB capture device: "
    "screen_capture (a frame) and screen_record (a few seconds), shared with VS Code's Board Screen tab. Keys: "
    "key_down, key_up and type_text go in as a PS/2 keyboard's bytes (in hardware, attached or not), so the "
    "ROM, programs and Spectrum-style games all see them."
)

ADDRESS = {"description": "A number, or a string: $8000, 0x8000, 8000 (hex), a symbol expression such as loop+3, "
                          "or P012000 for a physical address", "type": ["integer", "string"]}


def tool(name, description, properties=None, required=()):
    return {"name": name, "description": description,
            "inputSchema": {"type": "object", "properties": properties or {}, "required": list(required)}}


TOOLS = [
    tool("launch", "Upload a program (an image file with the RIMG header, or a raw binary with load) and attach, "
         "stopped at its entry. Ends any session under way; the board is reset by the upload.",
         {"program": {"type": "string", "description": "Path of a .rimg image, or a raw binary"},
          "sld": {"type": "string", "description": "sjasmplus --sld file for symbols and source lines"},
          "load": ADDRESS, "entry": ADDRESS,
          "stop_on_entry": {"type": "boolean", "description": "Default true; false runs it at once"}},
         ["program"]),
    tool("attach", "Stop the running program where it is (BREAK) and attach. Already attached: the current stop."),
    tool("detach", "Leave debug mode: every breakpoint and watchpoint cleared, the console back.",
         {"run": {"type": "boolean", "description": "true: the program goes on; false (default): it stays stopped at the monitor"}}),
    tool("reset", "Reset the board (the RESET control command). Ends any session."),
    tool("get_state", "Attached or not, running or stopped, the last stop (reason, PC, the access for a watchpoint), "
         "breakpoints and watchpoints with who set them, and the call stack when stopped."),
    tool("get_registers", "The registers, as hex: PC with its symbol, the flags spelled out (SZ5H3PNC, - for clear), "
         "the instruction at PC. raw: every register as a number.",
         {"raw": {"type": "boolean"}}),
    tool("set_registers", "Set registers by name, the rest unchanged: pc, sp, af, bc, de, hl, ix, iy, af_, bc_, de_, hl_, "
         "a, f, b, c, d, e, h, l (and a_ ... l_), ixh, ixl, iyh, iyl, i, r, im, iff1, iff2. 16-bit ones take an address "
         "expression too.",
         {k: {"type": ["integer", "string", "boolean"]} for k in
          ("pc", "sp", "af", "bc", "de", "hl", "ix", "iy", "af_", "bc_", "de_", "hl_", "a", "f", "b", "c", "d", "e",
           "h", "l", "a_", "f_", "b_", "c_", "d_", "e_", "h_", "l_", "ixh", "ixl", "iyh", "iyl", "i", "r", "im",
           "iff1", "iff2")}),
    tool("read_memory", "Read memory as the stopped program sees it (or a physical address with P). Registers whose "
         "reads have side effects read FF unless side_effects is true.",
         {"address": ADDRESS, "length": {"type": "integer", "description": "1-65536, default 1"},
          "side_effects": {"type": "boolean"}}, ["address"]),
    tool("write_memory", "Write memory: data as hex (\"3E 41 C9\") or an array of numbers.",
         {"address": ADDRESS, "data": {"type": ["string", "array"]}}, ["address", "data"]),
    tool("get_mmu", "The eight 8 KB windows: each one's read page and write page."),
    tool("set_breakpoint", "A hardware breakpoint at an address (works in ROM). 4 in all, shared with VS Code.",
         {"address": ADDRESS, "page": {"type": ["integer", "string"],
                                       "description": "Only when this MMU page is in the address's window"}},
         ["address"]),
    tool("clear_breakpoint", "Remove MCP's breakpoint at an address; with no address, all of MCP's.",
         {"address": ADDRESS}),
    tool("list_breakpoints", "Every breakpoint, VS Code's too, with its symbol and who set it."),
    tool("set_watchpoint", "Stop when the program reads or writes an address or a range (or an I/O port with io). "
         "length is a power of two, the range aligned to it (the hardware compares under a mask). 2 in all, shared "
         "with VS Code. The stop's PC is after the instruction that made the access.",
         {"address": ADDRESS, "length": {"type": "integer"},
          "access": {"type": "string", "enum": ["read", "write", "readwrite"]},
          "io": {"type": "boolean"}}, ["address"]),
    tool("clear_watchpoint", "Remove one of MCP's watchpoints by id; with no id, all of MCP's.",
         {"id": {"type": "integer"}}),
    tool("list_watchpoints", "Every watchpoint, with its range, access and who set it."),
    tool("step", "Run N instructions (default 1), or over or out of a call: mode into (default), over, out.",
         {"instructions": {"type": "integer"}, "mode": {"type": "string", "enum": ["into", "over", "out"]}}),
    tool("run", "Run until a breakpoint, a watchpoint, a break or the end, and say where it stopped. "
         "wait false: return at once and leave it running (pause or get_state later).",
         {"wait": {"type": "boolean"}, "timeout_ms": {"type": "integer", "description": "Default 30000"}}),
    tool("pause", "Stop the running program (BREAK)."),
    tool("load_debug_info", "Load an sjasmplus SLD file for symbols and source lines.",
         {"sld_path": {"type": "string"}, "asm_path": {"type": "string"}}, ["sld_path"]),
    tool("resolve_symbol", "A symbol (or an expression) to its address.", {"name": {"type": "string"}}, ["name"]),
    tool("resolve_address", "An address to the nearest symbol and offset, and its source line.",
         {"address": ADDRESS}, ["address"]),
    tool("monitor", "Run a monitor command line on the stopped program (D, E, F, C, V, S, R, P, I ...). "
         "Commands that run code or leave the monitor are refused: use run, step, detach.",
         {"command": {"type": "string"}}, ["command"]),
    tool("send_console", "Type into the monitor's console while not attached. A newline is sent as Enter.",
         {"text": {"type": "string"}}, ["text"]),
    tool("read_console", "The console's output: lines from number since (omit for the latest), and the line "
         "being written. Returns next, the number to pass as since next time.",
         {"since": {"type": "integer"}, "max": {"type": "integer"}}),
    tool("screen_capture", "The board's HDMI output now, as a JPEG image (from a USB capture device, the same "
         "picture VS Code's Board Screen view shows). save: also write it to this path.",
         {"save": {"type": "string", "description": "A path for the JPEG"}}),
    tool("screen_record", "Record the board's HDMI output for some seconds and return a few frames spread over it "
         "as images, each with its time, to see motion or a change. save keeps the whole sequence: a .mjpeg, "
         ".avi or .mkv (the frames as they came), .mp4 or .gif (re-encoded), or a folder (numbered JPEGs).",
         {"seconds": {"type": "number", "description": "0.1-30, default 2"},
          "frames": {"type": "integer", "description": "How many frames to return as images, 1-16, default 6"},
          "save": {"type": "string", "description": "A path for the whole sequence"}}),
    tool("key_down", "Press a key on the board's keyboard (as a PS/2 keyboard sends it) and hold it until key_up. "
         "key: a name (A, 5, ENTER, SPACE, SHIFT, CTRL, ALT, ESC, BACKSPACE, TAB, UP, DOWN, LEFT, RIGHT, F1-F12, "
         "HOME, DELETE, punctuation such as , . ;) or a KeyboardEvent.code (KeyA, ShiftLeft, ArrowUp). Port 0xFE "
         "sees it as the Spectrum key it maps to (SHIFT is CAPS SHIFT, CTRL is SYMBOL SHIFT).",
         {"key": {"type": "string"}}, ["key"]),
    tool("key_up", "Let a key go; with no key, every key held down.", {"key": {"type": "string"}}),
    tool("type_text", "Type text on the board's keyboard, a US layout, each key held hold_ms (default 40, long "
         "enough for a program that reads the keys once a frame) with gap_ms (default 20) between. \\n is Enter.",
         {"text": {"type": "string"}, "hold_ms": {"type": "integer"}, "gap_ms": {"type": "integer"}}, ["text"]),
    tool("server_info", "Which bridge this is: pid, version, ports, serial port, start time, the program last "
         "launched, the advert file."),
]


def text_result(text):
    return {"content": [{"type": "text", "text": text}]}


def json_result(value):
    return text_result(json.dumps(value))


def held_text(session):
    return "; held: %s" % ", ".join(sorted(session.held_keys)) if session.held_keys else ""


def image_content(jpeg):
    return {"type": "image", "data": base64.b64encode(jpeg).decode("ascii"), "mimeType": "image/jpeg"}


def error_result(text):
    r = text_result(text)
    r["isError"] = True
    return r


class Tools:
    def __init__(self, session, bridge=None):
        self.s = session
        self.bridge = bridge

    # ------------------------------------------------------------ helpers
    def addr(self, args, key="address"):
        if key not in args:
            raise BridgeError("'%s' is required" % key)
        return self.s.parse_address(args[key])

    def readable_registers(self):
        s = self.s
        regs = s.registers()
        out = {}
        for r in s.target.registers:
            v = regs[r.name]
            out[r.name] = ("%04X" if r.size == 2 else "%02X") % v
        out["PC"] = "$%04X" % regs["PC"] + (" (%s)" % s.symbol_text(regs["PC"]) if s.symbol_text(regs["PC"]) else "")
        f = regs["AF"] & 0xFF
        out["flags"] = "".join(n[0] if f >> b & 1 else "-" for n, b in FLAG_BITS)
        if regs["IM"] == 0xFF:
            out["IM"] = "?"
        out["IFF"] = "IFF1=%d IFF2=%d" % (regs["IFF"] & 1, regs["IFF"] >> 1 & 1)
        out["instruction"] = s.disassemble(regs["PC"], 1)[0][2]
        return out

    def stop_text(self, stop):
        if stop is None:
            return "no stop came back"
        return self.s.describe_stop(stop)

    def wait_for_stop(self, count, timeout):
        return self.s._wait_stop(count, timeout)

    # ------------------------------------------------------------ the tools
    def call(self, name, args):
        fn = getattr(self, "t_" + name, None)
        if fn is None:
            return error_result("unknown tool: %s" % name)
        try:
            return fn(args)
        except BridgeError as e:
            return error_result(str(e))
        except (P.Refused, P.LinkLost, rlink.LinkError, rlink.Refused) as e:
            return error_result(str(e))
        except (screen.ScreenError, OSError) as e:
            return error_result(str(e))
        except (ValueError, KeyError, TypeError) as e:
            return error_result("bad arguments: %s" % e)

    def t_launch(self, a):
        from rz80bridge.dap import load_program
        cwd = os.getcwd()
        args = {"program": a["program"]}
        for k in ("load", "entry"):
            if k in a:
                args[k] = a[k] if isinstance(a[k], int) else "%X" % self.s.parse_address(a[k])[1]
        img = load_program(args, cwd)
        syms = Symbols.load(a["sld"]) if a.get("sld") else None
        stop = self.s.launch(img, owner=OWNER, symbols=syms)
        if a.get("stop_on_entry", True) is False:
            self.s.cont(owner=OWNER)
            return text_result("Uploaded %s; running" % img.describe())
        return text_result("Uploaded %s. %s" % (img.describe(), self.stop_text(stop)))

    def t_attach(self, a):
        return text_result(self.stop_text(self.s.attach(owner=OWNER)))

    def t_detach(self, a):
        if not self.s.attached:
            return text_result("not attached")
        run = bool(a.get("run", False))
        self.s.detach(run=run, owner=OWNER)
        return text_result("detached; the program %s" % ("runs on" if run else "stays stopped at the monitor"))

    def t_reset(self, a):
        self.s.reset()
        return text_result("RESET sent")

    def t_get_state(self, a):
        st = self.s.state()
        if self.s.attached and not self.s.running:
            frames = self.s.call_stack()
            st["call_stack"] = [{"pc": "%04X" % f["pc"], "symbol": self.s.symbol_text(f["pc"])} for f in frames]
        return json_result(st)

    def t_get_registers(self, a):
        if a.get("raw"):
            return json_result(self.s.registers())
        return json_result(self.readable_registers())

    def t_set_registers(self, a):
        s = self.s
        s.require_stopped()
        order = ["pc", "sp", "af", "bc", "de", "hl", "ix", "iy", "af_", "bc_", "de_", "hl_"] + \
                [k for k in a if k not in ("pc", "sp", "af", "bc", "de", "hl", "ix", "iy", "af_", "bc_", "de_", "hl_")]
        done = []
        for key in order:
            if key not in a:
                continue
            v = a[key]
            name = key.upper().replace("_", "'")
            if isinstance(v, bool):
                v = int(v)
            if key in ("iff1", "iff2"):
                cur = s.registers()["IFF"]
                bit = 1 if key == "iff1" else 2
                s.set_register("IFF", (cur | bit) if v else (cur & ~bit))
                done.append(key)
                continue
            if isinstance(v, str):
                v = s.parse_address(v)[1]
            if name not in HALVES and s.target.reg(name) is None:
                raise BridgeError("no register %s" % key)
            s.set_register(name, int(v))
            done.append(key)
        return json_result(self.readable_registers())

    def t_read_memory(self, a):
        space, addr, _ = self.addr(a)
        length = int(a.get("length", 1))
        if not 0 <= length <= 0x10000:
            raise BridgeError("'length' must be between 0 and 65536")
        data = self.s.read_memory(addr, length, space, bool(a.get("side_effects")))
        hexs = " ".join("??" if b is None else "%02X" % b for b in data)
        out = {"address": ("P%06X" if space else "%04X") % addr, "hex": hexs}
        if None in data:
            out["note"] = "?? bytes are not allowed (the stub's own page, or past the end)"
        return json_result(out)

    def t_write_memory(self, a):
        space, addr, _ = self.addr(a)
        d = a.get("data")
        if isinstance(d, str):
            digits = d.replace(" ", "").replace(",", "")
            if len(digits) % 2:
                raise BridgeError("'data' as hex needs an even number of digits")
            data = bytes.fromhex(digits)
        elif isinstance(d, list):
            if any(not isinstance(b, int) or not 0 <= b <= 255 for b in d):
                raise BridgeError("'data' as an array must hold numbers 0-255")
            data = bytes(d)
        else:
            raise BridgeError("'data' is required: hex (\"3E 41 C9\") or an array of numbers")
        self.s.write_memory(addr, data, space)
        return text_result("wrote %d byte%s at %s" % (len(data), "" if len(data) == 1 else "s",
                                                      ("P%06X" if space else "%04X") % addr))

    def t_get_mmu(self, a):
        return json_result([{"window": i, "addresses": "%04X-%04X" % (i * 0x2000, i * 0x2000 + 0x1FFF),
                             "read_page": "%03X" % r, "write_page": "%03X" % w}
                            for i, (r, w) in enumerate(self.s.mmu())])

    def t_set_breakpoint(self, a):
        space, addr, page = self.addr(a)
        if space:
            raise BridgeError("a breakpoint takes a CPU address (and a page), not a physical one")
        if a.get("page") is not None:
            page = a["page"] if isinstance(a["page"], int) else self.s.parse_number(str(a["page"]))
        n = self.s.add_breakpoint(OWNER, addr, page)
        return text_result("breakpoint %d at %s%s" % (n, self.s.format_address(addr),
                                                     " in page %03X" % page if page is not None else ""))

    def t_clear_breakpoint(self, a):
        s = self.s
        if a.get("address") is None:
            for tag in {t for sl in s.bps if sl for o, t in sl.owners if o == OWNER}:
                s.set_breakpoints(OWNER, tag, [])
            return text_result("MCP's breakpoints cleared")
        _, addr, page = self.addr(a)
        if not s.remove_breakpoint(OWNER, addr, page):
            return error_result("MCP has no breakpoint at %04X" % addr)
        return text_result("cleared")

    def t_list_breakpoints(self, a):
        bps = self.s.list_breakpoints()
        for b in bps:
            b["address"] = "%04X" % b["address"]
            if b["page"] is not None:
                b["page"] = "%03X" % b["page"]
        return json_result(bps)

    def t_set_watchpoint(self, a):
        space, addr, _ = self.addr(a)
        for unsupported in ("on_change", "value", "not_value"):
            if a.get(unsupported) is not None:
                raise BridgeError("'%s' is not offered: the hardware compares addresses only" % unsupported)
        length = int(a.get("length", 1))
        mask = self.s.mask_for(length)
        if addr & ~mask & 0xFFFF:
            raise BridgeError("the range must be aligned to its length (%d)" % length)
        kind = {"read": P.WP_READ, "write": P.WP_WRITE, "readwrite": P.WP_READ | P.WP_WRITE}.get(
            a.get("access", "write"))
        if kind is None:
            raise BridgeError("'access' is read, write or readwrite")
        if a.get("io"):
            kind |= P.WP_IO
        tag = "wp:%04X/%d/%d" % (addr, length, kind)
        n, msg = self.s.set_watchpoints(OWNER, tag, [(kind, addr, mask)])[0]
        if n is None:
            raise BridgeError(msg)
        return json_result({"id": n, "address": "%04X" % addr, "length": length, "access": a.get("access", "write"),
                            "io": bool(a.get("io"))})

    def t_clear_watchpoint(self, a):
        s = self.s
        ident = a.get("id")
        tags = {t for sl in s.wps if sl and (ident is None or sl.n == ident) for o, t in sl.owners if o == OWNER}
        if ident is not None and not tags:
            return error_result("MCP has no watchpoint %d" % ident)
        for t in tags:
            s.set_watchpoints(OWNER, t, [])
        return text_result("cleared")

    def t_list_watchpoints(self, a):
        wps = self.s.list_watchpoints()
        for w in wps:
            w["address"] = "%04X" % w["address"]
            w["mask"] = "%04X" % w["mask"]
        return json_result(wps)

    def t_step(self, a):
        n = int(a.get("instructions", 1))
        if not 1 <= n <= 10000:
            raise BridgeError("'instructions' is 1 to 10000")
        stop = self.s.step(a.get("mode", "into"), owner=OWNER, granularity="instruction", count=n)
        return json_result({"stop": self.stop_text(stop), "registers": self.readable_registers()})

    def t_run(self, a):
        s = self.s
        count = s.stop_count
        s.cont(owner=OWNER)
        if a.get("wait", True) is False:
            return text_result("running")
        timeout = int(a.get("timeout_ms", RUN_WAIT * 1000)) / 1000.0
        stop = self.wait_for_stop(count, timeout)
        if stop is None:
            return text_result("still running after %g s (pause, or get_state later)" % timeout)
        return text_result(self.stop_text(stop))

    def t_pause(self, a):
        s = self.s
        if not s.running:
            return text_result("not running" if s.attached else "not attached")
        count = s.stop_count
        s.pause(owner=OWNER)
        stop = self.wait_for_stop(count, 3.0)
        return text_result(self.stop_text(stop))

    def t_load_debug_info(self, a):
        syms = Symbols.load(a["sld_path"])
        self.s.symbols = syms
        return text_result("%d symbols, %d source lines in %d file%s" % (
            len(syms.symbols), len(syms.addr_to_loc), len(syms.files), "" if len(syms.files) == 1 else "s"))

    def t_resolve_symbol(self, a):
        v = self.s.eval_expression(a["name"])
        return json_result({"name": a["name"], "address": "%04X" % (v & 0xFFFF)})

    def t_resolve_address(self, a):
        space, addr, _ = self.addr(a)
        out = {"address": "%04X" % addr, "symbol": self.s.symbol_text(addr)}
        loc = self.s.symbols.location_within(addr) if self.s.symbols else None
        if loc:
            out["source"] = {"path": loc[0], "line": loc[1]}
        return json_result(out)

    def t_monitor(self, a):
        return text_result(self.s.monitor(a["command"]).replace("\r\n", "\n"))

    def t_send_console(self, a):
        text = a["text"]
        self.s.send_console(text)
        return text_result("sent %d character%s" % (len(text), "" if len(text) == 1 else "s"))

    def t_read_console(self, a):
        lines, nxt, partial = self.s.console.read(a.get("since"), int(a.get("max", 200)))
        return json_result({"lines": lines, "next": nxt, "partial": partial})

    def t_screen_capture(self, a):
        jpeg, source = screen.capture()
        if a.get("save"):
            with open(a["save"], "wb") as f:
                f.write(jpeg)
        size = screen.jpeg_size(jpeg)
        text = "%s, from %s%s" % ("%dx%d" % size if size else "a frame", source,
                                  ", saved to %s" % a["save"] if a.get("save") else "")
        return {"content": [image_content(jpeg), {"type": "text", "text": text}]}

    def t_screen_record(self, a):
        seconds = min(30.0, max(0.1, float(a.get("seconds", 2))))
        want = min(16, max(1, int(a.get("frames", 6))))
        frames, fps, source = screen.record(seconds)
        if not frames:
            return error_result("no frames in %g s" % seconds)
        if a.get("save"):
            screen.save_sequence(frames, fps, a["save"])
        picks = sorted({round(i * (len(frames) - 1) / max(1, want - 1)) for i in range(want)}) if want > 1 else [0]
        content = []
        for i in picks:
            content.append({"type": "text", "text": "frame %d, t=%.3f s" % (i, frames[i][0])})
            content.append(image_content(frames[i][1]))
        distinct = len({f for _, f in frames})
        size = screen.jpeg_size(frames[0][1])
        content.append({"type": "text", "text": "%d frames in %g s (%.1f fps, %d byte-distinct), %s, from %s%s" % (
            len(frames), seconds, fps, distinct, "%dx%d" % size if size else "?", source,
            ", saved to %s" % a["save"] if a.get("save") else "")})
        return {"content": content}

    def t_key_down(self, a):
        code = self.s.key_down(a["key"])
        return text_result("%s down%s" % (code, held_text(self.s)))

    def t_key_up(self, a):
        codes = self.s.key_up(a.get("key"))
        return text_result("%s up%s" % (", ".join(codes) or "nothing held, nothing", held_text(self.s)))

    def t_type_text(self, a):
        n = self.s.type_text(a["text"], int(a.get("hold_ms", 40)) / 1000.0, int(a.get("gap_ms", 20)) / 1000.0)
        return text_result("typed %d character%s" % (n, "" if n == 1 else "s"))

    def t_server_info(self, a):
        b = self.bridge
        info = {"pid": os.getpid(), "name": SERVER_NAME, "serialPort": self.s.serial_name,
                "attached": self.s.attached, "program": getattr(self.s, "program_path", None)}
        if b is not None:
            from rz80bridge.bridge import VERSION
            info.update({"serverVersion": VERSION, "ports": b.ports,
                         "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(b.started)),
                         "advert": b.advert.path if b.advert else None})
        return json_result(info)


class McpServer(threading.Thread):
    def __init__(self, session, port=8780, host="127.0.0.1", bridge=None):
        super().__init__(daemon=True)
        self.tools = Tools(session, bridge)
        self.log = session.log
        tools = self.tools

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *a):
                pass

            def _send(self, status, body=None):
                data = json.dumps(body).encode() if body is not None else b""
                self.send_response(status)
                if body is not None:
                    self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                self._send(405 if self.path.split("?")[0] == "/mcp" else 404, {"error": "method not allowed"})

            def do_DELETE(self):
                self._send(202 if self.path.split("?")[0] == "/mcp" else 404)

            def do_POST(self):
                if self.path.split("?")[0] != "/mcp":
                    return self._send(404, {"error": "not found; MCP is served at /mcp"})
                n = int(self.headers.get("Content-Length") or 0)
                try:
                    msg = json.loads(self.rfile.read(n) or b"null")
                except ValueError:
                    return self._send(400, rpc_error(None, -32700, "invalid JSON"))
                if isinstance(msg, list):
                    replies = [r for r in (handle(tools, m) for m in msg) if r is not None]
                    return self._send(200, replies) if replies else self._send(202)
                reply = handle(tools, msg)
                if reply is None:
                    return self._send(202)
                self._send(200, reply)

        self.httpd = ThreadingHTTPServer((host, port), Handler)
        self.httpd.daemon_threads = True
        self.port = self.httpd.server_address[1]

    def run(self):
        self.httpd.serve_forever(poll_interval=0.2)

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


def rpc_error(ident, code, message):
    return {"jsonrpc": "2.0", "id": ident, "error": {"code": code, "message": message}}


def handle(tools, msg):
    """One JSON-RPC message -> its reply, or None for a notification."""
    if not isinstance(msg, dict) or not msg.get("method"):
        return rpc_error(msg.get("id") if isinstance(msg, dict) else None, -32600, "missing 'method'")
    if "id" not in msg:
        return None
    ident, method = msg["id"], msg["method"]
    params = msg.get("params") if isinstance(msg.get("params"), dict) else {}
    ok = lambda result: {"jsonrpc": "2.0", "id": ident, "result": result}
    if method == "initialize":
        from rz80bridge.bridge import VERSION
        return ok({"protocolVersion": PROTOCOL_VERSION,
                   "capabilities": {"tools": {"listChanged": False}},
                   "serverInfo": {"name": SERVER_NAME, "version": VERSION},
                   "instructions": INSTRUCTIONS})
    if method == "ping":
        return ok({})
    if method == "tools/list":
        return ok({"tools": TOOLS})
    if method == "tools/call":
        name = params.get("name")
        if not isinstance(name, str):
            return rpc_error(ident, -32602, "missing tool 'name'")
        args = params.get("arguments") if isinstance(params.get("arguments"), dict) else {}
        detail = next((" %s" % args[k] for k in ("address", "program", "command", "name", "save", "key", "text") if k in args), "")
        tools.s.log("MCP  %s%s" % (name, detail))
        return ok(tools.call(name, args))
    return rpc_error(ident, -32601, "unknown method: %s" % method)
