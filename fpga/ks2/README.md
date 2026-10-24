# Building for the ZX Spectrum Next KS2

The first build for the KS2 (issue 4, XC7A15T-1CSG324; design plan D1a and branch 12): a test pattern on HDMI and VGA at once, at 576p. It proves the tools, the pins, the clocks and both video outputs before any of the computer is involved (issue #10). The computer's KS2 build comes next (issue #11), with its own top level.

```
fpga/ks2/build.sh                    # -> fpga/ks2/build/ks2_pattern.bit (and .bin)
fpga/ks2/build.sh --program          # build, then load it over JTAG
fpga/ks2/build.sh --program-only     # load the last build
```

**You need:** Vivado 2026.1 (the free edition covers the XC7A15T), on the PATH or named by `VIVADO`. On Windows, from Git Bash or the MSYS2 shell, at the repository root:

```
VIVADO=/c/AMDDesignTools/2026.1/Vivado/bin/vivado.bat bash fpga/ks2/build.sh
```

A build takes about 3 minutes. The script stops with an error if timing isn't met; the reports are in `fpga/ks2/build/` (`timing.txt`, `utilization.txt`, `clocks.txt`, `clock_list.txt`, `drc.txt`, `io.txt`, `vivado.log`). Nothing in `build/` is committed.

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

## What you should see

On an HDMI display and a VGA monitor at the same time, 720 × 576 at 50 Hz (both syncs negative):

- A white one-pixel frame round the whole picture: every edge should show. A display that overscans hides it.
- The top two thirds: eight colour bars, 90 pixels each: white, yellow, cyan, green, magenta, red, blue, black.
- Below them, four ramps of eight steps, left (black) to right (full): red, green, blue, grey. Each step is one VGA level, so eight even steps on the VGA monitor mean the resistor ladder's three bits are all wired. HDMI shows the same eight levels.
- At the bottom, a 32 × 32 square moving left and right (about 3.4 s from side to side), white and yellow in turn, about 0.67 s each. If it stands still, the picture is frozen; if it moves but never changes colour, the 100 MHz system clock isn't running.

HDMI carries plain DVI (no audio, no InfoFrames), which HDMI displays accept.

## Files

| File | What |
|------|------|
| `build.sh` | The one script: Vivado, then JTAG |
| `build.tcl` | Vivado non-project flow: synthesis, place and route, reports, bitstream |
| `program.tcl` | Load the bitstream over JTAG with Vivado's hardware manager |
| `ks2.xdc` | Pins and configuration settings (from the Next's `zxnext_pins_issue4.xdc`), clocks |
| `top_ks2_pattern.v` | The test pattern's top level |

The board parts are in `fpga/rtl/platform/artix7/`: `ks2_clocks.v` (two MMCMs), `hdmi_out.v` (TMDS encoders and serialisers, with `fpga/rtl/tmds_encoder.v`). They and the flow come from retro68k's KS3 build (`fpga/rtl/PROVENANCE.md`).

## Design notes

- **Clocks.** Two MMCMs from the 50 MHz oscillator. MMCM 1 (VCO 1000 MHz) makes the 100 MHz system clock, used here only by the heartbeat counter so that it is placed, routed and timed. MMCM 2 makes 27 MHz (pixel) and 135 MHz (serialiser) from a 675 MHz VCO (50 MHz ÷ 2 × 27). retro68k's KS3 runs that VCO at 1350 MHz, which the KS2's -1 speed grade (600–1200 MHz) does not allow. The two MMCMs are asynchronous clock groups.
- **HDMI.** retro68k's `hdmi_out.v` unchanged: 10:1 OSERDESE2 pairs (DDR at 135 MHz) into TMDS_33 pads, least significant bit first, pairs 0 blue, 1 green, 2 red, 3 clock, as the Next does. The Next's issue 4 core uses ODDR at 5× the pixel clock with its own shift registers instead; either works on the XC7A15T (the serialiser runs at 270 Mb/s, far below the -1 part's OSERDESE2 limit). The OSERDESE2 keeps the 135 MHz logic inside the I/O tiles, so it is the easier one to meet timing with, and it is the same module the KS3 build uses.
- **VGA.** Three bits per colour straight from the pads' flip-flops (no DAC and no DAC clocks, unlike the KS3's ADV7125). The picture is made as RGB333 and widened to 8 bits for HDMI by repeating the bits, as the Next does, so both outputs show the same colours.
- **Configuration settings** follow the Next's: SPI ×4, 32-bit SPI addresses, 40 MHz configuration rate, no fallback, unused pins pulled up, and the bitstream compressed. `ks2_pattern.bin` is a raw flash image; nothing uses it yet.
- **Unused parts** are held where the Next's top level leaves them: SRAM /CS, /OE, /WE, /LB and /UB high with the data bus let go; flash and both SD cards deselected; audio and MIC low; keyboard rows let go (pulled up); expansion bus RAMCS pulled down. Every other pin is weakly pulled up, which is the Next's idle level for the expansion bus, ESP and joystick lines.

## Results

Vivado 2026.1, 24 October 2026, XC7A15T-1CSG324. DRC clean, no critical warnings. The build takes about 3 minutes.

| Resource | Used | Available | |
|------|------|------|------|
| LUTs | 161 | 10,400 | 1.6% |
| Flip-flops | 121 | 20,800 | 0.6% |
| Block RAM | 0 | 25 (36 Kb) | 0% |
| DSP | 0 | 45 | 0% |
| MMCMs | 2 | 5 | |
| Global clock buffers | 6 | 32 | |
| OSERDESE2 | 8 | | 4 TMDS pairs, master and slave |
| Output flip-flops in the pads | 11 | | VGA colour and syncs |
| Bonded I/O | 61 | 210 | |

| Clock | Frequency | Worst setup slack | Worst hold slack |
|------|------|------|------|
| System (`c0`) | 100 MHz | +7.287 ns | +0.254 ns |
| Pixel (`p0`) | 27 MHz | +30.404 ns | +0.122 ns |
| Serialiser (`p1`) | 135 MHz | (only the OSERDESE2 clock pins; pulse width slack +5.252 ns) | |

Timing is met everywhere. The 100 MHz figure says little about the computer's build, whose logic is much deeper (open question Q11).
