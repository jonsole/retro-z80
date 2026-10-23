# Simulation

Tests of the computer in simulation: Icarus Verilog for most tests, Verilator for the long ones (ZEXDOC).

```
make            # every test written so far
make smoke      # tool-chain smoke test: sjasmplus assembles a tiny ROM, Icarus checks its words
make vsmoke     # the same test built with Verilator
make hello      # the system: the boot ROM prints "hello" over USB serial, twice
make systest    # the system test ROM: system registers, I/O decode, SRAM bytes, writable boot ROM, soft reset
make speeds     # the speed test ROM: "hello" at every CPUSPEED setting, T-state rates measured
make lint       # Verilator lint of the RTL (fpga/lint.sh)
```

## The system test (`make hello`, `make systest`, `make speeds`)

`tb.v` runs the whole computer (`fpga/rtl/retroz80.v`) in Icarus with retro68k's SRAM model (datasheet timing checks on) and FT232H model. `make hello` assembles the boot ROM (`firmware/boot/boot.asm`, with the generated `hw.inc`), packs it with `tools/bin2hex.py` and runs it: the test passes when "hello" arrives at the FT232H model, the PC side then sends the RESET control command, and "hello" must arrive a second time. `make systest` runs `systest/systest.asm` in place of the boot ROM; it checks SYSID (0x5A) through its port and through `IN A,(0x00)`, the other system registers, the I/O decode, SRAM byte writes, the writable boot ROM and a soft reset, and prints `PASS` or `FAIL nn` (the number of the check).

`make speeds` runs `speeds/speeds.asm`, which copies itself to SRAM and runs from there. It writes CPUSPEED with each setting in turn (20, 10, 6.67, 5, 4, 3.33, 2.86, 2.5 and 3.57 MHz, then the changes between 3.57 MHz and the locked speeds in both directions), reads it back and prints "hello" at each; then a soft reset must bring back 20 MHz. The testbench (`+speeds`) notes the speed at which each line was sent and passes only if every setting printed one.

All three run with the DMA port kept busy (`+dma`), and all check that **the Z80 never waited**: every CPU request is issued in the first of cycles 0 and 2 that comes while it stands, none is turned away, and every byte the core takes from memory is at `di` before the cen edge that ends T2 and equals the memory's byte at that address (by the reset mapping of spec 2, worked out in the testbench), with at least the margin spec 1 gives for the speed (10n − 9 clocks at 20 MHz ÷ n, 43 at 3.57 MHz). They also **measure every T-state** against CPUSPEED, as the testbench works it out from the writes on the core's pins: 5n clocks ending on slot edge 0 or 5 at DIV = n − 1, 28 clocks with SPECTRUM, a new speed only from the first T1 of an M-cycle, and from 3.57 MHz back to a locked speed T-states of 28–32 clocks until that T1, which is on slot edge 0 or 5. With `+speeds` the T1s at 3.57 MHz must also have fallen on every slot edge 0–9. The summary at the end gives the counts, and for each speed the T-states, clocks, the measured rate in MHz, the smallest read margin and the "hello" lines. `hello` and `systest` take about a second each, `speeds` about 20 seconds.

Options: `+rom=FILE`, `+hello`, `+speeds`, `+dma`, `+trace=N` (print the first N memory and I/O accesses), `+timeout=US`.

Needs `iverilog` (12 or 13), `verilator` (5), `sjasmplus` (1.24) and `python3`. Paths can be given with `make SJASMPLUS=... IVERILOG=... VERILATOR=...`. On Windows, run it from an MSYS2 shell (see the main README).

Each test ends by printing `TEST PASSED` or `TEST FAILED`; `make` fails if it is not `TEST PASSED`. Build products go in `build/`.
