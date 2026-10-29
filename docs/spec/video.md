# Spec 4: Video

Status: **draft**

The video makes one 576p picture, sent over HDMI and VGA at once. It is retro68k's video as built (its spec 4, its guide chapter 3 "Playfield Hardware", and its RTL `video.v`, `bpldma.v` and `layer_pix.v`) narrowed to 8-bit registers: three layers L0–L2 fetched just in time through the DMA scheduler into data registers and shifters, mixed on the pixel side, with a palette per layer and one for the sprites, PRIO, direct colour and the display beam. The layers are chunky only. The one new piece of hardware is a **tile mode** in the layer fetcher (section 5.2). The attribute layer, the port `0xFE` border and the default palette are Spectrum extras (section 7).

## 1. Summary

| Item | Value |
|------|-------|
| Output | 576p (720 × 576, 50 Hz, CEA-861), 27 MHz pixel clock; DVI over HDMI and 24-bit VGA through the ADV7125, the same picture |
| Layers | Three, L0, L1 and L2, the same in every way. Each is a **bitmap** (chunky 1, 2, 4 or 8 bits per pixel) or a **tile map** (8 × 8 tiles of 1, 2, 4 or 8 bits per pixel), chosen by CTRL0.MODE |
| Per layer | Window (WINX, WINY, beam coordinates), scale 1×, 2×, 4× or 8× across and down (HSCALE, VSCALE), transparency, palette block (PALOFS) |
| Bitmap | One live pointer (BPL0PT), a signed stride (BPLSTRIDE), fine scroll (SCROLLX), pointer wrap (WRAP), as retro68k's chunky layers |
| Tile map | Map base (MAPPT), pattern base (PATPT), map 32, 64 or 128 entries each way (MAPW, MAPH), X and Y scroll round the map (SCROLLX, SCROLLY); 2-byte entries: tile number, palette block, X and Y flip, priority (PRI) |
| Priority | PRIO orders the layers; each sprite's DEPTH puts it among them (spec 5); PRI tile pixels go in front of all layers and of sprites with DEPTH 1–3 |
| Colours | 24-bit. PALETTE0–2 (one per layer) and SPRPALETTE, 256 entries each; PALOFS; VIDCON.SHAREPAL puts everything on PALETTE0. Background colour BGCOLOR (3 bytes). Direct colour: one layer per channel |
| Palette access | Index and data ports (PALIDX, PALDAT) in the globals; the palettes as memory in the register page (section 6.5) |
| Beam | All positions in beam coordinates. Software sees the **display beam**, as in retro68k |
| Fetch | Just in time, as retro68k: each layer has its data registers (its next group of 16 source pixels) and its shifters (the current group). Memory cycles 1 and 3 of every slot, earliest deadline first, shared with the sprites (spec 2) |
| Budget | A rate, as retro68k: **1.48 bytes per pixel** from the display's own cycles, at every point across the screen. 2×-tall layers fetch every line |
| Interrupts | VBLANK, LINE, VIDERR (spec 8 numbers them) |
| Registers | Custom block (spec 3): globals `0x000`–`0x00F`, sprites `0x010`–`0x08F` (spec 5), L0 `0x090`, L1 `0x0B0`, L2 `0x0D0` (32 bytes each), read-only status `0x0F0`–`0x0FF`, attribute layer `0x130`–`0x13F` |
| Spectrum extras | Attribute layer, port `0xFE` border, Spectrum colours in the default palette (section 7) |
| Block RAM | 2 RAMB36 for the palettes (section 9); no line buffer, no FIFOs |

## 2. Comparison with retro68k

| Feature | retro68k | retro-z80 | Why |
|---------|----------|-----------|-----|
| Pixel formats | Planar (1–8 planes) or chunky (1, 2, 4, 8 bpp) | Chunky only. CTRL0 bit 1 (PLANAR) and CTRL2 bits 2–0 (PLANES) are reserved | Branch 11. Eight pointers would not fit a 32-byte register block, and a Z80 draws chunky pixels more easily |
| Pointers | BPL0PT–BPL7PT | BPL0PT only; BPL1PT–BPL7PT left out | Chunky layers use BPL0PT only |
| Data registers | BPL0DAT–BPL7DAT, readable and writable; BPLDMA per plane | Inside the hardware, as retro68k's, but not registers: no BPLxDAT, no BPLDMA, no CPU-fed layers (open point V5) | The 8 data registers need 16 bytes, which a 32-byte block cannot spare; BPLDMA is no use without them |
| Tile maps | – (a later version) | CTRL0.MODE = 1: MAPPT, PATPT, CTRL3 (MAPW, MAPH), SCROLLX and SCROLLY round the map; a mode of the layer fetcher (section 5.2) | Branch 11: a full screen for little memory and bandwidth, and text with one write per character |
| Priority within a layer | – | A tile entry's PRI bit puts its pixels in front of all layers and of sprites with DEPTH 1–3 | Addition, kept from the previous draft |
| CTRL | One 32-bit register | Four byte registers, CTRL0–CTRL3, each written on its own; CTRL0–CTRL2 keep retro68k's bit positions | 8-bit registers; a copper MOVE changes PALOFS on its own |
| Registers | 32-bit, at `0xE00000` | Bytes, wider values low byte first; each byte is written directly, with no latch; a colour changes on its red byte (spec 3) | The Z80 |
| Global registers | `0x000`–`0x020` and DMACON at `0x094` | `0x000`–`0x00F`, packed; BEAMPOS, FRAMECOUNT and VIDSIZE at `0x0F0`–`0x0FF` | Copper MOVE codes `0xF0`–`0xFF` are other instructions (spec 6), so the read-only registers go there |
| Layer blocks | `0x100` + n × `0x80` | `0x090` + n × `0x20` | Copper MOVE reaches offsets `0x000`–`0x0EF` only |
| VIDSTAT | INVBLANK in bit 8 | INVBLANK in bit 3; OVERRUNA (attribute layer) in bit 2 | 8 bits |
| DMACON | 16 bits, Amiga bit positions | One byte, the same enables in the same order (section 6.1) | 8 bits |
| Palettes | Memory-mapped at `0xE04000`, 32-bit entries `0x00RRGGBB` | PALIDX and PALDAT ports; and the register page, 3-byte entries (blue, green, red) | 64 KB address space; the register page has 3 KB for them (section 6.5) |
| Palette write state per master | The held high half, one per writer (CPU, copper, DMA) | PALIDX, PALDAT's byte counter and the colour assembly buffer, one each per master | The same idea for 3-byte colours through an index port: the masters' writes never mix (spec 6, C14) |
| Palette contents after configuration | Undefined | Spectrum colours in entries 0–15, black elsewhere (section 7.4) | Spectrum extra (branch 11) |
| Urgent fetches | May take the CPU's cycle 0 | Never take a cycle the CPU uses; they go first in every other cycle | The Z80 never waits for SRAM (spec 2) |
| Memory cycle owners | 0 CPU, 1 and 3 display, 2 audio, 4 free pool | 0 and 2 CPU, 1 and 3 display, 4 audio (reserved) and the free pool | Spec 2 (branch 11) |
| Text | Drawn into a 1-plane bitmap | A 1 bpp tile layer, one map entry per character (section 8) | One 2-byte write per character, which a Z80 can afford |
| Attribute layer, port `0xFE` border | – | Spectrum extras (section 7) | Spectrum screens and programs |

Everything else is retro68k's: the mode, beam coordinates, the windows, the live pointer with stride and wrap, scaling, PALOFS, SHAREPAL, PRIO, direct colour, the fetch, the budget, OVERRUN and the write-timing rules.

## 3. Clocks, timing and the beam

### 3.1 Clocks

| Clock | Frequency | From | Use |
|-------|-----------|------|-----|
| System | 100 MHz | MMCM 1 (spec 2) | Memory slots of 100 ns, registers, the layer fetcher, palette writes, interrupts |
| Pixel | 27 MHz | MMCM 2 (50 ÷ 5 × 108 = 1080 MHz VCO, ÷ 40), as retro68k | The beam and the pixel pipeline |
| HDMI serialiser | 135 MHz | MMCM 2 (÷ 8) | Double-rate serialisers (OSERDESE2): 10 bits per pixel; also the fast "full" synchroniser (section 5.7) |

Both MMCMs run from the board's one oscillator, so one 576p line (864 pixels, 32 µs) is exactly 3200 system clocks, **320 memory slots**. The phase between the two clocks is not known, so they are treated as asynchronous, as in retro68k: events cross as toggles through two flip-flops, the data registers cross under a full/taken handshake (section 5.1), the beam position is sampled until two samples agree, and the layer settings are copied once per line. Nothing relies on the 320-slot coincidence.

In simulation the pixel clock runs free at an odd phase against the system clock, so the phase sweeps through every value along each line.

### 3.2 The mode

| Item | Value |
|------|-------|
| Visible | 720 × 576, 50 Hz progressive (CEA-861 formats 17 and 18: 4:3 or 16:9) |
| Horizontal | 720 visible, front porch 12, sync 64, back porch 68: 864 pixels (32 µs, 31.25 kHz) |
| Vertical | 576 visible, front porch 5, sync 5, back porch 39: 625 lines (20 ms, 50 Hz) |
| Sync | Both active low |
| Pixels | Not square: on a 4:3 screen a pixel is 16/15 as wide as it is tall |

There are no timing registers. VIDSIZE reads 720 × 576. The whole 720 × 576 is the overscan area; a normal screen is a window in it with the background colour round it as the border:

| Screen | Source | Window (beam coordinates) |
|--------|--------|---------------------------|
| Full screen | 360 × 288 at 2 × 2 | 144–864 × 49–625 |
| Spectrum size | 256 × 192 at 2 × 2 | 248–760 × 145–529 (centred) |
| 640 × 400 text | 80 × 25 characters of 8 × 8 at 1 × 2 | 184–824 × 137–537 |
| 640 × 480 | 1 × 1 | 184–824 × 97–577 |

### 3.3 Beam coordinates

Every position (BEAMPOS, LINECMP, the copper's WAIT and SKIP, layer windows, sprite windows) is in **beam coordinates**, which count the blanking too, as in retro68k:

| | Beam pixels (across, `hpixel`) | Beam lines (down, `vline`) |
|--|--|--|
| 0 | The start of the horizontal blank | The start of the vertical blank |
| Blank | 0–143 | 0–48 |
| The picture | 144–863 (720 pixels) | 49–624 (576 lines) |
| Total | 864 per line | 625 per frame |

A beam line starts with its horizontal blank and then shows its 720 pixels; a frame starts with its vertical blank. Positions only go up through a frame. `regmap.def` gives the picture's corner as VID_X0 = 144 and VID_Y0 = 49, its size as VID_W = 720 and VID_H = 576, and the totals as BEAM_W = 864 and BEAM_H = 625, as retro68k's `hw.inc`.

**Software sees the display beam**: the beam that is sending pixels to the connectors. BEAMPOS, FRAMECOUNT, LINECMP, VBLANK and the copper's waits (spec 6) all use it, as in retro68k.

| Register | Contents |
|----------|----------|
| BEAMPOS | `hpixel` (2 bytes, bits 10–0) and `vline` (2 bytes, bits 10–0). Reading its first byte captures all four, so they always match: read the first byte first |
| FRAMECOUNT | 16 bits, counts up at the start of each frame (beam 0, 0). Reading its first byte captures both |
| VIDSIZE | HVISIBLE (720) and VVISIBLE (576) |

The beam is counted on the pixel side. The system side samples it until two samples agree, as retro68k does, so a read is never torn; it lags the pixel side by a few system clocks.

### 3.4 Video interrupts

Each event sets a sticky flag in VIDSTAT, cleared by writing 1 to it. VIDINTEN has an enable for each flag. The unit's request to the interrupt controller is on while a flag and its enable are both set (level, as in retro68k; spec 8). The sources keep retro68k's names and numbers: VBLANK 0, LINE 1, VIDERR 3 (spec 8).

| Flag (VIDSTAT bit) | Source | When |
|--------------------|--------|------|
| VBLANK (0) | VBLANK | The start of the frame: beam line 0, pixel 0 (the start of the vertical blank) |
| LINE (1) | LINE | The start of beam line LINECMP: pixel 0, the start of its horizontal blank, 144 pixels before its picture. A value above 624 never matches |
| OVERRUNA (2) | VIDERR | The attribute layer's data was late (section 7.1) |
| OVERRUN0–2 (4–6) | VIDERR | Layer 0's, 1's or 2's next group was not ready in time (section 5.5) |
| SPRUNDER (7) | VIDERR | A sprite's FIFO ran dry (spec 5) |

- VIDERR is also raised by the sprite sequencer, a retro-z80 extra: SEQSTAT.SKIP with SEQCON.IRQEN (spec 17, section 8.1). VIDSTAT has no free bit, so its flag and enable are in the sequencer's own registers; a VIDERR handler reads both VIDSTAT and SEQSTAT.
- VIDSTAT.INVBLANK (bit 3, read only) is 1 while the beam is in lines 0–48.
- The first picture line, 49, is fetched from beam (49, 0), so a VBLANK handler has 49 lines (1.57 ms) to set up the next frame.
- The start of the vertical blank also stops every sprite: each frame the copper or the VBLANK handler starts each sprite again by writing its SPRxCTL (spec 5, section 4.2).
- A LINE handler runs during beam line LINECMP. Its writes to CTRL, WINX, WINY, SCROLLX, SCROLLY, PRIO or BGCOLOR act from line LINECMP + 1 if they are written before that line starts (32 µs: 640 T-states at 20 MHz, less the time the Z80 takes to start the handler); BPLSTRIDE acts at the end of the line being shown. This is retro68k's rule (section 5.6).

### 3.5 Output

The HDMI (DVI) and VGA outputs are retro68k's platform modules, copied in: `ks3_clocks.v` (the MMCMs), `tmds_encoder.v`, `hdmi_out.v` and `vga_out.v`. The ADV7125 takes 8 bits per colour over 4 pins at double rate and shows the same picture and timing as HDMI. Outside the picture the outputs are black with sync.

VIDCON.EN starts the beam. Clearing it stops the beam itself, as in retro68k: no picture, no sync and no VBLANK or LINE events; the monitor loses the signal. With EN set and no layer on, the screen shows BGCOLOR.

## 4. Layers

### 4.1 Overview

There are three layers, L0, L1 and L2, the same in every way. For every pixel the hardware takes the front-most source that is not transparent: a layer, a sprite (spec 5), or the background colour behind everything. In direct-colour mode (section 4.9) the three layers make one picture instead.

```
                 per layer
 SRAM ──fetch (cycles 1, 3 and spare)──▶ data registers ──▶ shifters ──┐
            map entries, attribute bytes                                ├─▶ priority ─▶ palette ─▶ HDMI and VGA
                                          sprites (spec 5) ─────────────┘    (or direct colour)
```

Each layer has its own registers (section 6.3): CTRL0–CTRL3, window, scroll, stride and pointers. The layers only meet at the priority stage.

A layer is fetched on a line when VIDCON.EN, DMACON.DMAEN, DMACON.BPLEN and its CTRL0.EN are set and its window covers the line. It is shown where PRIO names it. A layer that PRIO does not name is still fetched if it is enabled, but never shown, as in retro68k.

### 4.2 Modes and pixel formats

CTRL0.MODE picks what the layer is:

| MODE | Layer | Data |
|------|-------|------|
| 0 | Bitmap | A chunky picture at BPL0PT, BPLSTRIDE bytes from line to line (section 4.4) |
| 1 | Tile map | A map of 2-byte entries at MAPPT, naming 8 × 8 tiles at PATPT (section 4.5) |

**Chunky pixels**, for bitmaps and tile patterns alike: pixels of d = 1, 2, 4 or 8 bits (CTRL0.BPP) are packed in bytes, the leftmost pixel in the highest bits, bytes left to right at rising addresses. The SRAM is little-endian, so the fetcher puts each word's even byte in the high half of its data register: the data registers then hold the pixels in retro68k's order (leftmost pixel in the top bits of the first word).

| BPP | Bits per pixel | Pixels per byte | Colours |
|-----|----------------|-----------------|---------|
| 0 | 1 | 8 | 2 |
| 1 | 2 | 4 | 4 |
| 2 | 4 | 2 | 16 |
| 3 | 8 | 1 | 256 |

### 4.3 Display window

Each layer has a rectangle `XSTART ≤ x < XEND`, `YSTART ≤ y < YEND` in beam coordinates (WINX, WINY): the layer's display start and stop. Outside it the layer is transparent and nothing is fetched for it. Windows can overlap or sit side by side, so status panels and split screens need no copper. A full-screen window is 144, 864, 49, 625 (VID_X0, VID_X0 + VID_W, VID_Y0, VID_Y0 + VID_H), which is also the value after reset.

A window is clamped to the picture, as in retro68k: a start in the blank counts as the picture's edge, where the layer's first pixel then shows (layers are not clipped as sprites are), and an end past the last pixel or line counts as the picture's end. The window is in screen (beam) pixels: at 2× across, a 640-pixel window shows 320 source pixels.

The hardware works out the fetch from the window, the scale and the fine scroll: there are no fetch start and stop registers.

### 4.4 Bitmap mode: pointer, stride and scroll

As retro68k's chunky layers:

| Register | Bits | Meaning |
|----------|------|---------|
| BPL0PT | 21–1 (even) | Physical SRAM address of the layer's next word (spec 2). Bit 0 reads 0 |
| BPLSTRIDE | 15–0, signed (even) | Bytes from the start of one line to the start of the next. Bit 0 reads 0 |
| SCROLLX | 3–0 | Fine scroll: source pixels (0–15) skipped at the start of each line |
| CTRL2.WRAP | 7–4 | Pointer wrap (below) |

- **How the pointer moves.** Each word fetched moves BPL0PT on by 2. The line's first word saves the pointer: the line's start. The line's last word sets the pointer to **that start + BPLSTRIDE**. So at the end of each line inside the window the pointer is at its line's start + BPLSTRIDE, however many words were fetched: whole groups, the extra group of fine scroll and the window width make no difference.
- **One path for every move.** The pointer changes only when a word is fetched, or when the CPU or copper writes it. A write wins over the fetcher's own change in the same clock, and also sets the saved line start. Each byte is written directly, with no latch (spec 3, rule 2). So a pointer written while the layer is fetching picks up the fetcher's moves between its bytes: a fetch after the low byte and before the high byte moves the new low byte on, and the rest of the frame is shown from the wrong place. **Write the pointer only while the layer is not fetching**: in the vertical blank, above or below the layer's window, or, all three bytes, in the gap below.
- **Writing the pointer for a split.** A pointer written, all three bytes, between the layer's last fetch on line L and the start of line L + 1 (beam pixel 0) is line L + 1's start, as written. The last fetch is about two groups (32 source pixels) before the window's right edge, so with a full-width window the gap is about 1 µs at 1× and 2 µs at 2×: a copper job: a WAIT and three MOVEs fit the gap. One written earlier in line L is used for the rest of line L, and a write that spans a fetch gives the trouble above.
- **When BPLSTRIDE is read:** with the line's last fetch. A value written at the start of a line, or in the horizontal blank before it, applies at the end of that line.
- **The pointer is not reset by the hardware.** As in retro68k, the copper or the CPU (in its VBLANK handler) writes it every frame. If nothing rewrites it, the next frame carries on through memory.
- **Stride.** BPLSTRIDE = the picture's bytes per line shows a picture whose lines follow each other, at any window width. 0 repeats one line; −(bytes per line) steps back a line each time, showing the picture upside down.
- **Scrolling.** Down: move BPL0PT by whole lines. Across: coarse by moving BPL0PT by whole words (16, 8, 4 or 2 pixels at 1, 2, 4 or 8 bits per pixel), fine by SCROLLX. Any SCROLLX from 0 to 15 works at any depth, since a group is always 16 source pixels. With SCROLLX not 0 the line fetches one more group; the stride does not change.
- With vertical scaling, on each copy of a source line except the last, the last fetch sets the pointer back to the line's start (no stride added).

**Pointer wrap (CTRL2.WRAP).** As retro68k: with WRAP = n (1–13) the pointer stays inside an aligned block of 2^(n + 9) bytes (1 = 1 KB, 7 = 64 KB, 12 = 2 MB; 0 = no wrap). Every move the fetcher makes, word by word and at the end of each line, changes only the address bits inside the block. Values written by the CPU or copper are used as written. This gives endless vertical scrolling through a ring of lines. There is no wrap across a line.

| Layout | BPL0PT | BPLSTRIDE |
|--------|--------|-----------|
| 360 × 288, 4 bits per pixel, 2 × 2, full screen | base | 180 |
| 320 × 256 at 8 bits, window 640 × 512 at 2 × 2 | base | 320 |
| 640 × 480 at 1 bit, window 320 source pixels wide | base + left byte | 80 |

### 4.5 Tile mode: map, patterns and scroll

| Register | Bits | Meaning |
|----------|------|---------|
| MAPPT | 21–1 (even) | The map's first entry (column 0, row 0). Not moved by the hardware |
| PATPT | 21–1 (even) | Tile 0's first byte. Not moved by the hardware |
| CTRL3.MAPW | 1–0 | Map width: 0 = 32, 1 = 64, 2 = 128 entries; 3 reserved (as 128) |
| CTRL3.MAPH | 3–2 | Map height: 0 = 32, 1 = 64, 2 = 128 entries; 3 reserved (as 128) |
| SCROLLX | 9–0 | The map pixel at the window's left edge |
| SCROLLY | 9–0 | The map line at the window's top |

- **Map.** MW × MH entries of 2 bytes, row by row. Entry (column c, row r) is at `MAPPT + (r × MW + c) × 2`. A map takes 2 KB (32 × 32) to 32 KB (128 × 128).
- **Tiles.** A tile is 8 × 8 pixels of d bits (CTRL0.BPP): 8 rows of d bytes, row 0 first, packed as chunky pixels. Tile t's row y is at `PATPT + t × 8d + y × d`. Up to 512 tiles: 4 KB at 1 bit, 32 KB at 8 bits.
- **Scroll.** On the screen line showing source line n of the window (n counts source lines from YSTART; each is VSCALE screen lines), the map line is y = (SCROLLY + n) mod (8 × MH). Source pixel i across the window is map pixel x = (SCROLLX + i) mod (8 × MW). Map row = y >> 3, tile row = y & 7, and likewise across. Both wrap round the map, so it scrolls endlessly both ways; a map narrower than the window repeats across it. Unused high bits of SCROLLX and SCROLLY are ignored.
- **Lines.** SCROLLY, like the other line settings, is read at the start of each line (section 5.6), so a write during line L − 1 moves the map from line L: a split or a raster scroll needs one write, and nothing needs rewriting each frame.

**Map entry**, two bytes, low byte first:

| Bits | Field | Meaning |
|------|-------|---------|
| 8–0 | TILE | Tile number, 0–511 |
| 12–9 | PAL | Palette block for tiles of up to 4 bits (section 4.7) |
| 13 | XFLIP | The tile mirrored left to right |
| 14 | YFLIP | The tile upside down |
| 15 | PRI | The tile's pixels go in front of all layers and of sprites with DEPTH 1–3 (section 4.8) |

So the high byte is: bit 0 TILE bit 8, bits 4–1 PAL, bit 5 XFLIP, bit 6 YFLIP, bit 7 PRI.

Section 5.2 says how the fetcher reads a tile layer.

### 4.6 Scaling

CTRL0.HSCALE and CTRL1.VSCALE each pick 1×, 2×, 4× or 8× (values 0–3), as retro68k. Each source pixel is repeated that many times across, and each source line that many times down. There is no fractional scaling or shrinking.

| Picture | HSCALE, VSCALE | On the screen |
|---------|----------------|---------------|
| 360 × 288 | 2 × 2 | Full screen |
| 256 × 192 (Spectrum) | 2 × 2 | 512 × 384, centred at beam (248, 145) |
| 80 × 25 text, 8 × 8 characters | 1 × 2 | 640 × 400 |
| 180 × 144 | 4 × 4 | Full screen |
| 720 × 576 | 1 × 1 | Full screen |

- A layer at 2× across fetches half as much per screen pixel as at 1×.
- Scaling down the screen saves nothing in bandwidth: **each source line is fetched again for every screen line it shows on**, as in retro68k. It saves memory and drawing time.
- The first screen line of the window shows the first copy of the first source line. If the window's width or height is not a whole multiple of the scale, the last source pixel or line is cut short.

### 4.7 Transparency and palettes

**Palettes.** There are four palettes of 256 entries of 24-bit colour, as in retro68k: PALETTE0 for L0, PALETTE1 for L1, PALETTE2 for L2, and SPRPALETTE for the sprites (spec 5). Their palette numbers are 0, 1, 2 and 3. A layer's pixels take their colours from its own palette only. An entry is 3 bytes, blue, green, red, which is retro68k's `0x00RRGGBB` low byte first.

**Which entry a layer pixel uses.** The pixel value p of d bits becomes an index:

| Layer | d ≤ 4 | d = 8 |
|-------|-------|-------|
| Bitmap | PALOFS × 16 + p | p |
| Tile map | ((PALOFS + PAL) mod 16) × 16 + p, PAL from the tile's entry | p |
| Target of the attribute layer | From the attribute byte (section 7.1) | p |

CTRL1.PALOFS picks one of the palette's 16 blocks of 16 colours, as in retro68k, so one write swaps a layer's colours. For tiles, the entry's PAL is added, so each tile can have its own block and PALOFS still shifts the whole layer. A 1-bit layer uses the first two entries of its block.

**Shared palette.** With VIDCON.SHAREPAL set, every layer and sprite takes its colours from PALETTE0, as in retro68k.

**Transparency.** A layer is transparent outside its window, where it is not fetched, where its data was late (section 5.5), and where p = 0 if CTRL0.TRANSP is set. With TRANSP clear the layer is solid inside its window, and p = 0 shows entry 0 of its block. XFLIP and the attribute layer's flash act before the test.

**Background colour.** BGCOLOR is a register of its own, not a palette entry. It shows wherever no layer and no sprite has a pixel. VIDCON.BLANKALL shows BGCOLOR over the whole picture, hiding every layer and sprite without stopping them.

**Palette writes** take effect at once: the next pixel uses the new colour, so mid-line colour changes work. An entry changes whole when its red byte is written (section 6.5). The palettes are not cleared by reset; at configuration they hold the default palette (section 7.4).

### 4.8 Priority

PRIO lists the layers from front to back, as in retro68k:

| Bits | Field | Meaning |
|------|-------|---------|
| 1–0 | FRONT | Layer in front |
| 3–2 | MIDDLE | Next layer |
| 5–4 | BACK | Layer at the back |
| 7–6 | – | Reserved |

Each field holds a layer number, 0–2; 3 names no layer. Any order is allowed. After reset PRIO is `0x24`: L0 in front, then L1, then L2. Name each layer once.

Each sprite's 2-bit DEPTH (spec 5) puts it among the PRIO places, as retro68k's: 0 in front of all layers, 1 behind the FRONT place, 2 behind the MIDDLE place, 3 behind the BACK place. Tile pixels whose entry has PRI set move to a place of their own in front of all layers. So, back to front:

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

- A PRI tile pixel that is not transparent covers all layers and sprites of DEPTH 1–3, never DEPTH 0 ones. With TRANSP clear, a PRI tile's value 0 moves too.
- Sprites are placed by DEPTH first; among sprites of the same DEPTH the lower number is in front, as retro68k's video does (spec 5).
- PRIO is read at the start of each line's picture (section 5.6), so the order can change between lines.
- The priority stage tells the sprite unit where each layer has a non-transparent pixel, for SPRCOLL's layer bits (spec 5).

### 4.9 Direct colour

With VIDCON.DIRECT set, the layers' palettes, PRIO, PALOFS, PAL, PRI and TRANSP are not used (sprites still use SPRPALETTE, in front). Every visible pixel is made from the three layers' pixel values, as in retro68k:

| Channel | From | Depth |
|---------|------|-------|
| Red | L0 | L0's bits per pixel |
| Green | L1 | L1's |
| Blue | L2 | L2's |

- Each channel's value is widened to 8 bits by repeating its bits (a 4-bit value `abcd` becomes `abcdabcd`), so full scale stays full scale.
- With chunky layers the useful formats are 24-bit (8/8/8), 12-bit (4/4/4) and 6-bit (2/2/2); mixed depths work too. A tile layer gives its pixel values as a bitmap does.
- Software sets the three layers to the same window, scroll and scale. Where a layer has no pixel (outside its window, off, or late), its channel is 0.

### 4.10 Text

There is no text layer: text is a tile map of 1-bit tiles, one map entry per character. Printing a character is one 2-byte map write, and each character can have its own colour pair through PAL. The boot console is such a layer (section 8). The attribute layer can give a 1-bit layer Spectrum-style colours instead (section 7.1).

## 5. Fetch

This section is retro68k's fetch (its spec 4, section 5, and `bpldma.v`), with the tile mode and the attribute layer added. It sets the bandwidth and the timing rules the copper (spec 6) and sprites (spec 5) depend on.

### 5.1 Data registers and shifters

- Each layer has 8 data registers of 16 bits and 8 16-bit shifters inside, as retro68k's BPL0DAT–BPL7DAT. There is no other storage: the data registers hold the layer's **next group** of 16 source pixels while the shifters show the current group. They are not registers software can reach (section 2).
- **A group is always 16 source pixels**, d words for d bits per pixel, the first (leftmost pixels) in data register d − 1 and the last in data register 0, as retro68k's chunky groups. A tile group has the same shape (section 5.2). So every layer has 16 source pixels of time in hand.
- The group is **complete** when its last word arrives. The fetcher then toggles "full" to the pixel side; the shifters take all the data registers at once and toggle "taken" back.
- The shifters take the line's first group as soon as it is complete, in the horizontal blank, so the second group is already in the data registers when the window starts. After that they take the next group each time the current one is used up (every 16 source pixels × HSCALE). Each take empties the data registers, and the fetcher fetches the next group.
- **Start and stop:** at the start of the horizontal blank (beam pixel 0) of each line, each layer whose window covers the line starts its fetch; the number of groups comes from the window width, scale and fine scroll: ⌈(fine scroll + source pixels) ÷ 16⌉. A group still waiting from the line before is dropped. Nothing is fetched outside the windows.

### 5.2 The tile fetch

A tile layer is fetched by the same fetcher, through the same data registers and shifters, with the same groups of 16 source pixels. A group is **two tile columns** of 8 source pixels. The fetcher reads each column's map entry, then the column's pattern row, and writes the two rows into the data registers as a bitmap group of the same depth: column 0's row in the first d bytes, column 1's in the next. The pixel side sees an ordinary chunky group, plus each column's PAL and PRI.

**Where the line starts.** For the line's map line y (section 4.5), the first group starts at the tile column holding map pixel SCROLLX & ~7, and the shifters skip SCROLLX & 7 pixels of it (the fine scroll, 0–7). The groups then step two columns at a time, wrapping round the map at MW columns.

**Lookahead.** A pattern row's address needs its map entry, and a read's data comes back about 40 ns after its memory cycle (spec 2). So the fetcher reads the map entries **one group ahead** of the pattern rows: each tile layer has an entry register for the next group's two entries. The fetch of each group is:

1. The two pattern rows of group g, from the entries already held: each at `PATPT + TILE × 8d + row × d`, row = y & 7, or 7 − (y & 7) with YFLIP.
2. The two map entries of group g + 1, into the entry register.

Group g is complete when its last pattern word arrives (step 1). The entries of step 2 follow and are in place before the shifters take group g, which is when group g + 1's pattern fetch starts. The line's last group reads no entries.

**Line start.** At beam pixel 0 the entry register is empty, so the fetcher first reads group 0's entries, then group 0's rows (complete: the shifters take it at once), then group 1's entries, group 1's rows and group 2's entries. That is 6 entry words and two groups' rows before the window starts; the 144-pixel horizontal blank gives the display about 100 cycles of its own.

**Words.** Data is read as 16-bit words at even addresses. A 1-bit row is one byte, so its read gives a whole word and the fetcher keeps the byte it needs (the even or odd byte of the word). An 8 × 8 tile at d bits has rows of d bytes; at 2, 4 and 8 bits a row is 1, 2 or 4 whole words, since PATPT is even.

| Depth | Pattern words per group | Entry words per group | Memory cycles per group (16 source pixels) | A bitmap group |
|-------|-------------------------|-----------------------|--------------------------------------------|----------------|
| 1 bit | 2 | 2 | **4** | 1 |
| 2 bits | 2 | 2 | **4** | 2 |
| 4 bits | 4 | 2 | **6** | 4 |
| 8 bits | 8 | 2 | **10** | 8 |

**Flips.** YFLIP picks the row (step 1). XFLIP mirrors the row as the fetcher stores it in the data registers (pixel order reversed, each pixel's bits kept), so the shifters need nothing new. PAL and PRI of each column go to the pixel side with the group, in a small register of 2 × 5 bits beside the data registers; the pixel side applies them to the column's 8 source pixels.

**Deadlines.** The pattern words of group g carry the layer's deadline, as a bitmap's words do (section 5.3): the time until the shifters use up the group they hold. The entry words of group g + 1 are not needed until group g + 1's pattern fetch, so they carry that deadline plus one group's time (16 source pixels × HSCALE): they never go ahead of another layer's words that are due sooner, and they are urgent only when the next group would otherwise be late.

### 5.3 Memory cycles and the scheduler

The display (layers, the attribute layer and sprites) is one **hard-deadline** user of retro68k's DMA scheduler (`dmac.v`), which decides who gets every memory cycle (spec 2):

| Cycle (spec 2) | Owner | Display use |
|----------------|-------|-------------|
| 0, 2 | CPU | Only when the CPU leaves the cycle (free order) |
| 1, 3 | Display | Always the display's first, earliest deadline first; the free order when no layer or sprite wants it |
| 4 | Audio (reserved) and the free pool | Free order: hard-deadline users first, then the copper and the DMA engine (spec 2) |

- **Order: earliest deadline first.** When a layer's shifters take a group, the layer's countdown loads the time that group lasts: 16 source pixels × HSCALE, about 59 system clocks at 1× (593 ns), 118 at 2×. Each word goes to the layer or sprite whose deadline is nearest; layers with equal deadlines take turns. The line's first take (the group loaded in the horizontal blank) sets no deadline.
- **Urgent.** A request whose deadline is about to pass (the words its group still needs, at about 50 ns each, plus about 140 ns for the read and the crossing back) is **urgent**. An urgent request goes first in every cycle except a CPU cycle (0 or 2) that the CPU has asked for: unlike retro68k, it never takes the CPU's cycle, because the Z80 never waits for SRAM (spec 2, section 5.3). Such a fetch waits at most one memory cycle (20 ns), since cycles 0 and 2 are each followed by a display cycle, so the urgent mark is set one memory cycle (2 clocks) earlier than retro68k's (spec 2, open point M5).
- With vertical scaling, each source line is fetched again for every screen line it shows on.

### 5.4 Budget

Data is fetched while it is shown, so the budget is a **rate**, as in retro68k: the bytes that can be fetched for each pixel the beam passes. The display's own cycles give 4 bytes every 100 ns, and a pixel lasts 37 ns: **1.48 bytes per pixel** (1280 bytes in a line of 864 pixels).

A layer needs, per screen pixel:

| Layer | Bytes per screen pixel |
|-------|------------------------|
| Bitmap, d bits per pixel | d ÷ 8 ÷ HS |
| Tile map, 1 or 2 bits | 0.5 ÷ HS |
| Tile map, 4 bits | 0.75 ÷ HS |
| Tile map, 8 bits | 1.25 ÷ HS |
| Attribute layer | 0.125 ÷ the target's HS |

(Tiles: the memory cycles per group of section 5.2 × 2 bytes ÷ 16 pixels.) HS is the horizontal scale; vertical scaling does not reduce the cost. **At every point across the screen, the layers whose windows cover it, with the sprites there (spec 5), must add up to no more than the budget.**

| Screen | Bytes per pixel | Fits? |
|--------|-----------------|-------|
| Spectrum screen: 1-bit bitmap at 2 × 2 with attributes (section 7.3) | 0.0625 + 0.0625 = **0.125** | Yes |
| Boot console, 80 × 30 text: 1-bit tiles at 1 × 2 (section 8) | **0.5** | Yes |
| Text as above over a 4-bit 360 × 288 bitmap at 2 × 2 | 0.5 + 0.25 = **0.75** | Yes |
| Platform game: two 4-bit tile layers at 2 × 2 (parallax) and an 8-bit bitmap at 2 × 2 | 0.375 + 0.375 + 0.5 = **1.25** | Yes |
| Two 8-bit tile layers at 2 × 2 | 0.625 + 0.625 = **1.25** | Yes |
| One 8-bit tile layer at 1 × 1 | **1.25** | Yes |
| 8-bit bitmap at 1× and 4-bit tiles at 2× | 1.0 + 0.375 = **1.375** | Yes |
| 8-bit bitmap at 1× and 4-bit bitmap at 1× | **1.5** | **No** (just over) |
| Three 8-bit tile layers at 2 × 2 | **1.875** | **No** |
| Direct colour 12-bit (4/4/4) at 2× | **0.75** | Yes |
| Direct colour 24-bit (8/8/8) at 4× across | **0.75** | Yes |
| Direct colour 24-bit at 2× | **1.5** | **No** (just over) |
| Two 8-bit bitmaps at 1× | **2.0** | **No** |

The 1.48 is what cycles 1 and 3 guarantee. The scheduler also gives the display any cycle nobody else wants: cycle 4 (audio is not built) before the copper and the DMA engine, and the CPU's cycles 0 and 2 when the Z80 leaves them, which at 20 MHz is most of them (a memory access every 3 or 4 T-states, 1.5 or 2 slots). So a screen a little over the budget usually shows correctly, at the copper's and the DMA engine's expense; unlike retro68k it cannot borrow from the CPU. How far beyond 1.48 a screen can go is to be measured in simulation (open point V9). Windows help: a status panel below a game area, not on top of it, adds nothing on the game's lines.

Each layer has one group of time in hand. Close to the budget, 8-bit layers at 1× (8 words per group, or 10 for tiles) are the first to run short.

### 5.5 When a layer runs short

If a layer's next group is not complete when its shifters need it, the layer shows transparent pixels (in direct colour: 0) for that group, and tries again at the next one. Its OVERRUN flag is set (VIDSTAT bits 4–6), which can raise VIDERR. Nothing else on the display goes wrong, and the CPU is never affected. A late attribute group is section 7.1's (OVERRUNA); a late sprite is spec 5's (SPRUNDER). A screen within the budget never overruns, so OVERRUN is mainly a check while a program is written.

### 5.6 When register writes take effect

These are retro68k's rules. Each byte takes effect when it is written, with no latch; a colour (BGCOLOR, a palette entry) when its red byte is written (spec 3, rules 2 and 7). So a line setting copied at beam pixel 0 while it is half written shows that one line with the new low byte and the old high byte. **Change wide registers in the vertical blank, or with the copper at a set position**, as on the Amiga: a copper list writes a line setting's bytes in the horizontal blank or the visible part of the line before.

| Registers | Take effect |
|-----------|-------------|
| CTRL0–CTRL3, WINX, WINY, SCROLLX, SCROLLY, MAPPT, PATPT; ATCTL, ATADDR, ATSTRIDE, ATSCROLL (section 7.1) | At the start of the horizontal blank before each line (beam pixel 0). **To change line L, write during the visible part of line L − 1 or earlier** |
| BPL0PT, BPLSTRIDE | At once: they are live. The next word fetched uses a new pointer, which also becomes the pointer's saved line start; a CPU or copper write wins over the fetcher's own change in the same clock. BPLSTRIDE is used with the line's last fetch (section 4.4) |
| PRIO, BGCOLOR | At the start of each line's picture (beam pixel 144), so a write in the line's horizontal blank still changes that line |
| Port `0xFE` border bits (section 7.2) | At once: from the pixel being shown, about 10–60 ns after the write (a Spectrum extra) |
| VIDCON, palette entries | At once (the next pixel) |
| LINECMP, VIDSTAT, VIDINTEN, PALIDX, DMACON | At once (DMACON stops or starts the next fetch) |
| Sprite registers (spec 5, section 4.2) | A write to SPRxCTL starts the sprite; SPRxPT, SPRxH, SPRxV and SPRxSTEP act on a running sprite from the next line. The vertical blank (beam line 0, pixel 0) stops every sprite |

The settings read at beam pixel 0 are copied to the pixel side once per line. A write that lands in the same few clocks as that copy may take effect a line later, as in retro68k.

### 5.7 Clock crossings and turnaround

The pixel side (27 MHz) and the memory side (100 MHz) are asynchronous (section 3.1). The crossing does not change the display's bandwidth; it adds **latency** to each group, as in retro68k:

| Step | Time |
|------|------|
| The shifters take a group; the memory side sees "taken" (two flip-flops at 100 MHz, plus the phase) | up to 30 ns |
| The fetcher asks, and waits for the next display cycle (cycles 1 and 3, 40 and 60 ns apart) | 10–70 ns |
| The group's words, two per 100 ns slot | about 50 ns each after the first |
| The last word: SRAM read to the data register | 50 ns |
| "Full" reaches the pixel side: two flip-flops at 135 MHz, then read by the pixel side as a related clock | 7–22 ns |
| **Fixed part** | **about 80–170 ns** |

The next group must be complete before the current one is used up: 593 ns at 1×, 1185 ns at 2×. The display's cycle positions (1 and 3) are retro68k's, so these figures hold. retro68k measured every tested screen up to 1.5 bytes per pixel as fitting, with layers in step; those measurements used the CPU's cycle 0 for urgent fetches, which retro-z80 does not, and had no tile layers. They are to be repeated here (open point V9).

## 6. Registers

All registers are bytes in the **custom block** (spec 3). Custom offset n is I/O port `((n & 0xFF) << 8) | (0x10 + (n >> 8))`: write with `LD BC,port` and `OUT (C),r`, stepping to the next register with `INC B`; read with `LD A,n & 0xFF` and `IN A,(0x10 + (n >> 8))`. The same registers are at offset `0x1000 + n` of the register page (MMU page `0x3F8`). Values wider than a byte are at consecutive offsets, low byte first; each byte is written directly, a colour changes when its red byte is written, and reading the low byte of a counter captures it (spec 3). The copper's MOVE reaches offsets `0x000`–`0x0EF`, which holds every register here a copper list changes per line (spec 6). Reserved bits read 0; unused offsets read `0xFF` (spec 3). Unless stated, reset values are 0.

### 6.1 Global registers (`0x000`–`0x00F`)

| Offset | Port | Name | Access | Bits | Meaning |
|--------|------|------|--------|------|---------|
| `0x000` | `0x0010` | VIDCON | RW | EN (0), BLANKALL (2), DIRECT (4), SHAREPAL (5); 1, 3, 6, 7 reserved | Beam on; show BGCOLOR only; direct colour; everything on PALETTE0 |
| `0x001` | `0x0110` | VIDSTAT | W1C (INVBLANK R) | VBLANK (0), LINE (1), OVERRUNA (2), INVBLANK (3), OVERRUN0 (4), OVERRUN1 (5), OVERRUN2 (6), SPRUNDER (7) | Sticky flags, write 1 to clear (section 3.4) |
| `0x002` | `0x0210` | VIDINTEN | RW | As VIDSTAT bits 0, 1, 2, 4–7; bit 3 reserved | Interrupt enables |
| `0x003` | `0x0310` | PRIO | RW | FRONT (1–0), MIDDLE (3–2), BACK (5–4) | Layer order (section 4.8). Reset `0x24` |
| `0x004`–`0x006` | `0x0410`–`0x0610` | BGCOLOR | RW | Blue (`0x004`), green (`0x005`), red (`0x006`, commits) | Background colour; also set by port `0xFE` (section 7.2). Blue and green go into the master's colour assembly buffer; the red byte writes all three, as a palette entry (section 6.5) |
| `0x007`–`0x008` | `0x0710`, `0x0810` | LINECMP | RW | 10–0 | Beam line of the LINE event |
| `0x009`–`0x00A` | `0x0910`, `0x0A10` | PALIDX | RW | 7–0 entry; 9–8 palette (0–2 PALETTE0–2, 3 SPRPALETTE) | Palette index (section 6.5) |
| `0x00B` | `0x0B10` | PALDAT | RW | 7–0 | Palette data: blue, green, red (section 6.5) |
| `0x00C` | `0x0C10` | DMACON | Set/clear | SETCLR (7), DMAEN (6), BPLEN (5), COPEN (4), BLTEN (3), SPREN (2), AUDEN (1); 0 reserved | DMA enables (below) |
| `0x00D`–`0x00F` | | – | | | Reserved |

**DMACON** is retro68k's DMA enable register (its spec 5, section 8), narrowed to one byte with its enables in the same order. Writing with bit 7 = 1 sets the bits written as 1; with bit 7 = 0 clears them; bits written as 0 are left alone. Reading gives the enables (bit 7 reads 0). All off after reset.

| Bit | Name | Enables | retro68k bit |
|-----|------|---------|--------------|
| 7 | SETCLR | 1 = set, 0 = clear the bits written as 1 | 15 |
| 6 | DMAEN | Master enable for everything below | 9 |
| 5 | BPLEN | Layer and attribute fetch (with VIDCON.EN and each CTRL0.EN) | 8 |
| 4 | COPEN | Copper (spec 6) | 7 |
| 3 | BLTEN | DMA engine (spec 14) | 6 |
| 2 | SPREN | Sprites (spec 5) | 5 |
| 1 | AUDEN | Audio, reserved (spec 13) | 3–0 (AUD0EN–AUD3EN) |
| 0 | – | Reserved | 4 (unused) |

### 6.2 Read-only status (`0x0F0`–`0x0FF`)

| Offset | Port | Name | Bits | Meaning |
|--------|------|------|------|---------|
| `0x0F0`–`0x0F1` | `0xF010`, `0xF110` | BEAMPOS (HPIXEL) | 10–0 | Beam `hpixel`, 0–863. Reading `0x0F0` captures all four BEAMPOS bytes |
| `0x0F2`–`0x0F3` | `0xF210`, `0xF310` | BEAMPOS (VLINE) | 10–0 | Beam `vline`, 0–624 |
| `0x0F4`–`0x0F5` | `0xF410`, `0xF510` | FRAMECOUNT | 15–0 | Frames; reading `0x0F4` captures both bytes |
| `0x0F6`–`0x0F7` | `0xF610`, `0xF710` | VIDSIZE (HVISIBLE) | 10–0 | 720 |
| `0x0F8`–`0x0F9` | `0xF810`, `0xF910` | VIDSIZE (VVISIBLE) | 10–0 | 576 |
| `0x0FA`–`0x0FF` | | – | | Reserved |

Writes are ignored. A copper MOVE cannot name these offsets: codes `0xF0`–`0xFF` are its other instructions (spec 6).

### 6.3 Layer registers

Layer n (0–2) is at `0x090 + n × 0x20`: L0 at `0x090`–`0x0AF` (ports `0x9010`–`0xAF10`), L1 at `0x0B0`–`0x0CF` (`0xB010`–`0xCF10`), L2 at `0x0D0`–`0x0EF` (`0xD010`–`0xEF10`). `regmap.def` gives `L0`, `L1`, `L2`, the offsets `L_CTRL0` … `L_PATPT`, `L_SPAN` (`0x20`) and ready-added names (`L1_BPL0PT`), as retro68k's `hw.inc`.

| Offset | Name | Access | Bits | Meaning |
|--------|------|--------|------|---------|
| `+0x00` | CTRL0 | RW | EN (0), BPP (3–2), TRANSP (4), MODE (5), HSCALE (7–6); 1 reserved | retro68k's CTRL bits 7–0 (section 6.4) |
| `+0x01` | CTRL1 | RW | VSCALE (1–0), PALOFS (7–4); 3–2 reserved | CTRL bits 15–8 |
| `+0x02` | CTRL2 | RW | WRAP (7–4); 3–0 reserved | CTRL bits 23–16 |
| `+0x03` | CTRL3 | RW | MAPW (1–0), MAPH (3–2); 7–4 reserved | CTRL bits 31–24: tile map size |
| `+0x04`–`+0x05` | WINX (XEND) | RW | 10–0 | First beam pixel after the window. Reset 864 |
| `+0x06`–`+0x07` | WINX (XSTART) | RW | 10–0 | First beam pixel of the window. Reset 144 |
| `+0x08`–`+0x09` | WINY (YEND) | RW | 10–0 | First beam line after the window. Reset 625 |
| `+0x0A`–`+0x0B` | WINY (YSTART) | RW | 10–0 | First beam line of the window. Reset 49 |
| `+0x0C`–`+0x0D` | SCROLLX | RW | 9–0 | Bitmap: fine scroll, bits 3–0. Tiles: map X (section 4.5) |
| `+0x0E`–`+0x0F` | SCROLLY | RW | 9–0 | Tiles: map Y. Not used by bitmaps |
| `+0x10`–`+0x11` | BPLSTRIDE | RW | 15–0, signed, even | Bytes from one line's start to the next (section 4.4) |
| `+0x12`–`+0x13` | – | | | Reserved (retro68k's BPLDMA) |
| `+0x14`–`+0x16` | BPL0PT | RW | 21–1 | Bitmap: the next word's address (section 4.4) |
| `+0x17` | – | | | Reserved |
| `+0x18`–`+0x1A` | MAPPT | RW | 21–1 | Tiles: map base |
| `+0x1B` | – | | | Reserved |
| `+0x1C`–`+0x1E` | PATPT | RW | 21–1 | Tiles: pattern base |
| `+0x1F` | – | | | Reserved |

- **CTRL0–CTRL3 are four byte registers, each written on its own.** They hold separate fields, not one value: a copper list changes PALOFS with one MOVE. retro68k's bit positions are kept: CTRLk bit b is CTRL bit 8k + b.
- WINX and WINY are retro68k's 32-bit registers in byte order: their low halves (XEND, YEND) come first. Each half is a 2-byte value on its own. Change a window in the vertical blank or with the copper, so that no line starts with it half written.
- Pointers are 3 bytes; bits 23–22 are ignored and bit 0 reads 0 (spec 2).
- BPL0PT reads the live pointer, which moves as words are fetched. Reading its low byte (`+0x14`) captures all three bytes, so a read low byte first is never torn (spec 3).

### 6.4 CTRL fields

| Register | Bits | Field | Values |
|----------|------|-------|--------|
| CTRL0 | 0 | EN | 1: layer on |
| | 1 | – | Reserved (retro68k's PLANAR); write 0 |
| | 3–2 | BPP | 0 = 1, 1 = 2, 2 = 4, 3 = 8 bits per pixel |
| | 4 | TRANSP | 1: pixel value 0 is transparent |
| | 5 | MODE | 0: bitmap, 1: tile map (retro68k's bit 5 is unused) |
| | 7–6 | HSCALE | 0–3: 1×, 2×, 4×, 8× across |
| CTRL1 | 1–0 | VSCALE | 0–3: 1×, 2×, 4×, 8× down |
| | 3–2 | – | Reserved |
| | 7–4 | PALOFS | Palette block for layers of up to 4 bits (section 4.7) |
| CTRL2 | 2–0 | – | Reserved (retro68k's PLANES); write 0 |
| | 3 | – | Reserved |
| | 7–4 | WRAP | Bitmap: pointer wrap, 0 off, n = blocks of 2^(n + 9) bytes (1–13) |
| CTRL3 | 1–0 | MAPW | Tiles: 0 = 32, 1 = 64, 2 = 128 entries wide; 3 reserved |
| | 3–2 | MAPH | Tiles: 0 = 32, 1 = 64, 2 = 128 entries high; 3 reserved |
| | 7–4 | – | Reserved |

### 6.5 Palettes

**Through ports.** PALIDX is a 10-bit index: bits 7–0 the entry, bits 9–8 the palette number (0–2 PALETTE0–2, 3 SPRPALETTE), so the index is retro68k's palette address ÷ 4. Each byte of PALIDX acts when it is written, and writing either byte resets PALDAT's byte counter. **Each master (the CPU, the copper, the DMA engine) has its own PALIDX and byte counter**, as retro68k keeps its palette's held half per writer: a master's PALIDX and PALDAT writes move only its own, and the CPU reads its own PALIDX (spec 6, open point C14). PALDAT reads or writes the entry at the index, one byte at a time: blue, green, red. Blue and green writes go into the master's **colour assembly buffer**: one each for the CPU, the copper and the DMA engine, shared by PALDAT, the register page palettes and BGCOLOR, not a latch per entry (spec 3, rule 7). So the CPU's and the copper's colours never mix, whatever order their writes come in. The **red write changes the entry whole**, with the buffer's blue and green, and steps the index by 1 (from 255 of one palette to 0 of the next; from `0x3FF` to 0). A red read steps it too. So a loop of `OUT (C),r` with B fixed at PALDAT's register writes a palette, 3 bytes per entry. `OTIR` cannot be used: it counts B down, and B is the register number (spec 3; open point V4).

**Through the register page.** The palettes are memory in the register page (spec 2, section 10.2), 3 bytes per entry, packed:

| Register page | Palette |
|---------------|---------|
| `0x1400`–`0x16FF` | PALETTE0 |
| `0x1700`–`0x19FF` | PALETTE1 |
| `0x1A00`–`0x1CFF` | PALETTE2 |
| `0x1D00`–`0x1FFF` | SPRPALETTE |

Entry i of palette p is at `0x1400 + p × 0x300 + 3i`: blue, green, red. The blue and green bytes go into the colour assembly buffer and the red byte changes the entry whole, as through PALDAT. This path does not use or change PALIDX. `LDIR` copies a palette (it writes rising addresses, so red comes last in each entry). The palettes have no I/O port of their own: the register page offsets `0x1400`–`0x1FFF` lie beyond the custom pages (`0x1000`–`0x13FF`) and match no port (open point V3).

**Copper and DMA engine.** The copper reaches the palettes through PALIDX and PALDAT: a colour change is five MOVEs, three when PALIDX already points at the entry. The DMA engine's palette destination is spec 14's.

## 7. Spectrum extras

These are not in retro68k. They are kept for Spectrum screens and programs, each outside the retro68k-shaped core.

### 7.1 Attribute layer

The attribute layer draws nothing. It replaces the palette block of its **target**, L0, L1 or L2 (ATCTL.TARGET), with one byte per cell, as a Spectrum's attributes do.

- **Cells** are 8 source pixels across and 8 or 1 source lines down (ATCTL.CELL1) of the target, so they follow its HSCALE and VSCALE: an 8 × 8 cell on a 2 × 2 layer covers 16 × 16 beam pixels. It works on bitmaps and tile maps alike.
- **Window:** the target's. The attribute layer acts only where its target is shown.
- **Addresses:** ATADDR is the address of the cell row at the window's top-left; each cell row is ATSTRIDE bytes after the one before. The hardware keeps its own row address: it starts at ATADDR on the window's top line, and steps by ATSTRIDE after every 8 source lines of the target (8 × 8) or every source line (8 × 1). A line whose setup (beam pixel 0) comes after ATADDR was written restarts at ATADDR, so the copper can set any row's address. ATADDR itself is not moved, so it needs no rewriting each frame. ATADDR and ATSTRIDE are even.
- **Scroll:** ATSCROLL bits 3–0 skip 0–15 source pixels (two cells) at the start of each line; bits 6–4 start the first cell row 0–7 lines into the row (8 × 8 only). Coarse scroll is by ATADDR, in whole words (two cells). To follow a scrolled target, set fine X = the target's scroll mod 16 and move ATADDR by the rest.
- **Index:** with attribute byte A, the target's pixel p of d bits takes entry `((A << d) | p) & 0xFF` of the target's palette, in place of PALOFS and the tile entry's PAL. For a 1-bit target, **index = (A & 0x7F) × 2 + p**: a Spectrum attribute (flash, bright, paper, ink) picks a pair of entries, 2A for paper and 2A + 1 for ink, and the flash bit is not part of the index. For a 2-bit target A picks one of 64 groups of 4; for a 4-bit target bits 3–0 pick one of 16 blocks; an 8-bit target's index is p.
- **Flash:** with ATCTL.FLASH set, bit 7 of A is a flash bit. While the flash phase is on, a cell with bit 7 set has its pixel value inverted (p XOR (2^d − 1)), which swaps paper and ink for a 1-bit target. Transparency is tested after this. The phase changes every 8, 16, 32 or 64 frames (ATCTL.RATE; the Spectrum's is 16) and reads in ATCTL.PHASE.
- **Fetch:** a fourth channel of the layer fetcher, with its own data register and shifter, fetched just in time as a layer is: a group is one word (two cells, 16 source pixels of the target), ⌈(fine X + source pixels) ÷ 16⌉ words per line. Its deadline counts at the target's scale, as a 1-bit layer's. It costs 0.125 ÷ HS bytes per pixel (section 5.4). It is fetched on every screen line of its target, including each copy of a 2×-tall line.
- **Late data:** if an attribute group is not complete when it is needed, the target's pixels in those two cells are transparent, OVERRUNA is set (VIDSTAT bit 2) and VIDERR can be raised.
- The attribute layer is on when ATCTL.EN is set and its target is fetched on the line. In direct colour it has no effect.

**Registers** (custom `0x130`–`0x13F`, ports `0x3011`–`0x3F11`; the copper reaches them with MOVEF only, spec 6):

| Offset | Port | Name | Access | Bits | Meaning |
|--------|------|------|--------|------|---------|
| `0x130` | `0x3011` | ATCTL | RW (PHASE R) | EN (0), TARGET (2–1: 0 L0, 1 L1, 2 L2, 3 none), CELL1 (3: 0 = 8 × 8, 1 = 8 × 1), FLASH (4), RATE (6–5: 8, 16, 32, 64 frames), PHASE (7, read only) | Control |
| `0x131`–`0x133` | `0x3111`–`0x3311` | ATADDR | RW | 21–1 | Cell row address at the window's top; bit 0 reads 0 |
| `0x134` | `0x3411` | ATSTRIDE | RW | 7–1 | Bytes per cell row (0–254); bit 0 reads 0 |
| `0x135` | `0x3511` | ATSCROLL | RW | 3–0 fine X, 6–4 fine Y | Fine scroll |
| `0x136`–`0x13F` | | – | | | Reserved |

ATCTL (except PHASE), ATADDR, ATSTRIDE and ATSCROLL are read at the start of each line, as CTRL is (section 5.6).

### 7.2 Border: port 0xFE

As on a Spectrum, a write to port `0xFE` sets the border colour, which here is the background colour. Port `0xFE` itself (the keyboard on reads, the beeper in bit 4, MIC in bit 3) is spec 12's. Bits 2–0 pick one of eight fixed colours, the Spectrum's colours without BRIGHT, at level `0xD7`:

| Bits 2–0 | Colour | BGCOLOR (`0xRRGGBB`) |
|----------|--------|----------------------|
| 0 | Black | `0x000000` |
| 1 | Blue | `0x0000D7` |
| 2 | Red | `0xD70000` |
| 3 | Magenta | `0xD700D7` |
| 4 | Green | `0x00D700` |
| 5 | Cyan | `0x00D7D7` |
| 6 | Yellow | `0xD7D700` |
| 7 | White | `0xD7D7D7` |

- The write sets all three bytes of BGCOLOR at once, as a write of BGCOLOR's red byte does; BGCOLOR then reads back the new value. The CPU's colour assembly buffer is not changed.
- BGCOLOR and port `0xFE` set the same register, so the later write wins. A program that wants other border colours (BRIGHT ones, say) writes BGCOLOR.
- **A port `0xFE` write acts at once**, as on a Spectrum, so a program that changes the border in the middle of a line (a tape loader's stripes) shows the change in the middle of the line. The write sends the colour to the pixel side as well as to BGCOLOR: the 3 bits cross as a toggle through two flip-flops at 135 MHz, as "full" does (section 5.7, 7–22 ns), and the pixel side takes the colour at its next pixel (up to 37 ns). So the new colour shows from the pixel being shown about 10–60 ns after the write reaches the register bus, one or two pixels late. At the start of the next line's picture the pixel side reads BGCOLOR as usual, which holds the same colour.
- **BGCOLOR written as a register keeps retro68k's rule**: it is read at the start of each line's picture (section 5.6), so its changes land on whole lines. This holds for the CPU, the copper and the DMA engine. A port `0xFE` write after a BGCOLOR write in the same line shows at once; a BGCOLOR write after a port `0xFE` write shows from the next line's picture.
- The background shows wherever no layer and no sprite is opaque. With the Spectrum screen of section 7.3 (TRANSP clear) that is everywhere outside the 256 × 192 window, as a Spectrum's border.
- The copper cannot write port `0xFE`; it writes BGCOLOR.

### 7.3 Example: the Spectrum screen

A 48K Spectrum screen file (6,144 bytes of pixels in the Spectrum's line order, then 768 attribute bytes) at physical address `screen` (even), shown unchanged:

| Register | Value |
|----------|-------|
| L0 CTRL0 | EN, BPP 0 (1 bit), TRANSP 0, MODE 0 (bitmap), HSCALE 1: `0x41` |
| L0 CTRL1 | VSCALE 1, PALOFS 0: `0x01` |
| L0 window | XSTART 248, XEND 760, YSTART 145, YEND 529 |
| L0 BPLSTRIDE | 256 (the next pixel line of the same character row) |
| ATCTL | EN, TARGET L0, 8 × 8, FLASH, RATE 1 (16 frames): `0x31` |
| ATADDR, ATSTRIDE | screen + 6144, 32 |
| PALETTE0 | Entries 2A (paper) and 2A + 1 (ink) for A = 0–127, from the 16 Spectrum colours of section 7.4: paper (A >> 3) & 7, ink A & 7, plus 8 if bit 6 (bright) is set |
| BGCOLOR | Set by port `0xFE` |
| DMACON | SETCLR, DMAEN, BPLEN |

**The copper sets the layer pointer every line.** A Spectrum screen's pixel line y is at `screen + ((y & 0xC0) << 5) + ((y & 7) << 8) + ((y & 0x38) << 2)`. Source line k is shown on beam lines 145 + 2k and 146 + 2k, and fetched on both. Its address must be written, all three bytes, after L0's last fetch on beam line 144 + 2k and before beam pixel 0 of line 145 + 2k (section 4.4). L0's last fetch on a line is before its window's right edge, 760, so for each k the copper:

1. waits for beam (144 + 2k, 768);
2. writes L0's BPL0PT (custom `0x0A4`–`0x0A6`, inside MOVE's reach) with line k's address: three MOVEs, all after the wait, so no fetch comes between them.

That is 5 words a line, 192 times a frame; 96 pixels (3.5 µs) are left after the wait. On line 145 + 2k the fetch starts at the written address; at that line's end the pointer goes back to it (a copy of a 2×-tall line), and on line 146 + 2k it goes on to the address + 256, which the copper then overwrites.

**Every character row (cheaper):** within a character row of 8 lines each line is 256 bytes after the one before, which BPLSTRIDE = 256 does by itself. So the copper writes BPL0PT only for the first line of each row r = 0–23, `screen + ((r & 0x18) << 8) + ((r & 7) << 5)`, waiting for beam (144 + 16r, 768): 24 times a frame (row 0's write can be in the vertical blank).

A program that keeps its screen in linear order needs no copper: BPL0PT = screen, BPLSTRIDE = 32, written each frame in the vertical blank.

Cost: 0.0625 bytes per pixel for the bitmap and 0.0625 for the attributes, inside the 512-pixel window only.

### 7.4 Default palette

At configuration (from the bitstream; reset does not change the palettes) all four palettes hold the Spectrum colours in entries 0–15 and black in entries 16–255:

| Entry | Colour | Value (`0xRRGGBB`) | Entry | Colour | Value |
|-------|--------|--------------------|-------|--------|-------|
| 0 | Black | `0x000000` | 8 | Black | `0x000000` |
| 1 | Blue | `0x0000D7` | 9 | Bright blue | `0x0000FF` |
| 2 | Red | `0xD70000` | 10 | Bright red | `0xFF0000` |
| 3 | Magenta | `0xD700D7` | 11 | Bright magenta | `0xFF00FF` |
| 4 | Green | `0x00D700` | 12 | Bright green | `0x00FF00` |
| 5 | Cyan | `0x00D7D7` | 13 | Bright cyan | `0x00FFFF` |
| 6 | Yellow | `0xD7D700` | 14 | Bright yellow | `0xFFFF00` |
| 7 | White | `0xD7D7D7` | 15 | Bright white | `0xFFFFFF` |

So a 4-bit layer or sprite with PALOFS 0 shows the Spectrum colours with no palette set-up, and entry k is the colour of Spectrum ink k + 8 × bright. The 8 border colours of section 7.2 are entries 0–7.

## 8. Boot console

The boot ROM's text console is a layer in tile mode with 1-bit tiles (section 4.10): one map entry per character, the character code as TILE and a colour pair as PAL, an 8 × 8 font as the patterns. Printing a character is one 2-byte map write, and scrolling the text is a SCROLLY change and one cleared map row. Which layer, its SRAM addresses, its window and the font belong to spec 7 (section 5.1): an 80 × 30 console on L0 at 1 × 2, in a 640 × 480 window. It costs 0.5 bytes per pixel inside its window (section 5.4), which leaves room for the other two layers, the copper and the sprites.

## 9. FPGA resources

| Item | Resource |
|------|----------|
| Palettes, 4 × 256 × 24 bits | A RAM of 1024 × 24 ({palette number, entry}), kept twice and written together from the system side, as retro68k: one copy read back by the CPU and copper, the other by the pixel side. One RAMB36 each, **2** in all |
| Data registers and shifters | 3 layers × 8 × 16 bits each, as retro68k; the attribute channel's 16-bit data register and shifter: logic |
| Tile mode | Per layer an entry register (2 × 16 bits) and the group's PAL and PRI (2 × 5 bits); the row mirror for XFLIP; the map address sums: logic |
| Pointers | BPL0PT and its saved line start per layer: logic (retro68k keeps 24 in distributed RAM) |
| Line buffers, FIFOs, repeat buffers | None |
| Clocks | MMCM 2, shared with the rest of the design |

The sprites' FIFOs are spec 5's.

**Layers built.** The RTL takes the number of layers as a parameter (`NLAYERS`, 1–3, in `retroz80.v`). The KS2 build (`fpga/ks2/top_ks2.v`) has **1**, L0, to fit the XC7A15T; the KS3 build is to have all three. The registers of layers not built do not answer (spec 3: they read `0xFF` and writes do nothing).

## 10. Test plan

- **Timing:** sync positions, totals and the frame rate in simulation; real monitors and a TV lock on HDMI and VGA.
- **Golden images** (`make vtest` in `sim/`), as in retro68k: random settings of the three layers in both modes (each depth, every scale across and down, windows partly off screen, fine scroll, signed stride, pointer wrap, every map size with scroll wrapping round it both ways, X and Y flip, PRI, TRANSP, PALOFS and PAL, SHAREPAL, every PRIO value, direct colour, sprites at every DEPTH, the attribute layer on each target and depth, both cell sizes, flash), compared pixel by pixel with a Python model of this spec (`sim/vtest/vmodel.py`). Each palette gets different colours, so a pixel from the wrong palette shows. No OVERRUN on settings within the budget.
- **Tile fetch:** the order of section 5.2 (entries one group ahead, line start), 1-bit rows at even and odd addresses, YFLIP rows, XFLIP mirroring at each depth, a map that wraps inside a group, entries' deadlines one group later than the rows'.
- **Pointer:** BPL0PT moves word by word and ends each line at its start + BPLSTRIDE whatever the fetch; on a 2×-tall layer it goes back to the line's start on the first copy; a write between the last fetch and beam pixel 0 starts the next line as written; a write in the same clock as a fetch wins; WRAP keeps it in its block; nothing resets it at the frame start.
- **Order:** every PRIO value, including a layer left out and the reset value; sprites of each DEPTH against opaque and transparent pixels of each layer; PRI tiles over all layers and DEPTH 1–3 sprites, under DEPTH 0 sprites, and PRI tiles of two layers in PRIO's order.
- **Register timing:** each line setting written just before and just after beam pixel 0 acts on line L and on line L + 1; PRIO and BGCOLOR written in the horizontal blank change that line; palette writes land at the next pixel; CTRL1 written alone changes only its fields; a 2-byte line setting half written at beam pixel 0 shows one line with the mixed value and the next with the whole one; a BPL0PT written while the layer fetches shows the mixed pointer from then on, and one written in the gap does not; BPLSTRIDE acts with the line's last fetch.
- **Palettes:** PALIDX/PALDAT write and read every entry of the four palettes, the index steps across palettes after the red byte, a blue or green write alone changes nothing; either PALIDX byte resets the byte counter; a copper or DMA colour between the CPU's blue and red does not mix with it or move the CPU's index (one PALIDX, byte counter and buffer per master); BGCOLOR's red byte commits it; the register page offsets do the same without touching PALIDX; `LDIR` loads a palette; the default palette after configuration, and unchanged by reset.
- **Border:** `OUT (0xFE),A` with each of the 8 values sets BGCOLOR to the table's colour, shown from the pixel being shown 10–60 ns after the write, with the pixel clock at many phases; writes every few microseconds through a line give stripes that change mid-line, as a tape loader's; a BGCOLOR write mid-line shows from the next line's picture; BGCOLOR and port `0xFE` writes in either order, the later wins, and BGCOLOR reads back the later value.
- **Spectrum screen:** a .scr file shown through the copper's pointer writes (both ways of section 7.3) and the attribute layer, against the model; flash every 16 frames.
- **Budget:** each example of section 5.4 that fits, with the CPU at 20 MHz making random accesses, the copper and the DMA engine running, and sprites: no OVERRUN. Find how far beyond 1.48 bytes per pixel tile and bitmap screens go without OVERRUN, also at 25 MHz (open point V9). An over-budget screen sets the right OVERRUN bit and shows transparent pixels only for the late groups.
- **Beam and interrupts:** BEAMPOS reads are consistent and match the display beam; VBLANK and LINE fire at the right positions; FRAMECOUNT counts; INVBLANK; flags clear on writing 1; the request follows VIDSTAT and VIDINTEN.
- **DMACON:** set and clear each bit; with BPLEN or DMAEN clear no layer or attribute fetches.
- **Clock crossing:** the pixel clock at an odd phase that sweeps along each line; no lost or doubled groups.
- **CPU:** the Z80 never waits on any screen, within the budget or over it.

## 11. Open points

| # | Item |
|---|------|
| V1 | Check in Vivado that the clock crossings are covered (asynchronous clock groups) and that the pixel pipeline (a 9-place priority choice) and the tile fetcher meet timing, as retro68k's V1 |
| V2 | Plain DVI has no info packets; add the HDMI AVI InfoFrame later, as in retro68k |
| V3 | Closed: the palettes take 3 KB of the register page at `0x1400`–`0x1FFF`, 3 bytes per entry, as spec 2 (section 10.2), spec 3 (section 6) and the design plan (branch 11) have them |
| V4 | PALDAT is a register in the custom page, so `OTIR` cannot stream a palette (B is the register number). Making PALDAT also a low-byte-only stream port, as SERDATA is, would let it |
| V5 | The data registers are not visible and there is no BPLDMA, so a layer cannot be fed by the CPU or copper. BPLDMA and BPL0DAT would fit at `+0x12`–`+0x13` for 1-bit fed layers only |
| V6 | Closed: 1-bit tile rows take a whole memory cycle each, as 2-bit ones; packed 1-bit rows are deferred (branch 11) |
| V7 | Closed: port `0xFE` border writes act at once, from the pixel being shown after the crossing (10–60 ns), so mid-line stripes work as on a Spectrum (section 7.2). BGCOLOR written as a register keeps retro68k's rule, at the start of each line's picture |
| V8 | PRI tile pixels of two layers are ordered by PRIO. The previous draft had L0's in front of L1's |
| V9 | Measure in simulation how far beyond 1.48 bytes per pixel a screen fits, with tile layers and without taking the CPU's cycles (section 5.4), at 20 and 25 MHz |
| V10 | MAPPT, PATPT and SCROLLY are line settings, read at beam pixel 0 like CTRL, not live like BPL0PT: a write mid-line changes the next line, never the rest of the current one |
| V11 | ATADDR and ATSTRIDE are now even and ATSCROLL's fine X is 0–15, so an attribute group is one word; the previous draft allowed odd addresses |
| V12 | The default palette fills all four palettes the same way (section 7.4) |
| V13 | CTRL0–CTRL3 are separate byte registers, not one value (spec 3, section 3.1) |
| V14 | DMACON is one byte with retro68k's enables in the same order but not the same bit numbers; the four audio enables are one reserved bit, AUDEN, until sound is decided (spec 13) |
| V15 | Pointers and the stride are even, as in retro68k, so a bitmap line cannot start at an odd byte. A Spectrum screen and every 16-pixel-aligned picture are unaffected |
| V16 | Closed: VIDSIZE fits in the read-only area with BEAMPOS and FRAMECOUNT (`0x0F0`–`0x0F9`) |
| V17 | Closed: software sees the display beam, as retro68k (branch 11); the draw beam, line buffer, FIFOs and repeat buffers are gone |
| V18 | Closed: scales 4× and 8× are provided, as retro68k |
| V19 | Closed: the boot console's addresses and font belong to spec 7 |
| V20 | Closed (design plan, branch 11): register writes are direct, with no latches. BGCOLOR keeps a commit on its red byte, as the palette entries do, because a colour is shown live; it uses the same colour assembly buffer. A live pointer (BPL0PT) must be written while its layer is not fetching (section 4.4) |
