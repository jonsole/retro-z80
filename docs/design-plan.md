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
| 9 | Sprite order | DEPTH first, then number, as retro68k (replaces the earlier "number order") |
| 9 | Copper reads | No SRAM table reads: X and Y are 8-bit registers, as retro68k; per-cell colour is the attribute layer's job. A shared "MOVR from (X)+" stays an open point for both machines |
| 9 | Sprite limit | None, as retro68k: a guaranteed budget per line is stated; beyond it a late row sets SPRUNDER and the highest-numbered sprites lose first |
| 9 | Beam | Software sees the draw beam everywhere (BEAMPOS, LINECMP, VBLANK, copper waits), one line ahead of the screen |
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

> Branch 9 of section 1 (23 October 2026) brought the chipset back in line with retro68k, and branch 11 took retro68k's memory timing and video design too. Where D2–D11 below disagree with branch 11, branch 11 wins until they are rewritten. Each spec has a "Comparison with retro68k" section listing every difference and its reason.

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
  | 1 | Display fetch (layers L0 and L1, attributes) |
  | 2 | CPU |
  | 3 | A display FIFO that is running low; then the copper; then sprites; then display top-up |

  A cycle its owner does not use goes to the others, in the cycle-3 order; the DMA engine comes last. **The Z80 never waits, even at 28 MHz.**
- **The swap.** tv80 leaves room for exactly one memory cycle in a read, and at 28 MHz that cycle can fall on 1 or 3. The CPU then takes that cycle and hands its own next one (which it can never need) to the owner. Every owner keeps its number of cycles per slot but is sometimes one cycle (35.7 ns) late; specs 4–6 allow for it. No swap at 14 MHz or slower, nor for writes (spec 1, section 5).
- **MMU.** Eight 8 KB windows, each with a **read page** (ports `0x80`–`0x8F`) and a **write page** (ports `0x90`–`0x9F`). Setting the read page also sets the write page; setting the write page afterwards splits the window, for ROM shadowing, registers behind ROM, read-only windows and similar tricks. 10-bit page numbers: `0x000`–`0x1FF` SRAM (4 MB; on a 2 MB board the top half mirrors the bottom), `0x3F8` the register page, `0x3FB` NONE (writes ignored, for read-only windows), `0x3FC`–`0x3FF` the 32 KB boot ROM, others reserved. Reset: windows 0–1 = ROM, 2–7 = SRAM pages 0–5.
- The chipset uses 22-bit physical SRAM addresses, not the MMU.

### D5. Video

Defined in [spec 4: video](spec/video.md). retro68k's video narrowed to 8 bits:

- **Output:** 576p (720×576 at 50 Hz) over HDMI and VGA at once, with retro68k's platform modules and beam coordinates (picture: pixels 144–863, lines 49–624).
- **Two identical layers, L0 and L1**, each with retro68k's register block (CTRL, WINX, WINY, SCROLLX, BPLSTRIDE, BPL0PT) at custom offsets `0x020` and `0x040`. CTRL's MODE bit makes a layer a **chunky bitmap** (1/2/4/8 bpp) or a **tile map** (8×8 tiles, 1/2/4/8 bpp, MAPPT and PATPT, maps of 32, 64 or 128 entries each way, entries with tile, palette block, flips and PRI). HSCALE and VSCALE give 1× or 2× each way. retro68k's PRIO register orders the layers; sprites go between them by DEPTH.
- **Palettes as retro68k:** PALETTE0, PALETTE1 and SPRPALETTE, 256 entries each, PALOFS per layer, VIDCON.SHAREPAL. Colours are 12-bit RGB.
- **Global registers** with retro68k's names: VIDCON, VIDSTAT, VIDINTEN, PRIO, BGCOLOR, LINECMP, DMACON, VIDSIZE, BEAMPOS, FRAMECOUNT. Interrupts VBLANK, LINE and VIDERR.
- **Inside, for bandwidth:** a FIFO per source, a draw beam one line ahead filling a line buffer, and a repeat buffer that replays 2×-tall layers. Software sees the draw beam (BEAMPOS, LINECMP, copper waits). Late data shows as transparent, as in retro68k.
- **Budget:** 448 bytes per output line from cycle 1, 896 with cycle 3.
- **Spectrum extras:** the attribute layer (custom `0x120`), port `0xFE` border colours, the Spectrum screen layout by the copper.

### D6. Sprites

Defined in [spec 5: sprites](spec/sprites.md). retro68k's 8 sprites:

- SPRxPT, SPRxH (HSTART, HSTOP), SPRxV (VSTART, VSTOP), SPRxCTL (BPP 2/4/8, HMAG and VMAG ×1/2/4, DEPTH, PAL) and SPRxDAT for manual mode: 16 bytes per sprite at custom `0x060` + 16n, so the copper reuses sprites with plain MOVEs. Any size, through the window. SPRDMA and SPRCOLL as retro68k.
- Inside: each sprite's row for the next line is fetched whole into a row store (cycle 3 after the display and the copper, plus spare cycles), and 8 pixel units read it at the draw beam. Rows repeated by VMAG cost nothing.
- A commit during line L: the sprite shows nothing on L + 1 and uses the new settings from L + 2. A row not fetched in time sets SPRUNDER (VIDERR); the highest-numbered sprites lose first.

### D7. Copper

Defined in [spec 6: copper](spec/copper.md). retro68k's copper in 16-bit words with 8-bit data:

- MOVE is one word (register code and data) to custom offsets `0x000`–`0x0EF`; codes `0xF0`–`0xFF` are WAIT, SKIP, JUMP, STOP, MOVR, the ALU (R0–R7, X, Y, flags Z N C), SKIPC, CALL/RET and MOVEL (any custom offset).
- Registers COPCON, COP1LC, COP2LC, COPJMP1, COPJMP2, COPINT, COPPC, COPSTAT, COPX, COPY, COPFLAGS, COPSP, COPR0–7. retro68k's macros.
- Follows the draw beam; reads in cycle 3 after urgent display fetches: one word per slot on lines whose display fits in cycle 1 (4 MOVEs per 2× cell), best effort on busier lines.

### D8. Registers

Defined in [spec 3: register map](spec/registers.md).

- **System block** on 8-bit I/O ports (`OUT (n),A`, `OTIR`): interrupts, timers, serial, SD, input, system, MMU, in retro68k's order (section 3).
- **Custom block** (the chipset, as retro68k's at `0xE00000`): 1 KB on 16-bit ports; port = offset bits 7–0 in the high byte and `0xC0` + offset bits 9–8 in the low byte (`LD BC,reg` then `OUT (C),A`).
- The **register page** (MMU page `0x3F8`) shows the system ports at `0x0000`, the Spectrum keyboard rows at `0x0100`, the custom block at `0x1000` and the palettes at `0x1800`.
- Registers are bytes; wider values sit low byte first and commit on the highest byte. The copper has its own latch. Sources: `fpga/regmap.def` → `tools/regmap.py` → sjasmplus, C and Verilog headers.

### D9. I/O and interrupts

| Block | Spec | In short |
|-------|------|----------|
| Interrupts | [8](spec/interrupts.md) | retro68k's controller: INTCON, INTENA (set/clear), INTPEND, INTRAW, VECBASE, SOFTINT, INTID, NMICON, NMISTAT; units keep their own flags. Fixed priority by source number; IM 2 vector = VECBASE + 2n; IM 1 reads INTID |
| Timers | [9](spec/timers.md) | 4 × 16-bit timers (CTRL, PRESCALE, RELOAD, COUNT, STAT; clock, line, frame or chained), a 32-bit µs TIME counter, a watchdog |
| DMA engine | [14](spec/dma-engine.md) | One channel: copy and fill, 1D and 2D, SRAM only, spare cycles |
| USB serial | [10](spec/serial.md) | FT232H, retro68k's registers and control commands |
| SD card | [11](spec/sd-card.md) | SPI byte master (retro68k's version 1), polled |
| Input | [12](spec/input.md) | retro68k's PS/2 keyboard registers; joysticks; Spectrum extras: port `0xFE` rows, Kempston `0x1F` |
| System | [7](spec/system.md) | SYSID, SYSVER, SYSCFG, RESETWHY, SYSCON, SYSRESET, SYSBTN, CPUSPEED, I2C master; NMI monitor paging (Spectrum extra) |

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
| Palettes (1024 × 12 bits) | 1 | 4 |
| Display FIFOs | 1 | 4 |
| Repeat buffers, L0 and L1 | 2 | 4 |
| Sprite row store | 4 | 5 |
| USB serial FIFOs | 2 | 10 |
| PS/2 keyboard FIFO | 1 | 12 |
| **Total** | **29 of 100** | |

Logic is to be measured; a Z80 core is about 2–3k LUTs.

## 3. I/O port map

The full list is in [spec 3](spec/registers.md).

| Ports | Block |
|-------|-------|
| `0x00`–`0x0F` | Interrupt controller |
| `0x1F` | Kempston joystick (Spectrum extra) |
| `0x20`–`0x4F` | Timers, TIME, watchdog |
| `0x50`–`0x57` | USB serial |
| `0x58`–`0x5F` | SD card |
| `0x60`–`0x6F` | PS/2 keyboard, joysticks, extra keys |
| `0x70`–`0x7F` | System, I2C, NMI monitor |
| `0x80`–`0x9F` | MMU read pages, write pages |
| `0xA0`–`0xBF` | Geometry unit (branch 10) |
| `0xC0`–`0xC3` | Custom block, on 16-bit ports (below) |
| `0xFE` | Spectrum keyboard rows, border, beeper |
| Others | Reserved |

| Custom offset | Block | Copper |
|---------------|-------|--------|
| `0x000`–`0x01F` | Video globals, palette ports, DMACON | MOVE |
| `0x020`–`0x05F` | Layers L0, L1 | MOVE |
| `0x060`–`0x0DF` | Sprites 0–7 | MOVE |
| `0x0E0`–`0x0EF` | Copper control | MOVE |
| `0x0F0`–`0x0FF` | Video read-only, sprite globals | MOVEL |
| `0x100`–`0x11F` | Copper state and storage | MOVEL |
| `0x120`–`0x13F` | Attribute layer (Spectrum extra) | MOVEL |
| `0x140`–`0x17F` | DMA engine | MOVEL |
| `0x180`–`0x1FF` | Audio (reserved) | MOVEL |

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
| 11 | Memory timing | **retro68k's:** 100 MHz system clock, 20 ns memory cycles, 100 ns slots of 5 cycles. Display on cycles 1 and 3 (as retro68k); CPU on cycles 0 and 2; audio and the free pool (copper, DMA engine, cycles others leave) on cycle 4. Replaces the 56 MHz clock, the 4-cycle slots and the 28 MHz swap |
| 11 | CPU speed | Z80 top speed **20 MHz** (2 T-states per slot, locked to the slots); also 10, 5 and 3.57 MHz. 25 MHz to be tried in simulation (open point). Replaces branch 2's 28 MHz |
| 11 | Video design | **retro68k's design and RTL as built**: just-in-time layer fetch through its scheduler, data registers and shifters, mixing on the pixel side; software sees the display beam; 2×-tall layers fetch every line. The only new hardware is a **tile mode** in the layer fetcher. The FIFOs, draw beam, line buffer and repeat buffer go |
| 11 | Layers | **Three layers L0–L2**, chunky only (no planar), 1/2/4/8 bpp, scale 1×, 2×, 4× or 8× each way, PRIO, **direct colour**. Each a bitmap or a tile map |
| 11 | Colour | **24-bit** palette entries as retro68k (3 bytes: blue, green, red; red commits); BGCOLOR 3 bytes. PALETTE0–2 and SPRPALETTE. Default: the Spectrum colours in entries 0–15 at `0xD7` (normal) and `0xFF` (bright) |
| 11 | Sprites | retro68k's 8 sprites as built, streamed through its 32-word FIFOs (no image-row limit); **fractional scaling** with SPRxSTEP (XSTEP, YSTEP, 5.11, `0x0800` normal), as retro68k; signed HSTART. **No manual mode** (no SPRxDAT), so 16 bytes per sprite. Reuse needs one gap line |
| 11 | DMA engine | **retro68k's version 1** narrowed: 4 channels, descriptors in SRAM, COPY, FILL, KEYCOPY, LOGIC, ADD at 1–8 bpp, registers, palettes and the SD/serial ports as sources or destinations. No HIGH mode. OP 6–7 reserved, to agree with retro68k for the 3D drawing job. Sources DMA0–DMA3 |
| 11 | Ports | Every port is **register (high byte) : page (low byte)**. Page `0x00` the system block (register numbers as the old system ports); pages `0x10`–`0x13` the custom block; `0x1F` Kempston, `0xFE` Spectrum (high byte picks keyboard rows) and the stream ports SERDATA (`0x53`), SDDATA (`0x5B`), KBDATA (`0x62`) ignore the high byte. Writes `OUT (C),r`; reads `LD A,reg` then `IN A,(page)`; `OUT (n),A` is given up. Full I/O access is kept alongside the register page (the MMU must be reachable before the page is mapped) |
| 11 | Register page | Page p, register r at offset p × 256 + r: the port with its bytes swapped. Palettes memory-only at `0x1800` plus PALIDX/PALDAT |
| 11 | Custom block | `0x000`–`0x00F` video globals; `0x010`–`0x08F` sprites 0–7; `0x090`, `0x0B0`, `0x0D0` layers L0–L2 (32 bytes each); `0x0F0`–`0x0FF` video read-only; from `0x100`: copper control and state, sprite globals, attribute layer, DMA engine (4 channels), audio (reserved). Copper MOVE reaches `0x000`–`0x0EF` |
| 11 | Small items | `CMOVEL` keeps retro68k's meaning (a whole wide register); the one-byte far move is `CMOVEF`. Unused addresses read `0xFF`. Serial: retro68k's control sequence; check RXCOUNT before reading. SDCON keeps retro68k's layout; no SD transmit buffer. SERDROP, a membrane key map and JOY1X/JOY2X get registers. PS/2 keys also show on `0xFE`. No IM 0, no hardware debugger. CHIPMB is a build option. No UPLOAD on a long reset press; beeper level fixed. Copper prefetch 2 words; RESUME doesn't save the latch. The boot console belongs to spec 7. Deferred: 48-bit TIME, timer capture, DMA job queue, high-speed SD, accelerator-pin interrupts, a faster paging port |
| 11 | Next specs | 15 geometry unit (branch 10; its registers in the system page, reached by `OUT (C)` or the register page), 16 boot ROM |
| 11 | [SD card](spec/sd-card.md) | Draft |
| 12 | [Input](spec/input.md) | Draft |
| 13 | Sound | Waiting for Q1 |
| 14 | [DMA engine](spec/dma-engine.md) | Draft |
| 15 | Geometry unit (3D) | Next to write (branch 10) |

## 5. Phases

| Phase | Work | Done when |
|-------|------|-----------|
| **0. Plan** | This document and specs 1–12 and 14 agreed | Specs reviewed |
| **1. Simulated CPU** | tv80, bus interface, MMU, SRAM controller, boot ROM, USB serial, in simulation | Boot ROM prints "hello" over simulated serial; ZEXDOC passes in Verilator |
| **2. Video** | L0 in tile mode with the boot console, then bitmaps, palettes, PRIO, the attribute layer | Console text on the simulated screen, checked pixel by pixel |
| **3. On the board** | Build for the KS3; boot monitor | "hello" on a real monitor and over USB; RAM test at 28 MHz |
| **4. Games machine** | Copper, sprites, DMA engine, joysticks | A demo with scrolling tiles, magnified sprites reused down the screen and a Spectrum-style screen drawn by the copper |
| **5. Home computer** | SD card, keyboards, BBC BASIC | Boot to BASIC, load and save a program |
| **6. Next core** | Package and install as a Next core | The KS3 boots retro-z80 from its core menu |
| **Later** | Sound (if not before), geometry unit, CP/M 3, a 6502 version | |

## 6. Open questions

Each spec has its own open points; these are the ones that matter for the whole machine.

| # | Item | Plan |
|---|------|------|
| Q1 | Sound hardware: retro68k's 4 sample channels, AY-style chip(s), or both | Parked; custom offsets `0x180`–`0x1FF` and source AUDIO (9) reserved under retro68k's names; retro68k's audio narrowed would be the default |
| Q2 | 6502 version: build option here or its own repo | To be decided; the chipset stays CPU-independent. A 6502 sees the registers through the register page, as the Z80 can; the slots would give it 14 MHz with no waits |
| Q3 | Is tv80 exact enough (flags, undocumented instructions, interrupts)? | ZEXDOC and ZEXALL in Verilator in phase 1; fallback T80 (VHDL) |
| Q4 | Does the path from tv80's early cycle signals through the MMU to the SRAM pads meet 56 MHz? | Check in the first Vivado build (spec 1, B1); fallback: start a read speculatively in every T1 |
| Q5 | Copper priority | Closed: urgent display fetches come first in cycle 3, then the copper, then sprites (spec 2) |
| Q6 | Kempston port | Closed: port `0x1F` reads joystick 1 (spec 12) |
| Q7 | KS3 pins for the Spectrum keyboard, joysticks, PS/2 and `sd_miso`, not yet checked against the Next's pin file | Check before phase 3 (spec 7, SY1) |
| Q8 | The KS3 details still open in retro68k (SRAM size, accelerator pins, Next core format) | Answered once for both projects |
| Q9 | A Z80 faster than 28 MHz | Left for later. Options: (A) 56 MHz with one wait state on SRAM, about 1.6×; (B) A plus 128 KB of block-RAM fast RAM with no waits, 2× there; (C) 17.9 ns SRAM cycles on a 112 MHz system clock, 2× with no waits; (D) a core that needs fewer clocks per instruction, 2–3×. B looked the best value. All need tv80 (or the new core) to meet 56 MHz |
| Q10 | Hardware help for 3D filled polygons | Partly answered by branch 10: a geometry unit (matrices, perspective, multiply and divide) comes first. Still open: drawing help, either (a) a span filler, (y, x0, x1, colour) filled in spare memory cycles, about 0.5k LUTs, with the Z80 stepping the edges, or (b) a triangle job in the DMA engine taking three screen vertices, about 1–2k LUTs. With fast vertices, edge stepping becomes the Z80's main cost, so (b) looks the better value. Double buffering already works by switching the layer pointer at vertical blank |

## 7. Next step

Review the specs, starting with the open points above. Then start phase 1 in simulation: the tv80 wrapper, bus interface, MMU, SRAM controller, boot ROM and USB serial.
