# Chapter 8: Keyboards and Joysticks

## Introduction

retro-z80 reads its input three ways, and a program can use any of them, or all at once:

- the **membrane keyboard** on the KS3's case, a matrix of 56 keys that the hardware scans for you;
- a **PS/2 keyboard** plugged into the PS/2 socket, whose bytes the hardware receives into a small FIFO;
- two **joystick ports**, for Atari-style sticks and Mega Drive pads.

On top of these sit the **Spectrum extras**: port `0xFE` reads the keyboard rows exactly as a Spectrum does, with the PS/2 keyboard's keys mapped onto them, and port `0x1F` reads joystick 1 as a Kempston interface. So a program written the Spectrum way works with either keyboard, and with a joystick, unchanged.

A fourth source is the PC: keys typed in VS Code, or sent by the bridge's MCP tools, go down the USB link and come out of the PS/2 keyboard's side as if a PS/2 keyboard had sent them.

This chapter covers:

- which way to read the keys, and when;
- the membrane's matrix, and reading it the Spectrum way through port `0xFE`, with KEYCON;
- the whole membrane at once: KEYMAP0–6, KEYROW0–7 and the extra keys;
- the PS/2 keyboard: its registers, the FIFO and scan codes;
- how PS/2 keys reach port `0xFE`;
- keys typed from the PC;
- the boot ROM's key calls;
- the joysticks and the Kempston port;
- two complete programs, built step by step: the border from the number keys, and the PS/2 scan codes;
- advanced topics: sending to the keyboard, the keyboard's interrupt, Mega Drive pads;
- what the hardware cannot do, or does not do yet;
- a summary of the registers.

You should know how the Z80 reaches the registers through ports (see "Reaching the registers from the Z80" in the Playfield Hardware chapter). The keyboard's interrupt belongs to the Interrupts and Timers chapter; this chapter reads the keys by polling.

---

## Conventions in This Chapter

- Examples are Z80 assembly language for sjasmplus and start with `include "hw.inc"`. Numbers in the text are hexadecimal when they start with `0x`.
- Registers are reached through their ports: `ld bc,KBSTAT_P` then `in a,(c)`. The ports that answer whatever the high byte holds have their own names; this chapter uses three of them: `ULA_PORT` (`0xFE`), `KEMPSTON_PORT` (`0x1F`) and `KBDATA_PORT` (`0x62`), so `in a,(ULA_PORT)` works.
- **1 = pressed** everywhere except port `0xFE` and KEYROW0–7, which keep the Spectrum's 0 = pressed.
- The complete examples are in `examples/io/`, loaded at `0x8000` and run from the monitor or VS Code. They use the boot ROM's calls to print (`RST 18h` PUTS, `RST 28h` PUTHEX) and return to the monitor with `RET`.

---

## Which Way to Read the Keys

Table 8-1 shows which way of reading sees which keys.

**Table 8-1: Ways to Read the Keys**

| You want | Read | Sees the membrane | Sees a PS/2 keyboard | Sees keys from the PC |
|----------|------|-------------------|----------------------|-----------------------|
| Keys held now, for a game | Port `0xFE` (or KEYROW0–7) | The 40 Spectrum keys, and the extra keys as Spectrum pairs | Yes, mapped onto Spectrum keys | Yes, as PS/2 keys |
| Every membrane key on its own | KEYMAP0–6 | All 56 | No | No |
| Every PC key, presses and releases | KBDATA, the PS/2 FIFO | No | Yes, as scan codes | Yes |
| Characters, for text | The ROM's GETC and POLLC | Yes | Yes | Yes (and the serial console) |
| A joystick | JOY1, JOY2, or Kempston port `0x1F` | – | – | – |

A game usually reads **port `0xFE`**: it shows which keys are held, it works with both keyboards and with the PC, and Spectrum code already does it. A program that wants text uses **the ROM's calls**, which turn keys into characters and repeat them. A program that wants every PC key, the function keys and the releases reads the **PS/2 FIFO** itself.

---

## The Spectrum Way: Port 0xFE

### The membrane's matrix

The membrane is a matrix of 8 **rows** and 7 **columns**, 56 keys (Figure 8-1). Columns 0–4 hold the Spectrum's 40 keys, in the Spectrum's own layout. Columns 5–6 hold the KS3's 16 extra keys. Each row is picked by one line of the high byte of the port address, A8 for row 0 up to A15 for row 7: that line at 0 picks the row.

```
                       extra keys        Spectrum keys
 Line  High byte  Row   col 6   col 5     col 4 col 3 col 2 col 1 col 0
                      +-------+-------+ +-----+-----+-----+-----+-----+
 A8    0xFE        0  |  UP   |  EXT  | |  V  |  C  |  X  |  Z  | CS  |
                      +-------+-------+ +-----+-----+-----+-----+-----+
 A9    0xFD        1  | GRAPH |CAPS LK| |  G  |  F  |  D  |  S  |  A  |
                      +-------+-------+ +-----+-----+-----+-----+-----+
 A10   0xFB        2  |  INV  | TRUE  | |  T  |  R  |  E  |  W  |  Q  |
                      +-------+-------+ +-----+-----+-----+-----+-----+
 A11   0xF7        3  | EDIT  | BREAK | |  5  |  4  |  3  |  2  |  1  |
                      +-------+-------+ +-----+-----+-----+-----+-----+
 A12   0xEF        4  |   "   |   ;   | |  6  |  7  |  8  |  9  |  0  |
                      +-------+-------+ +-----+-----+-----+-----+-----+
 A13   0xDF        5  |   .   |   ,   | |  Y  |  U  |  I  |  O  |  P  |
                      +-------+-------+ +-----+-----+-----+-----+-----+
 A14   0xBF        6  | RIGHT |  DEL  | |  H  |  J  |  K  |  L  | ENT |
                      +-------+-------+ +-----+-----+-----+-----+-----+
 A15   0x7F        7  | DOWN  | LEFT  | |  B  |  N  |  M  | SS  | SPC |
                      +-------+-------+ +-----+-----+-----+-----+-----+
                       KEYMAP6 KEYMAP5   bit 4 bit 3 bit 2 bit 1 bit 0
                                         of port 0xFE

                   Figure 8-1: The Membrane's Matrix
```

In Figure 8-1, CS is CAPS SHIFT, SS SYMBOL SHIFT, ENT ENTER, SPC SPACE; EXT is EXTEND MODE, CAPS LK CAPS LOCK, TRUE and INV are TRUE VIDEO and INV VIDEO, DEL is DELETE, and UP, DOWN, LEFT and RIGHT are the cursor keys. Port `0xFE` reads columns 0–4; KEYMAP0–6 read every column (see "The Whole Membrane: KEYMAP0–6").

### Reading port 0xFE

Port `0xFE` is the Spectrum's keyboard. The high byte of the port address picks the rows, and the low 5 bits of the answer say which keys in those rows are held, **0 = pressed** (Table 8-2):

**Table 8-2: Port 0xFE Keyboard Rows**

| Row | High byte | Bit 4 | Bit 3 | Bit 2 | Bit 1 | Bit 0 |
|-----|-----------|-------|-------|-------|-------|-------|
| 0 | `0xFE` | V | C | X | Z | CAPS SHIFT |
| 1 | `0xFD` | G | F | D | S | A |
| 2 | `0xFB` | T | R | E | W | Q |
| 3 | `0xF7` | 5 | 4 | 3 | 2 | 1 |
| 4 | `0xEF` | 6 | 7 | 8 | 9 | 0 |
| 5 | `0xDF` | Y | U | I | O | P |
| 6 | `0xBF` | H | J | K | L | ENTER |
| 7 | `0x7F` | B | N | M | SYMBOL SHIFT | SPACE |

The byte read has the fields of Table 8-3.

**Table 8-3: Port 0xFE Read Bits**

| Bits | Name | Meaning |
|------|------|---------|
| 7 | – | Reads 1 |
| 6 | EAR | KEYCON.EAR6: a fixed value, 1 after reset |
| 5 | – | Reads 1 |
| 4–0 | Keys | One column each (Table 8-2), 0 = a key in that column is held in a selected row |

`IN A,(n)` puts A on the high half of the address, and `IN r,(C)` puts B there, so either picks the rows:

```asm
        ld      a,0xF7                  ; row 3: 1 2 3 4 5
        in      a,(ULA_PORT)            ; bits 4-0: 0 = held         (11 T)
        bit     2,a                     ; the 3 key
        jr      z,three_held
```

Bits 7–5 are not keys (Table 8-3): bit 6 is the Spectrum's EAR input, a fixed value here. So mask the answer with `0x1F` before comparing it.

**Several rows at once.** A high byte with more than one 0 bit reads those rows together: a bit is 0 if the key in that column is held in **any** of them. `0x00` reads every row, which is a quick way to ask "is anything held?":

```asm
        xor     a                       ; every row
        in      a,(ULA_PORT)
        and     0x1F
        cp      0x1F
        jr      nz,something_held
```

Reading port `0xFE` changes nothing, so read it as often as you like.

### Writing port 0xFE

Writing port `0xFE` sets the border colour (bits 2–0, a Spectrum colour, at once) and the beeper (bit 4), as on a Spectrum. Every write sets both.

**Table 8-4: Port 0xFE Write Bits**

| Bits | Name | Meaning |
|------|------|---------|
| 7–5 | – | Ignored |
| 4 | EAR | The beeper |
| 3 | MIC | Ignored (the Spectrum's tape output) |
| 2–0 | Border | The border colour, a Spectrum colour 0–7, at once |

For example, border magenta (3) with the beeper's bit at 1:

```asm
        ld      a,0x10 | 3              ; EAR 1, border 3 (magenta)
        db      0x3E,0x13               ; the same instruction: LD A,0x13
        out     (ULA_PORT),a
```

### KEYCON: the Spectrum extras

KEYCON (register `0x6B`, port `0x6B00`) switches the Spectrum extras of this chapter. All three bits are 1 after reset (`0x07`).

**Table 8-5: KEYCON Bits**

| Bits | Name | Meaning |
|------|------|---------|
| 7–3 | – | Read 0 |
| 2 | PS2MAP | PS/2 keys also show on port `0xFE` and KEYROW0–7 (see "PS/2 Keys on Port 0xFE") |
| 1 | EAR6 | The value of port `0xFE` bit 6 |
| 0 | KXMAP | The membrane's extra keys also show on port `0xFE` as Spectrum key pairs (see "The extra keys") |

A game that wants the extra keys as keys of their own clears KXMAP and keeps the rest:

```asm
        ld      a,KEYCON_EAR6_M | KEYCON_PS2MAP_M   ; KXMAP 0, EAR6 1, PS2MAP 1
        db      0x3E,0x06                           ; the same instruction: LD A,0x06
        ld      bc,KEYCON_P
        out     (c),a
```

Put `0x07` back before the program ends.

---

## The Whole Membrane: KEYMAP0–6

The hardware scans the whole matrix of Figure 8-1 all the time, about every half millisecond, and debounces it, so a read always gives a settled answer whatever the CPU speed.

**KEYMAP0–6** (registers `0x10`–`0x16`, ports `0x1000`–`0x1600`) give the whole membrane, one register per column, **1 = pressed**: bit r of KEYMAPc is the key at row r, column c. Table 8-6 gives every key.

**Table 8-6: KEYMAP0–6 Bits**

| Register | Bit 7 | Bit 6 | Bit 5 | Bit 4 | Bit 3 | Bit 2 | Bit 1 | Bit 0 |
|----------|-------|-------|-------|-------|-------|-------|-------|-------|
| KEYMAP0 | SPACE | ENTER | P | 0 | 1 | Q | A | CAPS SHIFT |
| KEYMAP1 | SYMBOL SHIFT | L | O | 9 | 2 | W | S | Z |
| KEYMAP2 | M | K | I | 8 | 3 | E | D | X |
| KEYMAP3 | N | J | U | 7 | 4 | R | F | C |
| KEYMAP4 | B | H | Y | 6 | 5 | T | G | V |
| KEYMAP5 | Cursor left | DELETE | `,` | `;` | BREAK | TRUE VIDEO | CAPS LOCK | EXTEND MODE |
| KEYMAP6 | Cursor down | Cursor right | `.` | `"` | EDIT | INV VIDEO | GRAPH | Cursor up |

The bit number is the row of Table 8-2: KEYMAP0 bit 0 is CAPS SHIFT, bit 1 is A, bit 7 is SPACE. To read all seven:

```asm
; the membrane's 56 keys to (HL): 7 bytes, 1 = pressed
        ld      bc,KEYMAP0_P            ; B = register 0x10, C = page 0x00
        ld      d,7
.col:   ini                             ; (HL) = KEYMAPn, HL + 1, B - 1 ...
        inc     b                       ; ... so put B back
        inc     b                       ; and step to the next register
        dec     d
        jr      nz,.col
```

(`INIR` does not suit: it counts B down, and B is the register number.)

KEYMAP0–6 show the membrane **alone**: PS/2 keys and keys from the PC never appear in them. Use them for a key map of your own, or to tell the extra keys apart.

### The extra keys

The KS3's 16 extra keys are in KEYMAP5 and KEYMAP6 (Table 8-6, the last two rows).

With **KEYCON.KXMAP** set (after reset), each extra key also shows on port `0xFE` as the Spectrum key pair it stands for: the cursor keys as CAPS SHIFT + 5, 6, 7, 8, DELETE as CAPS SHIFT + 0, BREAK as CAPS SHIFT + SPACE, EDIT as CAPS SHIFT + 1, `;` `"` `,` `.` as SYMBOL SHIFT + O, P, N, M, and so on (the input spec, section 8.2, has the full table). Spectrum code then sees the keys it expects. A game that wants the cursor keys without CAPS SHIFT clears KXMAP and reads KEYMAP5 and KEYMAP6.

### KEYROW0–7

KEYROW0–7 give each port `0xFE` row on its own, in port `0xFE`'s format (0 = pressed, PS/2 keys and extra keys included), for code that reads memory rather than ports. They are in the register page only, at offsets `0x0100`–`0x0107`, so a program that maps the register page can copy all eight rows with one `LDIR`.

---

## The PS/2 Keyboard

Any PS/2 keyboard plugs into the PS/2 socket. It sends **scan codes** (set 2): a byte, or `E0` and a byte for the grey keys, as a key goes down; the same with `F0` before the last byte as it comes up. Held down, a key repeats its down code, about ten times a second after half a second. The hardware checks each byte's parity and frame and keeps good ones in a 16-byte FIFO; software reads and decodes them.

### The registers

Six registers, KBCON to KBIRQEN (registers `0x60`–`0x65`), drive the keyboard; Table 8-19 in the summary gives their ports and access. KBCON turns the FIFO on (Table 8-7), KBSTAT counts the bytes waiting (Table 8-8), KBDATA gives them, KBSEND sends a byte to the keyboard (see "Sending to the keyboard" under Advanced Topics), and KBIRQ and KBIRQEN hold the flags and their interrupt enables (Table 8-9).

**Table 8-7: KBCON Bits**

| Bits | Name | Meaning |
|------|------|---------|
| 7–1 | – | Read 0 |
| 0 | EN | 1: the FIFO on. 0: the FIFO off; turning it off empties it |

**Table 8-8: KBSTAT Bits**

| Bits | Name | Meaning |
|------|------|---------|
| 7 | TXBUSY | 1: a byte is going to the keyboard |
| 6–5 | – | Read 0 |
| 4–0 | COUNT | Bytes waiting in the FIFO, 0–16 |

**Table 8-9: KBIRQ and KBIRQEN Bits**

| Bits | Name | Meaning |
|------|------|---------|
| 7–5 | – | Read 0 |
| 4 | TIMEOUT | A byte sent was not taken within 15 ms. Sticky, write 1 to clear |
| 3 | OVERFLOW | A byte arrived to a full FIFO and was dropped. Sticky, write 1 to clear |
| 2 | FRAME | A byte with a bad start or stop bit was dropped. Sticky, write 1 to clear |
| 1 | PARITY | A byte with bad parity was dropped. Sticky, write 1 to clear |
| 0 | DATA | 1 while the FIFO holds bytes (live; writes ignored) |

In KBIRQEN each bit enables the interrupt for the KBIRQ bit of the same name.

The boot ROM starts a program with KBCON.EN on and the keyboard's interrupt off, so the FIFO is already filling.

### Reading the FIFO

Check KBSTAT.COUNT, then read KBDATA. Reading KBDATA takes one byte. An empty FIFO reads `0x00` and takes nothing; but a keyboard also sends `0x00` (it means its own buffer overflowed), so KBDATA alone cannot say the FIFO is empty: check COUNT first:

```asm
        ld      bc,KBSTAT_P
        in      a,(c)
        and     KBSTAT_COUNT_M          ; bytes waiting
        jr      z,none
        in      a,(KBDATA_PORT)         ; take one
```

KBDATA ignores the high byte, so `INIR` with B = COUNT takes every byte waiting at once:

```asm
; every PS/2 byte waiting to (HL); B = how many
        ld      bc,KBSTAT_P
        in      a,(c)
        and     KBSTAT_COUNT_M
        jr      z,.none
        ld      b,a
        ld      c,KBDATA_PORT
        inir
.none:
```

Every read of KBDATA takes a byte, whichever way it is reached. A byte with a bad parity or frame is dropped (KBIRQ.PARITY or FRAME); a byte arriving to a full FIFO is dropped too (OVERFLOW). Sixteen bytes is several keys, so a program that reads the FIFO once a frame loses nothing to ordinary typing.

### Scan codes

**Table 8-10: Set 2 Scan Codes**

| The keyboard sends | Meaning |
|--------------------|---------|
| `1C` | A down |
| `F0 1C` | A up |
| `12` | Left Shift down |
| `F0 12` | Left Shift up |
| `E0 75` | Cursor up down |
| `E0 F0 75` | Cursor up up |
| `E1 14 77 E1 F0 14 F0 77` | Pause, pressed (it has no release) |
| `AA` | Self-test passed: sent when the keyboard is plugged in or reset |
| `FA` | Acknowledge, after a byte sent to the keyboard |

Shift is a key like any other: a capital A is Shift down, A down, A up, Shift up. As the bytes in the FIFO:

```asm
        db      0x12, 0x1C, 0xF0,0x1C, 0xF0,0x12    ; Shift down, A down, A up, Shift up
```

Software keeps track of the shift keys itself. A real decoder turns the codes into characters with a layout table, keeps the shift keys' state, and ignores Pause's `E1` sequence. The boot ROM's decoder (`firmware/boot/keys.asm`, `ps2key` and its tables `ps2tab` and `ps2tab_s`) does this for a UK layout.

---

## PS/2 Keys on Port 0xFE

With **KEYCON.PS2MAP** set (after reset), a key held on the PS/2 keyboard also shows on port `0xFE` as the Spectrum key, or pair of keys, it stands for. A **mapper** in the hardware watches the bytes the keyboard sends, follows `E0` and `F0`, and keeps a held bit for each key it knows. So a Spectrum game can be played on a PS/2 keyboard with no help from software. Table 8-11 gives the map.

**Table 8-11: PS/2 Keys on Port 0xFE**

| PS/2 key | Spectrum key(s) |
|----------|-----------------|
| A–Z, 0–9 (the main row and the keypad) | The same key |
| Enter, keypad Enter | ENTER |
| Space | SPACE |
| Either Shift | CAPS SHIFT |
| Either Ctrl, either Alt | SYMBOL SHIFT |
| Backspace | CAPS SHIFT + 0 (DELETE) |
| The cursor keys | CAPS SHIFT + 5, 6, 7, 8 |
| Esc | CAPS SHIFT + SPACE (BREAK) |
| Caps Lock | CAPS SHIFT + 2 |
| Tab | CAPS SHIFT + SYMBOL SHIFT (EXTEND MODE) |
| `,` `.` `;` `'` `/` `-` `=` | SYMBOL SHIFT + N, M, O, 7, V, J, L |

- The mapper watches the bytes **before** the FIFO, so it works whether KBCON.EN is on or off, and whatever the program does with KBDATA. A program can read port `0xFE` and the FIFO side by side.
- Its held keys are let go at reset, when PS2MAP is cleared, and when the keyboard sends `AA` (plugged in again), so a key cannot stay stuck.
- What the map leaves out is in "What It Cannot Do, or Not Yet".

---

## Keys from the PC

The PC can type on the board. Each key goes down the USB link as the **KEY** control command, which the FPGA turns into a PS/2 byte as if the PS/2 keyboard had sent it: a key's down code as it goes down, its up code as it comes up. The hardware decodes KEY itself, so it works whether the program is running, stopped in the debugger, or hung.

To the program, keys from the PC **are** PS/2 keys:

**Table 8-12: Where Keys from the PC Arrive**

| Where | Sees keys from the PC |
|-------|------------------------|
| The PS/2 FIFO (KBDATA) | Yes, as scan codes: Example 8-2 prints them |
| Port `0xFE` and KEYROW0–7 | Yes, through the mapper: Example 8-1 works |
| The ROM's GETC, POLLC and the monitor | Yes |
| KEYMAP0–6 | No: they are the membrane alone |

The PC side:

- **VS Code:** open **retro-z80: Show Screen**, the board's picture through a USB HDMI capture device, and click it. The keys you press go to the board, down and up, until you click elsewhere.
- **MCP:** the bridge's tools `key_down`, `key_up` and `type_text`, so Claude can type on the board and look at the result with `screen_capture`. Both examples in this chapter were tried this way.

Both need the bridge running (`tools/rz80_bridge.py`, which VS Code starts for a debug session). The KEY command itself is in the serial spec, section 4.

---

## The Boot ROM's Key Calls

For text, let the ROM do the work. Its console reads the serial link, the PS/2 keyboard and the membrane, turns keys into **key codes** (ASCII, plus codes above 127 for the cursor, editing and function keys), and repeats a held key.

**Table 8-13: Boot ROM Key Calls**

| Call | Does |
|------|------|
| `RST 10h` GETC | Waits for a key; A = its code |
| `RST 20h` POLLC | NZ and A = a key's code if one was waiting; Z if not. Never waits |
| `RST 28h` GETLINE (`0x05`) | Reads a line with the monitor's editing |
| `RST 28h` CONMODE (`0x0E`) | Which sources the ROM reads keys from (bit 2 the keyboards, bit 3 the serial link) |

The PS/2 keyboard is decoded with a UK layout. GETC and POLLC take bytes from the PS/2 FIFO, so a program uses either the ROM's calls or its own reads of KBDATA, not both. Port `0xFE` is never affected: the ROM's reads change nothing there. The boot ROM spec, section 7.4, lists every key code.

---

## The Joysticks

The KS3 has two 9-pin joystick ports. The hardware reads both, all the time, and keeps the result in two registers, JOY1 (`0x6600`) and JOY2 (`0x6700`), **1 = pressed**:

**Table 8-14: JOY1 and JOY2 Bits**

| Bits | Name | Meaning |
|------|------|---------|
| 7 | START | A Mega Drive pad's START |
| 6 | A | A Mega Drive pad's A |
| 5 | FIRE2 | Fire 2, or a pad's C |
| 4 | FIRE1 | Fire 1, or a pad's B |
| 3 | UP | Up |
| 2 | DOWN | Down |
| 1 | LEFT | Left |
| 0 | RIGHT | Right |

The low five bits are in the **Kempston** order, and **port `0x1F`** reads joystick 1 as a Kempston interface, with any high byte:

```asm
        in      a,(KEMPSTON_PORT)       ; joystick 1, 1 = pressed
        bit     KEMPSTON_FIRE1_B,a
        jr      nz,fire
        and     KEMPSTON_LEFT_M | KEMPSTON_RIGHT_M
        ...
```

An Atari one-button stick gives bits 0–4; a two-button stick adds Fire 2. Bits 6 and 7 are a Mega Drive pad's A and START (see "Mega Drive pads" under Advanced Topics), and read 0 with a stick, so a Spectrum game that compares the whole byte with 0 sees only what is pressed.

---

## Reading the Keys, Step by Step

The parts come together in two complete programs. Example 8-1 reads held keys through port `0xFE`, as a game does, so it works with every keyboard and with the PC. Example 8-2 reads every key going down and up from the PS/2 FIFO.

### Example 8-1: The border from the number keys

The program reads the keys 0–7 and sets the border to the colour of whichever is held. CAPS SHIFT and SPACE together, the Spectrum's BREAK, end it. On a PS/2 keyboard, or from the PC, Esc is BREAK.

It is built in four steps:

1. For each colour 0–7, read the row of that number key and test its column (the table `keys`, from Table 8-2).
2. If the key is held, write its colour to port `0xFE` (Table 8-4).
3. Read rows 0 and 7 one at a time; if CAPS SHIFT and SPACE are not both held, go back to step 1.
4. Put the border back to black, as the boot ROM left it, and return to the monitor.

```asm
; Example 8-1 (docs/guide/io.md): the border from the number keys.
; Keys 0-7 set the border to that Spectrum colour, read through port 0xFE
; the way a Spectrum reads its keyboard, so the membrane, a PS/2 keyboard
; and keys typed from the PC all work. BREAK (CAPS SHIFT + SPACE, or Esc
; on a PS/2 keyboard) puts the border back to black and goes back to the
; monitor.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

start:
.scan:  ld      hl,keys
        ld      e,0                     ; E = the colour of the key being tested
.key:   ld      a,(hl)                  ; the row's address byte: 0 in the row's bit
        in      a,(ULA_PORT)            ; A = that row, 0 = pressed (A15-A8 pick the row)
        inc     hl
        and     (hl)                    ; this key's column
        inc     hl
        jr      nz,.next                ; 1: not pressed
        ld      a,e
        out     (ULA_PORT),a            ; bits 2-0 the border, bit 4 the beeper (0)
.next:  inc     e
        ld      a,e
        cp      8
        jr      nz,.key

        ld      a,0xFE                  ; row 0: CAPS SHIFT is bit 0
        in      a,(ULA_PORT)
        rra
        jr      c,.scan
        ld      a,0x7F                  ; row 7: SPACE is bit 0
        in      a,(ULA_PORT)
        rra
        jr      c,.scan

        xor     a                       ; both held: BREAK. Put the border back to
        out     (ULA_PORT),a            ; black, as the boot ROM left it (beeper 0)
        ret                             ; RET goes to the ROM's EXIT

; For each colour 0-7: the row's address byte, then the key's column bit
keys:   db      0xEF, 0x01              ; 0: row 4, bit 0
        db      0xF7, 0x01              ; 1: row 3, bit 0
        db      0xF7, 0x02              ; 2
        db      0xF7, 0x04              ; 3
        db      0xF7, 0x08              ; 4
        db      0xF7, 0x10              ; 5
        db      0xEF, 0x10              ; 6: row 4, bit 4
        db      0xEF, 0x08              ; 7: row 4, bit 3
```

Hold 3 and the border goes magenta; 6, yellow. The keys on the digit row of a PS/2 keyboard, the keypad's digits and the PC's keys all work, because they all reach port `0xFE` (see "PS/2 Keys on Port 0xFE"). BREAK leaves the border black again.

**Note:** BREAK is tested with two reads, one row each. A single read of rows 0 and 7 together (`0x7E`) would say "bit 0 is held" for CAPS SHIFT alone, or SPACE alone: combined rows cannot tell which row a key is in.

### Example 8-2: Showing the scan codes

The program prints one line for every key that goes down or up, such as `down 1C` or `up E0 75`. Esc, pressed, ends it.

It is built in four steps:

1. Wait until KBSTAT.COUNT is not 0, then take a byte from KBDATA.
2. If the byte is `F0`, set a flag for a release; if it is `E0`, set a flag for a grey key. Go back to step 1.
3. Any other byte is the key's own code: print `down` or `up`, then `E0` if that flag is set, then the code.
4. If the code is `76` with neither flag set, Esc went down: return to the monitor. Otherwise clear both flags and go back to step 1.

```asm
; Example 8-2 (docs/guide/io.md): the PS/2 keyboard's scan codes.
; Reads the bytes from the PS/2 FIFO itself and prints one line per key
; going down or up, such as "down 1C" and "up E0 75", with the ROM's
; PUTS and PUTHEX. Keys typed from the PC (the link's KEY command) arrive
; the same way. Esc, pressed, goes back to the monitor.
;
; The program never calls GETC or POLLC, which would take bytes from the
; same FIFO.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

PUTHEX  equ     0x06                    ; RST 28h functions (boot ROM spec, section 7.3)

start:  ld      hl,title
        rst     0x18                    ; PUTS
        ld      d,0                     ; D bit 0: F0 seen (a release); bit 1: E0 seen

.wait:  ld      bc,KBSTAT_P
        in      a,(c)
        and     KBSTAT_COUNT_M          ; bytes waiting
        jr      z,.wait
        in      a,(KBDATA_PORT)         ; take one
        cp      0xF0
        jr      z,.release
        cp      0xE0
        jr      z,.extended

        ; a key's code: print the event, then start afresh
        ld      e,a
        ld      hl,s_down
        bit     0,d
        jr      z,.say
        ld      hl,s_up
.say:   rst     0x18
        bit     1,d
        jr      z,.code
        ld      hl,s_e0
        rst     0x18
.code:  ld      a,e
        rst     0x28
        db      PUTHEX
        ld      hl,s_nl
        rst     0x18
        ld      a,d                     ; Esc pressed (76, no prefix): done
        or      a
        jr      nz,.again
        ld      a,e
        cp      0x76
        ret     z                       ; RET goes to the ROM's EXIT
.again: ld      d,0
        jr      .wait

.release:
        set     0,d
        jr      .wait
.extended:
        set     1,d
        jr      .wait

title:  db      13, 10, "Scan codes. Esc ends.", 13, 10, 0
s_down: db      "down ", 0
s_up:   db      "up   ", 0
s_e0:   db      "E0 ", 0
s_nl:   db      13, 10, 0
```

Typing `a`, then `Z`, then Cursor up gives:

```
down 1C
up   1C
down 12
down 1A
up   1A
up   12
down E0 75
up   E0 75
```

**Note:** the program never calls the ROM's GETC or POLLC. They read the same FIFO, so a program that mixes its own reads with the ROM's loses bytes to whichever reads first.

---

## Advanced Topics

### Sending to the keyboard

The keyboard takes commands too: its lights, its repeat rate, a reset. Write a byte to KBSEND when TXBUSY is 0; a write while TXBUSY is 1 is ignored. The hardware holds the keyboard's clock low for 100 µs, then the keyboard clocks the byte in; TXBUSY goes back to 0 when the keyboard has taken it, or after 15 ms with KBIRQ.TIMEOUT set if it never does. The keyboard answers `FA` through the FIFO: wait for it before the next byte. Nothing is received while a byte is being sent.

```asm
; set the keyboard's lights: E = the lights byte (Table 8-16)
lights: ld      a,0xED
        call    kbsend
        ld      a,e
kbsend: ld      bc,KBSTAT_P
.busy:  in      d,(c)
        bit     KBSTAT_TXBUSY_B,d
        jr      nz,.busy
        ld      bc,KBSEND_P
        out     (c),a                   ; send it
        ld      bc,KBSTAT_P
.ack:   in      a,(c)                   ; wait for the answer (FA)
        and     KBSTAT_COUNT_M
        jr      z,.ack
        in      a,(KBDATA_PORT)
        ret
```

**Table 8-15: Keyboard Commands**

| Command | Bytes |
|---------|-------|
| Set the lights | `ED`, then the lights byte (Table 8-16) |
| Set the repeat rate and delay | `F3`, then the rate byte |
| Reset and self-test | `FF`; the keyboard answers `FA`, then `AA` |

**Table 8-16: Lights Byte**

| Bits | Name | Meaning |
|------|------|---------|
| 7–3 | – | 0 |
| 2 | Caps | Caps Lock light on |
| 1 | Num | Num Lock light on |
| 0 | Scroll | Scroll Lock light on |

For example, the Caps light alone:

```asm
        ld      e,0x04                  ; Caps 1, Num 0, Scroll 0
        db      0x1E,0x04               ; the same instruction: LD E,0x04
        call    lights
```

This loop waits for ever if no keyboard answers; a program that must not hang also checks KBIRQ.TIMEOUT.

### The keyboard's interrupt

With KBIRQEN.DATA set, the keyboard asks for an interrupt (source KEYB) while the FIFO holds bytes. DATA follows the FIFO, so the request stays on until the handler has read every byte; the error flags, if enabled, stay on until written back. Setting up the interrupt controller and a handler is in the Interrupts and Timers chapter.

### Mega Drive pads

A Mega Drive pad multiplexes its buttons on a select line, so the hardware must be told to read it as a pad. Set **JOYCON.MD1** (port 1) or **MD2** (port 2): the hardware then reads that port in a burst every 2 ms, and JOYCON says what it found.

**Table 8-17: JOYCON Bits**

| Bits | Name | Meaning |
|------|------|---------|
| 7 | MDPRES2 | A Mega Drive pad answered on port 2 (read only) |
| 6 | MDPRES1 | A Mega Drive pad answered on port 1 (read only) |
| 5 | SIX2 | A 6-button pad answered on port 2 (read only) |
| 4 | SIX1 | A 6-button pad answered on port 1 (read only) |
| 3–2 | – | Read 0 |
| 1 | MD2 | Read port 2 as a Mega Drive pad (you set this) |
| 0 | MD1 | Read port 1 as a Mega Drive pad (you set this) |

A 6-button pad's X, Y, Z and MODE are in **JOY1X** (`0x6C00`) and **JOY2X** (`0x6D00`), 1 = pressed:

**Table 8-18: JOY1X and JOY2X Bits**

| Bits | Name | Meaning |
|------|------|---------|
| 7–4 | – | Read 0 |
| 3 | MODE | MODE |
| 2 | Z | Z |
| 1 | Y | Y |
| 0 | X | X |

They read 0 without a 6-button pad. Each register is updated at the end of a burst, so all the buttons it shows were taken together.

```asm
; port 1 as a Mega Drive pad; then, a frame later, is one there?
        ld      bc,JOYCON_P
        ld      a,JOYCON_MD1_M
        out     (c),a
        ; ... wait at least 2 ms (a burst) ...
        in      a,(c)
        bit     JOYCON_MDPRES1_B,a
        jr      z,no_pad                ; an Atari stick, or nothing: clear MD1 again
```

With MD1 clear, port 1 is read as an Atari stick, and A, START and JOY1X read 0.

---

## What It Cannot Do, or Not Yet

**The membrane.**

- It has no diodes, as on a real Spectrum. Three keys held at three corners of a rectangle in the matrix of Figure 8-1 (two in one row, and one in the same column as one of them) can make the fourth corner look held too. Games pick keys that do not form rectangles, or accept it. PS/2 keys and keys from the PC never ghost: they are mapped, not wired.
- The shift of an extra key's Spectrum pair is not held on for an extra scan; it comes and goes with the key.
- The scan and debounce times (64 µs a row, two scans that agree) are still to be checked on the real membrane, which is slow to settle.

**Port 0xFE and port 0x1F.**

- Only the whole low byte `0xFE` reaches the keyboard. A Spectrum answers on any even port, so Spectrum code that reads through another even port must be changed to `0xFE`.
- In the same way, port `0x1F` is decoded whole. A real Kempston interface answers whenever A5 is 0, so code that reads it through another port (`0xDF`, say) must be changed to `0x1F`.
- Joystick 2 has no Kempston port; read it at JOY2.
- There is no tape input: port `0xFE` bit 6 is the fixed value in KEYCON.EAR6.

**The mapper.**

- Only the keys of Table 8-11 are mapped. The others (the function keys, Pause, `[` `]` and so on) map to nothing; read them from the FIFO.
- The map is per key and ignores the PC's shift state: Shift + `,` is CAPS SHIFT + SYMBOL SHIFT + N, not `<`. A program that wants the PC's own characters reads KBDATA, or the ROM's calls.
- The "fake shift" codes `E0 12` and `E0 59`, which some keyboards send round the grey cursor keys, are ignored.
- Nothing is received while a byte is being sent to the keyboard, so a key pressed or let go then may be missed by the mapper until it is next pressed.

**The PS/2 keyboard.**

- Only a PS/2 keyboard works. Some USB keyboards also speak PS/2 through a passive adapter; most new ones do not.
- The FIFO and the mapper have been tried on the board only with keys from the PC (the KEY command). A real PS/2 keyboard on the board is still to be checked: ticket #20.
- Sending has been tried in simulation against a keyboard model, not yet with a real keyboard: ticket #20.

**The joysticks.**

- The joysticks have been tried in simulation against models of a stick and of 3- and 6-button pads, not yet on the board: ticket #20.
- Which port is joystick 1 seen from the front (the left one, by the design) is still to be checked on the board, and so is the Mega Drive burst timing with real pads.

---

## Summary of Registers

All are registers of page `0x00`: port = (register << 8) | `0x00`. Access: R read only, RW read and write, W write only, W1C sticky flags cleared by writing 1, F reading takes data. Table 8-19 lists them.

**Table 8-19: Summary of Registers**

| Name | Register | Port | Access | Function |
|------|----------|------|--------|----------|
| KEYMAP0–6 | `0x10`–`0x16` | `0x1000`–`0x1600` | R | The membrane, column c, bit r = row r, 1 = pressed |
| KEMPSTON | `0x1F` | `0x1F`, any high byte; `0x1F00` | R | Joystick 1, as JOY1 |
| KBCON | `0x60` | `0x6000` | RW | EN (0): the FIFO on |
| KBSTAT | `0x61` | `0x6100` | R | TXBUSY (7), COUNT (4–0): bytes waiting, 0–16 |
| KBDATA | `0x62` | `0x62`, any high byte; `0x6200` | R, F | Takes a byte from the FIFO; `0x00` if empty |
| KBSEND | `0x63` | `0x6300` | W | A byte to send to the keyboard (ignored while TXBUSY) |
| KBIRQ | `0x64` | `0x6400` | R, W1C | TIMEOUT (4), OVERFLOW (3), FRAME (2), PARITY (1), DATA (0, live) |
| KBIRQEN | `0x65` | `0x6500` | RW | Interrupt enables, as KBIRQ |
| JOY1, JOY2 | `0x66`, `0x67` | `0x6600`, `0x6700` | R | START (7), A (6), Fire 2/C (5), Fire 1/B (4), Up (3), Down (2), Left (1), Right (0) |
| JOYCON | `0x68` | `0x6800` | RW | Read only: MDPRES2 (7), MDPRES1 (6), SIX2 (5), SIX1 (4); MD2 (1), MD1 (0) |
| KEYCON | `0x6B` | `0x6B00` | RW | PS2MAP (2), EAR6 (1), KXMAP (0) |
| JOY1X, JOY2X | `0x6C`, `0x6D` | `0x6C00`, `0x6D00` | R | MODE (3), Z (2), Y (1), X (0) |
| (the keyboard rows) | `0xFE` | `0xFE`, high byte picks rows; `0xFE00` all rows | RW | Read: keys, 0 = pressed. Write: border (2–0), beeper (4) |
| KEYROW0–7 | – | – (register page `0x0100`–`0x0107`) | R | Each row of port `0xFE` alone |

### State after reset

KBCON is 0 (the FIFO off and empty), KBIRQEN 0, JOYCON 0 (both ports read as Atari sticks), KEYCON `0x07` (KXMAP, EAR6 and PS2MAP on). The receiver runs for the mapper, so PS/2 keys reach port `0xFE` from the start. The boot ROM then turns KBCON.EN on before it starts a program.

### Equates in hw.inc

**Table 8-20: Equates in hw.inc**

| Equate | Value |
|--------|-------|
| `KBCON_P` … `KBIRQEN_P`, `JOY1_P`, `JOY2_P`, `JOYCON_P`, `KEYCON_P`, `JOY1X_P`, `JOY2X_P`, `KEYMAP0_P` … `KEYMAP6_P` | Each register's port |
| `ULA_PORT`, `KEMPSTON_PORT`, `KBDATA_PORT` | `0xFE`, `0x1F`, `0x62`: the ports that answer whatever the high byte holds |
| `KBSTAT_COUNT_M`, `KBSTAT_TXBUSY_B` | `0x1F`, 7 |
| `KBIRQ_DATA_M` … `KBIRQ_TIMEOUT_M`, and `KBIRQEN_` the same | `0x01` … `0x10` |
| `JOY1_RIGHT_M` … `JOY1_START_M`, and `JOY2_`, `KEMPSTON_` the same | `0x01` … `0x80` |
| `JOYCON_MD1_M`, `JOYCON_SIX1_M`, `JOYCON_MDPRES1_M` (and the 2s) | `0x01`, `0x10`, `0x40` |
| `KEYCON_KXMAP_M`, `KEYCON_EAR6_M`, `KEYCON_PS2MAP_M` | `0x01`, `0x02`, `0x04` |

Related: the input spec (`docs/spec/input.md`) for every detail; the serial spec, section 4, for KEY; the boot ROM spec, section 7.4, for the key codes; interrupt source KEYB in the Interrupts and Timers chapter.
