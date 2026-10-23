# retro-z80 handoff

Where the project stands, what is unfinished, and how to carry on. Written at the end of the first planning session (October 2026).

## 1. The project

retro-z80 is the 8-bit sister of [retro68k](https://github.com/jonsole/retro68k): a new Z80 computer (not a copy of an existing machine) inside the FPGA of a **ZX Spectrum Next KS3**, for use as a home computer and a games machine. A 6502 version may follow, so the chipset is kept independent of the CPU.

- **Repo:** `jonsole/retro-z80`. Work goes on `main`.
- **retro68k** (`jonsole/retro68k`) is the model for structure, writing style and shared logic. Clone it next to this repo; the specs refer to its files (RTL, sim models, register-map generator).
- **Phase:** 0 (planning). Nothing in `fpga/`, `firmware/` or `hardware/` exists yet.

## 2. Where things are

| File | What |
|------|------|
| `docs/design-plan.md` | Decision table (section 1), key decisions D1–D11, port map, spec list, phases, open questions Q1–Q10 |
| `docs/spec/bus-interface.md` | Spec 1: tv80 wrapper, clock enable, memory and I/O cycles, the 28 MHz swap, register page accesses, interrupts, NMI paging |
| `docs/spec/memory.md` | Spec 2: slots and cycle owners, SRAM controller, MMU (read and write pages), register page, physical addresses |
| `docs/spec/registers.md` | Spec 3: rules for all registers, every port, the register page layout, interrupt numbers |
| `docs/spec/video.md` | Spec 4: 576p, fetch/draw/show pipeline, FIFOs and repeat buffers, bitmap, tiles, attribute layer, palette, budget |
| `docs/spec/sprites.md` | Spec 5: 32 sprites, fractional scaling, fetch and render, limits, collisions |
| `docs/spec/copper.md` | Spec 6: 16-bit instruction set, timing, worked programs |
| `docs/spec/system.md` | Spec 7: ID and control ports, reset, boot ROM, buttons, NMI monitor, beeper, board pins |
| `docs/spec/interrupts.md` … `input.md` | Specs 8–12: interrupts, timers, USB serial, SD card, keyboards and joysticks |
| Spec 13 (sound) | Not written: sound is undecided (Q1) |

## 3. The machine in one page

- **CPU:** tv80 (Verilog Z80) at 3.5/7/14/28 MHz by clock enable on a 56 MHz system clock; 28 MHz after reset; never waits for memory. IM 2 vectored interrupts (IM 1 also works, IM 0 not supported).
- **Memory:** 4 MB SRAM (2 MB on some boards), 16-bit, 35.7 ns cycles, slots of 4 cycles (143 ns; 224 per 576p line). Cycles 0 and 2 = CPU, 1 = display fetch, 3 = urgent display FIFO, then copper, then sprites, then display top-up. At 28 MHz a read can "swap" into cycle 1 or 3 and hand back the CPU's next cycle (owners keep their count, sometimes 35.7 ns late).
- **MMU:** eight 8 KB windows, each with a read page (ports `0x08`–`0x17`) and a write page (`0xA8`–`0xB7`); setting the read page also sets the write page. Pages: `0x000`–`0x1FF` SRAM, `0x3F8` register page, `0x3FB` NONE, `0x3FC`–`0x3FF` boot ROM (32 KB).
- **Registers:** 8-bit, in Z80 I/O space (low byte decoded) and also as memory through the register page (ports at offsets `0x00`–`0xFF`, keyboard rows, sprite table, palette). Multi-byte values: low byte first, the highest byte commits.
- **Video:** 576p HDMI + VGA; 360×288 picture at 2×; per-layer window, scroll, hi-res (720 across) and height (288/576). Background colour, bitmap (1/2/4/8 bpp), 8×8 tiles (1/2/4/8 bpp), attribute layer (8×8 or 8×1 cells setting the palette bank of the bitmap or tiles), sprites. 512-entry palette of 12-bit RGB. Fetch through per-source FIFOs; draw one line ahead into a line buffer of final colours; 288-line layers replay from a repeat buffer.
- **Sprites:** 32, 8/16/32 px each way, 1/2/4/8 bpp, patterns in SRAM, X and Y scale 1/16× to 16× (4.12 steps), flips, collisions.
- **Copper:** follows the draw beam, 16-bit instructions, MOVE/WAIT/SKIP, loops, pointers X and Y, paced indirect moves (MOVX).
- **I/O:** FT232H USB serial, SD (SPI), PS/2, Spectrum keyboard on `0xFE`, two joysticks (also Kempston at `0x1F`), 2 timers and a frame counter.
- **Software:** sjasmplus; boot ROM monitor, then BBC BASIC (Z80); CP/M 3 later.

## 4. How decisions are made

The user prefers a **decision tree**: one branch at a time, 1–4 multiple-choice questions per step, the recommended option first, then the answers written into the plan. Decisions are recorded in the design plan's table (section 1) and are binding for the specs; anything a spec has to decide on its own goes into that spec's open points for review.

**Spec style** (follow retro68k's specs): plain, short sentences; British spelling; `# Spec N: Name`, `Status: **draft**`, a summary table, register tables with bit fields, a test plan and an open-points table (IDs such as B1, M1, V1). No marketing words. Specs refer to each other as "spec N, section M".

## 5. Unfinished work (do this first)

### 5.1 The review round ("CHANGE 3")

The user reviewed the choices the spec writers had made and decided the following. Items marked **done** are in the committed specs; the rest still have to be written in.

| # | Decision | Where | State |
|---|----------|-------|-------|
| 1 | Tile map size selectable: width 32, 64 or 128 entries, height 32 or 64 (TLCTL.MAPW, MAPH); TLSCRY grew to 2 bytes (`0x6A`–`0x6B`) | Spec 4 | Done |
| 2 | A VIDCTL swap bit puts the bitmap in front of the tiles (default behind); the two are then the back and front layer | Spec 4 | Done (VIDCTL.BMFRONT) |
| 3 | Sprite DEPTH, 2 bits, in attribute byte 12 bits 1–0 (XH bit 6, the old BEHIND, becomes reserved). Order, back to front: background < DEPTH 3 sprites < back layer < DEPTH 2 sprites < front layer < DEPTH 1 sprites < PRI tile pixels < DEPTH 0 sprites. So PRI tiles cover DEPTH 1–3 sprites but never DEPTH 0 | Specs 4, 5 | Done |
| 4 | Sprite pipeline shortened from 3 lines to 2: fetch and render share one line, so attribute writes act 2 lines later. The fetch and render limits then interact; keep the lowest-numbered sprites, predictably. Rule: a write committed while the draw beam is on line N is used from line N + 2 (writes during the scan, the last 32 clocks, from N + 3) | Spec 5 | Done |
| 5 | Cycle-3 order: urgent display FIFO first, then copper, sprites, display top-up. The copper may slip and sets COPSTAT.LATE | Specs 2, 4, 5 done; **spec 6 to do** |
| 6 | Copper second counter D (8-bit, like C), port `0x9C` COPD, with a loop instruction or a select bit | Spec 3 done; **spec 6 to do** |
| 7 | Port `0x1F` reads joystick 1 (Kempston); INTHIGH moves to `0xB8` | Done (specs 3, 8, 12) |
| 8 | Port `0xFE` writes: bits 2–0 border (sets BGCOL to one of 8 fixed Spectrum colours), bit 4 beeper into the audio output, bit 3 ignored | Done (specs 3, 4, 7, 12) |
| 9 | NMI pages in a monitor: window 0 → boot ROM page `0x3FF` (write page NONE), old pages saved in `0xBA`–`0xBD`, NMICTL at `0xB9`; RETN restores window 0 right after its opcode fetch (before its stack reads). Nested NMIs are held off | Done (specs 1, 2, 3, 7) |
| – | Kept as drafted: the attribute layer uses its target's window; the sprite fetch stops at the first sprite that doesn't fit; over-wide lines cut a sprite off; copper pacing in 2-pixel steps; no watchdog; IM 0 not supported | – | – |

### 5.2 Video and sprite specs

Done: `video.md` and `sprites.md` carry items 1–5 and 8. Points they raised for review:

- **V12:** the border colours use level `0xD` for the Spectrum's non-bright colours.
- **V13:** TLSCRY is now 2 bytes, so a copper program must write both.
- **S8:** SPRLIMIT's reset value of 192 leaves only 28 of the 220 cycle-3 cycles per line to the copper and urgent display fetches.
- **S11:** the sprite renderer waits for fixed due clocks so results never depend on timing, and loses time when the copper and display use less than their share.
- **Order quirk:** sprites among themselves are ordered by number whatever their DEPTH, so a low-numbered DEPTH 3 sprite hides a higher-numbered DEPTH 0 sprite where they overlap (as on the SNES). Worth a decision.

### 5.3 Then

1. **Copper spec (`copper.md`):** counter D (item 6), the new cycle-3 order (item 5: the copper is no longer first, so state its rate as best effort after urgent display fetches, and when LATE is set), sprite reuse timing from spec 5 (write a reused sprite during draw line M − 2; its section 3 still says N + 3 and (M − 3, 16), and its "216 cycles" is now SPRLIMIT out of 220), and TLSCRY as 2 bytes; fix the examples and tests.
2. **Design plan:** update the decision table and D5–D9 for items 1–9, the port map (section 3: `0x1F`, `0x9C`, `0xB8`–`0xBD`), and close Q6 (Kempston).
3. **Consistency pass:** grep all specs for stale text: "BEHIND", "3 lines", "N+3", "copper first", "INTHIGH" at `0x1F`, "64×32", "read-only bit".
4. Commit and push.

## 6. Open questions (design plan section 6)

| # | Question | Notes |
|---|----------|-------|
| Q1 | Sound hardware | Parked by the user. Ports `0x30`–`0x3F` and interrupt 10 reserved; the beeper already exists |
| Q2 | 6502 version: build option here or own repo | Parked. Registers through the register page; slots give a 6502 14 MHz with no waits |
| Q3 | Is tv80 exact enough? | Run ZEXDOC/ZEXALL first in phase 1; fallback T80 (VHDL) |
| Q4 | Early-signal → MMU → SRAM pad path at 56 MHz | First Vivado build |
| Q5 | Copper priority | Largely answered by item 5 (display first) |
| Q6 | Kempston port | Answered by item 7; close it |
| Q7 | KS3 pins for keyboard, joysticks, PS/2, `sd_miso` | Check against the Next's pin file before phase 3 |
| Q8 | KS3 details shared with retro68k | SRAM size, accelerator pins, Next core format |
| Q9 | Z80 faster than 28 MHz | Parked. Best value: 56 MHz with a wait on SRAM plus 128 KB block-RAM fast RAM |
| Q10 | 3D filled polygons | Branch 10: flat-shaded; a geometry unit first (two matrices, camera × object, perspective, multiply and divide), retro-z80 only, specified after the DMA engine. Drawing help (span fill or triangle job) still open |

## 7. Next phase: phase 1, the simulated CPU

Done when the boot ROM prints "hello" over simulated USB serial at all four speeds and ZEXDOC passes.

1. **Tools:** Icarus Verilog, Verilator, sjasmplus, Python 3 (the first session's container had none of the first three).
2. **Skeleton:** folders as in retro68k (`fpga/rtl`, `fpga/rtl/platform/{artix7,sim}`, `firmware/boot`, `firmware/include`, `tools`, `sim`); copy `tools/regmap.py` from retro68k and adapt it to 8-bit ports and the register page; write `fpga/regmap.def` from spec 3.
3. **tv80 first:** add tv80 (as a submodule or vendored under `fpga/third_party/`, BSD-style licence) and run ZEXDOC on the bare core in Verilator, to answer Q3 before building on it.
4. **CPU side:** `fpga/rtl/z80_cpu.v` (spec 1: brings out cen, the early cycle signals and `nmicycle`; `TV80_REFRESH`; Mode 0, T2Write 1, IOWait 1), the bus interface, the slot and SRAM controller with the swap, the MMU with read and write pages and the register page, the boot ROM in block RAM.
5. **USB serial** adapted from retro68k's `serial.v`, with its `ft232h_model.v` and `sram_model.v` for simulation.
6. **Boot ROM** in sjasmplus: memory and MMU checks, then "hello" over serial.
7. **CI:** GitHub Actions running the register-map check and the simulations, as in retro68k.

## 8. Working notes

- Keep `docs/design-plan.md` and the specs in step: a decision goes into the table first, then the specs.
- The register list's source of truth will be `fpga/regmap.def` once it exists; until then it is spec 3.
- Don't put model names in commits or docs.
