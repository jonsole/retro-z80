# FPGA RTL

Plain Verilog-2005, simulated with Icarus Verilog and Verilator in `sim/`. Chip-specific parts go in `platform/artix7/`, with behavioural versions for simulation in `platform/sim/` (design plan, D10).

Modules taken from retro68k are copied here at a recorded retro68k commit and narrowed to retro-z80's byte registers; [PROVENANCE.md](PROVENANCE.md) lists each one's origin and what was changed (design plan, branch 12, "RTL reuse").

## Rules

- **Widths must add up exactly.** Where a unit rebuilds a register's value from its stored fields (for a read, or to merge a byte write), the concatenation must be exactly the register's width. retro68k found a rebuild of SPRxCTL that was 34 bits for a 32-bit register, which shifted PAL and DEPTH on every half write; it stayed hidden while the CPU wrote whole registers. Every RTL change is linted with Verilator (`-Wall`, WIDTH warnings treated as errors), which reports such mismatches.
- Each byte register is written directly (spec 3, rule 2); check that a byte write changes only its own byte's fields.

Written so far: nothing yet (phase 1, ticket #1 sets up the folders).
