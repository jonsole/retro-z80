# Spec 13: Sound

Status: **draft, version 1**. Written on 11 November 2026 (ticket #113) with the wrapper, on retro-hw's audio engine ([spec](../../fpga/retro-hw/docs/spec/audio_engine.md), revision 3, locked), shared with retro68k, whose spec 6 is the same design with 32-bit registers. Design plan Q1 and branch 9. Some of retro68k's choices are not yet reviewed by its user (open point AU1); retro-z80 follows them.

Four sample channels, in the spirit of the Amiga's Paula. Each plays a sample from SRAM by itself, at any pitch, with its own left and right volume, and needs no CPU work while it plays. A sample can loop, or the next one can be queued, as on the Amiga. The Spectrum-style beeper (spec 7, section 10.2) stays, and is mixed in.

## 1. Summary

| Item | Value |
|------|-------|
| Channels | 4, all alike |
| Output rate | 100 MHz ÷ AUDRATE. Default 2083: 48.008 kHz. 2268: 44.092 kHz |
| Sample formats | 8-bit or 16-bit signed PCM, per channel; little-endian, as the SRAM |
| Pitch | A step per output sample, 4.16 fixed point: 1/65536 to just under 16 samples per output sample |
| Resampling | Linear interpolation between neighbouring samples, or "nearest" (no interpolation), per channel, for the raw Amiga sound |
| Volume and pan | Left and right volume per channel, 0–64 each (64 = full). Software sets them: there are no reset values |
| Loops and queues | As the Amiga: a channel takes its address and length when it starts and again at the end of each block, and can interrupt each time |
| Starting and stopping | AUDDMA's bits (with DMACON.AUDEN and DMAEN), AUDSTART and AUDSTOP: start, restart or stop channels with one write, with no waiting; a one-shot mode stops a channel by itself at the end of its block; AUDSTAT shows which channels play |
| Memory | One or two 16-bit reads per playing channel per output sample, at most 8: under 1 MB/s. Scheduler requester 2 (AUD), the owner of memory cycle 4 (spec 2, section 5) |
| Mixer | The four channels summed, then the beeper added with clipping (section 3.2) |
| Output | Three second-order sigma-delta modulators at 100 MHz: the jack (left, right) and the internal speaker (mono) (spec 7, section 10.2) |
| Interrupt | AUDIO (source 9): a channel took its registers, or a one-shot block ended (AUDSTAT, AUDINTEN) |
| Registers | Custom block `0x244`–`0x2F6` (spec 3, section 5.10) |
| Enable | DMACON.AUDEN with DMACON.DMAEN (spec 4), and a bit a channel in AUDDMA |
| Core | retro-hw's `audio_engine` (section 9), wrapped in `fpga/rtl/audio.v` |

**Against the Amiga (Paula).** Paula plays each channel's 8-bit samples at the channel's own rate (AUDxPER) into its own DAC, hard-panned: channels 0 and 3 left, 1 and 2 right. Here every channel is resampled to one output rate (AUDxSTEP), with 8- or 16-bit samples, linear interpolation or nearest, and any pan. LC and LEN are taken at the start and at each block's end, with an interrupt each time, as on the Amiga. Starting and stopping need no waiting, and a one-shot block stops by itself. An Amiga period P (in 3,546,895 Hz ticks, PAL) gives a step of 3,546,895 × 65536 ÷ (P × 48,008) ≈ 4,841,886 ÷ P at the default rate, so a MOD player needs only a table from periods to steps.

## 2. Comparison with retro68k

Sound is retro68k's (its spec 6, branch `hw-audio`, d706cd2) in every field, bit and rule, except these:

| Item | retro68k (spec 6) | retro-z80 | Why |
|------|-------------------|-----------|-----|
| Registers | 32-bit, big-endian | 8-bit, low byte first, each byte written directly (spec 3, rule 2); the same bit numbers | Z80: 8-bit ports |
| Register offsets | AUDRATE `0x404`, AUDSTAT `0x40C`, AUDINTEN `0x410`, AUDSTART `0x414`, AUDSTOP `0x418`; channel n at `0x440` + n × `0x20` | The same less `0x1C0`: AUDRATE `0x244`, AUDSTAT `0x24C`, AUDINTEN `0x250`, AUDSTART `0x254`, AUDSTOP `0x258`; channel n at `0x280` + n × `0x20`. AUDDMA at `0x25C` | The custom block is 1 KB (spec 3) |
| Channel enables | DMACON.AUD0EN–AUD3EN (bits 3–0) | **AUDDMA** (CH, bits 3–0; SETCLR, bit 7), a set/clear register in the audio block, with DMACON.AUDEN (bit 1) as audio's master bit: channel n is enabled while DMAEN, AUDEN and AUDDMA bit n are all set (open point AU3) | DMACON is one byte (spec 4, V14): one bit for audio. As SPRDMA with SPREN for the sprites |
| Channel registers | CTRL, LC, LEN, STEP, VOL, POS: one 32-bit register each | The same fields, a 4-byte word each, of which CTRL uses 1 byte, the others 3; VOL's R in byte 0 and L in byte 2 (byte 1 reads 0) | Byte registers |
| Writing a register a byte at a time | One write sets a whole register | Each byte acts when written: STEP half written plays one output sample at a pitch between the old and the new; LC or LEN half written at a block's end takes a mix (section 5.4) | Byte registers. Write LC and LEN just after the channel's AUDSTAT bit sets, as retro68k must for LC then LEN |
| AUDxPOS | Read whole | Reading its low byte captures all three; the other two come from the capture (spec 3, rule 4) | It moves while the channel plays |
| Byte order | 8-bit samples: the first in a word's high byte. 16-bit samples big-endian | 8-bit samples: the first (even address) in a word's **low** byte. 16-bit samples **little-endian** (`LE` 1) | The SRAM is little-endian (spec 2, section 8.4) |
| Addresses | CPU addresses in Chip RAM | Physical: MMU page × `0x2000` + offset; 22 bits used (section 4.5) | Z80: 64 KB address space; chipset units do not use the MMU windows (spec 2) |
| Memory cycles | Memory cycle 2 of every slot, its own | Requester 2 (AUD), owner of memory cycle 4; the free pool when it leaves it | The CPU has cycles 0 and 2 (spec 2, branch 11) |
| Copper | MOVE | MOVEF, one byte per instruction | Copper MOVE reaches offsets `0x000`–`0x0EF` only (spec 6) |
| Interrupt | Source 9, AUDIO, default level 4 | Source 9, AUDIO, fixed priority; IM 2 vector VECBASE + 18 (spec 8) | IM 2 on one /INT line |
| Reading a channel register | Answered the clock after the read, the read's decode straight into the core | Registered: answered a clock later still; the bus interface waits for it (`rb_late`, spec 1, section 4.2) | Keeps the bus decode out of the core's settings RAM address path, its tightest path (retro-hw's guide) |
| Beeper | None | Port `0xFE` bit 4, ± a quarter of full scale, added to the mix with clipping (section 3.2; open point AU4) | Spectrum extra (spec 7, section 10.2) |
| DAC pins | `audioext_l`, `audioext_r`, `audioint` on the KS3 | The same, on the KS2 and the KS3 | – |
| Reset | Every reset and the 68000's RESET instruction | Every reset (spec 7) | The Z80 has no RESET instruction |

## 3. Output

### 3.1 Output rate

Every AUDRATE clocks of 100 MHz the unit makes one stereo output sample: it works out each channel's sample, mixes them, and hands the result to the DACs. AUDRATE is 16 bits. Values below 200 act as 200. The default, 2083, gives 48.008 kHz. AUDRATE is written a byte at a time; between the two writes the rate is half old and half new, for at most one output sample.

### 3.2 Mixer

```
   left  = Σ (channel sample × channel left volume)  ÷ 256
   right = Σ (channel sample × channel right volume) ÷ 256
```

A channel sample is 16 bits signed (an 8-bit sample is shifted up by 8), a volume 0–64, so each product fits in 22 bits, and four of them in 24: the sum always fits in 16 bits. As on the Amiga, one channel at full volume uses a quarter of the output range.

Then the beeper is added to each side: −BEEPAMP while port `0xFE` bit 4 is 0, +BEEPAMP while it is 1, BEEPAMP a quarter of full scale (`0x2000`; spec 7, section 10.2). The sum is clipped to 16 bits signed. So the beeper, idle at 0, is a steady −`0x2000`, which the board's coupling capacitor blocks; four channels near full volume can clip at the negative end (open point AU4).

### 3.3 DAC

Three second-order sigma-delta modulators at 100 MHz turn left, right and the mono mix ((left + right) ÷ 2) into 1-bit streams: the jack (`audioext_l_o`, `audioext_r_o`) and the internal speaker (`audioint_o`). The input is scaled to half the modulator's range, which keeps it stable at full scale. The board's RC filter turns each stream back into sound (spec 7, section 10.2). The real quality depends on the board's filter and has to be measured (open point AU7).

## 4. Channels

### 4.1 Blocks: starting, looping and queuing

A channel plays **blocks**. A block is a sample in SRAM: an address (AUDxLC) and a length in samples (AUDxLEN).

- When a channel is **started**, it takes AUDxLC and AUDxLEN, starts at the first sample of the block, and sets its bit in AUDSTAT. It starts at the next output sample after it is enabled (section 5.2), or after a write to AUDSTART.
- When it plays past the end of the block, it takes AUDxLC and AUDxLEN **again**, carries on from the start of that block, and sets its AUDSTAT bit again. With AUDxCTRL.ONESHOT set, it stops instead, and sets its bit.

So:

- **A loop:** write AUDxLC and AUDxLEN once and start the channel. It plays the block over and over.
- **A sample with a loop:** write the whole sample, start the channel, and when its AUDSTAT bit sets, write the loop part. The whole sample plays once, then the loop part for ever.
- **A queue:** each time the channel's AUDSTAT bit sets, write the next block. The blocks play one after another with no gap.
- **A one-shot sound:** set AUDxCTRL.ONESHOT and start the channel: it plays the block once and stops. To play it again, write AUDSTART.
- **A sound effect that cuts off the one playing:** write the new sample's AUDxLC and AUDxLEN, then AUDSTART: the channel starts it at the next output sample, whatever it was doing.

The registers can be written at any time; the channel only takes LC and LEN when it starts a block. A block of length 0 stops the channel.

### 4.2 Pitch

Each output sample, a channel's position moves on by AUDxSTEP, 4.16 fixed point: `0x10000` plays one sample per output sample, `0x8000` half that (an octave down), `0x20000` twice (an octave up). The largest step is just under 16. A step past the end of a block carries on into the next block by the amount left over (if that is past the end of the next block too, it starts at its first sample). A one-shot channel stops instead.

### 4.3 Interpolation

```
   s = s0 + (s1 − s0) × frac ÷ 65536        (rounded down)
```

s0 is the sample at the position, s1 the one after it, frac the position's fraction. At the last sample of a block, s1 is the first sample of the block to come: the one at AUDxLC as the register then stands. So a loop is smooth round its join, and a queued block joins the one before. A one-shot channel, or one whose AUDxLEN is then 0, has no block to come: its s1 is s0. With AUDxCTRL.NEAREST set, s = s0: each sample is held until the next, as on the Amiga. retro-hw's audio engine spec, section 4.6, gives the exact result.

### 4.4 Sample formats

- **8-bit** (CTRL.BITS16 = 0): signed bytes, two to a word, the first (at the even address) in the low byte, as the Z80 stores them. AUDxLC can be any byte address.
- **16-bit** (CTRL.BITS16 = 1): signed little-endian words, as the Z80 stores them (`dw`). AUDxLC must be even; its bit 0 is ignored.

### 4.5 Addresses

AUDxLC is a physical SRAM address, 22 bits: MMU page × `0x2000` + offset, as the blitter's (spec 14, section 4). The MMU windows play no part. A 2 MB build ignores bit 21 (spec 2, section 11). AUDxLEN is 22 bits too, so a block can be the whole SRAM; AUDxPOS likewise. Addresses wrap at 4 MB.

### 4.6 Memory

For each output sample, each playing channel reads the word holding s0 and, unless NEAREST is set, the word holding s1 if that is a different one: at most 8 reads per output sample, 384,000 a second at 48 kHz, under 1 MB/s. Sound is requester 2 (AUD) of the scheduler and owns memory cycle 4 of every slot (spec 2, section 5), 20 MB/s, so it is never short; a cycle 4 it leaves goes to the free pool. Reads happen just before they are needed; there are no sample caches. The CPU is never slowed.

## 5. Starting and stopping

### 5.1 The enables

A channel can only play while it is **enabled**: DMACON.DMAEN, DMACON.AUDEN and its bit in AUDDMA all set. DMACON.AUDEN is audio's master bit; AUDDMA has a bit a channel, as retro68k's DMACON.AUD0EN–AUD3EN.

### 5.2 Starting and stopping

| To | Write | Takes effect |
|----|-------|--------------|
| Start a channel, or restart it from its registers even while it plays | AUDSTART bit n (the channel must be enabled), or enable it (AUDDMA bit n, AUDEN or DMAEN set, the others already set) | At the next output sample |
| Stop a channel | AUDSTOP bit n, or disable it (clear AUDDMA bit n, AUDEN or DMAEN) | At once: AUDSTAT.ACTIVE clears straight away, and the channel is left out of the next output sample. If the unit is working on the channel at that moment, it finishes it for this output sample: a block's end there still takes the registers and sets the AUDSTAT bit, but the channel stays stopped |
| Play a block once and stop | AUDxCTRL.ONESHOT, then start the channel | It stops by itself at the end of the block, and sets its AUDSTAT bit |

All of them act as soon as they are written: there is never a need to wait between stopping and starting a channel, as there is on the Amiga. Clearing a channel's AUDDMA bit and setting it again straight away restarts it. Clearing AUDEN stops all four; setting it again starts every channel whose AUDDMA bit is set. While a channel is not enabled, AUDSTART does nothing to it.

### 5.3 Settings

CTRL, STEP and VOL take effect from the next output sample; LC and LEN when the channel next starts a block (and LC for the join at the end of the block before, section 4.3).

**The channel registers have no reset values.** They are kept in a small RAM that a reset does not clear: after power-on they are CTRL 0, LC 0, LEN 0, STEP `0x10000` and VOL 0, and after a later reset whatever was last written. Write all five before starting a channel (open point AU1).

### 5.4 Writing a byte at a time

Each byte of a channel register acts when it is written.

- **STEP** taken between two of its byte writes plays one output sample at a step half old and half new: a click at most. Write it while the channel is stopped, or accept that.
- **LC and LEN** are taken only at a block's start, and LC also for the join. Write them just after the channel's AUDSTAT bit sets: the channel has just taken them and will not again before its block ends. A block shorter than the time software needs to write the next one cannot be queued this way. LC half written at a block's last sample joins to a wrong sample for that one output sample.
- **VOL**'s two volumes are separate bytes: each acts from the next output sample.

## 6. Registers

Custom block offsets (spec 3, section 5.10). Port = (offset & `0xFF`) << 8 | (`0x10` + (offset >> 8)): page `0x12`. Register page offset `0x1000` + offset.

| Offset | Port | Name | Access | Bits | Description |
|--------|------|------|--------|------|-------------|
| `0x244`–`0x245` | `0x4412`–`0x4512` | AUDRATE | RW | RATE 15–0 | Output rate = 100 MHz ÷ AUDRATE. 2083 after reset (48.008 kHz). Values below 200 act as 200 |
| `0x24C` | `0x4C12` | AUDSTAT | R, W1C | CH 3–0, ACTIVE 7–4 | CH bit n: channel n took its registers (it was started, or reached the end of a block), or its one-shot block ended. Sticky; write 1 to clear. ACTIVE bit 4 + n: channel n is playing (read only, live) |
| `0x250` | `0x5012` | AUDINTEN | RW | CH 3–0 | Bit n: AUDSTAT bit n raises the AUDIO interrupt |
| `0x254` | `0x5412` | AUDSTART | W (S) | CH 3–0 | Strobe: bit n starts channel n from its registers at the next output sample, even while it plays (if it is enabled). Reads 0 |
| `0x258` | `0x5812` | AUDSTOP | W (S) | CH 3–0 | Strobe: bit n stops channel n at once. Reads 0 |
| `0x25C` | `0x5C12` | AUDDMA | SC | CH 3–0, SETCLR 7 | The channel enables: with SETCLR 1 a write sets the CH bits written as 1, with SETCLR 0 it clears them (spec 3, rule 12). Reads the enables. 0 after reset |

Channel n (0–3) at `0x280` + n × `0x20` (AUD0 at `0x280`, port `0x8012`; AUD3 at `0x2E0`, port `0xE012`):

| Offset | Name | Access | Bits | Description |
|--------|------|--------|------|-------------|
| `+0x00` | AUDxCTRL | RW | BITS16 (1), NEAREST (2), ONESHOT (3) | Sample format; no interpolation; play one block, then stop |
| `+0x04`–`+0x06` | AUDxLC | RW | ADDR 21–0 | Block address, physical, in bytes (even for 16-bit). Taken at the start of each block |
| `+0x08`–`+0x0A` | AUDxLEN | RW | LEN 21–0 | Block length, in samples. Taken at the start of each block. 0 stops the channel |
| `+0x0C`–`+0x0E` | AUDxSTEP | RW | STEP 19–0 | Pitch: samples per output sample, 4.16 |
| `+0x10`–`+0x12` | AUDxVOL | RW | R 6–0, L 22–16 | Right volume (byte 0) and left volume (byte 2), 0–64; above 64 acts as 64. Byte 1 reads 0 |
| `+0x14`–`+0x16` | AUDxPOS | R, CAP | POS 21–0 | The sample the channel is at, in its block. Reading the low byte captures all three (spec 3, rule 4) |

The other offsets in `0x240`–`0x2FF` are reserved: they read `0xFF`, and writes do nothing. Bits above a field (LC, LEN and POS bits 23–22, STEP bits 23–20, CTRL bits 0 and 7–4, the volumes' bit 7) are not stored and read 0.

**Reads of a channel register** are answered a clock later than other registers' reads: the unit registers the read and the bus interface waits for it (spec 1, section 4.2). A read stops the engine for one clock, which never delays an output sample. The CPU sees no difference.

**The copper** writes these registers with MOVEF, one byte per instruction (spec 6).

### 6.1 Interrupt

Source 9, AUDIO, in the interrupt controller (spec 8): any AUDSTAT CH bit with its AUDINTEN bit set. IM 2 vector VECBASE + 18. The handler reads AUDSTAT to see which channels, writes their next blocks if any, and clears their bits. A write of 1 to an AUDSTAT bit clears it even if the channel sets it again in that same clock (as retro68k; open point AU2).

### 6.2 Reset

Every reset (spec 7, section 3) stops every channel, forgets a start not yet taken, and sets AUDRATE to 2083, AUDSTAT, AUDINTEN and AUDDMA to 0. The channel registers keep their values (section 5.3). The beeper bit is 0. DMACON clears too (spec 4).

## 7. Examples

Playing a looped 8-bit sample on channel 1 at 22,050 Hz, centre. The sample is at physical `0x040000`; a 3-byte register is written low byte first with `INC B` between bytes:

```
        ld      bc,AUD1_LC_P          ; LC = 0x040000
        xor     a
        out     (c),a
        inc     b
        out     (c),a
        inc     b
        ld      a,0x04
        out     (c),a
        ld      bc,AUD1_LEN_P         ; LEN = 8000 samples
        ld      hl,8000
        out     (c),l
        inc     b
        out     (c),h
        inc     b
        xor     a
        out     (c),a
        ld      bc,AUD1_STEP_P        ; STEP = 22050 × 65536 ÷ 48008 = 0x7595
        ld      a,0x95
        out     (c),a
        inc     b
        ld      a,0x75
        out     (c),a
        inc     b
        xor     a
        out     (c),a
        ld      bc,AUD1_VOL_P         ; right 32, left 32
        ld      a,32
        out     (c),a
        inc     b
        inc     b
        out     (c),a
        ld      bc,AUD1_CTRL_P        ; 8-bit, interpolated
        xor     a
        out     (c),a
        ld      bc,AUDDMA_P           ; enable channel 1 ...
        ld      a,AUDDMA_SETCLR_M | 0x02
        out     (c),a
        ld      bc,DMACON_P           ; ... and audio: it starts
        ld      a,DMACON_SETCLR_M | DMACON_DMAEN_M | DMACON_AUDEN_M
        out     (c),a
```

A sample with a loop: as above, then, when AUDSTAT bit 1 sets (the channel has taken the whole sample), write the loop part's LC and LEN, and write 2 to AUDSTAT to clear the bit.

A one-shot sound effect on channel 3, cutting off whatever it was playing: write AUD3_CTRL with ONESHOT, then AUD3_LC and AUD3_LEN, then 8 to AUDSTART.

## 8. Test plan

| Test | What it checks |
|------|----------------|
| `make atest` (`sim/atest`, about a minute and a half) | retro68k's golden test narrowed to the Z80: a test ROM plays all four channels at once, 8- and 16-bit, nearest and interpolated, steps below and above 1, odd addresses, queued blocks of different lengths, a one-shot block, a restart with AUDSTART while playing, a channel's AUDDMA bit turned off and on again with no wait, and AUDSTOP; the testbench records every output sample (and which channels started and played in it), and a Python model (`amodel.py`, retro-hw's spec 4.6 with the SRAM little-endian) must give exactly the same numbers. The DAC streams, averaged over 16 output samples, follow the output with the beeper's level added. Then, in the ROM: the channel registers read back by port and through the register page (VOL's empty byte, a reserved byte reading `0xFF`, `LD HL,(nn)` on AUDxLEN), AUDRATE, AUDDMA; AUDxPOS through the capture by port and through the register page; AUDSTAT.ACTIVE; the AUDIO source's INTRAW bit with AUDINTEN, and cleared with AUDSTAT; DMACON.AUDEN off stopping every channel, AUDDMA kept. The testbench's checks that the Z80 never waits cover the late read |
| `make fe` | The beeper alone at a quarter of full scale on all three streams (spec 7, section 10.2) |
| `make intc` | Source 9 now a line: INTRAW, the vector, INTID |
| retro-hw's `test/audio_engine` | The core against its bit-exact model (retro-hw's spec, section 6) |
| Lint | `fpga/lint.sh`, the full machine and the KS2's top |
| KS2 | A tone and a sample on the jack and the speaker; the beeper over a playing channel; LUTs and timing (open point AU6) |

## 9. FPGA resources

| Item | Resource |
|------|----------|
| `audio_engine` (4 channels, interpolation, read-back, `AW` 20, `LE` 1), out of context on the KS2's part | 646 LUTs, 417 flip-flops, 1 DSP block, +1.23 ns at 100 MHz (retro-hw's spec, U10). `AW` 21 here: about the same |
| The wrapper: the globals, the registered read, the beeper and the mix | Flip-flops and a few dozen LUTs; to be measured |
| Three sigma-delta modulators | As before (spec 7) |
| The scheduler's requester 2 | Was tied off; now used |

**Builds.** Both boards build sound. To make room on the KS2 (XC7A15T, 93% full before sound), the KS2 builds the rasteriser with lines only (`DMX_TRI = 0`; spec 19, section 10), which saves about 640 LUTs. The KS3 builds triangles. Size and timing of the KS2 build: open point AU6.

### 9.1 Shared core

Sound is retro-hw's `audio_engine` ([spec](../../fpga/retro-hw/docs/spec/audio_engine.md), revision 3, locked), in `fpga/retro-hw/rtl/audio_engine.v`: the channels' settings in LUT RAM, the engine, one multiplier used in turn, the mixer. `fpga/rtl/audio.v` wraps it, as retro68k's `audio.v` narrowed to bytes.

| Parameter | Value | Why |
|-----------|-------|-----|
| NCH | 4 | Four channels |
| AW | 21 | Word addresses: 4 MB of SRAM; LC, LEN and POS 22 bits (open point AU1) |
| LE | 1 | The SRAM is little-endian (spec 2, section 8.4) |
| INTERP | 1 | Interpolation built; each channel can still choose nearest |
| RDBACK | 1 | The channel registers read back; without it AUDxPOS cannot be read |

The wrapper keeps the registers of section 6: AUDRATE with its floor of 200 (the core has none), AUDSTAT, AUDINTEN and AUDDMA; it turns the enables' edges and AUDSTART and AUDSTOP into the core's `start` and `stop` strobes (a channel not enabled is never given a start); a channel register write is one `set_we` with that byte's enable (CTRL's bits moved down one place); a channel register read is registered (`rb_re` from a flip-flop, one clock long), the core's `rb_q` taken the clock after, and its low POS byte hands all 24 bits to the capture. It adds the beeper to `out_l` and `out_r` with clipping and drives the three modulators. The core's memory port is the scheduler's AUD requester.

**Resets.** The core is reset with every reset, the scheduler only at power-on (spec 2). A word the core asked for before a reset comes back within a few clocks, long before the 5.12 µs reset ends, and the core ignores a word it did not ask for, so the two need not be reset together (retro-hw's spec, 4.9).

## 10. Open points

| # | Item |
|---|------|
| AU1 | **retro68k's choices, not yet reviewed by its user**, which retro-z80 follows: (a) no reset values for the channel registers, so no Amiga pan defaults written by the wrapper (software writes VOL and STEP before a start); (b) LC, LEN and POS 22 bits; (c) AUDRATE's floor of 200 kept in the wrapper; (d) a write of 1 to AUDSTAT wins over a channel setting the bit in the same clock (AU2). If retro68k changes any of them, retro-z80 follows |
| AU2 | **AUDSTAT against DMXINT.** AUDSTAT follows retro68k: a write of 1 clears the bit even if the channel sets it in that same clock, so that event's interrupt is lost (the channel still took its block). `dmx.v`'s DMXINT does the opposite: a flag due in the clock a write clears it stays set, so an interrupt is never lost (spec 14, section 8.3). One rule for both would be simpler; the DMXINT rule is the safer. To settle with retro68k |
| AU3 | **AUDDMA is a new register** (not in retro68k): retro68k's DMACON.AUD0EN–AUD3EN do not fit DMACON's one byte, which has one bit, AUDEN. AUDDMA holds them, with AUDEN as master, as SPRDMA with SPREN for the sprites. The other way, AUDEN alone enabling all four channels (setting it would start all four, even ones software has not set up), was not taken. For the user to confirm |
| AU4 | **The beeper's idle level.** Spec 7's beeper is −BEEPAMP (a quarter of full scale) while its bit is 0, so with the beeper idle the channels' mix sits a quarter of full scale down and clips at the negative end if the four channels together go below −0.75 of full scale. Choices: keep it (a steady level costs nothing audible); make the beeper 0 and +BEEPAMP; or halve BEEPAMP. For the user |
| AU5 | **The late read.** A channel register read through the register page now has 1 clock to spare at 20 MHz when the copper writes in the same clock (spec 1, section 5.7: was 2); simulation confirms no wait (`make atest`). At 25 MHz (spec 1, B10) it would have none: check with B10 |
| AU6 | Measured (12 November 2026, #113): the KS2 build with `DMX_TRI = 0` is 9,826 logic LUTs (94.5%), timing met (+0.155 ns setup, +0.036 ns hold), no critical warnings; the wrapper is 1,001 LUTs. Had it not fitted, the choices were `INTERP` 0 (about 130 LUTs less), `RDBACK` 0 (about 60 less, but no AUDxPOS), or 2 channels |
| AU7 | The audio filter on the KS2 and the KS3, and the real quality of the sigma-delta output, measured on the board (retro68k's A1) |
| AU8 | Sound over HDMI (retro68k's A3; #117). **Decided by the user, 12 November 2026:** through retro-hw, from retro-spectrum's `hdmi_tx.v` (on the KS2 since 3 November) made stereo and shared; HDMI takes a fixed 48 kHz tap of the mix (`out_l`, `out_r`), locked to the 27 MHz pixel clock (N 6,144, CTS 27,000), whatever AUDRATE is; the jack and speaker keep AUDRATE. Not built yet |
| AU9 | AUDRATE, STEP, LC and LEN written a byte at a time can be taken half written (sections 3.1 and 5.4). A latch that commits on the top byte (as the MMU pages, spec 3) would remove it, at a few flip-flops a register; not done, as retro68k's LC then LEN have the same rule |
