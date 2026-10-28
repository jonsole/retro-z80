# Spec 10: USB serial

Status: **draft**

The USB serial link connects the computer to a PC through a small FT232H USB module on the KS3's accelerator port. It carries the console (text in and out), program and file uploads, and debug commands. On the PC it is an ordinary serial port, so any terminal program works.

This is retro68k's link (its spec 14, its guide chapter "The USB Serial Link" and `serial.v`) with the same registers, names and bit layouts, cut to bytes. Its registers are `0x50`–`0x57` and `0x5C` of page `0x00`, the system block (spec 3): SERCON is port `0x5000`. SERDATA is also the low-byte-only port `0x53`, so `INIR` and `OTIR` work on it.

## 1. Summary

| Item | Value |
|------|-------|
| Hardware | An FT232H USB module (e.g. FTDI UM232H-B) on the accelerator port (`accel_io`, 3.3 V), as an 8-bit parallel FIFO in asynchronous 245 FIFO mode. Powered from its own USB cable |
| On the PC | A normal serial port (e.g. `/dev/ttyUSB1` or `COM5`); the baud rate setting is ignored |
| Link speed | Up to about 8 MB/s each way in the FT232H; the Z80 is the limit (section 6), the DMA engine is not |
| Flow control | In hardware, both ways: no byte is lost; no XON/XOFF or RTS/CTS |
| Buffers | 2 KB receive and 2 KB transmit FIFOs in block RAM, plus the FT232H's own 1 KB each way |
| CPU access | SERDATA for bytes; SERSTAT with the counts (0–255, saturating); interrupts on levels and a timeout |
| Fast transfers | `INIR` / `OTIR` on port `0x53`, with B taken straight from SERSTAT: 21 T-states a byte, about 0.95 MB/s at 20 MHz |
| DMA | Port 1 of the DMA engine (spec 14), as retro68k: bulk transfers with no CPU work, paced by the FIFOs |
| Low delay | The FPGA tells the FT232H to send at once when the transmit FIFO empties |
| Interrupt | Source SERIAL (spec 8): data waiting, timeout, room to send, overflow |
| Control commands | `C0 c ~c` from the PC gives BREAK (NMI), RESET or UPLOAD, even when the Z80 has hung. The PC escapes `C0` and `DB` in everything else it sends, SLIP-style; the hardware takes the escapes out |
| Registers | Page `0x00`, registers `0x50`–`0x57` and `0x5C` (ports `0x5000`–`0x5700`, `0x5C00`); SERDATA also on port `0x53` with any high byte |
| Memory cycles | None by the CPU; DMA jobs use the DMA engine's (spec 14) |

## 2. Comparison with retro68k

| retro68k (spec 14) | retro-z80 | Why |
|--------------------|-----------|-----|
| 32-bit registers at `0xF00200` | 8-bit registers `0x50`–`0x57` of page `0x00`, in the same order, and SERDROP at `0x5C` | Z80 (8-bit registers). `0x58`–`0x5B` were already the SD card's, so SERDROP takes the first free register after them |
| SERSTAT: RXCOUNT and TXSPACE as 12-bit counts (0–2048) | Two bytes: SERSTAT0 = TXSPACE (`0x51`) and SERSTAT1 = RXCOUNT (`0x52`), each **saturating at 255**. Each byte reads live; reading one does not capture the other | Z80: 8-bit registers. 255 is the most a Z80 block instruction should be given (B = 0 would mean 256) |
| SERDATA read: EMPTY (bit 8) and the byte | The byte only; an empty FIFO reads `0x00` and nothing is taken. Software checks RXCOUNT first | Z80: no bit 8 |
| SERDATA at a normal address | SERDATA is also **port `0x53` whatever the high byte** | So `INIR` / `OTIR`, which put the count B on A15–A8, reach it |
| SERLEVEL: RXLEVEL and TXLEVEL as 12-bit counts | One byte: RXLEVEL (7–4) and TXLEVEL (3–0) as codes, 0 = off, n = 2^(n−1) bytes (1–2048) | Z80: 8-bit registers. Powers of two cover the useful levels |
| SERTIME: 16 bits, microseconds | One byte, in steps of 16 µs (16 µs to 4.08 ms) | Z80: 8-bit registers. A Z80 needs longer timeouts than a 68000, not finer ones |
| SERDROP: 16-bit count of bytes dropped by TXDROP, cleared by reading | One byte, saturating at 255, cleared by reading | Narrowed |
| — | SERCON.RXFLUSH, TXFLUSH: write 1 to empty a FIFO | Kept from the earlier retro-z80 design; bits 4–5 are unused in retro68k |
| BREAK sets NMISTAT.USB, NMI level 7 | BREAK sets NMISTAT.USB and drives the Z80's /NMI (spec 8) | Z80: one NMI input |
| Bytes moved with MOVE.B | Bytes moved with `INIR` / `OTIR` (section 6) | Z80 |
| Control commands: a 16-byte sequence (`00 FF "R68K-CTL" …`) found in the raw stream; matching bytes held back | `C0 c ~c`, with the PC's other bytes escaped SLIP-style (section 4). Nothing waits for a next byte | Found on the KS2: a frame whose CRC ended in `0x00` waited for the next byte, so the stub dropped it after 1 s and the debugger stalled (about 1 frame in 256). Proposed to retro68k |

Everything else is as in retro68k: the FT232H interface and its timing (the same 100 MHz system clock), flow control, SIWU#, the command codes, CTLEN and CTLLOCK, TXDROP, the four interrupt flags and their meanings, and DMA engine port 1.

## 3. The FIFO link

The FT232H runs in **asynchronous 245 FIFO mode**; its EEPROM is set for this once with FTDI's FT_Prog tool (open point U1). It uses 13 signals plus ground:

| Signal | Direction | Meaning |
|--------|-----------|---------|
| D7–D0 | Both | Data byte |
| RXF# | FTDI → FPGA | Low: a byte from the PC is waiting |
| RD# | FPGA → FTDI | Pulse low to read that byte |
| TXE# | FTDI → FPGA | Low: room for a byte to the PC |
| WR# | FPGA → FTDI | Pulse to write a byte |
| SIWU# | FPGA → FTDI | "Send immediate": send what it holds to the PC now |

Pins are the same as retro68k's KS3 build (checked on the KS2, open point U2): `accel_io[7:0]` D7–D0, `[8]` RXF#, `[9]` TXE#, `[10]` RD#, `[11]` WR#, `[12]` SIWU# (open point U2). The accelerator port has pull-ups, so with no module RXF# and TXE# read "not ready" and the link is simply idle.

The interface logic is retro68k's `serial.v`, unchanged in its timing: both machines run it on a 100 MHz system clock (10 ns), so its RD#/WR# pulse and gap counts already meet the FT232H's minimum timings.

**Flow control:**

- **PC to computer:** the FPGA reads from the FT232H only while the receive FIFO has room. When it is full, the FT232H's buffer fills and USB holds the PC back. Nothing is lost, however slowly software reads.
- **Computer to PC:** the FPGA writes only when TXE# says there is room. If the PC is not reading, the FT232H and then the transmit FIFO fill up (section 5.3).

**Low delay:** when the transmit FIFO becomes empty after sending, the FPGA pulses SIWU#, so a short console message reaches the PC at once instead of after the FT232H's 16 ms latency timer.

## 4. Control commands from the PC

While recognition is on (CTLEN or CTLLOCK set), the bytes from the PC are SLIP-style. Two byte values are kept for the link:

| Bytes from the PC | Reach the FIFO as | Meaning |
|-------------------|-------------------|---------|
| `C0 c ~c` | Nothing | A control command (table below) |
| `DB DC` | `C0` | An escaped data byte |
| `DB DD` | `DB` | An escaped data byte |
| `DB` then any other byte | That byte | Not sent by the PC tools; passed on |
| Any other byte | Itself, at once | Data |

| c | ~c | Command | Effect |
|---|----|---------|--------|
| `0x01` | `0xFE` | BREAK | NMI with NMISTAT.USB set (spec 8), to enter the debug monitor. Only while NMICON.USBEN is set |
| `0x02` | `0xFD` | RESET | Reset the computer, with RESETWHY.USB set (spec 7) |
| `0x03` | `0xFC` | UPLOAD | Reset with RESETWHY.UPLOAD set, so the boot ROM's loader waits for a program over the link (spec 16; the shared spec "Monitor and upload protocol", section 6). This is the only way into UPLOAD: the reset button has no long-press UPLOAD |

- The commands and escapes are handled in hardware, so commands work when the Z80 has crashed or runs with interrupts disabled.
- The command's 3 bytes and the escape bytes are removed from the stream; software and the DMA engine see only the data, in order.
- **No data byte waits for the next one.** Only a `DB` or a command's bytes are held, and the PC always sends what completes them at once. (retro68k's 16-byte sequence held back any bytes that might start it, so a message ending in `0x00` was seen only when the next byte came.)
- A broken command (a wrong inverse, or a code other than 1–3) is dropped. A `C0` always starts a command again, even inside another one.
- The PC tools escape every byte they send except the commands: `rlink.escape()` in every link's `write()`. Random data grows by about 0.8 %.
- With CTLEN and CTLLOCK both clear, every byte goes to the FIFO as it is, `C0` and `DB` too: a program can then run its own protocol on the link, and the PC must not escape.
- **SERCON.CTLEN** turns recognition off (on after reset). With **SERCON.CTLLOCK** set, RESET and UPLOAD still work when CTLEN is off. Once set, CTLLOCK cannot be cleared by software; a reset clears it.

The PC tool `tools/rlink.py` (shared with retro68k) sends the commands and uploads programs with the upload protocol of the shared spec "Monitor and upload protocol" ([`monitor.md`](monitor.md), sections 6 and 8). After the reset the loader's ready line (`LOAD Z80 1`, or `LOAD 68K 1` on retro68k) tells the tool which machine it is talking to. Until retro68k takes the same escapes (open point U3), its tool and this one differ in the command bytes and the escaping.

## 5. Using the link from the CPU

### 5.1 Turning it on

SERCON controls the link. The boot ROM writes it in full at start-up, with EN and CTLEN set; a program that may run with no PC attached also sets TXDROP. With EN = 0 nothing is read from or written to the FT232H and writes to SERDATA are thrown away; control commands are still recognised.

### 5.2 Bytes

- **Receive:** reading SERDATA takes the next byte from the receive FIFO. SERSTAT1 (RXCOUNT) says how many are waiting (0–255; 255 means 255 or more). **Check RXCOUNT before reading SERDATA**: reading SERDATA when the FIFO is empty returns `0x00` and takes nothing, which cannot be told from a received `0x00`.
- **Send:** writing SERDATA puts a byte in the transmit FIFO. SERSTAT0 (TXSPACE) says how much room there is (0–255; 255 means 255 or more). Writing when the FIFO is full loses the byte and sets SERIRQ.TXOVF, unless SERCON.TXDROP is set (section 5.3).
- The CPU never waits for the link. It reads the counts or uses interrupts.
- Every read of SERDATA takes a byte, through port `0x53`, port `0x5300` or the register page (offset `0x0053`). Don't use read-modify-write instructions (`INC (HL)`, `SET b,(HL)`) on it through the register page.
- Because SERDATA ignores the high byte, `IN A,(0x53)` and `OUT (0x53),A` reach it directly. The other serial registers need the page form: `LD BC,port` and `IN r,(C)` / `OUT (C),r`, or `LD A,register` and `IN A,(0x00)`.

```
; send A over USB (A, B, C changed; the byte is kept in E)
putc:   ld   e,a
.wait:  ld   a,0x51             ; SERSTAT0: TXSPACE
        in   a,(0x00)           ; page 0x00: port 0x5100
        or   a
        jr   z,.wait            ; no room yet
        ld   a,e
        out  (0x53),a           ; SERDATA
        ret

; wait for a byte from USB: A = the byte
getc:   ld   a,0x52             ; SERSTAT1: RXCOUNT
        in   a,(0x00)           ; port 0x5200
        or   a
        jr   z,getc             ; nothing yet
        in   a,(0x53)           ; SERDATA
        ret
```

### 5.3 When nothing is reading on the PC

If no program on the PC has the port open, or no module is fitted, sent data piles up: first in the FT232H, then in the transmit FIFO. Software can treat a long-full FIFO as "nobody listening". With **SERCON.TXDROP** set, a write to a full FIFO pushes out the oldest byte instead, so debug output never holds a program up; TXOVF is not set. **SERDROP** counts the bytes dropped since it was last read (saturating at 255); reading it clears it.

### 5.4 Interrupts

The link is source **SERIAL** in the interrupt controller (spec 8 gives its number and vector). It has retro68k's four flags, in SERIRQ:

| Bit | Flag | Set when | Cleared |
|-----|------|----------|---------|
| 0 | RXREADY | At least RXLEVEL bytes are waiting | By itself, when the count drops below RXLEVEL |
| 1 | RXTIMEOUT | At least one byte has waited for SERTIME without reaching RXLEVEL, and no byte has arrived or been read in that time | Sticky: write 1 |
| 2 | TXREADY | At least TXLEVEL bytes of room are free | By itself, when the room drops below TXLEVEL |
| 3 | TXOVF | A byte was written while the transmit FIFO was full, and was lost | Sticky: write 1 |

SERIRQEN has the same layout. The SERIAL request is on while any bit is set in both SERIRQ and SERIRQEN, and the controller follows it as a level (spec 8). RXREADY and TXREADY follow the FIFOs, so a handler must make the condition go away: read the bytes, or turn the enable off. A level code of 0 turns that flag off; a SERTIME of 0 turns RXTIMEOUT off.

The timeout counts in steps of 16 µs, from the microsecond tick that the timers use (spec 9), which comes from the 100 MHz system clock (one tick every 100 clocks). A SERTIME of n gives a timeout between 16(n − 1) and 16n µs.

| Use | Settings |
|-----|----------|
| Console | RXLEVEL code 1 (1 byte): an interrupt for every key |
| Bulk receive | RXLEVEL code 9 (256 bytes) and SERTIME 7 (about 100 µs): one `INIR` per interrupt, and the timeout catches the tail |
| Transmit | TXREADY enabled only while software has data queued; otherwise it interrupts for ever |
| Wait for the FIFO to drain | TXLEVEL code 12 (2048 bytes of room): TXREADY means the transmit FIFO is empty |

### 5.5 Bulk transfers with the DMA engine

The DMA engine's **port 1** is this link, as in retro68k (spec 14). A channel copies bytes from the receive FIFO to SRAM, or from SRAM to the transmit FIFO, one byte at a time, paced by the FIFOs: when the FIFO is empty (receive) or full (transmit) the channel waits and the other channels go on. The CPU does other work meanwhile. Commands and escapes are handled during DMA too: the engine sees only the data.

While a DMA job uses port 1 in one direction, the CPU must not read (receive) or write (transmit) SERDATA in that direction; the counts, flags and the other direction stay usable.

## 6. Fast transfers with INIR and OTIR

SERDATA is port `0x53` whatever A15–A8 hold (spec 3), so the Z80's block I/O instructions, which put B on A15–A8, reach it at every step. The counts saturate at 255, so they go straight into B:

```
; read every byte waiting (up to 255) to (HL)
        ld   bc,SERSTAT1_P      ; port 0x5200: RXCOUNT
        in   a,(c)
        or   a
        jr   z,.none
        ld   b,a                ; the count
        ld   c,0x53             ; SERDATA
        inir
; send up to TXSPACE bytes from (HL)
        ld   bc,SERSTAT0_P      ; port 0x5100: TXSPACE
        in   a,(c)
        ...                     ; B = the smaller of A and the bytes left
        ld   c,0x53             ; SERDATA
        otir
```

A count never goes down by itself while it is being used (bytes only arrive, and room only grows), so a block of that length never under- or overruns the FIFO. A DMA job on port 1 in the same direction would break this; see section 5.5.

| Method | T-states per byte | At 20 MHz | At 3.57 MHz |
|--------|-------------------|-----------|-------------|
| `INIR` / `OTIR` | 21 | 0.95 MB/s | 170 KB/s |
| Unrolled `INI` / `OUTI` | 16 | 1.25 MB/s | 223 KB/s |
| Polled loop (`IN`, test, store) | about 40–50 | 0.4–0.5 MB/s | 71–89 KB/s |
| DMA engine, port 1 | none | Limited by the FT232H and the PC, several MB/s | The same |

The FT232H moves bytes faster than the Z80, so the receive FIFO stays topped up during an upload. A 48 KB program arrives in about 52 ms with `INIR` at 20 MHz. Control-command recognition goes on during block transfers.

## 7. Registers

System block registers, page `0x00` (spec 3): port = (register << 8) | `0x00`; register page offset = `0x0000` + register. SERDATA is also port `0x53` with any high byte. The copper cannot reach these registers.

| Register | Port | Name | Access | Bits | Reset | Description |
|----------|------|------|--------|------|-------|-------------|
| `0x50` | `0x5000` | SERCON | RW | EN (0), CTLEN (1), CTLLOCK (2), TXDROP (3), RXFLUSH (4), TXFLUSH (5) | `0x02` | Link on; recognise control commands; keep RESET and UPLOAD with CTLEN off (set only; cleared by reset); drop the oldest byte on a full transmit FIFO; write 1 to empty the receive or transmit FIFO (bits 4–5 read 0). Bits 7–6 read 0 |
| `0x51` | `0x5100` | SERSTAT0 | R | TXSPACE (7–0) | 255 | Room in the transmit FIFO, 0–255 (255 = 255 or more) |
| `0x52` | `0x5200` | SERSTAT1 | R | RXCOUNT (7–0) | 0 | Bytes in the receive FIFO, 0–255 (255 = 255 or more) |
| `0x53` | `0x5300`, and `0x53` with any high byte | SERDATA | RW | 7–0 | – | Read: takes one byte from the receive FIFO (`0x00` if empty: check RXCOUNT first). Write: puts one byte in the transmit FIFO |
| `0x54` | `0x5400` | SERLEVEL | RW | RXLEVEL (7–4), TXLEVEL (3–0) | `0x00` | Interrupt thresholds: 0 = off; n = 1–12 means 2^(n−1) bytes (1, 2, 4 … 2048); 13–15 act as 12 |
| `0x55` | `0x5500` | SERTIME | RW | 7–0 | `0x00` | RXTIMEOUT time in steps of 16 µs; 0 = off |
| `0x56` | `0x5600` | SERIRQ | R, W1C | RXREADY (0), RXTIMEOUT (1), TXREADY (2), TXOVF (3) | `0x00` | RXREADY and TXREADY follow the FIFO levels and ignore writes; RXTIMEOUT and TXOVF are sticky, write 1 to clear. Bits 7–4 read 0 |
| `0x57` | `0x5700` | SERIRQEN | RW | Same layout as SERIRQ | `0x00` | Interrupt enables |
| `0x5C` | `0x5C00` | SERDROP | R | 7–0 | `0x00` | Bytes dropped by TXDROP since the last read, saturating at 255. Reading clears it. Writes ignored |

- SERSTAT0 and SERSTAT1 are two separate counts, not one 16-bit value: each byte reads live, and reading `0x51` does not capture `0x52` (an exception to spec 3's capture rule, listed there). The next byte of a register is the next register number, so in port form it is + `0x100` (`INC B`), not + 1.
- SERDATA and SERDROP are registers where reading has an effect (spec 3): SERDATA takes a byte, SERDROP clears.
- **After reset:** link off, CTLEN on, CTLLOCK clear, both FIFOs empty, flags and SERDROP clear. The FT232H and the PC's port are not disturbed, so a terminal stays connected while the computer restarts (spec 7); bytes the PC sends meanwhile wait in the FT232H until the boot ROM sets EN.

## 8. FPGA resources

| Item | Resource |
|------|----------|
| Receive and transmit FIFOs, 2 KB each | 2 block RAMs |
| FT232H interface, command and escape decoder, timeout, SERDROP, registers, DMA port 1 handshake | Estimate 200–300 LUTs |
| Pins | 13 on the accelerator port |
| Request lines | SERIAL (level) to spec 8; BREAK pulse to the NMI logic (spec 8); RESET and UPLOAD pulses to the reset logic (spec 7); port 1 ready/take to the DMA engine (spec 14) |

## 9. Test plan

- **Loopback:** a PC test sends megabytes of random data; the computer echoes it; it arrives complete and in order, with software reading slowly, with `INIR`, with unrolled `INI`, and with DMA jobs on port 1 both ways.
- **Flow control:** stop reading for seconds while the PC sends; nothing is lost.
- **Counts:** RXCOUNT and TXSPACE are exact from 0 to 254 and read 255 from 255 to 2048; an `INIR` of RXCOUNT bytes never reads an empty FIFO; an `OTIR` of TXSPACE bytes never overruns.
- **Ports:** SERDATA answers at `0x53` with every high byte (as `INIR` with B from 255 down to 1 uses), at `0x5300` and at register page offset `0x0053`; the other serial registers answer only in their page form (`0x5000` and so on); `IN A,(0x50)` reaches reserved page `0x50` and reads `0xFF`.
- **Interrupts:** RXREADY and TXREADY at every level code; RXTIMEOUT at several SERTIME values with fewer bytes than RXLEVEL; TXOVF on a full FIFO; the SERIAL request follows SERIRQ and SERIRQEN; W1C clears only the sticky flags.
- **No listener:** with the PC port closed, writes fill the FIFO and TXOVF is set; with TXDROP, the oldest bytes drop, TXOVF stays clear and SERDROP counts them, saturates at 255 and clears when read.
- **Control commands and escapes** (`make -C sim serial`, `tb_serial.v`): a frame ending in `0x00` is all in the FIFO at once; `DB DC` and `DB DD` give `C0` and `DB`; commands among data give one pulse each and leave nothing in the FIFO; broken commands are dropped and a `C0` starts again; CTLLOCK alone keeps RESET and UPLOAD but not BREAK; with CTLEN and CTLLOCK clear every byte is raw. In the system tests: BREAK gives one NMI with NMISTAT.USB set; RESET and UPLOAD reset with RESETWHY.USB and RESETWHY.UPLOAD; commands work with the Z80 stuck in `DI` / `HALT`.
- **On the board:** an upload of every byte value; 40 debugger steps from VS Code with registers read after each (before this change, a register read whose CRC ended in `0x00` stalled).
- **Flush:** RXFLUSH and TXFLUSH empty their FIFO and set the counts.
- **DMA:** port 1 jobs each way at full speed; a stalled port does not hold up other channels.
- **Latency:** a single byte reaches the PC in well under 16 ms (SIWU#).
- **Timing:** in simulation against retro68k's FT232H model at 100 MHz; on the board, measure throughput both ways.

## 10. Open points

| # | Item |
|---|------|
| U1 | Set the FT232H EEPROM to 245 FIFO mode with FT_Prog (once, before first use) |
| U2 | Checked on the KS2 (issue 4 schematic, sheets 2 and 5): `accel_io[n]` is Pi GPIO n on header J2, through 200 ohm, with no level shifting; D0-D7 on pins 27, 28, 3, 5, 7, 29, 31, 26, RXF# 24, TXE# 21, RD# 19, WR# 23, SIWU# 32 (wiring in `fpga/ks2/README.md`). Still shared with retro68k (its U6); the KS3's issue 5 pin file puts these on the same FPGA pins |
| U3 | Open: the SLIP-style commands and escapes (section 4) replace retro68k's 16-byte sequence here, built and tried on the KS2 first; proposed to retro68k so that one PC tool serves both machines again. The tool knows which machine it talks to from the loader's ready line (shared spec, section 6.1) |
| U4 | Closed: the upload protocol is the shared spec "Monitor and upload protocol" (`monitor.md`), the same in retro68k: frames with a CRC-32, a reply to each, the image header; spec 16 gives retro-z80's limits |
| U5 | Synchronous 245 FIFO mode (about 40 MB/s, two more pins) could help DMA jobs on port 1; shared with retro68k's U5. The CPU cannot use it |
| U6 | Closed: SERDROP is at register `0x5C` of page `0x00` (branch 11) |
| U7 | Closed (spec 7): a reset clears SERCON and the FIFOs but does not disturb the FT232H or the PC, so the terminal stays connected. Still open in retro68k ("the serial link surviving a reset"); the two should end up the same |
| U8 | Closed: software checks RXCOUNT before reading SERDATA (branch 11); an empty read gives `0x00` and no flag |
