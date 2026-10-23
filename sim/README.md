# Simulation

Tests of the computer in simulation: Icarus Verilog for most tests, Verilator for the long ones (ZEXDOC).

```
make            # every test written so far
make smoke      # tool-chain smoke test: sjasmplus assembles a tiny ROM, Icarus checks its words
make vsmoke     # the same test built with Verilator
```

Needs `iverilog` (12 or 13), `verilator` (5), `sjasmplus` (1.24) and `python3`. Paths can be given with `make SJASMPLUS=... IVERILOG=... VERILATOR=...`. On Windows, run it from an MSYS2 shell (see the main README).

Each test ends by printing `TEST PASSED` or `TEST FAILED`; `make` fails if it is not `TEST PASSED`. Build products go in `build/`.
