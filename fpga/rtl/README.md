# FPGA RTL

Plain Verilog-2005, simulated with Icarus Verilog and Verilator in `sim/`. Chip-specific parts go in `platform/artix7/`, with behavioural versions for simulation in `platform/sim/` (design plan, D10).

Modules taken from retro68k are copied here at a recorded retro68k commit and narrowed to retro-z80's byte registers; [PROVENANCE.md](PROVENANCE.md) lists each one's origin and what was changed (design plan, branch 12, "RTL reuse").

Written so far: nothing yet (phase 1, ticket #1 sets up the folders).
