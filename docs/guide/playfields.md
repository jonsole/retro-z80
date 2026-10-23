# Chapter 3: Playfield Hardware

## Introduction

This chapter tells you how to put pictures on the screen. The retro-z80 display is built from **playfields**: pictures in SRAM that the hardware reads by DMA and turns into pixels while the beam sweeps the screen. In this machine the playfields are called **layers**. There are three, L0, L1 and L2, and each is a complete playfield of its own, with its own window, scroll, scale and colours.

Each layer is one of two kinds:

- a **bitmap**: a chunky picture of 1, 2, 4 or 8 bits per pixel, read through a pointer that walks through memory, as on retro68k and the Amiga;
- a **tile map**: a map of 8 × 8 tiles, each named by a 2-byte entry, which the hardware scrolls round by itself in both directions.

PRIO puts the three layers in any order, front to back. Each layer has its own palette of 256 colours of 24 bits, and a shallow layer picks a block of 16 of them.

The chapter covers:

- how the Z80 reaches the video registers: through I/O ports, and through the register page;
- the fixed screen mode and beam coordinates;
- forming a basic playfield, step by step;
- chunky pixels, how they sit in memory, and how the Z80 draws them through an MMU window;
- the display window, scaling and the stride;
- scrolling a bitmap, both fine and coarse, and endless scrolling with pointer wrap;
- resetting the pointer every frame, and double buffering;
- tile maps in depth: patterns, the map, entries, scrolling round the map, flips, colours per tile, priority per tile, and text;
- split screens;
- priority and transparency;
- the palettes, palette offsets and the background colour;
- direct colour;
- the fetch budget, and how to work out whether a screen fits;
- video interrupts and the beam position;
- when register writes take effect;
- the Spectrum extras: the Spectrum screen, the attribute layer and the port `0xFE` border.

You should know Z80 assembly language. The Interrupts chapter explains interrupt handlers in full; this chapter uses them without repeating the details. The copper, which can change any of these registers at an exact beam position, has its own chapter.

### Comparison with retro68k

retro-z80's video is retro68k's, narrowed to 8-bit registers, with tile maps added. If you have programmed retro68k's layers, most of this chapter will be familiar. The differences:

| Feature | retro68k | retro-z80 |
|---------|----------|-----------|
| Pixel formats | Planar (1–8 planes) or chunky (1, 2, 4, 8 bpp) | Chunky only (1, 2, 4, 8 bpp) |
| Tile maps | – | Any layer can be a tile map (CTRL0.MODE) |
| Pointers | BPL0PT–BPL7PT | BPL0PT only |
| Data registers | BPL0DAT–BPL7DAT, BPLDMA: a layer can be fed by the CPU | Inside the hardware only. A layer cannot be fed by the CPU |
| Registers | 32 bits, at `0xE00000` | Bytes, through I/O ports and the register page. Wider values low byte first; the highest byte commits |
| CTRL | One 32-bit register | Four byte registers, CTRL0–CTRL3, each written on its own |
| Layer blocks | `0x80` bytes from custom offset `0x100` | `0x20` bytes from custom offset `0x090` |
| Fine scroll, chunky layers | SCROLLX taken modulo the pixels in a word | Any SCROLLX from 0 to 15 at any depth |
| Palettes | Memory-mapped, 4-byte entries `0x00RRGGBB` | PALIDX and PALDAT ports, or the register page, 3-byte entries (blue, green, red) |
| Palette contents at power-on | Undefined | The Spectrum's 16 colours in entries 0–15 |
| Priority within a layer | – | A tile's PRI bit puts its pixels in front of all layers |
| A late fetch | May take the CPU's memory cycle | Never: the Z80 never waits for the display |
| Spectrum extras | – | The attribute layer and the port `0xFE` border |

Everything else is retro68k's: the one video mode, beam coordinates, the windows, the live pointer with its stride and wrap, scaling, PALOFS, SHAREPAL, PRIO, direct colour, the fetch, the budget, OVERRUN and the rules for when writes take effect.

### Reaching the registers from the Z80

Every register is a byte. The video registers are in the **custom block**, 1 KB of registers at custom offsets `0x000`–`0x3FF`. The Z80 reaches them in two ways, and both reach the same registers.

**Through I/O ports.** Every port is **register : page**: the high byte (A15–A8) is the register, the low byte (A7–A0) the page. Custom offsets `0x000`–`0x0FF` are page `0x10` (`CUSTPAGE`), `0x100`–`0x1FF` page `0x11`, and so on. So custom offset k is port `(k & 0xFF) << 8 | (0x10 + (k >> 8))`, and `hw.inc` gives it as the register's name with `_P`: PRIO is custom offset `0x003`, and `PRIO_P` is port `0x0310`.

```asm
        ld   bc,PRIO_P              ; B = register 0x03, C = page 0x10
        out  (c),a                  ; PRIO = A                          (22 T)
```

`OUT (C),r` puts B on A15–A8, which is what makes the register:page form work. `INC B` steps to the next register, so a value wider than a byte is written low byte first:

```asm
        ld   bc,L1_SCROLLY_P        ; a 2-byte register
        out  (c),l                  ; bits 7-0: held
        inc  b
        out  (c),h                  ; bits 15-8: commits the whole value (38 T)
```

C stays `0x10` for every offset below `0x100`, so `LD B,name` moves to another register of the same page: `ld b,L1_CTRL0` then `out (c),a`.

To read a register, put its number in A and use `IN A,(n)`, which puts A on A15–A8:

```asm
        ld   a,VIDSTAT              ; register 0x01 ...
        in   a,(CUSTPAGE)           ; ... of page 0x10: A = VIDSTAT     (18 T)
```

`OUT (n),A` is no use here: it would put A, the value, on A15–A8 as the register number. And never use `OTIR`, `PUSH`, `EX (SP),HL` or `LDDR` on a register wider than a byte: they write the high byte first, or step B downwards.

**Through the register page.** MMU page `0x3F8` is not memory: it shows the registers. Map it into a window and every register is a memory address, so the Z80 can use `LD (nn),A`, `LD (nn),HL`, `LD (IX+d),n`, `SET`, `RES` and `LDIR` on them. Register r of I/O page p is at offset p × 256 + r, the port with its two bytes swapped:

| Register page offset | Contents |
|----------------------|----------|
| `0x0000`–`0x00FF` | The system page (I/O page `0x00`): the interrupt controller, the MMU, the timers, … |
| `0x0100`–`0x0107` | KEYROW0–7, the keyboard rows (Spectrum extra) |
| `0x1000`–`0x13FF` | The custom block: custom offset k at `0x1000` + k |
| `0x1400`–`0x1FFF` | The four palettes, 3 bytes per entry (see "Colour Registers and Palette Offsets") |

The MMU registers are in the system page, so the first time you map the register page you must use ports. Window 7's read page is MMU7, registers `0x8E` and `0x8F` of page `0x00`; its two bytes are MMU7_0 and MMU7_1. Writing MMU7_1 commits the read page and sets the window's write page to the same page:

```asm
; Map the register page into window 7 (0xE000-0xFFFF), through ports.
map_regs:   ld   bc,MMU7_0_P        ; register 0x8E of the system page
            ld   a,0xF8
            out  (c),a              ; page bits 7-0: held
            inc  b                  ; MMU7_1
            ld   a,0x03
            out  (c),a              ; page bits 9-8: commits read and write page
            ret                     ; 62 T with the CALL's RET
```

From then on, custom offset k is at `0xF000` + k, and window 6's MMU register, say, is at `0xE000 + MMU6`. A window then changes with one `LD (nn),HL` (16 T-states).

The two ways compare like this (T-states at any speed; at 20 MHz a T-state is 50 ns):

| Job | Ports | Register page in window 7 |
|-----|-------|---------------------------|
| Write a 1-byte register (PRIO) | `LD BC` and `OUT (C),A`: 22 | `LD (nn),A`: 13 |
| Write a 2-byte register (SCROLLY) | 38 | `LD (nn),HL`: 16 |
| Write a 3-byte pointer (BPL0PT) | 54 | `LD (nn),HL` and `LD (nn),A`: 29 |
| Read a byte (VIDSTAT) | `LD A,n` and `IN A,(n)`: 18 | `LD A,(nn)`: 13 |
| Set one bit (CTRL0.TRANSP) | `LD BC`, `IN`, `OR`, `OUT`: 41 | `SET 4,(IX+d)`: 23 |
| Write a whole layer (32 bytes) from a table | 32 × `OUT`/`INC B`, about 550 | `LDIR`: 667, or 32 × `LDI`: 512 |
| Load a palette (768 bytes) | `OUTI` and `INC B` (see "Loading a palette"): 15,360 | `LDIR`: 16,123, or unrolled `LDI`: 12,288 |

Two rules from the register map matter all through this chapter:

- **Low byte first; the highest byte commits.** Writing a lower byte only holds it. Writing the highest byte commits the whole value at once, so the hardware never sees half a value. To change only the high byte, write just the high byte. `LD (nn),HL`, `LDI`, `LDIR` and `OUT (C),r` with `INC B` all write low byte first.
- **Reading the lowest byte captures.** For registers the hardware changes by itself (BEAMPOS, FRAMECOUNT, BPL0PT), reading the lowest byte captures the whole value, and the higher bytes then read the captured copy. `LD HL,(nn)` reads the low byte first, so it always gives a matching pair.

The multi-byte rule has one exception in this chapter: **CTRL0–CTRL3 are four separate byte registers**, not one value. Each acts when it is written.

### Conventions in this chapter

- Examples are Z80 assembly language for sjasmplus and start with `include "hw.inc"`, the equates generated from the register map. Numbers in the text are hexadecimal when they start with `0x`.
- A custom register's name in `hw.inc` is its custom offset (`PRIO` = `0x003`); a system register's name is its register number (`MMU6` = `0x8C`). `name_P` is the port. `L0`, `L1` and `L2` are the layers' offsets (`0x090`, `0x0B0`, `0x0D0`), `L_CTRL0` … `L_PATPT` the offsets inside a layer, and `L1_SCROLLY` the ready-added name. Each byte of a wider register has a name too, lowest first: `L0_BPL0PT0`, `L0_BPL0PT1`, `L0_BPL0PT2`; `MMU7_0`, `MMU7_1`. Fields give `name_FIELD_B` (first bit), `name_FIELD_M` (mask).
- **The register page is in window 7, at `0xE000`–`0xFFFF`, all the time.** The examples call it `REGS` and write registers through it, because that is faster than ports and lets the Z80 use 16-bit loads, `LDIR`, `SET` and `RES` on registers. Interrupt handlers rely on it too, so window 7 never changes. Ports are used where the register page is not mapped yet, and they are the way for library code that cannot rely on window 7.
- **IX points at a layer** when code sets up a layer field by field, as `a0` does in retro68k's examples: `ld (ix+L_CTRL1),value`. A whole layer is set up from a 32-byte table with `LDIR` (see "Setting up a layer from a table").
- These equates are at the top of every complete example:

  ```asm
  REGS        equ     0xE000              ; the register page, in window 7
  SREG        equ     REGS+REGS_SYSTEM    ; 0xE000: system register r at SREG + r
  CREG        equ     REGS+REGS_CUSTOM    ; 0xF000: custom offset k at CREG + k
  PREG        equ     REGS+REGS_PALETTE   ; 0xF400: palette p at PREG + p * REGS_PAL_SPAN
  ```

- **Physical and Z80 addresses.** The display reads SRAM by 22-bit physical address, not through the MMU. In the examples physical addresses have names like `SCREEN` (`0x040000`), and the Z80 reaches them by mapping their 8 KB page (address ÷ `0x2000`) into a window: window 6, at `0xC000`, is the drawing window, `DRAWWIN`.
- The complete examples are loaded at `0x8000` and assume windows 2–6 still show SRAM pages 0–4, as after reset, so Z80 address a in `0x4000`–`0xDFFF` is physical address a − `0x4000` (`RAMOFS`). The stack is at `0xBF00` and the IM 2 table at `0xBFD0`. (What the boot ROM leaves when it starts a program is not specified yet.)
- Comments give T-states where they help. The CPU runs at 20 MHz: a 576p line is 640 T-states, a frame 400,000.

### About this chapter

The first sections build a working screen as quickly as possible: "The Screen" describes the one video mode, and "Forming a Basic Playfield" goes through the registers in the order you set them, ending with a complete program. The sections after that explain bitmaps in more depth: chunky pixels and how the Z80 draws them, the window, scaling, the stride, scrolling and resetting the pointer. "Tile Maps" is the longest section, since tile maps are new in this machine. Then come split screens and the parts that concern more than one layer: priority, the palettes and direct colour. "The Fetch Budget" tells you how to check a screen design before you build it. The chapter ends with the video interrupts, the timing rules, the Spectrum extras and a summary of every register.

---

## The Screen

The display has **one video mode, 576p**: 720 × 576 at 50 Hz, as the CEA-861 standard defines it, on HDMI and VGA at the same time. It is the digital form of PAL. There are no timing registers.

| Mode | Pixel clock | Visible | Total (pixels × lines) | Line time | Frame | Refresh |
|------|-------------|---------|------------------------|-----------|-------|---------|
| 576p | 27 MHz | 720 × 576 | 864 × 625 | 32.0 µs (640 T) | 20.0 ms (400,000 T) | 50 Hz |

The frame rate is the Spectrum's, so a Spectrum program's timing by frames carries over.

### Beam coordinates

Every position the hardware uses (the beam position, LINECMP, the copper's WAIT and SKIP, layer windows and sprite windows) is given in **beam coordinates**: **beam pixels** across (`hpixel`) and **beam lines** down (`vline`). They count the blanking too. Each line starts with its **horizontal blank** and then shows its 720 pixels. Each frame starts with the **vertical blank** and then shows its 576 lines.

| | Beam pixels (across) | Beam lines (down) |
|--|--|--|
| 0 | The start of the horizontal blank | The start of the vertical blank |
| Blank | 0–143 | 0–48 |
| The picture | 144–863 (720 pixels) | 49–624 (576 lines) |
| Total | 864 per line | 625 per frame |

```
  hpixel  0              144 (VID_X0)                 864
 vline 0 +--------------+------------------------------+
         |          vertical blank (lines 0-48)        |
      49 +--------------+------------------------------+
(VID_Y0) |              |                              |
         |  horizontal  |           picture            |
         |    blank     |          720 x 576           |
         |   (0-143)    |                              |
     625 +--------------+------------------------------+

                  Figure 3-1: The Screen and the Beam
```

The horizontal blank is 144 pixels (5.33 µs, 107 T-states). The vertical blank is 49 lines (1.57 ms, 31,360 T-states). Positions only go up through a frame.

`hw.inc` gives the picture's top left corner as **VID_X0** (144) and **VID_Y0** (49), its size as **VID_W** (720) and **VID_H** (576), and the beam's total as **BEAM_W** (864) and **BEAM_H** (625). The picture's pixel (x, y), counted from its top left corner, is at beam position (VID_X0 + x, VID_Y0 + y). This chapter calls that **picture position** (x, y).

The pixels are not quite square: on a 4:3 screen each one is 16/15 as wide as it is tall.

### Normal screens and overscan

HDMI sends exactly the visible pixels, so the whole 720 × 576 is the **overscan** area. A normal screen is a smaller window in it, with the background colour round it as the border:

| Screen | Source | Window (beam coordinates) |
|--------|--------|---------------------------|
| Full screen | 360 × 288 at 2 × 2 | 144–864 × 49–625 |
| Spectrum size | 256 × 192 at 2 × 2 | 248–760 × 145–529 (centred) |
| PAL Amiga lores | 320 × 256 at 2 × 2 | 184–824 × 81–593 |
| 640 × 400 text | 80 × 25 characters of 8 × 8 at 1 × 2 | 184–824 × 137–537 |
| 640 × 480 (the boot console) | 80 × 30 characters at 1 × 2 | 184–824 × 97–577 |

A computer monitor shows all 720 × 576 pixels. A TV may crop a few percent off each edge, so keep text and anything important inside the normal area.

VIDSIZE holds the screen size. Its two halves are HVISIBLE (720) and VVISIBLE (576), 2 bytes each:

```asm
        ld   hl,(CREG+VIDSIZE)      ; HVISIBLE: 720
        ld   de,(CREG+VIDSIZE+2)    ; VVISIBLE: 576
```

---

## Forming a Basic Playfield

To show a picture you need: the picture in SRAM, a display window, a pointer, a stride, some colours, and the layer, its DMA and the display turned on. This section goes through the steps for one layer showing a 320 × 256 picture in 16 colours at 2 × 2, as a 640 × 512 window in the middle of the screen: the shape of the Amiga's PAL lores screen. Each step is explained in more detail later in the chapter.

### Step 1: Choose the format and place the picture

A bitmap layer is **chunky**: all the bits of a pixel are together, packed into bytes with the leftmost pixel in the highest bits. For 16 colours you need 4 bits per pixel, two pixels to a byte. One line of 320 pixels is 160 bytes.

The picture can be anywhere in SRAM, at an even address. The Z80 does not see it directly: it maps the picture's 8 KB pages into a window when it draws. That is easiest if no line crosses from one page into the next, so this example spaces its lines **256 bytes apart**. Line y then starts at `SCREEN + y × 256`: its page is `SCREEN ÷ 0x2000 + y ÷ 32`, and inside the page the high byte of the address is just `y mod 32`. The last 96 bytes of each line are not shown. The picture takes 64 KB instead of 40 KB, out of 4 MB.

```asm
SCREEN      equ     0x040000            ; the picture: physical address, 8 KB-aligned
WIDTH       equ     320                 ; source pixels across
HEIGHT      equ     256                 ; source lines
STRIDE      equ     256                 ; bytes from line to line (160 shown)
```

### Step 2: Define the display window

The **display window** is the rectangle of the screen where the layer shows. It is given in beam coordinates by WINX and WINY. WINX is two 2-byte values: XEND first (layer offset `+0x04`), then XSTART (`+0x06`). WINY is the same: YEND (`+0x08`), then YSTART (`+0x0A`). The window includes XSTART and YSTART but stops just before XEND and YEND. Outside its window, a layer is transparent.

The picture is 320 × 256, and the layer will show each source pixel 2 × 2, so it covers 640 × 512 screen pixels. Centred in the 720 × 576 picture, that window starts at picture position (40, 32), which is beam position (184, 81):

```asm
WIN_X       equ     VID_X0+(VID_W-2*WIDTH)/2    ; 144 + 40 = 184
WIN_Y       equ     VID_Y0+(VID_H-2*HEIGHT)/2   ; 49 + 32 = 81

        ld   ix,CREG+L0             ; IX = layer 0
        ld   hl,WIN_X+2*WIDTH
        ld   (ix+L_WINX),l          ; XEND 824: low byte held ...
        ld   (ix+L_WINX+1),h        ; ... high byte commits
        ld   hl,WIN_X
        ld   (ix+L_WINX+2),l        ; XSTART 184
        ld   (ix+L_WINX+3),h
        ld   hl,WIN_Y+2*HEIGHT
        ld   (ix+L_WINY),l          ; YEND 593
        ld   (ix+L_WINY+1),h
        ld   hl,WIN_Y
        ld   (ix+L_WINY+2),l        ; YSTART 81
        ld   (ix+L_WINY+3),h
```

You never set a data-fetch start or stop: the hardware works out from the window, the scale and the fine scroll what to fetch and when.

### Step 3: Set the pointer

A bitmap layer has one pointer, **BPL0PT**: 3 bytes, the physical address of the next word to fetch. Before the first line of the window it must hold the address of the picture's first line. As each word is fetched the pointer moves on by 2, so during the frame it walks through memory; it does not go back by itself.

```asm
setptr:     ld   hl,SCREEN&0xFFFF
            ld   (CREG+L0_BPL0PT),hl    ; bits 15-0: held
            ld   a,SCREEN>>16
            ld   (CREG+L0_BPL0PT+2),a   ; bits 21-16: commits
            ret
```

### Step 4: Set the stride

At the end of each line, the hardware moves the pointer to the start of the next line: the start of the line just shown plus the stride, **BPLSTRIDE**. The stride is the number of bytes from the start of one line to the start of the next, here 256.

```asm
        ld   (ix+L_BPLSTRIDE),STRIDE&0xFF
        ld   (ix+L_BPLSTRIDE+1),STRIDE>>8
```

### Step 5: Set the colours

Each layer has its own palette of 256 entries of 24-bit colour. Each entry is 3 bytes: blue, green, red. Layer 0's is PALETTE0, at `PREG` (`0xF400`) in the register page. A 4-bit layer uses 16 entries: 0–15 unless you choose another block with the palette offset (step 6). Writing an entry's red byte changes the whole entry, so a rising `LDIR` loads colours whole.

At power-on the palettes already hold the Spectrum's 16 colours in entries 0–15. This example sets its own anyway. sjasmplus's `D24` stores a 3-byte value low byte first, so `d24 0xRRGGBB` gives blue, green, red, the order the palette wants.

```asm
        ld   hl,colours
        ld   de,PREG                ; PALETTE0, entry 0
        ld   bc,16*3
        ldir                        ; 16 entries: 1,003 T

colours:    d24     0x000000,0xFFFFFF,0xFF0000,0x00FF00,0x0000FF,0xFFFF00,0x00FFFF,0xFF00FF
            d24     0x808080,0xC0C0C0,0x800000,0x008000,0x000080,0x808000,0x008080,0x800080
```

The **background colour**, BGCOLOR, shows wherever no layer has a pixel. It is a 3-byte register of its own (blue, green, red; the red byte commits):

```asm
        ld   hl,0x0000
        ld   (CREG+BGCOLOR),hl      ; blue, green: held
        xor  a
        ld   (CREG+BGCOLOR+2),a     ; red: commits. Black
```

### Step 6: Set the layer's format and turn it on

CTRL0 and CTRL1 hold the format, the scale, the colour block and the enable bit:

| Register | Bits | Field | Here |
|----------|------|-------|------|
| CTRL0 | 0 | EN | 1: the layer is on |
| CTRL0 | 3–2 | BPP | 2: 4 bits per pixel |
| CTRL0 | 5 | MODE | 0: bitmap |
| CTRL0 | 7–6 | HSCALE | 1: each source pixel 2 screen pixels wide |
| CTRL1 | 1–0 | VSCALE | 1: each source line shown on 2 screen lines |
| CTRL1 | 7–4 | PALOFS | 0: colours 0–15 |

CTRL2 holds the pointer wrap and CTRL3 the tile map's size; both are 0 here. Write CTRL0 last, since it turns the layer on:

```asm
        ld   (ix+L_CTRL3),0
        ld   (ix+L_CTRL2),0
        ld   (ix+L_CTRL1),(1<<L_CTRL1_VSCALE_B)|(0<<L_CTRL1_PALOFS_B)
        ld   (ix+L_CTRL0),L_CTRL0_EN_M|(2<<L_CTRL0_BPP_B)|(1<<L_CTRL0_HSCALE_B)
```

PRIO says which layer is in front; after reset it is L0, then L1, then L2.

### Step 7: Arrange for the pointer to be reset each frame

At the end of a frame the pointer has walked off the end of the picture. Something must put it back before the next frame starts. The copper can do it (see the Copper chapter); here the CPU does it in the **vertical blank interrupt**. The handler clears the VBLANK flag and writes the pointer again:

```asm
vblank:     push af
            push hl
            ld   a,VIDSTAT_VBLANK_M
            ld   (CREG+VIDSTAT),a       ; clear the flag
            call setptr
            pop  hl
            pop  af
            ei
            reti                        ; about 150 T, 7.5 us
```

To enable it: put the handler's address in the IM 2 table, enable VBLANK in the video unit (VIDINTEN) and in the interrupt controller (INTENA0 and INTCON), and do `EI`. The Interrupts chapter explains each switch.

### Step 8: Turn on layer DMA and the display

The layers fetch only when **DMACON.DMAEN** and **DMACON.BPLEN** are both set and the display is on (**VIDCON.EN**). DMACON is a set/clear register: writing it with bit 7 (SETCLR) set sets the bits written as 1; with bit 7 clear, it clears them. Bits written as 0 are left alone.

```asm
        ld   a,DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_BPLEN_M
        ld   (CREG+DMACON),a
        ld   a,VIDCON_EN_M
        ld   (CREG+VIDCON),a
```

### Example 3-1: A basic playfield

Here are the steps put together. The picture is a pattern of 16 × 16-pixel squares in all 16 colours. The start-up routines at the end (`map_regs`, `video_off`, `im2_init`) are used by the other complete examples in this chapter too.

```asm
; Example 3-1: a basic playfield. A 320 x 256 chunky picture at 4 bits per
; pixel (16 colours), shown 2x across and 2x down as a 640 x 512 window in
; the middle of the 720 x 576 picture. Lines are 160 bytes, 256 apart.

            include "hw.inc"

REGS        equ     0xE000              ; the register page, in window 7
SREG        equ     REGS+REGS_SYSTEM    ; 0xE000: system register r at SREG + r
CREG        equ     REGS+REGS_CUSTOM    ; 0xF000: custom offset k at CREG + k
PREG        equ     REGS+REGS_PALETTE   ; 0xF400: the palettes
DRAWWIN     equ     0xC000              ; window 6: for drawing into SRAM
IM2TAB      equ     0xBFD0              ; IM 2 table: I = 0xBF, VECBASE = 0xD0
STACK       equ     0xBF00

SCREEN      equ     0x040000            ; the picture: physical, 8 KB-aligned
WIDTH       equ     320
HEIGHT      equ     256
STRIDE      equ     256                 ; bytes from line to line (160 shown)
WIN_X       equ     VID_X0+(VID_W-2*WIDTH)/2    ; 184
WIN_Y       equ     VID_Y0+(VID_H-2*HEIGHT)/2   ; 81

            org     0x8000
start:      di
            ld      sp,STACK
            call    map_regs            ; the register page into window 7
            call    video_off           ; whatever was left on, off
            call    im2_init
            call    draw                ; step 1: the picture in SRAM

            ld      ix,CREG+L0          ; IX = layer 0
            ; step 2: the window, in beam coordinates
            ld      hl,WIN_X+2*WIDTH
            ld      (ix+L_WINX),l       ; XEND 824
            ld      (ix+L_WINX+1),h
            ld      hl,WIN_X
            ld      (ix+L_WINX+2),l     ; XSTART 184
            ld      (ix+L_WINX+3),h
            ld      hl,WIN_Y+2*HEIGHT
            ld      (ix+L_WINY),l       ; YEND 593
            ld      (ix+L_WINY+1),h
            ld      hl,WIN_Y
            ld      (ix+L_WINY+2),l     ; YSTART 81
            ld      (ix+L_WINY+3),h
            ld      (ix+L_SCROLLX),0    ; no fine scroll
            ld      (ix+L_SCROLLX+1),0
            ; step 3: the pointer
            call    setptr
            ; step 4: the stride
            ld      (ix+L_BPLSTRIDE),STRIDE&0xFF
            ld      (ix+L_BPLSTRIDE+1),STRIDE>>8
            ; step 5: the colours and the background
            ld      hl,colours
            ld      de,PREG             ; PALETTE0, entry 0
            ld      bc,16*3
            ldir
            ld      hl,0x0000
            ld      (CREG+BGCOLOR),hl   ; blue, green
            xor     a
            ld      (CREG+BGCOLOR+2),a  ; red: commits
            ; step 6: 4 bpp bitmap, 2x by 2x, colours 0-15, on; L0 in front
            ld      (ix+L_CTRL3),0
            ld      (ix+L_CTRL2),0
            ld      (ix+L_CTRL1),1<<L_CTRL1_VSCALE_B
            ld      (ix+L_CTRL0),L_CTRL0_EN_M|(2<<L_CTRL0_BPP_B)|(1<<L_CTRL0_HSCALE_B)
            ld      a,(2<<PRIO_BACK_B)|(1<<PRIO_MIDDLE_B)|(0<<PRIO_FRONT_B)
            ld      (CREG+PRIO),a
            ; step 7: reset the pointer in every vertical blank
            ld      hl,vblank
            ld      (IM2TAB+2*INT_VBLANK),hl
            ld      a,VIDSTAT_VBLANK_M
            ld      (CREG+VIDSTAT),a    ; clear an old flag
            ld      (CREG+VIDINTEN),a   ; the video unit may ask
            ld      a,INTENA_SETCLR_M|(1<<INTB_VBLANK)
            ld      (SREG+INTENA0+INTR_VBLANK),a    ; the controller's enable
            ld      a,INTCON_MASTER_M
            ld      (SREG+INTCON),a
            ; step 8: layer DMA and the display on
            ld      a,DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_BPLEN_M
            ld      (CREG+DMACON),a
            ld      a,VIDCON_EN_M
            ld      (CREG+VIDCON),a
            ei

main:       halt                        ; (your program's main loop goes here)
            jr      main

; Layer 0's pointer to the top of the picture
setptr:     ld      hl,SCREEN&0xFFFF
            ld      (CREG+L0_BPL0PT),hl ; bits 15-0: held
            ld      a,SCREEN>>16
            ld      (CREG+L0_BPL0PT+2),a    ; bits 21-16: commits
            ret

; Vertical blank: clear the flag, put the pointer back to the top
vblank:     push    af
            push    hl
            ld      a,VIDSTAT_VBLANK_M
            ld      (CREG+VIDSTAT),a
            call    setptr
            pop     hl
            pop     af
            ei
            reti

; A test picture: squares of 16 x 16 pixels, colour (x/16 + y/16) and 15.
; Line y is in page SCREEN/0x2000 + y/32, at 0xC000 + (y and 31) * 256.
draw:       ld      c,0                 ; C = the line, y
.line:      ld      a,c
            and     31
            jr      nz,.mapped          ; the same page as the line before
            ld      a,c
            rlca
            rlca
            rlca
            and     7                   ; y / 32
            add     a,(SCREEN>>13)&0xFF
            ld      l,a
            ld      h,SCREEN>>21        ; HL = the page
            ld      (SREG+MMU6),hl      ; mapped at 0xC000 (16 T)
.mapped:    ld      a,c
            and     31
            add     a,DRAWWIN>>8
            ld      h,a
            ld      l,0                 ; HL = line y in the window
            ld      a,c
            rrca
            rrca
            rrca
            rrca
            ld      e,a                 ; E, bits 3-0: y / 16, the first colour
            ld      b,WIDTH/16          ; 20 squares
.square:    ld      a,e
            and     0x0F
            ld      d,a
            add     a,a
            add     a,a
            add     a,a
            add     a,a
            or      d                   ; the colour in both halves: 2 pixels
            DUP     8
            ld      (hl),a              ; 8 bytes: 16 pixels
            inc     l
            EDUP
            inc     e                   ; the next square's colour
            djnz    .square
            inc     c
            jr      nz,.line            ; 256 lines; about 37 ms in all
            ret

colours:    d24     0x000000,0xFFFFFF,0xFF0000,0x00FF00,0x0000FF,0xFFFF00,0x00FFFF,0xFF00FF
            d24     0x808080,0xC0C0C0,0x800000,0x008000,0x000080,0x808000,0x008080,0x800080

; ---- Start-up routines, used by the other examples too ----

; Map the register page (MMU page 0x3F8) into window 7. Through ports:
; no window shows the MMU registers yet.
map_regs:   ld      bc,MMU7_0_P         ; register 0x8E of the system page
            ld      a,0xF8
            out     (c),a               ; page bits 7-0: held
            inc     b                   ; MMU7_1
            ld      a,0x03
            out     (c),a               ; bits 9-8: commits read and write page
            ret

; Turn off what a program before us may have left on: layer DMA, the
; copper, the sprites, every layer, the attribute layer and the video
; interrupts. The background colour shows.
video_off:  ld      a,DMACON_BPLEN_M|DMACON_COPEN_M|DMACON_SPREN_M
            ld      (CREG+DMACON),a     ; SETCLR clear: these off
            xor     a
            ld      (CREG+L0_CTRL0),a
            ld      (CREG+L1_CTRL0),a
            ld      (CREG+L2_CTRL0),a
            ld      (CREG+ATCTL),a
            ld      (CREG+VIDINTEN),a
            ret

; IM 2 with its table at IM2TAB. Every entry points at "spurious" until a
; handler is put in its place.
im2_init:   ld      hl,IM2TAB
            ld      de,spurious
            ld      b,24                ; sources 0-20, 21-22 and NONE (23)
.fill:      ld      (hl),e
            inc     hl
            ld      (hl),d
            inc     hl
            djnz    .fill
            ld      a,IM2TAB>>8
            ld      i,a
            ld      a,IM2TAB&0xFF
            ld      (SREG+VECBASE),a
            im      2
            ret

spurious:   ei
            ret
```

The background colour, black here, shows round the window as a border: 40 pixels at each side and 32 lines at the top and bottom. For a full overscan picture, make the window larger, up to the whole 720 × 576 (see "Scaling").

`video_off` turns off the boot console, which is layer 0 in tile mode, so the screen shows only the background until the new layer is on. It clears BPLEN first, so no layer fetches while the others are being set up.

### Setting up a layer from a table

A layer's registers are 32 consecutive bytes, from CTRL0 at `+0x00` to PATPT at `+0x1C`. So a whole layer can be written from a 32-byte table with one `LDIR` (667 T-states), which writes every register low byte first. The reserved bytes ignore writes. Layer 0 of Example 3-1 as a table:

```asm
layer0:     db      L_CTRL0_EN_M|(2<<L_CTRL0_BPP_B)|(1<<L_CTRL0_HSCALE_B)  ; CTRL0
            db      1<<L_CTRL1_VSCALE_B ; CTRL1: 2x down, PALOFS 0
            db      0,0                 ; CTRL2 (no wrap), CTRL3
            dw      WIN_X+2*WIDTH,WIN_X ; WINX: XEND, XSTART
            dw      WIN_Y+2*HEIGHT,WIN_Y    ; WINY: YEND, YSTART
            dw      0,0                 ; SCROLLX, SCROLLY
            dw      STRIDE              ; BPLSTRIDE
            dw      0                   ; (reserved)
            d24     SCREEN              ; BPL0PT
            db      0                   ; (reserved)
            d24     0                   ; MAPPT (tile maps only)
            db      0
            d24     0                   ; PATPT (tile maps only)
            db      0

            ld      hl,layer0
            ld      de,CREG+L0
            ld      bc,L_SPAN           ; 32 bytes
            ldir
```

`LDIR` writes CTRL0 first, so the layer is on before its other registers are written. It takes about one line, so do it with DMACON.BPLEN off, as `video_off` leaves it, or in the vertical blank. The later examples set up their layers this way.

### Stopping the display

To turn a layer off, write 0 to its CTRL0. To stop all layer DMA, clear BPLEN in DMACON: no layer and no attribute layer then fetches, and none shows. To show only the background colour, set VIDCON.BLANKALL: the layers keep running, but nothing of theirs shows. Clearing VIDCON.EN stops the beam itself: there is no picture and no sync, so the monitor loses the signal.

```asm
        ld   a,DMACON_BPLEN_M
        ld   (CREG+DMACON),a        ; SETCLR clear: BPLEN off
```

---

## Chunky Pixels

A bitmap layer, and each tile of a tile layer, is made of **chunky pixels**: CTRL0.BPP gives the depth, and all the bits of a pixel are kept together.

| BPP | Bits per pixel | Pixels per byte | Colours |
|-----|----------------|-----------------|---------|
| 0 | 1 | 8 | 2 |
| 1 | 2 | 4 | 4 |
| 2 | 4 | 2 | 16 |
| 3 | 8 | 1 | 256 |

Pixels are packed into bytes with the **leftmost pixel in the highest bits**, and the bytes go left to right at rising addresses. At 8 bpp each byte is one pixel, so a picture is simply an array of bytes. At 1 bpp the layout is a Spectrum's: bit 7 is the left pixel.

```
 one byte:      bit 7                                   bit 0
   1 bpp:       | p0 | p1 | p2 | p3 | p4 | p5 | p6 | p7 |
   2 bpp:       |   p0    |   p1    |   p2    |   p3    |
   4 bpp:       |        p0         |        p1         |
   8 bpp:       |                  p0                   |

   bytes left to right at rising addresses: byte 0 holds the leftmost pixels

               Figure 3-2: Chunky Pixels in a Byte
```

The number of bytes in one line of a picture is width × bits per pixel ÷ 8: 320 bytes for 320 pixels at 8 bpp, 160 at 4 bpp, 40 at 1 bpp. The hardware fetches 16 source pixels at a time, so a line it shows must have whole 16-pixel groups of data: 2 bytes at 1 bpp, 8 bytes at 4 bpp.

### Memory needed

| Picture | Bits per pixel | Bytes, lines packed | Bytes, lines a power of 2 apart |
|---------|----------------|---------------------|----------------------------------|
| 256 × 192 (Spectrum screen) | 1 | 6,144 | 8,192 (32 bytes a line, as packed) |
| 640 × 480 | 1 | 38,400 | 61,440 (128 bytes a line) |
| 320 × 256 | 4 | 40,960 | 65,536 (256) |
| 360 × 288 | 4 | 51,840 | 73,728 (256) |
| 320 × 256 | 8 | 81,920 | 131,072 (512) |
| 360 × 288 | 8 | 103,680 | 147,456 (512) |
| 720 × 576 | 8 | 414,720 | 589,824 (1,024) |

There are 4 MB of SRAM (2 MB on some boards), so even a 256-colour full screen leaves room for several buffers.

### Drawing into a layer

The display reads the picture by physical address. The Z80 sees only 64 KB, in eight 8 KB windows, so it draws by mapping the picture's pages into a window, one at a time. A physical address splits into a page (address ÷ `0x2000`) and an offset in the page (address and `0x1FFF`).

A stride that is a power of two keeps every line inside one page and makes the arithmetic cheap. With 256 bytes from line to line, as in Example 3-1, a page holds 32 lines; with 512, 16 lines. The cost is the padding at the end of each line, and the padding can hold other data.

This routine plots one pixel on the screen of Example 3-1:

```asm
; Plot colour B (0-15) at x = DE (0-319), y = C (0-255) on Example 3-1's
; screen: 4 bpp, lines 256 bytes apart. Maps the line's page into window 6.
; About 175 T-states, plus the CALL.
plot4:      ld      a,c
            rlca
            rlca
            rlca
            and     7                   ; y / 32: 32 lines to a page
            add     a,(SCREEN>>13)&0xFF
            ld      l,a
            ld      h,SCREEN>>21
            ld      (SREG+MMU6),hl      ; the line's page at 0xC000
            ld      a,c
            and     31
            add     a,DRAWWIN>>8
            ld      h,a                 ; H: the line in the window
            ld      a,d
            rra                         ; bit 8 of x into the carry
            ld      a,e
            rra
            ld      l,a                 ; L = x / 2: HL = the pixel's byte
            ld      a,b
            bit     0,e
            jr      nz,.right
            add     a,a                 ; an even x is the left pixel:
            add     a,a                 ; the high 4 bits
            add     a,a
            add     a,a
            ld      b,a
            ld      a,(hl)
            and     0x0F
            or      b
            ld      (hl),a
            ret
.right:     ld      b,a                 ; an odd x: the low 4 bits
            ld      a,(hl)
            and     0xF0
            or      b
            ld      (hl),a
            ret
```

That is about 100,000 pixels a second at 20 MHz. Nearly a third of the time goes on mapping the page, so a routine that draws a run of pixels on one line, or a block of lines in the same page, maps it once. An 8 bpp layer is faster still: a pixel is a byte, with no masking.

Large jobs, such as clearing a screen or copying a picture into place, belong to the DMA engine, which has its own chapter; see also "What the CPU can draw in a frame" under "The Fetch Budget".

### Summary: format registers

| Register | Field | Bits | Function |
|----------|-------|------|----------|
| CTRL0 | BPP | 3–2 | 0–3 for 1, 2, 4, 8 bits per pixel |
| CTRL0 | MODE | 5 | 0: bitmap, 1: tile map |
| BPL0PT | ADDR | 21–1 | Bitmap: physical address of the next word; even |

---

## The Display Window

Each layer has its own display window, set by WINX and WINY in beam coordinates:

| Register | Layer offset | Bytes | Meaning |
|----------|--------------|-------|---------|
| WINX (XEND) | `+0x04`–`+0x05` | 2 | First beam pixel after the window. Reset 864 |
| WINX (XSTART) | `+0x06`–`+0x07` | 2 | First beam pixel of the window. Reset 144 |
| WINY (YEND) | `+0x08`–`+0x09` | 2 | First beam line after the window. Reset 625 |
| WINY (YSTART) | `+0x0A`–`+0x0B` | 2 | First beam line of the window. Reset 49 |

Each of the four is a 2-byte value on its own, committed by its high byte. The window covers `XSTART ≤ hpixel < XEND` and `YSTART ≤ vline < YEND`. The value after reset is the full screen: 144, 864, 49, 625. Outside its window, a layer is transparent: lower layers or the background colour show through, and nothing is fetched for it.

A window is clamped to the picture. A start in the blank counts as the picture's edge: the layer's first pixel then shows there, at VID_X0 or VID_Y0, so a layer is not clipped as a sprite is. An end past the last pixel or line counts as the picture's end.

```
        VID_X0                                       VID_X0+VID_W
 VID_Y0 +-------------------------------------------------------+
        |                                                       |
        |        XSTART                    XEND                 |
        | YSTART   +-------------------------+                  |
        |          |                         |                  |
        |          |   the layer's pixels    |                  |
        |          |                         |                  |
        | YEND     +-------------------------+                  |
        |          (first line after the window)                |
        +-------------------------------------------------------+
 VID_Y0+VID_H

                 Figure 3-3: A Layer's Display Window
```

Because every layer has its own window, windows can overlap, sit side by side, or be stacked one above the other. A status panel at the bottom of the screen is simply a second layer with a window covering the bottom lines; it needs no copper.

The window is given in **screen** pixels (beam pixels). With scaling (next section), it covers fewer **source** pixels: a 640-pixel-wide window at 2× shows 320 source pixels.

### Centring a window

There is one screen size, so a centred window can be worked out when you assemble. For a window W pixels wide and H lines high, XSTART is VID_X0 + (720 − W) ÷ 2 and YSTART is VID_Y0 + (576 − H) ÷ 2. This sets layer 1 to the Spectrum-sized window, 512 × 384, at beam pixels 248–760 and lines 145–529:

```asm
WIN_W       equ     512
WIN_H       equ     384
WIN_X       equ     VID_X0+(VID_W-WIN_W)/2  ; 248
WIN_Y       equ     VID_Y0+(VID_H-WIN_H)/2  ; 145

        ld   hl,WIN_X+WIN_W
        ld   (CREG+L1_WINX),hl      ; XEND
        ld   hl,WIN_X
        ld   (CREG+L1_WINX+2),hl    ; XSTART
        ld   hl,WIN_Y+WIN_H
        ld   (CREG+L1_WINY),hl      ; YEND
        ld   hl,WIN_Y
        ld   (CREG+L1_WINY+2),hl    ; YSTART
```

### When window changes take effect

The hardware reads CTRL0–CTRL3, WINX, WINY, SCROLLX and SCROLLY for each line at the start of its horizontal blank (beam pixel 0), before its picture. **To change line L, write during the visible part of line L − 1 or earlier.** This lets you move a window or change a layer's format partway down the screen.

### How much is fetched

The window also decides how much the hardware fetches for each line of a bitmap layer:

```
   source pixels  =  window width ÷ horizontal scale   (rounded up)
   groups         =  (fine scroll + source pixels) ÷ 16, rounded up
   bytes fetched  =  groups × 2 × bits per pixel
```

| Window width | Scale | Depth | Source pixels | Bytes fetched per line |
|--------------|-------|-------|---------------|------------------------|
| 640 | 2× | 4 bpp | 320 | 160 |
| 640 | 2× | 8 bpp | 320 | 320 |
| 720 | 2× | 8 bpp | 360 | 368 (23 groups) |
| 512 | 2× | 1 bpp | 256 | 32 |
| 640 | 1× | 1 bpp | 640 | 80 |

With fine scroll the hardware may fetch one group more. The picture must have this much data on each line. How much is fetched plays no part in where the next line starts: the stride alone decides that.

---

## Scaling

Each layer can show every source pixel 1, 2, 4 or 8 times across (CTRL0.HSCALE) and every source line 1, 2, 4 or 8 times down (CTRL1.VSCALE), independently:

| HSCALE, VSCALE | Scale |
|----------------|-------|
| 0 | 1× |
| 1 | 2× |
| 2 | 4× |
| 3 | 8× |

This gives the low-resolution looks of older machines on a modern screen, with sharp pixels:

| Picture | Scale | On the 720 × 576 picture | Looks like |
|---------|-------|--------------------------|------------|
| 256 × 192 | 2 × 2 | 512 × 384, centred | A Spectrum screen |
| 320 × 256 | 2 × 2 | 640 × 512 at (40, 32) | Amiga PAL lores |
| 360 × 288 | 2 × 2 | Full screen | Amiga PAL lores, full overscan |
| 640 × 200 | 1 × 2 | 640 × 400 at (40, 88) | 80-column text of the 1980s |
| 180 × 144 | 4 × 4 | Full screen | Chunky 8-bit-era graphics |
| 720 × 576 | 1 × 1 | Full screen | |

There is no fractional scaling and no shrinking.

Scaling is free in memory and, across the screen, in bandwidth: a layer at 2× across fetches half as much per screen pixel as at 1×. Scaling **down** the screen saves nothing in bandwidth, because the hardware fetches each source line again for every screen line it shows on. It saves memory, and it saves the Z80 drawing time, which matters more.

If the window width or height is not a whole multiple of the scale, the last source pixel or line is cut short. The first screen line of the window shows the first copy of the first source line.

With vertical scaling, the pointer goes back to the start of the source line after each copy except the last, and moves on by BPLSTRIDE only after the last copy. You do not need to do anything about this: set the stride for the source picture.

### Example 3-2: A full screen at 256 colours

A 360 × 288 picture at 8 bpp, 2 × 2, fills the whole 720 × 576. The window is the value after reset. The lines are spaced 512 bytes apart, so a page holds 16 lines and line y starts at `FULL + y × 512`; the picture takes 144 KB. Only the layer's table changes from Example 3-1:

```asm
; Example 3-2: a full-screen 256-colour layer. 360 x 288 at 8 bpp, 2 x 2.
FULL        equ     0x080000            ; 288 lines x 512 bytes = 144 KB
FS_STRIDE   equ     512

full0:      db      L_CTRL0_EN_M|(3<<L_CTRL0_BPP_B)|(1<<L_CTRL0_HSCALE_B)  ; 8 bpp, 2x
            db      1<<L_CTRL1_VSCALE_B ; 2x down
            db      0,0
            dw      VID_X0+VID_W,VID_X0 ; WINX: the whole picture
            dw      VID_Y0+VID_H,VID_Y0 ; WINY
            dw      0,0                 ; SCROLLX, SCROLLY
            dw      FS_STRIDE           ; BPLSTRIDE
            dw      0
            d24     FULL                ; BPL0PT
            db      0
            d24     0
            db      0
            d24     0
            db      0
```

It costs 8 ÷ 8 ÷ 2 = 0.5 bytes per pixel of the fetch budget, a third of what the display has (see "The Fetch Budget"). An 8 bpp layer uses all 256 entries of its palette; PALOFS does not apply. At 8 bpp a pixel at (x, y) is the byte at offset `(y and 15) × 512 + x` of page `FULL ÷ 0x2000 + y ÷ 16`.

---

## The Stride

The stride, BPLSTRIDE, is the number of bytes from the start of one line to the start of the next. It is a signed 16-bit value, and it must be even (bit 0 always reads 0).

Here is what happens to the pointer during one line. At the start of the line, BPL0PT holds the address of the line's first word. The hardware fetches the line word by word, and the pointer moves on by 2 for each word. When it fetches the line's **first** word, the hardware saves the pointer's value: the line's start. When it fetches the line's **last** word, it sets the pointer to that saved start plus BPLSTRIDE. So:

```
   next line's start  =  this line's start  +  BPLSTRIDE
```

The number of words fetched makes no difference. The window width, the scale and the fine scroll do not change the stride, and you never adjust it for them. BPLSTRIDE is the picture's **row stride**, whatever part of the line the window shows:

```
               picture lines in memory: 80 bytes each (640 pixels, 1 bpp)

     line y's start                                   line y+1's start
           v                                                 v
   ...-----+--------------------+----------------------------+--------------
           | shown: 40 bytes    | not shown: 40 bytes        | shown ...
   ...-----+--------------------+----------------------------+--------------
           <------------------ BPLSTRIDE = 80 ---------------->

   The stride is 80 whether the window shows all 640 pixels, 320 of them,
   or any other part, and whatever the fine scroll.

     Figure 3-4: The Stride for a Window Narrower Than the Picture
```

| Picture | Window shows | BPLSTRIDE |
|---------|--------------|-----------|
| 320 × 256, 4 bpp, packed | all, 2× | 160 |
| 320 × 256, 4 bpp, lines 256 apart (Example 3-1) | all, 2× | 256 |
| 360 × 288, 4 bpp, packed | all, 2× | 180 |
| 640 × 256, 4 bpp, lines 512 apart | 320 source pixels | 512 |
| 640 × 480, 1 bpp | 320 source pixels | 80 |
| A Spectrum screen, within a character row | all, 2× | 256 |

Other strides show the picture differently:

- BPLSTRIDE = 0 shows the same source line on every screen line.
- BPLSTRIDE = −(row stride) steps **back** one row each line. Point the pointer at the picture's last line and the picture appears upside down.

The stride is live. The hardware reads it when it fetches the line's last word, about two groups (32 source pixels) before the window's right edge. A value written at the start of a line, or in the horizontal blank before it, applies at the end of that line. Example 3-9 uses this for a reflection.

### Summary: the stride

| Name | Layer offset | Bytes | Function |
|------|--------------|-------|----------|
| BPLSTRIDE | `+0x10` | 2 | Signed, even: bytes from the start of one line to the start of the next |

---

## Scrolling a Bitmap

### Vertical scrolling

To scroll a picture up and down, change the address of the first line you give the pointer. To start the display at picture line y:

```
   BPL0PT  =  the picture's first line  +  y × row stride
```

The stride stays the same. To scroll smoothly, add or subtract one row stride per line scrolled, in each frame's vertical blank. The picture in memory must be tall enough for the window. To scroll endlessly, use pointer wrap (below), or a tile map.

### Horizontal scrolling

A picture wider than its window can be scrolled across in two parts:

- **Coarse scrolling**, in whole words, by moving the pointer. A word holds 16, 8, 4 or 2 pixels at 1, 2, 4 or 8 bits per pixel.
- **Fine scrolling**, by SCROLLX: the number of source pixels (0–15) the hardware skips at the start of each line. In a bitmap layer, bits 3–0 of SCROLLX are used.

A group is always 16 source pixels, so **any SCROLLX from 0 to 15 works at any depth**. The simplest rule is the same for every depth: move the pointer in whole groups, and let SCROLLX do the rest:

```
   BPL0PT   =  line start  +  (x ÷ 16) × 2 × bits per pixel     (÷ rounds down)
   SCROLLX  =  x mod 16
```

You may also move the pointer in single words and use a smaller SCROLLX:

| Depth | Pointer in groups | Or in words |
|-------|-------------------|-------------|
| 1 bpp | (x ÷ 16) × 2, SCROLLX = x mod 16 | the same |
| 2 bpp | (x ÷ 16) × 4, SCROLLX = x mod 16 | (x ÷ 8) × 2, SCROLLX = x mod 8 |
| 4 bpp | (x ÷ 16) × 8, SCROLLX = x mod 16 | (x ÷ 4) × 2, SCROLLX = x mod 4 |
| 8 bpp | (x ÷ 16) × 16, SCROLLX = x mod 16 | (x ÷ 2) × 2, SCROLLX = x mod 2 |

**The stride never depends on scroll.** When SCROLLX is not 0, the hardware fetches one extra group on each line, but the next line still starts at this line's start plus BPLSTRIDE. The picture must have a group to spare on the right of the part you show, which it always has if x + source width ≤ picture width.

SCROLLX skips pixels: it moves the picture to the **left** and shows more of its right-hand side. Increasing x always moves the view to the right through the picture.

The two parts take effect at different times: the pointer at once, SCROLLX at the next line. Change both in the vertical blank and they change together.

### Example 3-3: A scrolling routine

This routine points layer 1 at a 640 × 256 picture at 4 bpp, from any position (x, y). The window shows 320 source pixels; the lines are 512 bytes apart, so y × 512 is just a shift.

```asm
; Example 3-3: point layer 1 at the 640 x 256 picture BACK (4 bpp, lines
; 512 bytes apart) from source pixel (x = DE, y = A); 0 <= x <= 320.
; Call it in the vertical blank. About 140 T-states.
BACK        equ     0x060000            ; 128 KB, 128 KB-aligned
BK_STRIDE   equ     512

; once:     ld      hl,BK_STRIDE
;           ld      (CREG+L1_BPLSTRIDE),hl

scroll_back:
            ld      b,a                 ; B = y
            ld      a,e
            and     15
            ld      l,a
            ld      h,0
            ld      (CREG+L1_SCROLLX),hl    ; fine: x mod 16
            srl     d
            rr      e                   ; E = x / 2, bytes into the line
            ld      a,e
            and     0xF8                ; whole groups: 8 bytes = 16 pixels
            ld      (CREG+L1_BPL0PT),a  ; bits 7-0: held
            ld      a,b
            add     a,a                 ; y * 512: bits 15-9 in A, bit 16 in carry
            ld      (CREG+L1_BPL0PT+1),a    ; bits 15-8: held
            ld      a,BACK>>16
            adc     a,0
            ld      (CREG+L1_BPL0PT+2),a    ; bits 21-16: commits
            ret
```

Each register write commits only with its highest byte, so the hardware never sees a pointer with some bytes new and some old.

### Endless scrolling: pointer wrap

A game that scrolls through a long map does not need the whole map in memory as a picture, only the lines on the screen and a few more. With **pointer wrap**, those lines are kept as a **ring** in a block of memory, and the display goes round it by itself. (A tile map does the same job in both directions; see "Tile Maps".)

CTRL2.WRAP (bits 7–4) sets the size of the block, 2^(WRAP + 9) bytes:

| WRAP | Block | WRAP | Block |
|------|-------|------|-------|
| 0 | No wrap (the default) | 7 | 64 KB |
| 1 | 1 KB | 8 | 128 KB |
| 2 | 2 KB | 9 | 256 KB |
| ... | ... | 12 | 2 MB |

The pointer then stays inside the block it is in. The block must be **aligned**: it starts at a multiple of its own size. When the display moves the pointer on, a word at a time and to the line's start plus BPLSTRIDE at the end of a line, only the address bits inside the block change, so a pointer that runs off the end of the block carries on from its start.

- Wrap applies only to the moves the display makes. A pointer value **you** write is used as it is, so work out the address inside the block yourself.
- The wrap is on bytes, not lines. Lines are easiest to handle when the stride divides the block size exactly, so that no line is split at the end of the block.

To scroll down through a map: the ring holds more lines than the window shows. Each frame you move the pointer on by one stride per line scrolled, and draw the map's new lines into the ring just below the visible ones, where the display has not reached yet.

### Example 3-4: An endless vertical scroll

A 320 × 256 view, shown at 2 × 2, of a map as tall as you like, at 4 bpp. The lines are 256 bytes apart, as in Example 3-1, so a 128 KB block holds a ring of 512 lines: the 256 on the screen and 256 more to draw into. With a stride of 256 the pointer's bytes fall straight out of the line number:

```asm
; Example 3-4: endless vertical scroll through a ring of 512 lines.
RING        equ     0x080000            ; 128 KB, aligned to 128 KB
RING_WRAP   equ     8                   ; 2^(8+9) = 128 KB

; once (IX = layer 0): stride 256, and wrap
;           ld      (ix+L_BPLSTRIDE),0
;           ld      (ix+L_BPLSTRIDE+1),1
;           ld      (ix+L_CTRL2),RING_WRAP<<L_CTRL2_WRAP_B

; Each frame, in the vertical blank: show map line HL (it goes up by 1 per
; line scrolled) at the top of layer 0's window. Map line y is at ring line
; y mod 512, address RING + (y mod 512) * 256. About 70 T-states.
ring_scroll:
            xor     a
            ld      (CREG+L0_BPL0PT),a  ; bits 7-0: 0 (held)
            ld      a,l
            ld      (CREG+L0_BPL0PT+1),a    ; bits 15-8: y mod 256 (held)
            ld      a,h
            and     1                   ; bit 16: y bit 8
            or      RING>>16
            ld      (CREG+L0_BPL0PT+2),a    ; bits 21-16: commits
            ret
```

The display does the rest: as it fetches down the screen, a pointer that passes `RING + 0x1FFFF` carries on at `RING`. Before map line y + 256 scrolls into view, draw it at ring line z = (y + 256) mod 512: page `RING ÷ 0x2000 + z ÷ 32`, offset `(z mod 32) × 256`.

Wrap is not across a line: a picture that scrolls sideways must still be wide enough, or be redrawn at its edges.

### Summary: scrolling a bitmap

| Name | Layer offset | Bytes | Function |
|------|--------------|-------|----------|
| SCROLLX | `+0x0C` | 2 | Bitmap: fine scroll, source pixels (0–15) skipped at the start of each line (bits 3–0) |
| BPL0PT | `+0x14` | 3 | The pointer: coarse scrolling, across and down |
| CTRL2.WRAP | `+0x02`, bits 7–4 | 1 | Pointer wrap: the pointer stays in an aligned block of 2^(WRAP + 9) bytes; 0 off |

---

## Resetting the Pointer Every Frame

The pointer of a bitmap layer is not reset by the hardware. At the end of a frame it has moved on by BPLSTRIDE for every source line shown, and if nothing rewrites it, the next frame carries on from there through memory. Something must write it at the start of every frame:

- **the copper**, which does it in the vertical blank with three MOVEs in its list (see the Copper chapter);
- **the CPU**, in its vertical blank interrupt, as the examples in this chapter do.

A tile layer needs neither: its MAPPT and PATPT are never moved by the hardware.

The VBLANK interrupt comes at the start of the frame (beam line 0, pixel 0), after the last picture line has been fetched. The hardware starts fetching the picture's first line at beam line 49, pixel 0. So the handler has the whole vertical blank, 49 lines or 31,360 T-states, to write the pointer, less the time the Z80 takes to start the handler (at most 42 T-states in IM 2). A layer whose window starts lower down is fetched later, at the start of its YSTART line.

The handler is also the natural place to make any other change that must happen between frames: scroll positions, which buffer is shown, a new palette.

### Example 3-5: Double buffering

To animate without flicker, draw into one buffer while the other is shown, and swap them between frames. The main program draws the next frame into the hidden buffer, stores its address in a variable, and waits for the frame to change; the handler loads the pointer from the variable.

```asm
; Example 3-5: double buffering. The handler shows the buffer whose
; physical address is in "shown" (3 bytes).
vblank:     push    af
            push    hl
            ld      a,VIDSTAT_VBLANK_M
            ld      (CREG+VIDSTAT),a
            ld      hl,(shown)
            ld      (CREG+L0_BPL0PT),hl ; bits 15-0: held
            ld      a,(shown+2)
            ld      (CREG+L0_BPL0PT+2),a    ; bits 21-16: commits
            pop     hl
            pop     af
            ei
            reti

; In the main program: show the buffer at physical address A:HL from the
; next frame on, then wait until that frame has started.
showbuf:    di                          ; the handler must not see half of it
            ld      (shown),hl
            ld      (shown+2),a
            ei
            ld      a,(CREG+FRAMECOUNT) ; the low byte: counts frames
            ld      b,a
.wait:      ld      a,(CREG+FRAMECOUNT)
            cp      b
            jr      z,.wait
            ret

shown:      d24     0
```

`DI` and `EI` round the two writes matter: a VBLANK between them would show a buffer made of one address's low bytes and the other's high byte. FRAMECOUNT goes up by one at the start of each frame; reading its low byte is enough to see it change.

---

## Tile Maps

A layer with CTRL0.MODE set is a **tile map**. Instead of a picture, it shows a **map** of 8 × 8-pixel **tiles**. Each map entry is 2 bytes and names one tile, with its own colours, flips and priority. The hardware reads the map and the tiles' patterns as it goes, and scrolls round the map in both directions by itself.

A tile map suits the Z80 well:

- **Memory:** a full screen of 360 × 288 at 4 bpp is 51,840 bytes as a bitmap. As tiles it is a 64 × 64 map (8 KB) and the patterns it uses: 256 different tiles at 4 bpp are 8 KB more.
- **Scrolling:** a whole screen moves with one 2-byte write, SCROLLX or SCROLLY (16 T-states). Nothing is copied, and the map wraps round in both directions.
- **Text:** a character is one 2-byte map write (about 60 T-states with the loop round it), with its own colours.
- **Every frame:** nothing to reset. MAPPT and PATPT are not moved by the hardware.

The cost is bandwidth: a tile layer fetches its map entries as well as its patterns, so it takes more of the fetch budget than a bitmap of the same depth (see "What a tile layer costs").

### The patterns

A **tile** is 8 × 8 pixels of the layer's depth d (CTRL0.BPP), stored as 8 rows of d bytes, row 0 first. Each row is chunky pixels, exactly as a bitmap's: the leftmost pixel in the highest bits. The tiles are stored one after the other from **PATPT**, the pattern base:

```
 PATPT ---> +--------------------------+
            | tile 0, row 0  (d bytes) |
            | tile 0, row 1            |
            |  ...                     |    8 x d bytes per tile
            | tile 0, row 7            |
            +--------------------------+
            | tile 1, row 0            |
            |  ...                     |
            +--------------------------+
            | tile 2 ...               |

   tile t, row y is at  PATPT + t x 8d + y x d

             Figure 3-5: Tile Patterns in Memory
```

| Depth | Bytes per row | Bytes per tile | 512 tiles |
|-------|---------------|----------------|-----------|
| 1 bpp | 1 | 8 | 4 KB |
| 2 bpp | 2 | 16 | 8 KB |
| 4 bpp | 4 | 32 | 16 KB |
| 8 bpp | 8 | 64 | 32 KB |

There are up to 512 tiles per layer (the entry's TILE field is 9 bits). PATPT is a physical address and must be even. A 1 bpp tile is laid out as a character of a Spectrum font: 8 bytes, one per row, bit 7 on the left. At 4 bpp a tile looks like this:

```asm
; A 4 bpp tile: 8 rows of 4 bytes, two pixels to a byte, left pixel high.
; A diagonal line of colour 3 on colour 0.
diag:       db      0x30,0x00,0x00,0x00     ; row 0: pixel 0 is colour 3
            db      0x03,0x00,0x00,0x00     ; row 1: pixel 1
            db      0x00,0x30,0x00,0x00
            db      0x00,0x03,0x00,0x00
            db      0x00,0x00,0x30,0x00
            db      0x00,0x00,0x03,0x00
            db      0x00,0x00,0x00,0x30
            db      0x00,0x00,0x00,0x03     ; row 7: pixel 7
```

### The map

The map is **MW × MH entries** of 2 bytes, stored row by row from **MAPPT**. CTRL3 sets its size:

| CTRL3 field | Bits | 0 | 1 | 2 |
|-------------|------|---|---|---|
| MAPW | 1–0 | 32 entries wide (256 pixels) | 64 (512) | 128 (1,024) |
| MAPH | 3–2 | 32 entries high (256 lines) | 64 (512) | 128 (1,024) |

```
 MAPPT ---> entry (0,0)   (1,0)   ...   (MW-1,0)        row 0: MW x 2 bytes
            entry (0,1)   (1,1)   ...   (MW-1,1)        row 1
             ...
            entry (0,MH-1)        ...   (MW-1,MH-1)

   entry (column c, row r) is at  MAPPT + (r x MW + c) x 2

             Figure 3-6: A Tile Map in Memory
```

| Map | Bytes | Pixels | Row of entries |
|-----|-------|--------|----------------|
| 32 × 32 | 2 KB | 256 × 256 | 64 bytes |
| 64 × 32 | 4 KB | 512 × 256 | 128 bytes |
| 64 × 64 | 8 KB | 512 × 512 | 128 bytes |
| 128 × 32 | 8 KB | 1,024 × 256 | 256 bytes |
| 128 × 64 | 16 KB | 1,024 × 512 | 256 bytes |
| 128 × 128 | 32 KB | 1,024 × 1,024 | 256 bytes |

Two sizes are worth knowing for the Z80. A map of **8 KB fits one MMU page** exactly, so with MAPPT at the start of a page, the whole map is in one window. And in a map **128 entries wide**, a row is 256 bytes, so entry (c, r) is at `window + r × 256 + c × 2`: the row is the address's high byte and twice the column its low byte. The boot console uses a 128 × 32 map for both reasons.

MAPPT is a physical address and must be even. The map need not be aligned beyond that.

### The map entry

Each entry is 2 bytes, low byte first:

```
        high byte (address + 1)                      low byte (address)
   15    14      13     12   11   10    9      8     7                  0
 +-----+-------+-------+--------------------+------+--------------------+
 | PRI | YFLIP | XFLIP |      PAL (4)       | TILE |   TILE bits 7-0    |
 |     |       |       |                    | bit 8|                    |
 +-----+-------+-------+--------------------+------+--------------------+

                  Figure 3-7: A Map Entry
```

| Bits | Field | Meaning |
|------|-------|---------|
| 8–0 | TILE | Tile number, 0–511 |
| 12–9 | PAL | Palette block, for tiles of up to 4 bits (see "Colours per tile") |
| 13 | XFLIP | The tile mirrored left to right |
| 14 | YFLIP | The tile upside down |
| 15 | PRI | The tile's pixels go in front of all layers (see "Priority per tile") |

So the **low byte** is the tile number's low 8 bits, and the **high byte** is: bit 0 TILE bit 8, bits 4–1 PAL, bit 5 XFLIP, bit 6 YFLIP, bit 7 PRI. A program usually builds the high byte once (its colours and flips) and writes it after each tile number. The examples in this chapter use these names for the high byte:

```asm
; Map entry, high byte. (These names are not yet generated in hw.inc.)
ME_TILE8    equ     0x01                ; TILE bit 8: tiles 256-511
ME_PAL_B    equ     1                   ; PAL, bits 4-1: (pal << ME_PAL_B)
ME_XFLIP    equ     0x20
ME_YFLIP    equ     0x40
ME_PRI      equ     0x80
```

For example, tile 300 in colour block 2, mirrored left to right: low byte 300 and 255 = `0x2C`; high byte `ME_TILE8 | (2 << ME_PAL_B) | ME_XFLIP` = `0x25`.

### Turning on a tile layer

A tile layer uses these registers; BPL0PT, BPLSTRIDE and CTRL2.WRAP are not used:

| Register | Layer offset | Bytes | Meaning |
|----------|--------------|-------|---------|
| CTRL0 | `+0x00` | 1 | EN, BPP (the tiles' depth), TRANSP, MODE = 1, HSCALE |
| CTRL1 | `+0x01` | 1 | VSCALE, PALOFS |
| CTRL3 | `+0x03` | 1 | MAPW, MAPH |
| WINX, WINY | `+0x04`–`+0x0B` | 2 each | The window, as for a bitmap |
| SCROLLX | `+0x0C` | 2 | The map pixel at the window's left edge, 0–1023 |
| SCROLLY | `+0x0E` | 2 | The map line at the window's top, 0–1023 |
| MAPPT | `+0x18` | 3 | The map's first entry (column 0, row 0) |
| PATPT | `+0x1C` | 3 | Tile 0's first byte |

MAPPT, PATPT and SCROLLY are line settings, like CTRL0: the hardware reads them at the start of each line, so a change acts from the next line and never in the middle of one.

### Scrolling round the map

SCROLLX and SCROLLY say which map pixel is at the window's top left corner. On the screen line that shows source line n of the window (n counts source lines from YSTART), and at source pixel i across the window, the layer shows map pixel:

```
   x  =  (SCROLLX + i) mod (8 × MW)
   y  =  (SCROLLY + n) mod (8 × MH)

   map column = x ÷ 8,  pixel in the tile = x mod 8
   map row    = y ÷ 8,  row in the tile   = y mod 8
```

Both wrap round the map, so the view scrolls endlessly in both directions. A view that runs off the map's right edge carries on at its left edge, and off its bottom at its top. A map narrower than the window repeats across it. The high bits of SCROLLX and SCROLLY above the map's size are ignored, so a program can keep a 16-bit position and write it as it is.

```
        map: 8 x MW pixels across, 8 x MH lines down

   0                                                   8 x MW
 0 +----------------------------------------------------+
   |                                                    |
   |      (SCROLLX, SCROLLY)                            |
   |              +----------------------+              |
   |              | the window's view:   |              |
   |              | window width / HS    |              |
   |              | by window height / VS|              |
   |              +----------------------+              |
   |                                                    |
   +-----------------+                       +----------+
   |  ... a view     |                       | ... that |
   |  carries on     |                       | starts   |
   |  here           |                       | here     |
   +-----------------+-----------------------+----------+
 8 x MH

            Figure 3-8: The View Wraps Round the Map
```

To scroll a tile layer one pixel to the right and one down, add 1 to both, once a frame:

```asm
        ld   hl,(scroll_x)
        inc  hl
        ld   (scroll_x),hl
        ld   (CREG+L1_SCROLLX),hl   ; 16 T: the whole screen moves
```

The fine part (x mod 8) and the coarse part (whole tiles) are the same register; you never move a pointer.

### A world bigger than the map

A 64 × 64 map is 512 × 512 pixels. A screen at 2 × 2 shows 360 × 288 of it: 45 tile columns and 36 rows, plus one partly shown each way. The rest of the map is off the screen, and that is where new parts of a larger world are written, just before they scroll into view.

To scroll right through a world of any width: whenever the view has moved on by 8 pixels, write the world's next column into the map column that is about to come in on the right. If the view's left edge is at world pixel X, the map's SCROLLX is X mod 512, and the column to write is world column X ÷ 8 + 46, into map column (X ÷ 8 + 46) mod 64. There are 18 spare columns, so the write can be anywhere in the next 8 frames at one pixel a frame.

### Example 3-6: Writing a new column

```asm
; Example 3-6: write the 64 entries at HL (one world column, 128 bytes,
; top to bottom) into map column A (0-63) of a 64 x 64 map that is mapped
; at DRAWWIN (window 6). About 5,500 T-states, 0.3 ms.
put_col:    add     a,a                 ; column x 2
            ld      e,a
            ld      d,DRAWWIN>>8        ; DE = the column's entry in row 0
            ld      b,64
.row:       ld      a,(hl)
            ld      (de),a              ; low byte: the tile
            inc     hl
            inc     de
            ld      a,(hl)
            ld      (de),a              ; high byte: colours, flips
            inc     hl
            ld      a,e
            add     a,127               ; one row down: 128 bytes on, less 1
            ld      e,a
            jr      nc,.same
            inc     d
.same:      djnz    .row
            ret
```

A new row is easier: the 64 entries of a row are 128 consecutive bytes, so one `LDIR` writes it (2,700 T-states).

The display may read an entry while the Z80 is between its two bytes. The tile then shows for one frame with the other byte's old value. If that matters, write entries in the vertical blank, or off the screen as here.

### Flips

XFLIP shows the tile mirrored left to right, and YFLIP upside down; both together turn it half round. The flips act as the tile is fetched, so they cost nothing. A symmetrical object needs only half its tiles: the right half of a tree is its left half with XFLIP. The diagonal tile above, with XFLIP, gives the other diagonal, so two entries make a zigzag.

### Colours per tile: PAL and PALOFS

For tiles of up to 4 bits per pixel, the palette index of pixel value p is:

```
   index  =  ((PALOFS + PAL) mod 16) × 16  +  p
```

PAL comes from the tile's entry and PALOFS from the layer's CTRL1. So each tile has its own block of 16 colours (a 1 bpp tile uses the first two entries of its block, a 2 bpp tile the first four), and one write to CTRL1 shifts the whole layer to other blocks. An 8 bpp tile's index is p itself; PAL and PALOFS are not used.

| Layer depth | Index |
|-------------|-------|
| 1, 2 or 4 bits | ((PALOFS + PAL) mod 16) × 16 + p |
| 8 bits | p |

Uses:

- **Colour pairs for text:** a 1 bpp tile shows entry 16 × PAL as its paper and 16 × PAL + 1 as its ink, so 16 pairs of colours are available per character.
- **The same shapes in other colours:** grass and sand from one set of patterns, with PAL 1 and PAL 2.
- **Day and night:** a game whose map uses PAL 0–7 can switch every tile to a darker set in blocks 8–15 with one write: PALOFS = 8.

### Priority per tile: PRI

A tile whose entry has PRI set brings its pixels in front of **all** layers, and of every sprite except those of DEPTH 0. Other tiles of the same layer stay in the layer's own place. Among PRI tiles of two layers, PRIO's order holds.

PRI makes a single layer behave as two: a tree's leaves can be in front of the player's sprite (DEPTH 1) while the ground of the same map is behind it. A PRI tile's transparent pixels (value 0 with CTRL0.TRANSP set) still show what is behind them. With TRANSP clear, value 0 is a colour, and it moves to the front too.

"Priority and Transparency" gives the whole order.

### Text

There is no text layer: **text is a 1 bpp tile map**, one entry per character, with the character code as TILE and a colour pair as PAL. A font of 256 characters of 8 × 8 is 2 KB of patterns. The boot console is such a layer:

| Item | The boot console |
|------|------------------|
| Layer | L0, 1 bpp tiles, 1× across and 2× down (characters of 8 × 16 beam pixels) |
| Window | 640 × 480 at beam (184, 97): 80 columns, 30 rows |
| Map | 128 × 32 entries, 8 KB, at physical `0x1FC000` (MAPPT) |
| Font | 256 characters in code page 437 order, 2 KB, at physical `0x1FE000` (PATPT) |
| Entry | `code | (PAL << 9)`: the high byte is PAL × 2 |
| Colours | PALETTE0; pair PAL p: entry 16p is the paper, 16p + 1 the ink. PAL 1 is light grey on black |

**Printing** a character is one 2-byte write at `MAPPT + (row × 128 + column) × 2`. **Scrolling** the text up a line is SCROLLY + 8 and clearing the map row that comes in at the bottom; the map wraps at 32 rows, so nothing is copied.

The font stays at `0x1FE000` until a program overwrites it, so a program can use it for its own text layers, as Example 3-7 does.

### What a tile layer costs

A tile layer is fetched by the same hardware as a bitmap, 16 source pixels at a time: two tile columns per group. For each group the fetcher reads the two pattern rows, and the two map entries of the next group, one group ahead:

| Depth | Pattern words per group | Entry words per group | Memory cycles per group | A bitmap group |
|-------|-------------------------|-----------------------|-------------------------|----------------|
| 1 bpp | 2 | 2 | 4 | 1 |
| 2 bpp | 2 | 2 | 4 | 2 |
| 4 bpp | 4 | 2 | 6 | 4 |
| 8 bpp | 8 | 2 | 10 | 8 |

In bytes per screen pixel, HS being the horizontal scale:

| Layer | Bytes per screen pixel |
|-------|------------------------|
| Tile map, 1 or 2 bpp | 0.5 ÷ HS |
| Tile map, 4 bpp | 0.75 ÷ HS |
| Tile map, 8 bpp | 1.25 ÷ HS |
| Bitmap, d bpp, for comparison | d ÷ 8 ÷ HS |

So text at 1× costs 0.5 of the display's 1.48 bytes per pixel, and a 4 bpp tile layer at 2× costs 0.375. Close to the budget, an 8 bpp tile layer at 1× is the first to run short.

### Example 3-7: A scrolling tile map with a text overlay

Two tile layers. Layer 1 is a 64 × 64 map of 4 bpp tiles, 2 × 2 over the whole picture, scrolling one pixel right and one down every frame. Layer 0 is text in front of it: 1 bpp tiles from the boot console's font, 1× across and 2× down in the console's 640 × 480 window, with colour 0 transparent, so the map shows between the letters. The map's tiles are used where they sit in the program; the two maps are in pages of their own.

Bandwidth: 0.375 for layer 1, plus 0.5 for layer 0 inside its window: 0.875 bytes per pixel.

```asm
; Example 3-7: a scrolling tile map with a text overlay.
; Layer 1: a 64 x 64 map of 8 x 8 tiles at 4 bpp, 2x by 2x over the whole
;   picture, scrolled one pixel right and one down each frame.
; Layer 0: text, 1 bpp tiles (the boot console's font), 1x across and 2x
;   down in a 640 x 480 window; colour 0 transparent.
; Uses map_regs, video_off and im2_init from Example 3-1.

            include "hw.inc"

REGS        equ     0xE000
SREG        equ     REGS+REGS_SYSTEM
CREG        equ     REGS+REGS_CUSTOM
PREG        equ     REGS+REGS_PALETTE
DRAWWIN     equ     0xC000              ; window 6
TEXTWIN     equ     0x6000              ; window 3: the text map, kept there
RAMOFS      equ     0x4000              ; Z80 address - physical, windows 2-6
IM2TAB      equ     0xBFD0
STACK       equ     0xBF00

MAP         equ     0x040000            ; game map: 64 x 64 entries, 8 KB
TEXT        equ     0x042000            ; text map: 128 x 32 entries, 8 KB
FONT        equ     0x1FE000            ; the boot console's font

ME_PAL_B    equ     1                   ; map entry, high byte (see above)
ME_XFLIP    equ     0x20

            org     0x8000
start:      di
            ld      sp,STACK
            call    map_regs
            call    video_off
            call    im2_init
            call    fill_map            ; layer 1's map
            ld      hl,TEXT>>13
            ld      (SREG+MMU3),hl      ; the text map at 0x6000, for good
            call    clear_text
            ld      hl,msg1
            ld      d,1                 ; row 1
            ld      e,2                 ; column 2
            ld      b,1<<ME_PAL_B       ; pair 1: white
            call    print
            ld      hl,msg2
            ld      d,28
            ld      e,2
            ld      b,2<<ME_PAL_B       ; pair 2: yellow
            call    print

            ; colours: PALETTE1 blocks 1 (land) and 2 (sand), PALETTE0 inks
            ld      hl,land
            ld      de,PREG+1*REGS_PAL_SPAN+16*3    ; PALETTE1, entry 16
            ld      bc,5*3
            ldir
            ld      hl,sand
            ld      de,PREG+1*REGS_PAL_SPAN+32*3    ; PALETTE1, entry 32
            ld      bc,5*3
            ldir
            ld      hl,inks
            ld      de,PREG+0*REGS_PAL_SPAN+17*3    ; PALETTE0, entry 17
            ld      bc,3
            ldir                        ; pair 1's ink
            ld      de,PREG+0*REGS_PAL_SPAN+33*3    ; entry 33
            ld      bc,3
            ldir                        ; pair 2's ink

            ; the two layers, from their tables
            ld      hl,layer1
            ld      de,CREG+L1
            ld      bc,L_SPAN
            ldir
            ld      hl,layer0
            ld      de,CREG+L0
            ld      bc,L_SPAN
            ldir
            ld      a,(3<<PRIO_BACK_B)|(1<<PRIO_MIDDLE_B)|(0<<PRIO_FRONT_B)
            ld      (CREG+PRIO),a       ; L0 in front, then L1; no third

            ld      hl,vblank
            ld      (IM2TAB+2*INT_VBLANK),hl
            ld      a,VIDSTAT_VBLANK_M
            ld      (CREG+VIDSTAT),a
            ld      (CREG+VIDINTEN),a
            ld      a,INTENA_SETCLR_M|(1<<INTB_VBLANK)
            ld      (SREG+INTENA0+INTR_VBLANK),a
            ld      a,INTCON_MASTER_M
            ld      (SREG+INTCON),a
            ld      a,DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_BPLEN_M
            ld      (CREG+DMACON),a
            ld      a,VIDCON_EN_M
            ld      (CREG+VIDCON),a
            ei

main:       halt
            jr      main

; Vertical blank: the map one pixel right and one down. Nothing else.
vblank:     push    af
            push    hl
            ld      a,VIDSTAT_VBLANK_M
            ld      (CREG+VIDSTAT),a
            ld      hl,(scroll)
            inc     hl
            ld      (scroll),hl
            ld      (CREG+L1_SCROLLX),hl    ; high bits beyond 511 are ignored
            ld      (CREG+L1_SCROLLY),hl
            pop     hl
            pop     af
            ei
            reti                        ; about 150 T

scroll:     dw      0

; Layer 1's map: entry (c, r) = tile (c + r) and 3; PAL 1, or 2 on rows
; 16-31 and 48-63; XFLIP where c and 4. Entry at DRAWWIN + r*128 + c*2.
fill_map:   ld      hl,MAP>>13
            ld      (SREG+MMU6),hl      ; the map's page at 0xC000
            ld      hl,DRAWWIN
            ld      c,0                 ; C = row r
.row:       ld      b,0                 ; B = column c
.col:       ld      a,b
            add     a,c
            and     3
            ld      (hl),a              ; low byte: the tile
            inc     hl
            ld      a,c
            and     0x10
            rrca
            rrca
            rrca                        ; (r and 16) / 8: 0 or 2
            add     a,1<<ME_PAL_B       ; PAL 1, or PAL 2
            ld      e,a
            ld      a,b
            and     4
            rlca
            rlca
            rlca                        ; (c and 4) * 8 = ME_XFLIP or 0
            or      e
            ld      (hl),a              ; high byte
            inc     hl
            inc     b
            ld      a,b
            cp      64
            jr      nz,.col
            inc     c
            ld      a,c
            cp      64
            jr      nz,.row
            ret

; Clear the text map: entry 0 everywhere, character 0 (blank), PAL 0
clear_text: ld      hl,TEXTWIN
            ld      de,TEXTWIN+1
            ld      bc,0x2000-1
            ld      (hl),0
            ldir                        ; 172,000 T, 8.6 ms
            ret

; Print the 0-terminated string at HL at row D, column E, with the entry's
; high byte B (the colour pair). About 60 T-states a character.
print:      ld      a,d
            add     a,TEXTWIN>>8
            ld      d,a
            sla     e                   ; DE = TEXTWIN + row*256 + column*2
.char:      ld      a,(hl)
            or      a
            ret     z
            ld      (de),a              ; the character code: TILE
            inc     e
            ld      a,b
            ld      (de),a              ; PAL
            inc     e
            inc     hl
            jr      .char

msg1:       db      "A 64 x 64 tile map, 4 bpp, 2 x 2, scrolling",0
msg2:       db      "Text: 1 bpp tiles, colour 0 transparent",0

; Layer 1: the game map
layer1:     db      L_CTRL0_EN_M|(2<<L_CTRL0_BPP_B)|L_CTRL0_MODE_M|(1<<L_CTRL0_HSCALE_B)
            db      1<<L_CTRL1_VSCALE_B ; 2x down, PALOFS 0
            db      0
            db      (1<<L_CTRL3_MAPW_B)|(1<<L_CTRL3_MAPH_B) ; 64 x 64
            dw      VID_X0+VID_W,VID_X0 ; WINX: the whole picture
            dw      VID_Y0+VID_H,VID_Y0 ; WINY
            dw      0,0                 ; SCROLLX, SCROLLY
            dw      0,0                 ; BPLSTRIDE (not used), reserved
            d24     0                   ; BPL0PT (not used)
            db      0
            d24     MAP                 ; MAPPT
            db      0
            d24     tiles-RAMOFS        ; PATPT: the tiles below, in place
            db      0

; Layer 0: the text, in the boot console's window
layer0:     db      L_CTRL0_EN_M|(0<<L_CTRL0_BPP_B)|L_CTRL0_TRANSP_M|L_CTRL0_MODE_M
            db      1<<L_CTRL1_VSCALE_B ; 1x across, 2x down
            db      0
            db      (2<<L_CTRL3_MAPW_B)|(0<<L_CTRL3_MAPH_B) ; 128 x 32
            dw      VID_X0+40+640,VID_X0+40 ; WINX: 184-824
            dw      VID_Y0+48+480,VID_Y0+48 ; WINY: 97-577
            dw      0,0
            dw      0,0
            d24     0
            db      0
            d24     TEXT                ; MAPPT
            db      0
            d24     FONT                ; PATPT
            db      0

land:       d24     0x205020,0x30A030,0x70D060,0x806040,0xE0C040    ; block 1
sand:       d24     0xA08040,0xD0B060,0xF0E0A0,0x604020,0x4060C0    ; block 2
inks:       d24     0xFFFFFF,0xFFE040   ; pair 1, pair 2

; The tiles: 4 bpp, 32 bytes each, used in place by PATPT
            ALIGN   2
tiles:      ; tile 0: ground with a few spots
            db      0x00,0x00,0x00,0x00
            db      0x01,0x00,0x00,0x00
            db      0x00,0x00,0x00,0x10
            db      0x00,0x00,0x00,0x00
            db      0x00,0x00,0x00,0x00
            db      0x00,0x10,0x00,0x00
            db      0x00,0x00,0x00,0x01
            db      0x00,0x00,0x00,0x00
            ; tile 1: a 2 x 2 check of colours 1 and 2
            db      0x11,0x22,0x11,0x22
            db      0x11,0x22,0x11,0x22
            db      0x22,0x11,0x22,0x11
            db      0x22,0x11,0x22,0x11
            db      0x11,0x22,0x11,0x22
            db      0x11,0x22,0x11,0x22
            db      0x22,0x11,0x22,0x11
            db      0x22,0x11,0x22,0x11
            ; tile 2: a diagonal of colour 3 (XFLIP gives the other one)
            db      0x30,0x00,0x00,0x00
            db      0x03,0x00,0x00,0x00
            db      0x00,0x30,0x00,0x00
            db      0x00,0x03,0x00,0x00
            db      0x00,0x00,0x30,0x00
            db      0x00,0x00,0x03,0x00
            db      0x00,0x00,0x00,0x30
            db      0x00,0x00,0x00,0x03
            ; tile 3: a block, colour 4 round colour 2
            db      0x44,0x44,0x44,0x44
            db      0x42,0x22,0x22,0x24
            db      0x42,0x22,0x22,0x24
            db      0x42,0x22,0x22,0x24
            db      0x42,0x22,0x22,0x24
            db      0x42,0x22,0x22,0x24
            db      0x42,0x22,0x22,0x24
            db      0x44,0x44,0x44,0x44
```

The whole scrolling is two 2-byte writes a frame. The map is never touched after `fill_map`, and the text layer stays still while the map moves behind it. To move the text instead, change layer 0's SCROLLX and SCROLLY.

---

## Split Screens

A **split screen** shows different pictures, or different parts of one picture, in bands down the screen: a scrolling game area above a fixed status panel, for example. There are four ways to make one.

### Different layers

The simplest way is to use one layer for each band. Give each layer a window covering its band, and set each one up independently. A layer is fetched only on the lines its window covers, so bands that do not overlap cost no extra bandwidth.

```
 picture
 line  32 +-----------------------------------------+
          |  layer 1: game area                     |
          |  tile map, 4 bpp, 2x, scrolling         |
          |  WINY 81-529 (VID_Y0+32 to VID_Y0+480)  |
      480 +-----------------------------------------+
          |  layer 0: status panel, text            |
      544 +-----------------------------------------+  WINY 529-593

            Figure 3-9: A Split Screen from Two Layers
```

### Changing a line setting partway down

CTRL0–CTRL3, the window, SCROLLX, SCROLLY, MAPPT and PATPT are read at the start of each line. A write during line L − 1 changes line L. So one layer can show different settings in different bands. For a tile layer, one write to SCROLLY shows another part of the map from that line on.

The LINE interrupt is made for this. It comes at the start of beam line LINECMP (pixel 0), and the handler then has the rest of that line, 640 T-states less the time to start it (at most 42 in IM 2), to commit its writes for the next line.

### Example 3-8: A status panel from the same map

Layer 1 is a 64 × 64 tile map at 2 × 2 over the whole picture. The game area scrolls across; from picture line 512 (beam line 561) down, the layer shows map rows 60–63, unscrolled, as a status panel. Beam line 561 is source line n0 = (561 − 49) ÷ 2 = 256 of the window. To show map line 480 (row 60) there, SCROLLY = 480 − 256 = 224, since the map line is SCROLLY + n.

```asm
; Example 3-8: a panel from map rows 60-63, from beam line 561 down.
PANEL       equ     VID_Y0+512          ; beam line 561: the panel's first line

; in the set-up
            ld      hl,line
            ld      (IM2TAB+2*INT_LINE),hl
            ld      hl,PANEL-1
            ld      (CREG+LINECMP),hl   ; LINE at the line before the panel
            ld      a,VIDSTAT_VBLANK_M|VIDSTAT_LINE_M
            ld      (CREG+VIDSTAT),a
            ld      (CREG+VIDINTEN),a
            ld      a,INTENA_SETCLR_M|(1<<INTB_VBLANK)|(1<<INTB_LINE)
            ld      (SREG+INTENA0),a    ; both are sources in INTENA0

; Line 560: from line 561, the panel: no scroll across, map line 480
line:       push    af
            push    hl
            ld      a,VIDSTAT_LINE_M
            ld      (CREG+VIDSTAT),a
            ld      hl,0
            ld      (CREG+L1_SCROLLX),hl
            ld      hl,60*8-(PANEL-VID_Y0)/2    ; 224
            ld      (CREG+L1_SCROLLY),hl
            pop     hl
            pop     af
            ei
            reti                        ; commits about 4 us into line 560

; Vertical blank: the game's scroll for the next frame
vblank:     push    af
            push    hl
            ld      a,VIDSTAT_VBLANK_M
            ld      (CREG+VIDSTAT),a
            ld      hl,(game_x)
            ld      (CREG+L1_SCROLLX),hl
            ld      hl,0
            ld      (CREG+L1_SCROLLY),hl    ; rows 0-31 for the game
            pop     hl
            pop     af
            ei
            reti
```

The copper does the same with no CPU time: a WAIT for line 560 and two 2-byte MOVEs (see the Copper chapter).

### Changing the stride partway down

Because the stride is used at the end of each line, changing BPLSTRIDE during line L changes where line L + 1 starts. The write can land anywhere in line L before its last fetch, which is easy to hit from an interrupt.

- To jump to another part of memory at line L + 1, set BPLSTRIDE during line L to (address wanted − line L's start), then put the row stride back during line L + 1.
- To repeat a line, set BPLSTRIDE to 0 for as many lines as you want it repeated.
- To show a reflection, set BPLSTRIDE to −(row stride) and leave it there.

With vertical scaling, the stride is used only after the last copy of a source line.

### Example 3-9: A reflection

This example extends Example 3-1. From picture line 384 down (beam line 433, source line 176), the LINE interrupt sets the stride to step back one row per source line, so the picture above is reflected below it. It also switches the layer to colours 16–31, a darker set, with one write to CTRL1. The vertical blank handler puts the pointer, the stride and CTRL1 back for the next frame.

```asm
; Example 3-9: a reflection, added to Example 3-1
MIRROR      equ     VID_Y0+384          ; beam line 433: source line 176

            ; in the set-up: colours 16-31 for the water, then the interrupts
            ld      hl,mirror
            ld      (IM2TAB+2*INT_LINE),hl
            ld      hl,MIRROR
            ld      (CREG+LINECMP),hl
            ld      a,VIDSTAT_VBLANK_M|VIDSTAT_LINE_M
            ld      (CREG+VIDSTAT),a
            ld      (CREG+VIDINTEN),a
            ld      a,INTENA_SETCLR_M|(1<<INTB_VBLANK)|(1<<INTB_LINE)
            ld      (SREG+INTENA0),a

; Vertical blank: pointer, stride and colours back to normal
vblank:     push    af
            push    hl
            ld      a,VIDSTAT_VBLANK_M
            ld      (CREG+VIDSTAT),a
            call    setptr
            ld      hl,STRIDE
            ld      (CREG+L0_BPLSTRIDE),hl
            ld      a,(1<<L_CTRL1_VSCALE_B)|(0<<L_CTRL1_PALOFS_B)
            ld      (CREG+L0_CTRL1),a
            pop     hl
            pop     af
            ei
            reti

; Line MIRROR: each source line from now on steps back one row. The stride
; is used after the second copy of source line 176, so line 435 shows
; source line 175. The new PALOFS shows from line 434.
mirror:     push    af
            push    hl
            ld      a,VIDSTAT_LINE_M
            ld      (CREG+VIDSTAT),a
            ld      hl,-STRIDE
            ld      (CREG+L0_BPLSTRIDE),hl  ; -256
            ld      a,(1<<L_CTRL1_VSCALE_B)|(1<<L_CTRL1_PALOFS_B)
            ld      (CREG+L0_CTRL1),a   ; colours 16-31: one byte, no latch
            pop     hl
            pop     af
            ei
            reti
```

CTRL1 is a register of its own, so the handler changes PALOFS without touching the format and the enable in CTRL0.

### Writing a new pointer partway down

A bitmap's pointer is live, so it can be written at any time, but the hardware uses it at once. A pointer committed between the layer's last fetch on line L and the start of line L + 1 (beam pixel 0) becomes line L + 1's start, as written. One committed earlier is used for the rest of line L. With a full-width window the gap is about 1 µs at 1× (2 µs at 2×), 20 to 40 T-states: too short for the CPU to hit reliably. It is a job for the copper, which writes at an exact pixel. The Spectrum screen (see "Spectrum Extras") is built this way.

---

## Priority and Transparency

### Transparency

Where a layer has no pixel to show, it is **transparent** and whatever is behind it shows through. A layer is transparent:

- outside its display window;
- where its pixel value is 0, if CTRL0.TRANSP is set;
- where its data was not ready in time (see "When a layer runs short").

If TRANSP is clear, the layer is solid everywhere inside its window, and pixel value 0 shows entry 0 of its block. Where no layer and no sprite has a pixel, the **background colour**, BGCOLOR, shows.

### Priority

PRIO lists the three layers from front to back:

| Bits | Field | Meaning |
|------|-------|---------|
| 1–0 | FRONT | Number of the layer in front |
| 3–2 | MIDDLE | Number of the layer in the middle |
| 5–4 | BACK | Number of the layer at the back |

Any order is allowed. A field holding 3 names no layer, so a layer left out of PRIO is never shown (it is still fetched if it is enabled). Name each layer once. After reset PRIO is `0x24`: L0 in front, then L1, then L2.

```asm
; L1 in front, then L0; L2 not shown
        ld   a,(3<<PRIO_BACK_B)|(0<<PRIO_MIDDLE_B)|(1<<PRIO_FRONT_B)
        ld   (CREG+PRIO),a
```

Sprites go among the layers by their DEPTH, and PRI tiles have a place of their own. For each pixel the hardware shows the front-most source that is not transparent. Back to front:

| # | Source |
|---|--------|
| 1 | Background colour (BGCOLOR) |
| 2 | Sprites with DEPTH 3 |
| 3 | The layer PRIO names BACK |
| 4 | Sprites with DEPTH 2 |
| 5 | The layer PRIO names MIDDLE |
| 6 | Sprites with DEPTH 1 |
| 7 | The layer PRIO names FRONT |
| 8 | Tile pixels whose entry has PRI = 1, from any layer PRIO names; among them, PRIO's order |
| 9 | Sprites with DEPTH 0 |

```
                        front                                       back
   PRIO = L1, L0, L2:   DEPTH 0 -> PRI tiles -> L1 -> DEPTH 1 -> L0 -> ...
                           |          |         |       |         |
          the first non-transparent pixel, looking from the front, is shown

                   Figure 3-10: Choosing a Pixel
```

PRIO and BGCOLOR take effect at the start of each line's picture, so you can change the order partway down the screen.

### Dual playfields and parallax

Any two layers make a dual-playfield screen, each with its own depth, colours and scroll:

1. Set up the back layer as an ordinary solid layer.
2. Set up the front layer with CTRL0.TRANSP set, and draw it with colour 0 wherever the back layer should show.
3. Put the front layer first in PRIO.

Each layer scrolls independently, so scrolling them at different speeds gives parallax. With tile layers this is two writes a frame:

```asm
; Parallax: layer 1 (front, TRANSP) at 2 pixels a frame, layer 2 at 1.
; In the vertical blank handler.
            ld      hl,(far_x)
            inc     hl
            ld      (far_x),hl
            ld      (CREG+L2_SCROLLX),hl
            add     hl,hl
            ld      (CREG+L1_SCROLLX),hl
```

Two 4 bpp tile layers at 2× cost 0.375 + 0.375 = 0.75 bytes per pixel, leaving room for a third layer.

### Summary: priority and transparency

| Name | Offset | Port | Function |
|------|--------|------|----------|
| PRIO | `0x003` | `0x0310` | FRONT (1–0), MIDDLE (3–2), BACK (5–4): layer numbers, front to back; 3 = none. Reset `0x24` |
| BGCOLOR | `0x004`–`0x006` | `0x0410`–`0x0610` | Background colour: blue, green, red (commits) |
| CTRL0.TRANSP | Layer `+0x00`, bit 4 | | 1: pixel value 0 is transparent |

---

## Colour Registers and Palette Offsets

### The palettes

There are four palettes, each of 256 entries of 24-bit colour: one for each layer and one for the sprites. A layer takes its colours from its own palette only, so three 8 bpp layers can show 768 different colours at once, plus the background.

| Palette | Number | Used by | Register page | In this chapter's window 7 |
|---------|--------|---------|---------------|----------------------------|
| PALETTE0 | 0 | Layer 0 | `0x1400`–`0x16FF` | `0xF400`–`0xF6FF` |
| PALETTE1 | 1 | Layer 1 | `0x1700`–`0x19FF` | `0xF700`–`0xF9FF` |
| PALETTE2 | 2 | Layer 2 | `0x1A00`–`0x1CFF` | `0xFA00`–`0xFCFF` |
| SPRPALETTE | 3 | The sprites | `0x1D00`–`0x1FFF` | `0xFD00`–`0xFFFF` |

An entry is **3 bytes: blue, green, red**. Writing blue and green holds them; writing red changes the whole entry at once. So the colour never shows half-changed, and a rising copy (`LDIR`, `LDI`) loads entries whole. In a table, sjasmplus's `D24 0xRRGGBB` gives the bytes in this order.

A palette write takes effect from the next pixel, so colours can change in the middle of a line. There is no need to wait for the vertical blank, although changing a colour that is on the screen shows the change from that point on.

### Through the register page

Entry i of palette p is at `PREG + p × 0x300 + 3i`:

```asm
        ld   hl,0x8000              ; green 0x80, blue 0x00
        ld   (PREG+1*REGS_PAL_SPAN+5*3),hl      ; held
        ld   a,0xFF
        ld   (PREG+1*REGS_PAL_SPAN+5*3+2),a     ; red: PALETTE1 entry 5 = orange
```

### Through PALIDX and PALDAT

Through ports, the palettes are reached by an index and a data register, as many machines' colour hardware is:

- **PALIDX** (`0x009`–`0x00A`) is a 10-bit index: bits 7–0 the entry, bits 9–8 the palette number. Writing its high byte commits it and starts PALDAT's byte order again at blue.
- **PALDAT** (`0x00B`) takes blue, green and red in turn. The red write changes the entry and steps PALIDX by 1: from entry 255 of one palette to entry 0 of the next.

So a stream of bytes written to PALDAT loads entry after entry. The copper reaches the palettes this way too, as it cannot reach the register page.

### Example 3-10: Loading a palette

Two ways to load 256 entries (768 bytes, blue, green, red) into PALETTE2.

Through the register page, a rising `LDIR`:

```asm
        ld   hl,pal_table
        ld   de,PREG+2*REGS_PAL_SPAN    ; PALETTE2, entry 0
        ld   bc,256*3
        ldir                            ; 16,123 T: 0.8 ms
```

Through PALIDX and PALDAT. `OTIR` cannot be used, since it steps B, the register number, downwards. But `OUTI` decrements B **before** it puts B on A15–A8, so with B one above PALDAT, `OUTI` writes PALDAT, and `INC B` puts B back:

```asm
        ld   bc,PALIDX_P
        xor  a
        out  (c),a                      ; entry 0: held
        inc  b
        ld   a,2
        out  (c),a                      ; palette 2: commits; PALDAT starts at blue
        inc  b                          ; B = PALDAT
        inc  b                          ; B = PALDAT + 1
        ld   hl,pal_table
        ld   e,0                        ; 256 entries
.entry:     outi                        ; blue  (B - 1 = PALDAT on A15-A8)
            inc  b
            outi                        ; green
            inc  b
            outi                        ; red: the entry changes, PALIDX steps
            inc  b
            dec  e
            jr   nz,.entry              ; 76 T an entry: 19,456 T, 1 ms
```

Both fit easily in the vertical blank (31,360 T-states). For the fastest load, unroll `LDI` 768 times: 12,288 T-states. The same table serves both ways, since both take the bytes in the same order.

### Which entries a layer uses

| Layer | Depth up to 4 bits | 8 bits |
|-------|--------------------|--------|
| Bitmap | PALOFS × 16 + p | p |
| Tile map | ((PALOFS + PAL) mod 16) × 16 + p | p |
| Target of the attribute layer | From the attribute byte (see "Spectrum Extras") | p |

CTRL1.PALOFS (bits 7–4) picks one of the palette's 16 blocks of 16 colours. A layer's colours change with one write to CTRL1: a darker set for a "paused" screen, or a different set for each band of a split screen, as in Example 3-9.

```
 palette:  0     16    32    48          240   255
           +-----+-----+-----+--- ... ---+-----+
           |blk 0|blk 1|blk 2|           |blk15|
           +-----+-----+-----+--- ... ---+-----+
              ^     ^     ^
              |     |     +-- a 4 bpp layer with PALOFS 2: colours 32-47
              |     +-------- a 1 bpp layer with PALOFS 1: colours 16-17
              +-------------- a 2 bpp layer with PALOFS 0: colours 0-3

      an 8 bpp layer uses all 256 entries directly

                Figure 3-11: Palette Offsets
```

### One palette for everything (SHAREPAL)

With **VIDCON.SHAREPAL** (bit 5) set, every layer and every sprite takes its colours from PALETTE0, as on a machine with one palette; PALETTE1, PALETTE2 and SPRPALETTE are then not used. One write then changes a colour everywhere it shows, for example copper colour bars that should run through all three layers. The layers then share PALETTE0's 256 entries, so keep their blocks apart with PALOFS.

### The default palette

The palettes are not cleared by reset. When the FPGA is loaded, all four palettes hold the Spectrum's colours in entries 0–15 and black in 16–255:

| Entry | Colour | Value | Entry | Colour | Value |
|-------|--------|-------|-------|--------|-------|
| 0 | Black | `0x000000` | 8 | Black | `0x000000` |
| 1 | Blue | `0x0000D7` | 9 | Bright blue | `0x0000FF` |
| 2 | Red | `0xD70000` | 10 | Bright red | `0xFF0000` |
| 3 | Magenta | `0xD700D7` | 11 | Bright magenta | `0xFF00FF` |
| 4 | Green | `0x00D700` | 12 | Bright green | `0x00FF00` |
| 5 | Cyan | `0x00D7D7` | 13 | Bright cyan | `0x00FFFF` |
| 6 | Yellow | `0xD7D700` | 14 | Bright yellow | `0xFFFF00` |
| 7 | White | `0xD7D7D7` | 15 | Bright white | `0xFFFFFF` |

So a 4 bpp layer with PALOFS 0 shows the Spectrum colours with no set-up, and entry k is Spectrum ink k + 8 × bright. A program that changed the palettes cannot rely on them after a reset; set every colour you use.

### The background colour

BGCOLOR is a 3-byte register (blue, green, red; red commits), not a palette entry. It shows wherever no layer and no sprite has a pixel. It is read at the start of each line's picture, so a write partway down the screen changes it from the next line on, which makes colour bars easy (Example 3-12). As on the Amiga and retro68k, the boot ROM shows its start-up progress as the background colour.

On a Spectrum the border is set through port `0xFE`, and that works here too (see "Spectrum Extras").

**VIDCON.BLANKALL** shows the background colour over the whole screen, hiding every layer and sprite, without stopping them.

### Summary: colours

| Name | Offset | Port | Function |
|------|--------|------|----------|
| PALIDX | `0x009`–`0x00A` | `0x0910`–`0x0A10` | Entry (7–0), palette (9–8). The high byte commits and restarts PALDAT's byte order |
| PALDAT | `0x00B` | `0x0B10` | Blue, green, red in turn; red changes the entry and steps PALIDX |
| Palettes | Register page `0x1400`–`0x1FFF` | – | 4 × 256 entries of 3 bytes; red commits. PALIDX not used |
| VIDCON.SHAREPAL | `0x000`, bit 5 | `0x0010` | 1: every layer and sprite uses PALETTE0 |
| BGCOLOR | `0x004`–`0x006` | `0x0410`–`0x0610` | Background colour; read at the start of each line's picture |
| CTRL1.PALOFS | Layer `+0x01`, bits 7–4 | | Colour block for layers of up to 4 bits |
| VIDCON.BLANKALL | `0x000`, bit 2 | `0x0010` | 1: show only the background colour |

---

## Direct Colour

In **direct colour**, set by VIDCON.DIRECT, the three layers together make one picture with the colour in each pixel, instead of an index into a palette. Each layer gives one channel:

| Channel | From | Depth |
|---------|------|-------|
| Red | Layer 0 | Its bits per pixel |
| Green | Layer 1 | Its bits per pixel |
| Blue | Layer 2 | Its bits per pixel |

Each channel's value is widened to 8 bits by repeating its bits, so that full scale stays full scale: a 4-bit value `abcd` becomes `abcdabcd`, a 2-bit value `ab` becomes `abababab`.

| Colour | Each layer | Bits per pixel | Bytes per pixel at 2× across | At 4× across |
|--------|------------|----------------|------------------------------|--------------|
| 24-bit (8/8/8) | 8 bpp | 24 | 1.5: just over the budget | 0.75 |
| 12-bit (4/4/4) | 4 bpp | 12 | 0.75 | 0.375 |
| 6-bit (2/2/2) | 2 bpp | 6 | 0.375 | 0.1875 |

Mixed depths work too. A tile layer gives its pixel values as a bitmap does.

In direct colour the layers' palettes, PRIO, PALOFS, PAL, PRI and TRANSP are not used, nor is the background colour, except with BLANKALL. Sprites are still drawn in front, in their colours from SPRPALETTE. **Set the three layers to the same window, scroll and scale**, since each pixel is made from the same position in all three. Where a layer has no pixel, its channel is 0.

### Example 3-11: A 24-bit screen

24-bit colour at 2× across needs 1.5 bytes per pixel, just over the budget of 1.48. A narrower window does not help, because the budget counts at every point across the screen. So this screen shows each source pixel 4× across and 2× down: three 8 bpp layers of 160 × 256 in the 640 × 512 window of Example 3-1, 0.75 bytes per pixel. Each pixel is twice as wide as it is tall, which suits smooth pictures such as gradients and photographs.

Each channel's lines are 256 bytes apart (160 used), and the three channels are 64 KB apart, each 64 KB-aligned. So pixel (x, y) is at the same offset, `(y mod 32) × 256 + x`, in page y ÷ 32 of each channel. With the three pages mapped into windows 2, 3 and 6, one pixel is three stores:

```asm
; Example 3-11: a 24-bit direct-colour screen, 160 x 256 at 4 x 2.
RED         equ     0x100000            ; 64 KB each, 64 KB-aligned
GREEN       equ     0x110000
BLUE        equ     0x120000
CTRL0_8BPP  equ     L_CTRL0_EN_M|(3<<L_CTRL0_BPP_B)|(2<<L_CTRL0_HSCALE_B)

; set-up: layers 0, 1, 2 from one table, then each its own pointer
            ld      de,CREG+L0
            ld      a,3
.layer:     ld      hl,rgb_layer
            ld      bc,L_SPAN
            ldir                        ; DE moves on to the next layer
            dec     a
            jr      nz,.layer
            ld      hl,0                ; RED, GREEN and BLUE: bits 15-0 are 0
            ld      (CREG+L0_BPL0PT),hl
            ld      a,RED>>16
            ld      (CREG+L0_BPL0PT+2),a
            ld      (CREG+L1_BPL0PT),hl
            ld      a,GREEN>>16
            ld      (CREG+L1_BPL0PT+2),a
            ld      (CREG+L2_BPL0PT),hl
            ld      a,BLUE>>16
            ld      (CREG+L2_BPL0PT+2),a
            ld      a,VIDCON_EN_M|VIDCON_DIRECT_M
            ld      (CREG+VIDCON),a

; Plot (C = red, D = green, E = blue) at offset HL in the current pages:
; red at 0x4000 (window 2), green at 0x6000 (window 3), blue at 0xC000
; (window 6). H holds 0x00-0x1F on entry. 52 T-states.
plot24:     ld      a,h
            or      0x40
            ld      h,a
            ld      (hl),c              ; red
            set     5,h                 ; 0x4000 -> 0x6000
            ld      (hl),d              ; green
            res     5,h
            set     7,h                 ; 0x4000 -> 0xC000
            ld      (hl),e              ; blue
            ret

rgb_layer:  db      CTRL0_8BPP,1<<L_CTRL1_VSCALE_B,0,0
            dw      VID_X0+40+640,VID_X0+40     ; 640 x 512 at (40, 32)
            dw      VID_Y0+32+512,VID_Y0+32
            dw      0,0
            dw      256,0               ; BPLSTRIDE 256
            d24     0                   ; BPL0PT: set after the copy
            db      0
            d24     0
            db      0
            d24     0
            db      0
```

The pointers must be reset each frame, as for any bitmap. 12-bit colour (three 4 bpp layers) at 2× across costs the same 0.75 and has square pixels; it is set up the same way with BPP 2 and HSCALE 1.

---

## The Fetch Budget

### How the display fetches

Each layer holds its **next group** of 16 source pixels in its data registers, while its shifters show the current group. There is no other storage. At the start of each line's horizontal blank (beam pixel 0), each layer whose window covers the line fetches its first group, which goes straight into the shifters, and then its second, which waits. After that, each time the shifters use up a group, they take the next one, and the layer fetches another. The layers and sprites that want a word are served earliest deadline first.

So the display reads memory at the rate it shows it. It has **memory cycles 1 and 3 of every 100 ns slot**: 4 bytes every 100 ns, 40 MB/s. These are its own cycles. It also gets any cycle nobody else wants, before the copper and the DMA engine. It never takes a cycle the Z80 has asked for: **the Z80 never waits for the display**, whatever is on the screen.

### The budget

Because data is fetched while it is shown, the limit is a **rate**: bytes per screen pixel that the beam passes, counting the blanking. A line is 864 pixels and lasts 32 µs, which is 320 memory slots:

| Bytes per line | Pixels per line | Budget |
|----------------|-----------------|--------|
| 320 slots × 4 = 1,280 | 864 | **1.48 bytes per pixel** |

Each layer needs, per screen pixel:

| Layer | Bytes per screen pixel |
|-------|------------------------|
| Bitmap, d bits per pixel | d ÷ 8 ÷ HS |
| Tile map, 1 or 2 bpp | 0.5 ÷ HS |
| Tile map, 4 bpp | 0.75 ÷ HS |
| Tile map, 8 bpp | 1.25 ÷ HS |
| Attribute layer | 0.125 ÷ its target's HS |

HS is the horizontal scale; vertical scaling does not reduce the cost. **At every point across the screen, the layers whose windows cover that point, with the sprites there, must add up to no more than the budget.** The Sprites chapter gives the sprites' cost.

### How to work out whether a screen fits

1. List the layers and, for each, its kind, depth, horizontal scale and window.
2. Work out each layer's bytes per pixel from the table above.
3. Find the places across and down the screen where different sets of windows overlap. Windows that do not overlap do not add up.
4. Add up each place's layers, and the sprites that can be there. Each sum must be 1.48 or less.
5. Check the memory: each picture, map and set of tiles, at the stride you chose. There are 4 MB.
6. Check the Z80's time: what must be redrawn each frame (see "What the CPU can draw in a frame").

### Worked examples

**Example 3-1**, a 4 bpp bitmap at 2×: 4 ÷ 8 ÷ 2 = **0.25**. Memory 64 KB at a stride of 256.

**Example 3-2**, a full-screen 8 bpp bitmap at 2×: **0.5**. Memory 144 KB.

**Example 3-7**, a 4 bpp tile map at 2× (0.375) under 1 bpp text at 1× (0.5): **0.875** inside the text window, 0.375 outside it. Memory: two 8 KB maps, 128 bytes of tiles, and the console's font.

**The boot console**: 1 bpp tiles at 1×, **0.5**, which leaves room for the other two layers.

**The Spectrum screen**: a 1 bpp bitmap at 2× (0.0625) with the attribute layer (0.0625): **0.125**.

**A platform game**: two 4 bpp tile layers at 2× for parallax (0.375 each) and an 8 bpp bitmap at 2× (0.5): **1.25**. Fits, with some room for sprites.

**A 256-colour game screen with a text overlay**: an 8 bpp bitmap at 1× (1.0) and 1 bpp text tiles at 1× (0.5) = **1.5**. Just over. Show the text at 2× across (0.25, total 1.25), or give it a band of its own below the game.

**Three 8 bpp tile layers at 2×**: 3 × 0.625 = **1.875**. Too much. Make one of them 4 bpp (0.375): 1.625, still too much; make two of them 4 bpp: 1.375, fits.

| Screen | Bytes per pixel | Fits? |
|--------|-----------------|-------|
| Spectrum screen: 1 bpp bitmap at 2× with attributes | 0.125 | Yes |
| Boot console: 1 bpp tiles at 1× | 0.5 | Yes |
| Text over a 4 bpp 360 × 288 bitmap at 2× | 0.5 + 0.25 = 0.75 | Yes |
| Example 3-7: text over 4 bpp tiles at 2× | 0.875 | Yes |
| Two 4 bpp tile layers and an 8 bpp bitmap, all at 2× | 1.25 | Yes |
| Two 8 bpp tile layers at 2× | 1.25 | Yes |
| One 8 bpp tile layer at 1× | 1.25 | Yes |
| 8 bpp bitmap at 1× and 4 bpp tiles at 2× | 1.375 | Yes |
| 8 bpp bitmap at 1× and 4 bpp bitmap at 1× | 1.5 | **No** (just over) |
| Three 8 bpp tile layers at 2× | 1.875 | **No** |
| Direct colour 12-bit at 2× | 0.75 | Yes |
| Direct colour 24-bit at 4× across | 0.75 | Yes |
| Direct colour 24-bit at 2× | 1.5 | **No** (just over) |
| Two 8 bpp bitmaps at 1× | 2.0 | **No** |

The 1.48 is what cycles 1 and 3 guarantee. The display also gets cycles that others leave: cycle 4 while there is no sound, and the Z80's cycles when it does not use them, which at 20 MHz is most of them. So a screen a little over the budget usually still shows correctly, at the expense of the copper and the DMA engine, never of the Z80. How far it can go is still to be measured; design within 1.48.

Each layer has one group of time in hand. Close to the budget, 8 bpp layers at 1× (8 words a group, or 10 for tiles) are the first to run short.

### What the CPU can draw in a frame

The display's budget is one limit; the Z80's time is the other. At 20 MHz a frame is 400,000 T-states:

| Job | T-states | Time |
|-----|----------|------|
| A frame | 400,000 | 20 ms |
| The vertical blank (49 lines) | 31,360 | 1.57 ms |
| One line | 640 | 32 µs |
| Scroll a tile layer: one SCROLLX write | 16 | 0.8 µs |
| Print a character on a tile layer | about 60 | 3 µs |
| Write one new column of a 64-high map (Example 3-6) | about 5,500 | 0.3 ms |
| Load a palette (768 bytes, `LDIR`) | 16,123 | 0.8 ms |
| Clear a 64 × 64 tile map (8 KB, `LDIR`) | 172,000 | 8.6 ms |
| Clear a 320 × 256 4 bpp bitmap (40 KB): `LDIR` | 860,000 | 43 ms |
| … with unrolled `LDI` | 655,000 | 33 ms |
| … with `PUSH` (11 T per 2 bytes, interrupts off) | 225,000 | 11 ms |

A bitmap game that redraws a whole screen every frame is beyond the Z80; one that redraws only what moves, or uses tile maps and sprites, is not. Clearing and copying large areas is the DMA engine's job (see its chapter), which uses no CPU time.

### When a layer runs short

If a layer's next group is not complete when its shifters need it, the layer shows transparent pixels (in direct colour, 0) for those 16 source pixels and tries again at the next group. It also sets its **OVERRUN** flag in VIDSTAT (bits 4, 5 and 6 for L0, L1 and L2; bit 2, OVERRUNA, for the attribute layer), which can raise the VIDERR interrupt. Nothing else on the screen goes wrong, and the Z80 is never affected. A screen within the budget never overruns, so OVERRUN is mainly a check while you develop:

```asm
OVERRUNS    equ     VIDSTAT_OVERRUN0_M|VIDSTAT_OVERRUN1_M|VIDSTAT_OVERRUN2_M|VIDSTAT_OVERRUNA_M

        ld   a,OVERRUNS
        ld   (CREG+VIDSTAT),a       ; clear the flags
        ; ... wait for a frame or two ...
        ld   a,(CREG+VIDSTAT)
        and  OVERRUNS
        jr   nz,too_much            ; a layer ran short
```

---

## Video Interrupts and the Beam Position

### The beam position

BEAMPOS holds the beam's position in beam coordinates: `hpixel` (2 bytes, `0x0F0`) then `vline` (2 bytes, `0x0F2`). Reading its first byte, `0x0F0`, captures all four, so read that first and the line and pixel always match:

```asm
        ld   hl,(CREG+BEAMPOS)      ; hpixel: reading 0x0F0 captures all four
        ld   de,(CREG+BEAMPOS+2)    ; vline, from the same capture
```

Through ports:

```asm
        ld   bc,BEAMPOS_P           ; 0xF010
        in   l,(c)                  ; captures
        inc  b
        in   h,(c)                  ; HL = hpixel
        inc  b
        in   e,(c)
        inc  b
        in   d,(c)                  ; DE = vline
```

While the beam is in the vertical blank, `vline` is less than VID_Y0 (49), and VIDSTAT.INVBLANK (bit 3) reads 1. FRAMECOUNT (2 bytes, `0x0F4`) goes up by one at the start of each frame; reading its low byte captures both.

```asm
; Wait until the beam reaches beam line HL. About 60 T-states a try.
wait_line:  push    de
.w:         ld      a,(CREG+BEAMPOS)    ; capture
            ld      de,(CREG+BEAMPOS+2) ; vline
            ld      a,e
            cp      l
            jr      nz,.w
            ld      a,d
            cp      h
            jr      nz,.w
            pop     de
            ret
```

### Example 3-12: Colour bars

The background colour is read at the start of each line's picture, so a write during beam line L − 1 changes line L. This loop changes it every 8 lines from a table, which makes colour bars behind (or instead of) the layers. It runs with interrupts off, one frame per pass.

```asm
; Example 3-12: colour bars. BGCOLOR changes every 8 lines, from a table of
; 72 colours (576 lines). Uses wait_line, above.
bars:       ld      ix,bar_colours+3
            ld      hl,VID_Y0+7         ; during picture line 7, for line 8
.bar:       call    wait_line
            ld      e,(ix+0)            ; blue
            ld      d,(ix+1)            ; green
            ld      (CREG+BGCOLOR),de   ; held
            ld      a,(ix+2)
            ld      (CREG+BGCOLOR+2),a  ; red: commits
            ld      de,3
            add     ix,de
            ld      de,8
            add     hl,de
            push    hl
            ld      de,VID_Y0+VID_H-1   ; beam line 624
            or      a
            sbc     hl,de
            pop     hl
            jr      c,.bar              ; up to picture line 567, for 568
            ld      hl,0
            call    wait_line           ; the vertical blank
            ld      hl,(bar_colours)
            ld      (CREG+BGCOLOR),hl
            ld      a,(bar_colours+2)
            ld      (CREG+BGCOLOR+2),a  ; picture line 0's colour
            jr      bars

bar_colours:
k = 0
            DUP     72
            d24     ((k*3)<<16)|(255-k*3)   ; red rising, blue falling
k = k + 1
            EDUP
```

The copper makes the same bars with no CPU time (see the Copper chapter).

### Video interrupts

The video unit raises three interrupt sources:

| Flag (VIDSTAT bit) | Source | When |
|--------------------|--------|------|
| VBLANK (0) | VBLANK, source 0 | Start of the frame: beam line 0, pixel 0 |
| LINE (1) | LINE, source 1 | Start of beam line LINECMP, pixel 0: 144 pixels before its picture |
| OVERRUNA (2), OVERRUN0–2 (4–6), SPRUNDER (7) | VIDERR, source 3 | A layer, the attribute layer or a sprite was late |

Each flag is **sticky**: it is set by the event and stays set until you write 1 to it in VIDSTAT. It raises its interrupt only if its bit in **VIDINTEN** is set (the same layout, bit 3 reserved). From there the request goes through the interrupt controller: the source must also be enabled in INTENA0, with INTCON.MASTER on, and the Z80 must have done `EI`. In IM 2 the vector is VECBASE + 2 × the source number: with the table of Example 3-1, VBLANK's entry is at `0xBFD0`, LINE's at `0xBFD2`, VIDERR's at `0xBFD6`. The Interrupts chapter explains this path in full.

Requests are level-sensitive: **the handler must clear its flag before `EI`**, by writing 1 to it, or the interrupt comes straight back.

```asm
vblank:     push    af
            ld      a,VIDSTAT_VBLANK_M
            ld      (CREG+VIDSTAT),a    ; clear the cause in the unit
            ; ... the frame's work ...
            pop     af
            ei
            reti
```

You can also poll the flags with interrupts off:

```asm
.frame:     ld      a,(CREG+VIDSTAT)
            and     VIDSTAT_VBLANK_M
            jr      z,.frame            ; not yet
            ld      (CREG+VIDSTAT),a    ; clear it: A holds just that bit
```

**LINE** comes once per frame, at the start of the beam line in LINECMP (2 bytes, bits 10–0). For picture line L, write VID_Y0 + L; a value above 624 never matches. To have it on several lines, write the next line number into LINECMP in the handler. The Z80 at 20 MHz takes at most 42 T-states (2.1 µs) to start an IM 2 handler, so a LINE handler runs early in the line it was asked for; that leaves most of the line's 640 T-states to change CTRL0–CTRL3, the window, SCROLLX, SCROLLY, PRIO or BGCOLOR for the **next** line, or BPLSTRIDE for the end of this one. At slower CPUSPEED settings the start-up time grows (16.8 µs at 2.5 MHz), so a LINE handler at a slow speed may miss the next line. Effects that must land on an exact pixel belong to the copper.

### Summary: interrupts and the beam

| Name | Offset | Port | Function |
|------|--------|------|----------|
| VIDSTAT | `0x001` | `0x0110` | VBLANK (0), LINE (1), OVERRUNA (2), OVERRUN0–2 (4–6), SPRUNDER (7): sticky, write 1 to clear. INVBLANK (3): read only |
| VIDINTEN | `0x002` | `0x0210` | Interrupt enables, as VIDSTAT bits 0, 1, 2, 4–7 |
| LINECMP | `0x007`–`0x008` | `0x0710`–`0x0810` | Beam line (10–0) of the LINE interrupt |
| BEAMPOS | `0x0F0`–`0x0F3` | `0xF010`–`0xF310` | `hpixel` (`0x0F0`), `vline` (`0x0F2`); reading `0x0F0` captures all four bytes |
| FRAMECOUNT | `0x0F4`–`0x0F5` | `0xF410`–`0xF510` | Frames; reading `0x0F4` captures both bytes |
| VIDSIZE | `0x0F6`–`0x0F9` | `0xF610`–`0xF910` | HVISIBLE (720), VVISIBLE (576) |

---

## When Register Writes Take Effect

| Registers | Take effect |
|-----------|-------------|
| CTRL0–CTRL3, WINX, WINY, SCROLLX, SCROLLY, MAPPT, PATPT; ATCTL, ATADDR, ATSTRIDE, ATSCROLL | At the start of each line's horizontal blank (beam pixel 0), before its picture. **To change line L, write during the visible part of line L − 1 or earlier** |
| BPL0PT, BPLSTRIDE | At once: they are live. The next word fetched uses a new pointer, which also becomes the line's saved start. BPLSTRIDE is used with the line's last fetch |
| PRIO, BGCOLOR | At the start of each line's picture (beam pixel 144), so a write in the line's horizontal blank still changes that line |
| Port `0xFE` border | At once (see "Spectrum Extras") |
| VIDCON, palette entries | At once: the next pixel |
| LINECMP, VIDSTAT, VIDINTEN, PALIDX, DMACON | At once. DMACON stops or starts the next fetch |

A value wider than a byte takes effect when its highest byte commits. A write that lands in the same few clocks as the hardware's copy of the line settings (at beam pixel 0) may take effect a line later.

---

## Spectrum Extras

These are not in retro68k. They are there for Spectrum screens and programs.

### The attribute layer

The attribute layer draws nothing. It replaces the colour block of its **target** layer (ATCTL.TARGET: L0, L1 or L2) with one byte per **cell**, as a Spectrum's attributes do.

- **Cells** are 8 source pixels across and 8 source lines down, or 8 × 1 with ATCTL.CELL1. They follow the target's scale: an 8 × 8 cell on a 2 × 2 layer covers 16 × 16 beam pixels. The target can be a bitmap or a tile map.
- **Window:** the target's.
- **Addresses:** ATADDR is the physical address of the cell row at the window's top left. Each cell row is ATSTRIDE bytes after the one before. The hardware keeps its own row address, so ATADDR is not moved and needs no rewriting each frame. ATADDR and ATSTRIDE are even.
- **Scroll:** ATSCROLL bits 3–0 skip 0–15 source pixels at the start of each line; bits 6–4 start the first cell row 0–7 lines into the row. Coarse scroll is by ATADDR, in whole words (two cells).
- **Colours:** with attribute byte A, the target's pixel p of d bits takes entry `((A << d) | p) and 0xFF` of the target's palette. For a 1 bpp target that is **2 × (A and 0x7F) + p**: entry 2A is the paper, 2A + 1 the ink. For a 4 bpp target, bits 3–0 of A pick one of 16 blocks, so the attribute layer gives a 16-colour layer a colour block per cell.
- **Flash:** with ATCTL.FLASH set, bit 7 of A is a flash bit. While the flash phase is on, the pixel values in such a cell are inverted, which swaps paper and ink. The phase changes every 8, 16, 32 or 64 frames (ATCTL.RATE; the Spectrum's is 16).
- **Cost:** 0.125 ÷ the target's HS bytes per pixel, fetched as a layer is. A late attribute group makes the target transparent in its two cells and sets OVERRUNA.
- In direct colour it has no effect, and it does not act on sprites.

With 8 × 1 cells (CELL1) every pixel line of a cell has its own attribute: Timex-style high colour, with no CPU timing at all.

| Name | Offset | Port | Bits |
|------|--------|------|------|
| ATCTL | `0x130` | `0x3011` | EN (0), TARGET (2–1: 0 L0, 1 L1, 2 L2, 3 none), CELL1 (3), FLASH (4), RATE (6–5: 8, 16, 32, 64 frames), PHASE (7, read only) |
| ATADDR | `0x131`–`0x133` | `0x3111`–`0x3311` | 21–1: the top cell row's address |
| ATSTRIDE | `0x134` | `0x3411` | 7–1: bytes per cell row (0–254) |
| ATSCROLL | `0x135` | `0x3511` | 3–0 fine X, 6–4 fine Y |

The attribute registers are at offsets `0x130` and up, in page `0x11`: read them with `ld a,ATCTL&0xFF` then `in a,(CUSTPAGE+1)`, or at `CREG + ATCTL` in the register page. The copper reaches them only with its two-word MOVEF.

### The border: port 0xFE

As on a Spectrum, a write to port `0xFE` sets the border colour, which here is the background colour. Bits 2–0 pick one of eight colours, the Spectrum's without BRIGHT; bit 4 is the beeper and bit 3 MIC, as on a Spectrum:

```asm
        ld   a,2                    ; red border, beeper off
        out  (0xFE),a               ; or out (ULA_PORT),a
```

| Bits 2–0 | Colour | BGCOLOR |
|----------|--------|---------|
| 0 | Black | `0x000000` |
| 1 | Blue | `0x0000D7` |
| 2 | Red | `0xD70000` |
| 3 | Magenta | `0xD700D7` |
| 4 | Green | `0x00D700` |
| 5 | Cyan | `0x00D7D7` |
| 6 | Yellow | `0xD7D700` |
| 7 | White | `0xD7D7D7` |

- The write sets all three bytes of BGCOLOR, and BGCOLOR then reads back the new colour. BGCOLOR and port `0xFE` set the same register, so the later write wins. For other border colours (BRIGHT ones, say), write BGCOLOR.
- **A port `0xFE` write acts at once**, from the next pixel, so a Spectrum program that changes the border in the middle of a line (a tape loader's stripes, a border effect) shows the change where it made it. A write to BGCOLOR as a register keeps the line rule: it acts from the next line's picture.
- The background shows wherever no layer and no sprite is opaque. With the Spectrum screen below, that is everywhere outside the 512 × 384 window: a Spectrum's border.
- The copper cannot write port `0xFE`; it writes BGCOLOR.

### Example 3-13: The Spectrum screen

A 48K Spectrum's screen is 6,144 bytes of pixels, 32 bytes a line, in its own line order, then 768 attribute bytes, 32 a row. This example shows it unchanged at 2 × 2, centred:

| Part | Set-up |
|------|--------|
| Pixels | Layer 0: 1 bpp bitmap, 2 × 2 (CTRL0 `0x41`, CTRL1 `0x01`), window 248–760 × 145–529 |
| Line order | BPLSTRIDE 256, the next pixel line of the same character row; the copper sets BPL0PT at the start of each of the 24 character rows |
| Colours | The attribute layer on L0, 8 × 8 cells, flash every 16 frames (ATCTL `0x31`); ATADDR = the screen + 6,144, ATSTRIDE 32 |
| Palette | PALETTE0 entries 2A and 2A + 1 for A = 0–127: paper and ink |
| Border | Port `0xFE` |

The screen is at physical `0x000000`. After reset, window 2 shows SRAM page 0, so the Z80 sees the screen at `0x4000`–`0x5AFF`, exactly where a Spectrum has it.

**The line order.** Pixel line y of a Spectrum screen is at `screen + ((y and 0xC0) << 5) + ((y and 7) << 8) + ((y and 0x38) << 2)`. Within a character row of 8 lines each line is 256 bytes after the one before, which BPLSTRIDE = 256 does by itself. So the copper only writes BPL0PT for the first line of each character row r, `screen + ((r and 0x18) << 8) + ((r and 7) << 5)`. Row r starts at beam line 145 + 16r; the write must land after layer 0's last fetch on line 144 + 16r and before the line ends, so the copper waits for beam (144 + 16r, 768).

```asm
; Example 3-13: a Spectrum screen. The 6,912-byte screen at physical
; 0x000000 (Z80 0x4000-0x5AFF through window 2) shown by layer 0, 1 bpp at
; 2 x 2, with the attribute layer for its colours and the copper for its
; line order. Uses map_regs and video_off from Example 3-1.

            include "hw.inc"
            include "copper.inc"

REGS        equ     0xE000
CREG        equ     REGS+REGS_CUSTOM
PREG        equ     REGS+REGS_PALETTE
RAMOFS      equ     0x4000
STACK       equ     0xBF00

SCREEN      equ     0x000000            ; = Z80 0x4000 through window 2
SPEC_X      equ     VID_X0+(VID_W-512)/2    ; 248
SPEC_Y      equ     VID_Y0+(VID_H-384)/2    ; 145

            org     0x8000
start:      di
            ld      sp,STACK
            call    map_regs
            call    video_off
            call    test_screen         ; something to look at

            ld      hl,spec0            ; layer 0
            ld      de,CREG+L0
            ld      bc,L_SPAN
            ldir
            ld      hl,(SCREEN+6144)&0xFFFF
            ld      (CREG+ATADDR),hl    ; the attributes: held
            ld      a,(SCREEN+6144)>>16
            ld      (CREG+ATADDR+2),a   ; commits
            ld      a,32
            ld      (CREG+ATSTRIDE),a
            xor     a
            ld      (CREG+ATSCROLL),a
            ld      a,ATCTL_EN_M|(0<<ATCTL_TARGET_B)|ATCTL_FLASH_M|(1<<ATCTL_RATE_B)
            ld      (CREG+ATCTL),a      ; 0x31: on, L0, 8 x 8, flash every 16
            call    spec_pal

            ld      hl,(speclist-RAMOFS)&0xFFFF
            ld      (CREG+COP1LC),hl    ; the copper list's physical address
            ld      a,(speclist-RAMOFS)>>16
            ld      (CREG+COP1LC+2),a   ; commits
            ld      a,COPCON_EN_M
            ld      (CREG+COPCON),a

            ld      a,1
            out     (ULA_PORT),a        ; a blue border, as a Spectrum's
            ld      a,DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_BPLEN_M|DMACON_COPEN_M
            ld      (CREG+DMACON),a
            ld      a,VIDCON_EN_M
            ld      (CREG+VIDCON),a
main:       jr      main                ; Spectrum code draws at 0x4000-0x5AFF

; PALETTE0 for the attribute layer: entry 2A is attribute A's paper, 2A + 1
; its ink, for A = 0-127 (bit 7, flash, is not part of the index).
spec_pal:   ld      de,PREG             ; PALETTE0, entry 0
            ld      c,0                 ; C = A
.attr:      ld      a,c
            and     0x40                ; bright?
            rrca
            rrca
            rrca
            ld      b,a                 ; B = 8 if bright, else 0
            ld      a,c
            rrca
            rrca
            rrca
            and     7                   ; paper
            add     a,b
            call    .copy               ; entry 2A
            ld      a,c
            and     7                   ; ink
            add     a,b
            call    .copy               ; entry 2A + 1
            inc     c
            bit     7,c
            jr      z,.attr             ; 128 attributes, 256 entries
            ret
.copy:      ld      l,a                 ; colour A (0-15) of the table to (DE)
            add     a,a
            add     a,l
            ld      l,a
            ld      h,0
            push    bc
            ld      bc,speccy
            add     hl,bc
            ldi                         ; blue
            ldi                         ; green
            ldi                         ; red: the entry changes
            pop     bc
            ret

speccy:     d24     0x000000,0x0000D7,0xD70000,0xD700D7,0x00D700,0x00D7D7,0xD7D700,0xD7D7D7
            d24     0x000000,0x0000FF,0xFF0000,0xFF00FF,0x00FF00,0x00FFFF,0xFFFF00,0xFFFFFF

; A test screen: stripes, and the 256 attributes in turn
test_screen:
            ld      hl,0x4000
            ld      de,0x4001
            ld      bc,6143
            ld      (hl),0xF0           ; 4 pixels ink, 4 paper
            ldir
            ld      hl,0x5800
            ld      bc,768
.at:        ld      (hl),l              ; attribute = the address's low byte
            inc     hl
            dec     bc
            ld      a,b
            or      c
            jr      nz,.at
            ret

spec0:      db      L_CTRL0_EN_M|(0<<L_CTRL0_BPP_B)|(1<<L_CTRL0_HSCALE_B)  ; 0x41
            db      1<<L_CTRL1_VSCALE_B ; 0x01
            db      0,0
            dw      SPEC_X+512,SPEC_X   ; WINX: 248-760
            dw      SPEC_Y+384,SPEC_Y   ; WINY: 145-529
            dw      0,0
            dw      256,0               ; BPLSTRIDE: the next line of the row
            d24     SCREEN              ; BPL0PT: written by the copper
            db      0
            d24     0
            db      0
            d24     0
            db      0

; The copper: BPL0PT for the first line of each character row
            ALIGN   2
speclist:
row = 0
            DUP     24
            CWAIT   144+16*row,768      ; after the last fetch of the line before
            CMOVEA  L0+L_BPL0PT,SCREEN+((row&0x18)<<8)+((row&7)<<5)
row = row + 1
            EDUP
            CSTOP
```

The copper list is 24 × 5 words plus a STOP: 241 words, 482 bytes, and it costs 120 copper fetches a frame. The pointer needs no reset in the vertical blank, since the copper writes it before every character row. A program that keeps its screen in **linear** order (each line 32 bytes after the one before) needs no copper: BPLSTRIDE = 32, and BPL0PT written in the vertical blank. The Copper chapter also has a version of this list that writes every pixel line.

Cost: 0.0625 bytes per pixel for the bitmap and 0.0625 for the attributes, inside the 512-pixel window only.

### Porting a Spectrum game's screen code

A Spectrum game that writes its screen at `0x4000` runs its screen code unchanged once the display is set up as in Example 3-13. The points to check:

1. **The screen's address.** Keep the Spectrum screen at a page boundary and map that page into window 2 (`0x4000`–`0x5FFF`). After reset this is already so, with the screen at physical `0x000000`. A game that double-buffers through the 128K's second screen at `0xC000` can do the same with another page in window 6, and the copper list's addresses changed to it.
2. **The display.** Layer 0, the attribute layer, the palette and the copper list, as Example 3-13. They take no CPU time once set up.
3. **The border.** `OUT (0xFE),A` works as on a Spectrum, at once, so border stripes appear where the game makes them. The beeper is bit 4 of the same port (see the System chapter).
4. **The frame interrupt.** VBLANK comes at 50 Hz, as the Spectrum's frame interrupt does, but at a different point of the frame: the start of the vertical blank, 49 lines before the picture. A Spectrum game in IM 2 usually has a 257-byte table of equal bytes, so any vector byte lands on its handler; that works here unchanged. But **the game's handler does not clear VIDSTAT.VBLANK**, and the request stays on until it is cleared, so the handler would be entered again at its `EI`. Put a few lines of your own in front of it: clear the flag, then jump to the game's handler. In IM 1, `RST 38h` runs `0x0038` in the boot ROM, so map an SRAM page with your own code into window 0 first.
5. **Timing.** Code timed to the Spectrum's 3.5 MHz (sound, delay loops) needs CPUSPEED's SPECTRUM setting (3.57 MHz; see the System chapter). There is no contended memory and no floating bus, so code that times itself by them does not work as it did.
6. **Raster effects.** Attribute changes timed to the beam (multicolour) are not needed: use 8 × 1 attribute cells (ATCTL.CELL1) and an attribute area of 6,144 bytes, ATSTRIDE 32. Effects that need other changes mid-screen are the copper's job.
7. **The keyboard.** Port `0xFE` reads give the keyboard rows as on a Spectrum (see the Input chapter).

### The default palette

The Spectrum colours in entries 0–15 of every palette at power-on are a Spectrum extra too; see "The default palette" under "Colour Registers and Palette Offsets".

---

## Summary of Playfield Registers

All offsets are custom offsets. The port of offset k is `(k and 0xFF) << 8 | (0x10 + (k >> 8))`; in the register page offset k is at `0x1000` + k, which this chapter's convention puts at `0xF000` + k (`CREG + k`). Layer n's registers are at Ln + offset, where L0 = `0x090`, L1 = `0x0B0` and L2 = `0x0D0`; `hw.inc` also gives them ready-added, as `L0_CTRL0` and `L1_BPL0PT`, with `_P` for the port. Values wider than a byte are low byte first; the highest byte commits. Access: R read only, RW read and write, W1C sticky flags cleared by writing 1, SC set/clear, CAP reading the lowest byte captures.

### Global registers

| Name | Offset | Port | Access | Function |
|------|--------|------|--------|----------|
| VIDCON | `0x000` | `0x0010` | RW | EN (0): display on. BLANKALL (2): background colour only. DIRECT (4): direct colour. SHAREPAL (5): everything on PALETTE0 |
| VIDSTAT | `0x001` | `0x0110` | W1C | VBLANK (0), LINE (1), OVERRUNA (2), INVBLANK (3, R), OVERRUN0–2 (4–6), SPRUNDER (7) |
| VIDINTEN | `0x002` | `0x0210` | RW | Enables for VIDSTAT bits 0, 1, 2, 4–7 |
| PRIO | `0x003` | `0x0310` | RW | FRONT (1–0), MIDDLE (3–2), BACK (5–4); 3 = no layer. Reset `0x24` |
| BGCOLOR | `0x004`–`0x006` | `0x0410`–`0x0610` | RW | Background colour: blue, green, red (commits). Also set by port `0xFE` |
| LINECMP | `0x007`–`0x008` | `0x0710`–`0x0810` | RW | LINE interrupt beam line (10–0) |
| PALIDX | `0x009`–`0x00A` | `0x0910`–`0x0A10` | RW | Entry (7–0), palette (9–8) |
| PALDAT | `0x00B` | `0x0B10` | RW | Palette data: blue, green, red; red changes the entry and steps PALIDX |
| DMACON | `0x00C` | `0x0C10` | SC | SETCLR (7), DMAEN (6), BPLEN (5): both needed for layer DMA; COPEN (4), BLTEN (3), SPREN (2) |
| BEAMPOS | `0x0F0`–`0x0F3` | `0xF010`–`0xF310` | R, CAP | `hpixel` (`0x0F0`), `vline` (`0x0F2`) |
| FRAMECOUNT | `0x0F4`–`0x0F5` | `0xF410`–`0xF510` | R, CAP | Frames |
| VIDSIZE | `0x0F6`–`0x0F9` | `0xF610`–`0xF910` | R | HVISIBLE (720), VVISIBLE (576) |

### Layer registers

| Name | Offset | Bytes | Access | Function |
|------|--------|-------|--------|----------|
| CTRL0 | Ln + `0x00` | 1 | RW | EN (0), BPP (3–2), TRANSP (4), MODE (5), HSCALE (7–6) |
| CTRL1 | Ln + `0x01` | 1 | RW | VSCALE (1–0), PALOFS (7–4) |
| CTRL2 | Ln + `0x02` | 1 | RW | WRAP (7–4): bitmap pointer wrap |
| CTRL3 | Ln + `0x03` | 1 | RW | MAPW (1–0), MAPH (3–2): tile map size |
| WINX (XEND) | Ln + `0x04` | 2 | RW | First beam pixel after the window. Reset 864 |
| WINX (XSTART) | Ln + `0x06` | 2 | RW | First beam pixel of the window. Reset 144 |
| WINY (YEND) | Ln + `0x08` | 2 | RW | First beam line after the window. Reset 625 |
| WINY (YSTART) | Ln + `0x0A` | 2 | RW | First beam line of the window. Reset 49 |
| SCROLLX | Ln + `0x0C` | 2 | RW | Bitmap: fine scroll (3–0). Tiles: map X (9–0) |
| SCROLLY | Ln + `0x0E` | 2 | RW | Tiles: map Y (9–0) |
| BPLSTRIDE | Ln + `0x10` | 2 | RW | Bitmap: bytes from one line's start to the next; signed, even |
| BPL0PT | Ln + `0x14` | 3 | RW, CAP | Bitmap: physical address of the next word (21–1) |
| MAPPT | Ln + `0x18` | 3 | RW | Tiles: the map's first entry (21–1) |
| PATPT | Ln + `0x1C` | 3 | RW | Tiles: tile 0's first byte (21–1) |

Offsets `0x12`–`0x13`, `0x17`, `0x1B` and `0x1F` are reserved: they read `0xFF` and ignore writes.

### CTRL fields

| Register | Bits | Field | Values |
|----------|------|-------|--------|
| CTRL0 | 0 | EN | 1: layer on |
| CTRL0 | 1 | – | Reserved; write 0 |
| CTRL0 | 3–2 | BPP | 0 = 1, 1 = 2, 2 = 4, 3 = 8 bits per pixel |
| CTRL0 | 4 | TRANSP | 1: pixel value 0 is transparent |
| CTRL0 | 5 | MODE | 0: bitmap, 1: tile map |
| CTRL0 | 7–6 | HSCALE | 0–3: 1×, 2×, 4×, 8× across |
| CTRL1 | 1–0 | VSCALE | 0–3: 1×, 2×, 4×, 8× down |
| CTRL1 | 7–4 | PALOFS | Colour block for layers of up to 4 bits |
| CTRL2 | 7–4 | WRAP | Bitmap: 0 off; n = blocks of 2^(n + 9) bytes (1–13) |
| CTRL3 | 1–0 | MAPW | 0 = 32, 1 = 64, 2 = 128 entries wide |
| CTRL3 | 3–2 | MAPH | 0 = 32, 1 = 64, 2 = 128 entries high |

### Tile map entry

| Bits | Field | Byte |
|------|-------|------|
| 8–0 | TILE: tile number 0–511 | Low byte, and bit 0 of the high byte |
| 12–9 | PAL: palette block for tiles of up to 4 bits | High byte, bits 4–1 |
| 13 | XFLIP | High byte, bit 5 |
| 14 | YFLIP | High byte, bit 6 |
| 15 | PRI: in front of all layers and of sprites with DEPTH 1–3 | High byte, bit 7 |

### Palettes in the register page

| Register page | Palette | Entry i |
|---------------|---------|---------|
| `0x1400`–`0x16FF` | PALETTE0 (layer 0) | `0x1400` + 3i: blue, green, red (red commits) |
| `0x1700`–`0x19FF` | PALETTE1 (layer 1) | `0x1700` + 3i |
| `0x1A00`–`0x1CFF` | PALETTE2 (layer 2) | `0x1A00` + 3i |
| `0x1D00`–`0x1FFF` | SPRPALETTE | `0x1D00` + 3i |

### Attribute layer (Spectrum extra)

| Name | Offset | Port | Access | Function |
|------|--------|------|--------|----------|
| ATCTL | `0x130` | `0x3011` | RW (PHASE R) | EN (0), TARGET (2–1), CELL1 (3), FLASH (4), RATE (6–5), PHASE (7) |
| ATADDR | `0x131`–`0x133` | `0x3111`–`0x3311` | RW | Top cell row's address (21–1) |
| ATSTRIDE | `0x134` | `0x3411` | RW | Bytes per cell row (7–1) |
| ATSCROLL | `0x135` | `0x3511` | RW | Fine X (3–0), fine Y (6–4) |

### Port 0xFE (Spectrum extra)

| Port | Write | Read |
|------|-------|------|
| `0xFE`, any high byte | Bits 2–0: border, sets BGCOLOR at once to one of 8 colours; bit 3 MIC, bit 4 beeper | Keyboard rows picked by A15–A8 (Input chapter) |
