# Tools

| Tool | What it does |
|------|--------------|
| `bin2hex.py` | Turns a binary (the boot ROM, a test image) into a `$readmemh` file of 16-bit little-endian words, as the SRAM and boot ROM hold them (spec 2). Adapted from retro68k's, which writes big-endian words |
| `mkfont.py` | Makes the boot console's font (`firmware/boot/font.inc`, spec 7, section 5.1) from the public-domain `font8x8` in `firmware/third_party/font8x8`: 256 characters in code page 437 order, the leftmost pixel in bit 7, with the 40 characters `font8x8` lacks drawn in the tool itself (`firmware/third_party/README.md`). `--show` prints the font as text, `--missing` lists what `font8x8` lacks |
| `regmap.py` | Reads `fpga/regmap.def` (every register, field and named number), checks it, checks it against `docs/spec/registers.md`, and writes `firmware/include/hw.inc` (sjasmplus), `firmware/include/hw.h` (C) and `fpga/rtl/regmap.vh` (Verilog). Adapted from retro68k's |

Only the Python standard library is needed (Python 3.8 or newer).

## Register map

To add or change a register:

1. Edit `fpga/regmap.def`. Its header gives the syntax (spec 3, section 8).
2. Update the register's row in `docs/spec/registers.md`, and its bits in its unit's spec.
3. Run `python3 tools/regmap.py`. It stops with a message if the two disagree, if anything overlaps, is wider than 4 bytes or lies outside its block, if a field lies outside its register, if a low-byte-only port is not a register of page `0x00`, if a register a copper list changes per line is beyond a MOVE's reach (`0x0EF`), or if a generated name would be defined twice.
4. Run `make -C tools check` (below).
5. Commit the `.def`, the specs and the generated files together.

`python3 tools/regmap.py --verify` only checks, and fails if a generated file is out of date. It checks:

- every register row of spec 3's tables (sections 4 and 5: offset, name, width, access, and the CAP, F, LOCK and BUSY flags) against the `.def`, both ways;
- the low-byte-only ports (section 4.1), the register page (section 6) and the interrupt sources (section 7);
- every value a spec or the guide quotes as `` `NAME` = `value` `` against the generated names; in spec 3 the name must exist;
- that the generated files are up to date.

`make -C tools check` runs the verify, the self-test `test/test_regmap.py` (the real files pass; about twenty deliberately broken definitions and specs fail), and checks the generated headers: `test/hw_test.asm` includes `hw.inc` and asserts values quoted in the specs (sjasmplus), `test/hw_test.c` does the same for `hw.h` and checks `CPORT` against the `_P` names, and `test/regmap_test.v` checks `regmap.vh`'s decodes (Icarus; linted by Verilator with WIDTH warnings as errors, as `fpga/rtl/README.md` asks). GitHub runs it on every push. On Windows run it from MSYS2, as `make -C sim` (main README), with `CC=gcc`.

### The file

| Line | Means |
|------|-------|
| `block NAME PAGE SIZE "text"` | `SYSTEM` (page `0x00`), `CUSTOM` (pages `0x10`–`0x13`) or `REGS` (the register page, MMU page `0x3F8`). A PAGE below `0x100` is an I/O page, so its registers get ports |
| `reg OFFSET NAME WIDTH ACCESS SPEC [fields]` | A register of WIDTH bytes (1–4) |
| `regs NAME COUNT OFFSET WIDTH ACCESS SPEC [fields]` | NAME0…NAME(COUNT−1), separate registers WIDTH bytes apart (INTENA0–2, KEYMAP0–6, COPR0–7). Their fields are shared: `INTENA_SETCLR_M` |
| `array NAME COUNT OFFSET STRIDE SPEC` … `end` | A repeated group of `reg` lines (`L`, `SPR`, `TMR`, `DMX`). A `reg` named `-` is the element itself, and a lower-case `n` in the name marks the index: `MMU` gives `MMU0`…`MMU7`, `MMUnW` gives `MMU0W`…`MMU7W` |
| `area NAME OFFSET SIZE ACCESS SPEC` | A table in the register page (`SYSTEM`, `KEYROW`, `CUSTOM`, the palettes) |
| `port NAME LOWBYTE REGISTER` | A low-byte-only port; NAME must be the register's name |
| `const NAME VALUE ["text"]` | A named number. `INT_name` constants are the interrupt sources |

ACCESS is `R`, `W`, `RW`, `W1C`, `RW1C` (mixed), `SC` (set/clear) or `S` (strobe), with flags after commas: `CAP`, `SEP`, `COLR`, `MMU`, `PAIR`, `F`, `LOCK`, `BUSY` (spec 3, section 8). Fields are `FIELD=BIT` or `FIELD=HIGH:LOW`, numbered in the whole value; `fields=OTHER` copies another register's.

### Generated names

`hw.inc` and `hw.h` define the same names, as numbers. `regmap.vh` puts `RM_` in front and gives register bus addresses (13 bits: the register page offset).

| In `regmap.def` | `hw.inc`, `hw.h` | `regmap.vh` |
|-----------------|------------------|-------------|
| block `CUSTOM` | `CUSTOM_SIZE` | `` `RM_CUSTOM_BASE `` (`13'h1000`), `` `RM_CUSTOM_SIZE `` |
| `reg 0x70 SYSID` (system page) | `SYSID` = `0x70` (register number = register page offset), `SYSID_P` = `0x7000` (port), `SYSID_N` = 1 (bytes) | `` `RM_SYSID `` = `13'h0070`, `` `RM_SYSID_BYTES `` |
| `reg 0x004 BGCOLOR 3` (custom block) | `BGCOLOR` = `0x004` (custom offset), `BGCOLOR_P` = `0x0410`, `BGCOLOR_N` = 3; bytes `BGCOLOR0`…`BGCOLOR2`, each with `_P` | `` `RM_BGCOLOR `` = `13'h1004`, `` `RM_BGCOLOR0 `` … |
| A name ending in a digit, or in an index and a letter | Bytes `MMU0_0`, `MMU0_1`, `MMU0W_0` | The same |
| field `SDCON.CLKDIV=15:8` | `SDCON_CLKDIV_B` = 8 (first bit), `SDCON_CLKDIV_W` = 8 (width), `SDCON_CLKDIV_M` = `0xFF00` (mask in the whole value) | `` `RM_SDCON_CLKDIV `` = `15:8` |
| `regs INTENA 3 0x01` | `INTENA` (the first), `INTENA_NUM`, `INTENA0`…`INTENA2` with `_P` and `_N`, `INTENA_SETCLR_M` | `` `RM_INTENA0 `` … |
| `array L 3 0x090 0x20` | `L_NUM`, `L_SPAN`, `L0`…`L2` (with `_P`), `L_BPL0PT` (offset in a layer, with `_N` and bytes `L_BPL0PT0`…), `L_BPL0PT_ADDR_M` (fields), `L1_BPL0PT` with `_P`, `_N` and bytes | `` `RM_L_BASE ``, `` `RM_L_SPAN ``, `` `RM_L_NUM ``, `` `RM_L_BPL0PT `` (`8'h14`) |
| `area PALETTE0` in block `REGS` | `REGS_PALETTE0`, `REGS_PALETTE0_SIZE` | `` `RM_REGS_PALETTE0 `` |
| `port SERDATA 0x53 0x53` | `SERDATA_PORT` = `0x53` | `` `RM_SERDATA_PORT ``, and `` `RM_IS_LOWPORT(lo) `` |
| `const INT_TIMER0 11` | `INT_TIMER0` = 11, `INTB_TIMER0` = 4 (bit), `INTR_TIMER0` = 1 (byte: `INTENA0 + INTR_TIMER0`) | `` `RM_INT_TIMER0 `` |
| – | `hw.h` only: `CPORT(off)`, the port of a computed custom offset | Decodes: `` `RM_IS_CAP(a) ``, `` `RM_CAP_N(a) ``, `` `RM_IS_COLR(a) ``, `` `RM_IS_COLR_RED(a) ``, `` `RM_IS_MMU(a) ``, `` `RM_IS_MMU_COMMIT(a) ``, `` `RM_IS_SC(a) `` |

sjasmplus has no function-like defines (spec 3, open point R1), so `hw.inc` has no `CPORT`: write a computed custom port out, `((off & 0xFF) << 8) | 0x10 | (off >> 8)`.

Example (sjasmplus):

```
        include "hw.inc"
        ld   bc,VIDCON_P               ; a custom register's port
        ld   a,VIDCON_EN_M
        out  (c),a                     ; video on
        ld   bc,L0_BPL0PT_P            ; a 3-byte register, low byte first
        out  (c),l
        inc  b
        out  (c),h
        inc  b
        out  (c),e
        ld   a,INTID                   ; a system register
        in   a,(SYSPAGE)
```

Example (C, z88dk):

```c
#include "hw.h"
z80_outp(VIDCON_P, VIDCON_EN_M);
z80_outp(CPORT(L0 + n * L_SPAN + L_CTRL1), 2 << L_CTRL1_PALOFS_B);
```
