# Chapter 8: Keyboards and Joysticks

## Introduction

retro-z80 reads its input three ways, and a program can use any of them, or all at once:

- the **membrane keyboard** on the KS3's case, a matrix of 56 keys that the hardware scans for you;
- a **PS/2 keyboard** plugged into the PS/2 socket, whose bytes the hardware receives into a small FIFO;
- two **joystick ports**, for Atari-style sticks and Mega Drive pads.

On top of these sit the **Spectrum extras**: port `0xFE` reads the keyboard rows exactly as a Spectrum does, with the PS/2 keyboard's keys mapped onto them, and port `0x1F` reads joystick 1 as a Kempston interface. So a program written the Spectrum way works with either keyboard, and with a joystick, unchanged.

A fourth source is the PC: keys typed in VS Code, or sent by the bridge's MCP tools, go down the USB link and come out of the PS/2 keyboard's side as if a PS/2 keyboard had sent them.

The chapter covers:

- which way to read the keys, and when;
- reading the keyboard the Spectrum way, through port `0xFE`, with a complete program;
- the whole membrane at once: KEYMAP0–6, KEYROW0–7 and the extra Next keys;
- the PS/2 keyboard: the FIFO, scan codes, a complete program that prints them, and sending to the keyboard;
- how PS/2 keys reach port `0xFE`;
- keys typed from the PC;
- the boot ROM's key calls;
- the joysticks, Kempston and Mega Drive pads;
- a summary of the registers.

You should know how the Z80 reaches the registers through ports (see "Reaching the registers from the Z80" in the Playfield Hardware chapter). The keyboard's interrupt belongs to the Interrupts and Timers chapter; this chapter reads the keys by polling.

### Comparison with retro68k

retro68k's keyboard is a plain PS/2 receiver; retro-z80 has the same receiver, narrowed to byte registers, and a good deal more round it, because the KS3 is a Spectrum. The differences:

| Feature | retro68k | retro-z80 |
|---------|----------|-----------|
| Registers | 32 bits, in the system block at `0xF00400` | Bytes, registers `0x60`–`0x65` of page `0x00` (ports `0x6000`–`0x6500`), in the same order |
| KBSTAT.TXBUSY | Bit 8 | Bit 7 |
| KBDATA | EMPTY in bit 8 | The byte alone: an empty FIFO reads `0x00`. Check KBSTAT.COUNT first |
| KBDATA's port | – | Also port `0x62` with any high byte, so `INIR` reads the FIFO |
| Membrane keyboard | Not yet | Scanned in hardware: KEYMAP0–6 |
| Port `0xFE`, Kempston `0x1F` | – | The Spectrum's keyboard rows and joystick, with the PS/2 keys mapped on |
| Joysticks | Not yet | Two ports: Atari sticks, Mega Drive 3- and 6-button pads |
| Keys from the PC | KEY, `C0 04 b ~b` (planned, its #25) | KEY, the same command (built) |

### Conventions in this chapter

- Examples are Z80 assembly language for sjasmplus and start with `include "hw.inc"`. Numbers in the text are hexadecimal when they start with `0x`.
- Registers are reached through their ports: `ld bc,KBSTAT_P` then `in a,(c)`. The four that answer whatever the high byte holds have their own names: `ULA_PORT` (`0xFE`), `KEMPSTON_PORT` (`0x1F`) and `KBDATA_PORT` (`0x62`), so `in a,(ULA_PORT)` works.
- **1 = pressed** everywhere except port `0xFE` and KEYROW0–7, which keep the Spectrum's 0 = pressed.
- The complete examples are in `examples/io/`, loaded at `0x8000` and run from the monitor or VS Code. They use the boot ROM's calls to print (`RST 18h` PUTS, `RST 28h` PUTHEX) and return to the monitor with `RET`.

---

## Which Way to Read the Keys

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

Port `0xFE` is the Spectrum's keyboard. The 40 Spectrum keys are in 8 **rows** of 5; the high byte of the port address picks the rows, one address line each, and the low 5 bits of the answer say which keys in those rows are held, **0 = pressed**:

| Row | High byte | Bit 0 | Bit 1 | Bit 2 | Bit 3 | Bit 4 |
|-----|-----------|-------|-------|-------|-------|-------|
| 0 | `0xFE` | CAPS SHIFT | Z | X | C | V |
| 1 | `0xFD` | A | S | D | F | G |
| 2 | `0xFB` | Q | W | E | R | T |
| 3 | `0xF7` | 1 | 2 | 3 | 4 | 5 |
| 4 | `0xEF` | 0 | 9 | 8 | 7 | 6 |
| 5 | `0xDF` | P | O | I | U | Y |
| 6 | `0xBF` | ENTER | L | K | J | H |
| 7 | `0x7F` | SPACE | SYMBOL SHIFT | M | N | B |

`IN A,(n)` puts A on the high half of the address, and `IN r,(C)` puts B there, so either picks the rows:

```asm
        ld      a,0xF7                  ; row 3: 1 2 3 4 5
        in      a,(ULA_PORT)            ; bits 4-0: 0 = held         (11 T)
        bit     2,a                     ; the 3 key
        jr      z,three_held
```

Bits 5 and 7 read 1. Bit 6 is the Spectrum's EAR input, a fixed value here (KEYCON.EAR6, 1 after reset), so mask the answer with `0x1F` before comparing it.

**Several rows at once.** A high byte with more than one 0 bit reads those rows together: a bit is 0 if the key in that column is held in **any** of them. `0x00` reads every row, which is a quick way to ask "is anything held?":

```asm
        xor     a                       ; every row
        in      a,(ULA_PORT)
        and     0x1F
        cp      0x1F
        jr      nz,something_held
```

Reading port `0xFE` changes nothing, so read it as often as you like. Only the whole low byte `0xFE` reaches the keyboard: a Spectrum answers on any even port, so Spectrum code that reads through another even port must be changed to `0xFE`.

**Writing** port `0xFE` sets the border colour (bits 2–0, a Spectrum colour, at once) and the beeper (bit 4), as on a Spectrum.

### Example 8-1: The border from the number keys

The program reads the keys 0–7 and sets the border to the colour of whichever is held. CAPS SHIFT and SPACE together, the Spectrum's BREAK, end it. On a PS/2 keyboard, or from the PC, Esc is BREAK.

```asm
; Example 8-1: the border from the number keys (examples/io/border.asm)
        org     0x8000
        include "hw.inc"

start:
.scan:  ld      hl,keys
        ld      e,0                     ; E = the colour of the key being tested
.key:   ld      a,(hl)                  ; the row's high byte: 0 in the row's bit
        in      a,(ULA_PORT)            ; A = that row, 0 = pressed
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
        ret                             ; both held: BREAK. RET goes to the ROM's EXIT

; For each colour 0-7: the row's high byte, then the key's column bit
keys:   db      0xEF, 0x01              ; 0: row 4, bit 0
        db      0xF7, 0x01              ; 1: row 3, bit 0
        db      0xF7, 0x02              ; 2
        db      0xF7, 0x04              ; 3
        db      0xF7, 0x08              ; 4
        db      0xF7, 0x10              ; 5
        db      0xEF, 0x10              ; 6: row 4, bit 4
        db      0xEF, 0x08              ; 7: row 4, bit 3
```

Hold 3 and the border goes magenta; 6, yellow. The keys on the digit row of a PS/2 keyboard, the keypad's digits and the PC's keys all work, because they all reach port `0xFE` (see "PS/2 Keys on Port 0xFE" below).

**Note:** BREAK is tested with two reads, one row each. A single read of rows 0 and 7 together (`0x7E`) would say "bit 0 is held" for CAPS SHIFT alone, or SPACE alone: combined rows cannot tell which row a key is in.

### Ghosting

The membrane has no diodes, as on a real Spectrum. Three keys held at three corners of a rectangle in the matrix (two in one row, and one in the same column as one of them) can make the fourth corner look held too. Games pick keys that do not form rectangles, or accept it. PS/2 keys and keys from the PC never ghost: they are mapped, not wired.

---

## The Whole Membrane: KEYMAP0–6

The membrane is a matrix of 8 rows and 7 columns, 56 keys: the 40 Spectrum keys in columns 0–4, and the KS3's 16 extra keys in columns 5–6. The hardware scans it all the time, about every half millisecond, and debounces it, so a read always gives a settled answer whatever the CPU speed.

**KEYMAP0–6** (registers `0x10`–`0x16`, ports `0x1000`–`0x1600`) give the whole membrane, one register per column, **1 = pressed**: bit r of KEYMAPc is the key at row r, column c. For example KEYMAP0 bit 0 is CAPS SHIFT, bit 1 is A, bit 7 is SPACE. To read all seven:

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

| Row | Column 6 (KEYMAP6) | Column 5 (KEYMAP5) |
|-----|--------------------|--------------------|
| 0 | Cursor up | EXTEND MODE |
| 1 | GRAPH | CAPS LOCK |
| 2 | INV VIDEO | TRUE VIDEO |
| 3 | EDIT | BREAK |
| 4 | `"` | `;` |
| 5 | `.` | `,` |
| 6 | Cursor right | DELETE |
| 7 | Cursor down | Cursor left |

With **KEYCON.KXMAP** set (after reset), each extra key also shows on port `0xFE` as the Spectrum key pair it stands for: the cursor keys as CAPS SHIFT + 5, 6, 7, 8, DELETE as CAPS SHIFT + 0, BREAK as CAPS SHIFT + SPACE, EDIT as CAPS SHIFT + 1, `;` `"` `,` `.` as SYMBOL SHIFT + O, P, N, M, and so on (the input spec, section 8.2, has the full table). Spectrum code then sees the keys it expects. A game that wants the cursor keys without CAPS SHIFT clears KXMAP and reads KEYMAP5 and KEYMAP6.

### KEYROW0–7

KEYROW0–7 give each port `0xFE` row on its own, in port `0xFE`'s format (0 = pressed, PS/2 keys and extra keys included), for code that reads memory rather than ports. They are in the register page only, at offsets `0x0100`–`0x0107`, so a program that maps the register page can copy all eight rows with one `LDIR`.

---

## The PS/2 Keyboard

Any PS/2 keyboard plugs into the PS/2 socket. It sends **scan codes** (set 2): a byte, or `E0` and a byte for the grey keys, as a key goes down; the same with `F0` before the last byte as it comes up. Held down, a key repeats its down code, about ten times a second after half a second. The hardware checks each byte's parity and frame and keeps good ones in a 16-byte FIFO; software reads and decodes them.

### The registers

| Name | Register | Port | Function |
|------|----------|------|----------|
| KBCON | `0x60` | `0x6000` | EN (0): the FIFO on. Off empties it |
| KBSTAT | `0x61` | `0x6100` | COUNT (4–0): bytes waiting, 0–16. TXBUSY (7): a byte is going to the keyboard |
| KBDATA | `0x62` | `0x6200`, and `0x62` with any high byte | Reading takes one byte; an empty FIFO reads `0x00` and takes nothing |
| KBSEND | `0x63` | `0x6300` | Write a byte to send it to the keyboard |
| KBIRQ | `0x64` | `0x6400` | DATA (0): bytes waiting (live). PARITY (1), FRAME (2), OVERFLOW (3), TIMEOUT (4): errors, sticky, write 1 to clear |
| KBIRQEN | `0x65` | `0x6500` | Interrupt enables, as KBIRQ |

The boot ROM starts a program with KBCON.EN on and the keyboard's interrupt off, so the FIFO is already filling.

### Reading the FIFO

Check KBSTAT.COUNT, then read KBDATA. An empty FIFO reads `0x00`, which a keyboard also sends (it means its own buffer overflowed), so KBDATA alone cannot say the FIFO is empty: check COUNT first:

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

| The keyboard sends | Meaning |
|--------------------|---------|
| `1C` | A down |
| `F0 1C` | A up |
| `12` … `F0 12` | Left Shift down … up |
| `E0 75` | Cursor up down |
| `E0 F0 75` | Cursor up up |
| `E1 14 77 E1 F0 14 F0 77` | Pause, pressed (it has no release) |
| `AA` | Self-test passed: sent when the keyboard is plugged in or reset |
| `FA` | Acknowledge, after a byte sent to the keyboard |

Shift is a key like any other: a capital A is Shift down, A down, A up, Shift up. Software keeps track of the shift keys itself.

### Example 8-2: Showing the scan codes

The program prints one line for every key that goes down or up, such as `down 1C` or `up E0 75`. It keeps two flags, for an `F0` and an `E0` seen before the key's own byte. Esc, pressed, ends it.

```asm
; Example 8-2: the PS/2 keyboard's scan codes (examples/io/scancodes.asm)
        org     0x8000
        include "hw.inc"

PUTHEX  equ     0x06                    ; RST 28h function: print A as two hex digits

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

A real decoder turns the codes into characters with a layout table, keeps the shift keys' state, and ignores Pause's `E1` sequence. The boot ROM's decoder (`firmware/boot/keys.asm`, `ps2key` and its tables `ps2tab` and `ps2tab_s`) does this for a UK layout.

### Sending to the keyboard

The keyboard takes commands too: its lights, its repeat rate, a reset. Write a byte to KBSEND when TXBUSY is 0. The hardware holds the keyboard's clock low for 100 µs, then the keyboard clocks the byte in; TXBUSY goes back to 0 when the keyboard has taken it, or after 15 ms with KBIRQ.TIMEOUT set if it never does. The keyboard answers `FA` through the FIFO: wait for it before the next byte. Nothing is received while a byte is being sent.

```asm
; set the keyboard's lights: E = Scroll (bit 0), Num (bit 1), Caps (bit 2)
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

| Command | Bytes |
|---------|-------|
| Set the lights | `ED`, then bits 0–2 (Scroll, Num, Caps) |
| Set the repeat rate and delay | `F3`, then the rate byte |
| Reset and self-test | `FF`; the keyboard answers `FA`, then `AA` |

This loop waits for ever if no keyboard answers; a program that must not hang also checks KBIRQ.TIMEOUT. (Sending has been tried in simulation against a keyboard model, not yet with a real keyboard: ticket #20.)

### The keyboard's interrupt

With KBIRQEN.DATA set, the keyboard asks for an interrupt (source KEYB) while the FIFO holds bytes. DATA follows the FIFO, so the request stays on until the handler has read every byte; the error flags, if enabled, stay on until written back. Setting up the interrupt controller and a handler is in the Interrupts and Timers chapter.

---

## PS/2 Keys on Port 0xFE

With **KEYCON.PS2MAP** set (after reset), a key held on the PS/2 keyboard also shows on port `0xFE` as the Spectrum key, or pair of keys, it stands for. A **mapper** in the hardware watches the bytes the keyboard sends, follows `E0` and `F0`, and keeps a held bit for each key it knows. So a Spectrum game can be played on a PS/2 keyboard with no help from software.

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

- Other keys (the function keys, Pause and so on) map to nothing; read them from the FIFO.
- The map is per key and ignores the PC's shift state: Shift + `,` is CAPS SHIFT + SYMBOL SHIFT + N, not `<`.
- The mapper watches the bytes **before** the FIFO, so it works whether KBCON.EN is on or off, and whatever the program does with KBDATA. A program can read port `0xFE` and the FIFO side by side.
- Its held keys are let go at reset, when PS2MAP is cleared, and when the keyboard sends `AA` (plugged in again), so a key cannot stay stuck.

---

## Keys from the PC

The PC can type on the board. Each key goes down the USB link as the **KEY** control command, which the FPGA turns into a PS/2 byte as if the PS/2 keyboard had sent it: a key's down code as it goes down, its up code as it comes up. The hardware decodes KEY itself, so it works whether the program is running, stopped in the debugger, or hung.

To the program, keys from the PC **are** PS/2 keys:

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

| Call | Does |
|------|------|
| `RST 10h` GETC | Waits for a key; A = its code |
| `RST 20h` POLLC | NZ and A = a key's code if one was waiting; Z if not. Never waits |
| `RST 28h` GETLINE (`0x05`) | Reads a line with the monitor's editing |
| `RST 28h` CONMODE (`0x0E`) | Which sources the ROM reads keys from (bit 2 the keyboards, bit 3 the serial link) |

The PS/2 keyboard is decoded with a UK layout. GETC and POLLC take bytes from the PS/2 FIFO, so a program uses either the ROM's calls or its own reads of KBDATA, not both. Port `0xFE` is never affected: the ROM's reads change nothing there. The boot ROM spec, section 7.4, lists every key code.

---

## The Joysticks

The KS3 has two 9-pin joystick ports. The hardware reads both, all the time, and keeps the result in two registers, **1 = pressed**:

| Bit | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|-----|---|---|---|---|---|---|---|---|
| JOY1 (`0x6600`), JOY2 (`0x6700`) | Right | Left | Down | Up | Fire 1 / B | Fire 2 / C | A | START |

The low five bits are in the **Kempston** order, and **port `0x1F`** reads joystick 1 as a Kempston interface, with any high byte:

```asm
        in      a,(KEMPSTON_PORT)       ; joystick 1, 1 = pressed
        bit     KEMPSTON_FIRE1_B,a
        jr      nz,fire
        and     KEMPSTON_LEFT_M | KEMPSTON_RIGHT_M
        ...
```

An Atari one-button stick gives bits 0–4; a two-button stick adds Fire 2. Bits 6 and 7 are a Mega Drive pad's A and START, and read 0 with a stick, so a Spectrum game that compares the whole byte with 0 sees only what is pressed.

### Mega Drive pads

A Mega Drive pad multiplexes its buttons on a select line, so the hardware must be told to read it as a pad. Set **JOYCON.MD1** (port 1) or **MD2** (port 2): the hardware then reads that port in a burst every 2 ms, and JOYCON says what it found.

| JOYCON bit | Name | Meaning |
|------------|------|---------|
| 0, 1 | MD1, MD2 | Read port 1 or 2 as a Mega Drive pad (you set these) |
| 4, 5 | SIX1, SIX2 | A 6-button pad answered (read only) |
| 6, 7 | MDPRES1, MDPRES2 | A Mega Drive pad answered (read only) |

A 6-button pad's X, Y, Z and MODE are in **JOY1X** (`0x6C00`) and **JOY2X** (`0x6D00`), bits 0–3. Each register is updated at the end of a burst, so all the buttons it shows were taken together.

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

(The joysticks have been tried in simulation against models of a stick and of 3- and 6-button pads, not yet on the board: ticket #20.)

---

## Summary of Registers

All are registers of page `0x00`: port = (register << 8) | `0x00`. Access: R read only, RW read and write, W1C sticky flags cleared by writing 1, F reading takes data.

| Name | Register | Port | Access | Function |
|------|----------|------|--------|----------|
| KEYMAP0–6 | `0x10`–`0x16` | `0x1000`–`0x1600` | R | The membrane, column c, bit r = row r, 1 = pressed |
| KEMPSTON | `0x1F` | `0x1F`, any high byte; `0x1F00` | R | Joystick 1, as JOY1 |
| KBCON | `0x60` | `0x6000` | RW | EN (0) |
| KBSTAT | `0x61` | `0x6100` | R | COUNT (4–0), TXBUSY (7) |
| KBDATA | `0x62` | `0x62`, any high byte; `0x6200` | R, F | Takes a byte from the FIFO; `0x00` if empty |
| KBSEND | `0x63` | `0x6300` | W | A byte to send to the keyboard (ignored while TXBUSY) |
| KBIRQ | `0x64` | `0x6400` | R, W1C | DATA (0, live), PARITY (1), FRAME (2), OVERFLOW (3), TIMEOUT (4) |
| KBIRQEN | `0x65` | `0x6500` | RW | As KBIRQ |
| JOY1, JOY2 | `0x66`, `0x67` | `0x6600`, `0x6700` | R | Right, Left, Down, Up, Fire 1/B, Fire 2/C, A, START |
| JOYCON | `0x68` | `0x6800` | RW | MD1 (0), MD2 (1); read only: SIX1 (4), SIX2 (5), MDPRES1 (6), MDPRES2 (7) |
| KEYCON | `0x6B` | `0x6B00` | RW | KXMAP (0), EAR6 (1), PS2MAP (2) |
| JOY1X, JOY2X | `0x6C`, `0x6D` | `0x6C00`, `0x6D00` | R | X (0), Y (1), Z (2), MODE (3) |
| (the keyboard rows) | `0xFE` | `0xFE`, high byte picks rows; `0xFE00` all rows | R | Read: keys, 0 = pressed. Write: border (2–0), beeper (4) |
| KEYROW0–7 | – | – (register page `0x0100`–`0x0107`) | R | Each row of port `0xFE` alone |

### State after reset

KBCON is 0 (the FIFO off and empty), KBIRQEN 0, JOYCON 0 (both ports read as Atari sticks), KEYCON `0x07` (KXMAP, EAR6 and PS2MAP on). The receiver runs for the mapper, so PS/2 keys reach port `0xFE` from the start. The boot ROM then turns KBCON.EN on before it starts a program.

### Equates in hw.inc

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
