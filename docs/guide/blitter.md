# Chapter 6: Blitter and DMA Hardware

## Introduction

The **blitter** draws for you. You tell it where an image is, where it should go and how to combine it with what is already there, and it does the work while the Z80 gets on with something else: it can clear a whole screen in about a millisecond and a half, where `LDIR` would take five and a half frames.

It is part of the **DMA engine**, which has four **channels**. Each channel runs one job at a time, and all four can run at once, taking turns at memory. A job is 32 bytes of settings: you can write them straight into a channel's registers, or leave a list of jobs in memory and let the channel work through them on its own.

The blitter works like the Amiga's. Each job has up to three inputs and one output:

```
   A  the mask        (which pixels to draw)
   B  the image       (what to draw)
   C  the background  (what is on the screen now)
            │
            ▼
   ┌──────────────────┐
   │  MINTERM         │   any logic function of A, B and C,
   │  D = f(A, B, C)  │   worked out bit by bit
   └──────────────────┘
            │
            ▼
   D  the destination (the screen, or any memory)
```

C and D are the same place: the blitter reads what is there, combines it, and writes the result back. A **minterm** is one byte that says how A, B and C combine. With the right minterm the same hardware copies, fills, draws with a transparent colour, sets, clears or flips bits, and inverts areas.

The chapter covers:

- forming a job, step by step, with a first example;
- minterms, and how to work one out;
- masks: drawing a shape with a transparent colour, or through a mask image;
- moving objects about: saving and restoring the background;
- pixel depths, and placing an image at any pixel;
- rectangles, strides and clipping;
- overlapping copies, and scrolling;
- filling with a value or a pattern, and adding to pixels;
- lists of jobs (descriptors and chains);
- status, interrupts and errors;
- starting jobs from the copper and timers;
- speed, and how to keep jobs fast;
- a summary of the registers.

You should have read the Playfield Hardware chapter: the blitter mostly draws into the layers described there.

**Version 1 works on SRAM only.** Copying into the hardware registers, the palettes, from the boot ROM, and to and from the SD card and USB serial link are planned for later (spec 14, section 4). Until then, a job that names one of them stops with an error.

### Comparison with the Amiga

If you have used the Amiga's blitter, the ideas are the same. The differences:

| Feature | Amiga | retro-z80 |
|---------|-------|-----------|
| Inputs and output | A, B, C into D, minterm LF7–LF0 | The same, with the same minterm numbering |
| Pixels | Planar: one bitplane per blit | Chunky: 1, 2, 4 or 8 bits per pixel, all of a pixel's bits in one blit |
| Shifting | A and B shifted 0–15 bits (ASH, BSH) | A, B and D each start at any pixel in a byte; the blitter lines them up for you |
| Edge masks | First and last word masks (BLTAFWM, BLTALWM) set by software | Automatic, from the destination's position and the width |
| Mask | Channel A, read from memory | Channel A from memory (1 bit per pixel), or made on the fly by comparing B with a transparent colour, which costs no memory |
| Channels | One blit at a time | Four channels, running at once, each working through its own list of jobs |
| Starting | Writing BLTSIZE | RUN or START in a channel's CHCTRL; also the copper, a timer, or a list |
| CPU | The blitter can hold up the CPU ("blitter nasty") | Never: the blitter only uses memory cycles nobody else wants |
| Line and area fill modes | Yes | Not yet: they come with the 3D hardware |
| ADD | No | Yes: per-pixel add, wrapping or saturating |

### Comparison with retro68k

retro68k's DMA engine has the same channels, lists and speed, but separate COPY, FILL, KEYCOPY and LOGIC jobs instead of the minterm. Each of them is one minterm here; the table in "Minterms" shows which. retro-z80's design has been proposed to retro68k, so the two may yet be the same again.

### Conventions in this chapter

- Examples are Z80 assembly language for sjasmplus and start with `include "hw.inc"`. Numbers are hexadecimal when they start with `0x`.
- As in the other chapters, **the register page is in window 7** (`REGS` = `0xE000`), and the examples write registers through it: `CREG` (`0xF000`) + custom offset. So channel 2's MINTERM is at `CREG+DMX2_MINTERM`, and `CREG+DMX2` is the first of its job registers.
- **Addresses are physical.** The blitter reads and writes SRAM by its 23-bit physical address, not through the MMU windows: physical address = MMU page × `0x2000` + offset in the page. Names in capitals, such as `SCREEN`, are physical addresses.
- The examples draw into a **360 × 288 layer at 8 bpp** (one byte per pixel, shown at 2× each way), at physical `SCREEN`, 360 bytes a row, set up as in the Playfield Hardware chapter. The pixel at (x, y) is at `SCREEN + y × 360 + x`.
- **Jobs kept in the program** are at Z80 addresses, but NEXT and CHDESC need physical ones. As in the Sprite Hardware chapter, the programs are loaded so that a Z80 address a in `0x4000`–`0xDFFF` is physical a − `RAMOFS` (`0x4000`); the examples write this as `a+PHYS`, with `PHYS equ -RAMOFS`.
- Channel 2 does the examples' drawing, as the suggested channel use has it ("Status, Interrupts and Errors").
- These names for CTRL's middle byte, CTRL1, are used in the examples. `hw.inc` gives the same bits for the whole 3-byte CTRL register, so they are shifted down by 8:

```
BPP1    equ 0                        ; CTRL1: bits per pixel
BPP2    equ 1
BPP4    equ 2
BPP8    equ 3
DESC    equ DMX_CTRL_DESC_M >> 8     ; 0x04  run backwards
IRQ     equ DMX_CTRL_IRQ_M >> 8      ; 0x08  interrupt when this job ends
BCONST  equ DMX_CTRL_BCONST_M >> 8   ; 0x10  B is VALUE, not memory
MASKIMG equ 1 << 5                   ; 0x20  A is a 1 bpp mask image
MASKKEY equ 2 << 5                   ; 0x40  A is "B is not the key colour"
OP_BLIT equ 0                        ; CTRL0
OP_ADD  equ 1
```

---

## Forming a Job

Four steps: turn the blitter on, describe the job, start it, and wait for it (or don't).

### Step 1: Turn the engine on

The DMA engine runs only while **DMACON.DMAEN** and **DMACON.BLTEN** are both set. Do this once:

```
        ld   a,DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_BLTEN_M
        ld   (CREG+DMACON),a
```

Clearing BLTEN later holds every channel where it is; setting it again lets them carry on.

### Step 2: Describe the job

A job is 32 bytes, which are also the first 32 registers of each channel, in the same order:

| Offset | Name | Bytes | What it holds |
|--------|------|-------|---------------|
| `+0x00` | CTRL | 3 | CTRL0: the operation (BLIT or ADD). CTRL1: bits per pixel, DESC, IRQ, BCONST, MASK. CTRL2: 0 |
| `+0x03` | MINTERM | 1 | How A, B and C combine |
| `+0x04` | APT | 3 | Where the mask A starts (if MASK says it is an image) |
| `+0x07` | BPT | 3 | Where the image B starts |
| `+0x0A` | DPT | 3 | Where the destination D starts (C is read from here too) |
| `+0x0D` | WIDTH | 3 | Pixels across |
| `+0x10` | HEIGHT | 2 | Rows down |
| `+0x12` | SHIFT | 2 | Which pixel of its first byte A, B and D start at (0 unless below 8 bpp) |
| `+0x14` | ABSTRIDE | 2 | Bytes from one row of A and B to the next |
| `+0x16` | CDSTRIDE | 2 | Bytes from one row of D to the next |
| `+0x18` | VALUE | 4 | A colour: B's value when BCONST is set, or the transparent colour |
| `+0x1C` | NEXT | 3 | The next job in a list, or 0 |
| `+0x1F` | – | 1 | Spare |

Each value is stored low byte first, as the Z80 stores words. The easiest way to set a job is to keep it in memory as 32 bytes and copy it into the channel's registers with `LDIR`. The spare byte is ignored.

The registers can only be written while the channel is idle; writes while it is busy are ignored. They keep their values after a job, so a second job that differs only in a few places needs only those written.

### Step 3: Start it

Write **RUN** to the channel's CHCTRL:

```
        ld   a,DMX_CHCTRL_RUN_M
        ld   (CREG+DMX2_CHCTRL),a
```

The channel is busy from that moment.

### Step 4: Wait, or do something else

The job runs by itself. The Z80 carries on at full speed: the blitter never takes a memory cycle the CPU wants. When you need the result, wait until the channel's **CHSTAT.BUSY** (bit 0) is clear:

```
wait2:  ld   a,(CREG+DMX2_CHSTAT)
        rra                          ; BUSY into carry
        jr   c,wait2
```

Or ask for an interrupt when the job ends (IRQ in CTRL1, see "Status, Interrupts and Errors").

### Example 6-1: Clear the screen

```
        include "hw.inc"

clear:  ld   a,(CREG+DMX2_CHSTAT)    ; wait until channel 2 is free
        rra
        jr   c,clear
        ld   hl,clearjob
        ld   de,CREG+DMX2
        ld   bc,32
        ldir                         ; the job into channel 2's registers
        ld   a,DMX_CHCTRL_RUN_M
        ld   (CREG+DMX2_CHCTRL),a    ; go
        ret                          ; the screen is clear about 1.4 ms later

clearjob:
        db   OP_BLIT, BPP8|BCONST, 0 ; CTRL: draw with the value, 8 bpp
        db   0xCC                    ; MINTERM: D = B
        d24  0                       ; APT: no mask
        d24  0                       ; BPT: not read (BCONST)
        d24  SCREEN                  ; DPT
        d24  360                     ; WIDTH
        dw   288                     ; HEIGHT
        dw   0                       ; SHIFT
        dw   0                       ; ABSTRIDE: B is not read
        dw   360                     ; CDSTRIDE: the screen's row length
        dd   0                       ; VALUE: colour 0
        d24  0                       ; NEXT: no more jobs
        db   0
```

The job "draws" B onto D, and B is the constant VALUE: so every pixel becomes colour 0. With a different VALUE it fills with that colour. Since the screen's rows follow each other with no gap, the same job could also be one row of 103,680 pixels and HEIGHT 1.

---

## Minterms

For every bit of every pixel, the blitter takes the bits of A, B and C at that place and looks up the result in MINTERM:

| A | B | C | D is MINTERM bit |
|---|---|---|------------------|
| 0 | 0 | 0 | 0 |
| 0 | 0 | 1 | 1 |
| 0 | 1 | 0 | 2 |
| 0 | 1 | 1 | 3 |
| 1 | 0 | 0 | 4 |
| 1 | 0 | 1 | 5 |
| 1 | 1 | 0 | 6 |
| 1 | 1 | 1 | 7 |

So the minterm is a truth table of the function you want. There is a quick way to work one out, as on the Amiga: write the function you want with **A = `0xF0`, B = `0xCC`, C = `0xAA`**, and work it out with ordinary logic. The answer is the minterm.

- D = B: `0xCC`.
- D = B OR C: `0xCC | 0xAA` = `0xEE`.
- D = B XOR C: `0xCC ^ 0xAA` = `0x66`.
- D = A ? B : C, "B where the mask is set, otherwise C": `(0xF0 & 0xCC) | (~0xF0 & 0xAA)` = `0xC0 | 0x0A` = `0xCA`.

The ones you will use most:

| MINTERM | D = | Use |
|---------|-----|-----|
| `0xCC` | B | Copy an image; with BCONST, fill with a colour |
| `0xCA` | A ? B : C | Draw a shape: B where the mask is set, the background elsewhere |
| `0x0A` | A ? 0 : C | Cut a shape out (colour 0 where the mask is set) |
| `0xEE` | B OR C | Set bits |
| `0x88` | B AND C | Keep only bits set in both |
| `0x22` | C AND NOT B | Clear the bits B has set |
| `0x66` | B XOR C | Flip bits: drawing the same thing twice removes it again |
| `0x55` | NOT C | Invert an area |
| `0x00` | 0 | Clear (but a fill with VALUE 0 is just as fast) |

retro68k's jobs as minterms:

| retro68k job | CTRL1 | MINTERM |
|--------------|-------|---------|
| COPY | BPPn | `0xCC` |
| FILL | BPPn + BCONST | `0xCC` |
| KEYCOPY | BPPn + MASKKEY | `0xCA` |
| LOGIC with function FN | BPPn | FN × `0x11` |

**The minterm works on bits, not colours.** At 8 bpp, B XOR C flips the bits of each pixel's colour number, which gives another colour; it is drawing and undrawing that make XOR useful, not the colour you see. For colour arithmetic, use ADD.

---

## Masks

The mask, A, says which pixels to draw. It is one bit per pixel: where it is 1, the minterm sees A = 1 in all of that pixel's bits; where it is 0, A = 0. MASK in CTRL1 says where it comes from:

| MASK | A comes from | Costs |
|------|--------------|-------|
| 0 (none) | Nothing: A is 1 everywhere | Nothing |
| `MASKKEY` | Comparing each pixel of B with the **key colour** in VALUE: A is 0 where B is that colour, 1 elsewhere | Nothing: no memory is read |
| `MASKIMG` | A **mask image** at APT: 1 bit per pixel, the leftmost pixel in bit 7 of each byte | One memory read per 16 pixels |

With no mask, a minterm that uses A sees A = 1, so `0xCA` is just a copy.

### Drawing with a transparent colour

Most game graphics keep one colour, usually 0, for "nothing here". MASKKEY with VALUE = that colour and MINTERM `0xCA` draws only the other pixels:

```
        db   OP_BLIT, BPP8|MASKKEY, 0
        db   0xCA                    ; A ? B : C
```

At 8 bpp this costs no more than a plain copy: where the mask is 0 the blitter simply does not write that byte, and it never needs to read the screen.

### Drawing through a mask image

When a shape uses every colour, or when the same image needs different shapes, keep a mask image: 1 bit per pixel, 1 where the image should show. Set MASK to MASKIMG and APT to the mask. The mask's rows are the same distance apart as the image's (ABSTRIDE serves both), so a row of an 8 bpp mask uses only one byte in eight of its row's space. Keeping the masks of a sprite sheet in their own sheet, with the same row length as the images, puts that space to use.

---

## Moving Objects: Save, Draw, Restore

The classic way to move an object around a screen ("bobs", blitter objects, on the Amiga) uses three jobs per object, per frame:

1. **Restore** the background where the object was last frame, from a saved copy.
2. **Save** the background where it is going.
3. **Draw** it there.

### Example 6-2: One moving object

The object is 32 × 32 pixels at 8 bpp, at physical `BALL`, 32 bytes a row, with colour 0 transparent. `SAVE` is 1,024 bytes for the saved background. Each frame, the program writes the old and new positions into the three jobs and starts the list with START (see "Lists of Jobs").

```
        align 4
restore: db  OP_BLIT, BPP8, 0, 0xCC  ; copy
        d24  0, SAVE                 ; APT, BPT: the saved background
oldpos: d24  SCREEN                  ; DPT: where the ball was (set each frame)
        d24  32
        dw   32, 0                   ; HEIGHT, SHIFT
        dw   32, 360                 ; ABSTRIDE: SAVE's rows; CDSTRIDE: the screen's
        dd   0
        d24  save+PHYS               ; NEXT
        db   0

save:   db   OP_BLIT, BPP8, 0, 0xCC  ; copy
        d24  0
newpos1: d24 SCREEN                  ; BPT: where the ball goes (set each frame)
        d24  SAVE                    ; DPT
        d24  32
        dw   32, 0
        dw   360, 32                 ; ABSTRIDE: now the screen; CDSTRIDE: SAVE's rows
        dd   0
        d24  draw+PHYS
        db   0

draw:   db   OP_BLIT, BPP8|MASKKEY|IRQ, 0, 0xCA   ; A ? B : C, key colour 0
        d24  0, BALL                 ; APT (not used), BPT: the ball
newpos2: d24 SCREEN                  ; DPT: where the ball goes (set each frame)
        d24  32
        dw   32, 0
        dw   32, 360
        dd   0                       ; VALUE: the key colour
        d24  0                       ; NEXT: end of the list
        db   0
```

`PHYS` turns the Z80 address of a job into its physical address (see "Conventions"). The jobs must stay where they are while the channel uses them.

The first frame has nothing to restore: start the list at `save` instead of `restore`.

Note how the strides swap: when the screen is the source, its stride is ABSTRIDE; when it is the destination, CDSTRIDE.

---

## Pixel Depths and Positions

BPP in CTRL1 sets the bits per pixel: 1, 2, 4 or 8. A job works on whole pixels at that depth. A, B and D are read and written at the same depth, apart from A, which is always 1 bit per pixel.

Below 8 bpp, a byte holds several pixels, the leftmost in the most significant bits:

| BPP | Pixels per byte | Pixel x is in byte | At position |
|-----|-----------------|--------------------|-------------|
| 1 | 8 | x / 8 | x mod 8 |
| 2 | 4 | x / 4 | x mod 4 |
| 4 | 2 | x / 2 | x mod 2 |
| 8 | 1 | x | 0 |

An image can start at any pixel. Give its byte address in BPT or DPT, and its position within that byte in **SHIFT**: ABIT (bits 2–0) for A, counted in 1-bit pixels; BBIT (bits 6–4) for B and DBIT (bits 10–8) for D, counted in pixels of the job's depth. The blitter shifts A and B into line with D, so an image stored at the start of its bytes can be drawn at any x.

### Example 6-3: Placing an image at any x, at 4 bpp

The layer is 4 bpp, 360 pixels across, so 180 bytes a row. To draw a 16 × 16 image (8 bytes a row, starting at the beginning of its bytes) at (101, 50):

```
x       equ  101
y       equ  50
        ; the job, as a descriptor:
        db   OP_BLIT, BPP4|MASKKEY, 0, 0xCA
        d24  0, IMAGE
        d24  SCREEN4 + y*180 + x/2   ; DPT: the byte holding pixel 101
        d24  16
        dw   16
        dw   (x % 2) << 8            ; SHIFT: DBIT = 1, the second pixel of the byte
        dw   8, 180                  ; ABSTRIDE: the image's rows; CDSTRIDE: the screen's
        dd   0
        d24  0
        db   0
```

The blitter handles the bytes at each end of every row that the image covers only in part: it reads them, changes only the image's pixels, and writes them back. You never set edge masks.

8 bpp is the fastest depth for game graphics: every pixel is a whole byte, so nothing needs to be read back.

---

## Rectangles, Strides and Clipping

A job covers WIDTH × HEIGHT pixels. After each row it moves on by the **stride**: ABSTRIDE bytes for A and B, CDSTRIDE bytes for D. So an image can come out of a sheet of many images, of any row length, into a screen of a different row length.

- A **linear** job (one long run, like `LDIR`) is HEIGHT 1 and WIDTH the length; at 8 bpp the width is in bytes.
- A stride of **0** repeats the same row: a 1-row pattern fills a whole rectangle.
- A **negative** stride runs up the memory: an image drawn upside down.

**Clipping is up to you.** Before starting a job, trim it to the screen:

- **Off the left edge by k pixels:** add k pixels to BPT and DPT (bytes, plus BBIT and DBIT below 8 bpp), k bits to APT (bytes, plus ABIT), and take k from WIDTH.
- **Off the right edge:** take the pixels past the edge from WIDTH.
- **Off the top by r rows:** add r × ABSTRIDE to APT and BPT, r × CDSTRIDE to DPT, and take r from HEIGHT.
- **Off the bottom:** take the rows past the edge from HEIGHT.

If WIDTH or HEIGHT comes to 0 or less, the object is off the screen: skip the job (a job with WIDTH or HEIGHT 0 does nothing).

---

## Overlapping Copies and Scrolling

A job reads up to 16 bytes ahead of where it writes. When the source and destination overlap, that matters:

- If the destination is **before** the source (scrolling up or left), run forwards, as usual.
- If the destination is **after** the source (scrolling down or right), set **DESC** in CTRL1. The job then runs backwards, from the last pixel of the last row to the first. You still give the addresses of the first pixel: the blitter works out the end for itself.

### Example 6-4: Scroll the screen down by 8 lines

```
        db   OP_BLIT, BPP8|DESC, 0, 0xCC      ; copy, backwards
        d24  0
        d24  SCREEN                           ; BPT: the top of the screen
        d24  SCREEN + 8*360                   ; DPT: 8 lines further down
        d24  360
        dw   280                              ; the 280 lines that stay visible
        dw   0
        dw   360, 360
        dd   0
        d24  0
        db   0
```

Then fill the top 8 lines with the new picture.

---

## Filling and Adding

### Filling with a value or a pattern

With BCONST set, B is not read: every pixel of B is VALUE. At 1, 2 and 4 bpp, VALUE's low bits give the colour. At 8 bpp, VALUE's four bytes repeat **by address**: the byte at address a gets VALUE's byte number a mod 4 (byte 0 is the low byte). So:

- for one colour, put it in all four bytes: VALUE = `0x07070707`;
- for a tile map of 2-byte entries, put the entry in both halves (`0x01230123`) and start at an even address;
- for a 4-byte pattern, start at a multiple of 4.

Since the pattern goes by address, a 2D fill whose stride is not a multiple of 4 starts each row at a different point of it.

A fill with a mask is also useful: MASKIMG with MINTERM `0xCA` and BCONST paints a shape in one colour (a shadow, or a sprite flashing white when hit).

### ADD: shading and effects

OP_ADD adds B to C, pixel by pixel, at the job's depth: D = C + B. A carry never spills into the next pixel. The minterm is not used; the mask is (where A is 0, D keeps C). CTRL0 has two more bits for ADD:

- **SAT** (`DMX_CTRL_SAT_M`): stop at the limit instead of wrapping round. At 8 bpp, 250 + 10 gives 4 without SAT and 255 with it.
- **SIGNED** (`DMX_CTRL_SIGNED_M`): pixels are numbers from −128 to +127 (at 8 bpp), for saturating signed sums.

Uses:

- **Darken or brighten** an area when the palette is laid out in ramps (for example 16 shades of each colour): add a constant, with SAT, to step every pixel along its ramp.
- **Move an area to another palette block:** add 16, 32 and so on.
- **Glows and light maps:** add an image of light onto the scene.
- **Subtract:** add the two's complement: at 8 bpp, adding `0xFF` with wrap takes 1 away.

---

## Lists of Jobs

Each job ends with NEXT: the physical address of another job in SRAM, or 0. A list of jobs runs one after another, with no help from the CPU. Jobs in memory are called **descriptors**; they must start at an address that is a multiple of 4 (`align 4`).

To start a list, write the first descriptor's address to the channel's **CHDESC** and **START** to CHCTRL. The channel loads each descriptor in turn into its registers and runs it:

```
LIST    equ  restore+PHYS                 ; the first descriptor's physical address

        ld   hl,LIST & 0xFFFF
        ld   (CREG+DMX2_CHDESC),hl
        ld   a,LIST >> 16
        ld   (CREG+DMX2_CHDESC+2),a
        ld   a,DMX_CHCTRL_START_M
        ld   (CREG+DMX2_CHCTRL),a
```

(RUN runs the job already in the registers instead, and then follows its NEXT.)

Lists are the quickest way to start a lot of work: the CPU writes four registers, and a whole frame's drawing runs on its own. A list can be built once and reused, changing only the positions each frame.

---

## Status, Interrupts and Errors

Each channel has:

- **CHCTRL** (write): START (bit 0), RUN (bit 1), STOP (bit 2: end the list after the current group of at most 16 bytes), PAUSE (bit 3: hold until cleared).
- **CHSTAT** (read): BUSY (bit 0), DONE (bit 1: a list ended or was stopped), ERR (bit 2), PAUSED (bit 3). Write 1 to DONE or ERR to clear it.
- **CHDESC**: the descriptor START loads; while a list runs, the one now running.
- **CHERR**: after an error, the address that caused it.

**Interrupts.** A job with IRQ in CTRL1 sets its channel's bit in **DMXINT** when it ends. If the same bit is set in **DMXINTEN**, the channel interrupts the Z80: sources DMA0–DMA3 in the interrupt controller. The handler clears the bit by writing 1 to it in DMXINT. Put IRQ on the last job of a list to hear when the whole list is done, or on any job in it.

**Errors** stop only that channel: an address outside SRAM (in version 1, the registers, palettes and ROM too), a reserved operation or MASK value, or a descriptor address that is not a multiple of 4. ERR is set, CHERR says where, and the channel's DMXINT bit is set. The other channels carry on.

**Suggested use of the channels:** 0 for the SD card and 1 for the USB serial link (once they are targets), 2 for general copies and fills, 3 for graphics and the copper's jobs. Any channel can do any job.

---

## Starting Jobs from the Copper and Timers

The **copper** can start jobs at a chosen place on the screen. The channel registers are beyond a copper MOVE's reach, so it uses MOVEF, one byte per instruction: four MOVEFs write CHDESC and START. With the **B** bit, a copper WAIT also waits until every channel is idle, so a copper list can start a job and wait for it.

A **timer** can start a channel when it runs out (its CTRL.DMA and DMACH): the channel loads and runs the descriptor at its CHDESC, as if START had been written.

The copper chapter and spec 14, section 9, have the details.

---

## Speed

The blitter uses only memory cycles that nobody else wants: the Z80, the display, the sprites and the copper always come first. How fast it goes therefore depends on the screen and on what the CPU is doing. With a full-screen 8 bpp layer at 2×, 8 sprites and the CPU busy, it has about 1,190 memory cycles a line, which gives (figures worked out from the design; still to be measured):

| Job | Time | With `LDIR` |
|-----|------|-------------|
| Clear the 360 × 288 screen | about 1.4 ms | 109 ms |
| Copy the whole screen | about 2.8 ms | 109 ms |
| Draw a 32 × 32 object with a transparent colour | about 30 µs | about 1.1 ms (without transparency) |
| Save, restore and draw one 32 × 32 object (Example 6-2) | about 90 µs | – |

What a job costs, in memory cycles per 2 bytes of D:

| Job | Cycles | |
|-----|--------|-|
| Fill (BCONST, no C) | 1 | Only writes |
| Copy, or draw with MASKKEY at 8 bpp | 2 | Read B, write D |
| Draw with a mask image | 2 + 1 per 16 pixels | A is small |
| Any minterm that uses C, and ADD | 3 | Read B, read C, write D |

Tips:

- **Use 8 bpp for moving graphics.** No byte is shared between pixels, so nothing is read back.
- **Use a transparent colour (MASKKEY) rather than a mask image** where you can: it costs nothing.
- **Avoid minterms that read C** when a copy will do: a third of the cost of an XOR job is reading the screen.
- Waiting for the blitter in a loop gives it few extra cycles: the CPU's reads in a polling loop take about as many cycles as other code. Slowing the CPU (CPUSPEED) does give it more.

---

## Summary of Blitter Registers

Channel n's registers are at custom offset `0x140 + n × 0x40` (`DMX0`–`DMX3` in `hw.inc`), ports named with `_P` (`DMX2_CTRL_P` and so on; spec 14, section 8, lists them), and register page offset `0x1000` + custom offset.

| Offset | Name | Bytes | Access | Bits |
|--------|------|-------|--------|------|
| `+0x00` | CTRL | 3 | RW | CTRL0: OP (2–0: 0 BLIT, 1 ADD, 2–7 reserved), SAT (4), SIGNED (5). CTRL1: BPP (1–0), DESC (2), IRQ (3), BCONST (4), MASK (6–5: 0 none, 1 image, 2 key). CTRL2: 0 |
| `+0x03` | MINTERM | 1 | RW | Bit (A × 4 + B × 2 + C) is the result |
| `+0x04` | APT | 3 | RW | Mask image address |
| `+0x07` | BPT | 3 | RW | Image address |
| `+0x0A` | DPT | 3 | RW | Destination address |
| `+0x0D` | WIDTH | 3 | RW | Pixels across |
| `+0x10` | HEIGHT | 2 | RW | Rows |
| `+0x12` | SHIFT | 2 | RW | ABIT (2–0), BBIT (6–4), DBIT (10–8) |
| `+0x14` | ABSTRIDE | 2 | RW | Signed: A's and B's row to row |
| `+0x16` | CDSTRIDE | 2 | RW | Signed: D's row to row |
| `+0x18` | VALUE | 4 | RW | B's value with BCONST; the key colour with MASKKEY |
| `+0x1C` | NEXT | 3 | RW | Next descriptor, or 0 |
| `+0x20` | CHDESC | 3 | RW | First descriptor for START; the one running |
| `+0x24` | CHCTRL | 1 | W | START (0), RUN (1), STOP (2), PAUSE (3, also readable) |
| `+0x28` | CHSTAT | 1 | R, W1C | BUSY (0), DONE (1), ERR (2), PAUSED (3) |
| `+0x2C` | CHERR | 3 | R | Address of the last error |

The job registers (`+0x00`–`+0x1E`) and CHDESC are ignored while the channel is busy. Global registers: **DMXINT** at `0x230` (port `0x3012`), one bit per channel, write 1 to clear; **DMXINTEN** at `0x234` (port `0x3412`), the interrupt enables. **DMACON**.BLTEN and DMAEN let the engine run.

The full definition is spec 14, `docs/spec/dma-engine.md`.
