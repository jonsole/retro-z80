# retro-z80

The 8-bit sister of [retro68k](https://github.com/jonsole/retro68k): a homebrew Z80 computer on the **ZX Spectrum Next KS3** board. The Z80 is a soft core in the board's Artix-7 FPGA, main memory is the board's fast SRAM, and the FPGA does the video, sound and I/O with a small chipset sized for an 8-bit CPU. A 6502 version may follow.

## Goals (version 1)

- **CPU:** Z80 soft core at 3.5, 7, 14 or 28 MHz, with no wait states even at 28 MHz
- **Memory:** 4 MB SRAM reached through eight 8 KB MMU windows; 32 KB boot ROM in block RAM
- **Video:** HDMI and VGA at 576p; a 320×256 picture at 2× with a border; one bitmap layer, one tile layer (also the text console, 40 or 80 columns), 64 sprites of 16×16; 256 colours from 4096
- **Sound:** one AY-3-8910-style chip
- **I/O:** USB serial (FT232H), SD card, PS/2 keyboard, joysticks, timers, IM 2 interrupts
- **Later:** copper, DMA engine, sample channels, CP/M, a 6502 version

## Status

Planning. The draft design is in [`docs/design-plan.md`](docs/design-plan.md).
