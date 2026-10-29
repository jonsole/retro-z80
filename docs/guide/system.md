# Chapter 1: Introduction and System Control

## Introduction

retro-z80 is a Z80 home computer built in the FPGA of a ZX Spectrum Next. The Z80 runs at 20 MHz and never waits for memory. Around it is a chipset in the style of the Amiga's: layers of bitmaps and tile maps, sprites, a copper, and a DMA engine with a blitter, all reading the same SRAM as the CPU, on their own share of the memory cycles. An MMU gives the Z80 its 64 KB as eight 8 KB windows onto 4 MB of memory. A boot ROM starts the machine, offers a monitor, and loads programs from a PC over USB.

It is also a Spectrum at heart: port `0xFE` reads the keyboard and sets the border as a Spectrum's does, a Kempston joystick reads at port `0x1F`, and a Spectrum screen can be shown as it is.

This chapter is the base the others build on. It covers:

- an overview of the guide: the machine at a glance, and the other chapters;
- memory: the windows, the MMU, pages and physical addresses;
- the hardware registers, and how the Z80 reaches them through ports and through the register page;
- how memory is shared between the CPU and the chipset;
- the system control registers: identification, the cause of a reset, the CPU's speed, the buttons;
- reset and the boot ROM;
- the environment a program starts in, how it ends, and how it is built and loaded;
- a program built step by step, with the set-up the guide's examples use.

---

## Guide Overview

Two tables to start with: what the machine has, and which chapter covers each part.

### The Machine at a Glance

**Table 1-1: The Machine at a Glance**

| Item | Value |
|------|-------|
| CPU | Z80 at 20 MHz (or slower, down to 2.5 MHz, or 3.57 MHz for Spectrum timing). Never waits for memory |
| Memory | 2 MB or 4 MB of SRAM (the board's chip), shared by the CPU and the chipset. No other RAM |
| CPU address space | 64 KB, as eight 8 KB windows, each mapped by the MMU onto any 8 KB page |
| Boot ROM | 32 KB, four pages, in the FPGA |
| Display | 720 × 576 at 50 Hz on HDMI and VGA; three layers, bitmaps or tile maps, 1–8 bits per pixel |
| Sprites | Eight, any size, 3, 15 or 255 colours, scaled, at any depth among the layers |
| Copper | A display list that writes registers in step with the beam |
| DMA engine | Four channels with an Amiga-style blitter |
| Input | The membrane keyboard, a PS/2 keyboard, two joystick ports; keys from the PC |
| Link | USB serial to a PC: console, program upload, debugging from VS Code |

### The Hardware Chapters

**Table 1-2: The Hardware Chapters**

| Chapter | Covers |
|---------|--------|
| 1. Introduction and System Control | This chapter |
| 2. Interrupts and Timers | IM 2, the interrupt controller, interrupt pages, the NMI, the timers and the watchdog |
| 3. Playfield Hardware | The display: layers, bitmaps, tile maps, palettes, priority |
| 4. Sprite Hardware | The sprites and the sprite sequencer |
| 5. Coprocessor Hardware | The copper |
| 6. Blitter and DMA Hardware | The DMA engine and its blitter |
| 7. The USB Serial Link | The link, the console, upload and debugging |
| 8. Keyboards and Joysticks | Every way to read the keys and the joysticks |
| Appendix A | Timing and the screen in numbers |

---

## Conventions in This Guide

- Examples are Z80 assembly language for **sjasmplus**, starting with `include "hw.inc"` (in `firmware/include/`). `hw.inc` is made from the one register list, `fpga/regmap.def`, so its names are the specs' names.
- Numbers are hexadecimal when they start with `0x`, decimal otherwise. Bits are numbered from 0, the lowest. Bit tables list the top bit first.
- Tables and figures are numbered by chapter: Table 1-3 is the third table of Chapter 1.
- Register access codes: R read only, W write only, RW read and write, W1C sticky flags cleared by writing 1, SC set/clear, S strobe, F reading has an effect, CAP reading the low byte captures.
- Timings in T-states are at 20 MHz, where a T-state is 50 ns, a 576-line frame 400,000 T-states and one line 640.
- The complete examples are in `examples/`, one folder per chapter, and run on the board. Each starts with `device zxspectrum48`, `org 0x8000` and `include "hw.inc"`, and runs in the boot ROM's program map (see "Programs" below). The specs in `docs/spec/` have every detail; the guide refers to them where it leaves something out.

---

## Memory

### Windows and pages

The Z80 addresses 64 KB. The MMU cuts that into **eight windows** of 8 KB, and maps each window onto an 8 KB **page** of the machine's memory:

**Table 1-3: The Windows**

| Window | Z80 addresses |
|--------|---------------|
| 0 | `0x0000`–`0x1FFF` |
| 1 | `0x2000`–`0x3FFF` |
| 2 | `0x4000`–`0x5FFF` |
| 3 | `0x6000`–`0x7FFF` |
| 4 | `0x8000`–`0x9FFF` |
| 5 | `0xA000`–`0xBFFF` |
| 6 | `0xC000`–`0xDFFF` |
| 7 | `0xE000`–`0xFFFF` |

A Z80 address has two fields:

**Table 1-4: Z80 Address Bits**

| Bits | Name | Meaning |
|------|------|---------|
| 15–13 | Window | The window, 0–7 |
| 12–0 | Offset | The byte in the window's page, `0x0000`–`0x1FFF` |

A page is a number from 0 to `0x3FF`:

**Table 1-5: The Pages**

| Page | What it is |
|------|------------|
| `0x000`–`0x0FF` | SRAM, the first 2 MB (every board) |
| `0x100`–`0x1FF` | SRAM, the second 2 MB (4 MB boards; on 2 MB boards these repeat the first 2 MB) |
| `0x3F8` | **The register page**: the hardware registers as memory (below) |
| `0x3FB` | **NONE**: reads `0xFF`, ignores writes |
| `0x3FC`–`0x3FF` | The boot ROM's four pages |
| Others | Reserved: read `0xFF`, ignore writes |

The same page can be in several windows at once.

### The read page and the write page

Each window has **two** page registers: a **read page**, for opcode fetches and reads, and a **write page**, for writes. Normally they are the same page, and setting the read page sets the write page too. Splitting them gives some useful tricks:

**Table 1-6: Uses of a Split Window**

| Read page | Write page | Use |
|-----------|------------|-----|
| SRAM | NONE | A read-only window: a ROM image kept in RAM, safe from stray writes |
| ROM | SRAM | Copy the ROM into RAM by copying the window onto itself |
| SRAM page A | SRAM page B | Read one buffer while writing another at the same addresses |
| ROM or SRAM | The register page | Code and tables are read while plain writes go to the registers |

### The MMU registers

The MMU's registers are in the system page (see "The Hardware Registers" below): registers `0x80`–`0x9F`, ports `0x8000`–`0x9F00`.

**Table 1-7: The MMU Registers**

| Window | Read page | Registers | Write page | Registers |
|--------|-----------|-----------|------------|-----------|
| 0 | MMU0 | `0x80`, `0x81` | MMU0W | `0x90`, `0x91` |
| 1 | MMU1 | `0x82`, `0x83` | MMU1W | `0x92`, `0x93` |
| 2 | MMU2 | `0x84`, `0x85` | MMU2W | `0x94`, `0x95` |
| 3 | MMU3 | `0x86`, `0x87` | MMU3W | `0x96`, `0x97` |
| 4 | MMU4 | `0x88`, `0x89` | MMU4W | `0x98`, `0x99` |
| 5 | MMU5 | `0x8A`, `0x8B` | MMU5W | `0x9A`, `0x9B` |
| 6 | MMU6 | `0x8C`, `0x8D` | MMU6W | `0x9C`, `0x9D` |
| 7 | MMU7 | `0x8E`, `0x8F` | MMU7W | `0x9E`, `0x9F` |

A page number has 10 bits, so it takes two registers, MMUn_0 and MMUn_1 (MMUnW_0 and MMUnW_1 for the write page):

**Table 1-8: Page Register Bytes**

| Word | Bits | Meaning |
|------|------|---------|
| MMUn_0 | 7–0 | Page bits 7–0. Held until MMUn_1 is written |
| MMUn_1 | 7–2 | Read 0; write 0 |
| MMUn_1 | 1–0 | Page bits 9–8. Writing commits the page |

The register page, `0x3F8`, is the two bytes `0xF8` and `0x03`, low byte first:

```asm
        DB      0xF8,0x03               ; page 0x3F8: MMUn_0, then MMUn_1
        DW      0x3F8                   ; the same two bytes
```

**Writing the high byte commits the page**, using the low byte written just before: a window never points at a half-changed page, even while code runs in it. So always write the low byte first. Through ports, with B the register and C the page `0x00`, `INC B` steps from one to the other:

```asm
; window 6 onto page HL
        ld      bc,MMU6_0_P             ; register 0x8C of page 0x00
        out     (c),l                   ; bits 7-0: held
        inc     b                       ; MMU6_1
        out     (c),h                   ; bits 9-8: the read and write pages change (38 T)
```

Committing a read page also sets the window's write page to the same page. To split a window, write MMUnW afterwards. The new page applies from the next memory access, including the next opcode fetch, so code can change the window it is running in, as long as the next instruction is at the same address in the new page.

### Physical addresses

The chipset does not use the MMU. The display, the sprites, the copper and the DMA engine read SRAM by **physical address**: a 22-bit byte address, from `0x000000` to `0x3FFFFF`, written into their 3-byte pointer registers. A physical address has two fields:

**Table 1-9: Physical Address Bits**

| Bits | Name | Meaning |
|------|------|---------|
| 21–13 | Page | The SRAM page, `0x000`–`0x1FF` |
| 12–0 | Offset | The byte in the page: the Z80 address's bits 12–0 (Table 1-4) |

So Z80 address `0xC010`, in window 6 showing page `0x020`, is physical `0x040010`. A pointer register takes it low byte first:

```asm
        DB      0x10,0x00,0x04          ; physical 0x040010: page 0x020, byte 0x0010
        D24     0x020*0x2000+0x0010     ; the same three bytes
```

A screen, a sprite image or a copper list can be anywhere in SRAM: the Z80 writes it through a window, then gives its physical address to the chipset.

### Example 1-1: One page, two windows

The program, `examples/system/windows.asm`, maps SRAM page `0x020` (physical `0x040000`) into windows 5 and 6, writes a string through window 6 and prints it from window 5: the same memory. Then it makes window 6 read-only, with NONE as its write page, and shows that a write there changes nothing.

```asm
; Example 1-1 (docs/guide/system.md): one page in two windows, then a
; read-only window. SRAM page 0x020 (physical 0x040000) goes into windows 5
; and 6. A string written through window 6 is printed through window 5:
; the same memory. Then window 6's write page becomes NONE, and a write
; through it changes nothing. Windows 5 and 6 get their own pages back
; before the program ends.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

PG_NONE equ     0x3FB                   ; reads 0xFF, ignores writes (memory spec, section 9.3)
PAGE    equ     0x020                   ; an SRAM page this program does not use
WIN5    equ     0xA000
WIN6    equ     0xC000

start:  ld      hl,PAGE
        ld      bc,MMU6_0_P             ; window 6's read page: byte 0 is held ...
        out     (c),l
        inc     b                       ; ... MMU6_1 commits it, and the write page too
        out     (c),h
        ld      bc,MMU5_0_P             ; the same page in window 5
        out     (c),l
        inc     b
        out     (c),h

        ld      hl,text                 ; write the string through window 6
        ld      de,WIN6
        ld      bc,TEXTLEN
        ldir
        ld      hl,s_read
        rst     0x18                    ; PUTS
        ld      hl,WIN5                 ; and print it from window 5
        rst     0x18

        ld      hl,PG_NONE              ; window 6: reads page 0x020, writes go nowhere
        ld      bc,MMU6W_0_P
        out     (c),l
        inc     b
        out     (c),h
        ld      a,'J'
        ld      (WIN6),a                ; ignored: "Hello" stays
        ld      hl,s_ro
        rst     0x18
        ld      hl,WIN5
        rst     0x18

        ld      hl,6                    ; windows 5 and 6 back to the program map
        ld      bc,MMU6_0_P             ; (committing a read page sets the write page)
        out     (c),l
        inc     b
        out     (c),h
        dec     l
        ld      bc,MMU5_0_P
        out     (c),l
        inc     b
        out     (c),h
        ret

text:   db      "Hello from page 020", 13, 10, 0
TEXTLEN equ     $ - text
s_read: db      13, 10, "Written via window 6, read via 5: ", 0
s_ro:   db      "Window 6 read-only, 'J' written:  ", 0
```

It prints:

```
Written via window 6, read via 5: Hello from page 020
Window 6 read-only, 'J' written:  Hello from page 020
```

---

## The Hardware Registers

Every register is **8 bits**. A wider value, a pointer or a count, sits in consecutive registers, **low byte first**: its bytes are named NAME0, NAME1 and so on. There are two ways to reach the registers: **I/O ports**, always there, and the **register page**, which shows them as memory once a window is mapped onto it.

### Ports: register and page

Every port address is **register : page**:

**Table 1-10: Port Address Bits**

| Bits | Name | Meaning |
|------|------|---------|
| 15–8 | Register | The register number, `0x00`–`0xFF` (B in `OUT (C),r`) |
| 7–0 | Page | The **I/O page**, `0x00`–`0xFF` (C in `OUT (C),r`) |

The I/O page says which block of registers the port reaches:

**Table 1-11: The I/O Pages**

| Low byte | High byte | Reaches |
|----------|-----------|---------|
| `0x00` | Register r | The **system page**: interrupts, timers, serial, keyboard and joysticks, the system registers, the MMU |
| `0x01` | `0x40`–`0xFF` | The interrupt pages (Chapter 2) |
| `0x02` | Register r | The debug unit |
| `0x10`–`0x13` | Register r | The **custom block**, the chipset (Table 1-12) |
| `0x1F`, `0x53`, `0x5B`, `0x62`, `0xFE` | Anything | The **low-byte-only ports**: Kempston, SERDATA, SDDATA, KBDATA and the Spectrum's port `0xFE` |
| Anything else | | Reserved: reads `0xFF`, writes are ignored |

The chipset's registers are numbered by **custom offset**, `0x000`–`0x3FF`, which spreads over the four custom pages:

**Table 1-12: Custom Offset Bits**

| Bits | Name | Meaning |
|------|------|---------|
| 9–8 | Page | The I/O page less `0x10`: 0–3 for pages `0x10`–`0x13` |
| 7–0 | Register | The register number in that page |

`OUT (C),r` and `IN r,(C)` put B on the high half of the address, so `LD BC,port` loads the register into B and the page into C. `hw.inc` names every port `NAME_P`. CPUSPEED is register `0x77` of page `0x00`; BGCOLOR is custom offset `0x004`, so register `0x04` of page `0x10`:

```asm
        DB      0x01,0x00,0x77          ; LD BC,0x7700: C = page 0x00, B = register 0x77
        ld      bc,CPUSPEED_P           ; the same three bytes
        DB      0x01,0x10,0x04          ; LD BC,0x0410: C = page 0x10, B = register 0x04
        ld      bc,BGCOLOR_P            ; the same three bytes
```

Reading and writing a register through its port:

```asm
        ld      bc,CPUSPEED_P           ; 0x7700: register 0x77 of page 0x00
        in      a,(c)                   ; read it                        (12 T)
        ld      a,2
        out     (c),a                   ; write it: 6.67 MHz             (12 T)
```

A wider register is written low byte first with `INC B` between the bytes:

```asm
        ld      bc,L0_BPL0PT_P          ; a 3-byte custom register
        out     (c),l                   ; bits 7-0
        inc     b
        out     (c),h                   ; bits 15-8
        inc     b
        out     (c),e                   ; bits 23-16
```

`IN A,(n)` puts A on the high half, so `LD A,register` then `IN A,(page)` reads a register too. `OUT (n),A` is no use on the pages, because A would be both the register number and the value; it works on the low-byte-only ports, as on a Spectrum (`OUT (0xFE),A` sets the border). `INIR` and `OTIR` count B down, so they suit the low-byte-only stream ports (`0x53`, `0x5B`, `0x62`), where B is only a count, and not the pages.

### The register page

Map MMU page `0x3F8` into a window and the registers appear as memory. A register's offset in the page is its port with the two bytes swapped:

**Table 1-13: Register Page Offset Bits**

| Bits | Name | Meaning |
|------|------|---------|
| 12–8 | Page | The I/O page, `0x00`–`0x13`; from `0x14` up, the palettes (Table 1-14) |
| 7–0 | Register | The register number in that page |

So CPUSPEED, port `0x7700`, is at offset `0x0077`, and BGCOLOR, port `0x0410`, at offset `0x1004`. The page holds:

**Table 1-14: The Register Page**

| Offset in the page | What |
|--------------------|------|
| `0x0000`–`0x00FF` | The system page: register r at r |
| `0x0100`–`0x0107` | KEYROW0–7, the keyboard rows (memory only) |
| `0x0140`–`0x01FF` | The interrupt pages |
| `0x0200`–`0x023C` | The debug unit |
| `0x1000`–`0x13FF` | The custom block: custom offset k at `0x1000` + k |
| `0x1400`–`0x1FFF` | The four palettes, 3 bytes an entry (blue, green, red) |

Through the register page, any instruction that reads or writes memory works on registers: `LD (nn),HL` writes a 2-byte register in one instruction, `LDIR` sets up a whole block from a table, and `SET` and `RES` change single bits. An access is a normal memory cycle, 3 T-states, against an `IN` or `OUT`'s 4, and the address needs no B and C.

The MMU registers are in the system page too, so the first mapping of the register page must be made through ports. After that a window changes with one `LD (nn),HL`, 16 T-states.

**Note:** opcode fetches from the register page read `0xFF`, which is `RST 38h`: a program that runs into it stops in the monitor's trap rather than doing something strange.

### The rules

1. **Each byte is written at once.** There is no latch: writing one byte of a wide register changes that byte only, straight away, so the hardware can see a value half written. Change the display's wide registers in the vertical blank, or from the copper at a set point on the screen.
2. **Three exceptions wait for their last byte.** An **MMU page** (and an interrupt page) commits on its high byte. A **colour** (a palette entry, or the background colour BGCOLOR) commits on its red byte, the third, so a colour on screen never shows half changed. Write these low byte first: `LD (nn),HL`, `LDIR`, or `OUT (C),r` with `INC B`; not `PUSH` or `LDDR`.
3. **Counters capture.** For a value the hardware changes by itself (a pointer the display walks, a timer's count), **reading the low byte captures the whole value**, and the higher bytes then read from the capture, so a value read low byte first is always whole. `LD HL,(nn)` through the register page reads two bytes in one instruction, safe from interrupts.
4. **Sticky flags are cleared by writing 1** (W1C). Writing 0 leaves a flag alone, so writing back the value read clears exactly the flags seen.
5. **Set/clear registers** (DMACON, INTENA0–2, SPRDMA) have SETCLR in bit 7: write the bits to change with SETCLR 1 to set them, 0 to clear them. Bits written as 0 are left alone. Don't read, change and write back.
6. **Strobes** act on any write, whatever the value: COPJMP1, for example. Two need a magic value: SYSRESET (`0xA5`) and WDKICK (`0x5A`).
7. **Reading changes nothing**, except reading a FIFO's data register (SERDATA, KBDATA), which takes a byte, and the captures.
8. **Unused bits read 0** and should be written 0. **Unused registers** read `0xFF` and ignore writes; nothing ever gives an error.

### Changing some bits of a register

Through the register page, the Z80's bit instructions work on registers directly:

```asm
        set     KEYCON_KXMAP_B,(ix+0)   ; IX = the register page's KEYCON
```

Through ports, read, change and write back:

```asm
        ld      bc,KEYCON_P
        in      a,(c)
        and     ~KEYCON_KXMAP_M         ; clear one bit
        out     (c),a
```

Neither suits a set/clear register (rule 5) or a register with sticky flags (rule 4), where writing back what was read has effects of its own.

---

## Sharing the Memory

The CPU and the chipset share the SRAM, but the Z80 **never waits** for it. Memory works in **slots** of 100 ns, two T-states at 20 MHz, each with five memory cycles of 20 ns:

**Table 1-15: The Memory Cycles of a Slot**

| Cycle | Belongs to |
|-------|------------|
| 0, 2 | The CPU. A cycle the CPU asks for is never given to anyone else |
| 1, 3 | The display: the layers and the sprites |
| 4 | Sound (later); meanwhile the free pool |

The **free pool**, the copper and the DMA engine, gets cycle 4 and every cycle its owner leaves. The Z80 uses at most one memory cycle in three T-states, so it leaves more than half of its own; the display leaves what its layers do not need. In all the free pool has at least about 47 MB/s, while the CPU always runs at full speed.

The **register page and the boot ROM** use no SRAM cycle at all: they are not SRAM. Neither do I/O accesses.

**DMACON** (custom `0x00C`, set/clear) turns the chipset's memory users on and off: the layers, sprites, copper and blitter each have a bit, with DMAEN over them all. Each chapter says which bits its unit needs. Appendix A has the cycles and the bandwidth in full.

---

## The System Control Registers

### Identifying the machine: SYSID, SYSVER and SYSCFG

**SYSID** reads `0x5A` ("Z") on every retro-z80. **SYSVER** is the FPGA build's version:

**Table 1-16: SYSVER Bits**

| Bits | Name | Meaning |
|------|------|---------|
| 7–4 | MAJOR | Major version |
| 3–0 | MINOR | Minor version |

**SYSCFG** describes the hardware:

**Table 1-17: SYSCFG Bits**

| Bits | Name | Meaning |
|------|------|---------|
| 7–2 | CHIPMB | SRAM size in MB: 2 or 4 |
| 1–0 | CPU | The CPU: 0 = Z80 |

A program that wants more than 2 MB checks CHIPMB first: on a 2 MB board pages `0x100`–`0x1FF` repeat pages `0x000`–`0x0FF`.

### Example 1-2: About this machine

The program, `examples/system/about.asm`, reads the system registers through ports and prints what they say.

```asm
; Example 1-2 (docs/guide/system.md): about this machine.
; Reads the system registers through ports and prints what they say: the
; machine's ID, the FPGA build, the SRAM size, why it was last reset, and
; the CPU speed. Then RET goes back to the monitor.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

PUTHEX  equ     0x06                    ; RST 28h functions (boot ROM spec, section 7.3)
PUTDEC  equ     0x08

start:  ld      hl,s_id
        rst     0x18                    ; PUTS
        ld      bc,SYSID_P              ; B = register 0x70, C = page 0x00
        in      a,(c)                   ; 0x5A, "Z"
        rst     0x28
        db      PUTHEX

        ld      hl,s_ver
        rst     0x18
        ld      bc,SYSVER_P
        in      a,(c)                   ; major in bits 7-4, minor in 3-0
        rst     0x28
        db      PUTHEX

        ld      hl,s_ram
        rst     0x18
        ld      bc,SYSCFG_P
        in      a,(c)
        rrca                            ; CHIPMB is bits 7-2
        rrca
        and     0x3F
        ld      l,a
        ld      h,0
        rst     0x28
        db      PUTDEC
        ld      hl,s_mb
        rst     0x18

        ld      hl,s_reset              ; RESETWHY: exactly one bit is set
        rst     0x18
        ld      bc,RESETWHY_P
        in      a,(c)
        ld      hl,causes
.cause: rra                             ; the lowest set bit picks the name
        jr      c,.found
        inc     hl
        inc     hl
        jr      .cause
.found: call    puts_at                 ; print the string HL points at

        ld      hl,s_cpu
        rst     0x18
        ld      bc,CPUSPEED_P
        in      a,(c)
        ld      hl,s_spec
        bit     3,a                     ; SPECTRUM: 3.57 MHz
        jr      nz,.speed
        and     CPUSPEED_DIV_M          ; 20 MHz / (DIV + 1)
        add     a,a
        ld      e,a
        ld      d,0
        ld      hl,speeds
        add     hl,de
        call    puts_at
        ld      hl,s_mhz
.speed: rst     0x18
        ret                             ; RET goes to the ROM's EXIT

puts_at:                                ; print the string whose address is at (HL)
        ld      a,(hl)
        inc     hl
        ld      h,(hl)
        ld      l,a
        rst     0x18
        ret

s_id:   db      13, 10, "Machine ID   ", 0
s_ver:  db      13, 10, "FPGA build   ", 0
s_ram:  db      13, 10, "SRAM         ", 0
s_mb:   db      " MB", 0
s_reset:db      13, 10, "Last reset   ", 0
s_cpu:  db      13, 10, "CPU          ", 0
s_mhz:  db      " MHz", 13, 10, 0
s_spec: db      "3.57 MHz (Spectrum)", 13, 10, 0

causes: dw      c0, c1, c2, c3, c4, c5, c6, c7
c0:     db      "power-on", 0
c1:     db      "watchdog", 0
c2:     db      "reset button", 0
c3:     db      "software (SYSRESET)", 0
c4:     db      "USB RESET", 0
c5:     db      "USB UPLOAD", 0
c6:     db      "keyboard", 0
c7:     db      "halted", 0

speeds: dw      v0, v1, v2, v3, v4, v5, v6, v7
v0:     db      "20", 0
v1:     db      "10", 0
v2:     db      "6.67", 0
v3:     db      "5", 0
v4:     db      "4", 0
v5:     db      "3.33", 0
v6:     db      "2.86", 0
v7:     db      "2.5", 0
```

On a KS2, uploaded from VS Code, it prints:

```
Machine ID   5A
FPGA build   01
SRAM         2 MB
Last reset   USB UPLOAD
CPU          20 MHz
```

### Why was I reset? RESETWHY

Exactly one bit of RESETWHY is set, for the cause of the last reset (Table 1-24, in "Reset and the Boot ROM"):

**Table 1-18: RESETWHY Bits**

| Bits | Name | Meaning |
|------|------|---------|
| 7 | HALTED | Never set |
| 6 | KEYBOARD | Not set in this version |
| 5 | UPLOAD | The UPLOAD command from the PC |
| 4 | USB | The RESET command from the PC |
| 3 | SOFTWARE | `0xA5` written to SYSRESET |
| 2 | BUTTON | The reset button |
| 1 | WATCHDOG | The watchdog was not kicked in time |
| 0 | POWER | Power-on: the SRAM holds random values |

The usual use is a **warm start**: after anything but power-on the SRAM still holds what the program left, so a program can keep its state, a high-score table say, and pick it up again:

```asm
        ld      bc,RESETWHY_P
        in      a,(c)
        and     RESETWHY_POWER_M
        jr      nz,cold                 ; power-on: SRAM is random
        ld      a,(magic)               ; warm: is our data still there?
        cp      0xA7
        jr      z,warm
cold:   ; ... set everything up, then:
        ld      a,0xA7
        ld      (magic),a
```

### The CPU's speed: CPUSPEED

**Table 1-19: CPUSPEED Bits**

| Bits | Name | Meaning |
|------|------|---------|
| 7–4 | – | Read 0 |
| 3 | SPECTRUM | 1 = 3.57 MHz, whatever DIV holds |
| 2–0 | DIV | 20 MHz ÷ (DIV + 1) |

**Table 1-20: CPUSPEED Values**

| CPUSPEED | Speed |
|----------|-------|
| `0x00` (after reset) | 20 MHz |
| `0x01` | 10 MHz |
| `0x02` | 6.67 MHz |
| `0x03` | 5 MHz |
| `0x04` | 4 MHz |
| `0x05` | 3.33 MHz |
| `0x06` | 2.86 MHz |
| `0x07` | 2.5 MHz |
| `0x08` | 3.57 MHz, close to a Spectrum's 3.5 MHz |

The new speed starts at the next machine cycle. At every speed the Z80 still never waits for memory, and the ROM calls work the same (their waits use TIME, not loops). The SPECTRUM speed is for code that times itself with loops: beeper tones and delays sound and run as on a Spectrum, 2% fast.

```asm
        ld      bc,CPUSPEED_P
        ld      a,CPUSPEED_SPECTRUM_M
        out     (c),a                   ; 3.57 MHz from the next M-cycle
```

### Resetting from software: SYSRESET

Writing `0xA5` (`SYSRESET_MAGIC`) to SYSRESET gives a full reset, with RESETWHY.SOFTWARE set. Other values are ignored, so a stray write cannot reset the machine.

### The buttons: SYSBTN

**Table 1-21: The Buttons**

| Button | Does |
|--------|------|
| Reset | A full reset (RESETWHY.BUTTON) |
| Multiface | The NMI: a running program stops in the monitor |
| DivMMC | Nothing by itself. The boot ROM uses it as the "monitor" button at reset |

SYSBTN shows two of them, debounced, so a program can use them as two more keys:

**Table 1-22: SYSBTN Bits**

| Bits | Name | Meaning |
|------|------|---------|
| 7–2 | – | Read 0 |
| 1 | DIVMMC | 1 = the DivMMC button is held |
| 0 | MULTIFACE | 1 = the Multiface button is held |

### Writable boot ROM: SYSCON

**Table 1-23: SYSCON Bits**

| Bits | Name | Meaning |
|------|------|---------|
| 7–3 | – | Read 0 |
| 2 | ROMLOCK | Writing 1 locks ROMWE off until power-on; writing 0 does nothing |
| 1 | ROMWE | 1 = the boot ROM's pages are writable |
| 0 | – | Read 0 |

**SYSCON.ROMWE** makes the boot ROM's pages writable, through any window whose write page is a ROM page, so a new ROM can be tried without rebuilding the FPGA: write it in, then reset. It lasts until the FPGA is reloaded. **SYSCON.ROMLOCK** locks ROMWE off until the next power-on; the boot ROM sets it at power-on, unless D is held, so an everyday program cannot change the ROM by accident. Writing 0 to ROMLOCK does nothing.

---

## Reset and the Boot ROM

### What resets the computer

**Table 1-24: Reset Sources**

| Source | RESETWHY bit |
|--------|--------------|
| Power-on: the FPGA has just loaded the design | POWER (0) |
| The watchdog, not kicked in time (Chapter 2) | WATCHDOG (1) |
| The reset button | BUTTON (2) |
| Software: `0xA5` written to SYSRESET | SOFTWARE (3) |
| The PC: the RESET control command on the USB link | USB (4) |
| The PC: the UPLOAD command (reset, then wait for a program) | UPLOAD (5) |

RESETWHY tells a program which one it was: exactly one bit is set.

### What a reset does

Every source gives the same full reset. The Z80 starts at `0x0000` at 20 MHz, the MMU goes back to its reset map, and every chipset and system register goes back to its reset value: the display shows only the background colour, the sprites, copper and DMA engine are stopped, every interrupt is off. Some things survive:

- **The SRAM keeps its contents**, after anything but power-on. A program can keep data across a reset, and the monitor can look at what a crashed program left. After power-on the SRAM holds random values, so check RESETWHY.POWER before trusting it.
- **The palettes** keep their colours.
- **TIME**, the microsecond counter (Chapter 2), keeps counting.
- **The USB link** stays up: a terminal on the PC stays connected.

The Z80 has no instruction that resets the hardware without the CPU. A program that wants a clean machine sets the registers it uses, or writes SYSRESET.

### The reset map

**Table 1-25: The Reset Map**

| Window | Page |
|--------|------|
| 0, 1 | Boot ROM pages 0 and 1 |
| 2–7 | SRAM pages 0–5 |

So the Z80 starts in the ROM, with `0x0038` and `0x0066` in it too, and 48 KB of SRAM above, like a Spectrum 48K. The boot ROM changes the map before it starts a program (below).

### The boot ROM

The boot ROM is 32 KB in four MMU pages, `0x3FC`–`0x3FF`, part of the FPGA's design. Reading it uses no SRAM cycle. It ignores writes unless SYSCON.ROMWE is set (see "Writable boot ROM: SYSCON" above). After a reset it:

1. tests the SRAM, at power-on only, showing its progress as the background colour (a red screen with white stripes is a failed test; the number of stripes says which);
2. sets up the boot console: 80 × 30 characters on layer L0;
3. looks at the keys held: **U** waits for a program over USB, **M** or the DivMMC button starts the monitor, **D** at power-on leaves the boot ROM writable;
4. after an UPLOAD reset, waits for a program from the PC and starts it;
5. otherwise starts the **monitor**.

(Starting from an SD card and a resident BBC BASIC come later.) The monitor is on the screen and on the USB console at once; `H` lists its commands, and the boot ROM spec covers it in full.

---

## Programs

### The program map

When the boot ROM starts a program, the MMU holds the **program map**:

**Table 1-26: The Program Map**

| Window | Read page | Write page |
|--------|-----------|------------|
| 0 | Boot ROM page 0 | The same (it ignores writes) |
| 1–7 | SRAM pages 1–7 | The same |

**Window n holds SRAM page n**, so a Z80 address from `0x2000` to `0xFFFF` is also its **physical address**: `0x8000` is physical `0x008000`. A program can give the chipset the address of a screen or a copper list in its own memory as it stands. SRAM page 0, under the ROM, and every page from 8 up are free for the program to map where it likes, except the pages the boot ROM keeps for itself, `0x0F8`–`0x0FF` (physical `0x1F0000`–`0x1FFFFF`: its console, font and workspace).

### The state at the first instruction

**Table 1-27: The State at a Program's First Instruction**

| Item | State |
|------|-------|
| PC | The program's entry point |
| SP | `0xFFFE`, holding `0x0040`, the ROM's EXIT: a `RET` from the entry point ends the program |
| Registers | All 0 |
| Interrupts | Disabled (DI), IM 2, with the ROM's own table; every source off. A program that wants interrupts sets up its own (Chapter 2) |
| CPU speed | 20 MHz |
| Display | Layer L0 is the boot console; the other layers and the sprites are off; the background is black |
| Copper, DMA engine, timers | Stopped |
| PS/2 keyboard | Its FIFO on, its interrupt off |
| Serial link | On, dropping output when the PC is not reading |

### Ending a program

**Table 1-28: Ways to End a Program**

| How | Then |
|-----|------|
| `RET` from the entry point (SP back at `0xFFFE`) | `Program ended.`; the monitor shows the registers, and `G` runs the program again |
| `JP 0x0040`, or `RST 28h` function EXIT (`0x0F`) | The same, from anywhere, whatever SP holds |
| `RST 30h` | `Break at` the address; `G` carries on after it |
| SYSRESET, or `RST 28h` function RESET | A full reset |

The Multiface button, and BREAK from the PC, stop a running program in the monitor too; `G` carries on.

### The ROM calls

The boot ROM offers a small set of calls through `RST` instructions, as a Spectrum's ROM does:

**Table 1-29: The ROM Calls**

| Call | Does |
|------|------|
| `RST 08h` PUTC | Prints the character in A (13 is back to column 0, 10 down a line) |
| `RST 10h` GETC | Waits for a key; A = its code |
| `RST 18h` PUTS | Prints the string at HL, up to a 0 byte |
| `RST 20h` POLLC | A key if one is waiting (NZ), or Z |
| `RST 28h` CALL | A numbered function, its number in the byte after the `RST` |
| `RST 30h` BREAK | Into the monitor |

`RST 28h`'s functions include PUTHEX (`0x06`, A as two hex digits), PUTHEX16 (`0x07`), PUTDEC (`0x08`, HL in decimal), GETLINE (`0x05`), CLS (`0x09`), SETPOS (`0x0A`) and EXIT (`0x0F`). A call keeps every register except the ones it returns, works with interrupts on, and needs up to 48 bytes of stack. Its strings and buffers may be anywhere in `0x2000`–`0xFFFF`, under any mapping of windows 1–7, the register page included. The boot ROM spec, section 7, lists them all.

```asm
        ld      hl,hello
        rst     0x18                    ; PUTS
        ld      a,0x5A
        rst     0x28
        db      0x06                    ; PUTHEX: prints 5A
        ret
hello:  db      "Hello, ", 0
```

### Building and loading

A program is assembled with sjasmplus into a raw binary, then wrapped by `tools/rlink.py` into a **program image** (`.rimg`): a short header with its load address, entry point and checksums, then the code. The loader checks the header before it runs anything.

```
sjasmplus -Ifirmware/include --sld=build/game.sld --raw=build/game.bin game.asm
python tools/rlink.py image --machine z80 --load 8000 -o build/game.rimg build/game.bin
```

Then, from the PC:

- **VS Code**, with the retro-z80 extension: the `retro-z80-build` task does both steps, and a launch configuration uploads the image and stops at its entry point, with breakpoints, stepping and the registers at source level (the `.sld` file). The extension's README says how.
- **`rlink.py upload`** sends an image straight to the board and runs it, with no debugger.

The upload resets the board (UPLOAD) and the boot ROM's loader takes the program, so a program always starts from a clean machine.

---

## Putting Together a Program

The complete examples in the other chapters start from the program map and share one set-up. This section builds it step by step, as Example 1-3 does: the program moves the stack, maps the register page into window 7, works on registers with ordinary loads, and ends.

### Step 1: Start in the program map

Begin the file as every example does:

```asm
        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"
```

The program is **loaded at `0x8000`**, so its Z80 addresses are its physical addresses (window n holds SRAM page n, Table 1-26). It starts with interrupts disabled, at 20 MHz, with the boot console on layer L0 (Table 1-27).

### Step 2: Move the stack out of window 7

The boot ROM leaves SP at `0xFFFE`, in window 7. Window 7 is about to become the register page, and a stack there would write to registers. So move the stack first, to just below window 7:

```asm
start:  ld      sp,0xE000               ; the stack below window 7, at the top of window 6
```

The first push goes to `0xDFFF`, the top of window 6. The ROM's EXIT address, `0x0040`, stays behind at `0xFFFE`, so from here `RET` from the entry point no longer ends the program (Step 5).

### Step 3: Map the register page through ports

The MMU registers are in the system page, so the first mapping of the register page must be made through ports. Write the low byte, then the high byte, which commits the page (Table 1-8):

```asm
PG_REGS equ     0x3F8                   ; the register page

        ld      hl,PG_REGS
        ld      bc,MMU7_0_P             ; the first mapping needs ports
        out     (c),l
        inc     b
        out     (c),h                   ; from here, 0xE000-0xFFFF are the registers
```

Committing the read page sets the write page too, so reads and writes in window 7 both reach the registers. Then name the parts of the page (Table 1-14):

```asm
REGS    equ     0xE000                  ; the register page, in window 7
SREG    equ     REGS+REGS_SYSTEM        ; 0xE000: system register r at SREG + r
CREG    equ     REGS+REGS_CUSTOM        ; 0xF000: custom offset k at CREG + k
PREG    equ     REGS+REGS_PALETTE       ; 0xF400: palette p at PREG + p * REGS_PAL_SPAN
```

So custom offset k is at `CREG + k` and system register r at `SREG + r`. (Example 1-3 uses no palette, so it leaves PREG out.)

### Step 4: Use the registers as memory

Now ordinary loads reach the registers:

```asm
        ld      a,(SREG+SYSID)          ; a register read with LD
        ld      hl,0x8000               ; BGCOLOR: blue 0x00, green 0x80 ...
        ld      (CREG+BGCOLOR),hl       ; (held for the red byte)
        ld      a,0xFF
        ld      (CREG+BGCOLOR+2),a      ; ... red 0xFF: the colour changes, whole
```

The rules of "The Hardware Registers" still hold: a colour commits on its red byte, and a sticky flag such as VIDSTAT.VBLANK is cleared by writing 1. Use **ports** where the register page is not yet mapped, and in code meant to work whatever the program has in its windows.

### Step 5: End the program

Give window 7 its SRAM page back, with one `LD (nn),HL` through the register page itself, then end with `JP 0x0040`, the ROM's EXIT:

```asm
EXIT    equ     0x0040                  ; the ROM's EXIT: back to the monitor, whatever SP holds

        ld      hl,7
        ld      (SREG+MMU7),hl          ; window 7 back to SRAM page 7, in one instruction
        jp      EXIT
```

`RET` would need the stack the program moved, so a program that moves the stack, or keeps window 7 as the register page, ends with `JP 0x0040`, not `RET`.

### Example 1-3: The registers as memory

The whole program, `examples/system/regpage.asm`, puts the steps together. Between Steps 4 and 5 it waits 100 frames on the vertical blank flag, VIDSTAT.VBLANK, so the colour can be seen.

```asm
; Example 1-3 (docs/guide/system.md): the registers as memory.
; Moves the stack out of window 7, maps the register page (MMU page 0x3F8)
; there, and then works on registers with ordinary loads: it reads SYSID,
; sets the background colour to orange (blue and green first, red last),
; and waits two seconds, 100 frames of VIDSTAT.VBLANK. Then window 7 gets
; SRAM page 7 back, through the register page itself, and JP 0x0040 (the
; ROM's EXIT) ends the program.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

PUTHEX  equ     0x06                    ; RST 28h function: print A as two hex digits
EXIT    equ     0x0040                  ; the ROM's EXIT: back to the monitor, whatever SP holds
PG_REGS equ     0x3F8                   ; the register page

REGS    equ     0xE000                  ; the register page, in window 7
SREG    equ     REGS+REGS_SYSTEM        ; 0xE000: system register r at SREG + r
CREG    equ     REGS+REGS_CUSTOM        ; 0xF000: custom offset k at CREG + k

start:  ld      sp,0xE000               ; the stack below window 7, at the top of window 6
        ld      hl,PG_REGS
        ld      bc,MMU7_0_P             ; the first mapping needs ports
        out     (c),l
        inc     b
        out     (c),h                   ; from here, 0xE000-0xFFFF are the registers

        ld      hl,s_id
        rst     0x18                    ; PUTS
        ld      a,(SREG+SYSID)          ; a register read with LD
        rst     0x28
        db      PUTHEX

        ld      hl,0x8000               ; BGCOLOR: blue 0x00, green 0x80 ...
        ld      (CREG+BGCOLOR),hl       ; (held for the red byte)
        ld      a,0xFF
        ld      (CREG+BGCOLOR+2),a      ; ... red 0xFF: the colour changes, whole

        ld      b,100                   ; 100 frames: 2 seconds
.frame: ld      a,VIDSTAT_VBLANK_M
        ld      (CREG+VIDSTAT),a        ; a sticky flag: writing 1 clears it
.wait:  ld      a,(CREG+VIDSTAT)
        and     VIDSTAT_VBLANK_M        ; set again at the next frame's start
        jr      z,.wait
        djnz    .frame

        ld      hl,7
        ld      (SREG+MMU7),hl          ; window 7 back to SRAM page 7, in one instruction
        jp      EXIT

s_id:   db      13, 10, "SYSID through the register page: ", 0
```

The border round the console turns orange for two seconds, then the monitor is back.

---

## Summary of System Control Registers

All are registers of page `0x00`: the port is the register number then `0x00` (Table 1-10), and the offset in the register page is the register number.

**Table 1-30: System Control Registers**

| Name | Register | Port | Access | Function |
|------|----------|------|--------|----------|
| SYSID | `0x70` | `0x7000` | R | `0x5A` ("Z") |
| SYSVER | `0x71` | `0x7100` | R | FPGA build: MAJOR (7–4), MINOR (3–0) |
| SYSCFG | `0x72` | `0x7200` | R | CHIPMB (7–2): SRAM in MB. CPU (1–0): 0 = Z80 |
| RESETWHY | `0x73` | `0x7300` | R | HALTED (7), KEYBOARD (6), UPLOAD (5), USB (4), SOFTWARE (3), BUTTON (2), WATCHDOG (1), POWER (0); one bit set |
| SYSCON | `0x74` | `0x7400` | RW | ROMLOCK (2), ROMWE (1) |
| SYSRESET | `0x75` | `0x7500` | W (S) | `0xA5` resets |
| SYSBTN | `0x76` | `0x7600` | R | DIVMMC (1), MULTIFACE (0), 1 = held |
| CPUSPEED | `0x77` | `0x7700` | RW | SPECTRUM (3): 3.57 MHz. DIV (2–0): 20 MHz ÷ (DIV + 1) |
| MMUn_0 | `0x80` + 2n | `0x8000` + `0x200` × n | RW | Window n's read page bits 7–0; held until MMUn_1 is written |
| MMUn_1 | `0x81` + 2n | `0x8100` + `0x200` × n | RW | Bits 7–2 read 0. Bits 1–0: read page bits 9–8; writing commits the read page and sets the write page to it |
| MMUnW_0 | `0x90` + 2n | `0x9000` + `0x200` × n | RW | Window n's write page bits 7–0; held until MMUnW_1 is written |
| MMUnW_1 | `0x91` + 2n | `0x9100` + `0x200` × n | RW | Bits 7–2 read 0. Bits 1–0: write page bits 9–8; writing commits the write page only |

n is the window, 0–7 (Table 1-7). Reading a page register gives the committed page.

Registers `0x78`–`0x7B` are the I2C master, for the real-time clock and the display's DDC; the system spec, section 7, describes it.

### State after reset

SYSCON's ROMWE is clear (ROMLOCK keeps its value until power-on), CPUSPEED is `0x00` (20 MHz), and the MMU holds the reset map. The boot ROM then sets the program map before it starts a program.

### Equates in hw.inc

**Table 1-31: Equates in hw.inc**

| Equate | Value |
|--------|-------|
| `SYSID_P` … `CPUSPEED_P`, `MMU0_0_P` … `MMU7W_1_P` | Each register's port |
| `SYSID` … `CPUSPEED`, `MMU7`, `MMU7_0`, `MMU7_1` (and the others) | Register numbers, so `SREG+SYSID` and `SREG+MMU7` in the register page |
| `NAME_B`, `NAME_W`, `NAME_M` | A field's lowest bit, width and mask, for every field (`KEYCON_KXMAP_B`, `VIDSTAT_VBLANK_M`) |
| `SYSVER_MAJOR_M`, `SYSVER_MINOR_M` | `0xF0`, `0x0F` |
| `SYSCFG_CHIPMB_M`, `SYSCFG_CPU_M` | `0xFC`, `0x03` |
| `RESETWHY_POWER_M` … `RESETWHY_HALTED_M` | `0x01` … `0x80`: each cause's bit |
| `SYSCON_ROMWE_M`, `SYSCON_ROMLOCK_M` | `0x02`, `0x04` |
| `SYSBTN_MULTIFACE_M`, `SYSBTN_DIVMMC_M` | `0x01`, `0x02` |
| `CPUSPEED_DIV_M`, `CPUSPEED_SPECTRUM_M` | `0x07`, `0x08` |
| `MMU_PAGE_M`, `MMUW_PAGE_M` | `0x3FF`: a page number's 10 bits |
| `SYSRESET_MAGIC` | `0xA5` |
| `REGS_SYSTEM`, `REGS_CUSTOM`, `REGS_PALETTE`, `REGS_PAL_SPAN` | `0x0000`, `0x1000`, `0x1400`, `0x300`: offsets in the register page |
| `SYSPAGE`, `CUSTPAGE` | `0x00`, `0x10`: the I/O pages |

---

## Chapter Summary

- The Z80 sees 64 KB as eight 8 KB windows; the MMU maps each onto any page: SRAM, the boot ROM, the register page, or NONE. Each window has a read page and a write page. Page registers commit on their high byte.
- The chipset uses 22-bit physical addresses. In the program map a Z80 address in `0x2000`–`0xFFFF` is its own physical address.
- Every register is a byte, wider values low byte first, written at once. Ports are register : page; the register page shows the same registers as memory.
- The Z80 never waits for memory; the chipset takes its own cycles and what the CPU leaves.
- A reset keeps the SRAM (except at power-on); RESETWHY says why it happened.
- The boot ROM starts the monitor or a program from the PC; a program ends with `RET`, `JP 0x0040` or `RST 30h`, and prints with the ROM's calls.
