# ZEX results on tv80

Ticket #2 and design plan Q3: is tv80 exact enough to build on?

**Yes.** ZEXDOC and ZEXALL both pass all 67 tests on the bare core, documented and undocumented flags alike. The R register counts as on a real Z80.

## Set-up

| Item | Value |
|------|-------|
| Core | tv80 at upstream `66a131c` (2026-05-11), `fpga/third_party/tv80/` |
| Wrapper | `tv80s`, Mode 0, T2Write 1, IOWait 1, `TV80_REFRESH` defined (spec 1) |
| Memory | 64 KB RAM that answers in the same clock; no wait states, no interrupts |
| Simulator | Verilator 5.050 (MSYS2 UCRT64, GCC 16.2, `-O2`), `tb_zex.v` with `zex_main.cpp` |
| Programs | `zexdoc.com` and `zexall.com` from agn453/ZEXALL `8f71d41` |
| Date | 2026-10-23 |

## Run times

| | ZEXDOC | ZEXALL |
|--|--------|--------|
| Result | 67 of 67 OK, TEST PASSED | 67 of 67 OK, TEST PASSED |
| T-states (clocks) | 46,740 million | 46,740 million |
| Wall time, 7 jobs each, both at once on 16 threads | 88 minutes | 85 minutes |

The model runs 3.8–4.3 million T-states a second per process. The wall time is set by test 5 (`aluop a,<b,c,d,e,h,l,(hl),a>`, 20,000 million T-states, about 85 minutes), not by the number of CPUs: with 3 or more jobs the other 66 tests finish before it. On one CPU a whole program would take about 3 hours. Verilator's own timing scheduler (`--binary` with an `always #5` clock) ran 3.4 times slower than the C++ clock.

## Tests

The T-states are for one test run alone (`+only=K`); they are the same for ZEXDOC and ZEXALL.

| K | Test | T-states | ZEXDOC | ZEXALL |
|---|------|----------|--------|--------|
| 0 | `<adc,sbc> hl,<bc,de,hl,sp>` | 2260474120 | OK | OK |
| 1 | `add hl,<bc,de,hl,sp>` | 1124962528 | OK | OK |
| 2 | `add ix,<bc,de,ix,sp>` | 1125689568 | OK | OK |
| 3 | `add iy,<bc,de,iy,sp>` | 1125689568 | OK | OK |
| 4 | `aluop a,nn` | 574696314 | OK | OK |
| 5 | `aluop a,<b,c,d,e,h,l,(hl),a>` | 20006919112 | OK | OK |
| 6 | `aluop a,<ixh,ixl,iyh,iyl>` | 10169848624 | OK | OK |
| 7 | `aluop a,(<ix,iy>+1)` | 5123003030 | OK | OK |
| 8 | `bit n,(<ix,iy>+1)` | 40249582 | OK | OK |
| 9 | `bit n,<b,c,d,e,h,l,(hl),a>` | 1290424183 | OK | OK |
| 10 | `cpd<r>` | 252189321 | OK | OK |
| 11 | `cpi<r>` | 252555204 | OK | OK |
| 12 | `<daa,cpl,scf,ccf>` | 1108965247 | OK | OK |
| 13 | `<inc,dec> a` | 59895934 | OK | OK |
| 14 | `<inc,dec> b` | 59895934 | OK | OK |
| 15 | `<inc,dec> bc` | 30699063 | OK | OK |
| 16 | `<inc,dec> c` | 59895934 | OK | OK |
| 17 | `<inc,dec> d` | 59895934 | OK | OK |
| 18 | `<inc,dec> de` | 30699063 | OK | OK |
| 19 | `<inc,dec> e` | 59895934 | OK | OK |
| 20 | `<inc,dec> h` | 59895934 | OK | OK |
| 21 | `<inc,dec> hl` | 30699063 | OK | OK |
| 22 | `<inc,dec> ix` | 30734903 | OK | OK |
| 23 | `<inc,dec> iy` | 30734903 | OK | OK |
| 24 | `<inc,dec> l` | 59895934 | OK | OK |
| 25 | `<inc,dec> (hl)` | 59921022 | OK | OK |
| 26 | `<inc,dec> sp` | 30699063 | OK | OK |
| 27 | `<inc,dec> (<ix,iy>+1)` | 125038584 | OK | OK |
| 28 | `<inc,dec> ixh` | 59967614 | OK | OK |
| 29 | `<inc,dec> ixl` | 59967614 | OK | OK |
| 30 | `<inc,dec> iyh` | 59967614 | OK | OK |
| 31 | `<inc,dec> iyl` | 59967614 | OK | OK |
| 32 | `ld <bc,de>,(nnnn)` | 596958 | OK | OK |
| 33 | `ld hl,(nnnn)` | 297034 | OK | OK |
| 34 | `ld sp,(nnnn)` | 297034 | OK | OK |
| 35 | `ld <ix,iy>,(nnnn)` | 597638 | OK | OK |
| 36 | `ld (nnnn),<bc,de>` | 1367762 | OK | OK |
| 37 | `ld (nnnn),hl` | 297034 | OK | OK |
| 38 | `ld (nnnn),sp` | 297034 | OK | OK |
| 39 | `ld (nnnn),<ix,iy>` | 1369082 | OK | OK |
| 40 | `ld <bc,de,hl,sp>,nnnn` | 1183607 | OK | OK |
| 41 | `ld <ix,iy>,nnnn` | 597434 | OK | OK |
| 42 | `ld a,<(bc),(de)>` | 865175 | OK | OK |
| 43 | `ld <b,c,d,e,h,l,(hl),a>,nn` | 1139028 | OK | OK |
| 44 | `ld (<ix,iy>+1),nn` | 597604 | OK | OK |
| 45 | `ld <b,c,d,e>,(<ix,iy>+1)` | 10493803 | OK | OK |
| 46 | `ld <h,l>,(<ix,iy>+1)` | 5216209 | OK | OK |
| 47 | `ld a,(<ix,iy>+1)` | 2521929 | OK | OK |
| 48 | `ld <ixh,ixl,iyh,iyl>,nn` | 594141 | OK | OK |
| 49 | `ld <bcdehla>,<bcdehla>` | 90866523 | OK | OK |
| 50 | `ld <bcdexya>,<bcdexya>` | 186809948 | OK | OK |
| 51 | `ld a,(nnnn) / ld (nnnn),a` | 865083 | OK | OK |
| 52 | `ldd<r> (1)` | 865405 | OK | OK |
| 53 | `ldd<r> (2)` | 865888 | OK | OK |
| 54 | `ldi<r> (1)` | 865405 | OK | OK |
| 55 | `ldi<r> (2)` | 865888 | OK | OK |
| 56 | `neg` | 262721622 | OK | OK |
| 57 | `<rrd,rld>` | 141537116 | OK | OK |
| 58 | `<rlca,rrca,rla,rra>` | 120817190 | OK | OK |
| 59 | `shf/rot (<ix,iy>+1)` | 8190086 | OK | OK |
| 60 | `shf/rot <b,c,d,e,h,l,(hl),a>` | 183152447 | OK | OK |
| 61 | `<set,res> n,<bcdehl(hl)a>` | 183601916 | OK | OK |
| 62 | `<set,res> n,(<ix,iy>+1)` | 8573900 | OK | OK |
| 63 | `ld (<ix,iy>+1),<b,c,d,e>` | 23965435 | OK | OK |
| 64 | `ld (<ix,iy>+1),<h,l>` | 5216209 | OK | OK |
| 65 | `ld (<ix,iy>+1),a` | 1220253 | OK | OK |
| 66 | `ld (<bc,de>),a` | 1903579 | OK | OK |

## tv80's known quirks

None showed. Upstream fixed three ZEXALL failures in May 2026 (commit `59d343e`, Howard Harte): DAA computed P/V over the wrong width (`<daa,cpl,scf,ccf>`, which ZEXDOC also checks), and CPI/CPD set the undocumented X and Y flags by the plain CP rule (`cpi<r>`, `cpd<r>`). Older copies of tv80 (OpenCores, and GitHub before May 2026) have these bugs, so keep to the recorded commit or later.

## R register

`rtest.asm` (run by `make zexhello`) checks that R counts, since BBC BASIC (Z80) waits in RUN until `LD A,R` gives a non-zero value. Expected values are a real Z80's.

| Check | Expected | tv80 |
|-------|----------|------|
| `LD R,A` with 0x80, then `LD A,R` (two M1s) | 0x82 | OK |
| 0xFF, 200 NOPs, `LD A,R`: the low 7 bits wrap, bit 7 is kept | 0xC9 | OK |
| Two `LD A,R` with `LD B,A` between differ by | 3 | OK |
| A DD prefix is an M1: `INC IX` counts | 2 (4 with `LD A,R`) | OK |
| `BIT 0,(IX+0)` (DD CB d op) counts | 2 (4 with `LD A,R`) | OK |

Without `TV80_REFRESH` the core never counts R: every check reads 0x00, and RUN would hang. So `TV80_REFRESH` is required, as spec 1 says.

## Bus timing seen in the trace

`+trace=N` shows tv80s's strobes. Two details differ from spec 1 (section 5.1 and section 7); neither changes the bus interface's design:

| What | Spec 1 says | tv80s does |
|------|-------------|------------|
| Refresh in M1 | mreq_n and rfsh_n low in T3 and T4 | rfsh_n low in T3 and T4, mreq_n low in T4 only |
| Memory write | mreq_n and wr_n high at the end of the cycle | mreq_n and wr_n low in T2 only; high again from the start of T3 |

The rest matches: A and m1_n at the start of T1, mreq_n and rd_n low from the start of T2, dout valid at the start of T2, and an I/O cycle of 4 T-states with iorq_n and rd_n or wr_n low in T2 and TW. In `OUT (n),A` A15–A8 carry A.

## Open points

- Interrupts, NMI, wait states, HALT and the block I/O address (spec 1, B7, B8, B11) are not tested here; they come with the bus interface.
- Test 5 sets the run time. Splitting it (the testbench could run part of its counter range) would bring both programs under 30 minutes on 16 threads, if that is ever needed in CI.
