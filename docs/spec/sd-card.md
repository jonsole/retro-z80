# Spec 11: SD card

Status: **draft**

The SD card is the computer's storage. The KS3's SD slot is wired for **SPI mode** only. The FPGA has a plain **SPI byte master**: software writes a byte, the controller clocks it out while clocking a byte in, and software reads the result. Software does everything else: the card start-up, commands and their CRCs, data tokens, busy waiting and the file system (FAT). The controller has no interrupt; software polls it. Its ports are `0x2C`–`0x2F`.

## 1. Summary

| Item | Value |
|------|-------|
| Slot | The KS3's SD slot: `sd_sclk`, `sd_mosi`, `sd_miso`, `sd_cs0` (the slot), `sd_cs1` (wired, use unknown) |
| Cards | SD, SDHC and SDXC at 3.3 V, in SPI mode |
| SPI | Mode 0 (clock idles low, data sampled on the rising edge), most significant bit first |
| SPI clock | 56 MHz ÷ (2 × (SDDIV + 1)): 400 kHz for start-up (SDDIV = 69), 14 MHz for data (SDDIV = 1) |
| Transfer | One byte each way per exchange; an exchange takes 16 × (SDDIV + 1) system clocks plus 2 |
| Block reads | `INIR` on the data port, with AUTO set: each read starts the next exchange |
| Block writes | `OTIR` on the data port |
| Interrupt | None; software polls SDSTAT.BUSY or keeps to the timing rule (section 4) |
| Card detect | None on the KS3 (as in retro68k spec 15, section 5) |
| Ports | `0x2C`–`0x2F` (4 ports) |
| Memory cycles | None |

## 2. How an exchange works

- **Writing SDDATA** starts an exchange: the byte written goes out on MOSI, most significant bit first, while 8 bits are clocked in from MISO. SDSTAT.BUSY is 1 until the exchange ends.
- **Reading SDDATA** returns the byte received by the last exchange. With **SDCTL.AUTO = 1**, the read also starts a new exchange that sends `0xFF`, so the next byte is on its way while software stores this one. With AUTO = 0 a read starts nothing.
- A write to SDDATA, or an AUTO read, while BUSY is 1 is ignored: no exchange starts and the byte is lost. Software must wait for BUSY = 0 or keep to the timing rule in section 4.
- Between exchanges the clock stays low and MOSI stays high (`1`), which is what a card expects when idle.
- **Chip select:** SDCTL.CS0 and SDCTL.CS1 drive `sd_cs0` and `sd_cs1` directly (1 = selected, pin low). Software selects the card before a command and releases it afterwards, then sends one more `0xFF` byte with the card released, as SD cards in SPI mode expect.

## 3. Clock

SCLK = 56 MHz ÷ (2 × (SDDIV + 1)).

| SDDIV | SCLK | Exchange time | Use |
|-------|------|---------------|-----|
| 69 | 400 kHz | 20.0 µs | Start-up (cards need 100–400 kHz until ready); value after reset |
| 3 | 7 MHz | 1.18 µs | Safe fallback if 14 MHz proves unreliable |
| 1 | 14 MHz | 0.61 µs | Normal data transfers |
| 0 | 28 MHz | 0.32 µs | Above the 25 MHz default-speed limit of SD cards; only after switching the card to high speed (open point SD2) |

A change of SDDIV takes effect at the next exchange. Changing it during an exchange is not allowed (the result is undefined).

## 4. Timing rule for block I/O

The controller never makes the CPU wait, so a block instruction must not come back to SDDATA before the exchange it started has ended. An exchange takes 16 × (SDDIV + 1) + 2 system clocks; one Z80 T-state is 2, 4, 8 or 16 system clocks (28, 14, 7, 3.5 MHz).

| Method | Time between I/O accesses | At 28 MHz, SDDIV = 1 (needs 34 clocks) |
|--------|---------------------------|----------------------------------------|
| `INIR` / `OTIR` | 21 T-states = 42 clocks | Safe |
| Unrolled `INI` / `OUTI` | 16 T-states = 32 clocks | **Too fast**: use SDDIV = 0 only with a high-speed card, or poll BUSY |

At 14 MHz and slower the CPU is always slow enough for `INIR` and `OTIR` with SDDIV ≥ 1. At 400 kHz, software must poll BUSY (or use a delay) between bytes.

**Block read speed:** with `INIR` at 28 MHz and SCLK = 14 MHz, 512 bytes take 512 × 750 ns = 384 µs, about 1.3 MB/s, plus the command and the wait for the start token. Loading a 48 KB file takes about 40 ms plus FAT work.

## 5. Typical sequences

**Reading a 512-byte block** (SDHC: the argument is the block number):

```
        ld   a,0x01          ; CS0, AUTO off
        out  (0x2D),a
        ; send CMD17: 6 bytes (0x51, 4 argument bytes, CRC or 0xFF), polling BUSY
        ; read the R1 response: send 0xFF until a byte with bit 7 = 0 (up to 8 tries)
        ; wait for the start token: send 0xFF until 0xFE (timeout ~100 ms, use timer 1)
        ld   a,0x05          ; CS0, AUTO on
        out  (0x2D),a
        in   a,(0x2C)        ; discard the 0xFE; starts the exchange for data byte 0
        ld   hl,buffer
        ld   bc,0x002C       ; B = 0: 256 bytes, C = SDDATA
        inir                 ; bytes 0-255 (each read starts the next exchange)
        inir                 ; bytes 256-511
        in   a,(0x2C)        ; CRC high byte
        in   a,(0x2C)        ; CRC low byte (and one spare exchange)
        ld   a,0x00          ; release the card, AUTO off
        out  (0x2D),a
        ld   a,0xFF
        out  (0x2C),a        ; 8 clocks with the card released
```

The first read after setting AUTO returns the byte of the last exchange (the token) and starts the exchange for data byte 0; each `INIR` read then returns one data byte and starts the next.

**Writing a block:** select, send CMD24, read R1, send `0xFF`, then the start token `0xFE`, 512 bytes with two `OTIR`s, two CRC bytes (any value unless CRC checking is on), read the data-response token (`xxx00101` = accepted), then send `0xFF` until the card stops answering `0x00` (busy), with a timeout.

**Start-up** (the standard SPI-mode sequence, done by the boot ROM):

1. SDDIV = 69 (400 kHz), card released; send 10 bytes of `0xFF` (80 clocks; cards need at least 74).
2. Select; CMD0 (CRC `0x95`): expect R1 = `0x01`. No answer means no card, or a card that does not work.
3. CMD8 with `0x000001AA` (CRC `0x87`): new cards echo `0x1AA`; SDv1 cards reply "illegal command".
4. CMD55 + ACMD41 (bit 30 set for SDHC/SDXC) until R1 = `0x00`, with a timeout of about 1 s.
5. CMD58: OCR bit 30 (CCS) set = SDHC/SDXC (block addresses); clear = SDSC (byte addresses; also send CMD16 with 512).
6. SDDIV = 1 (14 MHz).

Commands sent after CMD8 need no correct CRC unless CRC checking is turned on with CMD59; software computes CRC7 only if it wants that.

## 6. No card detect

As on retro68k: the KS3 has no card-detect switch, and in SPI mode the card's DAT3 is its select line. Software finds the card by talking to it: CMD0 with no answer means no card; commands timing out mean it was removed; reading the CID (CMD10) after start-up tells a swapped card from the same one.

## 7. Registers

| Port | Name | Bits | Description |
|------|------|------|-------------|
| `0x2C` | SDDATA | 7–0 | Write: send this byte (starts an exchange). Read: the byte received by the last exchange; with AUTO = 1 the read also starts an exchange sending `0xFF` |
| `0x2D` | SDCTL | CS0 (0), CS1 (1), AUTO (2) | 1 = drive `sd_cs0` / `sd_cs1` low (card selected); reads start exchanges. Bits 7–3 read 0 |
| `0x2E` | SDDIV | 7–0 | SCLK = 56 MHz ÷ (2 × (SDDIV + 1)). 69 after reset (400 kHz) |
| `0x2F` | SDSTAT | BUSY (0), MISO (1) | Read only: an exchange is running; the present level of `sd_miso` (for debugging). Bits 7–2 read 0 |

**After reset:** both selects released, AUTO off, SDDIV = 69, no exchange running, SDDATA reads `0xFF`.

## 8. FPGA resources

| Item | Resource |
|------|----------|
| Shift register, bit counter, clock divider, registers | Estimate 40–60 LUTs |
| Block RAM, DSP | None |
| Pins | 5: `sd_sclk` (M1), `sd_mosi` (M2), `sd_cs0` (N1), `sd_cs1` (K2), `sd_miso` (location to be confirmed, open point SD3) |
| Request lines | None |

## 9. Test plan

- **Simulation:** against an SPI-mode SD card model (retro68k's, if it has one, or a new one): bit order, mode 0 timing, every SDDIV from 0 to 255 gives the right clock; BUSY covers the whole exchange.
- **AUTO:** a read with AUTO set returns the last byte and starts an `0xFF` exchange; with AUTO clear it starts nothing.
- **Pacing:** `INIR` at 28 MHz with SDDIV = 1 reads a 512-byte block correctly; an access while BUSY is ignored (shown with unrolled `INI`).
- **Start-up:** the full sequence for SDSC and SDHC models; no card gives no answer to CMD0, not a hang.
- **Real cards:** several brands and sizes at 400 kHz, 7 MHz and 14 MHz; write and read back a test area; measure read speed at each CPU speed.

## 10. Open points

| # | Item |
|---|------|
| SD1 | Is 14 MHz reliable on the KS3's wiring with all cards? Fall back to 7 MHz (SDDIV = 3) if not |
| SD2 | High-speed cards (CMD6) could use 28 MHz (SDDIV = 0), which would also allow unrolled `INI` at 28 MHz |
| SD3 | `sd_miso` is not in retro68k's pin file yet (unused there); take its location from the Next's `zxnext_pins_issue5.xdc` |
| SD4 | What `sd_cs1` is for on the board, and whether to support it beyond driving the pin |
| SD5 | A one-byte transmit buffer (so `OUTI` runs at full speed) or a CPU wait while BUSY; left out to keep the controller minimal and the CPU free of waits |
| SD6 | Card power is always on, so a stuck card can only be reset with CMD0 (as in retro68k) |
