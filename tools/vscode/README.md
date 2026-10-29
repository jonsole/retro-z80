# retro-z80 VS Code extension

Debug Z80 programs on the real retro-z80 board from VS Code, through the bridge (`tools/rz80_bridge.py`; `docs/spec/debug.md`, section 3): upload and stop at the entry, source breakpoints (the debug unit's 4, so they work in ROM), watchpoints (its 2), step in, over and out, pause, the registers with the alternates and flags, the 8 MMU windows, memory and disassembly with labels, and the debug console as the monitor's command line. The board is shared with Claude over MCP: the same stops, one pool of breakpoints.

Also: the board's screen live in a tab, through a USB HDMI capture device, and typing on the board from that tab; the z80-asm language (colours, Go to Definition, hovers, references, the outline), the build task, the program panel for `.rimg` files, the board's watchpoints in the debug sidebar, and a terminal on the monitor console.

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

## The board's screen

The KS2's HDMI output, through a USB capture device (one that sends MJPEG, as most do; the KS2 gives 720 × 576 at 50 Hz), shown live in an editor tab, as the zx emulator's extension shows its screen.

1. Plug the KS2's HDMI into the capture device, and the capture device into the PC.
2. Install ffmpeg (`winget install Gyan.FFmpeg` on Windows). The extension finds it on the PATH or where winget, Chocolatey and Scoop put it; else set **retroz80.screen.ffmpeg**.
3. **retro-z80: Show Screen** opens the tab beside the editor, or brings it forward. A debug session on the board opens it too (**retroz80.screen.showOnDebug**).

The capture device is found by itself: one whose name says capture or HDMI. If there are several, **Choose Capture Device...** (a button on the tab) lists them and sets **retroz80.screen.device**; empty means auto-detect.

The tab's buttons: pause (it lets go of the capture device, so another program can use it), **Screen Scaling...**, save the frame as a JPEG, and the capture device. Screen Scaling picks the filter (nearest neighbour, sharp bilinear, bilinear) and the size (fit, fit in whole multiples, 1x, 2x), the zx emulator's choices; they are the settings **retroz80.screen.filter** and **retroz80.screen.scale**. The line at the bottom (on hover) says the device, the size and the frame rate, or what is wrong: no device, no picture, or the device in use by another program.

The tab streams only while it is visible. While it does, it serves its frames on 127.0.0.1 port 4790 (**retroz80.screen.port**, 0 for off), so the bridge's MCP tools `screen_capture` and `screen_record` share the device with it; with the tab hidden or paused they open the device themselves.

## Typing on the board

Click the screen tab and the keys you press go to the board: the corner says **Typing on the board**. Each key goes down and up as on a PS/2 keyboard: the PC sends the PS/2 bytes through the link's KEY command, which the FPGA feeds in as if a PS/2 keyboard had sent them (`docs/spec/serial.md`, section 4). So the monitor, programs that read the PS/2 keyboard, and Spectrum-style programs that read port `0xFE` all see them, whether or not a debugger is attached, and with the program stopped or running. Keys held when you click away are let go. The keys VS Code would normally take (Ctrl+P and the rest) go to the board while the tab has focus.

The keys go through the bridge's MCP port (**retroz80.bridge.mcpPort**), so a bridge must be running: a debug session, or **retro-z80: Start Bridge**. The tab says so if none answers. Port `0xFE` sees the PC keys as the Spectrum keys they map to (Shift is CAPS SHIFT, Ctrl and Alt SYMBOL SHIFT; `docs/spec/input.md`, section 8.3). The membrane's own key map (KEYMAP0–6) does not.

## Commands

| Command | Does |
|---------|------|
| retro-z80: Console | A terminal on the monitor console, through the bridge. While a debugger is attached the console is on the board's screen only |
| retro-z80: Start Bridge / Stop Bridge / Show Bridge Log | The bridge by hand |
| retro-z80: Watch Address... | A watchpoint on an address, a symbol or a port (also in the Board Watchpoints view) |
| retro-z80: Show Screen | The board's screen, through the capture device |
| retro-z80: Screen Scaling... | The screen tab's filter and size |
| retro-z80: Pause / Resume Board Screen | Stop streaming and free the capture device, or start again |
| retro-z80: Save Board Screen Frame... | The latest frame as a JPEG |
| retro-z80: Choose Capture Device... | List the video capture devices; set one, or auto-detect |
| retro-z80: sjasmplus Path | The sjasmplus the build uses, for a `tasks.json` of your own (`${command:retroz80.sjasmplusPath}`) |

Opening a `.rimg` shows its header, both CRCs, and Debug and Run buttons.

## With the zx emulator's extension

Both contribute the z80-asm language. With the zx one installed, this one leaves Go to Definition, hovers and the rest to it, so nothing is answered twice; the colours are the same grammar.

## Tests

`make -C tools vscode` (part of `make -C tools check`), or each file in `tests/` with `node`. `hdmi_stream_test.js` checks the JPEG splitter, ffmpeg's command line and the device list with no device. `extension_smoke_test.js` activates the extension against a stand-in for the vscode API, starts the real bridge on the model through the debug type's factory, and holds a debug session over it.
