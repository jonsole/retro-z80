# Spec 3: Register map

Status: **draft**

This is the one place that lists every register in the machine: the rules every register follows, every port of the system block, every offset of the custom block, the register page and the interrupt sources. The bit layouts stay in each unit's spec, linked from here, so each is described only once. It follows retro68k's spec 3, narrowed to 8-bit registers.

## 1. Summary

| Item | Value |
|------|-------|
| System block | 256 8-bit I/O ports, decoded on A7–A0 only (A15–A8 ignored, except by port `0xFE` reads), so `OUT (n),A`, `OUT (C),r` with any B, `OTIR` and `INIR` all work. In retro68k's order: interrupts, timers, serial, SD card, keyboard and joysticks, system; then the MMU and the geometry unit (section 4) |
| Custom block | The chipset, as retro68k's custom block at `0xE00000`: 1 KB of byte registers, offsets `0x000`–`0x3FF`, on **16-bit ports**: port = (offset bits 7–0) << 8 \| (`0xC0` + offset bits 9–8). `LD BC,port`, then `OUT (C),A` or `IN A,(C)`; `INC B` steps to the next register (section 5) |
| Register page | MMU page `0x3F8`: the system block at offsets `0x0000`–`0x00FF`, the custom block at `0x1000`–`0x13FF`, the palettes at `0x1800`–`0x1FFF`. Both ways reach the same registers (section 6) |
| Register size | 8 bits. Wider values are consecutive bytes, low byte first; the write of the highest byte commits the whole value (section 3) |
| Copper reach | Writes only, custom block only: MOVE to offsets `0x000`–`0x0EF`, MOVR to `0x000`–`0x0FF`, MOVEL to any offset (section 5.1, spec 6) |
| DMA engine reach | None: it works on SRAM only (spec 14) |
| Unused ports and offsets | Read `0xFF`; writes are ignored. No access ever gives an error |
| Interrupts | 21 source numbers on one /INT line, fixed priority; IM 2 vector = VECBASE + 2 × source (section 7, spec 8) |
| Source file | `fpga/regmap.def`, turned into `hw.inc` (sjasmplus), `hw.h` (C) and `regmap.vh` (Verilog) by `tools/regmap.py` (section 8) |

**Who can reach what:**

| Area | CPU | Copper | DMA engine |
|------|-----|--------|------------|
| System block (ports `0x00`–`0xFF` except `0xC0`–`0xC3`) | Read and write | No | No |
| Custom block (16-bit ports `0xnnC0`–`0xnnC3`) | Read and write | Write: MOVE `0x000`–`0x0EF`, MOVR `0x000`–`0x0FF`, MOVEL all | No |
| Palettes | PALIDX and PALDAT, or the register page | PALIDX and PALDAT | No |
| Register page (MMU page `0x3F8`) | Through any MMU window | No | No |
| SRAM | Through the MMU (spec 2) | Reads its list only | Read and write |

## 2. Comparison with retro68k

| retro68k (spec 3) | retro-z80 | Why |
|-------------------|-----------|-----|
| Registers in the 68000's memory map: custom block at `0xE00000` (64 KB), system block at `0xF00000` (64 KB) | System block on 8-bit I/O ports; custom block on 16-bit I/O ports (1 KB of offsets); both also as memory in the register page | Z80: 64 KB address space, I/O instructions |
| Memory map in this spec (spec 2 folded in) | The memory map is the MMU's, in spec 2, section 6 | Z80: 64 KB address space through the MMU |
| Every register 32 bits, big-endian, in 16-bit halves | Every register 8 bits; wider values are consecutive bytes, low byte first | Z80: 8-bit data bus, little-endian |
| Halves rule: the high half is held, the low half commits | Byte rule: lower bytes are held, the highest byte commits (rule 2) | Z80: `LD (nn),HL`, `LDIR` and natural `OUT` sequences write the low byte first |
| Reading the high half captures the register | Reading the lowest byte captures, for registers the hardware changes by itself (rule 4) | Z80: low byte first |
| Don't use CLR.L on registers | Don't use `PUSH`, `EX (SP),HL` or `LDDR` on registers through the register page (rule 10) | Z80: those write the high byte first |
| The copper follows the same halves rule as the CPU | The copper has its own latch (rule 3) | Z80: a CPU write takes two instructions, so copper MOVEs can come between its bytes |
| Unused addresses read 0; unmapped regions give a bus error | Unused ports and offsets read `0xFF`; nothing gives an error (rule 11) | Z80: no bus error input; the register bus returns `0xFF` when no unit answers (spec 1, section 4.2) |
| SYSCON.PROTECT: user mode cannot reach the registers | No protection | Z80: no user mode |
| Set/clear: bit 15 of a 16-bit half | Bit 7 of a byte (DMACON, INTENA0–2); SPRDMA's SETCLR is in its high byte (rule 12) | 8-bit registers |
| Custom block order: video `0x000`, layers `0x100`, DMA engine `0x300`, audio `0x400`, sprites `0x500`, copper `0x700` | Video `0x000`, layers `0x020`, sprites `0x060`, copper control `0x0E0`, read-only status and sprite globals `0x0F0`; copper state `0x100`, attribute layer `0x120`, DMA engine `0x140`, audio `0x180` | Copper: a one-word MOVE reaches only offsets `0x000`–`0x0EF`, so everything a list changes per line is placed there |
| Layer n at `0x100` + n × `0x80`; three layers | Layer n at `0x020` + n × `0x20`; two layers | Copper reach; bandwidth (spec 4) |
| Sprite n at `0x520` + n × `0x20` | Sprite n at `0x060` + n × `0x10` | Copper reach (spec 5) |
| Palettes memory-mapped at `0xE04000`, 32-bit entries | PALIDX and PALDAT ports, and the register page at `0x1800`; 16-bit entries | 64 KB address space; 12-bit colour (spec 4) |
| DMA descriptor RAM at `0xE06000` | Left out | One channel, no descriptors (spec 14) |
| BPL1PT–BPL7PT, BPL0DAT–BPL7DAT, BPLDMA, PALETTE2, VIDCON.DIRECT | Left out; their offsets and bits are reserved where they would sit | Two chunky layers fed by FIFOs (spec 4) |
| System block: 256 bytes per device | 8 to 48 ports per device, in the same order | 8-bit ports |
| INTPRI0–2 | Left out | Z80: one /INT line, fixed priority (spec 8) |
| TIMEHI, TIMELO: 64-bit time | TIME: 32 bits in 4 ports | 8-bit ports (spec 9) |
| SYSSTAT, BUSERRADDR, BUSERRWHY | Left out | Z80: no halted state, no bus errors (spec 7) |
| SERDROP; SDARG, SDCMD, SDRESP0–3, SDBLKCNT, SDIRQ, SDIRQEN, SDTIMEOUT; KBREPLY, KBMAP0–15 | Left out | No port to spare (spec 10); SD byte master, retro68k's version 1 (spec 11); spec 12 |
| CHDESC, NEXT, CHERR; DMA channels 1–3 | Left out; offsets reserved | One channel (spec 14) |
| Audio registers | Offsets `0x180`–`0x1FF` reserved | Sound is parked (design plan Q1) |
| — | MMU read and write pages, ports `0x80`–`0x9F` | Z80: 64 KB address space (spec 2) |
| — | CPUSPEED, port `0x77` | retro-z80 only (spec 7) |
| — | Geometry unit, ports `0xA0`–`0xBF` | retro-z80 only (design plan branch 10, spec 15) |
| — | Kempston `0x1F`, port `0xFE`, KEYROW0–7, the attribute layer, the NMI monitor ports | Spectrum extras |
| `hw.inc` for vasm; names are byte offsets in a 32-bit layout | `hw.inc` for sjasmplus, `hw.h` for C; custom names are custom offsets, with `_P` port names and `_N` widths in bytes (section 8) | Z80 tools; the copper names offsets, the CPU ports |

## 3. Rules for all registers

1. **Decoding.** A system port is selected by A7–A0 alone, so `OUT (n),A`, `OUT (C),r` with any B, `OTIR` and `INIR` all reach the same port. Only port `0xFE` looks at A15–A8, on reads, as the Spectrum keyboard's row select (spec 12). A custom register is selected by all 16 bits: A7–A2 = `110000`, A1–A0 = offset bits 9–8, A15–A8 = offset bits 7–0 (spec 1, section 6.1). Ports `0xC0`–`0xC3` are never system ports.
2. **Multi-byte values.** A value wider than 8 bits sits at consecutive ports or offsets, **low byte at the lowest**. Writing a lower byte puts it in a latch; writing the **highest byte commits the whole value at once**. At the commit, the lower bytes written since the last commit come from the latch, and any lower byte not written since then keeps the register's current value. So the hardware never sees half a value, and to change only the high byte a program writes just the high byte. Each multi-byte register has its own CPU latch, so an interrupt handler that writes other registers between a program's two `OUT`s disturbs nothing.
3. **The copper has its own latch**, separate from the CPU's, and follows the same rule: lower bytes written since the last commit, the current value for the rest (spec 6, section 4.2). The copper's latch holds the bytes of one register at a time. A copper write never mixes with half a CPU write, nor the other way round.
4. **Reading.** Reading gives the committed value, never the latch. For registers the **hardware changes by itself**, **reading the lowest byte captures the whole value**, and the higher bytes then read the captured copy, so a value read low byte first always matches. Reading a higher byte without first reading the lowest returns the last capture. Each such register has its own capture; an interrupt handler that reads the same register between a program's reads spoils the program's value. The registers that capture:

   | Register | Lowest byte | Spec |
   |----------|-------------|------|
   | BEAMPOS (4 bytes) | Custom `0x0F0` | 4, 3.3 |
   | FRAMECOUNT (2) | Custom `0x0F4` | 4, 3.3 |
   | L0, L1 BPL0PT (3) | Custom `0x034`, `0x054` | 4, 7.3 |
   | SPRxPT (3) | Custom `0x060` + n × `0x10` | 5, 6 |
   | COPPC (3) | Custom `0x100` | 6, 6 |
   | TIME (4) | Port `0x20` | 9, 3 |
   | TMRn_COUNT (2) | Port `0x2D` + n × 8 | 9, 6 |

5. **Status bits.** Sticky flags (W1C) are cleared by writing 1 to them; writing 0 leaves them alone. Live bits in the same register ignore writes. A program clears exactly what it saw by writing back the value it read.
6. **Reserved bits** read 0 and should be written 0.
7. **Index and data ports.** The palettes are reached through PALIDX and PALDAT (spec 4, section 7.5). PALDAT steps the index after each entry, so `OTIR` and `INIR` stream a palette. The register page also shows the palettes directly (section 6).
8. **Bus timing.** A system or custom port access is the Z80's normal 4-T-state I/O cycle (one automatic wait), with no extra waits; a register page access is a normal 3-T-state memory cycle. If the copper writes a register in the same clock, the copper goes first and the CPU's strobe moves one clock later, inside the room its cycle has (spec 1, sections 4.2 and 6). Register accesses use no memory cycle.
9. **I/O and memory are the same registers.** A write through a port and a write through the register page go to the same register and the same CPU latch, so a value can be started through one and committed through the other. Reads have the same side effects both ways.
10. **Write order through memory.** `LD (nn),HL`, `LD (nn),DE/BC/IX/IY`, `LDI` and `LDIR` write the low byte first, so they write multi-byte registers correctly. `PUSH`, `EX (SP),HL` and `LDDR` write the high byte first: don't use them on registers. Read-modify-write instructions (`INC (HL)`, `SET b,(HL)`) are fine on plain registers, but not on FIFO data ports (rule 14).
11. **Unused addresses.** A system port, custom offset or register page offset with no register reads `0xFF` and ignores writes. A write-only register reads `0x00`. A byte that belongs to a register (such as SPRxCTL0) reads its bits, with reserved bits 0.
12. **Set/clear registers** (DMACON, INTENA0–2, SPRDMA): bit 7 of the byte (SPRDMA: of its high byte) is SETCLR. Writing with SETCLR = 1 sets the other bits written as 1; with SETCLR = 0 clears them; bits written as 0 are left alone. Reading gives the enables, with SETCLR reading 0. Never read, change and write back: write only the bits to change.
13. **Strobes** act on any write, whatever the value (COPJMP1, COPJMP2, COPINT, and the strobe bits of SOFTINT, CHCTRL, I2CCMD, SERCON's flush bits). A few act only on a magic value: SYSRESET (`0xA5`) and WDKICK (`0x5A`, where any other value resets).
14. **Reading has no side effects,** except: the FIFO data ports SERDATA and KBDATA, which take a byte; SDDATA with SDCON.AUTO set, which starts an exchange; PALDAT, whose high-byte read steps the index; and the captures of rule 4. All except PALDAT and the captures are system ports, out of the copper's reach (which never reads anyway).
15. **Timing.** A write takes effect as its unit's spec says: some at once, some at the draw beam's pixel (palette, BGCOLOR, PRIO), some at the next line's fetch (layer settings), some at a fixed later line (sprite registers). See spec 4, section 5.7, and spec 5, section 4.4.

**Access column key:** R = read only; W = write only (reads `0x00`); RW = read and write; W1C = sticky flags, cleared by writing 1; R, W1C = live bits and sticky flags mixed; SC = set/clear (rule 12); S = strobe (rule 13); F = FIFO or data port, reading has an effect (rule 14).

### 3.1 Exceptions

Each spec declares where a register departs from the rules above.

| Register | Exception | Why | Spec |
|----------|-----------|-----|------|
| **Set/clear** | | | |
| DMACON (custom `0x00B`) | One byte, SETCLR in bit 7 | retro68k's DMACON in a byte | 4, 7.1 |
| INTENA0–2 (ports `0x01`–`0x03`) | Three set/clear bytes, each written on its own, **no latch** | Each byte holds 7 sources; a program changes one source with one write | 8, 12 |
| SPRDMA (custom `0x0F8`–`0x0F9`) | A 2-byte set/clear value: SPRDMA0 holds the sprite bits (latched); writing SPRDMA1 (SETCLR in bit 7) commits the set or clear | 8 sprites and SETCLR need 9 bits | 5, 6 |
| **Separate bytes, not one value** (no latch, no capture) | | | |
| L0, L1 CTRL0–CTRL2 (`+0x00`–`+0x02`) | Three byte registers with separate fields, each written on its own | A copper list changes PALOFS with one MOVE | 4, 7.3 |
| WINX, WINY (`+0x04`–`+0x0B`) | Each is two 2-byte values (XEND then XSTART; YEND then YSTART), each committed by its own high byte | retro68k's 32-bit registers, half by half | 4, 7.3 |
| INTPEND0–2, INTRAW0–2 (ports `0x04`–`0x09`) | Separate read-only bytes, read live | Same positions as INTENA0–2 | 8, 12 |
| SPRCOLL0–2 (custom `0x0FC`–`0x0FE`) | Separate W1C bytes | Each byte is read and cleared on its own | 5, 6 |
| SERSTAT (ports `0x51`–`0x52`) | Two separate live counts, TXSPACE and RXCOUNT; reading `0x51` does **not** capture `0x52` | Each count is used on its own, for `OTIR` or `INIR` | 10, 7 |
| NMISAVL, NMISAVWL, NMISAVH (ports `0x7D`–`0x7F`) | Separate read-only bytes, set at NMI entry | Nothing changes them while the monitor reads them | 7, 11.3 |
| **Index and data** | | | |
| PALDAT (custom `0x00A`) | One port for 2-byte entries: a low-byte write is held, the high-byte write changes the entry and steps PALIDX; a high-byte read steps it too. Writing PALIDX's high byte resets PALDAT's byte order | Lets `OTIR` and `INIR` stream a palette | 4, 7.5 |
| **Reading has an effect** | | | |
| SERDATA (`0x53`), KBDATA (`0x62`) | Reading takes a byte from the FIFO | Streams, not values | 10, 7; 12, 6 |
| SDDATA (`0x5B`) | Writing starts an SPI exchange; with SDCON.AUTO, reading starts one too | Lets `INIR` read a block | 11, 6 |
| **Commits with an effect** | | | |
| MMUnH (ports `0x81` + 2n) | Committing a read page also sets the window's write page | One write changes a window | 2, 6.2 |
| SPRxPT, SPRxH, SPRxV, SPRxCTL | Committing restarts the sprite | retro68k's restart rule | 5, 4.4 |
| TMRn_COUNT | Committing sets the count at once; RELOAD is used only at the next underflow | retro68k's timers | 9, 4.1 |
| **Writes refused or limited** | | | |
| DMA engine job registers (custom `0x140`–`0x15B`) | Writes are ignored while CHSTAT.BUSY | retro68k's rule | 14, 8.1 |
| WDCTRL, WDTIME (ports `0x48`–`0x4A`) | Read only after WDCTRL.LOCK, until reset | retro68k's watchdog lock | 9, 5 |
| SYSCON.ROMLOCK, SERCON.CTLLOCK | Can be set, not cleared, by software | retro68k's locks | 7, 11.1; 10, 7 |
| **Mixed** | | | |
| CHCTRL (custom `0x164`) | Strobe bits RUN and STOP (read 0) beside the RW bit PAUSE | retro68k's CHCTRL | 14, 8.2 |
| COPSP (custom `0x107`) | Reads the stack depth; any write empties the stack | retro68k's COPSP | 6, 6 |
| **Spectrum extras** | | | |
| Port `0xFE` | Reads decode A15–A8 as keyboard rows; writes set the border (BGCOLOR, a custom register) and the beeper | Spectrum compatibility | 12, 8.1 and 8.3; 4, 8.2 |
| KEMPSTON (port `0x1F`) | A second view of JOY1 | Spectrum compatibility | 12, 8.4 |
| KEYROW0–7 | Register page only (offsets `0x0100`–`0x0107`); no port | A memory read has no A15–A8 for the row select | 12, 8.1 |

## 4. System block

8-bit ports, decoded on A7–A0 (rule 1). The same registers are at register page offset = port number. The copper and the DMA engine cannot reach them.

### 4.1 Layout

| Ports | Contents | Spec |
|-------|----------|------|
| `0x00`–`0x0F` | Interrupt controller | 8 |
| `0x10`–`0x1E` | Reserved | |
| `0x1F` | Kempston joystick (Spectrum extra) | 12 |
| `0x20`–`0x4F` | Time counter, timers and watchdog | 9 |
| `0x50`–`0x57` | USB serial | 10 |
| `0x58`–`0x5F` | SD card | 11 |
| `0x60`–`0x6F` | Keyboard and joysticks | 12 |
| `0x70`–`0x7F` | System: identification, CPU speed, reset, buttons, I2C, NMI monitor | 7 |
| `0x80`–`0x8F` | MMU read pages | 2 |
| `0x90`–`0x9F` | MMU write pages | 2 |
| `0xA0`–`0xBF` | Geometry unit (reserved for spec 15) | 15 |
| `0xC0`–`0xC3` | Custom block, with the offset on A15–A8 (section 5) | 1, 6.1 |
| `0xC4`–`0xFD` | Reserved | |
| `0xFE` | Keyboard rows, border, beeper (Spectrum extra) | 12 |
| `0xFF` | Reserved | |

In the tables below, Width is the value's width in bytes, at consecutive ports from the one given.

### 4.2 Interrupt controller (`0x00`–`0x0F`)

| Port | Name | Width | Access | Meaning | Spec |
|------|------|-------|--------|---------|------|
| `0x00` | INTCON | 1 | RW | MASTER | 8, 12 |
| `0x01` | INTENA0 | 1 | SC | Enables, sources 0–6 | 8, 12 |
| `0x02` | INTENA1 | 1 | SC | Enables, sources 7–13 | 8, 12 |
| `0x03` | INTENA2 | 1 | SC | Enables, sources 14–20 | 8, 12 |
| `0x04`–`0x06` | INTPEND0–2 | 1 each | R | Pending, sources 0–6, 7–13, 14–20 | 8, 12 |
| `0x07`–`0x09` | INTRAW0–2 | 1 each | R | Request lines, as INTPEND | 8, 12 |
| `0x0A` | VECBASE | 1 | RW | Low byte of the IM 2 table | 8, 5 |
| `0x0B` | SOFTINT | 1 | W (S) | SET, CLR of source SOFT | 8, 9 |
| `0x0C` | INTID | 1 | R | Source given at the last acknowledge | 8, 6 |
| `0x0D` | NMICON | 1 | RW | NMI sources allowed | 8, 10 |
| `0x0E` | NMISTAT | 1 | W1C | NMI sources seen | 8, 10 |
| `0x0F` | – | | | Reserved | |

### 4.3 Kempston (`0x1F`), a Spectrum extra

| Port | Name | Width | Access | Meaning | Spec |
|------|------|-------|--------|---------|------|
| `0x1F` | KEMPSTON | 1 | R | Joystick 1, the same value as JOY1; writes ignored | 12, 8.4 |

### 4.4 Time counter, timers and watchdog (`0x20`–`0x4F`)

| Port | Name | Width | Access | Meaning | Spec |
|------|------|-------|--------|---------|------|
| `0x20`–`0x23` | TIME | 4 | R | Microseconds since power-on; reading `0x20` captures all four bytes | 9, 3 |
| `0x24`–`0x27` | – | | | Reserved (a wider TIME, spec 9 T4) | |
| `0x28`–`0x2F` | TMR0 | | | Timer 0 (below) | 9, 6 |
| `0x30`–`0x37` | TMR1 | | | Timer 1 | 9, 6 |
| `0x38`–`0x3F` | TMR2 | | | Timer 2 | 9, 6 |
| `0x40`–`0x47` | TMR3 | | | Timer 3 | 9, 6 |
| `0x48` | WDCTRL | 1 | RW (lockable) | EN, LOCK | 9, 5 |
| `0x49`–`0x4A` | WDTIME | 2 | RW (lockable) | Milliseconds between kicks | 9, 5 |
| `0x4B` | WDKICK | 1 | W (S) | `0x5A` kicks; any other value resets | 9, 5 |
| `0x4C`–`0x4F` | – | | | Reserved | |

Timer n (0–3) at `0x28` + n × 8:

| Offset | Name | Width | Access | Meaning | Spec |
|--------|------|-------|--------|---------|------|
| `+0` | TMR_CTRL | 1 | RW | EN, REPEAT, SRC, IRQ, DMA, DMACH | 9, 6 |
| `+1`–`+2` | TMR_PRESCALE | 2 | RW | SRC 0 divider | 9, 4.2 |
| `+3`–`+4` | TMR_RELOAD | 2 | RW | Loaded at each underflow when repeating | 9, 4.1 |
| `+5`–`+6` | TMR_COUNT | 2 | RW | The count; reading `+5` captures both bytes | 9, 4.1 |
| `+7` | TMR_STAT | 1 | W1C | UNDER | 9, 6 |

### 4.5 USB serial (`0x50`–`0x57`)

| Port | Name | Width | Access | Meaning | Spec |
|------|------|-------|--------|---------|------|
| `0x50` | SERCON | 1 | RW | EN, CTLEN, CTLLOCK, TXDROP; RXFLUSH, TXFLUSH (S) | 10, 7 |
| `0x51` | SERSTAT (TXSPACE) | 1 | R | Room in the transmit FIFO, 0–255 | 10, 7 |
| `0x52` | SERSTAT+1 (RXCOUNT) | 1 | R | Bytes in the receive FIFO, 0–255 | 10, 7 |
| `0x53` | SERDATA | 1 | RW (F) | Receive and transmit FIFO | 10, 7 |
| `0x54` | SERLEVEL | 1 | RW | RXLEVEL, TXLEVEL codes | 10, 7 |
| `0x55` | SERTIME | 1 | RW | Receive timeout, 16 µs steps | 10, 7 |
| `0x56` | SERIRQ | 1 | R, W1C | RXREADY, RXTIMEOUT, TXREADY, TXOVF | 10, 5.4 |
| `0x57` | SERIRQEN | 1 | RW | Enables, as SERIRQ | 10, 5.4 |

### 4.6 SD card (`0x58`–`0x5F`)

| Port | Name | Width | Access | Meaning | Spec |
|------|------|-------|--------|---------|------|
| `0x58`–`0x59` | SDCON | 2 | RW | EN, CS, SEL, AUTO (`0x58`); CLKDIV (`0x59`, commits) | 11, 6 |
| `0x5A` | SDSTAT | 1 | R | BUSY, CARDBUSY | 11, 6 |
| `0x5B` | SDDATA | 1 | RW (F) | SPI byte exchange | 11, 3 |
| `0x5C`–`0x5F` | – | | | Reserved | |

### 4.7 Keyboard and joysticks (`0x60`–`0x6F`)

| Port | Name | Width | Access | Meaning | Spec |
|------|------|-------|--------|---------|------|
| `0x60` | KBCON | 1 | RW | EN | 12, 6 |
| `0x61` | KBSTAT | 1 | R | COUNT, TXBUSY | 12, 6 |
| `0x62` | KBDATA | 1 | R (F) | PS/2 FIFO | 12, 3.2 |
| `0x63` | KBSEND | 1 | W | Byte to the keyboard | 12, 3.4 |
| `0x64` | KBIRQ | 1 | R, W1C | DATA, PARITY, FRAME, OVERFLOW, TIMEOUT | 12, 6 |
| `0x65` | KBIRQEN | 1 | RW | Enables, as KBIRQ | 12, 6 |
| `0x66` | JOY1 | 1 | R | Joystick port 1, Kempston bit order, 1 = pressed | 12, 4.3 |
| `0x67` | JOY2 | 1 | R | Joystick port 2 | 12, 4.3 |
| `0x68` | JOYCON | 1 | RW | MD1, MD2; MDPRES1, MDPRES2 (R) | 12, 4.2 |
| `0x69` | KEYX5 | 1 | R | Membrane column 5 | 12, 5.3 |
| `0x6A` | KEYX6 | 1 | R | Membrane column 6 | 12, 5.3 |
| `0x6B` | KEYCON | 1 | RW | KXMAP, EAR6 (Spectrum extras) | 12, 8.2 |
| `0x6C`–`0x6F` | – | | | Reserved | |

### 4.8 System (`0x70`–`0x7F`)

| Port | Name | Width | Access | Meaning | Spec |
|------|------|-------|--------|---------|------|
| `0x70` | SYSID | 1 | R | `0x5A` ("Z") | 7, 11.1 |
| `0x71` | SYSVER | 1 | R | Build version | 7, 11.1 |
| `0x72` | SYSCFG | 1 | R | CPU, CHIPMB | 7, 11.1 |
| `0x73` | RESETWHY | 1 | R | Cause of the last reset | 7, 3.1 |
| `0x74` | SYSCON | 1 | RW | ROMWE, ROMLOCK | 7, 11.1 |
| `0x75` | SYSRESET | 1 | W (S) | `0xA5` resets | 7, 11.1 |
| `0x76` | SYSBTN | 1 | R | MULTIFACE, DIVMMC | 7, 6 |
| `0x77` | CPUSPEED | 1 | RW | 3.5, 7, 14, 28 MHz | 7, 11.1; 1, 3 |
| `0x78` | I2CCON | 1 | RW | EN, CLKDIV | 7, 7 |
| `0x79` | I2CDATA | 1 | RW | Byte sent or received | 7, 7 |
| `0x7A` | I2CCMD | 1 | W (S) | START, STOP, WRITE, READ, ACK | 7, 7 |
| `0x7B` | I2CSTAT | 1 | R | BUSY, NACK, ARBLOST | 7, 7 |
| `0x7C` | NMICTL | 1 | RW | EN; INNMI (R). Spectrum extra | 7, 11.3 |
| `0x7D` | NMISAVL | 1 | R | Saved window-0 read page, bits 7–0. Spectrum extra | 7, 11.3 |
| `0x7E` | NMISAVWL | 1 | R | Saved window-0 write page, bits 7–0. Spectrum extra | 7, 11.3 |
| `0x7F` | NMISAVH | 1 | R | Bits 9–8 of both saved pages. Spectrum extra | 7, 11.3 |

### 4.9 MMU (`0x80`–`0x9F`)

| Port | Name | Width | Access | Meaning | Spec |
|------|------|-------|--------|---------|------|
| `0x80` + 2n | MMUn (MMUnL, MMUnH) | 2 | RW | Window n's read page, 10 bits; committing also sets its write page | 2, 6.2 |
| `0x90` + 2n | MMUnW (MMUnWL, MMUnWH) | 2 | RW | Window n's write page, 10 bits | 2, 6.2 |

n = 0–7: MMU0 at `0x80`, MMU7 at `0x8E`; MMU0W at `0x90`, MMU7W at `0x9E`.

### 4.10 Geometry unit (`0xA0`–`0xBF`)

Reserved for the geometry unit (design plan branch 10, spec 15, not yet written). Until then these ports read `0xFF`. Its interrupt number, 19 (GEOM), is reserved too (section 7).

### 4.11 Port `0xFE`, a Spectrum extra

| Port | Name | Width | Access | Meaning | Spec |
|------|------|-------|--------|---------|------|
| `0xFE` | – | 1 | RW | Read: membrane rows selected by A15–A8, bits 4–0 active low. Write: bits 2–0 border (sets BGCOLOR), bit 4 beeper | 12, 8.1, 8.3; 4, 8.2; 7, 9.2 |

## 5. Custom block

Byte registers at custom offsets `0x000`–`0x3FF`. The CPU reaches offset k at 16-bit port (k & `0xFF`) << 8 \| (`0xC0` + (k >> 8)), and at register page offset `0x1000` + k. Ports are written below as `0xnnC0`–`0xnnC3`.

### 5.1 Layout and copper reach

| Offsets | Ports | Contents | Copper | Spec |
|---------|-------|----------|--------|------|
| `0x000`–`0x01F` | `0x00C0`–`0x1FC0` | Video global registers, DMACON, palette ports | MOVE | 4, 7.1 |
| `0x020`–`0x03F` | `0x20C0`–`0x3FC0` | Layer 0 | MOVE | 4, 7.3 |
| `0x040`–`0x05F` | `0x40C0`–`0x5FC0` | Layer 1 | MOVE | 4, 7.3 |
| `0x060`–`0x0DF` | `0x60C0`–`0xDFC0` | Sprites 0–7, 16 bytes each | MOVE | 5, 6 |
| `0x0E0`–`0x0EF` | `0xE0C0`–`0xEFC0` | Copper control | MOVE | 6, 6 |
| `0x0F0`–`0x0F7` | `0xF0C0`–`0xF7C0` | Video read-only status | MOVR, MOVEL (writes ignored) | 4, 7.2 |
| `0x0F8`–`0x0FF` | `0xF8C0`–`0xFFC0` | Sprite globals | MOVR, MOVEL | 5, 6 |
| `0x100`–`0x11F` | `0x00C1`–`0x1FC1` | Copper state and storage | MOVEL | 6, 6 |
| `0x120`–`0x13F` | `0x20C1`–`0x3FC1` | Attribute layer (Spectrum extra) | MOVEL | 4, 8.1 |
| `0x140`–`0x17F` | `0x40C1`–`0x7FC1` | DMA engine | MOVEL | 14, 8.1 |
| `0x180`–`0x1FF` | `0x80C1`–`0xFFC1` | Audio, reserved (design plan Q1) | MOVEL (no effect) | 13 |
| `0x200`–`0x3FF` | `0x00C2`–`0xFFC3` | Reserved | MOVEL (no effect) | |

A one-word MOVE names offsets `0x000`–`0x0EF` (its code byte); codes `0xF0`–`0xFF` are the copper's other instructions. MOVR takes its register code from X or from the instruction, so it reaches `0x000`–`0x0FF`. MOVEL (two words) reaches every offset. The copper only writes; read-only registers ignore its writes, as they do the CPU's (spec 6, section 6.6).

### 5.2 Video global registers (`0x000`–`0x01F`)

| Offset | Port | Name | Width | Access | Spec |
|--------|------|------|-------|--------|------|
| `0x000` | `0x00C0` | VIDCON | 1 | RW | 4, 7.1 |
| `0x001` | `0x01C0` | VIDSTAT | 1 | W1C (INVBLANK R) | 4, 3.4 |
| `0x002` | `0x02C0` | VIDINTEN | 1 | RW | 4, 3.4 |
| `0x003` | `0x03C0` | PRIO | 1 | RW | 4, 4.8 |
| `0x004`–`0x005` | `0x04C0`–`0x05C0` | BGCOLOR | 2 | RW | 4, 4.7 |
| `0x006`–`0x007` | `0x06C0`–`0x07C0` | LINECMP | 2 | RW | 4, 3.4 |
| `0x008`–`0x009` | `0x08C0`–`0x09C0` | PALIDX | 2 | RW | 4, 7.5 |
| `0x00A` | `0x0AC0` | PALDAT | 1 | RW (F) | 4, 7.5 |
| `0x00B` | `0x0BC0` | DMACON | 1 | SC | 4, 7.1 |
| `0x00C`–`0x01B` | | – | | Reserved | |
| `0x01C`–`0x01F` | `0x1CC0`–`0x1FC0` | VIDSIZE: HVISIBLE (`0x01C`), VVISIBLE (`0x01E`) | 4 | R | 4, 7.1 |

DMACON's bits: SETCLR (7), DMAEN (6), BPLEN (5), COPEN (4), BLTEN (3), SPREN (2), AUDEN (1, reserved), 0 reserved. These are retro68k's enables in retro68k's order, in one byte (spec 4, section 7.1).

### 5.3 Layers (`0x020`–`0x05F`)

Layer n (0, 1) at `0x020` + n × `0x20`: L0 at `0x020`, ports `0x20C0`–`0x3FC0`; L1 at `0x040`, ports `0x40C0`–`0x5FC0`.

| Offset | Name | Width | Access | Spec |
|--------|------|-------|--------|------|
| `+0x00` | CTRL0 | 1 | RW | 4, 7.4 |
| `+0x01` | CTRL1 | 1 | RW | 4, 7.4 |
| `+0x02` | CTRL2 | 1 | RW | 4, 7.4 |
| `+0x03` | – | | Reserved | |
| `+0x04`–`+0x05` | WINX (XEND) | 2 | RW | 4, 4.3 |
| `+0x06`–`+0x07` | WINX (XSTART) | 2 | RW | 4, 4.3 |
| `+0x08`–`+0x09` | WINY (YEND) | 2 | RW | 4, 4.3 |
| `+0x0A`–`+0x0B` | WINY (YSTART) | 2 | RW | 4, 4.3 |
| `+0x0C`–`+0x0D` | SCROLLX | 2 | RW | 4, 4.4, 4.5 |
| `+0x0E`–`+0x0F` | SCROLLY | 2 | RW | 4, 4.5 |
| `+0x10`–`+0x11` | BPLSTRIDE | 2 | RW | 4, 4.4 |
| `+0x12`–`+0x13` | – | | Reserved (retro68k's BPLDMA) | |
| `+0x14`–`+0x16` | BPL0PT | 3 | RW; reading `+0x14` captures | 4, 4.4 |
| `+0x17` | – | | Reserved | |
| `+0x18`–`+0x1A` | MAPPT | 3 | RW | 4, 4.5 |
| `+0x1B` | – | | Reserved | |
| `+0x1C`–`+0x1E` | PATPT | 3 | RW | 4, 4.5 |
| `+0x1F` | – | | Reserved | |

### 5.4 Sprites (`0x060`–`0x0DF`)

Sprite n (0–7) at `0x060` + n × `0x10`, ports `0x60C0` + n × `0x1000`.

| Offset | Name | Width | Access | Spec |
|--------|------|-------|--------|------|
| `+0x0`–`+0x2` | SPRxPT | 3 | RW; reading `+0x0` captures; commit restarts the sprite | 5, 6 |
| `+0x3` | SPRxDAT | 1 | W | 5, 4.5 |
| `+0x4`–`+0x7` | SPRxH (HSTART, HSTOP) | 4 | RW; commit restarts | 5, 3.1 |
| `+0x8`–`+0xB` | SPRxV (VSTART, VSTOP) | 4 | RW; commit restarts | 5, 3.1 |
| `+0xC`–`+0xF` | SPRxCTL | 4 | RW (byte 0 reserved, reads 0); commit restarts | 5, 3.3 |

### 5.5 Copper control (`0x0E0`–`0x0EF`)

| Offset | Port | Name | Width | Access | Spec |
|--------|------|------|-------|--------|------|
| `0x0E0` | `0xE0C0` | COPCON | 1 | RW | 6, 6 |
| `0x0E1`–`0x0E3` | `0xE1C0`–`0xE3C0` | COP1LC | 3 | RW | 6, 6 |
| `0x0E4`–`0x0E6` | `0xE4C0`–`0xE6C0` | COP2LC | 3 | RW | 6, 6 |
| `0x0E7` | `0xE7C0` | COPJMP1 | 1 | W (S) | 6, 6 |
| `0x0E8` | `0xE8C0` | COPJMP2 | 1 | W (S) | 6, 6 |
| `0x0E9` | `0xE9C0` | COPINT | 1 | W (S) | 6, 6.4 |
| `0x0EA`–`0x0EF` | | – | | Reserved | |

### 5.6 Video status and sprite globals (`0x0F0`–`0x0FF`)

| Offset | Port | Name | Width | Access | Spec |
|--------|------|------|-------|--------|------|
| `0x0F0`–`0x0F3` | `0xF0C0`–`0xF3C0` | BEAMPOS: HPIXEL (`0x0F0`), VLINE (`0x0F2`) | 4 | R; reading `0x0F0` captures | 4, 3.3 |
| `0x0F4`–`0x0F5` | `0xF4C0`–`0xF5C0` | FRAMECOUNT | 2 | R; reading `0x0F4` captures | 4, 3.3 |
| `0x0F6`–`0x0F7` | | – | | Reserved | |
| `0x0F8`–`0x0F9` | `0xF8C0`–`0xF9C0` | SPRDMA (SPRDMA0, SPRDMA1) | 2 | SC | 5, 6 |
| `0x0FA`–`0x0FB` | | – | | Reserved | |
| `0x0FC`–`0x0FE` | `0xFCC0`–`0xFEC0` | SPRCOLL0–2 | 1 each | R, W1C | 5, 3.5 |
| `0x0FF` | | – | | Reserved (retro68k's L2 collisions) | |

### 5.7 Copper state and storage (`0x100`–`0x11F`)

| Offset | Port | Name | Width | Access | Spec |
|--------|------|------|-------|--------|------|
| `0x100`–`0x102` | `0x00C1`–`0x02C1` | COPPC | 3 | R; reading `0x100` captures | 6, 6 |
| `0x103` | `0x03C1` | COPSTAT | 1 | R, W1C | 6, 6.1 |
| `0x104` | `0x04C1` | COPX | 1 | RW | 6, 4.6 |
| `0x105` | `0x05C1` | COPY | 1 | RW | 6, 4.6 |
| `0x106` | `0x06C1` | COPFLAGS | 1 | RW | 6, 4.6 |
| `0x107` | `0x07C1` | COPSP | 1 | RW (any write empties the stack) | 6, 4.8 |
| `0x108`–`0x10F` | `0x08C1`–`0x0FC1` | COPR0–COPR7 | 1 each | RW | 6, 4.6 |
| `0x110`–`0x11F` | | – | | Reserved | |

### 5.8 Attribute layer (`0x120`–`0x13F`), a Spectrum extra

| Offset | Port | Name | Width | Access | Spec |
|--------|------|------|-------|--------|------|
| `0x120` | `0x20C1` | ATCTL | 1 | RW (PHASE R) | 4, 8.1 |
| `0x121`–`0x123` | `0x21C1`–`0x23C1` | ATADDR | 3 | RW | 4, 8.1 |
| `0x124` | `0x24C1` | ATSTRIDE | 1 | RW | 4, 8.1 |
| `0x125` | `0x25C1` | ATSCROLL | 1 | RW | 4, 8.1 |
| `0x126`–`0x13F` | | – | | Reserved | |

### 5.9 DMA engine (`0x140`–`0x17F`)

Channel 0 (the only one) at `0x140`; each register at `0x140` + its retro68k channel offset.

| Offset | Port | Name | Width | Access | Spec |
|--------|------|------|-------|--------|------|
| `0x140`–`0x141` | `0x40C1`–`0x41C1` | CTRL | 2 | RW | 14, 3.1 |
| `0x142`–`0x143` | | – | | Reserved | |
| `0x144`–`0x146` | `0x44C1`–`0x46C1` | SRC | 3 | RW | 14, 8.1 |
| `0x147` | | – | | Reserved | |
| `0x148`–`0x14A` | `0x48C1`–`0x4AC1` | DST | 3 | RW | 14, 8.1 |
| `0x14B` | | – | | Reserved | |
| `0x14C`–`0x14E` | `0x4CC1`–`0x4EC1` | WIDTH | 3 | RW | 14, 8.1 |
| `0x14F` | | – | | Reserved | |
| `0x150`–`0x151` | `0x50C1`–`0x51C1` | HEIGHT | 2 | RW | 14, 8.1 |
| `0x152`–`0x153` | | – | | Reserved (retro68k's SRCBIT, DSTBIT) | |
| `0x154`–`0x155` | `0x54C1`–`0x55C1` | DSTSTRIDE | 2 | RW | 14, 8.1 |
| `0x156`–`0x157` | `0x56C1`–`0x57C1` | SRCSTRIDE | 2 | RW | 14, 8.1 |
| `0x158`–`0x15B` | `0x58C1`–`0x5BC1` | VALUE | 4 | RW | 14, 3.2 |
| `0x15C`–`0x163` | | – | | Reserved (retro68k's NEXT, CHDESC) | |
| `0x164` | `0x64C1` | CHCTRL | 1 | S (RUN, STOP), RW (PAUSE) | 14, 8.2 |
| `0x165`–`0x167` | | – | | Reserved | |
| `0x168` | `0x68C1` | CHSTAT | 1 | R, W1C | 14, 8.3 |
| `0x169`–`0x16F` | | – | | Reserved (`0x16C`: retro68k's CHERR) | |
| `0x170` | `0x70C1` | DMXINT | 1 | W1C | 14, 8.5 |
| `0x171`–`0x173` | | – | | Reserved | |
| `0x174` | `0x74C1` | DMXINTEN | 1 | RW | 14, 8.5 |
| `0x175`–`0x17F` | | – | | Reserved (a later drawing job, spec 14 section 10) | |

### 5.10 Audio (`0x180`–`0x1FF`)

Reserved for sound (spec 13, design plan Q1), under retro68k's names when it is specified. Reads give `0xFF`; writes, including the copper's, do nothing.

## 6. The register page

MMU page `0x3F8` (REGS) shows the registers as memory, in any window, for reads, writes or both (spec 2, sections 6.5 and 6.6).

| Offset | Contents | Spec |
|--------|----------|------|
| `0x0000`–`0x00FF` | The system block: offset = port number, with the same values, latches and side effects as through I/O. Offsets `0x00C0`–`0x00C3` are reserved. Offset `0x00FE` reads the keyboard with all rows selected | Section 4 |
| `0x0100`–`0x0107` | KEYROW0–7: membrane row r alone, in port `0xFE`'s read format; read only (Spectrum extra) | 12, 8.1 |
| `0x0108`–`0x0FFF` | Reserved | |
| `0x1000`–`0x13FF` | The custom block: custom offset k at `0x1000` + k | Section 5 |
| `0x1400`–`0x17FF` | Reserved | |
| `0x1800`–`0x19FF` | PALETTE0: entry i at `0x1800` + 2i | 4, 7.5 |
| `0x1A00`–`0x1BFF` | PALETTE1 | 4, 7.5 |
| `0x1C00`–`0x1DFF` | Reserved (retro68k's PALETTE2) | 4, 7.5 |
| `0x1E00`–`0x1FFF` | SPRPALETTE | 4, 7.5 |

- A palette entry is a 2-byte value (`0x0RGB`, low byte green and blue): its even byte is held and its odd byte commits the entry, as rule 2. This path does not use or change PALIDX. `LD (nn),HL` writes one entry; `LDIR` copies a palette.
- Reserved offsets read `0xFF` and ignore writes.
- Opcode fetches from the register page read `0xFF` (`RST 38h`) and have no side effect (spec 1, section 5.6).
- Register page accesses use no SRAM cycle.
- A window can read ROM or RAM while its writes go to the register page, so `LD (IX+d),A` stores to registers while code and tables are read from the same addresses (spec 2, section 6.6).

## 7. Interrupt sources

From spec 8, section 4. The number is the fixed priority (lower first) and the IM 2 table entry: vector = VECBASE + 2 × number. Source n's enable, pending and raw bits are in byte n div 7 (INTENA0–2, INTPEND0–2, INTRAW0–2), bit n mod 7.

| # | Name | From | Request while | Vector |
|---|------|------|---------------|--------|
| 0 | VBLANK | Video (spec 4) | VIDSTAT.VBLANK and VIDINTEN.VBLANK | VECBASE + 0 |
| 1 | LINE | Video (spec 4) | VIDSTAT.LINE and VIDINTEN.LINE | + 2 |
| 2 | COPPER | Copper (spec 6) | COPSTAT.IRQ and COPCON.IRQEN | + 4 |
| 3 | VIDERR | Video and sprites (specs 4, 5) | VIDSTAT OVERRUN0, OVERRUN1, OVERRUNA, SPRUNDER and their VIDINTEN bits | + 6 |
| 4 | DMA0 | DMA engine (spec 14) | DMXINT.CH0 and DMXINTEN.CH0 | + 8 |
| 5–7 | – | Reserved (retro68k's DMA1–DMA3) | – | + 10 … + 14 |
| 8 | – | Not used, as in retro68k | – | + 16 |
| 9 | AUDIO | Reserved for sound (spec 13) | – | + 18 |
| 10 | – | Not used, as in retro68k | – | + 20 |
| 11–14 | TIMER0–TIMER3 | Timers (spec 9) | TMRn_STAT.UNDER and TMRn_CTRL.IRQ | + 22 … + 28 |
| 15 | SERIAL | USB serial (spec 10) | SERIRQ and SERIRQEN | + 30 |
| 16 | SD | Not used in version 1: the SD controller is polled (spec 11), as in retro68k's version 1 | – | + 32 |
| 17 | KEYB | PS/2 keyboard (spec 12) | KBIRQ and KBIRQEN | + 34 |
| 18 | SOFT | Software (spec 8) | SOFTINT.SET until SOFTINT.CLR | + 36 |
| 19 | GEOM | Reserved for the geometry unit (spec 15) | – | + 38 |
| 20 | – | Reserved | – | + 40 |
| 21–22 | – | Do not exist (no enable bits) | – | + 42, + 44 |
| 23 | NONE | Spurious acknowledge, not a source | – | + 46 |

**NMI** (to `0x0066`, not maskable): the Multiface button and the USB BREAK command, allowed by NMICON and reported in NMISTAT (spec 8, section 10). With NMICTL.EN the NMI also pages the monitor into window 0 (a Spectrum extra, spec 7, section 9.1).

## 8. One source for the numbers

As in retro68k, every register, field, layout and named number is kept in **`fpga/regmap.def`**, a short text file. **`tools/regmap.py`** (standard Python, nothing to install) reads it.

**The file.** One item per line, as retro68k's, with the register's **width in bytes** added:

```
block  NAME BASE SIZE "text"                   the system block, the custom block, the register page
reg    OFFSET NAME WIDTH ACCESS SPEC [fields]  a register of WIDTH bytes (1-4) in the current block
regs   NAME COUNT OFFSET WIDTH ACCESS SPEC     NAME0..NAME(COUNT-1), WIDTH bytes apart
array  NAME COUNT OFFSET STRIDE SPEC ... end   a repeated group (L, SPR, TMR, DMX, MMU)
area   NAME OFFSET SIZE ACCESS SPEC            a table in the register page (palettes, KEYROW)
const  NAME VALUE ["text"]                     a named number
```

Access is R, W, RW, W1C, RW1C (mixed), SC (set/clear) or S (strobe), with flags: CAP (reading the lowest byte captures, rule 4), SEP (separate bytes, no latch), PAIR (two 2-byte values, as WINX), F (reading has an effect), LOCK (lockable). Fields are `FIELD=BIT` or `FIELD=HIGH:LOW`, numbered in the whole value (bit 8 is bit 0 of the second byte). For example:

```
block CUSTOM 0x000 0x400 "Custom block: port = (offset & 0xFF) << 8 | 0xC0 | offset >> 8"
reg 0x004 BGCOLOR 2 RW     4/4.7  RGB=11:0
reg 0x00B DMACON  1 SC     4/7.1  AUDEN=1 SPREN=2 BLTEN=3 COPEN=4 BPLEN=5 DMAEN=6 SETCLR=7
array SPR 8 0x060 0x10 5/6
  reg 0x0 PT  3 RW,CAP 5/6    ADDR=21:1
  reg 0xC CTL 4 RW     5/3.3  BPP=13:12 HMAG=17:16 VMAG=19:18 DEPTH=21:20 PAL=27:24
end
block SYSTEM 0x00 0x100 "System block: 8-bit ports, A7-A0"
reg 0x20 TIME    4 R,CAP 9/3
reg 0x51 SERSTAT 2 R,SEP 10/7 TXSPACE=7:0 RXCOUNT=15:8
```

**Checks.** The generator checks: every register inside its block, at consecutive addresses, with no overlap; widths of 1–4 bytes; fields inside the width and not overlapping; no name generated twice; system registers not at ports `0xC0`–`0xC3`; and every register against the tables in this spec (`--verify`), so the two can't disagree.

**Generated files:**

- `firmware/include/hw.inc` for sjasmplus, `firmware/include/hw.h` for C (z88dk), and `fpga/rtl/regmap.vh` for the Verilog decoders.
- **Names.** A system register's name is its **port** (which is also its register page offset): `out (NMISTAT),a`. A custom register's name is its **custom offset**, which copper lists use (`CMOVE BGCOLOR,0`) and the register page uses (`REGS + 0x1000 + BGCOLOR`); `name_P` is its **16-bit port** for the CPU (`ld bc,BGCOLOR_P`). Every register has `name_N`, its width in bytes (spec 6's `CMOVEN` uses it). Fields give `name_FIELD_B` (first bit), `name_FIELD_W` (width in bits) and `name_FIELD_M` (mask), as retro68k's.
- **Arrays** give the bases (`L0`, `L1`; `SPR0` … `SPR7`; `TMR0` … `TMR3`; `DMX0`), `NAME_NUM` and `NAME_SPAN`, the offsets within the group (`L_BPL0PT`, `SPR_H`, `TMR_COUNT`, `DMX_CTRL`), and ready-added names (`L1_BPL0PT`, `L1_BPL0PT_P`, `TMR2_COUNT`, `DMX0_CHCTRL_P`).
- `CPORT(offset)` gives the port of a computed custom offset (`CPORT(SPR0+SPR_H)`), in `hw.h` and in `hw.inc` (open point R1).
- `regmap.vh` also gives the copper's table of register widths and highest bytes (spec 6, section 4.2), and the capture and set/clear decodes.

GitHub runs `python3 tools/regmap.py --verify` on every push, which fails if this spec, the `.def` file and the generated files don't all agree. `tools/README.md` explains the file format and the generated names.

## 9. Test plan

1. `regmap.py` builds from `regmap.def`, its checks pass, and `--verify` agrees with this spec, in CI.
2. **Decoding:** in simulation, every system port answers at its port and nowhere else, whatever A15–A8 (except port `0xFE` reads); every custom offset answers at its 16-bit port and nowhere else; ports `0xC0`–`0xC3` with every A15–A8 reach the custom block, never a system port; every unused port, offset and register page offset reads `0xFF`; write-only registers read `0x00`.
3. **Reset values:** every register reads its spec's reset value after reset.
4. **Multi-byte writes:** for each multi-byte register, writing a lower byte alone changes nothing; writing the highest byte commits the bytes written since the last commit and keeps the current value of the others; an interrupt-style write to another register between the two bytes changes nothing; a copper write between the CPU's bytes disturbs neither (the copper latch).
5. **Captures:** for each register of rule 4, the value read low byte first while the register changes is always a value it really had; higher bytes read alone return the last capture; SERSTAT's two bytes read live.
6. **Exceptions:** each row of section 3.1 behaves as its spec says: set/clear bytes, unlatched groups, PALDAT stepping, FIFO reads taking exactly one byte through a port and through the register page, MMUnH setting the write page, locks.
7. **Copper reach:** MOVE reaches `0x000`–`0x0EF`, MOVR `0x000`–`0x0FF`, MOVEL `0x000`–`0x3FF`; nothing the copper does reaches a system port.
8. **Register page:** each system port at its offset, each custom register at `0x1000` + offset, with the same values and side effects; a 2-byte value started through a port commits through memory and the other way round; `LD (nn),HL` commits a 2-byte register; the palettes read and write at their offsets without touching PALIDX; KEYROW0–7 match port `0xFE`; opcode fetches read `0xFF`.
9. **Generated files:** the sjasmplus, C and Verilog files agree with this spec; `CPORT` gives the same ports as the `_P` names.

## 10. Open points

| # | Item |
|---|------|
| R1 | `CPORT(offset)` as a function-like define in sjasmplus (spec 5 uses it): to be checked. If sjasmplus cannot, `hw.inc` gives only the `_P` names and computed ports are written out as `((off & 0xFF) << 8) \| 0xC0 \| (off >> 8)` |
| R2 | Bit layouts in each spec should be checked against the rules of section 3 once more when the generator is written (as retro68k's R2) |
| R3 | Closed: the CPU and the copper follow the same commit rule (rules 2 and 3): bytes written since the last commit, the current value for the rest (spec 6, C6). Each multi-byte register has its own CPU latch, so interrupt handlers do not disturb a program's half-written value; the cost is about 170 latched bytes and their written flags |
| R4 | Unused addresses read `0xFF`, not 0 as in retro68k. Bytes that belong to a register (SPRxCTL0) read 0 in their reserved bits. The rule follows spec 1's register bus, where no answer gives `0xFF` |
| R5 | Free space. System ports: `0x10`–`0x1E`, `0x24`–`0x27`, `0x4C`–`0x4F`, `0x5C`–`0x5F`, `0x6C`–`0x6F`, `0xC4`–`0xFD`, `0xFF`. The system range `0x70`–`0x7F` is full (spec 7, SY11). Custom block: `0x200`–`0x3FF`, and gaps inside each block. A block that needs more than its range says so in its own spec (spec 14, D5) and takes it from the free space, not from another block |
| R6 | The audio block (`0x180`–`0x1FF`, 128 bytes) is sized before sound is specified (spec 13, design plan Q1); if it needs more, it takes it from `0x200`–`0x3FF` |
| R7 | The geometry unit's 32 ports (`0xA0`–`0xBF`) and interrupt 19 are reserved for spec 15; its register page view (memory access with LDI and `LD (IX+d)`, design plan branch 10) is offsets `0x00A0`–`0x00BF` like any system port |
| R8 | The palette write delay after a copper WAIT (spec 6, C9) should be listed here once known (as retro68k's R3) |
| R9 | COP2LC changes by itself only at a frame restart with COPCON.RESUME (spec 6, section 6.5), so it has no capture; a CPU that reads it while a background list runs may see a mixed value. Read it while the copper runs the idle list |
