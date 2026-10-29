# Chapter 5: Coprocessor Hardware

## Introduction

The **copper** is a small coprocessor that works in step with the video beam. It runs a list of instructions, the **copper list**, from SRAM once every frame, and with them it writes the custom registers at the beam positions you choose. It needs no help from the Z80 while it runs.

With a few instructions in its list, the copper can:

- change colours partway down the screen, on every line, or in the middle of a line;
- put a bitmap layer's pointer back to the top of its picture at the start of every frame;
- open a split screen, with a new pointer, scroll or format from a chosen line down;
- start the sprites for each frame, and reuse them lower down;
- start DMA jobs, and interrupt the Z80 at a chosen place on the screen.

Because the copper's writes are tied to the beam, they happen at the same place on the screen in every frame, whatever the Z80 is doing. Effects that would be impossible for an interrupt handler, which can be up to 2 µs late, cost the Z80 nothing.

The chapter covers:

- what a copper instruction is;
- writing registers with MOVE and MOVEF, a byte at a time, and colours whole;
- waiting for a beam position with WAIT, and the pixel-only WAIT;
- the copper's control registers, and starting and stopping it, with a complete program;
- loops with SKIP and JUMP;
- changing a colour in the middle of a line;
- the copper's own registers: X and Y, arithmetic, conditions, storage registers and subroutines, with a split screen and a raster bar moved by the Z80;
- the copper interrupt;
- layer pointers, the two lists, background lists and double-buffered lists;
- starting DMA jobs;
- copper timing: how exact it is, how fast it runs, and its priority;
- what the copper can and cannot reach;
- a summary of the instructions and the registers.

You should have read Chapter 1 ("The Hardware Registers") and the Playfield Hardware chapter, because nearly everything the copper does is to write the registers described there. Example 5-6 uses an interrupt, explained in the Interrupts and Timers chapter.

### Conventions in this chapter

- Examples are Z80 assembly language for sjasmplus. They start with `include "hw.inc"` and then `include "copper.inc"`, which gives the copper's instructions as macros.
- In a copper list, a register is named by its **offset in the custom block**, exactly as `hw.inc` gives it: `BGCOLOR`, `PALDAT`, `L0_SCROLLX0`. No port or page is involved, because the copper writes only the custom block.
- The Z80 reaches the copper's own registers through ports in page `0x11`: `COPCON_P`, `COP1LC0_P` and so on, with `LD BC,port` and `OUT (C),r`.
- Copper instructions are written with the macros (`CMOVE`, `CWAIT` and the rest). In the text, the instructions themselves are written MOVE, WAIT and so on.
- Positions in WAIT and SKIP are **beam positions** (see "The beam position" below): beam line 49 is the picture's first line, and beam pixel 144 its first pixel.
- The complete examples are in `examples/copper/`, loaded at `0x8000`. They draw over the boot ROM's console: layer 0, a tile layer in a 640 × 480 window at beam pixels 184–824 and beam lines 97–577, with rows of 16 beam lines. Its text is ink on paper, PALETTE0 entries 17 and 16 (the console's colour pair 0).
- The programs run in the boot ROM's **program map** (Chapter 1, "Programs"), so a Z80 address is also the physical address the copper needs.

---

## What Is a Copper Instruction?

A copper instruction is one or two **16-bit words**, at an even address in SRAM. A word is stored low byte first, as the Z80 stores any 16-bit value, so `DW` builds them. The high byte of the first word is the instruction's **code**:

- `0x00`–`0xEF`: **MOVE**. The code is the register's offset, and the low byte is the data. One word.
- `0xF0`–`0xFC`: the other instructions.

| Code | Instruction | Macro | Words | What it does |
|------|-------------|-------|-------|--------------|
| `0x00`–`0xEF` | MOVE | `CMOVE reg,value` | 1 | Writes a byte to a register at offset `0x000`–`0x0EF` |
| `0xFC` | MOVEF | `CMOVEF reg,value` | 2 | Writes a byte to any custom offset, `0x000`–`0x3FF` |
| `0xF0` | WAIT | `CWAIT line,pixel` | 2 | Waits until the beam reaches the position |
| `0xF0`, P set | WAIT, pixel only | `CWAITP pixel` | 2 | Waits until the beam reaches the pixel, on this line or the next |
| `0xF0`, B set | WAIT, and the DMA engine | `CWAITB line,pixel` | 2 | As WAIT, and also until the DMA engine is idle |
| `0xF1` | SKIP | `CSKIP line,pixel` | 2 | Skips the next instruction if the beam has reached the position |
| `0xF1`, P set | SKIP, pixel only | `CSKIPP pixel` | 2 | As SKIP, comparing the pixel only |
| `0xF2` | JUMP | `CJUMP address` | 2 | Continues at the address |
| `0xF3` | STOP | `CSTOP` | 1 | Stops until the next frame |
| `0xF4`–`0xF8` | MOVR | `CMOVX`, `CMOVR` … | 1 | A MOVE through the copper's registers X and Y |
| `0xF9` | ALU | `CLDI`, `CADDI` … | 1 or 2 | Arithmetic on X and Y |
| `0xFA` | SKIPC | `CSKIPEQ` … | 1 | Skips the next instruction if a condition holds |
| `0xFB` | CALL, RET | `CCALL address`, `CRET` | 2, 1 | Subroutines |

MOVR, ALU, SKIPC, CALL and RET work with the copper's own registers, and have their own section, "The Copper's Registers and Arithmetic". Codes `0xFD`–`0xFF`, and any bit that must be 0 but is set, are **reserved**. The copper treats them as STOP and sets COPSTAT.ERR. So erased memory (`0xFFFF`) stops the copper, rather than letting it write registers at random.

`CMOVE BGCOLOR0,0x80` is the one word `0x0480`: code `0x04` (BGCOLOR's blue byte), data `0x80`. `CSTOP` is `0xF300`.

---

## The MOVE Instruction

MOVE writes its byte to the register at its offset, **at once**, by the same rule as the Z80's writes: each byte of a register is written on its own, and takes effect when it is written.

### What a MOVE reaches

The code is the offset, so a one-word MOVE reaches offsets `0x000`–`0x0EF`. That is where the registers the copper writes most are:

| Offsets | Registers |
|---------|-----------|
| `0x000`–`0x00F` | The video globals: VIDCON, PRIO, BGCOLOR, PALIDX, PALDAT, DMACON … |
| `0x010`–`0x08F` | The 8 sprites, 16 bytes each |
| `0x090`–`0x0EF` | The 3 layers, 32 bytes each: `L0_`, `L1_`, `L2_` |

Everything above, `0x0F0`–`0x3FF`, needs **MOVEF**, two words: the copper's own registers (`0x100`–`0x11F`), the sprite globals, the attribute layer and the DMA engine. `CMOVE` with an offset of `0x0F0` or more is an assembly error; `CMOVEF` takes any offset.

### Registers wider than a byte

A register of 2, 3 or 4 bytes is that many consecutive offsets, **low byte first**. The macros write all its bytes, a MOVE (or MOVEF) each, low byte first:

| Macro | Writes | Used for |
|-------|--------|----------|
| `CMOVEW reg,value` | 2 bytes | SCROLLX, BPLSTRIDE, PALIDX |
| `CMOVEA reg,value` | 3 bytes | Pointers (BPL0PT, SPRxPT, COP1LC) and colours (BGCOLOR) |
| `CMOVEL reg,value` | 4 bytes | SPRxH, SPRxV, SPRxSTEP, a layer's window |
| `CMOVEN reg,value,n` | n bytes (1–4) | Any of them |

Each byte takes effect when it is written, so between the MOVEs the register holds a mix of old and new bytes. Write a wide register where the hardware is not using it: a layer's settings in the vertical blank or in the line before the one they are for, and a pointer while its layer is not fetching ("Copper Timing" gives the rules).

### Colours

**Colours are the exception.** A colour is 3 bytes: blue, green, red. A MOVE to a colour's blue or green byte goes into the copper's own **colour assembly buffer**, and the MOVE to its red byte writes the colour **whole**, with the blue and green from the buffer. So a colour never shows half changed.

- **BGCOLOR**, the background colour, is at `BGCOLOR0` (blue), `BGCOLOR1` (green) and `BGCOLOR2` (red). `CMOVEA BGCOLOR,0x0000FF` makes it blue: blue `0xFF`, green 0, red 0.
- **Palette entries** are reached through PALIDX and PALDAT, as the Z80 reaches them. PALIDX (2 bytes) chooses the entry: bits 7–0 the entry, bits 9–8 the palette (0–2 PALETTE0–2, 3 SPRPALETTE). Then three MOVEs to PALDAT write blue, green and red; the red changes the entry and moves PALIDX on to the next entry. Writing either byte of PALIDX starts again at blue.

```asm
        CMOVE   PALIDX0,17              ; PALETTE0 entry 17
        CMOVE   PALIDX1,0
        CMOVE   PALDAT,0x00             ; blue,
        CMOVE   PALDAT,0xFF             ; green: both held in the buffer,
        CMOVE   PALDAT,0xFF             ; red: the entry is yellow from here
```

The copper has its own PALIDX, byte count and buffer, apart from the Z80's and the DMA engine's. So the Z80 can write the palette while the copper does, in any order, and neither disturbs the other.

The buffer is one for all colours, not one per entry, and other instructions may come between the bytes. **Tip:** write a colour's blue and green *before* a WAIT and its red *after* it. The colour then changes with the one MOVE straight after the WAIT, which is exact to the pixel. Example 5-4 does this.

Palette entries take effect from the next pixel. BGCOLOR is read at the start of each line's picture, so a change made in a line's horizontal blank shows on that line, and one made during its picture shows from the next line.

---

## The WAIT Instruction

WAIT makes the copper wait until the beam reaches a position on the screen. While it waits, it uses no memory cycles. When the position comes, it goes on with the next instruction, which it has already read.

### The beam position

A WAIT gives a **line** and a **pixel** in beam coordinates: line 0 is the start of the vertical blank, and pixel 0 is the start of a line's horizontal blank. Each line has its blank first and then its picture. Both are 10 bits, so the copper can name every position in the frame, to the pixel:

| Part of the frame | Lines | Pixels |
|-------------------|-------|--------|
| Vertical blank | 0–48 | 0–863 |
| Horizontal blank | 0–624 | 0–143 |
| Picture | 49–624 | 144–863 |

The beam passes 864 pixels a line, 37 ns each, and 625 lines a frame, 50 frames a second. A position with a pixel of 864 or more, or a line of 625 or more, is never reached.

```asm
        CWAIT   149,0                   ; the blank before picture line 100
        CWAIT   149,144                 ; picture line 100's first pixel
        CWAIT   149,504                 ; the middle of picture line 100
```

A WAIT for line n, pixel 0 ends at the start of line n's horizontal blank, 144 pixels before its picture: the place for changes that must be in place for line n's picture, such as BGCOLOR, PRIO and the palette. A layer's line settings (CTRL, the window, SCROLLX) are taken at that moment, so those must be written during line n − 1.

### Beam positions through the frame

The copper starts its list again from COP1LC at the start of every frame, beam line 0, pixel 0, at the same moment as the vertical blank interrupt. The picture's first line comes 49 lines later. Those blank lines are where the set-up for the frame goes: the writes at the top of the list (pointers, colours) are done there, before the picture's first line is fetched.

```
     start of list --> line   0 +-----------------------------------+
     (COP1LC)                   |  vertical blank, lines 0-48       |
                                |  set-up: pointers, colours        |
                       line  49 +-----------------------------------+
                                |                                   |
                                |  the picture, lines 49-624        |
                                |  WAITs for picture lines          |
                                |                                   |
                       line 624 +-----------------------------------+
                                    |
                                    +--> next frame: the list
                                         starts again from COP1LC

                Figure 5-1: The Frame, as the Copper Sees It
```

Positions only go up through a frame, so:

- A WAIT ends when the beam reaches its position in this frame.
- A WAIT for a position the beam has **already passed** ends at once, and a SKIP for one skips.

Write your WAITs in order, from the top down. A WAIT for line 100 after a WAIT for line 600 ends at once.

### Ending a list

End every list with **STOP**. The copper then does nothing until the next frame, when it starts again from COP1LC. A WAIT for line 1023, `CWAIT 1023,0`, does the same.

If a list is still running when the next frame starts, it is abandoned: the copper starts again from the top whatever it was doing. A list may even loop for ever on purpose, as Example 5-4 does.

### The pixel-only WAIT

A WAIT with the **P** bit set, `CWAITP pixel`, ignores the line:

- if the beam has not yet reached the pixel on this line, the copper waits for it on this line;
- if it has passed it, the copper waits for it on the next line.

So a pixel-only WAIT always waits for the next time the beam comes to that pixel. A block that starts with `CWAITP 0` runs once at the start of each line's horizontal blank, whatever line it is on, which is what an effect on every line needs:

```asm
        CWAIT   149,0                   ; the blank before beam line 149
        CMOVEA  BGCOLOR,0x000080        ; line 149's background
        CWAITP  0                       ; the blank before line 150
        CMOVEA  BGCOLOR,0x000090        ; line 150's
        CWAITP  0                       ; ... and so on
```

The same block can be used on any line, so a loop can repeat it ("Loops and Branches"). Start a run of pixel-only WAITs with an ordinary WAIT, so that the run begins on the line you mean. And keep the work between them short: a block that runs past the next time its pixel comes round makes its WAIT wait for the line after, and the effect slips a line.

### Waiting for the DMA engine

A WAIT with the **B** bit set, `CWAITB line,pixel`, waits until the beam has reached the position **and** the DMA engine has nothing left to do: no job running or waiting to start on any of its four channels. A list can start a job, wait for it to finish, and start the next ("Starting DMA Jobs").

---

## The Copper Registers

The copper's registers are in the custom block at offsets `0x100`–`0x11F`. The Z80 reaches them through ports in page `0x11`: register at offset `0x1nn` is port `0xnn11`, so after `LD BC,COPCON_P` the others are `LD B,low register` away. The copper itself writes them with MOVEF.

### Location registers

**COP1LC** and **COP2LC** each hold the address of a copper list: a 22-bit physical SRAM address, 3 bytes, low byte first. Bit 0 is ignored, since instructions are at even addresses.

- **COP1LC** is list 1, the **main list**. The copper starts it again from the top at the start of every frame.
- **COP2LC** is list 2. The copper goes there only when told to, by the COPJMP2 strobe.

From the Z80, write the three bytes with three `OUT`s. In the program map a list's Z80 address is its physical address, with bits 21–16 zero:

```asm
        ld      hl,my_list
        ld      bc,COP1LC0_P
        out     (c),l                   ; bits 7-0
        inc     b
        out     (c),h                   ; bits 15-8
        inc     b
        xor     a
        out     (c),a                   ; bits 21-16
```

A write to COP1LC does not move the copper: the new address is used at the start of the next frame (or at the next COPJMP1 strobe). The three bytes are written one by one, so write them away from the start of a frame; "Double-Buffered Lists" explains why.

### Jump strobes

**COPJMP1** and **COPJMP2** are **strobes**: writing them makes something happen, and the value written does not matter.

| Strobe | What it does |
|--------|--------------|
| COPJMP1 | The copper starts again at COP1LC, now |
| COPJMP2 | The copper goes on at COP2LC, now |

Either the Z80 or the copper can write them. A strobe from the Z80 also wakes a copper that is waiting or stopped.

```asm
        ld      bc,COPJMP1_P            ; Z80: list 1 again, at once
        out     (c),a

        CMOVEF  COPJMP2,0               ; copper: carry on at list 2
```

### The control register: COPCON

| Bits | Field | Meaning |
|------|-------|---------|
| 0 | EN | 1: the copper is on (DMACON.COPEN and DMACON.DMAEN must also be set) |
| 1 | IRQEN | 1: a write to COPINT raises the copper interrupt |
| 2 | RESUME | 1: a list 2 cut off by the frame restart carries on in the next frame ("Background lists") |
| 3 | STKKEEP | 1: the frame restart keeps the copper's return stack |
| 5–4 | PRI | Memory priority: 0 normal, 1 high; 2 and 3 act as 1 ("Copper Timing") |

### Status: COPSTAT and COPPC

**COPSTAT** says what the copper is doing, and holds two sticky flags:

| Bit | Flag | Meaning |
|-----|------|---------|
| 0 | WAITING | The copper is in a WAIT |
| 1 | STOPPED | The copper is stopped: after a STOP, a reserved instruction or a stack error, while it is off, and after reset |
| 2 | ERR | Sticky: a reserved instruction, or a CALL or RET the stack could not take. Write 1 to clear |
| 3 | IRQ | Sticky: a write to COPINT. Write 1 to clear |

**COPPC** (3 bytes) reads the address of the instruction the copper is running; when stopped, the STOP or reserved instruction that stopped it. Reading its low byte, `COPPC0`, captures all three. Together with COPSTAT it tells you, when a list misbehaves, whether it reached its STOP or which WAIT it is stuck on.

### The interrupt strobe: COPINT

A write to **COPINT** sets COPSTAT.IRQ. With COPCON.IRQEN set, COPSTAT.IRQ raises the **COPPER** interrupt, source 2. A list writes it with `CMOVEF COPINT,0` (Example 5-6).

---

## Putting Together a Copper List

A copper list is a run of words in SRAM. It can sit in your program next to the code that uses it. Put `ALIGN 2` in front of it, since instructions are at even addresses.

A typical list has three parts:

1. **The set-up**, run in the vertical blank: pointers, and the colours and settings the top of the picture needs.
2. **The effects**, each a WAIT for a position and the MOVEs to make there, from the top of the screen down.
3. **A STOP.**

### Example 5-1: Colour bars

The background colour changes every 16 lines, 36 bars, from blue at the top to red at the bottom. Each new colour is written at the start of the bar's first line, in its horizontal blank, because BGCOLOR is read at the start of each line's picture. The assembler's `DUP` writes the 35 WAITs and their MOVEs.

```asm
BAR     equ     16                      ; lines a bar

        ALIGN   2                       ; copper instructions are words
bars:   CMOVEA  BGCOLOR,0x0000FF        ; bar 0: blue
b = 1
        DUP     35                      ; bars 1-35
        CWAIT   49+b*BAR,0              ; the blank before the bar
        CMOVEA  BGCOLOR,((b*7)<<16)|(255-b*7)   ; red rises, blue falls
b = b + 1
        EDUP
        CSTOP
```

The first instruction runs at beam line 0, at the start of the frame, and sets bar 0's colour; bar 0 starts at beam line 49, the picture's first line. The first WAIT is for beam line 65, pixel 0. Each bar costs 5 words (a WAIT and three MOVEs), so the list is 3 + 35 × 5 + 1 = 179 words, 358 bytes, and it takes the Z80 no time at all.

---

## Starting and Stopping the Copper

### Step by step

1. **Write the list** in SRAM, at an even address, ending with STOP.
2. **Write its address to COP1LC.**
3. **Write COPCON**: EN, and IRQEN and PRI if you need them.
4. **Turn on copper DMA**: set COPEN, and DMAEN if it is not on already, in DMACON.

The display must be on (VIDCON.EN), since the frame runs only while it is; the boot ROM leaves it on. The copper starts at the start of the next frame, and from then on runs its list from COP1LC at the start of every frame with no further help.

Three switches must all be on for the copper to run: COPCON.EN, DMACON.COPEN and DMACON.DMAEN. Turning any of them off stops it.

### Example 5-2: Starting the copper

This program shows the colour bars of Example 5-1 behind the console. It turns on the TRANSP bit of the console's layer, so that the paper (pixel value 0) is transparent and the background shows through. A key ends it, and it puts everything back.

```asm
; Example 5-2: starting the copper, with the colour bars of Example 5-1.
; The console's paper is made transparent, so the bars show behind the
; text. A key ends it, with everything put back.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"
        include "copper.inc"

BAR     equ     16                      ; lines a bar

start:  ld      bc,L0_CTRL0_P           ; the console's paper transparent
        in      a,(c)
        or      L_CTRL0_TRANSP_M
        out     (c),a

        ld      bc,COPCON_P             ; the copper off while it is set up
        xor     a
        out     (c),a
        ld      hl,bars                 ; 1. the list's address to COP1LC
        ld      bc,COP1LC0_P
        out     (c),l                   ;    the program map: the Z80 address
        inc     b                       ;    is the physical address
        out     (c),h
        inc     b
        out     (c),a                   ;    bits 21-16: 0
        ld      b,low COPCON            ; 2. on, normal priority (C = 0x11 still)
        ld      a,COPCON_EN_M
        out     (c),a
        ld      bc,DMACON_P             ; 3. copper DMA on (DMAEN is on already)
        ld      a,DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_COPEN_M
        out     (c),a                   ; it starts at the next frame

        ld      hl,title
        rst     0x18                    ; PUTS
.main:  rst     0x20                    ; POLLC: a key?
        jr      z,.main

        ld      bc,DMACON_P             ; copper DMA off: it stops at once
        ld      a,DMACON_COPEN_M        ; (SETCLR 0: clear)
        out     (c),a
        ld      bc,COPCON_P
        xor     a
        out     (c),a
        ld      bc,BGCOLOR0_P           ; the last bar's colour stays: black again
        out     (c),a                   ; blue,
        inc     b
        out     (c),a                   ; green,
        inc     b
        out     (c),a                   ; red: the colour changes
        ld      bc,L0_CTRL0_P           ; the console's paper solid
        in      a,(c)
        and     ~L_CTRL0_TRANSP_M
        out     (c),a
        ret

title:  db      13, 10, "Colour bars from the copper. A key ends it.", 13, 10, 0

        ALIGN   2                       ; copper instructions are words
bars:   CMOVEA  BGCOLOR,0x0000FF        ; bar 0: blue
b = 1
        DUP     35                      ; bars 1-35
        CWAIT   49+b*BAR,0              ; the blank before the bar
        CMOVEA  BGCOLOR,((b*7)<<16)|(255-b*7)   ; red rises, blue falls
b = b + 1
        EDUP
        CSTOP
```

DMACON is a set/clear register: written with bit 7 (SETCLR) set, it sets the bits written as 1; with bit 7 clear, it clears them. Bits written as 0 are left alone, so the layers' DMA (BPLEN) stays on throughout.

### What happens in each frame

```
 line 0, pixel 0       the frame and the vertical blank start:
                       - VIDSTAT.VBLANK is set
                       - the copper starts again at COP1LC, whatever it was doing
 lines 0-48            the copper runs the set-up part of the list
                       (49 lines, 1.57 ms: plenty of time)
 line 49, pixel 0      the display starts fetching the picture's first line,
                       with the pointers the copper has just written
 lines 49-624          the copper waits for each position in its list and makes
                       its writes there; then it reaches STOP and waits
 line 0                the next frame: the list starts again

          Figure 5-2: The Copper's Frame
```

### Starting at once: COPJMP1

The copper waits for the next frame before it first runs its list. To start it at once, write COPJMP1 after step 4. The list then runs from the top partway through a frame: its WAITs for positions already passed end at once, so that one frame may look wrong. From the next frame on, everything is as it should be. Usually it is simpler to let the copper start by itself.

### Stopping the copper

Clear COPEN in DMACON, or clear COPCON.EN. The copper stops at once. The registers it wrote keep their last values, so the screen goes on showing whatever the copper last set: in Example 5-2, the bottom bar's colour, which is why the program writes BGCOLOR black again. Setting COPEN again starts the copper at the next frame.

A program that ends, or is stopped by the debugger, is also tidied up by the boot ROM: when the monitor takes the screen back, it turns the copper off.

---

## Loops and Branches

### SKIP

SKIP compares the beam position as WAIT does, but does not wait. If the beam **has reached** the position in this frame, the copper skips the next instruction; if not, it runs it. A pixel-only SKIP, `CSKIPP pixel`, compares only the pixel position on the current line.

### JUMP

JUMP makes the copper continue at another address, at once: a 22-bit physical address, anywhere in the SRAM.

### A loop that ends at a line

Together, SKIP and JUMP make a loop that repeats until the beam reaches a line:

```
 loop:  CWAITP  pixel           ; wait for the pixel, on the next line
        ...                     ; the work for this line
        CSKIP   last,pixel      ; reached the last line? then skip the JUMP
        CJUMP   loop            ; otherwise round again
        ...                     ; the rest of the list
```

The pixel-only WAIT makes the loop run once a line. Each pass costs the loop's words plus four, the SKIP's and the JUMP's.

### Example 5-3: Scan lines with a loop

When the same thing happens on every line, a loop makes the list short. Here beam lines 149–448 alternate between two blues, line by line, behind the console; the rest of the background is black. The start-up and the ending are Example 5-2's; the whole program is `examples/copper/scan.asm`.

```asm
        ALIGN   2
scan:   CMOVEA  BGCOLOR,0x000000        ; black from the top
        CWAIT   149,0                   ; the blank before beam line 149
.loop:  CMOVE   BGCOLOR0,0xC0           ; even lines: blue 0xC0, into the buffer
        CMOVE   BGCOLOR2,0x00           ; red 0 commits it (green: still 0 in the buffer)
        CWAITP  0                       ; the next line's blank
        CMOVE   BGCOLOR0,0x60           ; odd lines: blue 0x60
        CMOVE   BGCOLOR2,0x00
        CWAITP  0
        CSKIP   449,0                   ; reached line 449? leave the loop
        CJUMP   .loop
        CMOVEA  BGCOLOR,0x000000        ; black again from line 449
        CSTOP
```

Follow it once. The first two MOVEs land at the start of line 149, in its horizontal blank, and set line 149's colour. Only blue changes, so the list writes blue and red, and the green waiting in the copper's buffer, 0 since the first `CMOVEA`, goes in with them. The first pixel-only WAIT ends at the start of line 150, and the next MOVEs set line 150. The second WAIT ends at the start of line 151. The SKIP asks: has the beam reached line 449? Not yet, so the JUMP runs and the loop goes round. On the 150th pass the second WAIT ends at the start of line 449, the SKIP skips the JUMP, and the last MOVEs make line 449 black. Eight instructions in the loop do the work of 600 MOVEs and 300 WAITs.

---

## Changing a Colour in the Middle of a Line

Palette writes take effect from the next pixel, so the copper can change a colour partway across a line. With the colour assembly buffer, the change is exact to the pixel: the blue and green go in before the WAIT, and the red, the only write after it, has already been read when the WAIT ends.

### Example 5-4: Two colours on one line

The console's ink, PALETTE0 entry 17, is light grey left of beam pixel 344 and yellow from there, on every line of the screen. Beam pixel 344 is the console's 21st column (the window starts at 184, and characters are 8 pixels wide), so the change falls exactly between two characters. The start-up and the ending are as in Example 5-2, without TRANSP; at the end the program writes entry 17 light grey again. The whole program is `examples/copper/midline.asm`.

```asm
INK     equ     17                      ; the console's ink: pair 0 is block 1, ink entry 1
SPLIT   equ     344                     ; the console's window starts at beam pixel 184: column 20

        ALIGN   2
mid:    CMOVE   PALIDX1,0               ; PALETTE0; it stays so
.line:  CMOVE   PALIDX0,INK             ; in the blank: grey for the left of the line
        CMOVE   PALDAT,0xD7             ; blue,
        CMOVE   PALDAT,0xD7             ; green,
        CMOVE   PALDAT,0xD7             ; red: changes the entry, and steps PALIDX
        CMOVE   PALIDX0,INK             ; back to the ink (and its byte counter to blue)
        CMOVE   PALDAT,0x00             ; yellow's blue and green: held in
        CMOVE   PALDAT,0xFF             ; the copper's colour assembly buffer
        CWAITP  SPLIT                   ; the split, on this line
        CMOVE   PALDAT,0xFF             ; red: yellow, from this pixel
        CWAITP  0                       ; the next line's blank
        CJUMP   .line                   ; every line, until the frame restart
```

The colour goes back to grey in each horizontal blank, where nothing is shown, so the timing there does not matter. The list has no STOP: it loops until the next frame starts and the copper starts it again from the top. On the board the change lands on the character boundary on every line, with no stray pixels.

---

## The Copper's Registers and Arithmetic

The copper also has a few registers of its own, and simple arithmetic on them, so that a short loop can do the work of a long list, and a list can count, compare, keep values from frame to frame and call subroutines.

| Register | Size | Offset | Used for |
|----------|------|--------|----------|
| X | 8 bits | COPX, `0x10E` | Data, or a register's offset to write through |
| Y | 8 bits | COPY, `0x10F` | Data, or a counter |
| Flags | Z, N, C | COPFLAGS, `0x110` | Set by arithmetic, tested by SKIPC |
| R0–R7 | 8 bits each | COPR0–COPR7, `0x118`–`0x11F` | Storage: saving X, Y and the flags, values kept between frames, values passed to and from the Z80 |
| The stack | 8 return addresses | COPSP, `0x111`, reads how many | CALL and RET |

The Z80 can read and write all of them except the stack's contents, through their ports (`COPX_P`, `COPR0_P` …). **Nothing resets them at the start of a frame**: X, Y, the flags and R0–R7 keep their values from frame to frame. The stack is emptied at each frame restart, unless COPCON.STKKEEP is set.

In a list, and in `copper.inc`, the registers are written `CX`, `CY`, `CF` and `CR0`–`CR7` when they are operands.

### Writing through X and Y: MOVR

An ordinary MOVE has both the register and the data in the instruction. A **MOVR** takes either, or both, from the copper's registers:

- **The data from X or Y**: the value written is whatever is in X or Y at the time.
- **The register from X**: X holds a register's offset, `0x00`–`0xFF`, and the MOVE writes that register. Change X, and the same instruction writes somewhere else.

| Macro | Writes | To |
|-------|--------|----|
| `CMOVR reg,CX` / `CMOVR reg,CY` | X or Y | reg (offset `0x000`–`0x0FF`) |
| `CMOVX n` | The number n | The register at X |
| `CMOVXP n` | The number n | The register at X, then X = X + 1 |
| `CMOVXR CY` / `CMOVXR CX` | Y or X | The register at X |
| `CMOVXRP CY` / `CMOVXRP CX` | Y or X | The register at X, then X = X + 1 |

The forms ending in `P` add 1 to X after the write, as the Z80's `(HL)` with `INC HL`, so a run of them walks through the bytes of a register, low to high, and on to the next. Each MOVR is one word, and none of them change the flags. A MOVR follows every MOVE rule: each byte at once, colours whole on their red byte.

### Arithmetic and comparing: the ALU instructions

Each ALU instruction does one operation on X or Y, with a **source**: a number in the instruction, or another copper register. The register being changed is written **first**, as in Z80 assembly: `CADDI CX,4` is X = X + 4, like `ADD A,4`.

Every operation has a form for a number, with `I` (immediate) on the end of its name, two words, and a form for a register (`CX`, `CY` or `CR0`–`CR7`), one word:

| Macro | Means | Flags |
|-------|-------|-------|
| `CLDI d,n` / `CLD d,src` | Load: d = source | Unchanged |
| `CST CRn,d` | Store: Rn = d | Unchanged |
| `CADDI d,n` / `CADD d,src` | d = d + source | Z, N, C (carry out) |
| `CSUBI d,n` / `CSUB d,src` | d = d − source | Z, N, C (borrow) |
| `CANDI d,n` / `CAND d,src` | d = d AND source | Z, N; C cleared |
| `CORI d,n` / `COR d,src` | d = d OR source | Z, N; C cleared |
| `CCMPI d,n` / `CCMP d,src` | Works out d − source and keeps only the flags | Z, N, C |

Here `d` is `CX` or `CY`. All arithmetic is 8 bits, and wraps: `0xFF` + 1 is 0, with C set. The flags mean what the Z80's do: **Z** the result is 0, **N** bit 7 of the result is 1, **C** a carry out of an add, or a borrow from a subtract or compare (the source was bigger, unsigned).

There is no instruction to load a custom register or a memory byte into X or Y: the copper reads nothing but its list. Values come from numbers in the list, from the Z80 (which can write COPX, COPY and COPR0–7), or from earlier arithmetic.

The flags themselves can be loaded and stored, as the register `CF` (Z in bit 0, N in bit 1, C in bit 2), so that a list can save them and put them back: `CST CR7,CF`, later `CLD CF,CR7`. `CF` can be used only with `CLD`, `CLDI` and `CST`.

### Testing the flags: SKIPC

**SKIPC** skips the next instruction if a condition on the flags holds. They are easiest to read after a `CCMPI` or `CCMP`:

| Macro | After `CCMPI CX,n`, skips if | Tests |
|-------|------------------------------|-------|
| `CSKIPEQ` | X = n | Z |
| `CSKIPNE` | X ≠ n | not Z |
| `CSKIPLO` | X < n (unsigned) | C |
| `CSKIPHS` | X ≥ n (unsigned) | not C |
| `CSKIPHI` | X > n (unsigned) | not C and not Z |
| `CSKIPLS` | X ≤ n (unsigned) | C or Z |
| `CSKIPMI` | bit 7 of X − n is 1 | N |
| `CSKIPPL` | bit 7 of X − n is 0 | not N |

After an add, subtract, AND or OR the same conditions test the result: `CSKIPEQ` after `CSUBI CY,1` skips when Y has just reached 0. The instruction skipped is usually a `CJUMP` back to the top of a loop, or out of it. A loop of 8 passes:

```
        CLDI    CY,8            ; Y = 8
.loop:  ...                     ; the work: done 8 times
        CSUBI   CY,1            ; Y = 7, 6, ... 0
        CSKIPEQ                 ; Y = 0? then skip the CJUMP ...
        CJUMP   .loop           ; ... else round again
```

### Subroutines: CALL and RET

`CCALL address` continues at the address and remembers where it came from; `CRET` goes back. The return addresses are kept in a stack inside the copper, 8 deep. A CALL with 8 already in use, or a RET with none, stops the copper and sets COPSTAT.ERR.

### Example 5-5: A split screen that scrolls itself

The console's top 15 rows stay still. From beam line 337, the console's row 15, the copper scrolls the layer sideways, a pixel further every frame, with no help from the Z80. It keeps the scroll from frame to frame in R1 (bits 7–0) and R2 (bits 9–8). The console's map is 128 tiles, 1,024 pixels, across, so a scroll that wraps at 1,024 never jumps.

SCROLLX is a line setting, taken at the start of each line's horizontal blank: to change line 337, the list writes it during line 336. The top of the screen gets SCROLLX 0 back in the vertical blank. The start-up is Example 5-2's, without TRANSP, and with R1 and R2 cleared; at the end the program writes SCROLLX 0. The whole program is `examples/copper/split.asm`.

```asm
SPLIT   equ     337                     ; the console's row 15: 97 + 15 x 16

        ALIGN   2
split:  CMOVE   L0_SCROLLX0,0           ; the top: no scroll (in the vertical blank)
        CMOVE   L0_SCROLLX1,0
        CLD     CX,CR1                  ; this frame's scroll: last frame's + 1
        CLD     CY,CR2
        CADDI   CX,1
        CSKIPHS                         ; no carry: skip
        CADDI   CY,1                    ; carry into bits 9-8
        CANDI   CY,3                    ; wrap at 1,024
        CST     CR1,CX                  ; kept for the next frame
        CST     CR2,CY
        CWAIT   SPLIT-1,0               ; SCROLLX is taken at the start of each line:
        CMOVR   L0_SCROLLX0,CX          ; write it during the line before
        CMOVR   L0_SCROLLX1,CY
        CSTOP
```

The rows above the split are untouched; from row 15 down the text slides left, 50 pixels a second. The same list with a pointer in place of SCROLLX makes a status panel from another picture (see "Pointers and split screens" below), and more WAITs make more bands, for parallax.

### Example 5-6: A raster bar moved by the Z80, and a copper interrupt

The storage registers are a mailbox between the Z80 and the copper. Here the Z80 leaves a line number in R0; every frame the copper counts that many lines down from beam line 113 and calls a subroutine that draws a 16-line bar, yellow brightening to its middle and fading again. At line 600, below the console, the copper writes **COPINT**. Its interrupt handler moves the bar for the next frame, bouncing it between 0 and 255, while the copper is stopped.

The copper cannot write the interrupt controller, but it can interrupt the Z80 through COPINT: that sets COPSTAT.IRQ, and with COPCON.IRQEN, COPSTAT.IRQ raises the COPPER interrupt, source 2, at IM 2 table entry 2 (VECBASE + 4). The handler clears it by writing 1 to COPSTAT.IRQ. A WAIT cannot take its line from a register, so the list counts lines with pixel-only WAITs instead.

```asm
; Example 5-6: a raster bar that the Z80 moves through a storage register,
; with a copper interrupt. A key ends it.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"
        include "copper.inc"

TOP     equ     113                     ; the bar's line for COPR0 = 0
TABLE   equ     0x9FD0                  ; the IM 2 table: I = 0x9F, VECBASE = 0xD0

start:  di
        ld      hl,TABLE                ; every entry to the spurious handler ...
        ld      b,24
.fill:  ld      (hl),low spurious
        inc     hl
        ld      (hl),high spurious
        inc     hl
        djnz    .fill
        ld      hl,copint               ; ... but the copper's
        ld      (TABLE+2*INT_COPPER),hl
        ld      a,high TABLE
        ld      i,a
        ld      bc,VECBASE_P
        ld      a,low TABLE
        out     (c),a
        im      2

        ld      bc,L0_CTRL0_P           ; the console's paper transparent
        in      a,(c)
        or      L_CTRL0_TRANSP_M
        out     (c),a

        ld      bc,COPCON_P             ; the copper off while it is set up
        xor     a
        out     (c),a
        ld      bc,COPR0_P              ; the bar at the top
        out     (c),a
        ld      bc,COPSTAT_P            ; no old COPINT
        ld      a,COPSTAT_IRQ_M
        out     (c),a
        ld      hl,bar_list
        ld      bc,COP1LC0_P
        out     (c),l
        inc     b
        out     (c),h
        inc     b
        xor     a
        out     (c),a
        ld      b,low COPCON            ; on, and COPINT interrupts
        ld      a,COPCON_EN_M|COPCON_IRQEN_M
        out     (c),a
        ld      bc,INTENA0_P+(INTR_COPPER<<8)
        ld      a,INTENA_SETCLR_M|(1<<INTB_COPPER)
        out     (c),a
        ld      bc,INTCON_P
        ld      a,INTCON_MASTER_M
        out     (c),a
        ld      bc,DMACON_P
        ld      a,DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_COPEN_M
        out     (c),a
        ei

        ld      hl,title
        rst     0x18                    ; PUTS
.main:  rst     0x20                    ; POLLC
        jr      z,.main

        di                              ; put everything back
        ld      bc,DMACON_P
        ld      a,DMACON_COPEN_M
        out     (c),a
        ld      bc,COPCON_P
        xor     a
        out     (c),a
        ld      bc,INTCON_P
        out     (c),a
        ld      bc,INTENA0_P+(INTR_COPPER<<8)
        ld      a,1<<INTB_COPPER
        out     (c),a
        ld      a,0x1F                  ; the ROM's table again
        ld      i,a
        ld      bc,VECBASE_P
        ld      a,0xD0
        out     (c),a
        ld      bc,BGCOLOR0_P           ; black
        xor     a
        out     (c),a
        inc     b
        out     (c),a
        inc     b
        out     (c),a
        ld      bc,L0_CTRL0_P
        in      a,(c)
        and     ~L_CTRL0_TRANSP_M
        out     (c),a
        ret

copint: push    af                      ; COPPER: once a frame, at line 600
        push    bc
        ld      bc,COPSTAT_P
        ld      a,COPSTAT_IRQ_M
        out     (c),a                   ; clear the cause first
        ld      bc,COPR0_P
        in      a,(c)                   ; where the bar was
        ld      b,a
        ld      a,(step)
        add     a,b                     ; moved on
        jr      z,.turn                 ; at 0 ...
        cp      255
        jr      nz,.put                 ; ... or 255: turn round
.turn:  push    af
        ld      a,(step)
        neg
        ld      (step),a
        pop     af
.put:   ld      bc,COPR0_P
        out     (c),a                   ; next frame's line, while the copper is stopped
        pop     bc
        pop     af
        ei
        reti

spurious:
        ei
        reti

step:   db      1                       ; +1 or -1 line a frame
title:  db      13, 10, "A raster bar moved by the CPU through COPR0. A key ends it.", 13, 10, 0

        ALIGN   2
bar_list:
        CMOVEA  BGCOLOR,0x000000        ; black above the bar
        CWAIT   TOP,0                   ; the blank of line TOP
        CLD     CY,CR0                  ; Y = lines down, from the CPU
.down:  CCMPI   CY,0
        CSKIPNE                         ; not there yet: skip the CJUMP
        CJUMP   .here
        CWAITP  0                       ; the next line's blank
        CSUBI   CY,1
        CJUMP   .down
.here:  CCALL   bar                     ; the bar, from this line
        CWAIT   600,0                   ; below the console
        CMOVEF  COPINT,0                ; tell the CPU
        CSTOP

; 16 lines from the line it is called in, in its blank: red and green
; both X, from 0x1F up to 0xFF and down again. Uses X and Y.
bar:    CLDI    CY,16                   ; Y: lines left
        CLDI    CX,0x1F                 ; X: the brightness
.line:  CMOVE   BGCOLOR0,0x00           ; blue 0, held
        CMOVR   BGCOLOR1,CX             ; green, held
        CMOVR   BGCOLOR2,CX             ; red: the colour changes, from this line
        CCMPI   CY,9                    ; the top half (Y > 9): brighter
        CSKIPLS
        CADDI   CX,0x20
        CCMPI   CY,9                    ; the bottom half (Y < 9): darker
        CSKIPHS
        CSUBI   CX,0x20
        CSUBI   CY,1
        CSKIPNE                         ; lines left: skip the CJUMP
        CJUMP   .done
        CWAITP  0                       ; the next line's blank
        CJUMP   .line
.done:  CWAITP  0                       ; the line after the bar: black
        CMOVEA  BGCOLOR,0x000000
        CRET
```

Each pass of `.line` is about 24 words, all in the line's horizontal blank, so the bar's colours are in place before each line's picture. The bar goes down a line a frame, turns at the bottom, comes back up, and turns again at the top.

**When the Z80 writes the copper's registers.** A Z80 write lands between two copper instructions, so the copper sees the old value or the new one, never half of each, since each register is one byte. A value made of several registers can still be torn, if the Z80 writes between the copper's reads of them. So write such values while the copper is stopped or waiting, as this handler does: the copper has just reached its STOP.

**Several COPINTs a frame.** A list may write COPINT as often as it likes, but a second write before the handler has cleared the first counts as one. Leave the Z80 time to answer between them: it can take up to 2 µs to start a handler.

---

## Pointers and Split Screens

### Resetting a bitmap's pointer every frame

A bitmap layer's pointer, BPL0PT, walks through memory as the layer fetches, and the hardware does not put it back (see "Resetting the Pointer Every Frame" in the Playfield Hardware chapter). The copper can do it at the top of its list, in the vertical blank, and the program needs no interrupt handler for it:

```asm
        ALIGN   2
list:   CMOVEA  L0_BPL0PT,SCREEN        ; the picture's start, in the vertical blank
        ; ... the rest of the list
        CSTOP
```

To scroll, or to swap screen buffers, the Z80 changes the address **in the list**: the data bytes of the three MOVEs, the low bytes of the list's first three words, `list`, `list+2` and `list+4`. Change them once the picture has started (beam line 49 or later), so that the copper never reads a pointer half changed. For bigger changes use two lists ("Double-Buffered Lists").

### Pointers and split screens

A pointer is live, and its bytes act when they are written, so new pointers partway down the screen must go where the layer is not fetching: after the layer's last fetch on line L and before line L + 1 starts. A pointer written there is used as written for line L + 1. The layer's last fetch on a line comes about 32 source pixels before its window's right edge (64 beam pixels at 2× across), so the gap is near the end of the line, and the three MOVEs must all fit in it. Set COPCON.PRI to 1 for such a burst ("Copper Timing"). With a layer 2× tall, write after the **last** copy of a source line.

The Playfield Hardware chapter's Example 3-13 shows a Spectrum screen this way: the copper writes BPL0PT at the start of each of the 24 character rows, after the layer's last fetch on the line before.

### Sprites

The vertical blank stops every sprite, so a list that shows sprites writes each one's registers in the vertical blank, CTL last: a write to CTL starts the sprite. All the sprite registers are within a MOVE's reach. To reuse a sprite lower down, the list waits until the first use has been shown, writes its window and pointer again, then CTL. The Sprite Hardware chapter has the rules and an example.

---

## Using the Two Lists

Most programs need only list 1. List 2 is useful when part of the list should change while the rest stays the same.

### Jumping to list 2

A write to **COPJMP2** makes the copper go on at the address in COP2LC. Unlike JUMP, whose address is fixed in the list, COPJMP2 goes to wherever COP2LC points **now**, so the Z80 chooses where the copper goes by writing one register:

- **List 1**, in COP1LC, does the set-up every frame, then ends with `CMOVEF COPJMP2,0`.
- **List 2**, in COP2LC, is the effect for this part of the program. To change the effect, the Z80 writes another list's address to COP2LC.

```asm
        ALIGN   2
list1:  CMOVEA  L0_BPL0PT,SCREEN        ; the set-up, every frame
        CMOVEF  COPJMP2,0               ; then whichever list COP2LC holds
plain:  CSTOP                           ; a list 2 with no effect
```

The copper reads COP2LC at the strobe, early in the vertical blank. COP2LC's three bytes are written one by one, so the Z80 changes it during the picture, well away from the strobe. The copper can write COP1LC and COP2LC too, with three MOVEFs (`CMOVEA COP2LC,address` makes them), so a list can choose the next list itself.

### Background lists: COPCON.RESUME

Some copper work is not tied to the beam at all: a long queue of DMA jobs, each started when the one before it is done, which may take several frames. Normally list 2 would be cut off at every frame restart. With **COPCON.RESUME** set it carries on:

- When the copper enters list 2 through COPJMP2, it remembers that it is in list 2.
- If it is still there when the next frame starts, the hardware writes its place in the list into COP2LC, and then starts list 1 as always.
- List 1 does its set-up and ends with `CMOVEF COPJMP2,0`; list 2 carries on where it was cut off.

The place saved is the instruction not yet finished: a WAIT still waiting runs again, whole. A STOP, a COPJMP1 strobe or turning the copper off ends "in list 2"; JUMP, CALL and RET do not. A background list follows a few rules:

- **No beam WAITs.** After a resume, a WAIT for a beam position would wait for it in the new frame. Use `CWAITB 0,0`, which waits for the DMA engine only (line 0, pixel 0 has always passed).
- **Only the place is saved.** X, Y, the flags and R0–R7 are left as they are, so a list 1 that uses them saves list 2's in spare storage registers first (`CST CR5,CX`, `CST CR6,CY`, `CST CR7,CF`) and puts them back before its COPJMP2.
- **Mind a register cut in two.** A cut-off between the bytes of a wide register leaves the bytes already written; list 2 carries on with the next. Never put a strobe, such as a DMA start, between the bytes of a register.
- **No colours.** The colour assembly buffer is not saved, so list 1's colours could mix with a cut-off one of list 2's.
- **End by pointing COP2LC at an idle list** (a STOP), with `CMOVEA COP2LC,idle`, or the next COPJMP2 runs the list again from its last place.
- **The Z80 hands out work only when the copper is idle.** While a background list runs, the hardware may overwrite COP2LC at the next frame restart, so the Z80 writes COP2LC only while the copper is in the idle list. COPPC tells it where the copper is, or the list can write COPINT when it is done.

---

## Double-Buffered Lists

When the Z80 builds a new list every frame, it must never change a list while the copper runs it: the copper would run a mix of old and new instructions, and may already have read the next words before the Z80 changed them. The answer is the same as for screen buffers, **two lists**:

1. Build the next frame's list in the buffer the copper is not using.
2. Write its address to COP1LC. The copper is not disturbed: it finishes the current frame with the old list.
3. At the next frame restart the copper starts the new list. Wait for that (VIDSTAT.VBLANK is set at the same moment), and the old buffer is free to build in.

COP1LC's three bytes are written one by one, and a frame restart between them would start a list at a mixed address. So write COP1LC early in the frame, for example in the vertical blank handler, which runs just after the restart. Or put the two buffers where their addresses differ in one byte only, and write just that byte: the boot ROM's sprite demo keeps its two lists 8 KB apart for this, and writes only COP1LC's middle byte.

---

## Starting DMA Jobs

The DMA engine's channel registers are beyond a MOVE's reach, so the copper writes them with MOVEF, two words a byte. Four MOVEFs start a list of jobs on a channel: the three bytes of CHDESC, the first descriptor's physical address, then START in CHCTRL. The Blitter and DMA Hardware chapter describes the jobs; channel 3 is the one it suggests for the copper.

```asm
JOB1    equ     0x00C000                ; descriptor lists in SRAM (multiples of 4)
JOB2    equ     0x00C100

        ALIGN   2
dma:    CWAIT   49,0                    ; the start of the picture
        CMOVEA  DMX3_CHDESC,JOB1        ; channel 3: the first list (three MOVEFs) ...
        CMOVEF  DMX3_CHCTRL,DMX_CHCTRL_START_M  ; ... started
        CWAITB  349,0                   ; line 349, and the engine idle
        CMOVEA  DMX3_CHDESC,JOB2        ; the second list
        CMOVEF  DMX3_CHCTRL,DMX_CHCTRL_START_M
        CSTOP
```

`CWAITB` waits for the engine to have **nothing** to do, on any channel, including jobs the Z80 started. If a job runs late, the copper's later writes come late too, and if the engine is still busy when the next frame starts, the list starts again regardless. So do not put a `CWAITB` before writes that must happen at a fixed place on the screen.

---

## Copper Timing

### How exact a WAIT is

The copper compares its WAIT position with the beam as the memory side sees it, a few clocks behind the pixel clock. A WAIT ends within about one pixel (37 ns) of its position.

### After a WAIT: the words already read

While it waits, the copper reads the next **two words** of its list. When the WAIT ends:

- the first MOVE after it is made within 10–20 ns, inside a pixel: put the write that must be exact there;
- with one-word MOVEs, a second MOVE follows 20 ns later, within the same pixel or the next;
- each write after those needs its own read from SRAM, one every 100 ns (2.7 pixels) at PRI 1;
- to change a colour exactly, write its blue and green before the WAIT and its red after it (Example 5-4). Other registers have no buffer: a 2-byte value written by the two MOVEs after a WAIT changes within a pixel, a wider one over a few.

A SKIP or SKIPC reads the first word of the instruction after it before it decides, so that it knows how long that instruction is. A skip is then a jump past it. JUMP, CALL and RET throw away anything read past them.

### When the writes take effect

The copper's writes take effect exactly as the Z80's do:

| Registers | Take effect |
|-----------|-------------|
| Palette entries (PALDAT), VIDCON.DIRECT, VIDCON.BLANKALL | At once, from the next pixel |
| BPL0PT, BPLSTRIDE | Live: a pointer written between a layer's last fetch on line L and the start of line L + 1 is used as written for line L + 1 |
| CTRL, the window, SCROLLX | At the start of each line's horizontal blank (beam pixel 0): to change line L, write during line L − 1 |
| PRIO, BGCOLOR | At the start of each line's picture (beam pixel 144): write in line L's horizontal blank, or earlier |
| Sprite registers | A CTL write starts the sprite, from the next line inside its window. The others act on a running sprite from the next line |

A good rule: make changes for line L in its horizontal blank, after `CWAIT L,0`, except the line settings (CTRL, the window, SCROLLX), which go in the line before, and pointers, which have their own gap at the end of the line before.

### How fast the copper runs

The copper reads its list one 16-bit word per memory cycle, through its own channel in the memory scheduler (Chapter 1, "Sharing the Memory"). Every word of every instruction it passes is read once, so its speed is counted in words:

| Instruction | Words |
|-------------|-------|
| MOVE, MOVR, ALU with a register, SKIPC, STOP, RET | 1 |
| WAIT, SKIP, JUMP, CALL, MOVEF, ALU with a number | 2 |
| An instruction skipped by SKIP or SKIPC | Its words, as if run |

At high priority (COPCON.PRI 1) the copper is sure of one word every 100 ns slot, on any screen within the display's budget, whatever the Z80, the sprites and the DMA engine are doing. One-word MOVEs then mean one MOVE every slot:

| At PRI 1 | Words (MOVEs) |
|----------|---------------|
| One slot (100 ns, 2.7 pixels) | 1 |
| The horizontal blank (144 pixels, 5.33 µs) | 53 |
| One line (32 µs) | 320 |
| The vertical blank (49 lines, 1.57 ms) | 15,680 |
| One frame (20 ms) | 200,000 |

While it waits, the copper uses no memory cycles, so a list that is mostly WAITs costs the rest of the machine almost nothing. A loop costs a read for every word in it, on every pass: use loops to make lists **short**, and unrolled MOVEs where the writes must be **fast**.

### Priority: COPCON.PRI

| PRI | The copper gets |
|-----|-----------------|
| 0, normal | Its own memory cycle in each slot and the cycles nobody else wants, after the layers, the sprites and the sprite sequencer (the default) |
| 1, high | The same cycle as its own, and first place among the spare cycles: ahead of the DMA engine, the sprite sequencer and layer and sprite fetches that are not urgent |
| 2, 3 | Act as 1 |

A layer or sprite fetch about to be late still comes first at every level, so raising the copper's priority never spoils the picture, and the Z80 never waits for the copper. Priority matters only while the copper has a word to read.

- **PRI 0** for most lists, which spend most of their time waiting. In the vertical blank, and on a quiet screen, it is often as fast as PRI 1.
- **PRI 1** when a burst of writes must fit in a short gap: new pointers between a layer's last fetch and the end of the line, many colours in one horizontal blank, or a screen close to its fetch budget.

The copper can write COPCON itself, so a list can raise its priority before a burst and lower it after. Write EN as 1 every time (and IRQEN if you use it): a write with EN clear turns the copper off.

```asm
        CMOVEF  COPCON,COPCON_EN_M|(1<<COPCON_PRI_B)    ; high priority ...
        CWAIT   528,808
        CMOVEA  L0_BPL0PT,PANEL                         ; ... for the burst
        CMOVEF  COPCON,COPCON_EN_M                      ; normal again
```

### The copper and the Z80

The copper and the Z80 share the bus to the registers. If both want it in the same clock, the copper goes first, and the Z80's access moves one clock later, which its I/O cycle has room for. So a copper write always lands on its pixel, and the Z80 never notices.

Both can write the same register, and the last write to each byte wins. A Z80 write between the copper's bytes of one register mixes with them (colours apart: each has its own buffer). It is easy to lose track of who set what, so let one of them own each register: if the copper resets a pointer, the Z80 changes the list, not the pointer.

---

## What the Copper Can Reach

| Area | The copper can |
|------|----------------|
| SRAM | Read its list, by physical address, without the MMU. Nothing else: it cannot write memory or read tables from it |
| Custom block `0x000`–`0x0EF` | Write with MOVE, MOVR or MOVEF: the video globals, the sprites, the three layers |
| Custom block `0x0F0`–`0x0FF` | Nothing useful: read-only video registers, which ignore writes |
| Custom block `0x100`–`0x3FF` | Write with MOVEF only: its own registers, the sprite globals, the attribute layer, the DMA engine |
| The system page, port `0xFE`, the register page, the boot ROM | Nothing |

Some consequences:

- **The copper only writes, apart from its own registers.** It cannot read a register or a memory byte, so it cannot copy data. It can test its own registers, which the Z80 can set, and the beam position.
- **A list cannot be in the boot ROM**, nor reached through the MMU: it is in SRAM, at a physical address. In the program map a program's Z80 addresses are physical addresses; elsewhere, work out the physical address from the MMU page (Chapter 1, "Physical addresses").
- **The copper cannot reach the interrupt controller, the timers, the MMU or the system registers.** It interrupts the Z80 through COPINT, and a runaway list can never page memory, reset the machine or change the interrupt set-up.
- **It cannot write port `0xFE`**, so to change the border it writes BGCOLOR, which port `0xFE` also sets. A BGCOLOR write shows from the start of a line's picture, not partway across as a port `0xFE` write does.
- **It can turn DMA on and off**, through DMACON. Take care with COPEN and DMAEN: clearing either stops the copper.
- **It can control itself**: COP1LC, COP2LC, COPCON and the strobes. A list that writes COPJMP1 unconditionally starts again at once, for ever.

---

## Summary of Copper Instructions

A word is stored low byte first; its high byte is the code. Bits shown as 0 must be 0.

| Instruction | Macro | Word 1 | Word 2 |
|-------------|-------|--------|--------|
| MOVE | `CMOVE reg,value` | reg (`0x00`–`0xEF`) << 8 \| value | – |
| MOVEF | `CMOVEF reg,value` | `0xFC00` \| reg >> 8 | (reg & `0xFF`) << 8 \| value |
| WAIT | `CWAIT line,pixel` | `0xF000` \| (line >> 8) << 2 \| pixel >> 8 | (line & `0xFF`) << 8 \| pixel & `0xFF` |
| WAIT, pixel only | `CWAITP pixel` | As WAIT, line 0, with P (`0x0080`) | As WAIT |
| WAIT and the DMA engine | `CWAITB line,pixel` | As WAIT, with B (`0x0040`) | As WAIT |
| SKIP | `CSKIP line,pixel`, `CSKIPP pixel` | As WAIT and WAIT pixel only, code `0xF1` | As WAIT |
| JUMP | `CJUMP address` | `0xF200` \| address >> 16 | address & `0xFFFE` |
| STOP | `CSTOP` | `0xF300` | – |
| MOVR | `CMOVX n`, `CMOVXP n` | `0xF400` \| n, `0xF500` \| n | – |
| | `CMOVR reg,CX`, `CMOVR reg,CY` | `0xF600` \| reg, `0xF700` \| reg | – |
| | `CMOVXR src`, `CMOVXRP src` | `0xF800` \| I << 1 \| R (R 1: X, 0: Y; I: X + 1) | – |
| ALU | `CLD`, `CST`, `CADD`, `CSUB`, `CAND`, `COR`, `CCMP` and their `I` forms | `0xF900` \| fn << 5 \| d << 4 \| source | The number, for the `I` forms (source 10) |
| SKIPC | `CSKIPEQ` … `CSKIPLS` | `0xFA00` \| cc | – |
| CALL | `CCALL address` | `0xFB00` \| address >> 16 | address & `0xFFFE` |
| RET | `CRET` | `0xFB80` | – |
| (reserved) | | `0xFD00`–`0xFFFF`, and bits that must be 0 set | Act as STOP and set COPSTAT.ERR |

ALU fields: fn 0 LD, 1 ST, 2 ADD, 3 SUB, 4 AND, 5 OR, 6 CMP, 7 the flags; d 0 X, 1 Y; source 0–7 R0–R7, 8 X, 9 Y, 10 the number in word 2. SKIPC cc: 0 EQ, 1 NE, 2 LO, 3 HS, 4 MI, 5 PL, 6 HI, 7 LS.

Lines and pixels are 10 bits (0–1023), in beam coordinates: line 0 is the start of the vertical blank and the picture is lines 49–624; pixel 0 is the start of a line's horizontal blank and the picture is pixels 144–863. The list starts at (0, 0), and positions only go up through a frame.

---

## Summary of Copper Registers

Custom offsets; the Z80's port is (offset bits 7–0) × 256 + `0x11`. Access: R read only, W write only (a strobe), RW read and write, W1C sticky flags cleared by writing 1.

| Name | Offset | Port | Access | Function |
|------|--------|------|--------|----------|
| COPCON | `0x100` | `0x0011` | RW | EN (0), IRQEN (1), RESUME (2), STKKEEP (3), PRI (5–4) |
| COP1LC | `0x101`–`0x103` | `0x0111`–`0x0311` | RW | List 1's address (21–0, bit 0 ignored): restarted at the start of every frame |
| COP2LC | `0x104`–`0x106` | `0x0411`–`0x0611` | RW | List 2's address. Written by the hardware only with COPCON.RESUME |
| COPJMP1 | `0x107` | `0x0711` | W | Strobe: start again at COP1LC now |
| COPJMP2 | `0x108` | `0x0811` | W | Strobe: carry on at COP2LC now |
| COPINT | `0x109` | `0x0911` | W | Strobe: sets COPSTAT.IRQ |
| COPPC | `0x10A`–`0x10C` | `0x0A11`–`0x0C11` | R | The instruction being run; reading `0x10A` captures all three bytes |
| COPSTAT | `0x10D` | `0x0D11` | R, W1C | WAITING (0), STOPPED (1); ERR (2) and IRQ (3) sticky |
| COPX, COPY | `0x10E`, `0x10F` | `0x0E11`, `0x0F11` | RW | X and Y |
| COPFLAGS | `0x110` | `0x1011` | RW | Z (0), N (1), C (2) |
| COPSP | `0x111` | `0x1111` | RW | Read: return addresses on the stack (0–8). Write: empties it |
| COPR0–COPR7 | `0x118`–`0x11F` | `0x1811`–`0x1F11` | RW | Storage registers |
| DMACON | `0x00C` | `0x0C10` | Set/clear | COPEN (4) and DMAEN (6) must be set for the copper to run |

The copper interrupt is source 2, COPPER: COPSTAT.IRQ with COPCON.IRQEN, at IM 2 table entry 2 (VECBASE + 4). It must also be enabled in INTENA, with INTCON.MASTER on.

### State after reset, and when a program starts

| Register | After reset | When a program starts |
|----------|-------------|-----------------------|
| COPCON | 0: off, normal priority | 0: the boot ROM's console does not use the copper |
| DMACON.COPEN | 0 | 0; DMAEN and BPLEN are on, for the console |
| COP1LC, COP2LC | 0 | Not set: write them before turning the copper on |
| COPSTAT | `0x02`: stopped | Stopped |
| X, Y, the flags, R0–R7, the stack | 0, empty | Whatever an earlier program left |

### Equates in hw.inc and copper.inc

| Name | Meaning |
|------|---------|
| `COPCON`, `COP1LC` … `COPR7` | The registers' custom offsets, for the copper (`CMOVEF COPINT,0`) |
| `COPCON_P`, `COP1LC0_P` … `COPR7_P` | Their ports, for the Z80 |
| `COPCON_EN_M`, `COPCON_IRQEN_M`, `COPCON_RESUME_M`, `COPCON_STKKEEP_M`; `COPCON_PRI_B`, `COPCON_PRI_M` | COPCON's bits |
| `COPSTAT_WAITING_M` … `COPSTAT_IRQ_M` | COPSTAT's bits |
| `DMACON_COPEN_M`, `DMACON_DMAEN_M`, `DMACON_SETCLR_M` | DMACON's copper bits |
| `INT_COPPER`, `INTR_COPPER`, `INTB_COPPER` | The copper's interrupt source, its INTENA byte and bit |
| `CX`, `CY`, `CF`, `CR0`–`CR7` | Operands of the register instructions (`copper.inc`) |
| `COP_P`, `COP_B`, `COP_FN_LD` … `COP_FN_FLAGS`, `COP_CC_EQ` … `COP_CC_LS` | The instructions' fields (`copper.inc`) |
| `CMOVE` … `CRET` | The instructions, as macros (`copper.inc`) |
