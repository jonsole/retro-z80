# Spec 5: Sprites

Status: **draft**

Sprites are small images drawn over (or between) the layers at any position, without touching the layers' memory. retro-z80 has retro68k's eight sprites, narrowed to 8-bit registers. Each has a pointer into SRAM for its image (SPRxPT), and its window and settings are plain registers (SPRxH, SPRxV, SPRxCTL) that the CPU or copper writes: the copper resets the pointers every frame, and can reuse a sprite further down the screen by writing its registers again.

The programming model is retro68k's. Inside, the fetch is different, because retro-z80 has far less memory bandwidth: each sprite's row for a line is fetched whole, at any time during the line before, into a row store; on the line itself a pixel unit per sprite reads the row out at the draw beam, as retro68k's pixel units read their FIFOs.

## 1. Summary

| Item | Value |
|------|-------|
| Sprites | 8 (SPR0–SPR7). Each can be reused further down the screen by the copper rewriting its registers |
| Window | HSTART–HSTOP across, VSTART–VSTOP down, in beam coordinates, as a layer's window. The image's size follows from the window and the magnify |
| Size | Any, set by the window. The row store holds 512 bytes of each line (section 4.2); the memory budget (section 5) limits how big and how many |
| Colours | 2, 4 or 8 bits per pixel. 2 and 4 bpp: 3 or 15 colours + transparent, from any 16-colour block of the sprite palette; 8 bpp: 255 colours + transparent, the whole sprite palette. The sprites have a 256-entry palette of their own, SPRPALETTE (spec 4) |
| Position | Any beam pixel and line, unsigned; clipped by the hardware at all four edges (section 3.2) |
| Magnify | ×1, ×2 or ×4, across and down separately |
| Depth | Per sprite: in front of both layers, between them (in PRIO order), or behind both |
| Order | Among sprites at the same depth, the lower number is in front |
| Collisions | Sprite–sprite and sprite–layer, per pixel, sticky (SPRCOLL) |
| Fetch | A whole row per sprite per line, during the line before, lowest number first, in cycle 3 after urgent display fetches and the copper, and in spare cycles (spec 2, section 4) |
| Manual mode | With a sprite's DMA off, the CPU or copper writes its rows through SPRxDAT, a byte at a time |
| Write timing | A write to SPRxPT, SPRxH, SPRxV or SPRxCTL committed while the draw beam is on line L restarts the sprite: it shows nothing on line L + 1, and its new settings from line L + 2 (section 4.4) |
| Per-line limit | The rows of a line must be fetched by the end of the line before. A row that is not shows nothing on its line and sets VIDSTAT.SPRUNDER (section 5) |
| Registers | Custom block: 16 bytes per sprite at `0x060` + n × `0x10` (copper MOVE reaches them); SPRDMA and SPRCOLL at `0x0F8`–`0x0FF` |
| Interrupts | None of their own: SPRUNDER raises VIDERR, as in retro68k (spec 4, spec 8) |
| Block RAM | 4 RAMB18 (section 8) |

## 2. Comparison with retro68k

The same: eight sprites; SPRxPT, SPRxH, SPRxV, SPRxCTL and SPRxDAT, with retro68k's fields and bit positions; any size, set by the window; chunky 2, 4 and 8 bpp, first pixel in the high bits; value 0 transparent; PAL blocks of SPRPALETTE, and VIDCON.SHAREPAL; HMAG and VMAG ×1, ×2, ×4; DEPTH among the layers in PRIO order; lower number in front; unsigned beam positions clipped at all edges; no flips; SPRxPT moves as the image is fetched and is rewritten every frame; a write to PT, H, V or CTL restarts the sprite; SPRDMA (set/clear) with DMACON.SPREN and DMAEN; SPRCOLL; SPRUNDER in VIDSTAT, raising VIDERR; reuse down the screen by the copper.

| Item | retro68k | retro-z80 | Why |
|------|----------|-----------|-----|
| Register width | 32-bit registers | Bytes. Each register is its bytes in order, low byte first; writing the highest byte commits it (spec 3) | Z80 |
| Sprite registers | 32 bytes per sprite at `0x520` + n × `0x20` | 16 bytes per sprite at custom offset `0x060` + n × `0x10`, so a one-word copper MOVE reaches them | Z80, copper word |
| SPRxPT | Bits 22–1 (8 MB Chip RAM), 4 bytes | Bits 21–1 (22-bit physical address, spec 2), 3 bytes; the fourth byte is SPRxDAT | Memory size |
| SPRDMA, SPRCOLL | `0x500`, `0x504` | `0x0F8`, `0x0FC`; the copper reaches them with MOVR or MOVEL only | Copper word |
| SPRCOLL | SPR, L0, L1, L2 (32 bits) | SPR, L0, L1 (3 bytes) | Two layers (spec 4) |
| DEPTH | 0 in front, 1 and 2 between the three layers, 3 behind all | 0 in front, 1 between the two layers, 2 and 3 behind both | Two layers |
| Tile priority | No tile layers | A tile-map layer's tile with PRI set covers DEPTH 1–3 sprites, never DEPTH 0 (section 3.4) | Tile layers (spec 4) |
| Fetch | Just in time into a 32-word FIFO per sprite, deadline first with the layers; may take the CPU's cycle | A whole row per line, at any time in the line before, into a row store; cycle 3 after urgent display fetches and the copper, and spare cycles; never the CPU's cycles | Bandwidth: 224 shared cycles a line (spec 2) |
| What adds up | Sprites over the same pixels at the same time | All rows fetched for a line, wherever the sprites are | Row fetch |
| VMAG | A repeated line is fetched again | A repeated line reuses the row and costs nothing; SPRxPT does not move on it | Bandwidth |
| Row length | Any | 512 bytes per sprite per line are fetched and shown; the rest of a longer row is transparent (only 8 bpp at ×1 wider than 512 pixels is affected) | Block RAM; such a row is over the guaranteed budget anyway |
| Underrun | The sprite shows nothing more until it next starts | The sprite shows nothing on that one line; the next line is fetched normally | Row fetch: each line's address is known |
| When writes take effect | From the next line, as far as the FIFO's lead allows | Exactly: committed during draw line L, nothing on line L + 1, new settings from line L + 2 | Deterministic timing for the copper |
| First lines | A sprite should not start on beam lines 0–1 | The same advice; line 0 never shows sprites (section 4.4) | Row fetched the line before |
| SPRxDAT | 16-bit pushes into the FIFO (up to 32 words ahead); read: words in the FIFO | 8-bit writes into the next row; no lead beyond that row; write-only | Z80, row store |
| Interrupt | None for sprites; SPRUNDER through VIDERR | The same. The SPRITE source of the earlier retro-z80 draft is dropped | – |
| Colours | 24-bit palette entries | 12-bit palette entries (spec 4) | KS3 VGA |
| Dropped from the earlier retro-z80 draft | – | 32 sprites; the attribute table and its index/data ports (SPRIDX, SPRDATA) and register-page copy; fractional scaling (XSTEP, YSTEP); X and Y flip; 1 bpp; SPRLIMIT and due clocks; SPRCTL, SPRSTAT, SPRIEN, SPRDROP; the DROP, WIDE and LATE flags; the sprite line buffer and renderer | Branch 9: retro68k's model |
| Later (retro68k section 11) | A sprite table; fractional scaling; sprites in direct colour at any depth | Not planned | – |

## 3. Sprites: pointer, window and settings

Each sprite has four registers (section 6):

- **SPRxPT** points at the sprite's image in SRAM: its lines one after another, top line first, each a whole number of 16-bit words. As in retro68k it moves through the image as it is fetched, so the hardware does not reset it: the copper (or the CPU) writes the eight pointers every frame.
- **SPRxH** and **SPRxV** give the sprite's window, and **SPRxCTL** its settings. They stay as written until written again. The image in memory is pixels only.
- **SPRxDAT** feeds a sprite whose DMA is off (section 4.5).

### 3.1 The window

In beam coordinates (spec 4: the picture is pixels 144–863, lines 49–624):

| Register | Bits | Field | Meaning |
|----------|------|-------|---------|
| SPRxH | 10–0 | HSTART | First beam pixel of the sprite (0–863; 864 or more: not shown). Pixels before 144 are in the horizontal blank: fetched, not shown |
| SPRxH | 26–16 | HSTOP | Beam pixel just after the sprite (above 864 counts as 864) |
| SPRxV | 10–0 | VSTART | First beam line of the sprite (0–624; 625 or more: not shown). Lines before 49 are in the vertical blank: fetched, not shown |
| SPRxV | 26–16 | VSTOP | Beam line just after the sprite (above 625 counts as 625) |

The image's size follows from the window: **source width** = (HSTOP − HSTART) ÷ HMAG pixels and **source height** = (VSTOP − VSTART) ÷ VMAG lines, each rounded up. A source line is stored in whole words: ⌈source width × BPP ÷ 16⌉ words, twice that in bytes. If HSTOP is not above HSTART, or VSTOP not above VSTART, the window is empty and the sprite does not show. After reset every window is empty.

A sprite shows inside its window once per frame. To hide it, turn its DMA off (SPRDMA), or set VSTART to 625 or more.

### 3.2 Clipping

The hardware clips at all four edges. A sprite's line is a beam line, and its frame the beam's frame:

- **Left:** pixels before beam pixel 144 are fetched but not shown. HSTART can be 0, so a sprite can hang 144 pixels off the left edge.
- **Top:** lines before beam line 49 are fetched and used up but not shown, so the first line that shows is the right line of the image. A sprite can hang up to 48 lines off the top, 47 if its registers are written in line 0 (section 4.4).
- **Right:** pixels from beam pixel 864 on are neither fetched nor shown.
- **Bottom:** lines from beam line 625 on are neither fetched nor shown.

### 3.3 SPRxCTL

| Bits | Field | Meaning |
|------|-------|---------|
| 13–12 | BPP | 0 = 2, 1 = 4, 2 = 8 bits per pixel; 3 reserved (taken as 8) |
| 17–16 | HMAG | Each source pixel shown 1, 2 or 4 times across (0, 1, 2); 3 reserved (taken as 4) |
| 19–18 | VMAG | Each source line shown on 1, 2 or 4 beam lines (0, 1, 2); 3 reserved (taken as 4) |
| 21–20 | DEPTH | 0 = in front of both layers; 1 = behind the front layer; 2 and 3 = behind both layers (in PRIO order) |
| 27–24 | PAL | 2 and 4 bpp: the 16-colour block of the sprite palette (colour = PAL × 16 + value). Not used at 8 bpp |

Other bits are reserved: write 0, read 0. The bit positions are retro68k's; as bytes (section 6), BPP is in byte 1, HMAG, VMAG and DEPTH in byte 2, PAL in byte 3, and byte 0 is unused.

### 3.4 Pixels, colours and depth

Image lines are **chunky**: 2, 4 or 8 bits per pixel, packed as the bitmap layers' are (spec 4): bytes left to right at rising addresses, the first pixel in the high bits of each byte. A value of 0 is transparent. Other values are entries of **SPRPALETTE**, the sprite palette (spec 4), which the layers do not use: at 8 bpp the value itself; at 2 and 4 bpp, PAL × 16 + the value. With VIDCON.SHAREPAL set, sprites use L0's palette instead, as the layers then do.

There is no flip: for an object that faces either way, store both images.

**Depth.** Each sprite's DEPTH puts it among the two layers in their PRIO order (spec 4). From the front:

| From the front | |
|----------------|--|
| 1 | Sprites with DEPTH 0 |
| 2 | Pixels of tiles with PRI set (either layer, the front layer's first) |
| 3 | The front layer |
| 4 | Sprites with DEPTH 1 |
| 5 | The back layer |
| 6 | Sprites with DEPTH 2 or 3 |
| 7 | The background colour (BGCOLOR) |

- Within each group of sprites, the **lower number is in front**: sprite 0 in front of sprite 1, and so on. A sprite at a front depth is in front of a lower-numbered sprite at a deeper one, as in retro68k.
- A layer's transparent pixels (TRANSP set, value 0), and pixels outside its window, show what is behind them. A layer without TRANSP hides everything behind it inside its window.
- **Tile priority.** A tile-map layer's map entry has a PRI bit (spec 4). The opaque pixels of such a tile cover sprites of DEPTH 1–3 and the other layer, but never DEPTH 0 sprites: score panels and foreground scenery go over most sprites, while a cursor or a player at DEPTH 0 stays in view. With PRI clear, a tile's pixels are at their layer's place.
- The attribute layer (Spectrum extra, spec 4) does not act on sprites.

### 3.5 Collisions

The hardware checks every picture pixel for sprites touching, as retro68k does, and sets bits in **SPRCOLL** (section 6):

| Byte | Bit n set when |
|------|----------------|
| 0, SPR | An opaque pixel of sprite n was on the same pixel as an opaque pixel of another sprite |
| 1, L0 | An opaque pixel of sprite n was on an opaque pixel of layer 0 |
| 2, L1 | The same, against layer 1 |

- A sprite pixel is opaque if its value is not 0. A layer pixel is opaque if it is inside the layer's window and not transparent. Depth does not matter: a sprite behind a layer still collides with it, and a PRI tile counts as its layer.
- Only picture pixels count (beam pixels 144–863 on lines 49–624), not those clipped or in the blanking. A sprite not shown on a line (underrun, section 5.3) takes part in no collision on that line.
- The sprite bits do not say which other sprite was hit: if bits 0 and 3 are set, sprites 0 and 3 might have touched each other, or each another sprite.
- The bits are set as the draw beam draws each pixel, and are **sticky** until cleared by writing 1. A frame's collisions are all in SPRCOLL when the draw beam reaches (0, 0) of the next frame. Read SPRCOLL once a frame, in the vertical blank, and clear the bits read.

There is no collision interrupt, as in retro68k.

## 4. Fetch and draw

### 4.1 Overview

The draw beam runs one output line ahead of the display beam (spec 4). Sprites work one more line ahead: during draw line L the sprite unit fetches each sprite's row for line L + 1 into the row store, while the pixel units read the rows for line L out at the draw beam.

| When (draw beam) | For line | Work |
|------------------|----------|------|
| (L, 0) | L + 1 | **Set-up:** each sprite takes its registers (window, CTL, the pointer, its DMA enable) for line L + 1, and works out whether it is on that line and whether the line starts a new source line |
| Draw line L, clocks 0–1791 | L + 1 | **Fetch:** the rows that line L + 1 needs, lowest-numbered sprite first, each row whole, into the row store (section 4.2) |
| (L + 1, 0) | L + 1 | **Hand-over:** the rows and settings of line L + 1 pass to the pixel units. A row not complete now shows nothing (section 5.3) |
| Draw line L + 1 | L + 1 | **Draw:** each pixel unit gives its sprite's pixel at the draw beam; the mixer places it among the layers (section 3.4) and checks collisions |

The set-up runs on every line, 0–624, so that sprites hanging off the top use up their lines. The first set-up of a frame is at (0, 0), for line 1.

### 4.2 The row store

Each sprite has two rows in the row store: one being drawn, one being filled. Each row holds **512 bytes**: 512 pixels at 8 bpp, 1,024 at 4 bpp, 2,048 at 2 bpp.

On each line of its window the sprite either starts a **new source line** or **repeats** the line before (VMAG ×2 or ×4):

- **New source line:** during the line before, its row is fetched from SPRxPT into the row being filled: one 16-bit word per memory cycle, in order. Each word fetched moves SPRxPT on by 2. Words for pixels from beam pixel 864 on, and words past the row's first 512 bytes, are not fetched. At the end of the line, SPRxPT goes to the line's start + one line (⌈source width × BPP ÷ 16⌉ words), whatever was fetched or skipped. At (L + 1, 0) the two rows swap.
- **Repeated line:** nothing is fetched and SPRxPT does not move. The pixel unit draws the same row again.

So VMAG costs no memory cycles. A sprite's lines are counted from its last restart (section 4.4): the first window line after a restart starts a new source line, from SPRxPT; then every VMAG-th line does.

The **memory cycles** are cycle 3 of each slot after urgent display fetches and the copper, and any spare cycle in the same order (spec 2, section 4): urgent display fetch, copper, sprites, display top-up. Sprites never take the CPU's cycles. The fetch works through the sprites in number order: sprite 0's row whole, then sprite 1's, and so on, so when cycles run short the higher numbers go without.

### 4.3 Pixel units

Each sprite has a pixel unit, as in retro68k. At (L, 0) it takes line L's settings (HSTART, HSTOP, BPP, HMAG, DEPTH, PAL) and the row; then, as the draw beam passes beam pixel x (from HSTART to the earlier of HSTOP and 864), it gives source pixel (x − HSTART) ÷ HMAG of the row, rounded down. Pixels before beam pixel 144 are counted but not shown. A pixel past the bytes in the row (past 512 bytes, or past the bytes written in manual mode) is transparent.

The mixer takes the eight pixels and the two layers' pixels at each beam pixel and picks the front-most opaque one (section 3.4). Everything a pixel unit uses was taken at (L, 0), so register writes never change the line being drawn.

### 4.4 Restart and when writes take effect

As in retro68k, **a write to SPRxPT, SPRxH, SPRxV or SPRxCTL restarts the sprite**. With byte registers, the restart happens when the value commits: when its highest byte is written (SPRxPT byte 2, SPRxH byte 3, SPRxV byte 3, SPRxCTL byte 3). Writing a lower byte only fills the latch.

A restart committed while the draw beam is on line L (at or after (L, 0), before (L + 1, 0)):

- stops the sprite's fetch for line L + 1, and empties its row being filled, so **the sprite shows nothing on line L + 1**;
- does not change line L, which is being drawn with settings taken at (L, 0);
- makes the set-up at (L + 1, 0) start the sprite again: **from line L + 2 it shows with its new settings**, its first window line from that point fetched from SPRxPT (as the pointer is then).

Several writes during the same line restart the sprite only once in effect: the fetch is stopped from the first, so SPRxPT does not move between them. If the writes run on into line L + 1, the sprite shows nothing on line L + 2 either, and shows from L + 3.

At the **start of each frame**, (0, 0), every sprite restarts, and the set-up at (0, 0) fetches line 1 from SPRxPT. Line 0's row would have been fetched during the last line of the frame before, so **line 0 never shows sprites**; a window from VSTART 0 starts its image on line 1. A copper list that writes a sprite's registers in line 0, as most do, makes it show from line 2. Lines 0–48 are in the vertical blank, so this matters only for a sprite hanging more than 47 lines off the top. As in retro68k: do not start a sprite on beam line 0 or 1.

Two rules follow, as in retro68k:

1. **Write SPRxPT last.** SPRxPT moves as the image is fetched. If the fetch for line L + 1 had already run when the window is written, a later restart starts from where the pointer had got to. Write the window and CTL first, then the pointer.
2. **Change a sprite while it is not being drawn:** in the vertical blank, or after its last line. A restart while the sprite is on the screen starts it again partway down, from wherever its pointer had got to, after one empty line.

Other writes:

| Register | Takes effect |
|----------|--------------|
| SPRxPT, SPRxH, SPRxV, SPRxCTL | Restart, as above: nothing on line L + 1, new settings from L + 2 |
| SPRDMA, DMACON.SPREN, DMACON.DMAEN | At the next set-up: a change committed during draw line L acts on line L + 2. The fetch for line L + 1 in progress finishes. No restart |
| SPRxDAT | At once: the byte goes into the row being filled (section 4.5) |
| SPRCOLL | At once |
| SPRPALETTE, VIDCON.SHAREPAL, PRIO | Spec 4's rules: at the draw beam |

**Reusing a sprite further down the screen**, as Amiga programs do with their control words: once the old use's last line E has started drawing (draw beam at (E, 0) or later), the copper writes the sprite's window, CTL and pointer. If the writes are all made during draw line M (M ≥ E), the new use can start on line M + 2 or later. So the new use starts at least one line after the old one ends; leave a line between uses, as retro68k advises.

### 4.5 Manual mode: SPRxDAT

With a sprite's DMA off at a set-up (its SPRDMA bit clear, or DMACON.SPREN or DMAEN clear), nothing is fetched for it. The CPU or copper feeds its rows instead, by writing **SPRxDAT**:

- Each write puts one byte into the **row being filled**, at the next place: byte 0, 1, 2 and so on, in image order. Writes past 512 bytes are ignored.
- The row being filled becomes the row drawn at the next window line that starts a new source line, and an empty row then starts being filled. So the bytes written since that row began make up the next source line: with VMAG ×1, the bytes written during draw line L show on line L + 1.
- Bytes of the row not written are transparent: a row may be written short.
- A restart (and the start of the frame) empties the row being filled. Write PT, H, V and CTL first, then the row's bytes. Bytes written before the window's first line make up its first line, so the copper can write a row in the vertical blank.
- Writes to SPRxDAT of a sprite whose DMA is on are ignored. Manual mode never sets SPRUNDER.
- SPRxDAT is write-only; it reads 0.

This is useful for sprites whose image is computed, and for effects that change a sprite line by line. The copper is the natural feeder: one MOVE per byte, at exact beam positions.

## 5. Memory budget and limits

### 5.1 Cost

A sprite costs memory cycles only on lines that start a new source line, and then **W = ⌈source width × BPP ÷ 16⌉ words**, one memory cycle each, fewer if clipped at the right edge or past 512 bytes. HMAG does not change W for a given image; it spreads it over more screen pixels. Repeated lines (VMAG) cost nothing. Unlike retro68k, sprites side by side add up as much as sprites stacked: what counts is the total of the rows fetched for a line.

| Width (source pixels) | 2 bpp | 4 bpp | 8 bpp |
|-----------------------|-------|-------|-------|
| 16 | 2 words | 4 | 8 |
| 32 | 4 | 8 | 16 |
| 64 | 8 | 16 | 32 |
| 128 | 16 | 32 | 64 |
| 256 | 32 | 64 | 128 |

### 5.2 The guaranteed budget

The rows for line L + 1 are fetched during draw line L, which has 224 cycle-3 cycles. Urgent display fetches and the copper come first, so the sprites are certain of

> **B = 224 − D − C** words for the rows of line L + 1

where D is the display's urgent cycle-3 cycles in draw line L (none on a line whose layers fit in cycle 1's 448 bytes, spec 4) and C is the copper's cycles in draw line L (spec 6). Spare cycles (the CPU's unused cycles, cycle 1 in the blanking and when the layers need no more) add to B; at 28 MHz the CPU alone leaves at least 150 a line (spec 2, section 8), and in the vertical blank nearly all of cycle 1 is spare.

The fetch goes in number order, so: **sprite k's row is always complete when the words of the rows of sprites 0 to k on that line add up to no more than B.** Beyond that it depends on spare cycles.

All eight sprites alike, on the same line, each starting a new source line, with the guaranteed budget only:

| Sprites | Words for the line | B = 224 (no copper, layers within cycle 1) | B = 160 (busy copper) |
|---------|--------------------|---------------------------------------------|------------------------|
| 8 × 16 px at 8 bpp, or 32 px at 4 bpp | 64 | All | All |
| 8 × 32 px at 8 bpp, or 64 px at 4 bpp | 128 | All | All |
| 8 × 48 px at 8 bpp | 192 | All | Sprites 0–5 (144) |
| 8 × 64 px at 8 bpp, or 128 px at 4 bpp | 256 | Sprites 0–6 (224) | Sprites 0–4 (160) |
| 1 × 256 px at 8 bpp | 128 | All | All |

The other sprites are likely to be fetched too, from spare cycles; they are not certain.

**Tips:** sprites magnified ×2 or ×4 down cost words only on their new source lines, so a ×2 sprite costs half as often; two such sprites whose windows start on lines of opposite parity fetch on alternate lines, and so spread the load. Magnify across rather than storing a wider image. Keep the copper's busy runs away from lines with many sprites.

### 5.3 Underrun: SPRUNDER

If a sprite's row for line L + 1 is not complete at (L + 1, 0), the sprite **underruns**:

- it shows nothing on line L + 1 (and takes part in no collision there);
- **VIDSTAT.SPRUNDER** (bit 7, spec 4) is set: sticky, cleared by writing 1, and with its enable in VIDINTEN it raises the **VIDERR** interrupt, as the layers' OVERRUN bits do;
- SPRxPT goes to the next line's start as usual, so the sprite's next line is fetched and shown normally.

Since the fetch goes in number order, the sprites that underrun are always the highest-numbered ones on the line. Give the important objects (the player, the cursor) low numbers. An underrun means that line asks too much of the memory: use fewer bits per pixel, magnify instead of a wider image, spread the sprites over more lines, or move copper work elsewhere.

## 6. Registers

Offsets in the custom block (spec 3): port = (offset bits 7–0) × 256 + `0xC0` + (offset bits 9–8), so the sprites' registers are at ports `0x60C0`–`0xDFC0` and the sprite globals at `0xF8C0`–`0xFFC0` (`LD BC,port`, `OUT (C),A`, `INC B` to the next byte). The register page shows the custom block at offsets `0x1000`–`0x13FF` (spec 2, section 6.5), sprite registers at `0x1060`–`0x10FF`. The copper writes sprite n's registers with one-word MOVEs (codes `0x60`–`0xDF`), and SPRDMA and SPRCOLL with MOVR or MOVEL (spec 6).

Sprite n (0–7) at `0x060` + n × `0x10`:

| Offset | Name | Access | Bits | Description | Reset |
|--------|------|--------|------|-------------|-------|
| `+0x0` | SPRxPT0 | RW | 7–1 | SPRxPT bits 7–1; bit 0 ignored, reads 0 (rows are words) | 0 |
| `+0x1` | SPRxPT1 | RW | 7–0 | SPRxPT bits 15–8 | 0 |
| `+0x2` | SPRxPT2 | RW | 5–0 | SPRxPT bits 21–16. **Writing it commits SPRxPT and restarts the sprite.** Bits 7–6 ignored; bit 5 ignored on a 2 MB board (spec 2) | 0 |
| `+0x3` | SPRxDAT | W | 7–0 | Manual mode: a byte into the row being filled (section 4.5). Reads 0 | – |
| `+0x4` | SPRxH0 | RW | 7–0 | HSTART bits 7–0 | 0 |
| `+0x5` | SPRxH1 | RW | 2–0 | HSTART bits 10–8 | 0 |
| `+0x6` | SPRxH2 | RW | 7–0 | HSTOP bits 7–0 | 0 |
| `+0x7` | SPRxH3 | RW | 2–0 | HSTOP bits 10–8. **Writing it commits SPRxH and restarts the sprite** | 0 |
| `+0x8` | SPRxV0 | RW | 7–0 | VSTART bits 7–0 | 0 |
| `+0x9` | SPRxV1 | RW | 2–0 | VSTART bits 10–8 | 0 |
| `+0xA` | SPRxV2 | RW | 7–0 | VSTOP bits 7–0 | 0 |
| `+0xB` | SPRxV3 | RW | 2–0 | VSTOP bits 10–8. **Writing it commits SPRxV and restarts the sprite** | 0 |
| `+0xC` | SPRxCTL0 | – | – | Reserved (CTL bits 7–0): writes ignored, reads 0 | 0 |
| `+0xD` | SPRxCTL1 | RW | 5–4 | BPP (CTL bits 13–12) | 0 |
| `+0xE` | SPRxCTL2 | RW | 1–0, 3–2, 5–4 | HMAG, VMAG, DEPTH (CTL bits 17–16, 19–18, 21–20) | 0 |
| `+0xF` | SPRxCTL3 | RW | 3–0 | PAL (CTL bits 27–24). **Writing it commits SPRxCTL and restarts the sprite** | 0 |

- Unused bits are written 0 and read 0. Each sprite has its own latches. Writing only the highest byte commits it with the other bytes unchanged (spec 3, rule 2).
- Reads give the committed value. SPRxPT moves as the image is fetched, so **reading SPRxPT0 captures all three bytes**, and SPRxPT1 and SPRxPT2 read the captured copy (spec 3's rule for values that change by themselves).

Sprite globals:

| Offset | Name | Access | Bits | Description | Reset |
|--------|------|--------|------|-------------|-------|
| `0x0F8` | SPRDMA0 | RW | 7–0 | SPR: DMA on for sprite n (bit n). Latched | `0xFF` |
| `0x0F9` | SPRDMA1 | W | 7 | SETCLR (SPRDMA bit 15). **Writing it commits:** SETCLR = 1 sets the SPR bits written as 1 in SPRDMA0; SETCLR = 0 clears them. Others unchanged. Reads 0 | – |
| `0x0FA`–`0x0FB` | – | – | – | Reserved (SPRDMA bits 31–16) | – |
| `0x0FC` | SPRCOLL0 | R, W1C | 7–0 | SPR: sprite n touched another sprite (section 3.5) | 0 |
| `0x0FD` | SPRCOLL1 | R, W1C | 7–0 | L0: sprite n touched layer 0 | 0 |
| `0x0FE` | SPRCOLL2 | R, W1C | 7–0 | L1: sprite n touched layer 1 | 0 |
| `0x0FF` | – | – | – | Reserved (SPRCOLL bits 31–24, retro68k's L2) | – |

- A sprite fetches only while its SPRDMA bit, DMACON.SPREN and DMACON.DMAEN are all set; otherwise it is in manual mode (section 4.5).
- SPRCOLL's bytes are status bits: each byte is read and cleared on its own, with no latch (spec 3, rule 5).

Bits elsewhere:

| Register | Bit | Function |
|----------|-----|----------|
| DMACON (spec 4) | 2, SPREN | Sprite DMA, with DMAEN (bit 6): retro68k's enables, in one byte (spec 4, section 7.1) |
| VIDSTAT (spec 4) | 7, SPRUNDER | A sprite's row was not complete in time. W1C |
| VIDINTEN (spec 4) | 7, SPRUNDER | Raise VIDERR on SPRUNDER |
| VIDCON (spec 4) | SHAREPAL | Sprites use L0's palette |
| SPRPALETTE (spec 4) | – | The sprites' 256-entry palette |

**State after reset:** DMACON.SPREN is clear, SPRDMA has all eight sprites on, every sprite's PT, H, V and CTL are 0 (empty windows, nothing shows), SPRCOLL is 0. The row store is not cleared.

**Equates** (`hw.inc`, as retro68k's where the thing is the same):

| Equate | Value |
|--------|-------|
| `SPR0` … `SPR7` | `0x060`, `0x070` … `0x0D0` |
| `SPR_PT`, `SPR_DAT`, `SPR_H`, `SPR_V`, `SPR_CTL` | `0x0`, `0x3`, `0x4`, `0x8`, `0xC` |
| `SPRDMA`, `SPRCOLL` | `0x0F8`, `0x0FC` |
| `SPR_CTL_BPP_B`, `SPR_CTL_HMAG_B`, `SPR_CTL_VMAG_B`, `SPR_CTL_DEPTH_B`, `SPR_CTL_PAL_B` | 12, 16, 18, 20, 24 (bit numbers in the 32-bit value; `_M` masks) |
| `SPRDMA_SETCLR_M`, `DMACON_SPREN_M`, `VIDSTAT_SPRUNDER_M` | The enables and status |
| `CPORT(off)` | The custom port of an offset: `((off & 0xFF) << 8) \| 0xC0 \| (off >> 8)` |

## 7. Examples

sjasmplus syntax. A 32 × 24 sprite at 4 bpp, in colours 32–47 (PAL 2), behind the front layer (DEPTH 1), on sprite 0 at picture pixel 200, line 100 (beam pixel 144 + 200, line 49 + 100). The image is 24 lines of 16 bytes at physical address `ship`.

Once, from the CPU, with ports:

```
X0      equ  VID_X0+200
Y0      equ  VID_Y0+100
        ld   bc,CPORT(SPR0+SPR_H)
        ld   hl,X0
        ld   de,X0+32
        out  (c),l           ; HSTART bits 7-0
        inc  b
        out  (c),h           ; HSTART bits 10-8
        inc  b
        out  (c),e           ; HSTOP bits 7-0
        inc  b
        out  (c),d           ; HSTOP bits 10-8: commits SPR0H
        ; ... SPR0V the same way, with Y0 and Y0+24
        ld   bc,CPORT(SPR0+SPR_CTL+1)
        ld   a,1<<4          ; BPP = 4 bpp
        out  (c),a
        inc  b
        ld   a,1<<4          ; HMAG x1, VMAG x1, DEPTH 1
        out  (c),a
        inc  b
        ld   a,2             ; PAL 2: commits SPR0CTL
        out  (c),a
```

The same window through the register page, mapped into window 7 (`REGS` = `0xE000`; the custom block at `REGS + 0x1000`):

```
        ld   hl,X0
        ld   (REGS+0x1000+SPR0+SPR_H),hl     ; HSTART
        ld   hl,X0+32
        ld   (REGS+0x1000+SPR0+SPR_H+2),hl   ; HSTOP: commits
```

In the copper list, every frame (in the vertical blank), the pointer, last:

```
        CMOVE   SPR0+SPR_PT,ship & 0xFF
        CMOVE   SPR0+SPR_PT+1,(ship >> 8) & 0xFF
        CMOVE   SPR0+SPR_PT+2,ship >> 16     ; commits: shows from two lines on
```

To move the ship, write SPR0H and SPR0V and then SPR0PT, in the vertical blank.

**Reusing sprite 0** for a second ship from picture line 300: the first ship's last line is picture line 123; the copper waits for the line after it, then writes sprite 0 again (all in that line, so the new use can start two lines later):

```
        CWAIT   VID_Y0+124,0
        CMOVE   SPR0+SPR_H,(VID_X0+400) & 0xFF
        CMOVE   SPR0+SPR_H+1,(VID_X0+400) >> 8
        CMOVE   SPR0+SPR_H+2,(VID_X0+432) & 0xFF
        CMOVE   SPR0+SPR_H+3,(VID_X0+432) >> 8
        CMOVE   SPR0+SPR_V,(VID_Y0+300) & 0xFF
        CMOVE   SPR0+SPR_V+1,(VID_Y0+300) >> 8
        CMOVE   SPR0+SPR_V+2,(VID_Y0+324) & 0xFF
        CMOVE   SPR0+SPR_V+3,(VID_Y0+324) >> 8
        CMOVE   SPR0+SPR_PT,ship2 & 0xFF
        CMOVE   SPR0+SPR_PT+1,(ship2 >> 8) & 0xFF
        CMOVE   SPR0+SPR_PT+2,ship2 >> 16
```

Eleven MOVEs: 11 cycle-3 cycles of that line (section 5.2). Writing only the bytes that change is enough: the others keep their values, and the highest byte commits.

**Collisions,** once a frame in the vertical blank:

```
        ld   bc,CPORT(SPRCOLL)
        in   a,(c)           ; sprite-sprite bits
        out  (c),a           ; clear exactly the bits read
        bit  0,a             ; sprite 0 hit another sprite?
        jr   nz,hit_sprite
        inc  b
        inc  b
        in   a,(c)           ; SPRCOLL2: against layer 1 (the walls)
        out  (c),a
        bit  0,a
        jr   nz,hit_wall
```

**Manual mode:** sprite 1, 16 pixels wide at 2 bpp (4 bytes a line), fed by the copper with a pattern that changes every line. With SPRDMA bit 1 clear, after a wait for the line before each sprite line:

```
        CMOVE   SPR1+SPR_DAT,0x1B
        CMOVE   SPR1+SPR_DAT,0x1B
        CMOVE   SPR1+SPR_DAT,0xE4
        CMOVE   SPR1+SPR_DAT,0xE4    ; shown on the next line
```

## 8. FPGA resources

Estimates, to be measured:

| Item | Resource |
|------|----------|
| Registers and latches, 8 × 16 bytes, per-sprite fetch state (pointer, line start, line counter, row byte count), worked on one sprite a clock in distributed RAM (retro68k's area technique) | About 250 LUTs |
| Set-up and fetcher: size from the window (shifts only), word count, cycle-3 requests, number order | About 250 LUTs |
| Row store: 8 sprites × 2 rows × 512 bytes, in 4 RAMB18 of 1K × 16, two sprites each. Port A: fetch and SPRxDAT writes (byte enables); port B: the two sprites' pixel units, alternate clocks (each needs a word at most every 4 clocks) | 4 RAMB18 |
| 8 pixel units (source counter, magnify, pixel select) | About 60 each, 480 in all |
| Mixer (depth, PRI tiles), collisions | About 200 LUTs |
| Total | About 1,200 LUTs; 4 RAMB18; no DSP slice |

The design plan's block RAM table (D11) lists 3 blocks for sprites; this spec needs 4.

## 9. Test plan

- **Golden images:** sprites of many window sizes at 2, 4 and 8 bpp; every HMAG and VMAG; PAL blocks; SHAREPAL; clipped at all four edges (HSTART 0, VSTART 2, HSTOP and VSTOP past the edges); every DEPTH against layers in both PRIO orders, over transparent and opaque layer pixels; PRI tiles over DEPTH 1–3 sprites and under DEPTH 0; lower numbers in front within a depth, and a front-depth sprite over a lower-numbered deeper one; compared pixel by pixel with the Python video model extended with sprites.
- **Collisions:** known overlaps set exactly the expected SPRCOLL bits; none from clipped pixels, the blanking, or an underrun line; W1C clears only the bits written.
- **Pointer:** SPRxPT after a frame equals the image's start + lines × line length, also with right clipping, rows over 512 bytes, VMAG (repeated lines do not move it) and underruns; reading SPRxPT0 captures all three bytes.
- **Write timing:** a commit of each of PT, H, V, CTL at draw beam (L, 0) and at clock 1791 of line L: nothing on line L + 1, new settings on L + 2; line L unchanged; writes of only lower bytes change nothing; several writes in one line act once; writes spread over two lines show from L + 3; SPRDMA and SPREN changes act on L + 2 without a restart.
- **Frame start:** line 0 never shows sprites; a sprite written by the copper in line 0 shows from line 2; VSTART 1 with no writes in line 0 shows on line 1.
- **Reuse:** one sprite shown three times down the screen by the copper (retro68k's three ships), with one gap line; writes during the old use's last line leave that line whole.
- **Manual mode:** a copper-fed sprite, with VMAG ×1 and ×2; a short row (transparent remainder); a row written in the vertical blank for the first line; writes past 512 bytes ignored; writes with DMA on ignored; no SPRUNDER.
- **Budget and underrun:** each line of section 5.2's table with the copper using C cycles and the layers within cycle 1, the CPU at 28 MHz flat out: the certain sprites always show; a deliberate overload sets SPRUNDER, hides only the highest-numbered sprites on that line, and the next line is right; VIDERR raised with VIDINTEN.SPRUNDER set.
- **CPU never loses a cycle** with all eight sprites fetching (spec 2's test).
- **Measure** in simulation the spare cycles sprites get in typical screens (open point S1).

## 10. Open points

| # | Item |
|---|------|
| S1 | Measure in simulation how many spare cycles sprites get at each CPU speed, and confirm that urgent display fetches happen only on lines whose layers need more than cycle 1 (spec 4), so that B = 224 − D − C holds |
| S2 | Which sprites show beyond the guaranteed budget depends on spare cycles, so on what the CPU is doing, as in retro68k. The earlier draft's SPRLIMIT and due clocks made it exact but were dropped for simplicity. Proposed: keep it so; reopen if games need exact results over budget |
| S3 | Row store 512 bytes per row (4 RAMB18). 8 RAMB18 would give 1,024 bytes, enough for any row (864 bytes at 8 bpp ×1), but such rows are over the guaranteed budget anyway. Proposed: 512 |
| S4 | A restart empties the row being filled, so the sprite misses line L + 1 even when that row was complete. Keeping it would save a line between reuses, but would mix old and new settings. Proposed: as written (retro68k's restart empties the FIFO too) |
| S5 | Tile PRI over sprites (section 3.4) needs spec 4 to keep a PRI bit in tile-map entries, and to place PRI pixels of either layer in front of both layers |
| S6 | Direct colour: retro68k draws sprites in front of a direct-colour picture. If spec 4 has a direct-colour mode, do the same; otherwise drop the point |
| S7 | SPRxDAT is write-only. A read of the bytes written to the row being filled could be added (retro68k reads the FIFO count) |
| S8 | Closed: SPRDMA (set/clear, SETCLR in its high byte) and SPRCOLL (separate W1C bytes) are listed in spec 3, section 3.1 |
| S9 | Line 0 never shows sprites (section 4.4); VSTART 0 acts as a window starting at line 1, one line lower than retro68k. Invisible (blank), but noted |
