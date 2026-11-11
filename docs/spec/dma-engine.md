# Spec 14: Blitter

Status: **draft, version 2**. Rebuilt on 10 November 2026 (ticket #103) on retro-hw's redesigned blitter core ([spec](../../fpga/retro-hw/docs/spec/blitter.md), revision 2), shared with retro68k, whose spec 11 is the same design with 32-bit registers.

The blitter works on rectangles of pixels in SRAM: it copies, fills, combines and cuts out, while the Z80 carries on with other work. Each destination pixel is a logic function (the minterm) of a mask A, a source B and the destination's old contents C, as in the Amiga's blitter. A job can name a next job, so a list of jobs runs with no CPU in between. The blitter uses only memory cycles that nobody else wants, so it never slows the Z80, which never waits for memory (design plan, branch 11).

**What changed from version 1, and why.** Version 1 was a 4-channel DMA engine with BLIT, ADD, LINE and EDGES jobs, PAUSE, timer starts, CHERR and a line clip rectangle. Its shared core tried to do too much (retro-hw's own words): about 3,350 LUTs here. retro-hw split it into three cores: this one for rectangles; `raster` for lines and triangles (the rasteriser, spec 19); `geom` for 3D points. Both machines ported to the new blitter together (design plan, branch 21, 10 November 2026).

| Version 1 | Now |
|-----------|-----|
| 4 channels taking turns, at `0x140 + n × 0x40` | One blitter, one job at a time, with chains. Its registers are at `0x140`–`0x16B` |
| BLIT, ADD, LINE (OP 2), EDGES (OP 3); OP 6 and 7 reserved for 3D | BLIT only: there is no OP field. ADD is gone. Lines and triangles are the rasteriser's, a unit of its own beside the blitter (spec 19) |
| The line clip rectangle (CLIPXMIN–CLIPYMAX, `0x238`–`0x23F`) | Gone, with LINE. The rasteriser has its own clip window (spec 19, section 4) |
| CHCTRL with PAUSE; CHSTAT with DONE, ERR and PAUSED; CHERR | BLTCMD (START, RUN, STOP); BLTSTAT (BUSY, ERR). No pause, no error address |
| Timers starting channels (TMRn_CTRL.DMA, DMACH) | Gone: those bits are reserved (spec 9) |
| Interrupt sources 4–7, DMA0–DMA3 | Source 4, BLT, shared with the rasteriser (spec 19); 5–7 are unused |
| The custom registers, palettes, boot ROM and ports planned as later targets | Gone: a job reaches SRAM only, for good (section 4) |
| DESC (a whole job backwards) | RTL (each row right to left); rows bottom-up by negative strides |
| A and B shared a stride (ABSTRIDE) | A has its own (ASTRIDE) |
| VALUE 32 bits, also the key colour; a fill's 4-byte pattern | VALUE 16 bits (one memory word of pixels); KEY is its own field |
| A key pixel at 8 bpp was a byte not written | Every destination word of the row is written; C is read first when the minterm needs it |
| WIDTH 24 bits | WIDTH 16 bits (up to 65,535); longer jobs are rectangles or chains |

Software written for version 1 needs porting: the job layout, the control registers and the interrupt source all differ.

## 1. Summary

| Item | Value |
|------|-------|
| Jobs | One at a time. A job may chain to a next descriptor |
| Programming | A job written straight into the job registers, or chains of 32-byte **descriptors** (laid out as those registers) in SRAM |
| Operation | D = minterm(A, B, C), any of the 256, bit by bit |
| Pixel formats | 1, 2, 4 or 8 bits per pixel, source and destination alike, positioned to the pixel |
| A (the mask) | None (all ones), a 1 bpp image (not on the KS2), or B compared with a key colour |
| B (the source) | SRAM, or a constant word (a fill) |
| Direction | Left to right, or right to left (RTL) for overlapping copies; rows in either order, by the sign of the strides |
| Clipping | None: software trims the rectangle (section 3.5) |
| Reach | **SRAM only**, by physical address: MMU page × `0x2000` + offset (section 4) |
| Memory cycles | The free pool only: cycle 4 and every cycle its owner leaves (spec 2, section 4). **The CPU is never slowed.** |
| Speed | Expected about 25 MB/s for a fill and 17 MB/s for a copy, as retro68k measures the same core; to be measured here (section 7). The Z80's `LDIR` copies about 0.95 MB/s at 20 MHz |
| Starting | The CPU (ports or the register page), or the copper (MOVEF) |
| Finishing | DMXINT.BLT and interrupt source 4 (BLT) at the end of a chain and after any job that asks; BUSY and ERR in BLTSTAT; an idle signal, with the rasteriser's, for the copper's WAIT B |
| Registers | Custom block `0x140`–`0x16B` and `0x230`–`0x237` (spec 3, section 5.9). The rasteriser's are at `0x180`–`0x1B3` (spec 19), and it shares DMXINT and DMXINTEN |
| Enable | DMACON.BLTEN with DMACON.DMAEN (spec 4), which also enable the rasteriser |
| Core | retro-hw's `blitter` (section 10), wrapped by `fpga/rtl/dmx.v` |

## 2. Comparison with retro68k

The blitter is retro68k's (its spec 11, version 2) in every field, bit and rule, except these:

| Item | retro68k (spec 11) | retro-z80 | Why |
|------|--------------------|-----------|-----|
| Registers | 32-bit, big-endian | 8-bit, low byte first, each byte written directly (spec 3, rule 2); the same bit numbers | Z80: 8-bit ports |
| Descriptors | Eight big-endian long words | Eight 4-byte words, **low byte first**, as the registers | The Z80 and the SRAM are little-endian (spec 2, section 8.4). An image of a descriptor in memory is also an image of the job registers |
| Register offsets | Job `0x300`–`0x31C`; BLTDESC `0x320`, BLTCMD `0x324`, BLTSTAT `0x328`; DMXINT `0x3F0`, DMXINTEN `0x3F4` | Job `0x140`–`0x15F`; BLTDESC `0x160`, BLTCMD `0x164`, BLTSTAT `0x168`; DMXINT `0x230`, DMXINTEN `0x234` | The custom block is 1 KB (spec 3). DMXINT and DMXINTEN keep version 1's places |
| BLTDESC | 32-bit register | 3 bytes; reading the low byte captures all three (spec 3, rule 4) | It changes by itself as a chain runs |
| Reserved bits of the job registers | Ignored; read back as written | Not stored; read 0 | `dmx.v` keeps only the bits the core uses |
| Addresses | CPU addresses; 22 bits used | Physical: MMU page × `0x2000` + offset; 22 bits used (section 4) | Z80: 64 KB address space; chipset units do not use the MMU windows (spec 2) |
| Memory cycles | Spare cycles; the slot plan (MEMSLOT0–4) can make the blitter the owner of cycles, even the CPU's cycle 0 | The free pool only. The CPU's cycles 0 and 2 are locked to it | The Z80 never waits for memory (design plan, branch 11) |
| Copper | MOVE | MOVEF, one byte per instruction (section 9.2) | Copper MOVE reaches offsets `0x000`–`0x0EF` only (spec 6) |
| Interrupt | Source 4, BLT, default level 4 | Source 4, BLT, fixed priority; IM 2 vector VECBASE + 8 (spec 8) | IM 2 on one /INT line |
| The 1 bpp mask image | Built | Built on the KS3; **not on the KS2** (`DMX_MASKIMG = 0`): MASK = 1 is an error there | The KS2's LUTs (design plan, branch 21) |
| Planar layers | Drawn a plane at a time (its section 6.1) | Not needed | Layers are chunky only (branch 11) |
| Reset | Every reset and the 68000's RESET instruction | Every reset (spec 7) | The Z80 has no RESET instruction |
| VALUE's byte order | Bits 15–8 the even byte: pixel order and memory order agree (big-endian) | **Pixel order, not memory byte order**: the even byte takes bits 15–8 (BLTVALUE1, at `0x159`), the odd byte bits 7–0 (BLTVALUE0, at `0x158`), although the SRAM and the rest of the job are little-endian. A 2-byte pattern goes in swapped (section 3.2) | The core's `job_value` has the leftmost pixel in its top bits whatever the memory's byte order; confirmed in simulation |
| Speed | Measured in simulation (its section 8) | Not yet measured (open point D2) | – |

## 3. The job

A job is eight 4-byte words: the **job registers**, or a 32-byte **descriptor** in SRAM at an even address, which the blitter loads into them. Each word is stored low byte first, in the registers and in a descriptor alike.

| Register | Descriptor | Name | Bits | Meaning |
|----------|------------|------|------|---------|
| `0x140` | `+0x00` | BLTCTRL | see below | Options, KEY and MINTERM |
| `0x144` | `+0x04` | BLTBPT | ADDR 23–0, BIT 26–24 | The source B: the byte holding the first row's first pixel (with RTL, its last pixel: the first one worked on). BIT (BBIT): that pixel's place in its byte, in pixels from the most significant end (0–7 at 1 bpp, 0–3 at 2, 0–1 at 4, 0 at 8) |
| `0x148` | `+0x08` | BLTDPT | ADDR 23–0, BIT 26–24 | The destination D, which is also where C is read. As BLTBPT (DBIT) |
| `0x14C` | `+0x0C` | BLTSIZE | WIDTH 15–0, HEIGHT 31–16 | Pixels per row, and rows. Either 0 is an empty job |
| `0x150` | `+0x10` | BLTAPT | ADDR 23–0, BIT 26–24 | The mask image A (MASK = 1), 1 bpp: the byte holding the first row's first mask bit (with RTL, its last). BIT (ABIT): that bit, from the most significant end (0–7) |
| `0x154` | `+0x14` | BLTSTRIDE | DSTRIDE 15–0, BSTRIDE 31–16, both signed | Bytes from one row's start to the next, for D and for B |
| `0x158` | `+0x18` | BLTVALUE | VALUE 15–0, ASTRIDE 31–16 (signed) | VALUE: the constant B (BCONST), one memory word of pixels **in pixel order, not memory byte order**: the even byte takes bits 15–8 (BLTVALUE1), the odd byte bits 7–0 (BLTVALUE0), although the SRAM is little-endian (section 3.2). A fill of 8 bpp colour c is VALUE c × `0x0101`. ASTRIDE: the stride for A |
| `0x15C` | `+0x1C` | BLTNEXT | ADDR 23–0 | The next descriptor's address; 0 for none |

**BLTCTRL bits:**

| Bits | Byte | Name | Meaning |
|------|------|------|---------|
| 7–0 | BLTCTRL0 | KEY | The key colour for MASK = 2, in its low bits (as many as the pixel has) |
| 9–8 | BLTCTRL1 | BPP | 0 = 1, 1 = 2, 2 = 4, 3 = 8 bits per pixel |
| 10 | BLTCTRL1 | RTL | Work each row right to left (section 3.4) |
| 12 | BLTCTRL1 | IRQ | Set DMXINT.BLT when this job ends (section 8) |
| 13 | BLTCTRL1 | BCONST | B is VALUE, not memory (a fill) |
| 18–17 | BLTCTRL2 | MASK | Where A comes from: 0 none (every pixel 1), 1 the 1 bpp image at BLTAPT, 2 a compare of B with KEY (A is 1 where B differs), 3 an error |
| 31–24 | BLTCTRL3 | MINTERM | The logic function of A, B and C (section 3.1) |

Bits not listed are reserved: write 0. They are not stored and read 0, in BLTCTRL and in the pointers alike (bits 31–27 of BLTBPT, BLTDPT and BLTAPT; bits 31–24 of BLTNEXT). Address bits 23–22 are stored but not used (section 4).

### 3.1 The minterm

For each pixel of the job, the blitter works out D from three inputs, bit by bit, as the Amiga's blitter does:

- **A, the mask.** One bit per pixel, used for every bit of the pixel.
- **B, the source.** Read from BLTBPT, or VALUE with BCONST.
- **C, the background:** the destination's old contents, read from BLTDPT.

Each bit of D is MINTERM's bit number A × 4 + B × 2 + C, as the Amiga's minterm (LF7–LF0). So A = `0xF0`, B = `0xCC` and C = `0xAA`, and any expression of them gives its minterm (A ? B : C is (`0xF0` AND `0xCC`) OR (NOT `0xF0` AND `0xAA`) = `0xCA`):

| MINTERM | D = | Use |
|---------|-----|-----|
| `0xCC` | B | Copy; with BCONST, fill |
| `0xCA` | A ? B : C | Cookie-cut: draw B where the mask is 1, leave the background where it is 0 |
| `0xEE` | B OR C | Set bits |
| `0x88` | B AND C | Keep only the bits B has |
| `0x66` | B XOR C | Draw and undraw with the same job |
| `0x22` | C AND NOT B | Clear where B is set |
| `0x55` | NOT C | Invert an area |
| `0x00`, `0xFF` | 0, all ones | Clear or set an area |
| `0x0A` | A ? 0 : C | Clear through the mask (a shape's hole) |

With MASK = 0, A is 1 everywhere, so only MINTERM's high four bits matter.

**Version 1's jobs now:**

| Old job | Now |
|---------|-----|
| BLIT | The same MINTERM; DESC becomes RTL or negative strides (section 3.4) |
| FILL (BLIT with BCONST) | MINTERM `0xCC`, BCONST, VALUE the colour in every pixel of a word |
| KEYCOPY | MINTERM `0xCA`, MASK = 2, KEY the transparent colour |
| ADD | None: the CPU does it |
| LINE, EDGES | The rasteriser's LINE and TRI jobs (spec 19) |

### 3.2 The mask and the constant

- **MASK = 1, the image.** A's bits are packed from the most significant end of each byte, one a pixel, whatever BPP is. So a mask's rows are shorter than an 8 bpp source's, and A has its own stride (ASTRIDE). Not on the KS2: there MASK = 1 is an error.
- **MASK = 2, the key.** A is 1 where B's pixel differs from KEY's low bits and 0 where it matches. It costs no memory. With BCONST it compares VALUE's pixels.
- **VALUE, the constant B.** VALUE lies over every memory word of the destination (the two bytes at an even address): **bits 15–8 over the even byte, bits 7–0 over the odd byte**, and a pixel takes VALUE's bits at its own place in its word. This is pixel order, not memory byte order: the SRAM is little-endian, but VALUE is not. So a plain colour is the pixel value repeated to fill 16 bits (`0x5555` for colour 1 at 2 bpp; colour c × `0x0101` at 8 bpp, `0x0707` for colour 7), and a pattern in VALUE lines up with memory words, not with the rectangle's left edge.
- **A 2-byte pattern at 8 bpp**, such as a tile map entry (spec 4), goes into VALUE with its bytes swapped: the entry's low byte, which the Z80 stores at the even address, is VALUE's bits 15–8. So entry `0x1234` is VALUE `0x3412` (BLTVALUE0 = `0x12`, BLTVALUE1 = `0x34`), and the fill starts at an even address.

### 3.3 The exact result

This is the definition the test model follows (retro-hw's blitter spec, section 4.8). A bit position n means bit 7 − (n mod 8) of the byte at address n div 8, so positions run left to right through a row. Byte addresses are taken modulo 4 MB.

```
bits = 1 << BPP
for r = 0 .. HEIGHT − 1:                                  # rows in the order given
    pd = 8 × (BLTDPT.ADDR + r × DSTRIDE) + DBIT × bits
    pb = 8 × (BLTBPT.ADDR + r × BSTRIDE) + BBIT × bits
    pa = 8 × (BLTAPT.ADDR + r × ASTRIDE) + ABIT
    for i = 0 .. WIDTH − 1:                               # pixels in the order worked
        k = −i if RTL else i
        C = the pixel at bit position pd + k × bits       # bits wide
        B = VALUE's bits at (pd + k × bits) mod 16        if BCONST (bit 15 is place 0)
            the pixel at bit position pb + k × bits       otherwise
        A = 1                                             if MASK = 0
            the bit at bit position pa + k                if MASK = 1
            1 if B ≠ KEY's low bits, else 0               if MASK = 2
        for each bit j of the pixel:
            D[j] = MINTERM[4 × A + 2 × B[j] + C[j]]
        the pixel at pd + k × bits becomes D
```

- **What is written.** Only bytes that hold at least one pixel of a row are written. In such a byte, pixels outside the row keep their value.
- **Nothing else changes.** No word outside the destination rows is written, and A and B are never written.
- **Overlap.** The result above is what the blitter gives whenever no memory word is written before it is read as A or B for a later pixel (section 3.4). With an overlap worked the wrong way the result is not specified.

### 3.4 Direction

A copy whose source and destination overlap must not overwrite source pixels it has yet to read.

- **Rows.** The blitter always goes from the row the pointers name to the next by adding the strides. To work from the bottom row up, give the bottom row's addresses and negative strides.
- **Within a row.** With RTL the blitter works each row from its last pixel to its first: the pointers and their BIT fields name the row's last pixel, and words are taken in falling address order.

| Destination is | Use |
|----------------|-----|
| To the left of the source, or above it | The job as it is |
| To the right, in the same rows | RTL |
| Below | Rows bottom-up (negative strides) |

The result is the same in either direction when source and destination don't overlap. A stride of 0 repeats the same row.

### 3.5 Shapes of jobs

**Linear jobs** (memcpy, memset): BPP = 8, HEIGHT = 1, WIDTH = the length in bytes, up to 65,535. A longer one is a job with equal widths and strides (for example WIDTH = BSTRIDE = DSTRIDE = 16,384, HEIGHT = the number of 16 KB blocks), or a chain. (Strides are signed: 32,767 at most.)

**Rectangles** (blits): WIDTH × HEIGHT pixels, with each row starting a stride after the last. A, B and D have their own strides, so an image can be copied out of a sheet of images into a screen of another width, through a 1 bpp mask sheet with shorter rows.

**Clipping is done by software.** To draw only part of an image (an object partly off the screen), trim the job before starting it, keeping the strides as they are:

- **Left edge:** skip k pixels: move BLTBPT and BLTDPT on by k pixels (bytes, plus BBIT and DBIT below 8 bpp), BLTAPT by k bits (bytes plus ABIT), and subtract k from WIDTH.
- **Right edge:** subtract the pixels past the edge from WIDTH.
- **Top edge:** skip r rows: add r × ASTRIDE to BLTAPT, r × BSTRIDE to BLTBPT and r × DSTRIDE to BLTDPT, and subtract r from HEIGHT.
- **Bottom edge:** subtract the rows past the edge from HEIGHT.
- If WIDTH or HEIGHT reaches 0, the object is off the screen: the job does nothing.

With RTL, or rows bottom-up, the pointers name the other end, and the same trims apply from that end.

### 3.6 Worked examples

A 320-pixel-wide, 8 bpp bitmap at physical `0x010000` (stride 320) in each case, as in retro68k's spec. CTRL is BLTCTRL as a 32-bit value; `0x300` is BPP = 3.

| Job | Registers |
|-----|-----------|
| Fill the 32 × 16 rectangle at (40, 20) with colour 7 | CTRL `0xCC002300` (MINTERM `0xCC`, BCONST), VALUE `0x0707`, WIDTH 32, HEIGHT 16, DPT `0x010000` + 20 × 320 + 40, DSTRIDE 320 |
| Copy a 32 × 32 image at `0x020000` (stride 32) to (100, 50) | CTRL `0xCC000300`, BPT `0x020000`, BSTRIDE 32, DPT `0x010000` + 50 × 320 + 100, DSTRIDE 320, WIDTH 32, HEIGHT 32 |
| The same, with colour 0 transparent | As the copy, with CTRL `0xCA040300` (MINTERM `0xCA`, MASK = 2, KEY 0) |
| An 8 × 8 character from a 1 bpp font at `0x030000` (one byte a row) in colour 15 at (8, 8); KS3 only | CTRL `0xCA022300` (MINTERM `0xCA`, MASK = 1, BCONST), APT `0x030000` + 8 × character, ASTRIDE 1, VALUE `0x0F0F`, DPT `0x010000` + 8 × 320 + 8, DSTRIDE 320, WIDTH 8, HEIGHT 8 |
| Scroll the whole 320 × 200 picture down 8 rows | A copy with the rows bottom-up: BPT `0x010000` + 191 × 320, DPT `0x010000` + 199 × 320, BSTRIDE −320, DSTRIDE −320, WIDTH 320, HEIGHT 192 |
| Scroll it right 4 pixels | A copy right to left: CTRL `0xCC000700` (RTL), BPT `0x010000` + 315 (the last source pixel of row 0), DPT `0x010000` + 319, strides 320, WIDTH 316, HEIGHT 200 |

At 4 bpp, an object at an odd x has DBIT 1: a 16-pixel-wide row then spans five bytes, the first and last half covered, so its first and last words are read as C and merged even for a plain copy.

## 4. What a job can reach

**SRAM only** (design plan, branch 21). The pointers and BLTNEXT are **physical addresses** in the MMU's page numbering (spec 2, section 9.3): address = page × `0x2000` + offset within the page. They do not go through the MMU windows, so a job sees the same thing whatever the CPU has mapped. A program finds the physical address of something it has mapped from the window's MMU register: page × `0x2000` + (Z80 address AND `0x1FFF`).

Only the low 22 bits of an address are used (4 MB, pages `0x000`–`0x1FF`). There is no range check: an address past 4 MB wraps round into the SRAM, and on a 2 MB board the top half mirrors the bottom (spec 2, section 11). Software keeps jobs in bounds. A descriptor's address also loses its bit 0, so BLTNEXT ends a chain when its bits 21–1 are 0.

The blitter never reaches the custom registers, the palettes, the boot ROM, the system page or the ports: it is not a register bus master, and has no path to the ROM. Registers and palettes are loaded by the copper (spec 6) or the CPU. Descriptors live in SRAM; there is no descriptor RAM.

**The blitter and the CPU** share memory with no locks. The CPU should not use an area while a job writes it. A CPU write made before the write that starts a job is in memory before the blitter's first read (spec 1).

## 5. Memory cycles and priority

The blitter is requester 5 (BLT) of the memory scheduler (spec 2, section 5.1; retro-hw's `dmac`), ahead of the rasteriser (6, spec 19) and the DMA port (7). Each 100 ns slot has 5 memory cycles of 20 ns: 0 and 2 the CPU's, 1 and 3 the display's, 4 audio's (reserved while sound is parked) and the free pool's.

- **The free pool** is cycle 4 and every cycle its owner leaves: cycles 0 and 2 the Z80 does not use (it makes a memory access at most every 3 T-states, and none in I/O and register page accesses or internal T-states), cycles 1 and 3 no layer or sprite needs (all of them in the vertical blank), and cycle 4 while audio is parked. The free order is: the copper at PRI 1, then by number: layers, sprites, audio, the copper, the CPU, **the blitter**, the rasteriser, the DMA port. So the blitter never delays anyone, and gets whatever is left.
- **No priority over the CPU.** The blitter never takes the CPU's cycles 0 and 2: they are locked to it. The Z80 never waits for SRAM.
- **One memory cycle** reads or writes 2 bytes at an even address, with byte selects for single bytes (spec 2, section 8.4).
- **A descriptor** takes 16 read cycles (32 bytes) to load.
- While DMACON.BLTEN or DMACON.DMAEN is clear (spec 4), a running job waits before its next memory access, and BLTSTAT.BUSY stays set.

## 6. How a blit works

The blitter works through each row a destination word (16 bits at an even address) at a time. Each word takes these memory accesses, in this order:

| Access | When |
|--------|------|
| Read B | B is memory, and MINTERM depends on B or MASK = 2. One word for each 16 source bits used: sometimes two for the row's first word, none for a word the last read still covers |
| Read A | MASK = 1 and MINTERM depends on A: one word for every 16 pixels |
| Read C | MINTERM depends on C, or the word is the row's first or last and a byte of it is only partly inside the row |
| Write D | Always, with the byte selects off for bytes wholly outside the row |

So a fill is one access a word, a copy two, and a cookie-cut with a key colour three.

"Depends on" is read from MINTERM alone: it depends on C when bits 7, 5, 3, 1 differ from bits 6, 4, 2, 0; on B when bits 7, 6, 3, 2 differ from 5, 4, 1, 0; on A when bits 7–4 differ from bits 3–0. With MASK = 0 only bits 7–4 count.

The datapath for a word:

| Stage | What |
|-------|------|
| B | The source bits for this word, lined up to the destination by a barrel shifter over the last and the current source word (as the Amiga's); or VALUE |
| A | The image's bits, one a pixel, widened to the pixel; or 1 where B's pixel differs from KEY; or all ones |
| Combine | The minterm of A, B and C, bit by bit |
| Edges | In the row's first and last words, pixels outside the row keep C |

**Edge masks are automatic.** The blitter works out which pixels of the first and last words of each row belong to the job from DBIT and WIDTH. There are no mask registers to set, unlike the Amiga's first-word and last-word masks.

The blitter puts up one memory request at a time. A word's B and C reads are asked for one after the other without waiting for data; its write follows when both are back, and an A read is waited for on its own. It may read one source or mask word past the row's last pixel. It never writes outside the row.

**A cookie-cut reads C at every depth**, 8 bpp included: where A is 0 the old pixel is written back. (Version 1 skipped the byte at 8 bpp, so its cookie-cut cost the same as a copy.)

**At the end of a job** its last write has been made. Then, if IRQ is set, DMXINT.BLT is set; if BLTNEXT is not 0 and no STOP was asked, BLTDESC becomes BLTNEXT and that descriptor is loaded and run. Otherwise BUSY clears and DMXINT.BLT is set.

## 7. Speed

A 576p line is 32 µs: 320 slots, **1,600 memory cycles**. The free pool leaves the blitter about 670 to 1,430 cycles a line, depending on the screen and the CPU (version 1's figures, which still hold for the free pool): a typical busy Z80 uses about 160, a full-screen 8 bpp layer at 2× about 180, eight sprites about 64.

The blitter uses far fewer than that: its own steps, not the memory, set its speed. retro68k measured the same core at the same clock and the same 20 ns memory cycle in simulation (its spec 11, section 8: the display off, 64 KB jobs at 8 bpp):

| Job | Accesses a word | Time a word | Speed |
|-----|-----------------|-------------|-------|
| Fill (`0xCC`, BCONST) | 1 | 80 ns | 25 MB/s |
| Copy (`0xCC`) | 2 | 120 ns | 16.7 MB/s |
| Invert with a constant (`0x66`, BCONST) | 2 | 120 ns | 16.7 MB/s |
| Cookie-cut with a key (`0xCA`, MASK = 2) | 3 | 160 ns | 12.5 MB/s |
| Cookie-cut with a mask image (`0xCA`, MASK = 1; KS3 only) | 3, and 1 for every 16 pixels | 170 ns | 11.8 MB/s |

retro-z80 should see about the same, with the screen and the Z80 costing little, since the blitter uses a quarter to a third of the free cycles it could have. These are **to be measured** here, in simulation and on the KS2 (open point D2).

**Against version 1:** the old engine was faster for long jobs: on the KS2, a fill 73 MB/s and a copy 39 MB/s with the screen on (ticket #78). The redesign chose a small, simple core first (retro-hw's blitter spec, B2), about a fifth of the old engine's LUTs.

**Against the Z80:** `LDIR` takes 21 T-states a byte, about **0.95 MB/s** at 20 MHz; unrolled `LDI` about 1.25 MB/s; a fill with unrolled `PUSH` about 3.6 MB/s. So the blitter is still several times faster than the fastest Z80 code, and **the CPU carries on at full speed meanwhile**.

Estimates from the times above:

| Job | Bytes | Blitter | `LDIR` |
|-----|-------|---------|--------|
| Clear a 360 × 288 8 bpp screen | 103,680 | about 4.1 ms | 109 ms |
| Copy a 360 × 288 8 bpp screen | 103,680 | about 6.2 ms | 109 ms |
| Clear a 64 × 32 tile map (2-byte entries) | 4,096 | about 165 µs | 4.3 ms |
| Copy a 32 × 32 8 bpp image into a screen | 1,024 | about 65 µs | 1.1 ms (32 `LDIR`s) |
| Draw a 32 × 32 8 bpp object with a key colour | 1,024 | about 85 µs | – |

## 8. Registers

Custom block offsets (spec 3, section 5.9). From the CPU: port = (offset bits 7–0) << 8 | (`0x10` + offset bits 9–8), used with `LD BC,port` then `OUT (C),r` or `IN r,(C)`; `INC B` steps to the next register byte. In the register page the blitter is at offset + `0x1000`. The copper reaches it with MOVEF (section 9.2). Multi-byte values are low byte first, and each byte is written directly (spec 3, rule 2). Reserved offsets read `0xFF` and ignore writes (spec 3, rule 11). Names are from `hw.inc` (spec 3, section 8).

| Offset | Port | Name | Width | Access | Bits | Meaning | Reset |
|--------|------|------|-------|--------|------|---------|-------|
| `0x140`–`0x15F` | `0x4011`–`0x5F11` | BLTCTRL … BLTNEXT | 8 × 4 | RW (ignored while BUSY) | Section 3 | The job registers | 0 at power-on; not reset |
| `0x160`–`0x162` | `0x6011`–`0x6211` | BLTDESC | 3 | RW (ignored while BUSY), CAP | ADDR 23–0 | The descriptor START loads. Read: the descriptor running, or the last one loaded. Bit 0 and bits 23–22 are not kept (read 0). Reading `0x160` captures all three bytes (spec 3, rule 4) | 0 |
| `0x164` | `0x6411` | BLTCMD | 1 | S | START (0), RUN (1), STOP (2) | Section 8.1. Reads 0 | – |
| `0x168` | `0x6811` | BLTSTAT | 1 | R | BUSY (0), ERR (2) | Section 8.2 | 0 |
| `0x230` | `0x3012` | DMXINT | 1 | W1C | BLT (0), RAS (1) | BLT is set when a job with IRQ ends, and whenever the blitter stops: the chain's end, STOP, an error. RAS is the rasteriser's (spec 19, section 7). Write 1 to a bit to clear it | 0 |
| `0x234` | `0x3412` | DMXINTEN | 1 | RW | BLT (0), RAS (1) | Interrupt enables | 0 |

`0x163`, `0x165`–`0x167`, `0x169`–`0x17F`, `0x231`–`0x233` and `0x235`–`0x23F` are reserved. The rasteriser's registers are at `0x180`–`0x1B3` (spec 19, section 7). Bits 7–2 of DMXINT and DMXINTEN, and the bits of BLTSTAT not listed, read 0. (DMXINT and DMXINTEN keep version 1's names and places, shared with the rasteriser; bits 3–1 were channels 1–3.)

**The job registers** can be written while the blitter is idle; writes are ignored while BUSY. A descriptor load overwrites all eight. They hold the job as loaded or written: the blitter's progress is kept inside it, not in them. So after a job, writing only the fields that change (for example BLTBPT and BLTDPT) and RUN starts a similar one, which suits the copper.

**Writing a whole job from memory:** the job registers are in address order with the low byte first, so a loop of `OUT`s (or `LDIR` into the register page) of a 32-byte descriptor image writes every register correctly. Through the register page that takes about 670 T-states (34 µs at 20 MHz). A descriptor in SRAM started with BLTDESC and START needs only 4 register writes (section 9.1).

### 8.1 BLTCMD

| Bit | Name | Meaning |
|-----|------|---------|
| 0 | START | Load the descriptor at BLTDESC into the job registers and run it. Ignored while BUSY |
| 1 | RUN | Run the job already in the job registers. Ignored while BUSY. START wins over RUN |
| 2 | STOP | End the job after the destination word in hand; the chain is not followed, and the job cannot be resumed. BUSY clears and DMXINT.BLT is set. Ignored while idle |
| 7–3 | – | Reserved, write 0 |

Either way, at the end of each job the blitter loads the descriptor at BLTNEXT and runs it, until BLTNEXT is 0. BUSY is set by the write of START or RUN, so a status read or a copper WAIT with B straight after it already sees the job.

### 8.2 BLTSTAT

| Bit | Name | Meaning |
|-----|------|---------|
| 0 | BUSY | A job or a chain is running, or waiting for DMACON.BLTEN |
| 2 | ERR | The last job stopped on an error (section 8.4). Cleared by the next START or RUN |
| 7–3, 1 | – | 0 |

BUSY is bit 0, so a polling loop is `IN A,(C)`, `RRA`, `JR C`.

### 8.3 Interrupts and DMACON

**DMACON** (spec 4): **BLTEN**, with DMAEN, lets the blitter use memory cycles. Both are clear after reset. While either is clear a running job waits before its next memory access (BUSY stays set), and a job started then waits too.

**Interrupts:** the blitter is **source 4, BLT**, of the interrupt controller (spec 8), IM 2 vector VECBASE + 8. It requests its interrupt while DMXINT.BLT and DMXINTEN.BLT are both set. The handler clears it by writing 1 to DMXINT.BLT. A flag that comes due in the same clock as a write of 1 that clears it **stays set**: the new interrupt is never lost (7 November 2026, as retro68k). The rasteriser shares the source, with DMXINT.RAS and DMXINTEN.RAS (spec 19, section 7.3): the handler reads DMXINT to see which. Sources 5–7 are unused.

### 8.4 Errors

MASK = 3 is the only error, and MASK = 1 on the KS2, which has no mask image (section 10). It is found before the job writes anything: the job and the chain end, BUSY clears, ERR and DMXINT.BLT are set, nothing is written, and BLTDESC still names the descriptor (unchanged, for a job started with RUN). Reserved bits are not an error (open point D5). Addresses are not checked (section 4).

### 8.5 Reset

Every reset (spec 7) makes the blitter idle with no memory request: BLTDESC is 0, and ERR, DMXINT and DMXINTEN are clear. The job registers are not reset; they are 0 after power-on.

## 9. Starting and waiting

### 9.1 From the CPU

1. One job: wait until BUSY is clear, write the job registers that change (BLTNEXT = 0 for a single job), then RUN (`0x02`) to BLTCMD.
2. A chain: write descriptors to SRAM, the first one's address to BLTDESC, then START (`0x01`) to BLTCMD. (Or write the first job into the job registers, with BLTNEXT pointing at the rest, and RUN.)
3. Carry on. Take the interrupt, or poll BLTSTAT.BUSY.

The job registers are in address order, so a 32-byte job image in memory can be written to them with a loop. Each register byte is one port, and `INC B` steps to the next.

```
; Clear a 360 x 288 8 bpp screen at physical 0x020000 to colour 0.
; The job registers are custom offsets 0x140-0x15F: page 0x11, so C stays
; 0x11 and only B changes. Names from hw.inc (spec 3, section 8).

clear:      ld   bc,BLTSTAT_P
.wait:      in   a,(c)
            rra                       ; BUSY into carry
            jr   c,.wait
            ld   hl,clearjob
            ld   b,high BLTCTRL_P     ; the first job register
.next:      ld   a,(hl)
            out  (c),a
            inc  hl
            inc  b
            ld   a,b
            cp   high BLTCTRL_P+0x20
            jr   nz,.next             ; 32 bytes written
            ld   b,high BLTCMD_P
            ld   a,BLTCMD_RUN_M
            out  (c),a
            ret                       ; about 4 ms later the screen is clear

clearjob:   dd   0xCC002300           ; BLTCTRL: MINTERM 0xCC (D = B), BCONST, 8 bpp
            dd   0                    ; BLTBPT (not used)
            dd   0x020000             ; BLTDPT, DBIT 0
            dw   360,288              ; BLTSIZE: WIDTH, HEIGHT
            dd   0                    ; BLTAPT (not used)
            dw   360,0                ; BLTSTRIDE: DSTRIDE, BSTRIDE
            dw   0x0000,0             ; BLTVALUE: VALUE (colour 0), ASTRIDE
            dd   0                    ; BLTNEXT: a single job
```

A chain in SRAM is quicker to start, and the jobs can be built once and reused:

```
; Clear the screen, then draw a 32 x 32 object with colour 0 transparent at
; (164,100), with an interrupt at the end. Window 4 (0x8000-0x9FFF) holds SRAM
; page 0x012, so Z80 address 0x8000 + x is physical 0x024000 + x.

PHYS        equ  0x024000-0x8000      ; add to a window-4 address

            align 2
job1:       dd   0xCC002300           ; a fill, as clearjob
            dd   0,0x020000
            dw   360,288
            dd   0
            dw   360,0, 0,0
            dd   job2+PHYS            ; BLTNEXT
job2:       dd   0xCA041300           ; MINTERM A ? B : C, MASK = 2 (key), IRQ, 8 bpp, KEY 0
            dd   0x030000             ; BLTBPT: the object, 32 bytes a row
            dd   0x020000+100*360+164 ; BLTDPT
            dw   32,32                ; WIDTH, HEIGHT
            dd   0                    ; BLTAPT (not used)
            dw   360,32               ; DSTRIDE (the screen), BSTRIDE (the object)
            dw   0,0                  ; VALUE, ASTRIDE (not used)
            dd   0                    ; BLTNEXT: end of chain

draw:       ld   bc,BLTDESC0_P        ; the blitter is idle
            ld   a,low (job1+PHYS)
            out  (c),a
            inc  b
            ld   a,high (job1+PHYS)
            out  (c),a
            inc  b
            ld   a,(job1+PHYS)>>16
            out  (c),a                ; BLTDESC bits 23-16
            ld   b,high BLTCMD_P
            ld   a,BLTCMD_START_M
            out  (c),a                ; BLT interrupts when job2 is done
            ret
```

### 9.2 From the copper

The blitter's registers are past `0x0EF`, so the copper writes them with **MOVEF** (spec 6), one byte per instruction of two words. The copper reads its list in the free pool, ahead of the blitter. Its writes are direct, as the CPU's are (spec 3, rule 3). Set a job up while the blitter is idle (writes are ignored while BUSY), and let one of the CPU and the copper own the blitter at a time, so their bytes never mix.

| Copper work | MOVEFs | Words read | Time, at one word per slot |
|-------------|--------|------------|----------------------------|
| RUN alone (the job registers already set) | 1 | 2 | 0.2 µs |
| START of a descriptor in SRAM (BLTDESC, then START) | 4 | 8 | 0.8 µs |
| New BLTBPT and BLTDPT addresses, then RUN (a repeat of the last job) | 7 | 14 | 1.4 µs |
| A whole new job in the job registers, then RUN | 33 | 66 | 6.6 µs (about a fifth of a line) |

```
        CWAIT  100,0
        CMOVEF BLTDESC0,low DESC              ; DESC: a descriptor in SRAM
        CMOVEF BLTDESC1,high DESC
        CMOVEF BLTDESC2,DESC>>16
        CMOVEF BLTCMD,BLTCMD_START_M
        CWAITB 0,0                             ; wait until the blitter is idle
```

Keep a strobe (START or RUN) out of the middle of a multi-byte value, so that a list cut off and run again never starts a job twice (spec 6).

### 9.3 The copper's B bit

The copper's WAIT has a **B** bit, as in retro68k: with B set, a WAIT also waits until the blitter and the rasteriser are both idle (spec 6). The two units give the copper one signal, **IDLE** = neither BLTSTAT.BUSY nor RASSTAT.BUSY (spec 19, section 8.3):

- IDLE goes low with the write of START or RUN, so a WAIT with B straight after the MOVEF that wrote it waits for that job or chain.
- IDLE goes high when the chain ends (its last write made), is stopped, or stops with an error, and the rasteriser is idle too. A whole chain counts as one wait.
- A job waiting for DMACON.BLTEN is not idle. A WAIT with B while BLTEN is clear therefore waits until BLTEN is set (or the next frame restarts the copper).
- A build without the blitter and the rasteriser (the KS2's `GEOM = 1`) is always idle.

## 10. FPGA resources

| Item | Resource |
|------|----------|
| The core (`blitter.v`) | Without the mask image (the KS2's build): about 620 LUTs (Vivado, alone, on the KS2's part) and 310 flip-flops (Yosys). With it: about 1,060 LUTs and 400 flip-flops. Both from retro-hw's blitter spec, B2 |
| The job registers (8 × 32 bits, only the used bits kept) and the control registers | Flip-flops in `dmx.v`, driving the core's job ports directly |
| Block RAM, DSP | None |

Version 1's engine was about 3,350 LUTs here. The whole KS2 build with the new blitter is still to be measured (open point D1).

**The KS2** builds 2 sprites and **no mask image** (`DMX_MASKIMG = 0`: MASK = 1 is an error there, section 8.4), as with version 1; compare masks and every minterm work. The KS3 builds everything (design plan, branch 21). The KS2's `GEOM = 1` build leaves the blitter and the rasteriser out (`DMX = 0`): their registers are then not answered and they count as idle (spec 15, section 8).

### 10.1 Shared core

The blitter is retro-hw's `blitter` ([spec](../../fpga/retro-hw/docs/spec/blitter.md), revision 2), in `fpga/retro-hw/rtl/blitter.v`: the descriptor load, the chain, the address units, the shifter, the mask, the minterm and the edges. `fpga/rtl/dmx.v` is retro-z80's wrapper round it, and round the rasteriser's core beside it (spec 19, section 10.1), as retro68k's `dmx.v` narrowed to bytes.

| Parameter | Value | Why |
|-----------|-------|-----|
| AW | 21 | Word addresses: 4 MB of SRAM |
| LE | 1 | The SRAM is little-endian (spec 2, section 8.4) |
| MASKIMG | `DMX_MASKIMG`: 0 on the KS2, 1 on the KS3 | The 1 bpp mask image (above) |

The wrapper keeps this spec's registers (section 8): the job registers as eight 32-bit words, stored a byte at a time from the register bus while the core is idle and a word at a time from a descriptor load; the core's job ports wired straight to their fields; BLTDESC through the capture; BLTCMD's strobes; BLTSTAT; DMXINT and DMXINTEN. It ties the core's `job_bad` to 0 and `dl_wait` to 0. The core's `busy`, with the rasteriser's, gives the copper's IDLE, and its memory port is the scheduler's BLT channel.

## 11. Test plan

- **Random jobs:** chains of random jobs against a Python model of section 3.3, comparing the whole SRAM: every depth, mask kind (MASK = 1 in a build with the mask image), row direction (RTL) and stride sign; random minterms, widths from 1 pixel, every BIT, constant and memory B, strides of 0; copies that overlap their source in every direction; jobs of no width or height inside chains; chains started by START and by RUN, with descriptors at any even address. (retro68k's `dgen.py` and `dmodel.py` with little-endian descriptors.)
- **Byte order:** a descriptor and the job registers hold the same job, low byte first; VALUE's bits 15–8 go to the even byte; a 2-byte tile map fill with VALUE swapped.
- **Registers:** the job registers and BLTDESC read back; each byte takes effect when written, in any order; reserved bits read 0; BLTDESC drops bit 0 and bits 23–22, and a read of its low byte captures all three; `LDIR` of a 32-byte image through the register page sets a job; reserved offsets, `0x169`–`0x17F` among them, read `0xFF`.
- **Control:** a fill by RUN with the bytes either side untouched; a copy by START, the job registers then holding the descriptor; writes to the job registers and BLTDESC ignored while BUSY; START and RUN ignored while BUSY; STOP mid-job, the chain not followed, DMXINT.BLT set; STOP while idle ignored.
- **Errors:** MASK = 3 by RUN and in a chain, and MASK = 1 on the KS2: ERR, DMXINT.BLT, nothing written, BLTDESC, ERR cleared by the next start.
- **Interrupts** (`sim/dmxint`): BLT requested only with DMXINT.BLT and DMXINTEN.BLT both set, at the end of a chain and after a job with IRQ; W1C clears it; a flag due in the clock of the clearing write stays set.
- **Copper:** a job set up and started by MOVEFs; a WAIT with B right after the start waits for the whole chain, and for a rasteriser job too (spec 19, section 11); a build without the blitter is idle.
- **DMACON:** a job waits while BLTEN or DMAEN is clear, and finishes when it is set again.
- **Free cycles only:** with the CPU at 20, 2.5 and 3.57 MHz, the display, copper and sprites busy, the blitter never takes a cycle another user wanted: CPU accesses, layer and sprite fetches and copper reads are exactly the same with and without jobs running.
- **Ordering:** a CPU write made just before the START or RUN is seen by the job's first read, at every CPU speed (spec 7).
- **Speed:** the figures of section 7, in simulation and on the KS2.
- **The core** has its own tests in retro-hw (`test/blitter`): every memory write against a pixel-exact model, random waits, both byte orders.

## 12. Open points

| # | Item |
|---|------|
| D1 | Build the KS2 with the new blitter in Vivado: LUTs, timing at 100 MHz, multi-driven nets (design plan, branch 23) |
| D2 | Measure the speed of section 7 in simulation and on the KS2, with the screen on and off. Version 1 measured a fill at 73 MB/s and a copy at 39 MB/s on the KS2; retro68k's simulation of the new core gives 25 and 16.7 |
| D3 | Closed (11 November 2026, #110): lines and triangles are the rasteriser's (spec 19), retro-hw's `raster` core with its own registers at custom `0x180`–`0x1B3`, beside the blitter in `dmx.v`, as retro68k. It shares interrupt source 4 (DMXINT.RAS); source 5 is no longer kept for it. `geom` (3D points) is later still. Version 1's LINE and EDGES, and the reserved OP 6 (span fill) and OP 7 (triangle), are gone |
| D4 | A FIFO mover for the SD card and the serial link (version 1's planned port jobs) is decided later, with retro68k (retro-hw's blitter spec, B3). Until then the CPU moves those bytes |
| D5 | Reserved bits of the job registers are not an error (the core's `job_bad` is tied off): they are not stored. Software written for version 1 gets a wrong picture, not ERR. The rasteriser treats its reserved RASCTRL bits as an error; whether the two should agree is spec 19, RA2 |
| D6 | Closed (11 November 2026, #110): `dmx.v` keeps its name, and DMXINT and DMXINTEN theirs; the rasteriser's wrapper is in it and shares them (bit 1, RAS), as retro68k's D7 |
| D7 | The core does not reset the register that holds C, so in simulation the first job after power-on writes unknown bits if it never reads C (an aligned fill). In hardware the result is right. retro68k's tests start with a job that reads C; a reset in retro-hw's `blitter.v` would be the proper cure (retro68k's D8) |
