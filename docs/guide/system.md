# Chapter 1: Introduction and System Control

## About retro-z80

retro-z80 is a Z80 home computer built in the FPGA of a ZX Spectrum Next. The Z80 runs at 20 MHz and never waits for memory. Around it is a chipset in the style of the Amiga's: layers of bitmaps and tile maps, sprites, a copper, and a DMA engine with a blitter, all reading the same SRAM as the CPU, on their own share of the memory cycles. An MMU gives the Z80 its 64 KB as eight 8 KB windows onto 4 MB of memory. A boot ROM starts the machine, offers a monitor, and loads programs from a PC over USB.

It is also a Spectrum at heart: port `0xFE` reads the keyboard and sets the border as a Spectrum's does, a Kempston joystick reads at port `0x1F`, and a Spectrum screen can be shown as it is.

This chapter is the base the others build on. It covers:

- the machine at a glance, and the other chapters;
- memory: the windows, the MMU, pages and physical addresses;
- the hardware registers, and how the Z80 reaches them through ports and through the register page;
- how memory is shared between the CPU and the chipset;
- reset and the boot ROM;
- the environment a program starts in, how it ends, and how it is built and loaded;
- the system control registers: identification, the cause of a reset, the CPU's speed, the buttons;
- the set-up the guide's examples use.

### The Machine at a Glance

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

### Conventions in This Guide

- Examples are Z80 assembly language for **sjasmplus**, starting with `include "hw.inc"` (in `firmware/include/`). `hw.inc` is made from the one register list, `fpga/regmap.def`, so its names are the specs' names.
- Numbers are hexadecimal when they start with `0x`, decimal otherwise. Bits are numbered from 0, the lowest.
- Register access codes: R read only, W write only, RW read and write, W1C sticky flags cleared by writing 1, SC set/clear, S strobe, F reading has an effect, CAP reading the low byte captures.
- Timings in T-states are at 20 MHz, where a T-state is 50 ns, a 576-line frame 400,000 T-states and one line 640.
- The complete examples are in `examples/`, one folder per chapter, and run on the board. The specs in `docs/spec/` have every detail; the guide refers to them where it leaves something out.

---

## Memory

### Windows and pages

The Z80 addresses 64 KB. The MMU cuts that into **eight windows** of 8 KB, and maps each window onto an 8 KB **page** of the machine's memory:

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

Address bits 15–13 pick the window and bits 12–0 the byte in its page. A page is a number from 0 to `0x3FF`:

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

| Read page | Write page | Use |
|-----------|------------|-----|
| SRAM | NONE | A read-only window: a ROM image kept in RAM, safe from stray writes |
| ROM | SRAM | Copy the ROM into RAM by copying the window onto itself |
| SRAM page A | SRAM page B | Read one buffer while writing another at the same addresses |
| ROM or SRAM | The register page | Code and tables are read while plain writes go to the registers |

### The MMU registers

The MMU's registers are in the system page (see "The Hardware Registers" below): registers `0x80`–`0x9F`, ports `0x8000`–`0x9F00`.

| Window | Read page | Write page |
|--------|-----------|------------|
| n (0–7) | MMUn: registers `0x80` + 2n (bits 7–0) and `0x81` + 2n (bits 9–8) | MMUnW: registers `0x90` + 2n and `0x91` + 2n |

A page number has 10 bits, so it takes two registers. **Writing the high byte commits the page**, using the low byte written just before: a window never points at a half-changed page, even while code runs in it. So always write the low byte first. Through ports, with B the register and C the page `0x00`, `INC B` steps from one to the other:

```asm
; window 6 onto page HL
        ld      bc,MMU6_0_P             ; register 0x8C of page 0x00
        out     (c),l                   ; bits 7-0: held
        inc     b                       ; MMU6_1
        out     (c),h                   ; bits 9-8: the read and write pages change (38 T)
```

Committing a read page also sets the window's write page to the same page. To split a window, write MMUnW afterwards. The new page applies from the next memory access, including the next opcode fetch, so code can change the window it is running in, as long as the next instruction is at the same address in the new page.

### Physical addresses

The chipset does not use the MMU. The display, the sprites, the copper and the DMA engine read SRAM by **physical address**: a 22-bit byte address, from `0x000000` to `0x3FFFFF`, written into their 3-byte pointer registers. A page's first byte is at page × `0x2000`, so:

| | |
|-|-|
| Physical address of Z80 address a, in a window showing page p | p × `0x2000` + (a and `0x1FFF`) |
| Page holding physical address x | x ÷ `0x2000` |

A screen, a sprite image or a copper list can be anywhere in SRAM: the Z80 writes it through a window, then gives its physical address to the chipset.

### Example 1-2: One page, two windows

The program maps SRAM page `0x020` (physical `0x040000`) into windows 5 and 6, writes a string through window 6 and prints it from window 5: the same memory. Then it makes window 6 read-only, with NONE as its write page, and shows that a write there changes nothing.

```asm
; Example 1-2: one page in two windows, then a read-only window (examples/system/windows.asm)
        org     0x8000
        include "hw.inc"

PG_NONE equ     0x3FB                   ; reads 0xFF, ignores writes
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

Every port address is **register : page**: the high byte is the register number and the low byte the **I/O page**.

| Low byte | High byte | Reaches |
|----------|-----------|---------|
| `0x00` | Register r | The **system page**: interrupts, timers, serial, keyboard and joysticks, the system registers, the MMU |
| `0x01` | `0x40`–`0xFF` | The interrupt pages (Chapter 2) |
| `0x02` | Register r | The debug unit |
| `0x10`–`0x13` | Register r | The **custom block**, the chipset: custom offset (page − `0x10`) × 256 + r |
| `0x1F`, `0x53`, `0x5B`, `0x62`, `0xFE` | Anything | The **low-byte-only ports**: Kempston, SERDATA, SDDATA, KBDATA and the Spectrum's port `0xFE` |
| Anything else | | Reserved: reads `0xFF`, writes are ignored |

`OUT (C),r` and `IN r,(C)` put B on the high half of the address, so `LD BC,port` loads the register into B and the page into C. `hw.inc` names every port `NAME_P`:

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

Map MMU page `0x3F8` into a window and the registers appear as memory. Register r of I/O page p is at offset p × 256 + r in the page, the port with its two bytes swapped:

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

### Example 1-3: The registers as memory

The program moves the stack out of window 7 (where the boot ROM put it), maps the register page there, and then uses ordinary loads: it reads SYSID, sets the background colour to orange, blue and green first and red last, waits 100 frames on the vertical blank flag, VIDSTAT.VBLANK, and gives window 7 its SRAM page back with one `LD (nn),HL`.

```asm
; Example 1-3: the registers as memory (examples/system/regpage.asm)
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

The border round the console turns orange for two seconds, then the monitor is back. `JP 0x0040` ends the program, because `RET` would need the stack the program moved.

---

## Sharing the Memory

The CPU and the chipset share the SRAM, but the Z80 **never waits** for it. Memory works in **slots** of 100 ns, two T-states at 20 MHz, each with five memory cycles of 20 ns:

| Cycle | Belongs to |
|-------|------------|
| 0, 2 | The CPU. A cycle the CPU asks for is never given to anyone else |
| 1, 3 | The display: the layers and the sprites |
| 4 | Sound (later); meanwhile the free pool |

The **free pool**, the copper and the DMA engine, gets cycle 4 and every cycle its owner leaves. The Z80 uses at most one memory cycle in three T-states, so it leaves more than half of its own; the display leaves what its layers do not need. In all the free pool has at least about 47 MB/s, while the CPU always runs at full speed.

The **register page and the boot ROM** use no SRAM cycle at all: they are not SRAM. Neither do I/O accesses.

**DMACON** (custom `0x00C`, set/clear) turns the chipset's memory users on and off: the layers, sprites, copper and blitter each have a bit, with DMAEN over them all. Each chapter says which bits its unit needs. Appendix A has the cycles and the bandwidth in full.

---

## Reset and the Boot ROM

### What resets the computer

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

| Window | Page |
|--------|------|
| 0, 1 | Boot ROM pages 0 and 1 |
| 2–7 | SRAM pages 0–5 |

So the Z80 starts in the ROM, with `0x0038` and `0x0066` in it too, and 48 KB of SRAM above, like a Spectrum 48K. The boot ROM changes the map before it starts a program (below).

### The boot ROM

The boot ROM is 32 KB in four MMU pages, `0x3FC`–`0x3FF`, part of the FPGA's design. Reading it uses no SRAM cycle. It ignores writes unless SYSCON.ROMWE is set (see "Writable boot ROM" below). After a reset it:

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

| Window | Read page | Write page |
|--------|-----------|------------|
| 0 | Boot ROM page 0 | The same (it ignores writes) |
| 1–7 | SRAM pages 1–7 | The same |

**Window n holds SRAM page n**, so a Z80 address from `0x2000` to `0xFFFF` is also its **physical address**: `0x8000` is physical `0x008000`. A program can give the chipset the address of a screen or a copper list in its own memory as it stands. SRAM page 0, under the ROM, and every page from 8 up are free for the program to map where it likes, except the pages the boot ROM keeps for itself, `0x0F8`–`0x0FF` (physical `0x1F0000`–`0x1FFFFF`: its console, font and workspace).

### The state at the first instruction

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

| How | Then |
|-----|------|
| `RET` from the entry point (SP back at `0xFFFE`) | `Program ended.`; the monitor shows the registers, and `G` runs the program again |
| `JP 0x0040`, or `RST 28h` function EXIT (`0x0F`) | The same, from anywhere, whatever SP holds |
| `RST 30h` | `Break at` the address; `G` carries on after it |
| SYSRESET, or `RST 28h` function RESET | A full reset |

The Multiface button, and BREAK from the PC, stop a running program in the monitor too; `G` carries on.

### The ROM calls

The boot ROM offers a small set of calls through `RST` instructions, as a Spectrum's ROM does:

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

## The System Control Registers

### Identifying the machine: SYSID, SYSVER and SYSCFG

**SYSID** reads `0x5A` ("Z") on every retro-z80. **SYSVER** is the FPGA build's version, major in bits 7–4 and minor in bits 3–0. **SYSCFG** describes the hardware: bits 1–0 the CPU (0 for the Z80) and bits 7–2 **CHIPMB**, the SRAM size in MB, 2 or 4. A program that wants more than 2 MB checks CHIPMB first: on a 2 MB board pages `0x100`–`0x1FF` repeat pages `0x000`–`0x0FF`.

### Example 1-1: About this machine

The program reads the system registers through ports and prints what they say.

```asm
; Example 1-1: about this machine (examples/system/about.asm)
        org     0x8000
        include "hw.inc"

PUTHEX  equ     0x06                    ; RST 28h functions
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

Exactly one bit of RESETWHY is set, for the cause of the last reset: POWER (0), WATCHDOG (1), BUTTON (2), SOFTWARE (3), USB (4), UPLOAD (5). Bits 6 and 7 are kept and never set. The usual use is a **warm start**: after anything but power-on the SRAM still holds what the program left, so a program can keep its state, a high-score table say, and pick it up again:

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

| CPUSPEED | Speed |
|----------|-------|
| `0x00` (after reset) | 20 MHz |
| `0x01`–`0x07` (DIV) | 20 MHz ÷ (DIV + 1): 10, 6.67, 5, 4, 3.33, 2.86, 2.5 MHz |
| `0x08` (SPECTRUM) | 3.57 MHz, close to a Spectrum's 3.5 MHz |

The new speed starts at the next machine cycle. At every speed the Z80 still never waits for memory, and the ROM calls work the same (their waits use TIME, not loops). The SPECTRUM speed is for code that times itself with loops: beeper tones and delays sound and run as on a Spectrum, 2% fast.

```asm
        ld      bc,CPUSPEED_P
        ld      a,CPUSPEED_SPECTRUM_M
        out     (c),a                   ; 3.57 MHz from the next M-cycle
```

### Resetting from software: SYSRESET

Writing `0xA5` (`SYSRESET_MAGIC`) to SYSRESET gives a full reset, with RESETWHY.SOFTWARE set. Other values are ignored, so a stray write cannot reset the machine.

### The buttons: SYSBTN

| Button | Does |
|--------|------|
| Reset | A full reset (RESETWHY.BUTTON) |
| Multiface | The NMI: a running program stops in the monitor |
| DivMMC | Nothing by itself. The boot ROM uses it as the "monitor" button at reset |

SYSBTN shows the Multiface (bit 0) and DivMMC (bit 1) buttons, 1 = held, debounced, so a program can use them as two more keys.

### Writable boot ROM: SYSCON

**SYSCON.ROMWE** (bit 1) makes the boot ROM's pages writable, through any window whose write page is a ROM page, so a new ROM can be tried without rebuilding the FPGA: write it in, then reset. It lasts until the FPGA is reloaded. **SYSCON.ROMLOCK** (bit 2) locks ROMWE off until the next power-on; the boot ROM sets it at power-on, unless D is held, so an everyday program cannot change the ROM by accident. Writing 0 to ROMLOCK does nothing.

---

## The Guide's Examples

The complete examples in the other chapters start from the program map and share one set-up:

- **Loaded at `0x8000`**, so their Z80 addresses are their physical addresses (window n holds SRAM page n).
- **The register page in window 7.** The stack is moved first, to `0xE000` (just below window 7), then window 7 is mapped onto page `0x3F8` through ports. They name the parts of it:

  ```asm
  REGS    equ     0xE000                  ; the register page, in window 7
  SREG    equ     REGS+REGS_SYSTEM        ; 0xE000: system register r at SREG + r
  CREG    equ     REGS+REGS_CUSTOM        ; 0xF000: custom offset k at CREG + k
  PREG    equ     REGS+REGS_PALETTE       ; 0xF400: palette p at PREG + p * REGS_PAL_SPAN
  ```

  so custom offset k is at `CREG + k` and system register r at `SREG + r`. A program that keeps window 7 as the register page ends with `JP 0x0040`, not `RET`.
- **Ports** where the register page is not yet mapped, and in code meant to work whatever the program has in its windows.

---

## Summary of System Control Registers

All are registers of page `0x00`: port = (register << 8) | `0x00`; in the register page at offset = register.

| Name | Register | Port | Access | Function |
|------|----------|------|--------|----------|
| SYSID | `0x70` | `0x7000` | R | `0x5A` ("Z") |
| SYSVER | `0x71` | `0x7100` | R | FPGA build: MAJOR (7–4), MINOR (3–0) |
| SYSCFG | `0x72` | `0x7200` | R | CPU (1–0): 0 = Z80. CHIPMB (7–2): SRAM in MB |
| RESETWHY | `0x73` | `0x7300` | R | POWER (0), WATCHDOG (1), BUTTON (2), SOFTWARE (3), USB (4), UPLOAD (5); one bit set |
| SYSCON | `0x74` | `0x7400` | RW | ROMWE (1), ROMLOCK (2) |
| SYSRESET | `0x75` | `0x7500` | W (S) | `0xA5` resets |
| SYSBTN | `0x76` | `0x7600` | R | MULTIFACE (0), DIVMMC (1), 1 = held |
| CPUSPEED | `0x77` | `0x7700` | RW | DIV (2–0): 20 MHz ÷ (DIV + 1). SPECTRUM (3): 3.57 MHz |
| MMU0–MMU7 | `0x80`–`0x8F` | `0x8000`–`0x8F00` | RW | Each window's read page, 2 bytes; the high byte commits, and sets the write page |
| MMU0W–MMU7W | `0x90`–`0x9F` | `0x9000`–`0x9F00` | RW | Each window's write page, 2 bytes; the high byte commits |

Registers `0x78`–`0x7B` are the I2C master, for the real-time clock and the display's DDC; the system spec, section 7, describes it.

### State after reset

SYSCON's ROMWE is clear (ROMLOCK keeps its value until power-on), CPUSPEED is `0x00` (20 MHz), and the MMU holds the reset map. The boot ROM then sets the program map before it starts a program.

### Equates in hw.inc

| Equate | Value |
|--------|-------|
| `SYSID_P` … `CPUSPEED_P`, `MMU0_0_P` … `MMU7W_1_P` | Each register's port |
| `MMU7`, `MMU7_0`, `MMU7_1` (and the others) | Register numbers, so `SREG+MMU7` in the register page |
| `RESETWHY_POWER_M` … | Each cause's bit |
| `CPUSPEED_DIV_M`, `CPUSPEED_SPECTRUM_M` | `0x07`, `0x08` |
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
