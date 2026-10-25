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
        self.assertEqual(rlink.control(1)[:14], bytes([0, 0xFF]) + b"R68K-CTL" + bytes([0xFF, 0, 0xA5, 0x5A]))
        self.assertEqual(rlink.control(1)[14:], b"\x01\xfe")

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
        self.assertEqual(r["result"], "8000  3E 41 CD 14  >A..")
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
                    link.write(data)
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


class SymbolTests(unittest.TestCase):
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
