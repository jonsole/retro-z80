# retro-z80 design plan

Status: **draft for review**. The decisions below were made one by one (section 1), and every block now has a draft spec in [`spec/`](spec/) (section 4). Nothing in `fpga/`, `firmware/` or `hardware/` gets built until the specs are agreed.

retro-z80 is the 8-bit sister of [retro68k](https://github.com/jonsole/retro68k): a **new machine** (not a copy of an existing one) for use both as a home computer and as a games machine. It runs on the same board, the **ZX Spectrum Next KS3**, with the same video output, storage and USB link, but with a Z80 and a smaller chipset made for an 8-bit CPU. The chipset is kept separate from the CPU, so a 6502 version stays possible.

## 1. Decision tree

| # | Branch | Decision |
|---|--------|----------|
| 1 | Board | ZX Spectrum Next KS3, the Z80 as a soft core in its FPGA |
| 1 | Compatibility | A new machine; Spectrum games are made easy to port, not run unchanged |
| 1 | Use | Both home computer and games machine |
| 1 | Chipset | ~~New and scaled down for an 8-bit CPU~~ retro68k's chipset narrowed to 8 bits (branch 9) |
| 2 | CPU core | tv80 (Verilog) |
| 2 | CPU speed | 3.5, 7, 14 or 28 MHz by software; **28 MHz after reset** |
| 2 | Interrupts | IM 2 with vectors from the interrupt controller (IM 1 also works) |
| 2 | Memory | Eight 8 KB windows onto the SRAM (MMU) |
| 3 | Picture | 360×288 at 2×, filling the 576p screen; every layer has its own size and position, so a 256×192 window can be placed |
| 3 | Layers | ~~Background colour, a bitmap layer, a tile layer, an attribute layer, sprites~~ see branch 9 |
| 3 | Bitmap | ~~1, 2, 4 or 8 bits per pixel~~ see branch 9 |
| 3 | Tiles | ~~8×8, 1, 2, 4 or 8 bits per pixel (1-bit for text)~~ see branch 9 |
| 3 | Hi-res | ~~Per layer: 720 across instead of 360~~ see branch 9 |
| 3 | Lines | ~~Per layer: 288 lines (each shown twice) or 576; output stays 576p (not 576i)~~ see branch 9 |
| 3 | Display fetch | ~~A FIFO per source just ahead of drawing; 288-line layers replay their first line from a repeat buffer~~ see branch 9 |
| 3 | Colours | ~~12-bit RGB (4096 colours); palette grown to 512 entries for the attribute layer~~ see branch 9 |
| 3 | Attributes | ~~An attribute layer of 8×8 or 8×1 cells that sets the palette bank of the bitmap or the tile layer~~ see branch 9 |
| 3 | Spectrum screen layout | Done by the copper (a line address per line), no extra hardware |
| 3 | Copper | ~~In version 1, a "smart" copper: loops, a counter, indirect moves through X/Y pointers~~ see branch 9 |
| 4 | Sprites | ~~32 sprites, 8 to 32 pixels, 1, 2, 4 or 8 bits per pixel, patterns in SRAM~~ see branch 9 |
| 4 | Sprite scaling | ~~Fractional, X and Y separately, 1/16× to 16× (16-bit steps, 4.12 fixed point)~~ see branch 9 |
| 5 | Sound | ~~**Open** (Q1)~~ see branch 9 |
| 6 | Registers | 8-bit, in Z80 I/O space and also as memory through a register page any window can map; 16- and 24-bit values are byte groups latched on the last byte |
| 6 | MMU read/write | Each window has a read page and a write page; setting the read page also sets the write page; ROM, RAM or registers in any window |
| 6 | DMA engine | ~~Later~~ see branch 9 |
| 7 | BASIC | BBC BASIC (Z80) |
| 7 | CP/M | Later (CP/M 3) |
| 7 | I/O | USB serial (FT232H), SD card, PS/2 keyboard, joysticks, Spectrum keyboard |
| 7 | Assembler | sjasmplus |
| 8 | 6502 | Decide later; keep the chipset CPU-independent |
| 9 | Direction | **retro-z80 is retro68k narrowed to 8 bits:** the same blocks, register names, bit layouts and programming model, cut to 8-bit ports. It differs only where the Z80 (8-bit ports, 64 KB address space, IM 2 on one /INT line) or the memory bandwidth (448 guaranteed display bytes per line against retro68k's 1,280) forces it. Every spec has a "Comparison with retro68k" table listing each difference and why |
| 9 | Layers | Background colour, **two identical layers L0 and L1** with retro68k's per-layer register block (CTRL, window, pointer, stride, scroll), each a **bitmap or a tile map** (a CTRL mode field), and retro68k's PRIO register. Bitmaps chunky 1/2/4/8 bpp; tiles 8×8 at 1/2/4/8 bpp. Scale 1× or 2× across and down (retro68k's HSCALE/VSCALE fields, 4× and 8× reserved). Kept inside the hardware for bandwidth: the FIFOs and the repeat buffer |
| 9 | Palettes | As retro68k: a 256-entry palette per layer and one for the sprites, with PALOFS and VIDCON.SHAREPAL. Colours stay 12-bit RGB (the KS3's VGA has 4 bits per colour) |
| 9 | Sprites | **retro68k's 8 sprites:** SPRxPT, SPRxH, SPRxV, SPRxCTL; any size (a window per sprite), 2/4/8 bpp, magnify ×1/2/4 across and down, DEPTH among the layers, own palette, collisions. Fetched whole rows into a line buffer inside, for bandwidth. Fractional scaling, flips and the attribute table are dropped |
| 9 | Copper | **retro68k's copper instructions and names in 16-bit words with 8-bit data:** MOVE is one word (register and 8-bit data); WAIT, SKIP and JUMP take two; MOVR, the ALU (8-bit R0–R7, flags Z N C), SKIPC, CALL/RET; COP1LC/COP2LC, COPJMP1/2, COPCON. Same macros as retro68k |
| 9 | DMA engine | retro68k's DMA engine (its version-1 decision), narrowed: one channel, copy and fill in 1D and 2D, SRAM only, spare memory cycles. Specified now |
| 9 | Sound | Still parked (Q1); its ports and interrupt reserved under retro68k's names |
| 9 | Interrupts | retro68k's model: each unit keeps its own flags and enables; the controller has INTCON.MASTER, INTENA (set/clear), INTPEND, INTRAW, VECBASE, SOFTINT, NMICON, NMISTAT; retro68k's source names and order. Fixed priority (one /INT line); IM 2 vector = VECBASE + 2 × source |
| 9 | Timers | retro68k's model at 16 bits: 4 timers, each CTRL, PRESCALE, RELOAD, COUNT, STAT, with retro68k's sources and chaining; a watchdog |
| 9 | Register map | retro68k's block order and names, narrowed to bytes. **System block** on 8-bit ports (A15–A8 ignored, so `OUT (n),A` and `OTIR` work), in retro68k's order: `0x00`–`0x0F` interrupts, `0x20`–`0x4F` timers and watchdog, `0x50`–`0x57` serial, `0x58`–`0x5F` SD, `0x60`–`0x6F` keyboard and joysticks, `0x70`–`0x7F` system, `0x80`–`0x9F` MMU read and write pages, `0xA0`–`0xBF` geometry unit (branch 10). Spectrum extras at `0x1F` (Kempston) and `0xFE` |
| 9 | Custom block | The chipset is retro68k's "custom block", 1 KB on **16-bit ports**: port = offset bits 7–0 in the high byte, `0xC0` + offset bits 9–8 in the low byte (`LD BC,reg` then `OUT (C),A`; `INC B` steps to the next register). Layout: `0x000` video globals and palette ports, `0x020` layer 0, `0x040` layer 1, `0x060` sprites 0–7 (16 bytes each), `0x0E0` copper control; `0x100` copper storage registers, `0x120` attribute layer, `0x140` DMA engine, `0x180` audio (reserved). The register page mirrors both blocks |
| 9 | Copper MOVE | One word: register (8 bits) and data (8 bits). Codes `0x00`–`0xEF` are MOVEs to custom offsets `0x000`–`0x0EF`; codes `0xF0`–`0xFF` are the other instructions, with a second word where needed. A two-word MOVEL reaches any custom register |
| 9 | Spectrum extras | Kept, each in its own section outside the retro68k core: port `0xFE` (keyboard rows, border, beeper), Kempston `0x1F`, the attribute layer, NMI monitor paging |
| 10 | 3D target | **Flat-shaded polygons** (one colour each), as in Elite or Starglider 2 but at 25–50 frames a second. No Z-buffer (it would triple the memory traffic): software sorts back to front |
| 10 | 3D hardware | First a **geometry unit** (matrix multiplier). Help with drawing (span fill or a triangle job in the DMA engine) is decided later. retro-z80 only, not in retro68k: a Z80 has no multiply, so it sits in its own section like the Spectrum extras |
| 10 | Geometry: numbers | Coordinates signed 16-bit integers; matrix entries signed 2.14 fixed point; sums 32-bit inside, results 16-bit. A result that doesn't fit **saturates** to −32768 or +32767 and sets a status bit |
| 10 | Geometry: matrices | **Two** 3×3 matrices, each with a translation vector: camera and object. Writing the object matrix makes the unit multiply them (camera × object) itself. A vertex then gives X = m11·x + m12·y + m13·z + tx, and so on |
| 10 | Geometry: perspective | Selectable by a control bit: screen x = cx + d·X ÷ Z, y = cy − d·Y ÷ Z, with d, cx and cy set once. A vertex with Z below a set minimum sets a **NEAR** bit and comes back unprojected (X, Y, Z), so software can clip or drop it |
| 10 | Geometry: extras | Plain 16×16 → 32 signed multiply and 32 ÷ 16 divide, on the same DSP slices and divider |
| 10 | Geometry: access | Ports, and as memory through the register page (LDI, LD (IX+d)); writing z starts a vertex. About 150 T-states a vertex at 28 MHz against 2,000–3,000 in software. The unit finishes in under 1 µs, before the Z80 can read back, but a busy bit is kept |
| 10 | Geometry: when | Specified after the DMA engine spec, which leaves room in its job codes for a later drawing job |

## 2. Key decisions

> **Being rewritten.** Branch 9 of section 1 (23 October 2026) brings the chipset back in line with retro68k. Where D5–D11 and section 3 below disagree with branch 9, branch 9 wins; they are updated as each spec is rewritten.

### D1. Board: ZX Spectrum Next KS3

Same as retro68k (its design plan, D1): Artix-7 XC7A35T, 4 MB (or 2 MB) of 10 ns SRAM, HDMI and an ADV7125 VGA DAC, audio jack, SD card in SPI mode, PS/2 sockets, two joystick ports, the Spectrum membrane keyboard, the accelerator port for the FT232H module, and a 50 MHz oscillator. Vivado free edition, scripted in Tcl, loaded over JTAG during development, installed as a Next core when finished.

### D2. CPU: tv80

- **tv80**, a Verilog version of the T80 core (BSD-style licence), so the whole design stays in Verilog and runs in Icarus and Verilator like retro68k. Checked with the ZEXDOC and ZEXALL instruction tests. It need not match a real Z80 cycle for cycle (open question Q3).
- The core runs on the 56 MHz system clock with a clock enable: a T-state every 2, 4, 8 or 16 clocks gives **28, 14, 7 or 3.5 MHz**. A register changes the speed at once; reset gives 28 MHz.
- **Interrupts:** IM 2, with the interrupt controller putting each source's vector byte on the bus during the acknowledge cycle. IM 1 (RST 38h) works too, with a status register to read. NMI from the Multiface button and a USB "break".

### D3. Clocks

- **System clock 56 MHz** from MMCM 1: 50 MHz × 21 = VCO 1050 MHz, ÷ 18.75 (CLKOUT0's fractional divider). CPU speeds are clock enables.
- **Pixel clock 27 MHz** (and 135 MHz for HDMI) from MMCM 2, as in retro68k, treated as asynchronous.
- Both come from one oscillator, so every 576p line (32 µs) is exactly **1792 system clocks = 224 memory slots**.

### D4. Memory: slots and the MMU

Defined in [spec 2: memory](spec/memory.md). In short:

- **Slots.** SRAM time is cut into slots of 4 memory cycles. A memory cycle is 2 system clocks (35.7 ns, gentle for a 10 ns SRAM) and moves 16 bits; a slot is 143 ns; 56 MB/s in total.

  | Cycle | Owner |
  |-------|-------|
  | 0 | CPU |
  | 1 | Display fetch (bitmap, tiles, attributes) |
  | 2 | CPU |
  | 3 | Copper; then a display FIFO that is running low; then sprites; then display top-up |

  A cycle its owner does not use goes to the others. **The Z80 never waits, even at 28 MHz.**
- **The swap.** tv80 leaves room for exactly one memory cycle in a read, and at 28 MHz that cycle can fall on 1 or 3. The CPU then takes that cycle and hands its own next one (which it can never need) to the owner. Every owner keeps its number of cycles per slot but is sometimes one cycle (35.7 ns) late; specs 4–6 allow for it. No swap at 14 MHz or slower, nor for writes (spec 1, section 5).
- **MMU.** Eight 8 KB windows, each with a **read page** (MMU0–MMU7, ports `0x08`–`0x17`) and a **write page** (MMU0W–MMU7W, ports `0xA8`–`0xB7`). Setting the read page also sets the write page; setting the write page afterwards splits the window, for ROM shadowing, registers behind ROM, read-only windows and similar tricks. 10-bit page numbers: `0x000`–`0x1FF` SRAM (4 MB; on a 2 MB board the top half mirrors the bottom), `0x3F8` the register page, `0x3FB` NONE (writes ignored, for read-only windows), `0x3FC`–`0x3FF` the 32 KB boot ROM, others reserved. Reset: windows 0–1 = ROM, 2–7 = SRAM pages 0–5.
- The chipset uses 22-bit physical SRAM addresses, not the MMU.

### D5. Video

Defined in [spec 4: video](spec/video.md). In short:

- **Output:** 576p (720×576 at 50 Hz) over HDMI and VGA at once, with retro68k's platform modules. The picture is **360×288 at 2×**, filling the whole screen; the background colour shows where no layer covers it. All positions are beam coordinates, as in retro68k (picture: pixels 144–863, lines 49–624).
- **Pipeline: fetch, draw, show.**
  - *Fetch:* each source (bitmap, tile map, tile patterns, attributes) has a small **FIFO** (128–256 bytes), filled just ahead of drawing and topped up as pixels are drawn.
  - *Draw:* a draw beam in the 56 MHz domain runs one output line ahead of the display beam and works out each pixel's final 12-bit colour (layers, attributes, sprites, palette) into a double line buffer.
  - *Show:* the pixel clock reads the line buffer out.
  - **288-line layers** fetch only on the first line of each pair; the draw stage saves their pixels in a **repeat buffer** and replays them on the second line.
  - Register writes that affect pixels act at the draw beam, so the copper's changes land on the pixel seen. Writes to a layer's fetch registers (pointers, line address, scroll) act from that layer's next line.
- **Layers**, back to front: background colour; **bitmap** (1/2/4/8 bits per pixel, own window and scroll, a line address taken every line so the copper can set it); **tiles** (64×32 map of 8×8 tiles, 128×32 in hi-res, 1/2/4/8 bits per pixel, 2-byte entries with tile number, bank, flips and priority); **attribute layer** (8×8 or 8×1 cells that set the palette bank of the bitmap or the tiles; uses its target's window, with its own fine scroll; flash); **sprites** in front of the bitmap, and in front of or behind the tiles. A tile with its priority bit is in front of all sprites.
- **Per layer:** window, scroll, hi-res (720 across) and height (288 or 576 lines).
- **Palette:** 512 entries of 12-bit RGB. Each layer forms a 9-bit index from its bank and pixel value.
- **Interrupts:** vertical blank, line compare, overrun.
- **Memory budget** (peak, per output line of 224 slots): 448 bytes from cycle 1, 896 with cycle 3. Examples: Spectrum-style 256×192 1-bit with 8×8 attributes, 64 bytes; a full-screen 8-bit bitmap with 4-bit tiles, 636. 288-line layers whose windows start on lines of opposite parity fetch on alternate lines, which spreads the load. Late data shows the background colour and sets OVERRUN.

### D6. Sprites

Defined in [spec 5: sprites](spec/sprites.md). In short:

- **32 sprites**, each 8, 16 or 32 pixels across and down (the pattern size), at **1, 2, 4 or 8 bits per pixel**, with a palette bank; patterns anywhere in SRAM through a pointer.
- **Fractional scaling**, X and Y separately: a 16-bit step (4.12 fixed point) per axis, from 16× (`0x0080`) through normal size (`0x0800`) to 1/16× (`0x8000`); nearest pixel. X and Y flip. Signed positions, so a sprite can slide in from any edge.
- 16 attribute bytes per sprite, through an index and a data port (two `OTIR`s load all 32).
- Lower numbers in front; a bit puts a sprite behind the tiles. Sprite–sprite and sprite–layer collisions, with the SPRITE interrupt.
- **Pipeline one line deeper than the layers:** the sprites for line N+2 are found and fetched (cycle 3) while line N+1 is rendered into a sprite line buffer. Attribute writes made from pixel 16 of line N act from line N+3, which the copper allows for when reusing sprites.
- **Limits per line:** a fetch budget (about 216 cycles, set by SPRLIMIT, less what the copper takes) and a render limit (about 1,600 on-screen pixels in total). Normal-size and enlarged sprites reuse rows, so they fetch only some lines. When a limit is hit, the lowest-numbered sprites are kept and a flag is set.

### D7. Copper

Defined in [spec 6: copper](spec/copper.md). In short:

- A coprocessor that follows the draw beam and writes ports `0x30`–`0x9F`. **16-bit instructions**, so a MOVE costs one memory read.
- **MOVE**, **WAIT** (line, pixel or a number of lines), **SKIP**, a counter with **LOOP**, **BRA**, two 22-bit pointers X and Y with ADD and LOAD, **MOVX** (an indirect move: a byte read through X or Y, written to a port, optionally paced every 2n pixels), INT and STOP.
- Program in SRAM, read in cycle 3 ahead of the sprites; prefetch, so the write after a WAIT lands on the pixel.
- About 4 MOVEs or 2 MOVXs per 8-pixel cell at 2×, half that in hi-res.
- Restarted each frame. It does the Spectrum's screen row order (a line address per line), gradients, split screens and per-cell colour changes from a table (a 90-byte program instead of 12,288 MOVEs).

### D8. Registers

Defined in [spec 3: register map](spec/registers.md). All registers are **8-bit**, in **Z80 I/O space**, decoded on A7–A0 (`OUT (n),A` and `OTIR` work), and **also as memory**: MMU page `0x3F8` (the register page) shows the 256 ports at offsets `0x00`–`0xFF`, the 8 Spectrum keyboard rows, the sprite attribute table and the palette, so `LD`, `LD (nn),HL`, `SET`/`RES` and `INC (IX+d)` work on registers. Both ways reach the same registers. Multi-byte values sit at consecutive ports, low byte first, and commit when the highest byte is written; reading the low byte of a counter captures the whole value. Big tables use an index port and a data port. The copper has its own latch, and goes first when it and the CPU write in the same clock. Sources: `fpga/regmap.def` → `tools/regmap.py` → sjasmplus, C and Verilog headers.

### D9. I/O and interrupts

| Block | Spec | In short |
|-------|------|----------|
| Interrupts | [8](spec/interrupts.md) | 12 sources with fixed priorities (VBLANK, LINE, COPPER, SPRITE, OVERRUN, TIMER0, TIMER1, SERRX, SERTX, KEYBOARD, SOUND reserved, SOFT); IM 2 vector = INTVEC + 2 × source; IM 1 with a "highest pending" port; NMI from Multiface and USB BREAK; no in-service state, RETI not needed |
| Timers | [9](spec/timers.md) | 2 × 16-bit timers (1 µs, line, frame, 3.5 MHz, or chained) and a 16-bit frame counter |
| USB serial | [10](spec/serial.md) | FT232H in 245 FIFO mode, 2 KB FIFOs each way, BREAK/RESET/UPLOAD from the PC; about 1.3 MB/s with `INIR`/`OTIR` |
| SD card | [11](spec/sd-card.md) | SPI byte master up to 14 MHz; an AUTO mode lets `INIR` read blocks |
| Input | [12](spec/input.md) | PS/2 byte FIFO; Spectrum keyboard on port `0xFE` as on a Spectrum; extra Next keys; two joysticks in Kempston bit order, Mega Drive pads |

### D10. Software and tools

- **HDL:** plain Verilog-2005; chip-specific parts in `fpga/rtl/platform/artix7/` with behavioural copies for simulation.
- **CPU wrapper:** `fpga/rtl/z80_cpu.v` around tv80, bringing out the clock enable and the core's early cycle signals (spec 1).
- **Simulation:** Icarus Verilog for blocks, Verilator for the whole computer (fast enough to run ZEXDOC).
- **Z80 code:** sjasmplus; z88dk if C is wanted later.
- **Boot ROM:** a monitor (dump, edit, load over USB or SD, run), then **BBC BASIC (Z80)** by R. T. Russell (open source, zlib licence). **CP/M 3** later.
- **Shared with retro68k:** the KS3 pin list, MMCM, HDMI and VGA modules, TMDS encoder, the FT232H serial logic, the SRAM and FT232H simulation models, and the register-map generator. They are copied in, since the bus widths differ.

### D11. Block RAM budget

| Item | Blocks (18 Kb) | Spec |
|------|----------------|------|
| Boot ROM, 32 KB | 16 | 7 |
| Line buffer (2 × 720 × 12 bits) | 2 | 4 |
| Palette (512 × 12 bits) | 1 | 4 |
| Display FIFOs | 1 | 4 |
| Repeat buffers, bitmap and tiles | 2 | 4 |
| Sprite row store and sprite line buffer | 3 | 5 |
| USB serial FIFOs | 2 | 10 |
| PS/2 keyboard FIFO | 1 | 12 |
| **Total** | **28 of 100** | |

Logic is to be measured; the sprites are about 1,000–1,200 LUTs and 1 DSP slice, and a Z80 core about 2–3k LUTs.

## 3. I/O port map

The full list is in [spec 3](spec/registers.md).

| Ports | Block | Copper can write |
|-------|-------|------------------|
| `0x00`–`0x07` | System: ID, version, CPU speed, reset cause, config, control, buttons | |
| `0x08`–`0x17` | MMU0–MMU7 read pages | |
| `0x18`–`0x1F` | Interrupt controller | |
| `0x20`–`0x27` | Timers, frame counter | |
| `0x28`–`0x2B` | USB serial | |
| `0x2C`–`0x2F` | SD card | |
| `0x30`–`0x3F` | Sound (reserved) | Yes |
| `0x40`–`0x7F` | Video | Yes |
| `0x80`–`0x8F` | Sprites | Yes |
| `0x90`–`0x9F` | Copper | Yes |
| `0xA0`–`0xA7` | PS/2 keyboard, extra keys, joysticks | |
| `0xA8`–`0xB7` | MMU write pages | |
| `0xB8`–`0xFD` | Reserved (DMA engine later) | |
| `0xFE` | Spectrum keyboard rows | |
| `0xFF` | Reserved | |

## 4. Specs

| # | Spec | Status |
|---|------|--------|
| 1 | [CPU bus interface](spec/bus-interface.md) | Draft |
| 2 | [Memory](spec/memory.md) | Draft |
| 3 | [Register map](spec/registers.md) | Draft |
| 4 | [Video](spec/video.md) | Draft |
| 5 | [Sprites](spec/sprites.md) | Draft |
| 6 | [Copper](spec/copper.md) | Draft |
| 7 | [System](spec/system.md) | Draft |
| 8 | [Interrupts](spec/interrupts.md) | Draft |
| 9 | [Timers](spec/timers.md) | Draft |
| 10 | [USB serial](spec/serial.md) | Draft |
| 11 | [SD card](spec/sd-card.md) | Draft |
| 12 | [Input](spec/input.md) | Draft |
| 13 | Sound | Waiting for Q1 |
| – | Geometry unit (3D) | After the DMA engine spec (branch 10) |

## 5. Phases

| Phase | Work | Done when |
|-------|------|-----------|
| **0. Plan** | This document and specs 1–12 agreed | Specs reviewed |
| **1. Simulated CPU** | tv80, bus interface, MMU, SRAM controller, boot ROM, USB serial, in simulation | Boot ROM prints "hello" over simulated serial; ZEXDOC passes in Verilator |
| **2. Video** | Tile layer with the boot console, then bitmap, palette, attribute layer | Console text on the simulated screen, checked pixel by pixel |
| **3. On the board** | Build for the KS3; boot monitor | "hello" on a real monitor and over USB; RAM test at 28 MHz |
| **4. Games machine** | Copper, sprites, joysticks | A demo with scrolling tiles, scaled sprites and a Spectrum-style screen drawn by the copper |
| **5. Home computer** | SD card, keyboards, BBC BASIC | Boot to BASIC, load and save a program |
| **6. Next core** | Package and install as a Next core | The KS3 boots retro-z80 from its core menu |
| **Later** | Sound (if not before), DMA engine, CP/M 3, a 6502 version | |

## 6. Open questions

Each spec has its own open points; these are the ones that matter for the whole machine.

| # | Item | Plan |
|---|------|------|
| Q1 | Sound hardware: AY-style chip(s), sample channels, or both | To be decided; ports `0x30`–`0x3F` and interrupt 10 kept for it |
| Q2 | 6502 version: build option here or its own repo | To be decided; the chipset stays CPU-independent. A 6502 sees the registers through the register page, as the Z80 can; the slots would give it 14 MHz with no waits |
| Q3 | Is tv80 exact enough (flags, undocumented instructions, interrupts)? | ZEXDOC and ZEXALL in Verilator in phase 1; fallback T80 (VHDL) |
| Q4 | Does the path from tv80's early cycle signals through the MMU to the SRAM pads meet 56 MHz? | Check in the first Vivado build (spec 1, B1); fallback: start a read speculatively in every T1 |
| Q5 | Is the copper's priority in cycle 3 too strong for sprites and the display? | Measure in simulation; a control bit could limit it to every other cycle 3 (spec 6, C3) |
| Q6 | Kempston joystick port `0x1F` is INTHIGH here | Ported code changes the port; could alias JOY1 at `0x1F` if porting matters more (spec 3, R1) |
| Q7 | KS3 pins for the Spectrum keyboard, joysticks, PS/2 and `sd_miso`, not yet checked against the Next's pin file | Check before phase 3 (spec 7, SY1) |
| Q8 | The KS3 details still open in retro68k (SRAM size, accelerator pins, Next core format) | Answered once for both projects |
| Q9 | A Z80 faster than 28 MHz | Left for later. Options: (A) 56 MHz with one wait state on SRAM, about 1.6×; (B) A plus 128 KB of block-RAM fast RAM with no waits, 2× there; (C) 17.9 ns SRAM cycles on a 112 MHz system clock, 2× with no waits; (D) a core that needs fewer clocks per instruction, 2–3×. B looked the best value. All need tv80 (or the new core) to meet 56 MHz |
| Q10 | Hardware help for 3D filled polygons | Partly answered by branch 10: a geometry unit (matrices, perspective, multiply and divide) comes first. Still open: drawing help, either (a) a span filler, (y, x0, x1, colour) filled in spare memory cycles, about 0.5k LUTs, with the Z80 stepping the edges, or (b) a triangle job in the DMA engine taking three screen vertices, about 1–2k LUTs. With fast vertices, edge stepping becomes the Z80's main cost, so (b) looks the better value. Double buffering already works by switching the layer pointer at vertical blank |

## 7. Next step

Review the specs, starting with the open points above. Then start phase 1 in simulation: the tv80 wrapper, bus interface, MMU, SRAM controller, boot ROM and USB serial.
