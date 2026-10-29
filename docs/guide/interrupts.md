# Chapter 2: Interrupts and Timers

## Introduction

An **interrupt** lets the hardware call your program when something happens: the beam reaches the bottom of the screen, a timer runs out, a key arrives, a DMA job finishes. The Z80 stops what it is doing, runs a short **handler**, and carries on. **Timers** make things happen at set times, and measure how long things take.

retro-z80 uses the Z80's **IM 2**: each source of interrupts has its own handler, found through a table. One controller collects the requests of every unit, puts them in order and hands the Z80 the right entry.

This chapter covers:

- how an interrupt reaches the Z80, and the four switches on its way;
- the sources and their order;
- setting up IM 2 and writing handlers, with a complete program;
- enabling, disabling and clearing;
- the software interrupt;
- TIME, the microsecond counter, with a program that times code;
- the four general timers, with a timer interrupt;
- the watchdog, with a program that lets it reset the computer;
- advanced topics: nesting, IM 1, the nonmaskable interrupt, interrupt pages, chaining timers;
- timing, and what interrupts cannot do;
- a summary of the registers.

You should know how to reach the registers through ports (Chapter 1, "The Hardware Registers").

---

## Conventions in This Chapter

- Examples are Z80 assembly language for sjasmplus and start with `include "hw.inc"`. Numbers are hexadecimal when they start with `0x`.
- Every register in this chapter is in the **system page**: port = register × 256 + `0x00`. So C stays `0x00`, and moving to another register is `LD B,register` or `INC B`.
- Bit tables list the top bit first, bit 7 down to bit 0.
- The complete examples are in `examples/interrupts/`, loaded at `0x8000`. They run in the boot ROM's program map, use its console calls (`RST 0x18` PUTS, `RST 0x20` POLLC, `RST 0x28` functions), and return to the monitor.

---

## How an Interrupt Reaches the Z80

Take the vertical blank as the example:

1. The beam reaches the start of a new frame. The video unit sets its **flag**, VIDSTAT.VBLANK. If the unit's own **enable**, VIDINTEN.VBLANK, is on, the unit raises its **request**.
2. If the source's bit in **INTENA** is on, and **INTCON.MASTER** is on, the request is **pending**.
3. While anything is pending, the controller holds the Z80's /INT line low.
4. At the end of each instruction, if interrupts are enabled (`EI`), the Z80 answers: it pushes PC and asks for a vector.
5. The controller picks the pending source with the **lowest number**, and gives the vector for it. In IM 2 the Z80 reads the handler's address from its table and jumps there.
6. The handler **clears the cause in the unit**, by writing 1 to VIDSTAT.VBLANK, and the request goes away.

So an interrupt needs four switches on: the **unit's enable**, the source's **INTENA** bit, **INTCON.MASTER**, and the Z80's own (`EI`). Figure 2-1 shows them.

```
     VIDSTAT.VBLANK            VIDINTEN.VBLANK
     (the unit's flag)         (the unit's enable)
             |                         |
             +---------> AND <---------+
                          |
                          |  the request
                          v
     INTENA bit -------> AND <------- INTCON.MASTER
                          |
                          |  pending: the controller holds /INT low
                          v
     EI ---------------> AND
                          |
                          v
            the Z80 answers: pushes PC, reads the vector

             Figure 2-1: The Four Switches of an Interrupt
```

### Requests are levels

A request stays on until its flag is cleared in the unit. Nothing is lost while interrupts are off, or while another handler runs: the request waits, and is taken as soon as it can be. The other side of this is the most important rule for handlers:

**A handler must clear the cause before it does `EI`**, or it is interrupted again at once by the same request.

Turning a source off in INTENA does not clear it either: the flag stays set, and turning the source on again gives the interrupt at once. To avoid an old event, clear the unit's flag before enabling the source.

How long the Z80 takes to answer is in "Timing", near the end of the chapter.

---

## The Sources

Table 2-1 lists every source, in priority order.

**Table 2-1: Interrupt Sources**

| Number | Name | From | Cleared by writing 1 to |
|--------|------|------|-------------------------|
| 0 | VBLANK | The start of each frame (and of vertical blanking) | VIDSTAT.VBLANK |
| 1 | LINE | The beam reaching line LINECMP (not built yet) | VIDSTAT.LINE |
| 2 | COPPER | The copper wrote COPINT | COPSTAT.IRQ |
| 3 | VIDERR | A layer fetched late, a sprite ran dry, the sprite sequencer skipped | VIDSTAT's error bits; SEQSTAT.SKIP |
| 4–7 | DMA0–DMA3 | A DMA channel finished a job with IRQ set, or met an error | DMXINT.CHn |
| 11–14 | TIMER0–TIMER3 | A timer underflowed | TMRn_STAT.UNDER |
| 15 | SERIAL | The USB link: data received, room to send, a timeout (does not reach the controller yet, ticket #58) | SERIRQ, or by reading or filling its FIFO |
| 17 | KEYB | The PS/2 keyboard: bytes waiting, or an error | KBIRQ, or by reading the FIFO |
| 18 | SOFT | The program itself, through SOFTINT | SOFTINT.CLR |
| 23 | NONE | Not a source: the controller had nothing to give (below) | – |

Numbers 8–10, 16, 19 and 20 are not used, or kept for later units (sound at 9, the geometry unit at 19); they never ask.

**The number is the priority.** When several are pending, the lowest number goes first: the video before the DMA engine, the DMA engine before the timers, the link and the keyboard after them (their FIFOs can wait), and SOFT last. `hw.inc` names them `INT_VBLANK` … `INT_SOFT`, and `INT_NONE` (23).

---

## Setting Up IM 2

### The table

In IM 2 the Z80 reads a handler's address from a **table** at **I × 256 + vector**. The controller makes the vector:

    vector = VECBASE + 2 × source number

so the table is 24 entries of 2 bytes, 48 bytes in all, for sources 0–20, two entries never used, and NONE (23) last. I picks its 256-byte page and **VECBASE** (register `0x0A`) its place in the page, at an even address (Table 2-2).

**Table 2-2: VECBASE Register**

| Bits | Name | Meaning |
|------|------|---------|
| 7–1 | VEC | The table's place in I's page, bits 7–1 of its address |
| 0 | – | Reads 0: the table starts at an even address |

With I = `0x9F` and VECBASE = `0xD0`, as the examples use, the table is at `0x9FD0`–`0x9FFF`: VBLANK's handler address at `0x9FD0`, TIMER0's at `0x9FE6`, NONE's at `0x9FFE`. Figure 2-2 shows how the Z80 makes each address, and where the entries lie. Each entry is a handler's address, low byte first, as `LD (nn),HL` writes it.

```
          I                  the vector, for source n
     +----------+     +-----------------------------+
     |   0x9F   |     |  VECBASE + 2n  =  0xD0 + 2n |
     +----------+     +-----------------------------+
      high byte                  low byte

     entry n is at 0x9F00 + 0xD0 + 2n:

                 +-----------+-----------+
       0x9FD0    | low byte  | high byte |    0  VBLANK   vbl (Example 2-1)
                 +-----------+-----------+
       0x9FD2    |     entries 1-10      |
                 +-----------+-----------+
       0x9FE6    | low byte  | high byte |   11  TIMER0   tick (Example 2-3)
                 +-----------+-----------+
       0x9FE8    |     entries 12-22     |
                 +-----------+-----------+
       0x9FFE    | low byte  | high byte |   23  NONE     spurious
                 +-----------+-----------+
                                  0x9FFF: the table's last byte

               Figure 2-2: The IM 2 Table at 0x9FD0
```

The boot ROM starts a program with its own table (in ROM) and every source off. **A program that wants interrupts builds its own table** in its memory and points I and VECBASE at it. Fill every entry, so that a source turned on by mistake, and NONE, have somewhere to go.

### Step by step

1. `DI`, while setting up.
2. Build the table; set I and VECBASE; `IM 2`.
3. In the unit: clear the flag (so no old event comes in), then set the unit's enable.
4. In the controller: set the source's INTENA bit, then INTCON.MASTER.
5. `EI`.

### Writing a handler

```asm
vbl:    push    af                      ; save what the handler uses
        push    bc
        ld      bc,VIDSTAT_P
        ld      a,VIDSTAT_VBLANK_M
        out     (c),a                   ; 1. clear the cause, first
        ...                             ; 2. the work
        pop     bc
        pop     af
        ei                              ; 3. interrupts on again ...
        reti                            ; ... after this instruction
```

- **Clear the cause first.** An event that comes while the handler runs then sets the flag again, and is taken after the handler, not lost.
- **Save every register you use**, or use the alternate set (`EX AF,AF'` and `EXX`) if the main program never does.
- **End with `EI` then `RETI`.** The Z80 takes the next interrupt only after the instruction that follows `EI`, so `RETI` always gets to return first. (`RET` works too; the controller does not watch for `RETI`.)
- **Keep it short.** While a handler runs with interrupts off, nothing else is served. Hand longer work to the main program, with a flag, or to the software interrupt (below).
- **ROM calls from a handler**: avoid the ones that print or read keys. If the main program is inside one of them when the interrupt comes, the console would be entered twice. Let the handler set a flag and the main program print (Example 2-3 does this).

### The spurious interrupt, NONE

Rarely, a request goes away between the moment the Z80 sees /INT and the moment it asks for the vector: the main program cleared it, say, in that very instruction. The controller then gives NONE, entry 23. Its handler only returns:

```asm
spurious:
        ei
        reti
```

### Example 2-1: The vertical blank and the software interrupt

The program builds its table at `0x9FD0`, takes the vertical blank interrupt, and every 50th frame raises the software interrupt, whose handler steps the border colour. So the border changes once a second until a key is pressed; then everything is put back as the boot ROM left it.

```asm
; Example 2-1 (docs/guide/interrupts.md): the vertical blank interrupt,
; and the software interrupt for the slow part. An IM 2 table in the
; program's memory; the VBLANK handler counts frames and, every 50th,
; raises SOFT; the SOFT handler steps the border colour. So the border
; changes once a second. A key ends it, with everything put back.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

TABLE   equ     0x9FD0                  ; the IM 2 table: I = 0x9F, VECBASE = 0xD0

start:  di
        ld      hl,TABLE                ; every entry to the spurious handler ...
        ld      b,24
.fill:  ld      (hl),low spurious
        inc     hl
        ld      (hl),high spurious
        inc     hl
        djnz    .fill
        ld      hl,vbl                  ; ... then the two this program uses
        ld      (TABLE+2*INT_VBLANK),hl
        ld      hl,soft
        ld      (TABLE+2*INT_SOFT),hl

        ld      a,high TABLE
        ld      i,a
        ld      bc,VECBASE_P
        ld      a,low TABLE
        out     (c),a
        im      2

        ld      bc,VIDSTAT_P            ; no old VBLANK
        ld      a,VIDSTAT_VBLANK_M
        out     (c),a
        ld      bc,VIDINTEN_P           ; 1. the unit's enable
        in      a,(c)
        or      VIDINTEN_VBLANK_M
        out     (c),a
        ld      bc,INTENA0_P+(INTR_VBLANK<<8)
        ld      a,INTENA_SETCLR_M|(1<<INTB_VBLANK)
        out     (c),a                   ; 2. the controller's enables: VBLANK ...
        ld      bc,INTENA0_P+(INTR_SOFT<<8)
        ld      a,INTENA_SETCLR_M|(1<<INTB_SOFT)
        out     (c),a                   ;    ... and SOFT
        ld      bc,INTCON_P
        ld      a,INTCON_MASTER_M
        out     (c),a                   ; 3. the master enable
        ei                              ; 4. the CPU's

        ld      hl,title
        rst     0x18                    ; PUTS: the ROM's calls work with interrupts on
.main:  rst     0x20                    ; POLLC: a key?
        jr      z,.main

        di                              ; put everything back
        ld      bc,INTCON_P
        xor     a
        out     (c),a                   ; master off
        ld      bc,INTENA0_P+(INTR_VBLANK<<8)
        ld      a,1<<INTB_VBLANK        ; SETCLR 0: clear
        out     (c),a
        ld      bc,INTENA0_P+(INTR_SOFT<<8)
        ld      a,1<<INTB_SOFT
        out     (c),a
        ld      bc,VIDINTEN_P
        in      a,(c)
        and     ~VIDINTEN_VBLANK_M
        out     (c),a
        ld      a,0x1F                  ; the ROM's table again
        ld      i,a
        ld      bc,VECBASE_P
        ld      a,0xD0
        out     (c),a
        xor     a
        out     (ULA_PORT),a            ; border black
        ret

vbl:    push    af                      ; VBLANK: 50 times a second
        push    bc
        ld      bc,VIDSTAT_P
        ld      a,VIDSTAT_VBLANK_M
        out     (c),a                   ; clear the cause first
        ld      a,(frames)
        inc     a
        cp      50
        jr      nz,.keep
        ld      bc,SOFTINT_P            ; a second gone: leave the rest to SOFT
        ld      a,SOFTINT_SET_M
        out     (c),a
        xor     a
.keep:  ld      (frames),a
        pop     bc
        pop     af
        ei
        reti

soft:   push    af                      ; SOFT: once a second, after every other source
        push    bc
        ld      bc,SOFTINT_P
        ld      a,SOFTINT_CLR_M
        out     (c),a                   ; clear it first
        ld      a,(colour)
        inc     a
        and     7
        ld      (colour),a
        out     (ULA_PORT),a            ; the next border colour
        pop     bc
        pop     af
        ei
        reti

spurious:
        ei                              ; NONE, or a source nobody asked for
        reti

frames: db      0
colour: db      0
title:  db      13, 10, "The border steps once a second. A key ends it.", 13, 10, 0
```

The border goes black, blue, red, magenta and on round the eight Spectrum colours, a step a second.

---

## Enabling, Disabling and Clearing

### INTENA is three set/clear bytes

Each source has one bit in **INTENA0**, **INTENA1** or **INTENA2** (registers `0x01`–`0x03`), seven sources to a byte (Tables 2-3 to 2-5). `hw.inc` gives both halves of a source's place: `INTR_name` is the byte (0, 1 or 2) and `INTB_name` the bit. Bit 7 of each byte is **SETCLR**. Reading a byte gives the enables, with bit 7 as 0.

**Table 2-3: INTENA0 Register**

| Bits | Name | Meaning |
|------|------|---------|
| 7 | SETCLR | Write: 1 sets, 0 clears the bits written as 1. Reads 0 |
| 6 | DMA2 | Source 6 |
| 5 | DMA1 | Source 5 |
| 4 | DMA0 | Source 4 |
| 3 | VIDERR | Source 3 |
| 2 | COPPER | Source 2 |
| 1 | LINE | Source 1 |
| 0 | VBLANK | Source 0 |

**Table 2-4: INTENA1 Register**

| Bits | Name | Meaning |
|------|------|---------|
| 7 | SETCLR | As INTENA0 |
| 6 | TIMER2 | Source 13 |
| 5 | TIMER1 | Source 12 |
| 4 | TIMER0 | Source 11 |
| 3 | – | Source 10, not used |
| 2 | AUDIO | Source 9, kept for sound |
| 1 | – | Source 8, not used |
| 0 | DMA3 | Source 7 |

**Table 2-5: INTENA2 Register**

| Bits | Name | Meaning |
|------|------|---------|
| 7 | SETCLR | As INTENA0 |
| 6 | – | Source 20, kept for later |
| 5 | GEOM | Source 19, kept for the geometry unit |
| 4 | SOFT | Source 18 |
| 3 | KEYB | Source 17 |
| 2 | SD | Source 16, not used: the SD card is polled |
| 1 | SERIAL | Source 15 |
| 0 | TIMER3 | Source 14 |

A write changes only the bits written as 1 (Table 2-6).

**Table 2-6: Writing an INTENA Byte**

| Write | Effect |
|-------|--------|
| SETCLR = 1, with bits set | Those sources on |
| SETCLR = 0, with bits set | Those sources off |
| Bits written as 0 | Left alone |

TIMER0 is bit 4 of INTENA1, so turning it on is `0x90` to port `0x0200`, and off `0x10`. The assembler makes the same bytes from the names:

```asm
        db      0x90                            ; INTENA1: SETCLR and bit 4, TIMER0 on
        db      INTENA_SETCLR_M|(1<<INTB_TIMER0) ; the same byte
        db      0x10                            ; SETCLR 0 and bit 4: TIMER0 off
        db      1<<INTB_TIMER0                  ; the same byte
```

In a program:

```asm
        ld      bc,INTENA0_P+(INTR_TIMER0<<8)   ; the byte that holds TIMER0
        ld      a,INTENA_SETCLR_M|(1<<INTB_TIMER0)
        out     (c),a                           ; TIMER0 on, the others as they were
        ld      a,1<<INTB_TIMER0
        out     (c),a                           ; TIMER0 off again
```

Never read INTENA, change a bit and write it back: the main program and a handler can then each turn their own sources on and off without getting in each other's way.

**INTCON.MASTER** (register `0x00`, bit 0) turns every source off at once, and back on, without touching INTENA. Requests that come meanwhile wait. The NMI does not pass through it.

**Table 2-7: INTCON Register**

| Bits | Name | Meaning |
|------|------|---------|
| 7–1 | – | Read 0 |
| 0 | MASTER | 1: every source but the NMI on, as INTENA says. 0: all off |

### Seeing what is going on

**Table 2-8: Interrupt Status Registers**

| Register | Shows |
|----------|-------|
| INTRAW0–2 (`0x07`–`0x09`) | Which units are asking, before INTENA and MASTER |
| INTPEND0–2 (`0x04`–`0x06`) | Which are pending: asking, enabled, and MASTER on |
| INTID (`0x0C`) | The source given at the last answer: 0–20, or 23 for NONE |

INTRAW, INTPEND and INTENA use the same bit positions (Tables 2-3 to 2-5), so a mask made for one works for the others; bit 7 of INTRAW and INTPEND reads 0.

**Table 2-9: INTID Register**

| Bits | Name | Meaning |
|------|------|---------|
| 7–5 | – | Read 0 |
| 4–0 | SRC | The source given at the last answer: 0–20, or 23 (NONE). The NMI does not change it |

A program can also **poll** without interrupts at all: leave the source off in INTENA and test the unit's flag, or INTRAW.

---

## The Software Interrupt

Writing **SOFTINT** (register `0x0B`) with SET (bit 0) raises source 18, SOFT; with CLR (bit 1) it clears it. It goes through INTENA and MASTER like any other source.

**Table 2-10: SOFTINT Register**

| Bits | Name | Meaning |
|------|------|---------|
| 7–2 | – | Not used. The register reads `0x00` |
| 1 | CLR | Write 1: clear SOFT |
| 0 | SET | Write 1: raise SOFT |

SOFT has the highest number, so it is taken only when nothing else is pending. That makes it the place for the slow part of a handler: the VBLANK handler does what must be done at once, raises SOFT and returns, and the rest runs in the SOFT handler, after every other source has been served. Example 2-1 does this. The SOFT handler clears SOFT first, so a new request made while it runs is kept.

---

## The Time Counter: TIME

**TIME** counts microseconds from power-on, in 32 bits: it wraps after 71.6 minutes. Only power-on resets it; every other reset leaves it counting. It sits in TIME0–TIME3 (registers `0x20`–`0x23`), low byte first, and cannot be written (Table 2-11).

**Table 2-11: TIME Registers**

| Register | Name | Bits of TIME |
|----------|------|--------------|
| `0x20` | TIME0 | 7–0. Reading it captures all 32 bits |
| `0x21` | TIME1 | 15–8, from the capture |
| `0x22` | TIME2 | 23–16, from the capture |
| `0x23` | TIME3 | 31–24, from the capture |

**Reading TIME0 captures all 32 bits**, and TIME1–TIME3 then read from the capture, so a value read low byte first is whole. The capture is shared with every other counter that captures (a timer's COUNT, for one), so read with interrupts off if a handler reads counters too:

```asm
; TIME to DEHL (D = bits 31-24)
time:   di
        ld      bc,TIME0_P
        in      l,(c)                   ; captures all 32 bits
        inc     b
        in      h,(c)
        inc     b
        in      e,(c)
        inc     b
        in      d,(c)
        ei
        ret
```

Through the register page, `LD HL,(SREG+TIME0)` reads the low 16 bits in one instruction, safe from interrupts.

Subtracting two readings gives the time between them, right across a wrap, as long as it is shorter than the wrap: 65.5 ms for 16 bits, 71.6 minutes for 32. TIME is the tool for **measuring**: how long a routine takes, a timeout, a delay that needs no setting up.

### Example 2-2: Timing code

The program times an 8 KB `LDIR` at 20 MHz and again at the Spectrum speed.

```asm
; Example 2-2 (docs/guide/interrupts.md): timing code with TIME.
; Copies 8 KB with LDIR and prints how many microseconds it took, at
; 20 MHz and again at the Spectrum speed (3.57 MHz). TIME counts
; microseconds; its low 16 bits are enough for anything under 65 ms.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

PUTDEC  equ     0x08                    ; RST 28h function: HL in decimal

start:  ld      hl,s_20
        rst     0x18                    ; PUTS
        call    measure

        ld      bc,CPUSPEED_P
        ld      a,CPUSPEED_SPECTRUM_M
        out     (c),a                   ; 3.57 MHz
        ld      hl,s_spec
        rst     0x18
        call    measure
        ld      bc,CPUSPEED_P
        xor     a
        out     (c),a                   ; 20 MHz again
        ret

measure:                                ; time the copy; print the microseconds
        di                              ; nothing else reads a counter meanwhile
        call    time
        push    hl
        ld      hl,0x2000               ; 8 KB from window 1 to window 5
        ld      de,0xA000
        ld      bc,8192
        ldir                            ; 21 T a byte, 16 for the last
        call    time
        pop     de
        or      a
        sbc     hl,de                   ; the difference is right across a wrap
        ei
        rst     0x28
        db      PUTDEC
        ld      hl,s_us
        rst     0x18
        ret

time:   ld      bc,TIME0_P              ; TIME bits 15-0 to HL
        in      l,(c)                   ; reading TIME0 captures all 32 bits
        inc     b
        in      h,(c)                   ; TIME1, from the capture
        ret

s_20:   db      13, 10, "8 KB LDIR at 20 MHz:   ", 0
s_spec: db      "8 KB LDIR at 3.57 MHz: ", 0
s_us:   db      " us", 13, 10, 0
```

It prints:

```
8 KB LDIR at 20 MHz:   8607 us
8 KB LDIR at 3.57 MHz: 48197 us
```

The copy is 8,191 × 21 + 16 = 172,027 T-states, and the code between the two readings about 100 more: 8,607 µs at 50 ns a T-state, and 48,197 µs at 3.57 MHz. The Z80 never waits for memory, so the count is exact.

---

## The General Timers

Four timers, **TMR0–TMR3**, make things happen at set times. Each is a 16-bit **COUNT** that goes down by 1 on every **tick** of its source. When COUNT is 0 and another tick comes, the timer **underflows**:

- its flag **STAT.UNDER** is set, and with **CTRL.IRQ** its interrupt (TIMER0–TIMER3) asks;
- with **CTRL.REPEAT** it reloads COUNT from **RELOAD** and goes on; without, it stops (CTRL.EN clears itself);
- with **CTRL.DMA** it starts a DMA channel (Chapter 6);
- the next timer, if it counts this one, gets a tick.

So a repeating timer with RELOAD = n underflows every n + 1 ticks.

### The registers

Timer n is at register `0x28` + 8n: TMR0 at `0x28`, TMR1 `0x30`, TMR2 `0x38`, TMR3 `0x40`. Each has the eight registers of Table 2-12. The 16-bit values are low byte first.

**Table 2-12: Timer Registers**

| Offset | Name | Function |
|--------|------|----------|
| +0 | CTRL | Control (Table 2-13) |
| +1, +2 | PRESCALE0, 1 | The system clock's divider, 16 bits |
| +3, +4 | RELOAD0, 1 | Loaded into COUNT at each underflow, in REPEAT |
| +5, +6 | COUNT0, 1 | The count. Writing sets it at once; reading COUNT0 captures it |
| +7 | STAT | Status (Table 2-14) |

**Table 2-13: TMRn_CTRL Register**

| Bits | Name | Meaning |
|------|------|---------|
| 7–6 | DMACH | The DMA channel to start, 0–3 |
| 5 | DMA | 1: start channel DMACH at each underflow (Chapter 6) |
| 4 | IRQ | 1: the timer's interrupt asks while STAT.UNDER is set |
| 3–2 | SRC | What a tick is, 0–3 (Table 2-15) |
| 1 | REPEAT | 1: reload from RELOAD at underflow and go on. 0: one-shot |
| 0 | EN | 1: running. A one-shot underflow clears it |

**Table 2-14: TMRn_STAT Register**

| Bits | Name | Meaning |
|------|------|---------|
| 7–1 | – | Read 0 |
| 0 | UNDER | The timer has underflowed. Write 1 to clear |

Example 2-3 starts timer 0 repeating, with its interrupt, at SRC 0: CTRL is `0x13`. Counting frames instead (SRC 2) makes it `0x1B`. The assembler makes the same bytes from the names:

```asm
        db      0x13                            ; EN, REPEAT, IRQ; SRC 0
        db      TMR_CTRL_EN_M|TMR_CTRL_REPEAT_M|TMR_CTRL_IRQ_M ; the same byte
        db      0x1B                            ; EN, REPEAT, IRQ; SRC 2
        db      TMR_CTRL_EN_M|TMR_CTRL_REPEAT_M|(2<<TMR_CTRL_SRC_B)|TMR_CTRL_IRQ_M ; the same byte
```

- **Writing COUNT** changes it at once, byte by byte, so stop the timer (CTRL = 0) first.
- **Writing RELOAD** changes nothing until the next underflow, so a running timer's period can change without one odd period.
- **Starting** (EN from 0 to 1) starts the prescaler afresh, so the first period is as long as the others.
- STAT.UNDER is set at every underflow, with IRQ or without, so a timer can be polled.

### What a timer counts

CTRL's SRC field picks what a tick is (Table 2-15).

**Table 2-15: Timer Sources**

| SRC (CTRL bits 3–2) | A tick is | Every |
|---------------------|-----------|-------|
| 0 | The 100 MHz system clock ÷ (PRESCALE + 1) | 10 ns × (PRESCALE + 1) |
| 1 | The start of a line | 32 µs |
| 2 | The start of a frame | 20 ms |
| 3 | The previous timer's underflow (timer 0 counts timer 3) | – |

At SRC 0 the period is (PRESCALE + 1) × (RELOAD + 1) × 10 ns. PRESCALE 99 gives a tick of exactly 1 µs. The line and frame ticks follow the beam whether or not anything is on the screen. Table 2-16 gives settings for common needs.

**Table 2-16: Timer Settings for Common Rates**

| Want | Settings |
|------|----------|
| 1000 Hz, an operating system's tick | SRC 0, PRESCALE 99, RELOAD 999, REPEAT, IRQ |
| 100 Hz | SRC 0, PRESCALE 99, RELOAD 9,999, REPEAT, IRQ |
| 10 Hz | SRC 0, PRESCALE 9,999, RELOAD 999, REPEAT, IRQ (Example 2-3) |
| Every 5th frame | SRC 2, RELOAD 4, REPEAT, IRQ |
| After n more lines | SRC 1, COUNT n − 1, one-shot |
| A 2-second timeout, polled | SRC 0, PRESCALE 49,999 (0.5 ms), COUNT 3,999, one-shot: test STAT.UNDER |
| Once a second, from the 1000 Hz tick | Timer 1: SRC 3, RELOAD 999, REPEAT, IRQ |

### Setting up a timer

1. Stop it: CTRL = 0.
2. Clear STAT.UNDER (write 1), so an old underflow gives no interrupt.
3. Write PRESCALE, RELOAD and COUNT.
4. For an interrupt: the handler in the table, and the source on in INTENA and INTCON.MASTER.
5. Write CTRL, with EN and the rest, in one write.

### Example 2-3: A timer interrupt

Timer 0 ticks at 10 Hz. Its handler only counts; the main program waits for ten counts, prints the second, and after five stops the timer and ends.

```asm
; Example 2-3 (docs/guide/interrupts.md): a timer interrupt.
; Timer 0 ticks at 10 Hz: 100 MHz / 10,000 (PRESCALE 9,999) is 10 kHz,
; and RELOAD 999 underflows every 1,000 of those. Its handler only counts;
; the main program waits for the count and prints the seconds, 1 to 5,
; then stops the timer and ends.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

PUTDEC  equ     0x08                    ; RST 28h function: HL in decimal
TABLE   equ     0x9FD0                  ; I = 0x9F, VECBASE = 0xD0

start:  di
        ld      hl,TABLE
        ld      b,24
.fill:  ld      (hl),low spurious
        inc     hl
        ld      (hl),high spurious
        inc     hl
        djnz    .fill
        ld      hl,tick
        ld      (TABLE+2*INT_TIMER0),hl
        ld      a,high TABLE
        ld      i,a
        ld      bc,VECBASE_P
        ld      a,low TABLE
        out     (c),a
        im      2

        ld      bc,TMR0_CTRL_P          ; C = 0x00 for the whole timer
        xor     a
        out     (c),a                   ; 1. stop
        ld      b,TMR0_STAT
        ld      a,TMR_STAT_UNDER_M
        out     (c),a                   ; 2. no old underflow
        ld      b,TMR0_PRESCALE0
        ld      hl,9999                 ; 3. 10 kHz ...
        out     (c),l
        inc     b
        out     (c),h
        inc     b                       ;    RELOAD
        ld      hl,999                  ;    ... / 1,000 = 10 Hz
        out     (c),l
        inc     b
        out     (c),h
        inc     b                       ;    COUNT: the first period too
        out     (c),l
        inc     b
        out     (c),h
        ld      b,INTENA0+INTR_TIMER0   ; 4. the controller
        ld      a,INTENA_SETCLR_M|(1<<INTB_TIMER0)
        out     (c),a
        ld      b,INTCON
        ld      a,INTCON_MASTER_M
        out     (c),a
        ld      b,TMR0_CTRL             ; 5. go: repeating, with its interrupt
        ld      a,TMR_CTRL_EN_M|TMR_CTRL_REPEAT_M|TMR_CTRL_IRQ_M
        out     (c),a
        ei

        ld      hl,title
        rst     0x18                    ; PUTS
        ld      hl,1                    ; HL = the next second to print
.wait:  ld      a,(ticks)
        cp      10                      ; 10 ticks: a second
        jr      c,.wait
        di
        sub     10
        ld      (ticks),a
        ei
        push    hl
        rst     0x28
        db      PUTDEC
        ld      a,' '
        rst     0x08                    ; PUTC
        pop     hl
        inc     hl
        ld      a,l
        cp      6
        jr      nz,.wait

        di                              ; stop and put things back
        ld      bc,TMR0_CTRL_P
        xor     a
        out     (c),a
        ld      bc,INTCON_P
        out     (c),a
        ld      bc,INTENA0_P+(INTR_TIMER0<<8)
        ld      a,1<<INTB_TIMER0
        out     (c),a
        ld      a,0x1F
        ld      i,a
        ld      bc,VECBASE_P
        ld      a,0xD0
        out     (c),a
        ld      hl,s_nl
        rst     0x18
        ret

tick:   push    af                      ; timer 0's underflow: 10 times a second
        push    bc
        ld      bc,TMR0_STAT_P
        ld      a,TMR_STAT_UNDER_M
        out     (c),a                   ; clear the cause
        ld      a,(ticks)
        inc     a
        ld      (ticks),a
        pop     bc
        pop     af
        ei
        reti

spurious:
        ei
        reti

ticks:  db      0
title:  db      13, 10, "Seconds: ", 0
s_nl:   db      13, 10, 0
```

It prints `Seconds: 1 2 3 4 5`, a number a second. The same program counting frames instead (SRC 2, RELOAD 4: every fifth frame is also 10 Hz) prints the same: change step 3's RELOAD and COUNT to 4 and step 5's CTRL to add `2<<TMR_CTRL_SRC_B`.

---

## The Watchdog

The watchdog resets the computer if a program stops working. Once it is on, the program must **kick** it, writing `0x5A` to **WDKICK**, at least once every **WDTIME** milliseconds; if a kick is late, the computer gets a full reset, with RESETWHY.WATCHDOG set. A kick with any other value resets at once, so a program running wild through its memory is caught quickly.

**Table 2-17: Watchdog Registers**

| Register | Name | Function |
|----------|------|----------|
| `0x48` | WDCTRL | Control (Table 2-18). Writing it restarts the time |
| `0x49`, `0x4A` | WDTIME0, 1 | Milliseconds allowed between kicks, 1–65,535 (1000 after reset) |
| `0x4B` | WDKICK | `0x5A` (`WDKICK_MAGIC`) kicks; anything else resets (while on) |

The watchdog is off after every reset, so simple programs need not know it is there. **Kick from the main loop, not from an interrupt handler**: interrupts usually keep running when the main program hangs, and a handler that kicks would hide the hang. Set LOCK in the same write as EN, so a fault cannot turn the watchdog off.

**Table 2-18: WDCTRL Register**

| Bits | Name | Meaning |
|------|------|---------|
| 7–2 | – | Read 0 |
| 1 | LOCK | 1: WDCTRL and WDTIME read only until the next reset |
| 0 | EN | 1: on, and the time starts |

EN and LOCK together are `0x03`:

```asm
        db      0x03                            ; WDCTRL: EN and LOCK
        db      WDCTRL_EN_M|WDCTRL_LOCK_M       ; the same byte
```

### Example 2-4: The watchdog

The program turns the watchdog on with half a second's grace, kicks it every frame for two seconds, then stops, as a hung program would.

```asm
; Example 2-4 (docs/guide/interrupts.md): the watchdog.
; Turns the watchdog on with half a second's grace, kicks it every frame
; for two seconds, then stops kicking, as a hung program would. Half a
; second later the computer resets, and the boot ROM says
; "Reset: watchdog."

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

start:  ld      hl,title
        rst     0x18                    ; PUTS

        ld      bc,WDTIME0_P            ; 500 ms between kicks
        ld      hl,500
        out     (c),l
        inc     b
        out     (c),h
        ld      bc,WDCTRL_P
        ld      a,WDCTRL_EN_M
        out     (c),a                   ; on: the time starts

        ld      e,100                   ; 100 frames: 2 seconds
.frame: ld      bc,VIDSTAT_P            ; wait for the next frame
        ld      a,VIDSTAT_VBLANK_M
        out     (c),a
.wait:  in      a,(c)
        and     VIDSTAT_VBLANK_M
        jr      z,.wait
        ld      bc,WDKICK_P
        ld      a,WDKICK_MAGIC
        out     (c),a                   ; kick: 0x5A, and only 0x5A
        dec     e
        jr      nz,.frame

        ld      hl,s_hang
        rst     0x18
.hang:  jr      .hang                   ; no more kicks: reset in 500 ms

title:  db      13, 10, "Kicking the watchdog for 2 seconds ...", 13, 10, 0
s_hang: db      "... and now not.", 13, 10, 0
```

Half a second after the last kick the computer resets, and the boot ROM starts with:

```
retro-z80 boot ROM 0.1  Z80 at 20 MHz, 2 MB SRAM
Reset: watchdog.
Monitor.  H for help.
```

---

## Advanced Topics

Most programs need nothing more than the parts above. This section is for programs that want one handler to interrupt another, IM 1 instead of IM 2, the NMI for themselves, or a slower tick than one timer can give.

### Nesting

The controller has no "in service" state. A handler that does `EI` early can be interrupted by any pending source, a higher number included. To let only more urgent ones in, a handler turns off the INTENA bits of the less urgent sources, does `EI`, and turns them back on before it returns. Most handlers are short enough not to bother.

### IM 1

In IM 1 every interrupt runs `RST 38h`. The controller still picks a source, and writes it to **INTID**, so one handler can read INTID and jump through a table of its own. But **in the program map, `0x0038` is in the boot ROM**, where it is the trap that stops a runaway program. A program that wants IM 1 maps its own SRAM page into window 0, with its handler at `0x0038` (and an NMI handler at `0x0066`), and then makes no ROM calls. IM 2 needs none of this, and is the one to use.

**IM 0 is not supported**: the controller always gives an IM 2 vector. Choose IM 1 or IM 2 before the first `EI`.

### The nonmaskable interrupt

The NMI cannot be turned off by `DI`. The Z80 jumps to `0x0066` and the handler ends with `RETN`. Three things raise it (Table 2-19):

**Table 2-19: NMI Sources**

| Source | Event | Allowed by | Seen in |
|--------|-------|------------|---------|
| The Multiface button | A press | NMICON.BUTTONEN (bit 0) | NMISTAT.BUTTON |
| The PC | The BREAK control command on the USB link | NMICON.USBEN (bit 1) | NMISTAT.USB |
| The debug unit | A step, a breakpoint or a watchpoint, from VS Code or the monitor | Its own settings | Its own status |

Each press or BREAK gives exactly one NMI. **NMISTAT** (register `0x0E`, W1C) keeps which sources there have been since it was last cleared; **NMICON** (`0x0D`) allows each one, and both are on after reset.

**Table 2-20: NMICON Register**

| Bits | Name | Meaning |
|------|------|---------|
| 7–2 | – | Read 0 |
| 1 | USBEN | 1: BREAK from the PC gives an NMI |
| 0 | BUTTONEN | 1: the Multiface button gives an NMI |

**Table 2-21: NMISTAT Register**

| Bits | Name | Meaning |
|------|------|---------|
| 7–2 | – | Read 0 |
| 1 | USB | BREAK from the PC gave an NMI. Write 1 to clear |
| 0 | BUTTON | The button gave an NMI. Write 1 to clear |

**The monitor owns the NMI.** By default, taking an NMI switches window 0 to the boot ROM's monitor page, and keeps the return address in registers instead of on the program's stack, so the program's memory and stack are not touched. `RETN` puts both back. This is how the Multiface button, BREAK from the PC and the debugger stop a program and let it carry on. A program that does not want to be stopped (a game, say, that must not be broken into) clears NMICON's bits:

```asm
        ld      bc,NMICON_P
        xor     a
        out     (c),a                   ; neither the button nor the PC can stop it now
```

That shuts out the debugger's pause too, which uses the PC's BREAK: clear only BUTTONEN to keep debugging.

An NMI never interrupts another NMI's handler: one that comes meanwhile is taken straight after `RETN`.

### Interrupt pages

The NMI's switch to the monitor page is one use of the **interrupt pages**: chosen windows switched to pages of their own on the way into a handler, and back on the way out. The same is meant for maskable interrupts, so that a handler can have its code, stack and data in a bank of its own whatever the program has mapped. That part is not built yet: maskable interrupts switch nothing, and its registers do not answer. Only the NMI's set is built.

### Chaining timers

With SRC 3 a timer counts the underflows of the one before it (timer 1 counts timer 0, and timer 0 counts timer 3). Two chained timers make a 32-bit counter, or turn a fast tick into a slow one: timer 0 at 1000 Hz and timer 1 counting 1,000 of its underflows give one interrupt a second.

---

## Timing

### How quickly

When a request becomes pending, the Z80 first finishes the instruction it is in, then answers. Table 2-22 gives each step.

**Table 2-22: Steps of an Interrupt Response**

| Step | T-states |
|------|----------|
| Finish the current instruction | Up to 23 (`INC (IX+d)`, for one). `LDIR` and the other repeats take interrupts between their steps |
| After `EI` | The next instruction always runs first |
| IM 2: answer, push PC, read the table | 19 |
| IM 1: answer, push PC | 13 |
| NMI: push PC | 11 |
| The controller | 1 system clock (10 ns), to pass the request on |

So the worst case is 23 + 19 = 42 T-states in IM 2, and 36 in IM 1, before the first instruction of the handler. Table 2-23 gives them in time at each CPU speed (CPUSPEED). Code that runs with interrupts off adds its own time.

**Table 2-23: Worst-Case Interrupt Latency**

| CPU speed | IM 2 (42 T) | IM 1 (36 T), before its own dispatch |
|-----------|-------------|--------------------------------------|
| 20 MHz | 2.1 µs | 1.8 µs |
| 10 MHz | 4.2 µs | 3.6 µs |
| 6.67 MHz | 6.3 µs | 5.4 µs |
| 5 MHz | 8.4 µs | 7.2 µs |
| 4 MHz | 10.5 µs | 9.0 µs |
| 3.57 MHz (SPECTRUM) | 11.8 µs | 10.1 µs |
| 3.33 MHz | 12.6 µs | 10.8 µs |
| 2.86 MHz | 14.7 µs | 12.6 µs |
| 2.5 MHz | 16.8 µs | 14.4 µs |

### What interrupts cannot do

- **Change the screen at an exact pixel.** A line takes 32 µs, 640 T-states at 20 MHz, and a handler starts between about 20 and 42 T-states after its event, depending on the instruction it waited for. That is the copper's job (Chapter 5).
- **IM 0.** It is not supported: the controller always gives an IM 2 vector, which the Z80 in IM 0 would run as an instruction. Choose IM 1 or IM 2 before the first `EI`.
- **Switch pages for a maskable handler.** The interrupt pages are built for the NMI only ("Interrupt pages", in Advanced Topics). A maskable handler runs in whatever the program has mapped.
- **The LINE interrupt.** It is not built yet: source 1 never asks.
- **The SERIAL interrupt.** The USB link's request does not reach the controller yet (ticket #58), so source 15 never asks. Poll the link's status (SERSTAT0 and SERSTAT1) for now.

---

## Summary of Registers

All are registers of page `0x00`: port = (register << 8) | `0x00`, register page offset = register.

### Interrupt controller

**Table 2-24: Interrupt Controller Registers**

| Register | Port | Name | Access | Function |
|----------|------|------|--------|----------|
| `0x00` | `0x0000` | INTCON | RW | MASTER (0): every source but the NMI |
| `0x01`–`0x03` | `0x0100`–`0x0300` | INTENA0–2 | SC | Sources 0–6, 7–13, 14–20 (bits 6–0); SETCLR (7) |
| `0x04`–`0x06` | `0x0400`–`0x0600` | INTPEND0–2 | R | Pending: asking, enabled, MASTER on |
| `0x07`–`0x09` | `0x0700`–`0x0900` | INTRAW0–2 | R | Asking, before INTENA and MASTER |
| `0x0A` | `0x0A00` | VECBASE | RW | The table's place in I's page (bits 7–1) |
| `0x0B` | `0x0B00` | SOFTINT | W | SET (0), CLR (1): the software interrupt |
| `0x0C` | `0x0C00` | INTID | R | The last source given: 0–20, or 23 (NONE) |
| `0x0D` | `0x0D00` | NMICON | RW | BUTTONEN (0), USBEN (1) |
| `0x0E` | `0x0E00` | NMISTAT | W1C | BUTTON (0), USB (1) |

### Time counter, timers and watchdog

**Table 2-25: Time Counter, Timer and Watchdog Registers**

| Register | Port | Name | Access | Function |
|----------|------|------|--------|----------|
| `0x20`–`0x23` | `0x2000`–`0x2300` | TIME0–3 | R, CAP | Microseconds from power-on, 32 bits |
| `0x28` + 8n | `0x2800` + n × `0x800` | TMRn_CTRL | RW | EN (0), REPEAT (1), SRC (3–2), IRQ (4), DMA (5), DMACH (7–6) |
| `0x29` + 8n | | TMRn_PRESCALE0–1 | RW | The SRC 0 divider |
| `0x2B` + 8n | | TMRn_RELOAD0–1 | RW | The reload value |
| `0x2D` + 8n | | TMRn_COUNT0–1 | RW, CAP | The count |
| `0x2F` + 8n | | TMRn_STAT | W1C | UNDER (0) |
| `0x48` | `0x4800` | WDCTRL | RW | EN (0), LOCK (1) |
| `0x49`–`0x4A` | `0x4900`–`0x4A00` | WDTIME0–1 | RW | Milliseconds between kicks |
| `0x4B` | `0x4B00` | WDKICK | W | `0x5A` kicks; anything else resets |

### State after reset, and when a program starts

After reset MASTER is off, every INTENA bit is off, VECBASE is 0, SOFT is clear, both NMI sources are allowed; every timer is stopped with its registers 0; the watchdog is off, WDTIME 1000; TIME counts on. When the boot ROM starts a program the Z80 is in IM 2 with interrupts disabled, I = `0x1F` and VECBASE = `0xD0` (the ROM's table), and every source still off: the program finds every interrupt and every timer free.

### Equates in hw.inc

**Table 2-26: Equates in hw.inc**

| Equate | Value |
|--------|-------|
| `INT_VBLANK` … `INT_SOFT`, `INT_NONE` | Source numbers, 0 … 18, and 23 |
| `INTR_name`, `INTB_name` | A source's INTENA byte (0–2) and bit (0–6) |
| `INTENA_SETCLR_M`, `INTCON_MASTER_M` | `0x80`, `0x01` |
| `SOFTINT_SET_M`, `SOFTINT_CLR_M` | `0x01`, `0x02` |
| `NMICON_BUTTONEN_M`, `NMICON_USBEN_M`, and `NMISTAT_` the same | `0x01`, `0x02` |
| `TMR0` … `TMR3`, `TMR_CTRL` … `TMR_STAT` | `0x28` … `0x40`, and the offsets 0–7 |
| `TMR0_CTRL`, `TMR0_COUNT0` …, and `_P` | Each timer register's number and port |
| `TMR_CTRL_EN_M`, `_REPEAT_M`, `_IRQ_M`, `_DMA_M`, `TMR_CTRL_SRC_B`, `TMR_STAT_UNDER_M` | Fields |
| `TIME0` … `TIME3`, `WDCTRL`, `WDTIME0`, `WDKICK`, and `_P`; `WDKICK_MAGIC` | `0x20` …, `0x5A` |
