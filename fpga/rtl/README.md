# FPGA RTL

Plain Verilog-2005, simulated with Icarus Verilog and Verilator in `sim/`. Chip-specific parts go in `platform/artix7/`, with behavioural versions for simulation in `platform/sim/` (design plan, D10).

Modules taken from retro68k are copied here at a recorded retro68k commit and narrowed to retro-z80's byte registers; [PROVENANCE.md](PROVENANCE.md) lists each one's origin and what was changed (design plan, branch 12, "RTL reuse").

## Rules

- **Widths must add up exactly.** Where a unit rebuilds a register's value from its stored fields (for a read, or to merge a byte write), the concatenation must be exactly the register's width. retro68k found a rebuild of SPRxCTL that was 34 bits for a 32-bit register, which shifted PAL and DEPTH on every half write; it stayed hidden while the CPU wrote whole registers. Every RTL change is linted with Verilator, as retro68k does (its `fpga/lint.sh`, CI job "RTL lint (Verilator)"): `--lint-only --default-language 1364-2005` (`new` and `soft` are SystemVerilog keywords), with **WIDTHTRUNC as an error** (it catches the 34-into-32 case); WIDTHEXPAND is left as a warning, since zero-extension is everywhere and harmless. A deliberate truncation uses an explicit slice, or a one-line `lint_off WIDTHTRUNC` / `lint_on` waiver. Third-party code (tv80) is waived with a `.vlt` file (`lint_off -rule ... -file ...`).
- Each byte register is written directly (spec 3, rule 2); check that a byte write changes only its own byte's fields.

Lint everything with `sh fpga/lint.sh` (or `make -C sim lint`); it fails on any width cut short. CI runs it on every push.

## Written so far

| File | What | Spec |
|------|------|------|
| `retroz80.v` | The computer without board parts: timebase, reset, CPU, memory, registers, serial. `CHIPMB = 2` builds for a 2 MB board: physical bit 21 ignored | 1, 2, 7 |
| `z80_cpu.v` | tv80 with retro-z80's own wrapper: cen, early cycle-type outputs | 1, section 2 |
| `cpu_cen.v` | The CPU's clock enable, set by CPUSPEED: a T-state every 5n clocks on slot edges 0 and 5, or every 28; a new speed from the next T1 | 1, section 3; 7, section 6.1 |
| `bus_if.v` | Bus interface: page looked up in T1, memory requests at E + 3, posted writes, boot ROM, NONE and reserved pages, the register page, I/O decode and register bus strobes | 1, sections 4–6 |
| `mmu.v` | The MMU: read and write page registers MMUn and MMUnW (byte 1 commits; a read-page commit sets the write page), reset mapping. retro-z80's own | 2, section 9 |
| `timebase.v` | Slot edge counter `sc` | 2, section 3 |
| `dmac.v` | Scheduler: CPU on cycles 0 and 2, never turned away | 2, section 5 |
| `sram_ctl.v` | SRAM controller, 20 ns cycles | 2, section 8 |
| `bootrom.v` | 32 KB boot ROM in block RAM, writable with SYSCON.ROMWE | 7, section 4 |
| `sysregs.v` | SYSID, SYSVER, SYSCFG, RESETWHY, SYSCON, SYSRESET, SYSBTN, CPUSPEED | 7, section 11.1 |
| `serial.v`, `fifo8.v` | USB serial (FT232H, 245 FIFO mode) and its FIFOs | 10 |
| `platform/sim/oddr.v` | Behavioural DDR output register | – |

The CPU runs at every CPUSPEED speed (20 MHz ÷ 1–8, or 3.57 MHz). tv80 needs `TV80_REFRESH` defined for the whole build (`-DTV80_REFRESH`).
