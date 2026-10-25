# FPGA RTL

Plain Verilog-2005, simulated with Icarus Verilog and Verilator in `sim/`. Chip-specific parts go in `platform/artix7/`, with behavioural versions for simulation in `platform/sim/` (design plan, D10).

Modules taken from retro68k are copied here at a recorded retro68k commit and narrowed to retro-z80's byte registers; [PROVENANCE.md](PROVENANCE.md) lists each one's origin and what was changed (design plan, branch 12, "RTL reuse").

## Rules

- **Widths must add up exactly.** Where a unit rebuilds a register's value from its stored fields (for a read, or to merge a byte write), the concatenation must be exactly the register's width. retro68k found a rebuild of SPRxCTL that was 34 bits for a 32-bit register, which shifted PAL and DEPTH on every half write; it stayed hidden while the CPU wrote whole registers. Every RTL change is linted with Verilator, as retro68k does (its `fpga/lint.sh`, CI job "RTL lint (Verilator)"): `--lint-only --default-language 1364-2005` (`new` and `soft` are SystemVerilog keywords), with **WIDTHTRUNC as an error** (it catches the 34-into-32 case); WIDTHEXPAND is left as a warning, since zero-extension is everywhere and harmless. A deliberate truncation uses an explicit slice, or a one-line `lint_off WIDTHTRUNC` / `lint_on` waiver. Third-party code (tv80) is waived with a `.vlt` file (`lint_off -rule ... -file ...`).
- Each byte register is written directly (spec 3, rule 2); check that a byte write changes only its own byte's fields.

Board builds live in `fpga/ks2/` (the computer on the KS2, issue #11, and its test pattern, issue #10; see its README). Lint everything with `sh fpga/lint.sh` (or `make -C sim lint`); it fails on any width cut short. CI runs it on every push.

## Written so far

| File | What | Spec |
|------|------|------|
| `retroz80.v` | The computer without board parts: timebase, reset, CPU, memory, registers, serial, interrupts, video, input, audio. `CHIPMB = 2` builds for a 2 MB board: physical bit 21 ignored; `NLAYERS` sets the video layers built (default 1) | 1, 2, 7 |
| `z80_cpu.v` | tv80 with retro-z80's own wrapper: cen, early cycle-type outputs | 1, section 2 |
| `cpu_cen.v` | The CPU's clock enable, set by CPUSPEED: a T-state every 5n clocks on slot edges 0 and 5, or every 28; a new speed from the next T1 | 1, section 3; 7, section 6.1 |
| `bus_if.v` | Bus interface: page looked up in T1, memory requests at E + 3, posted writes, boot ROM, NONE and reserved pages, the register page, I/O decode and register bus strobes; the interrupt acknowledge (the vector asked for in the first T1 only, held at di from E + 4, one int_ack) | 1, sections 4–6 and 8.1 |
| `mmu.v` | The MMU: read and write page registers MMUn and MMUnW (byte 1 commits; a read-page commit sets the write page), reset mapping. retro-z80's own | 2, section 9 |
| `timebase.v` | Slot edge counter `sc` | 2, section 3 |
| `dmac.v` | Scheduler: CPU on cycles 0 and 2, never turned away; the layer fetch on cycles 1 and 3 and any cycle left over | 2, section 5 |
| `sram_ctl.v` | SRAM controller, 20 ns cycles | 2, section 8 |
| `bootrom.v` | 32 KB boot ROM in block RAM, writable with SYSCON.ROMWE | 7, section 4 |
| `intc.v` | Interrupt controller: INTCON, INTENA0–2 (set/clear), INTPEND0–2, INTRAW0–2, VECBASE, SOFTINT, INTID, NMICON, NMISTAT; fixed priority by source number, IM 2 vector VECBASE + 2n, NONE (23) when nothing is pending. Sources so far: VBLANK (0), TIMER0–3 (11–14), KEYB (17) and SOFT (18); the NMI is not connected to the Z80 yet | 8 |
| `timers.v` | Timers and watchdog: TIME (32-bit microseconds, power-on only; TIME0 captures), TMR0–TMR3 (CTRL, PRESCALE, RELOAD, COUNT, STAT; SRC 0–3: the prescaled clock, video.v's line and frame ticks, the previous timer; one-shot and repeat; TIMER0–3 requests; DMA start lines, not connected yet), WDCTRL (EN, LOCK), WDTIME, WDKICK; the watchdog's reset sets RESETWHY.WATCHDOG. TIME0 and COUNT0 reads hand the whole value to the bus interface's capture on rb_cdata/rb_cap. bus_if.v keeps the CPU's one tagged capture (spec 3, rule 4) and answers the tagged register's higher bytes from it | 9; 3, rule 4 |
| `sysregs.v` | SYSID, SYSVER, SYSCFG, RESETWHY, SYSCON, SYSRESET, SYSBTN, CPUSPEED | 7, section 11.1 |
| `serial.v`, `fifo8.v` | USB serial (FT232H, 245 FIFO mode) and its FIFOs | 10 |
| `ps2kb.v` | PS/2 keyboard (retro68k's, narrowed): KBCON, KBSTAT, KBDATA (also port `0x62`), KBSEND, KBIRQ, KBIRQEN; filtered receiver into a 16-byte FIFO, sender with the 100 µs request and 15 ms timeout; the KEYB request; every good byte to the mapper. The receiver runs while KBCON.EN or KEYCON.PS2MAP | 12, section 3 |
| `ps2map.v` | PS/2 keys onto the Spectrum matrix: E0 and F0 followed, a held bit for each of the 70 mapped keys, Pause skipped, AA clears; 40 Spectrum keys out | 12, section 8.3 |
| `keys.v` | The membrane: scanned a row every 64 µs through open-drain rows, debounced (two scans agree), KEYMAP0–6; KEYCON (KXMAP, EAR6, PS2MAP); port `0xFE` reads with A15–A8 picking rows (all rows through `0xFE00` and the register page), with the extra keys' pairs (KXMAP) and PS/2 keys (PS2MAP); KEYROW0–7 at register page `0x0100` | 12, sections 5 and 8 |
| `joy.v` | The joysticks through the board's multiplexer (joysel, 5.12 µs a port): Atari sticks from every select-high sample, Mega Drive 3- and 6-button pads in a burst every 2.048 ms; JOY1, JOY2, JOYCON, JOY1X, JOY2X, Kempston port `0x1F` | 12, sections 4 and 8.5 |
| `video.v` | Video: the 576p beam on the 27 MHz pixel clock, VIDCON, VIDSTAT (VBLANK, INVBLANK, OVERRUN0-2), VIDINTEN and the VBLANK request line, PRIO, BGCOLOR, PALIDX, PALDAT and the palettes in the register page (the red byte commits, through the CPU's colour assembly buffer), DMACON, the layers' registers and line setup (bitmap or tile map, SCROLLY, the tile map line), the pixel pipeline (priority with PRI tiles in front, palette), VIDSIZE; port `0xFE` writes set BGCOLOR to a Spectrum colour and show at once, mid-line (a toggle through two flip-flops at 135 MHz; 15�52 ns in simulation). Parameter NL: layers built (1-3; the KS2 builds 1). No sprites, direct colour, LINE or VIDERR yet | 4 |
| `audio.v` | The audio output: the beeper (port `0xFE` bit 4, � a quarter of full scale, both channels) through three second-order sigma-delta modulators at 100 MHz (retro68k's `sigma_delta2`): left, right and mono. Spec 13's sound is to be mixed in here | 7, section 10.2 |
| `bpldma.v` | Layer fetch: just in time through the scheduler, earliest deadline first; the live pointers BPL0PT (with the CPU's capture) and BPLSTRIDE, pointer wrap; tile maps (MAPPT, PATPT, entries one group ahead, XFLIP and YFLIP, PAL and PRI to the pixel side) | 4, section 5 |
| `layer_pix.v` | One layer's pixel side: the shifters, scaling, fine scroll, TRANSP, PALOFS, OVERRUN | 4, sections 4 and 5.1 |
| `platform/sim/oddr.v` | Behavioural DDR output register | – |
| `tmds_encoder.v` | DVI TMDS encoder (8b/10b with DC balance) | – |
| `platform/artix7/ks2_clocks.v` | KS2 clocks: 100 MHz system, 27 and 135 MHz video | – |
| `platform/artix7/hdmi_out.v` | DVI over HDMI: encoders, 10:1 OSERDESE2 serialisers, TMDS_33 pads | – |
| `platform/artix7/oddr.v` | Artix-7 DDR output register, same ports as the simulation version | – |

The CPU runs at every CPUSPEED speed (20 MHz ÷ 1–8, or 3.57 MHz). tv80 needs `TV80_REFRESH` defined for the whole build (`-DTV80_REFRESH`).
