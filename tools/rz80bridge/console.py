"""The bridge's console port (debug.md, section 3.6): a plain TCP port on
the monitor console. VS Code's terminal panel joins it; so can any
terminal program. Output goes to every client; what a client types is
sent to the board while no debug session is attached."""

import queue
import socket
import threading

BACKLOG_LINES = 50
ATTACHED = b"\r\n[attached: console on the screen only]\r\n"


class _Client:
    def __init__(self, server, conn):
        self.server = server
        self.conn = conn
        self.q = queue.Queue()
        self.alive = True

    def put(self, data):
        if self.alive:
            self.q.put(data)

    def writer(self):
        while self.alive:
            try:
                data = self.q.get(timeout=0.5)
            except queue.Empty:
                continue
            if data is None:
                break
            try:
                self.conn.sendall(data)
            except OSError:
                break
        self.server.drop(self)

    def reader(self):
        session = self.server.session
        while self.alive:
            try:
                data = self.conn.recv(4096)
            except OSError:
                break
            if not data:
                break
            if session.attached:
                self.put(b"\r\n[attached: typing goes nowhere until the debugger detaches]\r\n")
                continue
            session.link.write(data)
        self.server.drop(self)


class ConsoleServer(threading.Thread):
    def __init__(self, session, port=4781, host="127.0.0.1"):
        super().__init__(daemon=True)
        self.session = session
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind((host, port))
        self.sock.listen(4)
        self.port = self.sock.getsockname()[1]
        self.clients = []
        self.lock = threading.Lock()
        session.add_listener(self._event)

    def _send_all(self, data):
        with self.lock:
            clients = list(self.clients)
        for c in clients:
            c.put(data)

    def drop(self, client):
        client.alive = False
        self.session.console.leave(client._listener)
        with self.lock:
            if client in self.clients:
                self.clients.remove(client)
        try:
            client.conn.close()
        except OSError:
            pass

    def _event(self, kind, data):
        if kind == "attached":
            self._send_all(ATTACHED)
        elif kind == "detached":
            self._send_all(b"\r\n[detached]\r\n")

    def run(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            c = _Client(self, conn)
            c._listener = lambda text, c=c: c.put(text.encode("latin-1", "replace"))
            backlog = self.session.console.join(c._listener, BACKLOG_LINES)
            if backlog:
                with c.q.mutex:     # the backlog goes before anything queued since joining
                    c.q.queue.appendleft(backlog.encode("latin-1", "replace"))
                    c.q.not_empty.notify()
            if self.session.attached:
                c.put(ATTACHED)
            with self.lock:
                self.clients.append(c)
            threading.Thread(target=c.writer, daemon=True).start()
            threading.Thread(target=c.reader, daemon=True).start()

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass
        with self.lock:
            clients = list(self.clients)
        for c in clients:
            self.drop(c)
