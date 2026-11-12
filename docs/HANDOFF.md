# retro-z80 handoff

Where the project stands, what is unfinished, and how to carry on. Updated on 23 October 2026, after branch 11 (retro68k's memory timing and video design) and branch 12 (the KS2 as first board).

## 1. The project

retro-z80 is the 8-bit sister of [retro68k](https://github.com/jonsole/retro68k): a Z80 computer inside the FPGA of a ZX Spectrum Next, for use as a home computer and a games machine. It is **retro68k narrowed to 8 bits**: the same blocks, register names, bit layouts, memory timing and video/sprite design, with byte-wide registers, differing only where the Z80 forces it, plus Spectrum extras in sections of their own.

- **Repo:** `jonsole/retro-z80`. Work goes on `main`.
- **retro68k** (`jonsole/retro68k`) is the model: its specs, guides (`docs/guide/`) and RTL. Clone it next to this repo.
- **Boards:** the **KS2** (issue 4, XC7A15T) is here and is the first hardware target, for a bring-up build loaded over JTAG with a Xilinx Platform Cable USB. The **KS3** (issue 5, XC7A35T) arrives in a few weeks and runs the full machine. No FT232H module yet.
- **Phase:** 0 (planning). Nothing in `fpga/`, `firmware/` or `hardware/` exists yet.

## 1a. Latest milestone (25 October 2026)

**Guide review and AI documents (12 November 2026, branch `guide-review`):** every guide chapter checked against the specs and the RTL as built and corrected: the old DMA engine gone from chapters 1, 2, 5, 7 and 9 and appendix A; live layer CTRL, the program map and the unbuilt attribute layer, direct colour and sprite sequencer in chapters 3 and 4; interrupt source 9 and the timers' DMA bits in chapter 2. Chapter 6 rewritten for the blitter and the rasteriser (#104), its eight examples run on the KS2 with measured speeds (fill 22.3 MB/s, copy 14.8 MB/s; spec 14 D2, spec 19 RA4); a triangle job on the KS2 is an error. New chapter 10, Audio Hardware (`docs/guide/sound.md`, `examples/sound`: tone, shot, stream), checked against a model in simulation and by read-back on the KS2 (not yet listened to). New `docs/llm/`: an llms.txt index, a system page and one reference per unit for an AI writing programs, with register tables from `tools/llm_docs.py` (`--check` regenerates nothing and checks tables, names and every fragment). Found: #115 (a copper BPLSTRIDE write acting a line early).

**Ticket #103 (10 November 2026, done; guide chapter 6 in #104):** the DMA engine is replaced by retro-hw's shared **blitter** core (revision 2), as retro68k did on its branch `blitter2`: one job in the registers or a chain of 32-byte little-endian descriptors in SRAM, no channels, no ADD, LINE or EDGES, no timer starts, PAUSE or CHERR; interrupt source 4 (BLT); registers BLTCTRL…BLTNEXT, BLTDESC, BLTCMD, BLTSTAT at custom `0x140`–`0x168`, DMXINT and DMXINTEN unchanged. Spec 14 is rewritten as "Blitter" (version 2), the other specs and design plan branch 21 follow. VALUE is in pixel order (bits 15–8 the even byte), not the SRAM's byte order. The KS2 build, the board test, the speed (D2) and chapter 6 are done. The rasteriser (lines and triangles, retro-hw's `raster`) follows in #110.

**Ticket #110 (11 November 2026, done):** retro-hw's **rasteriser** core (`raster`, revision 1) beside the blitter in `fpga/rtl/dmx.v`, as retro68k did on its branch `raster` (its spec 17): LINE and flat-filled TRI jobs from screen points, clipped to a shared window, as a 32-byte little-endian descriptor at custom `0x180`–`0x19F`; RASDESC, RASCMD, RASSTAT at `0x1A0`–`0x1A8`; RASCLIPMIN, RASCLIPMAX at `0x1AC`, `0x1B0`. It shares DMXINT/DMXINTEN (bit 1, RAS) and interrupt source 4 with the blitter (source 5 is no longer kept), DMACON.BLTEN enables both, the copper's WAIT B waits for both, and it is scheduler requester 6 (the DMA port moves to 7), free cycles only. New spec 19 ([`rasteriser.md`](spec/rasteriser.md)); specs 2, 3, 6, 8, 14, 15 and design plan branch 21 follow. retro68k's choices are provisional (its user has not reviewed them; spec 19, RA1). The KS2 builds lines only (`DMX_TRI = 0`, RA3); the guide covers it in chapter 6.

**Ticket #113 (11 November 2026, done, PR #114):** sound (design plan Q1 closed, branch 9): retro-hw's shared **`audio_engine`** (revision 3, locked; NCH 4, INTERP 1, RDBACK 1, LE 1, AW 21) wrapped by `fpga/rtl/audio.v`, as retro68k's audio (its spec 6, branch `hw-audio`) narrowed to bytes: AUDRATE, AUDSTAT, AUDINTEN, AUDSTART, AUDSTOP at custom `0x244`–`0x258` (retro68k's offsets less `0x1C0`), the channels at `0x280` + n × `0x20` (CTRL, LC, LEN, STEP, VOL, POS a 4-byte word each; POS through the capture). New: **AUDDMA** (`0x25C`, set/clear) holds retro68k's DMACON.AUD0EN–AUD3EN, with DMACON.AUDEN as audio's master bit (spec 13, AU3). Interrupt source 9 (AUDIO), scheduler requester 2 (cycle 4). The beeper is added to the mix with clipping. A channel register read is registered in the wrapper and answered a clock later (`rb_late` into `bus_if.v`). The KS2 builds the rasteriser with lines only (`DMX_TRI = 0`; spec 19, RA3 closed). New spec 13 ([`sound.md`](spec/sound.md)); specs 1–4, 6–8, 14, 19 and the design plan follow. `make atest` (retro68k's atest on the Z80: every output sample against a model, plus read-backs, the capture, the interrupt, AUDEN) passes. Open for the user: spec 13, AU1–AU4 (retro68k's unreviewed choices, AUDSTAT against DMXINT, AUDDMA, the beeper's idle level). KS2: 9,826 logic LUTs (94.5%), timing met (AU6); on the board by read-back; guide chapter 10. Still to do: listen on the jack.

**retro-hw main 3dd6012 (11 November 2026):** the submodule moves from 5e58abf to retro-hw's main after its PRs #17 to #21: the sprite FIFO's safe clock crossing (`sprites.v` and `video.v` pass `sprite_pix`'s binary read pointer, `rp`), the blitter and raster resets of their data registers and the raster's one-clock step outside the window (spec 14 D7, spec 19 RA5 and RA6 closed; the tests' first-job workarounds removed), size savings in `layer_pix` (revision 6, locked) and `layer_fetch` (revision 5, one write port), and the new shared `audio_engine` (revision 3, locked; not yet used here). Blitter (revision 2) and raster (revision 1) are locked. Each retro-hw change was gated here in Vivado out of context before its PR. KS2: 9,692 logic LUTs (93.2%, from 95.7%), timing met; the raster and blitter demos run on the board. Next: port `fpga/rtl/audio.v` to `audio_engine` (spec 13).

**On the KS2, all confirmed by the user:** the HDMI test pattern (#10); the computer passing its self-test on the real 2 MB SRAM (#11); IM 2 interrupts from VBLANK (#16); timers and the watchdog (#17); layer L0 as a bitmap (palette chart, #13) and as a full-screen smoothly scrolling tile map (#14); the 80 x 30 boot console (#15); the membrane keyboard and port 0xFE (#19). 4,663 LUTs (45% of the XC7A15T), 100 MHz met. Still to check: VGA (#12), PS/2 and joysticks (#20). Phase 1 in simulation is complete, including ZEXDOC on the whole machine (#7). Build and load: `fpga/ks2/README.md`. Way of working: hardware first (CLAUDE.md).

**Ticket #22 (built, to be tried on the KS2):** the boot ROM is now the monitor of spec 16 and the shared monitor spec: the RST calls and `RST 28h` functions 0x00-0x11, start-up with the self-test at power-on only, the commands D E F C V S G R P H with sizes, P addresses and the side-effect rule, breakpoints, RST 30h and the trap. The old bring-up demos are gone but the tape loader (EDIT or Tab on an empty line). In simulation: `make -C sim mon` (a scripted session over serial, in Verilator). The KS2 README has a "try this" session.

**Ticket #27 (built, to be tried on the KS2):** the NMI is wired (Multiface button, BREAK), with the NMI set of the interrupt pages (`fpga/rtl/intpages.v`: window 0 reads ROM page 3 and writes the workspace page; the pages in distributed RAM, copied one window a clock) and the stack capture (NMICAPPC, NMICAPSP; RETN pops from the capture). The boot ROM's NMI page enters the monitor without touching the program's memory (`NMI (button) at`, `NMI (USB) at`; `G` goes on through the save area). In simulation: `make -C sim nmitest`, and NMI stops in `make -C sim mon`. The maskable interrupt pages are still to come.

**Ticket #28 (built, to be tried on the KS2):** the debug unit of spec 18 (`fpga/rtl/dbgunit.v`, registers in I/O page `0x02`): single step, 4 breakpoints with an optional page match, 2 watchpoints, all on the NMI, /INT held off during a step unless STEPINT. The monitor's `G addr break` now uses breakpoint 0 (works in ROM; nothing written into the program), `N` steps one instruction (`Step at <addr>`, Enter steps again), and a watchpoint set by hand with `P` stops with `Watchpoint n at <addr> (write <addr>: <data>)` (that message is a proposal, spec 16 open point B18). In simulation: `make -C sim dbg` (each stop reason and its timing; DU6 confirmed), and N, a ROM breakpoint and a watchpoint in `make -C sim mon`. The debug stub for VS Code (debug.md) is still to come.

**Ticket #31 (built, to be tried on the KS2):** the sprites of spec 5 (design plan branch 19): retro68k's `sprites.v` and `sprite_pix.v` (its main, 973fbcb) narrowed to byte registers, all eight on the KS2 (`NSPRITES = 8`; 8,417 LUTs, 81%, 100 MHz met), with SPRPALETTE and SHAREPAL, DEPTH among the layers (and spec 4's PRI tile place), the collisions, SPRUNDER and the VIDERR request; sprite fetches never take the CPU's cycle. The boot ROM's sprite demo is F1 (or GRAPH) on an empty command line: eight Amiga "Boing" balls spinning by palette cycling over the tile scroller (`sprdemo.asm`, ROM page 3; `fpga/ks2/README.md` says what to look for). In simulation: the sprite screens against the video model (`make -C sim vtest VTESTS=q` locally, `s` and `h` in CI), now in a Verilator build of the system testbench (about a minute each, against 12 minutes in Icarus), and `make -C sim boing` grabs a frame of the demo. Next (branch 19): the copper (spec 6), and the demo moves to it.

**Ticket #29 (built, in simulation; on the KS2 only a regression check until the FT232H is fitted):** the debug stub of debug.md in the boot ROM (`firmware/boot/stub.asm`) and the board half of #24's loader it needs (`link.asm`: CRC-32, the transport frames both ways, `U` and UPLOAD for TARGET 0, ACTION 0 and 1). A HELLO frame at the monitor's prompt enters debug mode; the stub answers every command of debug.md, section 5, with the monitor's own code, and every stop while attached is a STOP frame. Page 0 is now 6.8 KB (1.2 KB left), the CRC table 1 KB in page 2; 23.2 KB of the ROM's 32 KB in all (spec 16, B6). In simulation: `make -C sim link` runs a whole session through the bridge (`tools/rz80bridge`, unchanged) with the machine's link on a TCP socket (`sim/link/`: launch, registers, memory, breakpoints in RAM and ROM, step, a watchpoint, QUERY, refusals, a damaged frame, pause, detach and attach), and the same session against the bridge's stub model; they agree but for the model's differences listed in `sim/link/session.py` (the alternate registers and I at entry, IM after running on main, D's layout). The PC side (#30, #33, #34) is the other session's.

**Ticket #32 (built, to be tried on the KS2):** the copper of spec 6 (`fpga/rtl/copper.v`, retro68k's narrowed to 16-bit words with 8-bit data): every instruction, the reserved encodings, the two-word prefetch, RESUME, STKKEEP, the COPPER interrupt; it goes first on the register bus (the CPU's strobe moves a clock, `bus_if.v`) and has its own colour assembly buffer (`video.v`). The macros are `firmware/include/copper.inc`. The sprite demo (F1 or GRAPH) now writes no video registers from the CPU: a double-buffered copper list sets the sprites, the scroll and the spinning palette in the vertical blank, then paints 48 rolling rainbow bands down the picture (WAIT and BGCOLOR). 9,271 LUTs (89.1%), 100 MHz met (+0.064 ns) with harder Vivado directives (`build.tcl`; builds now take about 10 minutes). In simulation: `make -C sim cop` (every instruction and its timing against a model, about 30 s), `make -C sim coppal` (CPU and copper palette writes interleaved), `make -C sim boing`. Open points C13 and C14 closed with retro68k. Next (branch 19): the sprite sequencer.

## 2. Where things are

| File | What |
|------|------|
| `docs/design-plan.md` | Decision table (section 1: branch 9 realignment, 10 geometry unit, 11 retro68k's timing and video, 12 KS2), D1–D11, port map, specs, phases, open questions |
| `docs/spec/bus-interface.md` | Spec 1: tv80 at 20 MHz on 100 ns slots, CPUSPEED divider, I/O decode (register:page), register bus, interrupts, NMI paging |
| `docs/spec/memory.md` | Spec 2: retro68k's slots and scheduler, SRAM controller, MMU, register page |
| `docs/spec/registers.md` | Spec 3: rules and exceptions, every port and offset, register page, interrupt sources, the generator |
| `docs/spec/video.md` | Spec 4: three layers (bitmap or tile map), PRIO, direct colour, 24-bit palettes; Spectrum extras |
| `docs/spec/sprites.md` | Spec 5: retro68k's 8 sprites with fractional scaling |
| `docs/spec/copper.md` | Spec 6: retro68k's copper in 16-bit words |
| `docs/spec/system.md` … `input.md` | Specs 7–12: system and boot console, interrupts, timers, USB serial, SD card, input |
| `docs/spec/dma-engine.md` | Spec 14: the blitter (version 2, #103): retro-hw's `blitter` core wrapped by `fpga/rtl/dmx.v`, as retro68k's spec 11. Version 1, before #103: the DMA engine, 4 channels, with an Amiga-style blitter (A, B, C into D through a minterm), adopted by retro68k. Built (ticket #39, `fpga/rtl/dmx.v`, `make dmx`, `examples/blitter`) and tried on the KS2, which builds 2 sprites and no mask image; next #40 (random-job test), #41 to #43. Compare with retro68k's merged rework once its PR #24 is in; guide chapter `docs/guide/blitter.md` |
| `docs/spec/boot-rom.md`, `monitor.md` | Spec 16: the boot ROM (draft); the shared spec "Monitor and upload protocol" (draft, for retro68k to adopt) |
| `docs/spec/sound.md` | Spec 13: sound (#113): retro-hw's `audio_engine`, four sample channels, wrapped by `fpga/rtl/audio.v` with the beeper; `make atest`. Spec 15, the geometry unit, is a draft (branch 10, 30 October 2026) |
| `docs/guide/` | The programmer's guide, chapters 1–10 and appendix A, in the Amiga Hardware Reference Manual's style (numbered tables, bit tables top bit first, worked encodings). Written and checked with the skill `.claude/skills/writing-programmer-guide`. Every complete example in `examples/<topic>/` was run on the KS2 (MCP `screen_capture`, `read_console`) except chapters 3 and 4's (#54) |
| `docs/guide/system.md` | Chapter 1: introduction and system control: memory and the MMU, the registers (ports, the register page), sharing memory, the system registers, reset and the boot ROM, programs, and a program built step by step. `examples/system` (1-1 one page in two windows, 1-2 about the machine, 1-3 the register page) |
| `docs/guide/interrupts.md` | Chapter 2: interrupts and timers: IM 2 and the table, handlers, INTENA, SOFT, TIME, the timers, the watchdog; advanced topics (nesting, IM 1, the NMI, interrupt pages); timing. `examples/interrupts` (2-1 VBLANK and SOFT, 2-2 timing with TIME, 2-3 a timer interrupt, 2-4 the watchdog, 2-5 LINE, BEAMPOS and FRAMECOUNT) |
| `docs/guide/playfields.md` | Chapter 3: playfields: bitmaps, tile maps, scaling, scrolling, split screens, priority, palettes, the fetch budget, the Spectrum extras, the limits. Its examples are still fragments under the reset map (#54) |
| `docs/guide/sprites.md` | Chapter 4: sprites and the sprite sequencer; the KS2 builds 2 sprites. Examples still fragments (#54) |
| `docs/guide/copper.md` | Chapter 5: the copper: instructions as bit tables, WAIT, loops, mid-line colours, its registers and ALU, the copper interrupt, two lists, timing. `examples/copper` (5-2 bars, 5-3 scan lines, 5-4 mid-line ink, 5-5 a split screen, 5-6 a raster bar from COPINT) |
| `docs/guide/blitter.md` | Chapter 6: the blitter and the rasteriser (#104): job layouts, chains, minterms, key masks, depths and BIT fields, strides, RTL and negative strides, constants in pixel order, lines with patterns, NOLAST and the clip window, triangles (KS3 only), the copper, speed measured on the KS2; figures 6-2 to 6-10 drawn by `tools/guide_figures/blitter.py`, 6-12 by `dmxpipe.py`. `examples/blitter` (6-1 clear, 6-2 bob, 6-3 shift, 6-4 scroll, 6-5 line, 6-6 cube with `cube.py`, 6-7 split (balls at 8 and 4 bpp, copper split), 6-8 speed), all run on the KS2; `blitter.asm` and `raster.asm` the bring-up demos (`raster.asm` draws triangles: KS3 only) |
| `docs/guide/serial.md` | Chapter 7: the USB serial link and debugging: bytes, OTIR/INIR, flow control, interrupts, the PC's commands and escapes, uploading, VS Code and MCP. `examples/serial` (7-1 echo, 7-2 16 KB with OTIR, 7-3 interrupt-driven) |
| `docs/guide/io.md` | Chapter 8: keyboards and joysticks: port 0xFE and the membrane, KEYMAP, the PS/2 keyboard and mapper, keys from the PC, the joysticks. `examples/io` (8-1 the border, 8-2 PS/2 scan codes) |
| `docs/guide/geometry.md` | Chapter 9: the geometry unit: the window and its five banks, GEOCTL and GEOSTAT, the numbers (2.14), a vertex step by step, the combined matrix and the product bank as a matrix multiplier, the near plane, culling with CAM, the face sign, INV, multiply and divide, timing from the board. `examples/geometry` (9-1 first, 9-2 cube, 9-3 ring, 9-4 faces, 9-5 calc; `screen.inc` a 256 × 192 1 bpp screen with a software line drawer, `cube.inc`, `tables.py`; `geomtest.asm` the board test). Needs the KS2's `--geom` build |
| `docs/guide/sound.md` | Chapter 10: audio hardware: the output rate, the channel registers, one-shot and looped blocks, AUDSTAT and the AUDIO interrupt, double buffering, pitch, volume and pan, interpolation, 16-bit samples, the beeper. `examples/sound` (10-1 tone, 10-2 shot, 10-3 stream) |
| `docs/guide/timing.md` | Appendix A: timing and screen reference, figures to scale |
| `docs/llm/`, `tools/llm_docs.py` | Documents for an AI writing programs for the machine: `llms.txt`, `system.md` and one file per unit; their register tables are generated from `fpga/regmap.def` by `tools/llm_docs.py` (`--check` before committing) |
| `docs/guide/img/`, `tools/guide_figures/` | The guide's SVG figures, and the scripts that draw the to-scale ones |

## 3. The machine in one page

- **CPU:** tv80, 20 MHz top speed (CPUSPEED divider: 20, 10, 6.67, 5, 4, 3.33, 2.86, 2.5 MHz, plus 3.57 MHz); never waits for memory. IM 2 (IM 1 also works).
- **Memory:** retro68k's: 100 MHz, 20 ns cycles, 100 ns slots; cycles 0 and 2 CPU, 1 and 3 display, 4 audio and the free pool. 4 MB on the KS3, 2 MB on the KS2. MMU: eight 8 KB windows with read and write pages.
- **Registers:** ports are register (high byte) : page (low byte); page `0x00` the system block, `0x10`–`0x13` the custom block; `OUT (C),r` to write, `LD A,reg` then `IN A,(page)` to read; `0x1F`, `0xFE` and the stream ports ignore the high byte. All also in the register page (MMU page `0x3F8`).
- **Video:** 576p HDMI + VGA; three layers, each a chunky bitmap or a tile map, 1×–8×, PRIO, direct colour; 24-bit palettes; 1.48 bytes per pixel.
- **Sprites:** 8, any size, 2/4/8 bpp, fractional scaling, DEPTH, collisions.
- **Copper:** MOVE/WAIT/SKIP/JUMP, MOVR, ALU, SKIPC, CALL/RET in 16-bit words.
- **Blitter:** one job or a chain of descriptors, D = minterm(A, B, C) at 1–8 bpp, SRAM only (#103; was the 4-channel DMA engine).
- **I/O:** serial, SD, PS/2, joysticks (six-button pads), 4 timers, watchdog, I2C; Spectrum extras `0xFE`, `0x1F`, attribute layer, NMI monitor paging.

## 4. How decisions are made

The user prefers a **decision tree**: 1–4 multiple-choice questions per step (or numbered rounds with a recommendation each), the recommended option first, then the answers written into the plan. Decisions go into the design plan's table first and are binding for the specs; anything a spec decides on its own goes into its open points.

**Spec style** (follow retro68k's specs): plain, short sentences; British spelling; `# Spec N: Name`, `Status: **draft**`, a summary table, a "Comparison with retro68k" section, register tables, a test plan and open points.

**Check retro68k first**, including its latest commits: it is still moving (it added fractional sprite scaling and its version-1 DMA engine on 23 October 2026).

## 5. Unfinished work (do this first)

1. **Points for the user** from the branch 11 rewrite:
   - HSTART signed or unsigned (spec 5, S3): retro68k's RTL and guide are unsigned, its register table says signed.
   - ~~The DMA engine reads the boot ROM; DMA port jobs over the register bus~~: gone with the DMA engine (#103). The blitter reaches SRAM only.
   - Byte names: L/H (MMUnL) or 0/1/2 (SPRxPT0)? Mixed today (spec 3, R10).
   - Video: port `0xFE` border colours change on whole lines (retro68k's BGCOLOR rule), not mid-line (spec 4, V7); no BPLxDAT/BPLDMA (V5); PALDAT as a stream port (spec 3, R12).
2. **Programmer's guide:** chapters 1–10 and appendix A are written, in the manual's style, and checked against the hardware (12 November 2026). Chapter 3's examples are inline in the chapter and loop for ever rather than files that return to the monitor. Still to do: chapters 3 and 4's examples as files run on the KS2 under the program map (#54); spec gaps: no generated names for WINX/WINY/BEAMPOS halves and MMU page numbers; level-sensitive VBLANK re-entering ported Spectrum handlers.
3. **Geometry unit (spec 15)**, branch 10: RTL done (`GEOM = 1` on the KS2, #67). The fast3d benchmark (#68, `examples/fast3d`): 268,245 T-states a picture with the unit against 472,907 in software; drawing is now most of it (spec 15, section 10). G1 done in software on the KS2: the EDGES job (#75; 351,912) and the DMA clear (#74; 433,002 alone, 311,801 with EDGES); the unit and the engine together wait for the KS3. Since #103 the EDGES job and the DMA clear are gone: the rasteriser's LINE jobs and the blitter replace them, and the `--geom` build (no blitter, no rasteriser) is not yet rebuilt with sound. List mode (G2) kept open.
4. **Boot ROM (spec 16) and the shared monitor spec**, drafted (branch 16): `docs/spec/boot-rom.md` and `docs/spec/monitor.md`. The user confirmed the program map and ROMLOCK at power-on only; the retro68k session reviewed `monitor.md` (four changes applied) and adopts it word for word. Implementation: tickets #22–#26. Choices in the drafts:
   - CRC-32 (zlib's) for frames and images; big-endian header and frames; 4,096-byte frames with a reply each (`LR` + `K`/`C`/`F`/`R`).
   - Physical addresses with a `P` prefix: the MMU's page space, `P000000`–`P7FFFFF` (SRAM, register page `P7F0000`, ROM `P7F8000`); on retro68k the same as plain addresses.
   - Command letters: D E F C V S G R P I T U L B X H; the disassembler is `I`, ports `P`, the resident image (BASIC) `X`. The PC tool is `tools/rlink.py` (needs `pyserial`).
   - Program map: windows 1–7 = SRAM pages 1–7, so a CPU address is its own physical address; SP = `0xFFFE` holding the exit `0x0040`.
   - RST calls: 08h PUTC, 10h GETC, 18h PUTS, 20h POLLC, 28h numbered functions (number in the next byte), 30h BREAK, 38h TRAP. IM 1 is not served with the ROM in window 0; the self-test's RST 38h clash is solved by I = 0 only during the self-test.
   - The console's state in the tile map's hidden columns 96–127, so a ROM call borrows only one window; the monitor rebuilds the console and workspace if a program spoilt them (closes spec 7, SY7).
   - ROMLOCK set at power-on only, so D at power-on starts a development session until power-off (spec 16, section 4.5).
   - The resident BASIC image in SRAM pages `0x0F8`–`0x0FB` (32 KB), mapped at `0x2000` with write page NONE (spec 16, section 10; open point B3).
   - Next: the boot ROM's tickets in spec 16, section 11 (monitor on screen and keyboard first; the loader waits for the FT232H).
4a. **BBC BASIC (Z80)** (branch 13): ask R. T. Russell about the name; after phase 1, break the port into tickets (host layer, loader, files, VDU). Research: `docs/notes/bbc-basic.md`.
4b. **Remote debugging** (branch 18), drafted: spec 18 `docs/spec/debug-unit.md` (registers in I/O page `0x02`) and `docs/spec/debug.md` (transport offered to retro68k; the `N` step command added to `monitor.md`); open points DU1–DU9, DB1–DB12, B15–B17. Screen capture over the link is recorded as future only (design plan, branch 18).
4c. **VS Code and MCP** (branch 20): the PC side is now one Python bridge, `tools/rz80_bridge.py`, serving DAP and MCP at once like the zx emulator's `zx_server`, with its own VS Code extension in `tools/vscode/` (a full copy of the zx extension's patterns). Spec: `docs/spec/debug.md`, section 3. Tickets #30 (bridge and DAP), #33 (MCP) and #34 (extension); built against the Python stub model until the FT232H is fitted.
5. Then phase 1 (section 7) and the KS2 bring-up build (phase 3, branch 12).

## 6. Open questions (design plan section 6)

| # | Question | Notes |
|---|----------|-------|
| Q1 | Sound hardware | Closed (11 November 2026, #113): retro-hw's `audio_engine`, retro68k's 4 channels narrowed (spec 13); the beeper stays, mixed in |
| Q2 | 6502 version: build option here or own repo | Parked. Registers through the register page; slots give a 6502 14 MHz with no waits |
| Q3 | Is tv80 exact enough? | Run ZEXDOC/ZEXALL first in phase 1; fallback T80 (VHDL) |
| Q4 | tv80 → MMU → SRAM pad path at 100 MHz (multicycle) | Met on the KS2 (issue #11), single-cycle, +0.89 ns; check again on the KS3 |
| Q11 | Does the KS2's XC7A15T-1 meet 100 MHz with the bring-up build? | Yes for issue #11's build (+0.86 ns, 1,949 LUTs; `fpga/ks2/README.md`); check again as units are added |
| Q5 | Copper priority | Closed: urgent display fetches first, then the copper |
| Q6 | Kempston port | Closed: `0x1F` reads joystick 1 |
| Q7 | KS3 pins for keyboard, joysticks, PS/2, `sd_miso` | Check against the Next's pin file before phase 3 |
| Q8 | KS3 details shared with retro68k | SRAM size, accelerator pins, Next core format |
| Q9 | Z80 faster than 20 MHz | Parked. 25 MHz needs the swap back; beyond that, block-RAM fast RAM |
| Q10 | 3D filled polygons | Branch 10: flat-shaded; a geometry unit first (two matrices, camera × object, perspective, multiply and divide), retro-z80 only, specified after the DMA engine. Spec 15 drafted. Benchmark done (#68): drawing help next is a DMA clear, then a line job (spec 14, D3); span fill or triangle job waits for filled 3D |

## 7. Next phase: phase 1, the simulated CPU

Done when the boot ROM prints "hello" over simulated USB serial at all four speeds and ZEXDOC passes.

1. **Tools:** done in ticket #1: Icarus, Verilator, sjasmplus, Python, set up as the main README's Tools section says (note the `-O2` workaround for Verilator on MSYS2).
2. **Skeleton:** folders as in retro68k (`fpga/rtl`, `fpga/rtl/platform/{artix7,sim}`, `firmware/boot`, `firmware/include`, `tools`, `sim`); copy `tools/regmap.py` from retro68k and adapt it to byte registers, the two blocks and the register page (spec 3, section 8); write `fpga/regmap.def` from spec 3.
3. **tv80 first:** done in ticket #2: tv80 vendored under `fpga/third_party/tv80/` (MIT licence); ZEXDOC and ZEXALL both pass on the bare core in Verilator (`make -C sim zexdoc zexall`, `sim/zex/RESULTS.md`), which answers Q3. Ticket #7 ran ZEXDOC on the whole system (tv80 behind the bus interface, MMU and SRAM controller at 20 MHz): all 67 tests pass and the Z80 never waited (`make -C sim zexsys`, 9 h 38 min; not in CI).
4. **CPU side:** `fpga/rtl/z80_cpu.v` (spec 1: brings out cen, the early cycle signals and `nmicycle`; `TV80_REFRESH`; Mode 0, T2Write 1, IOWait 1), the bus interface, the scheduler and SRAM controller adapted from retro68k's `dmac.v`, the MMU with read and write pages and the register page, the boot ROM in block RAM.
5. **USB serial** adapted from retro68k's `serial.v`, with its `ft232h_model.v` and `sram_model.v` for simulation.
6. **Boot ROM** in sjasmplus: memory and MMU checks, then "hello" over serial.
7. **CI:** GitHub Actions running the register-map check and the simulations, as in retro68k.

## 8. Working notes

- Keep `docs/design-plan.md` and the specs in step: a decision goes into the table first, then the specs.
- The register list's source of truth will be `fpga/regmap.def` once it exists; until then it is spec 3.
- Don't put model names in commits or docs.
