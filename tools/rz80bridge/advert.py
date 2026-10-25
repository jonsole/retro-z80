"""The bridge's advert (debug.md, section 3.2): <pid>.json in a directory,
in the zx emulator's layout (cpp-core/src/server_registry.h), version 1,
so the extension finds running bridges the way the zx extension finds
running zx_servers. A killed bridge leaves its file behind; readers check
that the pid is alive."""

import json
import os
import socket
import sys
import time

ADVERT_VERSION = 1


def advert_directory(env=None):
    env = os.environ if env is None else env
    if env.get("RZ80_BRIDGE_ADVERT_DIR"):
        return env["RZ80_BRIDGE_ADVERT_DIR"]
    if os.name == "nt":
        base = env.get("LOCALAPPDATA") or os.path.expanduser("~")
    else:
        base = env.get("XDG_RUNTIME_DIR") or os.path.join(os.path.expanduser("~"), ".cache")
    return os.path.join(base, "retro-z80", "bridges")


class Advert:
    def __init__(self, ports, serial_port, version):
        self.dir = advert_directory()
        self.path = os.path.join(self.dir, "%d.json" % os.getpid())
        self.data = {
            "version": ADVERT_VERSION,
            "pid": os.getpid(),
            "serverVersion": version,
            "host": socket.gethostname(),
            "ports": ports,
            "serialPort": serial_port,
            "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "exe": os.path.abspath(sys.argv[0]),
            "cwd": os.getcwd(),
            "program": None,
        }

    def write(self):
        os.makedirs(self.dir, exist_ok=True)
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.data, f, indent=2)
        os.replace(tmp, self.path)

    def set_program(self, path):
        self.data["program"] = path
        try:
            self.write()
        except OSError:
            pass

    def remove(self):
        try:
            os.remove(self.path)
        except OSError:
            pass
