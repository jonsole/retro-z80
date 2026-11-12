# Chapter 10: Audio Hardware

## Introduction

The machine has **four sound channels**. Each one plays a **sample**, a run of 8-bit or 16-bit values in SRAM, by itself: once you have told a channel where the sample is, how long it is, how fast to play it and how loud, it reads the sample from memory and plays it with no further help from the Z80. The four channels are mixed, each with its own left and right volume, and sent to the board's audio jack and its speaker.

A channel can play its sample once, play it over and over, or go straight on into another sample that you queue while the first one plays. With the sound interrupt, which comes each time a channel takes a new sample, a program can keep a channel fed for ever: music, speech or sound made by the Z80 as it goes.

This chapter covers:

- how sound is made: the output rate, the channels and the samples;
- turning sound on, and the channel enables;
- a channel's registers: the sample's format, address and length, its pitch and its volume;
- playing a first tone, step by step, with a complete program;
- starting and stopping channels, and one-shot sounds;
- AUDSTAT and the sound interrupt;
- joining samples together: loops, a sample with a loop, queues and double buffering;
- choosing the pitch, and the volume and pan;
- advanced topics: interpolation, 16-bit samples, the output rate, the channel's position, writing a register a byte at a time, the beeper, and sound from the copper;
- timing, what the sound hardware cannot do, and a comparison with the Amiga;
- a summary of the registers.

You should have read Chapter 1 ("Introduction and System Control"), for the registers, DMACON and the program map, and Chapter 2 ("Interrupts and Timers"), for IM 2, before Examples 10-2 and 10-3.

### Conventions in this chapter

- Examples are Z80 assembly language for sjasmplus, and start with `include "hw.inc"`.
- The sound registers are in the custom block, at offsets `0x244`–`0x2F6`. The Z80 reaches them through ports in page `0x12`: the port is (offset bits 7–0) × 256 + `0x12`, so AUDSTAT, offset `0x24C`, is port `0x4C12` (`AUDSTAT_P`), and channel 0's CTRL, offset `0x280`, is port `0x8012` (`AUD0_CTRL_P`). They are written with `LD BC,port` and `OUT (C),r`.
- A register of two or three bytes has a port for each byte, one apart in B, low byte first: `AUD0_LC0_P`, `AUD0_LC1_P`, `AUD0_LC2_P`. `INC B` steps from one byte to the next.
- A channel's registers are named AUDxCTRL, AUDxLC and so on, where x is the channel, 0–3. `hw.inc` names them `AUD0_CTRL` … `AUD3_POS`, and their bits `AUD_CTRL_ONESHOT_M` and so on, the same for every channel.
- The complete examples are in `examples/sound/`, loaded at `0x8000`. They run in the boot ROM's **program map** (Chapter 1, "Programs"), so a Z80 address is also the physical address a channel needs. They print with the boot ROM's calls (`RST 0x18` PUTS, `RST 0x08` PUTC), read keys with `RST 0x20` POLLC, and return to the monitor with everything put back.
- Sample rates and pitches are worked out at the output rate after reset, 48,008 Hz.

---

## Introducing Sound Generation

Sound is a pressure wave. The jack and the speaker make it from a stream of numbers, **output samples**, each one the height of the wave at a moment: the sound hardware hands one stereo output sample, a left and a right value, to the outputs at a steady rate, the **output rate**.

The four channels make those numbers. For every output sample, each playing channel works out its own value from its sample data in SRAM, scales it by its left and right volumes, and the four are added up. Figure 10-1 shows the path from memory to the jack.

```
     SRAM                    the channels                    the mixer           the outputs
  +---------+         +---------------------------+
  | sample  |-------->| channel 0  LC LEN STEP VOL|--+
  | data    |-------->| channel 1                 |--+--> left  = sum ----+---> sigma-delta --> jack, left
  |         |-------->| channel 2                 |--+--> right = sum --+ |
  |         |-------->| channel 3                 |--+                  | +--> sigma-delta --> jack, right
  +---------+         +---------------------------+     the beeper ---->+ |
                                                        (port 0xFE)       +--> sigma-delta --> speaker (mono)

                Figure 10-1: From Sample Data to the Jack
```

A channel's sample data, its **block**, is in SRAM, at an address (AUDxLC) and with a length in samples (AUDxLEN). The channel reads it as it plays: one or two 16-bit reads per output sample. Sound has its own memory cycle in every slot (Chapter 1, "Sharing the Memory"), so a channel never runs short of data, and **the Z80 is never slowed** by it.

**The pitch** is set by how fast a channel moves through its block. AUDxSTEP is the number of the block's samples it moves on at each output sample: a step of 1 plays the block's samples at the output rate, a step of ½ at half the rate (an octave lower), a step of 2 at twice it. The step has a fraction, so any rate can be played. Between two of the block's samples, the channel works out a value on the straight line between them (**interpolation**), unless you ask it to hold each sample as it is (**nearest**).

### The output rate

The output rate is set by **AUDRATE**: one output sample every AUDRATE clocks of 100 MHz. After reset it is 2083, which gives 48,008 Hz (more exactly 48,007.7 Hz): an output sample every 20.83 µs. All four channels share it. Table 10-1 gives AUDRATE's two bytes.

**Table 10-1: AUDRATE Register**

| Byte | Bits | Meaning |
|------|------|---------|
| AUDRATE0 (`0x244`) | 7–0 | RATE bits 7–0 |
| AUDRATE1 (`0x245`) | 7–0 | RATE bits 15–8 |

The output rate is 100,000,000 ÷ RATE Hz. Values below 200 act as 200, so the fastest output rate is 500 kHz. Most programs leave AUDRATE as it is and set each channel's pitch with its step. "Changing the output rate", under "Advanced Topics", says when to change it.

### The channels

The four channels, 0–3, are all alike. Each has six registers, in 32 bytes of the custom block: channel n is at offset `0x280` + n × `0x20`.

**Table 10-2: The Four Channels**

| Channel | Offsets | CTRL port | `hw.inc` |
|---------|---------|-----------|----------|
| 0 | `0x280`–`0x296` | `0x8012` | `AUD0_CTRL_P` … `AUD0_POS2_P` |
| 1 | `0x2A0`–`0x2B6` | `0xA012` | `AUD1_CTRL_P` … |
| 2 | `0x2C0`–`0x2D6` | `0xC012` | `AUD2_CTRL_P` … |
| 3 | `0x2E0`–`0x2F6` | `0xE012` | `AUD3_CTRL_P` … |

### Turning sound on

A channel plays only while it is **enabled**, and it is enabled while three bits are all set:

- **DMACON.DMAEN** (bit 6), the chipset's master bit (Chapter 1, "Sharing the Memory");
- **DMACON.AUDEN** (bit 1), sound's own bit, over all four channels;
- the channel's bit in **AUDDMA**, offset `0x25C`, port `0x5C12` (Table 10-3).

**Table 10-3: AUDDMA Register**

| Bits | Name | Meaning |
|------|------|---------|
| 7 | SETCLR | Write 1 to set the CH bits written as 1; write 0 to clear them. Reads 0 |
| 6–4 | – | Read 0 |
| 3–0 | CH | Bit n: channel n is enabled (with DMAEN and AUDEN) |

AUDDMA is a set/clear register, as DMACON is: CH bits written as 0 are left alone. **Enabling a channel starts it**: when the last of its three bits is set, it takes its block at the next output sample and plays. So write a channel's registers first and enable it last. Clearing any of the three stops it at once. "Starting and Stopping" below has the details.

When a program starts, DMAEN is on (the console's display needs it), and AUDEN and AUDDMA are 0.

---

## The Channel Registers

Table 10-4 shows a channel's registers as they lie in its 32 bytes. Each is one byte (CTRL) or three, in a 4-byte slot, low byte first. The bytes between them are reserved: they read `0xFF` (VOL's middle byte reads 0), and writing them does nothing.

**Table 10-4: A Channel's Registers**

| Offset | Register | Bytes | Access | What it holds |
|--------|----------|-------|--------|---------------|
| `+0x00` | AUDxCTRL | 1 | RW | The sample format, nearest or interpolated, one-shot |
| `+0x04` | AUDxLC | 3 | RW | The block's address |
| `+0x08` | AUDxLEN | 3 | RW | The block's length, in samples |
| `+0x0C` | AUDxSTEP | 3 | RW | The pitch: samples per output sample |
| `+0x10` | AUDxVOL | 3 | RW | The right volume (byte 0) and the left (byte 2) |
| `+0x14` | AUDxPOS | 3 | R | Where the channel is in its block (see "Advanced Topics") |

**The channel registers have no reset values.** They are kept in a small memory that a reset does not clear: after power-on they hold CTRL 0, LC 0, LEN 0, STEP `0x10000` and VOL 0, and after a later reset whatever was last written. So **write all five before you start a channel** (spec 13, open point AU1).

### AUDxCTRL: the sample format

**Table 10-5: AUDxCTRL Register**

| Bits | Name | Meaning |
|------|------|---------|
| 7–4 | – | Read 0 |
| 3 | ONESHOT | 1: play the block once, then stop. 0: at the end of the block, take LC and LEN again and carry on |
| 2 | NEAREST | 1: hold each sample until the next (no interpolation). 0: interpolate between samples |
| 1 | BITS16 | 1: 16-bit samples. 0: 8-bit samples |
| 0 | – | Reads 0 |

A first simple use writes 0: 8-bit samples, interpolated, played over and over. CTRL takes effect from the next output sample, so it can be changed while the channel plays (Example 10-3 does).

**8-bit samples** are signed bytes, −128 to 127, one after another in memory, as `DB` writes them. **16-bit samples** are signed words, low byte first, as `DW` writes them. Signed means that silence is 0, and a wave swings either side of it.

### AUDxLC: the block's address

**Table 10-6: AUDxLC Register**

| Byte | Bits | Meaning |
|------|------|---------|
| AUDxLC0 (`+0x04`) | 7–0 | Address bits 7–0. Bit 0 is ignored for 16-bit samples |
| AUDxLC1 (`+0x05`) | 7–0 | Address bits 15–8 |
| AUDxLC2 (`+0x06`) | 7–6 | Read 0 |
| | 5–0 | Address bits 21–16 |

LC is a **physical address** in SRAM, 22 bits: the MMU page × `0x2000` + the offset in the page (Chapter 1, "Physical addresses"). The MMU's windows play no part: a channel reads SRAM directly. In the program map, a Z80 address from `0x2000` up is its own physical address, so `LD HL,wave` gives LC's low two bytes, and the top byte is 0. An 8-bit block can start at any byte; a 16-bit block starts at an even address.

### AUDxLEN: the block's length

**Table 10-7: AUDxLEN Register**

| Byte | Bits | Meaning |
|------|------|---------|
| AUDxLEN0 (`+0x08`) | 7–0 | Length bits 7–0 |
| AUDxLEN1 (`+0x09`) | 7–0 | Length bits 15–8 |
| AUDxLEN2 (`+0x0A`) | 7–6 | Read 0 |
| | 5–0 | Length bits 21–16 |

The length is in **samples**, not bytes: 32 for a block of 32 bytes of 8-bit samples, or of 64 bytes of 16-bit ones. It can be anything from 1 up to the whole SRAM. **A length of 0 stops the channel** when it is taken.

**A channel takes LC and LEN only when it starts a block**: when it is started, and each time it reaches the end of a block. Writing them while a block plays changes nothing until that block ends. This is what lets you queue the next block ("Joining Sounds" below).

### AUDxSTEP: the pitch

**Table 10-8: AUDxSTEP Register**

| Byte | Bits | Meaning |
|------|------|---------|
| AUDxSTEP0 (`+0x0C`) | 7–0 | The step's fraction, bits 7–0 (units of 1/65536) |
| AUDxSTEP1 (`+0x0D`) | 7–0 | The step's fraction, bits 15–8 |
| AUDxSTEP2 (`+0x0E`) | 7–4 | Read 0 |
| | 3–0 | The whole samples, 0–15 |

STEP is a **4.16 fixed-point number**: the block's samples the channel moves on at each output sample, from 1/65536 to just under 16. `0x10000` plays one sample per output sample: the block at the output rate. A block of samples recorded at f Hz plays at its own pitch with

    STEP = f × 65536 ÷ output rate

so a recording at 8,000 Hz takes 8000 × 65536 ÷ 48008 = 10,921 (`0x02AA9`), and one at 22,050 Hz 30,101 (`0x07595`). A wave of one cycle in a block of N samples gives a note of f Hz with

    STEP = f × N × 65536 ÷ output rate

For a 32-sample cycle at 440 Hz that is 19,222 (`0x04B16`). STEP takes effect from the next output sample. "Choosing the Pitch" below has a table of notes.

### AUDxVOL: the volumes

**Table 10-9: AUDxVOL Register**

| Byte | Bits | Meaning |
|------|------|---------|
| AUDxVOL0 (`+0x10`) | 7 | Reads 0 |
| | 6–0 | Right volume, 0–64 |
| AUDxVOL1 (`+0x11`) | 7–0 | Reads 0 |
| AUDxVOL2 (`+0x12`) | 7 | Reads 0 |
| | 6–0 | Left volume, 0–64 |

64 is full volume and 0 silent; values above 64 act as 64. The two volumes set the channel's loudness and its place between left and right: 64 and 64 is full volume in the centre, 64 and 0 hard right. Each volume takes effect from the next output sample.

### A channel's registers as data

Because the registers lie in a fixed order, a program can keep a channel's set-up as 19 bytes in memory, laid out as the registers are, and write them with one short loop. The examples use a macro, `AUDCHAN`, to build the 19 bytes:

```asm
    MACRO AUDCHAN ctrl, lc, len, step, vr, vl
        db      ctrl, 0, 0, 0           ; CTRL (+0x00)
        d24     lc                      ; LC   (+0x04), low byte first
        db      0
        d24     len                     ; LEN  (+0x08)
        db      0
        d24     step                    ; STEP (+0x0C)
        db      0
        db      vr, 0, vl               ; VOL  (+0x10): right, empty, left
    ENDM
```

Here is Example 10-1's channel 0 as the assembler builds it: 8-bit samples, interpolated, looped; the wave at `0x008067`, 32 samples long; a step of 19,222; right volume 0, left 48:

```asm
        DB      0x00,0x00,0x00,0x00     ; CTRL: 8-bit, interpolated, looped
        DB      0x67,0x80,0x00,0x00     ; LC: 0x008067
        DB      0x20,0x00,0x00,0x00     ; LEN: 32 samples
        DB      0x16,0x4B,0x00,0x00     ; STEP: 0x04B16, 0.293 samples per output sample
        DB      0x00,0x00,0x30          ; VOL: right 0, left 48
        AUDCHAN 0, wave, 32, STEP_A, 0, 48      ; the same 19 bytes
```

---

## Playing a Sound Step by Step

To play a sound on a channel:

### Step 1: Put the sample in memory

Any SRAM will do. In the program map, data assembled into the program is already in place. Example 10-1 plays one cycle of a sine wave, 32 signed bytes:

```asm
wave:   db      0, 20, 38, 56, 71, 83, 92, 98
        db      100, 98, 92, 83, 71, 56, 38, 20
        db      0, -20, -38, -56, -71, -83, -92, -98
        db      -100, -98, -92, -83, -71, -56, -38, -20
```

### Step 2: Write the channel's registers

CTRL, LC, LEN, STEP and VOL, while the channel is stopped. Byte by byte, channel 0's LC is:

```asm
        ld      hl,wave                 ; the program map: the Z80 address is physical
        ld      bc,AUD0_LC0_P
        out     (c),l                   ; bits 7-0
        inc     b
        out     (c),h                   ; bits 15-8
        inc     b
        xor     a
        out     (c),a                   ; bits 21-16
```

With a 19-byte image, the loop `setchan` writes all five in one go. B holds the high byte of the channel's CTRL port, and each `INC B` moves on to the next byte's port. The reserved bytes between the registers are written too, which does nothing:

```asm
; Write a channel's registers from the 19-byte image at HL. B = the high
; byte of the channel's CTRL port; the low byte, 0x12, is the custom
; block's page.
setchan:
        ld      c,low AUD0_CTRL_P
        ld      d,AUD_VOL + 3           ; 19 bytes
.next:  ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b                       ; the next byte's port
        dec     d
        jr      nz,.next
        ret
```

### Step 3: Enable the channel

Set its AUDDMA bit, then DMACON.AUDEN (with DMAEN, which is on already). The channel starts at the next output sample. Channels enabled by the same write start together, in the same output sample:

```asm
        ld      bc,AUDDMA_P             ; enable channels 0 and 1 ...
        ld      a,AUDDMA_SETCLR_M | 0x03
        out     (c),a
        ld      bc,DMACON_P             ; ... and sound: both start together
        ld      a,DMACON_SETCLR_M | DMACON_DMAEN_M | DMACON_AUDEN_M
        out     (c),a
```

### Step 4: Stop it

Clear the AUDDMA bits, and AUDEN, as the program found it. The channels stop at once:

```asm
        ld      bc,AUDDMA_P             ; SETCLR 0: clear the bits
        ld      a,0x03
        out     (c),a
        ld      bc,DMACON_P
        ld      a,DMACON_AUDEN_M
        out     (c),a
```

### Example 10-1: A first tone

Two channels play the same 32-sample sine wave, over and over: channel 0 at A (440 Hz) on the left, channel 1 at C sharp (554 Hz) on the right. A key stops them. The file is `examples/sound/tone.asm`.

```asm
; Example 10-1 (docs/guide/sound.md): a first tone. Two channels play one
; cycle of a sine wave, 32 signed 8-bit samples, over and over: channel 0
; at A (440 Hz) on the left, channel 1 at C sharp (554 Hz) on the right.
; A key stops them, and the program ends.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

; STEP: samples of the block per output sample, 4.16 fixed point. At the
; output rate after reset, 48,008 Hz, with 32 samples to a cycle:
;   STEP = f x 32 x 65536 / 48008
STEP_A  equ     19222                   ; 440.0 Hz
STEP_CS equ     24218                   ; 554.4 Hz

; A channel's registers as they lie in the custom block, CTRL to VOL:
; 19 bytes, with the empty bytes between them
    MACRO AUDCHAN ctrl, lc, len, step, vr, vl
        db      ctrl, 0, 0, 0           ; CTRL (+0x00)
        d24     lc                      ; LC   (+0x04), low byte first
        db      0
        d24     len                     ; LEN  (+0x08)
        db      0
        d24     step                    ; STEP (+0x0C)
        db      0
        db      vr, 0, vl               ; VOL  (+0x10): right, empty, left
    ENDM

start:  ld      hl,chan0                ; 1. the two channels' registers
        ld      b,high AUD0_CTRL_P
        call    setchan
        ld      hl,chan1
        ld      b,high AUD1_CTRL_P
        call    setchan

        ld      bc,AUDDMA_P             ; 2. enable channels 0 and 1 ...
        ld      a,AUDDMA_SETCLR_M | 0x03
        out     (c),a
        ld      bc,DMACON_P             ; 3. ... and sound: both start together
        ld      a,DMACON_SETCLR_M | DMACON_DMAEN_M | DMACON_AUDEN_M
        out     (c),a

        ld      hl,title
        rst     0x18                    ; PUTS
.wait:  rst     0x20                    ; POLLC: a key?
        jr      z,.wait

        ld      bc,AUDDMA_P             ; 4. stop them: SETCLR 0 clears the bits
        ld      a,0x03
        out     (c),a
        ld      bc,DMACON_P             ;    and sound off, as the program found it
        ld      a,DMACON_AUDEN_M
        out     (c),a
        ret

; Write a channel's registers from the 19-byte image at HL. B = the high
; byte of the channel's CTRL port; the low byte, 0x12, is the custom
; block's page. The empty bytes are reserved: writing them does nothing.
setchan:
        ld      c,low AUD0_CTRL_P
        ld      d,AUD_VOL + 3           ; 19 bytes
.next:  ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b                       ; the next byte's port
        dec     d
        jr      nz,.next
        ret

chan0:  AUDCHAN 0, wave, 32, STEP_A, 0, 48      ; 8-bit, interpolated; left only
chan1:  AUDCHAN 0, wave, 32, STEP_CS, 48, 0     ; right only

; one cycle of a sine, 32 signed 8-bit samples, peak 100
wave:   db      0, 20, 38, 56, 71, 83, 92, 98
        db      100, 98, 92, 83, 71, 56, 38, 20
        db      0, -20, -38, -56, -71, -83, -92, -98
        db      -100, -98, -92, -83, -71, -56, -38, -20

title:  db      13, 10, "A on the left, C sharp on the right. A key stops them.", 13, 10, 0
```

Both channels play the same 32 bytes: a block can be shared by any number of channels, each at its own pitch and volume. In simulation the output matched a model of the hardware sample for sample, at 440.0 Hz on the left and 554.4 Hz on the right. Each side peaks at 4,792, about 15% of the output's range: a sample of 100 at volume 48 gives 100 × 48. On the board, while it plays, AUDSTAT reads `0x33` (ACTIVE 0 and 1, CH 0 and 1) and both channels' AUDxPOS move between reads; a key stops both, leaving AUDDMA `0x00` and DMACON `0x60`. Listening on the jack is still to be done.

---

## Starting and Stopping

### The ways to start and stop a channel

**Table 10-10: Starting and Stopping a Channel**

| To | Write | Takes effect |
|----|-------|--------------|
| Start a channel | Enable it: set its AUDDMA bit, AUDEN or DMAEN, the other two already set | At the next output sample |
| Start it again from its registers, even while it plays | AUDSTART bit n (the channel must be enabled) | At the next output sample |
| Stop a channel | AUDSTOP bit n, or disable it: clear its AUDDMA bit, AUDEN or DMAEN | At once: it is left out of the next output sample |
| Play a block once and stop | AUDxCTRL.ONESHOT, then start the channel | It stops by itself at the end of the block |

**Starting** a channel takes LC and LEN, starts at the first sample of the block, and sets the channel's bit in AUDSTAT (next section). **Stopping** leaves the registers as they are. Nothing needs waiting for: a channel can be stopped and started again in two writes running, and clearing its AUDDMA bit and setting it again straight away starts it again from its registers. Clearing AUDEN stops all four channels; setting it again starts every channel whose AUDDMA bit is set.

### AUDSTART and AUDSTOP

AUDSTART (offset `0x254`, port `0x5412`) and AUDSTOP (offset `0x258`, port `0x5812`) are **strobes**: writing a 1 to a bit acts on that channel, once. They read 0.

**Table 10-11: AUDSTART and AUDSTOP Registers**

| Bits | Name | Meaning |
|------|------|---------|
| 7–4 | – | Write 0 |
| 3–0 | CH | AUDSTART: bit n starts channel n from its registers at the next output sample, even while it plays. AUDSTOP: bit n stops channel n at once |

AUDSTART does nothing to a channel that is not enabled. It is the way to play a **sound effect**: write the effect's LC and LEN to a channel, then its AUDSTART bit, and the channel drops whatever it was playing and starts the effect at the next output sample:

```asm
        ld      bc,AUDSTART_P           ; channel 2 from the start, cutting off what it played
        ld      a,1 << 2
        out     (c),a
```

### One-shot blocks

With **AUDxCTRL.ONESHOT** set, a channel plays its block once and stops at the end, rather than taking LC and LEN again. It sets its AUDSTAT bit as it stops, and stays enabled: AUDSTART plays the block again.

### Sound and reset

Every reset stops every channel, and sets AUDRATE to 2083, and AUDSTAT, AUDINTEN, AUDDMA and DMACON to 0. The channel registers keep their values.

The monitor does not touch the sound. A program that ends with channels playing leaves them playing, in the monitor and in the next program, until something stops them or the machine is reset. So stop your channels before you return. On the board, a copy of Example 10-1 without its step 4 returned to the monitor with AUDSTAT still `0x33`, its positions moving and DMACON `0x62` (AUDEN on); the reset button then left AUDDMA and AUDSTAT `0x00` and DMACON `0x60`.

---

## AUDSTAT and the Sound Interrupt

### AUDSTAT

**AUDSTAT** (offset `0x24C`, port `0x4C12`) tells the program what each channel is doing (Table 10-12).

**Table 10-12: AUDSTAT Register**

| Bits | Name | Meaning |
|------|------|---------|
| 7–4 | ACTIVE | Bit 4 + n: channel n is playing. Read only; follows the channel at once |
| 3–0 | CH | Bit n: channel n took its registers (it was started, or reached the end of a block), or its one-shot block ended. Sticky: write 1 to clear |

A CH bit is set by each of these:

- the channel is **started** (enabled, or by AUDSTART): it has taken LC and LEN, and ACTIVE is 1 (unless LEN was 0);
- it reaches the **end of a block** and takes LC and LEN again, for the next block: ACTIVE stays 1 (unless the new LEN is 0);
- its **one-shot** block ends: ACTIVE is 0.

So after a CH bit sets, ACTIVE tells a start or a new block from a one-shot's end. Stopping a channel does not set its CH bit, except in one rare case: if the hardware is working out that channel's value for the current output sample as it stops, it finishes it, and if that value was the last of a block, the channel takes LC and LEN and sets its bit, but stays stopped.

To clear CH bits, write 1s to them. Writing back the CH bits you read clears exactly the events you have seen; ACTIVE ignores writes:

```asm
        ld      bc,AUDSTAT_P
        in      a,(c)
        and     AUDSTAT_CH_M
        out     (c),a                   ; clear the events seen
```

### The sound interrupt

**AUDINTEN** (offset `0x250`, port `0x5012`) turns AUDSTAT's CH bits into an interrupt (Table 10-13).

**Table 10-13: AUDINTEN Register**

| Bits | Name | Meaning |
|------|------|---------|
| 7–4 | – | Read 0 |
| 3–0 | CH | Bit n: AUDSTAT bit n raises the AUDIO interrupt |

The interrupt is source 9, **AUDIO** (`INT_AUDIO`), in the interrupt controller (Chapter 2): its IM 2 vector is VECBASE + 18, and its enable is INTENA1 bit 2 (`INTR_AUDIO`, `INTB_AUDIO`). It asks while any CH bit with its AUDINTEN bit is set, so the handler clears the bits it has dealt with. By priority it comes after the video and the DMA engine, and before the timers.

Setting it up follows Chapter 2's steps:

```asm
        ld      bc,AUDSTAT_P            ; no old events
        ld      a,AUDSTAT_CH_M
        out     (c),a
        ld      bc,AUDINTEN_P           ; 1. the unit: channel 2's events
        ld      a,1 << 2
        out     (c),a
        ld      bc,INTENA0_P+(INTR_AUDIO<<8)
        ld      a,INTENA_SETCLR_M|(1<<INTB_AUDIO)
        out     (c),a                   ; 2. the controller: AUDIO ...
        ld      bc,INTCON_P
        ld      a,INTCON_MASTER_M
        out     (c),a                   ;    ... and the master enable
        ei                              ; 3. the CPU's
```

A write of 1 to a CH bit clears it even if the channel sets it again in that very clock: that event's interrupt is then lost, though the channel still took its block (spec 13, open point AU2). Clear only the bits you have read, at once, and it cannot happen unless a channel's blocks are a single output sample long.

### Example 10-2: A one-shot sound effect

The program makes a burst of noise that dies away, 4,096 8-bit samples, and channel 2 plays it once, in the centre, at the output rate: 85 ms. Each key plays it again from the start, cutting off the one before. The sound interrupt comes when the channel takes the block (S) and when the block ends (E); the main program prints them. Q ends it. The file is `examples/sound/shot.asm`; here are the parts that are new.

The channel is one-shot, at a step of 1, at full volume both sides:

```asm
chan2:  AUDCHAN AUD_CTRL_ONESHOT_M, NOISE, NLEN, 0x10000, 64, 64
```

The IM 2 table and the interrupt are set up as above, with the handler at entry `INT_AUDIO`. Then the channel is enabled, which plays the sound once at the start:

```asm
        ld      bc,AUDDMA_P             ; enable channel 2 ...
        ld      a,AUDDMA_SETCLR_M | CH2
        out     (c),a
        ld      bc,DMACON_P             ; ... and sound: it plays once now
        ld      a,DMACON_SETCLR_M | DMACON_DMAEN_M | DMACON_AUDEN_M
        out     (c),a
```

Each key but Q writes AUDSTART:

```asm
        ld      bc,AUDSTART_P           ; any other: play it from the start
        ld      a,CH2
        out     (c),a
```

The handler clears the event, then reads ACTIVE to tell a start from an end:

```asm
; AUDIO: channel 2 took its block (it plays: S) or its one-shot block
; ended (it does not: E)
audio:  push    af
        push    bc
        ld      bc,AUDSTAT_P
        in      a,(c)
        push    af
        and     AUDSTAT_CH_M
        out     (c),a                   ; clear the events seen, first
        pop     af
        and     CH2 << AUDSTAT_ACTIVE_B ; channel 2's ACTIVE bit
        ld      a,'S'
        jr      nz,.put
        ld      a,'E'
.put:   ld      (event),a
        pop     bc
        pop     af
        ei
        reti
```

At the end the program clears channel 2's AUDDMA bit, AUDEN, AUDINTEN and AUDSTAT, turns the controller's AUDIO bit and master enable off, and puts back I and VECBASE for the boot ROM's table, as Chapter 2's examples do.

The noise comes from a 16-bit xorshift generator, a byte a sample, made into eight steps of 512 samples, each shifted right once more than the one before: each step is half as loud (6 dB down). Making it takes the Z80 about 41 ms, before the program says anything.

In simulation, with a key 30 ms after the start, another after the sound had ended and Q while it played, the program printed `SSES`: S as the channel was enabled; S again for the restart, with no E, because the cut-off sound never reached its end; E 85 ms later; S for the third. Every output sample matched the model. On the board, the start and three keys printed `SESESESE`, and Q ended the program with AUDDMA `0x00` and DMACON `0x60`. Keys typed through the debug bridge come more than 85 ms apart, so the board run did not catch a restart during the hiss.

---

## Joining Sounds

The registers can be written at any time, but a channel takes LC and LEN only when it starts a block. The moment it takes them, its AUDSTAT bit sets. From then until the end of that block, the registers are free for the **next** block: whatever LC and LEN hold when the block ends is what plays after it, with no gap. This gives four ways to join sounds (Table 10-14).

**Table 10-14: Ways to Join Blocks**

| To play | Do |
|---------|-----|
| A loop | Write LC and LEN once and start the channel: it plays the block over and over |
| A sample with a loop | Write the whole sample and start the channel. When its AUDSTAT bit sets (it has taken the whole sample), write the loop part's LC and LEN. The whole sample plays once, then the loop part for ever |
| A queue | Each time the channel's AUDSTAT bit sets, write the next block. The blocks play one after another with no gap |
| A sound, then silence | When the AUDSTAT bit sets for the last block, write LEN 0: the channel stops at that block's end. Or use ONESHOT |

Figure 10-2 shows a queue of two blocks played in turn.

```
  AUDSTAT bit:   set                     set                     set
                  |                       |                       |
  the channel:    |----- plays block A ---|----- plays block B ---|----- plays block A ...
                  |  takes LC = A         |  takes LC = B         |  takes LC = A
                  |                       |                       |
  the program:    write LC = B            write LC = A            write LC = B
                  (B is ready)            refill A                refill B

                  Figure 10-2: Two Blocks Played in Turn
```

A step that runs past the end of a block carries on into the next block by the amount left over, so the pitch stays even across a join. With interpolation, the channel's last sample of a block is joined to the first sample of the next: the one at LC **as the register then stands**. So a loop is smooth round its join, and so is a queued block, as long as LC was written before the end.

**The time you have** to write the next block is the length of the block that has just started, less the time the interrupt takes to come. A block shorter than that cannot be queued.

### Double buffering

A program that makes its sound as it plays needs only **two buffers** and a queue. The channel plays one buffer while the program fills the other; each time the channel takes a buffer, the program queues the other one and refills it. This is the Amiga's classic double buffering. The buffers can be short, and the sound can go on for ever.

### Example 10-3: A double-buffered stream

The Z80 makes a triangle wave, 8,000 samples a second, climbing a scale of C, a note every quarter second. Channel 0 plays two 256-sample buffers in turn, each 32 ms long, at a step of 10,921 (8,000 Hz). N switches the channel between interpolated and nearest; any other key ends the program. The file is `examples/sound/stream.asm`.

The two buffers are on 256-byte boundaries, `0xA000` and `0xA100`, so only LC's middle byte tells them apart. The program fills the first buffer, sets up the channel to play it, turns on channel 0's interrupt and starts the channel. From then on, the handler does the queuing:

```asm
; AUDIO: channel 0 has just taken a buffer (LC and LEN). Queue the other
; one, which it will take when this one ends, and have the main program
; refill it meanwhile.
audio:  push    af
        push    bc
        ld      bc,AUDSTAT_P
        ld      a,CH0
        out     (c),a                   ; clear the event first
        ld      a,(next)                ; the buffer to queue: its high byte
        ld      bc,AUD0_LC1_P
        out     (c),a                   ; LC's middle byte: the whole change
        ld      (pending),a             ; refill it
        xor     high BUF0 ^ high BUF1   ; the other one next time
        ld      (next),a
        pop     bc
        pop     af
        ei
        reti
```

The first event is the start: the channel has taken `0xA000`, so the handler queues `0xA100` and has it filled with the next 256 samples. At the end of `0xA000` the channel takes `0xA100`, and the handler queues `0xA000` again and has it refilled, while `0xA100` plays. Each buffer is refilled just after the channel has finished with it, 32 ms before it plays again. LEN never changes.

The main program refills the buffer the handler names, and reads the keys. Filling 256 samples takes it about a millisecond. N flips CTRL's NEAREST bit, which takes effect from the next output sample:

```asm
        ld      bc,AUD0_CTRL_P          ; N: interpolated <-> nearest
        in      a,(c)
        xor     AUD_CTRL_NEAREST_M
        out     (c),a                   ; from the next output sample
```

The rest, the IM 2 table, `fill` and the putting back, is as in Example 10-2 or in the file. `fill` makes the triangle from the top byte of a 16-bit phase, which moves on by the note's increment, f × 65536 ÷ 8000, for each sample.

In simulation, 300 ms of the stream, nine buffers and the change of note after the eighth, matched the model sample for sample, with no gap and no step at any join; N, pressed after 100 ms, switched the output to nearest from the next output sample. On the board the console showed "Nearest" and "Interpolated" for two presses of N, AUDxPOS wrapped round as the buffers joined, LC read `0xA000` at one moment and `0xA100` at another, and a key ended the program with AUDDMA `0x00`.

With nearest, each 8,000 Hz sample is held for six output samples, as an Amiga would play it: the steps add images of the tone around 8 kHz and its multiples. Interpolation draws straight lines between the samples and takes most of them away.

---

## Choosing the Pitch

A channel's pitch is the rate at which it moves through its block. For a wave of one cycle in N samples, a note of f Hz needs

    STEP = f × N × 65536 ÷ output rate

Table 10-15 gives the steps for one octave, from middle C, for a 32-sample cycle at the output rate after reset. For the octave above, double them; for the one below, halve them. A cycle of 16 samples needs half these steps, one of 64 samples twice.

**Table 10-15: STEP Values for One Octave, 32-Sample Cycle**

| Note | Frequency (Hz) | STEP | Hex |
|------|----------------|------|-----|
| C | 261.63 | 11,429 | `0x02CA5` |
| C♯ | 277.18 | 12,108 | `0x02F4C` |
| D | 293.66 | 12,828 | `0x0321C` |
| D♯ | 311.13 | 13,591 | `0x03517` |
| E | 329.63 | 14,399 | `0x0383F` |
| F | 349.23 | 15,256 | `0x03B98` |
| F♯ | 369.99 | 16,163 | `0x03F23` |
| G | 392.00 | 17,124 | `0x042E4` |
| G♯ | 415.30 | 18,142 | `0x046DE` |
| A | 440.00 | 19,221 | `0x04B15` |
| A♯ | 466.16 | 20,364 | `0x04F8C` |
| B | 493.88 | 21,574 | `0x05446` |
| C | 523.25 | 22,857 | `0x05949` |

The largest step is just under 16, so a 32-sample cycle goes up to about 24 kHz, well above hearing. The smallest is 1/65536. The step's fraction makes even a short cycle exact in pitch: 19,221 plays A at 440.0 Hz.

**Long and short cycles.** A short cycle, 16 or 32 samples, holds a simple wave: a sine, a square, a sawtooth. A longer one holds a richer sound, but its step for a given note is larger. With a step above 1 the channel skips samples, and harmonics above half the output rate fold back as false tones; keep the step at 1 or below where that matters, by using a shorter cycle for high notes.

**From an Amiga period.** An Amiga MOD file gives a channel's pitch as a period P, in ticks of 3,546,895 Hz (PAL). At the output rate after reset, that is

    STEP = 3,546,895 × 65536 ÷ (P × 48,008) ≈ 4,841,919 ÷ P

so the Amiga's middle C, period 428, is a step of 11,313 (`0x02C31`). A MOD player needs only a table from periods to steps.

### Changing the pitch while a channel plays

STEP takes effect from the next output sample, so a program can slide or wobble the pitch of a playing channel. STEP is written a byte at a time, so an output sample can fall between two of its writes and play at a step that is half old and half new. A change that leaves the upper bytes as they are needs only the low byte written, and has no such moment; for a larger one, write STEP while the channel is stopped, or accept a click at most ("Writing a register a byte at a time", below).

---

## Volume, Pan and the Mixer

### The mixer

For each output sample the four channels are added:

    left  = Σ (channel's value × left volume)  ÷ 256
    right = Σ (channel's value × right volume) ÷ 256

A channel's value is 16 bits signed: an 8-bit sample is taken as its value × 256. So at full volume, 64, one channel gives at most a quarter of the output's range (±8,128 from 8-bit samples), and the four together can never overflow: as on the Amiga, each channel has a quarter of the range to itself. A quiet channel loses nothing to the others.

### Volume

Volume is linear: 32 is half the amplitude of 64. Table 10-16 gives volumes in decibels, the way the ear hears loudness.

**Table 10-16: Volume in Decibels**

| Volume | Below full volume |
|--------|-------------------|
| 64 | 0 dB |
| 45 | 3 dB |
| 32 | 6 dB |
| 16 | 12 dB |
| 8 | 18 dB |
| 4 | 24 dB |
| 2 | 30 dB |
| 1 | 36 dB |
| 0 | Silent |

### Pan

Each channel has its own left and right volume, so a channel can sit anywhere between left and right, and move while it plays. The volumes are separate bytes, VOL0 (right) and VOL2 (left), each taking effect from the next output sample. To move channel 1 from centre to right:

```asm
        ld      bc,AUD1_VOL2_P          ; left down ...
        ld      a,16
        out     (c),a
        ld      bc,AUD1_VOL0_P          ; ... right up
        ld      a,64
        out     (c),a
```

Unlike the Amiga's, no channel is tied to a side: four channels can all play in the centre, or all on one side.

### The outputs

Three outputs are made from the mix: the jack's left and right, and the **speaker**, which plays the two added together and halved. Each is a **sigma-delta** stream: a 1-bit signal at 100 MHz whose average follows the sound, which the board's filter turns back into a smooth wave. How good the result sounds depends on the board's filter, and has not yet been measured (spec 13, open point AU7).

---

## Advanced Topics

### Interpolation and nearest

At each output sample a channel's position is a whole sample number and a fraction. With interpolation (CTRL.NEAREST 0) its value is on the straight line between the sample at the position, s0, and the one after it, s1:

    value = s0 + (s1 − s0) × fraction ÷ 65536        (rounded down)

At a block's last sample, s1 is the first sample of the block to come, the one at LC as the register then stands; for a one-shot block, or when LEN then holds 0, there is no block to come, and s1 is s0. With NEAREST set, the value is s0: each sample is held until the next, as the Amiga plays. NEAREST is for the raw, gritty sound of an old sample; interpolation is smoother whenever the step is below 1. Example 10-3 lets you hear both.

Nearest needs one memory read per output sample, interpolation one or two (two when s0 and s1 are in different words). Either way, the Z80 does not see it.

### 16-bit samples

With CTRL.BITS16 set, each sample is a signed word, low byte first (`DW`), and LC must be even; its bit 0 is ignored. LEN still counts samples. The mixer takes a 16-bit sample as it is, so 16-bit samples have 256 times the resolution of 8-bit ones at the same volume: the quietest sounds stay clean. A 16-bit sample of 32,767 at volume 64 gives 8,191, the same quarter of the range as 127 in 8 bits.

### Changing the output rate

The output rate is the rate at which every channel is worked out and mixed. 48 kHz suits nearly everything. To play 44.1 kHz recordings sample for sample, with a step of exactly `0x10000`, set AUDRATE to 2268 (44,092 Hz):

```asm
        ld      bc,AUDRATE0_P           ; 2268 = 0x08DC: 100 MHz / 2268 = 44,092 Hz
        ld      a,0xDC
        out     (c),a
        inc     b
        ld      a,0x08
        out     (c),a
```

Change it while no channel plays: between the two writes the rate is half old and half new, for at most one output sample. Every channel's step depends on the output rate, so the steps change their meaning with it. A program that changes AUDRATE should put back 2083 when it ends.

### Where a channel is: AUDxPOS

**Table 10-17: AUDxPOS Register**

| Byte | Bits | Meaning |
|------|------|---------|
| AUDxPOS0 (`+0x14`) | 7–0 | Position bits 7–0. Reading this byte captures all three |
| AUDxPOS1 (`+0x15`) | 7–0 | Position bits 15–8, from the capture |
| AUDxPOS2 (`+0x16`) | 7–6 | Read 0 |
| | 5–0 | Position bits 21–16, from the capture |

AUDxPOS is the sample the channel is at, counted from the start of its block (0 is LC). It moves while the channel plays, so **reading its low byte captures all three bytes**, and the other two are read from the capture: read it low byte first, as any capturing counter (Chapter 2). The capture is shared with the other capturing counters, so read with interrupts off if a handler reads them too.

```asm
        ld      bc,AUD0_POS0_P
        in      l,(c)                   ; bits 7-0: captures all three
        inc     b
        in      h,(c)                   ; bits 15-8
        inc     b
        in      a,(c)                   ; bits 21-16
```

A program can use it to keep pictures in step with the sound, or to tell how far a long sample has played. Reading a channel register takes the hardware one clock longer than other registers, but the Z80 never waits for it.

### Writing a register a byte at a time

Each byte of a channel register acts as soon as it is written. Mostly that does not matter, but three cases need care:

- **STEP** taken between two of its byte writes plays one output sample at a step half old and half new: a click at most. Write it while the channel is stopped, or accept that.
- **LC and LEN** are taken only at a block's start. Write them just after the channel's AUDSTAT bit sets, and the channel will not take them again before its block ends. LC half written at a block's last sample would join that one output sample to a wrong sample. Example 10-3 avoids it: its buffers differ only in one byte of LC.
- **AUDRATE**, as above.

(Spec 13, open point AU9.)

### The beeper

The Spectrum's beeper is still there: bit 4 of port `0xFE` (`ULA_BEEPER_M`), with the border colour in bits 2–0 (Chapter 1). It is added to both sides of the mix after the channels, at a quarter of the output's range: +`0x2000` while the bit is 1 and −`0x2000` while it is 0. The sum is clipped to 16 bits. Old Spectrum code that toggles the bit plays as it always did, over any channels:

```asm
        ld      a,ULA_BEEPER_M | 1      ; beeper bit 1, border blue
        out     (ULA_PORT),a
```

The beeper's bit is 0 after reset, so with the beeper silent the mix sits a steady quarter of the range below the middle; the board's coupling capacitor blocks a steady level, so it is not heard. But the four channels together near full volume can then clip at the negative end (spec 13, open point AU4).

### Sound from the copper

The copper can write the sound registers, to change a volume or a step at the same point in every frame with no work for the Z80. They are above its MOVE's reach, so it uses MOVEF, one byte per instruction (Chapter 5):

```asm
        CMOVEF  AUD0_VOL0,32            ; channel 0's right volume to 32
        CMOVEF  AUD0_VOL2,32            ; ... and its left
```

A channel register is also in the register page, at offset `0x1000` plus its custom offset (Chapter 1, "The register page"), so `LD HL,(nn)` can read two bytes of it in one instruction.

---

## Sound Timing

**Table 10-18: Sound Timing**

| What | Time |
|------|------|
| An output sample, after reset | 2083 clocks of 100 MHz: 20.83 µs (48,008 Hz) |
| A start (enable or AUDSTART) | At the next output sample: within 20.83 µs |
| A stop (AUDSTOP, or disabling) | At once: the channel is left out of the next output sample |
| CTRL, STEP, VOL | From the next output sample |
| LC, LEN | When the channel next starts a block |
| The interrupt | As the channel takes its block, or as a one-shot block ends. The Z80 answers within 2.1 µs, or later while the boot ROM's calls hold interrupts off (Chapter 2, "Timing") |
| Memory | One or two 16-bit reads per playing channel per output sample: at most 384,000 reads a second at 48 kHz, under 1 MB/s, from sound's own cycle. The Z80 is never slowed |

A block of 256 samples at a step of 1 lasts 5.3 ms at the output rate after reset; at 8,000 Hz, as in Example 10-3, 32 ms. Both are far longer than the interrupt takes to come.

---

## What the Sound Hardware Cannot Do

- **One channel cannot modulate another.** The Amiga's attached channels, one channel driving another's volume or period, are not built. A program changes VOL or STEP itself, or with the copper.
- **No reset values.** The channel registers keep whatever was last written (spec 13, open point AU1). Write them all before starting a channel.
- **One output rate.** Every channel is resampled to it; a channel has no rate of its own.
- **Signed PCM only.** No unsigned samples, no compressed formats.
- **No sound over HDMI.** Sound comes out of the jack and the speaker only (spec 13, open point AU8).
- **No reading of the output.** A program cannot read back the mixed sound.

---

## Comparison with the Amiga

**Table 10-19: Sound Here and on the Amiga**

| Item | Amiga (Paula) | This machine |
|------|---------------|--------------|
| Channels | 4 | 4 |
| Samples | 8-bit signed | 8-bit or 16-bit signed, per channel |
| Pitch | Each channel's own rate, set by its period AUDxPER | Every channel resampled to one output rate, by its step AUDxSTEP |
| Between samples | Each sample held | Interpolated, or held (NEAREST) |
| Volume | 0–64, one per channel | 0–64, left and right per channel |
| Pan | Hard: channels 0 and 3 left, 1 and 2 right | Any, per channel |
| Address and length | AUDxLC, AUDxLEN in words; taken at the start and at each block's end | AUDxLC, AUDxLEN in samples; the same rule |
| Interrupt | One per channel, when it takes its registers | One source, AUDIO, with a bit per channel in AUDSTAT; also when a one-shot block ends |
| Starting and stopping | DMACON's AUDxEN bits; a wait is needed between stopping and starting | AUDDMA with DMACON.AUDEN; AUDSTART and AUDSTOP; no waiting |
| One-shot | Queue a short block of silence | CTRL.ONESHOT |
| Modulation | Attached channels (ADKCON) | Not built |
| Output | Four DACs and a filter | A sigma-delta stream per side, and the speaker |

An Amiga program's structure carries over: set LC, LEN, volume and pitch, turn the channel on, and feed it from the interrupt as it takes each block.

---

## Summary of Sound Registers

Custom offsets; the Z80's port is (offset bits 7–0) × 256 + `0x12`. Access: R read only, W write only, RW read and write, W1C sticky flags cleared by writing 1, SC set/clear, S strobe, CAP reading the low byte captures.

**Table 10-20: Sound Registers**

| Name | Offset | Port | Access | Function |
|------|--------|------|--------|----------|
| AUDRATE | `0x244`–`0x245` | `0x4412`–`0x4512` | RW | RATE (15–0): an output sample every RATE clocks of 100 MHz. 2083 after reset; below 200 acts as 200 |
| AUDSTAT | `0x24C` | `0x4C12` | R, W1C | ACTIVE (7–4): channel playing. CH (3–0): channel took its registers, or its one-shot block ended |
| AUDINTEN | `0x250` | `0x5012` | RW | CH (3–0): AUDSTAT bit raises AUDIO |
| AUDSTART | `0x254` | `0x5412` | S | CH (3–0): start the channel from its registers at the next output sample. Reads 0 |
| AUDSTOP | `0x258` | `0x5812` | S | CH (3–0): stop the channel at once. Reads 0 |
| AUDDMA | `0x25C` | `0x5C12` | SC | SETCLR (7); CH (3–0): channel enables |
| AUDxCTRL | `+0x00` | | RW | ONESHOT (3), NEAREST (2), BITS16 (1) |
| AUDxLC | `+0x04`–`+0x06` | | RW | ADDR (21–0): the block's physical address |
| AUDxLEN | `+0x08`–`+0x0A` | | RW | LEN (21–0): the block's length in samples; 0 stops |
| AUDxSTEP | `+0x0C`–`+0x0E` | | RW | STEP (19–0): samples per output sample, 4.16 |
| AUDxVOL | `+0x10`–`+0x12` | | RW | R (6–0) in byte 0, L (6–0) in byte 2: 0–64 |
| AUDxPOS | `+0x14`–`+0x16` | | R, CAP | POS (21–0): the sample the channel is at |
| DMACON | `0x00C` | `0x0C10` | SC | DMAEN (6) and AUDEN (1) must be set for any channel to play |

Channel x's registers are at `0x280` + x × `0x20` plus the offset; their ports at `0x8012` + x × `0x2000` plus the offset × 256 (AUD0_CTRL `0x8012`, AUD3_POS2 `0xF612`). The other offsets in `0x240`–`0x2FF` are reserved: they read `0xFF`, and writing them does nothing.

The sound interrupt is source 9, AUDIO: any AUDSTAT CH bit with its AUDINTEN bit, at IM 2 table entry 9 (VECBASE + 18). It must also be enabled in INTENA1 (bit 2), with INTCON.MASTER on.

### State after reset, and when a program starts

**Table 10-21: Sound State After Reset and at Program Start**

| Register | After reset | When a program starts |
|----------|-------------|-----------------------|
| AUDRATE | 2083: 48,008 Hz | 2083, unless an earlier program changed it |
| AUDSTAT, AUDINTEN | 0 | AUDINTEN 0; AUDSTAT as an earlier program left it |
| AUDDMA, DMACON.AUDEN | 0: every channel stopped | 0, unless an earlier program left sound playing |
| The channel registers | Kept: at power-on CTRL 0, LC 0, LEN 0, STEP `0x10000`, VOL 0 | Whatever was last written |
| The beeper (port `0xFE` bit 4) | 0 | 0 |

### Equates in hw.inc

**Table 10-22: Sound Equates in hw.inc**

| Name | Meaning |
|------|---------|
| `AUDRATE`, `AUDSTAT`, `AUDINTEN`, `AUDSTART`, `AUDSTOP`, `AUDDMA` | The global registers' custom offsets, for the copper |
| `AUDRATE0_P`, `AUDRATE1_P`, `AUDSTAT_P` … `AUDDMA_P` | Their ports, for the Z80 |
| `AUDSTAT_CH_M`, `AUDSTAT_ACTIVE_M`, `AUDSTAT_ACTIVE_B`; `AUDDMA_SETCLR_M`, `AUDDMA_CH_M` | Their bits |
| `AUD0` … `AUD3`, `AUD_NUM`, `AUD_SPAN` | The channels' custom offsets, their number (4) and spacing (`0x20`) |
| `AUD_CTRL`, `AUD_LC`, `AUD_LEN`, `AUD_STEP`, `AUD_VOL`, `AUD_POS` | A register's offset within a channel |
| `AUD0_CTRL_P`, `AUD0_LC0_P` … `AUD3_POS2_P` | Every channel register byte's port |
| `AUD0_CTRL`, `AUD0_LC0` … `AUD3_POS2` | Their custom offsets, for the copper (`CMOVEF AUD0_VOL0,32`) |
| `AUD_CTRL_BITS16_M`, `AUD_CTRL_NEAREST_M`, `AUD_CTRL_ONESHOT_M` | CTRL's bits |
| `DMACON_AUDEN_M`, `DMACON_DMAEN_M`, `DMACON_SETCLR_M` | DMACON's sound bits |
| `INT_AUDIO`, `INTR_AUDIO`, `INTB_AUDIO` | The sound interrupt's source, its INTENA byte and bit |
| `ULA_PORT`, `ULA_BEEPER_M` | The beeper's port and bit |
