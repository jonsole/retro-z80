#!/usr/bin/env python3
"""MCP over stdio for the retro-z80 bridge, starting the bridge on demand.

An MCP client set to http://127.0.0.1:8780/mcp fails for its whole session
if the bridge is not running when it connects. This sits in front over
stdio, where the client starts the process (as the zx emulator's
tools/zxserver/mcp_server.py does for zx_server):

    adopt   something listens on the MCP port: use it, never stop it (VS
            Code's bridge, or one started by hand);
    spawn   nothing listens: start rz80_bridge.py on the serial port in
            RLINK_PORT (or the stub model with RZ80_PORT=model), wait for
            the port, and stop it when this process ends.

Every message is forwarded to the bridge as it is, so the bridge stays the
one definition of the tools. Standard library only.

    .mcp.json: {"command": "python", "args": ["tools/rz80_mcp.py"]}
    environment: RLINK_PORT=COM5 (or RZ80_PORT=model), RZ80_MCP_PORT (8780)
"""

import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
HOST = "127.0.0.1"
PORT = int(os.environ.get("RZ80_MCP_PORT", "8780"))
STARTUP = 10.0


def listening(port):
    try:
        with socket.create_connection((HOST, port), timeout=0.3):
            return True
    except OSError:
        return False


def log(text):
    print("rz80_mcp: " + text, file=sys.stderr, flush=True)


class Front:
    def __init__(self):
        self.child = None
        self.problem = None

    def ensure(self):
        """The bridge listens on PORT, adopted or spawned. False (and self.problem) if not."""
        if listening(PORT):
            return True
        if self.child is not None and self.child.poll() is None:
            return self._wait()
        serial = os.environ.get("RZ80_PORT") or os.environ.get("RLINK_PORT")
        if not serial:
            self.problem = ("the bridge is not running, and no serial port is set to start one: start "
                            "tools/rz80_bridge.py (or a VS Code debug session), or set RLINK_PORT (or "
                            "RZ80_PORT=model) for this MCP server")
            return False
        args = [sys.executable, os.path.join(HERE, "rz80_bridge.py"), "--mcp-port", str(PORT), "--quiet"]
        args += ["--model"] if serial == "model" else ["--port", serial]
        log("starting the bridge on %s" % serial)
        self.child = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
        return self._wait()

    def _wait(self):
        deadline = time.time() + STARTUP
        while time.time() < deadline:
            if listening(PORT):
                self.problem = None
                return True
            if self.child is not None and self.child.poll() is not None:
                self.problem = "the bridge stopped at once (exit %s): is the serial port free?" % self.child.returncode
                return False
            time.sleep(0.1)
        self.problem = "the bridge did not start listening within %g s" % STARTUP
        return False

    def forward(self, raw):
        req = urllib.request.Request("http://%s:%d/mcp" % (HOST, PORT), raw,
                                     {"Content-Type": "application/json",
                                      "Accept": "application/json, text/event-stream"})
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.read()

    def handle(self, line):
        try:
            msg = json.loads(line)
        except ValueError:
            return json.dumps({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "invalid JSON"}})
        ident = msg.get("id") if isinstance(msg, dict) else None
        if not self.ensure():
            if ident is None:
                return None
            if isinstance(msg, dict) and msg.get("method") == "tools/call":
                return json.dumps({"jsonrpc": "2.0", "id": ident, "result": {
                    "content": [{"type": "text", "text": self.problem}], "isError": True}})
            if isinstance(msg, dict) and msg.get("method") == "initialize":
                # answer, so the client connects; tools/list is then empty until the bridge is up
                return json.dumps({"jsonrpc": "2.0", "id": ident, "result": {
                    "protocolVersion": "2025-06-18", "capabilities": {"tools": {"listChanged": False}},
                    "serverInfo": {"name": "retro-z80", "version": "front"}, "instructions": self.problem}})
            if isinstance(msg, dict) and msg.get("method") == "tools/list":
                return json.dumps({"jsonrpc": "2.0", "id": ident, "result": {"tools": []}})
            return json.dumps({"jsonrpc": "2.0", "id": ident, "error": {"code": -32000, "message": self.problem}})
        try:
            body = self.forward(line.encode("utf-8"))
        except (urllib.error.URLError, OSError) as e:
            if ident is None:
                return None
            return json.dumps({"jsonrpc": "2.0", "id": ident, "error": {"code": -32000,
                                                                         "message": "the bridge: %s" % e}})
        return body.decode("utf-8") if body else None

    def close(self):
        if self.child is not None and self.child.poll() is None:
            self.child.terminate()
            try:
                self.child.wait(5)
            except subprocess.TimeoutExpired:
                self.child.kill()


def main():
    front = Front()
    try:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            reply = front.handle(line)
            if reply:
                sys.stdout.write(reply.replace("\n", " ") + "\n")
                sys.stdout.flush()
    except KeyboardInterrupt:
        pass
    finally:
        front.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
