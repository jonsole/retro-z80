# Spec 17: Sprite sequencer

Status: **draft**

The sprite sequencer reuses the 8 sprites down the screen without a copper list. Software keeps a list of sprite uses in SRAM, sorted by start line. Each frame a small register bus master reads the list and writes each entry into a free sprite's registers, in the line before the entry's first line, CTL last. The sprite hardware is unchanged (spec 5): the sequencer writes the same registers the copper and the CPU write, so the three can be mixed.

It is a retro-z80 extra (design plan, branch 14). retro68k has no sequencer; a sprite table is on its sprites spec's "later" list. It is designed so that retro68k can copy it as it is: a register bus master and a memory channel, outside the sprite unit.

## 1. Summary

| Item | Value |
|------|-------|
| What it does | Takes sprite uses from a list in SRAM and gives each to a free sprite, so 8 sprites can show many objects down the screen |
| List | Entries of 16 bytes, each a sprite's registers exactly as the custom block lays them out: PT (3), H (4), V (4), CTL (1), STEP (4). Sorted by VSTART by software. An entry with VSTART `0x7FF` ends the list (section 3) |
| Start of the list | SEQLC (3 bytes), reloaded at every frame start, as COP1LC is (section 4.1) |
| Sprites | SEQMASK: one bit per sprite the sequencer may use. The others stay with the copper and the CPU (section 6) |
| Allocation | Each entry goes to the **lowest-numbered free sprite** in SEQMASK. A sprite is free when it has not been started this frame, or its window has ended (VSTOP passed) (section 4.2) |
| When | In the **gap line**: a line after the sprite's old use has ended and before the entry's first line. All 16 writes land between beam pixels 16 and 836 of that line (section 5) |
| Write order | H, V, STEP, PT, then CTL last, which starts the sprite (spec 5, section 4.2) |
| Gap rule | A sprite can take a new entry whose VSTART is at least its old VSTOP + 1 (section 5.1) |
| Skips | An entry whose start line comes with no sprite free is skipped for that frame: SEQSTAT.SKIP (sticky) and a count, SEQSKIP. Optional interrupt through VIDERR (section 4.4) |
| Register bus | A fourth master, after the copper and the CPU, before the DMA engine: it never delays the CPU or the copper. 16 byte writes per entry, at most 40 clocks (section 5.3) |
| Memory | Its own channel in the scheduler: 8 word reads per entry, from the free pool, after the hard-deadline channels and audio and before the copper at PRI 0 (section 5.4) |
| Registers | Custom offsets `0x300`–`0x30F`, in a copper MOVEF's reach (section 8) |
| Enable | SEQCON.EN, with DMACON.SPREN and DMACON.DMAEN |
| FPGA | About 300 LUTs and 300 flip-flops; no block RAM (section 10) |

## 2. Comparison

### 2.1 With retro68k

| Item | retro68k | retro-z80 | Why |
|------|----------|-----------|-----|
| Sprite reuse | The copper rewrites a sprite after its last line (its spec 9, section 3) | The same, and also the sequencer | Design plan, branch 14 |
| Sprite table | On the "later" list of its spec 9 (section 11): "a sprite table, so that the copper need not rewrite sprites to reuse them" | This spec | A Z80 has little time to spare for building copper lists |
| Sprite unit | `sprites.v` (main `bf91e97`) | The same, copied (spec 5); the sequencer changes nothing in it | The sequencer only writes registers |

If retro68k takes the sequencer, the design carries over unchanged: a register bus master that writes a sprite's registers from a list, in its own memory channel. Only two things follow each machine's sprite block: an entry is that machine's sprite register bytes (retro68k: PT, H, V, CTL and STEP, without DAT), and the registers are that machine's width.

### 2.2 With copper reuse

| Item | Copper (spec 5, section 4.2; spec 6, section 8.4) | Sequencer |
|------|----------------------------------------------------|-----------|
| Who picks the sprite | Software, when it builds the list | The hardware: the lowest-numbered free sprite |
| Words per reuse | 14 list words (a WAIT and 12 MOVEs), at the right place in a list sorted by line | 8 words (16 bytes) per entry, in a list sorted by line |
| What software builds each frame | WAITs and MOVEs, with a sprite chosen for each use and a WAIT after each old use's last line | The 16 register bytes of each use, in order of VSTART |
| Too many objects on some lines | Software must notice and leave some out | The hardware skips the entry and counts it |
| Per-line effects (wobble, zoom, image switch) | Yes | No: one set of registers per use. Mix with the copper for these (section 6) |

## 3. The list

The list is in SRAM, at a physical address (spec 2, section 9.3): even, since it is read in words. SEQLC points at its first entry. Each entry is 16 bytes, the next straight after it:

| Bytes | Register | Meaning |
|-------|----------|---------|
| 0–2 | SPRxPT | The image's first line (spec 5, section 3) |
| 3–6 | SPRxH | HSTART, HSTOP |
| 7–10 | SPRxV | VSTART, VSTOP. VSTART is the entry's **start line**, the key the list is sorted by |
| 11 | SPRxCTL | BPP, DEPTH, PAL |
| 12–15 | SPRxSTEP | XSTEP, YSTEP |

The bytes are exactly sprite n's 16 registers (custom `0x010` + n × `0x10`), in the same order, with the same fields and the same rules (spec 5, section 6). An entry is a picture of a sprite's registers, so one routine can write either.

- **The end entry** has VSTART `0x7FF` (`SEQ_END`): byte 7 = `0xFF`, byte 8 = `0x07`. The sequencer reads it as a whole entry, but uses nothing else in it. A list with no uses is just an end entry.
- **Sorted** by VSTART, smallest first. Entries with the same VSTART may be in any order; they are taken in list order.
- **Unsorted lists** are not an error. Entries are always taken in list order. An entry whose start line has already passed when the sequencer comes to it is skipped and counted (section 4.4). An entry that starts later than the ones after it holds them back until it is placed.
- **Entries the sprite would not show** (an empty window, VSTART 625 or more but not `0x7FF`) are placed like any other: they take a sprite and show nothing.
- **HSTART must be 16 or more**, as for any sprite (spec 5, section 3.2). The sequencer does not check.
- **Cost:** 16 bytes, 8 memory reads, per entry, and 8 for the end entry. 20 uses cost 168 reads a frame.
- **Double buffering:** the sequencer reads the list during the frame, so software builds next frame's list in a second buffer and writes its address to SEQLC. The sequencer takes SEQLC only at the frame start (section 4.1), so writing SEQLC during the frame is safe, but not across the frame start: a frame start between its bytes would take a mixed address. Write it in the main loop after the VBLANK interrupt, as for COP1LC (spec 6, section 6.3).

## 4. How it works

### 4.1 The frame

- **The frame start** (beam line 0, pixel 0, the start of the vertical blank) stops every sprite (spec 5, section 4.2). With SEQCON.EN, DMACON.SPREN and DMACON.DMAEN all set, the sequencer then loads its pointer, SEQPT, from SEQLC, drops any entry it holds, copies SEQSKIP to SEQSKIPL, clears SEQSKIP and SEQSTAT.END, sets SEQSTAT.RUN, and starts reading the list.
- **Entries for the first lines** are placed in line 0 and the lines after it. The first line a sprite can show is line 1 (spec 5, section 3.2); lines 1–48 are fetched but not shown, so a sprite that starts above the picture is clipped at the top as usual.
- **The end entry** stops the sequencer for the frame: SEQSTAT.END is set and RUN cleared. It reads nothing more until the next frame start.
- Entries not yet reached when the frame ends are neither placed nor counted.

### 4.2 Free sprites

Sprite n is **free** in beam line G when:

1. SEQMASK bit n is set; and
2. either it has not been started this frame (no write to its SPRxCTL, by any master, since the frame start), or its window has ended: G ≥ its VSTOP.

The sequencer keeps what it needs to see this: a "started" bit for each sprite and a copy of each sprite's VSTOP. It sets them from its own writes and also from every other master's writes on the register bus: a CTL write by the copper, the CPU or the DMA engine sets the started bit, and a write to SPRxV2 or SPRxV3 changes the copy, byte by byte. So the sequencer always sees the sprite's live VSTOP. The frame start clears the started bits.

A sprite with VSTOP above 624 never ends in its frame, and is free again only at the next frame start.

### 4.3 Placing an entry

The sequencer holds one entry, the **head**: the next entry of the list, read whole into a 16-byte buffer. In each line G, from beam pixel 16:

1. If the head is the end entry, the sequencer stops (section 4.1).
2. If the head's VSTART is G or less, its first line can no longer be met: the head is **skipped** (section 4.4).
3. Otherwise, if a sprite is free and the beam is not past pixel 815, the head goes to the **lowest-numbered free sprite**: its 16 bytes are written to that sprite's registers in this order, each register low byte first:

   | Order | Bytes | Register |
   |-------|-------|----------|
   | 1 | 3–6 | SPRxH |
   | 2 | 7–10 | SPRxV |
   | 3 | 12–15 | SPRxSTEP |
   | 4 | 0–2 | SPRxPT |
   | 5 | 11 | SPRxCTL, last: it starts the sprite |

   The CTL write starts the sprite (spec 5, section 4.2): its first line is the next line inside its window, VSTART, from the image's first line at PT. The sprite is now busy until its VSTOP.
4. Otherwise (no sprite free, or too late in the line), the head waits for the next line.

After a skip or a placement, the sequencer reads the next entry into the buffer and goes back to step 1, in the same line if there is time. So several entries can be placed in one line, one sprite each.

The sequencer places an entry as soon as a sprite is free, which may be many lines before its VSTART. That costs nothing: every later entry starts at or below this one, so it could not have used the sprite before this use ends anyway. On a sorted list the sequencer needs no more sprites than the most uses that overlap on any line, counting each use from the line before its VSTART (its gap line) to its VSTOP. A sorted list never has a skip while, on every line L, the entries with VSTART − 1 ≤ L < VSTOP are no more than the sprites in SEQMASK, and the sequencer's reads keep up (section 5.4).

### 4.4 Skips

An entry is **skipped** when its start line comes before it could be placed: no sprite in SEQMASK was free in time, its words were not read in time (section 5.4), or (in an unsorted list) its start line had already passed. A skipped entry is not shown this frame. The sequencer:

- sets **SEQSTAT.SKIP**, sticky until cleared by writing 1;
- adds 1 to **SEQSKIP**, the skips so far this frame (it stops at 255). At the frame start SEQSKIP is copied to **SEQSKIPL**, the count for the frame just ended, and cleared;
- raises **VIDERR** (interrupt source 3, spec 8) while SEQSTAT.SKIP and SEQCON.IRQEN are both set. VIDSTAT has no free bit, so the flag and its enable are the sequencer's own, as COPSTAT.IRQ and COPCON.IRQEN are the copper's.

A skip is a sign that the screen asks for more sprites on some lines than SEQMASK gives. A game can thin out a wave, spread objects down the screen, or rotate which object on a crowded line comes first in the list, so a different one drops out each frame (flicker instead of a missing object).

### 4.5 Turning it on and off

- **On:** set SEQCON.EN (with DMACON.SPREN and DMACON.DMAEN). The sequencer starts at the next frame start, never part way through a frame.
- **Off:** clearing SEQCON.EN, DMACON.SPREN or DMACON.DMAEN stops it after the entry it is writing, if any: it never leaves an entry half written. Sprites it has started run on until the frame start. Setting them again starts it at the next frame start.
- **SEQMASK** acts at once for the next entry to be placed. A sprite taken out of SEQMASK keeps its current use; a sprite added is free as section 4.2 says.

## 5. Timing

### 5.1 The gap line

The rules come from the sprite unit as built in retro68k (main `bf91e97`, `sprites.v`; spec 5, section 4.2):

| Beam position | What the sprite unit does | So the sequencer |
|---------------|---------------------------|------------------|
| Line 0, pixel 0 | The vertical blank stops every sprite | Starts its frame here, and writes nothing before pixel 16 |
| Pixel 0 of every other line | The line-start pass: each running sprite checks whether the line is in its window (decided by pixel 12) | Writes no sprite register in pixels 0–15 of any line |
| Pixels 840–847 of line L − 1 | The line sizes for line L are worked out from H, V and STEP and frozen | Has all writes for line L done by pixel 836 of line L − 1 |
| A CTL write | Starts the sprite at once: its FIFO is emptied, and the rest of a line being drawn is lost | Never writes CTL while the sprite's old use is on its last line |

So a sprite whose old use has VSTOP = E + 1 (last line E) can be written in line E + 1 or later, the **gap line**, and its new use can start on the line after the gap line or later: **new VSTART ≥ old VSTOP + 1**. This is the same rule as the copper's reuse (spec 5, section 4.2: a WAIT for line E + 1, then the writes, then a new use from line E + 2).

The sequencer places entries only in pixels 16–815 of a line (it starts an entry's writes no later than pixel 815). The 16 writes then land by pixel 826 at worst (section 5.3), before the freeze at 840. So an entry placed in line G shows from its VSTART if VSTART ≥ G + 1.

### 5.2 How many in a line

Each entry takes its 16 writes (at most 40 clocks, 11 beam pixels) and, unless it is already in the buffer, 8 words read (section 5.4). In one line's placing time (800 beam pixels, 29.6 µs) there is room for all 8 sprites many times over, so every free sprite can take an entry in the same gap line.

### 5.3 The register bus

The sequencer is the third of four masters on the register bus (spec 3, section 3.2; spec 1, section 4.2). In each clock the first that wants the bus gets it:

| Order | Master | |
|-------|--------|-|
| 1 | Copper | At most one write every 2 clocks |
| 2 | CPU | At most one access every 15 clocks (a register page access is 3 T-states at 20 MHz; an I/O cycle 4) |
| 3 | **Sprite sequencer** | Writes only: 16 byte writes per entry, no reads |
| 4 | DMA engine | Waits for the other three |

- The sequencer never delays the copper or the CPU, so the copper's writes still land on their pixel and the CPU's strobe still moves at most one clock (spec 1).
- In any 40 clocks the copper takes at most 20 and the CPU at most 3, so the sequencer gets at least 17: an entry's 16 writes take 16–40 clocks (0.16–0.4 µs, 4–11 beam pixels).
- Writes are direct, with no latch (spec 3, rule 2), so the sequencer needs no buffer of its own beyond the entry. It writes 16 bytes because a whole entry is written; there is no shorter form.

### 5.4 Memory cycles

The sequencer has its own channel in the scheduler (spec 2, section 5). It reads the list one 16-bit word per memory cycle, 8 words per entry, into its buffer, and asks for a cycle only while the buffer is not full. Its place in the free order:

> the copper at PRI 1; the hard-deadline channels (layers, sprites); audio; **the sprite sequencer**; the copper at PRI 0; the DMA engine; the DMA port.

- It never takes a cycle the CPU uses (spec 2, rule 0), and an urgent display fetch goes first, so it never spoils the picture or slows the CPU.
- It goes before the copper at PRI 0, since its reads have a deadline (the gap line) and are few: at most 8 words per sprite reused, against at least 747 free-pool cycles per line (spec 2).
- The next entry is read as soon as the last one is placed or skipped, usually many lines before it is needed. Reads become tight only when several sprites are reused in the same line, each needing its 8 words in turn.
- Its words are not certain, as the copper's at PRI 0 are not: a copper burst at PRI 1 or a screen over its display budget can hold them up. An entry not read in time is skipped and counted (section 4.4), so the failure shows. To be measured (open point SQ2).
- DMACON.SPREN and DMACON.DMAEN turn it off with the sprites; it has no DMACON bit of its own.

## 6. Sharing the sprites with the copper and the CPU

SEQMASK says which sprites the sequencer may use. The others are the copper's and the CPU's, exactly as spec 5 describes; the sequencer never writes them.

- **Sprites outside SEQMASK** can do anything spec 5 allows: a player sprite written by the CPU each frame, a copper list that reuses a sprite or makes it wobble. The sequencer sees their CTL and VSTOP writes, but uses that only if the sprite is later added to SEQMASK.
- **Handing sprites over during a frame:** the copper can write SEQMASK with MOVEF, so a sprite can be the copper's in one part of the screen and the sequencer's in another (section 9.2). A sprite added to SEQMASK is free only once its current use has ended, so a copper use is never cut short.
- **Writes to a sequencer sprite** by the copper, the CPU or the DMA engine are allowed and land as on any sprite (spec 3, rule 3), but they act on whichever use has the sprite at that moment, which the program does not choose:
  - a write to H, STEP or PT changes that use from the next line (spec 5, section 4.2);
  - a CTL write starts the sprite again from its PT, and marks it started;
  - a VSTOP write changes when the sequencer sees the sprite as free: earlier frees it sooner, later keeps it longer;
  - the sequencer's next entry for that sprite overwrites all 16 bytes.

  Use this only where the program knows which sprite has which entry. Per-line effects on sequencer sprites are not supported; give such objects a sprite outside SEQMASK.
- **Bus order:** when the copper or CPU and the sequencer write the same sprite in the same line, their bytes land in bus order and the last write to each byte wins (spec 3, rule 3). Writing a sprite in SEQMASK while the sequencer may be writing it can mix two uses for a line.

## 7. Depth, overlap and collisions

The sequencer chooses the sprite number, and the number decides some things the program may care about:

- **Front and back.** Sprites are ordered by DEPTH first, then number: at the same DEPTH the lower number is in front (spec 5, section 3.5). With automatic allocation, which of two overlapping objects at the same DEPTH is in front depends on which sprites were free when each was placed, and can change from frame to frame as objects move. If it matters, give the objects different DEPTHs, or put the one that must be in front on a sprite outside SEQMASK with a lower number (the player on sprite 0 is in front of every sequencer sprite at its DEPTH).
- **DEPTH is per entry**, as CTL is: an entry carries its own DEPTH, PAL and BPP, so objects keep their place among the layers whatever sprite they get.
- **Collisions.** SPRCOLL has a bit per sprite number, not per object (spec 5, section 3.6), and the sequencer does not report which entry went to which sprite. A set bit says some use of that sprite touched something this frame. Keep objects whose collisions matter on sprites outside SEQMASK (SPRCOLL0 bit 0 then says "the player touched a sprite"), and check which enemy by its box in software.
- **Memory budget.** Allocation does not look at the budget: uses side by side on one line add up as spec 5, section 5 says. Too many wide sprites on a line underrun (SPRUNDER), whoever placed them.

## 8. Registers

Custom offsets `0x300`–`0x30F`. The CPU reaches them on ports, port = (offset bits 7–0) << 8 | (`0x10` + offset bits 9–8) (spec 3): page `0x13`, `LD BC,port` then `OUT (C),r`, or `LD A,reg` then `IN A,(0x13)`. In the register page they are at `0x1000` + offset (`0x1300`–`0x130F`). The copper writes them with MOVEF. Multi-byte values: low byte at the lowest offset, each byte written directly.

| Offset | Port | Name | Access | Bits | Description | Reset |
|--------|------|------|--------|------|-------------|-------|
| `0x300` | `0x0013` | SEQCON | RW | EN (0), IRQEN (1); 7–2 reserved | Sequencer on from the next frame start (with DMACON.SPREN and DMAEN); SEQSTAT.SKIP raises VIDERR | 0 |
| `0x301`–`0x303` | `0x0113`–`0x0313` | SEQLC | RW | 21–1; bit 0 ignored, reads 0 | Physical address of the list. Taken at every frame start | 0 |
| `0x304` | `0x0413` | SEQMASK | RW | SPR (7–0) | Sprite n may be used by the sequencer (bit n). Acts at once | 0 |
| `0x305` | `0x0513` | SEQSTAT | R, W1C | SKIP (0), END (1), RUN (2); 7–3 reserved | Bit 0 sticky, write 1 to clear. Bits 1–2 live, read only (section 8.1) | 0 |
| `0x306` | `0x0613` | SEQSKIP | R | COUNT (7–0) | Entries skipped so far this frame; stops at 255; cleared at the frame start | 0 |
| `0x307` | `0x0713` | SEQSKIPL | R | COUNT (7–0) | Entries skipped in the last whole frame (SEQSKIP at the frame start) | 0 |
| `0x308`–`0x30A` | `0x0813`–`0x0A13` | SEQPT | R | 21–1 | The address of the next entry to read; at the end, the end entry's. Reading `0x308` captures all three bytes | 0 |
| `0x30B`–`0x30F` | | – | | | Reserved: read `0xFF`, writes ignored (spec 3) | |

SEQPT changes by itself, so reading SEQPT0 captures it (spec 3, rule 4: the master's one tagged capture). SEQSKIP is one byte and needs no capture.

### 8.1 Status bits

| Bit | Meaning |
|-----|---------|
| SKIP | An entry was skipped (section 4.4). Sticky; write 1 to clear. With SEQCON.IRQEN it raises VIDERR |
| END | The end entry has been reached this frame. Cleared at the frame start |
| RUN | The sequencer is working through this frame's list: set at the frame start when it is on, cleared at the end entry or when it is turned off |

**Interrupt.** VIDERR (source 3, IM 2 vector VECBASE + 6, spec 8) is requested while any of the video error flags and their VIDINTEN bits are set (spec 4, section 3.4), or SEQSTAT.SKIP and SEQCON.IRQEN are. The handler reads VIDSTAT and SEQSTAT to see which, and clears the flag by writing 1 to it.

**Equates** (`hw.inc`, from `fpga/regmap.def`): `SEQCON` = `0x300`, `SEQLC` = `0x301`, `SEQMASK` = `0x304`, `SEQSTAT` = `0x305`, `SEQSKIP` = `0x306`, `SEQSKIPL` = `0x307`, `SEQPT` = `0x308`, their ports (`SEQCON_P` = `0x13`) and fields (`SEQCON_EN_M`, `SEQSTAT_SKIP_M` …), `SEQ_END` = `0x7FF` and `SEQ_ENTRY` = `16`, the bytes per entry. The offsets within an entry are the sprite's: `SPR_PT`, `SPR_H`, `SPR_V`, `SPR_CTL`, `SPR_STEP` (spec 5, section 6).

**State after reset:** SEQCON, SEQLC, SEQMASK, SEQSTAT, the counts and SEQPT are 0: the sequencer is off and may use no sprite.

## 9. Examples

sjasmplus syntax, with `hw.inc`.

### 9.1 Twenty enemies on sprites 1–7

A game has a player and 20 enemies, each 16 × 16 at 4 bpp, normal size. The player is sprite 0, written by the CPU in the VBLANK handler, so it is always in front of the enemies at its DEPTH and SPRCOLL0 bit 0 tells when it touches one. The enemies share sprites 1–7 through the sequencer.

Each enemy use takes 17 lines: its 16 and the gap line before it. So as long as no 17 lines hold the starts of more than 7 enemies, none is skipped.

The game keeps a table of enemies and a table of 20 sort records (VSTART, enemy number), which starts as enemies 0–19 in any order. Each frame it refreshes the records' VSTARTs, sorts them (an insertion sort: enemies move a little each frame, so the records are nearly sorted already) and writes the list into the buffer the sequencer is not reading. The two lists are in SRAM page `0x011`, shown in window 5:

```
NENEMY  equ  20
EX      equ  0                   ; an enemy: HSTART, beam pixel (2 bytes; 16 or more)
EY      equ  2                   ; VSTART, beam line (2 bytes)
EIMG    equ  4                   ; its image, physical address (3 bytes)
ECTL    equ  7                   ; its SPRxCTL: BPP, DEPTH, PAL
ESIZE   equ  8
LISTPG  equ  0x011               ; SRAM page of the lists (physical 0x022000) ...
LIST0   equ  0xA000              ; ... shown in window 5
LIST1   equ  0xA200              ; two lists of up to 31 entries

; Once: sprites 1-7 for the sequencer, sprite 0 kept for the player
seq_init:
        ld   hl,LIST0
        ld   (front),hl
        ld   hl,LIST1
        ld   (back),hl
        ld   hl,LIST0
        call seq_build           ; a first list
        ld   hl,LIST0
        call seq_point
        ld   bc,SEQMASK_P
        ld   a,0xFE              ; sprites 1-7
        out  (c),a
        ld   bc,DMACON_P
        ld   a,DMACON_SETCLR_M | DMACON_DMAEN_M | DMACON_SPREN_M
        out  (c),a
        ld   bc,SEQCON_P
        ld   a,SEQCON_EN_M       ; from the next frame start
        out  (c),a
        ret

; Each frame, after the VBLANK interrupt
frame:  call move_enemies        ; the game: new EX and EY for each enemy
        call seq_keys            ; each record's VSTART, from its enemy
        call seq_sort            ; sort the records by VSTART
        ld   hl,(back)
        call seq_build           ; the list, into the buffer not being read
        ld   hl,(back)
        call seq_point           ; the sequencer takes it at the next frame start
        ld   hl,(back)
        ld   de,(front)
        ld   (front),hl
        ld   (back),de
        ret

; SEQLC = the physical address of the list at HL (window 5)
seq_point:
        ld   a,h
        and  0x1F
        or   (LISTPG & 7) << 5   ; page bits 2-0 are address bits 15-13
        ld   h,a
        ld   bc,SEQLC_P
        out  (c),l               ; bits 7-0
        inc  b
        out  (c),h               ; bits 15-8
        inc  b
        ld   a,LISTPG >> 3       ; bits 21-16
        out  (c),a
        ret

; keys: NENEMY records of 3 bytes: VSTART (2 bytes), enemy number
seq_keys:
        ld   hl,keys
        ld   b,NENEMY
.next:  push hl
        inc  hl
        inc  hl
        ld   a,(hl)              ; the record's enemy
        call enemy_ix
        pop  hl
        ld   a,(ix+EY)
        ld   (hl),a
        inc  hl
        ld   a,(ix+EY+1)
        ld   (hl),a
        inc  hl
        inc  hl
        djnz .next
        ret

; Insertion sort of the records by VSTART
seq_sort:
        ld   ix,keys+3           ; record 1
        ld   b,NENEMY-1
.outer: ld   e,(ix+0)            ; DE = its VSTART, C = its enemy
        ld   d,(ix+1)
        ld   c,(ix+2)
        push ix
.inner: push ix
        pop  hl
        ld   a,l
        cp   keys & 0xFF
        jr   nz,.cmp
        ld   a,h
        cp   keys >> 8
        jr   z,.place            ; at record 0
.cmp:   ld   l,(ix-3)            ; HL = the record before
        ld   h,(ix-2)
        or   a
        sbc  hl,de
        jr   c,.place            ; it starts sooner: stop here
        jr   z,.place            ; the same line: keep the order
        ld   a,(ix-3)            ; move it up one place
        ld   (ix+0),a
        ld   a,(ix-2)
        ld   (ix+1),a
        ld   a,(ix-1)
        ld   (ix+2),a
        dec  ix
        dec  ix
        dec  ix
        jr   .inner
.place: ld   (ix+0),e
        ld   (ix+1),d
        ld   (ix+2),c
        pop  ix
        inc  ix
        inc  ix
        inc  ix
        djnz .outer
        ret

; The list at HL: one 16-byte entry per record, as a sprite's registers,
; then the end entry
seq_build:
        ld   iy,keys+2           ; IY = the record's enemy number
        ld   b,NENEMY
.entry: push bc
        push hl
        ld   a,(iy+0)
        call enemy_ix            ; IX = the enemy
        pop  hl
        ld   a,(ix+EIMG)         ; PT (+0): the image
        ld   (hl),a
        inc  hl
        ld   a,(ix+EIMG+1)
        ld   (hl),a
        inc  hl
        ld   a,(ix+EIMG+2)
        ld   (hl),a
        inc  hl
        ld   e,(ix+EX)
        ld   d,(ix+EX+1)
        call put_pair            ; H (+3): HSTART, HSTOP = HSTART + 16
        ld   e,(ix+EY)
        ld   d,(ix+EY+1)
        call put_pair            ; V (+7): VSTART, VSTOP = VSTART + 16
        ld   a,(ix+ECTL)
        ld   (hl),a              ; CTL (+11)
        inc  hl
        xor  a
        ld   (hl),a              ; STEP (+12): 0, normal size
        inc  hl
        ld   (hl),a
        inc  hl
        ld   (hl),a
        inc  hl
        ld   (hl),a
        inc  hl
        inc  iy
        inc  iy
        inc  iy
        pop  bc
        djnz .entry
        ld   bc,SPR_V            ; the end entry: only its VSTART is used
        add  hl,bc
        ld   (hl),SEQ_END & 0xFF
        inc  hl
        ld   (hl),SEQ_END >> 8
        ret

put_pair:                        ; DE, then DE + 16, low bytes first, at HL
        ld   (hl),e
        inc  hl
        ld   (hl),d
        inc  hl
        ex   de,hl
        ld   bc,16
        add  hl,bc
        ex   de,hl
        ld   (hl),e
        inc  hl
        ld   (hl),d
        inc  hl
        ret

enemy_ix:                        ; IX = enemy A; uses DE and HL
        ld   l,a
        ld   h,0
        add  hl,hl
        add  hl,hl
        add  hl,hl               ; A x ESIZE
        ld   de,enemies
        add  hl,de
        push hl
        pop  ix
        ret
```

In the VBLANK handler the CPU starts the player's sprite, which is outside SEQMASK, and looks at the frame just shown:

```
vblank_seq:
        ld   hl,player           ; PT, H, V and CTL, laid out as sprite 0's registers
        ld   bc,SPR0_PT_P
        ld   d,12
.byte:  ld   a,(hl)
        out  (c),a
        inc  hl
        inc  b                   ; the next register
        dec  d
        jr   nz,.byte            ; CTL, the last, starts the sprite
        ld   bc,SEQSKIPL_P
        in   a,(c)               ; entries dropped in the frame just shown
        or   a
        call nz,too_many         ; the game's choice: thin out the wave
        ret
```

The list costs 21 × 8 = 168 memory reads a frame. The CPU's work is the sort and about 150 T-states per entry to build it: well under a millisecond at 20 MHz. A copper list doing the same would need 14 words per reuse and the sprite for each use chosen by software.

### 9.2 Sprites shared with a copper panel

A score panel at the top of the picture (beam lines 49–80) uses sprites 4–7, written by the copper. Below it, all of sprites 1–7 go to the sequencer. The copper narrows SEQMASK for the top of the next frame at the end of this one, so the sequencer cannot take sprites 4–7 at the frame start before the copper has started them:

```
        ...                              ; frame start: the panel's sprites 4-7, CTL last (spec 6, section 8.4)
        CWAIT   81,0                     ; the panel's uses end at line 80 (VSTOP 81)
        CMOVEF  SEQMASK,0xFE             ; sprites 1-7 for the sequencer from here
        CWAIT   624,0
        CMOVEF  SEQMASK,0x0E             ; sprites 1-3 only, for the next frame's top
        CSTOP
```

Line 81 is the gap line for sprites 4–7, so sequencer entries from VSTART 82 can use them. Entries above that have only sprites 1–3.

## 10. FPGA resources

| Item | Estimate |
|------|----------|
| Entry buffer (16 bytes), list pointer (21 bits) and its adder, SEQLC | About 60 LUTs (the buffer in distributed RAM), 50 flip-flops |
| Each sprite's started bit and VSTOP copy (8 × 12 bits), with the register bus snoop | About 30 LUTs, 100 flip-flops |
| Free test (8 compares of VSTOP with the line), lowest-free picker | About 70 LUTs |
| Head checks: end entry, VSTART against the line; the placing window (pixels 16–815) | About 30 LUTs |
| Register bus master: the 16-write sequence (sprite base + byte order) | About 40 LUTs, 10 flip-flops |
| Memory channel in the scheduler | About 20 LUTs |
| Control and status registers, the counts, SEQPT capture | About 50 LUTs, 60 flip-flops |
| Total | About 300 LUTs, 300 flip-flops; no block RAM |

## 11. Spectrum extras

None. The Spectrum had no sprites.

## 12. Test plan

- **Model:** a Python model of this spec, added to the video model with sprites (spec 5), gives each frame's placements, skips and image; the RTL is compared with it pixel by pixel and write by write.
- **List format:** an entry written by the sequencer leaves the sprite's 16 registers equal to the entry's bytes; the end entry stops the list with only its VSTART set; a list that is only an end entry places nothing.
- **Write order and timing:** on the register bus model, each entry's writes are H, V, STEP, PT, then CTL, each register low byte first; none falls in pixels 0–15 of a line; none starts after pixel 815; all land by pixel 836, with the copper writing every 2 clocks and the CPU running OUTs at 20 MHz.
- **Gap rule:** a sprite whose use ends at VSTOP = E + 1 takes an entry with VSTART = E + 2 in line E + 1 and shows its first image line on line E + 2; the old use's last line E is drawn whole; an entry with VSTART = E + 1 for the same sprite is not placed on it.
- **Allocation:** the lowest-numbered free sprite in SEQMASK is chosen; sprites outside SEQMASK are never written; several entries placed in one line go to different sprites; an entry placed many lines before its VSTART shows from VSTART.
- **Free test:** a sprite not started this frame is free; one started by the copper or the CPU this frame is busy until its VSTOP; a copper write moving a sequencer sprite's VSTOP earlier frees it sooner, and later keeps it longer; the frame start frees every sprite.
- **Skips:** more uses on some lines than SEQMASK has sprites skip exactly the entries the model skips; SEQSTAT.SKIP is set and cleared by writing 1; SEQSKIP counts within the frame, stops at 255, and moves to SEQSKIPL at the frame start; VIDERR is raised only with SEQCON.IRQEN, and alongside the VIDSTAT causes.
- **Unsorted lists:** an entry whose start line has passed is skipped and counted; a late-starting entry holds back the ones after it; entries with the same VSTART are placed in list order.
- **Frame start:** SEQLC is reloaded at (0, 0); a SEQLC written during the frame takes effect only at the next frame start; double-buffered lists never show a half-built list; entries for lines 1–48 are placed in line 0 and the lines after it and are clipped at the top.
- **On and off:** EN set mid-frame starts at the next frame start; EN, SPREN or DMAEN cleared stops after a whole entry, never between its bytes; SEQMASK changed by a copper MOVEF mid-frame acts from the next placement (section 9.2).
- **Sharing:** a player on sprite 0 written by the CPU and a copper panel on sprites 4–7 run unchanged beside the sequencer; a CPU write to a sequencer sprite lands in bus order, as spec 3 says.
- **Register bus:** the sequencer never delays a copper write or a CPU strobe; the DMA engine waits for it; with all four busy, no access is lost.
- **Memory:** the sequencer never takes a cycle the CPU asked for, and never makes a layer overrun or a sprite underrun on a screen within the budget; it gets cycles ahead of the copper at PRI 0 and behind it at PRI 1; under a long copper burst at PRI 1 the entries it cannot read in time are skipped and counted.
- **Registers:** reset values; SEQPT0 captures all three bytes; reserved offsets read `0xFF`.
- **Example:** section 9.1 runs on the full-system simulation with 20 moving enemies and no skips while no 17 lines hold more than 7 starts, and the skips the model predicts when they do.

## 13. Open points

| # | Item |
|---|------|
| SQ1 | The buffer holds one entry. A second would let the next entry be read while one is written, for crowded gap lines. About 20 LUTs more. Proposed: one, until simulation shows a need |
| SQ2 | The sequencer's reads are best effort in the free pool (section 5.4). Measure in simulation how often entries are skipped for lack of reads, with the copper at PRI 1 in bursts and screens near the display budget. If needed, give the sequencer a share of cycle 4, or a place ahead of the copper at PRI 1 for its few words |
| SQ3 | The placing window (pixels 16–815) and the 836 limit come from retro68k's `sprites.v` at `bf91e97` (freeze at 840–847, line-start pass at pixel 0, decided by pixel 12). Check them again when the sprite unit is copied (phase 4) |
| SQ4 | Which entry got which sprite is not reported, so SPRCOLL cannot name an object (section 7). Possible later: write the sprite number back into a spare byte of the entry in SRAM (one write cycle per entry), or a small register of the last placements |
| SQ5 | Only VSTART `0x7FF` ends the list (branch 14). Entries with VSTART 625 or more before it take sprites and show nothing. Treating any VSTART above the last line as the end would save sprites; proposed: as written, since a sorted list puts such entries last anyway |
| SQ6 | Per-entry effects (an image switch part way down, a wobble) are left to the copper on sprites outside SEQMASK. A second entry type for mid-use changes would need the sprite number to be known; not planned |
| SQ7 | Specs 1 (section 4.2, the register bus masters), 2 (section 5, the free order), 6 (section 5.1, the free order) and 8 (section 4, VIDERR's causes) still list the masters, the free order and VIDERR without the sequencer, and are to be brought in line (spec 3, R15) |
| SQ8 | retro68k: offer the design for its sprite table (its spec 9, section 11). Its registers would be 32-bit and its entries its own sprite block's bytes (section 2.1) |
