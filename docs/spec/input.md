# Spec 12: Input

Status: **draft**

This spec covers the three kinds of input: a **PS/2 keyboard** (a raw byte FIFO, as in retro68k spec 16), the KS3's **Spectrum membrane keyboard** (read through port `0xFE` exactly as on a Spectrum), and the KS3's two **joystick ports** (Atari or Mega Drive style, read as bits). Their ports are `0xA0`–`0xA7`, `0xFE` and the Kempston port `0x1F`. Port `0xFE` also takes the Spectrum's border and beeper writes.

## 1. Summary

| Item | Value |
|------|-------|
| PS/2 keyboard | Any PS/2 keyboard, scan code set 2. Checked bytes into a 16-byte FIFO; software decodes. Bytes can be sent to the keyboard |
| Spectrum keyboard | The KS3's 8 × 7 membrane matrix, scanned and debounced in hardware. Port `0xFE` with A15–A8 as row select, active-low bits 4–0, as on a Spectrum |
| Extra Next keys | The 16 keys in matrix columns 5–6: read in KEYX5 and KEYX6, and optionally also shown on port `0xFE` as their Spectrum shift combinations |
| Joysticks | 2 ports, Atari (1 or 2 buttons) or Mega Drive 3-button pads. Kempston bit order, 1 = pressed. Joystick 1 also at the Kempston port `0x1F` |
| Port `0xFE` writes | Bits 2–0: border, i.e. the background colour, one of the 8 Spectrum colours (spec 4). Bit 4: the beeper (spec 7, section 9.1). Bit 3 (MIC) ignored |
| Interrupt | KEYBOARD (source 9, a level) from the PS/2 keyboard only. The Spectrum keyboard and joysticks are polled |
| Ports | `0xA0`–`0xA7` (8 ports), `0x1F` and `0xFE` |
| Memory cycles | None |

## 2. PS/2 keyboard

### 2.1 Receiving

- The keyboard sends 11-bit frames: start bit (0), 8 data bits (lowest first), odd parity, stop bit (1), on its own clock of about 10–17 kHz. The controller samples `ps2_clk` and `ps2_data` at 56 MHz, with a filter on the clock against noise.
- A good byte goes into the 16-byte FIFO unchanged.
- A bad byte is dropped: bad parity sets KBSTAT.PARITY; a bad start or stop bit sets KBSTAT.FRAME. Software can send `FE` (resend).
- If the FIFO is full, the new byte is dropped and KBSTAT.OVERFLOW is set.
- With KBCTL.EN = 0 nothing is received and the FIFO is empty.

### 2.2 Reading

- KBSTAT.AVAIL is 1 while the FIFO holds a byte. Reading KBDATA takes one byte. Reading it when empty returns `0x00` and takes nothing.
- The KEYBOARD request (spec 8, source 9) is on while AVAIL is 1, or while any error flag (PARITY, FRAME, OVERFLOW, TIMEOUT) is set and KBCTL.ERRIRQ is 1. It drops when the FIFO is read empty and the flags are cleared.

### 2.3 Decoding

Done by software, as in retro68k: `1C` = A pressed, `F0 1C` = A released, `E0` prefixes the extended keys (`E0 75` = cursor up), Pause sends `E1 14 77 E1 F0 14 F0 77`, `AA` = self-test passed (after power-on), `FA` = acknowledge. The boot ROM has a small decoder and a layout table, and BBC BASIC's `INKEY` and `GET` read through it.

### 2.4 Sending

1. Software checks that KBSTAT.TXBUSY is 0 and writes the byte to KBDATA.
2. The controller holds the clock low for 100 µs, pulls data low, releases the clock and sends the byte with parity on the keyboard's clock. TXBUSY is 1 meanwhile; nothing is received.
3. The keyboard answers, usually with `FA`, which arrives in the FIFO. Software waits for it before the next byte.
4. A write while TXBUSY is 1 is ignored. If the keyboard does not take the byte within 15 ms, TXBUSY goes to 0 and KBSTAT.TIMEOUT is set.

Common commands: set lights `ED` then bits 2–0 (Caps, Num, Scroll); set repeat `F3` then the rate byte; reset `FF` (answers `FA` then `AA`).

## 3. Spectrum keyboard

### 3.1 The matrix

The KS3 membrane is a matrix of 8 rows and 7 columns (56 keys). Columns 0–4 hold the Spectrum's 40 keys, in the Spectrum's own layout; columns 5–6 hold the 16 extra Next keys.

| Row | Selected by | Bit 0 | Bit 1 | Bit 2 | Bit 3 | Bit 4 |
|-----|-------------|-------|-------|-------|-------|-------|
| 0 | A8 = 0 (port `0xFEFE`) | CAPS SHIFT | Z | X | C | V |
| 1 | A9 = 0 (`0xFDFE`) | A | S | D | F | G |
| 2 | A10 = 0 (`0xFBFE`) | Q | W | E | R | T |
| 3 | A11 = 0 (`0xF7FE`) | 1 | 2 | 3 | 4 | 5 |
| 4 | A12 = 0 (`0xEFFE`) | 0 | 9 | 8 | 7 | 6 |
| 5 | A13 = 0 (`0xDFFE`) | P | O | I | U | Y |
| 6 | A14 = 0 (`0xBFFE`) | ENTER | L | K | J | H |
| 7 | A15 = 0 (`0x7FFE`) | SPACE | SYMBOL SHIFT | M | N | B |

### 3.2 Scanning

The FPGA scans the matrix all the time: it drives one row line low at a time and reads the 7 column lines (low = pressed), about every 64 µs per row (a full scan every 0.5 ms). A key's state changes only after two scans in a row agree (debounce, 0.5–1 ms). The result is a 56-bit key map. The CPU never drives the matrix; reads of port `0xFE` come from the key map, so any CPU speed works. The membrane has no diodes, so, as on a Spectrum, three keys held at three corners of a rectangle can make the fourth corner look pressed (ghosting).

### 3.3 Port 0xFE

`IN A,(0xFE)` (which puts A on A15–A8) and `IN r,(C)` (which puts B there, with C = `0xFE`) read the keyboard exactly like a Spectrum, the upper address byte selecting the rows:

| Bit | Value |
|-----|-------|
| 4–0 | Columns 0–4: 0 = a key in that column is pressed in **any** selected row (rows with their address line at 0 are combined, as on a Spectrum, so `IN A,(0xFE)` with A = 0 reads all rows) |
| 5 | 1 |
| 6 | INCTL.EAR6 (the Spectrum's EAR input; there is no tape input, so it is a fixed value, 1 after reset) |
| 7 | 1 |

- The whole low byte `0xFE` is decoded. A Spectrum decodes only A0 = 0, so code that reads the keyboard through another even port must be changed to use `0xFE`.
- Writes to port `0xFE` set the border and the beeper (section 3.4).
- Reading port `0xFE` changes nothing, so it can be read any number of times.
- **Through memory:** a memory read has no A15–A8 for row select, so the register page gives each row its own byte, KEYROW0–7 at offsets `0x0100`–`0x0107` (row r = the row selected by A(8 + r) = 0, in port `0xFE`'s format). Offset `0x00FE` reads as port `0xFE` with all rows selected (spec 3, section 5).

### 3.5 Extra Next keys

The 16 extra keys are: EXTEND MODE, EDIT, CAPS LOCK, TRUE VIDEO, INV VIDEO, GRAPH, DELETE, BREAK, the four cursor keys, and `;` `"` `,` `.`. Their exact positions in columns 5–6 are taken from the Next's own keyboard code (open point K1).

- **KEYX5** and **KEYX6** give columns 5 and 6 of all 8 rows, one bit per row, **1 = pressed** (bit n = row n). New software reads the extra keys here.
- With **INCTL.KXMAP = 1** (1 after reset), an extra key also shows on port `0xFE` as the Spectrum key pair it stands for, so Spectrum code sees the keys it expects:

| Extra key | Shown on port `0xFE` as |
|-----------|--------------------------|
| EDIT | CAPS SHIFT + 1 |
| CAPS LOCK | CAPS SHIFT + 2 |
| TRUE VIDEO | CAPS SHIFT + 3 |
| INV VIDEO | CAPS SHIFT + 4 |
| Cursor left, down, up, right | CAPS SHIFT + 5, 6, 7, 8 |
| GRAPH | CAPS SHIFT + 9 |
| DELETE | CAPS SHIFT + 0 |
| BREAK | CAPS SHIFT + SPACE |
| EXTEND MODE | CAPS SHIFT + SYMBOL SHIFT |
| `;` `"` `,` `.` | SYMBOL SHIFT + O, P, N, M |

With KXMAP = 0, port `0xFE` shows only the 40 Spectrum keys, and a program can treat the extra keys as separate keys (for example cursor keys for a game without CAPS SHIFT held).

### 3.4 Port 0xFE writes: border and beeper

`OUT (0xFE),A` works as on a Spectrum, so ported code keeps its border and sound. As for reads, the whole low byte `0xFE` is decoded; A15–A8 are ignored on writes.

| Bit | Spectrum use | Here |
|-----|--------------|------|
| 2–0 | Border colour | Sets the background colour to Spectrum colour 0–7 (black, blue, red, magenta, green, cyan, yellow, white), with the fixed 12-bit values given in spec 4 |
| 3 | MIC (tape out) | Ignored |
| 4 | EAR (beeper) | The beeper bit: drives the 1-bit beeper mixed into the audio output (spec 7, section 9.1) |
| 7–5 | Unused | Ignored |

- **Border:** the border of a Spectrum-size window is the background colour (spec 4), so a write to port `0xFE` writes BGCOL with that colour's 12-bit value. BGCOL then reads back that value, and a later BGCOL write overrides it; the last write of either kind wins. The new colour takes effect at the draw beam, from the pixel where the write lands, like any BGCOL write (spec 4). Spec 4 defines the colours and the BGCOL interaction.
- **Beeper:** bit 4 is kept until the next write to port `0xFE`; 0 after reset.
- Every write sets both: a program that only wants the beeper must also write the border bits it wants.
- **Through memory:** offset `0x00FE` of the register page takes the same writes.
- The copper cannot write port `0xFE`; it sets BGCOL directly.

## 4. Joysticks

### 4.1 The ports

The KS3 has two 9-pin joystick ports. They share one set of FPGA input pins through a multiplexer, switched by the FPGA's `joysel` output (pin U14 in the KS3 pin list). The FPGA switches `joysel` back and forth on its own, about every 2 µs, waits for the lines to settle and samples each port in turn, so software sees both ports at once.

| Pin | Atari joystick | Mega Drive pad, select high | Mega Drive pad, select low |
|-----|----------------|-----------------------------|----------------------------|
| 1 | Up | Up | Up |
| 2 | Down | Down | Down |
| 3 | Left | Left | Low (pad present) |
| 4 | Right | Right | Low (pad present) |
| 6 | Fire 1 | B | A |
| 7 | (+5 V on Atari) | Select (driven by the FPGA) | Select |
| 9 | Fire 2 (2-button sticks) | C | START |
| 8 | Ground | Ground | Ground |

All inputs are active low at the pins and are inverted, so the registers give **1 = pressed**.

### 4.2 Mega Drive pads

With INCTL.MD1 (or MD2) set, the FPGA also drives the select line low for one sample in each scan and reads A and START from that port. A pad that is present pulls pins 3 and 4 low while select is low; INCTL.MDPRES1 (or MDPRES2) reports this. With MDn = 0 the select line stays high and the port reads as an Atari stick (A and START read 0). Six-button pads are not read in version 1 (open point J3).

### 4.3 Bit order

The low 5 bits follow the **Kempston** interface, and joystick 1 is also at the Kempston port `0x1F` (section 4.4), so Spectrum code that reads a Kempston joystick runs unchanged.

| Bit | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|-----|---|---|---|---|---|---|---|---|
| JOY1 / JOY2 | Right | Left | Down | Up | Fire 1 / B | Fire 2 / C | A | START |

Pad detection (MDPRES1, MDPRES2) is read in INCTL, not in JOYn, so a Kempston-style read sees only buttons.

### 4.4 Kempston port 0x1F

Port `0x1F` reads **joystick 1**: the same value as JOY1 (`0xA5`), at the same moment. Writes to it are ignored. Like every port it is decoded on A7–A0 only, so `IN A,(0x1F)` and `IN r,(C)` with C = `0x1F` both work, and it is also at offset `0x001F` of the register page.

- Bits 4–0 are Right, Left, Down, Up, Fire as on a Kempston interface. Bits 7–5 carry Fire 2, A and START, where a real Kempston reads 0. With an Atari one-button stick they read 0; a game that tests the whole byte against 0 sees only what is pressed.
- A real Kempston decodes only A5 = 0; code that reads it through another port (for example `0xDF`) must be changed to use `0x1F`.
- Joystick 2 has no Kempston alias; it is read at JOY2.

## 5. Registers

| Port | Name | Bits | Description |
|------|------|------|-------------|
| `0x1F` | KEMPSTON | 7–0 | Read only: joystick 1, the same value as JOY1 (section 4.4). Writes ignored |
| `0xA0` | KBDATA | 7–0 | Read: takes one byte from the PS/2 FIFO (`0x00` if empty). Write: send this byte to the keyboard (ignored while TXBUSY) |
| `0xA1` | KBSTAT | AVAIL (0), TXBUSY (1), PARITY (2), FRAME (3), OVERFLOW (4), TIMEOUT (5) | AVAIL and TXBUSY read only; the error flags are sticky, write 1 to clear. Bits 7–6 read 0 |
| `0xA2` | KBCTL | EN (0), ERRIRQ (1), FLUSH (2) | Receive on; error flags also raise KEYBOARD; write 1 to empty the FIFO (reads 0). 0 after reset |
| `0xA3` | KEYX5 | 7–0 | Read only: matrix column 5, bit n = row n, 1 = pressed |
| `0xA4` | KEYX6 | 7–0 | Read only: matrix column 6, as KEYX5 |
| `0xA5` | JOY1 | 7–0 | Read only: left joystick port (section 4.3), 1 = pressed |
| `0xA6` | JOY2 | 7–0 | Read only: right joystick port |
| `0xA7` | INCTL | MD1 (0), MD2 (1), KXMAP (2), EAR6 (3), MDPRES1 (6), MDPRES2 (7) | Read a Mega Drive pad on port 1 / port 2; show extra keys on port `0xFE`; value of port `0xFE` bit 6. MDPRES1/2 are read only: a Mega Drive pad answered on that port. After reset `0x0C` (KXMAP and EAR6 on) |
| `0xFE` | (keyboard, border, beeper) | 7–0 | Read: Spectrum keyboard rows selected by A15–A8 (section 3.3). Write: bits 2–0 border (background) colour, bit 4 beeper, others ignored (section 3.4) |

Which joystick port is "1" (left or right as seen from the front) is to be checked on the board (open point J2).

## 6. FPGA resources

| Item | Resource |
|------|----------|
| PS/2 receiver and sender, 16-byte FIFO | Estimate 100–150 LUTs |
| Matrix scanner, debounce, 56-bit key map, port `0xFE` logic (reads, border colour table, beeper bit), KXMAP | Estimate 100–150 LUTs |
| Joystick multiplexer and Mega Drive select | Estimate 30–50 LUTs |
| Block RAM, DSP | None |
| Pins | PS/2: `ps2_clk`, `ps2_data`. Keyboard: 8 row outputs, 7 column inputs (`keyb_row_o[7:0]`, `keyb_col_i[6:0]`). Joysticks: `joysel` (U14), the shared direction and button inputs and the select output (section 8) |
| Request lines | KEYBOARD (level) to spec 8 |

## 7. Test plan

- **PS/2, simulation:** a keyboard model sends bytes; they come out of KBDATA in order; AVAIL and the KEYBOARD request follow the FIFO. Bad parity and stop bits set PARITY and FRAME and drop the byte; a 17th byte sets OVERFLOW. A sent byte arrives with the right parity; a silent model gives TIMEOUT.
- **Spectrum keyboard, simulation:** a matrix model with keys held: each of the 8 row addresses reads the right bits; several rows selected at once combine; bounce shorter than the debounce time is ignored; with KXMAP each extra key gives its pair; with KXMAP = 0 it does not.
- **Port decoding:** `IN A,(0xFE)` and `IN A,(C)` with every value of A15–A8; ports other than `0xFE` never read the keyboard.
- **Port `0xFE` writes:** each value of bits 2–0 sets BGCOL to its Spectrum colour, read back in BGCOL and seen at the draw beam pixel of the write; a later BGCOL write wins, and a later `0xFE` write wins over that; bit 4 reaches the beeper; bits 3 and 7–5 change nothing; the same through register page offset `0x00FE`.
- **Kempston:** port `0x1F` and offset `0x001F` equal JOY1 for every direction and button; writes to `0x1F` change nothing; INTHIGH is not at `0x1F` (spec 8).
- **Joysticks:** a model of both ports through the multiplexer: every direction and button on each port, Atari and Mega Drive 3-button pads, pad detection; Kempston bit order.
- **On the board:** every membrane key, including the 16 extra keys; a few PS/2 keyboards (every key, lights); Atari sticks and Mega Drive pads in both ports; a Spectrum game's keyboard, Kempston, border and beeper code unchanged (when it uses ports `0xFE` and `0x1F`).

## 8. Open points

Pin facts checked in retro68k's KS3 files: the Multiface, DivMMC and reset buttons; `joysel_o` at U14; the SD pins. The rest below is not yet checked against the Next's `zxnext_top_issue5.vhd` and `zxnext_pins_issue5.xdc`.

| # | Item |
|---|------|
| K1 | Positions of the 16 extra keys in matrix columns 5–6, and the row/column numbering of `keyb_row_o` / `keyb_col_i`, from the Next's keyboard code (`membrane` module) |
| K2 | Pin locations of `keyb_row_o[7:0]`, `keyb_col_i[6:0]`, `ps2_clk`, `ps2_data` (not in retro68k's pin file yet). Whether the row outputs must be open drain (driven low or left floating) to avoid shorting two rows when two keys in one column are pressed |
| K3 | Scan and debounce times (64 µs per row, two agreeing scans) to be checked on the real membrane, which is slow to settle |
| K4 | Decided: port `0xFE` writes set the border (background colour) with bits 2–0 and the beeper with bit 4; MIC is ignored (section 3.4) |
| K5 | Should PS/2 keys also show on port `0xFE` (a PS/2 to Spectrum matrix map, as the Next does)? Costs a decoder in hardware; left out for now |
| K6 | Should port `0xFE` bit 6 have a better default for games that test it (issue 2 / issue 3 behaviour)? INCTL.EAR6 lets software choose |
| J1 | Joystick pin names and locations: the shared inputs (expected as `joyp1_i`–`joyp4_i`, `joyp6_i`, `joyp9_i`) and the Mega Drive select output (`joyp7_o`), and whether select goes to both ports or only the selected one |
| J2 | `joysel` polarity (which level selects which port) and the settle time after switching it |
| J3 | Six-button Mega Drive pads (X, Y, Z, MODE) need a select pulse sequence; add later if wanted, with a JOYnX register |
| J4 | Decided: port `0x1F` reads joystick 1 as a Kempston interface (section 4.4); INTHIGH moved to `0xB8` (spec 8) |
