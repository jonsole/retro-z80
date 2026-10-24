# Simulation

Tests of the computer in simulation: Icarus Verilog for most tests, Verilator for the long ones (ZEXDOC on the bare core and on the whole system).

```
make            # every test written so far, but not zexdoc, zexall and zexsys
make smoke      # tool-chain smoke test: sjasmplus assembles a tiny ROM, Icarus checks its words
make vsmoke     # the same test built with Verilator
make hello      # the system: the boot ROM's self-test passes and it prints "hello" over USB serial, twice
make hello2mb   # the same on a build for a 2 MB board (CHIPMB = 2)
make systest    # the system test ROM: system registers, I/O decode, SRAM bytes, writable boot ROM, the self-test, MMU reset, soft reset
make intc       # the interrupt controller on its own: registers, every source's vector and priority, frozen choice, spurious, NMI
make inttest    # the interrupt test ROM: IM 2 and IM 1, INTENA, INTPEND/INTRAW, SOFTINT, VBLANK (about 2 minutes)
make bootvbl    # the boot ROM's VBLANK colour cycle, a colour a frame (about 4 minutes; not in make all)
make speeds     # the speed test ROM: "hello" at every CPUSPEED setting, T-state rates measured
make failshow   # the boot ROM's failure screen: check 45 shown as 5 white stripes (about 4 minutes; not in make all)
make -j3 vtest  # the video test: L0 bitmaps checked pixel by pixel against a Python model (minutes; not in make all)
make lint       # Verilator lint of the RTL (fpga/lint.sh)
make zexhello   # the ZEX testbench's own checks (seconds): a CP/M program that must pass,
                # one that must fail, and the R register test
make zexdoc     # ZEXDOC on the bare tv80 core in Verilator (long, see below)
make zexall     # ZEXALL, the same with the undocumented flags (long)
make zexsyshello  # the whole-system ZEX testbench's own checks (seconds): hello must pass, bad must fail
make zexsys     # ZEXDOC on the whole system at 20 MHz (very long, see below)
```

## The system tests (`make hello`, `make hello2mb`, `make systest`, `make speeds`)

`tb.v` runs the whole computer (`fpga/rtl/retroz80.v`) in Icarus with retro68k's SRAM model (datasheet timing checks on) and FT232H model. `make hello` assembles the boot ROM (`firmware/boot/boot.asm`, with the generated `hw.inc`), packs it with `tools/bin2hex.py` and runs it. The boot ROM first runs its memory and MMU self-test (`firmware/boot/selftest.asm`) and prints `selftest ok, N MB` (N from SYSCFG.CHIPMB) or `selftest FAIL nn`; then it prints "hello". The test passes when the self-test line, with the build's size, and "hello" arrive at the FT232H model, the PC side then sends the RESET control command, and both must arrive a second time. `make hello2mb` does the same on a build for a 2 MB board (`tb.CHIPMB = 2`, passed on to `retroz80`), where pages `0x100`–`0x1FF` mirror `0x000`–`0x0FF`.

The self-test (checks `0x41` up; spec 2, section 14) covers: the MMU's reset state through the ports; byte 0 held, byte 1 committing the read and the write page, byte 1 alone keeping bits 7–0, another register written between the two bytes; a write-page commit splitting a window and a read-page commit joining it again; NONE ignoring writes; NONE and reserved pages reading `0xFF`; boot ROM pages reading the ROM and ignoring writes; the register page (SYSID the same through its port and at offset `0x70`, an MMU page written with one `LD (nn),HL`, a page started by port and committed through memory, `0xFF` at reserved offsets and where no unit exists yet, an opcode fetch trapping to `RST 38h`, a window reading ROM and writing the registers); SYSCFG.CHIPMB and the 2 MB mirror; the SRAM data lines and address lines (A0–A12 within a page, page bits 0–7, and bit 8 on a 4 MB build).

`make systest` runs `systest/systest.asm` in place of the boot ROM; it checks SYSID (0x5A) through its port and through `IN A,(0x00)`, the other system registers, the I/O decode, SRAM byte writes, the writable boot ROM, `IN A,(0x00)` with A = MMU0_0, the video unit's VIDCON, BGCOLOR (changed by its red byte) and VIDSIZE, the palettes (the default palette; PALDAT's blue and green waiting for red, the index stepping into the next palette; the register page's entries, read back through PALDAT; a PALIDX write starting PALDAT at blue again), L0's registers, PRIO and DMACON (reset values, each byte written alone, reserved bits reading 0, BPL0PT's capture, DMACON's set and clear), the self-test, a soft reset and the MMU, VIDCON and BGCOLOR back at their reset values after it, and prints `PASS` or `FAIL nn` (the number of the check, in hex).

Both run with the DMA port kept busy (`+dma`), and both check that **the Z80 never waited**: every CPU request is issued in the first of cycles 0 and 2 that comes while it stands, none is turned away, and every byte the core takes from memory is at `di` before the cen edge that ends T2 and equals the memory's byte at that address. The testbench works out the address itself: it keeps its own model of the MMU from the Z80's writes to registers `0x80`–`0x9F`, through ports and through the register page (byte 0 held, byte 1 commits, a read-page commit sets the write page), with the 2 MB mirror on a 2 MB build. Reads of NONE and reserved pages and opcode fetches from the register page must give `0xFF`; register page reads are not checked there (the test ROMs check them). Every line received is echoed. The summary at the end gives the counts. `make systest` takes about 5 seconds, `make hello` and `make hello2mb` about 10.

**Interrupts** (ticket #16). Every run of `tb.v` checks each interrupt acknowledge (spec 1, section 8.1, B11): exactly one vector request from the bus interface, in the acknowledge's first T1 (tv80 repeats T1 for the wait states); the byte the core takes at the end of T2 is the controller's vector and equals VECBASE + 2 × INTID, and was at `di` at least 16 clocks before; then exactly one int_ack. The summary gives the counts. `make intc` tests `fpga/rtl/intc.v` on its own (`intc/tb_intc.v`), including what software cannot make happen: every source number's vector and priority, a lower source arriving during the acknowledge (the choice stays frozen), a spurious acknowledge (NONE, 23), and the NMI request. `make inttest` runs `inttest/inttest.asm` in place of the boot ROM: the registers' reset values, INTENA set/clear, INTRAW and INTPEND with INTENA and MASTER, SOFTINT, IM 2 with VECBASE `0x00`, `0xD0` and `0xF0` (which wraps), requests held off by MASTER or INTENA and taken when allowed, a handler that does not clear its source entered again, IM 1 with INTID, IM 2 at 3.57 MHz and 2.5 MHz, VIDINTEN, and a real VBLANK taken before SOFT. It waits for the first VBLANK, about 18 ms in, so it takes about 2 minutes. `make bootvbl` builds the boot ROM with `-DCYCLE_FRAMES=1` and passes (`+bgcycle`) when, after "hello", BGCOLOR goes from green to yellow and then cyan, each change made in the vertical blank.

`make speeds` runs `speeds/speeds.asm`, which copies itself to SRAM and runs from there. It writes CPUSPEED with each setting in turn (20, 10, 6.67, 5, 4, 3.33, 2.86, 2.5 and 3.57 MHz, then the changes between 3.57 MHz and the locked speeds in both directions), reads it back and prints "hello" at each; then a soft reset must bring back 20 MHz. The testbench (`+speeds`) notes the speed at which each line was sent and passes only if every setting printed one.

All three run with the DMA port kept busy (`+dma`), and all check that **the Z80 never waited**: every CPU request is issued in the first of cycles 0 and 2 that comes while it stands, none is turned away, and every byte the core takes from memory is at `di` before the cen edge that ends T2 and equals the memory's byte at that address (by the reset mapping of spec 2, worked out in the testbench), with at least the margin spec 1 gives for the speed (10n − 9 clocks at 20 MHz ÷ n, 43 at 3.57 MHz). They also **measure every T-state** against CPUSPEED, as the testbench works it out from the writes on the core's pins: 5n clocks ending on slot edge 0 or 5 at DIV = n − 1, 28 clocks with SPECTRUM, a new speed only from the first T1 of an M-cycle, and from 3.57 MHz back to a locked speed T-states of 28–32 clocks until that T1, which is on slot edge 0 or 5. With `+speeds` the T1s at 3.57 MHz must also have fallen on every slot edge 0–9. The summary at the end gives the counts, and for each speed the T-states, clocks, the measured rate in MHz, the smallest read margin and the "hello" lines. `hello` and `systest` take about a second each, `speeds` about 20 seconds.

**Video.** The testbench runs the 27 MHz pixel clock (and the 135 MHz clock whose edges it shares) free against the system clock and watches the video unit's output: every line 864 pixels and every frame 625 lines while the beam runs, and no picture line changing colour part-way while no layer shows on it (BGCOLOR is taken at the start of each line's picture). With `+hello` the screen must have been blue (the self-test running) and then green (passed), and BGCOLOR must be green at the end.

`make failshow` builds the boot ROM with `-DFAILTEST=0x45`, which skips the self-test and reports check 45 as failed, and runs it for three frames (60 ms of simulated time). It passes when `selftest FAIL 45` arrives and the next two whole frames both show 5 white stripes on red, each 16 lines with 16 lines between them, the first at picture line 17 (`firmware/boot/boot.asm`, `showfail`). It checks the T-state counting of the stripe loop, so run it after changing that loop or the CPU's timing.

## The video test (`make vtest`)

Ticket #13, after retro68k's `vtest`: layer L0 as a chunky bitmap, checked pixel by pixel against a Python model of spec 4 (`vtest/vmodel.py`). One frame holds many tests: it is cut into **bands**, each showing L0 with other settings over random picture data. `vtest/vgen.py VARIANT DIR` makes the bands, a random palette and the picture data (`ram.hex`, loaded into the SRAM with `+ram=`, 30% zero bytes so TRANSP shows). Variant `a` is a fixed list: every depth (1, 2, 4, 8 bits), every scale across and down (1×–8×), windows off the left and right edges and one 17 pixels wide, fine scroll 0–15 with unused SCROLLX bits set, positive, negative and zero stride, pointer wrap within a line (1 KB and 4 KB blocks), TRANSP and PALOFS, a full-width 8-bit band at 1× (1 byte per pixel, the most one layer needs). Variant `b` is random bands with PRIO and BGCOLOR changes between them (PRIO values that leave L0 out too). `vgen.py` writes each band as straight-line code (`vbands.inc`, included by `vtest/vtest.asm`), timed to the T-state from each frame's start (a line is 640 T-states at 20 MHz): in the lines between two bands it switches L0 off, writes the next band's settings and pointer, and switches L0 on, keeping each write away from beam pixel 0 (where line settings are copied) and beam pixel 144 (PRIO and BGCOLOR). Before the beam starts, the ROM writes the palettes through PALIDX and PALDAT and through the register page, stepping from PALETTE0's last entries into PALETTE1, and SPRPALETTE's first entries, so a pixel from the wrong palette shows.

`tb.v +frame=G` logs every write to the video unit with the beam position (`vlog.txt`), grabs beam frame G (`frame.ppm`; frame 0 is the one the beam starts in) and writes VIDSTAT at the end (`vend.txt`). The model replays the log as spec 4 says (each byte written directly; colours through the colour assembly buffer; line settings from the next line, PRIO and BGCOLOR from the line's picture; the live pointer from the next line, with stride, vertical copies and wrap), renders frame G, and fails on any pixel that differs, on a write too close to a copy point (a fault of the test), on a pointer written while L0 fetches, and on OVERRUN. Every run also makes the usual checks, among them that **the Z80 never waited**, with the display fetching and the DMA port busy (`+dma`): the band code's delay loop reads and writes an SRAM byte on every turn, so the Z80 uses the memory all through the frame.

`vtest_boot` runs the boot ROM on a 2 MB build, as on the KS2, grabs beam frame 2, the first with its palette chart, and checks it against the model with the SRAM as the boot ROM left it (`+dumpram=`).

Each variant takes about 5 minutes; `make -j3 vtest` runs them side by side. The results are in `build/vtest_*/` (`sim.log`, and `model.png` if Python has PIL).

Options: `+rom=FILE`, `+hello`, `+bgcycle`, `+speeds`, `+failshow=NN`, `+vidlog` (print each frame's colour bands), `+dma`, `+trace=N` (print the first N memory and I/O accesses), `+timeout=US`, `+ram=FILE`, `+frame=G`, `+dumpram=FILE`.

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

## ZEXDOC on the whole system (`make zexsys`)

`zex/tb_zexsys.v` runs ZEXDOC on the real machine (ticket #7): `fpga/rtl/retroz80.v`, with tv80 behind the bus interface, the MMU, the scheduler and the SRAM controller, at 20 MHz, in Verilator with a C++ clock (`zex/zexsys_main.cpp`). In place of `tb.v`'s timed SRAM and pad models it has a cycle model of them: the pins show in each clock what the controller set at the edge before, the SRAM takes the write data where /WE rises (low in a clock's first half, high in its second), and a read gives the word at the address on the pins. The SRAM's datasheet timing is checked by `tb.v`'s runs in Icarus; it does not depend on what the Z80 runs. The FT232H is left idle, and so is the video unit (its pixel clock held): it fetches nothing from SRAM yet.

The boot ROM is a loader, `zex/zexboot.asm`. It maps windows 2–7 to SRAM pages 2–7 and copies a trampoline to `0xFFE0`; the trampoline maps windows 0 and 1 to pages 0 and 1 and jumps to `0x0100`. So the Z80 sees a flat 64 KB of SRAM. Before the run the testbench puts the CP/M image at physical `0x000000` and the program at `0x000100`. The image is `zex/cpm.asm` built with `CONSOLE = 0x01` (`cpmsys.bin`): port `0x00` is the system block here, while `0x01` is a reserved page, which the machine ignores (spec 1, section 6.1). The testbench takes each character from the core's pins. The run ends at the jump to 0: the second opcode fetch from `0x0000` (the first is the reset's, from the boot ROM).

A run passes when every test prints `OK`, none prints `ERROR`, `Tests complete` comes before the jump to 0, and **the Z80 never waited**, checked as `tb.v` checks it:

- every CPU request is issued in the first CPU cycle (0 or 2) that comes while it stands, and none is turned away;
- the bus interface's late flag never rises;
- every byte the core takes from memory is at `di` at least a clock before the cen edge that ends T2 (10n − 9 at 20 MHz), and equals the memory's byte at that address, by the testbench's own model of the MMU, worked out from the Z80's writes.

It also checks that the CPU never has both CPU cycles of one slot (spec 1, section 13), that every T-state is 5 clocks and ends on slot edge 0 or 5, and, with `+dma` (on in `make zexsys` and `make zexsyshello`), that the DMA port's random reads and writes in `0x380000` up all come back right. The summary gives the counts.

`make zexsyshello` (part of `make`) runs `hello.com`, which must pass, and `bad.com`, which must fail. It takes about a second once built; the Verilator build takes about a minute. `make zexsys` runs ZEXDOC's 67 tests as separate processes, `ZEX_JOBS` at a time, into `build/zexsys.log`, as `make zexdoc` does.

The whole system runs about 0.63 million T-states a second per process with `+dma` (3.2 million clocks), and 0.68 million without: about 6 times slower than the bare core. ZEXDOC's 46,740 million T-states are about 21 CPU-hours. The wall time is set by test 5 (20,000 million T-states), however many CPUs there are: 9 hours 38 minutes with 14 jobs on 16 threads. So `make zexsys` is left out of `make` and CI. See `zex/RESULTS.md` for the run.

```
make zexsys ZEX_JOBS=14
cd build && ./vl_zexsys/vzexsys +cpm=cpmsys.bin +com=../zex/zexdoc.com +tests=1 +only=13 +dma
                                              # one test (here 13, <inc,dec> a: 95 seconds)
cd build && ./vl_zexsys/vzexsys +cpm=cpmsys.bin +com=hello.com +tests=2 +trace=100
                                              # the first 100 memory and I/O accesses
```

Options: `+cpm=FILE`, `+com=FILE`, `+tests=N`, `+only=K`, `+dma`, `+maxcycles=N` (clocks), `+trace=N`.
