# Spec 5: Sprites

Status: **draft**

Sprites are small images drawn over (or between) the layers at any position, without touching the layers' memory. retro-z80 has retro68k's eight sprites as built (its spec 9, guide chapter 4, `sprites.v` and `sprite_pix.v`), narrowed to byte registers. Each sprite has a pointer into SRAM for its image (SPRxPT); its window, settings and scale are plain registers (SPRxH, SPRxV, SPRxCTL, SPRxSTEP) that the CPU or copper writes. A write to SPRxCTL starts a sprite; the vertical blank stops them all, so each frame the copper writes each sprite's registers, CTL last. The others can be changed while a sprite is being drawn, from one line to the next, for effects such as wobbling, zooming and switching images, and the copper can reuse a sprite further down the screen by starting it again. The image is fetched just in time, through the same scheduler as the layers, into a 32-word FIFO per sprite.

## 1. Summary

| Item | Value |
|------|-------|
| Sprites | 8 (SPR0–SPR7). Each can be reused further down the screen by the copper rewriting its registers |
| Window | HSTART–HSTOP across, VSTART–VSTOP down, in beam coordinates, as a layer's window. The image's size follows from the window and the scale |
| Size | Any, set by the window. Lines of any length stream through the FIFO; only the memory budget (section 5) limits how big and how many |
| Colours | 2, 4 or 8 bits per pixel. 2 and 4 bpp: 3 or 15 colours + transparent, from any 16-colour block of the sprite palette; 8 bpp: 255 colours + transparent, the whole sprite palette. The sprites have a 256-entry palette of their own, SPRPALETTE (spec 4) |
| Position | Any beam pixel and line, unsigned, with HSTART 16 or more; clipped by the hardware at all four edges (section 3.2) |
| Scaling | Fractional, across and down separately: a 16-bit step per axis (SPRxSTEP), in source pixels per screen pixel, 5.11 fixed point, from 16× bigger (`0x0080`) through normal size (`0x0800`) to 1/16 (`0x8000`) |
| Depth | Per sprite: in front of all three layers, between any two (in PRIO order), or behind all |
| Order | DEPTH first, then number: a sprite at a front depth is in front of one at a deeper depth; at the same depth the lower number is in front |
| Collisions | Sprite–sprite and sprite–layer, per pixel, sticky (SPRCOLL) |
| Data registers | A 32-word FIFO per sprite, streaming: lines of any length pass through it |
| Fetch | Just in time, earliest deadline first, shared with the layers through the scheduler (spec 2). Each line's words are fetched during that line, from its start (the horizontal blank), as soon as the sprite's FIFO has room and a memory cycle is free |
| Starting | A write to SPRxCTL (one byte) starts a sprite; the vertical blank stops every sprite. The other registers act on a running sprite from the next line (section 4.2) |
| Late data | A sprite whose FIFO runs dry shows nothing more until its CTL is next written, and sets VIDSTAT.SPRUNDER, which can raise VIDERR (section 4.3) |
| Registers | Custom block: 16 bytes per sprite at `0x010` + n × `0x10` (in a copper MOVE's reach); SPRDMA and SPRCOLL at `0x120`–`0x127` |
| Interrupts | None of their own: SPRUNDER raises VIDERR, as in retro68k (spec 4, spec 8) |
| FPGA | About 3,000 LUTs; no block RAM (section 8) |

## 2. Comparison with retro68k

The same: eight sprites; SPRxPT, SPRxH, SPRxV, SPRxCTL and SPRxSTEP with retro68k's fields; any size, set by the window; chunky 2, 4 and 8 bpp, first pixel in the high bits; value 0 transparent; PAL blocks of SPRPALETTE, and VIDCON.SHAREPAL; fractional scaling with XSTEP and YSTEP (5.11, 0 counts as `0x0800`, limits `0x0080`–`0x8000`); DEPTH among three layers in PRIO order; DEPTH first, then number; direct colour (sprites in front, DEPTH not used); unsigned beam positions clipped at all edges, with HSTART 16 or more; no flips; a write to SPRxCTL starts a sprite and the vertical blank stops every sprite, so each frame the copper writes each sprite's registers, CTL last, and nothing restarts by itself; PT, H, V and STEP act on a running sprite from the next line, and a PT write sets exactly where the next image line starts; the window checked on every line; SPRxPT moves on line by line, and reading it gives the start of the image line being drawn (or the value just written); 32-word FIFOs filled just in time through the scheduler, deadline first, each line fetched during that line, from its start; SPRUNDER in VIDSTAT, raising VIDERR; SPRDMA (set/clear) with DMACON.SPREN and DMAEN, which pauses a sprite without starting or stopping it; SPRCOLL with SPR, L0, L1 and L2; reuse down the screen by the copper, CTL last.

| Item | retro68k | retro-z80 | Why |
|------|----------|-----------|-----|
| Register width | 32-bit registers | Bytes. Each register is its bytes in order, low byte first; each byte is written directly, with no latch (spec 3) | Z80 |
| Sprite registers | 32 bytes per sprite at `0x520` + n × `0x20`: PT, H, V, CTL, DAT, STEP at `+0x00`–`+0x14` | 16 bytes per sprite at custom offset `0x010` + n × `0x10`: PT (3 bytes), H (4), V (4), CTL (1), STEP (4) | Z80: a one-word copper MOVE reaches offsets below `0x0F0` only (spec 6) |
| SPRxPT | Bits 22–1, 4 bytes | Bits 21–1 (22-bit physical SRAM address, spec 2), 3 bytes. Written while the sprite runs, its three bytes go in within one line (section 4.2) | Memory size; byte registers |
| SPRxCTL | 32 bits: BPP (13–12), DEPTH (21–20), PAL (27–24) | One byte: BPP (1–0), DEPTH (3–2), PAL (7–4). Every field fits; nothing is lost. It is the packing retro68k's `sprites.v` keeps inside. One byte, so the write that starts a sprite never finds CTL half written | Byte registers |
| Manual mode | SPRxDAT pushes words into the FIFO with the sprite's DMA off; a read gives the words in the FIFO | None: no SPRxDAT. A sprite with its DMA off is paused as in retro68k, but nothing else fills its FIFO (section 4.4) | Branch 11: 16 bytes per sprite |
| SPRDMA, SPRCOLL | `0x500`, `0x504` | `0x120`, `0x124`; the copper reaches them with MOVEF only | Custom block layout (spec 3) |
| SPRDMA write | One 16-bit write: SPR (7–0) and SETCLR (15) | Two bytes: SPR in byte 0, SETCLR in byte 1 bit 7; writing byte 1 sets or clears the bits of byte 0 | Byte registers |
| CPU cycles | An urgent sprite fetch may take the CPU's cycle 0; the CPU waits one slot | An urgent fetch never takes a cycle the CPU is using; the CPU never waits (spec 2). Sprites get cycles 1 and 3 by deadline, then spare cycles | Z80: no wait states (spec 1) |
| Spare cycles | The 68000 leaves at least every other cycle 0 | The Z80 at 20 MHz makes at most one access in 1.5 slots, so at least one of its two cycles (0, 2) is spare in every slot (spec 2) | Memory timing (spec 2) |
| Colours | 24-bit palette entries | The same, 3 bytes per entry (spec 4) | – |
| Dropped from the earlier retro-z80 draft | – | The row store and the whole-row fetch; the 512-byte row limit; HMAG and VMAG (replaced by SPRxSTEP); the exact "nothing on L + 1, new from L + 2" write rule; manual mode by bytes; the guaranteed budget B = 224 − D − C; tile PRI as a sprite-spec rule (now spec 4's) | Branch 11: retro68k's sprites as built |
| Later (retro68k section 11) | A sprite table; sprites in direct colour at any depth | A sprite table: the sprite sequencer, a retro-z80 extra (spec 17). Direct colour at any depth: not planned | Design plan, branch 14 |

## 3. Sprites: pointer, window and settings

Each sprite has five registers (section 6):

- **SPRxPT** points at the sprite's image in SRAM: its lines one after another, top line first, each a whole number of 16-bit words. As a layer's pointer does, it moves through the image as it is fetched, so the hardware does not reset it: the copper (or the CPU) writes it every frame, before CTL (section 4.2).
- **SPRxH** and **SPRxV** give the sprite's window, **SPRxCTL** its settings and **SPRxSTEP** its scale. They are plain registers: the CPU or copper writes them, and they stay as written until written again. The image in memory is pixels only.

### 3.1 The window

In beam coordinates (spec 4: the picture is pixels 144–863, lines 49–624):

| Register | Bits | Field | Meaning |
|----------|------|-------|---------|
| SPRxH | 10–0 | HSTART | First beam pixel of the sprite (16–863, section 3.2; 864 or more: not shown). Pixels before 144 are in the horizontal blank: fetched, not shown |
| SPRxH | 26–16 | HSTOP | Beam pixel just after the sprite (above 864 counts as 864) |
| SPRxV | 10–0 | VSTART | First beam line of the sprite (0–624; 625 or more: not shown). Lines before 49 are in the vertical blank: fetched, not shown |
| SPRxV | 26–16 | VSTOP | Beam line just after the sprite (above 625 counts as 625) |

All four are unsigned 11-bit beam positions, as retro68k's RTL and guide (open point S3).

The image's size follows from the window and the scale (section 3.4): **source width** = ⌈(HSTOP − HSTART) × XSTEP ÷ 2048⌉ pixels and **source height** = ⌈(VSTOP − VSTART) × YSTEP ÷ 2048⌉ lines. At normal size (step `0x0800`) the image is the window's size. A source line is stored in whole words: ⌈source width × BPP ÷ 16⌉ words, twice that in bytes. These sizes are worked out for each line from the settings at its start (section 4.2), so a window or scale changed while a sprite is drawn changes the size of its lines from there on. If HSTOP is not above HSTART, or VSTOP not above VSTART, the window is empty and the sprite does not show. After reset every window is empty.

A sprite shows inside its window from a write to its SPRxCTL until the next vertical blank (section 4.2). To hide it, don't write its CTL this frame, turn its DMA off (section 4.4), or set VSTART to 625 or more.

### 3.2 Clipping

The hardware clips at all four edges. A sprite's line is a beam line, and its frame the beam's frame:

- **Left:** pixels before beam pixel 144 are fetched and used up but not shown. A line's words are fetched during the line, from its start, so the fetch needs a few pixels before the sprite's first pixel: **HSTART must be 16 or more**, so a sprite can hang up to 128 pixels off the left edge.
- **Top:** lines before beam line 49 are fetched and used up but not shown, so the first line that shows is the right line of the image.
- **Right:** pixels from beam pixel 864 on are neither fetched nor shown.
- **Bottom:** lines from beam line 625 on are neither fetched nor shown.

A sprite cannot show on beam line 0, where the vertical blank stops every sprite. Its first line is the next line after its CTL write that is inside its window (section 4.2).

### 3.3 SPRxCTL

One byte:

| Bits | Field | Meaning |
|------|-------|---------|
| 1–0 | BPP | 0 = 2, 1 = 4, 2 = 8 bits per pixel; 3 reserved (taken as 8) |
| 3–2 | DEPTH | 0 = in front of all layers; 1 = behind the front layer; 2 = behind the middle layer; 3 = behind all layers (in PRIO order, spec 4) |
| 7–4 | PAL | 2 and 4 bpp: the 16-colour block of the sprite palette (colour = PAL × 16 + value). Not used at 8 bpp |

These are retro68k's three fields, with its values, packed into one byte in the order retro68k's `sprites.v` stores them.

### 3.4 Scaling: SPRxSTEP

**SPRxSTEP** holds two steps, **XSTEP** (bits 15–0, bytes 0–1) and **YSTEP** (bits 31–16, bytes 2–3): source pixels (or lines) per screen pixel (or line), in 5.11 fixed point, as retro68k.

| Step | Size |
|------|------|
| `0x0080` | 16× bigger |
| `0x0200` | 4× bigger |
| `0x0400` | 2× bigger |
| `0x0555` | 1.5× bigger |
| `0x0800` | Normal |
| `0x0C00` | 2/3 |
| `0x1000` | Half |
| `0x8000` | 1/16 |

- **Which source pixel:** screen pixel i of the window (i = 0 at HSTART) shows source pixel ⌊i × XSTEP ÷ 2048⌋ of its line; screen line j of the sprite (j = 0 at its first line) shows source line ⌊j × YSTEP ÷ 2048⌋, while YSTEP and SPRxPT are left alone. So the first pixel and line always show the image's first, and every step works the same, with no rounding to pick. (A YSTEP changed part way down carries on from the fraction reached; a PT written part way down starts again from there.)
- **Limits:** steps below `0x0080` count as `0x0080`, steps above `0x8000` as `0x8000`. A step of 0 counts as `0x0800`, so a sprite whose SPRxSTEP was never written is normal size.
- **Cost** (section 5): bigger across, a word lasts more screen pixels; smaller across, fewer, since every source pixel of a line is fetched, the skipped ones too (they stream through the FIFO). Bigger down, a line is fetched again for each screen line it shows on (the FIFO cannot replay a line); smaller down, the lines skipped are not fetched.

For any other size the step is 2048 ÷ the scale. There is no flip: for an object that faces either way, store both images.

### 3.5 Pixels, colours and depth

Image lines are **chunky**: 2, 4 or 8 bits per pixel, packed as the chunky layers' are (spec 4): bytes left to right at rising addresses, the first pixel in the high bits of each byte. A value of 0 is transparent. Other values are entries of **SPRPALETTE**, the sprite palette (spec 4), which the layers do not use: at 8 bpp the value itself; at 2 and 4 bpp, PAL × 16 + the value. With VIDCON.SHAREPAL set, sprites use PALETTE0 instead, as the layers then do.

**Depth.** Each sprite's DEPTH puts it among the three layers in their PRIO order (spec 4). From the front:

| From the front | |
|----------------|--|
| 1 | Sprites with DEPTH 0 |
| 2 | The front layer |
| 3 | Sprites with DEPTH 1 |
| 4 | The middle layer |
| 5 | Sprites with DEPTH 2 |
| 6 | The back layer |
| 7 | Sprites with DEPTH 3 |
| 8 | The background colour (BGCOLOR) |

- Within each group the **lower number is in front**. A sprite at a front depth is in front of a lower-numbered sprite at a deeper one.
- A layer's transparent pixels (TRANSP set, value 0), and pixels outside its window, show what is behind them. A layer without TRANSP hides everything behind it inside its window.
- **Tile priority.** A tile-map entry's PRI bit (spec 4) can bring a tile's pixels in front of its layer's place. Where PRI tiles go among the sprites is spec 4's rule (section 4.8): in front of DEPTH 1–3 sprites and behind DEPTH 0.
- In **direct colour** (spec 4), as in retro68k, sprites are drawn in front of the whole picture in their colours from SPRPALETTE, and DEPTH is not used.
- The attribute layer (Spectrum extra, spec 4) does not act on sprites.

### 3.6 Collisions

The hardware checks every picture pixel for sprites touching, as retro68k does, and sets bits in **SPRCOLL** (section 6):

| Byte | Bit n set when |
|------|----------------|
| 0, SPR | An opaque pixel of sprite n was on the same pixel as an opaque pixel of another sprite |
| 1, L0 | An opaque pixel of sprite n was on an opaque pixel of layer 0 |
| 2, L1 | The same, against layer 1 |
| 3, L2 | The same, against layer 2 |

- A sprite pixel is opaque if its value is not 0. A layer pixel is opaque if it is inside the layer's window and not transparent. Depth does not matter: a sprite behind a layer still collides with it.
- Only picture pixels count (beam pixels 144–863 on lines 49–624), not those clipped or in the blanking. A sprite that shows nothing (underrun, DMA off) takes part in no collision.
- The sprite bits do not say which other sprite was hit: if bits 0 and 3 are set, sprites 0 and 3 might have touched each other, or each another sprite.
- Collisions are found on each line as it is drawn, and reach SPRCOLL just after the line ends. The bits are **sticky** until cleared by writing 1. A frame's collisions are all in SPRCOLL by the start of the next vertical blank: read SPRCOLL once a frame and clear the bits read.

There is no collision interrupt, as in retro68k.

## 4. Fetch and FIFOs

### 4.1 The FIFO

Each sprite has a **FIFO of 32 words**, its data registers. The fetcher pushes the image's words in at the back; the sprite takes them from the front as it is drawn, a line's worth per screen line (⌈source width × BPP ÷ 16⌉ words). The FIFO streams: a line can be longer than the FIFO, as long as the fetch keeps it from running dry. Its size only sets how far ahead the fetch can go.

- **Fetching within the line.** A line's words are fetched during that line, from its start: never ahead into the next line, since the next line's settings are not known until it starts. The fetcher pushes the line's words whenever the FIFO has room, up to 30 words ahead of the beam (it keeps two of the 32 places for words still on their way): 60 source pixels at 8 bpp, 120 at 4 bpp, 240 at 2 bpp. Fetching becomes urgent only when the FIFO is about to run dry: then the sprite takes part in the earliest-deadline-first order with the layers (spec 2).
- **The lead** is the time from the line's start to the sprite's first pixel: at least 16 pixels (HSTART 16), and the whole horizontal blank, 144 pixels (5.3 µs), for a sprite at the picture's left edge.
- **What a line takes.** The words that hold its shown pixels, from HSTART to HSTOP or beam pixel 864, whichever comes first. Words past the right edge are not fetched.
- **How the pointer moves.** SPRxPT moves on line by line: reading it gives the start of the image line being drawn, or the value just written. Each line starts where section 4.2 ("Which image line") says.

### 4.2 Starting, stopping and changing a sprite

- **A write to SPRxCTL starts the sprite** (any write: the CTL value may be the same as before). CTL is one byte, so it is never half written. Its FIFO is emptied and reads still on their way are dropped. Its first line is the next beam line, after the write, that is inside its window; that line shows the image line at SPRxPT. (It is the copper's job to point SPRxPT at the image's first line, as for a layer, before it writes CTL.)
- **The vertical blank stops every sprite** (beam line 0, pixel 0): its FIFO is emptied and nothing is fetched or shown until its CTL is written again. Nothing starts again by itself at the frame start. So each frame the copper (or the CPU, in its VBLANK interrupt) writes each sprite's registers, CTL last.
- A sprite whose CTL is written after its VSTART has gone by shows the image from its first line, from the next line, down to VSTOP.
- To hide a sprite, don't write its CTL this frame, turn its DMA off (section 4.4), or set VSTART to 625 or more.

**Each line.** At the start of every beam line (pixel 0, the start of its horizontal blank) each running sprite takes the line's settings: its window, its scale, its CTL settings. If the line is inside the window (VSTART ≤ line < VSTOP), the sprite shows on it, and its words are fetched during the line. The window is checked on every line: a VSTOP made later lets the sprite go on, one made earlier ends it; a VSTART moved later leaves the sprite off until the window reaches it again.

**Which image line.** The sprite's first line shows the image line at SPRxPT. Each further line it shows moves on by the source lines YSTEP gives (section 3.4): k lines, k × ⌈source width × BPP ÷ 16⌉ words, with the source width of that line's settings. When the sprite is bigger down (YSTEP below `0x0800`), k is often 0 and the line is fetched again; when it is smaller, lines in between are skipped: neither fetched nor shown. **A write to SPRxPT** while the sprite runs sets exactly where its next image line starts (not moved on by YSTEP that time); the lines after it move on from there. So an image can be switched from one line to the next.

**Changing a sprite while it is drawn.** Writes to SPRxH, SPRxV, SPRxSTEP and SPRxPT act on a running sprite from the next line that starts after the write; CTL's settings (BPP, DEPTH, PAL) likewise, but a CTL write also starts the sprite again. A stopped sprite takes them when it is started. So a copper list can move a sprite across on every line (a wobble), change XSTEP and the window on every line (a zoom, perspective), or switch its image part way down.

Each byte is written directly, with no latch (spec 3), and the others keep their values:

- **SPRxH, SPRxV, SPRxSTEP:** a value caught half written at a line's start gives at worst one wrong line.
- **SPRxPT:** the fetch moves it as the sprite runs, so a line that starts between its bytes can send the rest of the sprite to a mixed address. Write its three bytes while the sprite is stopped (in the vertical blank, before its CTL write), or all within one line (a copper `CMOVEA` takes three slots).

| Register | Takes effect |
|----------|--------------|
| SPRxCTL | On the write: starts the sprite. Its FIFO empties; its first line is the next line inside its window, from SPRxPT, with the new BPP, DEPTH and PAL |
| SPRxH, SPRxV, SPRxSTEP, SPRxPT | A running sprite: from the next line that starts after the write. A stopped sprite: when it is started |
| The vertical blank (beam line 0, pixel 0) | Stops every sprite until its CTL is written again |
| SPRDMA, DMACON.SPREN, DMACON.DMAEN | At once. Does not start or stop a sprite: off pauses its fetching (section 4.4) |
| SPRCOLL | At once |
| SPRPALETTE, VIDCON.SHAREPAL, PRIO | Spec 4's rules |

The copper's byte writes and the CPU's land in the order the register bus takes them, and the last write to each byte wins (spec 3, rule 3): let one of them own each sprite. Software and the copper see the display beam (spec 4), as in retro68k.

**Reusing a sprite further down the screen**, as Amiga programs do with their control words: after the sprite's last line, the copper WAITs, then writes the sprite's PT, window and STEP for its next use, and CTL last. For a last line E, a WAIT for (E + 1, 0) is enough. The CTL write then lands in line E + 1, so the new use can start on line E + 2 or later.

**The sprite sequencer** (spec 17) is another way to reuse sprites: a retro-z80 extra, outside this spec and the sprite unit. It reads a list of sprite uses from SRAM, sorted by start line, each 16 bytes laid out as a sprite's registers, and writes each into the lowest-numbered free sprite of those SEQMASK gives it, in the line after the old use's last line, CTL last. It follows exactly the rules of this section; the sprite hardware is unchanged, and the copper and CPU keep the sprites outside SEQMASK.

### 4.3 Underrun: SPRUNDER

If the fetch cannot keep a sprite's FIFO filled (section 5), the sprite **underruns**:

- **VIDSTAT.SPRUNDER** (spec 4) is set: sticky, cleared by writing 1, and with its enable in VIDINTEN it raises the **VIDERR** interrupt, as the layers' OVERRUN bits do;
- the sprite shows nothing more until its CTL is written again: its words would no longer line up with its lines.

An underrun means the screen asks too much of the memory at that point. Use fewer bits per pixel, scale a smaller image up across instead of a wider image, spread the sprites out, or put fewer layers' fetches under them.

### 4.4 DMA on and off

A sprite fetches only while its SPRDMA bit, DMACON.SPREN and DMACON.DMAEN are all set. SPRDMA acts at once and does not start or stop a sprite: off pauses its fetching (the sprite keeps what is in its FIFO), on lets it carry on, as in retro68k. There is no manual mode: nothing else fills the FIFO.

- While its DMA is off, a running sprite shows the words already in its FIFO (at most 32). When it needs a word and the FIFO is empty, it waits for it, transparent; it does not set SPRUNDER.
- Turned on again part way down the sprite, the fetch carries on where it stopped, so its words may no longer line up with its lines until its CTL is written again. Change SPRDMA in the vertical blank, or start the sprite again after it.
- To hide a sprite from the next line, set VSTART to 625 or more (section 4.2).

## 5. Memory budget

Sprites and layers share one budget, ordered by deadline (spec 2; retro68k spec 5, section 6). The display's own memory cycles (1 and 3 of each slot: 640 words per 320-slot line) give about **12 words per 16 screen pixels** for certain, as in retro68k. Cycles that others leave give more: cycle 4 when the copper and audio leave it, and the CPU's unused cycles.

- A **layer** needs, per 16 source pixels, b words at b bpp; at 2× across, half that per 16 screen pixels. A tile-map layer also fetches its map entries (spec 4 gives its cost).
- A **sprite** needs BPP words per 16 source pixels while the beam is over it (2, 4 or 8): BPP × XSTEP ÷ 2048 words per 16 screen pixels. Twice as big across (`0x0400`), half that; half size across (`0x1000`), twice.
- Sprites side by side do not add up; sprites over the same pixels at the same time do. Within a line, each FIFO (30 words ahead) lets a sprite fetch ahead into quieter stretches before its pixels, so short overlaps (up to about 60 pixels at 8 bpp, 240 at 2 bpp) are smoothed out; longer overlaps of wide sprites are limited by the budget at that moment, as the table shows. A sprite near the left of a line has less time to fetch ahead (as little as 16 pixels at HSTART 16).

Sprites stacked over the same 16 screen pixels, guaranteed (more when cycles are free):

| Layers | Words per 16 pixels | 8 bpp | 8 bpp, ×2 across | 4 bpp | 2 bpp |
|--------|--------------------|-------|------------------|-------|-------|
| None | 0 | 1 | 3 | 3 | 6 |
| Spectrum screen: 1 bpp at 2× and the attribute layer (spec 4) | About 1 | 1 | 2 | 2 | 5 |
| One 8 bpp layer at 2× | 4 | 1 | 2 | 2 | 4 |
| One 4 bpp tile layer at 1× (patterns 4, map entries 2) | About 6 | 0 | 1 | 1 | 3 |
| One 8 bpp layer at 1×, or two 4 bpp layers at 1× | 8 | 0 | 1 | 1 | 2 |
| Three 4 bpp layers at 1× | 12 | 0 | 0 | 0 | 0 |

These are worst cases: wide sprites stacked exactly on top of each other for longer than their lead. Typical game screens, with sprites spread out, do far better.

**The CPU's spare cycle.** The Z80 at 20 MHz makes at most one memory access in 1.5 slots (an M1 cycle is 4 T-states, a memory read or write 3), so at least one of its two cycles in every slot is spare (spec 2). Spare cycles go to the hard-deadline channels (layers and sprites) first, so in practice there are about 6 more words per 16 pixels than the table counts. The table leaves them out, as retro68k's leaves out its spare cycle 0s; to be measured (open point S1).

Sprite fetches never take a cycle the CPU is using, so sprites never slow the CPU. They can slow the copper at PRI 0 and the DMA engine, which come after them in the free order (spec 2, spec 6, spec 14).

## 6. Registers

Offsets in the custom block (spec 3). Port = (offset bits 7–0) << 8 | (`0x10` + offset bits 9–8): sprite registers at ports `0x1010`–`0x8F10`, the sprite globals at `0x2011`–`0x2711` (`LD BC,port`, `OUT (C),r`, `INC B` to the next byte; reads `LD A,reg` then `IN A,(page)`). The register page shows the custom block at `0x1000`–`0x13FF`: sprite registers at `0x1010`–`0x108F`, the globals at `0x1120`–`0x1127`. The copper writes sprite registers with one-word MOVEs (codes `0x10`–`0x8F`), and SPRDMA and SPRCOLL with MOVEF (spec 6).

Sprite n (0–7) at `0x010` + n × `0x10`:

| Offset | Name | Access | Bits | Description | Reset |
|--------|------|--------|------|-------------|-------|
| `+0x0` | SPRxPT0 | RW | 7–1 | SPRxPT bits 7–1; bit 0 ignored, reads 0 (lines are words) | 0 |
| `+0x1` | SPRxPT1 | RW | 7–0 | SPRxPT bits 15–8 | 0 |
| `+0x2` | SPRxPT2 | RW | 5–0 | SPRxPT bits 21–16. Bits 7–6 ignored; bit 5 ignored on a 2 MB board (spec 2) | 0 |
| `+0x3` | SPRxH0 | RW | 7–0 | HSTART bits 7–0 | 0 |
| `+0x4` | SPRxH1 | RW | 2–0 | HSTART bits 10–8 | 0 |
| `+0x5` | SPRxH2 | RW | 7–0 | HSTOP bits 7–0 | 0 |
| `+0x6` | SPRxH3 | RW | 2–0 | HSTOP bits 10–8 | 0 |
| `+0x7` | SPRxV0 | RW | 7–0 | VSTART bits 7–0 | 0 |
| `+0x8` | SPRxV1 | RW | 2–0 | VSTART bits 10–8 | 0 |
| `+0x9` | SPRxV2 | RW | 7–0 | VSTOP bits 7–0 | 0 |
| `+0xA` | SPRxV3 | RW | 2–0 | VSTOP bits 10–8 | 0 |
| `+0xB` | SPRxCTL | RW | 1–0, 3–2, 7–4 | BPP, DEPTH, PAL (section 3.3) | 0 |
| `+0xC` | SPRxSTEP0 | RW | 7–0 | XSTEP bits 7–0 | 0 |
| `+0xD` | SPRxSTEP1 | RW | 7–0 | XSTEP bits 15–8 | 0 |
| `+0xE` | SPRxSTEP2 | RW | 7–0 | YSTEP bits 7–0 | 0 |
| `+0xF` | SPRxSTEP3 | RW | 7–0 | YSTEP bits 15–8 | 0 |

- **When writes take effect:** a write to SPRxCTL (`+0xB`) starts the sprite (section 4.2). Writes to SPRxPT, SPRxH, SPRxV and SPRxSTEP act on a running sprite from the next line that starts after the write; a stopped sprite takes them when it is started. The vertical blank stops every sprite, so each frame write PT (and H, V and STEP as needed), then CTL last. Each byte is written directly; the others keep their values.
- Unused bits are written 0 and read 0.
- Reads give the value written. A write to SPRxPT sets where the sprite's next image line starts; a read gives the start of the image line being drawn, or the value just written, as retro68k. It changes by itself, so **reading SPRxPT0 captures all three bytes**, and SPRxPT1 and SPRxPT2 read the captured copy (spec 3, rule 4: one tagged capture for the CPU).

Sprite globals:

| Offset | Port | Name | Access | Bits | Description | Reset |
|--------|------|------|--------|------|-------------|-------|
| `0x120` | `0x2011` | SPRDMA0 | RW | 7–0 | SPR: DMA on for sprite n (bit n). Write: the bits SPRDMA1 acts on; they act only when SPRDMA1 is written. Read: the enables | `0xFF` |
| `0x121` | `0x2111` | SPRDMA1 | W | 7 | SETCLR (SPRDMA bit 15). **Writing it acts**, a trigger like a strobe: SETCLR = 1 sets the SPR bits written as 1 in SPRDMA0; SETCLR = 0 clears them. Others unchanged. Reads 0 | – |
| `0x122`–`0x123` | | – | – | – | Reserved (SPRDMA bits 31–16) | – |
| `0x124` | `0x2411` | SPRCOLL0 | R, W1C | 7–0 | SPR: sprite n touched another sprite (section 3.6) | 0 |
| `0x125` | `0x2511` | SPRCOLL1 | R, W1C | 7–0 | L0: sprite n touched layer 0 | 0 |
| `0x126` | `0x2611` | SPRCOLL2 | R, W1C | 7–0 | L1: sprite n touched layer 1 | 0 |
| `0x127` | `0x2711` | SPRCOLL3 | R, W1C | 7–0 | L2: sprite n touched layer 2 | 0 |
| `0x128`–`0x12F` | | – | – | – | Reserved: read `0xFF`, writes ignored (spec 3) | – |

- SPRCOLL's bytes are status bits: each byte is read and cleared on its own (spec 3).

Bits elsewhere:

| Register | Bit | Function |
|----------|-----|----------|
| DMACON (spec 4) | SPREN | Sprite DMA, with DMAEN |
| VIDSTAT (spec 4) | SPRUNDER | A sprite's FIFO ran dry. W1C |
| VIDINTEN (spec 4) | SPRUNDER | Raise VIDERR on SPRUNDER |
| VIDCON (spec 4) | SHAREPAL | Sprites use PALETTE0 |
| SPRPALETTE (spec 4) | – | The sprites' 256-entry palette |

**State after reset:** DMACON.SPREN is clear, SPRDMA has all eight sprites on, every sprite's PT, H, V, CTL and STEP are 0 (empty windows, nothing shows; STEP 0 counts as normal size), SPRCOLL is 0, the FIFOs are empty, and every sprite is stopped: none fetches until its CTL is written.

**Equates** (`hw.inc`, as retro68k's where the thing is the same):

| Equate | Value |
|--------|-------|
| `SPR0` … `SPR7` | `0x010`, `0x020` … `0x080` |
| `SPR_PT`, `SPR_H`, `SPR_V`, `SPR_CTL`, `SPR_STEP` | `0x0`, `0x3`, `0x7`, `0xB`, `0xC` |
| `SPR0_PT` … `SPR7_STEP` | Each register's full offset |
| `SPRDMA`, `SPRCOLL` | `0x120`, `0x124` |
| `SPR_CTL_BPP_B`, `SPR_CTL_DEPTH_B`, `SPR_CTL_PAL_B` | 0, 2, 4 (`_M` masks) |
| `SPR_STEP_XSTEP_B`, `SPR_STEP_YSTEP_B` | 0, 16 (bit numbers in the 32-bit value) |
| `SPRDMA_SETCLR_M`, `DMACON_SPREN_M`, `VIDSTAT_SPRUNDER_M` | The enables and status |
| `CPORT(off)` | The custom port of an offset: `((off & 0xFF) << 8) \| 0x10 \| (off >> 8)` |

## 7. Examples

sjasmplus syntax. `VID_X0` (144) and `VID_Y0` (49) are the picture's top left corner in beam coordinates. A 32 × 24 sprite at 4 bpp, in colours 32–47 (PAL 2), behind the front layer (DEPTH 1), on sprite 0 at picture pixel 200, line 100. The image is 24 lines of 16 bytes at physical address `ship`.

**Once, from the CPU, with ports.** PT, H, V and CTL are consecutive, so `INC B` walks through them, and CTL, which starts the sprite, comes last. STEP is left at 0 (normal size). Do it in the vertical blank:

```
X0      equ  VID_X0+200
Y0      equ  VID_Y0+100
        ld   bc,CPORT(SPR0+SPR_PT)
        ld   a,ship & 0xFF
        out  (c),a
        inc  b
        ld   a,0xFF & (ship >> 8)
        out  (c),a
        inc  b
        ld   a,ship >> 16
        out  (c),a           ; SPR0PT
        inc  b
        ld   hl,X0
        ld   de,X0+32
        out  (c),l           ; HSTART bits 7-0
        inc  b
        out  (c),h           ; HSTART bits 10-8
        inc  b
        out  (c),e           ; HSTOP bits 7-0
        inc  b
        out  (c),d           ; HSTOP bits 10-8
        inc  b
        ld   hl,Y0
        ld   de,Y0+24
        out  (c),l           ; VSTART
        inc  b
        out  (c),h
        inc  b
        out  (c),e           ; VSTOP
        inc  b
        out  (c),d
        inc  b
        ld   a,2<<SPR_CTL_PAL_B | 1<<SPR_CTL_DEPTH_B | 1<<SPR_CTL_BPP_B
        out  (c),a           ; SPR0CTL, last: PAL 2, DEPTH 1, 4 bpp; starts the sprite
```

The sprite shows in this frame only: the next vertical blank stops it. To show it every frame, write SPR0PT and SPR0CTL again in each vertical blank, or let the copper do it.

The same window through the register page, mapped into window 7 (`REGS` = `0xE000`; the custom block at `REGS + 0x1000`). `LD (nn),HL` writes the low byte first:

```
        ld   hl,X0
        ld   (REGS+0x1000+SPR0+SPR_H),hl     ; HSTART
        ld   hl,X0+32
        ld   (REGS+0x1000+SPR0+SPR_H+2),hl   ; HSTOP
```

**In the copper list**, every frame (in the vertical blank), the pointer and then CTL, which starts the sprite (`CMOVEA` writes a 3-byte register, spec 6):

```
SHIPCTL equ  2<<SPR_CTL_PAL_B | 1<<SPR_CTL_DEPTH_B | 1<<SPR_CTL_BPP_B
        CMOVEA  SPR0+SPR_PT,ship         ; 3 MOVEs
        CMOVE   SPR0+SPR_CTL,SHIPCTL     ; last: starts the sprite
```

Four words per sprite per frame. To move the ship, write SPR0H and SPR0V (from the CPU, or with copper MOVEs) before the CTL write; or, while it is drawn, at any time: each write acts from the next line.

**A wobble:** the copper moves sprite 0 two pixels further right on each of its lines (a list can step through a table of positions with MOVR, spec 6):

```
        CWAIT   VID_Y0+100,0
        CMOVEL  SPR0+SPR_H,((VID_X0+202+32)<<16)|(VID_X0+202)   ; for line 101
        CWAIT   VID_Y0+101,0
        CMOVEL  SPR0+SPR_H,((VID_X0+204+32)<<16)|(VID_X0+204)   ; for line 102
        ...
```

Six words a line. Here the high bytes of HSTART and HSTOP do not change, so writing only the two low bytes is enough: four words a line.

**The same ship at 1.5× its size:** a 48 × 36 window, and steps of 2048 ÷ 1.5 = `0x0555` across and down (the image is still 32 × 24: ⌈48 × `0x555` ÷ 2048⌉ = 32):

```
        CMOVEL  SPR0+SPR_H,((VID_X0+200+48)<<16)|(VID_X0+200)
        CMOVEL  SPR0+SPR_V,((VID_Y0+100+36)<<16)|(VID_Y0+100)
        CMOVEL  SPR0+SPR_STEP,($0555<<16)|$0555
        CMOVEA  SPR0+SPR_PT,ship
        CMOVE   SPR0+SPR_CTL,SHIPCTL                            ; last
```

**Reusing sprite 0** for a second ship from picture line 300: after the first ship's last line (picture line 123), the copper waits for line 124 and writes sprite 0 again, CTL last. The second use could start on line 125 or later:

```
        CWAIT   VID_Y0+124,0                                    ; ship 1 has been shown
        CMOVEL  SPR0+SPR_H,((VID_X0+432)<<16)|(VID_X0+400)
        CMOVEL  SPR0+SPR_V,((VID_Y0+324)<<16)|(VID_Y0+300)
        CMOVEA  SPR0+SPR_PT,ship2
        CMOVE   SPR0+SPR_CTL,SHIPCTL                            ; last: starts the second use
```

Fourteen words: 2 for the WAIT and 4 + 4 + 3 + 1 MOVEs. At the copper's PRI 1 rate (one word per slot, spec 6) the CTL write lands about 1.1 µs after the WAIT, in line 124's horizontal blank. Writing only the bytes that change is enough: each byte is written directly, and the others keep their values. CTL must be written even when its value does not change, since only that write starts the sprite.

**Collisions,** once a frame in the vertical blank:

```
        ld   bc,CPORT(SPRCOLL)
        in   a,(c)           ; sprite-sprite bits
        out  (c),a           ; clear exactly the bits read
        bit  0,a             ; sprite 0 hit another sprite?
        jr   nz,hit_sprite
        ld   b,0xFF & (SPRCOLL+2)   ; SPRCOLL2's register number
        in   a,(c)           ; against layer 1 (the walls)
        out  (c),a
        bit  0,a
        jr   nz,hit_wall
```

## 8. FPGA resources

The sprite RTL is retro68k's `sprites.v` and `sprite_pix.v`, with a byte register front end. retro68k's measured figures (Yosys, XC7A35T):

| Item | LUTs |
|------|------|
| `sprites.v`: registers, sizes, fetcher, deadlines, 8 FIFOs of 32 × 16 bits (distributed RAM) | About 2,000 |
| 8 pixel units (`sprite_pix.v`) | About 90 each, 730 in all |
| Mixing with the layers (depth), collisions | A few hundred |
| Byte register front end (byte writes, start on a CTL write, SPRxPT capture) | About 20 more |
| Total | About 3,000; no block RAM |

The per-sprite state lives in distributed RAM, worked on one sprite a clock, as in retro68k. The earlier draft's 4 RAMB18 for a row store are no longer needed.

## 9. Spectrum extras

None. The Spectrum had no sprites; the attribute layer does not act on them.

## 10. Test plan

- **Golden images:** sprites of many window sizes at 2, 4 and 8 bpp; many steps (bigger, smaller, odd steps, different across and down, the limits, step 0); PAL blocks; SHAREPAL; clipped at all four edges (HSTART 16, VSTART 1, HSTOP and VSTOP past the edges); every DEPTH against three layers in several PRIO orders, over transparent and opaque layer pixels; DEPTH first then number; direct colour; compared pixel by pixel with the Python video model extended with sprites (retro68k's model, narrowed).
- **Collisions:** known overlaps set exactly the expected SPRCOLL bits in all four bytes; none from clipped pixels, the blanking, or an underrun sprite; W1C clears only the bits written.
- **Pointer:** SPRxPT after the sprite's last line equals the image's start + the source lines moved on × line length, also with right clipping and YSTEP above and below `0x0800`; read mid-line it gives the start of the line being drawn; reading SPRxPT0 captures all three bytes.
- **Byte registers:** each byte of PT, H, V, CTL and STEP takes effect when written, whatever its order; only a CTL write starts the sprite; copper and CPU writes to the same sprite land in bus order; SPRDMA0 alone changes nothing; SPRDMA set and clear through SPRDMA1.
- **Starting:** a CTL write empties the FIFO, drops reads on their way, and the sprite's first line is the next line inside its window, showing the image line at SPRxPT; PT, H, V and STEP written in any order, then CTL, show the image from its first line at VSTART; a CTL write after VSTART has gone by shows the image from its first line on the next line, down to VSTOP; a CTL write with the same value starts it too.
- **Stopping:** the vertical blank stops every sprite, with its FIFO emptied; a sprite whose CTL is not written again shows nothing in the following frames and fetches nothing; a sprite whose VSTOP is past the frame's end stops at the vertical blank; writing PT and CTL in each vertical blank shows it every frame; nothing shows on beam line 0.
- **Changes while drawn:** a copper list moving a sprite across on every line, changing another's XSTEP and window on every line, switching an image part way down with a PT write (the next line starts exactly at the new PT, whatever YSTEP), moving a VSTOP earlier (the sprite ends) and later (it goes on), and moving a VSTART later (it is off until the window reaches it); each acts from the next line, without starting the sprite again; a byte of H, V or STEP caught half written spoils one line at most.
- **Fetch timing:** each line's words are fetched during that line, never in the line before; a sprite at HSTART 16 and one at the picture's left edge show their first pixels on time.
- **Reuse:** one sprite shown three times down the screen by the copper (retro68k's three ships), with PT, H, V and STEP then CTL written on line E + 1 and the new use from line E + 2.
- **DMA off:** SPRDMA cleared mid-sprite shows the FIFO's words, then waits, transparent, with no SPRUNDER; set again, the fetch carries on; SPRDMA never starts or stops a sprite.
- **Budget and underrun:** each row of section 5's table, with the CPU at 20 MHz running a memory-heavy loop: the sprites the table allows always show; a deliberate overload sets SPRUNDER, the sprite shows nothing more that frame, and VIDERR is raised with VIDINTEN.SPRUNDER set.
- **CPU never waits** with all eight sprites fetching (spec 2's test).
- **Measure** in simulation how many stacked sprites each layer set-up allows, with and without the CPU's spare cycles (open point S1).

## 11. Open points

| # | Item |
|---|------|
| S1 | Measure how many stacked sprites each layer set-up allows (section 5), in simulation, as retro68k's S1. Also measure how much the CPU's spare cycle adds at 20 MHz |
| S2 | Whether the sprites' share of the free cycles should be limited, so that a screen full of sprites cannot starve the copper at PRI 0 and the DMA engine (retro68k's S2, which worries about its CPU instead) |
| S3 | Closed: HSTART is unsigned, as retro68k's RTL and guide; retro68k's register table, which says "signed", should be corrected. All four window positions are unsigned 11-bit beam positions (10–0, 26–16). A sprite can still hang up to 128 pixels off the left edge (HSTART 16 or more), since the picture starts at beam pixel 144 |
| S4 | Closed: PRI tile pixels go in front of DEPTH 1–3 sprites and behind DEPTH 0 (spec 4, section 4.8) |
| S5 | Closed: as retro68k's spec 9 (section 3, "Which image line", and section 6) and its `sprites.v`, a write to SPRxPT sets where the next image line starts, and a read gives the start of the image line being drawn, or the value just written (confirmed with retro68k, 25 October 2026) |
| S6 | Closed: as retro68k, SPRDMA pauses a sprite without starting or stopping it; the sprite shows the words left in its FIFO, then waits, transparent (section 4.4). To hide it, set VSTART to 625 or more |
| S7 | Closed: manual mode (SPRxDAT) dropped (branch 11), so 16 bytes per sprite |
| S8 | Closed: the earlier draft's row store, 512-byte limit, exact L + 2 write rule, line-0 rule and budget B = 224 − D − C are replaced by retro68k's FIFOs and rules (branch 11) |
| S9 | Closed: SPRDMA (set/clear, SETCLR in its high byte) and SPRCOLL (separate W1C bytes) are listed in spec 3 |
| S10 | Closed (design plan, branch 11, and retro68k's rewritten spec 9): a sprite starts only when its SPRxCTL is written, and nothing restarts at the frame start. PT, H, V and STEP act on a running sprite from the next line. This replaces the DMA-off workaround (section 4.2) |
| S11 | Closed: the vertical blank stops every sprite (section 4.2), so a CTL write after the window's last line in a frame shows nothing; the sprite is stopped at the next vertical blank and stays off until its CTL is written again |
| S12 | Closed: the spec now says what was built and what retro68k's spec says: a read of SPRxPT gives the start of the image line being drawn (S5) |
| S13 | As built (ticket #31): the sprites' urgent mark is one deadline unit (8 clocks) earlier than retro68k's, as an urgent sprite fetch waits for a cycle the CPU is not using (spec 2; bpldma.v moves the layers' mark the same way). No SPRUNDER in the quick sprite screen; measure with S1 |
