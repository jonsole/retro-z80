#!/usr/bin/env python3
"""Tests of the debug bridge (docs/spec/debug.md, section 11), with no
hardware: the transport, the debug channel against the stub model, and
whole DAP sessions over TCP, as VS Code would hold them.

    python3 tools/test/test_bridge.py          (or: python3 -m unittest)
"""

import base64
import json
import os
import queue
import shutil
import socket
import struct
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import rlink  # noqa: E402
from rz80bridge import protocol as P  # noqa: E402
from rz80bridge.bridge import Bridge  # noqa: E402
from rz80bridge.model import ModelLink, StubModel  # noqa: E402
from rz80bridge import ps2keys  # noqa: E402
from rz80bridge.session import Session  # noqa: E402
from rz80bridge.sld import Symbols  # noqa: E402

# ---------------------------------------------------------------- the test program
# (line, label, text, bytes): assembled by hand, laid out as sjasmplus would.
PROGRAM = [
    (1, None, "; test program for the bridge", b""),
    (2, None, "        org 0x8000", b""),
    (3, "start", "start:  ld a,0x41", b"\x3e\x41"),
    (4, None, "        call add2", b"\xcd\x14\x80"),
    (5, None, "        ld (0x9000),a", b"\x32\x00\x90"),
    (6, None, "        out (0x53),a        ; SERDATA: straight to the link", b"\xd3\x53"),
    (7, None, "        ld b,3", b"\x06\x03"),
    (8, "loop", "loop:   rst 0x08", b"\xcf"),
    (9, None, "        djnz loop", b"\x10\xfd"),
    (10, None, "        ld hl,msg", b"\x21\x1b\x80"),
    (11, None, "        rst 0x18", b"\xdf"),
    (12, None, "        ret", b"\xc9"),
    (13, None, "", b""),
    (14, "add2", "add2:   inc a", b"\x3c"),
    (15, None, "        call add1", b"\xcd\x19\x80"),
    (16, None, "        ret", b"\xc9"),
    (17, "add1", "add1:   inc a", b"\x3c"),
    (18, None, "        ret", b"\xc9"),
    (19, "msg", "msg:    db \"hi\",13,10,0", b"hi\r\n\x00"),
]
ORG = 0x8000


def build_program(directory):
    """Writes test.asm, test.bin, test.sld and test.rimg. Returns their paths."""
    asm, sld, binary = [], ["|SLD.data.version|1"], bytearray()
    addr = ORG
    for line, label, text, code in PROGRAM:
        asm.append(text)
        if label:
            sld.append("test.asm|%d||0|-1|%d|F|%s" % (line, addr, label))
            sld.append("test.asm|%d||0|-1|%d|L|,%s," % (line, addr, label))
        if code:
            sld.append("test.asm|%d||0|-1|%d|T|" % (line, addr))
            binary += code
            addr += len(code)
    sld.append("test.asm|5||0|-1|36864|D|result")
    paths = {k: os.path.join(directory, "test." + k) for k in ("asm", "bin", "sld", "rimg")}
    with open(paths["asm"], "w") as f:
        f.write("\n".join(asm) + "\n")
    with open(paths["sld"], "w") as f:
        f.write("\n".join(sld) + "\n")
    with open(paths["bin"], "wb") as f:
        f.write(binary)
    with open(paths["rimg"], "wb") as f:
        f.write(rlink.Image(bytes(binary), "z80", ORG).file_bytes())
    return paths


def line_addr(n):
    addr = ORG
    for line, _, _, code in PROGRAM:
        if line == n:
            return addr
        addr += len(code)


# ---------------------------------------------------------------- a DAP client
class DapClient:
    def __init__(self, port):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=10)
        self.seq = 0
        self.responses = {}
        self.events = queue.Queue()
        self.cond = threading.Condition()
        self.buf = b""
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        while True:
            try:
                data = self.sock.recv(65536)
            except OSError:
                return
            if not data:
                return
            self.buf += data
            while True:
                end = self.buf.find(b"\r\n\r\n")
                if end < 0:
                    break
                n = int(self.buf[:end].split(b":")[1])
                if len(self.buf) < end + 4 + n:
                    break
                msg = json.loads(self.buf[end + 4:end + 4 + n])
                self.buf = self.buf[end + 4 + n:]
                if msg["type"] == "response":
                    with self.cond:
                        self.responses[msg["request_seq"]] = msg
                        self.cond.notify_all()
                else:
                    self.events.put(msg)

    def request(self, command, args=None, ok=True, timeout=10):
        self.seq += 1
        seq = self.seq
        msg = {"seq": seq, "type": "request", "command": command, "arguments": args or {}}
        body = json.dumps(msg).encode()
        self.sock.sendall(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        deadline = time.time() + timeout
        with self.cond:
            while seq not in self.responses:
                left = deadline - time.time()
                if left <= 0:
                    raise AssertionError("no response to %s" % command)
                self.cond.wait(left)
            r = self.responses.pop(seq)
        if ok and not r["success"]:
            raise AssertionError("%s failed: %s" % (command, r.get("message")))
        return r

    def event(self, name, timeout=5):
        deadline = time.time() + timeout
        while True:
            left = deadline - time.time()
            if left <= 0:
                raise AssertionError("no %s event" % name)
            ev = self.events.get(timeout=left)
            if ev["event"] == name:
                return ev

    def drain(self):
        time.sleep(0.05)
        out = []
        while not self.events.empty():
            out.append(self.events.get())
        return out

    def close(self):
        self.sock.close()


# ---------------------------------------------------------------- transport
class TransportTests(unittest.TestCase):
    def test_crc_check_value(self):
        self.assertEqual(rlink.crc32(b"123456789"), 0xCBF43926)

    def test_frame_layout(self):
        f = rlink.transport_frame(0x14, 7, P.CH_DEBUG, b"\x01\x02\x03")
        self.assertEqual(f[:2], b"LF")
        self.assertEqual(f[2:12], bytes([0x14, 7, 1, 0, 0, 0, 0, 3, 0xFF, 0xFC]))
        self.assertEqual(struct.unpack(">I", f[-4:])[0], rlink.crc32(f[2:-4]))

    def test_both_ways_among_stray_bytes(self):
        p = rlink.FrameParser(syncs=(rlink.SYNC_PC, rlink.SYNC_MACHINE))
        a = rlink.transport_frame(0x80, 1, 1, b"K\x00hello", sync=b"LD")
        b = rlink.transport_frame(0x12, 2, 1, b"")
        items = p.feed(b"noise L" + a + b"Lx" + b, now=0)
        frames = [i for i in items if isinstance(i, rlink.Frame)]
        stray = b"".join(i for i in items if isinstance(i, bytes))
        self.assertEqual([(f.sync, f.type, f.seq, f.channel, f.error) for f in frames],
                         [(b"LD", 0x80, 1, 1, None), (b"LF", 0x12, 2, 1, None)])
        self.assertEqual(frames[0].payload, b"K\x00hello")
        self.assertEqual(stray, b"noise LLx")

    def test_cut_short_and_errors(self):
        p = rlink.FrameParser(syncs=(rlink.SYNC_MACHINE,))
        good = rlink.transport_frame(0x81, 0, 1, bytes(15), sync=b"LD")
        self.assertEqual(p.feed(good[:9], now=0), [])
        self.assertEqual(p.poll(now=0.5), [])
        dropped = p.poll(now=1.5)
        self.assertEqual(dropped, [good[:9]])
        bad = bytearray(good)
        bad[-1] ^= 1
        self.assertEqual(p.feed(bytes(bad), now=2)[0].error, "crc")
        reserved = bytearray(rlink.transport_frame(0x81, 0, 1, b"", sync=b"LD"))
        reserved[6] = 1
        reserved[-4:] = struct.pack(">I", rlink.crc32(bytes(reserved[2:-4])))
        self.assertEqual(p.feed(bytes(reserved), now=3)[0].error, "frame")
        badlen = bytearray(good[:12])
        badlen[11] ^= 1
        self.assertEqual(p.feed(bytes(badlen), now=4)[0].error, "frame")

    def test_control_commands(self):
        self.assertEqual(rlink.control(1), b"\xc0\x01\xfe")
        self.assertEqual(rlink.escape(rlink.control(2)), b"\xc0\x02\xfd")   # sent as it is

    def test_escapes(self):
        self.assertEqual(rlink.escape(b"a\xc0b\xdbc"), b"a\xdb\xdcb\xdb\xddc")
        self.assertEqual(rlink.escape(b"\xdb\xdc"), b"\xdb\xdd\xdc")
        # every byte value comes back, and nothing waits for a next byte (a frame ending 0x00)
        u = rlink.Unescaper()
        data = bytes(range(256)) * 2
        self.assertEqual(b"".join(u.feed(rlink.escape(data))), data)
        frame = rlink.transport_frame(0x12, 0x43, 1)
        self.assertEqual(frame[-1], 0)
        self.assertEqual(u.feed(rlink.escape(frame)), [frame])
        # a command among data, split anywhere
        wire = rlink.escape(b"xy") + rlink.control(1) + rlink.escape(b"\xc0z")
        got = []
        for b in wire:
            got += u.feed(bytes([b]))
        self.assertEqual([g for g in got if isinstance(g, int)], [1])
        self.assertEqual(b"".join(g for g in got if isinstance(g, bytes)), b"xy\xc0z")
        # a broken command is dropped; a C0 starts again
        self.assertEqual(u.feed(b"\xc0\x05\xfa" + b"q"), [b"q"])
        self.assertEqual(u.feed(b"\xc0\x01\xc0\x03\xfc"), [3])

    def test_key(self):
        # KEY: C0 04 b ~b, b and ~b escaped (ticket #44), the same bytes as sim/serial/tb_serial.v
        self.assertEqual(rlink.escape(rlink.key(b"\x1c\xc0$")),
                         bytes.fromhex("c0041ce3 c004dbdc3f c00424dbdd"))
        u = rlink.Unescaper()
        wire = rlink.escape(b"a") + rlink.key(bytes(range(256))) + rlink.escape(b"b")
        got = []
        for b in wire:
            got += u.feed(bytes([b]))
        self.assertEqual([g[1] for g in got if isinstance(g, tuple)], list(range(256)))
        self.assertEqual(b"".join(g for g in got if isinstance(g, bytes)), b"ab")
        self.assertEqual(u.feed(b"\xc0\x04\x1c\x00q"), [b"q"])            # wrong inverse: dropped

    def test_ps2_keys(self):
        self.assertEqual((ps2keys.make("A"), ps2keys.brk("KeyA")), (b"\x1c", b"\xf0\x1c"))
        self.assertEqual((ps2keys.make("up"), ps2keys.brk("ArrowUp")), (b"\xe0u", b"\xe0\xf0u"))
        self.assertEqual(ps2keys.make("ENTER"), ps2keys.make("Enter"))
        self.assertEqual(ps2keys.type_text("a!")[1][:2], (b"\x12\x16", b"\xf0\x16\xf0\x12"))
        with self.assertRaises(ValueError):
            ps2keys.make("NOPE")

    def test_image_header(self):
        img = rlink.Image(b"\x01\x02\x03", "z80", 0x8000, 0x8001)
        back, problems = rlink.Image.parse(img.file_bytes())
        self.assertEqual(problems, [])
        self.assertEqual((back.load, back.entry, back.data, back.machine), (0x8000, 0x8001, b"\x01\x02\x03", b"Z80 "))


# ---------------------------------------------------------------- the debug channel against the model
class ChannelTests(unittest.TestCase):
    def setUp(self):
        self.model = StubModel()
        self.model.start()
        self.session = Session(ModelLink(self.model), "model")
        self.session.client.reply_wait = 0.3
        self.tmp = tempfile.mkdtemp()
        self.paths = build_program(self.tmp)
        with open(self.paths["rimg"], "rb") as f:
            self.image = rlink.Image.parse(f.read())[0]

    def tearDown(self):
        self.session.close()
        self.model.shutdown()
        shutil.rmtree(self.tmp)

    def test_keys_reach_the_board_attached_or_not(self):
        self.session.key_down("SHIFT")
        self.session.key_down("A")
        self.session.launch(self.image)
        self.session.key_up("A")
        self.session.type_text("b", 0, 0)
        self.session.key_up()                                   # SHIFT, still held
        deadline = time.time() + 2
        want = list(b"\x12\x1c\xf0\x1c2\xf02\xf0\x12")
        while self.model.keys_in != want and time.time() < deadline:
            time.sleep(0.01)
        self.assertEqual(self.model.keys_in, want)
        self.assertEqual(self.session.held_keys, set())

    def test_launch_stops_at_entry(self):
        stop = self.session.launch(self.image)
        self.assertEqual((stop.reason, stop.pc), (P.R_ENTRY, ORG))
        t = self.session.target
        self.assertEqual((t.machine, t.nbp, t.nwp, t.maxdata, t.blocklen), ("Z80 ", 4, 2, 2048, 28))
        self.assertEqual([r.name for r in t.registers][:8], ["AF", "BC", "DE", "HL", "IX", "IY", "SP", "PC"])

    def test_crc_error_each_way(self):
        self.session.launch(self.image)
        c = self.session.client
        # PC to machine: a damaged command is answered C and sent again
        orig = c.send
        sent = []

        def damage_first(frame):
            if not sent:
                frame = frame[:-1] + bytes([frame[-1] ^ 0xFF])
            sent.append(frame)
            orig(frame)
        c.send = damage_first
        self.assertEqual(len(c.read_regs()), 28)
        self.assertEqual(len(sent), 2)
        c.send = orig
        # machine to PC: a damaged reply is dropped; the resend is answered
        self.model.corrupt_next_reply = "crc"
        self.assertEqual(len(c.read_mem(ORG, 4)), 4)
        self.model.corrupt_next_reply = "drop"
        self.assertEqual(c.read_mem(ORG, 2), b"\x3e\x41")

    def test_repeated_seq(self):
        self.session.launch(self.image)
        c = self.session.client
        # a write done once even when its frame comes twice
        frame = rlink.transport_frame(P.WRITEMEM, 50, P.CH_DEBUG, struct.pack(">BBI", 0, 0, 0x9000) + b"\x07")
        c.seq = 49
        self.session.link.write(frame)
        self.session.link.write(frame)
        time.sleep(0.2)
        self.assertEqual(c.read_mem(0x9000, 1), b"\x07")
        # a read is read afresh
        c.seq = 60
        c.write_mem(0x9000, b"\x08")
        self.assertEqual(c.read_mem(0x9000, 1), b"\x08")

    def test_refusals(self):
        self.session.launch(self.image)
        c = self.session.client
        with self.assertRaises(P.Refused) as e:
            c.set_bp(4, ORG)
        self.assertEqual(e.exception.code, P.E_NUMBER)
        with self.assertRaises(P.Refused) as e:
            c.set_wp(0, 0, ORG, 0xFFFF)
        self.assertEqual(e.exception.code, P.E_LENGTH)
        with self.assertRaises(P.Refused) as e:
            c.console("G 8000")
        self.assertEqual(e.exception.code, P.E_CONSOLE)
        with self.assertRaises(P.Refused) as e:
            c.write_regs(27, b"\x00\x00")
        self.assertEqual(e.exception.code, P.E_REGISTER)
        with self.assertRaises(P.Refused) as e:
            c.read_mem(0x200000, 4, space=1)
        self.assertEqual(e.exception.code, P.E_ADDRESS)
        with self.assertRaises(P.Refused) as e:
            c.command(0x1F)
        self.assertEqual(e.exception.code, P.E_UNKNOWN)

    def test_lost_stop_recovered_by_query(self):
        s = self.session
        s.launch(self.image)
        events = queue.Queue()
        s.add_listener(lambda k, d: events.put((k, d)))
        s.set_breakpoints("test", "t", [(line_addr(5), None)])
        self.model.corrupt_next_reply = None
        # the STOP for the breakpoint is damaged on the way
        orig_frame = self.model._frame

        def damage_stop(ftype, seq, payload):
            if ftype == P.T_STOP:
                self.model._frame = orig_frame
                self.model.corrupt_next_reply = "crc"
            orig_frame(ftype, seq, payload)
        self.model._frame = damage_stop
        s.cont("test")
        while True:
            k, d = events.get(timeout=5)
            if k == "stopped" and d["stop"].reason != P.R_ENTRY:
                break
        self.assertEqual((d["stop"].reason, d["stop"].pc), (P.R_BREAKPOINT, line_addr(5)))

    def test_pool_shared_and_fifth_refused(self):
        s = self.session
        s.launch(self.image)
        r = s.set_breakpoints("vscode", "a", [(line_addr(3), None), (line_addr(4), None), (line_addr(5), None)])
        self.assertEqual([n for n, _ in r], [0, 1, 2])
        r = s.set_breakpoints("mcp", "x", [(line_addr(5), None), (line_addr(7), None), (line_addr(8), None)])
        self.assertEqual(r[0][0], 2)          # the same address shares the slot
        self.assertEqual(r[1][0], 3)
        self.assertIsNone(r[2][0])
        self.assertIn("only 4 hardware breakpoints", r[2][1])
        self.assertIn("vscode", r[2][1])
        listed = {b["address"]: b["owners"] for b in s.list_breakpoints()}
        self.assertEqual(listed[line_addr(5)], ["mcp", "vscode"])
        s.set_breakpoints("vscode", "a", [])
        self.assertEqual(sorted(listed[line_addr(5)] for listed in [{b["address"]: b["owners"] for b in s.list_breakpoints()}]), [["mcp"]])

    def test_step_over_without_spare_breakpoint(self):
        s = self.session
        s.launch(self.image)
        s.set_breakpoints("x", "x", [(0x7000 + i, None) for i in range(4)])
        s.set_register("PC", line_addr(4))
        stop = s.step("over", owner="x")
        self.assertEqual(stop.pc, line_addr(5))
        self.assertEqual(s.registers()["AF"] >> 8, 0x02)     # A was 0: LD A,0x41 was skipped


# ---------------------------------------------------------------- whole DAP sessions
class DapTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.paths = build_program(self.tmp)
        os.environ["RZ80_BRIDGE_ADVERT_DIR"] = os.path.join(self.tmp, "adverts")
        self.bridge = Bridge("model", advertise=True, mcp=False).start()
        self.dap = DapClient(self.bridge.ports["dap"])

    def tearDown(self):
        self.dap.close()
        self.bridge.close()
        shutil.rmtree(self.tmp)

    def launch(self, breakpoints=(), stop_on_entry=True):
        d = self.dap
        caps = d.request("initialize", {"adapterID": "retro-z80"})["body"]
        self.assertTrue(caps["supportsDisassembleRequest"])
        d.request("launch", {"program": self.paths["rimg"], "sld": self.paths["sld"], "stopOnEntry": stop_on_entry})
        d.event("initialized")
        r = d.request("setBreakpoints", {"source": {"path": self.paths["asm"]},
                                         "breakpoints": [{"line": n} for n in breakpoints]})
        d.request("configurationDone")
        return r["body"]["breakpoints"]

    def stopped(self):
        return self.dap.event("stopped")["body"]

    def top(self):
        return self.dap.request("stackTrace", {"threadId": 1})["body"]["stackFrames"]

    def regs(self):
        v = self.dap.request("variables", {"variablesReference": 1})["body"]["variables"]
        return {x["name"]: int(x["value"].split()[0], 16) for x in v if x["value"] != "?"}

    def test_advert(self):
        files = os.listdir(os.path.join(self.tmp, "adverts"))
        self.assertEqual(files, ["%d.json" % os.getpid()])
        with open(os.path.join(self.tmp, "adverts", files[0])) as f:
            ad = json.load(f)
        self.assertEqual((ad["version"], ad["ports"]["dap"], ad["serialPort"]), (1, self.bridge.ports["dap"], "model"))
        self.launch()
        self.stopped()
        time.sleep(0.1)
        with open(os.path.join(self.tmp, "adverts", files[0])) as f:
            self.assertEqual(json.load(f)["program"], self.paths["rimg"])

    def test_launch_breakpoint_and_source(self):
        bps = self.launch([5, 13])
        self.assertTrue(bps[0]["verified"])
        self.assertEqual(bps[1]["line"], 14)      # no code on 13: moved to the next line with code
        self.assertEqual(self.stopped()["reason"], "entry")
        frames = self.top()
        self.assertEqual((frames[0]["line"], frames[0]["source"]["name"]), (3, "test.asm"))
        d = self.dap
        d.request("continue", {"threadId": 1})
        ev = self.stopped()
        self.assertEqual(ev["reason"], "breakpoint")
        self.assertEqual(self.top()[0]["line"], 14)   # add2 comes first
        d.request("continue", {"threadId": 1})
        self.assertEqual(self.stopped()["reason"], "breakpoint")
        self.assertEqual(self.top()[0]["line"], 5)
        self.assertEqual(self.regs()["AF"] >> 8, 0x43)

    def test_step_in_over_out_and_call_stack(self):
        self.launch([4])
        self.stopped()
        d = self.dap
        d.request("continue", {"threadId": 1})
        self.stopped()
        d.request("stepIn", {"threadId": 1})
        self.assertEqual(self.stopped()["reason"], "step")
        frames = self.top()
        self.assertEqual(frames[0]["line"], 14)
        self.assertEqual([f["name"].split()[0] for f in frames], ["add2", "start+5"])
        self.assertEqual(frames[1]["line"], 5)
        d.request("next", {"threadId": 1})
        self.stopped()
        self.assertEqual(self.top()[0]["line"], 15)
        d.request("next", {"threadId": 1})          # over call add1
        self.stopped()
        self.assertEqual(self.top()[0]["line"], 16)
        self.assertEqual(self.regs()["AF"] >> 8, 0x43)
        d.request("stepOut", {"threadId": 1})
        self.stopped()
        self.assertEqual(self.top()[0]["line"], 5)
        d.request("next", {"threadId": 1, "granularity": "instruction"})
        self.stopped()
        self.assertEqual(self.top()[0]["line"], 6)

    def test_registers_flags_mmu_and_set(self):
        self.launch()
        self.stopped()
        d = self.dap
        scopes = d.request("scopes", {"frameId": 1})["body"]["scopes"]
        self.assertEqual([s["name"] for s in scopes], ["Registers", "Flags", "MMU windows"])
        regs = self.regs()
        self.assertEqual((regs["PC"], regs["SP"]), (ORG, 0xFFFE))
        self.assertIn("AF'", regs)
        d.request("setVariable", {"variablesReference": 1, "name": "HL", "value": "msg+1"})
        self.assertEqual(self.regs()["HL"], 0x801C)
        d.request("setVariable", {"variablesReference": 2, "name": "C", "value": "1"})
        flags = {v["name"]: v["value"] for v in d.request("variables", {"variablesReference": 2})["body"]["variables"]}
        self.assertEqual(flags["C"], "1")
        mmu = d.request("variables", {"variablesReference": 3})["body"]["variables"]
        self.assertEqual(mmu[0]["value"], "read 3FC  write 3FC")
        self.assertEqual(mmu[4]["value"], "read 004  write 004")

    def test_memory_and_disassembly(self):
        self.launch()
        self.stopped()
        d = self.dap
        r = d.request("readMemory", {"memoryReference": "0x8000", "count": 5})["body"]
        self.assertEqual(base64.b64decode(r["data"]), b"\x3e\x41\xcd\x14\x80")
        d.request("writeMemory", {"memoryReference": "0x9000", "data": base64.b64encode(b"\xaa\xbb").decode()})
        r = d.request("readMemory", {"memoryReference": "0x9000", "count": 2})["body"]
        self.assertEqual(base64.b64decode(r["data"]), b"\xaa\xbb")
        r = d.request("readMemory", {"memoryReference": "0xFFFE", "count": 4})["body"]
        self.assertEqual(r["unreadableBytes"], 2)
        ins = d.request("disassemble", {"memoryReference": "0x8005", "instructionOffset": -2,
                                        "instructionCount": 5})["body"]["instructions"]
        self.assertEqual([i["address"] for i in ins], ["0x8000", "0x8002", "0x8005", "0x8008", "0x800A"])
        self.assertEqual(ins[1]["instruction"], "CALL 0x8014 (add2)")
        self.assertEqual((ins[0]["symbol"], ins[0]["line"]), ("start", 3))
        ins = d.request("disassemble", {"memoryReference": "0xFFFE", "instructionCount": 4})["body"]["instructions"]
        self.assertEqual(len(ins), 4)

    def test_watchpoint_as_data_breakpoint(self):
        self.launch()
        self.stopped()
        d = self.dap
        info = d.request("dataBreakpointInfo", {"name": "result"})["body"]
        self.assertEqual(info["dataId"], "9000/1")
        r = d.request("setDataBreakpoints", {"breakpoints": [{"dataId": info["dataId"], "accessType": "write"}]})
        self.assertTrue(r["body"]["breakpoints"][0]["verified"])
        d.request("continue", {"threadId": 1})
        ev = self.stopped()
        self.assertEqual(ev["reason"], "data breakpoint")
        self.assertIn("write 9000: 43", ev["description"])
        self.assertEqual(self.top()[0]["line"], 6)    # after the instruction that wrote
        bad = d.request("dataBreakpointInfo", {"name": "result", "bytes": 3})["body"]
        self.assertIsNone(bad["dataId"])

    def test_watchpoint_panel_requests(self):
        self.launch()
        self.stopped()
        d = self.dap
        self.bridge.session.set_watchpoints("mcp", "m", [(P.WP_READ, 0x801B, 0xFFFC)])
        body = d.request("setWatchpoint", {"address": "result", "length": 1, "access": "write"})["body"]
        self.assertEqual([(w["address"], w["access"], w["owners"]) for w in body["watchpoints"]],
                         [(0x801B & 0xFFFC, "read", ["mcp"]), (0x9000, "write", ["vscode"])])
        r = d.request("setWatchpoint", {"address": "$9001", "length": 2}, ok=False)
        self.assertIn("multiple of 2", r["message"])
        r = d.request("setWatchpoint", {"address": "$A000"}, ok=False)
        self.assertIn("only 2 hardware watchpoints", r["message"])
        body = d.request("clearWatchpoint", {"id": 0})["body"]
        self.assertEqual([w["address"] for w in body["watchpoints"]], [0x9000])
        self.assertEqual(d.request("clearWatchpoint", {})["body"]["watchpoints"], [])
        self.assertEqual(self.bridge.model.wps, [None, None])

    def test_fifth_breakpoint_unverified(self):
        bps = self.launch([3, 4, 5, 7, 8])
        self.assertEqual([b["verified"] for b in bps], [True, True, True, True, False])
        self.assertIn("only 4 hardware breakpoints", bps[4]["message"])
        r = self.dap.request("setInstructionBreakpoints", {"breakpoints": [{"instructionReference": "0x8013"}]})
        self.assertFalse(r["body"]["breakpoints"][0]["verified"])

    def test_pause_and_program_output(self):
        self.launch()
        self.stopped()
        d = self.dap
        # make the program loop for ever: JR $ at 0x800F
        d.request("writeMemory", {"memoryReference": "0x800F", "data": base64.b64encode(b"\x18\xfe").decode()})
        d.request("continue", {"threadId": 1})
        out = d.event("output")
        self.assertEqual((out["body"]["category"], out["body"]["output"]), ("stdout", "C"))
        time.sleep(0.2)
        d.request("pause", {"threadId": 1})
        ev = self.stopped()
        self.assertEqual(ev["reason"], "pause")
        self.assertEqual(self.regs()["PC"], 0x800F)

    def test_debug_console_is_the_monitor(self):
        self.launch()
        self.stopped()
        r = self.dap.request("evaluate", {"expression": "D 8000 4", "context": "repl"})["body"]
        self.assertEqual(r["result"], "8000  3E 41 CD 14" + " " * 37 + "  >A..")
        r = self.dap.request("evaluate", {"expression": "G 8000", "context": "repl"}, ok=False)
        self.assertFalse(r["success"])
        self.assertIn("buttons", r["message"])
        r = self.dap.request("evaluate", {"expression": "add1", "context": "hover"})["body"]
        self.assertEqual(r["result"], "8019  byte 3C  word C93C")

    def test_program_end_and_disconnect(self):
        self.launch(stop_on_entry=False)
        self.dap.event("exited", timeout=5)
        self.dap.event("terminated")
        self.dap.request("disconnect", {})
        time.sleep(0.2)
        self.assertFalse(self.bridge.session.attached)

    def test_disconnect_detaches_and_console_comes_back(self):
        self.launch([5])
        self.stopped()
        con = socket.create_connection(("127.0.0.1", self.bridge.ports["console"]), timeout=5)
        self.dap.request("disconnect", {"terminateDebuggee": True})
        time.sleep(0.3)
        self.assertFalse(self.bridge.session.attached)
        self.assertEqual(self.bridge.model.bps, [None] * 4)
        con.sendall(b"R\r")
        got = b""
        deadline = time.time() + 3
        while b"PC=8000" not in got and time.time() < deadline:
            got += con.recv(4096)
        self.assertIn(b"Loaded.  PC = 8000", got)      # the usual stop message (debug.md 4.5)
        self.assertIn(b"PC=8000", got)
        con.close()

    def test_attach_to_a_running_program(self):
        m = self.bridge.model
        with m.lock:                         # as an upload with ACTION 1 leaves it: JR $ running
            m.phys_write(5, 0, 0x18)
            m.phys_write(5, 1, 0xFE)
            m._program_start(0xA000)
            m.resume = True
            m.mode = "running"
        time.sleep(0.2)
        d = self.dap
        d.request("initialize", {"adapterID": "retro-z80"})
        d.request("attach", {})
        d.event("initialized")
        d.request("configurationDone")
        ev = self.stopped()
        self.assertEqual(ev["reason"], "pause")
        self.assertEqual(self.regs()["PC"], 0xA000)
        d.request("disconnect", {})
        time.sleep(0.3)
        self.assertEqual(self.bridge.model.mode, "running")   # attach's disconnect lets it run on


class ModelAgreesWithTheRom(unittest.TestCase):
    """The differences found against the ROM's stub in simulation (issue #29)."""

    def setUp(self):
        self.model = StubModel()
        self.model.start()
        self.link = ModelLink(self.model)
        self.session = Session(self.link, "model")
        self.session.client.reply_wait = 0.3
        self.tmp = tempfile.mkdtemp()
        with open(build_program(self.tmp)["rimg"], "rb") as f:
            self.image = rlink.Image.parse(f.read())[0]

    def tearDown(self):
        self.session.close()
        self.model.shutdown()
        shutil.rmtree(self.tmp)

    def test_entry_registers(self):
        self.session.launch(self.image)
        r = self.session.registers()
        self.assertEqual([r[n] for n in ("AF'", "BC'", "DE'", "HL'")], [0, 0, 0, 0])
        self.assertEqual((r["I"], r["IM"]), (0x1F, 2))
        self.session.step()
        self.assertEqual(self.session.registers()["IM"], 0xFF)

    def test_dump_pads_the_text_column(self):
        self.session.launch(self.image)
        out = self.session.monitor("D 8000 4")
        self.assertEqual(out, "8000  3E 41 CD 14" + " " * 37 + "  >A..\r\n")

    def test_break_at_the_prompt_sends_nothing(self):
        time.sleep(0.2)
        before = self.session.console.read()[1:]
        self.link.write(rlink.control(rlink.CTL_BREAK))
        time.sleep(0.3)
        self.assertEqual(self.session.console.read()[1:], before)

    def test_damaged_hello_answered_and_frames_typed(self):
        time.sleep(0.2)
        replies = []
        self.session.mode = "debug"
        self.session.client.frame = lambda f: replies.append(f)
        hello = bytearray(rlink.transport_frame(P.HELLO, 1, P.CH_DEBUG, b"\x01"))
        hello[-1] ^= 1
        self.link.write(bytes(hello))
        time.sleep(0.3)
        self.assertEqual([(f.type, f.payload[:1]) for f in replies], [(P.T_REPLY, b"C")])
        self.assertFalse(self.model.attached)
        self.session.mode = "console"
        self.link.write(rlink.upload_frame(rlink.PING, 0) + b"\r")
        time.sleep(0.3)
        self.assertIn("? ", "".join(self.session.console.read()[0][-2:]))   # typed, and not understood

    def test_stub_page_refused_through_a_window(self):
        self.session.launch(self.image)
        with self.model.lock:
            self.model.mmu[5] = (0x0FC, 0x0FC)
        with self.assertRaises(P.Refused) as e:
            self.session.client.read_mem(0xA000, 1)
        self.assertEqual(e.exception.code, P.E_ADDRESS)

    def test_writeregs_im(self):
        self.session.launch(self.image)
        c = self.session.client
        c.write_regs(27, b"\x01")
        with self.assertRaises(P.Refused) as e:
            c.write_regs(27, b"\x03")
        self.assertEqual(e.exception.code, P.E_LENGTH)
        c.write_regs(26, b"\x00\x01")          # IFF changed, IM unchanged

    def test_hello_stop_has_the_current_pc(self):
        self.session.launch(self.image)
        self.session.detach()
        time.sleep(0.2)
        with self.model.lock:
            self.model.cpu.pc = 0x8005          # as R PC 8005 at the prompt would
        stop = self.session.attach()
        self.assertEqual((stop.reason, stop.pc), (P.R_ENTRY, 0x8005))

    def test_console_empty_line_after_n_and_after_exit(self):
        self.session.launch(self.image)
        with self.model.lock:
            self.model.last_cmd = "N"
        with self.assertRaises(P.Refused) as e:
            self.session.client.console(" ")
        self.assertEqual(e.exception.code, P.E_CONSOLE)
        self.session.cont()
        time.sleep(0.3)
        self.assertTrue(self.session.ended)
        for cmd in (lambda: self.session.client.cont(), lambda: self.session.client.step()):
            with self.assertRaises(P.Refused) as e:
                cmd()
            self.assertEqual(e.exception.code, P.E_ADDRESS)


class ConsoleTextTests(unittest.TestCase):
    def test_cr_lf_split_across_reads(self):
        from rz80bridge.session import Console
        c = Console()
        c.add("one\r")
        c.add("\ntwo\r\n")
        self.assertEqual(c.read()[0], ["one", "two"])

    def test_upload_replies_split_across_reads(self):
        p = rlink.FrameParser(syncs=(), replies=True)
        text = b""
        for chunk in (b"LOAD Z80 1\r\nL", b"RK\x00", b"\x00LRK\x01\x00"):
            text += b"".join(i for i in p.feed(chunk, now=0) if isinstance(i, bytes))
        self.assertEqual(text, b"LOAD Z80 1\r\n")


class TcpLinkTests(unittest.TestCase):
    def test_bridge_over_a_raw_tcp_link(self):
        """A simulation's FT232H model on a TCP port: here the stub model behind a socket."""
        model = StubModel()
        model.start()
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)

        def serve():
            conn, _ = srv.accept()
            link = ModelLink(model)

            def up():
                while True:
                    data = conn.recv(4096)
                    if not data:
                        return
                    model.inbox.put(data)     # the wire's bytes, escaped already

            threading.Thread(target=up, daemon=True).start()
            while True:
                data = link.read_some(0.1)
                if data:
                    conn.sendall(data)
        threading.Thread(target=serve, daemon=True).start()
        tmp = tempfile.mkdtemp()
        try:
            img = rlink.Image.parse(open(build_program(tmp)["rimg"], "rb").read())[0]
            s = Session(rlink.open_link("tcp:127.0.0.1:%d" % srv.getsockname()[1]), "tcp")
            stop = s.launch(img)
            self.assertEqual((stop.reason, stop.pc), (P.R_ENTRY, ORG))
            self.assertEqual(s.read_memory(ORG, 2), [0x3E, 0x41])
            s.close()
        finally:
            model.shutdown()
            srv.close()
            shutil.rmtree(tmp)


class McpClient:
    def __init__(self, port):
        self.url = "http://127.0.0.1:%d/mcp" % port
        self.seq = 0

    def rpc(self, method, params=None):
        import urllib.request
        self.seq += 1
        body = json.dumps({"jsonrpc": "2.0", "id": self.seq, "method": method, "params": params or {}}).encode()
        req = urllib.request.Request(self.url, body, {"Content-Type": "application/json",
                                                      "Accept": "application/json, text/event-stream"})
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.loads(r.read())

    def call(self, _tool, ok=True, **args):
        r = self.rpc("tools/call", {"name": _tool, "arguments": args})["result"]
        text = r["content"][0]["text"]
        if ok and r.get("isError"):
            raise AssertionError("%s failed: %s" % (_tool, text))
        if not ok:
            assert r.get("isError"), "%s should have failed: %s" % (_tool, text)
        return text

    def json(self, _tool, **args):
        return json.loads(self.call(_tool, **args))


class McpTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.paths = build_program(self.tmp)
        os.environ["RZ80_BRIDGE_ADVERT_DIR"] = os.path.join(self.tmp, "adverts")
        self.bridge = Bridge("model").start()
        self.mcp = McpClient(self.bridge.ports["mcp"])

    def tearDown(self):
        self.bridge.close()
        shutil.rmtree(self.tmp)

    def test_initialize_and_tools(self):
        r = self.mcp.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                        "clientInfo": {"name": "test", "version": "1"}})["result"]
        self.assertEqual((r["protocolVersion"], r["serverInfo"]["name"]), ("2025-06-18", "retro-z80"))
        names = {t["name"] for t in self.mcp.rpc("tools/list")["result"]["tools"]}
        for n in ("get_state", "get_registers", "set_registers", "read_memory", "write_memory", "set_breakpoint",
                  "clear_breakpoint", "list_breakpoints", "set_watchpoint", "clear_watchpoint", "list_watchpoints",
                  "step", "run", "pause", "load_debug_info", "resolve_symbol", "resolve_address", "server_info",
                  "launch", "attach", "detach", "reset", "get_mmu", "monitor", "send_console", "read_console"):
            self.assertIn(n, names)
        self.assertEqual(self.mcp.rpc("ping")["result"], {})
        self.assertEqual(self.mcp.rpc("nope")["error"]["code"], -32601)
        info = self.mcp.json("server_info")
        self.assertEqual((info["serialPort"], info["ports"]["mcp"]), ("model", self.bridge.ports["mcp"]))

    def test_not_attached(self):
        text = self.mcp.call("get_registers", ok=False)
        self.assertIn("not attached", text)
        self.assertEqual(self.mcp.json("get_state")["attached"], False)

    def test_console_while_not_attached(self):
        time.sleep(0.2)
        start = self.mcp.json("read_console")["next"]
        self.mcp.call("send_console", text="H\n")
        time.sleep(0.3)
        lines = self.mcp.json("read_console", since=start)["lines"]
        self.assertTrue(any("help" in l for l in lines), lines)

    def test_launch_break_registers_memory(self):
        m = self.mcp
        self.assertIn("Entry at 8000 (start)", m.call("launch", program=self.paths["rimg"], sld=self.paths["sld"]))
        self.assertEqual(m.call("set_breakpoint", address="add1"), "breakpoint 0 at 8019 (add1)")
        self.assertEqual(m.call("run"), "Breakpoint 0 at 8019 (add1)")
        r = m.json("get_registers")
        self.assertEqual((r["PC"], r["AF"][:2], r["instruction"]), ("$8019 (add1)", "42", "INC A"))
        self.assertEqual(len(r["flags"]), 8)
        st = m.json("get_state")
        self.assertEqual([f["symbol"] for f in st["call_stack"]], ["add1", "add2+4", "start+5"])
        self.assertEqual(m.json("read_memory", address="msg", length=3)["hex"], "68 69 0D")
        m.call("write_memory", address="$9000", data="AA BB")
        self.assertEqual(m.json("read_memory", address=0x9000, length=2)["hex"], "AA BB")
        self.assertEqual(m.json("read_memory", address="P009000", length=1)["hex"], "AA")
        self.assertEqual(m.json("resolve_symbol", name="add2+1")["address"], "8015")
        ra = m.json("resolve_address", address="8016")
        self.assertEqual((ra["symbol"], ra["source"]["line"]), ("add2+2", 15))   # inside call add1
        self.assertEqual(m.json("get_mmu")[7]["read_page"], "007")
        self.assertIn("8000  3E 41", m.call("monitor", command="D 8000 2"))
        self.assertIn("buttons", m.call("monitor", ok=False, command="G"))
        m.json("set_registers", hl="msg", a=7, af_=0x1234)
        r = m.json("get_registers", raw=True)
        self.assertEqual((r["HL"], r["AF"] >> 8, r["AF'"]), (0x801B, 7, 0x1234))
        s = m.json("step", instructions=2)
        self.assertEqual(s["registers"]["PC"], "$8018 (add2+4)")     # INC A, RET: back in add2

    def test_watchpoint(self):
        m = self.mcp
        m.call("launch", program=self.paths["rimg"], sld=self.paths["sld"])
        w = m.json("set_watchpoint", address="result", access="write")
        self.assertEqual(w["id"], 0)
        self.assertIn("aligned", m.call("set_watchpoint", ok=False, address="$9001", length=2))
        self.assertIn("not offered", m.call("set_watchpoint", ok=False, address="$9000", value=5))
        self.assertEqual(m.call("run"), "Watchpoint 0 at 8008 (start+8) (write 9000: 43)")
        self.assertEqual(m.json("list_watchpoints")[0]["owners"], ["mcp"])
        m.call("clear_watchpoint")
        self.assertEqual(m.json("list_watchpoints"), [])

    def test_run_wait_false_pause_and_detach(self):
        m = self.mcp
        m.call("launch", program=self.paths["rimg"], sld=self.paths["sld"])
        m.call("write_memory", address="$800F", data="18 FE")
        self.assertEqual(m.call("run", wait=False), "running")
        time.sleep(0.2)
        self.assertEqual(m.call("pause"), "Paused at 800F (loop+3)")
        self.assertIn("runs on", m.call("detach", run=True))
        time.sleep(0.2)
        self.assertEqual(self.bridge.model.mode, "running")
        self.assertEqual(m.call("attach"), "Paused at 800F (loop+3)")

    def test_shared_with_vscode(self):
        dap = DapClient(self.bridge.ports["dap"])
        try:
            dap.request("initialize", {"adapterID": "retro-z80"})
            dap.request("launch", {"program": self.paths["rimg"], "sld": self.paths["sld"]})
            dap.event("initialized")
            r = dap.request("setBreakpoints", {"source": {"path": self.paths["asm"]},
                                               "breakpoints": [{"line": n} for n in (3, 4, 5)]})
            self.assertTrue(all(b["verified"] for b in r["body"]["breakpoints"]))
            dap.request("configurationDone")
            dap.event("stopped")
            m = self.mcp
            m.call("set_breakpoint", address="add1")
            text = m.call("set_breakpoint", ok=False, address="add2")
            self.assertIn("only 4 hardware breakpoints", text)
            self.assertIn("vscode", text)
            owners = {b["address"]: b["owners"] for b in m.json("list_breakpoints")}
            self.assertEqual(owners["8019"], ["mcp"])
            self.assertEqual(owners["8005"], ["vscode"])
            # a stop MCP causes is seen by VS Code, without moving its editor
            dap.drain()
            self.assertTrue(m.call("run").startswith("Breakpoint"))
            ev = dap.event("stopped")["body"]
            self.assertTrue(ev.get("preserveFocusHint"))
            # VS Code disconnects: MCP holds a breakpoint, so the session stays (DB15)
            dap.request("disconnect", {})
            time.sleep(0.2)
            self.assertTrue(self.bridge.session.attached)
            self.assertEqual([b["owners"] for b in m.json("list_breakpoints")], [["mcp"]])
        finally:
            dap.close()


class McpFrontTests(unittest.TestCase):
    """tools/rz80_mcp.py: MCP over stdio, adopting a bridge or starting one."""

    def run_front(self, env, messages):
        import subprocess
        full = dict(os.environ)
        full.pop("RLINK_PORT", None)
        full.pop("RZ80_PORT", None)
        full.update(env)
        p = subprocess.Popen([sys.executable, os.path.join(os.path.dirname(HERE), "rz80_mcp.py")],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=full)
        out = []
        for m in messages:
            p.stdin.write((json.dumps(m) + "\n").encode())
            p.stdin.flush()
            if "id" in m:
                out.append(json.loads(p.stdout.readline()))
        p.stdin.close()
        p.wait(10)
        return out

    @staticmethod
    def free_port():
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            return s.getsockname()[1]

    def test_spawns_the_bridge_and_stops_it(self):
        port = self.free_port()
        tmp = tempfile.mkdtemp()
        try:
            out = self.run_front({"RZ80_PORT": "model", "RZ80_MCP_PORT": str(port),
                                  "RZ80_BRIDGE_ADVERT_DIR": tmp}, [
                {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
                {"jsonrpc": "2.0", "method": "notifications/initialized"},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
                {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "get_state", "arguments": {}}},
            ])
            self.assertEqual(out[0]["result"]["serverInfo"]["name"], "retro-z80")
            self.assertIn("launch", [t["name"] for t in out[1]["result"]["tools"]])
            state = json.loads(out[2]["result"]["content"][0]["text"])
            self.assertEqual((state["attached"], state["serial_port"]), (False, "model"))
            time.sleep(0.3)
            with self.assertRaises(OSError):
                socket.create_connection(("127.0.0.1", port), timeout=0.5).close()
        finally:
            shutil.rmtree(tmp)

    def test_adopts_a_running_bridge_and_leaves_it(self):
        tmp = tempfile.mkdtemp()
        os.environ["RZ80_BRIDGE_ADVERT_DIR"] = tmp
        b = Bridge("model").start()
        try:
            out = self.run_front({"RZ80_MCP_PORT": str(b.ports["mcp"])}, [
                {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "server_info", "arguments": {}}},
            ])
            self.assertEqual(json.loads(out[0]["result"]["content"][0]["text"])["pid"], os.getpid())
            socket.create_connection(("127.0.0.1", b.ports["mcp"]), timeout=1).close()   # still up
        finally:
            b.close()
            shutil.rmtree(tmp)

    def test_no_bridge_and_no_port(self):
        out = self.run_front({"RZ80_MCP_PORT": str(self.free_port())}, [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "get_state", "arguments": {}}},
        ])
        self.assertIn("RLINK_PORT", out[0]["result"]["instructions"])
        self.assertTrue(out[1]["result"]["isError"])


class SymbolTests(unittest.TestCase):
    def test_sld_paths_relative_to_where_sjasmplus_ran(self):
        tmp = tempfile.mkdtemp()
        try:
            os.makedirs(os.path.join(tmp, "src"))
            os.makedirs(os.path.join(tmp, "build"))
            open(os.path.join(tmp, "src", "game.asm"), "w").write("start: nop\n")
            sld = os.path.join(tmp, "build", "game.sld")
            open(sld, "w").write("|SLD.data.version|1\nsrc/game.asm|1||0|-1|32768|T|\n")
            alone = Symbols.load(sld)
            self.assertFalse(os.path.exists(alone.location(0x8000)[0]))
            s = Symbols.load(sld, bases=[tmp])
            self.assertEqual(s.location(0x8000), (os.path.join(tmp, "src", "game.asm"), 1))
        finally:
            shutil.rmtree(tmp)

    def test_sld(self):
        tmp = tempfile.mkdtemp()
        try:
            paths = build_program(tmp)
            s = Symbols.load(paths["sld"])
            self.assertEqual(s.resolve("add2"), 0x8014)
            self.assertEqual(s.line_address(paths["asm"], 13)[0], 0x8014)
            self.assertEqual(s.location(0x8005), (os.path.normpath(paths["asm"]), 5))
            self.assertEqual(s.symbol_at(0x8016), ("add2", 2))
            self.assertIsNone(s.symbol_at(0x7FFF))
            self.assertIn("result", s.equates)
        finally:
            shutil.rmtree(tmp)


if __name__ == "__main__":
    unittest.main(verbosity=2)
