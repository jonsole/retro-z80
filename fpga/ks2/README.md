# Building for the ZX Spectrum Next KS2

Two builds for the KS2 (issue 4, XC7A15T-1CSG324; design plan D1a and branch 12):

- **The computer** (issue #11, `top_ks2.v`): tv80 at 20 MHz, the MMU, the scheduler and SRAM controller on the KS2's 2 MB SRAM, the boot ROM, the system registers, USB serial on the accelerator header, the interrupt controller (issue #16), and the video unit with one layer, L0, as a bitmap (issue #13) or a tile map (issue #14), and the palettes, on HDMI and VGA. The boot ROM tests the memory and shows the result as the screen's colour, draws a palette chart in L0, then changes the background colour once a second from a VBLANK interrupt, and dims and brightens it every half second from a timer interrupt (issue #17: timers and watchdog). Two seconds after the chart appears, L0 becomes the boot console (issue #15): text on the screen, which echoes what comes in over the USB serial link. Built with `-DTILEDEMO` (by hand: assemble `boot.asm` with it in place of `build.sh`'s plain command), L0 becomes issue #14's scrolling tile map instead.
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

On an HDMI display and a VGA monitor at the same time, 720 × 576 at 50 Hz (both syncs negative). The picture is the background colour (BGCOLOR, spec 4), which the boot ROM sets as it goes (`firmware/boot/boot.asm`), and, once the self-test has passed, the palette chart in the middle, then the boot console:

| Screen | Meaning |
|--------|---------|
| No signal | The beam is off: the FPGA is not loaded, the clocks are not running, or the Z80 did not run the boot ROM's first instructions (they start the beam a few microseconds after reset) |
| Blue | The self-test is running. It takes about 0.8 ms (some 25 lines), so blue is only seen as a flash, if at all. **A screen that stays blue means the Z80 stopped inside the self-test** (for example an SRAM read that never returns the right byte and a loop that never ends) |
| **Green** | **The self-test passed**: MMU, boot ROM pages, register page, SRAM data and address lines, and the 2 MB mirror. The boot ROM then sends "selftest ok, 2 MB" and "hello" and turns on the VBLANK interrupt (IM 2) |
| **The palette chart** appears in the middle about 20 ms after green (at once, to the eye): a 512 × 512 square of 16 rows of 16 cells, each 32 × 32 pixels, with a black line on the right and bottom of each cell. Row 1 is the default palette's Spectrum colours: black, blue, red, magenta, green, cyan, yellow, white, then the same eight bright (the bright black looks black). Rows 2–14 and the first half of row 15 are a 6 × 6 × 6 colour cube: blue changes fastest along the row, then green, then red, from black (row 2's first cell) to white (row 15's eighth cell). The last 24 cells, the second half of row 15 and row 16, are a grey ramp from near black to near white | **The layer works** (issue #13): L0 is an 8-bit bitmap at 2 × across and 8 × down, fetched from the SRAM through the scheduler, coloured through PALETTE0, whose entries 16–255 the boot ROM wrote through PALIDX and PALDAT. A cell out of place, a torn or jumping chart, stripes in it or wrong colours point at the layer fetch or the palette. The background round the chart keeps changing colour (next row) |
| Green for a second, then yellow, cyan, magenta, white, green, ... a colour a second | **The interrupts work** (issue #16): the VBLANK handler counts 50 frames and sets the next colour. Between interrupts the Z80 waits in HALT. Green that never changes means the self-test passed but no VBLANK interrupt was taken |
| Each background colour bright for half a second, then half as bright for half a second, and so on | **The timers work** (issue #17): timer 0 counts the 100 MHz clock ÷ 50,000 (0.5 ms) and interrupts every 1,000 of those; its handler (TIMER0, IM 2) halves or restores the colour. The chart, and later the console's window, stay as they are. A colour that changes but never dims means no timer interrupt was taken. The two rates come from different clocks (VBLANK from the 27 MHz pixel clock), so the dimming drifts slowly against the colour changes |
| **The boot console**: two seconds after the chart, text in a black 640 × 480 window in the middle, with the background colour as a border round it (still changing and dimming) | **The console works** (issue #15; `firmware/boot/console.asm`): L0 as a 1 bpp tile map. Below |
| Red with white stripes | The self-test failed. The number of white stripes is the failing check's number less 0x40. The stripes are 16 lines tall with 16 red lines between them, starting at picture line 17, and stand still |

**The boot console.** Two seconds after the chart appears, the chart goes and L0 shows the console: 80 columns × 30 rows of 8 × 8 characters shown 8 × 16 (2× tall), in a 640 × 480 window 40 pixels in from the left and 48 lines down, on black. Round the window the background colour keeps changing once a second and dimming every half second. The window shows, from the top:

```
retro-z80 0.1                                          white
Z80 at 20 MHz, 2 MB SRAM                               light grey
selftest ok, 2 MB                                      green
hello                                                  light grey

Characters typed on the USB serial link appear here.
_                                                      the cursor
...
 retro-z80 boot console                      up 000012 s      bottom row: black on light grey
```

- **0.1** is SYSVER (major.minor), **20 MHz** is CPUSPEED's speed, **2 MB** SYSCFG.CHIPMB.
- **The cursor** (an underscore) blinks: shown while the border is bright, gone while it is dim (timer 0).
- **The status line** at the bottom counts the seconds since the console started, one a second (timer 0's interrupt). Seconds that count mean the Z80 is running, the interrupts work and the CPU's writes to the map show on the screen.
- **Typed characters**, once the FT232H module is fitted: a terminal on its serial port shows the boot ROM's two lines, and what is typed appears on the screen at the cursor and is sent back (Return gives a new line; Backspace rubs out). With no module nothing arrives, so the cursor stays where it is. When the text reaches the status line it scrolls up a row (SCROLLY), and the status line stays at the bottom.

Characters torn, shifted or doubled, wrong colours, a window in the wrong place or flicker point at the tile fetch at 1 bit per pixel (1-bit rows are one byte of a word, spec 4, section 5.2), the 128-entry map width or the 2× vertical scale. Text but no counting seconds means the main loop or timer 0 stopped.

**The tile map** (built with `-DTILEDEMO` only). Two seconds after the chart appears, the VBLANK handler turns L0 into a map of 64 × 32 tiles of 8 × 8 pixels at 4 bits per pixel, shown at 2 × 2 over the whole picture, so each tile is 16 × 16 screen pixels (45 across, 36 down). The chart goes and does not come back. The map is built from blocks of 4 × 4 tiles:

- Each block has a letter **F** with a black drop shadow four ways, on every other tile across and down (one tile, 16 pixels, apart): top left as normal (F), top right mirrored (XFLIP: the bars point left, the shadow on the left), bottom left upside down (YFLIP: the long bar at the bottom), bottom right both (turned half round). Each F only looks right if XFLIP and YFLIP work.
- The other 12 tiles of each block are a small dark grey dot in the middle, so the F's sit on a grid of dots.
- The F's colour changes from block to block along diagonals: red, blue, orange, purple (each entry's PAL, 1–4, picks a palette block).
- Everything else is transparent (TRANSP), so the background colour shows through, still changing once a second and dimming every half second.
- The map scrolls one source pixel right and one down each frame (SCROLLX and SCROLLY, written by the VBLANK handler): the picture moves smoothly up and to the left, 100 screen pixels a second. It never stops or jumps: the map (512 × 256 source pixels) wraps round both ways. The window is 288 source lines tall, so 32 of the map's lines show twice, at the top and at the bottom.

A tile torn or shifted against its neighbours, an F the wrong way round, wrong colours, flicker or sparkle (late data: OVERRUN) or jerky movement point at the tile fetch.

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

The reset button starts it all again: the beam stops for a moment (the monitor may lose the signal) and the boot ROM runs from the start. The MULTIFACE and DIVMMC buttons only show in SYSBTN.

**Serial.** The FT232H module is not fitted yet. When it is (on the accelerator header, pins as below), a terminal on its serial port shows `selftest ok, 2 MB` and `hello`, or `selftest FAIL nn`; then the console echoes what is typed. Without it the boot ROM does not wait: SERCON.TXDROP is set, so a full transmit FIFO drops its oldest bytes.

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
| `ks2_machine.xdc` | The computer's own: buttons, the accelerator header, false paths, the SRAM input flip-flops, tv80's multicycle paths |
| `top_ks2.v` | The computer's top level: clocks, power-on reset, buttons, SRAM pads, FT232H, HDMI and VGA |
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
- **Unused parts** are held where the Next's top level leaves them: flash and both SD cards deselected; audio and MIC low; keyboard rows let go (pulled up); expansion bus RAMCS pulled down. Every other pin is weakly pulled up.
- **tv80 timing.** tv80 alone is far too slow for 100 MHz (its longest register-to-register path is about 18 ns here), but every register in it changes only on cen, at least 5 clocks apart, so those paths are 5-clock multicycle paths (`ks2_machine.xdc`; spec 1, section 3.3). The paths from the core into the bus interface stay single-cycle and still meet 100 MHz (+0.89 ns), so the 3-clock multicycle spec 1 allows for them is not needed yet.

## Results: the computer

Vivado 2026.1, 24 October 2026, XC7A15T-1CSG324: the video layer L0 as a bitmap or a tile map and the palettes (issues #13 and #14), the interrupt controller (issue #16), the timers, TIME, the watchdog and the CPU's capture (issue #17). Earlier builds: issue #11's 1,949 LUTs, 1,190 flip-flops and +0.863 ns; issue #16's 2,080 LUTs, 1,261 flip-flops and +0.455 ns; issue #13's 3,062 LUTs, 2,227 flip-flops and +0.585 ns. One layer is built (`NLAYERS = 1`, in `retroz80.v`'s default): L1 and L2 would add a layer unit and a share of the fetcher each, roughly 300–400 LUTs a layer, which would still fit. DRC clean, no critical warnings. The build takes about 3 minutes.

Issue #17 alone (on issue #13's build) came to 3,658 LUTs and 2,712 flip-flops: `timers.v` is about 460 LUTs and 415 flip-flops (spec 9 estimated 250–350 LUTs), and the bus interface grew from 393 to about 540 LUTs with the capture. The tile mode (issue #14) adds about 470 LUTs and 430 flip-flops, nearly all in the layer fetcher (`bpldma.v`: 453 LUTs and 552 flip-flops before, 739 and 860 with it). The tables are the build with all of them.

| Resource | Used | Available | |
|------|------|------|------|
| LUTs | 4,136 | 10,400 | 39.8% |
| Flip-flops | 3,136 | 20,800 | 15.1% |
| Block RAM (36 Kb) | 11 (8 × 36 Kb boot ROM, 2 × 36 Kb palettes, 2 × 18 Kb serial FIFOs) | 25 | 44% |
| DSP | 2 (the register page palettes' divide by 3) | 45 | 4% |
| MMCMs | 2 | 5 | |
| Global clock buffers | 6 | 32 | |
| Bonded I/O | 93 | 210 | 44% |

| Part | LUTs | Flip-flops |
|------|------|------|
| tv80 (with the 32 LUT-RAM register file) | 1,163 | 239 |
| Serial and its FIFOs | 261 | 195 |
| Bus interface (the palette read from its register bus input, the CPU's capture) | 546 | 176 |
| Video (beam, registers, palettes, priority, pixel pipeline, the tile map line) | 433 | 545 |
| Layer fetch (`bpldma.v`, with the tile fetch) | 739 | 860 |
| Layer L0's pixel side (`layer_pix.v`) | 148 | 158 |
| Timers, TIME, watchdog (`timers.v`) | 458 | 415 |
| MMU | 153 | 297 |
| Interrupt controller (synthesis folds the tied-off sources away) | 18 | 61 |
| Everything else (scheduler, SRAM controller, system registers, reset, top level) | about 100 | about 180 |

| Clock | Frequency | Worst setup slack | Worst hold slack |
|------|------|------|------|
| System (`c0`) | 100 MHz | +0.797 ns (the layer fetcher's pick of the next slot, `ngr` to `a_j`) | +0.045 ns |
| Pixel (`p0`) | 27 MHz | +24.933 ns | +0.059 ns |
| Serialiser (`p1`) | 135 MHz | (only the OSERDESE2 clock pins; pulse width slack +5.252 ns) | |

Timing is met everywhere (open question Q11: yes, with tv80's multicycle paths). Other tight 100 MHz paths: tv80's instruction register to the bus interface's address register (+0.89 ns, single-cycle); the CPU's clock-enable divider into tv80's register enables (+3.4 ns). tv80's own paths need 17.9 ns of their 50 ns.

## Results: the test pattern

As issue #10 (24 October 2026): 161 LUTs, 121 flip-flops, timing met (100 MHz +7.3 ns). Shown correctly on HDMI; VGA not yet checked.

## Risks for the first run of the computer

- **SRAM timing on the board.** The controller has never run on real SRAM (retro68k's KS3 has not been built yet either). The KS2's 8 ns part is faster than the KS3's 10 ns one, so the datasheet margins of spec 2, section 8.3 grow (address to data 8 ns in place of 10; /OE high to the SRAM off the bus about 3 ns in place of 4, so a write after a read has about 2 ns spare in place of 1; the /WE pulse needs about 6.5 ns of the 10). What is not known is the board: the pads' delays on the -1 part, the trace lengths and the ringing at SLEW FAST. A screen that stays blue, or 15–17 stripes, points here. Fallbacks (spec 2, open point M1): a free cycle before a write that follows a read, or a slower drive or slew setting.
- **SRAM read capture.** Read data is taken in the input pads' flip-flops at E + 30 ns with no input-delay constraint, so Vivado does not check it; it relies on the 20 ns from the address leaving to the capture (about 5 ns left after the output pad, the SRAM's 8 ns and the input pad).
- **Pins.** The SRAM, video and clock pins are those the test pattern proved, or the Next's issue 4 pin file for the SRAM (the pattern only held the SRAM deselected, so the SRAM pins are proved only by this build). The buttons (V9, T8, T9) and accelerator pins come from the same file and match the KS3's.
- **Reset button.** If the reset button does nothing, check V9 against the board; the Next also folds joystick buttons into its reset, which this build does not.
