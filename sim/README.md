# Simulation

Tests of the computer in simulation: Icarus Verilog for most tests, Verilator for the long ones (ZEXDOC).

```
make            # every test written so far (smoke, vsmoke, zexhello)
make smoke      # tool-chain smoke test: sjasmplus assembles a tiny ROM, Icarus checks its words
make vsmoke     # the same test built with Verilator
make zexhello   # the ZEX testbench's own checks (seconds): a CP/M program that must pass,
                # one that must fail, and the R register test
make zexdoc     # ZEXDOC on the bare tv80 core in Verilator (long, see below)
make zexall     # ZEXALL, the same with the undocumented flags (long)
```

Needs `iverilog` (12 or 13), `verilator` (5), `sjasmplus` (1.24) and `python3`. Paths can be given with `make SJASMPLUS=... IVERILOG=... VERILATOR=...`. On Windows, run it from an MSYS2 shell (see the main README).

Each test ends by printing `TEST PASSED` or `TEST FAILED`; `make` fails if it is not `TEST PASSED`. Build products go in `build/`.

## ZEXDOC and ZEXALL

`zex/` runs CP/M programs on the bare tv80 core (ticket #2): `tb_zex.v` with a C++ clock (`zex_main.cpp`), 64 KB of RAM, and a BDOS for functions 2 and 9 (`cpm.asm`). See `zex/README.md` for the files and `zex/RESULTS.md` for the results.

Each of the 67 tests runs as its own process, `ZEX_JOBS` at a time (default: the number of CPUs); the results are collected into `build/zexdoc.log` or `build/zexall.log`, one line per test. The model runs about 4 million T-states a second, so the 46,740 million T-states of each program would take about 3 hours on one CPU. With 3 or more jobs a program takes about 85–90 minutes, the time of its longest test (test 5, 20,000 million T-states); both at once with 7 jobs each took 88 minutes on 16 threads. They are left out of `make` for that reason.

```
make zexdoc ZEX_JOBS=8                        # 8 tests at a time
cd build && ./vl_zex/vzex +cpm=cpm.bin +com=../zex/zexdoc.com +tests=1 +only=4
                                              # one test (here 4, aluop a,nn: 2 minutes)
cd build && ./vl_zex/vzex +cpm=cpm.bin +com=hello.com +tests=2 +trace=100
                                              # the bus for the first 100 clocks
```
