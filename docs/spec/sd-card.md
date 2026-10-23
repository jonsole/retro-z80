# Spec 11: SD card

Status: **draft**

The SD card is the computer's storage. The KS3's SD slot is wired for **SPI mode** only. This is retro68k's version-1 controller (its spec 15): a plain **SPI byte master**. Software writes a byte, the controller clocks it out while clocking a byte in, and software reads the result. Software does everything else: the card start-up, commands and their CRCs, data tokens, busy waiting and the file system (FAT). Bulk data can go through the DMA engine's port 0 (spec 14), as in retro68k, or through the Z80's `INIR` and `OTIR`. The controller has no interrupt; software polls it.

The registers use retro68k's names and bit positions (SDCON with EN, CS0, CS1 and CLKDIV; SDDATA; SDCOUNT), cut to bytes. They are registers `0x58`–`0x5B` and `0x5D`–`0x5E` of page `0x00`, the system block (spec 3): SDCON is port `0x5800`. SDDATA is also the low-byte-only port `0x5B`, so `INIR` and `OTIR` work on it.

## 1. Summary

| Item | Value |
|------|-------|
| Slot | The KS3's SD slot: `sd_sclk`, `sd_mosi`, `sd_miso`, `sd_cs0` (the slot), `sd_cs1` (wired and driven, use unknown) |
| Cards | SD, SDHC and SDXC at 3.3 V, in SPI mode |
| SPI | Mode 0 (clock idles low, data sampled on the rising edge), most significant bit first |
| SPI clock | 100 MHz ÷ (2 × CLKDIV): 400 kHz for start-up (CLKDIV = 125), 25 MHz for data (CLKDIV = 2), as retro68k |
| Transfer | One byte each way per exchange; an exchange takes 16 × CLKDIV + 2 system clocks (0.34 µs at 25 MHz) |
| Block reads | By the DMA engine (port 0, with SDCOUNT): about 2.9 MB/s. Or `INIR` on port `0x5B` with SDCON.AUTO set: about 0.95 MB/s at 20 MHz |
| Block writes | By the DMA engine (port 0), or `OTIR` on port `0x5B` |
| Interrupt | None; source SD is not used in version 1 (spec 8), as in retro68k version 1 |
| Card detect | None on the KS3 (section 7) |
| Registers | Page `0x00`, registers `0x58`–`0x5B`, `0x5D`–`0x5E` (ports `0x5800`–`0x5B00`, `0x5D00`–`0x5E00`); SDDATA also on port `0x5B` with any high byte. `0x5C` is the serial port's SERDROP (spec 10); `0x5F` is reserved |
| Memory cycles | None by the controller; DMA jobs use the DMA engine's (spec 14) |

## 2. Comparison with retro68k

| retro68k (spec 15, version 1) | retro-z80 | Why |
|-------------------------------|-----------|-----|
| 32-bit registers at `0xF00300` | 8-bit registers `0x58`–`0x5E` of page `0x00` | Z80 (8-bit registers) |
| SDCON: EN (0), CS0 (1), CS1 (2), CLKDIV (15–8) | The same bits: SDCON0 (register `0x58`) holds bits 7–0, SDCON1 (`0x59`) holds CLKDIV (bits 15–8); each byte acts when written | Narrowed, layout kept (open point SD7) |
| — | SDCON.AUTO (bit 7): a read of SDDATA starts the next `0xFF` exchange | Lets `INIR` read a block (section 4). retro-z80 only, placed in the top bit to keep retro68k's low bits free |
| SDDATA: BYTE (7–0), BUSY (8) on reads | SDDATA is the byte only; BUSY is in SDSTAT (register `0x5A`, bit 0) | Z80: no bit 8 |
| SDDATA at a normal address | SDDATA is also **port `0x5B` whatever the high byte** | So `INIR` / `OTIR`, which put the count B on A15–A8, reach it |
| SDCOUNT: 16 bits | Two bytes, SDCOUNT0–1 (registers `0x5D`–`0x5E`), each written directly; a write to the high byte starts the run | Narrowed; `0x5C` was already SERDROP's |
| SCLK = 100 MHz ÷ (2 × CLKDIV); CLKDIV 0 and 1 count as 2 | The same | Same system clock |
| DMA engine port 0 | The same (spec 14) | – |
| Source SD (16): unused in version 1 | Source SD reserved (spec 8 numbers it) | As retro68k |

## 3. How an exchange works

- **Writing SDDATA** starts an exchange: the byte written goes out on MOSI, most significant bit first, while 8 bits are clocked in from MISO. SDSTAT.BUSY is 1 until the exchange ends. To read a byte from the card, send `0xFF`.
- **Reading SDDATA** returns the byte received by the last exchange. With **SDCON.AUTO = 1** the read also starts a new exchange that sends `0xFF`, so the next byte is on its way while software stores this one. With AUTO = 0 a read starts nothing.
- A write to SDDATA, or an AUTO read, while BUSY is 1 is ignored: no exchange starts and the byte is lost. As in retro68k, there is no transmit buffer and the CPU never waits; section 4 shows that the Z80 is never fast enough to hit this at 25 MHz.
- Between exchanges the clock stays low and MOSI stays high, which is what a card expects when idle.
- **Select lines:** SDCON.CS0 and SDCON.CS1 drive the two select lines, 1 = selected (the line low), as in retro68k. Software selects the card before a command, releases it afterwards, then sends one more `0xFF` byte with the card released, as SD cards in SPI mode expect. Change the select lines only while not BUSY.
- **SDCON.EN = 0:** no exchanges, both select lines high, SCLK low, writes to SDDATA ignored. Exchanges run whenever EN = 1, with the card selected or not, so the start-up clocks are ordinary `0xFF` exchanges with CS0 = CS1 = 0.

### 3.1 Writing SDCON

SDCON is a 2-byte register, and each byte acts when it is written (spec 3, rule 2). So a change of CS0, CS1, AUTO or EN is one write to SDCON0 (`0x5800`), and a change of CLKDIV one write to SDCON1 (`0x5900`):

```
        ld   bc,SDCON0_P               ; port 0x5800
        ld   a,SDCON_EN_M|SDCON_CS0_M  ; select the card, AUTO off
        out  (c),a                     ; acts at once
```

Through the register page, `LD (REGS+SDCON0),HL` with L = the control bits and H = CLKDIV writes both in one instruction (spec 2). A change of CLKDIV takes effect at the next exchange; changing it during an exchange is not allowed (the result is undefined).

## 4. Clock and speed

SCLK = 100 MHz ÷ (2 × CLKDIV). CLKDIV = 0 and 1 count as 2, as in retro68k.

| CLKDIV | SCLK | Exchange time | Use |
|--------|------|---------------|-----|
| 125 | 400 kHz | 20.0 µs | Start-up (cards need 100–400 kHz until ready); value after reset |
| 4 | 12.5 MHz | 0.66 µs | Fallback if 25 MHz proves unreliable (open point SD1) |
| 2 | 25 MHz | 0.34 µs | Normal data transfers: the SD default-speed limit |

**No timing rule at 25 MHz.** The controller never makes the CPU wait, so a block instruction must not come back to SDDATA before the exchange it started has ended. At CLKDIV = 2 an exchange is 34 system clocks. The quickest the Z80 can come back is unrolled `INI` / `OUTI`, 16 T-states: 80 clocks at 20 MHz, 64 at 25 MHz. So `INIR`, `OTIR`, `INI` and `OUTI` are all safe at every CPU speed. At 400 kHz, software polls BUSY (or waits) between bytes.

| Method | Per byte | 512-byte block | Speed |
|--------|----------|----------------|-------|
| DMA engine, port 0 | One exchange, 0.34 µs | 174 µs | About 2.9 MB/s |
| `INIR` / `OTIR` at 20 MHz | 21 T-states, 1.05 µs | 538 µs | About 0.95 MB/s |
| `INIR` / `OTIR` at 3.57 MHz | 5.9 µs | 3.0 ms | About 170 KB/s |

These leave out the command and the wait for the start token. Loading a 48 KB file takes about 17 ms by DMA, or 52 ms by `INIR` at 20 MHz, plus FAT work.

## 5. Typical sequences

### 5.1 Reading a block with INIR

SDHC: the argument is the block number.

```
        ; select (CS0, AUTO off, CLKDIV 2) as in section 3.1
        ; send CMD17: 6 bytes (0x51, 4 argument bytes, CRC or 0xFF) with OUT (0x5B),A
        ; read the R1 response: send 0xFF until a byte with bit 7 = 0 (up to 8 tries)
        ; wait for the start token: send 0xFF until 0xFE (timeout ~100 ms, with a timer)
        ld   bc,SDCON0_P
        ld   a,SDCON_EN_M|SDCON_CS0_M|SDCON_AUTO_M
        out  (c),a
        inc  b
        ld   a,2
        out  (c),a                     ; AUTO on
        in   a,(0x5B)                  ; SDDATA: discard the 0xFE; starts the exchange for data byte 0
        ld   hl,buffer
        ld   bc,0x005B                 ; B = 0: 256 bytes, C = SDDATA
        inir                           ; bytes 0-255 (each read starts the next exchange)
        inir                           ; bytes 256-511
        in   a,(0x5B)                  ; CRC high byte
        in   a,(0x5B)                  ; CRC low byte (and one spare exchange)
        ld   bc,SDCON0_P
        ld   a,SDCON_EN_M              ; release the card, AUTO off
        out  (c),a
        inc  b
        ld   a,2
        out  (c),a
        ld   a,0xFF
        out  (0x5B),a                  ; 8 clocks with the card released
```

The first read after setting AUTO returns the byte of the last exchange (the token) and starts the exchange for data byte 0; each `INIR` read then returns one data byte and starts the next. SDDATA is port `0x5B` whatever the high byte holds, so the falling count in B does not matter, and `IN A,(0x5B)` and `OUT (0x5B),A` reach it directly.

### 5.2 Reading a block with the DMA engine

As retro68k's spec 15, section 3.5:

1. Send CMD17 and wait for R1 and the start token `0xFE`, as above, with AUTO off.
2. Write 512 to SDCOUNT: SDCOUNT0 = `0x00`, then SDCOUNT1 = `0x02` (starts the run).
3. Run a DMA job: COPY from port 0 to the buffer, 512 bytes (spec 14).
4. When the job is done, read the 2 CRC bytes, release the card, send one more `0xFF`.

**SDCOUNT** gives the controller a run of bytes to read for the DMA engine: writing N (1–65535) starts it. Its bytes are written directly, and a write to SDCOUNT1 is the start trigger, as a strobe is: write SDCOUNT0 first, then SDCOUNT1, even when the high byte does not change. `LD (nn),HL` through the register page does both in that order. A write to SDCOUNT0 alone changes the count but starts nothing; while a run goes it changes the bytes still to read. The controller clocks in byte after byte, sending `0xFF`, and hands each to DMA port 0; it starts the next as soon as the engine has taken the last, until N bytes have been read. Reading SDCOUNT gives the bytes still to read (reading SDCOUNT0 captures both bytes, spec 3). So the controller never reads past the end of the block: it stops before the CRC bytes, which software then reads itself.

As a destination, port 0 sends each byte the engine gives it, as soon as the last has gone (the bytes received are dropped). While SDCOUNT is not 0, or a DMA job sends to port 0, the CPU must not write SDDATA or read it with AUTO set.

### 5.3 Writing a block

Select, send CMD24, read R1, send `0xFF`, then the start token `0xFE`, 512 bytes (two `OTIR`s, or a DMA job to port 0), two CRC bytes (any value unless CRC checking is on), read the data-response token (`xxx00101` = accepted), then send `0xFF` until the card stops answering `0x00` (busy), with a timeout.

### 5.4 Start-up

The standard SPI-mode sequence, as in retro68k spec 15, section 4; done by the boot ROM:

1. EN = 1, CS0 = CS1 = 0, CLKDIV = 125 (400 kHz); send 10 bytes of `0xFF` (80 clocks; cards need at least 74 with the card released).
2. Select; CMD0 (CRC `0x95`): expect R1 = `0x01`. No answer means no card, or a card that does not work.
3. CMD8 with `0x000001AA` (CRC `0x87`): new cards echo `0x1AA`; SDv1 cards reply "illegal command".
4. CMD55 + ACMD41 (bit 30 set for SDHC/SDXC) until R1 = `0x00`, with a timeout of about 1 s.
5. CMD58: OCR bit 30 (CCS) set = SDHC/SDXC (block addresses); clear = SDSC (byte addresses; also send CMD16 with 512).
6. CLKDIV = 2 (25 MHz).

Commands sent after CMD8 need no correct CRC unless CRC checking is turned on with CMD59; software computes CRC7 and CRC16 only if it wants that.

## 6. Registers

System block registers, page `0x00` (spec 3): port = (register << 8) | `0x00`; register page offset = `0x0000` + register. SDDATA is also port `0x5B` with any high byte. The copper cannot reach these registers.

| Register | Port | Name | Access | Bits | Reset | Description |
|----------|------|------|--------|------|-------|-------------|
| `0x58` | `0x5800` | SDCON0 | RW | EN (0), CS0 (1), CS1 (2), AUTO (7) | `0x00` | Controller on; select lines (1 = selected, the line low); reads of SDDATA start an `0xFF` exchange. Bits 6–3 read 0. Acts when written |
| `0x59` | `0x5900` | SDCON1 | RW | CLKDIV (7–0) = SDCON bits 15–8 | 125 | SCLK = 100 MHz ÷ (2 × CLKDIV); 0 and 1 count as 2. Acts when written; the control bits are kept |
| `0x5A` | `0x5A00` | SDSTAT | R | BUSY (0) | `0x00` | An exchange is running. Bits 7–1 read 0 |
| `0x5B` | `0x5B00`, and `0x5B` with any high byte | SDDATA | RW | 7–0 | `0xFF` | Write: send this byte (starts an exchange; ignored while BUSY). Read: the byte received by the last exchange; with AUTO = 1 the read also starts an exchange sending `0xFF` |
| `0x5C` | `0x5C00` | SERDROP | | | | The serial port's (spec 10) |
| `0x5D` | `0x5D00` | SDCOUNT0 | RW | COUNT (7–0) | `0x00` | Bytes to read for DMA port 0, low byte, written directly. Reading captures both bytes |
| `0x5E` | `0x5E00` | SDCOUNT1 | RW | COUNT (15–8) | `0x00` | High byte; writing it sets bits 15–8 and starts the run (section 5.2). Reads the captured value |
| `0x5F` | `0x5F00` | – | – | – | – | Reserved: reads `0xFF`, writes ignored |

- SDDATA is a register where reading can have an effect (with AUTO set), through a port or through the register page (spec 3).
- **After reset:** controller off, both selects released, AUTO off, CLKDIV = 125, no exchange or run going, SDDATA reads `0xFF`.

## 7. No card detect

As on retro68k (its spec 15, section 5): the KS3 has no card-detect switch, and in SPI mode the card's DAT3 is its select line. Software finds the card by talking to it: CMD0 with no answer means no card; commands timing out mean it was removed; reading the CID (CMD10) after start-up tells a swapped card from the same one.

## 8. FPGA resources

| Item | Resource |
|------|----------|
| Shift register, bit counter, clock divider, SDCOUNT, DMA port 0 handshake, registers | Estimate 80–120 LUTs (as retro68k) |
| Block RAM, DSP | None |
| Pins | 5: `sd_sclk` (M1), `sd_mosi` (M2), `sd_miso` (L1, pulled up), `sd_cs0` (N1), `sd_cs1` (K2), as in retro68k's KS3 build |
| Request lines | None to spec 8; port 0 ready/take to the DMA engine (spec 14) |

## 9. Test plan

- **Simulation:** against an SPI-mode SD card model shared with retro68k: bit order, mode 0 timing; every CLKDIV from 0 to 255 gives the right clock; BUSY covers the whole exchange.
- **SDCON:** a write to SDCON0 alone changes the control bits at once and keeps CLKDIV; a write to SDCON1 alone changes CLKDIV and keeps the control bits; CS0 and CS1 drive their lines; EN = 0 stops exchanges and releases both lines; the same through the register page with `LD (nn),HL`.
- **AUTO:** a read with AUTO set returns the last byte and starts an `0xFF` exchange; with AUTO clear it starts nothing; the same through the register page.
- **Ports:** SDDATA answers at `0x5B` with every high byte, at `0x5B00` and at register page offset `0x005B`.
- **Pacing:** `INIR` and unrolled `INI` at 20 MHz (and 25 MHz, if tried) with CLKDIV = 2 read a 512-byte block correctly; an access while BUSY is ignored (shown at CLKDIV = 125).
- **DMA:** SDCOUNT = 512 and a port 0 job read a block and stop before the CRC bytes; a write to SDCOUNT0 alone starts nothing; a write to SDCOUNT1 starts a run with both bytes as written; reading SDCOUNT counts down; a job to port 0 writes a block.
- **Start-up:** the full sequence for SDSC and SDHC models; no card gives no answer to CMD0, not a hang.
- **Real cards:** several brands and sizes at 400 kHz, 12.5 MHz and 25 MHz; write and read back a test area; measure read speed by DMA and by `INIR` at each CPU speed.

## 10. Open points

| # | Item |
|---|------|
| SD1 | Is 25 MHz reliable on the KS3's wiring with all cards? Fall back to 12.5 MHz (CLKDIV = 4) if not (retro68k's SD1) |
| SD2 | Deferred: high-speed cards (CMD6) could use a faster SPI clock (retro68k's SD2); needs a CLKDIV below 2 and a new timing rule for the Z80 |
| SD3 | Closed: `sd_miso` is at L1 in retro68k's KS3 pin file |
| SD4 | What `sd_cs1` is for on the board, and whether to support it beyond driving the pin (retro68k's SD3) |
| SD5 | Closed: no transmit buffer and no CPU wait (branch 11). At 25 MHz the Z80 cannot outrun an exchange (section 4) |
| SD6 | Card power is always on, so a stuck card can only be reset with CMD0 (as in retro68k) |
| SD7 | Closed: SDCON keeps retro68k's layout (branch 11): control bits in the low byte, CLKDIV in the high byte. Each byte acts when written (direct writes, design plan branch 11), so a control change is one write to SDCON0 |
| SD8 | Closed: retro68k has written its version-1 byte master (EN, CS0, CS1, CLKDIV; SDDATA with BUSY; SDCOUNT for DMA port 0); this spec follows it. AUTO is the only addition, offered to retro68k only if it ever wants CPU block reads |
