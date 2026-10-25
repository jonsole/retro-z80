"""rz80_bridge.py's main: open the link, start the servers, advertise."""

import argparse
import os
import signal
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import rlink  # noqa: E402
from rz80bridge.advert import Advert  # noqa: E402
from rz80bridge.console import ConsoleServer  # noqa: E402
from rz80bridge.dap import DapServer  # noqa: E402
from rz80bridge.session import Session  # noqa: E402

VERSION = "0.1.0"
DEFAULT_PORTS = {"dap": 4780, "mcp": 8780, "console": 4781}


def open_link(port, log):
    if port == "model":
        from rz80bridge.model import StubModel, ModelLink
        model = StubModel()
        model.start()
        return ModelLink(model), model
    return rlink.SerialLink(port), None


class Bridge:
    """Everything one bridge runs. Tests make one in-process with port 0."""

    def __init__(self, serial_port, dap_port=0, mcp_port=0, console_port=0, advertise=False, log=None, mcp=True):
        self.log = log or (lambda s: None)
        self.link, self.model = open_link(serial_port, self.log)
        self.session = Session(self.link, serial_port, log=self.log)
        self.dap = DapServer(self.session, dap_port)
        self.console = ConsoleServer(self.session, console_port)
        self.mcp = None
        if mcp:
            try:
                from rz80bridge.mcp import McpServer
            except ImportError:
                McpServer = None
            if McpServer is not None:
                self.mcp = McpServer(self.session, mcp_port, bridge=self)
        self.ports = {"dap": self.dap.port, "mcp": self.mcp.port if self.mcp else None, "console": self.console.port}
        self.advert = Advert(self.ports, serial_port, VERSION) if advertise else None
        self.started = time.time()
        self.serial_port = serial_port

    def start(self):
        self.dap.start()
        self.console.start()
        if self.mcp:
            self.mcp.start()
        if self.advert:
            self.advert.write()
            self.session.add_listener(self._on_event)
        return self

    def _on_event(self, kind, data):
        if kind == "attached" and self.advert and getattr(self.session, "program_path", None):
            self.advert.set_program(self.session.program_path)

    def close(self):
        for s in (self.dap, self.console, self.mcp):
            if s:
                s.close()
        if self.advert:
            self.advert.remove()
        self.session.close()
        if self.model:
            self.model.shutdown()


def main(argv=None):
    ap = argparse.ArgumentParser(prog="rz80_bridge.py",
                                 description="retro-z80's debug bridge: owns the serial port, serves DAP, MCP and the console.")
    ap.add_argument("--port", "-p", default=os.environ.get("RLINK_PORT"),
                    help="the FT232H's serial port (COM5, /dev/ttyUSB1), or 'model' for the stub model")
    ap.add_argument("--model", action="store_true", help="the stub model instead of a serial port")
    ap.add_argument("--dap-port", type=int, default=DEFAULT_PORTS["dap"])
    ap.add_argument("--mcp-port", type=int, default=DEFAULT_PORTS["mcp"])
    ap.add_argument("--console-port", type=int, default=DEFAULT_PORTS["console"])
    ap.add_argument("--no-advertise", action="store_true")
    ap.add_argument("--quiet", "-q", action="store_true")
    args = ap.parse_args(argv)
    port = "model" if args.model else args.port
    if not port:
        ap.error("give --port PORT (or set RLINK_PORT), or --model")

    def log(s):
        if not args.quiet:
            print("rz80_bridge: " + s, file=sys.stderr, flush=True)
    try:
        b = Bridge(port, args.dap_port, args.mcp_port, args.console_port, advertise=not args.no_advertise, log=log)
    except OSError as e:
        print("rz80_bridge: %s" % e, file=sys.stderr)
        return 1
    b.start()
    log("on %s: DAP %d, MCP %s, console %d (version %s)" % (
        port, b.ports["dap"], b.ports["mcp"], b.ports["console"], VERSION))
    if b.ports["mcp"]:
        log("MCP at http://127.0.0.1:%d/mcp" % b.ports["mcp"])
    stop = threading.Event()
    signal.signal(signal.SIGINT, lambda *a: stop.set())
    if hasattr(signal, "SIGTERM"):
        signal.signal(signal.SIGTERM, lambda *a: stop.set())
    while not stop.is_set():
        stop.wait(0.5)
    b.close()
    return 0
