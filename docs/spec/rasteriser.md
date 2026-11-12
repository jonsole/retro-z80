# Spec 19: Rasteriser

Status: **draft, version 1**. Written on 11 November 2026 (ticket #110) with the wrapper, on retro-hw's rasteriser core ([spec](../../fpga/retro-hw/docs/spec/raster.md), revision 1), shared with retro68k, whose spec 17 is the same design with 32-bit registers. retro68k made its choices without review by its user (open point RA1); retro-z80 follows them.

The rasteriser draws lines and flat-filled triangles into a bitmap in SRAM, from screen coordinates, while the Z80 carries on with other work. Each pixel is the blitter's logic function (the minterm, spec 14, section 3.1) of a pattern bit A, a constant colour B and the bitmap's old pixel C, and only pixels inside a clip window are written. It is programmed as the blitter is: job registers laid out as a descriptor, chains of descriptors in SRAM, START, RUN and STOP. It is a separate unit beside the blitter, and the two can run at the same time. Like the blitter it uses only memory cycles that nobody else wants, so it never slows the Z80 (design plan, branch 11).

It closes spec 14's open point D3. The third core of retro-hw's redesign, `geom` (3D points), is not built here; the geometry unit (spec 15) does the Z80's 3D arithmetic, and the rasteriser draws what it gives.

## 1. Summary

| Item | Value |
|------|-------|
| Jobs | LINE: a line between two points. TRI: a filled triangle. One at a time; a job may chain to a next descriptor |
| Programming | A job written straight into the job registers, or chains of 32-byte **descriptors** (laid out as those registers) in SRAM |
| Coordinates | Signed 16-bit whole pixels, x to the right, y down |
| Pixel formats | 1, 2, 4 or 8 bits per pixel, packed as the blitter's |
| Colour | A constant, through D = minterm(A, B, C): B the colour, C the old pixel, A a 16-bit pattern along a line (all ones in a triangle) |
| Clipping | A window (RASCLIPMIN, RASCLIPMAX), inclusive, shared by every job. Nothing outside it is written |
| Reach | **SRAM only**, by physical address: MMU page × `0x2000` + offset (section 3.2) |
| Memory cycles | The free pool only, after the blitter (section 6). **The CPU is never slowed** |
| Time | A line: about 0.5 µs to start, then about 100 ns a pixel written. A triangle: about 1.5 µs to start, then each row 40 ns and each memory word of its span 60 ns or more (section 9; not measured yet) |
| Starting | The CPU (ports or the register page), or the copper (MOVEF) |
| Finishing | DMXINT.RAS and interrupt source 4 (BLT, shared with the blitter) at the end of a chain and after any job that asks; BUSY and ERR in RASSTAT; the copper's WAIT B waits for it |
| Registers | Custom block `0x180`–`0x1B3`, and DMXINT, DMXINTEN at `0x230`, `0x234`, shared with the blitter (spec 3, section 5.9) |
| Enable | DMACON.BLTEN with DMACON.DMAEN, as the blitter (spec 4). There is no bit of its own |
| Core | retro-hw's `raster` (section 10), wrapped in `fpga/rtl/dmx.v` beside the blitter |

**Against the Amiga.** The Amiga's blitter draws a line once the CPU has worked out the octant, the Bresenham terms and the first word's address; it fills an area by drawing outlines one pixel a row into a spare plane and running a fill blit over them. Here the rasteriser takes the two or three points, clips to a window in hardware and fills a triangle directly, with no gaps or doubled pixels between triangles that share an edge. The 16-bit line pattern and the minterms are the Amiga's.

## 2. Comparison with retro68k

The rasteriser is retro68k's (its spec 17, version 1) in every field, bit and rule, except these:

| Item | retro68k (spec 17) | retro-z80 | Why |
|------|--------------------|-----------|-----|
| Registers | 32-bit, big-endian | 8-bit, low byte first, each byte written directly (spec 3, rule 2); the same bit numbers | Z80: 8-bit ports |
| Descriptors | Eight big-endian long words | Eight 4-byte words, **low byte first**, as the registers | The Z80 and the SRAM are little-endian (spec 2, section 8.4). An image of a descriptor in memory is also an image of the job registers |
| Register offsets | Job `0x340`–`0x35C`; RASDESC `0x360`, RASCMD `0x364`, RASSTAT `0x368`; RASCLIPMIN `0x36C`, RASCLIPMAX `0x370`; DMXINT `0x3F0`, DMXINTEN `0x3F4` | Job `0x180`–`0x19F`; RASDESC `0x1A0`, RASCMD `0x1A4`, RASSTAT `0x1A8`; RASCLIPMIN `0x1AC`, RASCLIPMAX `0x1B0`; DMXINT `0x230`, DMXINTEN `0x234` | The custom block is 1 KB (spec 3); the blitter's layout (spec 14) |
| RASDESC | 32-bit register | 3 bytes; reading the low byte captures all three (spec 3, rule 4) | It changes by itself as a chain runs |
| Reserved bits | RASCTRL's are an error; in the other job registers they are ignored and read back as written | RASCTRL's are an error too, and are stored but **read 0**. In the other job registers they are not stored and read 0 | `dmx.v` keeps only the bits the core uses, as for the blitter (spec 14, section 2) |
| Addresses | CPU addresses in Chip RAM; 22 bits used | Physical: MMU page × `0x2000` + offset; 22 bits used (section 3.2) | Z80: 64 KB address space; chipset units do not use the MMU windows (spec 2) |
| Memory cycles | Requester 6 (RAS), with an owner bit (6) in MEMSLOT0–4; the DMA port moves to 7 and loses its owner bit | Requester 6 (RAS), the DMA port 7, as there. The free pool only: no owner bit, since the slot plan is fixed (spec 2, section 5.2) | The Z80 never waits for memory (design plan, branches 11 and 25) |
| Copper | MOVE | MOVEF, one byte per instruction (section 8.2) | Copper MOVE reaches offsets `0x000`–`0x0EF` only (spec 6) |
| Interrupt | Source 4, BLT, shared with the blitter, default level 4 | Source 4, BLT, shared with the blitter, fixed priority; IM 2 vector VECBASE + 8 (spec 8) | IM 2 on one /INT line |
| Triangles | Always built | A build option, `DMX_TRI`: 1 on the KS3; 0 on the KS2, lines only (section 10) | The KS2's LUTs, with sound (spec 13) |
| Planar layers | Drawn a plane at a time | Not needed | Layers are chunky only (branch 11) |
| Reset | Every reset and the 68000's RESET instruction | Every reset (spec 7) | The Z80 has no RESET instruction |
| Time | From the core's design (its section 8) | The same: the same core, clock and memory cycle (section 9) | – |

## 3. The job

A job is eight 4-byte words: the **job registers**, or a 32-byte **descriptor** in SRAM at an even address, which the rasteriser loads into them. Each word is stored low byte first, in the registers and in a descriptor alike. The clip window is not part of a job (section 4).

| Register | Descriptor | Name | Bits | Meaning |
|----------|------------|------|------|---------|
| `0x180` | `+0x00` | RASCTRL | see below | Options, the colour and MINTERM |
| `0x184` | `+0x04` | RASP0 | Y 15–0, X 31–16, both signed | Point 0: a line's start |
| `0x188` | `+0x08` | RASP1 | Y 15–0, X 31–16 | Point 1: a line's end |
| `0x18C` | `+0x0C` | RASP2 | Y 15–0, X 31–16 | Point 2, for a triangle. A line ignores it |
| `0x190` | `+0x10` | RASDPT | ADDR 23–0 | The byte holding pixel (0, 0) of the bitmap |
| `0x194` | `+0x14` | RASSTRIDE | DSTRIDE 15–0, signed | Bytes from one row of the bitmap to the next |
| `0x198` | `+0x18` | RASPAT | PATTERN 15–0 | LINE: A for each pixel in turn, from bit 15, going round. `0xFFFF` for a solid line. A triangle ignores it: its A is 1 |
| `0x19C` | `+0x1C` | RASNEXT | ADDR 23–0 | The next descriptor's address; 0 for none |

So a point's Y is its low two bytes and X its high two: RASP0 is RASP0_0 (Y bits 7–0), RASP0_1 (Y bits 15–8), RASP0_2 (X bits 7–0), RASP0_3 (X bits 15–8). In memory, a point is two 16-bit words, Y then X (`dw y,x`).

**RASCTRL bits:**

| Bits | Byte | Name | Meaning |
|------|------|------|---------|
| 7–0 | RASCTRL0 | VALUE | The colour, in its low bits (as many as the pixel has): B for every pixel |
| 9–8 | RASCTRL1 | BPP | 0 = 1, 1 = 2, 2 = 4, 3 = 8 bits per pixel |
| 12 | RASCTRL1 | IRQ | Set DMXINT.RAS when this job ends (section 7.3) |
| 16 | RASCTRL2 | TRI | 0 = LINE, 1 = TRI |
| 17 | RASCTRL2 | NOLAST | LINE: the last pixel (at point 1) is not drawn, so joined lines don't draw a corner twice |
| 31–24 | RASCTRL3 | MINTERM | The logic function of A, B and C (section 3.1) |

BPP, IRQ and MINTERM are where BLTCTRL has them, and RASNEXT where BLTNEXT is.

**RASCTRL's other bits (23–18, 15–13, 11–10) are reserved: write 0. A job with any of them set is an error** (section 7.4). They are stored, so a descriptor that sets one is refused, but they read 0. So a blitter descriptor given to the rasteriser by mistake is refused if it has RTL, BCONST or a key mask set, and the bits stay free for later versions. The blitter treats its own reserved bits differently (open point RA2).

In the other job registers, bits not listed are reserved: write 0. They are not stored and read 0 (bits 31–24 of RASDPT and RASNEXT, bits 31–16 of RASSTRIDE and RASPAT). They are not an error.

### 3.1 The minterm

Each bit of a pixel's new value D is MINTERM's bit number A × 4 + B × 2 + C, exactly as in the blitter (spec 14, section 3.1), with:

- **A:** the pattern's bit for this pixel of a line; 1 for every pixel of a triangle.
- **B:** VALUE's low bits, the same for every pixel.
- **C:** the pixel's old value in the bitmap.

| MINTERM | D = | Use |
|---------|-----|-----|
| `0xCC` | B | Draw in the colour. A line's pattern has no effect |
| `0xCA` | A ? B : C | A dashed line: the colour where the pattern is 1, the bitmap left alone where it is 0 |
| `0xC0` | A ? B : 0 | A dashed line on colour 0 |
| `0x66` | B XOR C | Draw and undraw with the same job (rubber bands, cursors). Use NOLAST for joined lines |
| `0xEE`, `0x88` | B OR C, B AND C | Set or keep bits of a pixel |
| `0x55` | NOT C | Invert |

In a triangle only MINTERM's high four bits matter (A is 1).

Unlike BLTVALUE (spec 14, section 3.2), VALUE is one pixel's colour, not a word of pixels, so it has no byte order to mind: colour 5 at any depth is VALUE 5.

### 3.2 The bitmap

RASDPT is the byte holding pixel (0, 0), and row y starts DSTRIDE × y bytes after it. Pixels are packed from the most significant end of each byte, as everywhere in this machine (spec 4; spec 14, section 3.3). So for a layer's bitmap RASDPT is the layer's pointer and DSTRIDE its bytes a row.

- **Physical addresses.** RASDPT and RASNEXT are in the MMU's page numbering (spec 2, section 9.3): page × `0x2000` + offset within the page, as the blitter's (spec 14, section 4). They do not go through the MMU windows.
- **SRAM only.** Only the low 22 bits of an address are used. There is no range check: an address past 4 MB wraps round into the SRAM, and on a 2 MB board the top half mirrors the bottom (spec 2, section 11). Bits 23–22 are stored but not used. The rasteriser never reaches the registers, the palettes, the boot ROM or the ports.
- **Negative coordinates are real places.** Pixel (−1, 0) is the pixel before (0, 0) in memory. Whether they are drawn is the window's business, not the bitmap's.
- **A bitmap that is the wrong way up** (row 0 at the highest address) has a negative DSTRIDE and RASDPT at its last row.
- **To draw into part of a bitmap with its own origin** (a window on the screen), point RASDPT at that part's pixel (0, 0); if that pixel is not at a byte's start (depths under 8 bits), add the odd pixels to every x instead.

## 4. The clip window

Two registers, written by the CPU or the copper, shared by every job. They are not part of a descriptor: a chain runs under one window.

| Offset | Port | Name | Bits | Meaning |
|--------|------|------|------|---------|
| `0x1AC`–`0x1AF` | `0xAC11`–`0xAF11` | RASCLIPMIN | YMIN 15–0, XMIN 31–16, both signed | The window's first row and first column |
| `0x1B0`–`0x1B3` | `0xB011`–`0xB311` | RASCLIPMAX | YMAX 15–0, XMAX 31–16, both signed | Its last row and last column: the window includes them |

- **Only pixels inside the window are written**: XMIN ≤ x ≤ XMAX and YMIN ≤ y ≤ YMAX. Points may lie anywhere; the shape is the same whatever the window is, and the window only decides which of its pixels are written.
- **The window is the only thing that keeps a job inside its bitmap.** There is no address check. Set it to the bitmap, or to a smaller box to clip to a window on the screen.
- A window with XMAX < XMIN or YMAX < YMIN draws nothing.
- Writes are ignored while RASSTAT.BUSY. The registers are not reset: they are 0 after power-on, a window of the one pixel (0, 0).

## 5. What is drawn

### 5.1 LINE

The pixels of the line from point 0 to point 1 are those of Bresenham's algorithm, stepping one pixel along the longer axis each time, starting at point 0 with the error term at half the longer length (rounded down). Both ends are drawn, unless NOLAST leaves out point 1.

- A line with both ends beyond the same side of the window is skipped whole, at no cost.
- Otherwise **every pixel is stepped**, written or not, and those inside the window are written. So a line's pixels inside the window are the same whatever the window is, but a line that runs far outside it costs time (section 9): software should cut very long lines down roughly first.
- The pattern moves on one bit for every pixel stepped, written or not.
- Pixels are written one at a time, in order. With a minterm that reads C, a pixel that two joined lines both draw is combined twice: with XOR it would come out undrawn. NOLAST on each line of a polyline leaves the shared corners to the next line.
- A line and the same line reversed may differ by a pixel, where the error term is exactly on a tie.

### 5.2 TRI

The three points may be given in any order. The rasteriser sorts them by y, divides for the three slopes, and fills row by row.

| Rule | |
|------|--|
| Rows | From the top point's y up to, not including, the bottom point's y |
| An edge from (xa, ya) down to (xb, yb) | Its slope is s = floor((xb − xa) × 65536 ÷ (yb − ya)), and its x in row y is X = xa × 65536 + s × (y − ya): a fixed-point number with 16 fraction bits |
| A row's span | Between the long edge (top to bottom) and the short edge for that row (top to middle above the middle point's y, middle to bottom from it): the pixels x with ceil(X_left ÷ 65536) ≤ x < ceil(X_right ÷ 65536) |
| Clipping | Rows outside the window are stepped without writing; a span is cut to the window's columns |

So:

- two triangles that share an edge fill every pixel along it exactly once (no gaps, and nothing doubled under XOR);
- a triangle's bottom row and right-hand edge pixels are left for its neighbours, as in most rasterisers;
- a triangle with no area draws nothing;
- the result does not depend on the order of the points;
- each pixel is written once, so any minterm works. A span is written a memory word at a time.

Other filled shapes are chains of triangles: a convex polygon of n corners is a fan of n − 2.

### 5.3 The exact result

This is the definition the test model (`sim/rastest/rmodel.py`) follows; it is the core's (retro-hw's raster spec, section 4.5). A pixel (x, y) is at bit position 8 × (RASDPT + y × DSTRIDE) + x × bits, where bit position n means bit 7 − (n mod 8) of the byte at address n div 8. Byte addresses are taken modulo 4 MB.

```
bits = 1 << BPP

plot(x, y, A):
    if XMIN ≤ x ≤ XMAX and YMIN ≤ y ≤ YMAX:
        C = the pixel at (x, y);  B = VALUE's low bits
        each bit j:  D[j] = MINTERM[4 × A + 2 × B[j] + C[j]]
        the pixel at (x, y) becomes D

LINE (TRI = 0):  (x0, y0) = RASP0, (x1, y1) = RASP1
    dx = |x1 − x0|;  dy = |y1 − y0|
    sx = +1 if x1 ≥ x0 else −1;  sy = +1 if y1 ≥ y0 else −1
    xmajor = (dx ≥ dy);  major = max(dx, dy);  minor = min(dx, dy)
    err = major div 2;  (x, y) = (x0, y0)
    for i = 0 .. major:
        if not (NOLAST and i = major):
            plot(x, y, PATTERN[15 − (i mod 16)])
        err = err − minor
        if err < 0:
            err = err + major
            step the minor axis (y by sy if xmajor, else x by sx)
        step the major axis (x by sx if xmajor, else y by sy)

TRI (TRI = 1):
    sort RASP0, RASP1, RASP2 by y:  (xt, yt), (xm, ym), (xb, yb)
    slope(a, b) = floor((xb − xa) × 65536 / (yb − ya))       # only for yb > ya
    for y = yt .. yb − 1:
        XL = xt × 65536 + slope(t, b) × (y − yt)              # the long edge
        XS = xt × 65536 + slope(t, m) × (y − yt)   if y < ym  # the short edge
             xm × 65536 + slope(m, b) × (y − ym)   otherwise
        left = ceil(min(XL, XS) / 65536);  right = ceil(max(XL, XS) / 65536)
        for x = left .. right − 1:  plot(x, y, 1)
```

- **What is written.** Only bytes that hold a plotted pixel are written. In such a byte, the other pixels keep their value.
- **Reads.** The old word is read first when MINTERM depends on C (its bits 7, 5, 3, 1 differ from bits 6, 4, 2, 0; in a triangle only bits 7–4 count), or when the write covers only part of a byte (depths under 8 bits; a span's ends).

### 5.4 Worked examples

**A line** from (2, 1) to (9, 4): dx 7, dy 3, x is the longer axis, the error term starts at 3. The pixels, in order:

```
(2,1) (3,1) (4,2) (5,2) (6,3) (7,3) (8,4) (9,4)
```

With RASPAT `0xF0F0` the first four pixels have A = 1 and the next four A = 0; with MINTERM `0xCA` only the first four are drawn.

**A triangle** with points (10, 2), (3, 6), (14, 9), in any order. Sorted: top (10, 2), middle (3, 6), bottom (14, 9). Slopes: the long edge 4/7 (`0x0000_9249`), top to middle −7/4 (`0xFFFE_4000`), middle to bottom 11/3 (`0x0003_AAAA`).

| Row y | Pixels x |
|-------|----------|
| 2 | none (both edges at x = 10) |
| 3 | 9 to 10 |
| 4 | 7 to 11 |
| 5 | 5 to 11 |
| 6 | 3 to 12 |
| 7 | 7 to 12 |
| 8 | 11 to 13 |

Row 9, the bottom point's, is not drawn: a triangle below, sharing that point or edge, draws it.

**Registers** for that triangle in colour 5 on a 320 × 200, 8 bpp bitmap at physical `0x010000`, as 4-byte values (each stored low byte first):

| Register | Value |
|----------|-------|
| RASCLIPMIN, RASCLIPMAX | `0x00000000`, `0x013F00C7` (0, 0 to 319, 199) |
| RASCTRL | `0xCC010305` (MINTERM `0xCC`, TRI, BPP = 3, VALUE 5) |
| RASP0, RASP1, RASP2 | `0x000A0002`, `0x00030006`, `0x000E0009` |
| RASDPT, RASSTRIDE | `0x010000`, 320 |
| RASNEXT | 0 |

then RUN to RASCMD. With MINTERM `0x66` instead, running it twice restores the bitmap. Both examples are directed tests (section 11).

## 6. Memory cycles

The rasteriser is requester 6 (RAS) of the memory scheduler (spec 2, section 5.1; retro-hw's `dmac`), straight after the blitter (5) and before the DMA port (7).

- **The free pool only**, as the blitter (spec 14, section 5): cycle 4 and every cycle its owner leaves. The free order is: the copper at PRI 1, then by number: layers, sprites, audio, the copper, the CPU, the blitter, **the rasteriser**, the DMA port.
- **No priority over the CPU.** The rasteriser never takes the CPU's cycles 0 and 2: they are locked to it. The slot plan is fixed (spec 2, section 5.2), so the rasteriser owns no cycle. The Z80 never waits for SRAM.
- **Beside the blitter.** It takes its turn after the blitter's requests. Both ask for a cycle only now and then (the blitter uses a quarter to a third of the free pool, spec 14, section 7), so each still gets most of what it asks for while the other runs.
- **One memory cycle** reads or writes 2 bytes at an even address, with byte selects for single bytes (spec 2, section 8.4).
- **A descriptor** takes 16 read cycles (32 bytes) to load.
- **A pixel of a line** is one write, after one read where section 5.3 says. **A triangle's row** is one write for each memory word (16 bits at an even address) the span touches, after one read where needed: at 8 bpp with a minterm that does not read C, no reads at all when the span starts and ends on word boundaries, and one or two a row otherwise.
- While DMACON.BLTEN or DMACON.DMAEN is clear, a running job waits before its next memory access, and RASSTAT.BUSY stays set.

## 7. Registers

Custom block offsets (spec 3, section 5.9). From the CPU: port = (offset bits 7–0) << 8 | (`0x10` + offset bits 9–8), used with `LD BC,port` then `OUT (C),r` or `IN r,(C)`; `INC B` steps to the next register byte. In the register page the rasteriser is at offset + `0x1000`. The copper reaches it with MOVEF (section 8.2). Multi-byte values are low byte first, and each byte is written directly (spec 3, rule 2). Reserved offsets read `0xFF` and ignore writes (spec 3, rule 11). Names are from `hw.inc` (spec 3, section 8).

| Offset | Port | Name | Width | Access | Bits | Meaning | Reset |
|--------|------|------|-------|--------|------|---------|-------|
| `0x180`–`0x19F` | `0x8011`–`0x9F11` | RASCTRL … RASNEXT | 8 × 4 | RW (ignored while BUSY) | Section 3 | The job registers | 0 at power-on; not reset |
| `0x1A0`–`0x1A2` | `0xA011`–`0xA211` | RASDESC | 3 | RW (ignored while BUSY), CAP | ADDR 23–0 | The descriptor START loads. Read: the descriptor running, or the last one loaded. Bit 0 and bits 23–22 are not kept (read 0). Reading `0x1A0` captures all three bytes (spec 3, rule 4) | 0 |
| `0x1A4` | `0xA411` | RASCMD | 1 | S | START (0), RUN (1), STOP (2) | Section 7.1. Reads 0 | – |
| `0x1A8` | `0xA811` | RASSTAT | 1 | R | BUSY (0), ERR (2) | Section 7.2 | 0 |
| `0x1AC`–`0x1B3` | `0xAC11`–`0xB311` | RASCLIPMIN, RASCLIPMAX | 2 × 4 | RW (ignored while BUSY) | Section 4 | The clip window | 0 at power-on; not reset |
| `0x230` | `0x3012` | DMXINT | 1 | W1C | BLT (0), RAS (1) | Shared with the blitter (spec 14, section 8). RAS is set when a rasteriser job with IRQ ends, and whenever the rasteriser stops: the chain's end, STOP, an error. Write 1 to a bit to clear it | 0 |
| `0x234` | `0x3412` | DMXINTEN | 1 | RW | BLT (0), RAS (1) | Interrupt enables | 0 |

`0x1A3`, `0x1A5`–`0x1A7` and `0x1A9`–`0x1AB` are reserved; so are `0x169`–`0x17F` and `0x1B4`–`0x22F` round the rasteriser's block. Bytes `0x193`, `0x196`–`0x197`, `0x19A`–`0x19B` and `0x19F` hold no bits of their registers' fields but are part of them: they read 0. Bits 7–2 of DMXINT and DMXINTEN, and the bits of RASSTAT not listed, read 0.

**The job registers** can be written while the rasteriser is idle; writes are ignored while BUSY. A descriptor load overwrites all eight. They hold the job as loaded or written, so after a job, writing only what changes and RUN starts a similar one: for a polyline, RASP0 and RASP1; for a triangle fan, one point. The copper can do the same.

**Writing a whole job from memory:** the job registers are in address order with the low byte first, so a loop of `OUT`s (or `LDIR` into the register page) of a 32-byte descriptor image writes every register correctly. A descriptor in SRAM started with RASDESC and START needs only 4 register writes.

### 7.1 RASCMD

| Bit | Name | Meaning |
|-----|------|---------|
| 0 | START | Load the descriptor at RASDESC into the job registers and run it. Ignored while BUSY |
| 1 | RUN | Run the job already in the job registers. Ignored while BUSY. START wins over RUN |
| 2 | STOP | End the job after the pixel (LINE) or row (TRI) in hand; the chain is not followed, and the job cannot be resumed. BUSY clears and DMXINT.RAS is set. Ignored while idle |
| 7–3 | – | Reserved, write 0 |

Either way, at the end of each job with RASNEXT not 0, RASDESC becomes RASNEXT and that descriptor is loaded and run. BUSY is set by the write of START or RUN, so a status read or a copper WAIT with B straight after it already sees the job.

### 7.2 RASSTAT

| Bit | Name | Meaning |
|-----|------|---------|
| 0 | BUSY | A job or a chain is running, or waiting for DMACON.BLTEN |
| 2 | ERR | The last job stopped on an error (section 7.4). Cleared by the next START or RUN |
| 7–3, 1 | – | 0 |

BUSY is bit 0, so a polling loop is `IN A,(C)`, `RRA`, `JR C`, as for BLTSTAT.

### 7.3 Interrupts and DMACON

**DMACON** (spec 4): the blitter's bit, **BLTEN**, with DMAEN, also lets the rasteriser use memory cycles. While either is clear a running job waits before its next memory access (BUSY stays set), and a job started then waits too. There is no separate enable.

**Interrupts:** the rasteriser shares the blitter's source, **4 (BLT)**, of the interrupt controller (spec 8), IM 2 vector VECBASE + 8. The request is (DMXINT.BLT and DMXINTEN.BLT) or (DMXINT.RAS and DMXINTEN.RAS). The handler reads DMXINT to see which, and clears each flag by writing 1 to it. A flag that comes due in the same clock as a write of 1 that clears it **stays set**: no interrupt is lost (spec 14, section 8.3). Sources 5–7 are unused.

### 7.4 Errors

A reserved bit set in RASCTRL (section 3) is an error, and so is a TRI job in a build without triangles (`DMX_TRI = 0`, section 10). It is found before the job writes anything: the job and the chain end, BUSY clears, ERR and DMXINT.RAS are set, nothing is written, and RASDESC still names the descriptor (unchanged, for a job started with RUN). Addresses are not checked (section 3.2).

### 7.5 Reset

Every reset (spec 7) makes the rasteriser idle with no memory request: RASDESC is 0, and ERR, DMXINT and DMXINTEN are clear. The job registers and the clip window are not reset; they are 0 after power-on.

### 7.6 The blitter and the rasteriser at once

They are separate units with their own registers, descriptors and memory requests, and neither waits for the other. Nothing stops them writing the same memory: where their destinations overlap, the order of the writes is not specified. A program that clears a screen with the blitter and then draws on it with the rasteriser waits for the blitter first (BLTSTAT.BUSY, its interrupt, or a copper WAIT with B).

## 8. Starting and waiting

### 8.1 From the CPU

1. Set the window once (RASCLIPMIN, RASCLIPMAX).
2. One job: wait until BUSY is clear, write the job registers that change (RASNEXT = 0 for a single job), then RUN (`0x02`) to RASCMD.
3. A chain (a mesh, a polygon, a frame of wire-frame lines): write descriptors to SRAM, the first one's address to RASDESC, then START (`0x01`).
4. Carry on. Take the interrupt, or poll RASSTAT.BUSY.

```
; Draw a line from (x0,y0) to (x1,y1). HL points at four 16-bit words:
; y0, x0, y1, x1 (RASP0 then RASP1, low byte first). RASCTRL, RASDPT,
; RASSTRIDE, RASPAT, RASNEXT and the window are already set. The registers
; are custom offsets 0x180-0x1A8: page 0x11, so C stays 0x11 and only B
; changes. Names from hw.inc (spec 3, section 8).

line:       ld   bc,RASSTAT_P
.wait:      in   a,(c)
            rra                       ; BUSY into carry
            jr   c,.wait
            ld   b,high RASP0_P       ; the first point register
.next:      ld   a,(hl)
            out  (c),a
            inc  hl
            inc  b
            ld   a,b
            cp   high RASP2_P
            jr   nz,.next             ; 8 bytes: RASP0, RASP1
            ld   b,high RASCMD_P
            ld   a,RASCMD_RUN_M
            out  (c),a
            ret                       ; HL points at the next line's ends
```

The worked triangle of section 5.4 as a descriptor in SRAM, to be started with RASDESC and START, or chained from another job's RASNEXT:

```
            align 2
tri:        dd   0xCC010305           ; RASCTRL: MINTERM 0xCC (D = B), TRI, 8 bpp, colour 5
            dw   2,10                 ; RASP0: Y, X
            dw   6,3                  ; RASP1
            dw   9,14                 ; RASP2
            dd   0x010000             ; RASDPT: pixel (0,0) of the bitmap
            dd   320                  ; RASSTRIDE
            dd   0                    ; RASPAT (not used by a triangle)
            dd   0                    ; RASNEXT: end of chain
```

### 8.2 From the copper

The rasteriser's registers are past `0x0EF`, so the copper writes them with **MOVEF** (spec 6), one byte per instruction of two words, as it does the blitter's (spec 14, section 9.2). Set a job up while the rasteriser is idle (writes are ignored while BUSY), and let one of the CPU and the copper own the rasteriser at a time, so their bytes never mix. Keep a strobe (START or RUN) out of the middle of a multi-byte value, so that a list cut off and run again never starts a job twice (spec 6).

| Copper work | MOVEFs | Words read | Time, at one word per slot |
|-------------|--------|------------|----------------------------|
| RUN alone (the job registers already set) | 1 | 2 | 0.2 µs |
| START of a descriptor in SRAM (RASDESC, then START) | 4 | 8 | 0.8 µs |
| A new line: RASP0, RASP1, then RUN | 9 | 18 | 1.8 µs |

```
        CWAIT  100,0
        CMOVEF RASDESC0,low DESC              ; DESC: a descriptor in SRAM
        CMOVEF RASDESC1,high DESC
        CMOVEF RASDESC2,DESC>>16
        CMOVEF RASCMD,RASCMD_START_M
        CWAITB 0,0                             ; wait until both units are idle
```

### 8.3 The copper's B bit

A WAIT with the **B** bit waits until the blitter **and** the rasteriser are idle (spec 6). The two units give the copper one signal, IDLE = neither BLTSTAT.BUSY nor RASSTAT.BUSY:

- IDLE goes low with the write of START or RUN to either unit, so a WAIT with B straight after the MOVEF that wrote it waits for that job or chain.
- IDLE goes high when both are idle: each chain ended (its last write made), stopped, or stopped with an error.
- A job waiting for DMACON.BLTEN is not idle.
- A build without the blitter and the rasteriser (the KS2's `GEOM = 1`) is always idle.

## 9. Time

From the core's design (retro-hw's raster spec, sections 4.4 and 4.7), in 10 ns clocks, as retro68k gives them (its spec 17, section 8); a memory access also waits for its cycle, 20 ns or more. Not measured in this machine yet (open point RA4).

| Step | Time |
|------|------|
| Descriptor load (START, or a chain) | 16 read cycles: about 1 µs |
| Set-up and the first row's address | About 25 clocks: 0.25 µs |
| TRI: the sort and the three slopes | About 110 clocks: 1.1 µs |
| LINE: each pixel stepped | 2 clocks; if it is written, about 6 more and its memory accesses |
| TRI: each row | 4 clocks, and for each memory word of the span about 4 clocks and its memory accesses |

So a triangle pays about 1.5 µs before its first pixel, and then fills at 8 bpp at up to about 25 MB/s, as a blitter fill does; many tiny triangles are slow, and a few pixels may be quicker as a line. A line pixel takes about 100 ns (150 ns where it reads first).

**Long lines.** A line's end far outside the window costs 20 ns for each pixel stepped there: up to 1.3 ms for an end at ±32767. Software clips long lines roughly first, for example to a box a few times the window's size; the hardware does the exact clip.

A line pixel outside the window is stepped in one clock, as retro-hw's raster spec (its section 4.4) gives; a pixel inside takes its write and then a clock to step.

## 10. FPGA resources

| Item | Resource |
|------|----------|
| The core (`raster.v`) | Lines only (`TRI` 0): about 770 LUTs alone in Vivado on the KS2's part (+0.3 ns of slack at 100 MHz). With triangles: about 1,410 LUTs (+0.6 ns); 1,825 LUTs and 781 flip-flops by Yosys (retro-hw's raster spec, R6) |
| The job registers (8 × 32 bits, only the used bits kept, RASCTRL whole), the clip window (8 bytes) and the control registers | Flip-flops in `dmx.v`, driving the core's job ports directly |
| The scheduler's eighth requester | A wider multiplexer in `dmac.v` |
| Block RAM, DSP | None |

**Builds.** The KS3 builds triangles (`DMX_TRI = 1`). The KS2 builds lines only (`DMX_TRI = 0`: a TRI job is an error), to make room for sound (spec 13; design plan, branch 21; open point RA3). The KS2's `GEOM = 1` build leaves the blitter and the rasteriser out (`DMX = 0`): their registers are then not answered (read `0xFF`), and they count as idle (spec 15, section 8).

### 10.1 Shared core

The rasteriser is retro-hw's `raster` ([spec](../../fpga/retro-hw/docs/spec/raster.md), revision 1), in `fpga/retro-hw/rtl/raster.v`: the descriptor load, the chain, the Bresenham stepper, the sort, the serial divider for the slopes, the span walk, the clip and the minterm. `fpga/rtl/dmx.v` wraps it beside the blitter, as retro68k's `dmx.v` narrowed to bytes.

| Parameter | Value | Why |
|-----------|-------|-----|
| AW | 21 | Word addresses: 4 MB of SRAM |
| LE | 1 | The SRAM is little-endian (spec 2, section 8.4) |
| TRI | `DMX_TRI`: 1 on the KS3, 0 on the KS2 (section 10) | Triangles are about half the core |

The wrapper keeps this spec's registers (section 7): the job registers as eight 32-bit words, stored a byte at a time from the register bus while the core is idle and a word at a time from a descriptor load; the clip window as 8 bytes; the core's job ports wired straight to their fields; RASDESC through the capture; RASCMD's strobes; RASSTAT; and DMXINT and DMXINTEN, shared with the blitter. It drives the core's `job_bad` from RASCTRL's reserved bits and ties `dl_wait` to 0. Neither core busy gives the copper's IDLE; either's interrupt flag, enabled, gives source 4. The core's memory port is the scheduler's RAS requester; it shares the read data bus with the blitter's.

## 11. Test plan

`sim/rastest` (`make -C sim rastest`), ported from retro68k's `rastest`, with little-endian descriptors and job registers:

- **Random:** chains of jobs from `rgen.py`, every byte of the simulated SRAM against the model of section 5.3 (`rmodel.py`), so also that nothing outside a window is written. Among them a LINE and a TRI for every depth, stride sign and kind of minterm (plain, through the pattern, with the old pixel, both, random); points inside the window, just outside and far outside; random patterns and NOLAST; flat and one-pixel shapes; windows at negative coordinates; bitmaps at any byte address; chains started by START and by RUN, with descriptors at any even address; the reserved bits of the job registers other than RASCTRL set at random (they must have no effect).
- **Byte order:** a descriptor and the job registers hold the same job, low byte first; a point is Y then X.
- **Registers:** the job registers, RASDESC and the window read back, each byte written on its own and in any order; reserved bits read 0, RASCTRL's included; RASDESC drops bit 0 and bits 23–22, and a read of its low byte captures all three; `LDIR` of a 32-byte image through the register page sets a job; reserved offsets (`0x1A3`, `0x1A5`–`0x1A7`, `0x1A9`–`0x1AB`, `0x1B4`–`0x22F`) read `0xFF`.
- **Directed:** the example line by RUN; the pattern through `0xCA`, NOLAST and the window's edge; the example triangle by START, the job registers then holding the descriptor; a chain with DMXINT.RAS only at its end, and after a job with IRQ.
- **Control:** writes to the job registers, RASDESC and the window ignored while BUSY; START and RUN ignored while BUSY; STOP mid-job, the chain not followed, DMXINT.RAS set; STOP while idle ignored.
- **Errors:** a reserved RASCTRL bit by RUN and in a chain, and a TRI job with `DMX_TRI = 0`: ERR, DMXINT.RAS, nothing written, RASDESC, ERR cleared by the next start.
- **Interrupts** (`sim/dmxint`): source 4 requested by DMXINT.RAS with DMXINTEN.RAS, and by BLT with its enable; each flag cleared by its own W1C bit; a flag due in the clock of the clearing write stays set.
- **Both units:** a blitter fill and a line running together, each with its right result.
- **Copper:** a job set up and started by MOVEFs; a WAIT with B waits for the rasteriser, for the blitter, and for both.
- **DMACON:** a job waits while BLTEN or DMAEN is clear, and finishes when it is set again.
- **Free cycles only:** with the CPU at 20, 2.5 and 3.57 MHz, the display, copper, sprites and blitter busy, the rasteriser never takes a cycle another user wanted.
- **Speed:** the times of section 9, in simulation.
- **On the KS2:** a test program draws the worked examples and chains of random lines and triangles (triangles if built), reads the bitmap back with the CPU and compares it with tables from `rmodel.py`, and reports over serial; and the same drawing on the screen, looked at through the HDMI capture.
- **The core** has its own tests in retro-hw (`test/raster`): every memory write against the same model, random waits, both byte orders, lines only (`TRI` 0), and the properties of section 5.2 (shared edges, point order).

## 12. Open points

| # | Item |
|---|------|
| RA1 | **retro68k's choices, not yet reviewed by its user**, which retro-z80 follows (retro68k's spec 17, Z1): (a) the wrapper lives in `dmx.v` beside the blitter's, sharing DMXINT and DMXINTEN; (b) its own requester, 6, with the DMA port moved to 7; (c) DMACON.BLTEN enables both units, with no bit of its own; (d) one interrupt source with the blitter, not one of its own (so source 5 is no longer kept for it); (e) the copper's WAIT B waits for both; (f) reserved RASCTRL bits are an error (RA2); (g) the descriptor layout: points together, the pattern a word of its own, the colour in RASCTRL's low byte; (h) the window as two corner points. If retro68k changes any of them, retro-z80 follows |
| RA2 | **A mismatch retro68k flagged:** the rasteriser treats a reserved RASCTRL bit as an error, but the blitter's wrapper ignores reserved bits (spec 14, D5). One rule for both units would be simpler; to settle with retro68k |
| RA3 | Closed (11 November 2026, #113): the KS2 builds lines only (`DMX_TRI = 0`), which saves about 640 LUTs for sound (spec 13); the KS3 builds triangles. The KS2 build's LUTs and timing with sound: spec 13, AU6 |
| RA4 | Measure the times of section 9 in simulation and on the KS2, alone and with the blitter and a display running |
| RA5 | Closed (11 November 2026): retro-hw's `raster.v` now resets the register that holds the old word (`creg`, retro-hw PR #18), so the first job after power-on may be any job; `rgen.py` no longer starts with a job that reads |
| RA6 | Closed (11 November 2026): the core steps a line pixel outside the window in one clock, as retro-hw's spec gives (retro-hw PR #18) |
| RA7 | A window per descriptor would let one chain draw into several windows. The core's descriptor has no room for it (retro-hw's raster spec, section 2.1) |
| RA8 | Shading, depth, and filled shapes other than triangles are not in this revision of the core (its R4). `geom` (3D points as a bus master) is not built here; the geometry unit (spec 15) serves the Z80 |
| RA9 | The fast3d flight (spec 15, section 10) should move its lines and clipping to LINE jobs, and filled faces to TRI jobs, and be timed again (spec 15, G1) |
