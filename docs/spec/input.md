# Spec 12: Input

Status: **draft**

This spec covers the three kinds of input: a **PS/2 keyboard**, the KS3's **membrane keyboard** and its two **joystick ports**. The PS/2 keyboard is retro68k's (its spec 16, version 1): a raw byte FIFO with the same registers, names and bits, cut to bytes. The joysticks and the membrane's extra keys are on retro68k's "later versions" list; here they are in version 1, in the same port range. Their ports are `0x60`–`0x6F` in the system block (spec 3).

The Spectrum's own ways in, port `0xFE` (keyboard rows) and the Kempston port `0x1F`, are kept as **Spectrum extras** in section 8, outside the retro68k-shaped core.

## 1. Summary

| Item | Value |
|------|-------|
| PS/2 keyboard | Any PS/2 keyboard, scan code set 2. Checked bytes into a 16-byte FIFO, unchanged; software decodes. Bytes can be sent to the keyboard |
| Membrane keyboard | The KS3's 8 × 7 matrix, scanned and debounced in hardware. The 40 Spectrum keys are read through port `0xFE` (section 8); the 16 extra Next keys also in KEYX5 and KEYX6 |
| Joysticks | 2 ports, Atari (1 or 2 buttons) or Mega Drive 3-button pads. Kempston bit order, 1 = pressed |
| Interrupt | Source KEYB (spec 8) from the PS/2 keyboard: FIFO not empty, or an error. The membrane and the joysticks are polled |
| Ports | `0x60`–`0x6B` used, `0x6C`–`0x6F` reserved; Spectrum extras `0xFE` and `0x1F` |
| Memory cycles | None |

## 2. Comparison with retro68k

| retro68k (spec 16, version 1) | retro-z80 | Why |
|-------------------------------|-----------|-----|
| 32-bit registers at `0xF00400` | 8-bit ports `0x60`–`0x65`, in the same order | Z80 (8-bit ports) |
| KBSTAT: COUNT (4–0), TXBUSY (8) | COUNT (4–0), TXBUSY (**7**) | Z80: no bit 8 in a byte |
| KBDATA: EMPTY (8), BYTE (7–0) | The byte only; an empty FIFO reads `0x00` and nothing is taken. Software checks KBSTAT.COUNT or KBIRQ.DATA first | Z80: no bit 8 |
| KBCON, KBSEND, KBIRQ, KBIRQEN | The same, bits unchanged | – |
| Controller samples at 100 MHz | At 56 MHz | System clock |
| Joysticks: a later version | JOY1, JOY2, JOYCON in version 1 (section 4) | The KS3's joystick ports are for games; the Next's games machine use |
| Spectrum (membrane) keyboard: a later version | Scanned in version 1; extra keys in KEYX5, KEYX6 (section 5); the Spectrum keys through port `0xFE` | The KS3's own keyboard; Spectrum extra |
| — | Port `0xFE` reads, KEYCON, KEYROW0–7 in the register page, Kempston port `0x1F` (section 8) | Spectrum extras |
| Ctrl + Alt + Delete in software, writing SYSRESET | The same (spec 7) | – |

## 3. PS/2 keyboard

### 3.1 Receiving

- The keyboard sends 11-bit frames: a start bit (0), 8 data bits (lowest first), odd parity and a stop bit (1), on its own clock of about 10–17 kHz. The controller samples `ps2_clk` and `ps2_data` at 56 MHz, with a short filter on the clock line against noise.
- A good byte goes into the 16-byte FIFO, unchanged.
- A bad byte is dropped. Bad parity sets KBIRQ.PARITY; a bad start or stop bit sets KBIRQ.FRAME. Software can send `FE` (resend) if it wants the byte again.
- If the FIFO is full, the new byte is dropped and KBIRQ.OVERFLOW is set.
- With KBCON.EN = 0 nothing is received and the FIFO is empty.

### 3.2 Reading the FIFO

- KBSTAT.COUNT says how many bytes are waiting (0–16).
- Reading KBDATA takes one byte. Reading it when the FIFO is empty returns `0x00` and takes nothing.
- KBIRQ.DATA is 1 while the FIFO is not empty. It is not sticky. With KBIRQEN.DATA set, this gives the interrupt.
- Every read of KBDATA takes a byte, through a port or the register page. Don't use read-modify-write instructions on it through the register page.

### 3.3 Decoding (software)

The bytes are scan code set 2, as the keyboard sends them. Software decodes them, as in retro68k:

| Keyboard sends | Meaning |
|----------------|---------|
| `1C` | A pressed |
| `F0 1C` | A released |
| `E0 75` | Cursor up pressed |
| `E0 F0 75` | Cursor up released |
| `E1 14 77 E1 F0 14 F0 77` | Pause pressed (Pause has no release) |
| `AA` | Self-test passed (sent after power-on or a reset command) |
| `FA` | Acknowledge, after a byte sent to the keyboard |

The boot ROM has a small decoder and a layout table, and BBC BASIC's `INKEY` and `GET` read through it.

### 3.4 Sending

1. Software checks that KBSTAT.TXBUSY is 0.
2. Software writes the byte to KBSEND.
3. The controller holds the clock low for 100 µs, pulls data low, releases the clock and sends the byte with parity on the keyboard's clock. TXBUSY is 1 meanwhile; nothing is received.
4. TXBUSY goes back to 0 when the keyboard has taken the byte.
5. The keyboard answers, usually with `FA`, which arrives in the FIFO. Software waits for it before the next byte.

| Command | Bytes |
|---------|-------|
| Set lights (Scroll, Num, Caps) | `ED`, wait for `FA`, then bits 0–2, wait for `FA` |
| Set repeat rate and delay | `F3`, wait for `FA`, then the rate byte, wait for `FA` |
| Reset and self-test | `FF`, wait for `FA`, then `AA` |

- A write to KBSEND while TXBUSY is 1 is ignored.
- If the keyboard does not take the byte within 15 ms, the controller gives up: TXBUSY goes to 0 and KBIRQ.TIMEOUT is set.

### 3.5 Interrupt

The KEYB request (spec 8 gives its number) is on while any bit is set in both KBIRQ and KBIRQEN, and the controller follows it as a level. It drops when the FIFO is read empty (DATA) and the sticky flags are cleared.

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

With JOYCON.MD1 (or MD2) set, the FPGA also drives the select line low for one sample in each scan and reads A and START from that port. A pad that is present pulls pins 3 and 4 low while select is low; JOYCON.MDPRES1 (or MDPRES2) reports this. With MDn = 0 the select line stays high and the port reads as an Atari stick (A and START read 0). Six-button pads are not read in version 1 (open point J3).

### 4.3 Bit order

The low 5 bits follow the **Kempston** interface, so joystick 1 can also be the Kempston port (section 8.4):

| Bit | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|-----|---|---|---|---|---|---|---|---|
| JOY1 / JOY2 | Right | Left | Down | Up | Fire 1 / B | Fire 2 / C | A | START |

Pad detection (MDPRES1, MDPRES2) is read in JOYCON, not in JOYn, so a Kempston-style read sees only buttons.

## 5. The membrane keyboard

### 5.1 The matrix

The KS3 membrane is a matrix of 8 rows and 7 columns (56 keys). Columns 0–4 hold the Spectrum's 40 keys, in the Spectrum's own layout (section 8.1); columns 5–6 hold the 16 extra Next keys.

### 5.2 Scanning

The FPGA scans the matrix all the time: it drives one row line low at a time and reads the 7 column lines (low = pressed), about every 64 µs per row (a full scan every 0.5 ms). A key's state changes only after two scans in a row agree (debounce, 0.5–1 ms). The result is a 56-bit key map. The CPU never drives the matrix; every read comes from the key map, so any CPU speed works. The membrane has no diodes, so, as on a Spectrum, three keys held at three corners of a rectangle can make the fourth corner look pressed (ghosting).

### 5.3 Extra Next keys

The 16 extra keys are: EXTEND MODE, EDIT, CAPS LOCK, TRUE VIDEO, INV VIDEO, GRAPH, DELETE, BREAK, the four cursor keys, and `;` `"` `,` `.`. Their exact positions in columns 5–6 are taken from the Next's own keyboard code (open point K1).

**KEYX5** and **KEYX6** give columns 5 and 6 of all 8 rows, one bit per row, **1 = pressed** (bit n = row n). Software reads the extra keys here. With KEYCON.KXMAP they also show on port `0xFE` as Spectrum key pairs (section 8.2).

## 6. Registers

| Port | Name | Access | Bits | Description | Reset |
|------|------|--------|------|-------------|-------|
| `0x60` | KBCON | RW | EN (0) | PS/2 receiver on. Turning it off empties the FIFO. Bits 7–1 read 0 | `0x00` |
| `0x61` | KBSTAT | R | COUNT (4–0), TXBUSY (7) | Bytes waiting (0–16); a byte is being sent | `0x00` |
| `0x62` | KBDATA | R | 7–0 | Reading takes one byte from the FIFO (`0x00` if empty) | – |
| `0x63` | KBSEND | W | 7–0 | Send this byte to the keyboard (ignored while TXBUSY) | – |
| `0x64` | KBIRQ | R, W1C | DATA (0), PARITY (1), FRAME (2), OVERFLOW (3), TIMEOUT (4) | DATA follows the FIFO (1 = not empty) and ignores writes. The others are sticky, write 1 to clear. Bits 7–5 read 0 | `0x00` |
| `0x65` | KBIRQEN | RW | Same layout as KBIRQ | Interrupt enables | `0x00` |
| `0x66` | JOY1 | R | 7–0 | Joystick port 1 (section 4.3), 1 = pressed | – |
| `0x67` | JOY2 | R | 7–0 | Joystick port 2 | – |
| `0x68` | JOYCON | RW | MD1 (0), MD2 (1), MDPRES1 (6), MDPRES2 (7) | Read a Mega Drive pad on port 1 / port 2. MDPRES1/2 are read only: a Mega Drive pad answered on that port | `0x00` |
| `0x69` | KEYX5 | R | 7–0 | Membrane column 5, bit n = row n, 1 = pressed | – |
| `0x6A` | KEYX6 | R | 7–0 | Membrane column 6, as KEYX5 | – |
| `0x6B` | KEYCON | RW | KXMAP (0), EAR6 (1) | Spectrum extra (section 8): show the extra keys on port `0xFE`; the value of port `0xFE` bit 6 | `0x03` |
| `0x6C`–`0x6F` | – | – | – | Reserved: read `0xFF`, writes ignored (spec 3) | – |

- KBDATA is one of the system block's FIFO data ports, where reading takes data out (spec 3).
- All these ports also appear in the register page at offset = port (spec 2, section 6.5).
- Which joystick port is "1" (left or right as seen from the front) is to be checked on the board (open point J2).

## 7. FPGA resources

| Item | Resource |
|------|----------|
| PS/2 receiver and sender, 16-byte FIFO, registers | Estimate 100–150 LUTs |
| Matrix scanner, debounce, 56-bit key map, port `0xFE` read logic, KXMAP | Estimate 100–150 LUTs |
| Joystick multiplexer and Mega Drive select | Estimate 30–50 LUTs |
| Block RAM, DSP | None |
| Pins | PS/2: `ps2_clk`, `ps2_data`. Membrane: 8 row outputs, 7 column inputs (`keyb_row_o[7:0]`, `keyb_col_i[6:0]`). Joysticks: `joysel` (U14), the shared direction and button inputs and the select output (open point J1) |
| Request lines | KEYB (level) to spec 8 |

## 8. Spectrum extras

These are outside the retro68k-shaped core. They let Spectrum code that reads the keyboard and a Kempston joystick run unchanged, as long as it uses ports `0xFE` and `0x1F`.

### 8.1 Port 0xFE reads: the keyboard rows

Port `0xFE` is the one system port that looks at A15–A8 (spec 1, section 6). `IN A,(0xFE)` (which puts A on A15–A8) and `IN r,(C)` (which puts B there, with C = `0xFE`) read the membrane exactly like a Spectrum, the upper address byte selecting the rows:

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

| Bit | Value |
|-----|-------|
| 4–0 | Columns 0–4: 0 = a key in that column is pressed in **any** selected row (rows with their address line at 0 are combined, as on a Spectrum, so A15–A8 = 0 reads all rows) |
| 5 | 1 |
| 6 | KEYCON.EAR6 (the Spectrum's EAR input; there is no tape input, so it is a fixed value, 1 after reset) |
| 7 | 1 |

- The whole low byte `0xFE` is decoded. A Spectrum decodes only A0 = 0, so code that reads the keyboard through another even port must be changed to use `0xFE`.
- Reading port `0xFE` changes nothing, so it can be read any number of times.
- **Through memory:** a memory read has no A15–A8 for row select. Offset `0x00FE` of the register page reads as port `0xFE` with all rows selected, and **KEYROW0–7** at offsets `0x0100`–`0x0107` give each row alone, in port `0xFE`'s format (row r = the row selected by A(8 + r) = 0). They are read only, and only in the register page (spec 2, section 6.5).

### 8.2 Extra keys on port 0xFE (KXMAP)

With **KEYCON.KXMAP = 1** (after reset), an extra key also shows on port `0xFE` as the Spectrum key pair it stands for, so Spectrum code sees the keys it expects:

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

With KXMAP = 0, port `0xFE` shows only the 40 Spectrum keys, and a program can treat the extra keys as separate keys (for example cursor keys for a game without CAPS SHIFT held). KEYX5 and KEYX6 show them either way.

### 8.3 Port 0xFE writes

`OUT (0xFE),A` works as on a Spectrum. The whole low byte `0xFE` is decoded; A15–A8 are ignored on writes. The bits belong to other specs:

| Bit | Spectrum use | Here |
|-----|--------------|------|
| 2–0 | Border colour | The background colour, one of the 8 Spectrum colours (spec 4) |
| 3 | MIC (tape out) | Ignored |
| 4 | EAR (beeper) | The beeper (spec 7) |
| 7–5 | Unused | Ignored |

Every write sets both the border and the beeper. Offset `0x00FE` of the register page takes the same writes.

### 8.4 Kempston port 0x1F

Port `0x1F` reads **joystick 1**: the same value as JOY1, at the same moment. Writes to it are ignored. Like every system port it is decoded on A7–A0 only, so `IN A,(0x1F)` and `IN r,(C)` with C = `0x1F` both work, and it is also at offset `0x001F` of the register page.

- Bits 4–0 are Right, Left, Down, Up, Fire as on a Kempston interface. Bits 7–5 carry Fire 2, A and START, where a real Kempston reads 0. With an Atari one-button stick they read 0, so a game that tests the whole byte against 0 sees only what is pressed.
- A real Kempston decodes only A5 = 0; code that reads it through another port (for example `0xDF`) must be changed to use `0x1F`.
- Joystick 2 has no Kempston alias; it is read at JOY2.

### 8.5 Ports

| Port | Name | Access | Bits | Description |
|------|------|--------|------|-------------|
| `0x1F` | KEMPSTON | R | 7–0 | Joystick 1, the same value as JOY1. Writes ignored |
| `0xFE` | (keyboard, border, beeper) | RW | 7–0 | Read: membrane rows selected by A15–A8 (section 8.1). Write: bits 2–0 border (spec 4), bit 4 beeper (spec 7), others ignored |
| Register page `0x0100`–`0x0107` | KEYROW0–7 | R | 7–0 | Membrane row r alone, in port `0xFE`'s format |

## 9. Test plan

- **PS/2, simulation:** a keyboard model sends bytes; they come out of KBDATA in order, and COUNT is right; KBIRQ.DATA and the KEYB request follow the FIFO and KBIRQEN. Bad parity and stop bits set PARITY and FRAME and drop the byte; a 17th byte sets OVERFLOW. A byte sent through KBSEND arrives with the right parity; TXBUSY follows the transfer; a silent model gives TIMEOUT. KBCON.EN = 0 empties the FIFO.
- **Membrane, simulation:** a matrix model with keys held: KEYX5 and KEYX6 show the extra keys; bounce shorter than the debounce time is ignored.
- **Joysticks:** a model of both ports through the multiplexer: every direction and button on each port, Atari and Mega Drive 3-button pads, pad detection; Kempston bit order.
- **Spectrum extras:** each of the 8 row addresses reads the right bits on port `0xFE`; several rows selected at once combine; `IN A,(0xFE)` and `IN A,(C)` with every value of A15–A8; ports other than `0xFE` never read the keyboard; with KXMAP each extra key gives its pair, with KXMAP = 0 it does not; KEYROW0–7 match port `0xFE`; EAR6 reaches bit 6. Port `0x1F` and offset `0x001F` equal JOY1 for every direction and button; writes to `0x1F` change nothing. Port `0xFE` writes reach the border (spec 4) and beeper (spec 7) logic.
- **On the board:** every membrane key, including the 16 extra keys; a few PS/2 keyboards (every key, lights, plugged in while running: `AA` arrives); Atari sticks and Mega Drive pads in both ports; a Spectrum game's keyboard and Kempston code unchanged (when it uses ports `0xFE` and `0x1F`).

## 10. Open points

Pin facts checked in retro68k's KS3 files: the Multiface, DivMMC and reset buttons; `joysel_o` at U14; the SD pins. The rest below is not yet checked against the Next's `zxnext_top_issue5.vhd` and `zxnext_pins_issue5.xdc`.

| # | Item |
|---|------|
| K1 | Positions of the 16 extra keys in matrix columns 5–6, and the row/column numbering of `keyb_row_o` / `keyb_col_i`, from the Next's keyboard code (`membrane` module) |
| K2 | Pin locations of `keyb_row_o[7:0]`, `keyb_col_i[6:0]`, `ps2_clk`, `ps2_data` (not in retro68k's pin file yet). Whether the row outputs must be open drain to avoid shorting two rows when two keys in one column are pressed |
| K3 | Scan and debounce times (64 µs per row, two agreeing scans) to be checked on the real membrane, which is slow to settle |
| K4 | Closed: port `0xFE` writes set the border with bits 2–0 (spec 4) and the beeper with bit 4 (spec 7); MIC is ignored |
| K5 | Should PS/2 keys also show on port `0xFE` (a PS/2 to Spectrum matrix map, as the Next does)? Costs a decoder in hardware; left out for now |
| K6 | Should port `0xFE` bit 6 have a better default for games that test it (issue 2 / issue 3 behaviour)? KEYCON.EAR6 lets software choose |
| K7 | Some USB keyboards also speak PS/2 through a passive adapter; most new ones don't. List keyboards known to work (retro68k's K3) |
| K8 | retro68k's later-version ideas (a key map of all keys, decoded key events, a send queue that waits for `FA`) are left out, as in retro68k version 1. A membrane key map in the core (instead of only port `0xFE` and KEYX5/6) would need 7 more ports; `0x6C`–`0x6F` leave room for 4 |
| J1 | Joystick pin names and locations: the shared inputs (expected as `joyp1_i`–`joyp4_i`, `joyp6_i`, `joyp9_i`) and the Mega Drive select output (`joyp7_o`), and whether select goes to both ports or only the selected one |
| J2 | `joysel` polarity (which level selects which port) and the settle time after switching it; which port is joystick 1 |
| J3 | Six-button Mega Drive pads (X, Y, Z, MODE) need a select pulse sequence; add later if wanted, with a JOYnX register in `0x6C`–`0x6F` |
| J4 | Closed: port `0x1F` reads joystick 1 as a Kempston interface (section 8.4) |
