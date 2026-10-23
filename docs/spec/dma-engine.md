# Spec 14: DMA engine

Status: **draft**

The DMA engine copies and fills SRAM for the CPU, in lines (1D) or rectangles (2D), while the CPU carries on with other work. It is retro68k's DMA engine (its spec 11) cut to retro68k's version-1 scope: **one channel, copy and fill, 1D and 2D, byte by byte, SRAM only, spare memory cycles only**. The registers keep retro68k's names and its channel layout, narrowed to 8-bit registers.

The engine never takes a memory cycle that anyone else wants, so it never slows the CPU, the display, the copper or the sprites (spec 2, section 4). It is started by the CPU or by the copper.

## 1. Summary

| Item | Value |
|------|-------|
| Channels | 1 (retro68k's channel 0) |
| Programming | The job is written straight into the job registers (CTRL, SRC, DST, WIDTH, HEIGHT, DSTSTRIDE, SRCSTRIDE, VALUE), then RUN is written to CHCTRL. No descriptors in memory |
| Jobs | COPY and FILL, in 1D (a run of bytes) or 2D (a rectangle with a source and a destination stride). DESC runs a job backwards, for overlapping copies. Codes kept for retro68k's other jobs and for a later drawing job (section 10) |
| Pixel format | Bytes only (retro68k's BPP = 8). Every layer format is packed in bytes, so this suits all of them for whole-byte areas |
| Addresses | 22-bit physical SRAM byte addresses, as the other chipset units (spec 2, section 7). Not through the MMU |
| Memory cycles | Spare cycles only, after everyone else (spec 2, section 4.3). Each moves 16 bits |
| Speed at 576p | Copy about 11–23 MB/s, fill about 21–45 MB/s, depending on the screen and the CPU (section 7). The Z80's `LDIR` copies about 1.3 MB/s at 28 MHz |
| Starting | CPU (port or register page), or the copper with MOVEL (section 9.2) |
| Finishing | CHSTAT.BUSY and DONE; the DMA0 interrupt if CTRL.IRQ is set; an IDLE signal for the copper's B bit |
| Registers | Custom block offsets `0x140`–`0x17F` (spec 3) |
| Enable | DMACON.BLTEN with DMACON.DMAEN (spec 4) |

## 2. Comparison with retro68k

retro68k's spec 11 still describes its full design (four channels, descriptor chains, the blitter, ports). Its design plan cuts its version 1 to one channel, byte-granular copy and fill in 1D and 2D, Chip RAM only, free memory cycles only. retro-z80 follows that version-1 decision.

| Item | retro68k (spec 11) | retro-z80 | Why |
|------|--------------------|-----------|-----|
| Channels | 4, taking turns | 1 | retro68k's version-1 decision |
| Descriptors | 32-byte descriptors in Chip RAM or a 2 KB descriptor RAM; NEXT, CHDESC, CHCTRL.START | Left out: a job is written into the job registers and started with RUN. NEXT and CHDESC offsets and the START bit are kept reserved | retro68k's version-1 decision |
| Jobs | COPY, FILL, KEYCOPY, LOGIC, ADD (MIX on hold) | COPY and FILL. The other OP codes keep retro68k's numbers and are reserved | retro68k's version-1 decision |
| Pixel formats | 1, 2, 4, 8 bpp, positioned to the pixel (SRCBIT, DSTBIT, shifter, edge masks) | 8 bpp only: CTRL.BPP must be 3. SRCBIT and DSTBIT left out | retro68k's version-1 decision ("byte-granular") |
| Sources and destinations | Chip RAM, custom registers, palettes, descriptor RAM, boot ROM, peripheral ports; SRCKIND, DSTKIND | SRAM only; SRCKIND and DSTKIND left out (CTRL bits 15–13 reserved) | retro68k's version-1 decision. Also, the chipset cannot read the boot ROM here (spec 2, section 2) |
| HIGH bit, CHCTRL.CPUSHARE | A job may take some of the CPU's cycle 0s | Left out (bits reserved) | Nobody takes the CPU's cycles in retro-z80 (spec 2, section 4.1) |
| Registers | 32-bit | 8-bit; wider values are consecutive bytes, low byte first, committed by the highest byte (spec 3) | Z80: 8-bit ports |
| Register offsets | Channel n at `0x300 + n × 0x40`, DMXINT `0x3F0`, DMXINTEN `0x3F4` | Channel 0 at `0x140`, with each register at `0x140` + its retro68k offset; DMXINT `0x170`, DMXINTEN `0x174` | The custom block is 1 KB (spec 3); the engine has `0x140`–`0x17F` |
| STRIDE | One 32-bit register: SRCSTRIDE in bits 31–16, DSTSTRIDE in bits 15–0 | Two 2-byte registers, DSTSTRIDE then SRCSTRIDE, in the same bytes | 8-bit registers: each stride can be written alone |
| Addresses | 24-bit CPU addresses; anything outside Chip RAM is an error | 22-bit physical SRAM addresses; bits 23–22 ignored; every address is SRAM, so there are no address errors | Z80: 64 KB address space; the chipset does not use the MMU (spec 2, section 7) |
| CHERR | The address that caused an error | Left out | No address errors |
| WIDTH | 24 bits | 24 bits (3 bytes) | Same |
| VALUE byte order | Byte at address a gets VALUE's byte a mod 4, most significant first | Byte at address a gets VALUE's byte a mod 4, **least** significant first | The SRAM is little-endian (spec 2, section 5.3), as is the Z80 |
| Memory cycle | 20 ns, 2 bytes | 35.7 ns, 2 bytes | Memory bandwidth (spec 2) |
| Speed | Copy 25–38 MB/s | Copy about 11–23 MB/s | Memory bandwidth |
| Interrupts | DMA0–DMA3, one per channel | DMA0 only; its number and fixed priority are in spec 8 | One channel; IM 2 on one /INT line |
| Copper start | A MOVE (two for a 32-bit register) | MOVEL only, one per byte (section 9.2) | Copper MOVE reaches offsets `0x000`–`0x0EF` only (spec 6) |
| Drawing job | Line drawing and area fill are "version 2" (D3) | OP codes 6 and 7 kept for a drawing job (section 10) | retro-z80 only: 3D work of design plan branch 10 |

## 3. Jobs

A job is described by the job registers (section 8.1). The engine reads them when RUN is written and keeps its progress inside itself, so the job registers still hold the job afterwards: to run a similar job, write only the fields that change, then RUN again.

### 3.1 CTRL

CTRL is 2 bytes. Its bits are where retro68k has them.

| Bits | Name | Meaning |
|------|------|---------|
| 2–0 | OP | 0 COPY, 1 FILL. 2 KEYCOPY, 3 LOGIC, 4 ADD, 5 MIX: reserved (retro68k's codes). 6 and 7: reserved for a drawing job (section 10). A reserved code is an error |
| 3 | – | Reserved, write 0 |
| 7–4 | FN | Reserved (retro68k's LOGIC and ADD function), write 0 |
| 9–8 | BPP | Must be 3 (8 bits per pixel). Other values are reserved and are an error |
| 10 | DESC | Run backwards, from the last byte of the last row to the first byte of the first row. SRC and DST still give the first byte |
| 11 | – | Reserved (retro68k's HIGH), write 0 |
| 12 | IRQ | Set DMXINT.CH0 when the job finishes |
| 15–13 | – | Reserved (retro68k's SRCKIND, DSTKIND), write 0 |

CTRL resets to `0x0300`: a COPY with BPP = 3.

### 3.2 Operations

| OP | Does | Uses |
|----|------|------|
| COPY | dst = src | SRC, DST, WIDTH, HEIGHT, SRCSTRIDE, DSTSTRIDE |
| FILL | dst = VALUE's bytes | DST, WIDTH, HEIGHT, DSTSTRIDE, VALUE. SRC and SRCSTRIDE are ignored |

**FILL's value:** the byte at address a gets VALUE's byte a mod 4, where byte 0 is bits 7–0. So:

- a fill of single bytes writes the same byte to all four bytes of VALUE;
- a fill of 2-byte entries (a tile map, spec 4) puts the entry in bytes 0–1 and again in bytes 2–3, and starts at an even address;
- a fill that starts on a multiple of 4 writes VALUE exactly, as a 4-byte pattern.

The pattern goes by address, not by position in the row, so each row of a 2D fill with an odd stride starts at another point of the pattern. That keeps it simple; a 2-pixel dither of a 4 bpp layer, for example, needs an even stride.

### 3.3 1D and 2D

- **1D jobs** (memcpy, memset): HEIGHT = 1, WIDTH = the length in bytes, up to 16 MB (more than the whole SRAM). The strides are not used.
- **2D jobs** (blits): HEIGHT rows of WIDTH bytes. Each row starts SRCSTRIDE bytes after the start of the source row before, and DSTSTRIDE bytes after the start of the destination row before. So an image can be copied out of a sheet of images into a screen of a different width. The strides are signed 16-bit: 0 repeats the same row, a negative stride runs up the screen (an image drawn upside down).
- A WIDTH or HEIGHT of 0 makes the job do nothing: it finishes at once, as any other job (DONE, and DMXINT if IRQ is set).

**Clipping is done by software**, as in retro68k, with no extra hardware. Trim the job before starting it, keeping both strides as they are:

- **Left edge:** to skip k bytes, add k to SRC and DST and subtract k from WIDTH.
- **Right edge:** subtract the bytes past the edge from WIDTH.
- **Top edge:** to skip r rows, add r × SRCSTRIDE to SRC and r × DSTSTRIDE to DST, and subtract r from HEIGHT.
- **Bottom edge:** subtract the rows past the edge from HEIGHT.
- If WIDTH or HEIGHT reaches 0, the object is off the screen: the job does nothing.

At 1, 2 or 4 bits per pixel the engine works on whole bytes, so a clip or an object at a pixel that is not on a byte boundary needs the CPU for the edge bytes.

### 3.4 Overlapping copies

A COPY reads up to 16 bytes ahead of what it writes (section 6). So:

- If the destination is **before** the source, or the areas do not overlap, run forwards (DESC = 0).
- If the destination is **after** the source and the areas overlap, run backwards (DESC = 1). For a 2D job this holds for the whole rectangle: scrolling a screen down within itself, for example, is a backwards job.

DESC = 1 starts at the last byte of the last row (SRC + (HEIGHT − 1) × SRCSTRIDE + WIDTH − 1, and the same for DST) and works back. SRC and DST are still written as the first byte, so the same job can be run either way.

## 4. Addresses

SRC and DST are **22-bit physical SRAM byte addresses** (spec 2, section 7), in 3-byte registers; bits 23–22 are ignored. A program finds the physical address of something it has mapped from the MMU: page × `0x2000` + offset within the window (spec 2, section 6).

| Physical address | 4 MB board | 2 MB board |
|------------------|------------|------------|
| `0x000000`–`0x1FFFFF` | SRAM | SRAM |
| `0x200000`–`0x3FFFFF` | SRAM | Mirror of `0x000000`–`0x1FFFFF` (bit 21 ignored) |

- Every address is SRAM, so there are no bad addresses. A job that runs past `0x3FFFFF` carries on at `0x000000` (and below `0x000000` backwards, or with a negative stride, at `0x3FFFFF`).
- The engine cannot reach the registers, the register page, the palettes, the boot ROM or the I/O devices. Registers are written by the CPU or the copper.
- The engine and the CPU share the memory with no locks. The CPU should not use an area while a job is writing it. A CPU write made before the RUN write is in memory before the engine's first read (a posted write ends before the next M-cycle, spec 1, section 5).

## 5. Memory cycles

The engine uses **spare cycles only** (spec 2, section 4.3): a cycle that its owner leaves unused, and that nobody earlier in the order wants. The order for a spare cycle is: a display FIFO below its low mark; the copper; sprites; display top-up; **the DMA engine last**. So the engine never delays anyone, and gets whatever is left:

- cycles 0 and 2 the CPU does not need (between accesses, I/O and internal T-states, boot ROM and register page accesses, slower CPU speeds);
- cycle 1 when no display FIFO has room (horizontal and vertical blank, layers off, the second line of a 2×-tall layer's pair);
- cycle 3 when the copper, sprites and display do not want it.

The 28 MHz swap (spec 2, section 4.2) moves owners' cycles about but does not change how many are spare; the engine just takes the spare ones wherever they fall.

**Each memory cycle moves 16 bits.** The engine reads whole words (both bytes) and writes words with the byte selects, so a byte at the edge of a row is written alone without touching its neighbour. What a job costs:

| Job | Memory cycles |
|-----|---------------|
| FILL | 1 per 2 bytes, plus at most 1 per row for an odd start or end |
| COPY, source and destination at the same parity (both even or both odd) | 1 read and 1 write per 2 bytes, plus at most 2 per row at the edges |
| COPY, different parity | As above, plus 1 read per row (the engine shifts the data by one byte) |

So a long copy costs about **1 cycle per byte** and a long fill about **half a cycle per byte**. Rows of only a few bytes cost relatively more.

While DMACON.BLTEN or DMACON.DMAEN is clear, the engine takes no cycles: a running job waits, and CHSTAT.BUSY stays set.

## 6. How a job runs

The engine works through each row in **groups** of up to 8 words (16 bytes), as retro68k's does:

1. **Read** (COPY): up to 16 bytes from the source into the engine's buffer, one word per spare cycle.
2. **Shift** (COPY, when SRC and DST have different parity): the data is moved by one byte; the byte left over carries into the next group, as in retro68k's shifter (which here only ever shifts by 0 or 1 byte).
3. **Write:** one word per spare cycle, using the byte selects at the row's first and last byte.

FILL skips steps 1 and 2: it writes VALUE's bytes (section 3.2) straight from the register.

Between groups, and at the end of each row, the engine works out the next addresses from the strides. That takes no memory cycles; the engine is pipelined so that it can use back-to-back spare cycles (for example all four cycles of a slot in the vertical blank with the CPU at 3.5 MHz).

**At the end of the job** the last write has gone into the SRAM. Then BUSY clears, DONE is set, IDLE goes high (section 9.3), and DMXINT.CH0 is set if CTRL.IRQ is set.

## 7. Speed

A 576p line is 32 µs: 224 slots, **896 memory cycles**, 31,250 lines a second. The engine gets what is left after the others (spec 2, section 8):

| User | Cycles per line |
|------|-----------------|
| CPU at 28 MHz | Typical code about 224 (an access every 4 T-states); at most 298 (every 3 T-states); `LDIR` about 171; `HALT` about 224 (it repeats M1 reads, spec 1, section 10). At 3.5 MHz at most 37. Boot ROM and register page accesses use none |
| Display | A 2×-tall layer fetches on the first line of each pair only, so its average is half its peak. A full-screen 8 bpp layer at 2× (360 bytes a fetched line): 180 on fetched lines, 90 on average. Nothing in the vertical blank |
| Copper | A few per line for a simple list; up to about 54 for heavy per-cell work (spec 6) |
| Sprites | Their rows, a line ahead (spec 5): 8 sprites 16 pixels wide at 8 bpp, all on the line, need 64; magnified rows are reused |

A copy moves about 1 byte per spare cycle and a fill about 2, so copy speed in MB/s ≈ spare cycles per line × 31,250 ÷ 1,000,000. Average per line over the picture:

| Situation (CPU at 28 MHz unless stated) | CPU | Display | Copper, sprites | Spare | Copy | Fill |
|------------------------------------------|-----|---------|-----------------|-------|------|------|
| Spectrum-style screen (256×192, 1 bpp, attributes), CPU busy | 224 | about 20 | 10 | about 640 | 20 MB/s | 40 MB/s |
| One full-screen 8 bpp layer at 2×, 8 sprites, CPU busy | 224 | 90 | 10 + 32 | about 540 | 17 MB/s | 34 MB/s |
| Two full-screen 8 bpp layers at 2×, 8 sprites all on the line, CPU flat out | 298 | 180 | 10 + 64 | about 340 | 11 MB/s | 21 MB/s |
| One full-screen 8 bpp layer at 2×, 8 sprites, CPU at 3.5 MHz | 37 | 90 | 10 + 32 | about 725 | 23 MB/s | 45 MB/s |
| Vertical blank (49 lines a frame), CPU busy | 224 | 0 | 10 | about 660 | 21 MB/s | 41 MB/s |

**Against the Z80:** `LDIR` takes 21 T-states a byte, about **1.3 MB/s** at 28 MHz; unrolled `LDI` (16 T-states) about 1.75 MB/s; a fill with unrolled `PUSH` about 5 MB/s. So the engine copies about 8–17 times as fast as `LDIR`, and **the CPU carries on at full speed meanwhile**.

Examples, with one full-screen 8 bpp layer, 8 sprites and the CPU busy:

| Job | Bytes | Engine | `LDIR` |
|-----|-------|--------|--------|
| Clear a 360 × 288 8 bpp screen | 103,680 | about 3 ms | 78 ms (4 frames) |
| Copy a 360 × 288 8 bpp screen | 103,680 | about 6 ms | 78 ms |
| Clear a 64 × 32 tile map (2-byte entries) | 4,096 | about 0.12 ms | 3 ms |
| Copy a 32 × 32 8 bpp image into a screen (2D) | 1,024 | about 60 µs | 0.8 ms |

These figures are worked out from the slot rules; open point D2 is to measure them in simulation. Making the CPU wait for the engine in a polling loop or in `HALT` does not free its cycles; slowing the CPU (spec 7) or running from the boot ROM does.

## 8. Registers

Custom block offsets (spec 3). From the CPU: port = (offset bits 7–0) << 8 | (`0xC0` + offset bits 9–8), so the engine's ports are `0x40C1`–`0x7FC1`, used with `LD BC,port` then `OUT (C),A` or `IN A,(C)`; `INC B` steps to the next register. In the register page the engine is at `0x1140`–`0x117F` (spec 3). The copper reaches it with MOVEL only (section 9.2).

Each register is at `0x140` plus its offset in a retro68k channel, low byte first. Multi-byte values commit on the write of their highest byte (spec 3). The gaps between registers are reserved: they read `0xFF` and ignore writes (spec 3).

### 8.1 Register table

| Offset | Port | Name | Bytes | Access | Bits | Meaning | Reset |
|--------|------|------|-------|--------|------|---------|-------|
| `0x140`–`0x141` | `0x40C1`–`0x41C1` | CTRL | 2 | RW | 15–0 | Operation and options (section 3.1) | `0x0300` |
| `0x142`–`0x143` | | – | | | | Reserved | |
| `0x144`–`0x146` | `0x44C1`–`0x46C1` | SRC | 3 | RW | 21–0 | Source address of the first byte (bits 23–22 ignored) | 0 |
| `0x147` | | – | | | | Reserved | |
| `0x148`–`0x14A` | `0x48C1`–`0x4AC1` | DST | 3 | RW | 21–0 | Destination address of the first byte (bits 23–22 ignored) | 0 |
| `0x14B` | | – | | | | Reserved | |
| `0x14C`–`0x14E` | `0x4CC1`–`0x4EC1` | WIDTH | 3 | RW | 23–0 | Bytes per row | 0 |
| `0x14F` | | – | | | | Reserved | |
| `0x150`–`0x151` | `0x50C1`–`0x51C1` | HEIGHT | 2 | RW | 15–0 | Rows (1 for a 1D job) | 0 |
| `0x152`–`0x153` | | – | | | | Reserved (retro68k's SRCBIT and DSTBIT) | |
| `0x154`–`0x155` | `0x54C1`–`0x55C1` | DSTSTRIDE | 2 | RW | 15–0 | Signed: bytes from one destination row's start to the next | 0 |
| `0x156`–`0x157` | `0x56C1`–`0x57C1` | SRCSTRIDE | 2 | RW | 15–0 | Signed: bytes from one source row's start to the next | 0 |
| `0x158`–`0x15B` | `0x58C1`–`0x5BC1` | VALUE | 4 | RW | 31–0 | FILL's pattern (section 3.2) | 0 |
| `0x15C`–`0x15F` | | – | | | | Reserved (retro68k's NEXT) | |
| `0x160`–`0x163` | | – | | | | Reserved (retro68k's CHDESC) | |
| `0x164` | `0x64C1` | CHCTRL | 1 | W strobes, RW PAUSE | 7–0 | Start, stop, pause (section 8.2) | 0 |
| `0x165`–`0x167` | | – | | | | Reserved | |
| `0x168` | `0x68C1` | CHSTAT | 1 | R, W1C | 7–0 | Status (section 8.3) | 0 |
| `0x169`–`0x16F` | | – | | | | Reserved (`0x16C`: retro68k's CHERR) | |
| `0x170` | `0x70C1` | DMXINT | 1 | R, W1C | 0 | CH0: the job finished with CTRL.IRQ set, or an error | 0 |
| `0x171`–`0x173` | | – | | | | Reserved | |
| `0x174` | `0x74C1` | DMXINTEN | 1 | RW | 0 | CH0: interrupt enable | 0 |
| `0x175`–`0x17F` | | – | | | | Reserved (room for a drawing job's registers, section 10) | |

**The job registers** (CTRL to VALUE) can be written only while the engine is idle: writes while CHSTAT.BUSY is set are ignored, as in retro68k. They read back the committed values, also during and after a job.

**Writing a whole job from memory:** the job registers are in address order with the low byte first, so `LDIR` of a 28-byte image (offsets `0x140`–`0x15B`, gaps included) into the register page writes every register in the right order (spec 2, section 6.5). It takes about 590 T-states (21 µs at 28 MHz). Writing only the fields that change through ports is usually quicker: each byte is `OUT (C),A` and `INC B`, 16 T-states.

### 8.2 CHCTRL

| Bit | Name | Access | Meaning |
|-----|------|--------|---------|
| 0 | START | – | Reserved (retro68k: load a descriptor and run it). Write 0 |
| 1 | RUN | W, strobe | Run the job in the job registers. Ignored while BUSY. Reads 0 |
| 2 | STOP | W, strobe | End the running job after its current group (at most 16 bytes later). DONE is set; DMXINT is not. Reads 0 |
| 3 | PAUSE | RW | While set, the job holds after its current group, BUSY stays set and PAUSED is set. Clearing it lets the job carry on |
| 5–4 | – | – | Reserved (retro68k's CPUSHARE). Write 0 |
| 7–6 | – | – | Reserved. Write 0 |

A RUN is checked when it is written: a reserved OP or a BPP other than 3 does not start the job, and sets ERR and DMXINT.CH0 instead (section 8.3). Otherwise BUSY is set in the same clock, so a status read or a copper WAIT straight after the RUN already sees the job.

A RUN written while PAUSE is set starts the job paused.

### 8.3 CHSTAT

| Bit | Name | Access | Meaning |
|-----|------|--------|---------|
| 0 | BUSY | R | A job is running, paused or waiting for DMACON.BLTEN |
| 1 | DONE | R, W1C | A job finished or was stopped. Sticky |
| 2 | ERR | R, W1C | A RUN was refused: bad CTRL (section 8.2). Sticky |
| 3 | PAUSED | R | The job is held by CHCTRL.PAUSE |
| 7–4 | – | R | 0 |

BUSY is bit 0, so a polling loop is `IN A,(C)`, `RRA`, `JR C`.

### 8.4 DMACON

The engine uses memory cycles only while **DMACON.BLTEN** and **DMACON.DMAEN** are both set, as in retro68k (DMACON's 8-bit layout is in spec 4). Both are clear after reset. While either is clear, a running job waits where it is, BUSY stays set, and a RUN is still accepted (the job waits). Clearing BLTEN is a way to hold the engine without stopping the job.

### 8.5 Interrupt

The engine is one interrupt source, **DMA0** (retro68k's name for channel 0's source; its number and place in the fixed priority are in spec 8). It requests its interrupt while DMXINT.CH0 and DMXINTEN.CH0 are both set. DMXINT.CH0 is set when a job with CTRL.IRQ finishes (including a job of zero WIDTH or HEIGHT), or when a RUN is refused. The handler clears it by writing 1 to DMXINT bit 0.

## 9. Starting and waiting

### 9.1 From the CPU

1. Wait until CHSTAT.BUSY is clear (or the last DMA0 interrupt).
2. Write the job registers that change.
3. Write RUN (`0x02`) to CHCTRL.
4. Carry on. Take the DMA0 interrupt, or poll CHSTAT.BUSY.

```
; Clear a 360 x 288 8 bpp screen at physical 0x020000 to colour 0.
; Ports from hw.inc (spec 3, section 8): DMX0_CTRL_P = 0x40C1 (offset 0x140),
; DMX0_DST_P = 0x48C1, DMX0_WIDTH_P = 0x4CC1, DMX0_HEIGHT_P = 0x50C1,
; DMX0_VALUE_P = 0x58C1, DMX0_CHCTRL_P = 0x64C1, DMX0_CHSTAT_P = 0x68C1.

clear:      ld   bc,DMX0_CHSTAT_P
.wait:      in   a,(c)
            rra                  ; BUSY into carry
            jr   c,.wait
            ld   bc,DMX0_CTRL_P
            ld   a,0x01          ; OP = FILL
            out  (c),a
            inc  b
            ld   a,0x03          ; BPP = 8, no IRQ: commits CTRL
            out  (c),a
            ld   b,high DMX0_DST_P  ; DST = 0x020000
            xor  a
            out  (c),a
            inc  b
            out  (c),a
            inc  b
            ld   a,0x02
            out  (c),a           ; commits DST
            ld   b,high DMX0_WIDTH_P ; WIDTH = 103,680 = 0x019500, one row
            xor  a
            out  (c),a
            inc  b
            ld   a,0x95
            out  (c),a
            inc  b
            ld   a,0x01
            out  (c),a
            ld   b,high DMX0_HEIGHT_P ; HEIGHT = 1
            out  (c),a
            inc  b
            xor  a
            out  (c),a
            ld   b,high DMX0_VALUE_P ; VALUE = 0x00000000
            out  (c),a
            inc  b
            out  (c),a
            inc  b
            out  (c),a
            inc  b
            out  (c),a
            ld   bc,DMX0_CHCTRL_P
            ld   a,0x02          ; RUN
            out  (c),a
            ret                  ; about 3 ms later the screen is clear
```

### 9.2 From the copper

The engine's registers are past `0x0EF`, so the copper writes them with **MOVEL** (spec 6), one MOVEL per byte. A MOVEL is two instruction words, and each word costs the copper one memory read (cycle 3 after urgent display fetches, or a spare cycle). The copper's writes go through its own latch (spec 3), so they never mix with a CPU write in progress.

| Copper work | MOVELs | Words read | Time, at one cycle 3 per slot |
|-------------|--------|------------|-------------------------------|
| RUN alone (the job registers already set) | 1 | 2 | 0.3 µs |
| New SRC and DST, then RUN (a repeat of the last job) | 7 | 14 | 2 µs |
| A whole new job, then RUN | 22 | 44 | 6.3 µs (about a fifth of a line) |

These words come out of cycle 3 ahead of the sprites, so a list that sets up jobs on a line leaves the sprites less on that line (spec 5, section 5.2). The job itself runs in spare cycles as usual. Keep a strobe (the RUN) out of the middle of a multi-byte value, so that a list cut off and run again never starts a job twice (spec 6, section 6.5).

### 9.3 IDLE, for the copper's B bit

The copper's WAIT has a **B** bit, as in retro68k: with B set, a WAIT also waits until the DMA engine is idle (spec 6, section 4.1; SKIP has no B bit). The engine gives the copper one signal, **IDLE** = not CHSTAT.BUSY:

- IDLE goes low in the clock RUN is written, so a WAIT with B straight after the MOVEL that wrote RUN waits for that job.
- IDLE goes high when the job's last write is in memory (section 6), or when it is stopped.
- A paused job, or one waiting for DMACON.BLTEN, is not idle. A WAIT with B while BLTEN is clear therefore waits until BLTEN is set (or the next vertical blank restarts the copper).

With it, a copper list can start a job, wait for it, and start the next, as on the Amiga with the blitter.

### 9.4 From a timer

Spec 9 keeps retro68k's timer DMA start: with a timer's CTRL.DMA bit set (spec 9, section 4.5), its underflow acts as a write of RUN to CHCTRL: it starts the job in the job registers, and is ignored if the engine is busy.

## 10. Room for a drawing job

Design plan branch 10 may add drawing help for flat-shaded 3D (open question Q10): a span filler or a triangle job. It is not specified here. This spec keeps room for it:

- **OP codes 6 and 7** are reserved for drawing jobs (2–5 keep retro68k's codes).
- **CTRL.FN** (bits 7–4) is reserved and can carry a drawing job's options.
- **Offsets `0x175`–`0x17F`**, and the reserved bytes among the job registers, can hold its extra registers. If it needs more, that is open point D5.
- A drawing job would use the same spare cycles, the same IDLE signal, DONE, and DMA0.

Version 1 already fills a span: a 1D FILL with DST = the line's start + x0 and WIDTH = x1 − x0 + 1. Each span costs the CPU about 100 T-states of register writes, against about 21 T-states a byte with `LDIR`, so it pays for spans longer than about 5 bytes; but the CPU must wait for each span to finish before writing the next.

## 11. FPGA resources

| Item | Resource |
|------|----------|
| Job registers (about 21 bytes) and latches | Flip-flops |
| Data buffer (8 words) and the 1-byte shift | Distributed RAM or flip-flops |
| Two 22-bit address units with 16-bit signed strides, 24-bit width and 16-bit row counters | Logic |
| Control and memory request | Logic |
| In all | Estimate 400–600 LUTs, no block RAM, to be confirmed by synthesis |

## 12. Test plan

- **Copy and fill:** 1D and 2D; widths 0, 1, 2, 3 and long; HEIGHT 0, 1 and many; every combination of even and odd SRC and DST; positive, zero and negative strides; forwards and backwards (DESC) with overlapping areas, the destination before and after the source. Compare the whole SRAM with a Python model of this spec.
- **FILL's value:** the 4-byte pattern by address at every starting address mod 4; a tile map fill with 2-byte entries.
- **Addresses:** a job running past `0x3FFFFF` wraps to `0x000000` (and backwards); bits 23–22 ignored; the mirror on a 2 MB build.
- **Registers:** commit on the highest byte; job register writes ignored while BUSY; read back after a job; LDIR of a 28-byte image through the register page sets the job; reserved offsets read `0xFF`.
- **Control:** RUN ignored while BUSY; STOP ends after a group and sets DONE; PAUSE holds and resumes with the same result as an uninterrupted job; RUN while PAUSE is set; a reserved OP or BPP sets ERR and DMXINT and starts nothing.
- **DMACON:** a job waits while BLTEN or DMAEN is clear, and finishes when it is set again.
- **Interrupt:** DMA0 requested only with DMXINT.CH0 and DMXINTEN.CH0; IRQ clear gives DONE but no DMXINT; W1C clears it; a zero-size job with IRQ.
- **Spare cycles only:** with the CPU at all four speeds, the display, copper and sprites busy, and the swap at 28 MHz, the engine never takes a cycle that another user wanted: CPU accesses, display FIFOs (no OVERRUN on a within-budget screen), copper and sprite fetches are exactly the same with and without a job running.
- **Copper:** a job set up and started by MOVELs; a WAIT with B right after the RUN waits for that job; IDLE stays low while paused or with BLTEN clear.
- **Ordering:** a CPU write made just before the RUN is seen by the job's first read, at all four speeds.
- **Speed:** the figures of section 7, with the screens and CPU loads listed there.

## 13. Open points

| # | Item |
|---|------|
| D1 | Check the engine fits (section 11) and can use back-to-back spare cycles at 56 MHz |
| D2 | Measure the speed figures of section 7 in simulation |
| D3 | retro68k's other jobs (KEYCOPY, LOGIC, ADD), pixel positioning at 1, 2 and 4 bpp, and descriptor chains: later, following retro68k when its version 2 is decided. Their codes and register offsets are kept reserved |
| D4 | A drawing job for flat-shaded 3D (design plan branch 10, Q10): span filler or triangle job. OP 6 and 7 are kept for it (section 10) |
| D5 | If a drawing job needs more registers than the reserved bytes in `0x140`–`0x17F`, it needs more custom block space (from the reserved `0x200`–`0x3FF`, not from audio) |
| D6 | A small job queue (or descriptor chains), so the CPU can queue the next job (a span, say) while one runs. Not in version 1 |
| D7 | No HIGH bit: the engine never takes the CPU's cycles. If games want faster blits with the CPU waiting, a mode that takes cycles 0 and 2 while the CPU is in `HALT` would add about 224 cycles a line. Not in version 1 |
| D8 | VALUE's byte order is little-endian, unlike retro68k (section 2). Closed: it follows the SRAM and the Z80 |
