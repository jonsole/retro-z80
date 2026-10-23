# Simulation

Tests of the computer in simulation: Icarus Verilog for most tests, Verilator for the long ones (ZEXDOC).

```
make            # every test written so far
make smoke      # tool-chain smoke test: sjasmplus assembles a tiny ROM, Icarus checks its words
make vsmoke     # the same test built with Verilator
make hello      # the system: the boot ROM prints "hello" over USB serial, twice
make systest    # the system test ROM: system registers, I/O decode, SRAM bytes, writable boot ROM, soft reset
make lint       # Verilator lint of the RTL (fpga/lint.sh)
```

## The system test (`make hello`, `make systest`)

`tb.v` runs the whole computer (`fpga/rtl/retroz80.v`) in Icarus with retro68k's SRAM model (datasheet timing checks on) and FT232H model. `make hello` assembles the boot ROM (`firmware/boot/boot.asm`, with the generated `hw.inc`), packs it with `tools/bin2hex.py` and runs it: the test passes when "hello" arrives at the FT232H model, the PC side then sends the RESET control command, and "hello" must arrive a second time. `make systest` runs `systest/systest.asm` in place of the boot ROM; it checks SYSID (0x5A) through its port and through `IN A,(0x00)`, the other system registers, the I/O decode, SRAM byte writes, the writable boot ROM and a soft reset, and prints `PASS` or `FAIL nn` (the number of the check).

Both run with the DMA port kept busy (`+dma`), and both check that **the Z80 never waited**: every CPU request is issued in the first of cycles 0 and 2 that comes while it stands, none is turned away, and every byte the core takes from memory is at `di` before the cen edge that ends T2 and equals the memory's byte at that address (by the reset mapping of spec 2, worked out in the testbench). The summary at the end gives the counts. Each takes about a second.

Options: `+rom=FILE`, `+hello`, `+dma`, `+trace=N` (print the first N memory and I/O accesses), `+timeout=US`.

Needs `iverilog` (12 or 13), `verilator` (5), `sjasmplus` (1.24) and `python3`. Paths can be given with `make SJASMPLUS=... IVERILOG=... VERILATOR=...`. On Windows, run it from an MSYS2 shell (see the main README).

Each test ends by printing `TEST PASSED` or `TEST FAILED`; `make` fails if it is not `TEST PASSED`. Build products go in `build/`.
