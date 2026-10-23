# Provenance

Modules and files copied from [retro68k](https://github.com/jonsole/retro68k) (design plan, branch 12, "RTL reuse"). Copy only from a committed retro68k state. Later retro68k fixes are ported by hand: compare its git log since the commit below.

| File here | From retro68k | retro68k commit | What was changed |
|-----------|---------------|-----------------|------------------|
| `tools/bin2hex.py` | `tools/bin2hex.py` | 57e7f6d | Writes little-endian words |
| `tools/regmap.py` | `tools/regmap.py` | 57e7f6d | Byte registers with a width (1–4 bytes) in place of 32-bit words; I/O pages with ports (`_P`), custom offsets and register page offsets; byte names NAME0–NAME3 (spec 3, section 8); `regs` with a width and fields, `port`, element arrays (`MMU`, `MMUnW`); access flags; copper MOVE reach check; `INTB_`/`INTR_` names; sjasmplus `hw.inc`, a C `hw.h` with the same names and `CPORT`, a `regmap.vh` with bus addresses and decodes; `--verify` reads spec 3's tables, ports, register page and interrupt sources, and quoted values; `--def`, `--spec` and `--out` for the self-test. `struct` left out |
| `fpga/rtl/sram_ctl.v` | `fpga/rtl/sram_ctl.v` | 57e7f6d | Unchanged |
| `fpga/rtl/fifo8.v` | `fpga/rtl/fifo8.v` | 57e7f6d | Unchanged |
| `fpga/rtl/platform/sim/oddr.v` | `fpga/rtl/platform/sim/oddr.v` | 57e7f6d | Unchanged |
| `fpga/rtl/dmac.v` | `fpga/rtl/dmac.v` | 57e7f6d | retro-z80's cycle owners (spec 2, section 5): the CPU owns cycles 0 and 2 and a CPU request there is never overridden (rule 0, before the urgent rule); cycle 4 kept for audio (then the copper at high priority), cycle 2 no longer audio's. Left out: the nasty copper (PRI 2 and 3 act as 1) and the DMA engine's HIGH mode (`blt_high`, `blt_share` and the share counter) |
| `fpga/rtl/timebase.v` | `fpga/rtl/timebase.v` | 57e7f6d | Only `sc`: `ph` (the 40 MHz phase) left out, as tv80 runs on the system clock |
| `fpga/rtl/bootrom.v` | `fpga/rtl/bootrom.v` | 57e7f6d | The second (DMA engine) read port left out until the DMA engine comes (spec 14) |
| `fpga/rtl/sysregs.v` | `fpga/rtl/sysregs.v` | 57e7f6d | Byte registers `0x70`–`0x77` on the 8-bit register bus (13-bit address, `rb_hit`): SYSID `0x5A`, SYSVER one byte, SYSCFG CPU and CHIPMB, RESETWHY, SYSCON ROMWE and ROMLOCK only (ROMWE cannot be set while ROMLOCK is or becomes 1, and reads back as stored), SYSRESET `0xA5`, SYSBTN, CPUSPEED (retro-z80 only: DIV and SPECTRUM, bits 7–4 read 0; the divider is `cpu_cen.v`). Left out: OVERLAY, PROTECT, HALTRESET, SYSSTAT, BUSERRADDR, BUSERRWHY, the byte-enable merge. I2C and the NMI registers come later |
| `fpga/rtl/serial.v` | `fpga/rtl/serial.v` | 57e7f6d | Registers narrowed to spec 10, section 7, on the 8-bit register bus: SERSTAT0/1 saturating counts, SERDATA empty reads `0x00`, SERLEVEL as two 4-bit level codes, SERTIME in 16 µs steps (8 bits), SERDROP 8 bits saturating, SERCON.RXFLUSH and TXFLUSH. The FT232H interface and the control-command matcher are unchanged, but reset only by power-on (`por`), so the link is not disturbed by other resets (spec 7, section 3.2; spec 10, U7) |
| `sim/sram_model.v` | `sim/sram_model.v` | 57e7f6d | Unchanged |
| `sim/ft232h_model.v` | `sim/ft232h_model.v` | 57e7f6d | Unchanged |
| `sim/tb.v` | `sim/tb.v` | 57e7f6d | Structure only (pads, SRAM and FT232H models, DMA port load, the PASS/FAIL scan, the control-command task); rewritten for the Z80, with the never-waited checks |
| `fpga/rtl/retroz80.v` | `fpga/rtl/retro68k.v` | 57e7f6d | Structure only (timebase, microsecond tick, reset logic, unit wiring); rewritten for tv80 on one clock. RESETWHY sets exactly one bit (UPLOAD alone, not USB too). The scheduler and SRAM controller are reset only at power-on |
| `fpga/rtl/z80_cpu.v` | – (tv80's `tv80s.v`, upstream `66a131c`) | – | retro-z80's own wrapper (spec 1, section 2.1): cen passed to the core and gating the strobes and read register, the early cycle-type outputs brought out, each strobe assigned once per clock |
