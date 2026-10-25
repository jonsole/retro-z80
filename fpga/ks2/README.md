# Building for the ZX Spectrum Next KS2

Two builds for the KS2 (issue 4, XC7A15T-1CSG324; design plan D1a and branch 12):

- **The computer** (issue #11, `top_ks2.v`): tv80 at 20 MHz, the MMU, the scheduler and SRAM controller on the KS2's 2 MB SRAM, the boot ROM, the system registers, USB serial on the accelerator header, the interrupt controller (issue #16), the video unit with one layer, L0, as a bitmap (issue #13) or a tile map (issue #14), and the palettes, on HDMI and VGA, the timers and the watchdog (issue #17), the keyboards and joysticks (issue #19), port `0xFE`'s border and beeper (issue #21). The boot ROM (spec 16) tests the memory at power-on, sets up the boot console on L0 (issue #15) and starts the **monitor** (issue #22; the shared spec `docs/spec/monitor.md`): commands typed on the Spectrum keyboard or a PS/2 keyboard, a small program typed in and run, breakpoints, the registers, the ports. The tape loader demo of issue #21 is EDIT (or Tab) on an empty command line.
- **The test pattern** (issue #10, `top_ks2_pattern.v`): colour bars on HDMI and VGA at 576p. It proved the tools, the pins, the clocks and both video outputs before the computer was involved.

```
fpga/ks2/build.sh                    # the computer -> fpga/ks2/build/retroz80_ks2.bit (and .bin)
fpga/ks2/build.sh --program          # build, then load it over JTAG
fpga/ks2/build.sh --program-only     # load the last build
fpga/ks2/build.sh --pattern          # the test pattern -> fpga/ks2/build/pattern/ks2_pattern.bit
fpga/ks2/build.sh --pattern --program-only
```

**You need:** Vivado 2026.1 (the free edition covers the XC7A15T), on the PATH or named by `VIVADO`. The computer also needs sjasmplus and Python 3 for the boot ROM (on the PATH, or `SJASMPLUS` and `PYTHON`; `C:/tools/sjasmplus/sjasmplus.exe` is found by itself). On Windows, from Git Bash or the MSYS2 shell, at the repository root:

```
VIVADO=/c/AMDDesignTools/2026.1/Vivado/bin/vivado.bat bash fpga/ks2/build.sh
```

A build takes about 3 minutes. The script stops with an error if timing isn't met; the reports are in `fpga/ks2/build/` (or `build/pattern/`): `timing.txt`, `utilization.txt`, `utilization_hier.txt`, `clocks.txt`, `clock_list.txt`, `drc.txt`, `io.txt`, `vivado.log`. Nothing in `build/` is committed.

## Loading it into the KS2

Loading over JTAG changes only the FPGA, until the power goes off. The flash and the Next's own cores are not touched: power the KS2 off and on and it starts the Next as usual.

1. **Cable.** The Xilinx Platform Cable USB (or USB II) with its 14-pin 2 mm ribbon. Plug its USB end into the PC. Vivado's cable driver must be installed (Vivado's installer offers it; otherwise run `C:\AMDDesignTools\2026.1\Vivado\data\xicom\cable_drivers\nt64\install_drivers_wrapper.bat` as administrator). The cable's status LED is amber while it sees no target.
2. **Header.** With the KS2 **off**, plug the ribbon into the KS2's 14-pin JTAG header (marked JTAG). It is a shrouded 2 mm header (Amphenol T821, 14 way), so the ribbon's key fits the notch in the shroud one way only. Pin 1 is the ribbon's red (or marked) wire and the triangle on its socket; it goes to the pin 1 end of the header (the "1" or square pad on the board). Don't force it if the key does not fit: turn it round.
   The KS2 schematic puts TMS, TCK, TDO and TDI on pins 4, 6, 8 and 10 and the reference voltage (3.3 V) on pin 2, as on Xilinx's cable. The odd pins from 3 to 13 are ground.
3. **Power.** Power the KS2 from its usual supply. The Next starts from its flash as normal. The cable's LED turns green when it sees the board's 3.3 V on pin 2.
4. **Load.** At the repository root:

   ```
   VIVADO=/c/AMDDesignTools/2026.1/Vivado/bin/vivado.bat bash fpga/ks2/build.sh --program-only
   ```

   It takes a few seconds and ends with `retro-z80: FPGA loaded`. If it reports no XC7A15T, check the cable's LED, the ribbon's orientation and that the board is on. Vivado's Hardware Manager (Open Target, Auto Connect, Program Device) does the same by hand.

## The computer: what you should see

On an HDMI display and a VGA monitor at the same time, 720 × 576 at 50 Hz (both syncs negative). The picture is the background colour (BGCOLOR, spec 4), which the boot ROM sets as it starts (`firmware/boot/boot.asm`, spec 16, section 4.4), then the boot console with the monitor:

| Screen | Meaning |
|--------|---------|
| No signal | The beam is off: the FPGA is not loaded, the clocks are not running, or the Z80 did not run the boot ROM's first instructions (they start the beam a few microseconds after reset) |
| Blue | Start-up, and at power-on (a JTAG load is one) the memory and MMU self-test. It takes about a millisecond, so blue is only seen as a flash, if at all. **A screen that stays blue means the Z80 stopped there** (for example an SRAM read that never returns the right byte and a loop that never ends). A press of the reset button skips the self-test, so SRAM keeps what a program left |
| Green, a flash | The self-test passed (or was skipped); the units, the monitor's workspace and the console are being set up, a few milliseconds |
| **Black border, the console** | **The boot console and the monitor** (issue #22): text in a black 640 × 480 window in the middle, the border black round it. Below |
| Red with white stripes | The self-test failed. The number of white stripes is the failing check's number less 0x40. The stripes are 16 lines tall with 16 red lines between them, starting at picture line 17, and stand still |

**The console.** 80 columns × 30 rows of 8 × 8 characters shown 8 × 16 (2× tall), in a 640 × 480 window 40 pixels in from the left and 48 lines down (spec 7, section 5.1). After a JTAG load it shows:

```
retro-z80 boot ROM 0.1  Z80 at 20 MHz, 2 MB SRAM
Reset: power-on.  Self-test ok.
Monitor.  H for help.
> _
```

- **0.1** is the boot ROM's version (ROMID, spec 16, section 3.1); **20 MHz** is CPUSPEED's speed, **2 MB** SYSCFG.CHIPMB. **Reset:** says why the machine started: `power-on` after a JTAG load, `button` after the reset button (with no `Self-test ok.`: the self-test runs at power-on only).
- **The cursor** (an underscore) blinks, about four times a second, while the monitor waits for a key.
- Lines go up the screen as the text reaches the bottom (SCROLLY, a row at a time).
- The boot ROM looks for the start-up keys M, U and D for a quarter of a second before the `Monitor.` line (spec 16, section 4.3); today each of them ends at the monitor too.

### The monitor: try this

The monitor (the shared spec `docs/spec/monitor.md`, sections 2–4; spec 16, section 8) reads lines typed on the KS2's own keys or a PS/2 keyboard (and, once the FT232H is fitted, from a terminal), with the prompt `> `. Commands are one letter and hex numbers, upper or lower case; Enter runs the line. `H` lists them. **On the membrane**, the characters a monitor line needs:

| To type | On the KS2's keys |
|---------|-------------------|
| Letters and digits | The keys themselves; lower case is fine (hold CAPS SHIFT for capitals) |
| Space | SPACE |
| Enter | ENTER |
| Rub out the last character | CAPS SHIFT + 0 (DELETE), or the DELETE key |
| `.` (sizes: `D.W`; ends `E`'s stepping) | SYMBOL SHIFT + M, or the `.` key |
| `"` (text: `E 9000 "Hi"`) | SYMBOL SHIFT + P, or the `"` key |
| `?` (help, as `H`) | SYMBOL SHIFT + C |
| `'` (`R AF' 0`) | SYMBOL SHIFT + 7 |
| `-` (back one in `E`'s stepping) | SYMBOL SHIFT + J |
| `,` (works as a space) | SYMBOL SHIFT + N, or the `,` key |
| Esc: drop the line, or stop `E`'s stepping | CAPS SHIFT + SPACE (BREAK), or the BREAK key |
| The last line again | CAPS SHIFT + 7, or the cursor up key |
| The tape loader demo (an empty line) | CAPS SHIFT + 1 (EDIT), or the EDIT key |

A key held for half a second repeats, ten times a second. A PS/2 keyboard types as on a PC (UK layout): Backspace, Esc, the cursor up key and Tab do the same.

Type these lines in turn (what you type follows `> `; the rest is what the monitor prints; the `R=` value and the bytes after `P7F0020` change from run to run):

```
> D 0040 20
0040  F5 3E 01 C3 25 01 FF FF  52 5A 38 30 00 01 11 00  .>..%...RZ80....
0050  32 30 32 36 2D 31 30 2D  32 35 00 00 00 00 00 00  2026-10-25......
```

The boot ROM itself: the EXIT entry at `0040` (where a program's `RET` goes), the identity block `RZ80`, version 0.1 and 17 functions at `0048`, the build date at `0050` (spec 16, section 3.1).

```
> P 7000
7000: 5A
```

Port `0x7000` is SYSID: `5A` is retro-z80.

```
> E 8000 3E 41 CF C9
> D 8000 4
8000  3E 41 CF C9                                       >A..
> G 8000
A
Program ended.
AF=4100 BC=0000 DE=0000 HL=0000 IX=0000 IY=0000 SP=0000 PC=0040
AF'=0000 BC'=0000 DE'=0000 HL'=0000 I=1F R=7F IFF=0 IM=2?
```

A program typed in at `8000`: `LD A,'A'` (`3E 41`), `RST 08h` (`CF`: the ROM prints A), `RET` (`C9`: back to the monitor through EXIT). The monitor shows the registers the program left: A = `41`, SP back at `0000` after the `RET` popped `FFFE`, PC at EXIT. `R` shows them again; `G` alone runs the program again.

```
> E 8100 3E 42 CF 3E 43 CF C9
> G 8100 8103
B
Breakpoint at 8103
AF=4200 BC=0000 DE=0000 HL=0000 IX=0000 IY=0000 SP=FFFE PC=8103
AF'=0000 BC'=0000 DE'=0000 HL'=0000 I=1F R=7E IFF=0 IM=2?
> G
C
Program ended.
AF=4300 BC=0000 DE=0000 HL=0000 IX=0000 IY=0000 SP=0000 PC=0040
AF'=0000 BC'=0000 DE'=0000 HL'=0000 I=1F R=7D IFF=0 IM=2?
```

A breakpoint: `G 8100 8103` puts `RST 30h` at `8103`, so the program prints B and stops before printing C; the monitor puts the old byte back (`D 8103 1` shows `3E`). `G` goes on from there.

```
> E 8200 F7 3E 44 CF C9
> G 8200
Break at 8200
AF=4300 BC=0000 DE=0000 HL=0000 IX=0000 IY=0000 SP=FFFE PC=8201
AF'=0000 BC'=0000 DE'=0000 HL'=0000 I=1F R=6A IFF=0 IM=2?
> G
D
Program ended.
```

`RST 30h` (`F7`) in a program breaks into the monitor; `G` goes on after it.

```
> F 9000 10 2A
> D.W 9000 10
9000  2A2A 2A2A 2A2A 2A2A  2A2A 2A2A 2A2A 2A2A          ****************
> E 9000
9000: 2A 55
9001: 2A .
> D 9000 2
9000  55 2A                                             U*
```

Fill 16 bytes with `2A`, dump them as words, then step through memory with `E`: type a new value and Enter, or Enter alone to keep it, `-` to go back, `.` (or BREAK) to stop.

```
> D P7F0020 4
P7F0020  -- A8 03 00                                       ....
> P FE
00FE: FF
> P 1F
001F: 00
> P 6700
6700: 00
```

A `P` in front of an address makes it physical: `P7F0020` is the register page, where TIME0's read would capture TIME, so the monitor shows `--` for it (spec 16, section 8.1); the other three bytes of TIME count. `P FE` reads port `0xFE` with every keyboard row: `FF` with no key held, but the line runs the moment ENTER goes down, so ENTER (column 0) usually still shows: `FE` (hold SYMBOL SHIFT as well and it is `FC`). `P 1F` is joystick 1 through the Kempston port and `P 6700` joystick 2 (JOY2): hold a direction while pressing ENTER to see its bit (right 01, left 02, down 04, up 08, fire 10; issue #20).

More to try: `S 8000 300 CF` finds the `RST 08h`s typed above; `C 8000 4 9000` then `V 8000 4 9000` (`Differences: 0000`); `R HL 1234` then `R`; `E 8300 FF` and `G 8300` (`Trap RST 38h at 8300`: a fetch of `0xFF`); `D P1FC000` shows the console's own map (each character, then its colour byte `02`); a wrong line answers `? syntax`, `? address` or `? size`. A program that never comes back needs the reset button (the Multiface NMI is not wired yet).

**The tape loader demo** (issue #21): on an empty line, press **EDIT** (CAPS SHIFT + 1, or the EDIT key) or Tab on a PS/2 keyboard. Plug headphones or an amplifier into the KS2's audio jack (the internal speaker, if fitted, plays the same in mono). For about 3.6 seconds the boot ROM plays a Spectrum loading a tape, writing port `0xFE` for every edge (border and beeper together):

1. **Pilot, 1.5 s.** The border fills with **red and cyan stripes**, each about 19 picture lines tall, rolling slowly up or down, and the jack plays a steady **807 Hz tone** (the Spectrum's pilot, 2,168 T-states a half wave).
2. **Data, about 1.5 s.** After two short sync stripes, **thin blue and yellow stripes** (8–15 lines each, uneven, jittering) and the familiar **rasp** of data: the boot ROM's first 256 bytes as Spectrum tape bits (855 or 1,710 T-states a half wave).
3. **Pause, 0.17 s.** Black border, quiet.
4. **Beep, 0.4 s.** A **clean 880 Hz tone** (A), the border black.
5. Then the border is black again and a new prompt shows.

What to look at: the stripes' edges are **ragged, in the middle of lines** (a Spectrum's loader look): each `OUT (0xFE),A` shows from the pixel on screen 15–52 ns later (spec 4: about 10–60 ns), not at the next line. The stripes cover the border only: the console's black window stays on top. The tone should be clean, at a modest level (the beeper is a fixed quarter of full scale), the same in both ears.

**What to report:** a key that types the wrong character or none (the membrane's rows and columns, spec 12 open point K1), a command whose output differs from the lines above, characters torn, shifted or doubled (the tile fetch at 1 bit per pixel, spec 4, section 5.2), a cursor that does not blink (TIME), and anything the monitor does that the shared spec says otherwise.

The keyboards (issue #19, spec 12; `fpga/rtl/ps2kb.v`, `ps2map.v`, `keys.v`, `joy.v`; the boot ROM's side is `firmware/boot/keys.asm`): the membrane is read through KEYMAP0–6, a key typed when it goes down; a PS/2 keyboard in the KS2's PS/2 socket (one that speaks PS/2: an old one, or a USB keyboard that works through a passive adapter) through its FIFO, polled. While a PS/2 key is held, port `0xFE` shows the Spectrum key it stands for (KEYCON.PS2MAP), so `P FE` with A held gives `FE`.

The checks (`firmware/boot/selftest.asm`):

| Stripes | Check | What failed |
|---------|-------|-------------|
| 1 | 41 | An MMU register's reset value |
| 2 | 42 | MMU byte 0 alone changed the mapping |
| 3 | 43 | MMU byte 1 did not commit the read and write page |
| 4 | 44 | MMU byte 1 alone did not keep bits 7–0 |
| 5 | 45 | A write to another register between the two MMU bytes |
| 6 | 46 | A write page commit did not split the window |
| 7 | 47 | A read page commit did not join it again |
| 8 | 48 | NONE as a write page did not ignore writes |
| 9 | 49 | NONE or a reserved page did not read `0xFF` |
| 10 | 4A | Boot ROM pages through the MMU (contents, or writes not ignored) |
| 11 | 4B | Registers through the register page |
| 12 | 4C | An opcode fetch from the register page was not RST 38h |
| 13 | 4D | ROM reads and register writes in one window |
| 14 | 4E | SYSCFG.CHIPMB, or the 2 MB mirror (pages `0x100`–`0x1FF` must show `0x000`–`0x0FF`) |
| 15 | 4F | **SRAM data lines** (even and odd bytes) |
| 16 | 50 | **SRAM address lines A0–A12** within a page |
| 17 | 51 | **SRAM page lines** (address lines A13 and up) |

Checks 4F–51 are the ones that test the board's SRAM wiring and timing; the earlier ones need the SRAM only for the stack and a few bytes.

The reset button starts it all again: the beam stops for a moment (the monitor may lose the signal) and the boot ROM runs from the start, without the self-test. The MULTIFACE and DIVMMC buttons only show in SYSBTN (DIVMMC held at reset counts as M).

**Serial.** The FT232H module is not fitted yet. When it is (on the accelerator header, pins as below), a terminal on its serial port shows everything the monitor prints and types into it, as the keyboards do. Without it the boot ROM does not wait: SERCON.TXDROP is set, so a full transmit FIFO drops its oldest bytes.

**Earlier demos.** Issues #13–#19's demos (the palette chart, the colour cycle, the dimming and the console's status line) are gone from the boot ROM now that it runs the monitor (spec 16, section 4.1); the hardware they showed is still built. The tile map demo (`-DTILEDEMO`, issue #14) went with them; the commit before issue #22 still has it.

## The test pattern: what you should see

- A white one-pixel frame round the whole picture: every edge should show. A display that overscans hides it.
- The top two thirds: eight colour bars, 90 pixels each: white, yellow, cyan, green, magenta, red, blue, black.
- Below them, four ramps of eight steps, left (black) to right (full): red, green, blue, grey. Each step is one VGA level, so eight even steps on the VGA monitor mean the resistor ladder's three bits are all wired. HDMI shows the same eight levels.
- At the bottom, a 32 × 32 square moving left and right (about 3.4 s from side to side), white and yellow in turn, about 0.67 s each. If it stands still, the picture is frozen; if it moves but never changes colour, the 100 MHz system clock isn't running.

HDMI carries plain DVI (no audio, no InfoFrames), which HDMI displays accept.

## Files

| File | What |
|------|------|
| `build.sh` | The one script: boot ROM, Vivado, then JTAG |
| `build.tcl` | Vivado non-project flow: synthesis, place and route, reports, bitstream (the computer or the pattern) |
| `program.tcl` | Load the bitstream over JTAG with Vivado's hardware manager |
| `ks2.xdc` | Pins and configuration settings shared by both builds (from the Next's `zxnext_pins_issue4.xdc`), clocks |
| `ks2_machine.xdc` | The computer's own: buttons, the accelerator header, the PS/2 keyboard, membrane columns and joystick pins, false paths, the SRAM input flip-flops, the audio pads' flip-flops, tv80's multicycle paths |
| `top_ks2.v` | The computer's top level: clocks, power-on reset, buttons, SRAM pads, FT232H, the open-drain PS/2 lines and keyboard rows, HDMI and VGA, the audio pads |
| `top_ks2_pattern.v` | The test pattern's top level |

The board parts are in `fpga/rtl/platform/artix7/`: `ks2_clocks.v` (two MMCMs), `hdmi_out.v` (TMDS encoders and serialisers, with `fpga/rtl/tmds_encoder.v`), `oddr.v`. They and the flow come from retro68k's KS3 build (`fpga/rtl/PROVENANCE.md`).

## Design notes

- **Clocks.** Two MMCMs from the 50 MHz oscillator. MMCM 1 (VCO 1000 MHz) makes the 100 MHz system clock. MMCM 2 makes 27 MHz (pixel) and 135 MHz (serialiser) from a 675 MHz VCO (50 MHz ÷ 2 × 27). retro68k's KS3 runs that VCO at 1350 MHz, which the KS2's -1 speed grade (600–1200 MHz) does not allow. The two MMCMs are asynchronous clock groups.
- **Reset.** Power-on reset is held until both MMCMs lock, then 256 clocks more. The reset button is synchronised and needs 10 ms of agreement (as retro68k's KS3 build), then goes to the computer's reset logic (RESETWHY.BUTTON).
- **SRAM.** IS61WV102416FBLL-8: 1M × 16, 8 ns, 20 address lines. `retroz80` is built with CHIPMB = 2, so physical address bit 21 is ignored (pages `0x100`–`0x1FF` mirror `0x000`–`0x0FF`) and `sram_a[19:0]` go to the pins. The controller is retro68k's: 20 ns cycles, outputs from the pads' flip-flops, /OE, /WE and the data enable from ODDRs, read data taken in the input pads' flip-flops. See "Risks" below.
- **FT232H.** On the accelerator header, provisional pins as retro68k's KS3 build (spec 10, open point U2): `accel_io[7:0]` D7–D0, `[8]` RXF#, `[9]` TXE#, `[10]` RD#, `[11]` WR#, `[12]` SIWU#. The KS2 and KS3 put these on the same FPGA pins (the Next's issue 4 and issue 5 pin files). All 13 are pulled up, so with no module the link is idle.
- **HDMI.** retro68k's `hdmi_out.v` unchanged: 10:1 OSERDESE2 pairs (DDR at 135 MHz) into TMDS_33 pads, least significant bit first, pairs 0 blue, 1 green, 2 red, 3 clock, as the Next does. The computer sends 24-bit colour.
- **VGA.** Three bits per colour straight from the pads' flip-flops (no DAC). The computer sends the top three bits of each colour; the test pattern makes RGB333 and widens it for HDMI.
- **Configuration settings** follow the Next's: SPI ×4, 32-bit SPI addresses, 40 MHz configuration rate, no fallback, unused pins pulled up, and the bitstream compressed. The `.bin` is a raw flash image; nothing uses it yet.
- **Input** (issue #19; spec 12, open points K2 and J1), pins from the Next's issue 4 pin file: the PS/2 keyboard on `ps2_clk_io` K1 and `ps2_data_io` L4 (LVCMOS33, pulled up, open collector; the KS3 moves them to N5 and N6); the membrane rows `keyb_row_o[7:0]` (J14, M16, M13, N16, K16, K15, K13, J15) open drain as the Next drives them, low for the row being scanned and let go (pulled up) otherwise, so two keys in one column never short two rows; the columns `keyb_col_i[6:0]` (R8, R7, T6, V7, U6, T18, R17) pulled up; the joysticks' shared lines `joyp1_i`–`joyp4_i`, `joyp6_i`, `joyp9_i` (T13, R12, V16, U17, V15, V17, with weak pull-ups the Next does not have), `joysel_o` U14 (0 = the left port) and `joyp7_o` R13, the Mega Drive select for both ports. The KS3 (issue 5) has the same keyboard and joystick pins.
- **Audio** (issue #21; spec 7, section 10.2), pins from the Next's issue 4 pin file: `audioext_l_o` B4 and `audioext_r_o` A4 (the jack; LVCMOS33, DRIVE 16, no termination) and `audioint_o` U16 (the internal speaker; DRIVE 8, slow slew). Each carries a 1-bit sigma-delta stream at 100 MHz from a second-order modulator (retro68k's `sigma_delta2`), from the pads' flip-flops; the board's RC filters make the sound. The Next drives the same pins the same way, with first-order DACs at 28 MHz (`zxnext_top_issue4.vhd`: `dac` on its 12-bit left and right mixes and a 13-bit mono one, each registered on its way out; the speaker's stream ANDed with its enable). Here the speaker always plays (no enable yet). The beeper is the only source: port `0xFE` bit 4, ± a quarter of full scale.
- **Unused parts** are held where the Next's top level leaves them: flash and both SD cards deselected; MIC low; expansion bus RAMCS pulled down. Every other pin is weakly pulled up.
- **tv80 timing.** tv80 alone is far too slow for 100 MHz (its longest register-to-register path is about 18 ns here), but every register in it changes only on cen, at least 5 clocks apart, so those paths are 5-clock multicycle paths (`ks2_machine.xdc`; spec 1, section 3.3). The paths from the core into the bus interface stay single-cycle and still meet 100 MHz (+0.89 ns), so the 3-clock multicycle spec 1 allows for them is not needed yet.

## Results: the computer

Vivado 2026.1, 25 October 2026, XC7A15T-1CSG324: the video layer L0 as a bitmap or a tile map and the palettes (issues #13 and #14), the interrupt controller (issue #16), the timers, TIME, the watchdog and the CPU's capture (issue #17), the keyboards and joysticks (issue #19), port `0xFE` writes: the border and the beeper with its audio output (issue #21). Earlier builds: issue #19's 4,663 LUTs, 3,709 flip-flops and +0.383 ns; issue #17's and #14's 4,136 LUTs, 3,136 flip-flops and +0.797 ns; issue #11's 1,949 LUTs, 1,190 flip-flops and +0.863 ns; issue #16's 2,080 LUTs, 1,261 flip-flops and +0.455 ns; issue #13's 3,062 LUTs, 2,227 flip-flops and +0.585 ns. One layer is built (`NLAYERS = 1`, in `retroz80.v`'s default): L1 and L2 would add a layer unit and a share of the fetcher each, roughly 300–400 LUTs a layer, which would still fit. DRC clean, no critical warnings. The build takes about 3 minutes.

Issue #17 alone (on issue #13's build) came to 3,658 LUTs and 2,712 flip-flops: `timers.v` is about 460 LUTs and 415 flip-flops (spec 9 estimated 250–350 LUTs), and the bus interface grew from 393 to about 540 LUTs with the capture. The tile mode (issue #14) adds about 470 LUTs and 430 flip-flops, nearly all in the layer fetcher (`bpldma.v`: 453 LUTs and 552 flip-flops before, 739 and 860 with it). The input units (issue #19) add about 530 LUTs and 570 flip-flops: `ps2kb.v` 163 LUTs and 123 flip-flops, `ps2map.v` 38 and 75, `keys.v` 139 and 259, `joy.v` 66 and 99 (spec 12 estimated 400–630 LUTs), and the bus interface grew by about 120 LUTs with the wider read-data OR. Port `0xFE` writes (issue #21) add about 150 LUTs and 55 flip-flops: `audio.v` is 76 LUTs and 47 flip-flops (synthesis shares the three modulators, whose inputs are the same while the beeper is the only source; spec 7 estimated about 280 LUTs for three), the rest the border's decode, crossing and colour in `video.v`. The tables are the build with all of them.

| Resource | Used | Available | |
|------|------|------|------|
| LUTs | 4,814 | 10,400 | 46.3% |
| Flip-flops | 3,763 | 20,800 | 18.1% |
| Block RAM (36 Kb) | 11 (8 × 36 Kb boot ROM, 2 × 36 Kb palettes, 2 × 18 Kb serial FIFOs) | 25 | 44% |
| DSP | 2 (the register page palettes' divide by 3) | 45 | 4% |
| MMCMs | 2 | 5 | |
| Global clock buffers | 6 | 32 | |
| Bonded I/O | 109 | 210 | 52% |

| Part | LUTs | Flip-flops |
|------|------|------|
| tv80 (with the 32 LUT-RAM register file) | 1,163 | 239 |
| Serial and its FIFOs | 262 | 195 |
| Bus interface (the palette read from its register bus input, the CPU's capture) | 668 | 182 |
| Video (beam, registers, palettes, priority, pixel pipeline, the tile map line, the port `0xFE` border) | 454 | 552 |
| Layer fetch (`bpldma.v`, with the tile fetch) | 769 | 872 |
| Layer L0's pixel side (`layer_pix.v`) | 149 | 158 |
| Timers, TIME, watchdog (`timers.v`) | 425 | 415 |
| PS/2 keyboard (`ps2kb.v`) and its mapper (`ps2map.v`) | 201 | 198 |
| Membrane and port `0xFE` (`keys.v`) | 139 | 259 |
| Joysticks (`joy.v`) | 66 | 99 |
| Audio: the beeper and its sigma-delta modulators (`audio.v`) | 76 | 47 |
| MMU | 151 | 297 |
| Interrupt controller (synthesis folds the tied-off sources away) | 20 | 62 |
| Everything else (scheduler, SRAM controller, system registers, reset, top level) | about 100 | about 180 |

| Clock | Frequency | Worst setup slack | Worst hold slack |
|------|------|------|------|
| System (`c0`) | 100 MHz | +0.565 ns (the layer fetcher's pick of the next slot, `dlt` to `a_j`) | +0.027 ns |
| Pixel (`p0`) | 27 MHz | +23.332 ns | +0.125 ns |
| Serialiser (`p1`) | 135 MHz | (only the OSERDESE2 clock pins; pulse width slack +5.252 ns) | |

Timing is met everywhere (open question Q11: yes, with tv80's multicycle paths). The tightest path is now tv80's instruction register into the bus interface's read data register (single-cycle: the core's early cycle-type outputs decide whether `di` loads); it was +0.89 ns before issue #19 and +0.38 ns with the input units' read data on the bus; in issue #21's build the worst is the layer fetcher's pick of the next slot (`dlt` to `a_j`, +0.57 ns), placement noise rather than the new logic, which is not on either path. If more units push it under 0, it can take the 3-clock multicycle spec 1 allows. Other tight 100 MHz paths: the layer fetcher's pick of the next slot (`ngr` to `a_j`, +0.80 ns before); the CPU's clock-enable divider into tv80's register enables (+3.4 ns). tv80's own paths need 17.9 ns of their 50 ns.

## Results: the test pattern

As issue #10 (24 October 2026): 161 LUTs, 121 flip-flops, timing met (100 MHz +7.3 ns). Shown correctly on HDMI; VGA not yet checked.

## Risks for the first run of the computer

- **SRAM timing on the board.** The controller has never run on real SRAM (retro68k's KS3 has not been built yet either). The KS2's 8 ns part is faster than the KS3's 10 ns one, so the datasheet margins of spec 2, section 8.3 grow (address to data 8 ns in place of 10; /OE high to the SRAM off the bus about 3 ns in place of 4, so a write after a read has about 2 ns spare in place of 1; the /WE pulse needs about 6.5 ns of the 10). What is not known is the board: the pads' delays on the -1 part, the trace lengths and the ringing at SLEW FAST. A screen that stays blue, or 15–17 stripes, points here. Fallbacks (spec 2, open point M1): a free cycle before a write that follows a read, or a slower drive or slew setting.
- **SRAM read capture.** Read data is taken in the input pads' flip-flops at E + 30 ns with no input-delay constraint, so Vivado does not check it; it relies on the 20 ns from the address leaving to the capture (about 5 ns left after the output pad, the SRAM's 8 ns and the input pad).
- **Pins.** The SRAM, video and clock pins are those the test pattern proved, or the Next's issue 4 pin file for the SRAM (the pattern only held the SRAM deselected, so the SRAM pins are proved only by this build). The buttons (V9, T8, T9) and accelerator pins come from the same file and match the KS3's.
- **Reset button.** If the reset button does nothing, check V9 against the board; the Next also folds joystick buttons into its reset, which this build does not.
