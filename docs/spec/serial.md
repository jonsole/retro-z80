# Spec 10: USB serial

Status: **draft**

The USB serial link connects the computer to a PC through a small FT232H USB module on the KS3's accelerator port. It carries the console, program and file uploads, and debug commands. On the PC it is an ordinary serial port. The logic is retro68k's (its spec 14 and `serial.v`), with 8-bit registers. Its ports are `0x28`–`0x2B`.

## 1. Summary

| Item | Value |
|------|-------|
| Hardware | An FT232H USB module (e.g. FTDI UM232H-B) on the accelerator port (`accel_io`, 3.3 V), as an 8-bit parallel FIFO in asynchronous 245 FIFO mode. Powered from its own USB cable |
| On the PC | A normal serial port; the baud rate setting is ignored |
| Link speed | Up to about 8 MB/s each way in the FT232H; the Z80 is the limit (section 5) |
| Flow control | In hardware, both ways: no byte is lost; no XON/XOFF or RTS/CTS |
| Buffers | 2 KB receive and 2 KB transmit FIFOs in block RAM, plus the FT232H's own 1 KB each way |
| CPU access | A data port, a status port with FIFO flags, a control port, an interrupt-level port |
| Fast transfers | `INIR` / `OTIR` (or unrolled `INI` / `OUTI`) on the data port, 256 bytes at a time |
| Interrupts | SERRX (source 7) and SERTX (source 8) in spec 8, both level sources |
| Control commands | A 16-byte sequence from the PC gives BREAK (NMI), RESET or UPLOAD, even when the Z80 has hung |
| Ports | `0x28`–`0x2B` (4 ports) |
| Memory cycles | None (the CPU moves the data) |

## 2. The FIFO link

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

- **PC to computer:** the FPGA reads from the FT232H only while the receive FIFO has room. When it is full, the FT232H's buffer fills and USB holds the PC back.
- **Computer to PC:** the FPGA writes only when TXE# says there is room. If the PC is not reading, the FT232H and then the transmit FIFO fill up (section 4.3).

**Low delay:** when the transmit FIFO becomes empty after sending, the FPGA pulses SIWU#, so a short console message reaches the PC at once instead of after the FT232H's 16 ms latency timer.

## 3. Control commands from the PC

The receiver watches the data stream for this 16-byte sequence:

```
 00 FF 52 5A 38 30 2D 43 54 4C FF 00 A5 5A  c  ~c
 (0x00 0xFF "RZ80-CTL" 0xFF 0x00 0xA5 0x5A, then a command byte c and its inverse)
```

| c | Command | Effect |
|---|---------|--------|
| `0x01` | BREAK | NMI, with INTREQH.NMIUSB set (spec 8, section 9), to enter the debug monitor. Ignored if INTENH.NMIUSBEN is 0 |
| `0x02` | RESET | Reset the computer; the reset cause says USB (spec 7) |
| `0x03` | UPLOAD | Reset with the UPLOAD cause, so the boot ROM waits for a program over the link (spec 7) |

- The sequence is recognised in hardware, so it works when the Z80 has crashed or runs with interrupts disabled.
- The 16 bytes are removed from the stream; software never sees them. A partly matching sequence that turns out different is passed on unchanged and in order.
- The chance of binary data holding the sequence by accident is about 1 in 2^120 at each position, so file transfers need no escaping.
- **SERCTL.CTLEN** turns recognition off (on after reset). With **SERCTL.CTLLOCK** set, RESET and UPLOAD still work when CTLEN is off; CTLLOCK stays set until the next reset.

A PC tool in `tools/` sends the commands and uploads programs with the boot ROM's loader protocol (with the boot ROM, spec 7).

## 4. Using the link from the CPU

### 4.1 Bytes

- **Receive:** reading SERDATA takes the next byte from the receive FIFO. If the FIFO is empty the read returns `0x00` and takes nothing; software checks SERSTAT.RXAVAIL first.
- **Send:** writing SERDATA puts a byte in the transmit FIFO. If the FIFO is full the byte is lost and SERSTAT.TXOVF is set (unless SERCTL.TXDROP, section 4.3).
- The CPU never waits for the link. The 8-bit status port cannot hold the byte counts (0–2048), so it gives flags for "at least 1" and "at least 256", which is what `INIR` and `OTIR` need.

### 4.2 Interrupts

Both serial sources are **levels** (spec 8): the request follows the condition and drops by itself when software has served the FIFO.

| Source | Request is on while |
|--------|---------------------|
| SERRX (7) | The receive FIFO holds at least RXLEVEL bytes, **or** it holds at least one byte and no byte has arrived or been read for RXTIME (the receive timeout) |
| SERTX (8) | The transmit FIFO has at least TXLEVEL bytes of room |

RXLEVEL, TXLEVEL and RXTIME are chosen in SERLEVEL (section 6) from a few fixed values. A console driver uses RXLEVEL = 1. A bulk receiver uses RXLEVEL = 256 and reads 256 bytes with one `INIR` per interrupt, plus a short RXTIME to catch the tail of a transfer. A transmit driver enables SERTX only while it has data queued, and disables it in INTENH when its own buffer is empty; otherwise the interrupt stays on.

### 4.3 When nothing is reading on the PC

If no program on the PC has the port open, sent data piles up: first in the FT232H, then in the transmit FIFO. Software can treat a long-full FIFO as "nobody listening". With **SERCTL.TXDROP** set, a write to a full FIFO drops the oldest byte to make room instead, and TXOVF is not set, so debug output never holds a program up.

## 5. Fast transfers with INIR and OTIR

Only the low 8 bits of the port address are decoded (spec 3), so the Z80's block I/O instructions, which put B on A15–A8, all reach SERDATA whatever B is.

```
; read 256 bytes to (HL), once SERSTAT.RXBLOCK is set
        ld   bc,0x0028       ; B = 0 (256 bytes), C = SERDATA
        inir
; send 256 bytes from (HL), once SERSTAT.TXBLOCK is set
        ld   bc,0x0028
        otir
```

RXBLOCK means at least 256 bytes are waiting, and TXBLOCK at least 256 bytes of room, so a 256-byte `INIR` or `OTIR` started after checking it never under- or overruns the FIFO.

| Method | T-states per byte | At 28 MHz | At 3.5 MHz |
|--------|-------------------|-----------|------------|
| `INIR` / `OTIR` | 21 | 1.33 MB/s | 167 KB/s |
| Unrolled `INI` / `OUTI` | 16 | 1.75 MB/s | 219 KB/s |
| Polled loop (`IN`, test, store) | about 40–50 | 0.6–0.7 MB/s | 70–90 KB/s |

The FT232H moves bytes faster than this, so the receive FIFO stays topped up during an upload. A 48 KB program arrives in under 40 ms at 28 MHz. Control-command recognition goes on during block transfers.

## 6. Registers

| Port | Name | Bits | Description |
|------|------|------|-------------|
| `0x28` | SERDATA | 7–0 | Read: takes one byte from the receive FIFO (`0x00` if empty). Write: puts one byte in the transmit FIFO |
| `0x29` | SERSTAT | RXAVAIL (0), RXBLOCK (1), TXROOM (2), TXBLOCK (3), TXEMPTY (4), RXREQ (5), TXREQ (6), TXOVF (7) | Read: at least 1 / at least 256 bytes waiting; at least 1 / at least 256 bytes of room; transmit FIFO empty; SERRX and SERTX request states. TXOVF is sticky: a byte was lost on a full FIFO; write 1 to bit 7 to clear it. Other bits ignore writes |
| `0x2A` | SERCTL | EN (0), CTLEN (1), CTLLOCK (2), TXDROP (3), RXFLUSH (4), TXFLUSH (5) | Link on; recognise control commands; keep RESET and UPLOAD with CTLEN off (set until reset); drop oldest on a full transmit FIFO; write 1 to empty the receive or transmit FIFO (bits 4–5 read 0) |
| `0x2B` | SERLEVEL | RXLEVEL (1–0), TXLEVEL (3–2), RXTIME (5–4) | RXLEVEL: 0 = 1, 1 = 16, 2 = 256, 3 = 1024 bytes. TXLEVEL (room): 0 = 1, 1 = 16, 2 = 256, 3 = 1024 bytes. RXTIME: 0 = off, 1 = 64 µs, 2 = 1 ms, 3 = 16 ms (from the 1 µs tick, spec 9) |

**After reset:** SERCTL = `0x02` (link off, CTLEN on), SERLEVEL = 0, both FIFOs empty, TXOVF clear. The boot ROM sets EN. With EN = 0 nothing is read from or written to the FT232H, writes to SERDATA are ignored, and control commands are still recognised.

## 7. FPGA resources

| Item | Resource |
|------|----------|
| Receive and transmit FIFOs, 2 KB each | 2 block RAMs (in the design plan's budget, D11) |
| FT232H interface, control-sequence matcher, timeout, registers | Estimate 200–300 LUTs |
| Pins | 13 on the accelerator port |
| Request lines | SERRX, SERTX (levels) to spec 8; BREAK pulse to the NMI logic; RESET and UPLOAD pulses to the reset logic (spec 7) |

## 8. Test plan

- **Loopback:** a PC test sends megabytes of random data; the computer echoes it; it arrives complete and in order, with software reading slowly, with `INIR`, and with unrolled `INI`.
- **Flow control:** stop reading for seconds while the PC sends; nothing is lost.
- **Flags:** RXAVAIL, RXBLOCK, TXROOM, TXBLOCK and TXEMPTY switch at exactly 1 and 256 bytes; a 256-byte `INIR` after RXBLOCK never reads an empty FIFO.
- **Interrupts:** SERRX at each RXLEVEL, and by timeout with fewer bytes; SERTX at each TXLEVEL; both drop when served.
- **No listener:** with the PC port closed, writes fill the FIFO; TXOVF is set; with TXDROP, old bytes drop and TXOVF stays clear.
- **Control commands:** BREAK gives one NMI with NMIUSB set; RESET and UPLOAD reset with the right cause; the 16 bytes never reach SERDATA; near misses pass through unchanged; CTLEN and CTLLOCK work; commands work with the Z80 stuck in `DI` / `HALT`.
- **Latency:** a single byte reaches the PC in well under 16 ms (SIWU#).
- **Timing:** in simulation against retro68k's FT232H model at 56 MHz; on the board, measure throughput both ways.

## 9. Open points

| # | Item |
|---|------|
| U1 | Set the FT232H EEPROM to 245 FIFO mode with FT_Prog (once, before first use) |
| U2 | The `accel_io` pin assignment is provisional, shared with retro68k (its open point U6) |
| U3 | The control sequence uses "RZ80-CTL" so the PC tool can tell the machines apart; the alternative is retro68k's exact sequence, so one tool command works for both |
| U4 | The boot ROM's upload protocol (with spec 7) |
| U5 | Synchronous 245 FIFO mode is not useful here: the Z80 cannot use more than about 2 MB/s. Revisit with a DMA engine |
| U6 | Should SERSTAT give a coarse byte count (for example in 64-byte steps) instead of the RXREQ and TXREQ bits? |
