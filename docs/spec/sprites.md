# Spec 5: Sprites

Status: **draft**

Sprites are small images drawn over (or between) the layers at any position, without touching the layers' memory. retro-z80 has 32 of them. Each sprite's image (its pattern) is in SRAM, given by a pointer; its position, size, scale and settings are sixteen bytes in a sprite attribute table, which the CPU writes through an index port and a data port, so two OTIRs upload all 32 sprites. Each sprite can be scaled, larger or smaller, by any fraction across and down. The copper writes the same ports, so it can reuse a sprite further down the screen after it has been drawn (multiplexing).

The sprite unit works in three steps, each one output line apart: it finds the sprites on a line and fetches their rows from SRAM (in cycle 3 of each slot); on the next line it renders them into a sprite line buffer; on the line after, the draw beam mixes that buffer with the layers (spec 4).

## 1. Summary

| Item | Value |
|------|-------|
| Sprites | 32 (sprite 0 to sprite 31) |
| Pattern size | Width 8, 16 or 32 pixels; height 8, 16 or 32 rows; set separately |
| Colours | 1, 2, 4 or 8 bits per pixel. Value 0 is transparent. A palette bank gives the high bits of the 9-bit palette index (512-entry palette, shared with the layers) |
| Patterns | In SRAM, anywhere: a 22-bit pointer per sprite, rows one after another, row stride = width × bpp ÷ 8 bytes |
| Position | X, Y in beam coordinates (beam pixel and beam line of the top left corner), 11-bit signed |
| Scale | X step and Y step per sprite, 16 bits each, 4.12 fixed point (source pixels per beam pixel, source rows per beam line). 0x0800 = normal size (one sprite pixel = one 2 × 2 picture pixel); from 0x0080 (16× normal) to 0xFFFF (about 1/32×). Nearest pixel, no filtering |
| Flip | X flip and Y flip, per sprite |
| Priority | Per sprite: in front of the tile layer, or behind it. Always in front of the bitmap layer |
| Sprite order | Lower number in front |
| Collisions | Sprite–sprite and sprite–playfield, per sprite, sticky; interrupt line SPRITE |
| Attributes | 32 × 16 bytes, through an index port + data port |
| Ports | `0x80`–`0x8F` |
| Fetch | Cycle 3, after the copper and urgent display fetches; two output lines before the line shown |
| Per-line limits | Fetch: a budget of memory cycles (SPRLIMIT, at most 216). Render: the total on-screen sprite width, about 1,760 beam pixels less 4 per sprite. Lowest numbers are kept; a status flag shows when sprites were left out (section 5) |
| Block RAM | 3 blocks of 18 Kb; 1 DSP slice (section 8) |

## 2. Sprite attributes

### 2.1 The attribute table

Each sprite has 16 bytes in the attribute table, at index n × 16 (n = 0–31); the table is 512 bytes. The index (9 bits) is set through SPRIDX and SPRIDXH, and the data is read and written through SPRDATA (section 6). The index steps by 1 after each SPRDATA read or write, wrapping from 511 to 0, so two `OTIR`s with B = 0 write the whole table.

| Byte | Name | Bits | Field | Meaning |
|------|------|------|-------|---------|
| 0 | XL | 7–0 | X[7:0] | Low byte of X |
| 1 | XH | 2–0 | X[10:8] | High bits of X (X is signed, −1024 to 1023). **Writing XH commits X and the fields below** |
| | | 4–3 | W | Pattern width: 0 = 8, 1 = 16, 2 = 32 pixels; 3 = reserved (taken as 32) |
| | | 5 | XFLIP | 1 = mirror left to right |
| | | 6 | BEHIND | 1 = behind the tile layer; 0 = in front of it (section 3) |
| | | 7 | EN | 1 = sprite on. 0 = never shown, never fetched |
| 2 | YL | 7–0 | Y[7:0] | Low byte of Y |
| 3 | YH | 2–0 | Y[10:8] | High bits of Y (signed). **Writing YH commits Y and the fields below** |
| | | 4–3 | H | Pattern height: 0 = 8, 1 = 16, 2 = 32 rows; 3 = reserved (taken as 32) |
| | | 5 | YFLIP | 1 = mirror top to bottom |
| | | 7–6 | BPP | 0 = 1, 1 = 2, 2 = 4, 3 = 8 bits per pixel |
| 4 | PL | 7–0 | PTR[7:0] | Pattern pointer, low byte |
| 5 | PM | 7–0 | PTR[15:8] | Pattern pointer, middle byte |
| 6 | PH | 5–0 | PTR[21:16] | Pattern pointer, high bits (bits 7–6 ignored). **Writing PH commits PTR** |
| 7 | BANK | 7–0 | BANK | Palette bank (section 2.4). Takes effect when written |
| 8 | XSL | 7–0 | XSTEP[7:0] | X step, low byte |
| 9 | XSH | 7–0 | XSTEP[15:8] | X step, high byte. **Writing XSH commits XSTEP** |
| 10 | YSL | 7–0 | YSTEP[7:0] | Y step, low byte |
| 11 | YSH | 7–0 | YSTEP[15:8] | Y step, high byte. **Writing YSH commits YSTEP** |
| 12–15 | — | | | Reserved: read 0, writes ignored |

**Latching**, as for every multi-byte value (spec 3): a write to XL, YL, PL, PM, XSL or YSL goes to a latch for that byte of that sprite; the write to the value's highest byte commits the whole value at once. Each sprite has its own latches, so writing XH alone commits X with the XL last written for that sprite. Reads return the committed value. Bits above 21 of PTR are ignored, and bit 21 too on a 2 MB board (spec 2).

**Reset:** the whole table is 0, so every sprite is off (EN = 0), and its steps (0) mean normal size (section 2.3).

### 2.2 Position

X is the beam pixel of the sprite's left edge and Y the beam line of its top edge, in beam coordinates (spec 4: the picture is pixels 144–863, lines 49–624). Picture pixel (x, y) of a 360 × 288 layer is at beam position (144 + 2x, 49 + 2y). Positions have beam precision whatever the scale.

Both are signed, so a sprite can slide in from the left or rise out of the top of the picture with any part of it off screen. Only picture pixels are drawn and take part in collisions. A sprite with X ≥ 864 or Y ≥ 625 is not shown. To hide a sprite, clear EN.

### 2.3 Scale

XSTEP is the number of source pixels the sprite moves on per beam pixel; YSTEP the number of source rows per beam line. Both are 4.12 fixed point: 4 integer bits and 12 fraction bits. A step of **0 is taken as 0x0800**, normal size, so a program that does not scale need not set the steps (and the table's reset state shows sprites at normal size).

| Step | Source per beam pixel/line | Size against normal | A 32-pixel pattern on screen |
|------|---------------------------|---------------------|------------------------------|
| 0x0080 | 1/32 | 16× | 1,024 beam pixels |
| 0x0200 | 1/8 | 4× | 256 |
| 0x0400 | 1/4 | 2× | 128 |
| 0x0800 (or 0) | 1/2 | 1× (normal: 2 beam pixels per sprite pixel) | 64 |
| 0x1000 | 1 | 1/2× (1 beam pixel per sprite pixel, as a hi-res layer) | 32 |
| 0x2000 | 2 | 1/4× | 16 |
| 0x8000 | 8 | 1/16× | 4 |
| 0xFFFF | about 16 | about 1/32× | 2 |

On-screen width = ⌈W × 4096 ÷ XSTEP⌉ beam pixels, height = ⌈H × 4096 ÷ YSTEP⌉ beam lines. Steps below 0x0080 are allowed (larger still) but are not tested. The pattern sizes W and H stay the source size; the hardware never divides: it steps an accumulator.

**Down: the Y accumulator.** Each sprite has a Y accumulator (6.12 bits) and an active bit, kept by the line scan (section 4.1):

- At the scan for line 0 of each frame every sprite is made inactive; a sprite with Y < 0 is started at once with its accumulator at (−Y) × YSTEP (one multiply, section 8).
- When the scan reaches line L = Y, the sprite starts: active, accumulator 0. This also restarts a sprite that is still active from an earlier use.
- On each line while active, the row is r = accumulator ÷ 4096 (its integer part). If r ≥ H the sprite ends (inactive). Otherwise the sprite is on the line with row r (H − 1 − r if YFLIP), and YSTEP is added for the next line.
- Clearing EN ends the sprite. Setting it again shows nothing until the scan next reaches line Y.

**Across: the X accumulator.** The renderer draws a sprite from beam pixel p0 = max(X, 144). It starts an X accumulator at (p0 − X) × XSTEP, and for each beam pixel takes source pixel c = accumulator ÷ 4096 (W − 1 − c if XFLIP), then adds XSTEP. It stops when c ≥ W or at pixel 863.

Sampling is nearest pixel (the integer part), with no filtering. Enlarging repeats pixels and rows and costs no extra memory; shrinking skips them.

### 2.4 Patterns and colours

A pattern is H rows, top row first, at PTR, PTR + stride, PTR + 2 × stride and so on, with **stride = W × BPP ÷ 8 bytes** (1, 2, 4, 8, 16 or 32). Pixels are packed as in the bitmap layer (spec 4): within each byte the leftmost pixel is in the highest bits, and bytes go left to right at rising addresses.

| W | 1 bpp | 2 bpp | 4 bpp | 8 bpp |
|---|-------|-------|-------|-------|
| 8 | 1 byte | 2 | 4 | 8 |
| 16 | 2 | 4 | 8 | 16 |
| 32 | 4 | 8 | 16 | 32 |

A row of 1 byte (8 pixels at 1 bpp) may be at any address. Longer rows must start at an even address: PTR bit 0 is ignored for them. Animation is a change of PTR.

**Colour.** A pixel value of 0 is transparent. Any other value v gives the palette index

    index = (BANK × 2^BPP + v) mod 512

so the bank bits used are BANK[7:0] at 1 bpp (256 pairs; one colour plus transparent), BANK[6:0] at 2 bpp (128 banks of 4), BANK[4:0] at 4 bpp (32 banks of 16) and BANK[0] at 8 bpp (the low or high 256 entries). This is the same rule as the attribute layer's (spec 4). The attribute layer does not act on sprites.

### 2.5 Flip

XFLIP and YFLIP walk the source backwards: source pixel W − 1 − c in place of c, and row H − 1 − r in place of r. Each is a subtract on an accumulator's integer part, a few LUTs. They save a mirrored copy of every left/right facing image, and with it the Z80's time to build the copies. They also match the tile layer, which has X and Y flip.

## 3. Display order, transparency and collisions

**Order**, back to front:

1. background colour
2. bitmap layer
3. sprites with BEHIND = 1
4. tile layer
5. sprites with BEHIND = 0

Sprites are always in front of the bitmap. The bitmap is the backdrop layer (a Spectrum screen, a drawn picture); the tile layer carries foreground scenery and score panels, so it is the one a sprite must be able to pass behind. One bit and one fixed order keep the mixer a 3-way choice. A program that wants sprites behind a picture can draw the picture in tiles.

Where sprites overlap, the **lower-numbered sprite is in front**, whatever their BEHIND bits: the sprite unit keeps only the front sprite's pixel at each position (section 4.3), and that pixel then goes in front of or behind the tile layer by its own BEHIND bit. A transparent sprite pixel (value 0) shows what is behind it, including higher-numbered sprites. A transparent tile pixel (value 0) shows a BEHIND sprite.

The tile entry's own priority bit is defined in spec 4. This spec assumes it puts that tile's opaque pixels in front of all sprites (open point S2).

**Collisions** are found per pixel, on picture pixels only, after scaling (what is on the screen):

- **Sprite–sprite:** when an opaque pixel of a sprite lands on a pixel already taken by an opaque pixel of a lower-numbered sprite, both sprites' bits in SPRCOLL are set. So each sprite that touches any other has its bit set.
- **Sprite–playfield:** when the front sprite's opaque pixel lands on an opaque pixel (value ≠ 0, inside its window) of the tile layer or the bitmap layer, that sprite's bit in SPRPFC is set. SPRCTL.CTILE and CBMP choose which layers count. Only the front sprite at each pixel is checked.
- Sprites, or parts of sprites, left out by a per-line limit (section 5) take part in no collision on that line.

The bits are sticky until cleared by writing 1. SPRSTAT.COLL and PFCOLL are set with them and can raise the SPRITE interrupt (section 6).

## 4. Fetch and draw

### 4.1 Pipeline

The draw beam runs one output line ahead of the display beam (spec 4). The sprite unit works two steps further ahead. While the draw beam draws output line N:

| Step | For line | Draw-line time (1792 system clocks per line) | Work |
|------|----------|-----------------------------------------------|------|
| Scan | N + 2 | Clocks 0–31 (slots 0–3) | Check the 32 sprites, one per clock, lowest number first: step the Y accumulators, find which sprites are on the line and their rows, apply the fetch budget (section 5). Copy each kept sprite's X, XSTEP, W, BPP, flags and BANK into the line list |
| Fetch | N + 2 | Slots 4–219 | Fetch the kept sprites' rows, lowest number first, into the row store, in cycle 3 (section 4.2) |
| Render | N + 1 | Clocks 0–1759 | Draw the kept sprites, lowest number first, from the row store into the sprite line buffer, one beam pixel per clock (section 4.3) |
| Draw | N | At the draw beam | Read line N's sprite line buffer, mix it with the layers (section 3), clear it |

So each line's rows are fetched during the line before the one in which they are rendered, and rendered during the line before the one drawn. Fetch and render each have a whole line, which makes their limits independent (section 5). The scan runs on every line, 0–624, so that the Y accumulators keep step in the vertical blank; fetch and render work for picture lines (49–624) only.

The line list and the row store are double-buffered (one half for the line being fetched, one for the line being rendered).

### 4.2 Fetch and the row store

The row store holds one row per sprite (32 × 32 bytes) for each of its two halves. A row is fetched whole, 16 bits per memory cycle, whatever the scale: enlarging needs no more memory, and shrinking may skip rows. The fetcher uses **cycle 3** of each slot, in the order set by spec 2 and spec 4:

1. the copper;
2. a display FIFO below its low mark (urgent);
3. **sprites**;
4. display top-up.

It also takes cycles 0–2 when their owners leave them free; that only makes it finish sooner. Which sprites are drawn is set by the budgets alone, never by how busy the CPU is.

**Row reuse.** When a sprite's row on a line is the same row as on the line before (enlarged sprites, and normal-size sprites on every second line), it is not fetched again: the renderer reads the row where it already is, and the fetch costs nothing. This holds when the sprite was fetched and kept on the line before and its XH, YH and PH have not been written since; otherwise the row is fetched again.

**Late fetch.** If the fetch is not finished by slot 220 (because the copper and urgent display fetches took more of cycle 3 than SPRLIMIT left for them), the sprites not yet fetched, the highest numbers, are left out of that line and SPRSTAT.LATE is set. LATE means SPRLIMIT is set too high for that copper program and layer set-up: a programming error, as OVERRUN is for the layers.

### 4.3 Render and the sprite line buffer

The sprite line buffer has two banks, one per line parity, each in its own block RAM: the renderer fills bank (N + 1) mod 2 while the draw beam reads bank N mod 2. A bank holds 720 entries, one per picture beam pixel (144–863). An entry is 16 bits:

| Bits | Field |
|------|-------|
| 15 | OPAQUE |
| 14 | BEHIND |
| 13–9 | Sprite number |
| 8–0 | Palette index |

The renderer takes the kept sprites from the lowest number to the highest, and for each beam pixel of a sprite (section 2.3, X accumulator) reads the source pixel from the row store. It reads the entry ahead through the bank's second port, and writes the pixel only if it is opaque and the entry is still free, so lower numbers stay in front. An opaque pixel that finds the entry taken is a sprite–sprite collision: the bits of both sprite numbers are set.

The renderer does one beam pixel per clock, at any scale. Each sprite costs its on-screen width in picture pixels plus 4 clocks of start-up (the start offset multiply and the pipeline). The render stops at clock 1760 of the line (section 5.3).

**Draw.** The draw beam reads each entry of its bank, uses it for the mixer (section 3), checks sprite–playfield collisions, and writes it back as 0, so the bank is clear for its next use. This happens on every picture line, even with sprites off.

### 4.4 When writes take effect

Attributes are used when the scan reads them. The scan for line N + 2 runs at the start of draw line N (system clocks 0–31, about draw-beam pixels 0–15), and reads each sprite's committed values in one clock, so a half-written value is never used. So:

- A write committed while the draw beam is on line N at pixel 16 or later is used **from line N + 3**.
- A write committed during pixels 0–15 may be used from line N + 2 or N + 3. Avoid this window.
- Everything the renderer needs is copied at the scan, so a write never changes a line already scanned.
- A change to YSTEP is added to the accumulator from the next line scanned, so the copper can change the scale down a sprite. A change to XSTEP or X acts on whole lines.
- SPRCTL and SPRLIMIT are used from the next scan, as attributes are.

**Multiplexing.** To reuse sprite n, whose current use ends on line M − 1, for a new use starting on line M (no gap needed): the copper WAITs for draw-beam position (M − 3, 16) and then writes sprite n's new attributes, all committed before (M − 2, 0). The old use's last line was scanned at the start of line M − 3, before the writes; the new use's first line, where the scan finds L = Y and restarts the Y accumulator, is scanned at the start of line M − 2, after them.

## 5. Per-line limits

Two limits apply to each line: memory cycles to fetch the rows, and time to render them. Both keep the lowest-numbered sprites.

### 5.1 Fetch cost

A sprite on a line costs ⌈W × BPP ÷ 16⌉ memory cycles (at least 1), or 0 when its row is reused (section 4.2). The scale does not change the cost of a row.

| W | 1 bpp | 2 bpp | 4 bpp | 8 bpp |
|---|-------|-------|-------|-------|
| 8 | 1 | 1 | 2 | 4 |
| 16 | 1 | 2 | 4 | 8 |
| 32 | 2 | 4 | 8 | 16 |

### 5.2 Fetch budget

A line has 224 slots. The scan takes slots 0–3, and a margin of 4 slots is kept at the end, so the fetch has **216 cycle-3 cycles**, less what the copper and the urgent display fetches take in that line:

    fetch budget = 216 − copper's cycle-3 cycles − display's urgent cycle-3 cycles

- **Copper:** a WAITing copper takes almost nothing; each MOVE or indirect move costs its instruction and data reads (spec 6). A copper changing attributes every 8-pixel cell can take 100 or more cycles of a line.
- **Display:** urgent fetches in cycle 3 happen only on lines where the layers need more than cycle 1 gives (448 bytes per output line, spec 4). The worst case is the excess: the display's bytes on that line ÷ 2 − 224 cycles (0 when the layers fit in cycle 1). On the second line of a 288-line layer's pair the layer fetches nothing.

**SPRLIMIT** (section 6) holds the budget the scan uses, in cycles, 0–216 (higher values are taken as 216). Reset value: 192, which leaves 24 cycles per line for the copper and the display. The scan adds up the fetch costs of the sprites on the line, lowest number first. The first sprite whose cost would take the total over SPRLIMIT is left out, **with every higher-numbered sprite** on that line; SPRSTAT.DROP is set and SPRDROP records that sprite's number. Give the important objects (the player, the cursor) low numbers.

Setting SPRLIMIT from what the copper and display really use makes the result fixed: it depends only on the sprites, the copper program and the layers, never on the CPU. If the copper and display take more than 216 − SPRLIMIT in a line, the fetch may run late (section 4.2).

Sprites per line on a fetch line, all alike (a reused row costs nothing):

| Sprite | Cost | SPRLIMIT 216 | 192 (reset) | 120 (busy copper) |
|--------|------|--------------|-------------|-------------------|
| 8 px, any bpp; 16 px up to 4 bpp; 32 px up to 2 bpp | ≤ 4 | 32 | 32 | 30 |
| 16 px 8 bpp; 32 px 4 bpp | 8 | 27 | 24 | 15 |
| 32 px 8 bpp | 16 | 13 | 12 | 7 |

**Worst case:** all 32 sprites 32 pixels wide at 8 bpp starting on one line cost 512 cycles; at SPRLIMIT 216, sprites 0–12 are fetched (208 cycles) and 13–31 are left out. At normal size, the rows are reused on every second line, which then costs nothing.

### 5.3 Render limit: on-screen width

The renderer has 1,760 clocks per line (32 are kept as a margin) and does one beam pixel per clock. Each kept sprite takes its on-screen width on that line (picture pixels only, after scaling and clipping) plus 4 clocks:

    Σ (on-screen width + 4) ≤ 1760

With 32 sprites that is 1,632 beam pixels of sprite in all, more than two full picture widths. The renderer works lowest number first; when it reaches clock 1760, the sprite it is drawing is cut off at that pixel, the higher-numbered sprites are left out, SPRSTAT.WIDE is set and SPRDROP records the cut sprite. Since the width needs a divide to know in advance, the limit is applied as the render goes, not at the scan.

Sprites per line by width, all alike:

| Pattern width and scale | On-screen width | Sprites per line |
|--------------------------|-----------------|------------------|
| 8 px, normal | 16 | 32 (640 clocks) |
| 16 px, normal | 32 | 32 (1,152 clocks) |
| 32 px, normal | 64 | 25 |
| 32 px, 1/2× (step 0x1000) | 32 | 32 |
| 32 px, 2× (step 0x0400) | 128 | 13 |
| 32 px, 16× (step 0x0080) | 720 (clipped to the picture) | 2, the third cut |

**Tip:** sprites whose Y values differ in parity, at normal size, fetch on alternate lines, and so spread the fetch load, as layers with windows of opposite parity do (spec 4). The render limit is per line and cannot be spread.

## 6. Registers

| Port | Name | Access | Bits | Meaning |
|------|------|--------|------|---------|
| `0x80` | SPRIDX | RW | 7–0 | Attribute table index, bits 7–0 (sprite × 16 + byte). A write also clears index bit 8 |
| `0x81` | SPRIDXH | RW | 0 | Index bit 8 (sprites 16–31). Write it after SPRIDX |
| `0x82` | SPRDATA | RW | 7–0 | Attribute table data at the index (section 2.1); the index steps after each access |
| `0x83` | SPRCTL | RW | 0 EN, 1 CTILE, 2 CBMP | EN: sprites on. CTILE, CBMP: the tile layer, the bitmap layer count for sprite–playfield collisions. Reset 0 |
| `0x84` | SPRSTAT | R, W1C | 0 COLL, 1 PFCOLL, 2 DROP, 3 WIDE, 4 LATE | COLL: a sprite–sprite collision. PFCOLL: a sprite–playfield collision. DROP: sprites left out by the fetch budget. WIDE: by the render limit. LATE: a fetch ran late. Sticky; write 1 to clear |
| `0x85` | SPRIEN | RW | 0–4, as SPRSTAT | Interrupt enables. SPRITE request = (SPRSTAT AND SPRIEN) ≠ 0. Reset 0 |
| `0x86` | SPRLIMIT | RW | 7–0 | Fetch budget in memory cycles per line, 0–216 (section 5.2). Reset 192 |
| `0x87` | SPRDROP | R | 4–0 number, 6 CAUSE, 7 VALID | The first sprite left out (or cut) on the latest line that lost sprites. CAUSE: 0 = fetch budget or late, 1 = render limit. VALID is cleared when DROP, WIDE and LATE are all clear |
| `0x88`–`0x8B` | SPRCOLL0–3 | R, W1C | 7–0 | Sprite–sprite collision bits: port 0x88 bit k = sprite k, 0x89 = sprites 8–15, 0x8A = 16–23, 0x8B = 24–31 |
| `0x8C`–`0x8F` | SPRPFC0–3 | R, W1C | 7–0 | Sprite–playfield collision bits, laid out as SPRCOLL |

SPRIDX is an index the hardware steps, not a value, so it is not latched: a write to SPRIDX sets the index at once, so sprites 0–15 need one write and sprites 16–31 two.

The copper can write all of these ports (it writes 0x30–0x9F). SPRSTAT and the collision bits are usually read and cleared once per frame in the vertical blank.

**Interrupt line:** SPRITE (spec 8 gives its number and vector). It stays raised while (SPRSTAT AND SPRIEN) ≠ 0.

## 7. Examples

Upload the whole attribute table from memory (sjasmplus):

```
        xor  a
        out  (SPRIDX),a          ; index 0
        ld   hl,sprtab           ; 512 bytes: 32 sprites x 16
        ld   bc,0x0000+SPRDATA   ; B = 0: 256 bytes
        otir                     ; sprites 0-15
        otir                     ; sprites 16-31 (B is 0 again)
        ld   a,SPRCTL_EN
        out  (SPRCTL),a
```

A 16 × 16 sprite at 4 bpp at normal size (32 × 32 beam pixels), at picture position (100, 60) of the 360 × 288 picture, colours 0x50–0x5F (BANK 5), as sprite 3:

```
X       equ  144+2*100
Y       equ  49+2*60
        ld   a,3*16
        out  (SPRIDX),a
        ld   hl,sprite3
        ld   bc,0x0C00+SPRDATA   ; 12 bytes
        otir
        ...
sprite3 db   low X, high X | (1<<3) | SPR_EN        ; W = 16
        db   low Y, high Y | (1<<3) | (2<<6)        ; H = 16, 4 bpp
        db   low ship, high ship, ship>>16          ; 22-bit pointer
        db   5                                      ; BANK
        dw   0x0800, 0x0800                         ; X step, Y step: normal
```

To grow the same sprite to twice the size about its centre, write steps of 0x0400 and move X and Y back by 16 beam pixels and lines.

Multiplexing in the copper (syntax of spec 6): sprite 0 shows a ship on lines 100–131; the same sprite shows a second ship from line 132:

```
        CWAIT  129,16            ; after the scan for line 131
        CMOVE  SPRIDX,0
        CMOVE  SPRDATA,low X2
        CMOVE  SPRDATA,high X2 | (1<<3) | SPR_EN
        CMOVE  SPRDATA,low 132
        CMOVE  SPRDATA,high 132 | (1<<3) | (2<<6)
        CMOVE  SPRDATA,low ship2
        CMOVE  SPRDATA,high ship2
        CMOVE  SPRDATA,ship2>>16 ; all committed before (130, 0)
```

## 8. FPGA resources

| Item | Resource |
|------|----------|
| Attribute table (512 bytes, 384 used, + 192 bytes of latches) | Distributed RAM, about 100 LUTs |
| Scan: Y accumulators (32 × 19 bits), row, fetch cost, budget adder, line lists (2 × 32 × 56 bits) | About 350 LUTs |
| Start offsets: (−Y) × YSTEP at line 0, (p0 − X) × XSTEP per sprite | 1 DSP48 slice, shared (the scan uses it in clocks 0–31, the renderer after) |
| Fetcher: row addresses, cycle-3 requests, reuse bits | About 150 LUTs |
| Row store: 2 halves × 32 rows × 32 bytes (2 KB) | 1 block RAM (18 Kb, 1K × 16) |
| Renderer: X accumulator, flip, pixel select, bank, read-ahead, render limit | About 250 LUTs |
| Sprite line buffer: 2 banks × 720 × 16 bits | 2 block RAMs (18 Kb each) |
| Collisions, registers, interrupt | About 150 LUTs |
| Total | About 1,000–1,200 LUTs; 3 blocks of 18 Kb; 1 DSP slice |

The 3 blocks are in the design plan's block RAM table (D11).

## 9. Test plan

- **Golden images:** every width, height and bpp; normal size; X and Y flip; BANK at each bpp; clipping at all four picture edges, with negative X and Y; compared pixel by pixel with the Python video model extended with sprites.
- **Scaling:** steps 0x0080, 0x0400, 0x0800, 0x0801, 0x0C00, 0x1000, 0x8000, 0xFFFF and step 0 (taken as 0x0800), across and down separately, with and without flip, against the model's accumulator arithmetic bit for bit; on-screen sizes match ⌈W × 4096 ÷ step⌉; start offsets right for sprites clipped at the left and top at every scale; YSTEP changed by the copper part way down a sprite; shrunk sprites skip rows, enlarged sprites fetch each row once (counted fetch cycles).
- **Order:** overlapping sprites (lower number in front), BEHIND against opaque and transparent tile pixels, sprites always over the bitmap, tile priority bit (once spec 4 settles it).
- **Collisions:** known overlaps, at several scales, set exactly the expected SPRCOLL and SPRPFC bits, with CTILE and CBMP each way; none in the blanking or from left-out sprites; SPRITE interrupt with each SPRIEN bit.
- **Fetch budget:** lines with sprite sets just under and just over SPRLIMIT leave out exactly the expected sprites; DROP and SPRDROP right; reused rows cost nothing.
- **Render limit:** lines whose total on-screen width is just under and just over 1,760 − 4 × sprites; the cut sprite and those after it as section 5.3 says; WIDE and SPRDROP.CAUSE right.
- **Late fetch:** a copper program that takes most of cycle 3 with SPRLIMIT at 216 sets LATE and leaves out only the highest numbers; a CPU running flat out at 28 MHz never changes which sprites are drawn.
- **Timing:** attribute writes by the copper at (N, 16) take effect on line N + 3; back-to-back multiplexing of one sprite with no gap line; two OTIRs of the whole table and INIR read-back; latching (XH alone uses the last XL); SPRIDXH.
- **Measure** in simulation: the renderer's start-up per sprite (4 clocks assumed) and the margins (open point S1).

## 10. Open points

| # | Item |
|---|------|
| S1 | Confirm in simulation the renderer's 4-clock start-up per sprite, the 32-clock render margin and the 4-slot fetch margin; adjust the 1,760 and 216 figures if not |
| S2 | The tile entry's priority bit (spec 4): this spec assumes it puts the tile's opaque pixels in front of all sprites. To be agreed with spec 4 |
| S3 | Pipeline depth: rows are fetched two output lines before they are drawn (scan, fetch; render; draw), so fetch and render have a line each and two independent limits. Fetching and rendering in the same line would save a line of latency and the second half of the row store, but the two limits would then interact. Confirm with spec 4 |
| S4 | The render limit cuts the sprite being drawn at clock 1760 (part of it shows). Knowing the width in advance needs a divide (or the width given by software); kept simple for now |
| S5 | Step 0 is taken as 0x0800 (normal size), so the reset table and programs that never scale show normal sprites. The brief suggested 0x0001; to be confirmed |
| S6 | Should LATE also set VIDSTAT.OVERRUN (spec 4), so one flag shows all late data? |
| S7 | Fetch budget rule: stop at the first sprite that does not fit (simple, "lowest numbers kept"), or skip it and keep later, cheaper ones. This spec stops |
| S8 | Reset value of SPRLIMIT (192): to be checked against typical copper programs once spec 6 gives the copper's cycle costs |
| S9 | SPRIDX is not latched (an exception to spec 3's rule for multi-byte values), so one write reaches sprites 0–15. To be listed in spec 3 |
| S10 | Width/height code 3 is reserved; it could be 64 pixels later if the budgets allow |
