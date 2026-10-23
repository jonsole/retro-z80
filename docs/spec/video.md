# Spec 4: Video

Status: **draft**

The video makes one 576p picture, sent over HDMI and VGA at once. It is retro68k's video (its spec 4 and its guide, chapter 3) narrowed to 8 bits: a background colour, two identical layers L0 and L1 with retro68k's per-layer registers, a palette per layer and one for the sprites, and retro68k's PRIO, VIDCON, VIDSTAT and beam registers. Each layer is a chunky bitmap or a tile map. Inside, the data is read from SRAM just ahead of drawing into small FIFOs, because the display has only 448 guaranteed bytes per line against retro68k's 1,280. The attribute layer and the port `0xFE` border are Spectrum extras (section 8).

## 1. Summary

| Item | Value |
|------|-------|
| Output | 576p (720 × 576, 50 Hz, CEA-861), 27 MHz pixel clock; DVI over HDMI and 24-bit VGA through the ADV7125, the same picture |
| Normal picture | 360 × 288 at 2 × 2, the whole screen; any window from 1 × 1 |
| Layers | Two, L0 and L1, the same in every way. Each is a **bitmap** (chunky 1, 2, 4 or 8 bits per pixel) or a **tile map** (8 × 8 tiles of 1, 2, 4 or 8 bits per pixel), chosen by CTRL.MODE |
| Per layer | Window (XSTART, XEND, YSTART, YEND, beam coordinates), scroll, scale 1× or 2× across and down (HSCALE, VSCALE), transparency, palette block (PALOFS) |
| Bitmap | One pointer (BPL0PT) that moves down the picture, a signed stride (BPLSTRIDE), fine scroll (SCROLLX), pointer wrap (WRAP) |
| Tile map | Map base (MAPPT), pattern base (PATPT), map 32, 64 or 128 entries wide and high, X and Y scroll round the map; 2-byte entries with tile number, palette block, X and Y flip, priority (PRI) |
| Priority | PRIO orders the layers; each sprite's DEPTH puts it among them (spec 5); PRI tiles in front of all but DEPTH 0 sprites |
| Colours | 12-bit RGB. PALETTE0 (L0), PALETTE1 (L1), SPRPALETTE (sprites), 256 entries each; VIDCON.SHAREPAL puts everything on PALETTE0. Background colour BGCOLOR |
| Palette access | Index and data ports (PALIDX, PALDAT), and directly in the register page |
| Beam | All positions in beam coordinates (as retro68k). Software sees the **draw beam**, which runs one line ahead of the picture on the screen |
| Interrupts | VBLANK, LINE, VIDERR (spec 8 numbers them) |
| Memory | Cycle 1 of every slot; cycle 3 for urgent fetches (first) and top-up (after copper and sprites); spare cycles. Never the CPU's cycles |
| Budget | Per output line: 448 bytes guaranteed (cycle 1), 896 with all of cycle 3. A 2×-tall layer fetches on one line of each pair |
| Spectrum extras | Attribute layer (custom `0x120`–`0x13F`), port `0xFE` border (section 8) |
| Registers | Custom block: globals `0x000`–`0x01F`, L0 `0x020`–`0x03F`, L1 `0x040`–`0x05F`, read-only status `0x0F0`–`0x0F7`; palettes in the register page |
| Block RAM | 6 RAMB18 (section 10), sprites not counted |

## 2. Comparison with retro68k

| Feature | retro68k | retro-z80 | Why |
|---------|----------|-----------|-----|
| Layers | Three, L0–L2 | Two, L0 and L1 | Bandwidth: 448 guaranteed bytes per line, not 1,280. Branch 9 |
| What a layer is | A bitmap, planar or chunky | A chunky bitmap or a tile map (CTRL.MODE, bit 5) | A tile map gives a full screen for a fraction of the memory and bandwidth, and text with one write per character. retro68k leaves tile maps for later |
| Planar | 1–8 planes (CTRL.PLANAR, PLANES; BPL1PT–BPL7PT) | Left out. CTRL bit 1 and bits 18–16 are kept reserved for it | Each plane needs its own pointer and fetch stream: 8 pointers would not fit in a 32-byte register block. A Z80 gains nothing from planes; chunky pixels cost the same bandwidth |
| Data registers | BPL0DAT–BPL7DAT, loaded by DMA or written by the CPU or copper; BPLDMA per plane | Left out: no data registers, no BPLDMA, no CPU-fed layers | The display reads into FIFOs inside the chip (section 5), which bandwidth needs; there is no register to feed |
| Pointers | BPL0PT live: moves word by word, a write is used for the next word | BPL0PT is the **next source line's start**: taken at the line's fetch, then moved on by BPLSTRIDE at once | The FIFO fetch runs ahead of the draw beam by a varying amount, so a write in the middle of a fetch could not land at a fixed pixel. The end state each line is the same as retro68k's |
| BPLSTRIDE | Read with the line's last fetch | Read with the pointer, at the line's fetch | As above |
| Tile maps | – | MAPPT, PATPT, SCROLLX/SCROLLY round the map, CTRL2.MAPW/MAPH, tile PRI bit | Addition (branch 9) |
| Scale | 1×, 2×, 4×, 8× across and down | 1× or 2×; codes 2 and 3 (4×, 8×) reserved | Branch 9: 2 × 2 already fills the screen with 360 × 288 |
| Vertical scale | Each copy of a line is fetched again | A 2×-tall layer is fetched once per pair; the second line replays it from a repeat buffer | Bandwidth: halves a 2×-tall layer's cost |
| Colours | 24-bit RGB | 12-bit RGB (`0x0RGB`) | The KS3's VGA has 4 bits per colour; 2 bytes per entry |
| Palettes | PALETTE0–2 and SPRPALETTE, memory-mapped at `0xE04000`, 32-bit entries | PALETTE0, PALETTE1, SPRPALETTE (palette numbers 0, 1, 3; 2 reserved); through PALIDX/PALDAT and in the register page | 64 KB address space: tables are reached through ports or the register page |
| Direct colour | VIDCON.DIRECT, one layer per channel | Left out; VIDCON bit 4 reserved | Needs three layers |
| PRIO | FRONT, MIDDLE, BACK, each a layer number, 3 = none | The same byte; layer numbers 2 and 3 name no layer. Reset `0x24`: L0, then L1, then none | Two layers. Keeping three fields keeps sprite DEPTH 0–3 and retro68k's PRIO values working |
| Priority within a layer | – | A tile entry's PRI bit puts its pixels in front of all layers and of sprites with DEPTH 1–3 | Addition (branch 9) |
| PRIO, BGCOLOR timing | At the start of each line's picture | At the draw-beam pixel where the write lands | The draw stage runs on the system clock, so nothing holds them to the line start; port `0xFE` border stripes need it (section 8.2) |
| Beam the software sees | The display beam | The draw beam, one line ahead of the screen (section 3.3) | The draw pipeline. Every position software sees (BEAMPOS, LINECMP, VBLANK, copper waits) is the same beam, so effects land where retro68k's would |
| Late data | Transparent for that 16-pixel group, OVERRUN per layer, VIDERR | Transparent from the late pixel until the data arrives; OVERRUN0, OVERRUN1; VIDERR | Same rule; FIFOs instead of groups |
| Registers | 32-bit | Bytes; wider values low byte first, the highest byte commits. CTRL is three separate bytes (section 7.3) | The Z80 |
| VIDSTAT | VBLANK (0), LINE (1), OVERRUN L0–L2 (4–6), SPRUNDER (7), INVBLANK (8) | VBLANK (0), LINE (1), INVBLANK (3), OVERRUN0 (4), OVERRUN1 (5), OVERRUNA (6), SPRUNDER (7) | 8 bits: INVBLANK moves to bit 3; L2's bit is the attribute layer's |
| DMACON | 16 bits at `0x094`, Amiga bit positions | One byte at `0x00B`, set/clear in bit 7, the same enables in the same order (section 7.1) | 8 bits |
| VIDSIZE | `0x020` | `0x01C`–`0x01F` | The read-only area `0x0F0`–`0x0F7` is full (open point V1) |
| Fetch | Data registers, earliest-deadline-first scheduler, cycles 1 and 3 of a 100 ns slot; an urgent fetch takes the CPU's cycle 0 | FIFOs, earliest-deadline-first between them, cycle 1, cycle 3 when urgent; never the CPU's cycles | The Z80 never waits (spec 2) |
| Budget | A rate: 1.48 bytes per pixel | Per output line: 448 bytes guaranteed, 896 with cycle 3 | Bandwidth |
| Text | No text layer; the console is drawn into a 1-plane bitmap with an 8 × 16 font | The console is a 1-bit tile map with an 8 × 8 font at 2× down (section 9) | One 2-byte write per character, which a Z80 can afford |
| Layer register blocks | `0x100` + n × `0x80` | `0x020` + n × `0x20` | Copper MOVE reaches offsets `0x000`–`0x0EF` only |
| Attribute layer | – | Spectrum extra (section 8.1) | Spectrum screens |
| Port `0xFE` border | – | Spectrum extra (section 8.2) | Spectrum programs |

## 3. Clocks, timing and the beam

### 3.1 Clocks

| Clock | Frequency | From | Use |
|-------|-----------|------|-----|
| System | 56 MHz | MMCM 1 (50 MHz × 21 = 1050 MHz VCO, ÷ 18.75) | Fetch and draw, registers, SRAM |
| Pixel | 27 MHz | MMCM 2 (50 ÷ 5 × 108 = 1080 MHz VCO, ÷ 40), as in retro68k | Show stage, sync, VGA |
| HDMI serialiser | 135 MHz | MMCM 2 (÷ 8) | OSERDESE2, 10 bits per pixel at double rate |

Both come from one oscillator, so one 576p line (864 pixels, 32 µs) is exactly **1792 system clocks = 224 memory slots**. The phase between the two clocks is not known, so they are treated as asynchronous; only the line start and the line buffer cross (section 5.6).

### 3.2 The mode

| Item | Value |
|------|-------|
| Visible | 720 × 576, 50 Hz progressive (CEA-861 formats 17 and 18) |
| Horizontal | 720 visible, front porch 12, sync 64, back porch 68: 864 pixels (32 µs) |
| Vertical | 576 visible, front porch 5, sync 5, back porch 39: 625 lines (20 ms) |
| Sync | Both active low |
| Pixels | Not square: on a 4:3 screen a pixel is 16/15 as wide as it is tall |

There are no timing registers. VIDSIZE reads 720 × 576.

### 3.3 Beam coordinates and the draw beam

Every position (windows, sprite windows, copper waits, LINECMP, BEAMPOS) is in beam coordinates, which count the blanking, as in retro68k:

| | Pixels (across, `hpixel`) | Lines (down, `vline`) |
|--|--|--|
| 0 | Start of the horizontal blank | Start of the vertical blank |
| Blank | 0–143 | 0–48 |
| Picture | 144–863 (720) | 49–624 (576) |
| Total | 864 | 625 |

The picture's corner is VID_X0 = 144, VID_Y0 = 49; its size VID_W = 720, VID_H = 576 (`hw.inc`, as retro68k). The full-screen 360 × 288 picture is the window 144–864 × 49–625. A Spectrum-size 256 × 192 window at 2 × 2, centred, is pixels 248–760, lines 145–529.

**The draw beam.** The picture is worked out one line before it is shown (section 5). The beam that software sees is the **draw beam**: it reaches line L, pixel P when the hardware works out the pixel that will be shown at (L, P). BEAMPOS, LINECMP, VBLANK, FRAMECOUNT and the copper's waits (spec 6) all use it, and every register write acts at the draw beam. So a write that lands at draw beam (L, P) acts on the pixel shown at (L, P), and programs see the same beam as in retro68k. The picture leaves the HDMI and VGA connectors one line (32 µs) later; nothing in software can tell.

The draw beam runs on the system clock. Each draw line is 1792 clocks:

| System clocks of the draw line | Draw beam `hpixel` |
|---------------|-----------|
| 0–287 | 0–143: horizontal blank. Nothing drawn; FIFOs prefill |
| 288–1727 | 144–863: one pixel every 2 clocks |
| 1728–1791 | Stays at 863: 64 clocks of slack at the end of the line |

Pixel h is reached at clock 2h of the line. The draw beam's frame starts at (0, 0) while the screen still shows line 624.

| Register | Contents |
|----------|----------|
| BEAMPOS | `hpixel` (bytes 0–1, 10 bits) and `vline` (bytes 2–3, 10 bits) of the draw beam. Reading byte 0 captures all four bytes, so they always match: read byte 0 first |
| FRAMECOUNT | 16 bits, counts up when the draw beam reaches (0, 0). Reading byte 0 captures both bytes |
| VIDSIZE | HVISIBLE (720) and VVISIBLE (576), read only |

### 3.4 Video interrupts

Each event sets a sticky flag in VIDSTAT, which is cleared by writing 1 to it. VIDINTEN has an enable for each flag. A unit's request to the interrupt controller is on while a flag and its enable are both set (level, as in retro68k; spec 8). The sources keep retro68k's names; spec 8 numbers them.

| Flag (VIDSTAT bit) | Source | When |
|--------------------|--------|------|
| VBLANK (0) | VBLANK | The draw beam reaches (0, 0), the start of the vertical blank |
| LINE (1) | LINE | The draw beam reaches pixel 0 of line LINECMP: 144 pixels before that line's picture. A value above 624 never matches |
| OVERRUN0 (4), OVERRUN1 (5), OVERRUNA (6) | VIDERR | Layer 0's, layer 1's or the attribute layer's data was late (section 5.5) |
| SPRUNDER (7) | VIDERR | A sprite's data was late (spec 5) |

- The first picture line, 49, is fetched from draw beam (49, 0), so a VBLANK handler has 49 lines (1.57 ms) to set up the next frame.
- A LINE handler runs during draw line LINECMP. Its writes to fetch registers act from line LINECMP + 1 if they are committed within 32 µs (about 900 T-states at 28 MHz); its writes to pixel registers act at once, from the pixel where they land. This is retro68k's rule.
- VIDSTAT.INVBLANK (bit 3, read only) is 1 while the draw beam is in lines 0–48.

### 3.5 Output

The HDMI (DVI) and VGA outputs are retro68k's platform modules, copied in: `ks3_clocks.v` (MMCMs), `tmds_encoder.v`, `hdmi_out.v` and `vga_out.v` in `fpga/rtl/platform/artix7/`. Each 4-bit colour channel is widened to 8 bits by repeating it (`0xA` becomes `0xAA`), so full scale stays full scale. Outside the picture the outputs are black with sync. The output runs from configuration, with or without any layer on: with every layer off the screen shows BGCOLOR.

## 4. Layers

### 4.1 Overview

There are two layers, L0 and L1, the same in every way. For every pixel the hardware takes the front-most source that is not transparent: a layer, a sprite (spec 5), or the background colour BGCOLOR behind everything.

```
                per layer, per source
 SRAM ──cycle 1, 3──▶ FIFOs ──▶ draw (L0, L1, attributes, sprites) ──▶ priority ──▶ palette ──▶ line buffer ──▶ HDMI, VGA
                                     ▲                                                              (one line later)
                               repeat buffers
```

Each layer has its own registers (section 7.3): CTRL, window, scroll, stride and pointers. The layers only meet at the priority stage.

A layer is fetched and shown on a line when VIDCON.EN, DMACON.DMAEN, DMACON.BPLEN and its CTRL0.EN are set, its window covers the line, and PRIO names it. A layer that PRIO does not name is still fetched if it is enabled, but never shown, as in retro68k.

### 4.2 Modes and pixel formats

CTRL0.MODE picks what the layer is:

| MODE | Layer | Data |
|------|-------|------|
| 0 | Bitmap | A chunky picture at BPL0PT, BPLSTRIDE bytes from line to line (section 4.4) |
| 1 | Tile map | A map of 2-byte entries at MAPPT, naming 8 × 8 tiles at PATPT (section 4.5) |

**Chunky pixels** (bitmaps and tile patterns alike): pixels of d = 1, 2, 4 or 8 bits (CTRL0.BPP) are packed in bytes, the leftmost pixel in the highest bits, bytes left to right at rising addresses. As in retro68k, a 16-bit word holds 16, 8, 4 or 2 pixels; the SRAM is little-endian, so in retro-z80 a word's first pixels are in its even byte.

### 4.3 Display window

Each layer has a rectangle `XSTART ≤ x < XEND`, `YSTART ≤ y < YEND` in beam coordinates: WINX (XEND, XSTART) and WINY (YEND, YSTART). Outside it the layer is transparent and nothing is fetched for it. Windows can overlap or sit side by side, so status panels and split screens need no copper. A full-screen window is 144, 864, 49, 625 (VID_X0, VID_X0 + VID_W, VID_Y0, VID_Y0 + VID_H), which is also the value after reset.

A window is clamped to the picture: a start in the blank counts as the picture's edge, where the layer's first pixel then shows (layers are not clipped as sprites are); an end past the last pixel or line counts as the picture's end. The window is in screen (beam) pixels: at 2× across, a 640-pixel window shows 320 source pixels.

### 4.4 Bitmap mode: pointer, stride and scroll

| Register | Bits | Meaning |
|----------|------|---------|
| BPL0PT | 22 (even) | Physical SRAM address of the next source line's first byte (spec 2, section 7). Bit 0 reads 0 |
| BPLSTRIDE | 16, signed (even) | Bytes from the start of one source line to the start of the next. Bit 0 reads 0 |
| SCROLLX | 4 (bits 3–0) | Fine scroll: source pixels skipped at the start of each line, taken modulo the pixels in a word (16, 8, 4, 2 at 1, 2, 4, 8 bits per pixel) |
| CTRL2.WRAP | 4 | Pointer wrap (below) |

- **How the pointer moves.** When a source line is fetched (at draw beam (L, 0) of its first screen line, section 5.7), the hardware takes BPL0PT as the line's start and at once sets BPL0PT to that start + BPLSTRIDE. So between fetches BPL0PT always holds the next source line's start, as retro68k's pointer does at the end of each line. How many bytes the line fetches (window width, scale, fine scroll) makes no difference.
- **Writing the pointer.** A value committed before a source line's fetch is that line's start, as written. The hardware's own move and a write in the same clock: the write wins. So a split screen is one BPL0PT write before the line, and the copper can set every line's address (the Spectrum screen, section 8.3).
- **The pointer is not reset by the hardware.** As in retro68k, the copper or the CPU (in its VBLANK handler) writes it every frame. If nothing rewrites it, the next frame carries on through memory.
- **Stride.** BPLSTRIDE = the picture's bytes per line shows a picture whose lines follow each other, at any window width. 0 repeats one line; −(bytes per line) steps back a line each time, showing the picture upside down.
- **Scrolling.** Down: move BPL0PT by whole lines. Across: coarse by moving BPL0PT by whole words (2 bytes), fine by SCROLLX. With fine scroll the line fetches one word more; the stride does not change.

**Pointer wrap (CTRL2.WRAP).** As retro68k: with WRAP = n (1–13) the pointer stays inside an aligned block of 2^(n + 9) bytes (1 = 1 KB, 7 = 64 KB, 13 = 4 MB; 0 = no wrap). Every move the hardware makes, within a line and from line to line, changes only the address bits inside the block. Values written by the CPU or copper are used as written. This gives endless vertical scrolling through a ring of lines. There is no wrap across a line.

| Layout | BPL0PT | BPLSTRIDE |
|--------|--------|-----------|
| 360 × 288, 4 bits per pixel, 2 × 2 | base | 180 |
| 320 × 256 at 8 bits, window 640 × 512 at 2 × 2 | base | 320 |
| 640 × 480 at 1 bit, window 320 source pixels wide | base + left byte | 80 |

### 4.5 Tile mode: map, patterns and scroll

| Register | Bits | Meaning |
|----------|------|---------|
| MAPPT | 22 (even) | The map's first entry (row 0, column 0). Not moved by the hardware |
| PATPT | 22 (even) | Tile 0's first byte |
| CTRL2.MAPW | 2 | Map width: 0 = 32, 1 = 64, 2 = 128 entries; 3 reserved |
| CTRL2.MAPH | 2 | Map height: 0 = 32, 1 = 64, 2 = 128 entries; 3 reserved |
| SCROLLX | 10 | Map pixel at the window's left edge |
| SCROLLY | 10 | Map line at the window's top |

- **Map.** MW × MH entries of 2 bytes, row by row. Entry (column c, row r) is at `MAPPT + (r × MW + c) × 2`. A map takes 2 KB (32 × 32) to 32 KB (128 × 128).
- **Tiles.** A tile is 8 × 8 pixels of d bits (CTRL0.BPP): 8 rows of d bytes, row 0 first, packed as chunky pixels. Tile t's row y is at `PATPT + t × 8d + y × d`. Up to 512 tiles (4 KB at 1 bit, 32 KB at 8 bits).
- **Scroll.** For source line n of the window (n counts source lines from YSTART) and source pixel i across it: map y = (SCROLLY + n) mod (8 × MH), map x = (SCROLLX + i) mod (8 × MW). Map row = y >> 3, tile row = y & 7, and likewise across. Both wrap round the map, so it scrolls endlessly both ways; a map narrower than the window repeats across it. The unused high bits of SCROLLX and SCROLLY are ignored.
- **Fetch.** A line fetches `⌈((SCROLLX & 7) + w) ÷ 8⌉` columns, w = source pixels in the window: 46 for a full-width 2× layer (45 when SCROLLX is a multiple of 8), 91 at 1×. For each column the map entry, then its pattern row (row 7 − y with YFLIP).

**Map entry**, two bytes, low byte first:

| Bits | Field | Meaning |
|------|-------|---------|
| 8–0 | TILE | Tile number, 0–511 |
| 12–9 | PAL | Palette block for tiles of up to 4 bits (section 4.7) |
| 13 | XFLIP | Tile mirrored left to right |
| 14 | YFLIP | Tile upside down |
| 15 | PRI | The tile's non-transparent pixels are in front of both layers and of sprites with DEPTH 1–3 (section 4.8) |

So the high byte is: bit 0 TILE bit 8, bits 4–1 PAL, bit 5 XFLIP, bit 6 YFLIP, bit 7 PRI.

### 4.6 Scaling

CTRL0.HSCALE and CTRL1.VSCALE each pick 1× (0) or 2× (1), as retro68k's fields; 2 (4×) and 3 (8×) are reserved and show as 2×. Each source pixel is repeated that many times across, and each source line that many times down: 2 × 2 shows a 360 × 288 picture on the whole screen.

| Picture | HSCALE, VSCALE | On the screen |
|---------|----------------|---------------|
| 360 × 288 | 2 × 2 | Full screen |
| 256 × 192 (Spectrum) | 2 × 2 | 512 × 384, centred at beam (248, 145) |
| 640 × 200 text, 80 × 25 | 1 × 2 | 640 × 400 |
| 720 × 576 | 1 × 1 | Full screen |
| 360 × 576 | 2 × 1 | Full screen, tall pixels |

- With 2× across, the layer fetches half as much per screen pixel.
- With 2× down, each source line is a **pair** of beam lines, starting at YSTART: lines YSTART and YSTART + 1, then YSTART + 2 and YSTART + 3, and so on. The layer is fetched on the pair's first line only; the second replays it (section 5.4). So 2× down halves the bandwidth too, unlike retro68k. The pointer moves once per pair.
- If the window width or height is not a whole multiple of the scale, the last source pixel or line is cut short.

### 4.7 Transparency and palettes

**Palettes.** There are three palettes of 256 entries of 12-bit RGB: PALETTE0 for L0, PALETTE1 for L1, SPRPALETTE for the sprites (spec 5). As in retro68k, the palette number of PALETTE0 is 0, of PALETTE1 1 and of SPRPALETTE 3; number 2 (retro68k's PALETTE2) is reserved. A layer's pixels take their colours from its own palette only. An entry is the 16-bit value `0x0RGB`:

| Byte | Bits 7–4 | Bits 3–0 |
|------|----------|----------|
| 0 (low) | Green | Blue |
| 1 (high) | 0 | Red |

**Which entry a layer pixel uses.** The pixel value p of d bits becomes an index:

| Layer | d ≤ 4 | d = 8 |
|-------|-------|-------|
| Bitmap | PALOFS × 16 + p | p |
| Tile map | ((PALOFS + PAL) mod 16) × 16 + p, PAL from the entry | p |
| Target of the attribute layer | from the attribute byte (section 8.1) | p |

CTRL1.PALOFS picks one of the palette's 16 blocks of 16 colours, as in retro68k, so one write swaps a layer's colours. For tiles, the entry's PAL is added to it, so each tile can have its own block and PALOFS still shifts the whole layer. A 1-bit layer uses the first two entries of its block.

**Shared palette.** With VIDCON.SHAREPAL set, both layers and the sprites take their colours from PALETTE0, as in retro68k; PALETTE1 and SPRPALETTE are then not used.

**Transparency.** A layer is transparent outside its window, when it is off or not fetched for the line, where its data was late (section 5.5), and where p = 0 if CTRL0.TRANSP is set. With TRANSP clear the layer is solid inside its window, and p = 0 shows entry 0 of its block (a Spectrum screen's paper). XFLIP and the attribute layer's flash act before the test.

**Background colour.** BGCOLOR (`0x0RGB`) is a register of its own, not a palette entry. It shows wherever no layer and no sprite has a pixel. VIDCON.BLANKALL shows BGCOLOR over the whole picture, hiding every layer and sprite without stopping them.

**Palette access** (section 7.5): through PALIDX and PALDAT, `OTIR`-friendly, and directly in the register page. A palette write acts at the draw beam: pixels drawn after it use the new colour, so the copper changes a colour at an exact pixel. The palettes are not cleared by reset (open point V7).

### 4.8 Priority

PRIO lists the layers from front to back, as in retro68k:

| Bits | Field | Meaning |
|------|-------|---------|
| 1–0 | FRONT | Layer in front |
| 3–2 | MIDDLE | Next layer |
| 5–4 | BACK | Layer at the back |
| 7–6 | – | Reserved |

Each field holds a layer number: 0 for L0, 1 for L1; 2 and 3 name no layer. After reset PRIO is `0x24`: L0 in front, then L1, and BACK names none, so a retro68k PRIO value works unchanged. Name each layer once; a layer named twice shows at the front-most of its places.

Each sprite's 2-bit DEPTH (spec 5) puts it among the PRIO places, as retro68k's: 0 in front of all layers, 1 behind the FRONT place, 2 behind the MIDDLE place, 3 behind the BACK place (behind all layers). Tile pixels whose entry has PRI set move to their own place in front of all layers. So, back to front:

| # | Source |
|---|--------|
| 1 | Background colour (BGCOLOR) |
| 2 | Sprites with DEPTH 3 |
| 3 | The layer PRIO names BACK |
| 4 | Sprites with DEPTH 2 |
| 5 | The layer PRIO names MIDDLE |
| 6 | Sprites with DEPTH 1 |
| 7 | The layer PRIO names FRONT |
| 8 | Tile pixels whose entry has PRI = 1, from either layer (L0's in front of L1's) |
| 9 | Sprites with DEPTH 0 |

- With the reset PRIO, DEPTH 2 and DEPTH 3 both put a sprite behind both layers.
- A PRI tile pixel that is not transparent moves to place 8: it covers both layers and sprites of DEPTH 1–3, never DEPTH 0 ones. With TRANSP clear, a PRI tile's value 0 moves too.
- The output pixel is the front-most non-transparent source: a priority choice made by the draw stage at each pixel. PRIO acts at the draw-beam pixel, so the order can change within a line.
- Sprites are placed by DEPTH first; among sprites of the same DEPTH the lower number is in front, so a sprite at a front depth is in front of a lower-numbered one at a deeper depth, as retro68k's video does (spec 5, section 3.4). The sprite unit gives the draw stage, per pixel, the front-most opaque sprite of each DEPTH (its colour index, 0 = none).
- The draw stage also tells the sprite unit where each layer has a non-transparent pixel, for SPRCOLL's layer bits (spec 5).

### 4.9 Text

There is no text mode: text is a tile map of 1-bit tiles, one map entry per character. Printing a character is one 2-byte map write, and each character can have its own colour pair through PAL. The boot console is such a layer (section 9). The attribute layer can give a 1-bit layer Spectrum-style colours instead (section 8.1).

## 5. Fetch and draw

This section is hardware detail. It sets the bandwidth (section 6) and the timing rules the copper (spec 6) and sprites (spec 5) depend on.

### 5.1 Pipeline

| Stage | Clock | Runs | Work |
|-------|-------|------|------|
| Fetch | 56 MHz | Just ahead of the draw beam, from (L, 0) of the line being drawn | Reads each layer's bitmap data, or its map entries and pattern rows, and the attribute bytes, into one FIFO per source |
| Draw | 56 MHz | With the draw beam, one line before the screen | Takes pixels from the FIFOs or repeat buffers, applies scroll, flips, attributes, flash, transparency, priority and sprites, looks up the palette, writes the 12-bit colour into the line buffer |
| Show | 27 MHz | With the display beam | Reads the line buffer out to HDMI and VGA |

The sprite unit fetches each line's sprite rows into its row store during the line before (spec 5, section 4); its pixel units give the draw stage the sprites' pixels at the draw beam.

### 5.2 FIFOs and memory cycles

Each source has a FIFO, all in one block RAM (section 10):

| Source | FIFO | Holds |
|--------|------|-------|
| L0 data | 256 bytes | Bitmap words, or each column's pattern row with its entry |
| L0 map | 128 bytes | Map entries for the coming columns (tile mode only) |
| L1 data | 256 bytes | As L0 |
| L1 map | 128 bytes | As L0 |
| Attributes | 128 bytes | Attribute bytes (section 8.1) |

- At draw beam (L, 0) the fetch unit takes the layer's fetch registers (section 5.7) and works out the line's addresses. Each FIFO then **prefills** during the horizontal blank and is **topped up** as the draw beam takes data, until the line's data has all been read. A full FIFO stops its source.
- Fetching can use the whole line, 864 pixel times for at most 720 pixels. A FIFO must hold at most what is fetched before the first picture pixel, 144/864 of the line: about 152 bytes for the biggest line one source can have (910 bytes, 8-bit tiles at 1×). 256 bytes leave room for uneven cycles.
- In tile mode the map FIFO runs a few columns ahead of the pattern fetch, which takes each entry, reads its pattern row and pushes the entry and the row together into the data FIFO.
- Data is read as 16-bit words at even addresses. A line starting or ending in the middle of a word reads the whole word.
- **Order: earliest deadline first.** Each cycle goes to the source whose FIFO holds the fewest output pixels ahead of the draw beam, as retro68k's scheduler serves the nearest deadline.
- **Low mark:** a FIFO holding less than 32 output pixels ahead of the draw beam is **urgent**.

| Cycle ([spec 2](memory.md)) | Video use |
|-------|-----------|
| 1 | Always the display's, when a FIFO has room and its line is not finished |
| 3 | In this order: an urgent display FIFO; copper; sprites; display top-up |
| 0, 2 | Only when the CPU leaves them spare, in the same order |

Urgent fetches go before the copper in cycle 3, so the copper can never make the picture late; it slips instead (spec 6). At 28 MHz the swap (spec 2, section 4.2) sometimes moves a display cycle one cycle (35.7 ns) later; the FIFOs absorb it.

### 5.3 The draw stage

The draw stage takes one output pixel every 2 system clocks. For each of L0 and L1 it gets the pixel value (after scroll and flip), the tile entry's PAL and PRI, and a late flag; then the attribute byte (section 8.1); then it forms each layer's palette index (section 4.7), chooses the front-most source (section 4.8), reads that source's palette and writes the colour into the line buffer. Register values are delayed inside the pipeline to match, so a write that lands at draw beam (L, P) acts on the pixel shown at (L, P).

### 5.4 2×-tall layers and repeat buffers

- On the **first line** of a pair, a layer with VSCALE = 1 is fetched and drawn as a 1×-tall layer is, and the draw stage also writes each of its pixels into the layer's **repeat buffer**: 720 entries of 16 bits (pixel value after flip, the tile entry's PAL and PRI, and the late flag).
- On the **second line** the layer is not fetched; the draw stage reads the repeat buffer instead. Its memory cycles are free for others.
- Everything after the repeat buffer is done again on the second line: CTRL0.EN, TRANSP, PALOFS, the attribute byte, flash, priority, sprites, BGCOLOR and the palette. So those registers act on the second line as on the first; fetch registers (section 5.7) do not.
- The attribute layer has its own small repeat buffer (128 bytes), so its bytes are fetched once per pair too.
- A 2×-tall layer whose window ends on the first line of a pair shows just that line.

### 5.5 When a layer runs short

If the draw beam needs a source's data and its FIFO is empty, the data is **late**. As in retro68k:

- From that pixel the layer is **transparent** (lower layers, sprites or the background show), until its data arrives. A late attribute byte leaves its target's pixels transparent too.
- The fetch unit skips the data the draw beam has passed and carries on from just ahead of it, so the rest of the line is right and the next line starts on time.
- The layer's VIDSTAT flag is set (OVERRUN0, OVERRUN1 or OVERRUNA), which can raise VIDERR.
- On a 2×-tall layer the late flag goes into the repeat buffer, so the second line shows the same pixels as transparent.
- Nothing else is affected: the CPU never waits.

The copper cannot cause late data, since urgent fetches go before it. Late data means the layers on that line need more than cycles 1 and 3 give (section 6). Retro68k shows late data as transparent too, and bandwidth gives no reason to differ: showing the background instead would hide the sprites and the other layer for no gain. Sprite data that is late is spec 5's (SPRUNDER).

### 5.6 Clock domain crossing

| Signal | Crossing |
|--------|----------|
| Line start, frame start | The show side toggles a flip-flop at each display line start (pixel 0), with a frame flag at line 624. Two flip-flops at 56 MHz; the system side restarts its line clock (0) on each, and sets the draw beam's line to 0 on the frame flag, else adds 1 |
| Line buffer | A true dual-port block RAM, written at 56 MHz, read at 27 MHz. The half is the line's bit 0, which both sides know. No handshake |

Nothing else crosses. The beam registers read the draw beam, which is on the system side, so unlike retro68k they need no sampling.

**Margins.** Line L is drawn during display line L − 1, from about display pixel 139 (system clock 288) to about display pixel 836 (clock 1727, plus a few clocks of pipeline). Its half of the line buffer was last read for line L − 2, which ended before display line L − 1 started; it is read for line L from display pixel 144 of line L, about 170 pixels (6 µs) after the draw ends. Both margins are far larger than the crossing's few clocks.

### 5.7 When register writes take effect

| Registers | Take effect |
|-----------|-------------|
| **Fetch fields:** CTRL0.MODE, BPP, HSCALE; CTRL1.VSCALE; CTRL2 (MAPW, MAPH, WRAP); XSTART, XEND; SCROLLX, SCROLLY; BPLSTRIDE, BPL0PT, MAPPT, PATPT | At the fetch of each source line, draw beam (L, 0) of its first screen line. A value committed before (L, 0) acts on line L; one committed at or after it, from the next source line. **To change line L, write during line L − 1 or earlier.** On a 2×-tall layer, write before the pair's first line; a write during the first line acts from the next pair |
| **Line fields:** CTRL0.EN, TRANSP; CTRL1.PALOFS; YSTART, YEND | At (L, 0) of every screen line, on both lines of a pair |
| **Pixel registers:** VIDCON, BGCOLOR, PRIO, palette entries | At the draw beam, from the pixel where the write lands, on both lines of a pair |
| LINECMP, VIDSTAT, VIDINTEN, PALIDX, DMACON | At once (DMACON stops or starts the next fetch) |
| Attribute layer (section 8.1) | Fetch fields as above; ATCTL.EN and FLASH at (L, 0) of every line |

retro68k's rule for CTRL, the windows and SCROLLX (write during line L − 1 for line L) holds unchanged. Its pointers are live and its PRIO and BGCOLOR act at the line's start; here the pointer and stride follow the fetch rule and PRIO and BGCOLOR the pixel rule.

## 6. Memory budget

### 6.1 Rule

The display has cycle 1 of every slot: 224 cycles, **448 bytes per output line**, guaranteed. With all of cycle 3 (no copper, no sprites) it has **896**. Spare CPU cycles add more, but are not counted on. retro68k has 1,280 per line; here a 2×-tall layer fetches only on the first line of each pair, which makes up much of the difference.

A layer's cost falls on the lines it fetches: every line for a 1×-tall layer, the **first line of each pair** for a 2×-tall one. So the budget is a **peak per output line**: add the costs of the sources fetched on that line. Up to 448 bytes always fits. Beyond that the FIFOs go urgent and take cycle 3 first, so up to 896 fits whatever the copper does; the copper then slips (spec 6) and the sprites get less (spec 5). Settings over the budget are allowed: the data that does not arrive in time is late (section 5.5) and sets OVERRUN.

**Tip:** 2×-tall layers whose windows start on lines of opposite parity fetch on alternate lines, so their costs do not add up on the same line.

### 6.2 Cost per source line

In bytes of memory cycles (2 per cycle), full width, with fine scroll:

| Layer | 1 bit | 2 bits | 4 bits | 8 bits |
|-------|-------|--------|--------|--------|
| Bitmap, 2× across (360 source pixels) | 48 | 92 | 182 | 362 |
| Bitmap, 1× across (720) | 92 | 182 | 362 | 722 |
| Tiles, 2× across (46 columns) | 184 | 184 | 276 | 460 |
| Tiles, 1× across (91 columns) | 364 | 364 | 546 | 910 |
| Attribute layer | 46 at 2×, 92 at 1× | | | |

A tile column costs one cycle for its map entry and d ÷ 2 cycles for its pattern row, but a 1-bit row (one byte) still takes a whole cycle, so 1-bit tiles cost as much memory time as 2-bit ones (open point V6). A narrower window costs less in proportion. Sprites are counted in spec 5.

### 6.3 Worked examples

| Screen | Bytes on its busiest line | Fits? |
|--------|---------------------------|-------|
| Spectrum screen: 256 × 192, 1 bit, 2 × 2, with 8 × 8 attributes (section 8.3) | 32 + 32 = **64**, first line of each pair only | Yes: 14% of cycle 1 on half the lines |
| 80-column text: 1-bit tiles, 1 × 2, 640 × 400 window (section 9) | 81 columns × 2 cycles = **324**, first line of each pair | Yes: 72% of cycle 1 |
| Text as above + a 4-bit 2 × 2 bitmap on L1 starting on the other parity | 324 and 182 on alternate lines | Yes |
| 360 × 288 8-bit bitmap (L0) + 4-bit tiles (L1), both 2 × 2, both windows from line 49 | 362 + 276 = **638** | Over cycle 1 by 190: 95 cycle 3s per pair line go to urgent fetches; copper and sprites share the rest |
| The same with L1's window from line 50 (lines 50–624) | 362 and 276 on alternate lines | Yes, cycle 3 left to the copper and sprites |
| 720 × 576 4-bit bitmap, 1 × 1 | **362** every line | Yes: 81% of cycle 1 |
| 720 × 576 8-bit bitmap, 1 × 1 | **722** every line | Only with cycle 3: 137 cycle 3s per line; little left for sprites |
| Two 8-bit layers, 1 × 1 | 1,444 | **No** |

## 7. Registers

All registers are 8 bits, in the **custom block** (spec 3): custom offset `n` is I/O port `(n & 0xFF) << 8 | (0xC0 + (n >> 8))`, so `LD BC,reg` then `OUT (C),A` or `IN A,(C)`, and `INC B` steps to the next register. The same registers are at offset `0x1000 + n` of the register page (MMU page `0x3F8`). Values wider than 8 bits are at consecutive offsets, low byte first; writing the highest byte commits the value, and reading the lowest byte of a counter captures it (spec 3, section 3). The copper's MOVE reaches offsets `0x000`–`0x0EF`, which holds every register here a copper program changes per line (spec 6). Reserved bytes follow spec 3. Unless stated, reset values are 0.

### 7.1 Global registers (`0x000`–`0x01F`)

| Offset | Port | Name | Access | Bits | Meaning |
|--------|------|------|--------|------|---------|
| `0x000` | `0x00C0` | VIDCON | RW | EN (0), BLANKALL (2), SHAREPAL (5); 1, 3, 4 (retro68k's DIRECT), 6–7 reserved | Layer fetch on (with DMACON); show BGCOLOR only; everything on PALETTE0 (section 4.7) |
| `0x001` | `0x01C0` | VIDSTAT | W1C (INVBLANK R) | VBLANK (0), LINE (1), INVBLANK (3), OVERRUN0 (4), OVERRUN1 (5), OVERRUNA (6), SPRUNDER (7); 2 reserved | Sticky flags, write 1 to clear (section 3.4) |
| `0x002` | `0x02C0` | VIDINTEN | RW | As VIDSTAT bits 0, 1, 4–7 | Interrupt enables |
| `0x003` | `0x03C0` | PRIO | RW | FRONT (1–0), MIDDLE (3–2), BACK (5–4) | Layer order (section 4.8). Reset `0x24` |
| `0x004`–`0x005` | `0x04C0`, `0x05C0` | BGCOLOR | RW | 11–0: `0x0RGB` | Background colour; also set by port `0xFE` writes (section 8.2) |
| `0x006`–`0x007` | `0x06C0`, `0x07C0` | LINECMP | RW | 9–0 | Draw-beam line of the LINE event |
| `0x008`–`0x009` | `0x08C0`, `0x09C0` | PALIDX | RW | 7–0 entry; 9–8 palette (0 PALETTE0, 1 PALETTE1, 2 reserved, 3 SPRPALETTE) | Palette index (section 7.5) |
| `0x00A` | `0x0AC0` | PALDAT | RW | 7–0 | Palette data, low byte then high byte (section 7.5) |
| `0x00B` | `0x0BC0` | DMACON | Set/clear | SETCLR (7), DMAEN (6), BPLEN (5), COPEN (4), BLTEN (3), SPREN (2), AUDEN (1), 0 reserved | DMA enables (below) |
| `0x00C`–`0x01B` | | – | | | Reserved |
| `0x01C`–`0x01D` | `0x1CC0`, `0x1DC0` | VIDSIZE (HVISIBLE) | R | 9–0 | 720 |
| `0x01E`–`0x01F` | `0x1EC0`, `0x1FC0` | VIDSIZE (VVISIBLE) | R | 9–0 | 576 |

**DMACON** is retro68k's DMA enable register, narrowed to one byte with its enables in the same order. Writing with bit 7 = 1 sets the bits written as 1; with bit 7 = 0 clears them; bits written as 0 are left alone. Reading gives the enables (bit 7 reads 0). All off after reset.

| Bit | Name | Enables | retro68k bit |
|-----|------|---------|--------------|
| 7 | SETCLR | 1 = set, 0 = clear the bits written as 1 | 15 |
| 6 | DMAEN | Master enable for everything below | 9 |
| 5 | BPLEN | Layer and attribute fetch (with VIDCON.EN and each CTRL0.EN) | 8 |
| 4 | COPEN | Copper (spec 6) | 7 |
| 3 | BLTEN | DMA engine (spec 14) | 6 |
| 2 | SPREN | Sprites (spec 5) | 5 |
| 1 | AUDEN | Audio, reserved (spec 13, Q1) | 3–0 (AUD0EN–AUD3EN) |
| 0 | – | Reserved | – |

### 7.2 Read-only status (`0x0F0`–`0x0F7`)

| Offset | Port | Name | Bits | Meaning |
|--------|------|------|------|---------|
| `0x0F0`–`0x0F1` | `0xF0C0`, `0xF1C0` | BEAMPOS (HPIXEL) | 9–0 | Draw beam `hpixel`, 0–863. Reading `0x0F0` captures all four BEAMPOS bytes |
| `0x0F2`–`0x0F3` | `0xF2C0`, `0xF3C0` | BEAMPOS (VLINE) | 9–0 | Draw beam `vline`, 0–624 |
| `0x0F4`–`0x0F5` | `0xF4C0`, `0xF5C0` | FRAMECOUNT | 15–0 | Frames; reading `0x0F4` captures both bytes |
| `0x0F6`–`0x0F7` | | – | | Reserved |

A copper MOVE cannot name these offsets: codes `0xF0`–`0xFF` are its other instructions (spec 6). MOVR and MOVEL can, and the writes are ignored, as the CPU's are.

### 7.3 Layer registers

Layer n (0, 1) is at `0x020 + n × 0x20`: L0 at `0x020`–`0x03F` (ports `0x20C0`–`0x3FC0`), L1 at `0x040`–`0x05F` (ports `0x40C0`–`0x5FC0`). `hw.inc` gives `L0`, `L1` and the offsets `L_CTRL0` … `L_PATPT`, and ready-added names (`L1_BPL0PT`), as retro68k's.

| Offset | Name | Access | Bits | Meaning |
|--------|------|--------|------|---------|
| `+0x00` | CTRL0 | RW | EN (0), MODE (5), BPP (3–2), TRANSP (4), HSCALE (7–6); 1 reserved | retro68k's CTRL bits 7–0 (section 7.4) |
| `+0x01` | CTRL1 | RW | VSCALE (1–0), PALOFS (7–4); 3–2 reserved | CTRL bits 15–8 |
| `+0x02` | CTRL2 | RW | MAPW (1–0), MAPH (3–2), WRAP (7–4) | CTRL bits 23–16 |
| `+0x03` | – | | | Reserved (CTRL bits 31–24) |
| `+0x04`–`+0x05` | WINX (XEND) | RW | 9–0 | First beam pixel after the window. Reset 864 |
| `+0x06`–`+0x07` | WINX (XSTART) | RW | 9–0 | First beam pixel of the window. Reset 144 |
| `+0x08`–`+0x09` | WINY (YEND) | RW | 9–0 | First beam line after the window. Reset 625 |
| `+0x0A`–`+0x0B` | WINY (YSTART) | RW | 9–0 | First beam line of the window. Reset 49 |
| `+0x0C`–`+0x0D` | SCROLLX | RW | 9–0 | Bitmap: fine scroll, bits 3–0. Tiles: map X (section 4.5) |
| `+0x0E`–`+0x0F` | SCROLLY | RW | 9–0 | Tiles: map Y. Not used by bitmaps |
| `+0x10`–`+0x11` | BPLSTRIDE | RW | 15–0, signed, even | Bytes from one source line's start to the next (section 4.4) |
| `+0x12`–`+0x13` | – | | | Reserved (retro68k's BPLDMA) |
| `+0x14`–`+0x16` | BPL0PT | RW | 21–1 | Bitmap: the next source line's start (section 4.4) |
| `+0x17` | – | | | Reserved |
| `+0x18`–`+0x1A` | MAPPT | RW | 21–1 | Tiles: map base |
| `+0x1B` | – | | | Reserved |
| `+0x1C`–`+0x1E` | PATPT | RW | 21–1 | Tiles: pattern base |
| `+0x1F` | – | | | Reserved |

- **CTRL0, CTRL1 and CTRL2 are three byte registers, each written on its own.** They hold separate fields, not one value, so there is no latch: a copper program changes PALOFS with one MOVE. retro68k's CTRL bit positions are kept: CTRL0 bit k is CTRL bit k, CTRL1 bit k is bit 8 + k, CTRL2 bit k is bit 16 + k.
- WINX and WINY are retro68k's 32-bit registers in byte order: their low halves (XEND, YEND) come first. Each half is a 2-byte value on its own, committed by its high byte.
- Pointers are 3 bytes; bits 23–22 are ignored and bit 0 reads 0 (spec 2, section 7).
- BPL0PT reads the next source line's start: the hardware moves it at each fetch (section 4.4). Reading its low byte (`+0x14`) captures all three bytes, so a read low byte first is never torn (spec 3, rule 4).

### 7.4 CTRL fields

| Register | Bits | Field | Values |
|----------|------|-------|--------|
| CTRL0 | 0 | EN | 1: layer on |
| | 1 | – | Reserved (retro68k's PLANAR); write 0 |
| | 3–2 | BPP | 0 = 1, 1 = 2, 2 = 4, 3 = 8 bits per pixel |
| | 4 | TRANSP | 1: pixel value 0 is transparent |
| | 5 | MODE | 0: bitmap, 1: tile map |
| | 7–6 | HSCALE | 0: 1×, 1: 2× across; 2, 3 reserved (shown as 2×) |
| CTRL1 | 1–0 | VSCALE | 0: 1×, 1: 2× down; 2, 3 reserved (shown as 2×) |
| | 3–2 | – | Reserved |
| | 7–4 | PALOFS | Palette block for layers of up to 4 bits (section 4.7) |
| CTRL2 | 1–0 | MAPW | Tiles: 0 = 32, 1 = 64, 2 = 128 entries wide; 3 reserved |
| | 3–2 | MAPH | Tiles: 0 = 32, 1 = 64, 2 = 128 entries high; 3 reserved |
| | 7–4 | WRAP | Bitmap: pointer wrap, 0 off, n = blocks of 2^(n + 9) bytes (1–13) |

### 7.5 Palettes

**Through ports.** PALIDX is a 10-bit index: bits 7–0 the entry, bits 9–8 the palette number (0 PALETTE0, 1 PALETTE1, 3 SPRPALETTE), so the index is retro68k's palette address ÷ 4. Writing PALIDX's high byte commits it and resets PALDAT's byte flip-flop. PALDAT reads or writes the entry at the index, low byte then high byte. A low-byte write is held; the **high-byte write changes the entry** and steps the index by 1 (from 255 of one palette to 0 of the next; `0x3FF` to 0). A high-byte read steps it too. So `OTIR` with B = 2n writes n entries. Palette 2's entries read 0 and ignore writes.

**Through the register page.** The palettes are also at offsets `0x1800`–`0x1FFF` of the register page (spec 3), entry i of palette p at `0x1800 + p × 0x200 + 2i`:

| Register page | Palette |
|---------------|---------|
| `0x1800`–`0x19FF` | PALETTE0 |
| `0x1A00`–`0x1BFF` | PALETTE1 |
| `0x1C00`–`0x1DFF` | Reserved (retro68k's PALETTE2) |
| `0x1E00`–`0x1FFF` | SPRPALETTE |

The even byte (green, blue) is held and the odd byte (red) changes the entry, with the same timing as PALDAT. This does not use or change PALIDX. `LD (nn),HL` writes one entry; `LDIR` copies a palette.

**Timing.** A write changes the entry at the draw beam (section 5.7). The copper reaches the palettes through PALIDX and PALDAT: a colour change is four MOVEs (two when PALIDX is already set).

## 8. Spectrum extras

These are not in retro68k. They are kept for Spectrum screens and programs, each outside the retro68k-shaped core.

### 8.1 Attribute layer

The attribute layer draws nothing. It replaces the palette block of its **target**, L0 or L1 (ATCTL.TARGET), with one byte per cell, as a Spectrum's attributes do.

- **Cells** are 8 source pixels across and 8 or 1 source lines down (ATCTL.CELL1) of the target, so they follow its HSCALE and VSCALE: an 8 × 8 cell on a 2 × 2 layer covers 16 × 16 beam pixels. It works on bitmaps and tile maps alike.
- **Window:** the target's. The attribute layer acts only where its target is shown, so it has no window of its own.
- **Addresses:** ATADDR is the address of the cell row at the window's top-left; each cell row is ATSTRIDE bytes (0–255) after the one before. The row address steps by ATSTRIDE after every 8 source lines of the target (8 × 8) or every source line (8 × 1). A restart (row address = ATADDR) happens at the window's top line and at any line whose fetch starts after ATADDR was written, so the copper can set any row's address. ATADDR is not moved by the hardware, so it needs no rewriting each frame.
- **Scroll:** ATSCROLL bits 2–0 shift the cells left by 0–7 source pixels; bits 6–4 start the first cell row 0–7 lines into the row (8 × 8 only). Coarse scroll is by ATADDR. To follow a scrolled target, set fine X = the target's scroll & 7 and move ATADDR by the rest.
- **Index:** with attribute byte A, the target's pixel p of d bits takes entry `((A << d) | p) & 0xFF` of the target's palette, in place of PALOFS and the tile entry's PAL. For a 1-bit target, **index = (A & 0x7F) × 2 + p**: a Spectrum attribute (flash, bright, paper, ink) picks a pair of entries, 2A for paper and 2A + 1 for ink, and the flash bit is not part of the index. For a 2-bit target A picks one of 64 groups of 4; for a 4-bit target bits 3–0 pick one of 16 blocks; an 8-bit target's index is p.
- **Flash:** with ATCTL.FLASH set, bit 7 of A is a flash bit. While the flash phase is on, a cell with bit 7 set has its pixel value inverted (p XOR (2^d − 1)), which swaps paper and ink for a 1-bit target. Transparency is tested after this. The phase changes every 8, 16, 32 or 64 frames (ATCTL.RATE; the Spectrum's is 16) and reads in ATCTL.PHASE.
- **Fetch:** `⌈(fine X + w) ÷ 8⌉` bytes per source line of the target (46 at full width and 2×, 91 at 1×), fetched on the first line of each pair for a 2×-tall target and kept in the attribute repeat buffer. It uses the attribute FIFO and is late as section 5.5 says (OVERRUNA).
- The attribute layer is on when ATCTL.EN is set and its target is fetched on the line.

**Registers** (custom `0x120`–`0x13F`, ports `0x20C1`–`0x3FC1`; the copper reaches them with MOVEL only, spec 6):

| Offset | Port | Name | Access | Bits | Meaning |
|--------|------|------|--------|------|---------|
| `0x120` | `0x20C1` | ATCTL | RW (PHASE R) | EN (0), TARGET (1: 0 = L0, 1 = L1), CELL1 (2: 0 = 8 × 8, 1 = 8 × 1), FLASH (3), RATE (5–4: 8, 16, 32, 64 frames), PHASE (7, read only); 6 reserved | Control |
| `0x121`–`0x123` | `0x21C1`–`0x23C1` | ATADDR | RW | 21–0 | Cell row address at the window's top |
| `0x124` | `0x24C1` | ATSTRIDE | RW | 7–0 | Bytes per cell row |
| `0x125` | `0x25C1` | ATSCROLL | RW | 2–0 fine X, 6–4 fine Y | Fine scroll |
| `0x126`–`0x13F` | | – | | | Reserved |

ATADDR, ATSTRIDE, ATSCROLL, TARGET and CELL1 are fetch fields (section 5.7); EN, FLASH and RATE act at (L, 0) of every line.

### 8.2 Border: port 0xFE

As on a Spectrum, a write to port `0xFE` sets the border colour, which here is the background colour. Port `0xFE` itself (the keyboard on reads, the beeper in bit 4, MIC in bit 3) is spec 12's; the write also works through offset `0x00FE` of the register page. Bits 2–0 pick one of eight fixed colours, the Spectrum's colours without BRIGHT, at level `0xD`:

| Bits 2–0 | Colour | BGCOLOR |
|----------|--------|---------|
| 0 | Black | `0x000` |
| 1 | Blue | `0x00D` |
| 2 | Red | `0xD00` |
| 3 | Magenta | `0xD0D` |
| 4 | Green | `0x0D0` |
| 5 | Cyan | `0x0DD` |
| 6 | Yellow | `0xDD0` |
| 7 | White | `0xDDD` |

- The write sets BGCOLOR as a BGCOLOR commit would: at the draw beam, from the pixel where it lands. BGCOLOR then reads back the new value. The CPU's BGCOLOR latch is not changed.
- BGCOLOR and port `0xFE` set the same register, so the later write wins. A program that wants other border colours (BRIGHT ones, say) writes BGCOLOR.
- The background shows wherever no layer and no sprite is opaque. With the Spectrum screen of section 8.3 (TRANSP clear) that is everywhere outside the 256 × 192 window, as a Spectrum's border.
- Border stripes timed from VBLANK or LINE (by counting T-states) land where the draw beam is, as on a Spectrum they land where its beam is.
- The copper cannot write port `0xFE`; it writes BGCOLOR.

### 8.3 Example: the Spectrum screen

A 48K Spectrum screen file (6,144 bytes of pixels in the Spectrum's line order, then 768 attribute bytes) at physical address `screen`, shown unchanged:

| Register | Value |
|----------|-------|
| L0 CTRL0 | EN, BPP 0 (1 bit), TRANSP 0, MODE 0 (bitmap), HSCALE 1: `0x41` |
| L0 CTRL1 | VSCALE 1, PALOFS 0: `0x01` |
| L0 window | XSTART 248, XEND 760, YSTART 145, YEND 529 |
| L0 BPLSTRIDE | 256 (the next pixel line of the same character row) |
| ATCTL | EN, TARGET L0, 8 × 8, FLASH, RATE 1 (16 frames): `0x19` |
| ATADDR, ATSTRIDE | screen + 6144, 32 |
| PALETTE0 | Entries 2A (paper) and 2A + 1 (ink) for A = 0–127: bit 6 bright (level `0xF`, else `0xD`), paper in bits 5–3, ink in bits 2–0 |
| BGCOLOR | Set by port `0xFE` |

**The copper sets the layer pointer.** A Spectrum screen's pixel line y is at `screen + ((y & 0xC0) << 5) + ((y & 7) << 8) + ((y & 0x38) << 2)`. Picture line k is the pair starting at beam line 145 + 2k, fetched at draw beam (145 + 2k, 0); its BPL0PT must be committed after the previous pair's fetch (143 + 2k, 0) and before its own, so during draw line 143 + 2k or 144 + 2k.

- **Every line:** the copper waits for each (144 + 2k, 0) and writes BPL0PT for line k: three MOVEs (the high byte last, to commit), 5 words a line with the wait, 192 times a frame.
- **Every character row (cheaper):** within a character row of 8 lines, each line is 256 bytes after the one before, which BPLSTRIDE = 256 does by itself. So the copper writes BPL0PT only at the start of each row r = 0–23, `screen + ((r & 0x18) << 8) + ((r & 7) << 5)`, during draw line 144 + 16r (row 0 in the vertical blank): 24 times a frame.

L0's BPL0PT is at custom `0x034`–`0x036`, inside the copper's MOVE reach. A program that keeps its screen in linear order needs no copper: BPL0PT = screen, BPLSTRIDE = 32, written each frame in the vertical blank.

Cost: bitmap 32 + attributes 32 = **64 bytes** on the first line of each pair, nothing on the second.

## 9. Boot console

The boot ROM's text console is layer L0 as a 1-bit tile map (section 4.9):

1. Copy the 8 × 8 font (256 characters, code page 437, 1 bit, 2 KB) from the boot ROM into SRAM and set PATPT there.
2. Clear an 8 KB map (128 × 32 entries) to spaces and set MAPPT. An entry is the character code with PAL = colour pair, so its high byte is pair × 2.
3. Write PALETTE0's pairs 0–15 (entries 16k for paper, 16k + 1 for ink); pair 0 is light grey on black. BGCOLOR black.
4. L0: CTRL0 = EN, BPP 0, TRANSP 0, MODE 1, HSCALE 0 (`0x21`); CTRL1 = VSCALE 1 (`0x01`); CTRL2 = MAPW 2, MAPH 0 (`0x02`); SCROLLX = SCROLLY = 0; window 184–824 × 137–537 (640 × 400 beam pixels: 80 × 25 characters, each 8 × 16 beam pixels).
5. VIDCON.EN = 1; DMACON = SETCLR, DMAEN, BPLEN (`0xE0`).

Printing a character is one 2-byte map write. Scrolling the text up is SCROLLY += 8 and clearing the new row (the map wraps at 32 rows). The cost is 324 bytes on the first line of each pair (section 6.3), which leaves L1, the copper and the sprites free. The SRAM addresses are set in spec 7 (open point V8).

## 10. FPGA resources

| Item | Size | RAMB18 |
|------|------|--------|
| Line buffer | 2 × 720 × 12 bits (one per line parity) | 2 |
| Palettes | 1024 × 12 bits ({palette number, entry}: PALETTE0, PALETTE1, reserved, SPRPALETTE), two ports: the draw stage reads, the CPU and copper read and write | 1 |
| Display FIFOs | L0 data 256, L0 map 128, L1 data 256, L1 map 128, attributes 128 bytes, in one 1024 × 16 block: one write port (the fetch, at most one word per cycle), one read port (the draw) | 1 |
| Repeat buffers | 720 × 16 bits for each layer | 2 |
| Attribute repeat buffer | 128 × 8 bits | LUT RAM |
| **Total** | | **6** |

The sprite row store is spec 5's. Unlike retro68k, the palette is kept once: the draw stage is on the system clock, so its read port and the CPU's port are both there.

## 11. Test plan

- **Timing:** sync positions, totals and the frame rate in simulation; real monitors and a TV lock on HDMI and VGA.
- **Golden images** (`make vtest` in `sim/`), as in retro68k: random settings of both layers in both modes (each depth, 1× and 2× across and down, windows partly off screen, fine scroll, signed stride, pointer wrap, every map size with scroll wrapping round it, X and Y flip, PRI, TRANSP, PALOFS and PAL, SHAREPAL, every PRIO value, sprites at every DEPTH, the attribute layer on each target and depth, both cell sizes, flash), line-buffer contents compared pixel by pixel with a Python model of this spec (`sim/vtest/vmodel.py`). Each palette gets different colours, so a pixel from the wrong palette shows. No OVERRUN on settings within budget.
- **Pointer:** BPL0PT reads the next line's start after each fetch; a write before (L, 0) starts line L, a write after it starts the next source line; on a 2×-tall layer it moves once per pair; with WRAP it stays in its block; nothing resets it at the frame start.
- **Order:** every PRIO value, including a layer left out and the reset value; sprites of each DEPTH against opaque and transparent pixels of both layers; PRI tiles over both layers and DEPTH 1–3 sprites, under DEPTH 0 sprites; PRIO changed within a line.
- **Register timing:** a fetch field committed just before and just after (L, 0) acts on L and on the next source line; on a 2×-tall layer a write during a pair's first line does not change its second; EN, TRANSP and PALOFS change on the second line of a pair; palette, BGCOLOR and PRIO writes land on the exact pixel, on both lines of a pair; CTRL1 written alone changes only its fields.
- **Palettes:** PALIDX/PALDAT write and read every entry of the three palettes, the index steps across palettes, `OTIR` loads a palette; the register page's offsets do the same without touching PALIDX; palette 2 reads 0.
- **Border:** `OUT (0xFE),A` with each of the 8 values sets BGCOLOR to the table's colour at the draw-beam pixel; BGCOLOR and port `0xFE` writes in either order, the later wins; the register page's offset `0x00FE` does the same.
- **Spectrum screen:** a .scr file shown through the copper's pointer writes (both ways of section 8.3) and the attribute layer, against the model; flash every 16 frames.
- **Budget:** each example of section 6.3 with the CPU at 28 MHz and the copper running; a copper that never waits does not cause OVERRUN on a screen within budget; an over-budget screen sets the right OVERRUN bit, shows transparent pixels only where late, and the next line is right.
- **Beam and interrupts:** BEAMPOS reads are consistent and match the draw beam; VBLANK and LINE fire at the right draw-beam positions; FRAMECOUNT counts; INVBLANK; flags clear on writing 1; the request follows VIDSTAT and VIDINTEN.
- **DMACON:** set and clear each bit; with BPLEN or DMAEN clear no layer fetches.
- **Clock crossing:** the pixel clock at an odd phase that sweeps along each line; no line buffer tearing.
- **Boot console:** text on the simulated screen, checked pixel by pixel.

## 12. Open points

| # | Item |
|---|------|
| V1 | VIDSIZE (4 bytes) does not fit the read-only area `0x0F0`–`0x0F7` beside BEAMPOS (4) and FRAMECOUNT (2); it is at `0x01C`–`0x01F` in the globals, where the copper could reach it (writes ignored) |
| V2 | Closed: the palettes are at `0x1800`–`0x1FFF` of the register page, laid out by retro68k's palette numbers (spec 3, section 6; spec 2, section 6.5) |
| V3 | PRIO and BGCOLOR act at the draw-beam pixel, not at the line start as in retro68k. A retro68k program that writes them during the line before still works if it writes in the horizontal blank or the last pixels of the line |
| V4 | Software sees the draw beam (BEAMPOS, LINECMP, VBLANK, FRAMECOUNT), so every position matches the copper's and retro68k's. The previous draft showed the display beam to the CPU. Specs 5, 6, 8 and 9 must use the same beam |
| V5 | CTRL0–CTRL2 are separate byte registers, an exception to the multi-byte rule (spec 3, section 3.1) |
| V6 | 1-bit tiles cost a cycle per row, as 2-bit ones; packing two rows per cycle would need tiles stored row-interleaved |
| V7 | The palettes are not cleared by reset; their contents at configuration (the boot console's pairs, a Spectrum set) are a default set by the bitstream, to be decided |
| V8 | The boot console's SRAM addresses and the 8 × 8 font (a public-domain code page 437 font) are to be fixed in spec 7 |
| V9 | Plain DVI has no info packets; add the HDMI AVI InfoFrame later, as in retro68k |
| V10 | Check in Vivado that the clock crossings are constrained and the draw pipeline (a 9-place priority choice, two palette indices) meets 56 MHz |
| V11 | Closed: the 8 border colours use level `0xD` (about 85%, the Spectrum's non-bright level) |
| V12 | HSCALE and VSCALE codes 2 and 3 (4×, 8×) are reserved and show as 2×. 4× across is cheap; 4× down would need the repeat buffer replayed three times |
| V13 | A tile's palette block is (PALOFS + PAL) mod 16, so PALOFS shifts a whole tile layer. The attribute layer replaces both |
| V14 | The attribute layer uses its target's window (kept from the previous draft, to save 8 bytes) |
| V15 | DMACON is one byte with retro68k's enables in the same order but not the same bit numbers; the four audio enables are one reserved bit, AUDEN, until Q1 is decided |
| V16 | Pointers and the stride are even, as in retro68k, so a bitmap line cannot start at an odd byte. A Spectrum screen and every 16-pixel-aligned picture are unaffected |
| V17 | Closed: sprites are ordered by DEPTH first and by number within a DEPTH, as retro68k's video does (spec 5, section 3.4) |
| V18 | PRIO keeps retro68k's three fields for two layers; values 2 and 3 name no layer, so with the reset value DEPTH 2 and 3 are the same place |
