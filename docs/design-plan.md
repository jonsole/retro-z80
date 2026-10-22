# retro-z80 design plan

Status: **draft for review**. Nothing in `fpga/`, `firmware/` or `hardware/` gets built until the decisions below are agreed and each block has a written spec.

retro-z80 is the 8-bit sister of [retro68k](https://github.com/jonsole/retro68k). It runs on the same board, the **ZX Spectrum Next KS3**, with the same video output, storage and USB link, but with a Z80 and a smaller chipset sized for an 8-bit CPU. A 6502 version may follow, so the chipset is kept separate from the CPU from the start.

## Main path

The Z80 is a soft core inside the KS3's Artix-7 FPGA, and main memory is the board's fast SRAM, reached through an MMU of 8 KB pages. The only extra hardware is the FT232H USB module already used by retro68k. The design is installed as another core on the Next, next to the normal Next core and retro68k.

## 1. Requirements

| # | Requirement | Source |
|---|-------------|--------|
| R1 | CPU is a Z80 soft core, at 3.5, 7, 14 or 28 MHz, chosen by software | decided |
| R2 | 64 KB address space mapped onto the SRAM through eight 8 KB windows (MMU) | decided |
| R3 | Chipset is new and scaled down for an 8-bit CPU: tiles, a bitmap and sprites, not retro68k's three planar layers | decided |
| R4 | Version 1 is kept small; extra features (copper, DMA engine, sample channels) come later | decided |
| R5 | Same board and I/O as retro68k: KS3, HDMI and VGA at 576p, SD card, PS/2 keyboard, FT232H USB serial | decided |
| R6 | The chipset talks to the CPU through one 8-bit bus interface, so a 6502 can replace the Z80 later | decided |
| R7 | Usable as a home computer (monitor, then BASIC) and as a games machine (tiles, sprites, joysticks) | proposed |

## 2. Key decisions

### D1. Board: ZX Spectrum Next KS3

Same as retro68k (its design plan, D1): Artix-7 XC7A35T, 4 MB (or 2 MB) of 10 ns SRAM, HDMI and an ADV7125 VGA DAC, audio jack, SD card in SPI mode, PS/2 sockets, two joystick ports, the accelerator port for the FT232H module, and a 50 MHz oscillator. Vivado free edition, scripted in Tcl, loaded over JTAG during development.

The Next is itself a Z80 machine, so the board is a natural fit.

### D2. CPU: a Z80 soft core

| Core | Language | Licence | Notes |
|------|----------|---------|-------|
| **tv80** (proposed) | Verilog | BSD-style (from T80) | A Verilog version of T80; works with Icarus and Verilator like the rest of the design |
| T80 | VHDL | BSD-style | The core the Next uses (as T80N); Vivado takes mixed languages, but Icarus and Verilator do not read VHDL |

Proposal: **tv80**, checked with the ZEXDOC/ZEXALL instruction tests (open question Q1). The core runs on the 56 MHz system clock with a clock enable: one T-state every 2, 4, 8 or 16 clocks gives 28, 14, 7 or 3.5 MHz. The CPUSPEED register changes the speed at once; the speed at reset is open question Q6.

Interrupts use the Z80's own modes: **IM 2** with a vector byte from the interrupt controller during the acknowledge cycle, or IM 1 (RST 38h) with a status register to read. NMI comes from the Multiface button and a USB "break".

### D3. Clocks

- **System clock 56 MHz**, from MMCM 1: 50 MHz × 21 = VCO 1050 MHz, ÷ 18.75 (CLKOUT0 has a fractional divider). The CPU speeds are clock enables, not separate clocks.
- **Pixel clock 27 MHz** (and 135 MHz for HDMI) from MMCM 2, exactly as in retro68k. The two are treated as asynchronous.
- Both come from one oscillator, so every 576p line (32 µs) is exactly **1792 system clocks = 224 memory slots**: the display's memory use repeats the same way on every line.

### D4. Memory: slots and the MMU

**Slots.** SRAM time is cut into slots of 4 memory cycles. A memory cycle is 2 system clocks (35.7 ns, a gentle cycle for a 10 ns SRAM) and moves 16 bits; a slot is 143 ns, one 28 MHz T-state per cycle.

| Cycle | Owner |
|-------|-------|
| 0 | CPU |
| 1 | Video (tiles, bitmap) |
| 2 | CPU |
| 3 | Sprites, then anything with work waiting |

A cycle its owner does not use goes to the others. The CPU has a cycle every 2 T-states, and a Z80 never touches memory more often than every 3, so **the Z80 never waits, even at 28 MHz** (the real Next adds a wait state at 28 MHz). A 6502, which uses memory on every clock, would get up to 14 MHz with no waits from the same slots. Total bandwidth is 56 MB/s; the video needs less than a quarter of it (D5).

**MMU.** The Z80's 64 KB is eight 8 KB windows. Each window has a 10-bit page register (MMU0–MMU7, two ports each):

| Page | Meaning |
|------|---------|
| `0x000`–`0x1FF` | SRAM, 512 pages of 8 KB (4 MB); `0x100` and up do not exist on a 2 MB board |
| `0x3FC`–`0x3FF` | Boot ROM, 4 pages (32 KB of block RAM) |
| Others | Reserved: reads give `0xFF`, writes are ignored |

At reset, windows 0–1 map boot ROM pages 0–1 (so the Z80 starts in the ROM at `0x0000`) and windows 2–7 map SRAM pages 0–5. A window can be set read-only, so RAM loaded with a ROM image behaves like ROM.

Video data, sprite patterns and sound live in the SRAM like everything else; the CPU reaches them by mapping their pages into a window.

### D5. Video (version 1)

Kept on purpose much smaller than retro68k's.

- **Output:** 576p (720×576 at 50 Hz) over HDMI and VGA at once, as in retro68k, so the same platform modules are used. The picture is **320×256 shown at 2×** (640×512) in the middle of the screen with a border colour around it, like a PAL home computer. A hi-res setting doubles the width to 640 for 80-column text.
- **Line buffers.** Each picture line is drawn into a line buffer in block RAM while the line before it is shown (each picture line lasts two 576p lines, 64 µs). This makes layers and sprites simple and keeps memory reads in short bursts.
- **Layers**, back to front in a fixed order (with a priority bit on tiles and sprites):
  1. **Border/background colour**
  2. **Bitmap layer:** 320×256 at 4 or 8 bits per pixel (40 KB or 80 KB), or 640×256 at 4 bits; scroll in X and Y, wrapping in its pages
  3. **Tile layer:** a 64×32 map of 8×8 tiles, 2 bytes per entry (tile number, palette offset, X/Y flip, priority); tiles at 4 bits per pixel, or 1 bit per pixel for text with a foreground colour; scroll in X and Y. The boot ROM's console is this layer
  4. **Sprites:** 64 sprites of 16×16 at 4 bits per pixel (with a palette offset), up to 16 on one line; attributes (X, Y, pattern, palette, flip, priority) in block RAM, patterns in SRAM
- **Palette:** one of 256 colours, 12-bit RGB (4096 colours, as on the Amiga OCS), in block RAM. Each layer and sprite picks a 16-colour bank for 4-bit data.
- **Interrupts:** vertical blank and a line compare. Beam position registers.
- **Memory budget per picture line (64 µs, 448 slots):** cycle 1 alone gives 896 bytes. An 8-bit bitmap uses 320, the tile layer up to 246, 16 sprites 128: about 700 bytes.

No copper, no multiple bitmap layers and no direct colour in version 1.

### D6. Sound (version 1)

- **One AY-3-8910-style sound chip** (3 tone channels, noise, envelope), the sound of the Spectrum 128, MSX and Amstrad CPC, so existing Z80 music players work with little change.
- Output by sigma-delta to the audio jack and the internal speaker, as in retro68k.
- Later: a second AY (as in the Next's TurboSound) or 2 DMA sample channels.

### D7. Registers: one 8-bit block, in I/O space

- All chipset registers are 8-bit and form **one block of 256 registers**. On the Z80 the block is in I/O space and **only the low 8 bits of the port address are decoded**, so `OUT (n),A` works and `OTIR` can stream bytes to one port.
- Big tables (palette, sprite attributes) are reached through an index port and a data port that steps the index after each access, so `OTIR` loads them quickly.
- For the 6502, which has no I/O space, the same block is mapped into one 256-byte memory page; only the bus interface changes.
- The register list is kept in one file (`fpga/regmap.def`) and turned into assembler, C and Verilog headers by a generator, as in retro68k.

### D8. I/O

| Block | Version 1 | Notes |
|-------|-----------|-------|
| USB serial | Yes | FT232H in 245 FIFO mode: console and fast uploads, logic from retro68k |
| SD card | Yes | SPI byte master; software does the commands, as in retro68k |
| PS/2 keyboard | Yes | Raw byte FIFO, as in retro68k |
| Joysticks | Yes | Both KS3 ports, read as plain bits |
| Timers | Yes | 2 timers, 16-bit, plus a frame counter (fewer than retro68k) |
| Interrupt controller | Yes | About 10 sources, fixed priorities, IM 2 vectors |
| Spectrum keyboard, mouse, RTC | Later | |

### D9. Tools and languages

- **HDL:** plain Verilog-2005; chip-specific parts in `fpga/rtl/platform/artix7/`, with behavioural copies for simulation, as in retro68k.
- **Simulation:** Icarus Verilog for blocks, Verilator for the whole computer (fast enough to run ZEXDOC).
- **Z80 software:** `sjasmplus` for the boot ROM, `z88dk` for C.
- **BASIC:** BBC BASIC (Z80) by R. T. Russell, open source; CP/M 2.2 or 3 later, which needs the 80-column text setting.
- **Shared with retro68k:** the KS3 pin list, MMCM, HDMI and VGA output modules, TMDS encoder, the FT232H serial logic, the SRAM and FT232H simulation models and the register-map generator. They are copied in (not linked), since the bus widths differ; changes that help both are made in both.

### D10. Block RAM budget

| Item | Blocks (18 Kb) |
|------|----------------|
| Boot ROM, 32 KB | 16 |
| Line buffers (two lines of 640 pixels, 16 bits each) | 2 |
| Palette (256 × 12 bits) | 1 |
| Sprite attributes | 1 |
| USB serial FIFOs, keyboard FIFO | 3 |
| **Total** | **23 of 100** |

The logic budget is to be measured; a Z80 core is about 2–3k LUTs, so the whole design should use well under half the XC7A35T.

## 3. Memory and I/O map

**Z80 memory** (64 KB): eight 8 KB windows, set by MMU0–MMU7 (D4).

**Z80 I/O ports** (low byte only; a first sketch, the real list goes in spec 3):

| Ports | Block |
|-------|-------|
| `0x00`–`0x0F` | System: ID, CPU speed, reset cause, MMU0–MMU7 |
| `0x10`–`0x1F` | Interrupt controller and timers |
| `0x20`–`0x2F` | USB serial, SD card, keyboard, joysticks |
| `0x30`–`0x3F` | Sound (AY register select and data) |
| `0x40`–`0x7F` | Video: layers, scroll, palette and sprite index/data ports, beam |
| `0x80`–`0xFF` | Reserved (later: copper, DMA engine, sample channels) |

## 4. Specs to write before code

1. **CPU bus interface:** Z80 core with clock enables, memory and I/O cycles, the internal 8-bit chipset bus, interrupt acknowledge, reset
2. **Memory:** slots, SRAM timing, MMU, boot ROM overlay
3. **Registers:** the full port list
4. **Video:** timing, line buffers, bitmap and tile layers, palette, interrupts
5. **Sprites**
6. **Sound:** AY-style chip, sigma-delta output
7. **System:** reset, boot ROM, start-up, buttons, installing as a Next core, board pins
8. **I/O:** serial, SD, keyboard, joysticks, timers, interrupts (short, since most follow retro68k)

## 5. Phases

| Phase | Work | Done when |
|-------|------|-----------|
| **0. Plan** | This document agreed, specs written | Decisions D1–D10 signed off |
| **1. Simulated CPU** | tv80 + bus interface + MMU + SRAM controller + boot ROM + USB serial, in simulation | Boot ROM prints "hello" over simulated serial; ZEXDOC passes in Verilator |
| **2. Video** | Tile layer with the boot console, then the bitmap layer and palette | Console text on the simulated screen, checked pixel by pixel |
| **3. On the board** | Build for the KS3; boot monitor (dump, edit, load over USB, run) | "hello" on a real monitor and over USB; RAM test at 28 MHz |
| **4. Games machine** | Sprites, AY sound, joysticks | A small demo with scrolling tiles, sprites and music |
| **5. Home computer** | SD card, PS/2 keyboard, BBC BASIC | Boot to BASIC, load and save a program |
| **6. Next core** | Package and install as a Next core | The KS3 boots retro-z80 from its core menu |
| **Later** | Copper, DMA engine, sample channels, CP/M, the 6502 version | |

## 6. Open questions

| # | Item | Plan |
|---|------|------|
| Q1 | Is tv80 exact enough (flags, undocumented instructions, interrupt timing)? | Run ZEXDOC and ZEXALL in Verilator in phase 1; fall back to T80 (VHDL) with GHDL for simulation |
| Q2 | Does the Z80 need to be cycle-exact to a real one? | Not planned: code is new, not Spectrum software. Say if Spectrum compatibility matters |
| Q3 | Bitmap at 4 and 8 bits, or 8 bits only? | Proposed both; 4-bit halves memory and makes 640 wide possible |
| Q4 | One AY, or two, or sample channels in version 1? | Proposed one AY; the others later |
| Q5 | Should the 6502 version be a build option of this repo, or its own repo? | Proposed a build option here, since only the CPU and its bus interface change |
| Q6 | Start-up CPU speed: 3.5 MHz (like a Spectrum) or 28 MHz? | Proposed 28 MHz; software can slow down |
| Q7 | The KS3 details still open in retro68k (SRAM size, accelerator pins, Next core format) | Answered once for both projects |

## 7. Next step

Review this plan and change anything that doesn't feel right, especially the size of version 1 (D5, D6) and the open questions. Then write the specs in section 4, starting with the CPU bus interface and memory, and begin phase 1 in simulation.
