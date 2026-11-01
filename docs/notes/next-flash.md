# The Next's flash, cores and Pi header (Artix-7 boards)

Findings for the KS2 (issue 4, XC7A15T-1) and KS3 (issue 5, XC7A35T-2), read from the Next's own sources on 1 November 2026. Shared with retro68k (its SY5) and retro-spectrum (its O2). Not yet tried on the board.

Sources:

- `R/` = the Next's FPGA repository, [gitlab.com/SpectrumNext/ZX_Spectrum_Next_FPGA](https://gitlab.com/SpectrumNext/ZX_Spectrum_Next_FPGA/-/tree/master/cores/zxnext), `cores/zxnext/` (master at `b047011`, 6 November 2025).
- `T/` = the System/Next distribution, [gitlab.com/thesmog358/tbblue](https://gitlab.com/thesmog358/tbblue) (`5cd10da`, 28 September 2026). Its firmware source is older than its released `TBBLUE.FW` binary (see section 3).
- Xilinx package files for the [xc7a15tcsg324](https://www.xilinx.com/content/dam/xilinx/support/packagefiles/a7packages/xc7a15tcsg324pkg.txt) and [xc7a35tcsg324](https://www.xilinx.com/content/dam/xilinx/support/packagefiles/a7packages/xc7a35tcsg324pkg.txt).

## 1. The flash

| Item | Value | Source |
|------|-------|--------|
| Part | Macronix **MX25L25645G**, 256 Mbit (32 MB), 4-byte addresses, on both issue 4 and issue 5 | `R/nextreg.txt`, nextreg `0x0F` |
| Pins (both issues) | `flash_cs_n_o` L13 (FCS_B), `flash_mosi_o` K17 (D00), `flash_miso_i` K18 (D01, pulled up), `flash_wp_o` L14 (D02), `flash_hold_o` M14 (D03), **`flash_sclk_o` D9** | `R/src/zxnext_pins_issue4.xdc`, `…issue5.xdc` |
| Flash clock | D9 is an ordinary user pin (bank 16); the dedicated CCLK is E9. The board wires the flash clock to both, so a design drives it on D9 as a plain output: **no STARTUPE2 needed**. Inferred from the xdc and package file; the schematic was not checked | Package files |
| How the Next writes it | Its ordinary SPI master, 1 bit wide. WP held low, HOLD high. Erase: write enable, then `0x5C` (32 KB block, 4-byte address), poll status `0x05` bit 0. Program: write enable, then `0x12` (256-byte page). Read: `0x13` | `R/src/zxnext_top_issue4.vhd` (~1898–1913), `T/src/firmware/app/src/flashw.c` |
| Configuration settings | SPIx4, 32-bit addresses, falling edge, CONFIGRATE 40, CONFIGFALLBACK and NEXT_CONFIG_REBOOT disabled (as our `ks2.xdc`) | `R/src/zxnext_pins_issue4.xdc` |

## 2. Slots

| Item | Value | Source |
|------|-------|--------|
| Slot size | **`0x220000`** bytes (2,176 KB = 34 × 64 KB). Slot n starts at n × `0x220000` | `R/src/misc/flashboot_256.vhd` |
| Number | **15 slots, 0–14** (core ID 15 is refused in hardware) | `R/src/zxnext.vhd` (~5691), `T/…/flash.c` |
| Slot 0 | The anti-brick core; the firmware refuses to flash it | `T/…/flashw.c` |
| Slot 1 | The Next core | `R/mcsmaker/makemcs-4.cmd` |
| Slots 2–7 | Reserved (`RESERVED_SLOTS 8`) | `T/…/cores.c` |
| **Slots 8–14** | **Extra (third-party) cores**: slot 8 at `0x1100000`, slot 9 at `0x1320000`, … slot 14 at `0x1DC0000` | Derived |

Addresses above 16 MB need **25 address bits**.

## 3. Installing a core

- Put it on the SD card as `/machines/<dir>/core2.bit` (issue 4) or `core3.bit` (issue 5), with an optional `core.cfg` (`name=…`). Holding C at a hard reset opens the Extra Cores menu, which writes it into a slot. `.CORE` starts a core from NextBASIC. Per-board names came in `TBBLUE.FW` 1.44db ([hoglet67's commit](https://gitlab.com/hoglet67/tbblue/-/commit/53d6d97f09638d9f985af64bc2216e8d33e5631f), 15 December 2023). (`T/docs/extracores/extracoresinstructions.txt`, the strings in `T/TBBLUE.FW`.)
- The firmware writes **the whole `.bit` file, header included**, at the start of the slot, and reads the header back to name the slot in its menu. The header must be a standard Vivado one (fields `a` name ≤ 80 bytes, `b`, `c` date of 11 bytes, `d` time of 9 bytes). A `.bin` is not recognised. The FPGA itself skips the header while looking for the sync word.
- A core must be at most 2,176 KB. The Next's own image is uncompressed: 2,192,012 bytes. No source forbids compressed bitstreams, but every example is uncompressed.
- Which slot the menu chooses, and whether the user can pick it, is not yet checked.

## 4. Starting a core

- The Next uses **ICAPE2** (32 bits wide, clock under 20 MHz). It sends: `FFFFFFFF`, `AA995566` (sync), `20000000` (NOP), `30020001` (write WBSTAR), the address word, `30008001` (write CMD), `0000000F` (IPROG), then NOPs. Each byte is bit-reversed on its way into ICAPE2. (`R/src/misc/flashboot_256.vhd`.)
- **WBSTAR[23:0] = byte address >> 8** in 32-bit SPI mode (UG470, table 7-2). RS bits 0.
- At power-on the FPGA loads slot 0 (anti-brick), which starts slot 1 (the Next). A hard reset in the Next restarts core 1; nextreg `0x10` bit 7 restarts the chosen core.
- With fallback disabled, a slot that does not configure presumably leaves the FPGA blank until a power-cycle (not checked).

## 5. The Pi header

- **`accel_io[n]` is Pi GPIO n (BCM numbering).** The Next's top level passes `accel_io(27:0)` straight to its GPIO, and its peripherals sit on the Pi's own function pins: UART on GPIO 14/15 with RTS/CTS on 16/17, I2C1 on 2/3, SPI0 on 7–11, I2S on 18–21. (`R/src/zxnext_top_issue4.vhd` ~2114–2153, `R/src/zxnext.vhd` ~2301–2356.) Confirmed on the KS2's issue 4 schematic (header J2, through 200 ohm resistors, no level shifting; spec 10, open point U2).
- The Next's Pi UART: nextreg `0xA0` bit 5 enables it, bit 4 = 1 is "Rx on GPIO 14, Tx on GPIO 15" (for a Pi). NextPi uses 115,200 baud.
- **No sign of the Pi header reaching JTAG, PROGRAM_B (P9) or DONE (P10).** The reset button is a user input (V9). Not confirmed without the schematic.

## 6. Pi Zero 2 W notes

- The Pi's PL011 UART is on GPIO 14/15 only with Bluetooth moved off it (`dtoverlay=disable-bt`); the mini UART's rate follows the core clock and is no use here.
- PL011's default clock (48 MHz) makes **3 Mbaud exactly**; `init_uart_clock` can raise it for 4 Mbaud.
- At power-on the Pi pulls **GPIO 0–8 up and GPIO 9–27 down**. A pin that means something when low (the rescue pin) must be one of GPIO 2–8, or a Pi that is still booting looks like a request. GPIO 0–1 are the HAT ID EEPROM pins.
