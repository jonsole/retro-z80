"""The simulated machine's USB link as a link object for the PC tools (ticket #29).

tb_link.v runs the computer in Verilator with the PC's side of its FT232H
on a TCP socket (link_main.cpp; sim/README.md, "The link on a socket"):
a plain byte stream both ways, the bytes the PC would write to the serial
port and the bytes it would read back. SimLink gives that socket the shape
of rlink.SerialLink, write(bytes) and read_some(timeout), so the debug
bridge (tools/rz80bridge) and rlink.py drive the simulation unchanged.

    sim = start_sim("build")              # runs build/vl_link/vlink
    link = SimLink(sim.port)
    ...
    link.close(); sim.wait()              # closing the socket ends the run
"""

import os
import select
import socket
import subprocess
import threading


class SimLink:
    """The PC's end of the simulated link."""

    def __init__(self, port, host="127.0.0.1"):
        self.sock = socket.create_connection((host, port), timeout=30)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.sock.settimeout(None)
        self.lock = threading.Lock()
        self.closed = False
        self.sent = 0
        self.received = 0

    def write(self, data):
        with self.lock:
            self.sock.sendall(bytes(data))
            self.sent += len(data)

    def read_some(self, timeout):
        if self.closed:
            return b""
        r, _, _ = select.select([self.sock], [], [], max(0.0, timeout))
        if not r:
            return b""
        try:
            data = self.sock.recv(65536)
        except OSError:
            data = b""
        if not data:
            self.closed = True
        self.received += len(data)
        return data

    def close(self):
        if not self.closed:
            self.closed = True
            try:
                self.sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self.sock.close()


class Sim:
    """The running simulation: its port, and its output lines once it ends."""

    def __init__(self, proc, port):
        self.proc = proc
        self.port = port
        self.lines = []
        self._t = threading.Thread(target=self._drain, daemon=True)
        self._t.start()

    def _drain(self):
        for line in self.proc.stdout:
            self.lines.append(line.rstrip("\r\n"))

    def wait(self, timeout=60):
        try:
            self.proc.wait(timeout)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        self._t.join(5)
        return self.lines


def start_sim(build, maxms=0, port=0):
    """Starts build/vl_link/vlink (in build, where mon_rom.hex is) and waits for its port."""
    exe = os.path.join(build, "vl_link", "vlink")
    if os.name == "nt" and not exe.endswith(".exe") and os.path.exists(exe + ".exe"):
        exe += ".exe"
    args = [os.path.abspath(exe), "+port=%d" % port]
    if maxms:
        args.append("+maxms=%d" % maxms)
    proc = subprocess.Popen(args, cwd=build, stdout=subprocess.PIPE, text=True)
    line = proc.stdout.readline()
    if not line.startswith("LISTENING "):
        proc.kill()
        raise RuntimeError("the simulation did not start: %r" % line)
    return Sim(proc, int(line.split()[1]))
