# retro-z80 handoff

Where the project stands, what is unfinished, and how to carry on. Updated on 23 October 2026, after branch 11 (retro68k's memory timing and video design) and branch 12 (the KS2 as first board).

## 1. The project

retro-z80 is the 8-bit sister of [retro68k](https://github.com/jonsole/retro68k): a Z80 computer inside the FPGA of a ZX Spectrum Next, for use as a home computer and a games machine. It is **retro68k narrowed to 8 bits**: the same blocks, register names, bit layouts, memory timing and video/sprite design, with byte-wide registers, differing only where the Z80 forces it, plus Spectrum extras in sections of their own.

- **Repo:** `jonsole/retro-z80`. Work goes on `main`.
- **retro68k** (`jonsole/retro68k`) is the model: its specs, guides (`docs/guide/`) and RTL. Clone it next to this repo.
- **Boards:** the **KS2** (issue 4, XC7A15T) is here and is the first hardware target, for a bring-up build loaded over JTAG with a Xilinx Platform Cable USB. The **KS3** (issue 5, XC7A35T) arrives in a few weeks and runs the full machine. No FT232H module yet.
- **Phase:** 0 (planning). Nothing in `fpga/`, `firmware/` or `hardware/` exists yet.

## 1a. Latest milestone (24 October 2026)

**retro-z80 runs on the KS2.** The phase 1 computer (tv80 at 20 MHz, MMU, scheduler and SRAM controller from retro68k, boot ROM, serial, a minimal video unit) loaded over JTAG passes its self-test on the real 2 MB SRAM and shows a green screen (#11). HDMI works (#10); VGA not yet checked (#12). Phase 1 in simulation is complete: ZEXDOC and ZEXALL pass 67/67 on the bare core, ZEXDOC 67/67 on the whole machine (#2, #7). Build and load: `fpga/ks2/README.md`.

**Phase 2 has started (#13):** video layer L0 as a chunky bitmap (retro68k's fetch and pixel path: 1/2/4/8 bpp, 1×–8×, windows, live pointer with stride and wrap, fine scroll, TRANSP, PALOFS), PRIO, DMACON and the palettes (PALIDX/PALDAT and the register page), checked pixel by pixel against a Python model (`make -C sim vtest`). The KS2 build has one layer (`NLAYERS = 1`) and the boot ROM shows a palette chart in it; 3,062 LUTs, 100 MHz met. Not yet loaded on the board.

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
| Specs 13, 15, 16 | Not written: sound (parked), geometry unit (branch 10, another session), boot ROM |
| `docs/guide/playfields.md` | Programmer's guide, chapter 3: playfields (the first chapter written) |

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
2. **Programmer's guide:** the playfields chapter (`docs/guide/playfields.md`) is written; the user is checking its style and depth before the other chapters. Its spec gaps: no generated names for WINX/WINY/BEAMPOS halves, tile-map entry fields and MMU page numbers; what a loaded program inherits from the boot ROM (spec 16); level-sensitive VBLANK re-entering ported Spectrum handlers; the boot console font as a public resource.
3. **Geometry unit (spec 15)**, branch 10, in the other session, against the new register map.
4. **Boot ROM spec (16)**, including how it loads the BASIC image (branch 13).
4a. **BBC BASIC (Z80)** (branch 13): ask R. T. Russell about the name; after phase 1, break the port into tickets (host layer, loader, files, VDU). Research: `docs/notes/bbc-basic.md`.
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
