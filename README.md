# retro-z80

The 8-bit sister of [retro68k](https://github.com/jonsole/retro68k): a new homebrew Z80 computer on the **ZX Spectrum Next KS3** board, for use as a home computer and a games machine. The Z80 is a soft core (tv80) in the board's FPGA, main memory is the board's fast SRAM, and the FPGA does the video and I/O with a small chipset made for an 8-bit CPU.

## Goals (version 1)

- **CPU:** Z80 at 3.5, 7, 14 or 28 MHz, no wait states even at 28 MHz; IM 2 interrupts
- **Memory:** 4 MB SRAM through eight 8 KB MMU windows; 32 KB boot ROM
- **Video:** HDMI and VGA at 576p; a 360×288 picture at 2×; bitmap layer (1–8 bits per pixel), 8×8 tile layer (1–8 bits per pixel, also the text console), an attribute layer for Spectrum-style colour cells, 32 sprites of 8–32 pixels with fractional scaling (1/16× to 16×); per-layer windows, hi-res and 576-line settings; 512 colours on screen from 4096
- **Copper:** beam-following, with loops and indirect moves
- **I/O:** USB serial (FT232H), SD card, PS/2 and Spectrum keyboards, joysticks, timers
- **Software:** monitor, then BBC BASIC (Z80)
- **Later:** sound (to be decided), DMA engine, CP/M 3, maybe a 6502 version

## Status

Planning. The decisions and the design are in [`docs/design-plan.md`](docs/design-plan.md); each block has a draft spec in [`docs/spec/`](docs/spec/).
