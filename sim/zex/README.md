# ZEX tests

Frank D. Cringle's Z80 instruction set exercisers, run on the bare tv80 core by `tb_zex.v` (ticket #2, design plan Q3) and on the whole system by `tb_zexsys.v` (ticket #7).

| File | What |
|------|------|
| `zexdoc.com`, `zexdoc.z80` | ZEXDOC: 67 tests of every instruction, checking the documented flags |
| `zexall.com`, `zexall.z80` | ZEXALL: the same, also checking the undocumented flags (bits 5 and 3) |
| `LICENSE` | GNU GPL v2 (the programs say "version 2 or later") |
| `cpm.asm` | The CP/M pieces they need: page zero and a BDOS (functions 2 and 9) that writes to I/O port CONSOLE: 0x00 on the bare core, 0x01 (a reserved port) on the whole system |
| `hello.asm`, `bad.asm` | Checks of the testbench: one run must pass, one must fail |
| `rtest.asm` | R register test: R counts M1s and keeps bit 7 (BBC BASIC's RUN needs it) |
| `tb_zex.v`, `zex_main.cpp` | The testbench, and the C++ main that clocks it |
| `tb_zexsys.v`, `zexsys_main.cpp` | The whole-system testbench (the computer at 20 MHz, with the never-waited checks), and the C++ main that clocks it |
| `zexboot.asm` | Its boot ROM: maps SRAM pages 0–7 flat and jumps to 0x0100 |
| `RESULTS.md` | The results on tv80, bare and in the whole system |

The programs and their sources come from [github.com/agn453/ZEXALL](https://github.com/agn453/ZEXALL) at commit `8f71d41` (2025-06-15), which took them from YAZE-AG 2.51.3. They are copied unchanged (`.z80` sources with LF line endings). ZEXDOC and ZEXALL are test programs run in simulation only; nothing of them goes into the FPGA or the boot ROM.

The testbench loads `cpm.bin` at 0x0000 and the program at 0x0100, and runs tv80s (Mode 0, T2Write 1, IOWait 1, `TV80_REFRESH`) with one clock per T-state and a 64 KB RAM that answers in the same clock. It passes when every test prints `OK`, none prints `ERROR`, and the program prints `Tests complete` and jumps to 0. See `sim/README.md` for the commands.

`tb_zexsys.v` runs the same programs on the computer itself: tv80 behind the bus interface, the MMU and the SRAM controller at 20 MHz. See "ZEXDOC on the whole system" in `sim/README.md`.
