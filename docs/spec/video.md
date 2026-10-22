# Spec 4: Video

Status: **draft**

## 1. Summary

The video makes one 576p picture, sent over HDMI and VGA at once. It has four layers (background colour, bitmap, tiles, attribute layer) and the sprites of [spec 5](sprites.md), mixed into a 512-entry palette of 12-bit colours. Each layer has its own window, scroll, depth, width (360 or 720 pixels across) and height (288 or 576 lines). The data is read from SRAM just ahead of where it is drawn, into small FIFOs, so a line's fetch can use the whole line time.

| Item | Value |
|------|-------|
| Output | 576p (720 × 576, 50 Hz, CEA-861), 27 MHz pixel clock; DVI over HDMI and 24-bit VGA through the ADV7125, same picture |
| Normal picture | 360 × 288 at 2× (each picture pixel is 2 × 2 beam pixels), the whole screen |
| Layers, back to front | Background colour, bitmap, sprites with BEHIND set, tiles, sprites, tiles with their priority bit set |
| Bitmap | 1, 2, 4 or 8 bits per pixel; window, X and Y scroll, stride, Y wrap, X wrap; line address taken from a register at every line |
| Tiles | 8 × 8 pixels, 1, 2, 4 or 8 bits per pixel; a 64 × 32 map (128 × 32 in hi-res) of 2-byte entries: tile number, bank, X/Y flip, priority |
| Attribute layer | 8 × 8 or 8 × 1 cells, one byte each, replacing the high bits of the bitmap's or the tile layer's palette index; flash |
| Per layer | Hi-res (720 across) or 2× (360); 576 lines or 288 (each shown twice) |
| Palette | 512 entries of RGB444, index/data ports, changes land on the pixel the copper waited for |
| Pipeline | Fetch (FIFOs, just ahead of the draw beam), draw (system clock, one output line ahead of the display), show (pixel clock) |
| Memory | Cycle 1 of every slot; cycle 3 when the copper leaves it (urgent fetches before sprites); any cycle another owner leaves unused |
| Peak budget | Per output line: 448 bytes in cycle 1 alone, 896 with all of cycle 3 |
| Interrupts | VBLANK, LINE, OVERRUN ([spec 8](interrupts.md)) |
| Ports | `0x40`–`0x7F` (section 9) |
| Block RAM | 6 RAMB18 (section 10), sprites not counted |

## 2. Clocks and timing

### 2.1 Clocks

| Clock | Frequency | From | Use |
|-------|-----------|------|-----|
| System | 56 MHz | MMCM 1 (50 MHz × 21 = 1050 MHz VCO, ÷ 18.75) | Fetch and draw stages, registers, SRAM |
| Pixel | 27 MHz | MMCM 2 (50 ÷ 5 × 108 = 1080 MHz VCO, ÷ 40), as in retro68k | Show stage, sync, VGA |
| HDMI serialiser | 135 MHz | MMCM 2 (÷ 8) | OSERDESE2, 10 bits per pixel at double rate |

Both come from one oscillator, so one 576p line (864 pixels, 32 µs) is exactly **1792 system clocks = 224 memory slots**. The phase between the two clocks is not known, so they are treated as asynchronous; only a few signals cross (section 4.6).

### 2.2 The mode

| Item | Value |
|------|-------|
| Visible | 720 × 576, 50 Hz progressive (CEA-861 formats 17 and 18) |
| Horizontal | 720 visible, front porch 12, sync 64, back porch 68: 864 pixels (32 µs) |
| Vertical | 576 visible, front porch 5, sync 5, back porch 39: 625 lines (20 ms) |
| Sync | Both active low |
| Pixels | Not square: on a 4:3 screen a beam pixel is 16/15 as wide as it is tall |

There are no timing registers.

### 2.3 Beam coordinates

Every position (windows, sprite X and Y, copper waits, line compare) is in beam coordinates, which count the blanking:

| | Pixels (across) | Lines (down) |
|--|--|--|
| 0 | Start of horizontal blank | Start of vertical blank |
| Blank | 0–143 | 0–48 |
| Picture | 144–863 (720) | 49–624 (576) |
| Total | 864 | 625 |

A 2× layer pixel covers 2 beam pixels; a 288-line layer's line covers 2 beam lines. The full-screen 360 × 288 picture is the window 144–864 × 49–625; a Spectrum-size 256 × 192 window at 2×, centred, is pixels 248–759, lines 145–528.

### 2.4 Output

The HDMI (DVI) and VGA outputs are retro68k's platform modules, copied in: `ks3_clocks.v` (MMCMs), `tmds_encoder.v`, `hdmi_out.v` and `vga_out.v` in `fpga/rtl/platform/artix7/`. Each 4-bit channel is widened to 8 bits by repeating it (`0xA` becomes `0xAA`), so full scale stays full scale. Outside the picture the outputs are black with sync. The output runs from configuration, with or without any layer on.

## 3. Layers and colour

### 3.1 Palette index

Every layer pixel is turned into a 9-bit palette index. A layer of d bits per pixel (d = 1, 2, 4, 8) with pixel value p and bank B forms

    index = ((B << d) | p) & 0x1FF

so only the low 9 − d bits of the bank are used:

| d | Bank bits used | Meaning |
|---|----------------|---------|
| 1 | 8 | 256 pairs of colours |
| 2 | 7 | 128 groups of 4 |
| 4 | 5 | 32 groups of 16 |
| 8 | 1 | The low or high 256 entries |

| Layer | Bank B |
|-------|--------|
| Bitmap | BMBANK (8 bits) |
| Tiles | TLBANK × 16 + the entry's 4-bit bank (section 6.2) |
| A layer the attribute layer targets | The attribute byte, in place of the above (section 7) |
| Sprites | Their BANK ([spec 5](sprites.md), section 2.3), same rule |

### 3.2 Transparency and order

A pixel is **transparent** when its value p is 0 (after flash, section 7) and its layer's TRANSP bit is set. With TRANSP clear the layer is solid inside its window, so a Spectrum screen's paper (p = 0) shows. Sprite pixels of value 0 are always transparent. Outside its window, when disabled, or on a line it was not fetched for, a layer is transparent.

Order, back to front:

| # | Source |
|---|--------|
| 1 | Background colour (BGCOL) |
| 2 | Bitmap |
| 3 | Sprites with BEHIND = 1 |
| 4 | Tile pixels whose entry has PRI = 0 |
| 5 | Sprites with BEHIND = 0 |
| 6 | Tile pixels whose entry has PRI = 1 |

The output pixel is the front-most non-transparent source. Sprites among themselves are ordered by spec 5 (the lower number in front); the sprite unit gives the draw stage one entry per pixel (OPAQUE, BEHIND, palette index). Where a layer's data was late (section 4.5), the pixel shows the background colour whatever else is there.

### 3.3 Palette

512 entries of 12-bit RGB, in block RAM, read by the draw stage. Each entry is two bytes, written low byte first:

| Byte | Bits 7–4 | Bits 3–0 |
|------|----------|----------|
| 0 (low) | Green | Blue |
| 1 (high) | 0 | Red |

So an entry is the 16-bit value `0x0RGB`. BGCOL has the same format.

- **Access:** PALIDX0 and PALIDX1 hold the 9-bit index (writing PALIDX1 commits it, as for any 2-byte value). PALDAT reads or writes the entry at the index, low byte then high byte; a flip-flop picks the byte and is reset when the index is committed. A low-byte write is held; the **high-byte write changes the entry** and steps the index (from 511 to 0). A high-byte read steps it too. So `OTIR` with B = 2n writes n entries.
- **Timing:** a palette write acts at the draw beam: pixels drawn after it use the new colour, so the copper changes a colour at an exact pixel.
- The palette is not cleared by reset. Its contents at configuration are a default set by the bitstream (open point V8); the boot ROM writes the colours it uses.

## 4. Pipeline

### 4.1 Overview

```
 SRAM ──cycle 1, 3──▶ FIFOs ──▶ draw beam ──▶ line buffer ──▶ show ──▶ HDMI, VGA
        (fetch)       (block RAM)  │  ▲  (56 MHz)  (2 × 720 × 12)   (27 MHz)
                                   ▼  │
                          repeat buffers, sprite line buffer (spec 5), palette
```

| Stage | Clock | Runs | Work |
|-------|-------|------|------|
| Fetch | 56 MHz | Just ahead of the draw beam, from the horizontal blank of the line being drawn | Reads bitmap, tile map, tile pattern and attribute data into one FIFO per source |
| Draw | 56 MHz | One output line ahead of the display beam | Takes pixels from the FIFOs (or repeat buffers), applies scroll, flip, banks, attributes, flash, transparency, priority and sprites, looks up the palette, writes the final 12-bit colour into the line buffer |
| Show | 27 MHz | With the display beam | Reads the line buffer out to HDMI and VGA |

Sprites are fetched and rendered by spec 5 a line before the draw (each line's rows during the line before); the draw stage only reads the sprite line buffer.

### 4.2 The draw beam

The system side keeps its own line and clock counters, restarted at each display line start (section 4.6). During display line k (system clocks 0–1791 of that line), the **draw beam** is on line k + 1 (624 is followed by 0) and passes beam pixel h at system clock 2h:

| System clocks | Draw beam |
|---------------|-----------|
| 0–287 | Pixels 0–143: horizontal blank. Nothing drawn; FIFOs prefill; copper waits here work |
| 288–1727 | Pixels 144–863: one output pixel every 2 clocks, 720 in 1440 clocks |
| 1728–1791 | Past pixel 863: nothing drawn (64 clocks of slack) |

The draw beam position is the position of the pixel at the palette lookup; register values are delayed inside the pipeline to match, so a write that lands at draw beam (L, P) acts on the pixel shown at (L, P). The copper ([spec 6](copper.md)) waits on the draw beam. The CPU's beam registers (section 8) report the display beam, which is one line behind.

The frame starts for the draw beam at (0, 0), during display line 624.

### 4.3 Fetch: FIFOs

Each source has a FIFO in block RAM (section 10):

| Source | FIFO | Holds |
|--------|------|-------|
| Bitmap | 256 bytes | Pixel data words, in screen order |
| Tile map | 128 bytes | Map entries for the coming columns |
| Tile patterns | 256 bytes | Each column's pattern row (1–8 bytes), with its entry |
| Attributes | 128 bytes | Attribute bytes |

- At draw beam (L, 0) the fetch unit copies the layer's fetch registers (section 4.7) and works out the line's addresses. Each FIFO then **prefills** during the horizontal blank and is **topped up** as the draw beam takes data, until the line's data has all been read.
- Fetching can use the whole line time, 864 pixel times for 720 pixels. At the most the FIFO must hold what is fetched before the first picture pixel: 144/864 = one sixth of the line's data. The biggest line one source can have is 910 bytes (hi-res 8-bit tiles), so the figure is about 152 bytes; 256 (128 for small sources) leaves room for uneven cycles. A full FIFO stops its source's fetch.
- The tile map FIFO runs a few columns ahead of the pattern fetch, which takes each entry, reads its pattern row (row 7 − r with Y flip) and pushes the entry and the row together.
- **Low mark:** a FIFO holding less than 32 output pixels' worth of data ahead of the draw beam is **urgent**. Urgent fetches go before sprites in cycle 3.
- Data is fetched as 16-bit words at even addresses. A line starting at an odd byte, or ending at one, reads a whole word.

**Memory cycles** ([spec 2](memory.md)):

| Cycle | Video use |
|-------|-----------|
| 1 | Always the display's, when a FIFO has room and its line is not finished (urgent sources first, then bitmap, tile map, patterns, attributes in turn) |
| 3 | In this order: copper; an urgent display FIFO; sprites; display top-up |
| 0, 2 | When the CPU leaves them unused |

### 4.4 288-line layers and repeat buffers

A 288-line layer's lines are pairs of beam lines. Pairs start at the layer's window top: lines YSTART and YSTART + 1, then YSTART + 2 and YSTART + 3, and so on.

- On the **first line** of a pair the layer is fetched and drawn as a 576-line layer is, and the draw stage also writes each of its pixels into the layer's **repeat buffer**: 720 entries of 16 bits (pixel value after flip, the tile entry's bank and PRI, and a late flag).
- On the **second line** the layer is not fetched. The draw stage reads the repeat buffer instead. Its cycles are free for others.
- Everything after the repeat buffer is done again on the second line: the bank registers, the attribute byte, flash, transparency, priority, sprites and the palette. So palette, background, bank, enable and sprite changes act on the second line as on the first; fetch register writes (section 4.7) do not.
- The attribute layer has its own FIFO and its own small repeat buffer (128 bytes), and is applied while drawing on both lines.
- A 288-line layer whose window ends on the first line of a pair shows just that line.

### 4.5 Late data (OVERRUN)

If the draw beam needs a source's data and its FIFO is empty, the data is **late**:

- From that pixel, the layer's pixels show the **background colour** (all layers and sprites are hidden there), until the data arrives.
- The fetch unit skips the data the draw beam has passed, and carries on from just ahead of it, so one late line never spoils the next.
- VIDSTAT.OVERRUN is set, with the late layer's bit (OVBM, OVTL, OVAT), and the OVERRUN request line pulses once for that line.
- On a 288-line layer the late flag goes into the repeat buffer, so the second line shows the same pixels as background.
- Nothing else is affected: the CPU never waits, and the next line starts its fetch on time.

Sprite fetches that are late are spec 5's (SPRSTAT.LATE); they do not set OVERRUN.

### 4.6 Clock domain crossing

| Signal | Crossing |
|--------|----------|
| Line start, frame start | The show side toggles a flip-flop at each display line start (pixel 0), with a frame flag at line 0. Two flip-flops at 56 MHz; the system side restarts its clock counter (0) on each, and sets its line counter to 0 on the frame flag, else adds 1 |
| Line buffer | A true dual-port block RAM: written at 56 MHz, read at 27 MHz. The half is the line's bit 0, which both sides know. No handshake |
| Beam position for the CPU | The show side's counters, sampled at 56 MHz until two samples agree, as in retro68k |

Nothing else crosses: all layer logic and registers are on the system side.

**Margins.** Line L is drawn during display line L − 1, from about display pixel 139 (system clock 288) to about display pixel 836 (clock 1727, plus a few clocks of pipeline). Its half of the line buffer was last read for line L − 2, which ended before display line L − 1 started; it is read for line L from display pixel 144 of line L, about 170 pixels (6 µs) after the draw ends. Both margins are far larger than the crossing's few clocks.

### 4.7 When register writes take effect

| Registers | Take effect |
|-----------|-------------|
| **Fetch registers:** BMCTL, BMADDR, BMSTRIDE, BMSCRX, BMSCRY, BMHEIGHT, TLCTL, TLMAP, TLTILE, TLSCRX, TLSCRY, ATCTL, ATADDR, ATSTRIDE, ATSCROLL, the windows | Copied at the start of the layer's next output-line fetch, at draw beam (L, 0). A value committed before (L, 0) acts on line L; one committed at or after it, from line L + 1. On a 288-line layer, from the next pair: to change the pair starting at L, write during draw lines L − 2 or L − 1 |
| **Pixel registers:** VIDCTL, BGCOL, PALIDX, PALDAT, BMBANK, TLBANK | At the draw beam, from the pixel where the write lands |
| LINECMP, VIDSTAT | At once |

**Layer enables.** A layer is fetched for line L if its VIDCTL bit is set at (L, 0) and its window covers L. It is drawn where its bit is set at the draw beam. So turning a layer off, or back on, within a line works at the pixel; a layer turned on during a line it was not fetched for stays transparent until the next fetched line.

## 5. Bitmap layer

### 5.1 Format

Pixels of d bits are packed in bytes, the leftmost pixel in the highest bits, bytes left to right at rising addresses. Picture line n of the bitmap is BMSTRIDE bytes after line n − 1.

### 5.2 Line address and Y scroll

For each layer line the fetch takes its line address from the registers:

    line address = BMADDR + ((BMSCRY + n) mod H) × BMSTRIDE

where H = BMHEIGHT (0 means no wrap), and n counts the layer lines fetched since the last **restart**. A restart (n = 0) happens at the window's top line, and at any line whose fetch starts after BMADDR or BMSCRY was written. So:

- With nothing rewritten, the bitmap is a plain picture, Y scrolled by BMSCRY, wrapping after H lines (endless vertical scroll in a ring of H lines).
- A write of BMADDR before a line's fetch sets that line's address (with BMSCRY = 0, exactly BMADDR), and the following lines go on from it by BMSTRIDE. Writing it on every line, as the copper does for the Spectrum's row order, sets every line's address.
- BMSTRIDE is signed: a negative stride shows the picture upside down; 0 repeats one line.
- The multiply is done in the horizontal blank by shifts and adds; addresses wrap at 4 MB.

### 5.3 X scroll and X wrap

BMSCRX (10 bits) is the first picture pixel shown at the window's left edge: the fetch starts at byte `(BMSCRX × d) >> 3` of the line, skipping `BMSCRX mod (8 ÷ d)` pixels (none at 8 bits). With BMCTL.WRAPX set, the byte offset within the line wraps at BMSTRIDE (which must then be positive), so a picture BMSTRIDE bytes wide scrolls round endlessly; a word that crosses the wrap point is read as two.

### 5.4 Window, hi-res, height

The window (BMXS ≤ x < BMXE, BMYS ≤ y < BMYE, beam coordinates) is where the layer shows. A start in the blank counts as the picture's edge, where the layer's first pixel then shows; an end past the picture counts as its end. HIRES: one layer pixel per beam pixel (720 across); else two (360). L576: one layer line per beam line; else a pair (section 4.4). The fetch reads only what the window shows: `⌈(skip + width) × d ÷ 8⌉` bytes, width in layer pixels.

### 5.5 BMCTL

| Bits | Field | Meaning |
|------|-------|---------|
| 1–0 | DEPTH | 0: 1 bit, 1: 2 bits, 2: 4 bits, 3: 8 bits per pixel |
| 2 | HIRES | 720 across (1 = hi-res) |
| 3 | L576 | 576 lines (1) or 288 (0) |
| 4 | TRANSP | Pixel value 0 is transparent |
| 5 | WRAPX | X wrap at the stride |
| 7–6 | – | Reserved, write 0 |

## 6. Tile layer

### 6.1 Map and tiles

- The **map** is 64 × 32 entries (512 × 256 pixels) at TLMAP, or **128 × 32** in hi-res (1024 × 256 pixels), so that 90 columns fit. Entry (column c, row r) is at `TLMAP + (r × W + c) × 2`, W = 64 or 128: 4 KB or 8 KB. TLMAP is even.
- A **tile** is 8 × 8 pixels of d bits (the layer's DEPTH): 8, 16, 32 or 64 bytes, row 0 first, each row d bytes, packed as the bitmap's. Tile t's row y is at `TLTILE + t × 8d + y × d`. Up to 512 tiles (4 KB at 1 bit, 32 KB at 8 bits).
- **Scroll:** TLSCRX (9 bits, 10 in hi-res) and TLSCRY (8 bits) give the map pixel at the window's top-left. Both wrap round the map, so the map scrolls endlessly in both directions. For layer line n of the window: map y = (TLSCRY + n) mod 256, map row = y >> 3, tile row = y & 7.
- Window, HIRES, L576 and TRANSP are as the bitmap's. A line fetches `⌈((TLSCRX & 7) + width) ÷ 8⌉` columns: 46 at full width (45 when TLSCRX is a multiple of 8), 91 in hi-res.

### 6.2 Map entry

Two bytes, low byte first:

| Bits | Field | Meaning |
|------|-------|---------|
| 8–0 | TILE | Tile number, 0–511 |
| 12–9 | BANK | Low 4 bits of the bank: B = TLBANK × 16 + BANK (section 3.1) |
| 13 | XFLIP | Tile mirrored left to right |
| 14 | YFLIP | Tile upside down |
| 15 | PRI | Opaque pixels in front of all sprites (section 3.2) |

So the high byte is: bit 0 TILE8, bits 4–1 BANK, bit 5 XFLIP, bit 6 YFLIP, bit 7 PRI.

**Colours by depth** (section 3.1):

| Depth | Index | Use |
|-------|-------|-----|
| 1 bit | (TLBANK × 16 + BANK) × 2 + p | Text: a colour pair per character, 16 pairs per TLBANK value |
| 2 bits | ((TLBANK & 7) × 16 + BANK) × 4 + p | |
| 4 bits | ((TLBANK & 1) × 16 + BANK) × 16 + p | 16 groups of 16 per tile, TLBANK bit 0 picks the half |
| 8 bits | (BANK & 1) × 256 + p | The entry's BANK bit 0 picks the low or high 256 entries; 8-bit tiles can use the whole palette |

### 6.3 TLCTL and TLBANK

| Register | Bits | Field |
|----------|------|-------|
| TLCTL | 1–0 DEPTH, 2 HIRES, 3 L576, 4 TRANSP, 7–5 reserved | As BMCTL |
| TLBANK | 3–0 | High bits of the bank; 7–4 reserved |

## 7. Attribute layer

The attribute layer draws nothing. It replaces the bank of its **target**, the bitmap or the tile layer (ATCTL.TARGET), with one byte per cell.

- **Cells** are 8 target pixels across and 8 or 1 target lines down (ATCTL.CELL1). They follow the target's HIRES and L576, so an 8 × 8 cell on a 288-line, 2× bitmap covers 16 × 16 beam pixels.
- **Window:** the target's window. The attribute layer only acts where its target does, so it has no window of its own.
- **Addresses:** ATADDR is the address of the cell row at the window's top-left; each cell row is ATSTRIDE bytes (0–255) after the one before. The row address steps by ATSTRIDE after every 8 target lines (8 × 8) or every target line (8 × 1). A restart (row address = ATADDR) happens at the window's top line and at any line whose fetch starts after ATADDR was written, so the copper can set any row's address.
- **Scroll:** ATSCROLL bits 2–0 shift the cells left by 0–7 target pixels; bits 6–4 start the first cell row 0–7 lines into the row (8 × 8 only). Coarse scroll is by ATADDR. To follow a scrolled target, set fine X = target scroll & 7 and move ATADDR by the rest.
- **Index:** with attribute byte A, the target's pixel p of d bits gives `index = ((A << d) | p) & 0x1FF`. For a 1-bit target, **index = A × 2 + p**: a Spectrum attribute byte (flash, bright, paper, ink) picks a pair of entries, 2A for paper and 2A + 1 for ink. For a 2-bit target A picks one of 128 groups of 4; for a 4-bit target one of 32 groups of 16 (bits 4–0); for an 8-bit target bit 0 picks the half. The tile entry's BANK and TLBANK, or BMBANK, are not used.
- **Flash:** with ATCTL.FLASH set, bit 7 of A is a flash bit. While the flash phase is on, a cell with bit 7 set has its pixel value inverted (p XOR (2^d − 1)), which swaps the pair for a 1-bit target. Transparency is tested after this. The phase changes every 8, 16, 32 or 64 frames (ATCTL.RATE; the Spectrum's is 16) and can be read in VIDSTAT.FLASH. Bit 7 still forms the index for a 1-bit target, so entries 256–511 should repeat 0–255 for Spectrum colours.
- Fetch: `⌈(fine X + width) ÷ 8⌉` bytes per target line (46 at full width, 91 in hi-res), fetched on every target line.

| ATCTL bits | Field | Meaning |
|------------|-------|---------|
| 0 | TARGET | 0: bitmap, 1: tile layer |
| 1 | CELL1 | 0: 8 × 8 cells, 1: 8 × 1 |
| 2 | FLASH | Bit 7 of the attribute is a flash bit |
| 4–3 | RATE | Flash phase every 8, 16, 32, 64 frames |
| 7–5 | – | Reserved |

The attribute layer is on when VIDCTL.ATEN is set and its target is on.

## 8. Beam, interrupts and status

- **HBEAM, VBEAM** (read only): the **display** beam's pixel (0–863) and line (0–624). Reading HBEAM0 takes one sample of both (section 4.6) into a latch; HBEAM1, VBEAM0 and VBEAM1 then read the latch, so the four bytes always match. Read HBEAM0 first.
- **LINECMP** (10 bits): the LINE event happens when the display beam reaches pixel 0 of line LINECMP. A value above 624 never matches. Since the draw beam is a line ahead, a CPU handler's pixel register writes land on line LINECMP + 1 or later.
- **VBLANK** happens when the display beam reaches (0, 0). The first picture line, 49, is fetched from draw beam (49, 0), during display line 48, so the CPU has about 48 lines (1.5 ms) to set up the next frame.

Each event sets a sticky VIDSTAT flag and gives a one-clock pulse on its request line to the interrupt controller ([spec 8](interrupts.md): VBLANK, LINE, OVERRUN), which latches and masks it.

**VIDSTAT** (`0x41`). Writing 1 clears a sticky bit.

| Bit | Name | Meaning |
|-----|------|---------|
| 0 | VBLANK | Sticky: a frame started |
| 1 | LINE | Sticky: line compare matched |
| 2 | OVERRUN | Sticky: some layer data was late (section 4.5) |
| 3 | OVBM | Sticky: bitmap data was late |
| 4 | OVTL | Sticky: tile data (map or patterns) was late |
| 5 | OVAT | Sticky: attribute data was late |
| 6 | FLASH | Live, read only: the flash phase |
| 7 | INVBL | Live, read only: the display beam is in lines 0–48 |

## 9. Registers

All 8-bit, in I/O ports `0x40`–`0x7F` ([spec 3](registers.md)). Multi-byte values are at consecutive ports, low byte first; the highest byte's write commits the value. Reading gives the committed value. All are 0 after reset (layers off, windows empty, background black). The copper can write all of them. Every register the copper changes per line (scroll, bitmap line address, palette, background colour, banks, layer enables) is a direct port.

| Port | Name | R/W | Meaning |
|------|------|-----|---------|
| `0x40` | VIDCTL | RW | Bit 0 BMEN, 1 TLEN, 2 ATEN (layer enables); 7–3 reserved |
| `0x41` | VIDSTAT | RW | Status (section 8) |
| `0x42`–`0x43` | BGCOL0–1 | RW | Background colour, `0x0RGB` (section 3.3) |
| `0x44`–`0x45` | PALIDX0–1 | RW | Palette index, 9 bits (PALIDX1 bit 0 = index bit 8) |
| `0x46` | PALDAT | RW | Palette data, low byte then high byte (section 3.3) |
| `0x47`–`0x48` | LINECMP0–1 | RW | Line compare, 10 bits |
| `0x49`–`0x4A` | HBEAM0–1 | R | Display beam pixel, 10 bits; reading HBEAM0 latches all four beam bytes |
| `0x4B`–`0x4C` | VBEAM0–1 | R | Display beam line, 10 bits |
| `0x4D` | ATCTL | RW | Attribute layer control (section 7) |
| `0x4E`–`0x50` | ATADDR0–2 | RW | Attribute cell row address, 22 bits |
| `0x51` | ATSTRIDE | RW | Bytes per cell row, 0–255 |
| `0x52` | ATSCROLL | RW | Bits 2–0 fine X, 6–4 fine Y |
| `0x53` | BMCTL | RW | Bitmap control (section 5.5) |
| `0x54` | BMBANK | RW | Bitmap palette bank, 8 bits |
| `0x55`–`0x57` | BMADDR0–2 | RW | Bitmap address (section 5.2), 22 bits |
| `0x58`–`0x59` | BMSTRIDE0–1 | RW | Bytes from line to line, 16 bits signed |
| `0x5A`–`0x5B` | BMSCRX0–1 | RW | X scroll, 10 bits, layer pixels |
| `0x5C`–`0x5D` | BMSCRY0–1 | RW | Y scroll, 10 bits, layer lines |
| `0x5E`–`0x5F` | BMHEIGHT0–1 | RW | Y wrap after this many lines, 10 bits; 0 = no wrap |
| `0x60` | TLCTL | RW | Tile layer control (section 6.3) |
| `0x61` | TLBANK | RW | Tile bank high bits, 4 bits |
| `0x62`–`0x64` | TLMAP0–2 | RW | Map address, 22 bits, even |
| `0x65`–`0x67` | TLTILE0–2 | RW | Tile pattern address, 22 bits |
| `0x68`–`0x69` | TLSCRX0–1 | RW | X scroll, 9 bits (10 in hi-res) |
| `0x6A` | TLSCRY | RW | Y scroll, 8 bits |
| `0x6B`–`0x6F` | – | | Reserved: read `0xFF`, writes ignored |
| `0x70`–`0x71` | BMXS0–1 | RW | Bitmap window: first beam pixel, 10 bits |
| `0x72`–`0x73` | BMXE0–1 | RW | Bitmap window: beam pixel after the last |
| `0x74`–`0x75` | BMYS0–1 | RW | Bitmap window: first beam line |
| `0x76`–`0x77` | BMYE0–1 | RW | Bitmap window: beam line after the last |
| `0x78`–`0x7F` | TLXS, TLXE, TLYS, TLYE | RW | Tile window, the same layout |

59 of the 64 ports are used, all direct; no index/data pair was needed for settings. Section 4.7 says when each takes effect.

## 10. Memory budget

### 10.1 Rule

The display has cycle 1 of every slot: 224 cycles, **448 bytes per output line**, guaranteed. With all of cycle 3 (no copper, no sprites) it has **896**. Cycles the CPU leaves unused add more, but are not counted on.

A layer's cost falls on the lines it fetches: every line for a 576-line layer, the **first line of each pair** for a 288-line layer (the second is replayed). So the budget is a **peak per output line**: add the costs of the layers fetched on that line. Up to 448 bytes always fits. Beyond that, the FIFOs go urgent and take cycle 3 before sprites, so up to 896 fits less what the copper uses; sprites get less (spec 5). Settings over the budget are allowed: the data that does not arrive in time is late (section 4.5), shown as background colour, and sets OVERRUN.

**Tip:** 288-line layers whose windows start on lines of opposite parity fetch on alternate lines, so their costs do not add up on the same line.

### 10.2 Cost per layer line

Costs are in bytes of memory cycles (2 per cycle), full width, with scroll:

| Layer | 1 bit | 2 bits | 4 bits | 8 bits | Hi-res (720) |
|-------|-------|--------|--------|--------|--------------|
| Bitmap, 360 wide | 46 | 92 | 182 | 362 | About twice: 92 / 182 / 362 / 722 |
| Tiles: data (map + patterns) | 138 | 184 | 276 | 460 | 273 / 364 / 546 / 910 |
| Tiles: memory cycles | 184 | 184 | 276 | 460 | 364 / 364 / 546 / 910 |
| Attributes | 46 | | | | 92 |

A tile column costs one cycle for its map entry and d ÷ 2 cycles for its pattern row, but a 1-bit row (one byte) still takes a whole cycle, so 1-bit tiles cost as much memory time as 2-bit ones. A narrower window costs less in proportion. Sprites are counted in spec 5.

### 10.3 Worked examples

**Spectrum screen: 256 × 192, 1 bit, 8 × 8 attributes.** Bitmap: DEPTH 0, 2×, 288 lines, TRANSP 0, window 248–760 × 145–529. Attributes: TARGET bitmap, 8 × 8, FLASH on, RATE 1, ATADDR = screen + 6144, ATSTRIDE 32. The copper writes BMADDR (3 bytes, the high one last) for each picture line k = 0–191 during draw lines 143 + 2k or 144 + 2k, with `screen + ((k & 0xC0) << 5) + ((k & 7) << 8) + ((k & 0x38) << 2)`. A program that keeps its screen in linear order needs no copper: BMADDR = screen, BMSTRIDE = 32. The palette holds the 256 paper/ink pairs (entry 2A = paper, 2A + 1 = ink with bright), repeated in 256–511. Cost: bitmap 32 + attributes 32 = **64 bytes** on the first line of each pair, nothing on the second: 14% of cycle 1 on half the lines.

**Full screen: 360 × 288 8-bit bitmap + 4-bit tiles.** Bitmap 362 + tiles 276 = **638 bytes** on the same line if both windows start at line 49: over cycle 1 by 190 bytes, so 95 cycle-3s per pair line go to urgent fetches and sprites get the rest. With the tile window starting at line 50 instead (lines 50–624), the bitmap fetches on lines 49, 51, … (362 bytes) and the tiles on 50, 52, … (276): both fit in cycle 1, and cycle 3 is left to the copper and sprites. Two 8-bit layers in hi-res at 576 lines (722 + 910) do not fit at all.

**80-column text.** Tiles: DEPTH 0, hi-res, 288 lines, window 184–824 × 137–537 (640 × 400 beam pixels: 80 × 25 characters, each 8 × 16 beam pixels). The map is 128 × 32, so 80 columns fit. Cost: 81 entries + 81 rows = 162 cycles = **324 bytes** on the first line of each pair, 72% of cycle 1. A 4-bit 360-wide bitmap behind it, starting on the other line parity, fits as well.

## 11. Boot console

The boot ROM sets up the 80-column tile layer of section 10.3:

1. Copies its 8 × 8 font (256 characters, code page 437, 1 bit, 2 KB) from the boot ROM to SRAM at `0x012000` (physical) and sets TLTILE there.
2. Clears the 8 KB map at `0x010000` to spaces (entry = character code, BANK = colour pair, so the high byte is pair × 2) and sets TLMAP.
3. Writes palette pairs 0–15 (entries 0–31: paper, ink); pair 0 is light grey on black. BGCOL black.
4. TLCTL = hi-res, 288 lines, TRANSP 0; TLBANK 0; scroll 0; the window above; VIDCTL.TLEN = 1.

Printing a character is one 2-byte map write; scrolling the text up is TLSCRY += 8 and clearing the new row (the map wraps at 32 rows). The addresses are suggestions until spec 7 sets the memory layout (open point V9).

## 12. Block RAM

| Item | Size | RAMB18 |
|------|------|--------|
| Line buffer | 2 × 720 × 12 bits (one per line parity) | 2 |
| Palette | 512 × 12 bits, two ports: draw reads, CPU/copper reads and writes | 1 |
| Display FIFOs | Bitmap 256, tile map 128, patterns 256, attributes 128 bytes, in one 1024 × 16 block: one write port (the fetch, at most one word per cycle) and one read port (the draw; at most 0.6 reads per clock) | 1 |
| Repeat buffers, bitmap and tiles | 720 × 16 bits each | 2 |
| Attribute repeat buffer | 128 × 8 bits | LUT RAM |
| **Total** | | **6** |

The sprite row store and line buffer are spec 5's. The design plan's block RAM table (D11) includes these 6 blocks.

## 13. Test plan

- **Timing:** sync positions, totals and the frame rate in simulation; real monitors and a TV lock on HDMI and VGA.
- **Golden images** (`make vtest` in `sim/`): random settings of every layer (each depth, 2× and hi-res, 288 and 576 lines, windows partly off screen, X and Y scroll and wrap, signed stride, X/Y flip, PRI, TRANSP, banks, attributes on each target and depth, both cell sizes, flash, sprites), line-buffer contents compared pixel by pixel with a Python model of this spec (`sim/vtest/vmodel.py`), as in retro68k. No OVERRUN on settings within budget.
- **Spectrum screen:** a .scr file shown through the copper's line addresses and the attribute layer, against the model.
- **Register timing:** a fetch register committed just before and just after draw beam (L, 0) acts on L and L + 1; on a 288-line layer a write on a pair's first line does not change its second; palette, BGCOL and bank writes land on the exact pixel, on both lines of a pair.
- **Budget:** each example of 10.3, with the CPU at 28 MHz and the copper running; the over-budget case sets OVERRUN and the right OVxx bit, shows background on the late pixels only, and the next line is right.
- **Clock crossing:** the pixel clock at an odd phase that sweeps along each line; no line buffer tearing.
- **Beam registers:** HBEAM/VBEAM reads are consistent and match the display beam; VBLANK and LINE fire at the right positions.
- **Boot console:** text on the simulated screen, checked pixel by pixel.

## 14. Open points

| # | Item |
|---|------|
| V1 | The attribute layer uses its target's window (no window of its own, to save 8 ports); D5 says "own window and scroll". Only the scroll is its own |
| V2 | In hi-res the tile map is 128 × 32, not 64 × 32, so that 80–90 columns fit (D5 says 90 columns in hi-res, which a 64-wide map cannot show) |
| V3 | Block RAM: 6 blocks for video against D11's 3 |
| V4 | The repeat buffer holds pixel values before the bank registers, so BMBANK and TLBANK writes act on both lines of a pair (needed by spec 6's per-cell bank example). The tile entry's BANK is kept in the repeat buffer |
| V5 | Bitmap and tile order is fixed (bitmap behind). A swap bit in VIDCTL could be added later |
| V6 | 1-bit tiles cost a cycle per row, as 2-bit ones; packing two rows per cycle would need tiles stored row-interleaved |
| V7 | Spec 6's Spectrum example writes only the low and middle bytes of the line address; under the 3-byte commit rule it must write all three (the high byte last, constant) |
| V8 | The default palette in the bitstream (for example the boot console's pairs and a Spectrum set) |
| V9 | The boot console's SRAM addresses and the 8 × 8 font (a public-domain code page 437 font) are to be fixed in spec 7 |
| V10 | Plain DVI has no info packets; add the HDMI AVI InfoFrame later, as in retro68k |
| V11 | Check in Vivado that the clock crossings are constrained and the draw pipeline meets 56 MHz |
