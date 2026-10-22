# Spec 6: Copper

Status: **draft**

## 1. Summary

The copper is a small coprocessor that follows the beam. Every frame it runs a program from SRAM and writes chipset registers at chosen beam positions: it changes colours partway down the screen, sets the bitmap's line address on every line (the Spectrum screen layout), opens split screens, and so on, without the CPU. It also has two pointers into SRAM, a counter and a loop instruction, so that per-line and per-cell effects take a short program and a table, not a list the size of the screen.

| Item | Value |
|------|-------|
| Program | 16-bit instruction words in SRAM (a few instructions take two words), restarted from COPLC at the start of every frame (draw-beam line 0) |
| Instructions | MOVE, MOVX (indirect move through X or Y), WAITV, WAITH, WAITD, SKIPV, LDC, LOOP, BRA, ADDX, ADDY, LDX, LDY, INT, STOP |
| Registers | Pointers X and Y (22-bit SRAM byte addresses), counter C (8 bits), wait target T (line, pixel). The CPU can read and write X, Y and C |
| Can write | Ports `0x30`–`0x9F` only (sound, video, sprites, copper). The encoding cannot name any other port |
| Beam position | Draw-beam coordinates (section 3), 10-bit line and pixel, pixel exact |
| Memory | Cycle 3 of every slot, first in line (before the display FIFOs and sprites), plus any cycle its owner leaves unused (spec 2). One 16-bit read per cycle |
| Guaranteed rate | One word every slot (143 ns): 4 MOVEs per 8-pixel cell at 2×, 2 in hi-res; 2 stepping MOVXs per cell at 2×, 1 in hi-res (section 5.3) |
| Prefetch | The next instruction word, and the data byte of a MOVX, are read while the copper waits, so the first write after a wait lands on the wait's pixel |
| Interrupt | The INT instruction raises request line COPPER (spec 8) |
| Ports | `0x90`–`0x9F` (section 6) |

## 2. What it keeps from retro68k

retro68k's copper (its spec 10) has 32-bit instructions, 16-bit X and Y, an ALU with flags, eight storage registers, conditional skips and CALL/RET. retro-z80 takes only what its effects need:

| retro68k | retro-z80 |
|----------|-----------|
| MOVE, WAIT, SKIP, JUMP, STOP | Kept, sized for 8-bit registers: MOVE is one 16-bit word; WAIT is split into line and pixel parts (section 4.3); JUMP is a relative BRA |
| MOVR (write through X, Y) | Replaced by MOVX: X and Y are **memory pointers**, and MOVX reads a byte through one and writes it to a port |
| ALU (ADD, SUB, AND, OR, CMP), flags, SKIPC | Replaced by a counter C with LOOP, and ADDX/ADDY to step the pointers back or on |
| R0–R7, CALL/RET, the second list, RESUME, PRI | Left out. A far jump is three MOVEs to COPPC; the copper always comes first in cycle 3 |
| Pixel-only WAIT | Kept in a deterministic form: WAITH and WAITD move a wait target (section 4.3) |

## 3. Beam positions and the draw beam

Positions are beam coordinates: line 0 is the start of vertical blank and the picture is lines 49–624; pixel 0 is the start of horizontal blank and the picture is pixels 144–863. The copper uses **all** 864 × 625 positions, blanking included.

The copper follows the **draw beam** of spec 4, not the display beam. The draw beam runs one output line ahead of the display beam and produces each pixel's final colour into the line buffer. A wait for (L, P) ends when the draw beam reaches the pixel that will be shown at (L, P), so a write made then lands on that pixel when it is shown, palette changes included.

- The copper compares against the draw position plus a fixed lead of a few clocks, equal to the delay from the end of a wait to the register write. So the first write after a wait acts from pixel P exactly.
- In real time, a copper position (L, P) comes about one line (32 µs) before the display beam shows it. The CPU's beam position registers (spec 4) report the display beam, so a CPU that reads the beam just after a copper interrupt at (L, P) sees about line L − 1.
- The frame restart (section 6.3) happens when the draw beam reaches (0, 0).

**When writes take effect** (as for the CPU's writes, spec 4, section 4.7):

| Registers | Take effect |
|-----------|-------------|
| **Fetch registers:** BMCTL, BMADDR, BMSTRIDE, BMSCRX, BMSCRY, BMHEIGHT, TLCTL, TLMAP, TLTILE, TLSCRX, TLSCRY, ATCTL, ATADDR, ATSTRIDE, ATSCROLL, the windows | Copied at the start of the layer's next output-line fetch, at draw beam (L, 0). A value committed before (L, 0) acts on line L; one committed at or after it, from line L + 1. To change line L, write during line L − 1 |
| The same, on a **288-line layer** | Its pairs are fetched only on the first line; the second is replayed from the repeat buffer, so a write has no effect on a pair's second line. To change the pair starting at L, write during draw lines L − 2 or L − 1 |
| **Pixel registers:** VIDCTL, BGCOL, PALIDX, PALDAT, BMBANK, TLBANK | At the draw beam, from the pixel where the write lands, on both lines of a 288-line pair |
| **Sprite attributes** (spec 5, section 4.4) | A write committed while the draw beam is on line N at pixel 16 or later is used from line N + 3 (pixels 0–15: line N + 2 or N + 3; avoid). To reuse a sprite from line M, write its new attributes after a wait for (M − 3, 16), all committed before (M − 2, 0) |

## 4. Instructions

Instructions are 16-bit words at even addresses, stored little-endian (low byte at the even address), so a Z80 assembler's `DW` builds them. A few take a second word.

```
 MOVE   0 | p (14-8) | data (7-0)                       port = 0x30 + p, p = 0x00-0x6F
 MOVX   1 0 | R | I | 0 | W (10-7) | p (6-0)            port = 0x30 + p
 CTRL   1 1 | op (13-10) | v (9-0)
```

| op | Name | v | Words | Does |
|----|------|---|-------|------|
| 0 | WAITV | line | 1 | T = (v, 0); wait until the beam reaches T |
| 1 | WAITH | pixel | 1 | T = (T.line, v); wait until the beam reaches T |
| 2 | WAITD | lines | 1 | T = (T.line + v, T.pixel); wait until the beam reaches T |
| 3 | SKIPV | line | 1 | Skip the next instruction if the beam's line ≥ v |
| 4 | LDC | n (7-0) | 1 | C = n |
| 5 | LOOP | offset | 1 | C = C − 1; if C ≠ 0, branch |
| 6 | BRA | offset | 1 | Branch |
| 7 | ADDX | s | 1 | X = X + s |
| 8 | ADDY | s | 1 | Y = Y + s |
| 9 | LDX | address 21-16 (5-0) | 2 | X = address; the second word holds address bits 15–0 |
| 10 | LDY | as LDX | 2 | Y = address |
| 11 | INT | 0 | 1 | Set COPSTAT.IRQ (section 6.4) |
| 12 | STOP | 0 | 1 | Stop until the next frame restart or a write to COPPC |
| 13–15 | – | | | Reserved |

Offsets (LOOP, BRA) and s (ADDX, ADDY) are signed 10-bit values (−512 to +511). A branch goes to the address after the instruction plus 2 × offset, so programs are relocatable. Bits shown as 0 must be 0.

**Why 16-bit words.** A memory cycle reads 16 bits, and the copper gets about one cycle per slot. A MOVE needs a 7-bit port number (112 ports, `0x30`–`0x9F`) and 8 bits of data, which with one opcode bit is exactly 16 bits, so the most common instruction costs one fetch. With 32-bit instructions every MOVE would cost two fetches and the per-cell rates of section 5.3 would halve. Only the instructions that carry a 22-bit address take a second word; they are rare and used outside the time-critical parts.

### 4.1 MOVE

Writes the 8-bit data to port `0x30` + p. p from `0x70` to `0x7F` is reserved. Ports `0x30`–`0x3F` (sound) are reserved until sound is decided: writes there do nothing.

**Multi-byte registers.** The copper follows the latch rule of spec 3 (lower bytes are latched, the write to the highest byte commits the whole value), with **its own latch**, separate from the CPU's, so that a CPU write between two copper MOVEs never mixes with them. The copper latch holds 2 bytes. Rule: write a group's bytes low first and finish one group before starting another; MOVEs to single-byte registers and other instructions may come in between. A commit takes the lower bytes from the copper latch as it is.

### 4.2 MOVX: indirect move

Reads the byte at the address in pointer X (R = 0) or Y (R = 1) and writes it to port `0x30` + p.

| Field | Meaning |
|-------|---------|
| R | Pointer: 0 X, 1 Y |
| I | After the read, step the pointer by +1 |
| W | Pacing: 0 none. 1–15: before the write, T = (T.line, T.pixel + 2W), and wait until the beam reaches T |

A paced MOVX reads its data first and then waits, so its write lands exactly on T.pixel. W = 8 steps 16 pixels (one 8-pixel cell at 2×); W = 4 steps 8 pixels (one cell in hi-res). If the beam has already passed T when the copper reaches the wait, the write is made at once and COPSTAT.LATE is set.

**Word buffer.** Each pointer has a buffer that keeps the last 16-bit word read through it. A MOVX whose byte lies in the buffered word uses it without a memory read, so a run of stepping MOVXs costs half a data read each. The buffer is dropped when its pointer moves to another word (LDX, ADDX, a write to the COPX ports, a step across a word), at every WAITV, WAITH and WAITD, and at the frame restart. A byte the CPU changes between the copper's reads of the two bytes of one word may be missed; double-buffer tables that change while the copper reads them.

MOVX can write the copper's own registers: loading C from a table gives a loop count per frame, and three MOVXs into COPPC make a jump through a table.

### 4.3 Waits and the target T

The copper holds a wait target T = (line, pixel). The beam has reached T when its line is greater than T.line, or equal with its pixel ≥ T.pixel. WAITV sets the line, WAITH the pixel, WAITD steps the line, and paced MOVXs step the pixel. Waits are measured from the previous target, not from where the beam is, so a program that is a little late does not drift.

- `WAITV L` then `WAITH P` waits for (L, P). The macro `CWAIT L,P` makes the pair.
- `WAITD d` repeats the same pixel d lines later: one instruction per line in a loop.
- T.pixel 864 or more is reached at the start of the next line. T.line is 10 bits; a WAITD above 1023 gives 1023. A line of 625 or more is never reached: the copper waits until the frame restart (the usual end of a program, like STOP).
- After the frame restart T = (0, 0).

While it waits, the copper reads the next instruction word and, if that is a MOVX needing a new word, its data. Then it uses no memory cycles until the wait ends.

### 4.4 SKIPV, LOOP and BRA

- **SKIPV L** compares the beam's line (not T) with L. With BRA it makes loops that end at a line.
- **LOOP** is the Z80's DJNZ: LDC 0 gives 256 passes. With one counter, a second level of loop uses SKIPV and BRA (example 7.4).

### 4.5 Pointers

X and Y are 22-bit physical SRAM byte addresses, as for every chipset unit (spec 2): bits above 21 are ignored, and bit 21 on a 2 MB board. ADDX and ADDY add a signed 10-bit step and wrap at 22 bits. LDX and LDY load a whole address. The frame restart does not change X, Y or C, so the CPU can leave values in them.

### 4.6 Errors

A reserved encoding (MOVE with p ≥ `0x70`, MOVX with bit 11 set, CTRL op 13–15, a non-zero bit shown as 0) stops the copper and sets COPSTAT.ERR; COPPC then points at it. The copper cannot write outside `0x30`–`0x9F`. A program address wraps like a pointer.

## 5. Memory and timing

### 5.1 Memory cycles

The program, the tables read by MOVX, and the second words of LDX/LDY are all in SRAM. The copper reads 16 bits per memory cycle:

- **Cycle 3** of every slot, first in line. The order in cycle 3 is: copper; a display FIFO below its low mark (urgent); sprites; display top-up.
- Any spare cycle: a cycle 0, 1 or 2 its owner leaves unused, which also goes to the copper first (spec 2, section 4.3). These come often but are not guaranteed.
- At 28 MHz the CPU sometimes takes cycle 3 for a read and gives back its next cycle (the swap, spec 2, section 4.2). The copper keeps its one cycle per slot, but that access comes one cycle (35.7 ns, about one beam pixel) later.

A copper that never waits can take every cycle 3, leaving sprites only the spare cycles of others, and can make an urgent display FIFO late (OVERRUN, spec 4). Keep busy runs short, or plan the line's budget with spec 4's and spec 5's figures. The sprite fetch has 216 cycle-3 cycles per line less what the copper and urgent display fetches take; set SPRLIMIT (spec 5, section 5.2) from the copper's cost per line (section 5.2) so that the sprites shown do not depend on timing.

### 5.2 Cost of each instruction

| Instruction | Fetches (16-bit reads) |
|-------------|------------------------|
| MOVE, WAITV, WAITH, WAITD, SKIPV (not skipping), LDC, ADDX, ADDY, INT, STOP, LOOP not taken | 1 |
| MOVX | 1, plus 1 data read, or none from the word buffer: 1.5 on average when stepping |
| LDX, LDY | 2 |
| LOOP or BRA taken, SKIPV skipping | 2 (the prefetched word is thrown away) |

A wait costs nothing while it waits. The write itself goes over the register bus, not to memory. The copper has priority on the register bus: if it and the CPU want it in the same clock, the copper goes first and the CPU's I/O strobe moves one clock later, which its I/O cycle has room for (spec 1, sections 4.2 and 6). So a copper write is never delayed and lands on its pixel.

### 5.3 Throughput and the guaranteed rate

Cycle 3 comes every 143 ns. An 8-pixel cell is 16 beam pixels (593 ns, 4.15 slots) at 2× and 8 beam pixels (296 ns, 2.07 slots) in hi-res. Any 593 ns holds at least 4 cycle 3s, any 296 ns at least 2. At 28 MHz the swap can move one of them 35.7 ns later, out of the window, so the count in a single cell may be one lower; it is made up in the next cell, since the copper never loses a cycle per slot.

| | Fetches needed | Per 2× cell (593 ns) | Per hi-res cell (296 ns) | Per line (32 µs) |
|-|----------------|----------------------|--------------------------|------------------|
| Guaranteed fetches | | 4 | 2 | 224 |
| MOVE | 1 | 4 | 2 | 224 |
| Paced MOVX, stepping | 1.5 | 2 | 1 | 149 |
| Paced MOVX, no reuse | 2 | 2 | 1 | 112 |

**Guaranteed rate:** with the copper first in cycle 3, these rates hold on any screen, whatever the CPU, display and sprites do. Free cycles of other owners make it faster, but plan with these figures. The fetches for the next MOVX (its word and data) overlap the wait of the current one, so the copper works one cell ahead of its writes. That lead covers a cycle 3 moved by the swap: the paced rates hold cell by cell, not only on average. The hi-res MOVX without reuse has no margin (2 of 2.07 fetches per cell, and the swap can delay one): test it (open point C6).

Other figures at the guaranteed rate: the horizontal blank (144 pixels, 5.3 µs) holds 37 fetches; the vertical blank (49 lines) about 11,000.

**On time after a wait:** the next word (and a MOVX's data) is prefetched while waiting, so the first write after WAITV/WAITH/WAITD lands on the wait's pixel; each further write needs its own fetch, one slot (about 4 pixels) apart at worst, or one cycle more after a swap. To change a 2- or 3-byte register exactly at a pixel, write its lower bytes before the wait and the commit byte after it. Where every write must land on its own pixel, use paced MOVXs.

## 6. Registers

Ports `0x90`–`0x9F`. Multi-byte values: low byte at the lowest port, committed on the highest (spec 3). The copper can write all of them.

| Port | Name | Access | Bits | Description |
|------|------|--------|------|-------------|
| `0x90` | COPCTRL | RW | EN (0) | 1: copper on. Clearing it stops the copper at once |
| `0x91` | COPSTAT | R, W1C | WAITING (0), STOPPED (1), ERR (2), IRQ (3), LATE (4), OVER (5) | Bits 0–1 read only. Bits 2–5 sticky, write 1 to clear |
| `0x92` | COPC | RW | 7–0 | Counter C |
| `0x93`–`0x95` | COPLC0–2 | RW | 21–1 | Program start address, loaded at each frame restart. Bit 0 ignored |
| `0x96`–`0x98` | COPX0–2 | RW | 21–0 | Pointer X |
| `0x99`–`0x9B` | COPY0–2 | RW | 21–0 | Pointer Y |
| `0x9C` | – | | | Reserved: reads 0, writes ignored |
| `0x9D`–`0x9F` | COPPC0–2 | RW | 21–1 | Read: the address of the instruction being run (or that stopped the copper). Write: the commit makes the copper continue there at once, if EN is set |

### 6.1 Status bits

| Bit | Set when |
|-----|----------|
| WAITING | The copper is in a wait |
| STOPPED | After STOP, an error, EN cleared, or after reset |
| ERR | A reserved encoding was met (section 4.6) |
| IRQ | An INT was run |
| LATE | A paced MOVX found the beam already past its target |
| OVER | The frame restart came while the copper was neither stopped nor waiting: the program ran over the frame |

### 6.2 CPU access

The CPU can read and write X, Y, C and COPPC at any time; a CPU write lands between two copper instructions. While the copper runs, X or Y may change between the reads of their bytes: read them while the copper is stopped or waiting. A CPU write to COPX or COPY drops that pointer's word buffer. Let one side own each register: if the copper writes a register, the CPU changes the program or its table, not the register.

### 6.3 Starting, stopping and the frame restart

- After reset all copper registers are 0 and EN is 0.
- With EN set, the copper starts at the next frame restart. A write to COPPC starts it at once at that address.
- **Frame restart**, when the draw beam reaches (0, 0) with EN set: PC = COPLC, T = (0, 0); the prefetched word, the word buffers and the copper latch are dropped; OVER is set if the program was still running. X, Y and C are kept.
- Changing COPLC takes effect at the next frame restart, so a program can be double-buffered: build the next one, then write its address to COPLC.
- Writes for the coming picture go in the 49 blank lines (0–48) before it.

### 6.4 Interrupt

The copper raises request line **COPPER** while COPSTAT.IRQ is set; spec 8 assigns its number, vector and enable. The handler clears it by writing 1 to COPSTAT.IRQ. A second INT before that changes nothing.

## 7. Examples

Port names are spec 4's and spec 5's. Macros: `CMOVE`, `CMOVX`, `CWAITV`, `CWAITH`, `CWAITD`, `CWAIT`, `CSKIPV`, `CLDC`, `CLOOP`, `CBRA`, `CADDX`, `CADDY`, `CLDX`, `CLDY`, `CINT`, `CSTOP`, in `firmware/include/copper.inc`. `CMOVX port,X+,16` is a MOVX through X with I set and pacing of 16 pixels.

### 7.1 Spectrum screen layout

The bitmap as in spec 4, section 10.3: 256×192, 1 bit, 2×, 288 lines, window 248–760 × 145–529, BMSCRY = 0. Picture line k is the pair starting at beam line 145 + 2k. A BMADDR value committed before a line's fetch (draw beam (L, 0)) restarts the layer at that address (spec 4, section 5.2), so writing BMADDR before every pair sets every line's address. For line k it is committed during draw line 144 + 2k, the line before its pair (section 3).

BMADDR0–2 (`0x55`–`0x57`) is committed by the write to BMADDR2, so all three bytes are written on every line, high byte last; without that write the two lower bytes would stay in the copper's latch and change nothing. The CPU builds a table of 192 two-byte entries, the low and middle bytes of `screen + ((k & 0xC0) << 5) + ((k & 7) << 8) + ((k & 0x38) << 2)`. The 6 KB screen must not cross a 64 KB boundary, so the high byte is the same on every line and comes from a MOVE, not the table. Colours come from the attribute layer (8×8 cells, ATADDR = screen + 6144), with no copper work.

```
        CLDX    spec_lines          ; 192 x 2 bytes, word-aligned
        CLDC    192
        CWAIT   144,760             ; line before picture line 0's pair
line:   CMOVX   BMADDR0,X+          ; low byte (latched)
        CMOVX   BMADDR1,X+          ; middle byte, same word: no read
        CMOVE   BMADDR2,screen>>16  ; high byte: commits, before (145+2k, 0)
        CWAITD  2                   ; the line before the next pair
        CLOOP   line
        CSTOP
```

Cost: 7 fetches per two lines. A Spectrum game's screen code then works unchanged on its 6912 bytes.

### 7.2 Colour gradient

Palette entry SKY changes on every line from 200 to 455, from a table of 256 colours, two bytes each in spec 4's format (section 3.3: low byte green and blue, high byte red). PALDAT holds the low byte; the high-byte write changes the entry and steps the index, so the index is set again on every pass (which also resets PALDAT's byte flip-flop). The low byte is written before the wait and the high byte, the prefetched MOVX after it, changes the entry at pixel 0 of its line.

```
        CLDX    sky                 ; 256 x 2 bytes
        CLDC    0                   ; 256 passes
        CWAIT   199,0
loop:   CMOVE   PALIDX0,SKY & 255   ; palette index, 9 bits ...
        CMOVE   PALIDX1,SKY >> 8    ; ... committed
        CMOVX   PALDAT,X+           ; low byte (green, blue): held
        CWAITD  1                   ; next line, pixel 0
        CMOVX   PALDAT,X+           ; high byte (red): the entry changes here
        CLOOP   loop
        CSTOP
```

### 7.3 Split-screen scroll

A horizontal scroller: the tile layer (288 lines, full screen, window from line 49, TLSCRY = 0) scrolls in X with the game above a status panel in map rows 30–31. With TLSCRY = 0, map y = layer line (spec 4, section 6.1), so rows 30–31 are picture lines 240–255: beam lines 529–560, from the pair starting at 529. The CPU does not patch the program: it writes the 2 bytes of the game's X scroll to `scroll` in SRAM during its frame, and the copper picks them up in the vertical blank, so the scroll changes once per frame, in step with the picture. TLSCRX is a fetch register: the panel's value is committed during line 528, the line before its pair, so it acts from (529, 0) (section 3).

```
        CLDX    scroll              ; X low, X high
        CMOVX   TLSCRX0,X+
        CMOVX   TLSCRX1,X+          ; commits: acts from line 49
        CWAIT   528,760
        CMOVE   TLSCRX0,0           ; panel: no scroll ...
        CMOVE   TLSCRX1,0           ; ... committed before (529, 0)
        CINT                        ; tell the CPU the panel has started
        CSTOP
```

Parallax bands are the same with a loop over a table of X scrolls, 2 bytes per band: `CLDC 8` / `CWAIT 80,760` / `band: CMOVX TLSCRX0,X+` / `CMOVX TLSCRX1,X+` / `CWAITD 32` / `CLOOP band`. Each wait is on the line before a pair (81, 113, …: odd lines, as pairs start at 49); a band of 32 beam lines is 16 picture lines. The bitmap's scroll, BMSCRX and BMSCRY, works the same way; a write of BMSCRY also restarts the bitmap's line count (spec 4, section 5.2).

### 7.4 Per-cell colours from a byte table

The same Spectrum-size 1-bit bitmap, but with the attribute layer off (VIDCTL.ATEN = 0, so BMBANK is used): the copper writes BMBANK (`0x54`) at every 8-pixel cell from a 32 × 24 byte table. For a 1-bit bitmap, index = BMBANK × 2 + pixel (spec 4, section 3.1), so a cell byte picks a pair of colours as a Spectrum attribute does. BMBANK is a pixel register: it acts at the draw-beam pixel, on both lines of a pair (the repeat buffer holds pixel values before the bank), so the copper writes every beam line: 16 beam lines per row of cells, the same 32 bytes each time (X stepped back by 32), then the next row. One counter counts the lines; SKIPV ends the rows.

```
        CLDX    cells               ; 32 x 24 bytes, one per cell
        CWAITV  144
row:    CLDC    16                  ; 16 beam lines = 8 picture lines
line:   CWAITH  232                 ; one cell before the window (passed: no wait)
        CWAITD  1                   ; next line, pixel 232
        REPT    32
        CMOVX   BMBANK,X+,16        ; cells at pixels 248, 264, ... 744
        ENDR
        CADDX   -32                 ; back to the row's first byte
        CLOOP   line
        CADDX   32                  ; next row of cells
        CSKIPV  528                 ; last row done (beam on line 528): leave
        CBRA    row
        CSTOP
```

The program is 45 words (90 bytes); as plain MOVEs it would be 12,288. Cost per line: 32 × 1.5 + 6 = 54 fetches of 224, 1.5 of the 4 guaranteed per cell. What this gives beyond the hardware attribute layer: cells of any height (`CLDC 4` and a 32 × 96 table gives 8×2 cells), a table with any layout or stride, colours that scroll by moving X each frame, banks on the tile layer at the same time (2 MOVXs per cell fit at 2×), or palette entries per cell. In hi-res, `CMOVX BMBANK,X+,8` changes each 8-pixel cell (1.5 of 2 fetches). The copper takes about 54 cycle-3 cycles on each of these lines, so SPRLIMIT (spec 5, section 5.2) should be at most about 216 − 54 − the display's urgent cycles, for example 150; the reset value 192 leaves only 24.

## 8. FPGA resources

| Item | Estimate |
|------|----------|
| PC (21 bits), prefetch word, instruction decode | About 100 LUTs |
| X and Y with step adders, two word buffers | About 120 LUTs, 90 flip-flops |
| T, its adders and the beam compare; SKIPV compare | About 80 LUTs, 20 flip-flops |
| C, the copper latch, port-group table (from `fpga/regmap.def`), register bus | About 80 LUTs |
| Total | About 400 LUTs, 200 flip-flops; no block RAM |

## 9. Test plan

- **Encodings:** every instruction against a Python copper model; every reserved encoding stops with ERR and COPPC at it.
- **Waits:** WAITV/WAITH/WAITD targets on blank and picture lines; T.pixel ≥ 864; WAITD saturation; lines ≥ 625 wait to the restart.
- **Pixel exactness:** golden line-buffer images: palette and bank changes at chosen pixels land on that pixel (first write after a wait, and every paced MOVX), at 2× and hi-res.
- **Fetch registers:** a line address or scroll write during line L − 1 acts on line L; on a 288-line layer, a write on the first line of a pair does not change the second.
- **Loops and pointers:** LOOP with C = 1, 0 (256); BRA both ways; SKIPV; ADDX/ADDY wrap at 22 bits and at 21 on a 2 MB board; LDX/LDY.
- **Word buffer:** reads counted on the SRAM model: half a read per stepping MOVX; dropped at waits, pointer loads and CPU writes.
- **Latch:** copper and CPU writing different multi-byte registers interleaved never mix bytes.
- **Rates:** examples 7.1–7.4 (and 7.4 in hi-res, with and without reuse) with 32 sprites, the CPU at 28 MHz (so with swaps) and a full display budget: LATE never set.
- **Register bus:** a copper write in the same clock as a CPU OUT goes first and lands on its pixel; the CPU's strobe moves one clock and its write still arrives.
- **Sprite reuse:** spec 5's multiplexing example: attributes written after (M − 3, 16) act from line M.
- **Status and control:** frame restart (OVER, X/Y/C kept), COPPC write jumps at once, EN cleared stops at once, INT raises COPPER once until cleared.

## 10. Open points

| # | Item |
|---|------|
| C1 | Closed: the examples use spec 4's and spec 5's ports and timing rules |
| C2 | The copper's own 2-byte latch and its port-group table: to be agreed with spec 3's latch rule |
| C3 | The copper first in cycle 3 can make an urgent display FIFO late; sprites are protected by SPRLIMIT (spec 5). If this bites, add a COPCTRL bit that limits the copper to every other cycle 3 |
| C4 | Word buffer coherence with CPU writes (section 4.2): accepted for now |
| C5 | One counter: nested loops use SKIPV. A second counter would cost about 20 LUTs if a program needs it |
| C6 | Hi-res MOVX without reuse has no margin, less with the 28 MHz swap; confirm in simulation |
| C7 | Pacing steps in units of 2 pixels (2–30); whether 1-pixel steps are needed |
| C8 | Writes to `0x30`–`0x3F` do nothing until sound (Q1) is decided |
