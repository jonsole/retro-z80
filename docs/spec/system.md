# Spec 7: System: reset, boot ROM and start-up

Status: **draft**

This spec covers how the computer starts: what resets it and what a reset does, the boot ROM and its NMI monitor page, what the boot ROM does first, the board's buttons, how start-up progress is shown, how the design is installed on the ZX Spectrum Next KS3, the system ports `0x00`–`0x07` and the NMI monitor ports `0xB9`–`0xBD`. It ends with the board connections and the beeper's path to the audio pins.

The other system pieces have their own specs: the MMU (spec 2), interrupts (8), timers (9), USB serial (10), SD card (11) and keyboards and joysticks (12).

## 1. Summary

| Item | Value |
|------|-------|
| Board | ZX Spectrum Next KS3: Artix-7 XC7A35T, 4 MB (or 2 MB) SRAM (design plan D1) |
| Reset sources | Power-on, reset button, software (SYSRESET), USB serial RESET and UPLOAD |
| What survives a reset | SRAM contents (except at power-on), boot ROM contents, the USB link |
| Boot ROM | 32 KB of block RAM, loaded with the bitstream, seen through MMU pages `0x3FC`–`0x3FF`; can be made writable for development |
| After reset | Z80 at 28 MHz, starting at `0x0000` in boot ROM page 0 (MMU windows 0–1 = ROM pages 0–1, windows 2–7 = SRAM pages 0–5) |
| Start-up | A few microseconds from the end of FPGA configuration to the first instruction |
| Start-up progress | The screen's background colour and the USB serial console, as in retro68k. The board has no user LEDs |
| Start-up options | Keys held during reset, and the DivMMC button |
| Buttons | Reset = reset; Multiface = NMI; DivMMC = "monitor" button, readable in SYSBTN |
| NMI monitor | Taking an NMI pages boot ROM page `0x3FF` into window 0 (write page NONE); `RETN` restores the saved pages. NMICTL `0xB9`, saved pages `0xBA`–`0xBD` (section 4.4) |
| Audio | Version 1: the 1-bit beeper (port `0xFE` bit 4, spec 12), through sigma-delta modulators to the jack (both channels) and the internal speaker (section 9.1) |
| Ports | `0x00`–`0x07`: ID, version, CPU speed, reset cause, configuration, control, soft reset, buttons. `0xB9`–`0xBD`: NMI monitor |
| Installing | Development: JTAG straight into the FPGA. Everyday use: an extra Next core in a free flash slot |

## 2. Reset

### 2.1 Reset sources

| Source | How | RESETWHY bit |
|--------|-----|--------------|
| Power-on | The FPGA finishes loading the design and the clocks lock | POWER (0) |
| Reset button | The KS3's reset button, debounced (10 ms) | BUTTON (1) |
| Software | Writing `0xA5` to SYSRESET | SOFTWARE (2) |
| USB RESET | Control command from the PC (spec 10) | USB (3) |
| USB UPLOAD | Control command from the PC: reset, then wait for a program | UPLOAD (4) |

RESETWHY shows the cause of the last reset; exactly one bit is set. Ctrl + Alt + Delete is done by software, which watches for the keys and writes SYSRESET (as in retro68k). There is no watchdog in version 1 (open point SY3).

### 2.2 What a reset does

Every source gives the same **full reset**:

- The Z80 is reset and starts at `0x0000` (spec 1, section 9), at **28 MHz** (CPUSPEED = 3).
- The MMU goes back to its reset state (spec 2, section 6.4): boot ROM pages 0–1 in windows 0–1, SRAM pages 0–5 in windows 2–7, each window's write page the same as its read page. NMI mode ends (NMICTL.INNMI = 0) and automatic paging is on (NMICTL.EN = 1).
- Every chipset port goes back to its reset value: video shows only the background colour, sprites and copper stopped, interrupts off, timers stopped, serial and keyboard FIFOs empty.
- SYSCON.ROMWE is cleared. ROMLOCK is cleared only at power-on.
- **The SRAM keeps its contents.** Static RAM needs no refresh, so after anything except power-on, memory holds what it held before. A debugger can look at what a crashed program left, and software can keep data across resets.
- **The boot ROM keeps its contents,** including any changes made while it was writable (section 4.3). Only reloading the FPGA restores the original.
- **The USB serial link stays up.** Its FIFOs are cleared, but the FT232H and the PC's serial port are not disturbed, so a terminal stays connected.

### 2.3 Power-on sequence

1. The FPGA loads the design: from its Next core slot in the flash, or over JTAG during development (section 7).
2. MMCM 1 (56 MHz system clock) and MMCM 2 (pixel clocks) lock.
3. The system reset is released on slot clock 0 of a slot (spec 1, section 9), and the Z80 runs its first T1.

The SRAM needs no start-up, so steps 2 and 3 take a few microseconds. At every later reset only step 3 happens: reset is held for at least 16 clocks (one T-state at 3.5 MHz) and released on slot clock 0.

The Z80 has no RESET instruction, so software cannot reset the devices without resetting the CPU. A program that wants clean hardware writes the ports it uses, or does a soft reset.

## 3. Buttons

| Button | Effect |
|--------|--------|
| Reset | Full reset, RESETWHY.BUTTON (section 2) |
| Multiface | NMI, through the interrupt controller (spec 8): the Z80 calls `0x0066` in the monitor page (section 4.4). Readable in SYSBTN.MULTIFACE |
| DivMMC | No action of its own. Readable in SYSBTN.DIVMMC; the boot ROM uses it as the "monitor" button (section 6) |

All three are synchronised and debounced: a change must hold for 2^19 clocks (9.4 ms). As in retro68k's `top_ks3.v`.

## 4. Boot ROM

### 4.1 The ROM

- **32 KB of block RAM** (16 blocks of 18 Kb, design plan D11). Its contents are part of the FPGA bitstream: the build assembles the boot ROM with sjasmplus and puts it into the bitstream, so the ROM can change without re-running synthesis.
- The Z80 sees it as **4 MMU pages**, `0x3FC`–`0x3FF` (ROM offsets `0x0000`, `0x2000`, `0x4000`, `0x6000`), mapped into any window like SRAM pages (spec 2, section 6.3).
- Reading it costs no SRAM cycle and no wait states.
- The chipset cannot see it. The boot ROM copies the console font and anything else the chipset needs into SRAM.

### 4.2 Mapping at reset

At reset, windows 0 and 1 hold ROM pages 0 and 1, so the Z80 starts in the ROM at `0x0000`, and `0x0038` (IM 1) is in the ROM too. An NMI runs from ROM page 3, the monitor page, whatever window 0 holds (section 4.4). The ROM's code for pages 2 and 3 is reached by mapping them into a window, for example window 1. There is no overlay: once the ROM has set up SRAM, it can map SRAM into windows 0 and 1 and jump to it.

### 4.3 Writable boot ROM, for development

Rebuilding the FPGA takes minutes. To try new boot ROM code quickly:

- Setting **SYSCON.ROMWE** makes the boot ROM pages writable through any window whose write page is a ROM page.
- A program or the USB upload loader writes a new image through the ROM pages, then writes SYSRESET.
- The new ROM runs from the next reset onwards, until the FPGA is reloaded.
- **SYSCON.ROMLOCK** stops ROMWE being set again until the next power-on. The boot ROM sets it, unless the development key (D) is held during reset (section 6).

Running code from a ROM page while rewriting that page works but is unwise; the loader runs from SRAM.

### 4.4 The NMI monitor page

Like a Multiface, an NMI (Multiface button or USB BREAK, spec 8, section 9) brings up a monitor whatever the running program has done with the memory map.

**Entry.** When the Z80 takes an NMI, it first pushes PC through the program's own mapping. Then, just before the opcode fetch at `0x0066` reads memory, the bus interface (spec 1, section 8.2):

1. copies window 0's read page and write page into NMISAVL/H and NMISAVWL/H,
2. sets window 0's read page to `0x3FF` (boot ROM page 3, the **monitor page**) and its write page to NONE (`0x3FB`),
3. sets NMICTL.INNMI.

So the fetch at `0x0066` already comes from the monitor page. Windows 1–7 are not changed. While INNMI is 1, MMU0 and MMU0W read back `0x3FF` and `0x3FB`.

**Exit.** The monitor ends with `RETN` (`ED 45`). When the bus interface sees that instruction fetched in NMI mode, it puts the saved pages back in window 0 and clears INNMI, from the first memory access after the `0x45` byte. So the two stack reads of `RETN` and everything after it see the program's own window 0 again, even when the program's stack is in window 0. If the monitor wrote MMU0 or MMU0W meanwhile, the saved pages still win.

**With NMICTL.EN = 0** nothing is paged: the NMI runs whatever window 0 holds at `0x0066`, and `RETN` changes nothing, as on a plain Z80. EN is 1 after every reset. EN is read only at entry, so changing it inside the monitor does not stop the restore.

**Nested NMIs.** While INNMI is 1 the interrupt controller holds /NMI high (spec 8, section 9). Events still set their flags; a flag that is still set after `RETN` gives a new NMI straight away. So the monitor is never entered twice and the saved pages always belong to the interrupted program.

**Layout of the monitor page** (ROM offsets `0x6000`–`0x7FFF`, seen at `0x0000`–`0x1FFF` in window 0):

| Window 0 address | ROM offset | Contents |
|------------------|------------|----------|
| `0x0000`–`0x0065` | `0x6000`–`0x6065` | Reserved, filled with `0xFF`. The monitor runs with interrupts off (an NMI clears IFF1), so `0x0038` is never used here |
| `0x0066` | `0x6066` | NMI entry: the first instruction of the monitor |
| `0x0067`–`0x1FFF` | `0x6067`–`0x7FFF` | The monitor's code and tables. It runs from window 0 throughout; it reaches code in ROM pages 0–2 by mapping one into another window, after saving that window's pages |

Boot ROM page 0 also has a jump to the monitor at `0x0066`, for an NMI taken with EN = 0 while page 0 is in window 0.

**What the monitor does.** Its commands are in the boot ROM spec (open point SY2). Here, the parts that touch the hardware:

1. Save the registers on the interrupted program's stack (a few bytes, as any interrupt handler uses), then move to its own workspace: an SRAM page set aside by the boot ROM (open point SY7), mapped into a window after that window's own pages are saved.
2. Show the interrupted program's state: its registers and PC (from its stack), its window-0 pages (NMISAVL/H, NMISAVWL/H) and windows 1–7 (MMU1–MMU7 and MMU1W–MMU7W, unchanged). To show or edit the memory the program had in window 0, it maps the saved page into another window.
3. Clear the NMI flags in INTREQH (spec 8).
4. Restore what it changed: every window it used goes back to its saved pages; registers and SP go back to the program's values.
5. `RETN`. The hardware restores window 0 (above), and the program carries on.

If the program's SP pointed at ROM or nowhere, the pushed PC is lost; the monitor can still be used, and the way out is a reset.

```
; Monitor page 0x3FF, seen at 0x0000-0x1FFF in window 0
        org  0x0066
nmi:    push af
        push hl
        in   a,(0xBA)        ; NMISAVL: program's window-0 read page, bits 7-0
        ...                  ; save more, switch to the workspace, run commands
        ld   a,0x30
        out  (0x19),a        ; INTREQH: clear NMIBTN and NMIUSB
        pop  hl
        pop  af
        retn                 ; window 0 back to the program's pages
```

## 5. Start-up progress

The KS3 has no user LEDs or switches, so, as in retro68k:

- **Progress and errors** are shown as the screen's **background colour** (spec 4): a colour for each start-up step, and a distinct colour for each error (for example "SRAM test failed"). The background colour shows on HDMI and VGA before any layer is set up, since every layer is off after reset.
- The same messages go to the **USB serial console** (spec 10).
- The colour codes are set in the boot ROM spec (open point SY2).

## 6. What the boot ROM does

The boot ROM's own spec defines this in detail. In outline:

1. Show each step as a background colour and on the serial console.
2. Read RESETWHY, SYSCFG, the keys held down (PS/2 or Spectrum keyboard, spec 12) and SYSBTN.DIVMMC.
3. **Power-on only:** a quick SRAM test (data and address lines, and a pattern in each page), on the size SYSCFG.RAM4M gives. The full test is a monitor command.
4. Set up the stack, the interrupt controller in IM 2, and a timer tick (spec 9).
5. Copy the font to SRAM and start the text console on the tile layer (spec 4): 1-bit tiles, hi-res, 80 columns, with the background colour as a border.
6. **If RESETWHY.UPLOAD, or U is held:** wait for a program over the USB serial link and run it.
7. **Otherwise:** start the SD card (spec 11). If it holds a boot file, load and run it.
8. **If there is no boot file, or M or the DivMMC button is held:** start the monitor, on the screen and the serial console at once. Without M, the boot ROM then starts **BBC BASIC (Z80)** (phase 5).
9. Set SYSCON.ROMLOCK, unless D was held.

| Held during reset | Effect |
|-------------------|--------|
| M, or the DivMMC button | Go straight to the monitor |
| U | Wait for a program over USB |
| D | Development: leave the boot ROM writable (do not set ROMLOCK) |

## 7. Installing on the KS3

As in retro68k: the Next keeps several FPGA designs ("cores") in its configuration flash, in slots. Slot 0 holds the anti-brick core and slot 1 the Next itself. **Those two slots are never touched.**

- **Development:** the design is loaded straight into the FPGA over the board's JTAG header, with Vivado or openFPGALoader. Nothing is written to the flash; turning the power off brings back the normal Next.
- **Everyday use:** the design is installed as an extra Next core in a free flash slot and started from the Next's core menu. The KS3's core file format and slot size are to be confirmed once for both projects (open point SY4; design plan Q6).

## 8. Ports `0x00`–`0x07`

All ports are 8-bit (spec 3). Only A7–A0 are decoded.

| Port | Name | R/W | Bits | Reset | Description |
|------|------|-----|------|-------|-------------|
| `0x00` | SYSID | R | 7–0 | `0x5A` | Machine ID: `0x5A` ("Z") |
| `0x01` | SYSVER | R | 7–4 major, 3–0 minor | build | FPGA build version |
| `0x02` | CPUSPEED | R/W | 1–0 SPEED | 3 | Z80 speed: 0 = 3.5, 1 = 7, 2 = 14, 3 = 28 MHz. Takes effect at the next M-cycle (spec 1, section 3). Bits 7–2 read 0 |
| `0x03` | RESETWHY | R | POWER (0), BUTTON (1), SOFTWARE (2), USB (3), UPLOAD (4) | cause | Cause of the last reset (section 2.1). Bits 7–5 read 0 |
| `0x04` | SYSCFG | R | RAM4M (0), CPU (3–1) | build | RAM4M: 1 = 4 MB SRAM, 0 = 2 MB. CPU: 0 = Z80 (tv80); other values kept for a 6502 build. Bits 7–4 read 0 |
| `0x05` | SYSCON | R/W | ROMWE (0), ROMLOCK (1) | 0 | ROMWE: boot ROM pages writable; cannot be set while ROMLOCK is 1. ROMLOCK: writing 1 sets it; it stays set until power-on |
| `0x06` | SYSRESET | W | 7–0 | – | Write `0xA5` for a full reset (RESETWHY.SOFTWARE); other values are ignored. Reads `0x00` |
| `0x07` | SYSBTN | R | MULTIFACE (0), DIVMMC (1) | – | 1 = button pressed (debounced). Bits 7–2 read 0 |

Writes to read-only ports are ignored.

### 8.1 NMI monitor ports `0xB9`–`0xBD`

These sit outside the system block because `0x00`–`0x07` is full. The copper cannot reach them (it writes `0x30`–`0x9F` only). Like every port, they also appear in the register page at offset = port.

| Port | Name | R/W | Bits | Reset | Description |
|------|------|-----|------|-------|-------------|
| `0xB9` | NMICTL | R/W | EN (0), INNMI (1) | `0x01` | EN: page the monitor in when an NMI is taken (section 4.4). INNMI: read only, 1 from the NMI entry to the `RETN` that ends it. Bits 7–2 read 0 |
| `0xBA` | NMISAVL | R | 7–0 | `0xFC` | Window 0's read page at the last NMI entry, bits 7–0 |
| `0xBB` | NMISAVH | R | 1–0 | `0x03` | The same, bits 9–8. Bits 7–2 read 0 |
| `0xBC` | NMISAVWL | R | 7–0 | `0xFC` | Window 0's write page at the last NMI entry, bits 7–0 |
| `0xBD` | NMISAVWH | R | 1–0 | `0x03` | The same, bits 9–8. Bits 7–2 read 0 |

The saved pages reset to `0x3FC`, window 0's reset page, and keep their values after `RETN` until the next NMI entry. They are read only: the restore always puts back exactly what was saved.

## 9. Board connections

Pin names follow the Next's own `zxnext_top_issue5.vhd` and `zxnext_pins_issue5.xdc`, as in retro68k's `fpga/rtl/top_ks3.v` and `fpga/ks3/ks3.xdc`.

| Connection | Pins | Use |
|------------|------|-----|
| 50 MHz oscillator | clock_50_i | Both MMCMs |
| SRAM | ram_addr_o[20:0], ram_data_io[15:0], ram_cs_n_o, ram_oe_n_o, ram_we_n_o, ram_lb_n_o, ram_ub_n_o | Spec 2, section 5 |
| VGA | rgb_r_o, rgb_g_o, rgb_b_o (4 bits each), hsync_o, vsync_o, vgaclk_o, vgaclkn_o | Video (spec 4), as in retro68k |
| HDMI | hdmi_p_o[3:0], hdmi_n_o[3:0] | Video (spec 4), as in retro68k |
| Buttons | btn_reset_n_i, btn_multiface_n_i, btn_divmmc_n_i | Section 3 |
| Accelerator port | accel_io[27:0] (Raspberry Pi header). [7:0] D7–D0, [8] RXF#, [9] TXE#, [10] RD#, [11] WR#, [12] SIWU# | FT232H USB serial (spec 10; pins provisional, as in retro68k). The rest free |
| SD card | sd_cs0_n_o, sd_cs1_n_o, sd_sclk_o, sd_mosi_o, sd_miso_i | Spec 11 |
| PS/2 | ps2_clk_io, ps2_data_io (keyboard); ps2_pin6_io, ps2_pin2_io (mouse, spare) | PS/2 keyboard (spec 12). Mouse not used |
| **Spectrum keyboard** | keyb_row_o[7:0], keyb_col_i[6:0] | The membrane matrix: 8 rows × 7 columns. A row is selected by driving it low (open drain); a pressed key pulls its column low. Columns 0–4 are the Spectrum's 40 keys; columns 5–6 are the Next's extra keys. Scanned and debounced in hardware, read at port `0xFE` (spec 12) |
| **Joysticks** | joyp1_i (up), joyp2_i (down), joyp3_i (left), joyp4_i (right), joyp6_i (fire 1), joyp9_i (fire 2), joyp7_o (pin 7 out), joysel_o | Both ports share the input pins; joysel_o picks the left or the right port, and the hardware reads them in turn. joyp7_o drives pin 7 (select line of Mega Drive pads). Low = pressed. Read at ports `0xA0`–`0xA7` (spec 12) |
| Audio | audioext_l_o, audioext_r_o, audioint_o | Sigma-delta streams: the beeper in version 1 (section 9.1), sound later (spec 13) |
| Configuration flash | flash_cs_n_o and the SPI pins | Kept deselected |
| I2C | i2c_scl_io, i2c_sda_io (real-time clock, HDMI DDC) | Not used in version 1 |
| ESP8266 WiFi | esp_rx_i, esp_tx_o | Not used |
| Spectrum expansion connector | | Not used |

Unused outputs are held at safe levels, as in retro68k's `top_ks3.v`.

### 9.1 Audio output and the beeper

Until sound (spec 13) is decided, the only sound source is the Spectrum-style **beeper**: bit 4 of the last write to port `0xFE` (spec 12, section 3.3).

| Step | What happens |
|------|--------------|
| Beeper bit | Port `0xFE` bit 4, held until the next write. 0 after reset |
| Level | 0 gives the 16-bit value −BEEPAMP, 1 gives +BEEPAMP. BEEPAMP is a build constant, a quarter of full scale (open point SY8) |
| Mix | The beeper's value is the same on both channels. When spec 13 adds sound, its left and right mixes are added to it here, with clipping |
| Modulators | Three second-order sigma-delta modulators at 56 MHz, as retro68k's `sigma_delta2`, input scaled to half their range: left, right and mono ((left + right) ÷ 2) |
| Pins | audioext_l_o and audioext_r_o (the jack), audioint_o (the internal speaker) |

The board's RC filter turns each stream back into sound. A steady beeper bit gives a steady level, which the board's coupling capacitor blocks, so silence costs nothing. Square waves toggled by software sound as on a Spectrum, at any CPU speed (the pitch follows the program's timing, so code timed for 3.5 MHz should run at CPUSPEED = 0 or use the timers).

## 10. FPGA resources

| Item | Resource |
|------|----------|
| Boot ROM, 32 KB | 16 block RAMs (in the design plan's budget) |
| Reset control, button debounce, system ports, NMI monitor ports | Estimate 80–150 LUTs |
| Beeper and three sigma-delta modulators | About 280 LUTs (as in retro68k) |

## 11. Test plan

- **Each reset source** resets the Z80, the MMU, the speed and the chipset, and sets the right RESETWHY bit (only that one).
- **SRAM survives:** write a pattern, reset by each source except power-on, check it is still there.
- **Reset state:** after reset the Z80 runs from `0x0000` in ROM page 0 at 28 MHz; MMU0–MMU7 read `0x3FC`, `0x3FD`, `0x000`–`0x005`.
- **Soft reset:** writing `0xA5` to SYSRESET resets; any other value does nothing.
- **Writable ROM:** with ROMWE, a new image written through the ROM pages runs after a soft reset; with ROMLOCK set, ROMWE cannot be set until power-on; with ROMWE off, ROM writes are ignored.
- **USB link across reset:** a terminal stays connected through every reset except power-on.
- **Start-up time:** from configuration done to the first T1 within a few microseconds; reset released on slot clock 0.
- **Buttons:** SYSBTN follows the Multiface and DivMMC buttons, debounced; Multiface gives one NMI per press.
- **NMI paging:** with each read/write page pair in window 0 (SRAM, ROM, REGS, NONE, split), an NMI fetches `0x0066` from page `0x3FF`; the PC push goes through the old mapping; NMISAVL–NMISAVWH hold the old pages, MMU0/MMU0W read `0x3FF`/`0x3FB`, INNMI = 1; writes to window 0 are ignored; `RETN` with SP in window 0 pops the program's own stack, and the next fetch uses the old pages; `RETI` and other `ED` instructions in the monitor change nothing; with EN = 0 nothing is paged; a second button press in the monitor gives no nested NMI but a new one after `RETN`; reset clears INNMI and sets EN.
- **Beeper:** toggling port `0xFE` bit 4 gives a square wave on all three audio pins (averaged sigma-delta stream in simulation; heard on the jack and the speaker on the board); bits 3 and 5–7 have no effect on the sound.
- **Ports:** SYSID, SYSVER, SYSCFG (2 MB and 4 MB builds) read correctly; CPUSPEED changes the speed at the next M-cycle.
- **Board:** keyboard rows and columns, both joystick ports and all buttons checked on a real KS3.

## 12. Open points

| # | Item |
|---|------|
| SY1 | The KS3 pin locations for keyb_row_o, keyb_col_i, the joystick pins, PS/2, sd_miso_i and I2C are not yet in retro68k's `ks3.xdc`; take them from the Next's `zxnext_pins_issue5.xdc`, and check whether the keyboard rows need to be open drain on this issue |
| SY2 | The boot ROM spec: monitor commands, the upload protocol (with spec 10), the boot file name and format, the background colour codes |
| SY3 | Decided: no watchdog (spec 9 has two timers and a frame counter). RESETWHY bit 5 stays reserved |
| SY4 | The KS3 core file format and flash slot size, and installing from the SD card (shared with retro68k, its SY5) |
| SY5 | How SYSCFG.RAM4M is set: a build parameter, or a test at power-on (spec 2, M2) |
| SY6 | Should a long press of the reset button (for example 3 seconds) reset into UPLOAD? (as retro68k SY3) |
| SY7 | The monitor's workspace: which SRAM page the boot ROM sets aside for it (for example the top page), and how a program that uses every page can keep the monitor working |
| SY8 | Beeper amplitude (a quarter of full scale proposed) and whether software should be able to set it before spec 13 exists |
