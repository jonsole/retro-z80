# Spec 11: SD card

Status: **draft**

The SD card is the computer's storage. The KS3's SD slot is wired for **SPI mode** only. As retro68k decided for its version 1 (its design plan, spec 15), the FPGA has a plain **SPI byte master**: software writes a byte, the controller clocks it out while clocking a byte in, and software reads the result. Software does everything else: the card start-up, commands and their CRCs, data tokens, busy waiting and the file system (FAT). The controller has no interrupt; software polls it.

The registers use retro68k's names and bit positions (SDCON with CLKDIV, SDSTAT, SDDATA), cut to bytes. Its ports are `0x58`–`0x5F` in the system block (spec 3).

## 1. Summary

| Item | Value |
|------|-------|
| Slot | The KS3's SD slot: `sd_sclk`, `sd_mosi`, `sd_miso`, `sd_cs0` (the slot), `sd_cs1` (wired, use unknown) |
| Cards | SD, SDHC and SDXC at 3.3 V, in SPI mode |
| SPI | Mode 0 (clock idles low, data sampled on the rising edge), most significant bit first |
| SPI clock | 56 MHz ÷ (2 × CLKDIV): 400 kHz for start-up (CLKDIV = 70), 14 MHz for data (CLKDIV = 2) |
| Transfer | One byte each way per exchange; an exchange takes 16 × CLKDIV + 2 system clocks |
| Block reads | `INIR` on SDDATA, with SDCON.AUTO set: each read starts the next exchange |
| Block writes | `OTIR` on SDDATA |
| Interrupt | None; source SD is not used in version 1 (spec 8), as in retro68k version 1 |
| Card detect | None on the KS3 (section 7) |
| Ports | `0x58`–`0x5B` used; `0x5C`–`0x5F` reserved (8 ports) |
| Memory cycles | None |

## 2. Comparison with retro68k

retro68k's spec 15 still describes a full SPI-mode host controller (commands, responses, a 2 KB FIFO, DMA port 0, an interrupt). Its design plan, interrupt spec and DMA spec settle version 1 as a plain SPI byte master that software polls, and leave the registers to be written. This spec is that version 1, with spec 15's names and bit positions where the thing is the same.

| retro68k | retro-z80 | Why |
|----------|-----------|-----|
| 32-bit registers at `0xF00300` | 8-bit ports `0x58`–`0x5F`, in spec 15's order (SDCON, SDSTAT, SDDATA) | Z80 (8-bit ports) |
| SDCON: EN (0), CS (1), CLKDIV (15–8) | The same bits: SDCON at `0x58` (bits 7–0), CLKDIV at `0x59` (bits 15–8) | – |
| SCLK = 100 MHz ÷ (2 × CLKDIV) | SCLK = 56 MHz ÷ (2 × CLKDIV) | System clock |
| SDCON: INITCLK (2), CRCCHK (3), AUTOSTOP (4) | Reserved, read 0: software sends the start-up clocks, checks CRCs and stops transfers itself | Version 1 is a byte master (retro68k's decision) |
| The controller drives the select line for each command | SDCON.SEL (5): software selects and releases the card | Byte master: software runs the commands |
| — | SDCON.AUTO (6): a read of SDDATA starts the next `0xFF` exchange | Lets `INIR` read a block (section 4) |
| SDARG, SDCMD, SDRESP0–3, SDBLKCNT, SDIRQ, SDIRQEN, SDTIMEOUT | Left out | Byte master: software does commands and blocks |
| SDSTAT: CMDBUSY (0), DATABUSY (1), CARDBUSY (2), INITBUSY (3), FIFOCOUNT | BUSY (0) an exchange is running; CARDBUSY (2) as retro68k (MISO is low). Bits 1 and 3 reserved | Byte master |
| SDDATA: a 2 KB FIFO, 4 bytes a read | One byte: the last byte received | Byte master |
| DMA engine port 0 | No DMA | The DMA engine works on SRAM only (spec 14) |
| Source SD (16): unused in version 1 | Source SD reserved (spec 8 numbers it) | As retro68k |

## 3. How an exchange works

- **Writing SDDATA** starts an exchange: the byte written goes out on MOSI, most significant bit first, while 8 bits are clocked in from MISO. SDSTAT.BUSY is 1 until the exchange ends.
- **Reading SDDATA** returns the byte received by the last exchange. With **SDCON.AUTO = 1** the read also starts a new exchange that sends `0xFF`, so the next byte is on its way while software stores this one. With AUTO = 0 a read starts nothing.
- A write to SDDATA, or an AUTO read, while BUSY is 1 is ignored: no exchange starts and the byte is lost. Software waits for BUSY = 0 or keeps to the timing rule in section 4.
- Between exchanges the clock stays low and MOSI stays high, which is what a card expects when idle.
- **Chip select:** SDCON.CS chooses the select line (0 = `sd_cs0`, the slot; 1 = `sd_cs1`), as in retro68k. SDCON.SEL = 1 drives that line low (card selected); the other line stays high. Software selects the card before a command, releases it afterwards, then sends one more `0xFF` byte with the card released, as SD cards in SPI mode expect.
- **SDCON.EN = 0:** no exchanges, both select lines high, SCLK low, writes to SDDATA ignored. Exchanges run whenever EN = 1, with the card selected or not, so the start-up clocks are ordinary `0xFF` exchanges with SEL = 0.

### 3.1 Writing SDCON

SDCON is a 2-byte register (spec 3, multi-byte rule): writing `0x58` only fills a latch, and writing `0x59` (CLKDIV) commits both bytes. So every change of SEL, AUTO, CS or EN is two writes, control byte first:

```
        ld   a,SDCON_EN|SDCON_SEL      ; select the card, AUTO off
        out  (SDCON),a
        ld   a,SD_FAST                 ; CLKDIV = 2 (14 MHz)
        out  (SDCON+1),a               ; commits
```

Through the register page, `LD (SDCON),HL` with L = the control bits and H = CLKDIV does it in one instruction (spec 2, section 6.5). A change of CLKDIV takes effect at the next exchange; changing it during an exchange is not allowed (the result is undefined).

## 4. Clock and the timing rule for block I/O

SCLK = 56 MHz ÷ (2 × CLKDIV). CLKDIV = 0 acts as 1.

| CLKDIV | SCLK | Exchange time | Use |
|--------|------|---------------|-----|
| 70 | 400 kHz | 20.0 µs | Start-up (cards need 100–400 kHz until ready); value after reset |
| 4 | 7 MHz | 1.18 µs | Safe fallback if 14 MHz proves unreliable |
| 2 | 14 MHz | 0.61 µs | Normal data transfers |
| 1 | 28 MHz | 0.32 µs | Above the 25 MHz default-speed limit of SD cards; only after switching the card to high speed (open point SD2) |

The controller never makes the CPU wait, so a block instruction must not come back to SDDATA before the exchange it started has ended. An exchange takes 16 × CLKDIV + 2 system clocks; one Z80 T-state is 2, 4, 8 or 16 system clocks (28, 14, 7, 3.5 MHz).

| Method | Time between I/O accesses | At 28 MHz, CLKDIV = 2 (needs 34 clocks) |
|--------|---------------------------|-----------------------------------------|
| `INIR` / `OTIR` | 21 T-states = 42 clocks | Safe |
| Unrolled `INI` / `OUTI` | 16 T-states = 32 clocks | **Too fast**: use CLKDIV = 1 only with a high-speed card, or poll BUSY |

At 14 MHz and slower the CPU is always slow enough for `INIR` and `OTIR` with CLKDIV ≥ 2. At 400 kHz, software polls BUSY (or waits) between bytes.

**Block read speed:** with `INIR` at 28 MHz and SCLK = 14 MHz, 512 bytes take 512 × 750 ns = 384 µs, about 1.3 MB/s, plus the command and the wait for the start token. Loading a 48 KB file takes about 40 ms plus FAT work.

## 5. Typical sequences

**Reading a 512-byte block** (SDHC: the argument is the block number):

```
        ld   a,SDCON_EN|SDCON_SEL      ; select, AUTO off
        out  (SDCON),a
        ld   a,2
        out  (SDCON+1),a
        ; send CMD17: 6 bytes (0x51, 4 argument bytes, CRC or 0xFF), polling BUSY
        ; read the R1 response: send 0xFF until a byte with bit 7 = 0 (up to 8 tries)
        ; wait for the start token: send 0xFF until 0xFE (timeout ~100 ms, with a timer)
        ld   a,SDCON_EN|SDCON_SEL|SDCON_AUTO
        out  (SDCON),a
        ld   a,2
        out  (SDCON+1),a
        in   a,(SDDATA)                ; discard the 0xFE; starts the exchange for data byte 0
        ld   hl,buffer
        ld   bc,0x0000|SDDATA          ; B = 0: 256 bytes, C = SDDATA
        inir                           ; bytes 0-255 (each read starts the next exchange)
        inir                           ; bytes 256-511
        in   a,(SDDATA)                ; CRC high byte
        in   a,(SDDATA)                ; CRC low byte (and one spare exchange)
        ld   a,SDCON_EN                ; release the card, AUTO off
        out  (SDCON),a
        ld   a,2
        out  (SDCON+1),a
        ld   a,0xFF
        out  (SDDATA),a                ; 8 clocks with the card released
```

The first read after setting AUTO returns the byte of the last exchange (the token) and starts the exchange for data byte 0; each `INIR` read then returns one data byte and starts the next. SDDATA is a system port, decoded on A7–A0 only, so the falling count in B does not matter (spec 1, section 6).

**Writing a block:** select, send CMD24, read R1, send `0xFF`, then the start token `0xFE`, 512 bytes with two `OTIR`s, two CRC bytes (any value unless CRC checking is on), read the data-response token (`xxx00101` = accepted), then send `0xFF` until the card stops answering `0x00` (busy; SDSTAT.CARDBUSY shows MISO low), with a timeout.

**Start-up** (the standard SPI-mode sequence, as in retro68k spec 15, section 4; done by the boot ROM):

1. EN = 1, SEL = 0, CLKDIV = 70 (400 kHz); send 10 bytes of `0xFF` (80 clocks; cards need at least 74 with the card released).
2. Select; CMD0 (CRC `0x95`): expect R1 = `0x01`. No answer means no card, or a card that does not work.
3. CMD8 with `0x000001AA` (CRC `0x87`): new cards echo `0x1AA`; SDv1 cards reply "illegal command".
4. CMD55 + ACMD41 (bit 30 set for SDHC/SDXC) until R1 = `0x00`, with a timeout of about 1 s.
5. CMD58: OCR bit 30 (CCS) set = SDHC/SDXC (block addresses); clear = SDSC (byte addresses; also send CMD16 with 512).
6. CLKDIV = 2 (14 MHz).

Commands sent after CMD8 need no correct CRC unless CRC checking is turned on with CMD59; software computes CRC7 and CRC16 only if it wants that.

## 6. Registers

| Port | Name | Access | Bits | Description | Reset |
|------|------|--------|------|-------------|-------|
| `0x58` | SDCON | RW | EN (0), CS (1), SEL (5), AUTO (6) | Controller on; which select line (0 = `sd_cs0`, 1 = `sd_cs1`); drive that line low (card selected); reads of SDDATA start an `0xFF` exchange. Bits 2–4 (retro68k's INITCLK, CRCCHK, AUTOSTOP) and 7 reserved, read 0. Latched: committed by writing `0x59` | `0x00` |
| `0x59` | SDCON+1 | RW | CLKDIV (7–0), SDCON bits 15–8 | SCLK = 56 MHz ÷ (2 × CLKDIV); 0 acts as 1. Writing it commits SDCON | 70 |
| `0x5A` | SDSTAT | R | BUSY (0), CARDBUSY (2) | An exchange is running; MISO is low now (the card is busy, or sending a 0 bit). Bits 1, 3 (retro68k's DATABUSY, INITBUSY) and 7–4 read 0 | `0x00` |
| `0x5B` | SDDATA | RW | 7–0 | Write: send this byte (starts an exchange). Read: the byte received by the last exchange; with AUTO = 1 the read also starts an exchange sending `0xFF` | `0xFF` |
| `0x5C`–`0x5F` | – | – | – | Reserved: read `0xFF`, writes ignored (spec 3) | – |

- SDDATA is one of the system block's data ports where reading can have an effect (with AUTO set), through a port or through the register page (spec 3).
- All ports also appear in the register page at offset = port (spec 2, section 6.5).
- **After reset:** controller off, both selects released, AUTO off, CLKDIV = 70, no exchange running, SDDATA reads `0xFF`.

## 7. No card detect

As on retro68k (its spec 15, section 5): the KS3 has no card-detect switch, and in SPI mode the card's DAT3 is its select line. Software finds the card by talking to it: CMD0 with no answer means no card; commands timing out mean it was removed; reading the CID (CMD10) after start-up tells a swapped card from the same one.

## 8. FPGA resources

| Item | Resource |
|------|----------|
| Shift register, bit counter, clock divider, registers | Estimate 40–60 LUTs |
| Block RAM, DSP | None |
| Pins | 5: `sd_sclk` (M1), `sd_mosi` (M2), `sd_cs0` (N1), `sd_cs1` (K2), `sd_miso` (location to be confirmed, open point SD3) |
| Request lines | None |

## 9. Test plan

- **Simulation:** against an SPI-mode SD card model (retro68k's, if it has one by then, or a new one shared with it): bit order, mode 0 timing; every CLKDIV from 0 to 255 gives the right clock; BUSY covers the whole exchange.
- **SDCON:** a write to `0x58` alone changes nothing; the write to `0x59` commits both; SEL drives only the line CS picks; EN = 0 stops exchanges and releases both lines.
- **AUTO:** a read with AUTO set returns the last byte and starts an `0xFF` exchange; with AUTO clear it starts nothing; the same through the register page.
- **Pacing:** `INIR` at 28 MHz with CLKDIV = 2 reads a 512-byte block correctly; an access while BUSY is ignored (shown with unrolled `INI`).
- **CARDBUSY:** follows MISO, during the busy time after a block write.
- **Start-up:** the full sequence for SDSC and SDHC models; no card gives no answer to CMD0, not a hang.
- **Real cards:** several brands and sizes at 400 kHz, 7 MHz and 14 MHz; write and read back a test area; measure read speed at each CPU speed.

## 10. Open points

| # | Item |
|---|------|
| SD1 | Is 14 MHz reliable on the KS3's wiring with all cards? Fall back to 7 MHz (CLKDIV = 4) if not |
| SD2 | High-speed cards (CMD6) could use 28 MHz (CLKDIV = 1), which would also allow unrolled `INI` at 28 MHz |
| SD3 | `sd_miso` is not in retro68k's pin file yet; take its location from the Next's `zxnext_pins_issue5.xdc` |
| SD4 | What `sd_cs1` is for on the board, and whether to support it beyond driving the pin (retro68k's SD3) |
| SD5 | A one-byte transmit buffer (so `OUTI` runs at full speed) or a CPU wait while BUSY; left out to keep the controller minimal and the CPU free of waits |
| SD6 | Card power is always on, so a stuck card can only be reset with CMD0 (as in retro68k) |
| SD7 | SDCON's commit rule makes every SEL or AUTO change two writes (section 3.1). The alternative is to put CLKDIV in the low byte and the control bits in the high byte, so one write to the high byte changes them; that moves retro68k's bit positions. Kept as retro68k for now |
| SD8 | retro68k has not yet written its version-1 byte master's registers. When it does, the two should match; this layout (SDCON EN, CS, SEL, AUTO, CLKDIV; SDSTAT BUSY, CARDBUSY; SDDATA) is offered to it |
