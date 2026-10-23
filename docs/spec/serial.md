# Spec 10: USB serial

Status: **draft**

The USB serial link connects the computer to a PC through a small FT232H USB module on the KS3's accelerator port. It carries the console (text in and out), program and file uploads, and debug commands. On the PC it is an ordinary serial port, so any terminal program works.

This is retro68k's link (its spec 14, its guide chapter "The USB Serial Link" and `serial.v`) with the same registers, names and bit layouts, cut to bytes. Its ports are `0x50`–`0x57` in the system block (spec 3).

## 1. Summary

| Item | Value |
|------|-------|
| Hardware | An FT232H USB module (e.g. FTDI UM232H-B) on the accelerator port (`accel_io`, 3.3 V), as an 8-bit parallel FIFO in asynchronous 245 FIFO mode. Powered from its own USB cable |
| On the PC | A normal serial port (e.g. `/dev/ttyUSB1` or `COM5`); the baud rate setting is ignored |
| Link speed | Up to about 8 MB/s each way in the FT232H; the Z80 is the limit (section 6) |
| Flow control | In hardware, both ways: no byte is lost; no XON/XOFF or RTS/CTS |
| Buffers | 2 KB receive and 2 KB transmit FIFOs in block RAM, plus the FT232H's own 1 KB each way |
| CPU access | SERDATA for bytes; SERSTAT with the counts (0–255, saturating); interrupts on levels and a timeout |
| Fast transfers | `INIR` / `OTIR` on SERDATA, with B taken straight from SERSTAT |
| Low delay | The FPGA tells the FT232H to send at once when the transmit FIFO empties |
| Interrupt | Source SERIAL (spec 8): data waiting, timeout, room to send, overflow |
| Control commands | retro68k's 16-byte sequence from the PC gives BREAK (NMI), RESET or UPLOAD, even when the Z80 has hung. The same PC tool serves both machines |
| Ports | `0x50`–`0x57` (8 ports) |
| Memory cycles | None (the CPU moves the data) |

## 2. Comparison with retro68k

| retro68k (spec 14) | retro-z80 | Why |
|--------------------|-----------|-----|
| 32-bit registers at `0xF00200` | 8-bit ports `0x50`–`0x57`, in the same order | Z80 (8-bit ports) |
| SERSTAT: RXCOUNT and TXSPACE as 12-bit counts (0–2048) | Two bytes: TXSPACE (`0x51`) and RXCOUNT (`0x52`), each **saturating at 255**. Each byte reads live; reading one does not capture the other | Z80: 8-bit ports. 255 is the most a Z80 block instruction should be given (B = 0 would mean 256) |
| SERDATA read: EMPTY (bit 8) and the byte | The byte only; an empty FIFO reads `0x00` and nothing is taken. Software checks RXCOUNT first | Z80: no bit 8 |
| SERLEVEL: RXLEVEL and TXLEVEL as 12-bit counts | One byte: RXLEVEL (7–4) and TXLEVEL (3–0) as codes, 0 = off, n = 2^(n−1) bytes (1–2048) | Z80: 8-bit ports. Powers of two cover the useful levels |
| SERTIME: 16 bits, microseconds | One byte, in steps of 16 µs (16 µs to 4.08 ms) | Z80: 8-bit ports. A Z80 needs longer timeouts than a 68000, not finer ones |
| SERDROP: count of bytes dropped by TXDROP | Left out | No port left in `0x50`–`0x57` (open point U6) |
| — | SERCON.RXFLUSH, TXFLUSH: write 1 to empty a FIFO | Kept from the earlier retro-z80 design; bits 4–5 are unused in retro68k |
| DMA engine port 1 moves serial data | No DMA | The DMA engine works on SRAM only (spec 14) |
| BREAK sets NMISTAT.USB, NMI level 7 | BREAK sets NMISTAT.USB and drives the Z80's /NMI (spec 8) | Z80: one NMI input |
| Bytes moved with MOVE.B | Bytes moved with `INIR` / `OTIR` (section 6) | Z80 |

Everything else is as in retro68k: the FT232H interface, flow control, SIWU#, the control sequence and its codes, CTLEN and CTLLOCK, TXDROP, the four interrupt flags and their meanings.

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

Pins are provisional and the same as retro68k's KS3 build: `accel_io[7:0]` D7–D0, `[8]` RXF#, `[9]` TXE#, `[10]` RD#, `[11]` WR#, `[12]` SIWU# (open point U2). The accelerator port has pull-ups, so with no module RXF# and TXE# read "not ready" and the link is simply idle.

The interface logic is copied from retro68k, with its RD#/WR# pulse and gap counts re-set for the 56 MHz clock (17.9 ns) so the FT232H's minimum timings are still met.

**Flow control:**

- **PC to computer:** the FPGA reads from the FT232H only while the receive FIFO has room. When it is full, the FT232H's buffer fills and USB holds the PC back. Nothing is lost, however slowly software reads.
- **Computer to PC:** the FPGA writes only when TXE# says there is room. If the PC is not reading, the FT232H and then the transmit FIFO fill up (section 5.3).

**Low delay:** when the transmit FIFO becomes empty after sending, the FPGA pulses SIWU#, so a short console message reaches the PC at once instead of after the FT232H's 16 ms latency timer.

## 4. Control commands from the PC

The receiver watches the data stream for retro68k's 16-byte sequence, unchanged:

```
 00 FF 52 36 38 4B 2D 43 54 4C FF 00 A5 5A  c  ~c
 (0x00 0xFF "R68K-CTL" 0xFF 0x00 0xA5 0x5A, then a command byte c and its inverse)
```

| c | ~c | Command | Effect |
|---|----|---------|--------|
| `0x01` | `0xFE` | BREAK | NMI with NMISTAT.USB set (spec 8), to enter the debug monitor. Only while NMICON.USBEN is set |
| `0x02` | `0xFD` | RESET | Reset the computer, with RESETWHY.USB set (spec 7) |
| `0x03` | `0xFC` | UPLOAD | Reset with RESETWHY.UPLOAD set, so the boot ROM waits for a program over the link (spec 7) |

- The sequence is recognised in hardware, so it works when the Z80 has crashed or runs with interrupts disabled.
- The 16 bytes are removed from the stream; software never sees them. A partly matching sequence that turns out different is passed on unchanged and in order.
- The chance of binary data holding the sequence by accident is about 1 in 2^120 at each position, so file transfers need no escaping.
- While the hardware is matching the start of a sequence it holds those bytes back, so a message that ends with the start of the sequence (a single `0x00`, say) is seen only when the next byte arrives. With CTLEN and CTLLOCK both clear, nothing is held back.
- **SERCON.CTLEN** turns recognition off (on after reset). With **SERCON.CTLLOCK** set, RESET and UPLOAD still work when CTLEN is off. Once set, CTLLOCK cannot be cleared by software; a reset clears it.

The PC tool in `tools/` (shared with retro68k) sends the commands and uploads programs with the boot ROM's loader protocol (spec 7). The sequence is the same as retro68k's, so one tool and one command serve both machines; the tool tells them apart after the fact by what the boot ROM sends (open point U3).

## 5. Using the link from the CPU

### 5.1 Turning it on

SERCON controls the link. The boot ROM writes it in full at start-up, with EN and CTLEN set; a program that may run with no PC attached also sets TXDROP. With EN = 0 nothing is read from or written to the FT232H and writes to SERDATA are thrown away; control commands are still recognised.

### 5.2 Bytes

- **Receive:** reading SERDATA takes the next byte from the receive FIFO. SERSTAT's RXCOUNT says how many are waiting (0–255; 255 means 255 or more). Reading SERDATA when the FIFO is empty returns `0x00` and takes nothing.
- **Send:** writing SERDATA puts a byte in the transmit FIFO. SERSTAT's TXSPACE says how much room there is (0–255; 255 means 255 or more). Writing when the FIFO is full loses the byte and sets SERIRQ.TXOVF, unless SERCON.TXDROP is set (section 5.3).
- The CPU never waits for the link. It reads the counts or uses interrupts.
- Every read of SERDATA takes a byte, through a port or through the register page (spec 2, section 6.5). Don't use read-modify-write instructions (`INC (HL)`, `SET b,(HL)`) on it through the register page.

```
; send A over USB (B, C changed)
putc:   ld   b,a
.wait:  in   a,(SERSTAT)        ; TXSPACE
        or   a
        jr   z,.wait            ; no room yet
        ld   a,b
        out  (SERDATA),a
        ret

; wait for a byte from USB: A = the byte
getc:   in   a,(SERSTAT+1)      ; RXCOUNT
        or   a
        jr   z,getc             ; nothing yet
        in   a,(SERDATA)
        ret
```

### 5.3 When nothing is reading on the PC

If no program on the PC has the port open, or no module is fitted, sent data piles up: first in the FT232H, then in the transmit FIFO. Software can treat a long-full FIFO as "nobody listening". With **SERCON.TXDROP** set, a write to a full FIFO pushes out the oldest byte instead, so debug output never holds a program up; TXOVF is not set, and the dropped bytes are not counted (retro68k's SERDROP is left out, open point U6).

### 5.4 Interrupts

The link is source **SERIAL** in the interrupt controller (spec 8 gives its number and vector). It has retro68k's four flags, in SERIRQ:

| Bit | Flag | Set when | Cleared |
|-----|------|----------|---------|
| 0 | RXREADY | At least RXLEVEL bytes are waiting | By itself, when the count drops below RXLEVEL |
| 1 | RXTIMEOUT | At least one byte has waited for SERTIME without reaching RXLEVEL, and no byte has arrived or been read in that time | Sticky: write 1 |
| 2 | TXREADY | At least TXLEVEL bytes of room are free | By itself, when the room drops below TXLEVEL |
| 3 | TXOVF | A byte was written while the transmit FIFO was full, and was lost | Sticky: write 1 |

SERIRQEN has the same layout. The SERIAL request is on while any bit is set in both SERIRQ and SERIRQEN, and the controller follows it as a level (spec 8). RXREADY and TXREADY follow the FIFOs, so a handler must make the condition go away: read the bytes, or turn the enable off. A level code of 0 turns that flag off; a SERTIME of 0 turns RXTIMEOUT off.

| Use | Settings |
|-----|----------|
| Console | RXLEVEL code 1 (1 byte): an interrupt for every key |
| Bulk receive | RXLEVEL code 9 (256 bytes) and a SERTIME of a few hundred µs: one `INIR` per interrupt, and the timeout catches the tail |
| Transmit | TXREADY enabled only while software has data queued; otherwise it interrupts for ever |
| Wait for the FIFO to drain | TXLEVEL code 12 (2048 bytes of room): TXREADY means the transmit FIFO is empty |

## 6. Fast transfers with INIR and OTIR

System ports decode only A7–A0 (spec 1, section 6), so the Z80's block I/O instructions, which put B on A15–A8, all reach SERDATA whatever B is. The counts saturate at 255, so they go straight into B:

```
; read every byte waiting (up to 255) to (HL)
        in   a,(SERSTAT+1)      ; RXCOUNT
        or   a
        jr   z,.none
        ld   b,a
        ld   c,SERDATA
        inir
; send up to TXSPACE bytes from (HL)
        in   a,(SERSTAT)        ; TXSPACE
        ...                     ; B = the smaller of A and the bytes left
        ld   c,SERDATA
        otir
```

A count never goes down by itself while it is being used (bytes only arrive, and room only grows), so a block of that length never under- or overruns the FIFO.

| Method | T-states per byte | At 28 MHz | At 3.5 MHz |
|--------|-------------------|-----------|------------|
| `INIR` / `OTIR` | 21 | 1.33 MB/s | 167 KB/s |
| Unrolled `INI` / `OUTI` | 16 | 1.75 MB/s | 219 KB/s |
| Polled loop (`IN`, test, store) | about 40–50 | 0.6–0.7 MB/s | 70–90 KB/s |

The FT232H moves bytes faster than this, so the receive FIFO stays topped up during an upload. A 48 KB program arrives in under 40 ms at 28 MHz. Control-command recognition goes on during block transfers.

## 7. Registers

| Port | Name | Access | Bits | Description | Reset |
|------|------|--------|------|-------------|-------|
| `0x50` | SERCON | RW | EN (0), CTLEN (1), CTLLOCK (2), TXDROP (3), RXFLUSH (4), TXFLUSH (5) | Link on; recognise control commands; keep RESET and UPLOAD with CTLEN off (set only; cleared by reset); drop the oldest byte on a full transmit FIFO; write 1 to empty the receive or transmit FIFO (bits 4–5 read 0). Bits 7–6 read 0 | `0x02` |
| `0x51` | SERSTAT | R | TXSPACE (7–0) | Room in the transmit FIFO, 0–255 (255 = 255 or more) | 255 |
| `0x52` | SERSTAT+1 | R | RXCOUNT (7–0) | Bytes in the receive FIFO, 0–255 (255 = 255 or more) | 0 |
| `0x53` | SERDATA | RW | 7–0 | Read: takes one byte from the receive FIFO (`0x00` if empty). Write: puts one byte in the transmit FIFO | – |
| `0x54` | SERLEVEL | RW | RXLEVEL (7–4), TXLEVEL (3–0) | Interrupt thresholds: 0 = off; n = 1–12 means 2^(n−1) bytes (1, 2, 4 … 2048); 13–15 act as 12 | `0x00` |
| `0x55` | SERTIME | RW | 7–0 | RXTIMEOUT time in steps of 16 µs; 0 = off | `0x00` |
| `0x56` | SERIRQ | R, W1C | RXREADY (0), RXTIMEOUT (1), TXREADY (2), TXOVF (3) | RXREADY and TXREADY follow the FIFO levels and ignore writes; RXTIMEOUT and TXOVF are sticky, write 1 to clear. Bits 7–4 read 0 | `0x00` |
| `0x57` | SERIRQEN | RW | Same layout as SERIRQ | Interrupt enables | `0x00` |

- SERSTAT is two separate counts, not one 16-bit value: each byte reads live, and reading `0x51` does not capture `0x52` (an exception to spec 3's capture rule, listed there).
- SERDATA is one of the system block's FIFO data ports, where reading has an effect (spec 3).
- All eight ports also appear in the register page at offset = port (spec 2, section 6.5).
- **After reset:** link off, CTLEN on, CTLLOCK clear, both FIFOs empty, flags clear. The FT232H and the PC's port are not disturbed, so a terminal stays connected while the computer restarts (spec 7); bytes the PC sends meanwhile wait in the FT232H until the boot ROM sets EN.

## 8. FPGA resources

| Item | Resource |
|------|----------|
| Receive and transmit FIFOs, 2 KB each | 2 block RAMs |
| FT232H interface, control-sequence matcher, timeout, registers | Estimate 200–300 LUTs |
| Pins | 13 on the accelerator port |
| Request lines | SERIAL (level) to spec 8; BREAK pulse to the NMI logic (spec 8); RESET and UPLOAD pulses to the reset logic (spec 7) |

## 9. Test plan

- **Loopback:** a PC test sends megabytes of random data; the computer echoes it; it arrives complete and in order, with software reading slowly, with `INIR`, and with unrolled `INI`.
- **Flow control:** stop reading for seconds while the PC sends; nothing is lost.
- **Counts:** RXCOUNT and TXSPACE are exact from 0 to 254 and read 255 from 255 to 2048; an `INIR` of RXCOUNT bytes never reads an empty FIFO; an `OTIR` of TXSPACE bytes never overruns.
- **Interrupts:** RXREADY and TXREADY at every level code; RXTIMEOUT at several SERTIME values with fewer bytes than RXLEVEL; TXOVF on a full FIFO; the SERIAL request follows SERIRQ and SERIRQEN; W1C clears only the sticky flags.
- **No listener:** with the PC port closed, writes fill the FIFO and TXOVF is set; with TXDROP, the oldest bytes drop and TXOVF stays clear.
- **Control commands:** BREAK gives one NMI with NMISTAT.USB set; RESET and UPLOAD reset with RESETWHY.USB and RESETWHY.UPLOAD; the 16 bytes never reach SERDATA; near misses pass through unchanged; CTLEN and CTLLOCK work; commands work with the Z80 stuck in `DI` / `HALT`. The same PC tool commands drive retro68k's simulation and this one.
- **Flush:** RXFLUSH and TXFLUSH empty their FIFO and set the counts.
- **Latency:** a single byte reaches the PC in well under 16 ms (SIWU#).
- **Timing:** in simulation against retro68k's FT232H model at 56 MHz; on the board, measure throughput both ways.

## 10. Open points

| # | Item |
|---|------|
| U1 | Set the FT232H EEPROM to 245 FIFO mode with FT_Prog (once, before first use) |
| U2 | The `accel_io` pin assignment is provisional, shared with retro68k (its open point U6) |
| U3 | Closed: the control sequence is retro68k's, byte for byte, so one PC tool serves both machines. If the tool must know which machine it talks to, it asks after the reset (boot ROM protocol, U4) |
| U4 | The boot ROM's upload protocol (with spec 7), shared with retro68k's |
| U5 | Synchronous 245 FIFO mode is not useful here: the Z80 cannot use more than about 2 MB/s, and the DMA engine (spec 14) has no serial port |
| U6 | SERDROP (bytes dropped by TXDROP) is left out for lack of a port. It could come back if the serial block is given more ports in spec 3, or as a sticky flag in a spare SERIRQ bit (not an interrupt) |
| U7 | Closed (spec 7): a reset clears SERCON and the FIFOs but does not disturb the FT232H or the PC, so the terminal stays connected. Still open in retro68k ("the serial link surviving a reset"); the two should end up the same |
| U8 | Should SERDATA give a way to tell an empty read from a received `0x00`, for example a spare SERIRQ bit set by an empty read? Software that checks RXCOUNT first never needs it |
