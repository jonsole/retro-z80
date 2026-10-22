# retro-z80 design plan

Status: **draft for review**. The decisions below were made one by one (section 1). Nothing in `fpga/`, `firmware/` or `hardware/` gets built until each block has a written spec.

retro-z80 is the 8-bit sister of [retro68k](https://github.com/jonsole/retro68k): a **new machine** (not a copy of an existing one) for use both as a home computer and as a games machine. It runs on the same board, the **ZX Spectrum Next KS3**, with the same video output, storage and USB link, but with a Z80 and a smaller chipset made for an 8-bit CPU. The chipset is kept separate from the CPU, so a 6502 version stays possible.

## 1. Decision tree

| # | Branch | Decision |
|---|--------|----------|
| 1 | Board | ZX Spectrum Next KS3, the Z80 as a soft core in its FPGA |
| 1 | Compatibility | A new machine; Spectrum games are made easy to port, not run unchanged |
| 1 | Use | Both home computer and games machine |
| 1 | Chipset | New and scaled down for an 8-bit CPU |
| 2 | CPU core | tv80 (Verilog) |
| 2 | CPU speed | 3.5, 7, 14 or 28 MHz by software; **28 MHz after reset** |
| 2 | Interrupts | IM 2 with vectors from the interrupt controller (IM 1 also works) |
| 2 | Memory | Eight 8 KB windows onto the SRAM (MMU) |
| 3 | Picture | 360×288 at 2×, filling the 576p screen; every layer has its own size and position, so a 256×192 window can be placed |
| 3 | Layers | Background colour, a bitmap layer, a tile layer, an attribute layer, sprites |
| 3 | Bitmap | 1, 2, 4 or 8 bits per pixel |
| 3 | Tiles | 8×8, 4-bit, or 1-bit for text |
| 3 | Hi-res | Per layer: 720 across instead of 360 |
| 3 | Lines | Per layer: 288 lines (each shown twice) or 576 |
| 3 | Colours | 12-bit RGB (4096 colours); palette grown to 512 entries for the attribute layer |
| 3 | Attributes | An attribute layer of 8×8 or 8×1 cells that sets the palette bank of the bitmap or the tile layer |
| 3 | Spectrum screen layout | Done by the copper (a line address per line), no extra hardware |
| 3 | Copper | In version 1, a "smart" copper: loops, a counter, indirect moves through X/Y pointers |
| 4 | Sprites | 32 sprites, 8 to 32 pixels, 1, 2, 4 or 8 bits per pixel, patterns in SRAM |
| 5 | Sound | **Open** (Q1) |
| 6 | Registers | 8-bit, in Z80 I/O space only; 16- and 24-bit values are byte groups latched on the last byte |
| 6 | DMA engine | Later |
| 7 | BASIC | BBC BASIC (Z80) |
| 7 | CP/M | Later (CP/M 3) |
| 7 | I/O | USB serial (FT232H), SD card, PS/2 keyboard, joysticks, Spectrum keyboard |
| 7 | Assembler | sjasmplus |
| 8 | 6502 | Decide later; keep the chipset CPU-independent |

## 2. Key decisions

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

**Slots.** SRAM time is cut into slots of 4 memory cycles. A memory cycle is 2 system clocks (35.7 ns, gentle for a 10 ns SRAM) and moves 16 bits; a slot is 143 ns.

| Cycle | Owner |
|-------|-------|
| 0 | CPU |
| 1 | Video: bitmap, tiles, attributes |
| 2 | CPU |
| 3 | Sprites and copper, then video if it is behind |

A cycle its owner does not use goes to the others. The CPU has a cycle every 2 T-states and a Z80 never touches memory more often than every 3, so **the Z80 never waits, even at 28 MHz**. (A 6502, which uses memory on every clock, would get 14 MHz with no waits from the same slots.) Total bandwidth is 56 MB/s.

**MMU.** Eight 8 KB windows (MMU0–MMU7), each with a 10-bit page number:

| Page | Meaning |
|------|---------|
| `0x000`–`0x1FF` | SRAM, 512 pages of 8 KB (4 MB); `0x100` and up do not exist on a 2 MB board |
| `0x3FC`–`0x3FF` | Boot ROM, 4 pages (32 KB of block RAM) |
| Others | Reserved: reads give `0xFF`, writes are ignored |

At reset, windows 0–1 map boot ROM pages 0–1 (the Z80 starts at `0x0000` in the ROM) and windows 2–7 map SRAM pages 0–5. A window can be set read-only.

The chipset (video, sprites, copper) sees the SRAM by its 22-bit physical address, not through the MMU.

### D5. Video

**Output.** 576p (720×576 at 50 Hz) over HDMI and VGA at once, with retro68k's platform modules. The picture is **360×288 at 2×**, filling the whole screen; the background colour shows where no layer covers it.

**Line buffers.** Each picture line is drawn into a line buffer in block RAM while the line before is shown. At 288 lines, each picture line lasts two 576p lines (64 µs); at 576 lines, one (32 µs).

**Layers**, back to front:

1. **Background colour.**
2. **Bitmap layer.** 1, 2, 4 or 8 bits per pixel. Its own window (size and position on the screen), scroll in X and Y, a line stride, and a line address that is reloaded at the start of every line, so the copper can set any line's address (this is how the Spectrum's row order is done). Hi-res: 720 across. Height: 288 or 576 lines.
3. **Tile layer.** A 64×32 map of 8×8 tiles, 2 bytes per entry (tile number, palette bank, X/Y flip, priority). Tiles at 4 bits per pixel, or 1 bit per pixel for text with the colour from the palette bank. Own window, scroll, hi-res (90 columns, 80 in a window) and height. The boot console is this layer.
4. **Attribute layer.** Draws nothing itself: it changes the colours of the bitmap or the tile layer (a register picks which). A map of cells, **8×8 or 8×1 pixels**, one byte each; the byte replaces the high bits of the target's palette index. For a 1-bit target, index = attribute × 2 + pixel, so a Spectrum attribute byte (bright, paper, ink) picks a pair of colours as on the Spectrum. For a 4-bit target it picks a 16-colour bank per cell. A flash bit swaps the pair on a timer. Own window and scroll, so it lines up with its target.
5. **Sprites** (D6), each in front of or behind the tile layer by its priority bit.

**Palette.** 512 entries of 12-bit RGB (4096 colours), in block RAM, looked up as each pixel goes out. Layers with fewer than 8 bits per pixel take a bank.

**Interrupts and beam.** Vertical blank and a line compare interrupt; beam position registers.

**Memory budget.** Video has cycle 1 of every slot, plus cycle 3 when sprites and copper leave it free:

| | Per picture line at 288 lines (448 slots) | At 576 lines (224 slots) |
|-|-------------------------------------------|---------------------------|
| Cycle 1 alone | 896 bytes | 448 bytes |
| Cycles 1 and 3 | 1792 bytes | 896 bytes |

| Layer | Bytes per line |
|-------|----------------|
| Bitmap 360 wide, 8-bit | 360 (720 hi-res) |
| Bitmap 360 wide, 1-bit | 45 |
| Tiles, 4-bit | 276 (546 hi-res) |
| Attributes | 45 (90 hi-res) |
| Sprites | width × depth ÷ 8 per sprite: a 16×16 4-bit sprite is 8, a 32×32 8-bit one is 32 |

Settings that ask for more than the budget are allowed; the video sets an OVERRUN flag and shows the background colour where data was late, as in retro68k. Example: Spectrum-style 256×192, 1-bit plus 8×8 attributes, uses 64 bytes per line.

### D6. Sprites

- **32 sprites**, each 8, 16 or 32 pixels across and down (set separately), at **1, 2, 4 or 8 bits per pixel**, with a palette bank for fewer than 8 bits.
- **Patterns in SRAM**, anywhere in the 4 MB, given by a pointer per sprite; animation is changing the pointer.
- Attributes (X, Y, size, depth, pointer, bank, flip, priority) in registers.
- On each line, the sprites on that line are fetched during the line before, in cycle 3. How many fit depends on their size and depth (D5); the spec will set the limits.

### D7. Copper

A beam-following coprocessor that writes chipset registers, in version 1. It is more than the Amiga's: it has loops and pointers so that per-cell effects (like attributes from a Spectrum screen in memory) take a short program, not a list the size of the screen.

- **Instructions:** MOVE (value to register), WAIT (beam position), SKIP, a counter with a loop instruction, and an **indirect move**: read a byte from SRAM through pointer X or Y (stepping it) and write it to a register; pointers can be stepped back (for example by 32, to repeat a row of cells).
- **Timing:** the copper runs in step with the line being drawn into the line buffer, not with the beam, so its changes land on the pixels it waited for. Palette writes take effect as the pixel goes out.
- The program is in SRAM, read in cycle 3. A change every 8 pixels is about one memory read per cell, within its share.
- Restarted at the start of each frame.

### D8. Registers

- All chipset registers are **8-bit**, in **Z80 I/O space only**. Only the low 8 bits of the port address are decoded, so `OUT (n),A` works and `OTIR` can stream bytes to one port.
- 16- and 24-bit values (pointers, scroll) are 2 or 3 consecutive ports; the value changes when the last byte is written, so the hardware never sees half a value.
- Big tables (palette, sprite attributes) are reached through an index port and a data port that steps the index after each access.
- 256 ports are a tight fit; if they run out, a bank register selects between groups (spec 3).
- The copper writes the same registers by port number.
- The register list is kept in one file (`fpga/regmap.def`) and turned into sjasmplus, C and Verilog headers by a generator, as in retro68k.

### D9. I/O

| Block | Notes |
|-------|-------|
| USB serial | FT232H in 245 FIFO mode: console and fast uploads, logic from retro68k |
| SD card | SPI byte master; software does the commands, as in retro68k |
| PS/2 keyboard | Raw byte FIFO, as in retro68k |
| Spectrum keyboard | The KS3's 8×7 membrane matrix, read as rows like a Spectrum's port `0xFE` |
| Joysticks | Both KS3 ports, read as plain bits |
| Timers | 2 timers of 16 bits and a frame counter |
| Interrupt controller | About 12 sources, fixed priorities, IM 2 vectors |

### D10. Software and tools

- **HDL:** plain Verilog-2005; chip-specific parts in `fpga/rtl/platform/artix7/` with behavioural copies for simulation.
- **Simulation:** Icarus Verilog for blocks, Verilator for the whole computer (fast enough to run ZEXDOC).
- **Z80 code:** sjasmplus for the boot ROM and system code; z88dk if C is wanted later.
- **Boot ROM:** a monitor (dump, edit, load over USB or SD, run), then **BBC BASIC (Z80)** by R. T. Russell (open source, zlib licence) with a small hardware layer. **CP/M 3** later, using the MMU and hi-res tiles for 80 columns.
- **Shared with retro68k:** the KS3 pin list, MMCM, HDMI and VGA modules, TMDS encoder, the FT232H serial logic, the SRAM and FT232H simulation models, and the register-map generator. They are copied in, since the bus widths differ.

### D11. Block RAM budget

| Item | Blocks (18 Kb) |
|------|----------------|
| Boot ROM, 32 KB | 16 |
| Line buffers (two lines of 720 pixels, 16 bits each) | 2 |
| Palette (512 × 12 bits) | 1 |
| USB serial and keyboard FIFOs | 3 |
| **Total** | **22 of 100** |

The logic budget is to be measured; a Z80 core is about 2–3k LUTs, and the chipset should be well under retro68k's.

## 3. I/O port map (first sketch)

Low byte of the port address only. The full list goes in spec 3.

| Ports | Block |
|-------|-------|
| `0x00`–`0x1F` | System: ID, CPU speed, reset cause, MMU0–MMU7, interrupt controller, timers |
| `0x20`–`0x2F` | USB serial, SD card, PS/2 keyboard, joysticks |
| `0x30`–`0x3F` | Sound (reserved until Q1 is decided) |
| `0x40`–`0x7F` | Video: layers, windows, scroll, palette index/data, beam |
| `0x80`–`0x9F` | Sprite index/data, copper |
| `0xA0`–`0xFD` | Reserved (DMA engine later) |
| `0xFE` | Spectrum keyboard rows (same port as a Spectrum's, for easy ports) |
| `0xFF` | Reserved |

## 4. Specs to write before code

1. **CPU bus interface:** tv80 with clock enables, memory and I/O cycles, the internal chipset bus, IM 2 acknowledge, reset
2. **Memory:** slots, SRAM timing, MMU, boot ROM overlay
3. **Registers:** the full port list
4. **Video:** timing, line buffers, windows, bitmap, tile and attribute layers, palette, budget, interrupts
5. **Sprites**
6. **Copper:** instruction set, timing against the line buffer
7. **System:** reset, boot ROM, buttons, installing as a Next core, board pins
8. **I/O:** serial, SD, keyboards, joysticks, timers, interrupts (short, since most follow retro68k)
9. **Sound:** once Q1 is decided

## 5. Phases

| Phase | Work | Done when |
|-------|------|-----------|
| **0. Plan** | This document agreed, specs written | Specs 1–8 drafted |
| **1. Simulated CPU** | tv80, bus interface, MMU, SRAM controller, boot ROM, USB serial, in simulation | Boot ROM prints "hello" over simulated serial; ZEXDOC passes in Verilator |
| **2. Video** | Tile layer with the boot console, then bitmap, palette, attribute layer | Console text on the simulated screen, checked pixel by pixel |
| **3. On the board** | Build for the KS3; boot monitor | "hello" on a real monitor and over USB; RAM test at 28 MHz |
| **4. Games machine** | Copper, sprites, joysticks | A demo with scrolling tiles, sprites and a Spectrum-style screen drawn by the copper |
| **5. Home computer** | SD card, keyboards, BBC BASIC | Boot to BASIC, load and save a program |
| **6. Next core** | Package and install as a Next core | The KS3 boots retro-z80 from its core menu |
| **Later** | Sound (if not before), DMA engine, CP/M 3, a 6502 version | |

## 6. Open questions

| # | Item | Plan |
|---|------|------|
| Q1 | Sound hardware: AY-style chip(s), sample channels, or both | To be decided; ports `0x30`–`0x3F` kept for it |
| Q2 | 6502 version: build option here or its own repo | To be decided; the chipset stays CPU-independent meanwhile. With registers in I/O space only, a 6502 would see them through a memory page in its bus interface |
| Q3 | Is tv80 exact enough (flags, undocumented instructions, interrupts)? | ZEXDOC and ZEXALL in Verilator in phase 1; fallback T80 (VHDL) |
| Q4 | Copper timing: a cell is 8 pixels, 593 ns at 2× but only 296 ns (about 2 slots) in hi-res. Can the indirect moves keep up while sprites also use cycle 3? | Work out in spec 6; give the copper priority over sprites in cycle 3 if needed |
| Q5 | Are 256 I/O ports enough? | Count them in spec 3; add a bank register if not |
| Q6 | The KS3 details still open in retro68k (SRAM size, accelerator pins, Next core format) | Answered once for both projects |

## 7. Next step

Write specs 1 and 2 (CPU bus interface and memory), then start phase 1 in simulation.
