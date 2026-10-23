# Spec 14: DMA engine

Status: **draft**

One engine moves data for the CPU: it copies and fills memory, feeds the SD card and the USB serial link, writes hardware registers and palettes, and draws graphics (the blitter). The CPU describes a job in a channel's registers, or a chain of jobs in memory, starts the channel, and carries on with other work while the engine runs them.

It is retro68k's DMA engine as decided for its version 1 (its spec 11), narrowed to 8-bit registers: 4 channels, descriptor chains, COPY, FILL, KEYCOPY, LOGIC and ADD at 1, 2, 4 and 8 bits per pixel, positioned to the pixel. The engine uses only memory cycles that nobody else wants, so it never slows the Z80, which never waits for memory (design plan, branch 11).

## 1. Summary

| Item | Value |
|------|-------|
| Channels | 4, running at the same time and taking turns, a group of memory cycles each |
| Programming | A job written straight into a channel's registers, or chains of 32-byte **descriptors** (job descriptions, laid out as those registers) in SRAM |
| Jobs | COPY, FILL, KEYCOPY (transparent copy with a colour key), LOGIC (any function of source and destination), ADD (per pixel); in 1D (a run of bytes) or 2D (rectangles with a stride). MIX is on hold, as in retro68k. OP 6 and 7 reserved for a drawing job |
| Pixel formats | 1, 2, 4 or 8 bits per pixel, positioned to the pixel (SRCBIT, DSTBIT) |
| Sources and destinations | SRAM, the custom registers (a byte at a time), the palettes, the boot ROM (read only), or a peripheral port (the SD card, the USB serial link) |
| Addresses | Physical: MMU page × `0x2000` + offset (section 4). Not through the MMU windows |
| Memory cycles | The free pool only: cycle 4 and every cycle its owner leaves (spec 2, section 4). **The CPU is never slowed.** No HIGH mode |
| Speed at 576p | Copy about 21–45 MB/s, fill about 42–89 MB/s, depending on the screen and the CPU (section 7). The Z80's `LDIR` copies about 0.95 MB/s at 20 MHz |
| Starting | The CPU (ports or the register page), the copper (MOVEF), another channel (a COPY into CHCTRL), or a timer (spec 9) |
| Finishing | An interrupt per descriptor if asked (DMA0–DMA3), status flags per channel, an idle signal for the copper's WAIT B |
| Registers | Custom block offsets `0x140`–`0x23F` (spec 3): channel n at `0x140 + n × 0x40`; DMXINT and DMXINTEN at `0x230` and `0x234` |
| Enable | DMACON.BLTEN with DMACON.DMAEN (spec 4) |

## 2. Comparison with retro68k

| Item | retro68k (spec 11) | retro-z80 | Why |
|------|--------------------|-----------|-----|
| Channels, jobs, descriptors, chains | 4 channels; COPY, FILL, KEYCOPY, LOGIC, ADD; 32-byte descriptors with NEXT; START, RUN, STOP, PAUSE | The same | – |
| Registers | 32-bit | 8-bit; each of retro68k's long words is the same bits in consecutive bytes, low byte first, committed by its highest used byte (spec 3, rule 2) | Z80: 8-bit ports |
| STRIDE | One register: SRCSTRIDE in bits 31–16, DSTSTRIDE in bits 15–0 | Two 2-byte registers, DSTSTRIDE then SRCSTRIDE, in the same bytes | 8-bit registers: each stride can be written alone |
| Register offsets | Channel n at `0x300 + n × 0x40`; DMXINT `0x3F0`, DMXINTEN `0x3F4` | Channel n at `0x140 + n × 0x40`; DMXINT `0x230`, DMXINTEN `0x234` (the same place after channel 3: base + `0xF0`, + `0xF4`) | The custom block is 1 KB (spec 3) |
| Addresses | 24-bit CPU addresses | Physical: MMU page × `0x2000` + offset (23 bits), so the custom registers are at `0x7F1000` (section 4) | Z80: 64 KB address space; chipset units do not use the MMU windows (spec 2) |
| Register accesses | 32-bit; addresses, lengths and strides multiples of 4 | Bytes, at any address, through each channel's own latch | 8-bit registers |
| Palettes | 4-byte entries (`0x00RRGGBB`) at `0xE04000` | 3-byte entries (blue, green, red; the red byte commits) in the register page (spec 4) | retro-z80's palette format (branch 11) |
| Descriptor RAM | 2 KB inside the FPGA at `0xE06000` | None in version 1: descriptors in SRAM only. Open point D5 | Block RAM |
| Boot ROM | A source, on the register bus | A source too, read only, at `0x7F8000`–`0x7FFFFF`, through the ROM's second block RAM port (spec 2, section 2) | The CPU reaches the ROM through the MMU, not the register bus |
| HIGH, CPUSHARE | A job may take some of the CPU's cycle 0s | Left out: CTRL bit 11 is ignored, CHCTRL bits 5–4 reserved | The Z80 never waits for SRAM (design plan, branch 11) |
| Memory cycles | The free order after the display, audio and copper | The same order and the same 4-channel turn-taking. Cycle 2 is the CPU's here, cycle 4 audio's (reserved) | Slot owners (spec 2, section 4) |
| Speed | Copy 25–38 MB/s, fill 50–77 MB/s | Copy about 21–45 MB/s, fill about 42–89 MB/s | The Z80 leaves more cycles than a 68000; there is no HIGH mode |
| Planar layers | Drawn a plane at a time (its section 6.1) | Not needed | Layers are chunky only (branch 11) |
| FILL's value at 8 bpp | Byte at address a gets VALUE's byte a mod 4, most significant first | The same, **least** significant first | The SRAM is little-endian (spec 2, section 8.4), as is the Z80 |
| Interrupts | DMA0–DMA3, sources 4–7, a level each | DMA0–DMA3, sources 4–7, fixed priority (spec 8) | IM 2 on one /INT line |
| Copper start | A MOVE | MOVEF, one byte per instruction (section 9.2) | Copper MOVE reaches offsets `0x000`–`0x0EF` only (spec 6) |
| OP 6 and 7 | Reserved (an error) | Reserved (an error), to be agreed with retro68k for a drawing job (open point D6) | Design plan, branches 10 and 11 |

## 3. Descriptors

A job is described by 32 bytes: a channel's **job registers** (section 8), or a 32-byte **descriptor** in SRAM, at an address that is a multiple of 4, which the channel loads into them. Each job can point to the next descriptor, so a chain of jobs runs without the CPU.

The layout is retro68k's eight long words, each stored low byte first. Bytes that hold no bits are reserved: they are ignored in a descriptor and are not registers (spec 3, rule 11).

| Offset | Name | Bytes | Bits | Meaning |
|--------|------|-------|------|---------|
| `+0x00`–`+0x02` | CTRL | 3 | see below | Operation and options |
| `+0x04`–`+0x06` | SRC | 3 | 23–0 | Source address (section 4) of the first pixel, or port number |
| `+0x08`–`+0x0A` | DST | 3 | 23–0 | Destination address (section 4) of the first pixel, or port number |
| `+0x0C`–`+0x0E` | WIDTH | 3 | 23–0 | Pixels per row (bytes when BPP = 8) |
| `+0x10`–`+0x12` | HEIGHT | 3 | HEIGHT 15–0, SRCBIT 18–16, DSTBIT 22–20 | Rows (1 for a linear job). SRCBIT and DSTBIT: the first pixel's position within its byte, counted in pixels from the most significant end, at 1, 2 and 4 bpp (0–7, 0–3, 0–1); 0 at 8 bpp |
| `+0x14`–`+0x15` | DSTSTRIDE | 2 | 15–0, signed | Bytes from the start of one destination row to the start of the next |
| `+0x16`–`+0x17` | SRCSTRIDE | 2 | 15–0, signed | Bytes from the start of one source row to the start of the next |
| `+0x18`–`+0x1B` | VALUE | 4 | 31–0 | FILL's value, KEYCOPY's key colour, or the constant source for LOGIC and ADD |
| `+0x1C`–`+0x1E` | NEXT | 3 | 23–0 | Address of the next descriptor; 0 = end of chain |

`+0x03`, `+0x07`, `+0x0B`, `+0x0F`, `+0x13` and `+0x1F` are reserved. A WIDTH or HEIGHT of 0 makes the job do nothing; the chain carries on with NEXT.

**CTRL bits** (retro68k's positions):

| Bits | Name | Meaning |
|------|------|---------|
| 2–0 | OP | 0 COPY, 1 FILL, 2 KEYCOPY, 3 LOGIC, 4 ADD, 5 MIX (on hold: an error), 6 and 7 reserved (an error) |
| 3 | – | Reserved, write 0 |
| 7–4 | FN | LOGIC: truth table, result bit = FN[src × 2 + dst]. For example `0x8` = AND, `0xE` = OR, `0x6` = XOR, `0x5` = NOT destination, `0x2` = destination AND NOT source. ADD: bit 4 = saturate, bit 5 = signed |
| 9–8 | BPP | 0 = 1, 1 = 2, 2 = 4, 3 = 8 bits per pixel |
| 10 | DESC | Run backwards: from the last pixel of the last row to the first pixel of the first row, for overlapping copies where the destination is after the source. SRC and DST still give the first pixel |
| 11 | – | retro68k's HIGH. Ignored: the job runs as a normal job |
| 12 | IRQ | Set the channel's DMXINT bit when this descriptor finishes |
| 14–13 | SRCKIND | 0 = memory, 1 = port, 2 = none (FILL), 3 = VALUE (LOGIC and ADD with a constant) |
| 16–15 | DSTKIND | 0 = memory, 1 = port, 2 and 3 reserved (an error) |
| 23–17 | – | Reserved, write 0 |

In bytes: CTRL0 holds OP and FN; CTRL1 holds BPP (1–0), DESC (2), IRQ (4), SRCKIND (6–5) and DSTKIND bit 0 (7); CTRL2 bit 0 is DSTKIND bit 1. A COPY at 8 bpp from memory to memory is `0x00`, `0x03`, `0x00`; a FILL at 8 bpp is `0x01`, `0x43`, `0x00`.

**Operations:**

| OP | Does | Reads the destination? |
|----|------|------------------------|
| COPY | dst = src | Only for bytes the job covers in part, at 1, 2 or 4 bpp |
| FILL | dst = VALUE | Same |
| KEYCOPY | dst = src, except where the source pixel equals the key colour (VALUE's low BPP bits), which is left alone | At 8 bpp no: a key pixel is a byte not written. At 1, 2 and 4 bpp yes |
| LOGIC | dst = FN(src, dst), bit by bit | Yes |
| ADD | dst = dst + src, pixel by pixel | Yes |

**FILL's value:** at 8 bpp the fill repeats all four bytes of VALUE, by address: the byte at address a gets VALUE's byte a mod 4, where byte 0 is bits 7–0. So:

- a fill of single bytes writes the same byte to all four bytes of VALUE;
- a fill of 2-byte entries (a tile map, spec 4) puts the entry in bytes 0–1 and again in bytes 2–3, and starts at an even address;
- a fill that starts on a multiple of 4 writes VALUE exactly, as a 4-byte pattern.

The pattern goes by address, not by position in the row, so each row of a 2D fill with a stride that is not a multiple of 4 starts at another point of the pattern. At 1, 2 and 4 bpp every pixel gets VALUE's low BPP bits. SRCKIND = 3 (VALUE as a source, for LOGIC and ADD) gives every source pixel the same value, in the same way, by the destination's address.

**ADD:**

- Each pixel is added separately, at the job's colour depth (1, 2, 4 or 8 bits). Carries never spill into the next pixel.
- **Wrap** (FN bit 4 = 0): the result wraps round, e.g. 250 + 10 = 4 at 8 bpp.
- **Saturate** (FN bit 4 = 1): the result sticks at the limit instead. Unsigned (FN bit 5 = 0): 0 to the top value, e.g. 250 + 10 = 255. Signed (FN bit 5 = 1): pixels are two's complement, e.g. −128 to +127 at 8 bpp.
- The source can be memory or a constant (SRCKIND = 3).
- Uses: shading with palettes laid out as ramps (add a constant to darken or brighten an area, or add a light map); moving an area to another palette block by adding 16, 32 and so on; additive effects such as glows; fading a palette (a saturating ADD on the palette's bytes, section 4); mixing 8-bit signed audio samples.
- To subtract, add the two's complement, e.g. add `0xFF` to subtract 1 at 8 bpp with wrap.

**Linear jobs** (memcpy, memset, port transfers): BPP = 8, HEIGHT = 1, WIDTH = the length in bytes (up to 16 MB, more than the whole SRAM).

**2D jobs** (blits): WIDTH × HEIGHT pixels, with each row starting a stride after the last. Source and destination have their own strides, so an image can be copied out of a sheet of images into a screen of a different width. A stride of 0 repeats the same row; a negative stride runs up the screen (an image drawn upside down).

**Clipping is done by software,** with no extra hardware. Trim the job before starting it, keeping both strides as they are:

- **Left edge:** skip k pixels: move SRC and DST on by k pixels (bytes, plus SRCBIT and DSTBIT at 1, 2 and 4 bpp), and subtract k from WIDTH.
- **Right edge:** subtract the pixels past the edge from WIDTH.
- **Top edge:** skip r rows: add r × SRCSTRIDE to SRC and r × DSTSTRIDE to DST, and subtract r from HEIGHT.
- **Bottom edge:** subtract the rows past the edge from HEIGHT.
- If WIDTH or HEIGHT reaches 0, the object is off the screen: the job does nothing.

**Overlapping copies:** a job reads up to 16 bytes ahead of what it writes (section 6). If the destination is before the source, or the areas do not overlap, run forwards (DESC = 0). If the destination is after the source and the areas overlap, run backwards (DESC = 1); for a 2D job this holds for the whole rectangle (scrolling a screen down within itself is a backwards job). DESC = 1 starts at the last pixel of the last row and works back; SRC and DST are still written as the first pixel, so the same job can run either way.

**Which kinds go together:**

| OP | SRCKIND | DSTKIND |
|----|---------|---------|
| COPY | memory or port | memory or port (not both ports) |
| FILL | none | memory |
| KEYCOPY | memory | memory |
| LOGIC, ADD | memory or VALUE | memory |

A port job is a COPY moving one byte at a time: linear, BPP = 8, HEIGHT = 1, no DESC, and its memory side in SRAM. Any other combination stops the channel with an error.

### 3.1 MIX

On hold, as in retro68k (its section 3.1): OP 5 stops the channel with an error. Sound is parked here anyway (spec 13).

## 4. Where data can come from and go to

**DMA addresses are physical addresses** in the MMU's page numbering (spec 2, section 9.3): address = page × `0x2000` + offset within the page. They do not go through the MMU windows, so a job sees the same thing whatever the CPU has mapped. The address registers are 3 bytes; the areas are:

| Address | MMU page | Area | Read | Write | Uses SRAM cycles? |
|---------|----------|------|------|-------|-------------------|
| `0x000000`–`0x3FFFFF` | `0x000`–`0x1FF` | **SRAM** (4 MB; 2 MB boards: `0x000000`–`0x1FFFFF`) | Yes | Yes | Yes |
| `0x7F1000`–`0x7F13FF` | `0x3F8` (REGS) | The custom block: custom offset k at `0x7F1000` + k (spec 3) | Yes | Yes (COPY and FILL) | No |
| `0x7F1400`–`0x7F1FFF` | `0x3F8` (REGS) | The palettes, laid out as in the register page: palette p, entry i at `0x7F1400` + p × `0x300` + 3i, blue, green, red (spec 2, section 10.2; spec 3, section 6) | Yes | Yes | No |
| `0x7F8000`–`0x7FFFFF` | `0x3FC`–`0x3FF` | The **boot ROM** (spec 7), through the ROM's second block RAM port, one byte per clock | Yes | No (an error) | No |

Anything else stops the channel with an error. That includes SRAM past the end on a 2 MB board (unlike the display, which sees a mirror there), a write to the boot ROM, and the **system block** of the register page (`0x7F0000`–`0x7F0FFF`: interrupt controller, timers, serial, SD card, MMU, keyboard rows). As in retro68k, the system block is left out so a runaway job cannot disturb interrupts, paging or the serial console; its devices are reached through ports instead.

A program finds the physical address of something it has mapped from the window's MMU register: page × `0x2000` + (Z80 address AND `0x1FFF`).

**Rules for registers** (the custom block):

- Register accesses are bytes, at any address, with BPP = 8 and no DESC. A job with DESC or another BPP on registers is an error.
- Only COPY and FILL may write registers. A COPY from SRAM into a block of registers sets up a whole layer, or several, in one job; a COPY into another channel's CHCTRL starts that channel, just as a CPU write does, so one chain can start others. COPY can also read registers into SRAM, for example to save a screen setup or to log beam positions.
- **Multi-byte values:** each channel writes registers through **its own latch**, which follows spec 3, rules 2 and 3 (lower bytes held, the highest byte commits). So a channel's writes never mix with the CPU's, the copper's or another channel's. A job that writes a register must write its highest byte, or the value is not committed.
- **Reading:** a register read by the engine has no side effect. For registers that capture (spec 3, rule 4), the engine has its own capture, separate from the CPU's: a job that reads the lowest byte first reads one consistent value.
- A DMA register write has exactly the same effect as a CPU write to the same register, including its timing rules (for example, a layer setting for line n written before line n starts, spec 4). Writes ignored by the CPU (read-only registers, reserved offsets) are ignored for the engine too, without an error.
- Register and palette accesses take one 100 MHz clock each on the FPGA's register bus. The copper goes first, then the CPU, then the engine (spec 1, section 4.2; spec 3, rule 8): a job waits a clock when either of the others is using the bus. Boot ROM reads also take one clock each, on the ROM's own port.

**Palettes** are memory to the engine: any operation can use them, a byte at a time, at any address, with no DESC (DESC on palettes is an error). An entry changes when its red byte is written, as for the CPU through the register page (spec 4); each channel has its own latch for this. A job that covers whole entries forwards therefore changes them entry by entry. A saturating ADD over a palette's bytes fades it.

**Ports:**

| Port | Device |
|------|--------|
| 0 | The SD card (spec 11): a source reads the run of bytes SDCOUNT asked for; a destination sends bytes to the card. Paced by the SPI clock |
| 1 | The USB serial FIFOs (spec 10), paced by the link: a source reads the receive FIFO, a destination writes the transmit FIFO |
| 2–7 | Reserved (an error) |

When a port isn't ready, that channel waits and the other channels keep running. Port addresses don't move on.

A port job moves each byte over the register bus, through SDDATA (port 0) or SERDATA (port 1), one clock per byte like any register access, paced by the unit's ready signal (spec 3, section 3.2). There is no separate port path. The boot ROM is read through the ROM's second block RAM port, not the register bus (spec 2, section 2). Both paths are decided (design plan, branch 11; spec 3, R13).

**The engine and the CPU** share memory with no locks. The CPU should not use an area while a job writes it. A CPU write made before the write that starts a channel is in memory before the engine's first read (spec 1).

## 5. Memory cycles and priority

The engine is the DMA engine channel of the memory scheduler, as in retro68k (spec 2, section 4; retro68k's spec 5, section 6). Each 100 ns slot has 5 memory cycles of 20 ns: 0 and 2 the CPU's, 1 and 3 the display's, 4 audio's (reserved while sound is parked) and the free pool's.

- **The free pool** is cycle 4 and every cycle its owner leaves: cycles 0 and 2 the Z80 does not use (it makes a memory access at most every 3 T-states, and none in I/O and register page accesses or internal T-states), cycles 1 and 3 no layer or sprite needs (all of them in the vertical blank), and cycle 4 while audio is parked. The free order is retro68k's: hard-deadline users (display, sprites), audio, the copper, **the DMA engine**, the DMA port. So the engine never delays anyone, and gets whatever is left.
- **No HIGH mode:** the engine never takes a cycle from the CPU. The Z80 never waits for SRAM.
- **One memory cycle** reads or writes 2 bytes at an even address, with byte selects for single bytes (spec 2, section 8.4). A copy costs 2 cycles per 2 bytes (one read, one write); a fill 1; a job that reads the destination 3.
- **Between channels:** channels with work to do take turns, a group of up to 8 destination words (or 8 bytes of a port job) each, so a long blit can't hold up a peripheral transfer for more than a fraction of a microsecond. A channel waiting for its port gives up its turn.
- **Descriptors** in SRAM take 16 read cycles (32 bytes) to load.
- While DMACON.BLTEN or DMACON.DMAEN is clear (spec 4), running channels wait and CHSTAT.BUSY stays set. Register and port transfers, which need no memory cycles, also wait, so clearing BLTEN holds the whole engine.

## 6. How a blit works

The engine works through each row in groups of up to 8 words (16 bytes). Each group goes through the same four steps:

1. **Read:** up to 16 bytes from the source into the engine's buffer, one word per memory cycle. Jobs that read the destination (LOGIC, ADD, KEYCOPY below 8 bpp, and bytes covered in part at 1, 2 or 4 bpp) also read the matching destination words.
2. **Shift:** when the source and destination start at different places, the data is shifted by the difference: by a byte when SRC and DST have different parity, and by pixels at 1, 2 and 4 bpp when SRCBIT ≠ DSTBIT. Bits carry from one word into the next. The engine treats data as a stream of bytes in address order (the low byte of a word first, as the SRAM is little-endian), with pixels from the most significant end of each byte.
3. **Combine:** key compare (KEYCOPY), logic function (LOGIC) or per-pixel add (ADD).
4. **Write:** one word per memory cycle, using the byte selects to leave an untouched byte alone.

**Edge masks are automatic.** The engine works out which pixels of the first and last bytes of each row belong to the job from DSTBIT and WIDTH. There are no mask registers to set.

**Read-modify-write:** the SRAM can only skip whole bytes when writing. When a write would change only some pixels in a byte, the engine reads the destination, merges, and writes it back. This happens at the row edges of 1, 2 and 4 bpp jobs that don't start or end on a byte, for every byte of KEYCOPY at 1, 2 and 4 bpp, and always for LOGIC and ADD. At 8 bpp, COPY, FILL and KEYCOPY never need it: a skipped key pixel is a byte not written. **8 bpp is the fastest format for game graphics.**

Between groups, and at the end of each row, the engine works out the next addresses from the strides. That takes no memory cycles; the engine is pipelined so that it can use back-to-back free cycles (all five cycles of a slot in the vertical blank with the CPU slowed, for example).

**At the end of a job** its last write has reached the SRAM or the register. Then, if CTRL.IRQ is set, the channel's DMXINT bit is set; the channel loads the descriptor at NEXT and runs it, or, if NEXT is 0, BUSY clears and DONE is set.

## 7. Speed

A 576p line is 32 µs: 320 slots, **1,600 memory cycles**, 31,250 lines a second. The engine gets what the other users leave:

| User | Cycles per line |
|------|-----------------|
| CPU at 20 MHz (640 T-states a line) | Typical code about 160 (an access every 4 T-states); at most 213 (every 3 T-states); `LDIR` about 122 (4 accesses in 21 T-states); `HALT` about 160 (it repeats M1 reads). At 3.57 MHz at most 38. I/O, register page and boot ROM accesses use none |
| Display | The layers' fetches (spec 4): a full-screen 8 bpp layer is 360 words a line at 1×, 180 at 2× across; at most 640 a line (the budget, 1.48 bytes per pixel). Nothing in the vertical blank (49 lines a frame) |
| Sprites | 8 sprites 16 pixels wide at 8 bpp, all on the line: 64 (spec 5) |
| Copper | A few per line for a simple list (spec 6) |
| Audio | None while sound is parked |

A copy moves 1 byte per free cycle and a fill 2, so copy speed in MB/s ≈ free cycles per line × 31,250 ÷ 1,000,000. On a line with the display fetching:

| Situation (CPU at 20 MHz unless stated) | CPU | Display | Sprites, copper | Free | Copy | Fill |
|------------------------------------------|-----|---------|-----------------|------|------|------|
| Spectrum-style screen (256 × 192 at 2×, 1 bpp, attributes), CPU busy | 160 | about 20 | 10 | about 1,410 | 44 MB/s | 88 MB/s |
| One full-screen 8 bpp layer at 2×, 8 sprites, CPU busy | 160 | 180 | 64 + 10 | about 1,190 | 37 MB/s | 74 MB/s |
| One full-screen 8 bpp layer at 1×, 8 sprites, CPU busy | 160 | 360 | 64 + 10 | about 1,010 | 31 MB/s | 63 MB/s |
| Layers using the whole display budget, 8 sprites, CPU flat out | 213 | 640 | 64 + 10 | about 670 | 21 MB/s | 42 MB/s |
| One full-screen 8 bpp layer at 1×, 8 sprites, CPU at 3.57 MHz | 38 | 360 | 64 + 10 | about 1,130 | 35 MB/s | 71 MB/s |
| Vertical blank, CPU busy | 160 | 0 | 10 | about 1,430 | 45 MB/s | 89 MB/s |

The 4 channels share these cycles. Jobs that read the destination (LOGIC, ADD) need 3 cycles per 2 bytes instead of 2, so they run at about two thirds of the copy speed. Jobs at 1, 2 or 4 bpp that are not byte-aligned add a read at each row edge. Rows of only a few bytes cost relatively more.

**Against the Z80:** `LDIR` takes 21 T-states a byte, about **0.95 MB/s** at 20 MHz; unrolled `LDI` (16 T-states) about 1.25 MB/s; a fill with unrolled `PUSH` (11 T-states per 2 bytes) about 3.6 MB/s. So the engine copies about 22–47 times as fast as `LDIR`, and **the CPU carries on at full speed meanwhile**.

Examples, with one full-screen 8 bpp layer at 2×, 8 sprites and the CPU busy:

| Job | Bytes | Engine | `LDIR` |
|-----|-------|--------|--------|
| Clear a 360 × 288 8 bpp screen | 103,680 | about 1.4 ms | 109 ms (5½ frames) |
| Copy a 360 × 288 8 bpp screen | 103,680 | about 2.8 ms | 109 ms |
| Clear a 64 × 32 tile map (2-byte entries) | 4,096 | about 55 µs | 4.3 ms |
| Copy a 32 × 32 8 bpp image into a screen (2D) | 1,024 | about 30 µs | 1.1 ms (32 `LDIR`s) |
| Load a 256-entry palette (768 bytes) from SRAM | 768 | about 25 µs | 0.8 ms |

These figures are worked out from the slot rules; open point D2 is to measure them in simulation. Making the CPU wait for the engine in a polling loop or in `HALT` frees few of its cycles; slowing the CPU (spec 7) does.

## 8. Channels and registers

Custom block offsets (spec 3, section 5). From the CPU: port = (offset bits 7–0) << 8 | (`0x10` + offset bits 9–8), used with `LD BC,port` then `OUT (C),r` or `IN r,(C)`; `INC B` steps to the next register. In the register page the engine is at `0x1140`–`0x123F` (offset + `0x1000`). The copper reaches it with MOVEF (section 9.2). Multi-byte values are low byte first and commit on their highest byte (spec 3, rule 2). Reserved offsets read `0xFF` and ignore writes (spec 3, rule 11).

**Channel bases:**

| Channel | Offsets | Ports | Register page |
|---------|---------|-------|---------------|
| 0 (`DMX0`) | `0x140`–`0x17F` | `0x4011`–`0x7F11` | `0x1140`–`0x117F` |
| 1 (`DMX1`) | `0x180`–`0x1BF` | `0x8011`–`0xBF11` | `0x1180`–`0x11BF` |
| 2 (`DMX2`) | `0x1C0`–`0x1FF` | `0xC011`–`0xFF11` | `0x11C0`–`0x11FF` |
| 3 (`DMX3`) | `0x200`–`0x23F` | `0x0012`–`0x3F12` | `0x1200`–`0x123F` |

### 8.1 Per channel

Channel n at `0x140 + n × 0x40`. The first 32 bytes are the **job registers**, laid out exactly as a descriptor (section 3): a job can be set up by writing them directly, or loaded into them from a descriptor in SRAM.

| Offset | Name | Bytes | Access | Bits | Meaning | Reset |
|--------|------|-------|--------|------|---------|-------|
| `+0x00`–`+0x02` | CTRL | 3 | RW | 23–0 | Operation and options (section 3) | 0 |
| `+0x04`–`+0x06` | SRC | 3 | RW | 23–0 | Source address or port | 0 |
| `+0x08`–`+0x0A` | DST | 3 | RW | 23–0 | Destination address or port | 0 |
| `+0x0C`–`+0x0E` | WIDTH | 3 | RW | 23–0 | Pixels per row | 0 |
| `+0x10`–`+0x12` | HEIGHT | 3 | RW | HEIGHT 15–0, SRCBIT 18–16, DSTBIT 22–20 | Rows; first pixels' positions in their bytes | 0 |
| `+0x14`–`+0x15` | DSTSTRIDE | 2 | RW | 15–0 | Signed destination stride | 0 |
| `+0x16`–`+0x17` | SRCSTRIDE | 2 | RW | 15–0 | Signed source stride | 0 |
| `+0x18`–`+0x1B` | VALUE | 4 | RW | 31–0 | Fill value, key colour or constant source | 0 |
| `+0x1C`–`+0x1E` | NEXT | 3 | RW | 23–0 | Next descriptor; 0 = end of chain | 0 |
| `+0x20`–`+0x22` | CHDESC | 3 | RW | 23–0 | The descriptor START loads (a multiple of 4). Read: the descriptor now running, or the last one loaded; it changes by itself as a chain runs, so reading `+0x20` captures all three bytes (spec 3, rule 4) | 0 |
| `+0x24` | CHCTRL | 1 | S (START, RUN, STOP), RW (PAUSE) | START (0), RUN (1), STOP (2), PAUSE (3) | Section 8.2 | 0 |
| `+0x28` | CHSTAT | 1 | R, W1C | BUSY (0), DONE (1), ERR (2), PAUSED (3) | Section 8.3 | 0 |
| `+0x2C`–`+0x2E` | CHERR | 3 | R | 23–0 | The address that caused the error, or the descriptor's address for a bad descriptor | 0 |

`+0x03`, `+0x07`, `+0x0B`, `+0x0F`, `+0x13`, `+0x1F`, `+0x23`, `+0x25`–`+0x27`, `+0x29`–`+0x2B` and `+0x2F`–`+0x3F` are reserved (in channel 3, `+0x30` and `+0x34` hold DMXINT and DMXINTEN, section 8.4).

**The job registers and CHDESC** can be written only while the channel is idle: writes while CHSTAT.BUSY is set are ignored, as in retro68k. The job registers keep the values of the last job loaded or written: the engine keeps its progress through a job inside itself, not in them. So after a job, writing only the fields that change (for example SRC and DST) and RUN starts a similar one, which suits the copper.

**Writing a whole job from memory:** the job registers are in address order with the low byte first, so `LDIR` of a 32-byte descriptor image into the register page writes every register correctly (the reserved bytes are ignored). It takes about 670 T-states (34 µs at 20 MHz). A descriptor in SRAM started with CHDESC and START needs only 4 register writes (section 9.1).

### 8.2 CHCTRL

| Bit | Name | Access | Meaning |
|-----|------|--------|---------|
| 0 | START | S | Load the descriptor at CHDESC into the job registers and run it. Ignored while BUSY. Reads 0 |
| 1 | RUN | S | Run the job already in the job registers. Ignored while BUSY. Reads 0 |
| 2 | STOP | S | End the chain after the current group (at most 16 bytes later). DONE is set; DMXINT is not. Reads 0 |
| 3 | PAUSE | RW | While set, the chain holds after its current group; BUSY stays set and PAUSED is set. Clearing it lets the chain carry on |
| 5–4 | – | – | Reserved (retro68k's CPUSHARE). Write 0 |
| 7–6 | – | – | Reserved. Write 0 |

Either way, at the end of each job the channel loads the descriptor at NEXT and runs it, until NEXT is 0. BUSY is set in the clock START or RUN is written, so a status read or a copper WAIT straight after it already sees the job. A START or RUN written while PAUSE is set starts the chain paused.

### 8.3 CHSTAT

| Bit | Name | Access | Meaning |
|-----|------|--------|---------|
| 0 | BUSY | R | A chain is running, paused, or waiting for DMACON.BLTEN |
| 1 | DONE | R, W1C | A chain reached its end (NEXT = 0) or was stopped. Sticky |
| 2 | ERR | R, W1C | A job stopped with an error (section 8.5). Sticky |
| 3 | PAUSED | R | The chain is held by CHCTRL.PAUSE |
| 7–4 | – | R | 0 |

BUSY is bit 0, so a polling loop is `IN A,(C)`, `RRA`, `JR C`.

### 8.4 Global

In channel 3's spare bytes, where retro68k has them (after its channel 3):

| Offset | Port | Register page | Name | Access | Bits | Meaning | Reset |
|--------|------|---------------|------|--------|------|---------|-------|
| `0x230` | `0x3012` | `0x1230` | DMXINT | W1C | CH3–CH0 (3–0) | A channel's interrupt is pending: a job with IRQ finished, or an error. Bits 7–4 read 0 | 0 |
| `0x234` | `0x3412` | `0x1234` | DMXINTEN | RW | CH3–CH0 (3–0) | Interrupt enables per channel. Bits 7–4 read 0 | 0 |

`0x231`–`0x233` and `0x235`–`0x23F` are reserved.

**DMACON** (spec 4): **BLTEN**, with DMAEN, lets the engine run. Both are clear after reset.

**Interrupts:** each channel is its own source in the interrupt controller (spec 8): **DMA0–DMA3, sources 4–7**. A channel requests its interrupt while its DMXINT bit and DMXINTEN bit are both set. The handler clears it by writing 1 to that DMXINT bit.

### 8.5 Errors

A bad address (section 4), a register or palette access breaking the rules, a bad OP, a bad combination of kinds or a reserved port (section 3), a CHDESC or NEXT that is not a multiple of 4 or not in SRAM, stops the channel: ERR is set, BUSY clears, CHERR holds the address (or the descriptor's address), CHDESC the descriptor, and the channel's DMXINT bit is set. The other channels carry on. A job written directly and started with RUN that is bad stops in the same way, with CHDESC unchanged.

## 9. Starting and waiting

### 9.1 From the CPU

1. One job: wait until the channel's BUSY is clear, write the job registers that change (NEXT = 0 for a single job), then RUN (`0x02`) to CHCTRL.
2. A chain: write descriptors to SRAM, the first one's address to CHDESC, then START (`0x01`) to CHCTRL. (Or write the first job into the job registers, with NEXT pointing at the rest, and RUN.)
3. Carry on. Take the interrupt, or poll CHSTAT.BUSY.

```
; Clear a 360 x 288 8 bpp screen at physical 0x020000 to colour 0, on channel 2.
; Channel 2's registers are custom offsets 0x1C0-0x1DF: page 0x11, so C stays
; 0x11 and only B changes. Names from hw.inc (spec 3, section 8).

clear:      ld   bc,DMX2_CHSTAT_P
.wait:      in   a,(c)
            rra                       ; BUSY into carry
            jr   c,.wait
            ld   b,high DMX2_CTRL_P   ; CTRL = FILL, 8 bpp, SRCKIND none
            ld   a,0x01
            out  (c),a
            inc  b
            ld   a,0x43
            out  (c),a
            inc  b
            xor  a
            out  (c),a                ; commits CTRL
            ld   b,high DMX2_DST_P    ; DST = 0x020000
            out  (c),a
            inc  b
            out  (c),a
            inc  b
            ld   a,0x02
            out  (c),a                ; commits DST
            ld   b,high DMX2_WIDTH_P  ; WIDTH = 103,680 = 0x019500, one row
            xor  a
            out  (c),a
            inc  b
            ld   a,0x95
            out  (c),a
            inc  b
            ld   a,0x01
            out  (c),a                ; commits WIDTH
            ld   b,high DMX2_HEIGHT_P ; HEIGHT = 1, SRCBIT = DSTBIT = 0
            out  (c),a
            inc  b
            xor  a
            out  (c),a
            inc  b
            out  (c),a                ; commits HEIGHT
            ld   b,high DMX2_VALUE_P  ; VALUE = 0
            out  (c),a
            inc  b
            out  (c),a
            inc  b
            out  (c),a
            inc  b
            out  (c),a                ; commits VALUE
            inc  b                    ; NEXT = 0: a single job
            out  (c),a
            inc  b
            out  (c),a
            inc  b
            out  (c),a                ; commits NEXT
            ld   b,high DMX2_CHCTRL_P
            ld   a,DMX_CHCTRL_RUN_M
            out  (c),a
            ret                       ; about 1.4 ms later the screen is clear
```

A chain in SRAM is quicker to start, and the jobs can be built once and reused:

```
; Clear the screen, then copy a 32 x 32 image to (164,100), with an interrupt
; at the end. Window 4 (0x8000-0x9FFF) holds SRAM page 0x012, so Z80 address
; 0x8000 + x is physical 0x024000 + x.

PHYS        equ  0x024000-0x8000      ; add to a window-4 address

            align 4
job1:       db   0x01,0x43,0x00,0     ; CTRL: FILL, 8 bpp, SRCKIND none
            dd   0                    ; SRC (not used)
            dd   0x020000             ; DST
            dd   103680               ; WIDTH
            dd   1                    ; HEIGHT
            dw   0,0                  ; DSTSTRIDE, SRCSTRIDE
            dd   0                    ; VALUE
            dd   job2+PHYS            ; NEXT
job2:       db   0x00,0x13,0x00,0     ; CTRL: COPY, 8 bpp, IRQ
            dd   0x030000             ; SRC: the image, 32 bytes a row
            dd   0x020000+100*360+164 ; DST
            dd   32                   ; WIDTH
            dd   32                   ; HEIGHT
            dw   360,32               ; DSTSTRIDE, SRCSTRIDE
            dd   0                    ; VALUE (not used)
            dd   0                    ; NEXT: end of chain

draw:       ld   bc,DMX2_CHDESC_P     ; the channel is idle
            ld   a,low (job1+PHYS)
            out  (c),a
            inc  b
            ld   a,high (job1+PHYS)
            out  (c),a
            inc  b
            ld   a,(job1+PHYS)>>16
            out  (c),a                ; commits CHDESC
            ld   b,high DMX2_CHCTRL_P
            ld   a,DMX_CHCTRL_START_M
            out  (c),a                ; DMA2 interrupts when job2 is done
            ret
```

### 9.2 From the copper

The engine's registers are past `0x0EF`, so the copper writes them with **MOVEF** (spec 6), one byte per instruction of two words. The copper reads its list in the free pool, ahead of the engine, at least one word per slot (cycle 4). Its writes go through its own latch (spec 3, rule 3), so they never mix with a CPU write in progress.

| Copper work | MOVEFs | Words read | Time, at one word per slot |
|-------------|--------|------------|----------------------------|
| RUN alone (the job registers already set) | 1 | 2 | 0.2 µs |
| START of a descriptor in SRAM (CHDESC, then START) | 4 | 8 | 0.8 µs |
| New SRC and DST, then RUN (a repeat of the last job) | 7 | 14 | 1.4 µs |
| A whole new job in the job registers, then RUN | 27 | 54 | 5.4 µs (about a sixth of a line) |

```
        CWAIT  100,0
        CMOVEF DMX3+DMX_CHDESC+0,low DESC     ; DESC: a descriptor in SRAM
        CMOVEF DMX3+DMX_CHDESC+1,high DESC
        CMOVEF DMX3+DMX_CHDESC+2,DESC>>16
        CMOVEF DMX3+DMX_CHCTRL,DMX_CHCTRL_START_M
        CWAITB 0,0                             ; wait until every channel is idle
```

Keep a strobe (START or RUN) out of the middle of a multi-byte value, so that a list cut off and run again never starts a job twice (spec 6).

### 9.3 The copper's B bit

The copper's WAIT has a **B** bit, as in retro68k: with B set, a WAIT also waits until **every channel** is idle (spec 6). The engine gives the copper one signal, **IDLE** = no channel's CHSTAT.BUSY set:

- IDLE goes low in the clock START or RUN is written, so a WAIT with B straight after the MOVEF that wrote it waits for that chain.
- IDLE goes high when the last busy channel's chain ends (its last write has reached memory), is stopped, or stops with an error.
- A paused chain, or one waiting for DMACON.BLTEN, is not idle. A WAIT with B while BLTEN is clear therefore waits until BLTEN is set (or the next frame restarts the copper).
- A long transfer on another channel (an SD card read, say) also holds a WAIT with B. A copper list that waits for its own blits should leave the other channels to the CPU's interrupts, or poll its channel's CHSTAT with a copper SKIP instead.

### 9.4 From a timer

With a timer's CTRL.DMA set, its underflow acts as a write of START to the CHCTRL of channel CTRL.DMACH (spec 9, section 4.5), as in retro68k: it loads and runs the descriptor at CHDESC, and is ignored while that channel is busy. Set up the descriptor and CHDESC first.

## 10. Suggested channel use

Software decides, but a sensible default, as retro68k's:

| Channel | Use |
|---------|-----|
| 0 | SD card |
| 1 | USB serial |
| 2 | General memory copies and fills |
| 3 | Graphics (blits), and the copper's jobs |

## 11. FPGA resources

| Item | Resource |
|------|----------|
| Job registers, CHDESC and latches, 4 channels | Flip-flops, or distributed RAM (about 4 × 40 bytes) |
| Per-channel state (the running job's positions) | Distributed RAM, one channel worked on at a time (as retro68k's `bpldma.v` and `sprites.v`) |
| Data buffer between reads and writes (16 bytes and the shifter's carry) | Logic |
| The shared datapath: 2D address units, byte and pixel shifter, edge masks, colour key compare, logic function, per-pixel adder | Estimate 1,500–2,500 LUTs, as retro68k's, to confirm by synthesis; pipelined from the start for 100 MHz |
| Block RAM | None in version 1 (a descriptor RAM would be one RAMB18, open point D5) |

## 12. Test plan

- **Copy and fill:** linear and 2D, every BPP, starting and ending part-way through a byte, every combination of even and odd SRC and DST, positive, zero and negative strides, forwards and backwards (DESC) with overlapping areas. Compare the whole SRAM with a Python model of this spec.
- **FILL's value:** the 4-byte pattern by address, least significant byte first, at every starting address mod 4; a tile map fill with 2-byte entries.
- **KEYCOPY and LOGIC:** every BPP, with key pixels at the edges; every FN.
- **ADD:** every BPP, wrap and saturate, signed and unsigned, memory and constant sources; carries never cross pixels.
- **Chains:** a chain of mixed jobs in SRAM; IRQ only on the marked ones; jobs of zero width or height; a CHDESC or NEXT not a multiple of 4.
- **Direct jobs:** a job written into the job registers and started with RUN, with and without a NEXT chain after it; job register and CHDESC writes ignored while BUSY; the job registers read back as loaded; `LDIR` of a 32-byte image through the register page sets a job.
- **Registers:** commit on the highest byte; reserved offsets read `0xFF`.
- **Channels:** all 4 running at once, taking turns; a stalled port channel does not hold up the others; STOP and PAUSE, and a START or RUN while PAUSE is set.
- **Free cycles only:** with the CPU at 20 MHz, 2.5 MHz and 3.57 MHz, the display, copper and sprites busy, the engine never takes a cycle another user wanted: CPU accesses, layer and sprite fetches (no OVERRUN or SPRUNDER on a screen within budget) and copper reads are exactly the same with and without jobs running.
- **Boot ROM:** a COPY from the boot ROM to SRAM (the console font) gives the ROM's bytes, with no SRAM read cycles.
- **Errors:** a bad address (the system block, a write to the boot ROM, past the end of a 2 MB board), a bad OP, MIX, a bad combination, DESC on registers or palettes and a reserved port each stop only that channel, set ERR and CHERR, and raise its interrupt.
- **Register targets:** a block COPY into a layer's registers gives exactly the same result as CPU writes; a COPY into CHCTRL starts another channel; two channels writing multi-byte registers at once never mix; register reads into SRAM, with a captured register read consistently; a CPU register access is never delayed by the engine.
- **Palettes:** COPY into a palette changes entries as their red bytes arrive; a saturating ADD fades a palette.
- **Ports:** an SD card read of a block through port 0 with SDCOUNT (with the SD model in `sim/`); a USB serial transfer each way through port 1, paced by the FIFOs.
- **Interrupts:** DMA0–DMA3 requested only with DMXINT and DMXINTEN bits both set; W1C clears them.
- **Copper and timers:** a job set up and started by MOVEFs; a WAIT with B right after the start waits for every channel; a timer underflow with CTRL.DMA starts channel DMACH as a START write would, and is ignored while it is busy.
- **DMACON:** a chain waits while BLTEN or DMAEN is clear, including register and port jobs, and finishes when it is set again.
- **Ordering:** a CPU write made just before the START or RUN is seen by the job's first read, at every CPU speed (spec 7).
- **Speed:** the figures of section 7.

## 13. Open points

| # | Item |
|---|------|
| D1 | Check the engine fits and meets timing at 100 MHz, and uses back-to-back free cycles |
| D2 | Measure the speed figures of section 7 in simulation |
| D3 | Line drawing, area fill, and scaling or rotating blits: later, as retro68k's D3 |
| D4 | MIX (section 3.1): on hold until it has proper resampling, as retro68k's D4 |
| D5 | A descriptor RAM, as retro68k's: 2 KB (64 descriptors) in one RAMB18, with no SRAM cycles to load a descriptor, for short frequent jobs. It needs a block RAM from the budget (spec 4 sets the video's share) and an address: an MMU page of its own (for example `0x3F9`), which the CPU could also map, rather than room in the register page. Not in version 1 |
| D6 | OP 6 and 7: a drawing job for flat-shaded 3D (design plan, branch 10), span filler or triangle job. To be agreed with retro68k, so both machines use the same codes and registers. CTRL.FN and the reserved bytes `+0x2F`–`+0x3F` of each channel give room |
| D7 | Closed: the job queue is deferred (design plan, branch 11); descriptor chains do most of its work |
| D8 | Closed: VALUE's byte order is little-endian, unlike retro68k (section 2). It follows the SRAM and the Z80 |
| D9 | Closed: no HIGH mode (design plan, branch 11). The Z80 never gives up its cycles; CTRL bit 11 is ignored so retro68k's jobs still run |
| D10 | Closed: DMXINT and DMXINTEN sit in channel 3's spare bytes at `0x230` and `0x234`, where retro68k has them relative to its channel 0, so the engine stays inside `0x140`–`0x23F` |
