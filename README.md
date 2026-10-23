# retro-z80

The 8-bit sister of [retro68k](https://github.com/jonsole/retro68k): a Z80 computer in the FPGA of a **ZX Spectrum Next** (KS2 for bring-up, KS3 for the full machine), for use as a home computer and a games machine. It is retro68k narrowed to 8 bits: the same chipset, registers and memory system, with a Z80 (the tv80 core) at 20 MHz.

## Goals (version 1)

- **CPU:** Z80 at up to 20 MHz, never waiting for memory; IM 2 interrupts
- **Memory:** 4 MB SRAM (2 MB on the KS2) through eight 8 KB MMU windows; 32 KB boot ROM
- **Video:** HDMI and VGA at 576p; three layers, each a bitmap or a tile map, 1×–8× scaling, 24-bit palettes; 8 sprites with fractional scaling; a copper
- **DMA engine:** 4 channels: copy, fill, colour-key copy, logic and add
- **I/O:** USB serial (FT232H), SD card, PS/2 and Spectrum keyboards, joysticks, timers
- **Software:** monitor, then BBC BASIC (Z80); CP/M 3 later

## Status

Phase 1: the simulated CPU. The decisions are in [`docs/design-plan.md`](docs/design-plan.md), the specs in [`docs/spec/`](docs/spec/), the programmer's guide in [`docs/guide/`](docs/guide/), and the work in GitHub Issues.

## Layout

| Folder | What |
|--------|------|
| `fpga/rtl/` | Verilog; `platform/artix7/` chip-specific parts, `platform/sim/` their simulation versions |
| `fpga/third_party/` | Cores by others (tv80) |
| `firmware/boot/`, `firmware/include/` | Boot ROM and headers (sjasmplus) |
| `tools/` | Build tools (Python) |
| `sim/` | Simulation tests (Icarus Verilog, Verilator) |

## Tools

| Tool | Version | Notes |
|------|---------|-------|
| Icarus Verilog | 12 or 13 | `iverilog`, `vvp` |
| Verilator | 5 | For the long simulations (ZEXDOC) |
| sjasmplus | 1.24.0 | Z80 assembler |
| Python 3 | 3.8 or newer | Standard library only |
| Vivado | 2026.1 | FPGA builds, later |

### Windows

As for retro68k: MSYS2 in `C:/msys64`, with the UCRT64 packages `gcc`, `make`, `iverilog`, `yosys`, `python` and `verilator` (`pacman -S mingw-w64-ucrt-x86_64-verilator`). sjasmplus is the Windows build from its GitHub release (`sjasmplus-1.24.0.win.zip`), unpacked into `C:/tools/sjasmplus` and added to the user PATH. Run the Makefiles from an MSYS2 shell (`C:/msys64/usr/bin/bash.exe -l`) with `/ucrt64/bin` and `/c/tools/sjasmplus` first on the PATH, not with Chocolatey's `make`:

```
export PATH=/ucrt64/bin:/c/tools/sjasmplus:$PATH
make -C sim
```

MSYS2's GCC 16.2 cannot link C++20 code built with `-Os`, which Verilator uses by default; `sim/Makefile` builds Verilator models with `-O2` instead.

### Linux

`apt-get install iverilog verilator`, and build sjasmplus from its release source (`make`), as the GitHub Actions workflow does.
