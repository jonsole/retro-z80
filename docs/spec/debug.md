# Remote debugging protocol

Status: **draft**

This spec describes debugging a program on the real machine from VS Code, over the USB serial link: load, run, pause, breakpoints, watchpoints, step, registers and memory (design plan, branch 18). It has two parts:

- **The transport** (section 2): frames over the FT232H link, reusing the upload frames and CRC-32 of the shared spec "Monitor and upload protocol" ([`monitor.md`](monitor.md)), with a **channel** field so that console, debug and later video traffic can share the link. It is CPU-neutral and stands alone. It is **offered to retro68k to copy word for word**: retro68k uses its own debugger (the GDB remote protocol, with a stub in its ROM), but wants the same transport under it.
- **The debug channel** (sections 3–9): the commands between the bridge (`tools/rz80_bridge.py`) and retro-z80's debug stub in the boot ROM. This part is retro-z80's own. The register block is described by the machine itself (section 5.2), so the commands hold nothing Z80-only but the block's contents.

## 1. Summary

| Item | Value |
|------|-------|
| PC side | `tools/rz80_bridge.py`, one bridge process that owns the serial port and serves DAP on TCP to VS Code and MCP on HTTP to an MCP client, at once, as the ZX Spectrum emulator's `zx_server` (design plan, branch 20). It shares the link code (frames, CRC-32, BREAK, RESET, UPLOAD) with `rlink.py`. The VS Code extension in `tools/vscode/` registers the debug type `retro-z80`, starts or joins the bridge, and gives the console a terminal (section 3) |
| Transport | monitor.md's frames, TYPE `0x10` and up, with a CHANNEL byte in the OFFSET field; SYNC `LF` from the PC, `LD` from the machine (section 2) |
| Channels | 1 debug, 2 console, 3 video (reserved), 4 GDB (retro68k); the rest free |
| Launch | UPLOAD, the program uploaded with ACTION 0, then HELLO: the program is stopped at its entry point |
| Attach | The BREAK control command, then HELLO: the program is stopped where it was |
| Link while attached | The debug channel only. The program's console output goes to the screen only (section 4.3) |
| Commands | Hello and target description, registers, memory (CPU and physical addresses), MMU windows, breakpoints, watchpoints, continue, step, detach, a monitor command line (section 5) |
| Stops | Pause (BREAK), the NMI button, breakpoint n, watchpoint n (with the access), step done, the break call `RST 30h`, the trap `RST 38h`, entry, program ended (section 6) |
| Breakpoints | Hardware only (spec 18), so they work in ROM. A fifth is refused (section 7) |
| Step over, step out | Done by the adapter with breakpoints and steps (section 7.3) |
| Source level | Assembly, from sjasmplus SLD files; C later |

## 2. The transport (shared)

This section is CPU-neutral and is the part offered to retro68k word for word.

### 2.1 Frames

A transport frame has the layout of an upload frame (monitor.md, section 6.2), with the OFFSET field used as below:

| Offset | Size | Field | Value |
|--------|------|-------|-------|
| 0 | 2 | SYNC | ASCII `LF` (`0x4C 0x46`) from the PC; ASCII `LD` (`0x4C 0x44`) from the machine |
| 2 | 1 | TYPE | `0x10`–`0xFF`: the frame's kind within its channel. 0–4 stay the upload's (monitor.md) and carry no channel |
| 3 | 1 | SEQ | Counted by the sender, as each channel says |
| 4 | 1 | CHANNEL | Section 2.2 |
| 5 | 3 | – | 0 |
| 8 | 2 | LENGTH | n, 0–4,096 |
| 10 | 2 | NLENGTH | LENGTH with every bit inverted |
| 12 | n | PAYLOAD | As the channel says |
| 12 + n | 4 | CRC | CRC-32 of bytes 2 to 11 + n, the CRC of monitor.md, section 5.1 |

- Big-endian, as the upload frames.
- The receiver hunts for SYNC and drops other bytes, so frames can follow stray bytes or text. A frame whose bytes stop for more than 1 second is dropped.
- A frame with a bad CRC, a bad NLENGTH, LENGTH over 4,096, or bytes 5–7 not 0 is dropped by the transport, or answered as its channel says (the debug channel answers it, section 4.6).
- The control commands (BREAK, RESET, UPLOAD; each machine's serial spec) stay outside the frames: the hardware takes them out of the stream wherever they come.

### 2.2 Channels

| CHANNEL | Name | Carries | Used by |
|---------|------|---------|---------|
| 0 | – | Not used: the upload's own frames (TYPE 0–4) have no channel | – |
| 1 | DEBUG | Debug commands, replies and stops | retro-z80's debug stub and the bridge (sections 3–9) |
| 2 | CONSOLE | The serial console's bytes, in either direction (TYPE `0x20` DATA) | A bridge that carries the console and another channel at once |
| 3 | VIDEO | Screen capture, from the machine (TYPE `0x82`) | Reserved for later (section 10) |
| 4 | GDB | GDB remote protocol bytes, in either direction (TYPE `0x20` DATA) | retro68k's debugger |
| 5–255 | – | Free; a new use takes the next number, agreed in both repos | – |

- **Multiplexing.** The channel field lets several uses share the link at once: for example retro68k's `rlink.py` TCP bridge, carrying the console and GDB together (its serial open point U4).
- **One channel at a time is also allowed.** retro-z80 sends only the DEBUG channel while VS Code is attached; the console goes to the screen only (section 4.3).
- Each channel says its TYPE values, how SEQ counts, and whether its frames are answered. A stream channel (CONSOLE, GDB) needs no replies: its bytes are whatever the far side reads, and the CRC only lets a damaged frame be dropped.

## 3. The PC side

Design plan, branches 18 and 20. The PC side is shaped like the ZX Spectrum emulator's (`jonsole/zx-spectrum-emulator`): one process serves DAP and MCP, and the extension starts it or joins it. Its behaviour is copied where the two machines mean the same thing; its code is not (it is C++, this is Python).

### 3.1 Pieces

| Piece | Where | What it does |
|-------|-------|--------------|
| The bridge | `tools/rz80_bridge.py` and `tools/rz80bridge/` | Python 3, the standard library and `pyserial` only. **Owns the serial port** (only one process can open it). Serves DAP on TCP, MCP on HTTP and the console on TCP, all at once, to `127.0.0.1` only |
| The link code | `tools/rlink.py`, imported by the bridge | Frames, CRC-32, the control commands, the upload (monitor.md, section 8) |
| The MCP front | `tools/rz80_mcp.py` | MCP over stdio, for `.mcp.json`: uses a running bridge, or starts one on `RLINK_PORT` and stops it at the end; forwards every message to the bridge's MCP server |
| The stub model | `tools/rz80bridge/model.py` | A Python model of the board's debug stub and monitor behind a fake serial port, for tests and for working with no board (section 3.8) |
| The VS Code extension | `tools/vscode/` | Debug type `retro-z80`; starts or joins the bridge and connects VS Code to its DAP port (`debugServer`); the console terminal; the z80-asm language, asm index and sjasmplus finder; the program and watchpoint panels; the build task type. Plain JavaScript, no build step, no dependencies, as the zx extension. Files copied from the zx extension are listed in `tools/vscode/PROVENANCE.md` |
| Symbol files | The program's build | sjasmplus `--sld` output: addresses, pages, source lines, labels |

### 3.2 The bridge

| Item | Value |
|------|-------|
| Command line | `rz80_bridge.py --port COM5 [--dap-port N] [--mcp-port N] [--console-port N] [--model] [--no-advertise]` |
| Default ports | DAP 4780, MCP 8780 (`http://127.0.0.1:8780/mcp`, streamable HTTP), console 4781. Not the emulator's (4711, 8000), so both can run. Port 0 picks a free one |
| Advert | Once its ports are bound, the bridge writes `<pid>.json` (its pid, ports, serial port, start time, program last launched) into `$RZ80_BRIDGE_ADVERT_DIR`, else `%LOCALAPPDATA%\retro-z80\bridges` on Windows and `$XDG_RUNTIME_DIR` (or `~/.cache`)`/retro-z80/bridges` elsewhere: the zx emulator's advert layout, version 1 |
| At start | Opens the serial port and **leaves the board running**: it attaches only when asked (section 3.4) |
| Lifetime | Runs until stopped. Ending a VS Code debug session leaves it running, so MCP clients stay connected, as `zx_server` |
| One target | One board per bridge. A second board needs a second bridge on other ports |

### 3.3 launch.json

```json
{
  "type": "retro-z80",
  "request": "launch",
  "name": "Debug on the KS2",
  "port": "COM5",
  "program": "build/game.rimg",
  "sld": "build/game.sld",
  "stopOnEntry": true,
  "preLaunchTask": "retro-z80: build game"
}
```

| Field | Meaning |
|-------|---------|
| `port` | The serial port of the FT232H, or `model` for the stub model. Left out: the setting `retroz80.bridge.serialPort` |
| `program` | An image file with the 32-byte header (monitor.md, section 5), or a raw binary with `load` and `entry` given |
| `sld` | The symbol file, for source lines, labels and the call stack |
| `stopOnEntry` | Stop at ENTRY (true by default). With false, the adapter continues at once after the entry stop |
| `request` | `launch` (section 4.1) or `attach` (section 4.2) |
| `bridgePorts` | `{ "dap": n, "mcp": n, "console": n }`: join or start the bridge on these ports instead of the settings' |
| `preLaunchTask` | Usually a `retro-z80-build` task (section 3.7) |

The extension joins a bridge if one is listening on the DAP port, and otherwise starts one and waits for its port to answer, as the zx extension does with `zx_server`. A bridge started on another serial port than `port` is refused with a message, not taken over.

### 3.4 What VS Code shows

| View | From |
|------|------|
| Registers | READREGS, laid out as the target description says (section 5.2): the main and alternate registers, I, R, IM, IFF, and the flags decoded |
| MMU windows | READMMU: each window's read and write page |
| Memory | READMEM, CPU or physical addresses |
| Disassembly | READMEM, and the adapter's own Z80 disassembler |
| Call stack | The adapter walks the stack from SP and keeps each word that SLD knows as a return address (just after a `CALL` or `RST`) |
| Breakpoints and watchpoints | SETBP, SETWP; VS Code's data breakpoints are watchpoints |
| Debug console | CONSOLE: a monitor command line, and its output (section 5.9) |

### 3.5 Sharing the board: VS Code and MCP

- **Attach only when asked.** A VS Code launch or attach, or MCP's `launch` or `attach`, attaches (section 4). Every other MCP tool that needs a stopped machine answers "not attached" instead of stopping the board by itself.
- **One session.** Once attached, VS Code and MCP drive the same stopped program. A stop caused by either is seen by both: VS Code shows it in its call stack and registers but does not move its editor for a stop it did not ask for (the zx emulator's rule); MCP's `get_state` reports it.
- **One pool of breakpoints.** The 4 breakpoints and 2 watchpoints are shared, first come, first served. Each is kept with who set it (`vscode` or `mcp`). A fifth breakpoint or third watchpoint is refused: unverified in VS Code with "only 4 hardware breakpoints" (or "only 2 hardware watchpoints"), an error from MCP naming who holds them. `list_breakpoints` and `list_watchpoints` list all, with their owner. The adapter's own spare breakpoint for step over and step out (section 7.3) comes from the same pool, and only while a step needs it.
- **Detach.** A VS Code disconnect detaches only if MCP holds no breakpoints or watchpoints; otherwise it leaves the session to MCP. MCP's `detach` ends the session for both.

### 3.6 The console

While no session is attached, the monitor console goes through the bridge, since nothing else can open the port:

| Way in | What |
|--------|------|
| VS Code terminal | The extension's command **retro-z80: Console** opens a terminal panel joined to the bridge's console port: the monitor's output, and typed lines sent to it |
| MCP | `send_console(text)` types a line (or bytes); `read_console(since, max)` gives the output since a given line number. The bridge keeps the last 2,000 lines |

Output goes to every way in at once; input from either is sent as it comes. While attached, the console's serial side is off (section 4.3): the terminal shows `[attached: console on the screen only]`, and bytes the program writes to SERDATA directly are shown there as program output. The console port is a plain TCP port, so another terminal program can also join it.

### 3.7 MCP tools

The names and arguments are `zx_server`'s where they mean the same, so a client that knows the emulator knows these. Addresses take a number, or a string: hex as `"$8000"`, `"0x8000"`, `"8000"`, or a symbol expression such as `"loop+3"` once `load_debug_info` has loaded symbols. A banked address names its page in front: `"0x0A3:$4000"` (the page in that window, as SETBP's PAGE); a physical address is `"P012000"` (monitor.md, section 3.2).

| Tool | Does | As zx_server |
|------|------|--------------|
| `launch(program, sld, stop_on_entry)` | Upload and attach, stopped at ENTRY (section 4.1) | retro-z80's own |
| `attach()` / `detach(run)` | Attach to the running board (section 4.2); leave, with the program stopped or running (section 4.5) | Own |
| `reset()` | The RESET control command: ends any session | As `reset`, without a machine choice |
| `get_state()` | Attached or not, stopped or running, the last stop (REASON, PC with its symbol, the access for a watchpoint), breakpoints, watchpoints, call stack | Same |
| `get_registers(raw)` / `set_registers(...)` | READREGS and WRITEREGS: PC with its symbol, the flags spelled out, the instruction at PC; `raw` every register as a number | Same |
| `read_memory(address, length)` / `write_memory(address, data)` | READMEM and WRITEMEM; `P` addresses for physical; registers with read side effects read `0xFF` unless `side_effects: true` | Same, with `P` and pages in place of 128K banks |
| `get_mmu()` | READMMU: each window's read and write page | Own |
| `set_breakpoint(address)` / `clear_breakpoint(address)` / `list_breakpoints()` | SETBP and CLEARBP, from the shared pool (section 3.5) | Same |
| `set_watchpoint(address, length, access)` / `clear_watchpoint(id)` / `list_watchpoints()` | SETWP and CLEARWP. `length` becomes a mask, so a power of two, aligned; `access` `read`, `write` or `readwrite`, and `io: true` for ports. zx's `on_change`, `value` and `not_value` are refused (the hardware has no data compare) | Same, narrower |
| `step(instructions, mode)` | STEP, 1 or more times; `mode` `over` or `out` as VS Code's buttons (section 7.3) | Same, no `ticks`; `mode` is own |
| `run(wait, timeout_ms)` / `pause()` | CONTINUE, and with `wait` (the default) the stop; BREAK | Same |
| `load_debug_info(sld_path, asm_path)` | Load an SLD file for symbols and source lines | Same |
| `resolve_symbol(name)` / `resolve_address(address)` | Symbol to address, address to the nearest symbol and offset | Same |
| `monitor(command)` | CONSOLE: a monitor command line while attached (section 5.9) | Own |
| `send_console(text)` / `read_console(since, max)` | The console while not attached (section 3.6) | Own |
| `server_info()` | The bridge's pid, version, ports, serial port, start time, program last launched, advert path | Same |

No screen, video, audio, profile or rewind tools: the board cannot give them (screen capture is future, section 10).

### 3.8 Build task and stub model

- **Build task.** The extension adds the task type `retro-z80-build` (`source`, `output`, `load`, `entry`): it runs sjasmplus with `--sld`, then `rlink.py image` to wrap the binary in the image header. sjasmplus is found as the zx extension finds it (setting, `tools/`, PATH, or offered for download).
- **Stub model.** `--model` (or `"port": "model"`) runs the bridge against the Python model of the stub instead of a serial port: a 64 KB machine with eight MMU windows, the register block, 4 breakpoints and 2 watchpoints, a small Z80 interpreter enough to step and run test programs, and the monitor's prompt for the console. It is what the tests use (section 11), and what the extension and MCP are built against until the FT232H is fitted.

## 4. Entering and leaving debug mode

### 4.1 Launch

```
PC (the bridge)                               Machine
UPLOAD control command            ──►         reset; loader: LOAD Z80 1
HEADER, DATA …, END ACTION 0      ──►         the upload of monitor.md, section 6
                                              back to the monitor, PC = ENTRY
HELLO                             ──►         debug mode
                                  ◄──         REPLY K: the target description
                                  ◄──         STOP: ENTRY at ENTRY
```

The upload is exactly that of monitor.md (ACTION 0: back to the monitor with PC = ENTRY). The monitor, at its prompt, takes a HELLO frame on the serial link as the way into debug mode (section 4.4).

### 4.2 Attach

```
BREAK control command             ──►         NMI: the monitor is entered
                                  ◄──         (the monitor's NMI line; the adapter drops it)
HELLO                             ──►         debug mode
                                  ◄──         REPLY K: the target description
                                  ◄──         STOP: PAUSE at the program's PC
```

If the monitor is already at its prompt with a program stopped, the BREAK's NMI goes back to the prompt and keeps the stopped program as it was (spec 16, section 8.8); the STOP then gives the reason the monitor was entered.

### 4.3 While attached

- **The link carries only the DEBUG channel.** The stub sends nothing but replies and STOP frames; the PC sends nothing but commands, and BREAK while the program runs.
- **The program's console output goes to the screen only.** At HELLO the stub turns the console's serial side off for the program (CONMODE, spec 16, section 7.3), and puts it back at detach. A program that writes SERDATA directly still can: the adapter hunts for SYNC, drops other bytes, and shows them in the debug console as program output.
- **While the program runs** nothing on the machine reads the link. The adapter sends only BREAK (pause).
- **While the program is stopped** the stub runs in the NMI handler, or in the monitor after a break or a trap, with interrupts off, and answers commands one at a time.
- **The screen is not taken** while attached: the program's picture stays, so a stop does not disturb what is being debugged. The monitor's own screen comes back at detach.

### 4.4 How the monitor takes HELLO

At its prompt, the monitor watches the serial link for `L`, `F` followed by TYPE HELLO (`0x10`). It holds back a received `L` until the next byte shows it is not a frame. A whole HELLO frame with a good CRC enters debug mode; anything else is typed text, as before. The machine's own keyboards are not affected.

### 4.5 Leaving

| How | Then |
|-----|------|
| DETACH | Every breakpoint and watchpoint cleared; the console's serial side back; the monitor prints its usual stop message and prompt on both consoles. The program stays stopped; `G` goes on |
| CONTINUE with DETACH | Every breakpoint and watchpoint cleared; the console back; the program goes on, not attached |
| The PC goes away (VS Code stopped, cable pulled) | The machine stays as it is. A new attach (BREAK, HELLO) takes it over again. A stopped stub has no timeout |
| RESET or UPLOAD control command | Ends debug mode, as any reset does |

### 4.6 The DEBUG channel's frames

| From | TYPE | Name | SEQ | Payload |
|------|------|------|-----|---------|
| PC | `0x10`–`0x1F` | Commands (section 5) | Counts up by one for each new command (after 255 comes 0) | As the command |
| Machine | `0x80` | REPLY | The SEQ of the command it answers | STATUS (1), CODE (1), then data |
| Machine | `0x81` | STOP | The stub's own count of STOP frames | Section 6 |

A REPLY's payload is at most 2 + 2,048 bytes. Every command is answered:

| STATUS | Meaning | The adapter |
|--------|---------|-------------|
| `K` ok | Done; the data follow | Goes on |
| `C` CRC error | The CRC did not match; nothing was done | Sends the same frame again |
| `F` frame error | NLENGTH did not match, LENGTH was over 4,096, or bytes 5–7 were not 0 | Sends the same frame again |
| `R` refused | Not done; CODE says why | Reports it |

| CODE (with `R`) | Refused because |
|------|-----------------|
| 1 | Unknown TYPE |
| 2 | The payload's length or a field is wrong for the command |
| 3 | The address or range is not allowed (as the monitor's `? address`) |
| 4 | No such breakpoint or watchpoint number (section 7.1) |
| 5 | A watchpoint kind or mask the target description does not offer |
| 6 | The register block offset or length is outside the block, or names a read-only register |
| 7 | A console command that would run code or leave the monitor (section 5.9) |
| 8 | HELLO's protocol version is not one the stub speaks |

- **Repeats.** A command whose SEQ is that of the last command done is not done twice. If it only reads (HELLO, QUERY, READREGS, READMEM, READMMU), it is answered again, read afresh. Otherwise the stub answers with the STATUS and CODE it gave the first time, and no data.
- **Timing.** The stub answers within 1 s. The adapter waits 2 s, then sends the frame again; after 5 tries it reports the link as lost (as monitor.md, section 6.6).
- **Lost STOP frames.** STOP frames are not answered. An adapter that sees a damaged frame from the machine, or none when it expects one, sends QUERY, which gives the state and the last STOP again.

## 5. Commands

All values are big-endian, as in the frames. Addresses are 4 bytes; the stub ignores the bits above the target description's widths (CPU addresses 16 bits, physical 23 bits).

| TYPE | Command | Payload | Reply data |
|------|---------|---------|------------|
| `0x10` | HELLO | VERSION (1) | Target description (section 5.2) |
| `0x11` | QUERY | – | STATE (1): 1 stopped; then the last STOP payload |
| `0x12` | READREGS | – | The register block |
| `0x13` | WRITEREGS | START (1), bytes | – |
| `0x14` | READMEM | SPACE (1), FLAGS (1), ADDR (4), COUNT (2) | COUNT bytes |
| `0x15` | WRITEMEM | SPACE (1), FLAGS (1), ADDR (4), bytes | – |
| `0x16` | READMMU | – | For each window: READPAGE (2), WRITEPAGE (2) |
| `0x17` | SETBP | N (1), FLAGS (1), ADDR (4), PAGE (2) | – |
| `0x18` | CLEARBP | N (1) | – |
| `0x19` | SETWP | N (1), KIND (1), ADDR (4), MASK (4) | – |
| `0x1A` | CLEARWP | N (1) | – |
| `0x1B` | CONTINUE | FLAGS (1): bit 0 DETACH | – (the next STOP comes when the program stops) |
| `0x1C` | STEP | FLAGS (1): bit 0 INTO, step into interrupt handlers | – (then a STOP) |
| `0x1D` | DETACH | – | – |
| `0x1E` | CONSOLE | A monitor command line, ASCII, 1–80 bytes | Its output, ASCII, lines ending CR LF |
| `0x1F` | – | Reserved | |

There is no PAUSE command: pause is the BREAK control command (section 6). The reply to CONTINUE and STEP comes before the program runs.

### 5.1 HELLO

VERSION is the protocol version the adapter speaks: 1. The stub replies with the target description and enters debug mode (section 4), then sends a STOP. A HELLO while attached is answered again and sends the STOP again; it changes nothing else.

### 5.2 The target description

| Offset | Size | Field | retro-z80 |
|--------|------|-------|-----------|
| 0 | 1 | VERSION | 1 |
| 1 | 4 | MACHINE | `Z80 ` (as the image header, monitor.md section 5.1) |
| 5 | 1 | ADDRBITS: CPU address width | 16 |
| 6 | 1 | PHYSBITS: physical address width | 23 |
| 7 | 1 | NBP: breakpoints | 4 |
| 8 | 1 | NWP: watchpoints | 2 |
| 9 | 1 | WPKINDS: bit 0 read, bit 1 write, bit 2 I/O, bit 3 a mask | `0x0F` |
| 10 | 1 | NWIN: MMU windows | 8 |
| 11 | 1 | STEPS: bit 0 step, bit 1 step into interrupt handlers | `0x03` |
| 12 | 2 | MAXDATA: largest READMEM COUNT | 2,048 |
| 14 | 1 | BLOCKLEN: the register block's length | 28 |
| 15 | 1 | NREG: registers described | 16 |
| 16 | … | NREG register entries | Below |

Each **register entry** is: LEN (1), the name in ASCII (LEN bytes), OFFSET (1) in the block, SIZE (1) in bytes, FLAGS (1): bit 0 the PC, bit 1 the stack pointer, bit 2 a flags register (decoded by the adapter for the MACHINE), bit 3 read only. So the adapter needs no table of the CPU's registers.

**The register block** (28 bytes; every register big-endian, as the frames):

| Offset | Register | Size | Flags |
|--------|----------|------|-------|
| 0 | AF | 2 | Flags register |
| 2, 4, 6 | BC, DE, HL | 2 each | |
| 8, 10 | IX, IY | 2 each | |
| 12 | SP | 2 | Stack pointer |
| 14 | PC | 2 | PC |
| 16, 18, 20, 22 | AF', BC', DE', HL' | 2 each | AF' a flags register |
| 24, 25 | I, R | 1 each | R as the monitor keeps it (only roughly) |
| 26 | IFF | 1 | Bit 0 IFF1, bit 1 IFF2 |
| 27 | IM | 1 | 0, 1 or 2; `0xFF` when not known (the monitor's `?`, spec 16, section 8.3) |

### 5.3 READREGS and WRITEREGS

READREGS gives the whole block: the stopped program's registers. WRITEREGS writes LENGTH − 1 bytes into the block from offset START; a range outside the block, or one that covers a read-only register, is refused (6). The new values are used when the program goes on.

### 5.4 READMEM and WRITEMEM

| Field | Values |
|-------|--------|
| SPACE | 0 a CPU address, through the stopped program's map; 1 a physical address, page × `0x2000` + offset (the monitor's `P` addresses, monitor.md section 3.2) |
| FLAGS | Bit 0: also read registers whose reads have side effects. Without it, they read `0xFF` and are not touched (the monitor's `--`, spec 16, section 8.1) |
| COUNT | 1 to MAXDATA. The data of WRITEMEM is LENGTH − 6 bytes, 1 to MAXDATA |

The range may cross windows and pages; the stub follows the map. Memory the monitor forbids is refused (3) and nothing is read or written. Wide registers are written low byte first, so an MMU page commits on its high byte (monitor.md, section 3.3) when the adapter writes it in one WRITEMEM.

### 5.5 READMMU

Eight entries of READPAGE and WRITEPAGE: the stopped program's map, the copy the monitor keeps (spec 16, section 5.2).

### 5.6 SETBP and CLEARBP

| Field | Values |
|-------|--------|
| N | 0–3: the hardware breakpoint to set. The adapter chooses the number |
| FLAGS | Bit 0 PAGE: match the page too |
| ADDR | The CPU address of the instruction |
| PAGE | With PAGE: the read page (10 bits) that ADDR's window must hold. Otherwise 0 |

SETBP replaces whatever breakpoint N held. CLEARBP turns it off. Both act when the program goes on.

### 5.7 SETWP and CLEARWP

| Field | Values |
|-------|--------|
| N | 0–1 |
| KIND | Bit 0 READ, bit 1 WRITE (both for either), bit 2 IO: I/O ports instead of memory |
| ADDR | The address, or the 16-bit I/O port |
| MASK | Bit 1 = this address bit is compared, 0 = ignored. `0xFFFF` watches one address; `0xFFF0` 16 bytes |

KIND with neither READ nor WRITE is refused (2). Watchpoints compare data accesses, not opcode fetches; an instruction's operand bytes are memory reads and do count (spec 18, section 5).

### 5.8 CONTINUE, STEP and DETACH

- **CONTINUE** runs the stopped program with the registers as they now are. With DETACH, it leaves debug mode first (section 4.5).
- **STEP** runs one instruction and stops (reason STEP). Maskable interrupts are held off for the step unless INTO is set; with INTO, an interrupt taken at that point stops at the first instruction of its handler. A block instruction that repeats (`LDIR` and the others) steps one iteration; `HALT` steps past itself without waiting.
- **After EXIT** (the program ended), CONTINUE and STEP are refused (3): there is no program to run. A new launch, or `G` after detach, starts one.
- **DETACH**: section 4.5.

### 5.9 CONSOLE

A monitor command line, run as if typed at the monitor's prompt, against the stopped program. Its output comes back as the reply's data, at most 2,048 bytes (cut short beyond that). Commands that run code or leave the monitor (`G`, `N`, `U`, `L`, `B`, `X`, and `T`, which destroys memory) are refused (7); the adapter offers the VS Code buttons instead. So is an empty line when the monitor's last command was `N`, since Enter would step again (7).

## 6. Stops

The stub sends a STOP frame each time the program stops while attached, and once after HELLO.

| Offset | Size | Field | Value |
|--------|------|-------|-------|
| 0 | 1 | REASON | Below |
| 1 | 1 | N | The breakpoint or watchpoint number; otherwise 0 |
| 2 | 4 | PC | Where the program is stopped: the next instruction to run |
| 6 | 4 | AADDR | WATCHPOINT: the address or port accessed. Otherwise 0 |
| 10 | 4 | ADATA | WATCHPOINT: the byte read or written, in the low byte. Otherwise 0 |
| 14 | 1 | AKIND | WATCHPOINT: bit 0 WRITE (0 a read), bit 1 IO. Otherwise 0 |

| REASON | Name | Cause |
|--------|------|-------|
| 0 | ENTRY | Stopped at the entry point after a launch; PC = ENTRY |
| 1 | PAUSE | The BREAK control command: the NMI with NMISTAT.USB |
| 2 | BUTTON | The Multiface button: the NMI with NMISTAT.BUTTON |
| 3 | BREAKPOINT | Breakpoint N reached (spec 18); PC is its address, not yet run |
| 4 | WATCHPOINT | Watchpoint N hit (spec 18); PC is after the instruction that made the access |
| 5 | STEP | A STEP finished (spec 18) |
| 6 | BREAK | The program's break call: `RST 30h`, or `RST 28h` function BREAK; PC after it |
| 7 | TRAP | `RST 38h`, a fetch of `0xFF`; PC at the `0xFF` |
| 8 | EXIT | The program ended (returned, or called EXIT): `Program ended.` |

When several causes come together (a step whose instruction hits a watchpoint, say), REASON gives the first in this order: WATCHPOINT, BREAKPOINT, STEP, BUTTON, PAUSE. The adapter maps REASON to DAP's `stopped` event: `entry`, `pause`, `breakpoint`, `data breakpoint`, `step`, `exception` (TRAP), and to `exited` for EXIT. A reset seen on the link (the loader's ready line or the sign-on) ends the session in VS Code.

## 7. Breakpoints and stepping

### 7.1 Hardware breakpoints only

Breakpoints are the debug unit's (spec 18), never instructions written into memory, so they work in ROM and in pages the program has not mapped yet. There are 4. VS Code may ask for more; the adapter **refuses a fifth** by marking it unverified, with the message "only 4 hardware breakpoints". Watchpoints are the same, 2. The stub refuses a number beyond the hardware (4).

### 7.2 Source breakpoints

The adapter turns a source line into an address with the SLD file, and sets PAGE with the page the SLD gives for code in a banked window (sjasmplus's `SLOT` and `PAGE`). A line with no code moves to the next line that has some, as VS Code expects.

### 7.3 Step over and step out

The protocol has only STEP. The adapter makes the rest:

| VS Code | The adapter |
|---------|-------------|
| Step into | STEPs until the source line changes (one STEP in the disassembly view) |
| Step over | At a `CALL`, `RST` or block repeat instruction, sets a spare breakpoint after the instruction and CONTINUEs; otherwise as step into. If no breakpoint is spare, STEPs until it is back after the instruction with SP where it was |
| Step out | Sets a spare breakpoint at the return address of the current frame (from the call stack) and CONTINUEs, then clears it. If none is spare, STEPs until SP is above the frame |

A stop elsewhere (a user breakpoint, a watchpoint, a pause) ends the step over or out, and the adapter clears its spare breakpoint.

## 8. How the stub works

The stub is part of the boot ROM's monitor (spec 16, section 8.8). It runs on branch 17's NMI part: the NMI switches window 0 to the monitor page with writes to the workspace page, and the stack capture keeps the program's PC and SP in NMICAPPC and NMICAPSP (spec 2, section 9.7), so a stop touches none of the program's memory or stack. Its frame buffers are in SRAM page `0x0FC` (spec 16, section 5.3). It leaves by `RETN`, which also makes the debug unit live (spec 18, section 3).

## 9. Comparison with the upload

| | Upload (monitor.md) | Debug channel |
|---|------|---------|
| Frames from the PC | SYNC `LF`, TYPE 0–4, OFFSET | SYNC `LF`, TYPE `0x10`–`0x1F`, CHANNEL 1 |
| From the machine | A 5-byte reply, SYNC `LR` | Transport frames, SYNC `LD`: REPLY, STOP |
| Who runs it | The loader | The debug stub |
| A repeated SEQ | Answered `K` again, not used twice | The same; reads are done again |

## 10. Future: screen capture

CHANNEL 3, VIDEO, and its TYPE `0x82` are **reserved** for screen capture: a later unit that taps the final picture and sends slices of it on the link, so VS Code can show the screen in a panel, and the board's real output can be compared with the simulation's video model (design plan, branch 18, marked future). Its payload is specified later, together with retro68k, since both machines would want it. Until then nothing sends it, and receivers drop it.

## 11. Test plan

- **The transport:** `tools/test/test_bridge.py` checks frames both ways against monitor.md's layout and CRC (its check value), CHANNEL in byte 4, bytes 5–7 not 0, a frame among stray bytes, a frame cut short (the 1 s drop), the control commands between frames.
- **The bridge against the model:** `tools/test/test_bridge.py` runs the bridge against a Python model of the stub (a fake serial port), with no hardware: launch and attach, every command and reply, each refusal code, every STOP reason, a fifth breakpoint refused, step over and step out with and without a spare breakpoint, a CRC error and a frame error each way, a lost reply and a lost STOP (QUERY), a repeated SEQ for a read and for a write, detach and continue with detach. DAP is checked with recorded VS Code requests.
- **The stub in simulation:** the boot ROM's stub in the whole machine in Verilator, over the FT232H model (spec 10), driven by the bridge through a socket: launch a test program; a breakpoint in RAM, one in ROM and one with a page match in a banked window; both watchpoints (memory read, memory write, I/O write, a masked range); a step of each instruction class, `LDIR` and `HALT` included, and a step with INTO into an interrupt; pause while running; the program's serial output kept off the link; the screen untouched at a stop; no byte of the program's memory changed by a stop and a continue (a checksum); detach.
  - **Built** (ticket #29, `make -C sim link`, sim/README.md): the machine's link on a TCP socket, and the bridge's own session code on it, unchanged. A launch (UPLOAD, the upload with ACTION 0, HELLO at the prompt) stopped at ENTRY; the target description, the registers, memory and the MMU windows; a breakpoint in RAM, one in ROM, and one whose page does not match; a step; a memory read watchpoint; QUERY; every refusal code; a damaged command answered `C` and sent again; a repeated SEQ of a write not done twice; WRITEMEM and WRITEREGS; CONSOLE, with `G`, `N` and `T` refused; pause while running; detach, attach to the stopped program and to a running one. The same session runs against the stub model, and the two must agree but for the differences the script lists (the model's to change). Still to add: a page match in a banked window that does hit, the write, I/O and masked watchpoints, the step classes and INTO, the screen and the program's memory checked across a stop.
- **On the board:** a launch from VS Code on the KS2 once the FT232H is fitted: a source breakpoint, step, step over, a watchpoint, pause and continue.
- **The shared section:** once retro68k takes the transport, a check that section 2 is the same in both repos (as monitor.md, section 12).

## 12. Open points

Accepted as proposed on 25 October 2026. Still open: DB8 (whether `T` is allowed on CONSOLE), the future items DB10 and DB11, and branch 20's DB13–DB16.

| # | Item |
|---|------|
| DB1 | The transport (section 2) is offered to retro68k word for word. It keeps its own GDB stub, on CHANNEL 4. Until it adopts the section, this is retro-z80's proposal |
| DB2 | The channel byte sits in the upload frame's OFFSET field, so one frame parser serves the upload and the transport. A separate SYNC per channel was the other choice |
| DB3 | Launch uses ACTION 0 and then HELLO at the monitor's prompt, so monitor.md needs no new ACTION. A shared ACTION 2 ("enter debug mode, stopped at ENTRY") would save the prompt's watching for frames (section 4.4); proposed only if that proves awkward |
| DB4 | The register block is big-endian, as the frames, though the Z80 keeps words little-endian: one rule for every field |
| DB5 | Largest READMEM: 2,048 bytes, so a reply fits in one frame with room to spare. VS Code's memory view asks for small pieces anyway |
| DB6 | STOP frames are not answered; a lost one is recovered with QUERY. A reply to each STOP would make the stub wait after every stop |
| DB7 | Step over with no spare breakpoint steps one instruction at a time, about 1 ms each over USB: slow through a long subroutine. Keeping one breakpoint for the adapter (so the user gets 3) is the other choice |
| DB8 | CONSOLE refuses `G N U L B X T`. Whether `T` should be allowed |
| DB9 | The screen is not taken at a stop while attached (section 4.3). The monitor's own screen is used only at detach |
| DB10 | VIDEO (CHANNEL 3, TYPE `0x82`) is reserved for screen capture (section 10), to be specified later together with retro68k |
| DB11 | C source level (z88dk's debug output) is later; the protocol needs no change for it |
| DB12 | The stub's frame buffers take SRAM page `0x0FC` (kept for the ROM's later use, spec 16, section 5.3) while attached; a program being debugged keeps out of it |
| DB13 | Branch 20 (25 October 2026): the bridge's default ports, DAP 4780, MCP 8780, console 4781, chosen to sit beside the emulator's 4711 and 8000 |
| DB14 | Both this extension and the zx extension contribute the `z80-asm` language. With both installed, check that the grammars and the asm index do not clash; if they do, this one stands down when the zx one is present |
| DB15 | A VS Code disconnect leaves the session attached when MCP holds breakpoints or watchpoints (section 3.5); the other choice is to detach always |
| DB16 | Whether retro68k wants the same bridge, carrying its GDB channel (CHANNEL 4) and an MCP server: to ask its session |
