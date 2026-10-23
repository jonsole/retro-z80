# Spec 6: Copper

Status: **draft**

The copper is a small coprocessor that follows the beam, as on the Amiga and in retro68k: it runs a list of instructions from SRAM every frame and writes custom registers at chosen beam positions. It changes colours partway down the screen, resets the layer and sprite pointers for each frame, sets a layer's line address on every line (the Spectrum screen layout), opens split screens, and so on, without the CPU.

It is retro68k's copper (its spec 10) narrowed to 8 bits: the same instructions, registers, macros and programming model, with 16-bit instruction words that carry 8 bits of data.

## 1. Summary

| Item | Value |
|------|-------|
| Program | A list of 16-bit instruction words in SRAM, at even addresses; restarted from COP1LC at the start of every frame (draw beam line 0) |
| Instructions | MOVE (one word), WAIT, SKIP, JUMP, STOP, MOVEL; MOVE through X and Y (MOVR); LD, ST, ADD, SUB, AND, OR, CMP; SKIP on a condition (SKIPC); CALL and RET. One or two words each (section 4.1) |
| Registers | X and Y (8 bits), the flags (Z, N, C), 8 storage registers COPR0–7 (8 bits), a return stack 8 deep. The CPU can read and write all but the stack contents |
| Can write | The custom block only: MOVE reaches offsets `0x000`–`0x0EF` (video globals, layers, sprites, copper control), MOVEL every offset `0x000`–`0x3FF`. Not the system block |
| Multi-byte registers | Low byte first; the highest byte commits. The copper has its own latch, separate from the CPU's (section 4.2) |
| Beam position | The draw beam of spec 4 (one line ahead of the display beam); 10-bit line and pixel, pixel exact |
| Memory | Cycle 3 of every slot, after urgent display fetches, before sprites and display top-up; spare cycles in the same order (spec 2, section 4). One 16-bit word per cycle |
| Guaranteed rate | On a line whose display fetch fits in cycle 1: one word every slot (143 ns), 224 per line, so one MOVE about every 4 beam pixels. On busier lines, best effort (section 5.3) |
| Prefetch | Two words, read while the copper waits: the first write after a WAIT lands on the WAIT's pixel, and a second MOVE one pixel later |
| Lateness | COPSTAT.LATE: a WAIT reached after its position. COPSTAT.OVER: list 1 still running when the next frame started (section 5.4) |
| Interrupt | A MOVE to COPINT raises the copper's interrupt (source COPPER, spec 8) |
| Registers | Custom offsets `0x0E0`–`0x0E9` (control) and `0x100`–`0x10F` (state and storage), section 6 |

## 2. Comparison with retro68k

| | retro68k (spec 10) | retro-z80 | Why |
|--|--------------------|-----------|-----|
| Instruction size | 32 bits, every instruction one fetch of two words | 16-bit words. MOVE, MOVR, ALU with a register source, SKIPC, STOP and RET are one word; WAIT, SKIP, JUMP, CALL, MOVEL and ALU with a value are two | Bandwidth: a memory cycle reads 16 bits and the copper gets about one per slot, so a MOVE must be one word |
| MOVE | 16 bits of data to a register half; offset up to `0x7FFE` | 8 bits of data; the register code is 8 bits, so MOVE reaches offsets `0x000`–`0x0EF`. Codes `0xF0`–`0xFF` are the other instructions | 8-bit registers; one-word MOVE |
| MOVEL | Not an instruction (its open point C1). The macro `CMOVEL` writes a 32-bit register as two MOVEs | An instruction: two words, one byte to any custom offset. The macro `CMOVEL` makes it. Wide values are written with `CMOVEW`, `CMOVEA` and `CMOVEN` (section 7) | MOVE cannot name offsets `0x0F0`–`0x3FF` |
| Halves rule | A high half is held until the low half of the same register | The byte rule: lower bytes are held until the highest byte of the same register (section 4.2) | 8-bit registers (spec 3) |
| Beam | The beam as the memory side sees it, 11-bit line and pixel | The draw beam (spec 4), one line ahead of the display beam; 10-bit line and pixel. The end-of-list WAIT is line 1023, not 2047 | Bandwidth: the picture is drawn a line ahead into a line buffer. 10 bits cover 864 × 625 and leave spare bits in the encoding |
| X, Y, R0–R7 | 16 bits; X holds a register offset with bit 1 choosing the half; MOVR steps X by 2 | 8 bits; X holds a register code `0x00`–`0xFF`; MOVR steps X by 1; N is bit 7 | 8-bit data |
| MOVR reach | The whole MOVE reach | Offsets `0x000`–`0x0FF` (an 8-bit code, from X or from the instruction) | One-word MOVR |
| MOVR encoding | One op with A, S, I and X bits | Five one-word codes (section 4.5); the same five forms and macros | Fits one word |
| ALU encoding | fn, d (X, Y or the flags), s (value, X, Y or Rn) | fn, d (X or Y), a 4-bit source; loads and stores of the flags use fn 7. The same macros, `CF` included | Fits one word |
| COPCON.PRI | 0 normal, 1 high, 2 nasty (takes the CPU's cycle 0) | Left out: bits 5–4 reserved | The cycle 3 order is fixed (spec 2), and the CPU's cycles 0 and 2 are never given away |
| Memory cycles | Cycle 4 and free cycles; at PRI 1 at least 20 MB/s, one instruction every 200 ns | Cycle 3 after urgent display fetches; one word every 143 ns on lines whose display fits in cycle 1, best effort on others | Bandwidth: 448 guaranteed display bytes per line, against 1,280 |
| Lateness | Not reported | COPSTAT.LATE and COPSTAT.OVER (section 5.4) | The rate is best effort on busy lines, so lists must be able to see when they ran late |
| Prefetch | One instruction (two words) | Two words: a two-word instruction, or two MOVEs | The same buffer size, used for 16-bit words |
| JUMP, CALL penalty | The prefetched instruction is thrown away | None on a busy line: the target is fetched next (section 5.2) | Fetch-bound lines are the common case here |
| Register bus | A CPU access already on the bus goes first; the copper may wait a clock | The copper goes first; the CPU's strobe moves one clock (spec 1) | The Z80's I/O cycle has room, and the copper's writes then always land on their pixel |
| Addresses | COPxLC, COPPC, JUMP and CALL: bits 22–2, long-word aligned | 22-bit physical SRAM byte addresses, even (bit 0 = 0), 3 bytes | Memory (spec 2, section 7): chipset units address the SRAM without the MMU |
| Strobes | Act on a write that reaches the low half | Act on any write: they are single bytes | 8-bit registers |
| Registers | 32-bit, at `0xE00700` | Bytes at custom offsets `0x0E0`–`0x0E9` and `0x100`–`0x10F`, on 16-bit ports (spec 3) | Register map |
| Frame restart | At beam line 0, with the VBLANK interrupt | When the draw beam reaches (0, 0), with the VBLANK interrupt, which follows the draw beam too (spec 4, section 3.4) | – |

Kept as retro68k: WAIT with P (pixel only) and B (DMA engine idle), SKIP, JUMP, STOP, COP1LC, COP2LC, COPJMP1, COPJMP2, COPINT, COPSTAT (WAITING, STOPPED, ERR, IRQ), COPPC, COPCON (EN, IRQEN, RESUME, STKKEEP), COPX, COPY, COPFLAGS, COPSP, COPR0–7, the conditions, CALL and RET with a stack 8 deep, background lists with RESUME, double-buffered lists, the macro names.

## 3. Beam positions

WAIT and SKIP positions are in **beam coordinates** (spec 4): line 0 is the start of the vertical blank and the picture is lines 49–624; pixel 0 is the start of a line's horizontal blank and the picture is pixels 144–863. The copper uses all 864 × 625 positions, blanking included. Positions only go up through a frame.

The copper follows the **draw beam** of spec 4, not the display beam. The draw beam runs one line ahead of the display beam and writes each pixel's final colour into the line buffer. A WAIT for (L, P) ends when the draw beam reaches the pixel that will be shown at (L, P), so a write made then acts on that pixel when it is shown.

- The copper compares against the draw beam plus a fixed lead of a few clocks, equal to the delay from the end of a WAIT to its register write. So the first write after a WAIT acts from pixel P exactly.
- In real time, (L, P) comes about one line (32 µs) before the display beam shows it. The CPU's beam register (BEAMPOS, spec 4, section 3.3) reports the same draw beam, so a CPU that reads it in a copper interrupt raised at (L, P) sees line L, a little after pixel P.
- The list restarts from COP1LC when the draw beam reaches (0, 0). Its writes for the coming picture land in draw lines 0–48, before the picture's first line is fetched.
- A WAIT for line L, pixel 0 ends at the start of line L's horizontal blank, 144 pixels before its picture.
- A position the beam has already passed in this frame satisfies a WAIT at once and makes a SKIP skip.

**When writes take effect:** exactly as for the CPU's writes (spec 4, section 5.7, and spec 5, section 4.4 for the sprites). In short:

| Registers | Rule for the copper |
|-----------|---------------------|
| Pixel registers (the palette, and the others spec 4 lists) | From the pixel where the write lands. A WAIT for (L, P) and a MOVE change the pixel at (L, P) |
| Registers taken at the start of a line's fetch (CTRL, the window, BPL0PT, BPLSTRIDE, SCROLLX, as spec 4 lists) | To change line L, write during line L − 1. On a 2×-tall layer they act from the next pair: write during the line before the pair. The second line of a pair is replayed from the repeat buffer, so a write made during it changes nothing on the screen until the next pair |
| Sprite registers (SPRxPT, SPRxH, SPRxV, SPRxCTL) | Spec 5, section 4.4: a commit during line L shows nothing on line L + 1 and the new settings from line L + 2, which also gives the point at which a sprite can be reused lower down |

## 4. Instructions

### 4.1 Encoding

Instructions are 16-bit words at even addresses, stored little-endian (the low byte at the even address), so a Z80 assembler's `DW` builds them. The high byte of the first word is the **code**: `0x00`–`0xEF` is a MOVE, `0xF0`–`0xFF` the other instructions. Some instructions take a second word.

```
 Code     Low byte of word 1                 Word 2
 00-EF    data                               -                                  MOVE
 F0       P | B | 0 0 | line 9-8 | pixel 9-8   line 7-0 (15-8) | pixel 7-0 (7-0)   WAIT
 F1       P | 0 | 0 0 | line 9-8 | pixel 9-8   line 7-0 (15-8) | pixel 7-0 (7-0)   SKIP
 F2       0 0 | address 21-16                address 15-0, bit 0 = 0            JUMP
 F3       0                                  -                                  STOP
 F4       value                              -                                  MOVR: (X) = value
 F5       value                              -                                  MOVR: (X) = value, X = X + 1
 F6       register code                      -                                  MOVR: register = X
 F7       register code                      -                                  MOVR: register = Y
 F8       0 0 0 0 0 0 | I | R                -                                  MOVR: (X) = X or Y
 F9       fn (7-5) | d (4) | source (3-0)    value (7-0), bits 15-8 = 0;        ALU
                                             only when source = 10
 FA       0 0 0 0 | cc (3-0)                 -                                  SKIPC
 FB       R | 0 | address 21-16              CALL: address 15-0, bit 0 = 0;     CALL, RET
                                             RET: no second word
 FC       0 0 0 0 0 0 | offset 9-8           offset 7-0 (15-8) | data (7-0)     MOVEL
 FD-FF    reserved
```

| Instruction | Words | Does |
|-------------|-------|------|
| **MOVE** | 1 | Writes the data byte to the custom register at offset = code (`0x000`–`0x0EF`), following the byte rule (section 4.2) |
| **MOVEL** | 2 | The same, to any custom offset `0x000`–`0x3FF`. Word 2 looks like a MOVE word, with offset bits 9–8 in word 1 |
| **WAIT** | 2 | Waits until the beam has reached the position: it ends on the position itself. A position the beam never reaches (pixel 864 or more, line 625 or more) waits until the next frame. With **P** set (pixel only), the line is ignored: it waits until the pixel position on the current line, or on the next line if it has already passed. With **B** set, it also waits until the DMA engine (spec 14) is idle: no job running or waiting to start, including one a MOVEL just before started (spec 14, section 9.3) |
| **SKIP** | 2 | If the beam has reached the position, skips the next instruction. With P set, compares the pixel position only |
| **JUMP** | 2 | Continues at the address |
| **STOP** | 1 | Stops until the next frame (or a COPJMP strobe). A WAIT for line 1023 does the same |
| **MOVR** | 1 | A MOVE through X and Y (section 4.5) |
| **ALU** | 1, or 2 with a value | Loads, stores, arithmetic and compare on X and Y (section 4.6) |
| **SKIPC** | 1 | Skips the next instruction if a condition on the flags holds (section 4.7) |
| **CALL**, **RET** | 2, 1 | Subroutines (section 4.8) |

Bits shown as 0 must be 0. Unused patterns are reserved (section 4.9).

**Why 16-bit words.** The copper gets about one 16-bit memory cycle per slot (section 5). A MOVE needs an 8-bit register code and 8 bits of data, exactly one word, so the most common instruction costs one fetch. With retro68k's 32-bit instructions every MOVE would cost two and the copper's rate would halve. Positions, addresses and values that do not fit go in a second word.

**Loops:** SKIP and JUMP make loops that end at a beam position, as in retro68k. For example, to repeat a block of MOVEs on every line until line 400: `loop: CWAITP 0` … MOVEs … `CSKIP 400,0` / `CJUMP loop`. Loops that end on a count or a value use the registers and SKIPC (sections 4.6, 4.7).

### 4.2 MOVE, MOVEL and the copper latch

A MOVE or MOVEL writes one byte. Registers wider than 8 bits are consecutive bytes, **low byte first**, and the write of the **highest byte commits** the whole value (spec 3). The copper follows this rule with **its own latch**, separate from the CPU's, so that a CPU write between two copper MOVEs never mixes with them:

- A write to a lower byte of a multi-byte register puts the byte in the copper latch, tagged with the register. If the latch holds bytes of another register, they are dropped first. The latch holds up to 3 bytes.
- A write to the highest byte commits the register: its lower bytes come from the latch where it holds them for this register; bytes it does not hold keep the register's current value. The latch is then empty.
- MOVEs to single-byte registers, and every other instruction, leave the latch alone. So other instructions (WAITs, other MOVEs) may come between the bytes of one register, but one register's bytes must be finished before another's are started.
- The frame restart and the COPJMP strobes empty the latch.

The register's widths and highest bytes come from the register map (`fpga/regmap.def`, spec 3). MOVR follows the same rule.

Strobes (COPJMP1, COPJMP2, COPINT and the DMA engine's) act on any write. Read-only registers ignore the copper's writes, as they do the CPU's.

**A byte at an exact pixel.** Because lower bytes are held, a list can write a register's lower bytes before a WAIT and its highest byte after it, so that the whole value changes exactly at the WAIT's position (section 5.5).

### 4.3 WAIT and SKIP

Line and pixel are 10 bits each (0–1023). The macros take them as numbers: `CWAIT line,pixel`, `CWAITP pixel`, `CWAITB line,pixel`, `CSKIP line,pixel`, `CSKIPP pixel`.

- A pixel-only WAIT always waits for the next time the draw beam comes to that pixel. A block that starts with `CWAITP 0` runs once at the start of each line's horizontal blank. Start a run of pixel-only WAITs with an ordinary WAIT, so that the run begins on the line you mean.
- A pixel-only WAIT relies on the copper finishing its block before the beam comes round again; a block that runs past its own pixel position slips a line.
- `CWAITB 0,0` waits only for the DMA engine (the position has always passed).
- While it waits, the copper fills its two-word prefetch buffer (section 5.5), then uses no memory cycles until the WAIT ends.
- **End of a list:** STOP, or a WAIT for line 1023 (`CWAIT 1023,0`). If a list is still running when the next frame starts, it is abandoned: the copper starts again from COP1LC whatever it was doing.

### 4.4 JUMP and STOP

JUMP continues at a 22-bit even SRAM address, anywhere in the SRAM (spec 2, section 7). STOP stops the copper until the next frame restart or a COPJMP strobe; COPPC then points at the STOP. The address of a list wraps at 22 bits.

### 4.5 MOVR: MOVE through X and Y

MOVR is a MOVE whose register, or data, or both, come from the copper's registers X and Y (section 4.6). X used as a register is an 8-bit **register code**, as in a MOVE, and names custom offset `0x000`–`0x0FF`. Each form is one word.

| Code | Form | Macro | Does |
|------|------|-------|------|
| `0xF4` | A | `CMOVX value` | (X) ← value |
| `0xF5` | A, I | `CMOVXP value` | (X) ← value, then X = X + 1 |
| `0xF6` | S, X | `CMOVR reg,CX` | reg ← X. The low byte is the register code `0x00`–`0xFF` |
| `0xF7` | S | `CMOVR reg,CY` | reg ← Y |
| `0xF8` | A, S | `CMOVXR CY` / `CMOVXR CX` | (X) ← Y (R = 0) or X (R = 1) |
| `0xF8` | A, S, I | `CMOVXRP CY` / `CMOVXRP CX` | The same, then X = X + 1 (I = 1) |

With I, a run of MOVRs walks through consecutive registers: the bytes of a multi-byte register, low to high, and on to the next register. X wraps from `0xFF` to `0x00`. None of them change the flags. A MOVR follows every MOVE rule: the byte rule, the strobes, the register bus. An X of `0xF0`–`0xFF` writes offsets `0x0F0`–`0x0FF`, which a MOVE cannot name (read-only status, and the sprite globals spec 5 puts there).

### 4.6 Registers and the ALU

The copper has these registers, all 8 bits except the flags and the stack. The CPU can read and write them at their custom offsets (section 6), and the copper can too, with MOVEL; normally the copper uses the ALU.

| Register | Name | |
|----------|------|--|
| X, Y | COPX, COPY | Working registers: register codes (MOVR) and data |
| Flags | COPFLAGS | Z (0): the result was 0. N (1): bit 7 of the result. C (2): carry out of an ADD, borrow from a SUB or CMP |
| R0–R7 | COPR0–COPR7 | Storage: to save X, Y and the flags, to keep values between frames, and to pass values to and from the CPU |

The **ALU** instruction (code `0xF9`): `fn` (bits 7–5) is the function, `d` (bit 4) the register it works on (0 X, 1 Y), and `source` (bits 3–0): 0–7 Rn, 8 X, 9 Y, 10 the value in word 2; 11–15 are reserved.

| fn | Name | Does | Flags |
|----|------|------|-------|
| 0 | LD | d = source | Unchanged |
| 1 | ST | Rn = d (source must be Rn) | Unchanged |
| 2 | ADD | d = d + source | Z, N, C (carry) |
| 3 | SUB | d = d − source | Z, N, C (borrow: d < source, unsigned) |
| 4 | AND | d = d AND source | Z, N; C cleared |
| 5 | OR | d = d OR source | Z, N; C cleared |
| 6 | CMP | d − source, result not kept | Z, N, C as SUB |
| 7 | Flags | d = 0: flags = bits 2–0 of the source (LD to the flags). d = 1: Rn = the flags (ST of the flags; source must be Rn) | d = 0: loaded |

All arithmetic is 8 bits and wraps. With a register source the instruction is one word; with a value (source 10) it is two. Macros as retro68k: `CLDI`, `CLD`, `CST`, `CADDI`/`CADD`, `CSUBI`/`CSUB`, `CANDI`/`CAND`, `CORI`/`COR`, `CCMPI`/`CCMP`; the `I` forms take a value, the others a register (`CX`, `CY`, `CR0`–`CR7`). The register changed is named first: `CADDI CX,4` is X = X + 4, `CST CR3,CX` is R3 = X. `CF` (the flags) can be used only with `CLD`, `CLDI` and `CST`; the macros make fn 7 for it.

There is no instruction to load a custom register into X or Y, and no load from SRAM: values come from numbers in the list, from the CPU (which can write COPX, COPY and COPR0–7), or from earlier arithmetic (open point C1).

The frame restart and the COPJMP strobes never change X, Y, the flags or R0–R7.

### 4.7 SKIPC: SKIP on a condition

Skips the next instruction if the condition `cc` (bits 3–0) holds, as the 68000's conditions:

| cc | Macro | Skips if | After `CMP d,source` |
|----|-------|----------|----------------------|
| 0 | `CSKIPEQ` | Z | d = source |
| 1 | `CSKIPNE` | not Z | d ≠ source |
| 2 | `CSKIPLO` | C | d < source (unsigned) |
| 3 | `CSKIPHS` | not C | d ≥ source |
| 4 | `CSKIPMI` | N | bit 7 of d − source set |
| 5 | `CSKIPPL` | not N | bit 7 clear |
| 6 | `CSKIPHI` | not C and not Z | d > source |
| 7 | `CSKIPLS` | C or Z | d ≤ source |

Codes 8–15 are reserved. A loop of N passes (N = 1–255; 0 gives 256): `CLDI CY,N` / `loop:` … `CSUBI CY,1` / `CSKIPEQ` / `CJUMP loop`.

### 4.8 CALL and RET

**CALL** pushes the address of the next instruction onto the copper's stack and continues at the address. **RET** (R set, one word) pops an address and continues there. The stack is inside the copper (the copper does not write memory), **8 entries** deep; COPSP reads how many are in use. A CALL with the stack full, or a RET with it empty, stops the copper and sets COPSTAT.ERR.

At each frame restart the stack is emptied, unless **COPCON.STKKEEP** is set: then it is kept as it is, and list 1 starts with it. The COPJMP strobes do not change the stack; a CPU write to COPSP empties it.

Macros `CCALL address`, `CRET`.

### 4.9 Reserved encodings

Codes `0xFD`–`0xFF`, a bit shown as 0 that is set, B set in a SKIP, an ALU source of 11–15, an ST whose source is not Rn, and SKIPC codes 8–15 are reserved. The copper treats them as STOP and sets COPSTAT.ERR; COPPC points at the instruction. So erased memory (`0xFFFF`), and the Amiga's end-of-list `$FFFF,$FFFE`, stop the copper with ERR set.

## 5. Memory and timing

### 5.1 Memory cycles

The list is in SRAM; the copper reads it one 16-bit word per memory cycle (spec 2, section 4):

- **Cycle 3** of every slot, in this order: a display FIFO below its low mark (urgent); **copper**; sprites; display top-up.
- **Spare cycles:** a cycle 0, 1 or 2 its owner leaves unused goes to the first that wants it, in the same order. These are common (the CPU leaves about half its cycles unused, and cycle 1 is free in the vertical blank and on the second line of a 2×-tall layer's pair), but not guaranteed.
- At 28 MHz the CPU sometimes takes cycle 3 for a read and gives back its next cycle (the swap, spec 2, section 4.2). The copper keeps one cycle per slot, but that access comes one cycle (35.7 ns) later.
- The DMA engine (spec 14) has spare cycles only, after the copper.

While it waits with its prefetch buffer full, the copper takes no cycles. A copper that never waits takes every cycle 3 the urgent display fetches leave, so the sprites get only spare cycles on those lines; spec 5's fetch budget must allow for the copper's use of cycle 3 on each line.

### 5.2 Cost of each instruction

Every word of every instruction the copper passes is fetched once:

| Instruction | Words (fetches) |
|-------------|-----------------|
| MOVE, MOVR (all forms), ALU with a register source, SKIPC, STOP, RET | 1 |
| WAIT, SKIP, JUMP, CALL, MOVEL, ALU with a value | 2 |
| An instruction skipped by SKIP or SKIPC | Its words, as if run |

JUMP, CALL and RET carry no extra cost on a busy line: the copper runs them as soon as their last word arrives, before it asks for the next cycle, and then fetches the target. On a quiet line (spare cycles) it may already have read up to two words past them, which are thrown away. A loop costs a fetch for every word in it, every pass: unrolled MOVEs are faster, loops are shorter.

Running an instruction takes 1–2 system clocks (a register write: one clock on the register bus and one spare clock, so that a write to the copper's own registers has acted before the next instruction). This is small against the fetch time, so the copper's speed is its fetch rate.

### 5.3 Guaranteed rate

Cycle 3 comes every 143 ns. A display fetch that fits in cycle 1 (spec 4: up to 448 bytes on the line) leaves its FIFOs above their low mark, so on such a line the display takes no cycle 3 and the copper has all of them:

| On a line whose display fetch fits in cycle 1 | Words | MOVEs |
|-----------------------------------------------|-------|-------|
| One slot (143 ns, about 3.9 beam pixels) | 1 | 1 |
| One 8-pixel cell at 2× (16 beam pixels, 593 ns) | 4 (3 if a swap moves one out; made up in the next cell) | 4 |
| The horizontal blank (144 pixels, 5.3 µs) | 37 | 37 |
| One line (32 µs) | 224 | 224 |
| The vertical blank (49 lines, 1.57 ms; no display fetch) | 10,976 | 10,976 |

These figures hold whatever the CPU and the sprites do. Spare cycles make the copper faster; plan with these figures.

**Busy lines.** On a line where the display needs more than cycle 1, urgent fetches take some cycle 3s first, and the copper gets the rest: 224 − U words per line, where U is the urgent fetches (about (display bytes − 448) ÷ 2). For example, spec 4's 638-byte line leaves the copper about 129 words; a line at the 896-byte limit leaves it none until the line's fetch is done. The copper's rate there is best effort: it is never wrong, only late. Plan time-critical effects on lines whose display fits in cycle 1 (for 2×-tall layers, the second line of each pair is always free), or start them earlier.

### 5.4 Busy lines: LATE and OVER

The display is never late because of the copper (urgent fetches go first), so VIDSTAT.OVERRUN (spec 4) is never the copper's doing. The copper reports its own lateness in COPSTAT (sticky, write 1 to clear):

| Bit | Set when |
|-----|----------|
| **LATE** | The copper reached a WAIT (not pixel-only) whose position the beam had already passed. WAITs for line 0 do not set it, so `CWAITB 0,0` and a list's first `CWAIT 0,…` are not reported |
| **OVER** | The frame restart came while list 1 was still running: neither stopped nor waiting. A list waiting for an unreachable position (line 1023) is waiting, not over. A background list in list 2 (section 6.5) does not set it |

LATE means a write after that WAIT landed later than its position: the work before it took longer than the time to the WAIT, usually because the display took cycle 3 on a busy line. A pixel-only WAIT that the copper reaches late waits for the next line instead (it slips a line); LATE cannot tell this from an intended wait. After a COPJMP1 from the CPU part-way through a frame, the WAITs the beam has passed set LATE: clear it afterwards.

LATE and OVER raise no interrupt. A program checks them in its VBLANK handler, or the list itself writes COPINT where it matters.

### 5.5 After a WAIT: prefetch

The copper has a prefetch buffer of **two words**. While it waits, it reads the next two words, so the instruction after the WAIT, and with a one-word instruction the one after that, are already there when the WAIT ends:

- The first MOVE after a WAIT acts from the WAIT's pixel exactly (the lead of section 3).
- A second prefetched MOVE lands one beam pixel later (2 system clocks).
- Each write after those needs its own fetch: one slot apart (about 4 pixels) at the guaranteed rate, or one cycle more after a swap.
- To change a 2-byte value exactly at a pixel, write its low byte before the WAIT (it is held in the copper latch) and its high byte after it. A 3-byte value: its two lower bytes before the WAIT.

A SKIP that skips throws away the prefetched words of the instruction it skips; JUMP, CALL and RET throw away anything prefetched past them (section 5.2).

### 5.6 Register bus

The copper's writes go over the register bus that the CPU's I/O cycles and register page accesses use (spec 1, section 4.2). If both want it in the same clock, **the copper goes first** and the CPU's strobe moves one clock later, which its I/O cycle has room for (spec 1, section 6). So a copper write is never delayed and lands on its pixel.

Both can write the same register. The last write wins, and their bytes never mix, because each has its own latch. Let one of them own each register: if the copper resets the layer pointers, the CPU changes the list, not the pointers.

## 6. Registers

Custom offsets. The CPU reaches them on 16-bit ports, port = (offset bits 7–0) << 8 | (`0xC0` + offset bits 9–8) (spec 3), and in the register page at `0x1000` + offset. Multi-byte values: low byte at the lowest offset, committed on the highest.

| Offset | Port | Name | Access | Bits | Description | Reset |
|--------|------|------|--------|------|-------------|-------|
| `0x0E0` | `0xE0C0` | COPCON | RW | EN (0), IRQEN (1), RESUME (2), STKKEEP (3); 7–4 reserved | Copper on (DMACON.COPEN and DMACON.DMAEN must also be set); COPINT raises the interrupt; the frame restart saves list 2's place in COP2LC (section 6.5); the frame restart keeps the stack (section 4.8) | 0 |
| `0x0E1`–`0x0E3` | `0xE1C0`–`0xE3C0` | COP1LC | RW | 21–0, bit 0 ignored | List 1: restarted at every frame restart | 0 |
| `0x0E4`–`0x0E6` | `0xE4C0`–`0xE6C0` | COP2LC | RW | 21–0, bit 0 ignored | List 2: runs when COPJMP2 is written. Changed by the hardware only with COPCON.RESUME set | 0 |
| `0x0E7` | `0xE7C0` | COPJMP1 | W | – | Strobe: restart at COP1LC now | – |
| `0x0E8` | `0xE8C0` | COPJMP2 | W | – | Strobe: continue at COP2LC now | – |
| `0x0E9` | `0xE9C0` | COPINT | W | – | Strobe: sets COPSTAT.IRQ. Meant to be written by the copper itself | – |
| `0x0EA`–`0x0EF` | | – | | | Reserved: read `0xFF`, writes ignored (spec 3, rule 11) | |
| `0x100`–`0x102` | `0x00C1`–`0x02C1` | COPPC | R | 21–0 | The instruction being run; when stopped, the STOP (or reserved instruction) that stopped it. Reading `0x100` captures all three bytes | 0 |
| `0x103` | `0x03C1` | COPSTAT | R, W1C | WAITING (0), STOPPED (1), ERR (2), IRQ (3), LATE (4), OVER (5); 7–6 reserved | Bits 0–1 live, read only. Bits 2–5 sticky, write 1 to clear (sections 4.9, 5.4, 6.4) | `0x02` |
| `0x104` | `0x04C1` | COPX | RW | 7–0 | X (section 4.6) | 0 |
| `0x105` | `0x05C1` | COPY | RW | 7–0 | Y | 0 |
| `0x106` | `0x06C1` | COPFLAGS | RW | Z (0), N (1), C (2) | The flags | 0 |
| `0x107` | `0x07C1` | COPSP | RW | 3–0 | Read: entries in use on the stack (0–8). Write (any value): empty the stack | 0 |
| `0x108`–`0x10F` | `0x08C1`–`0x0FC1` | COPR0–COPR7 | RW | 7–0 | Storage registers R0–R7 | 0 |
| `0x110`–`0x11F` | | – | | | Reserved: read `0xFF`, writes ignored (spec 3, rule 11) | |

The control registers (`0x0E0`–`0x0E9`) are in a MOVE's reach; the state and storage registers (`0x100`–`0x10F`) are reached by the CPU, and by the copper's ALU and MOVEL.

### 6.1 Status bits

| Bit | Set when |
|-----|----------|
| WAITING | The copper is in a WAIT |
| STOPPED | After STOP, a reserved instruction, a stack error, while off (EN, COPEN or DMAEN clear), and after reset |
| ERR | A reserved instruction (section 4.9), or a CALL with the stack full or a RET with it empty |
| IRQ | A write to COPINT |
| LATE | A WAIT was reached after its position (section 5.4) |
| OVER | The frame restart cut off list 1 (section 5.4) |

### 6.2 CPU access

The CPU can read and write COPX, COPY, COPFLAGS and COPR0–7 at any time; a write lands between two copper instructions. Each is one byte, so the copper sees either the old value or the new one. A value the copper takes from several storage registers can still be torn by a CPU write between the copper's reads: write such values while the copper is stopped or waiting (for example from a copper interrupt raised just before a STOP), or use storage registers that only one side writes.

### 6.3 Starting, stopping and the frame restart

- **Starting:** after reset COPCON, COP1LC, COP2LC, X, Y, the flags, R0–R7 and the stack are 0, and the copper is stopped. With COPCON.EN, DMACON.COPEN and DMACON.DMAEN (spec 4) all set, the copper starts from COP1LC at the next frame restart; a write to COPJMP1 starts it at once.
- **Stopping:** clearing any of the three stops it at once. Setting them again starts it at the next frame restart (or COPJMP1). The copper can write COPCON itself: write EN as 1 every time.
- **Frame restart**, when the draw beam reaches (0, 0) with the copper on: OVER is set if list 1 was still running; with RESUME, list 2's place is saved (section 6.5); the PC is loaded from COP1LC; the prefetched words and the copper latch are dropped; the stack is emptied unless STKKEEP is set. X, Y, the flags and R0–R7 are kept.
- **Restarting** with COPJMP1 or COPJMP2 also drops the prefetched words and the copper latch. A strobe from the CPU wakes a copper that is waiting or stopped.
- **Double-buffered lists:** build next frame's list in a second buffer, then write its address to COP1LC (three bytes; the highest commits). The copper picks it up at the next frame restart, so a half-built list is never run.

### 6.4 Interrupt

Source **COPPER** (2) in the interrupt controller (spec 8) is COPSTAT.IRQ with COPCON.IRQEN; its IM 2 vector is VECBASE + 4. A list raises it with `CMOVE COPINT,0`. The handler clears it by writing 1 to COPSTAT.IRQ. A second COPINT before that changes nothing.

### 6.5 Background lists: COPCON.RESUME

As in retro68k, the copper can run a long **background** list, such as a queue of DMA engine jobs (spec 14), that carries on across frames while list 1 still restarts at every frame. With COPCON.RESUME set:

- The copper keeps an **in list 2** flag. A COPJMP2 strobe sets it. A COPJMP1 strobe, a STOP (or a WAIT for line 1023, or a reserved instruction), and the frame restart clear it. JUMP, CALL, RET and the SKIPs leave it as it is.
- At the frame restart, if the flag is set, the hardware writes the **resume address** to COP2LC before it reloads from COP1LC. The resume address is the instruction not yet finished: a WAIT still waiting (it runs again, whole), or the next instruction to run. If the copper latch holds lower bytes, the resume address is that of the MOVE that wrote the first of them, so the register is written again whole.
- List 1 ends with `CMOVE COPJMP2,0`, and list 2 carries on where it was cut off.

Without RESUME (the default), COP2LC is never changed by the hardware.

**Only the place is saved.** X, Y, the flags and R0–R7 are never changed by the frame restart. A list 1 that uses X, Y or the ALU saves what it uses into spare storage registers first (`CST CR5,CX`, `CST CR7,CF`) and puts it back (`CLD`) before its COPJMP2. With STKKEEP, list 1's CALLs must all have returned before its COPJMP2.

Rules for a background list, as retro68k's:

- Its WAITs should be pixel-only, DMA-only (`CWAITB 0,0`) or none: after a resume, a beam WAIT would wait for its position in the new frame.
- Some MOVEs may run twice: if the cut-off comes between the bytes of a multi-byte register, they run again. Never put a strobe (such as a DMA engine start) between the bytes of a register.
- When it is done, it sets COP2LC to an idle list (`CMOVEA COP2LC,idle` then `CSTOP`, where `idle` is a STOP).
- While RESUME is set and a background list is running, the CPU's writes to COP2LC may be replaced at the next frame restart. The CPU writes COP2LC only while the copper runs the idle list (COPPC tells it where the copper is).

### 6.6 What the copper can reach

| Area | The copper can |
|------|----------------|
| SRAM | Read its list (22-bit physical addresses, not through the MMU). Nothing else: it cannot write SRAM or read tables from it |
| Custom block `0x000`–`0x0EF` | Write with MOVE, MOVR or MOVEL: video globals, palette ports, both layers, the sprites, its own control registers |
| Custom block `0x0F0`–`0x0FF` | Write with MOVR or MOVEL (read-only status ignores the writes) |
| Custom block `0x100`–`0x3FF` | Write with MOVEL only: its own state and storage registers, the attribute layer, the DMA engine, audio (reserved) |
| System block (8-bit ports), port `0xFE`, the register page, the boot ROM | Nothing |

So the copper cannot reach the interrupt controller, the timers, the MMU or the system registers: a runaway list can never page memory, reset the machine or change the interrupt set-up. It can turn the copper off (COPCON, DMACON), and a list that writes COPJMP1 unconditionally loops for ever.

## 7. Macros: `copper.inc`

`firmware/include/copper.inc` gives retro68k's macros for sjasmplus, with the register names (custom offsets) from `hw.inc`. Lists are word-aligned (`ALIGN 2`).

| Macro | Instruction | Words |
|-------|-------------|-------|
| `CMOVE reg,value` | MOVE; reg must be below `0x0F0` | 1 |
| `CMOVEL reg,value` | MOVEL: one byte to any custom offset | 2 |
| `CMOVEW reg,value` | A 2-byte register, low byte first: MOVE or MOVEL for each byte | 2–4 |
| `CMOVEA reg,address` | A 3-byte register (a 22-bit address), low byte first | 3–6 |
| `CMOVEN reg,value,n` | An n-byte register (n = 1–4), low byte first | n–2n |
| `CWAIT line,pixel` | WAIT | 2 |
| `CWAITP pixel` | WAIT, pixel only | 2 |
| `CWAITB line,pixel` | WAIT, and the DMA engine idle | 2 |
| `CSKIP line,pixel`, `CSKIPP pixel` | SKIP, SKIP pixel only | 2 |
| `CJUMP address`, `CSTOP` | JUMP, STOP | 2, 1 |
| `CMOVX value`, `CMOVXP value` | MOVR: (X) = value; then X + 1 | 1 |
| `CMOVR reg,CX`, `CMOVR reg,CY` | MOVR: reg = X or Y | 1 |
| `CMOVXR src`, `CMOVXRP src` | MOVR: (X) = src (`CX` or `CY`); then X + 1 | 1 |
| `CLDI d,value`, `CLD d,src` | LD (d = `CX`, `CY` or `CF`) | 2, 1 |
| `CST CRn,d` | ST (d = `CX`, `CY` or `CF`) | 1 |
| `CADDI`/`CADD`, `CSUBI`/`CSUB`, `CANDI`/`CAND`, `CORI`/`COR`, `CCMPI`/`CCMP` | ALU on `CX` or `CY`; the `I` forms take a value | 2, 1 |
| `CSKIPEQ` … `CSKIPLS` | SKIPC | 1 |
| `CCALL address`, `CRET` | CALL, RET | 2, 1 |

Operands `CX`, `CY`, `CF`, `CR0`–`CR7` are equates in `copper.inc`. `CMOVEL` is the long-reach MOVE here; retro68k's `CMOVEL` (a whole 32-bit register) becomes `CMOVEW`, `CMOVEA` or `CMOVEN` by the register's width.

## 8. Examples

Register names are the custom offsets of `hw.inc` (spec 3, section 8): `L0+L_BPL0PT` is layer 0's pointer (3 bytes), `L0+L_SCROLLX` its scroll, `BGCOLOR` the background colour (2 bytes, `0x0RGB`: low byte green and blue, high byte red), `SPR0+SPR_PT` sprite 0's pointer. Their widths and timing are spec 4's and spec 5's. Costs are in words (fetches), at the guaranteed rate of section 5.3.

### 8.1 Spectrum screen layout

Layer 0 shows the Spectrum's 6 KB screen as a 256 × 192 1-bit bitmap at 2× across and down, window 248–760 × 145–529, with colours from the attribute layer (spec 4, Spectrum extras). Picture line k is the pair of beam lines 145 + 2k and 146 + 2k, and its address is `SCREEN + ((k & 0xC0) << 5) + ((k & 7) << 8) + ((k & 0x38) << 2)`. BPL0PT is taken at the start of each pair's fetch, so the copper writes it during line 144 + 2k: the line before the pair, which for k ≥ 1 is the replayed second line of the pair before, so no fetch is disturbed.

**Unrolled:** a WAIT and three MOVEs per line, built by the assembler (or by the CPU once):

```
            ALIGN   2
spec_list:
k = 0
            DUP     192
            CWAIT   144+2*k,0                   ; the line before pair k
            CMOVEA  L0+L_BPL0PT,SCREEN+((k&$C0)<<5)+((k&7)<<8)+((k&$38)<<2)
k = k + 1
            EDUP
            CSTOP
```

Cost: 5 words per line pair, 960 per frame (0.7% of the frame's cycle 3); the list is 961 words (1,922 bytes).

**As a loop:** the ALU steps the address down one line, as the Spectrum ROM's own routine does: Y holds address bits 15–8, X bits 7–0. SCREEN is 8 KB-aligned (one MMU page), so bits 12–0 of the address are the offset alone.

```
            ALIGN   2
spec_loop:  CLDI    CX,0                        ; line 0: address bits 7-0
            CLDI    CY,(SCREEN>>8)&$FF          ; address bits 15-8
            CWAIT   144,0                       ; the line before pair 0
.pair:      CMOVR   L0+L_BPL0PT,CX              ; bits 7-0 (held)
            CMOVR   L0+L_BPL0PT+1,CY            ; bits 15-8 (held)
            CMOVE   L0+L_BPL0PT+2,SCREEN>>16    ; bits 21-16: BPL0PT written whole
            CSKIP   526,0                       ; pair 191 written?
            CJUMP   .down
            CSTOP
.down:      CADDI   CY,1                        ; next pixel row (bits 10-8)
            CST     CR0,CY
            CANDI   CY,7                        ; still in the character cell?
            CLD     CY,CR0                      ; Y back; the flags are kept
            CSKIPEQ
            CJUMP   .next                       ; yes: done
            CADDI   CX,32                       ; next character row (bits 7-5)
            CSKIPHS
            CJUMP   .next                       ; carry: next third, done
            CSUBI   CY,8                        ; same third: undo the carry into bits 12-11
.next:      CWAITP  0                           ; the pair's first line
            CWAITP  0                           ; its second: the line before the next pair
            CJUMP   .pair
```

Cost: 22 words per pair, 29 at most (every eighth pair); about 4,500 per frame (3.2% of cycle 3), fewer than 30 on any one line. The list is 36 words (72 bytes) instead of 961. The BPL0PT writes come about 3 slots after pixel 0 of line 144 + 2k, well before the pair's fetch.

A program that keeps its screen in linear order needs no copper: BPL0PT = screen, BPLSTRIDE = 32.

### 8.2 Colour gradient

The background goes from black through blue to cyan down the screen: 31 bands of 8 beam lines from line 49, colours `0x000`, `0x001` … `0x00F`, `0x01F`, `0x02F` … `0x0FF`.

**Unrolled** (as retro68k's colour bars):

```
            ALIGN   2
grad_list:  CMOVEW  BGCOLOR,$000                ; band 0, set in the vertical blank
b = 1
            DUP     30
            CWAIT   49+8*b,0                    ; the blank before band b
            IF b < 16
            CMOVEW  BGCOLOR,b                   ; blue rises ...
            ELSE
            CMOVEW  BGCOLOR,((b-15)<<4)|$0F     ; ... then green
            ENDIF
b = b + 1
            EDUP
            CSTOP
```

Cost: 4 words per band. Both MOVEs after each WAIT are prefetched: the low byte is held at pixel 0 and the high byte commits the colour at pixel 1 of its line, in the horizontal blank.

**As a loop**, with Y the colour's green and blue and X counting lines:

```
            ALIGN   2
grad_loop:  CLDI    CY,$00                      ; black
            CWAIT   49,0
.band:      CMOVR   BGCOLOR,CY                  ; green, blue (held)
            CMOVE   BGCOLOR+1,$00               ; red 0: commits
            CCMPI   CY,$FF                      ; the last colour?
            CSKIPNE
            CSTOP
            CCMPI   CY,$0F                      ; blue full yet?
            CSKIPLO
            CADDI   CY,$0F                      ; yes: green + 1 (with the + 1 below)
            CADDI   CY,$01                      ; no: blue + 1
            CLDI    CX,8                        ; 8 lines
.wait:      CWAITP  0                           ; the next line
            CSUBI   CX,1
            CSKIPEQ
            CJUMP   .wait
            CJUMP   .band
```

Cost: 7 words per line while it waits, and 17 more per band. The colour write comes about 9 words after the band's last `CWAITP`, about 1.3 µs (35 pixels) into the horizontal blank. The list is 28 words.

### 8.3 Split-screen scroll

Layer 0 scrolls across, with a fixed status panel from beam line 529 (picture line 240 of a 2×-tall layer). The CPU leaves the game's pointer in COPR0–2 and its fine scroll in COPR3; the copper puts them in place in the vertical blank, so the scroll changes once per frame, in step with the picture. At the panel the copper writes the panel's pointer and scroll during line 528, the replayed line before the panel's first pair, and tells the CPU, which then writes the next frame's values while the copper is stopped.

```
            ALIGN   2
split:      CLD     CX,CR0                      ; the game's BPL0PT, from the CPU
            CMOVR   L0+L_BPL0PT,CX
            CLD     CX,CR1
            CMOVR   L0+L_BPL0PT+1,CX
            CLD     CX,CR2
            CMOVR   L0+L_BPL0PT+2,CX            ; commits
            CLD     CX,CR3                      ; the game's fine scroll
            CMOVR   L0+L_SCROLLX,CX
            CWAIT   528,0                       ; the line before the panel
            CMOVEA  L0+L_BPL0PT,panel           ; the panel's picture
            CMOVE   L0+L_SCROLLX,0              ; no scroll
            CMOVE   COPINT,0                    ; tell the CPU
            CSTOP
```

Cost: 8 words in the vertical blank; 7 at the panel, all within line 528's horizontal blank (37 words). Parallax bands are the same with a WAIT and a pointer per band.

### 8.4 Sprite reuse down the screen

Sprite 0 shows a ship on beam lines 100 to 131, and a second ship lower down, from line 140. Spec 5's rule (section 4.4): writes committed during draw line L leave line L as it was, show nothing on line L + 1 and the new settings from line L + 2. So once the first use's last line, 131, has started, the copper writes the sprite again during that line, and the second use may start on line 133 or later: one gap line, as retro68k advises. SPRxPT goes last, since the fetch moves it (spec 5, section 4.4). `SPR_H_N` and `SPR_V_N` are the registers' widths in bytes from `hw.inc` (spec 3, section 8), 4 each.

```
            ALIGN   2
ships:      CMOVEN  SPR0+SPR_V,SHIP1_V,SPR_V_N   ; first use: window down ...
            CMOVEN  SPR0+SPR_H,SHIP1_H,SPR_H_N   ; ... and across
            CMOVEA  SPR0+SPR_PT,ship             ; image, last
            CWAIT   131,0                        ; the first use's last line has started
            CMOVEN  SPR0+SPR_V,SHIP2_V,SPR_V_N
            CMOVEN  SPR0+SPR_H,SHIP2_H,SPR_H_N
            CMOVEA  SPR0+SPR_PT,ship
            CSTOP
```

Cost: 2 + 4 + 4 + 3 = 13 words per reuse (WAIT, SPRxV, SPRxH, SPRxPT): about 1.9 µs, 52 pixels, well inside line 131. Eight sprites reused on the same line take 8 × 11 words after the WAIT, 88 cycle 3s that the sprites' fetch for the next line then lacks (spec 5, section 5.2): spread them over the lines between uses.

### 8.5 Per-cell colours

A colour change at every 8-pixel cell needs a WAIT (2 words) and the writes for the cell, within a cell of 4.15 slots at 2×:

| Per cell | Words | At the guaranteed rate (4 per 2× cell, 3 after a swap) |
|----------|-------|--------------------------------------------------------|
| WAIT and one byte (the highest byte of a register whose lower bytes stay the same) | 3 | Fits, on lines whose display fits in cycle 1; the sprites then get only spare cycles on those lines |
| WAIT and a 2-byte colour | 4 | Does not fit with a swap: not guaranteed |
| WAIT, palette index and a 2-byte palette entry | 5 | Does not fit |
| Hi-res cells (8 beam pixels, 2 words) | – | Nothing fits |

So the copper can change per cell only a register that acts at the pixel and takes one byte per change; which registers do is spec 4's (open point C2). Spectrum-style colours per cell are the attribute layer's job (spec 4, Spectrum extras), at no copper cost. retro-z80's earlier copper read per-cell bytes from an SRAM table through pointers; retro68k's copper cannot read memory, and neither can this one.

## 9. Spectrum extras

The copper has no Spectrum extras of its own. It reaches the attribute layer (custom `0x120`–`0x13F`, spec 4) only with MOVEL, two words per byte. It cannot reach port `0xFE`: to change the border colour it writes BGCOLOR, which `0xFE` also sets (spec 4). The Spectrum screen layout is a copper list (section 8.1).

## 10. FPGA resources

| Item | Estimate |
|------|----------|
| PC (21 bits), two-word prefetch buffer, pre-decode of instruction lengths, decode | About 150 LUTs |
| Beam compare (10-bit line and pixel against the draw beam), P and B | About 50 LUTs |
| X, Y, the flags, the 8-bit ALU, the conditions | About 80 LUTs, 20 flip-flops |
| R0–R7 (8 × 8) and the stack (8 × 21) | Distributed RAM, about 30 LUTs; register-bus reads about 30 LUTs |
| Copper latch (3 bytes, a 10-bit tag), register-width table from `fpga/regmap.def`, register bus master | About 80 LUTs, 40 flip-flops |
| Control and status registers, RESUME | About 60 LUTs, 80 flip-flops |
| Total | About 450–550 LUTs, 200 flip-flops; no block RAM |

## 11. Test plan

- **Encodings:** every instruction and form against a Python copper model; every reserved encoding stops with ERR and COPPC at it; `0xFFFF` stops with ERR.
- **MOVE reach:** MOVE to `0x000`–`0x0EF`; MOVR to `0x0F0`–`0x0FF`; MOVEL to every block up to `0x3FF`; nothing reaches the system block.
- **Copper latch:** a 3-byte register written by three MOVEs is never seen half-written; a CPU write between them changes nothing of the copper's value, and the CPU's own latch is not disturbed; a lower byte of another register drops the held bytes; a highest byte alone keeps the current lower bytes; a WAIT between the lower bytes and the commit.
- **Waits:** WAIT and SKIP on blank and picture lines, at pixels 0, 143, 144 and 863; positions beyond the frame; the pixel-only forms on the current and the next line; B with the DMA engine busy and idle, including a job started by the MOVEL just before; line 1023 as the end of a list.
- **Pixel exactness:** golden line-buffer images: palette writes after a WAIT land on the WAIT's pixel, and a second prefetched MOVE one pixel later; a 2-byte value with its low byte before the WAIT changes whole at the pixel.
- **When writes take effect:** layer writes during line L − 1 act on line L; on a 2×-tall layer a write during a pair's second line does not change that line; spec 5's sprite reuse rule with the example of section 8.4.
- **Registers and ALU:** every ALU function and source, every flag result (carry and borrow at the 8-bit edges, N from bit 7), every condition, loads and stores of the flags, MOVR in all forms with X + 1 across a multi-byte register and the wrap from `0xFF`.
- **CALL and RET:** nesting to 8, overflow and underflow set ERR; the stack emptied at the frame restart, or kept with STKKEEP.
- **Costs and rates:** words counted on the SRAM model match section 5.2 for each example; on lines whose display fits in cycle 1, with the CPU at 28 MHz (so with swaps) and every sprite busy, the copper gets one word per slot and LATE is never set; on a line over the cycle-1 budget the copper gets 224 − U words and the display is never late (OVERRUN clear).
- **LATE and OVER:** a list made to run past a WAIT's position sets LATE; WAITs for line 0 do not; a list still running at the frame restart sets OVER; a list waiting for line 1023, and list 2 under RESUME, do not.
- **Register bus:** a copper write in the same clock as a CPU OUT goes first and lands on its pixel; the CPU's strobe moves one clock and its access still completes.
- **Strobes and lists:** COPJMP1 and COPJMP2 from the CPU and the copper; COP1LC double buffering; the frame restart at draw beam (0, 0), in the same clock as VIDSTAT.VBLANK is set.
- **COPINT:** raises COPPER once per write, only with IRQEN; cleared by writing 1 to COPSTAT.IRQ.
- **RESUME:** a background list cut off at the frame restart mid-WAITB and between the bytes of a register carries on from the right place; without RESUME COP2LC is never changed.
- **Examples:** sections 8.1–8.4 run on the full-system simulation and match the model's images.

## 12. Open points

| # | Item |
|---|------|
| C1 | X and Y are 8 bits, as retro68k's are its data width: register codes and data. They are not SRAM pointers, since the copper (like retro68k's) reads no memory but its list. A load of X or Y from an SRAM table (retro68k's C4) would need a 22-bit pointer and would bring back table-driven per-line and per-cell effects; later, if wanted |
| C2 | Per-cell colours (section 8.5) need a register that acts at the pixel and takes one byte per change; spec 4 to say which, if any. Otherwise per-cell colour is left to the attribute layer |
| C3 | The guaranteed rate assumes that a line whose display fetch fits in cycle 1 never takes cycle 3 (no FIFO falls below its low mark). To be confirmed in spec 4 and in simulation, with the swap at 28 MHz |
| C4 | LATE exempts WAITs for line 0. Confirm in use that this tells real lateness from intended passed WAITs |
| C5 | Prefetch depth: two words. Three would let a 3-byte pointer change within two pixels of a WAIT, at about 20 LUTs |
| C6 | Closed: spec 3, rules 2 and 3 give the CPU and the copper the same rule: lower bytes written since the last commit, the register's current value for the rest |
| C7 | The copper comes before sprites in cycle 3, so a busy copper line takes sprite fetch time; spec 5's fetch budget must allow for it (design plan, Q5) |
| C8 | MOVEL reaches the audio offsets (`0x180`–`0x1FF`); writes there do nothing until sound is decided (Q1) |
| C9 | Exact pixel delay from a WAIT to a palette change, and of the second prefetched MOVE (retro68k's C2): to be confirmed in simulation |
| C10 | Whether RESUME should also save the held lower bytes, so that no MOVE is ever repeated (retro68k's C3) |
