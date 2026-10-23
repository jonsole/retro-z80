# retro-z80 handoff

Where the project stands, what is unfinished, and how to carry on. Updated on 23 October 2026, after the specs were realigned with retro68k (branch 9).

## 1. The project

retro-z80 is the 8-bit sister of [retro68k](https://github.com/jonsole/retro68k): a Z80 computer inside the FPGA of a **ZX Spectrum Next KS3**, for use as a home computer and a games machine. Since branch 9 it is **retro68k narrowed to 8 bits**: the same blocks, register names, bit layouts and programming model, cut to byte-wide registers, differing only where the Z80 or the memory bandwidth forces it, plus a few Spectrum extras kept in sections of their own.

- **Repo:** `jonsole/retro-z80`. Work goes on `main`.
- **retro68k** (`jonsole/retro68k`) is the model. Clone it next to this repo; the specs refer to its files and its programmer's guides (`docs/guide/`).
- **Phase:** 0 (planning). Nothing in `fpga/`, `firmware/` or `hardware/` exists yet.

## 2. Where things are

| File | What |
|------|------|
| `docs/design-plan.md` | Decision table (section 1; branch 9 is the realignment, branch 10 the 3D geometry unit), key decisions D1–D11, port map, spec list, phases, open questions |
| `docs/spec/bus-interface.md` | Spec 1: tv80 wrapper, clock enable, memory and I/O cycles (8-bit system ports, 16-bit custom block ports), the 28 MHz swap, register page, interrupts, NMI paging |
| `docs/spec/memory.md` | Spec 2: slots and cycle owners, SRAM controller, MMU, register page |
| `docs/spec/registers.md` | Spec 3: register rules and exceptions, every system port, every custom offset, register page, interrupt sources, the generator |
| `docs/spec/video.md` | Spec 4: layers L0 and L1 (bitmap or tile map), PRIO, palettes, globals, fetch and draw, budget; attribute layer and `0xFE` border as Spectrum extras |
| `docs/spec/sprites.md` | Spec 5: retro68k's 8 sprites, row-store fetch, write timing, collisions |
| `docs/spec/copper.md` | Spec 6: retro68k's copper in 16-bit words, timing, worked programs |
| `docs/spec/system.md` … `input.md` | Specs 7–12: system, interrupts, timers, USB serial, SD card, input |
| `docs/spec/dma-engine.md` | Spec 14: one-channel copy and fill |
| Spec 13 (sound), spec 15 (geometry) | Not written: sound is parked (Q1); geometry is next (branch 10) |

Every spec has a "Comparison with retro68k" section.

## 3. The machine in one page

- **CPU:** tv80 at 3.5/7/14/28 MHz by clock enable on a 56 MHz system clock; 28 MHz after reset; never waits for memory. IM 2 (IM 1 also works).
- **Memory:** 4 MB SRAM, 16-bit, slots of 4 cycles (143 ns; 224 per line). Cycles 0 and 2 CPU, 1 display, 3 urgent display FIFO, then copper, then sprites, then display top-up; the DMA engine takes spare cycles. The 28 MHz swap as before.
- **MMU:** eight 8 KB windows, read pages at ports `0x80`–`0x8F`, write pages at `0x90`–`0x9F`.
- **Registers:** the system block on 8-bit ports (`0x00` interrupts, `0x20` timers, `0x50` serial, `0x58` SD, `0x60` input, `0x70` system, `0x80` MMU, `0xA0` geometry); the chipset as a 1 KB custom block on 16-bit ports (`LD BC,reg` then `OUT (C),A`); both also in the register page.
- **Video:** 576p HDMI + VGA; layers L0 and L1, each a bitmap (1/2/4/8 bpp) or a tile map, 1× or 2× each way, with PRIO, PALETTE0/1 and SPRPALETTE (12-bit), SHAREPAL.
- **Sprites:** 8, any size, 2/4/8 bpp, ×1/2/4 magnify, DEPTH, collisions, manual mode.
- **Copper:** retro68k's MOVE/WAIT/SKIP/JUMP, MOVR, ALU, SKIPC, CALL/RET in 16-bit words; MOVE reaches custom offsets `0x000`–`0x0EF`.
- **I/O:** serial, SD, PS/2, joysticks, 4 timers, TIME, watchdog, I2C; Spectrum extras `0xFE`, `0x1F`, NMI monitor paging.
- **Software:** sjasmplus; boot ROM monitor, then BBC BASIC (Z80); CP/M 3 later.

## 4. How decisions are made

The user prefers a **decision tree**: 1–4 multiple-choice questions per step, the recommended option first, then the answers written into the plan. Decisions go into the design plan's table (section 1) first and are binding for the specs; anything a spec decides on its own goes into its open points for review.

**Spec style** (follow retro68k's specs): plain, short sentences; British spelling; `# Spec N: Name`, `Status: **draft**`, a summary table, a "Comparison with retro68k" section, register tables with bit fields, a test plan and an open-points table. Specs refer to each other as "spec N, section M".

**Check against retro68k.** Before inventing anything, look at what retro68k does (its specs, guides and RTL). The first planning round drifted into a different machine; branch 9 undid that.

## 5. Unfinished work (do this first)

1. **Review the choices the spec writers made** in the branch 9 rewrite (each spec's open points). The main ones:
   - Sprites: placed by DEPTH first, then number (retro68k's rule; replaces the earlier "number order" decision). One gap line to reuse a sprite. No SPRLIMIT: over-budget results depend on spare cycles, as in retro68k.
   - Copper: X and Y are 8-bit registers, not SRAM pointers (per-cell colour from a table is left to the attribute layer). `CMOVEL` is the one-byte any-offset MOVE; wide writes are `CMOVEW`, `CMOVEA`, `CMOVEN`.
   - Video: software sees the draw beam (one line ahead of the screen); the layer pointer is taken per source line, not live; separate MAPPT and PATPT for tile mode.
   - Registers: one commit rule for CPU and copper (bytes not written keep their value); unused ports read `0xFF`.
   - Serial: retro68k's control sequence, so one PC tool serves both machines; SERDROP left out for lack of ports.
   - Ports still wanted: SERDROP (spec 10, U6), a membrane key map (spec 12, K8), more system registers (spec 7, SY11).
2. **Geometry unit (spec 15)**, branch 10: write it against the new register map (ports `0xA0`–`0xBF`, interrupt source 19 reserved).
3. Then phase 1 (section 7).

## 6. Open questions (design plan section 6)

| # | Question | Notes |
|---|----------|-------|
| Q1 | Sound hardware | Parked. Custom offsets `0x180`–`0x1FF` and source AUDIO (9) reserved; retro68k's 4 channels narrowed is the default; the beeper already exists |
| Q2 | 6502 version: build option here or own repo | Parked. Registers through the register page; slots give a 6502 14 MHz with no waits |
| Q3 | Is tv80 exact enough? | Run ZEXDOC/ZEXALL first in phase 1; fallback T80 (VHDL) |
| Q4 | Early-signal → MMU → SRAM pad path at 56 MHz | First Vivado build |
| Q5 | Copper priority | Closed: urgent display fetches first, then the copper |
| Q6 | Kempston port | Closed: `0x1F` reads joystick 1 |
| Q7 | KS3 pins for keyboard, joysticks, PS/2, `sd_miso` | Check against the Next's pin file before phase 3 |
| Q8 | KS3 details shared with retro68k | SRAM size, accelerator pins, Next core format |
| Q9 | Z80 faster than 28 MHz | Parked. Best value: 56 MHz with a wait on SRAM plus 128 KB block-RAM fast RAM |
| Q10 | 3D filled polygons | Branch 10: flat-shaded; a geometry unit first (two matrices, camera × object, perspective, multiply and divide), retro-z80 only, specified after the DMA engine. Drawing help (span fill or triangle job) still open |

## 7. Next phase: phase 1, the simulated CPU

Done when the boot ROM prints "hello" over simulated USB serial at all four speeds and ZEXDOC passes.

1. **Tools:** Icarus Verilog, Verilator, sjasmplus, Python 3 (the first session's container had none of the first three).
2. **Skeleton:** folders as in retro68k (`fpga/rtl`, `fpga/rtl/platform/{artix7,sim}`, `firmware/boot`, `firmware/include`, `tools`, `sim`); copy `tools/regmap.py` from retro68k and adapt it to byte registers, the two blocks and the register page (spec 3, section 8); write `fpga/regmap.def` from spec 3.
3. **tv80 first:** add tv80 (as a submodule or vendored under `fpga/third_party/`, BSD-style licence) and run ZEXDOC on the bare core in Verilator, to answer Q3 before building on it.
4. **CPU side:** `fpga/rtl/z80_cpu.v` (spec 1: brings out cen, the early cycle signals and `nmicycle`; `TV80_REFRESH`; Mode 0, T2Write 1, IOWait 1), the bus interface, the slot and SRAM controller with the swap, the MMU with read and write pages and the register page, the boot ROM in block RAM.
5. **USB serial** adapted from retro68k's `serial.v`, with its `ft232h_model.v` and `sram_model.v` for simulation.
6. **Boot ROM** in sjasmplus: memory and MMU checks, then "hello" over serial.
7. **CI:** GitHub Actions running the register-map check and the simulations, as in retro68k.

## 8. Working notes

- Keep `docs/design-plan.md` and the specs in step: a decision goes into the table first, then the specs.
- The register list's source of truth will be `fpga/regmap.def` once it exists; until then it is spec 3.
- Don't put model names in commits or docs.
