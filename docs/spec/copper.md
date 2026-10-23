# Spec 6: Copper

Status: **draft**

The copper is a small coprocessor that follows the beam, as on the Amiga and in retro68k: it runs a list of instructions from SRAM every frame and writes custom registers at chosen beam positions. It changes colours partway down the screen, resets the layer and sprite pointers and starts the sprites for each frame, sets a layer's line address on every line (the Spectrum screen layout), opens split screens, and so on, without the CPU.

It is retro68k's copper (its spec 10, guide chapter 5 and `copper.v`) narrowed to 8 bits: the same instructions, registers, macros, memory channel and programming model, with 16-bit instruction words that carry 8 bits of data.

## 1. Summary

| Item | Value |
|------|-------|
| Program | A list of 16-bit instruction words in SRAM, at even addresses; restarted from COP1LC at the start of every frame (beam line 0, pixel 0: the start of the vertical blank) |
| Instructions | MOVE (one word), WAIT, SKIP, JUMP, STOP, MOVEF (one byte to any offset, two words); MOVE through X and Y (MOVR); LD, ST, ADD, SUB, AND, OR, CMP; SKIP on a condition (SKIPC); CALL and RET. One or two words each (section 4.1) |
| Registers | X and Y (8 bits), the flags (Z, N, C), 8 storage registers COPR0–7 (8 bits), a return stack 8 deep. The CPU can read and write all but the stack contents |
| Can write | The custom block only: MOVE reaches offsets `0x000`–`0x0EF` (video globals, sprites, layers), MOVEF every offset `0x000`–`0x3FF`. Not the system block |
| Multi-byte registers | Low byte first; each byte is written directly, with no latch, except a colour, which waits for its red byte in the copper's colour assembly buffer (section 4.2). The macro `CMOVEL` writes a whole 4-byte register, as retro68k's writes a whole 32-bit one |
| Beam position | The display beam, as retro68k (spec 4); 10-bit line and pixel, pixel exact |
| Memory | Its own channel in the scheduler (spec 2): cycle 4 and the free pool, as retro68k's copper. COPCON.PRI 1 makes cycle 4 its own |
| Rate at PRI 1 | One word every slot (100 ns, 2.7 beam pixels): one MOVE per slot, 320 per line, on screens within the display budget (section 5.3) |
| Prefetch | Two words, read while the copper waits: the first write after a WAIT lands on the WAIT's pixel, a second prefetched MOVE within a pixel after it |
| Interrupt | A MOVE to COPINT raises the copper's interrupt (source COPPER, spec 8) |
| Registers | Custom offsets `0x100`–`0x11F` (section 6); the copper writes them with MOVEF |

## 2. Comparison with retro68k

| | retro68k (spec 10) | retro-z80 | Why |
|--|--------------------|-----------|-----|
| Instruction size | 32 bits, every instruction one fetch of two words | 16-bit words. MOVE, MOVR, ALU with a register source, SKIPC, STOP and RET are one word; WAIT, SKIP, JUMP, CALL, MOVEF and ALU with a value are two | Z80: 8-bit data. A MOVE is a register code and a data byte, one word, so the most common instruction costs one fetch |
| MOVE | 16 bits of data to a register half; offset up to `0x7FFE` | 8 bits of data; the register code is 8 bits, so MOVE reaches offsets `0x000`–`0x0EF`. Codes `0xF0`–`0xFF` are the other instructions | 8-bit registers; one-word MOVE |
| MOVEF | None | Two words: one byte to any custom offset `0x000`–`0x3FF`. Macro `CMOVEF` | MOVE cannot name offsets `0x0F0`–`0x3FF`: the copper's own registers, the sprite globals, the attribute layer, the DMA engine |
| `CMOVEL` | Two MOVEs: a whole 32-bit register | The same meaning: a whole 4-byte register, as four MOVEs (or MOVEFs), low byte first. 3-byte pointers and colours use `CMOVEA`, 2-byte registers `CMOVEW`, any width `CMOVEN` (section 7) | Byte registers of 1–4 bytes; pointers are 3 bytes |
| Halves rule | A high half is held until the low half of the same register | No latch: each byte is written directly; only colours wait for their red byte (section 4.2) | Cost; 8-bit registers (spec 3, rule 3) |
| Beam | 11-bit line and pixel. End-of-list WAIT: line 2047 | The same beam, 10-bit line and pixel. End-of-list WAIT: line 1023 | One-word encoding: 10 bits cover 864 × 625 |
| X, Y, R0–R7 | 16 bits; X holds a register offset with bit 1 choosing the half; MOVR steps X by 2 | 8 bits; X holds a register code `0x00`–`0xFF`; MOVR steps X by 1; N is bit 7 | 8-bit data |
| MOVR reach | The whole MOVE reach | Offsets `0x000`–`0x0FF` (an 8-bit code, from X or from the instruction) | One-word MOVR |
| MOVR encoding | One op with A, S, I and X bits | Five one-word codes (section 4.5); the same five forms and macros | Fits one word |
| ALU encoding | fn, d (X, Y or the flags), s (value, X, Y or Rn) | fn, d (X or Y), a 4-bit source; loads and stores of the flags use fn 7. The same macros, `CF` included | Fits one word |
| Memory cycles | Cycle 4 and the free pool; audio has cycle 2 | Cycle 4 and the free pool; cycle 4 is also where audio (reserved) goes, since cycle 2 is the CPU's | Z80: the CPU has cycles 0 and 2 (spec 2) |
| Rate at PRI 1 | One instruction (two words) every 200 ns | One word every 100 ns: one MOVE every slot | One-word MOVE |
| COPCON.PRI | 0 normal, 1 high, 2 nasty (may take the CPU's cycle 0) | 0 normal, 1 high; 2 and 3 reserved, taken as 1 | The CPU never waits (spec 2) |
| Prefetch | One instruction (two words) | Two words: a two-word instruction, or two MOVEs | The same buffer, used for 16-bit words |
| JUMP, CALL penalty | The prefetched instruction is thrown away | None while the copper is fetch-bound: it runs them as soon as their last word arrives, then fetches the target (section 5.2) | One-word instructions keep the buffer busy |
| Register bus | A CPU access already on the bus goes first; the copper may wait a clock | The copper goes first; the CPU's strobe moves one clock (spec 1) | The Z80's I/O cycle has room, and the copper's writes then always land on their pixel |
| Addresses | COPxLC, COPPC, JUMP and CALL: bits 22–2, long-word aligned | 22-bit physical SRAM byte addresses, even (bit 0 = 0), 3 bytes | Word instructions; memory (spec 2): chipset units address the SRAM without the MMU |
| Strobes | Act on a write that reaches the low half | Act on any write: they are single bytes | 8-bit registers |
| Registers | 32-bit, at `0xE00700` | Bytes at custom offsets `0x100`–`0x11F`, ports `0x0011`–`0x1F11` (spec 3) | Register map |

Kept as retro68k: WAIT with P (pixel only) and B (DMA engine idle), SKIP, JUMP, STOP, COP1LC, COP2LC, COPJMP1, COPJMP2, COPINT, COPSTAT (WAITING, STOPPED, ERR, IRQ), COPPC, COPCON (EN, IRQEN, RESUME, STKKEEP, PRI), COPX, COPY, COPFLAGS, COPSP, COPR0–7, the conditions, CALL and RET with a stack 8 deep, background lists with RESUME (the place only), double-buffered lists, the display beam, the memory channel and its free-pool order, the macro names.

## 3. Beam positions

WAIT and SKIP positions are in **beam coordinates** (spec 4): line 0 is the start of the vertical blank and the picture is lines 49–624; pixel 0 is the start of a line's horizontal blank and the picture is pixels 144–863. The copper uses all 864 × 625 positions, blanking included. Positions only go up through a frame.

The copper follows the **display beam**, as retro68k's does and as software sees it (BEAMPOS, LINECMP, VBLANK, spec 4). It compares against the beam as the memory side sees it, a few clocks behind the pixel clock, so a WAIT ends within about one pixel (37 ns) of its position.

- The list restarts from COP1LC when the beam reaches (0, 0), with the VBLANK interrupt. Its writes for the coming picture (pointers, colours) land in lines 0–48, before the picture's first line is fetched.
- A WAIT for line L, pixel 0 ends at the start of line L's horizontal blank, 144 pixels before its picture.
- A position the beam has already passed in this frame satisfies a WAIT at once and makes a SKIP skip.

**When writes take effect:** exactly as for the CPU's writes (spec 4; spec 5, section 4.2 for the sprites). In short, as retro68k:

| Registers | Take effect |
|-----------|-------------|
| Palette entries (PALDAT), VIDCON.DIRECT, VIDCON.BLANKALL | At once, from the next pixel |
| BPL0PT, BPLSTRIDE | Live: a pointer written between a layer's last fetch on line L and the start of line L + 1 is used as written for line L + 1. On a 2×-tall layer, write after the **last** copy of a source line |
| CTRL, the window, SCROLLX | At the start of each line's horizontal blank (beam pixel 0): to change line L, write during line L − 1 |
| PRIO, BGCOLOR | At the start of each line's picture (beam pixel 144): write in line L's horizontal blank, or earlier |
| Sprite registers (SPRxPT, SPRxH, SPRxV, SPRxCTL, SPRxSTEP) | Spec 5, section 4.2: a CTL write starts the sprite, from the next line inside its window, at SPRxPT. PT, H, V and STEP act on a running sprite from the next line. The vertical blank stops every sprite, so each frame the list writes each sprite's registers, CTL last |

Spec 4 has the full list; where it differs, spec 4 wins.

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
 FC       0 0 0 0 0 0 | offset 9-8           offset 7-0 (15-8) | data (7-0)     MOVEF
 FD-FF    reserved
```

| Instruction | Words | Does |
|-------------|-------|------|
| **MOVE** | 1 | Writes the data byte to the custom register at offset = code (`0x000`–`0x0EF`), following the byte rule (section 4.2) |
| **MOVEF** | 2 | The same, to any custom offset `0x000`–`0x3FF`. Word 2 looks like a MOVE word, with offset bits 9–8 in word 1 |
| **WAIT** | 2 | Waits until the beam has reached the position: it ends on the position itself. A position the beam never reaches (pixel 864 or more, line 625 or more) waits until the next frame. With **P** set (pixel only), the line is ignored: it waits until the pixel position on the current line, or on the next line if it has already passed. With **B** set, it also waits until the DMA engine (spec 14) is idle: no job running or waiting to start on any of its four channels, including one a MOVEF just before started |
| **SKIP** | 2 | If the beam has reached the position, skips the next instruction. With P set, compares the pixel position only |
| **JUMP** | 2 | Continues at the address |
| **STOP** | 1 | Stops until the next frame (or a COPJMP strobe). A WAIT for line 1023 does the same |
| **MOVR** | 1 | A MOVE through X and Y (section 4.5) |
| **ALU** | 1, or 2 with a value | Loads, stores, arithmetic and compare on X and Y (section 4.6) |
| **SKIPC** | 1 | Skips the next instruction if a condition on the flags holds (section 4.7) |
| **CALL**, **RET** | 2, 1 | Subroutines (section 4.8) |

Bits shown as 0 must be 0. Unused patterns are reserved (section 4.9).

**Loops:** SKIP and JUMP make loops that end at a beam position, as in retro68k. For example, to repeat a block of MOVEs on every line until line 400: `loop: CWAITP 0` … MOVEs … `CSKIP 400,0` / `CJUMP loop`. Loops that end on a count or a value use the registers and SKIPC (sections 4.6, 4.7).

### 4.2 MOVE, MOVEF and direct writes

A MOVE or MOVEF writes one byte, **straight to its register**, with no latch (spec 3, rules 2 and 3). Registers wider than 8 bits are consecutive bytes, **low byte first**, and each byte takes effect when it is written. So a register holds a mixed value between a list's MOVEs to it, and a list writes wide registers where the hardware does not read them:

- A line setting (spec 4, section 5.6): in the horizontal blank after beam pixel 0, or in the visible part of the line before the one it is for.
- A live pointer (BPL0PT): while the layer is not fetching, in the vertical blank, or after the layer's last fetch on a line and before the next line starts. A fetch between its bytes would move the pointer on from a mixed value (spec 4, section 4.4).
- A sprite register: to start a sprite, write PT, H, V and STEP in any order, then CTL last. On a running sprite, write SPRxPT's three bytes within one line, so that no line starts between them (spec 5, section 4.2).
- **Colours are the exception** (spec 3, rule 7): MOVEs to a colour's blue and green bytes (BGCOLOR, or PALDAT) go into the copper's **colour assembly buffer**, its own, separate from the CPU's and the DMA engine's, and the red MOVE writes the colour whole. Other instructions may come between them. The buffer is one for all colours, not one per entry.

MOVR follows the same rules. A CPU write between two copper MOVEs to one register lands between them, and the last write to each byte wins.

Strobes (COPJMP1, COPJMP2, COPINT and the DMA engine's) act on any write. Read-only registers ignore the copper's writes, as they do the CPU's.

**A value at an exact pixel.** A one-byte change lands whole after a WAIT (section 5.4). A colour can change whole at a pixel too: write its blue and green before the WAIT, where they wait in the colour assembly buffer, and its red after it, as retro68k's lists do with the high half. Other wide values change over their MOVEs; the first two after a WAIT land 20 ns apart, within a pixel.

### 4.3 WAIT and SKIP

Line and pixel are 10 bits each (0–1023). The macros take them as numbers: `CWAIT line,pixel`, `CWAITP pixel`, `CWAITB line,pixel`, `CSKIP line,pixel`, `CSKIPP pixel`.

- A pixel-only WAIT always waits for the next time the beam comes to that pixel. A block that starts with `CWAITP 0` runs once at the start of each line's horizontal blank. Start a run of pixel-only WAITs with an ordinary WAIT, so that the run begins on the line you mean.
- A pixel-only WAIT relies on the copper finishing its block before the beam comes round again; a block that runs past its own pixel position slips a line. At PRI 1 a line is 320 words.
- `CWAITB 0,0` waits only for the DMA engine (the position has always passed).
- While it waits, the copper fills its two-word prefetch buffer (section 5.4), then uses no memory cycles until the WAIT ends.
- **End of a list:** STOP, or a WAIT for line 1023 (`CWAIT 1023,0`). If a list is still running when the next frame starts, it is abandoned: the copper starts again from COP1LC whatever it was doing.

### 4.4 JUMP and STOP

JUMP continues at a 22-bit even SRAM address, anywhere in the SRAM (spec 2). STOP stops the copper until the next frame restart or a COPJMP strobe; COPPC then points at the STOP. The address of a list wraps at 22 bits.

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

With I, a run of MOVRs walks through consecutive registers: the bytes of a multi-byte register, low to high, and on to the next register. X wraps from `0xFF` to `0x00`. None of them change the flags. A MOVR follows every MOVE rule: the byte rule, the strobes, the register bus. Codes `0xF0`–`0xFF` name the read-only video registers (BEAMPOS, FRAMECOUNT, VIDSIZE, spec 4), which ignore the writes.

### 4.6 Registers and the ALU

The copper has these registers, all 8 bits except the flags and the stack. The CPU can read and write them at their custom offsets (section 6), and the copper can too, with MOVEF; normally the copper uses the ALU.

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

There is no instruction to load a custom register into X or Y, and no load from SRAM, as in retro68k: values come from numbers in the list, from the CPU (which can write COPX, COPY and COPR0–7), or from earlier arithmetic (open point C1).

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

The list is in SRAM; the copper reads it one 16-bit word per memory cycle, through its own channel in the scheduler, as retro68k's copper does (spec 2; retro68k spec 5, section 6). Each 100 ns slot has five cycles: 0 CPU, 1 display, 2 CPU, 3 display, 4 audio (reserved) and the free pool. For each cycle the first rule that finds a request wins:

1. An **urgent** hard-deadline request (a layer or sprite about to be late) gets the cycle, unless it is a cycle the CPU is using: the CPU never waits.
2. The cycle's **default owner**: the CPU on cycles 0 and 2, the hard-deadline channels on cycles 1 and 3, and on cycle 4 audio (reserved: none yet), then **the copper at PRI 1**.
3. The **free order**: the copper at PRI 1 first; then hard-deadline channels (earliest deadline first), audio, the copper at PRI 0, the DMA engine (spec 14), the DMA port.

So the copper gets cycle 4 and any cycle its owner leaves: the CPU's unused cycle 0 or 2 (at 20 MHz the Z80 leaves at least one of the two in every slot, spec 2), and cycles 1 and 3 when no layer or sprite wants them (the whole vertical blank, quiet stretches of a line).

**Priority, COPCON.PRI** (retro68k's field, without its nasty mode):

| PRI | The copper gets |
|-----|-----------------|
| 0, normal | Cycle 4 and the cycles nobody else wants, after the layers, sprites and audio (the default) |
| 1, high | Cycle 4 as its own (after audio, when audio exists), and first place in the free order: ahead of the DMA engine and of layer and sprite fetches that are not urgent |
| 2, 3 | Reserved, taken as 1. retro68k's PRI 2 takes the CPU's cycle; here the CPU never gives up a cycle it uses |

An urgent display or sprite fetch still comes first at every level, so raising the copper never spoils the picture. PRI matters only while the copper has a word to fetch: while it waits with its prefetch buffer full, it takes nothing.

When to use them, as retro68k: **PRI 0** for most lists, which spend most of their time waiting; **PRI 1** when a burst of writes must fit in a short gap (new pointers between a layer's last fetch and the end of the line, per-cell colours, many changes in one horizontal blank), or on a screen near its fetch budget. The copper can write COPCON itself (with MOVEF), so a list can raise its priority before a burst and lower it after; write EN as 1 every time.

### 5.2 Cost of each instruction

Every word of every instruction the copper passes is fetched once:

| Instruction | Words (fetches) |
|-------------|-----------------|
| MOVE, MOVR (all forms), ALU with a register source, SKIPC, STOP, RET | 1 |
| WAIT, SKIP, JUMP, CALL, MOVEF, ALU with a value | 2 |
| An instruction skipped by SKIP or SKIPC | Its words, as if run |

JUMP, CALL and RET carry no extra cost while the copper is fetch-bound: it runs them as soon as their last word arrives, before it asks for the next word, and then fetches the target. When memory is quiet it may already have read up to two words past them, which are thrown away. A loop costs a fetch for every word in it, every pass: unrolled MOVEs are faster, loops are shorter.

Running an instruction takes 1–2 system clocks (a register write: one clock on the register bus and one spare clock, so that a write to the copper's own registers has acted before the next instruction, as in retro68k). This is small against the fetch time, so the copper's speed is its fetch rate.

### 5.3 Rates

At **PRI 1**, cycle 4 is the copper's in every slot unless an urgent fetch takes it, which happens only on screens over the display budget (spec 4). So on screens within the budget, the copper is certain of one word every slot, 100 ns, the same memory rate as retro68k's copper (20 MB/s), and with one-word MOVEs that is one MOVE per slot:

| At PRI 1, on a screen within the display budget | Words | MOVEs |
|-------------------------------------------------|-------|-------|
| One slot (100 ns, 2.7 beam pixels) | 1 | 1 |
| One 8-pixel cell at 1× (8 beam pixels, 296 ns) | 2 (3 in some cells) | 2 |
| One 8-pixel cell at 2× (16 beam pixels, 593 ns) | 5 (6 in some cells) | 5 |
| The horizontal blank (144 pixels, 5.33 µs) | 53 | 53 |
| One line (32 µs) | 320 | 320 |
| The vertical blank (49 lines, 1.57 ms) | 15,680 | 15,680 |
| One frame (625 lines, 20 ms) | 200,000 | 200,000 |

These figures hold whatever the CPU, the sprites and the DMA engine do. Spare cycles make the copper faster: in the vertical blank cycles 1 and 3 are free too, and the CPU leaves at least one of its cycles in every slot.

At **PRI 0** the copper is best effort, as retro68k's: it usually gets cycle 4 and many spare cycles, but sprites filling their FIFOs ahead and early layer fetches come first. Plan time-critical bursts at PRI 1.

When audio is specified (Q1), its few words per line will come before the copper's in cycle 4 (open point C3).

### 5.4 After a WAIT: prefetch

The copper has a prefetch buffer of **two words**. While it waits, it reads the next two words, so the instruction after the WAIT, and with a one-word instruction the one after that, are already there when the WAIT ends:

- The first MOVE after a WAIT is made 10–20 ns after the WAIT ends, within a pixel of its position, as in retro68k.
- A second prefetched MOVE lands 20 ns (two clocks) after the first, within the same or the next pixel.
- Each write after those needs its own fetch: one slot apart (2.7 pixels) at PRI 1.
- To change a colour exactly at a pixel, write its blue and green before the WAIT (they wait in the copper's colour assembly buffer) and its red after it. Other registers have no latch: a 2-byte value written by the two prefetched MOVEs changes within a pixel, but a wider one changes over a slot or more.

A SKIP that skips throws away the prefetched words of the instruction it skips; JUMP, CALL and RET throw away anything prefetched past them (section 5.2).

### 5.5 Register bus

The copper's writes go over the register bus that the CPU's I/O cycles and register page accesses use (spec 1). If both want it in the same clock, **the copper goes first** and the CPU's strobe moves one clock later, which its I/O cycle has room for (spec 1). So a copper write is never delayed and lands on its pixel.

Both can write the same register. Writes are direct, so the last write to each byte wins, and a CPU write between the copper's bytes of one register mixes with them; only colours are assembled, in a buffer per master (spec 3, rule 3). Let one of them own each register: if the copper resets the layer pointers, the CPU changes the list, not the pointers.

## 6. Registers

Custom offsets. The CPU reaches them on ports, port = (offset bits 7–0) << 8 | (`0x10` + offset bits 9–8) (spec 3): page `0x11`, `LD BC,port` then `OUT (C),r`, or `LD A,reg` then `IN A,(0x11)`. In the register page they are at `0x1000` + offset (`0x1100`–`0x111F`). The copper writes them with MOVEF. Multi-byte values: low byte at the lowest offset, each byte written directly.

| Offset | Port | Name | Access | Bits | Description | Reset |
|--------|------|------|--------|------|-------------|-------|
| `0x100` | `0x0011` | COPCON | RW | EN (0), IRQEN (1), RESUME (2), STKKEEP (3), PRI (5–4); 7–6 reserved | Copper on (DMACON.COPEN and DMACON.DMAEN must also be set); COPINT raises the interrupt; the frame restart saves list 2's place in COP2LC (section 6.5); the frame restart keeps the stack (section 4.8); memory priority, 0 normal, 1 high, 2–3 taken as 1 (section 5.1) | 0 |
| `0x101`–`0x103` | `0x0111`–`0x0311` | COP1LC | RW | 21–0, bit 0 ignored | List 1: restarted at every frame restart | 0 |
| `0x104`–`0x106` | `0x0411`–`0x0611` | COP2LC | RW | 21–0, bit 0 ignored | List 2: runs when COPJMP2 is written. Changed by the hardware only with COPCON.RESUME set | 0 |
| `0x107` | `0x0711` | COPJMP1 | W | – | Strobe: restart at COP1LC now | – |
| `0x108` | `0x0811` | COPJMP2 | W | – | Strobe: continue at COP2LC now | – |
| `0x109` | `0x0911` | COPINT | W | – | Strobe: sets COPSTAT.IRQ. Meant to be written by the copper itself | – |
| `0x10A`–`0x10C` | `0x0A11`–`0x0C11` | COPPC | R | 21–0 | The instruction being run; when stopped, the STOP (or reserved instruction) that stopped it. Reading `0x10A` captures all three bytes | 0 |
| `0x10D` | `0x0D11` | COPSTAT | R, W1C | WAITING (0), STOPPED (1), ERR (2), IRQ (3); 7–4 reserved | Bits 0–1 live, read only. Bits 2–3 sticky, write 1 to clear (sections 4.9, 6.4) | `0x02` |
| `0x10E` | `0x0E11` | COPX | RW | 7–0 | X (section 4.6) | 0 |
| `0x10F` | `0x0F11` | COPY | RW | 7–0 | Y | 0 |
| `0x110` | `0x1011` | COPFLAGS | RW | Z (0), N (1), C (2) | The flags | 0 |
| `0x111` | `0x1111` | COPSP | RW | 3–0 | Read: entries in use on the stack (0–8). Write (any value): empty the stack | 0 |
| `0x112`–`0x117` | | – | | | Reserved: read `0xFF`, writes ignored (spec 3) | |
| `0x118`–`0x11F` | `0x1811`–`0x1F11` | COPR0–COPR7 | RW | 7–0 | Storage registers R0–R7 | 0 |

### 6.1 Status bits

| Bit | Set when |
|-----|----------|
| WAITING | The copper is in a WAIT |
| STOPPED | After STOP, a reserved instruction, a stack error, while off (EN, COPEN or DMAEN clear), and after reset |
| ERR | A reserved instruction (section 4.9), or a CALL with the stack full or a RET with it empty |
| IRQ | A write to COPINT |

### 6.2 CPU access

The CPU can read and write COPX, COPY, COPFLAGS and COPR0–7 at any time; a write lands between two copper instructions. Each is one byte, so the copper sees either the old value or the new one. A value the copper takes from several storage registers can still be torn by a CPU write between the copper's reads: write such values while the copper is stopped or waiting (for example from a copper interrupt raised just before a STOP), or use storage registers that only one side writes.

### 6.3 Starting, stopping and the frame restart

- **Starting:** after reset COPCON, COP1LC, COP2LC, X, Y, the flags, R0–R7 and the stack are 0, and the copper is stopped. With COPCON.EN, DMACON.COPEN and DMACON.DMAEN (spec 4) all set, the copper starts from COP1LC at the next frame restart; a write to COPJMP1 starts it at once.
- **Stopping:** clearing any of the three stops it at once. Setting them again starts it at the next frame restart (or COPJMP1).
- **Frame restart**, when the beam reaches (0, 0) with the copper on: with RESUME, list 2's place is saved (section 6.5); the PC is loaded from COP1LC; the prefetched words are dropped; the stack is emptied unless STKKEEP is set. X, Y, the flags and R0–R7 are kept.
- **Restarting** with COPJMP1 or COPJMP2 also drops the prefetched words. A strobe from the CPU wakes a copper that is waiting or stopped.
- **Double-buffered lists:** build next frame's list in a second buffer, then write its address to COP1LC. The copper picks it up at the next frame restart, so a half-built list is never run. COP1LC's three bytes are written directly, so write them well away from the frame restart, for example in the VBLANK handler, which runs just after it: a restart between the bytes would start a list at a mixed address.

### 6.4 Interrupt

Source **COPPER** (2) in the interrupt controller (spec 8) is COPSTAT.IRQ with COPCON.IRQEN; its IM 2 vector is VECBASE + 4. A list raises it with `CMOVEF COPINT,0`. The handler clears it by writing 1 to COPSTAT.IRQ. A second COPINT before that changes nothing.

### 6.5 Background lists: COPCON.RESUME

As in retro68k, the copper can run a long **background** list, such as a queue of DMA engine jobs (spec 14), that carries on across frames while list 1 still restarts at every frame. With COPCON.RESUME set:

- The copper keeps an **in list 2** flag. A COPJMP2 strobe sets it. A COPJMP1 strobe, a STOP (or a WAIT for line 1023, or a reserved instruction), and the frame restart clear it. JUMP, CALL, RET and the SKIPs leave it as it is.
- At the frame restart, if the flag is set, the hardware writes the **resume address** to COP2LC before it reloads from COP1LC. The resume address is the instruction not yet finished: a WAIT still waiting (it runs again, whole), or the next instruction to run.
- **Nothing else is saved**, as in retro68k. Bytes already written stay written, and list 2 carries on with the next instruction. The colour assembly buffer is not saved: if list 2 is cut off between a colour's blue or green and its red, list 1 may use the buffer meanwhile, so a background list should not write colours (open point C10).
- List 1 ends with `CMOVEF COPJMP2,0` (two words), and list 2 carries on where it was cut off.

Without RESUME (the default), COP2LC is never changed by the hardware.

**Only the place is saved.** X, Y, the flags and R0–R7 are never changed by the frame restart. A list 1 that uses X, Y or the ALU saves what it uses into spare storage registers first (`CST CR5,CX`, `CST CR7,CF`) and puts it back (`CLD`) before its COPJMP2. With STKKEEP, list 1's CALLs must all have returned before its COPJMP2.

Rules for a background list, as retro68k's:

- Its WAITs should be pixel-only, DMA-only (`CWAITB 0,0`) or none: after a resume, a beam WAIT would wait for its position in the new frame.
- Some MOVEs may run twice: if the cut-off comes between the bytes of a multi-byte register, they run again. Never put a strobe (such as a DMA engine start) between the bytes of a register.
- When it is done, it sets COP2LC to an idle list (`CMOVEA COP2LC,idle`, three MOVEFs, then `CSTOP`, where `idle` is a STOP).
- While RESUME is set and a background list is running, the CPU's writes to COP2LC may be replaced at the next frame restart. The CPU writes COP2LC only while the copper runs the idle list (COPPC tells it where the copper is).

### 6.6 What the copper can reach

| Area | The copper can |
|------|----------------|
| SRAM | Read its list (22-bit physical addresses, not through the MMU). Nothing else: it cannot write SRAM or read tables from it |
| Custom block `0x000`–`0x0EF` | Write with MOVE, MOVR or MOVEF: video globals (BGCOLOR, PALIDX, PALDAT, DMACON …), the sprites, the three layers |
| Custom block `0x0F0`–`0x0FF` | Nothing useful: read-only video registers, which ignore MOVR and MOVEF writes |
| Custom block `0x100`–`0x3FF` | Write with MOVEF only: its own control and state registers, the sprite globals, the attribute layer, the DMA engine (4 channels), audio (reserved) |
| System block (page `0x00`), port `0xFE`, the palettes in the register page, the boot ROM | Nothing. Palette entries are written through PALIDX and PALDAT |

So the copper cannot reach the interrupt controller, the timers, the MMU or the system registers: a runaway list can never page memory, reset the machine or change the interrupt set-up. It can turn the copper off (COPCON, DMACON), and a list that writes COPJMP1 unconditionally loops for ever.

## 7. Macros: `copper.inc`

`firmware/include/copper.inc` gives retro68k's macros for sjasmplus, with the register names (custom offsets) from `hw.inc`. Lists are word-aligned (`ALIGN 2`). Each macro emits `DW` words as section 4.1; the table gives the words.

| Macro | Instruction | Words | Emits |
|-------|-------------|-------|-------|
| `CMOVE reg,value` | MOVE; reg must be below `0x0F0` (an assembly error otherwise) | 1 | `reg << 8 \| value & 0xFF` |
| `CMOVEF reg,value` | MOVEF: one byte to any custom offset | 2 | `0xFC00 \| reg >> 8`, `(reg & 0xFF) << 8 \| value & 0xFF` |
| `CMOVEW reg,value` | A 2-byte register, low byte first | 2–4 | A MOVE for each byte, or a MOVEF where the offset is `0x0F0` or more |
| `CMOVEA reg,value` | A 3-byte register (a 22-bit address or a 24-bit colour), low byte first | 3–6 | Likewise |
| `CMOVEL reg,value` | A 4-byte register (SPRxH, SPRxV, SPRxSTEP …), low byte first: retro68k's whole-register `CMOVEL` | 4–8 | Likewise |
| `CMOVEN reg,value,n` | An n-byte register (n = 1–4), low byte first | n–2n | Likewise |
| `CWAIT line,pixel` | WAIT | 2 | `0xF000 \| (line >> 8) << 2 \| pixel >> 8`, `(line & 0xFF) << 8 \| pixel & 0xFF` |
| `CWAITP pixel` | WAIT, pixel only | 2 | As `CWAIT 0,pixel`, with P (`0x0080`) in word 1 |
| `CWAITB line,pixel` | WAIT, and the DMA engine idle | 2 | As `CWAIT`, with B (`0x0040`) in word 1 |
| `CSKIP line,pixel`, `CSKIPP pixel` | SKIP, SKIP pixel only | 2 | As `CWAIT` and `CWAITP`, code `0xF1` |
| `CJUMP address` | JUMP | 2 | `0xF200 \| address >> 16`, `address & 0xFFFE` |
| `CSTOP` | STOP | 1 | `0xF300` |
| `CMOVX value`, `CMOVXP value` | MOVR: (X) = value; then X + 1 | 1 | `0xF400 \| value`, `0xF500 \| value` |
| `CMOVR reg,CX`, `CMOVR reg,CY` | MOVR: reg = X or Y; reg below `0x100` | 1 | `0xF600 \| reg`, `0xF700 \| reg` |
| `CMOVXR src`, `CMOVXRP src` | MOVR: (X) = src (`CX` or `CY`); then X + 1 | 1 | `0xF800 \| I << 1 \| R` |
| `CLDI d,value`, `CLD d,src` | LD (d = `CX`, `CY` or `CF`) | 2, 1 | `0xF900 \| fn << 5 \| d << 4 \| source`, and the value word for `I` forms |
| `CST CRn,d` | ST (d = `CX`, `CY` or `CF`) | 1 | Likewise |
| `CADDI`/`CADD`, `CSUBI`/`CSUB`, `CANDI`/`CAND`, `CORI`/`COR`, `CCMPI`/`CCMP` | ALU on `CX` or `CY`; the `I` forms take a value | 2, 1 | Likewise |
| `CSKIPEQ` … `CSKIPLS` | SKIPC | 1 | `0xFA00 \| cc` |
| `CCALL address`, `CRET` | CALL, RET | 2, 1 | `0xFB00 \| address >> 16`, `address & 0xFFFE`; `0xFB80` |

Operands `CX`, `CY`, `CF`, `CR0`–`CR7` are equates in `copper.inc`, with the field equates (`COP_P`, `COP_B`, `COP_FN_LD` … `COP_FN_FLAGS`, `COP_CC_EQ` … `COP_CC_LS`). `CMOVEL` keeps retro68k's meaning, a whole wide register; since retro-z80's pointers and colours are 3 bytes, retro68k's `CMOVEL` on a pointer becomes `CMOVEA` here.

## 8. Examples

Register names are the custom offsets of `hw.inc` (spec 3): video globals at `0x000`–`0x00F` (`BGCOLOR` is 3 bytes: blue, green, red, the red byte commits), sprites at `SPR0` = `0x010` + 16n (spec 5), layers `L0`, `L1`, `L2` at `0x090`, `0x0B0`, `0x0D0` with spec 4's per-layer names (`L_BPL0PT`, a 3-byte pointer; `L_SCROLLX`). Their widths and timing are spec 4's and spec 5's. Costs are in words (fetches); times are at the PRI 1 rate of section 5.3.

### 8.1 Spectrum screen layout

Layer 0 shows the Spectrum's 6 KB screen as a 256 × 192 1-bit bitmap at 2× across and down, window 248–760 × 145–529, with colours from the attribute layer (spec 4, Spectrum extras). Picture line k is the pair of beam lines 145 + 2k and 146 + 2k, and its address is `SCREEN + ((k & 0xC0) << 5) + ((k & 7) << 8) + ((k & 0x38) << 2)`. BPL0PT is live (section 3): the copper writes pair k's address after the layer's last fetch on line 144 + 2k, the last copy of the pair before, and before that line ends. The layer's last fetch on a line comes about two groups (32 source pixels, 64 beam pixels at 2×) before its window's right edge, about beam pixel 696, so the writes go after a WAIT for pixel 704.

**Unrolled:** a WAIT and three MOVEs per pair, built by the assembler (or by the CPU once):

```
            ALIGN   2
spec_list:
k = 0
            DUP     192
            CWAIT   144+2*k,704                 ; after the last fetch of the line before pair k
            CMOVEA  L0+L_BPL0PT,SCREEN+((k&$C0)<<5)+((k&7)<<8)+((k&$38)<<2)
k = k + 1
            EDUP
            CSTOP
```

Cost: 5 words per pair, 960 per frame (0.5% of the frame's 200,000 cycle 4s); the list is 961 words (1,922 bytes). The three MOVEs land within about 3 slots (8 pixels) of pixel 704, well before the line ends at 864.

**As a loop:** the ALU steps the address down one line, as the Spectrum ROM's own routine does: Y holds address bits 15–8, X bits 7–0. SCREEN is 8 KB-aligned (one MMU page), so bits 12–0 of the address are the offset alone.

```
            ALIGN   2
spec_loop:  CLDI    CX,0                        ; line 0: address bits 7-0
            CLDI    CY,(SCREEN>>8)&$FF          ; address bits 15-8
            CWAIT   144,704                     ; the line before pair 0
.pair:      CMOVR   L0+L_BPL0PT,CX              ; bits 7-0
            CMOVR   L0+L_BPL0PT+1,CY            ; bits 15-8
            CMOVE   L0+L_BPL0PT+2,SCREEN>>16    ; bits 21-16, all after the last fetch
            CSKIP   526,704                     ; pair 191 written?
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
.next:      CWAITP  704                         ; the pair's first line
            CWAITP  704                         ; its second: the line before the next pair
            CJUMP   .pair
```

Cost: 22 words per pair, 29 at most (every eighth pair); about 4,500 per frame (2.3% of cycle 4), fewer than 30 on any one line. The list is 36 words (72 bytes) instead of 961. The BPL0PT writes come about 5 slots (14 pixels) after pixel 704.

A program that keeps its screen in linear order needs no copper: BPL0PT = screen, BPLSTRIDE = 32.

### 8.2 Colour gradient

The background goes from black through blue to cyan down the picture: 31 bands of 18 beam lines from line 49, blue rising in steps of `0x11` to `0xFF`, then green likewise.

**Unrolled** (as retro68k's colour bars):

```
            ALIGN   2
grad_list:  CMOVEA  BGCOLOR,$000000             ; band 0 black, set in the vertical blank
b = 1
            DUP     30
            CWAIT   49+18*b,0                   ; the blank before band b
            IF b < 16
            CMOVEA  BGCOLOR,b*$11               ; blue rises (bits 7-0) ...
            ELSE
            CMOVEA  BGCOLOR,((b-15)*$11)<<8|$FF ; ... then green (bits 15-8)
            ENDIF
b = b + 1
            EDUP
            CSTOP
```

The macros take a value as its bytes go, low byte first, so BGCOLOR's value has blue in bits 7–0, green in 15–8 and red in 23–16. Cost: 5 words per band. The first two MOVEs after each WAIT are prefetched, and blue and green go into the copper's colour assembly buffer; the third, red, commits the colour about one slot later, in the horizontal blank.

**As a loop**, with X the blue and Y the green, and a count of lines in R1:

```
            ALIGN   2
grad_loop:  CLDI    CX,$00                      ; blue
            CLDI    CY,$00                      ; green
            CWAIT   49,0
.band:      CMOVR   BGCOLOR,CX                  ; blue (held)
            CMOVR   BGCOLOR+1,CY                ; green (held)
            CMOVE   BGCOLOR+2,$00               ; red 0: commits
            CCMPI   CY,$FF                      ; the last colour?
            CSKIPNE
            CSTOP
            CCMPI   CX,$FF                      ; blue full yet?
            CSKIPNE
            CJUMP   .green
            CADDI   CX,$11                      ; no: blue up
            CJUMP   .count
.green:     CADDI   CY,$11                      ; yes: green up
.count:     CST     CR1,CX                      ; free X for the line count
            CLDI    CX,18
.wait:      CWAITP  0                           ; the next line
            CSUBI   CX,1
            CSKIPEQ
            CJUMP   .wait
            CLD     CX,CR1
            CJUMP   .band
```

Cost: 7 words per line while it waits, and about 22 more per band. The colour commits about 11 words after the band's last `CWAITP`, about 1.1 µs (30 pixels) into the horizontal blank. The list is 37 words.

### 8.3 Split-screen scroll

Layer 0, 2× across and down over the whole picture, scrolls across, with a fixed status panel from beam line 529 (the start of a pair). The CPU leaves the game's pointer in COPR0–2 and its fine scroll in COPR3; the copper puts them in place in the vertical blank, so the scroll changes once per frame, in step with the picture. At the panel the copper writes the panel's pointer after the layer's last fetch on line 528 (the last copy of the pair before; at 2× across the last fetch is about beam pixel 800) and its scroll during line 528, then tells the CPU, which writes the next frame's values while the copper is stopped. SCROLLX is taken here as 2 bytes (bits 9–0 in tile mode, spec 4), so both bytes are written. Every write in the vertical blank lands while the layer is not fetching.

```
            ALIGN   2
split:      CMOVEF  COPCON,COPCON_EN_M|1<<COPCON_PRI_B  ; PRI 1 for the burst at the panel
            CLD     CX,CR0                      ; the game's BPL0PT, from the CPU
            CMOVR   L0+L_BPL0PT,CX
            CLD     CX,CR1
            CMOVR   L0+L_BPL0PT+1,CX
            CLD     CX,CR2
            CMOVR   L0+L_BPL0PT+2,CX
            CLD     CX,CR3                      ; the game's fine scroll
            CMOVR   L0+L_SCROLLX,CX
            CMOVE   L0+L_SCROLLX+1,0
            CWAIT   528,808                     ; line 528, after the layer's last fetch
            CMOVEA  L0+L_BPL0PT,panel           ; the panel's picture, used as written for line 529
            CMOVEW  L0+L_SCROLLX,0              ; no scroll
            CMOVEF  COPINT,0                    ; tell the CPU
            CSTOP
```

Cost: 11 words in the vertical blank; 9 at the panel. The five MOVEs after the WAIT land within about 4 slots (11 pixels), well inside the 56 pixels left of line 528. Parallax bands are the same with a WAIT and a pointer per band.

### 8.4 Sprite reuse down the screen

Sprite 0 shows a ship on beam lines 100 to 131, and a second ship lower down, from line 140. Spec 5's rules (section 4.2): a CTL write starts a sprite, from the next line inside its window, at SPRxPT; the vertical blank stops every sprite, so the list starts the first use in the vertical blank too. The other registers act on a running sprite from the next line, so the reuse writes come after the old use's last line has been shown. So the copper waits for line 132, writes the window and the pointer, then CTL; the CTL write lands in line 132, so the second use may start on line 133 or later.

```
            ALIGN   2
ships:      CMOVEL  SPR0+SPR_V,SHIP1_V           ; first use: window down ...
            CMOVEL  SPR0+SPR_H,SHIP1_H           ; ... and across
            CMOVEA  SPR0+SPR_PT,ship             ; image
            CMOVE   SPR0+SPR_CTL,SHIP_CTL        ; last: starts the sprite
            CWAIT   132,0                        ; the first use has been shown
            CMOVEL  SPR0+SPR_V,SHIP2_V
            CMOVEL  SPR0+SPR_H,SHIP2_H
            CMOVEA  SPR0+SPR_PT,ship
            CMOVE   SPR0+SPR_CTL,SHIP_CTL        ; last: starts the second use
            CSTOP
```

Cost: 2 + 4 + 4 + 3 + 1 = 14 words per reuse (WAIT, SPRxV, SPRxH, SPRxPT, SPRxCTL): the CTL write lands about 1.1 µs (30 pixels) after the WAIT, in line 132's horizontal blank. CTL is written even when its value does not change, since only that write starts the sprite. All the sprite registers are in a MOVE's reach.

### 8.5 Per-cell colours

A colour change at every 8-pixel cell needs a WAIT (2 words) and the writes for the cell, within the cell's time:

| Per cell | Words | 2× cells (5 words at PRI 1) | 1× cells (2 words at PRI 1) |
|----------|-------|-----------------------------|-----------------------------|
| WAIT and one byte (a one-byte change, or a colour's red byte with its blue and green written before the WAIT) | 3 | Fits | Does not fit |
| WAIT and a 3-byte colour | 5 | Fits, with nothing to spare | Does not fit |
| WAIT, PALIDX (2 bytes) and a 3-byte palette entry (PALDAT) | 7 | Does not fit | Does not fit |

So at 2× the copper can change a pixel register at every cell at PRI 1, if spec 4 has a register that acts at the pixel and takes one to three bytes per change (open point C2). Without WAITs, a run of MOVEs changes a register every slot, 2.7 pixels apart, which does not line up with 1× cells. Spectrum-style colours per cell are the attribute layer's job (spec 4, Spectrum extras), at no copper cost. The copper cannot read per-cell bytes from an SRAM table, as retro68k's cannot.

## 9. Spectrum extras

The copper has no Spectrum extras of its own. It reaches the attribute layer (custom `0x130`–`0x13F`, spec 4) only with MOVEF, two words per byte. It cannot reach port `0xFE`: to change the border colour it writes BGCOLOR, which `0xFE` also sets (spec 4). A BGCOLOR write shows from the start of a line's picture, not mid-line as a port `0xFE` write does (spec 4, section 7.2). The Spectrum screen layout is a copper list (section 8.1).

## 10. FPGA resources

| Item | Estimate |
|------|----------|
| PC (21 bits), two-word prefetch buffer, pre-decode of instruction lengths, decode | About 150 LUTs |
| Beam compare (10-bit line and pixel), P and B | About 50 LUTs |
| X, Y, the flags, the 8-bit ALU, the conditions | About 80 LUTs, 20 flip-flops |
| R0–R7 (8 × 8) and the stack (8 × 21) | About 100 LUTs: retro68k's first build found R0–R7 needs three read ports, so flip-flops, not distributed RAM |
| Colour assembly buffer (2 bytes), register bus master | About 30 LUTs, 20 flip-flops |
| Control and status registers, RESUME, PRI to the scheduler | About 60 LUTs, 80 flip-flops |
| Total | About 500–600 LUTs, 250 flip-flops; no block RAM. retro68k's 16-bit copper's first build is about 1,100 LUTs |

## 11. Test plan

- **Encodings:** every instruction and form against a Python copper model; every reserved encoding stops with ERR and COPPC at it; `0xFFFF` stops with ERR.
- **Reach:** MOVE to `0x000`–`0x0EF`; MOVR to `0x000`–`0x0FF` (writes to `0x0F0`–`0x0FF` ignored); MOVEF to every block up to `0x3FF`, the copper's own registers included; nothing reaches the system block.
- **Macros:** `CMOVEW`, `CMOVEA`, `CMOVEL` and `CMOVEN` emit MOVEs below `0x0F0` and MOVEFs above, low byte first; `CMOVE` above `0x0EF` is an assembly error.
- **Direct writes:** each MOVE's byte takes effect when it is written, in any order; a CPU write between two copper MOVEs to one register lands between them and the last write to each byte wins; a colour's blue and green MOVEs change nothing until its red, with a WAIT or other MOVEs between them, through BGCOLOR and PALDAT; a CPU colour write between them does not mix with the copper's buffer.
- **Waits:** WAIT and SKIP on blank and picture lines, at pixels 0, 143, 144 and 863; positions beyond the frame; the pixel-only forms on the current and the next line; B with each of the four DMA channels busy and all idle, including a job started by the MOVEF just before; line 1023 as the end of a list.
- **Pixel exactness:** golden images: palette writes after a WAIT land within a pixel of the WAIT's position, and a second prefetched MOVE within the next; a colour with its blue and green before the WAIT changes whole at the pixel.
- **When writes take effect:** pointer writes between a layer's last fetch and the line's end used as written for the next line; on a 2×-tall layer a pointer written after the first copy changes nothing until the next source line's rules allow (spec 4); spec 5's sprite rules (a CTL write starts a sprite, the vertical blank stops it, the other registers act from the next line) with the example of section 8.4.
- **Registers and ALU:** every ALU function and source, every flag result (carry and borrow at the 8-bit edges, N from bit 7), every condition, loads and stores of the flags, MOVR in all forms with X + 1 across a multi-byte register and the wrap from `0xFF`.
- **CALL and RET:** nesting to 8, overflow and underflow set ERR; the stack emptied at the frame restart, or kept with STKKEEP.
- **Rates and priority:** words counted on the SRAM model match section 5.2 for each example; at PRI 1, with the CPU at 20 MHz running a memory-heavy loop, every sprite fetching and the DMA engine busy, on a screen within the display budget, the copper gets every cycle 4; at PRI 0 it gets fewer, never ahead of non-urgent layer and sprite fetches; PRI 2 and 3 act as 1; the CPU never waits at any PRI; the display is never late because of the copper.
- **Register bus:** a copper write in the same clock as a CPU OUT goes first and lands on its pixel; the CPU's strobe moves one clock and its access still completes.
- **Strobes and lists:** COPJMP1 and COPJMP2 from the CPU and the copper (by MOVEF); COP1LC double buffering; the frame restart at beam (0, 0), in the same clock as VIDSTAT.VBLANK is set.
- **COPINT:** raises COPPER once per write, only with IRQEN; cleared by writing 1 to COPSTAT.IRQ.
- **RESUME:** a background list cut off at the frame restart mid-WAITB and between the bytes of a register carries on from the next instruction, with the bytes already written kept; without RESUME COP2LC is never changed.
- **Examples:** sections 8.1–8.4 run on the full-system simulation and match the model's images.

## 12. Open points

| # | Item |
|---|------|
| C1 | X and Y are 8 bits, as retro68k's are its data width: register codes and data, not SRAM pointers, since the copper reads no memory but its list. A shared "MOVR from (X)+" or a load of X or Y from an SRAM table (retro68k's C4) stays an open point for both machines |
| C2 | Per-cell colours (section 8.5) need a register that acts at the pixel and takes one to three bytes per change; spec 4 to say which, if any (the palette through PALDAT needs PALIDX too). Otherwise per-cell colour is left to the attribute layer |
| C3 | Audio (Q1) is to share cycle 4 with the copper and goes before it. When sound is specified, the PRI 1 rate becomes 320 words per line less audio's few. Proposed: accept |
| C4 | Closed: COPSTAT.LATE and OVER are dropped with the cycle-3 design. At PRI 1 the copper's rate is certain on screens within the budget, as retro68k's, which has no such bits |
| C5 | Closed: prefetch depth two words (branch 11) |
| C6 | Closed (design plan, branch 11): the copper writes registers directly, with no latch, as the CPU does (spec 3, rule 3). Only colours wait for their red byte, in the copper's own colour assembly buffer. A wide value no longer changes whole at one pixel, except a colour |
| C7 | Closed: the copper no longer shares cycle 3 with the sprites. Sprites are hard-deadline channels on cycles 1 and 3 (spec 5); the copper has cycle 4 at PRI 1 |
| C8 | MOVEF reaches the audio offsets (`0x240`–`0x2FF`); writes there do nothing until sound is decided (Q1) |
| C9 | Exact pixel delay from a WAIT to a palette change, and of the second prefetched MOVE (retro68k's C2: 0 pixels late in its simulation): to be confirmed in simulation |
| C10 | RESUME saves only the place (branch 11), as retro68k. With no latch, a cut-off register keeps the bytes already written and list 2 carries on with the next one. The colour buffer is not saved, so a background list that writes colours can mix with list 1's. Proposed: a background list writes no colours |
| C11 | COPCON.PRI 2 (nasty) is reserved and taken as 1, since the CPU never gives up a cycle it uses. A nasty mode here could only take the CPU's spare cycles, which PRI 1 already gets first. Proposed: as written |
| C12 | Copper register layout at `0x100`–`0x11F` (COPCON, COP1LC, COP2LC, the strobes, COPPC, COPSTAT, COPX, COPY, COPFLAGS, COPSP at `0x100`–`0x111`; COPR0–7 at `0x118`–`0x11F`) is this spec's choice. Closed: spec 3 lists it (section 5) |
