# retro-z80 handoff

Where the project stands, what is unfinished, and how to carry on. Updated on 23 October 2026, after branch 11 (retro68k's memory timing and video design) and branch 12 (the KS2 as first board).

## 1. The project

retro-z80 is the 8-bit sister of [retro68k](https://github.com/jonsole/retro68k): a Z80 computer inside the FPGA of a ZX Spectrum Next, for use as a home computer and a games machine. It is **retro68k narrowed to 8 bits**: the same blocks, register names, bit layouts, memory timing and video/sprite design, with byte-wide registers, differing only where the Z80 forces it, plus Spectrum extras in sections of their own.

- **Repo:** `jonsole/retro-z80`. Work goes on `main`.
- **retro68k** (`jonsole/retro68k`) is the model: its specs, guides (`docs/guide/`) and RTL. Clone it next to this repo.
- **Boards:** the **KS2** (issue 4, XC7A15T) is here and is the first hardware target, for a bring-up build loaded over JTAG with a Xilinx Platform Cable USB. The **KS3** (issue 5, XC7A35T) arrives in a few weeks and runs the full machine. No FT232H module yet.
- **Phase:** 0 (planning). Nothing in `fpga/`, `firmware/` or `hardware/` exists yet.

## 1a. Latest milestone (25 October 2026)

**On the KS2, all confirmed by the user:** the HDMI test pattern (#10); the computer passing its self-test on the real 2 MB SRAM (#11); IM 2 interrupts from VBLANK (#16); timers and the watchdog (#17); layer L0 as a bitmap (palette chart, #13) and as a full-screen smoothly scrolling tile map (#14); the 80 x 30 boot console (#15); the membrane keyboard and port 0xFE (#19). 4,663 LUTs (45% of the XC7A15T), 100 MHz met. Still to check: VGA (#12), PS/2 and joysticks (#20). Phase 1 in simulation is complete, including ZEXDOC on the whole machine (#7). Build and load: `fpga/ks2/README.md`. Way of working: hardware first (CLAUDE.md).

**Ticket #22 (built, to be tried on the KS2):** the boot ROM is now the monitor of spec 16 and the shared monitor spec: the RST calls and `RST 28h` functions 0x00-0x11, start-up with the self-test at power-on only, the commands D E F C V S G R P H with sizes, P addresses and the side-effect rule, breakpoints, RST 30h and the trap. The old bring-up demos are gone but the tape loader (EDIT or Tab on an empty line). In simulation: `make -C sim mon` (a scripted session over serial, in Verilator). The KS2 README has a "try this" session.

**Ticket #27 (built, to be tried on the KS2):** the NMI is wired (Multiface button, BREAK), with the NMI set of the interrupt pages (`fpga/rtl/intpages.v`: window 0 reads ROM page 3 and writes the workspace page; the pages in distributed RAM, copied one window a clock) and the stack capture (NMICAPPC, NMICAPSP; RETN pops from the capture). The boot ROM's NMI page enters the monitor without touching the program's memory (`NMI (button) at`, `NMI (USB) at`; `G` goes on through the save area). In simulation: `make -C sim nmitest`, and NMI stops in `make -C sim mon`. The maskable interrupt pages are still to come.

**Ticket #28 (built, to be tried on the KS2):** the debug unit of spec 18 (`fpga/rtl/dbgunit.v`, registers in I/O page `0x02`): single step, 4 breakpoints with an optional page match, 2 watchpoints, all on the NMI, /INT held off during a step unless STEPINT. The monitor's `G addr break` now uses breakpoint 0 (works in ROM; nothing written into the program), `N` steps one instruction (`Step at <addr>`, Enter steps again), and a watchpoint set by hand with `P` stops with `Watchpoint n at <addr> (write <addr>: <data>)` (that message is a proposal, spec 16 open point B18). In simulation: `make -C sim dbg` (each stop reason and its timing; DU6 confirmed), and N, a ROM breakpoint and a watchpoint in `make -C sim mon`. The debug stub for VS Code (debug.md) is still to come.

**Ticket #31 (built, to be tried on the KS2):** the sprites of spec 5 (design plan branch 19): retro68k's `sprites.v` and `sprite_pix.v` (its main, 973fbcb) narrowed to byte registers, all eight on the KS2 (`NSPRITES = 8`; 8,417 LUTs, 81%, 100 MHz met), with SPRPALETTE and SHAREPAL, DEPTH among the layers (and spec 4's PRI tile place), the collisions, SPRUNDER and the VIDERR request; sprite fetches never take the CPU's cycle. The boot ROM's sprite demo is F1 (or GRAPH) on an empty command line: eight Amiga "Boing" balls spinning by palette cycling over the tile scroller (`sprdemo.asm`, ROM page 3; `fpga/ks2/README.md` says what to look for). In simulation: the sprite screens against the video model (`make -C sim vtest VTESTS=q` locally, `s` and `h` in CI), now in a Verilator build of the system testbench (about a minute each, against 12 minutes in Icarus), and `make -C sim boing` grabs a frame of the demo. Next (branch 19): the copper (spec 6), and the demo moves to it.

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
| `docs/spec/dma-engine.md` | Spec 14: retro68k's version-1 DMA engine, 4 channels |
| `docs/spec/boot-rom.md`, `monitor.md` | Spec 16: the boot ROM (draft); the shared spec "Monitor and upload protocol" (draft, for retro68k to adopt) |
| Specs 13, 15 | Not written: sound (parked), geometry unit (branch 10, another session) |
| `docs/guide/playfields.md` | Programmer's guide, chapter 3: playfields (the first chapter written) |
| `docs/guide/sprites.md` | Programmer's guide, chapter 4: sprites and the sprite sequencer |
| `docs/guide/timing.md` | Programmer's guide, appendix A: timing and screen reference, figures to scale |
| `docs/guide/img/`, `tools/guide_figures/` | The guide's SVG figures, and the scripts that draw the to-scale ones |

## 3. The machine in one page

- **CPU:** tv80, 20 MHz top speed (CPUSPEED divider: 20, 10, 6.67, 5, 4, 3.33, 2.86, 2.5 MHz, plus 3.57 MHz); never waits for memory. IM 2 (IM 1 also works).
- **Memory:** retro68k's: 100 MHz, 20 ns cycles, 100 ns slots; cycles 0 and 2 CPU, 1 and 3 display, 4 audio and the free pool. 4 MB on the KS3, 2 MB on the KS2. MMU: eight 8 KB windows with read and write pages.
- **Registers:** ports are register (high byte) : page (low byte); page `0x00` the system block, `0x10`–`0x13` the custom block; `OUT (C),r` to write, `LD A,reg` then `IN A,(page)` to read; `0x1F`, `0xFE` and the stream ports ignore the high byte. All also in the register page (MMU page `0x3F8`).
- **Video:** 576p HDMI + VGA; three layers, each a chunky bitmap or a tile map, 1×–8×, PRIO, direct colour; 24-bit palettes; 1.48 bytes per pixel.
- **Sprites:** 8, any size, 2/4/8 bpp, fractional scaling, DEPTH, collisions.
- **Copper:** MOVE/WAIT/SKIP/JUMP, MOVR, ALU, SKIPC, CALL/RET in 16-bit words.
- **DMA engine:** 4 channels, COPY, FILL, KEYCOPY, LOGIC, ADD.
- **I/O:** serial, SD, PS/2, joysticks (six-button pads), 4 timers, watchdog, I2C; Spectrum extras `0xFE`, `0x1F`, attribute layer, NMI monitor paging.

## 4. How decisions are made

The user prefers a **decision tree**: 1–4 multiple-choice questions per step (or numbered rounds with a recommendation each), the recommended option first, then the answers written into the plan. Decisions go into the design plan's table first and are binding for the specs; anything a spec decides on its own goes into its open points.

**Spec style** (follow retro68k's specs): plain, short sentences; British spelling; `# Spec N: Name`, `Status: **draft**`, a summary table, a "Comparison with retro68k" section, register tables, a test plan and open points.

**Check retro68k first**, including its latest commits: it is still moving (it added fractional sprite scaling and its version-1 DMA engine on 23 October 2026).

## 5. Unfinished work (do this first)

1. **Points for the user** from the branch 11 rewrite:
   - HSTART signed or unsigned (spec 5, S3): retro68k's RTL and guide are unsigned, its register table says signed.
   - The DMA engine reads the boot ROM through the ROM's second block-RAM port (spec 1, spec 14).
   - DMA port jobs go over the register bus, paced by each unit's ready signal (spec 3, R13).
   - Byte names: L/H (MMUnL) or 0/1/2 (SPRxPT0)? Mixed today (spec 3, R10).
   - Video: port `0xFE` border colours change on whole lines (retro68k's BGCOLOR rule), not mid-line (spec 4, V7); no BPLxDAT/BPLDMA (V5); PALDAT as a stream port (spec 3, R12).
2. **Programmer's guide:** the playfields chapter (`docs/guide/playfields.md`) is written; the user is checking its style and depth before the other chapters. Its spec gaps: no generated names for WINX/WINY/BEAMPOS halves, tile-map entry fields and MMU page numbers; level-sensitive VBLANK re-entering ported Spectrum handlers. (What a loaded program inherits and the console font as a resource are now in spec 16, sections 5.3 and 6.)
3. **Geometry unit (spec 15)**, branch 10, in the other session, against the new register map.
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
5. Then phase 1 (section 7) and the KS2 bring-up build (phase 3, branch 12).

## 6. Open questions (design plan section 6)

| # | Question | Notes |
|---|----------|-------|
| Q1 | Sound hardware | Parked. Custom offsets `0x180`–`0x1FF` and source AUDIO (9) reserved; retro68k's 4 channels narrowed is the default; the beeper already exists |
| Q2 | 6502 version: build option here or own repo | Parked. Registers through the register page; slots give a 6502 14 MHz with no waits |
| Q3 | Is tv80 exact enough? | Run ZEXDOC/ZEXALL first in phase 1; fallback T80 (VHDL) |
| Q4 | tv80 → MMU → SRAM pad path at 100 MHz (multicycle) | Met on the KS2 (issue #11), single-cycle, +0.89 ns; check again on the KS3 |
| Q11 | Does the KS2's XC7A15T-1 meet 100 MHz with the bring-up build? | Yes for issue #11's build (+0.86 ns, 1,949 LUTs; `fpga/ks2/README.md`); check again as units are added |
| Q5 | Copper priority | Closed: urgent display fetches first, then the copper |
| Q6 | Kempston port | Closed: `0x1F` reads joystick 1 |
| Q7 | KS3 pins for keyboard, joysticks, PS/2, `sd_miso` | Check against the Next's pin file before phase 3 |
| Q8 | KS3 details shared with retro68k | SRAM size, accelerator pins, Next core format |
| Q9 | Z80 faster than 20 MHz | Parked. 25 MHz needs the swap back; beyond that, block-RAM fast RAM |
| Q10 | 3D filled polygons | Branch 10: flat-shaded; a geometry unit first (two matrices, camera × object, perspective, multiply and divide), retro-z80 only, specified after the DMA engine. Drawing help (span fill or triangle job) still open |

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
