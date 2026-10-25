#!/usr/bin/env python3
"""retro-z80's debug bridge (docs/spec/debug.md, section 3): one process
that owns the serial port and serves DAP (VS Code), MCP (Claude and other
MCP clients) and the monitor console at once.

    python3 tools/rz80_bridge.py --port COM5
    python3 tools/rz80_bridge.py --model          # the stub model, no board
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from rz80bridge.bridge import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
