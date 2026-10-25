# retro-z80 VS Code extension

Debug Z80 programs on the real retro-z80 board from VS Code, through the bridge (`tools/rz80_bridge.py`; `docs/spec/debug.md`, section 3): upload and stop at the entry, source breakpoints (the debug unit's 4, so they work in ROM), watchpoints (its 2), step in, over and out, pause, the registers with the alternates and flags, the 8 MMU windows, memory and disassembly with labels, and the debug console as the monitor's command line. The board is shared with Claude over MCP: the same stops, one pool of breakpoints.

Also: the z80-asm language (colours, Go to Definition, hovers, references, the outline), the build task, the program panel for `.rimg` files, the board's watchpoints in the debug sidebar, and a terminal on the monitor console.

Plain JavaScript, no build step and no dependencies, shaped like the zx emulator's extension, much of whose code it carries (`PROVENANCE.md`).

## Install

Link this folder into VS Code's extensions folder, then **Developer: Reload Window**:

```
mklink /D "%USERPROFILE%\.vscode\extensions\jonsole.retro-z80-debug-0.1.0" "C:\path\to\retro-z80\tools\vscode"      (Windows, an administrator prompt)
ln -s "$PWD/tools/vscode" ~/.vscode/extensions/jonsole.retro-z80-debug-0.1.0                                       (elsewhere)
```

A link means a change here takes effect on the next reload. The bridge needs Python 3 and, for a real port, `pip install pyserial`.

## A first session, with no board

The bridge's stub model stands in for the board. In a launch configuration, `"port": "model"`:

```json
{
  "type": "retro-z80",
  "request": "launch",
  "name": "Debug on the model",
  "port": "model",
  "program": "${workspaceFolder}/build/game.rimg",
  "sld": "${workspaceFolder}/build/game.sld",
  "preLaunchTask": "build game"
}
```

With the board, `"port": "COM5"` (the FT232H's port), or set **retroz80.bridge.serialPort** once and leave `port` out. `"port": "tcp:127.0.0.1:PORT"` drives the simulated machine (`make -C sim link`).

F5 starts the bridge if nothing listens on its DAP port (4780), or joins the one that does: one started by another window, by `rz80_mcp.py` for Claude, or by hand. A bridge this window started stays up after the session, so Claude keeps the board, and stops when VS Code closes. The status bar shows it; click for its log.

`"request": "attach"` stops a program already running on the board where it is, instead of uploading.

## The build task

In `.vscode/tasks.json`:

```json
{
  "label": "build game",
  "type": "retro-z80-build",
  "source": "game.asm",
  "load": "8000",
  "includes": ["firmware/include"],
  "problemMatcher": "$sjasmplus"
}
```

It runs sjasmplus with `--sld`, then `rlink.py image`, leaving `build/game.bin`, `.sld` and `.rimg` beside the source (or at `"output"`). sjasmplus is the setting **retroz80.sjasmplus**, else the one on the PATH, else on Windows the pinned release, fetched once.

## Commands

| Command | Does |
|---------|------|
| retro-z80: Console | A terminal on the monitor console, through the bridge. While a debugger is attached the console is on the board's screen only |
| retro-z80: Start Bridge / Stop Bridge / Show Bridge Log | The bridge by hand |
| retro-z80: Watch Address... | A watchpoint on an address, a symbol or a port (also in the Board Watchpoints view) |
| retro-z80: sjasmplus Path | The sjasmplus the build uses, for a `tasks.json` of your own (`${command:retroz80.sjasmplusPath}`) |

Opening a `.rimg` shows its header, both CRCs, and Debug and Run buttons.

## With the zx emulator's extension

Both contribute the z80-asm language. With the zx one installed, this one leaves Go to Definition, hovers and the rest to it, so nothing is answered twice; the colours are the same grammar.

## Tests

`make -C tools vscode` (part of `make -C tools check`), or each file in `tests/` with `node`. `extension_smoke_test.js` activates the extension against a stand-in for the vscode API, starts the real bridge on the model through the debug type's factory, and holds a debug session over it.
