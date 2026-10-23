# Simulation

Tests of the computer in simulation: Icarus Verilog for most tests, Verilator for the long ones (ZEXDOC).

```
make            # every test written so far
make smoke      # tool-chain smoke test: sjasmplus assembles a tiny ROM, Icarus checks its words
make vsmoke     # the same test built with Verilator
make hello      # the system: the boot ROM's self-test passes and it prints "hello" over USB serial, twice
make hello2mb   # the same on a build for a 2 MB board (CHIPMB = 2)
make systest    # the system test ROM: system registers, I/O decode, SRAM bytes, writable boot ROM, the self-test, MMU reset, soft reset
make lint       # Verilator lint of the RTL (fpga/lint.sh)
```

## The system test (`make hello`, `make hello2mb`, `make systest`)

`tb.v` runs the whole computer (`fpga/rtl/retroz80.v`) in Icarus with retro68k's SRAM model (datasheet timing checks on) and FT232H model. `make hello` assembles the boot ROM (`firmware/boot/boot.asm`, with the generated `hw.inc`), packs it with `tools/bin2hex.py` and runs it. The boot ROM first runs its memory and MMU self-test (`firmware/boot/selftest.asm`) and prints `selftest ok, N MB` (N from SYSCFG.CHIPMB) or `selftest FAIL nn`; then it prints "hello". The test passes when the self-test line, with the build's size, and "hello" arrive at the FT232H model, the PC side then sends the RESET control command, and both must arrive a second time. `make hello2mb` does the same on a build for a 2 MB board (`tb.CHIPMB = 2`, passed on to `retroz80`), where pages `0x100`–`0x1FF` mirror `0x000`–`0x0FF`.

The self-test (checks `0x41` up; spec 2, section 14) covers: the MMU's reset state through the ports; byte 0 held, byte 1 committing the read and the write page, byte 1 alone keeping bits 7–0, another register written between the two bytes; a write-page commit splitting a window and a read-page commit joining it again; NONE ignoring writes; NONE and reserved pages reading `0xFF`; boot ROM pages reading the ROM and ignoring writes; the register page (SYSID the same through its port and at offset `0x70`, an MMU page written with one `LD (nn),HL`, a page started by port and committed through memory, `0xFF` at reserved offsets and where no unit exists yet, an opcode fetch trapping to `RST 38h`, a window reading ROM and writing the registers); SYSCFG.CHIPMB and the 2 MB mirror; the SRAM data lines and address lines (A0–A12 within a page, page bits 0–7, and bit 8 on a 4 MB build).

`make systest` runs `systest/systest.asm` in place of the boot ROM; it checks SYSID (0x5A) through its port and through `IN A,(0x00)`, the other system registers, the I/O decode, SRAM byte writes, the writable boot ROM, `IN A,(0x00)` with A = MMU0_0, the self-test, a soft reset and the MMU back at its reset mapping after it, and prints `PASS` or `FAIL nn` (the number of the check, in hex).

Both run with the DMA port kept busy (`+dma`), and both check that **the Z80 never waited**: every CPU request is issued in the first of cycles 0 and 2 that comes while it stands, none is turned away, and every byte the core takes from memory is at `di` before the cen edge that ends T2 and equals the memory's byte at that address. The testbench works out the address itself: it keeps its own model of the MMU from the Z80's writes to registers `0x80`–`0x9F`, through ports and through the register page (byte 0 held, byte 1 commits, a read-page commit sets the write page), with the 2 MB mirror on a 2 MB build. Reads of NONE and reserved pages and opcode fetches from the register page must give `0xFF`; register page reads are not checked there (the test ROMs check them). Every line received is echoed. The summary at the end gives the counts. `make systest` takes about 5 seconds, `make hello` and `make hello2mb` about 10.

Options: `+rom=FILE`, `+hello`, `+dma`, `+trace=N` (print the first N memory and I/O accesses), `+timeout=US`.

Needs `iverilog` (12 or 13), `verilator` (5), `sjasmplus` (1.24) and `python3`. Paths can be given with `make SJASMPLUS=... IVERILOG=... VERILATOR=...`. On Windows, run it from an MSYS2 shell (see the main README).

Each test ends by printing `TEST PASSED` or `TEST FAILED`; `make` fails if it is not `TEST PASSED`. Build products go in `build/`.
