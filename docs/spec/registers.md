# Spec 3: Register map

Status: **draft**

This is the one place that lists every register in the machine: the rules every register follows, the port form, every register of the system page, every offset of the custom block, the register page, the register bus and the interrupt sources. The bit layouts stay in each unit's spec, linked from here, so each is described only once. It follows retro68k's spec 3, narrowed to 8-bit registers. Where this spec and a unit's spec disagree on a bit, the unit's spec wins and this spec is corrected.

## 1. Summary

| Item | Value |
|------|-------|
| Register size | 8 bits. Wider values are consecutive bytes, low byte first. Every byte is written straight through, with no latch, except the MMU and interrupt pages and the colours (rule 2) |
| Ports | Every I/O port is **register (high byte) : page (low byte)**: port = register × 256 + page. Page `0x00` is the system page; registers `0x40`–`0xFF` of page `0x01` are the interrupt pages; page `0x02` is the debug unit; pages `0x10`–`0x13` are the custom block; every other page is reserved (section 4.1) |
| Low-byte-only ports | `0x1F` (Kempston), `0x53` (SERDATA), `0x5B` (SDDATA), `0x62` (KBDATA) and `0xFE` (Spectrum port) answer whatever the high byte holds, so `IN A,(n)`, `OUT (n),A`, `INIR` and `OTIR` work on them. Each is also a register of page `0x00` (section 4.1) |
| System page | Page `0x00`: interrupts, the key map, timers, serial, SD card, input, system, the MMU and the geometry unit, in retro68k's order. SYSID is port `0x7000` (section 4) |
| Custom block | The chipset, as retro68k's custom block: 1 KB of byte registers, offsets `0x000`–`0x3FF`. Custom offset k is port (k bits 7–0) × 256 + `0x10` + (k bits 9–8) (section 5) |
| Register page | MMU page `0x3F8`, in any window: page p, register r at offset p × 256 + r, the port with its bytes swapped. The system page at `0x0000`, KEYROW0–7 at `0x0100`, the interrupt pages at `0x0140`–`0x01FF`, the debug unit at `0x0200`–`0x023C`, the custom block at `0x1000`, the palettes at `0x1400`–`0x1FFF` (section 6) |
| Register bus | 8-bit, one clock per access. Masters in order: the copper, the CPU, the sprite sequencer, the DMA engine (section 3.2) |
| Copper reach | Writes only, custom block only: MOVE `0x000`–`0x0EF`, MOVR `0x000`–`0x0FF`, MOVEF `0x000`–`0x3FF` (section 5.1, spec 6) |
| DMA engine reach | The custom block and the palettes (read and write), the boot ROM (read), and SERDATA and SDDATA through its port jobs; not the system page (spec 14) |
| Unused ports, pages and offsets | Read `0xFF`; writes are ignored. No access ever gives an error (rule 11) |
| Interrupts | 21 source numbers on one /INT line, fixed priority; IM 2 vector = VECBASE + 2 × source (section 7, spec 8) |
| Source file | `fpga/regmap.def`, turned into `hw.inc` (sjasmplus), `hw.h` (C) and `regmap.vh` (Verilog) by `tools/regmap.py` (section 8) |

**Who can reach what:**

| Area | CPU | Copper | DMA engine |
|------|-----|--------|------------|
| System page (page `0x00`; register page `0x0000`–`0x00FF`) | Read and write | No | No: a job that names it stops with an error |
| Low-byte-only ports | Read and write | No | SERDATA and SDDATA, through its port jobs (ports 1 and 0) |
| Custom block (pages `0x10`–`0x13`; register page `0x1000`–`0x13FF`) | Read and write | Write: MOVE `0x000`–`0x0EF`, MOVR `0x000`–`0x0FF`, MOVEF all | Read; write with COPY and FILL |
| Palettes | PALIDX and PALDAT, or the register page | PALIDX and PALDAT | Read and write, as laid out in the register page |
| KEYROW0–7 (register page `0x0100`–`0x0107`) | Read, through the register page | No | No |
| Interrupt pages (page `0x01`, registers `0x40`–`0xFF`; register page `0x0140`–`0x01FF`) | Read and write | No | No: a job that names them stops with an error |
| Debug unit (page `0x02`; register page `0x0200`–`0x023C`) | Read and write | No | No: a job that names it stops with an error |
| Boot ROM (MMU pages `0x3FC`–`0x3FF`) | Read; write with SYSCON.ROMWE | No | Read |
| SRAM | Through the MMU (spec 2) | Reads its list only | Read and write |

The sprite sequencer (spec 17, a retro-z80 extra) reads its list from SRAM and writes only the registers of the sprites SEQMASK gives it (custom `0x010`–`0x08F`); it reads no registers.

## 2. Comparison with retro68k

| retro68k (spec 3) | retro-z80 | Why |
|-------------------|-----------|-----|
| Registers in the 68000's memory map: custom block at `0xE00000`, system block at `0xF00000` | I/O ports in register:page form; both blocks also as memory in the register page, an MMU page any window can map | Z80: 64 KB address space, I/O instructions |
| Memory map in this spec (spec 2 folded in) | The memory map is the MMU's, in spec 2 | Z80: 64 KB address space through the MMU |
| Every register 32 bits, big-endian, in 16-bit halves | Every register 8 bits; wider values are consecutive bytes, low byte first | Z80: 8-bit data bus, little-endian |
| Halves rule: the high half is held, the low half commits | No latches: every byte is written straight through, in any order (rule 2). Only the MMU pages (byte 1 commits) and the colours (the red byte commits) wait for a last byte | Cost: latches for every wide register would take about 1,000–2,000 LUTs. An 8-bit CPU writes a wide value in several instructions anyway, so wide display registers are changed in the vertical blank or by the copper, as on the Amiga |
| Reading the high half captures the register, in one tagged capture (`bus_if.v`) | Reading the low byte captures, for registers the hardware changes by itself; one tagged capture per master, as retro68k (rule 4) | Z80: low byte first |
| Don't use CLR.L on registers | Any instruction can write registers, `PUSH`, `EX (SP),HL` and `LDDR` included; the MMU pages and the colours need their last byte last (rule 10) | No latches |
| The copper has its own latch for a held high half | The copper writes each byte directly; no latch (rule 3) | No latches |
| DMA jobs write 32 bits at once | DMA jobs write bytes, each directly (rule 3) | 8-bit registers |
| Register bus: the CPU, then the copper, then the DMA engine | The copper, then the CPU, then the DMA engine (section 3.2) | The Z80's cycles have room for a clock's delay, and the copper's writes then always land on their pixel (spec 1) |
| Unused addresses read 0; unmapped regions give a bus error | Unused ports, pages and offsets read `0xFF`; nothing gives an error (rule 11) | Z80: no bus error input; the register bus returns `0xFF` when no unit answers (spec 1, section 4.2) |
| SYSCON.PROTECT: user mode cannot reach the registers | No protection | Z80: no user mode |
| Set/clear: bit 15 of a 16-bit half | Bit 7 of a byte (DMACON, INTENA0–2); SPRDMA's SETCLR is in its second byte (rule 12) | 8-bit registers |
| Custom block order: video `0x000`, layers `0x100`, DMA engine `0x300`, audio `0x400`, sprites `0x500`, copper `0x700` | Video globals `0x000`, sprites `0x010`, layers `0x090`, video read-only `0x0F0`; copper `0x100`, sprite globals `0x120`, attribute layer `0x130`, DMA engine `0x140`, audio `0x240`, sprite sequencer `0x300` | A one-word copper MOVE reaches offsets `0x000`–`0x0EF` only, so everything a list changes per line sits there; the custom block is 1 KB |
| Layer n at `0x100` + n × `0x80` | Layer n at `0x090` + n × `0x20`; three layers in both | Copper reach (spec 4) |
| Sprite n at `0x520` + n × `0x20` | Sprite n at `0x010` + n × `0x10` | Copper reach; no SPRxDAT (spec 5) |
| Palettes memory-mapped at `0xE04000`, 4-byte entries `0x00RRGGBB` | PALIDX and PALDAT; and the register page at `0x1400`–`0x1FFF`, 3-byte entries (blue, green, red) | 64 KB address space; four 4-byte palettes would not fit the 8 KB register page beside the custom block (spec 2, section 10.2) |
| DMA descriptor RAM at `0xE06000` | None in version 1 | Block RAM (spec 14, D5) |
| BPL1PT–BPL7PT, BPL0DAT–BPL7DAT, BPLDMA, CTRL.PLANAR and PLANES | Left out; their offsets and bits are reserved where they would sit | Chunky layers only; the data registers are not visible (spec 4) |
| DMA engine at `0x300`, DMXINT and DMXINTEN at `0x3F0`, `0x3F4` | At `0x140`; DMXINT and DMXINTEN at `0x230`, `0x234`, the same place after channel 3 | Custom block layout (spec 14) |
| System block: 256 bytes per device | 8 to 48 registers per device in page `0x00`, in the same order | 8-bit registers |
| INTPRI0–2 | Left out | Z80: one /INT line, fixed priority (spec 8) |
| TIMEHI, TIMELO: 64-bit time | TIME: 32 bits in 4 registers | 8-bit registers (spec 9) |
| SYSSTAT, BUSERRADDR, BUSERRWHY | Left out | Z80: no halted state, no bus errors (spec 7) |
| Boot ROM at `0xF80000` | Boot ROM in MMU pages `0x3FC`–`0x3FF`; the DMA engine reads it at physical `0x7F8000` | MMU (spec 2, spec 14) |
| Audio registers at `0x400` | Offsets `0x240`–`0x2FF` reserved | Sound is parked (design plan Q1) |
| — | MMU read and write pages, registers `0x80`–`0x9F` | Z80: 64 KB address space (spec 2) |
| — | CPUSPEED, register `0x77` | retro-z80 only (spec 7) |
| — | Geometry unit, registers `0xA0`–`0xBF` | retro-z80 only (design plan branch 10, spec 15) |
| — | Sprite sequencer, custom `0x300`–`0x30F`, a fourth register bus master | retro-z80 extra (design plan branch 14, spec 17); on retro68k's "later" list |
| — | KEYMAP0–6, JOY1, JOY2, JOYCON, JOY1X, JOY2X | In version 1 here; a later version in retro68k (spec 12) |
| — | Interrupt pages and stack capture: I/O page `0x01`, registers `0x40`–`0xFF` (section 4.13) | retro-z80 extra (design plan branch 17, spec 2): retro68k has no MMU |
| — | Kempston `0x1F`, port `0xFE`, KEYCON, KEYROW0–7, the attribute layer, the NMI monitor paging (now the NMI set of the interrupt pages) | Spectrum extras |
| `hw.inc` for vasm; names are byte offsets in a 32-bit layout | `hw.inc` for sjasmplus, `hw.h` for C; a system name is its register number, a custom name its custom offset; `_P` names are ports, `_N` widths in bytes (section 8) | Z80 tools; the copper names offsets, the CPU's `OUT (C),r` ports |

## 3. Rules for all registers

1. **Decoding.** Every port is register (A15–A8) : page (A7–A0). A port whose low byte is one of the five low-byte-only ports (`0x1F`, `0x53`, `0x5B`, `0x62`, `0xFE`) goes to that register of page `0x00` whatever A15–A8 hold; only port `0xFE` looks at A15–A8, on reads, to pick keyboard rows (spec 12). Otherwise page `0x00` is the system page, registers `0x40`–`0xFF` of page `0x01` are the interrupt pages (registers `0x00`–`0x3F` of page `0x01` are reserved), pages `0x10`–`0x13` are the custom block, and every other page is reserved: no strobe, reads `0xFF`, writes ignored (spec 1, section 6.1). The register bus address is page × 256 + register, the same address as the register page offset (section 6).
2. **Multi-byte values.** A value wider than 8 bits sits at consecutive registers (offsets), **low byte at the lowest**. The bytes are named NAME0, NAME1, NAME2, NAME3, lowest first (section 8). There are **no latches**: every byte is written straight through when it is written, in any order, with any instruction. To change one byte, a program writes just that byte. So the hardware can see a value half written: a unit that copies it at the start of a line may take the new low byte with the old high byte. Software therefore changes wide display registers (layer pointers, scroll, windows, sprite registers mid-frame) in the vertical blank, or with the copper at a set position, as on the Amiga. A line setting read half written gives at worst a one-line glitch. A live pointer is the one case that can do more: a layer pointer written while the layer fetches picks up the fetcher's moves between its bytes, and the rest of the frame is shown from the wrong place (spec 4, section 4.4). There are three exceptions (section 3.1): the MMU pages and the interrupt pages, where writing byte 1 commits the page; the colours, which change when their red byte arrives; and the captures of rule 4.
3. **The copper and the DMA engine write directly too.** A copper MOVE and a DMA job write each byte straight to its register, as the CPU does, with no latch of their own (spec 6, section 4.2; spec 14, section 4). The masters' writes land in the order the register bus takes them, and the last write to each byte wins: a copper or DMA write between two of the CPU's bytes lands at once, and the other way round. Only the colours are assembled (the MMU pages are out of their reach): each master has one **colour assembly buffer** that holds its blue and green bytes until its red byte (rule 7).
4. **Reading.** Reading gives the register's value. For registers the **hardware changes by itself** (the table), **reading the low byte captures the whole value**. Each master that reads has **one tagged capture**, as retro68k's bus interface (`bus_if.v`: `rh_valid`, `rh_tag`, `rh_data`): one for the CPU and one for the DMA engine; the copper never reads. Reading a capturing register's low byte stores its whole value in the capture, tagged with that register. Reading a higher byte of the same register gives the captured byte, so a value read low byte first always matches, however long after the capture. Reading a higher byte of a register that is not the tagged one gives the live byte. Reading another capturing register's low byte replaces the capture. So an interrupt handler that reads a counter between a program's reads replaces the program's capture, and the program's later bytes come from the handler's register or read live. The fix: read with interrupts off, or, for a 2-byte value, with `LD HL,(nn)` through the register page, which reads both bytes in one instruction (an interrupt is taken only between instructions). The DMA engine's one capture is shared by its four channels (spec 14, section 4). On a read of a low byte that captures, the unit hands the master its whole value beside the byte (section 3.2). The registers that capture:

   | Register | Bytes | Low byte | Spec |
   |----------|-------|-------------|------|
   | BEAMPOS (HPIXEL and VLINE) | 4 | Custom `0x0F0` | 4, 3.3 |
   | FRAMECOUNT | 2 | Custom `0x0F4` | 4, 3.3 |
   | L0, L1, L2 BPL0PT | 3 | Custom `0x0A4`, `0x0C4`, `0x0E4` | 4, 6.3 |
   | SPRxPT | 3 | Custom `0x010` + n × `0x10` | 5, 6 |
   | COPPC | 3 | Custom `0x10A` | 6, 6 |
   | SEQPT | 3 | Custom `0x308` | 17, 8 |
   | CHDESC (DMA channel n) | 3 | Custom `0x160` + n × `0x40` | 14, 8.1 |
   | TIME | 4 | Register `0x20` | 9, 3 |
   | TMRn_COUNT | 2 | Register `0x2D` + n × 8 | 9, 4.1 |
   | SDCOUNT | 2 | Register `0x5D` | 11, 5.2 |

5. **Status bits.** Sticky flags (W1C) are cleared by writing 1 to them; writing 0 leaves them alone. Live bits in the same register ignore writes. A program clears exactly what it saw by writing back the value it read.
6. **Reserved bits** read 0 and should be written 0.
7. **Index, data and colours.** The palettes are reached through PALIDX and PALDAT (spec 4, section 6.5): PALDAT takes blue, green and red in turn, and the red byte changes the entry and steps the index. The register page also shows the palettes directly (section 6). A colour is shown live, so it changes whole: blue and green go into the master's colour assembly buffer, and the **red byte writes the colour whole**, with the buffer's blue and green. Each master (CPU, copper, DMA engine) has one buffer, shared by PALDAT, the register page palettes and BGCOLOR; it is not a latch per entry. Each master also has its own PALIDX and PALDAT byte counter (spec 4, section 6.5). BGCOLOR follows the same rule: its red byte (`0x006`) commits it (spec 4, section 6.1).
8. **The register bus.** Every register access, from a port, the register page, the copper, the sprite sequencer or the DMA engine, is one clock on the register bus; the copper goes first, then the CPU, then the sprite sequencer, then the DMA engine (section 3.2). A port access is the Z80's normal 4-T-state I/O cycle and a register page access a normal 3-T-state memory cycle, with no wait states. Register accesses use no memory cycle.
9. **I/O and memory are the same registers.** A write through a port and a write through the register page go to the same register, so a value can be written partly through one and partly through the other. The MMU's held byte 0, the CPU's colour assembly buffer and the CPU's capture are shared by both paths too. Reads have the same side effects both ways.
10. **Write order.** With no latches, the bytes of a register can be written in any order and with any instruction: `LD (nn),HL`, `LD (nn),DE/BC/IX/IY`, `LDI`, `LDIR`, `PUSH`, `EX (SP),HL`, `LDDR`, and `OUT (C),r` with `INC B` or `DEC B`. `OUTI` decrements B, the register number, before the write, so unrolled `OUTI`s write a register from a table held high byte first; `OTIR` runs on down to register 0, so it is no use on a page. Two exceptions need their last byte last: an **MMU or interrupt page** (byte 0, then byte 1: `LD (nn),HL`, or `OUT (C),r` with `INC B`; not `PUSH` or `LDDR`) and a **colour** (blue, green, then red: rising addresses, `LDIR`, not `LDDR`). Read-modify-write instructions (`INC (HL)`, `SET b,(HL)`) are fine on plain registers, but not on the data ports of rule 14.
11. **Unused addresses.** A register of a page, a custom offset, a reserved page or a register page offset with no register reads `0xFF` and ignores writes. A write-only register reads `0x00`. A byte that belongs to a register reads its bits, with reserved bits 0. Bytes of a DMA descriptor that hold no bits are not registers: they read `0xFF`.
12. **Set/clear registers** (DMACON, INTENA0–2, SPRDMA): bit 7 of the byte (SPRDMA: of its second byte, SPRDMA1) is SETCLR. Writing with SETCLR = 1 sets the other bits written as 1; with SETCLR = 0 clears them; bits written as 0 are left alone. Reading gives the enables, with SETCLR reading 0. Never read, change and write back: write only the bits to change.
13. **Strobes** act on any write, whatever the value: COPJMP1, COPJMP2, COPINT, and the strobe bits of SOFTINT, CHCTRL (START, RUN, STOP), I2CCMD, SERCON (RXFLUSH, TXFLUSH) and IPRESTORE (RET, NOW). Two act only on a magic value: SYSRESET (`0xA5`) and WDKICK (`0x5A`, where any other value resets while the watchdog is on).
14. **Reading has no side effects,** except for the CPU: SERDATA and KBDATA, which take a byte; SDDATA with SDCON.AUTO set, which starts an exchange; SERDROP, which clears; PALDAT, whose red read steps the index; and the captures of rule 4. All except PALDAT and the captures are in the system page, out of the copper's and the DMA engine's reach. The copper never reads, and a DMA engine read of a register has no side effect (spec 14).
15. **Timing.** A write takes effect as its unit's spec says: some at once (palette entries, VIDCON), some at the start of the line's picture (PRIO, BGCOLOR), some at the start of the next line (layer settings; a running sprite's PT, H, V and STEP), and a write to SPRxCTL starts its sprite (the vertical blank stops every sprite). Each byte takes effect when it is written; only an MMU page and a colour wait for their last byte (rule 2). A port `0xFE` border write acts at once, from the pixel being shown about 10–60 ns later (a Spectrum extra, spec 4, section 7.2). See spec 4, section 5.6, and spec 5, section 4.2.

**Access column key:** R = read only; W = write only (reads `0x00`); RW = read and write; W1C = sticky flags, cleared by writing 1; R, W1C = live bits and sticky flags mixed; SC = set/clear (rule 12); S = strobe (rule 13); F = reading has an effect (rule 14); CAP = reading the low byte captures (rule 4).

### 3.1 Exceptions

Each spec declares where a register departs from the rules above. The first three rows are the only places where a write waits for another byte or a read is not live.

| Register | Exception | Why | Spec |
|----------|-----------|-----|------|
| **The three exceptions to direct access** | | | |
| MMUn_0/MMUn_1, MMUnW_0/MMUnW_1 (registers `0x80`–`0x9F`); the interrupt pages IPn, IPnW, IPSAVn, IPSAVnW, NMIPn, NMIPnW, NMISAVn, NMISAVnW (registers `0x80`–`0xFF` of page `0x01`) | Byte 0 is held; writing byte 1 commits the page, with the held byte 0 (or the current one, if none was written). Committing a read page also sets the matching write page | A window must never point at a half-changed page: the next opcode fetch may use it, and an interrupt may load an interrupt page or restore a saved one at any time | 2, 9.2 and 9.8 |
| Colours: PALDAT, the palettes in the register page, BGCOLOR (custom `0x004`–`0x006`) | Blue and green go into the master's colour assembly buffer; the red byte writes the colour whole. One buffer per master (CPU, copper, DMA engine), shared by all three paths; not a latch per entry | A colour is shown live: a half-written one would show for some pixels | 4, 6.1 and 6.5 |
| Captures (rule 4) | Reading the low byte captures the whole value in the master's one tagged capture; higher bytes of the same register read from it | Counters the hardware changes by itself must be read whole | 3, rule 4 |
| **Set/clear** | | | |
| DMACON (custom `0x00C`) | One byte, SETCLR in bit 7 | retro68k's DMACON in a byte | 4, 6.1 |
| INTENA0–2 (registers `0x01`–`0x03`) | Three set/clear bytes, each acting on its own | Each byte holds 7 sources; one write changes one source | 8, 12 |
| SPRDMA (custom `0x120`–`0x121`) | A 2-byte set/clear register: a write to SPRDMA0 stores the sprite bits to act on (it reads the enables); writing SPRDMA1 (SETCLR in bit 7) sets or clears them, a trigger like a strobe | 8 sprites and SETCLR need 9 bits | 5, 6 |
| **Separate bytes, not one value** (no capture) | | | |
| Layer CTRL0–CTRL3 (`+0x00`–`+0x03`) | Four byte registers with separate fields, each written on its own | A copper list changes PALOFS with one MOVE | 4, 6.3 |
| WINX, WINY (layer `+0x04`–`+0x0B`) | Each is two 2-byte values (XEND then XSTART; YEND then YSTART) | retro68k's 32-bit registers, half by half | 4, 6.3 |
| BEAMPOS (custom `0x0F0`–`0x0F3`), VIDSIZE (`0x0F6`–`0x0F9`) | Two 2-byte values each (HPIXEL, VLINE; HVISIBLE, VVISIBLE). BEAMPOS has one capture for all four bytes | retro68k's 32-bit registers | 4, 6.2 |
| INTPEND0–2, INTRAW0–2 (registers `0x04`–`0x09`) | Separate read-only bytes, read live | Same positions as INTENA0–2 | 8, 12 |
| KEYMAP0–6 (registers `0x10`–`0x16`), KEYROW0–7 | Separate read-only bytes, one per column or row | Each is used on its own | 12, 5.3 and 8.1 |
| SPRCOLL0–3 (custom `0x124`–`0x127`) | Separate W1C bytes | Each byte is read and cleared on its own | 5, 6 |
| SERSTAT0, SERSTAT1 (registers `0x51`–`0x52`) | Two separate live counts, TXSPACE and RXCOUNT; reading `0x51` does **not** capture `0x52` | Each count is used on its own, for `OTIR` or `INIR` | 10, 7 |
| **Index and data** | | | |
| PALDAT (custom `0x00B`) | One register for 3-byte entries: blue and green writes go into the colour assembly buffer, the red write changes the entry and steps PALIDX; a red read steps it too. Writing either byte of PALIDX resets PALDAT's byte order | Lets a loop of `OUT (C),r` stream a palette | 4, 6.5 |
| Palettes in the register page (`0x1400`–`0x1FFF`) | 3-byte entries, blue first; the red byte writes the entry, as above. PALIDX is not used or changed | 3 KB fits the page | 2, 10.2; 4, 6.5 |
| **Reading has an effect** | | | |
| SERDATA (`0x53`), KBDATA (`0x62`) | Reading takes a byte from the FIFO; an empty FIFO reads `0x00` | Streams, not values | 10, 7; 12, 6 |
| SDDATA (`0x5B`) | Writing starts an SPI exchange; with SDCON.AUTO, reading starts one too | Lets `INIR` read a block | 11, 6 |
| SERDROP (`0x5C`) | Reading clears it | retro68k's SERDROP | 10, 7 |
| **Writes with an effect** | | | |
| MMUn_1 (registers `0x81` + 2n) | Committing a read page also sets the window's write page (the first row) | One write changes a window | 2, 9.2 |
| SPRxCTL | A write starts the sprite: its FIFO empties, and its first line is the next line inside its window, at SPRxPT. Writes to SPRxPT, SPRxH, SPRxV and SPRxSTEP act on a running sprite from the next line; write them first, then CTL. The vertical blank stops every sprite; nothing restarts at the frame start | CTL is one byte, so a start never sees a half-written register (design plan, branch 11) | 5, 4.2 |
| TMRn_COUNT | Each byte written sets that byte of the count at once; RELOAD is used only at the next underflow. Stop the timer before writing its count | retro68k's timers | 9, 4.1 |
| SDCOUNT (registers `0x5D`–`0x5E`) | A write to SDCOUNT1 starts a run of reads for DMA port 0: a start trigger, not a latch. Write SDCOUNT0 first | retro68k's SDCOUNT | 11, 5.2 |
| BGCOLOR (custom `0x004`–`0x006`) | A write to port `0xFE` sets all three bytes at once and shows at once, mid-line, after the clock crossing (10–60 ns); the CPU's colour assembly buffer is kept. BGCOLOR written as a register shows from the start of a line's picture | Spectrum border | 4, 7.2 |
| **Writes refused or limited** | | | |
| DMA job registers and CHDESC (channel `+0x00`–`+0x22`) | Writes are ignored while CHSTAT.BUSY | retro68k's rule | 14, 8.1 |
| WDCTRL, WDTIME (registers `0x48`–`0x4A`) | Read only after WDCTRL.LOCK, until reset | retro68k's watchdog lock | 9, 5 |
| SYSCON.ROMLOCK, SERCON.CTLLOCK | Can be set, not cleared, by software | retro68k's locks | 7, 11.1; 10, 7 |
| SDDATA, KBSEND, I2CCMD | A write while the unit is busy is ignored | No transmit buffers; the CPU never waits | 11, 3; 12, 3.4; 7, 11.2 |
| **Mixed** | | | |
| CHCTRL (channel `+0x24`) | Strobe bits START, RUN and STOP (read 0) beside the RW bit PAUSE | retro68k's CHCTRL | 14, 8.2 |
| COPSP (custom `0x111`) | Reads the stack depth; any write empties the stack | retro68k's COPSP | 6, 6 |
| COP2LC (custom `0x104`–`0x106`) | Changed by the hardware at a frame restart with COPCON.RESUME; no capture | retro68k's RESUME | 6, 6.5 |
| **Interrupt pages** (a retro-z80 extra) | | | |
| IPSAVn, IPSAVnW, NMISAVn, NMISAVnW | Loaded by the hardware with all 16 MMU page registers at a switch; written by software to change what the return puts back | The saved map is the program's; a handler may change it | 2, 9.7 |
| NMICAPPC, NMICAPSP | Loaded by the hardware at every NMI's entry; NMICAPPC is read by `RETN`. No capture of their own: they do not change while the NMI handler reads them | The NMI's return address kept off the stack | 2, 9.7 |
| IPDEPTH | Counted by each maskable response and return; writing sets it and changes no window | Nesting | 2, 9.7 |
| IPRESTORE | Strobe bits RET (arm the next `RET`) and NOW (return at once) | Handlers that do not end with `RETI` | 2, 9.7 |
| IPCTL, IPMASK, NMICTL, NMIMASK | Looked at only on an outermost entry; the return uses the values noted then | Changing them in a handler cannot break its return | 2, 9.7 |
| **Spectrum extras** | | | |
| Port `0xFE` | Reads decode A15–A8 as keyboard rows (register `0xFE` of page `0x00`, with no row select, reads all rows); writes set the border (BGCOLOR, at once) and the beeper | Spectrum compatibility | 12, 8.1 and 8.4; 4, 7.2; 7, 10.2 |
| KEMPSTON (port `0x1F`) | A second view of JOY1 | Spectrum compatibility | 12, 8.5 |
| KEYROW0–7 | Register page only (offsets `0x0100`–`0x0107`); no port | A memory read has no A15–A8 for the row select | 12, 8.1 |

### 3.2 The register bus

The registers are reached over one 8-bit register bus in the 100 MHz domain (spec 1, section 4.2). Its address is the register page offset: page × 256 + register for a port, the custom offset + `0x1000` for the custom block. Every unit decodes the address, so one address names a register however it is reached. Each access takes one clock; a unit not addressed puts 0 on the read data, and if no unit answers the master gets `0xFF`. A read of a capturing register's low byte also gets the register's whole value, on a 32-bit capture path beside the read data, for the master's capture (rule 4; spec 1, section 4.2). Writes need no such path: each byte goes straight to its register.

In each clock the first master in this order that wants the bus gets it:

| Order | Master | What it reaches | Spec |
|-------|--------|-----------------|------|
| 1 | **Copper** | Writes only: the custom block, `0x000`–`0x0EF` by MOVE, `0x000`–`0x0FF` by MOVR, any offset by MOVEF. At most one write every 2 clocks | 6 |
| 2 | **CPU** | Everything: port accesses and register page accesses | 1 |
| 3 | **Sprite sequencer** | Writes only: the registers of the sprites SEQMASK gives it (custom `0x010`–`0x08F`), 16 bytes per list entry, in the line before the entry's first line | 17 |
| 4 | **DMA engine** | Reads and writes of the custom block and the palettes; SERDATA and SDDATA for its port jobs, paced by each unit's ready signals. A job that names anything else stops with an error | 14 |

- The copper goes first, so its writes always land on their pixel. The CPU's strobe then moves one clock, which every CPU access has room for (spec 1, sections 5.7 and 6).
- The sprite sequencer waits a clock whenever the copper or the CPU has the bus, so it never delays either of them. Its 16 writes for an entry take at most 40 clocks (spec 17, section 5).
- The DMA engine waits a clock whenever the copper, the CPU or the sequencer has the bus. It never delays any of them.
- The boot ROM is not on this bus: the CPU reads it through the MMU, the DMA engine through the ROM's second block RAM port (spec 2, section 2).

## 4. Ports and the system page

### 4.1 The port form

Every port is **register (high byte) : page (low byte)**: port = register × 256 + page.

| Low byte (A7–A0) | High byte (A15–A8) | Goes to |
|------------------|--------------------|---------|
| `0x1F`, `0x53`, `0x5B`, `0x62`, `0xFE` | Any | The **low-byte-only ports**: register A7–A0 of page `0x00`. Port `0xFE` uses A15–A8 to pick keyboard rows on reads |
| `0x00` | Register r | The **system page**: register r (this section) |
| `0x01` | Register r, `0x40`–`0xFF` | The **interrupt pages** (section 4.13). Registers `0x00`–`0x3F` are reserved |
| `0x10`–`0x13` | Register r | The **custom block**: custom offset (page − `0x10`) × 256 + r (section 5) |
| Any other | – | Reserved: no strobe; reads give `0xFF`, writes are ignored |

The low-byte-only ports are also ordinary registers of page `0x00`: SERDATA is port `0x53` and port `0x5300`, the same register. In the page form A15–A8 are the register number, so register `0xFE` of page `0x00` (port `0xFE00`) reads all keyboard rows at once.

| Low-byte-only port | Name | Spec |
|--------------------|------|------|
| `0x1F` | KEMPSTON: joystick 1 (Spectrum extra) | 12, 8.5 |
| `0x53` | SERDATA: the USB serial FIFOs | 10, 7 |
| `0x5B` | SDDATA: the SD card's SPI byte | 11, 6 |
| `0x62` | KBDATA: the PS/2 FIFO | 12, 6 |
| `0xFE` | Keyboard rows, border, beeper (Spectrum extra) | 12, 8 |

**From the Z80** (spec 1, section 6.2):

| Instruction | A15–A8 | Use |
|-------------|--------|-----|
| `OUT (C),r`, `IN r,(C)` | B | The normal way: `LD BC,port` (B = register, C = page). `INC B` steps to the next register, so a multi-byte register is written low byte first |
| `IN A,(n)` | A | `LD A,register` then `IN A,(page)` reads that register. On a low-byte-only port, A picks keyboard rows (`0xFE`) or is ignored |
| `OUT (n),A` | A | Writes A to register A: no use with pages. On a low-byte-only port it works as on a Spectrum: `OUT (0xFE),A`, `OUT (0x53),A` |
| `INIR`, `OTIR` and the other block I/O | B, the count | With C = a low-byte-only stream port (`0x53`, `0x5B`, `0x62`), B is a plain count. With C = a page they step registers downwards: `OTIR` runs on to register 0, so it is no use there; unrolled `OUTI`s write a register from a table held high byte first (rule 10) |

```
        ld   bc,SPR0_PT_P          ; a 3-byte custom register, low byte first
        out  (c),l                 ; bits 7-0
        inc  b
        out  (c),h                 ; bits 15-8
        inc  b
        out  (c),e                 ; bits 23-16
        ld   a,INTID               ; a system register
        in   a,(SYSPAGE)           ; page 0x00: A = INTID
```

Full I/O access is kept alongside the register page, because the MMU must be reachable before any window shows the page (spec 2, section 9.2).

### 4.2 Layout of the system page

Page `0x00`. The same registers are at register page offset = register number. The copper cannot reach them, and the DMA engine stops with an error if a job names them. In the tables below, Width is the value's width in bytes, at consecutive registers from the one given; Port is the page form.

| Registers | Contents | Spec |
|-----------|----------|------|
| `0x00`–`0x0F` | Interrupt controller | 8 |
| `0x10`–`0x16` | Membrane key map | 12 |
| `0x17`–`0x1E` | Free | |
| `0x1F` | Kempston joystick (Spectrum extra; also low-byte-only port `0x1F`) | 12 |
| `0x20`–`0x4F` | Time counter, timers and watchdog | 9 |
| `0x50`–`0x57`, `0x5C` | USB serial | 10 |
| `0x58`–`0x5B`, `0x5D`–`0x5F` | SD card | 11 |
| `0x60`–`0x6F` | PS/2 keyboard, joysticks, KEYCON | 12 |
| `0x70`–`0x7B` | System: identification, reset, buttons, CPU speed, I2C | 7 |
| `0x7C`–`0x7F` | Free (the NMI monitor registers moved to page `0x01`, section 4.13) | |
| `0x80`–`0x8F` | MMU read pages | 2 |
| `0x90`–`0x9F` | MMU write pages | 2 |
| `0xA0`–`0xBF` | Geometry unit (reserved for spec 15) | 15 |
| `0xC0`–`0xFD` | Free | |
| `0xFE` | Keyboard rows, border, beeper (Spectrum extra; also low-byte-only port `0xFE`) | 12 |
| `0xFF` | Free | |

Page `0x01` holds the interrupt pages at registers `0x40`–`0xFF` (section 4.13).

### 4.3 Interrupt controller (`0x00`–`0x0F`)

| Register | Port | Name | Width | Access | Meaning | Spec |
|----------|------|------|-------|--------|---------|------|
| `0x00` | `0x0000` | INTCON | 1 | RW | MASTER | 8, 12 |
| `0x01` | `0x0100` | INTENA0 | 1 | SC | Enables, sources 0–6 | 8, 12 |
| `0x02` | `0x0200` | INTENA1 | 1 | SC | Enables, sources 7–13 | 8, 12 |
| `0x03` | `0x0300` | INTENA2 | 1 | SC | Enables, sources 14–20 | 8, 12 |
| `0x04`–`0x06` | `0x0400`–`0x0600` | INTPEND0–2 | 1 each | R | Pending, sources 0–6, 7–13, 14–20 | 8, 12 |
| `0x07`–`0x09` | `0x0700`–`0x0900` | INTRAW0–2 | 1 each | R | Request lines, as INTPEND | 8, 12 |
| `0x0A` | `0x0A00` | VECBASE | 1 | RW | Low byte of the IM 2 table | 8, 5 |
| `0x0B` | `0x0B00` | SOFTINT | 1 | W (S) | SET, CLR of source SOFT | 8, 9 |
| `0x0C` | `0x0C00` | INTID | 1 | R | Source given at the last acknowledge | 8, 6 |
| `0x0D` | `0x0D00` | NMICON | 1 | RW | NMI sources allowed | 8, 10 |
| `0x0E` | `0x0E00` | NMISTAT | 1 | W1C | NMI sources seen | 8, 10 |
| `0x0F` | | – | | | Reserved | |

### 4.4 Key map and Kempston (`0x10`–`0x1F`)

| Register | Port | Name | Width | Access | Meaning | Spec |
|----------|------|------|-------|--------|---------|------|
| `0x10`–`0x16` | `0x1000`–`0x1600` | KEYMAP0–6 | 1 each | R | Membrane column c, bit r = row r, 1 = pressed | 12, 5.3 |
| `0x17`–`0x1E` | | – | | | Free | |
| `0x1F` | `0x1F00`, and `0x1F` with any high byte | KEMPSTON | 1 | R | Joystick 1, the same value as JOY1; writes ignored. Spectrum extra | 12, 8.5 |

### 4.5 Time counter, timers and watchdog (`0x20`–`0x4F`)

| Register | Port | Name | Width | Access | Meaning | Spec |
|----------|------|------|-------|--------|---------|------|
| `0x20`–`0x23` | `0x2000`–`0x2300` | TIME (TIME0–3) | 4 | R, CAP | Microseconds since power-on | 9, 3 |
| `0x24`–`0x27` | | – | | | Reserved (a wider TIME, spec 9 T4) | |
| `0x28`–`0x2F` | `0x2800`–`0x2F00` | TMR0 | | | Timer 0 (below) | 9, 6 |
| `0x30`–`0x37` | `0x3000`–`0x3700` | TMR1 | | | Timer 1 | 9, 6 |
| `0x38`–`0x3F` | `0x3800`–`0x3F00` | TMR2 | | | Timer 2 | 9, 6 |
| `0x40`–`0x47` | `0x4000`–`0x4700` | TMR3 | | | Timer 3 | 9, 6 |
| `0x48` | `0x4800` | WDCTRL | 1 | RW (lockable) | EN, LOCK | 9, 5 |
| `0x49`–`0x4A` | `0x4900`–`0x4A00` | WDTIME (WDTIME0, WDTIME1) | 2 | RW (lockable) | Milliseconds between kicks | 9, 5 |
| `0x4B` | `0x4B00` | WDKICK | 1 | W (S) | `0x5A` kicks; any other value resets | 9, 5 |
| `0x4C`–`0x4F` | | – | | | Reserved | |

Timer n (0–3) at register `0x28` + n × 8:

| Offset | Name | Width | Access | Meaning | Spec |
|--------|------|-------|--------|---------|------|
| `+0` | TMR_CTRL | 1 | RW | EN, REPEAT, SRC, IRQ, DMA, DMACH | 9, 6 |
| `+1`–`+2` | TMR_PRESCALE (TMR_PRESCALE0, TMR_PRESCALE1) | 2 | RW | SRC 0 divider | 9, 4.2 |
| `+3`–`+4` | TMR_RELOAD (TMR_RELOAD0, TMR_RELOAD1) | 2 | RW | Loaded at each underflow when repeating | 9, 4.1 |
| `+5`–`+6` | TMR_COUNT (TMR_COUNT0, TMR_COUNT1) | 2 | RW, CAP | The count; each byte written sets it at once | 9, 4.1 |
| `+7` | TMR_STAT | 1 | W1C | UNDER | 9, 6 |

### 4.6 USB serial (`0x50`–`0x57`, `0x5C`)

| Register | Port | Name | Width | Access | Meaning | Spec |
|----------|------|------|-------|--------|---------|------|
| `0x50` | `0x5000` | SERCON | 1 | RW | EN, CTLEN, CTLLOCK, TXDROP; RXFLUSH, TXFLUSH (S) | 10, 7 |
| `0x51` | `0x5100` | SERSTAT0 | 1 | R | TXSPACE: room in the transmit FIFO, 0–255 | 10, 7 |
| `0x52` | `0x5200` | SERSTAT1 | 1 | R | RXCOUNT: bytes in the receive FIFO, 0–255 | 10, 7 |
| `0x53` | `0x5300`, and `0x53` with any high byte | SERDATA | 1 | RW (F) | Receive and transmit FIFO | 10, 7 |
| `0x54` | `0x5400` | SERLEVEL | 1 | RW | RXLEVEL, TXLEVEL codes | 10, 7 |
| `0x55` | `0x5500` | SERTIME | 1 | RW | Receive timeout, 16 µs steps | 10, 7 |
| `0x56` | `0x5600` | SERIRQ | 1 | R, W1C | RXREADY, RXTIMEOUT, TXREADY, TXOVF | 10, 5.4 |
| `0x57` | `0x5700` | SERIRQEN | 1 | RW | Enables, as SERIRQ | 10, 5.4 |
| `0x5C` | `0x5C00` | SERDROP | 1 | R (F) | Bytes dropped by TXDROP; reading clears | 10, 7 |

### 4.7 SD card (`0x58`–`0x5B`, `0x5D`–`0x5F`)

| Register | Port | Name | Width | Access | Meaning | Spec |
|----------|------|------|-------|--------|---------|------|
| `0x58`–`0x59` | `0x5800`–`0x5900` | SDCON (SDCON0, SDCON1) | 2 | RW | EN, CS0, CS1, AUTO (`0x58`); CLKDIV (`0x59`); each byte acts when written | 11, 6 |
| `0x5A` | `0x5A00` | SDSTAT | 1 | R | BUSY | 11, 6 |
| `0x5B` | `0x5B00`, and `0x5B` with any high byte | SDDATA | 1 | RW (F) | SPI byte exchange | 11, 3 |
| `0x5C` | | | | | SERDROP (section 4.6) | 10 |
| `0x5D`–`0x5E` | `0x5D00`–`0x5E00` | SDCOUNT (SDCOUNT0, SDCOUNT1) | 2 | RW, CAP | Bytes to read for DMA port 0; a write to SDCOUNT1 starts the run | 11, 5.2 |
| `0x5F` | | – | | | Reserved | |

### 4.8 Keyboard and joysticks (`0x60`–`0x6F`)

| Register | Port | Name | Width | Access | Meaning | Spec |
|----------|------|------|-------|--------|---------|------|
| `0x60` | `0x6000` | KBCON | 1 | RW | EN | 12, 6 |
| `0x61` | `0x6100` | KBSTAT | 1 | R | COUNT, TXBUSY | 12, 6 |
| `0x62` | `0x6200`, and `0x62` with any high byte | KBDATA | 1 | R (F) | PS/2 FIFO | 12, 3.2 |
| `0x63` | `0x6300` | KBSEND | 1 | W | Byte to the keyboard | 12, 3.4 |
| `0x64` | `0x6400` | KBIRQ | 1 | R, W1C | DATA, PARITY, FRAME, OVERFLOW, TIMEOUT | 12, 6 |
| `0x65` | `0x6500` | KBIRQEN | 1 | RW | Enables, as KBIRQ | 12, 6 |
| `0x66` | `0x6600` | JOY1 | 1 | R | Joystick port 1, Kempston bit order, 1 = pressed | 12, 4.3 |
| `0x67` | `0x6700` | JOY2 | 1 | R | Joystick port 2 | 12, 4.3 |
| `0x68` | `0x6800` | JOYCON | 1 | RW | MD1, MD2; SIX1, SIX2, MDPRES1, MDPRES2 (R) | 12, 4.2 |
| `0x69`–`0x6A` | | – | | | Reserved | |
| `0x6B` | `0x6B00` | KEYCON | 1 | RW | KXMAP, EAR6, PS2MAP (Spectrum extras) | 12, 8 |
| `0x6C` | `0x6C00` | JOY1X | 1 | R | X, Y, Z, MODE of a 6-button pad on port 1 | 12, 4.3 |
| `0x6D` | `0x6D00` | JOY2X | 1 | R | The same, port 2 | 12, 4.3 |
| `0x6E`–`0x6F` | | – | | | Reserved | |

### 4.9 System (`0x70`–`0x7F`)

| Register | Port | Name | Width | Access | Meaning | Spec |
|----------|------|------|-------|--------|---------|------|
| `0x70` | `0x7000` | SYSID | 1 | R | `0x5A` ("Z") | 7, 11.1 |
| `0x71` | `0x7100` | SYSVER | 1 | R | Build version | 7, 11.1 |
| `0x72` | `0x7200` | SYSCFG | 1 | R | CPU, CHIPMB (build constants) | 7, 11.1 |
| `0x73` | `0x7300` | RESETWHY | 1 | R | Cause of the last reset | 7, 3.1 |
| `0x74` | `0x7400` | SYSCON | 1 | RW | ROMWE, ROMLOCK | 7, 11.1 |
| `0x75` | `0x7500` | SYSRESET | 1 | W (S) | `0xA5` resets | 7, 11.1 |
| `0x76` | `0x7600` | SYSBTN | 1 | R | MULTIFACE, DIVMMC | 7, 6 |
| `0x77` | `0x7700` | CPUSPEED | 1 | RW | DIV (20 MHz ÷ 1–8), SPECTRUM (3.57 MHz) | 7, 6.1; 1, 3 |
| `0x78` | `0x7800` | I2CCON | 1 | RW | EN, CLKDIV | 7, 11.2 |
| `0x79` | `0x7900` | I2CDATA | 1 | RW | Byte sent or received | 7, 11.2 |
| `0x7A` | `0x7A00` | I2CCMD | 1 | W (S) | START, STOP, WRITE, READ, ACK | 7, 11.2 |
| `0x7B` | `0x7B00` | I2CSTAT | 1 | R | BUSY, NACK, ARBLOST | 7, 11.2 |
| `0x7C`–`0x7F` | | – | | | Free (the NMI monitor registers moved to page `0x01`, section 4.13) | |

### 4.10 MMU (`0x80`–`0x9F`)

| Register | Port | Name | Width | Access | Meaning | Spec |
|----------|------|------|-------|--------|---------|------|
| `0x80` + 2n | `0x8000` + n × `0x200` | MMUn (MMUn_0, MMUn_1) | 2 | RW | Window n's read page, 10 bits; byte 0 is held and writing byte 1 commits, which also sets its write page | 2, 9.2 |
| `0x90` + 2n | `0x9000` + n × `0x200` | MMUnW (MMUnW_0, MMUnW_1) | 2 | RW | Window n's write page, 10 bits; byte 0 is held and writing byte 1 commits | 2, 9.2 |

n = 0–7: MMU0 at `0x80`, MMU7 at `0x8E`; MMU0W at `0x90`, MMU7W at `0x9E`. While an interrupt or an NMI has switched a window, its MMU registers read the interrupt page (spec 2, section 9.7).

### 4.11 Geometry unit (`0xA0`–`0xBF`)

Reserved for the geometry unit (design plan branch 10, spec 15, not yet written). Until then these registers read `0xFF`. Its interrupt number, 19 (GEOM), is reserved too (section 7).

### 4.12 Port `0xFE`, a Spectrum extra

| Register | Port | Name | Width | Access | Meaning | Spec |
|----------|------|------|-------|--------|---------|------|
| `0xFE` | `0xFE` with A15–A8 picking rows; `0xFE00` (all rows) | – | 1 | RW | Read: membrane rows (and PS/2 keys mapped on) selected by A15–A8, bits 4–0 active low. Write: bits 2–0 border (sets BGCOLOR and shows at once, mid-line), bit 4 beeper | 12, 8.1, 8.4; 4, 7.2; 7, 10.2 |

### 4.13 Interrupt pages (page `0x01`), a retro-z80 extra

I/O page `0x01`: port = register × 256 + `0x01`; register page offset `0x0100` + register. Registers `0x00`–`0x3F` are reserved through I/O (their register page offsets hold KEYROW0–7 and free space, section 6). The bits are in spec 2, section 9.8.

| Register | Port | Name | Width | Access | Meaning | Spec |
|----------|------|------|-------|--------|---------|------|
| `0x40` | `0x4001` | IPCTL | 1 | RW | EN (maskable interrupts) | 2, 9.8 |
| `0x41` | `0x4101` | IPMASK | 1 | RW | Windows switched on an interrupt | 2, 9.8 |
| `0x42` | `0x4201` | IPDEPTH | 1 | RW | Nesting depth, 0–255 | 2, 9.8 |
| `0x43` | `0x4301` | IPRESTORE | 1 | W (S) | RET, NOW | 2, 9.8 |
| `0x44`–`0x47` | | – | | | Reserved | |
| `0x48` | `0x4801` | NMICTL | 1 | RW | EN, INNMI (R) (the NMI; its stack capture is always on) | 2, 9.8 |
| `0x49` | `0x4901` | NMIMASK | 1 | RW | Windows switched on an NMI | 2, 9.8 |
| `0x4A`–`0x4B` | | – | | | Reserved | |
| `0x4C`–`0x4D` | `0x4C01`–`0x4D01` | NMICAPPC (NMICAPPC0, NMICAPPC1) | 2 | RW | Captured return address | 2, 9.8 |
| `0x4E`–`0x4F` | `0x4E01`–`0x4F01` | NMICAPSP (NMICAPSP0, NMICAPSP1) | 2 | R | The program's SP at the capture | 2, 9.8 |
| `0x50`–`0x7F` | | – | | | Free | |
| `0x80` + 2n | `0x8001` + n × `0x200` | IPn (IPn_0, IPn_1) | 2 | RW | Window n's interrupt read page; byte 1 commits, and also sets IPnW | 2, 9.8 |
| `0x90` + 2n | `0x9001` + n × `0x200` | IPnW (IPnW_0, IPnW_1) | 2 | RW | Window n's interrupt write page; byte 1 commits | 2, 9.8 |
| `0xA0` + 2n | `0xA001` + n × `0x200` | IPSAVn (IPSAVn_0, IPSAVn_1) | 2 | RW | Window n's read page saved at the switch | 2, 9.8 |
| `0xB0` + 2n | `0xB001` + n × `0x200` | IPSAVnW (IPSAVnW_0, IPSAVnW_1) | 2 | RW | Window n's write page saved at the switch | 2, 9.8 |
| `0xC0` + 2n | `0xC001` + n × `0x200` | NMIPn (NMIPn_0, NMIPn_1) | 2 | RW | Window n's NMI read page | 2, 9.8 |
| `0xD0` + 2n | `0xD001` + n × `0x200` | NMIPnW (NMIPnW_0, NMIPnW_1) | 2 | RW | Window n's NMI write page | 2, 9.8 |
| `0xE0` + 2n | `0xE001` + n × `0x200` | NMISAVn (NMISAVn_0, NMISAVn_1) | 2 | RW | Window n's read page saved at the NMI | 2, 9.8 |
| `0xF0` + 2n | `0xF001` + n × `0x200` | NMISAVnW (NMISAVnW_0, NMISAVnW_1) | 2 | RW | Window n's write page saved at the NMI | 2, 9.8 |

n = 0–7: IP0 at `0x80` (port `0x8001`), IP7 at `0x8E`; the eight page arrays sit at the MMU's own register numbers and above, so IPn is to page `0x01` what MMUn is to page `0x00`.

### 4.14 Debug unit (page `0x02`), a retro-z80 extra

I/O page `0x02`: port = register × 256 + `0x02`; register page offset `0x0200` + register. Registers `0x3D`–`0xFF` are reserved. The bits are in spec 18, section 8.

| Register | Port | Name | Width | Access | Meaning | Spec |
|----------|------|------|-------|--------|---------|------|
| `0x00` | `0x0002` | DBGCTL | 1 | RW | STEP, STEPINT, LIVE | 18, 8 |
| `0x01` | `0x0102` | DBGSTAT | 1 | W1C | BP0–BP3, WP0, WP1, STEP: what asked for the NMI | 18, 8 |
| `0x02`–`0x03` | `0x0202`–`0x0302` | DBGHITADDR (DBGHITADDR0, DBGHITADDR1) | 2 | R | The watched access's address or port | 18, 6.3 |
| `0x04` | `0x0402` | DBGHITDATA | 1 | R | Its data | 18, 6.3 |
| `0x05` | `0x0502` | DBGHITKIND | 1 | R | WRITE, IO, WP | 18, 6.3 |
| `0x06`–`0x0F` | | – | | | Reserved | |
| `0x10`–`0x2F` | `0x1002`–`0x2F02` | DBGBP0–DBGBP3 | | | Breakpoints (below) | 18, 5 |
| `0x30`–`0x3C` | `0x3002`–`0x3C02` | DBGWP0–DBGWP1 | | | Watchpoints (below) | 18, 6 |

Breakpoint n (0–3) at register `0x10` + n × 8:

| Offset | Name | Width | Access | Meaning | Spec |
|--------|------|-------|--------|---------|------|
| `+0`–`+1` | DBGBP_ADDR (DBGBP_ADDR0, DBGBP_ADDR1) | 2 | RW | The instruction's address | 18, 5.1 |
| `+2`–`+3` | DBGBP_PAGE (DBGBP_PAGE0, DBGBP_PAGE1) | 2 | RW | The read page to match | 18, 5.1 |
| `+4` | DBGBP_CTL | 1 | RW | EN, PAGEEN | 18, 5.1 |

Watchpoint n (0–1) at register `0x30` + n × 8:

| Offset | Name | Width | Access | Meaning | Spec |
|--------|------|-------|--------|---------|------|
| `+0`–`+1` | DBGWP_ADDR (DBGWP_ADDR0, DBGWP_ADDR1) | 2 | RW | The address or port | 18, 6.1 |
| `+2`–`+3` | DBGWP_MASK (DBGWP_MASK0, DBGWP_MASK1) | 2 | RW | Bit 1 = compared | 18, 6.1 |
| `+4` | DBGWP_CTL | 1 | RW | EN, READ, WRITE, IO | 18, 6.1 |

## 5. Custom block

Byte registers at custom offsets `0x000`–`0x3FF`. The CPU reaches offset k at port (k & `0xFF`) << 8 | (`0x10` + (k >> 8)), in pages `0x10`–`0x13`, and at register page offset `0x1000` + k. A unit's register names in `hw.inc` are custom offsets; `name_P` gives the port (section 8).

### 5.1 Layout and copper reach

| Offsets | Ports | Contents | Copper | Spec |
|---------|-------|----------|--------|------|
| `0x000`–`0x00F` | `0x0010`–`0x0F10` | Video globals: VIDCON, VIDSTAT, VIDINTEN, PRIO, BGCOLOR, LINECMP, PALIDX, PALDAT, DMACON | MOVE | 4, 6.1 |
| `0x010`–`0x08F` | `0x1010`–`0x8F10` | Sprites 0–7, 16 bytes each | MOVE | 5, 6 |
| `0x090`–`0x0AF` | `0x9010`–`0xAF10` | Layer L0 | MOVE | 4, 6.3 |
| `0x0B0`–`0x0CF` | `0xB010`–`0xCF10` | Layer L1 | MOVE | 4, 6.3 |
| `0x0D0`–`0x0EF` | `0xD010`–`0xEF10` | Layer L2 | MOVE | 4, 6.3 |
| `0x0F0`–`0x0FF` | `0xF010`–`0xFF10` | Video read-only: BEAMPOS, FRAMECOUNT, VIDSIZE | None useful: read only (MOVR and MOVEF writes ignored) | 4, 6.2 |
| `0x100`–`0x11F` | `0x0011`–`0x1F11` | Copper control and state | MOVEF | 6, 6 |
| `0x120`–`0x12F` | `0x2011`–`0x2F11` | Sprite globals: SPRDMA, SPRCOLL | MOVEF | 5, 6 |
| `0x130`–`0x13F` | `0x3011`–`0x3F11` | Attribute layer (Spectrum extra) | MOVEF | 4, 7.1 |
| `0x140`–`0x23F` | `0x4011`–`0xFF11`, `0x0012`–`0x3F12` | DMA engine: 4 channels of `0x40`; DMXINT, DMXINTEN | MOVEF | 14, 8 |
| `0x240`–`0x2FF` | `0x4012`–`0xFF12` | Audio, reserved (design plan Q1) | MOVEF (no effect) | 13 |
| `0x300`–`0x30F` | `0x0013`–`0x0F13` | Sprite sequencer (retro-z80 extra) | MOVEF | 17, 8 |
| `0x310`–`0x3FF` | `0x1013`–`0xFF13` | Free | MOVEF (no effect) | |

A one-word MOVE names offsets `0x000`–`0x0EF` (its code byte); codes `0xF0`–`0xFF` are the copper's other instructions. MOVR takes its register code from X or from the instruction, so it reaches `0x000`–`0x0FF`. MOVEF (two words) reaches every offset. The copper only writes; read-only registers ignore its writes, as they do the CPU's (spec 6, section 6.6).

### 5.2 Video globals (`0x000`–`0x00F`)

| Offset | Port | Name | Width | Access | Spec |
|--------|------|------|-------|--------|------|
| `0x000` | `0x0010` | VIDCON | 1 | RW | 4, 6.1 |
| `0x001` | `0x0110` | VIDSTAT | 1 | W1C (INVBLANK R) | 4, 3.4 |
| `0x002` | `0x0210` | VIDINTEN | 1 | RW | 4, 3.4 |
| `0x003` | `0x0310` | PRIO | 1 | RW | 4, 4.8 |
| `0x004`–`0x006` | `0x0410`–`0x0610` | BGCOLOR (blue, green, red) | 3 | RW | 4, 4.7 |
| `0x007`–`0x008` | `0x0710`–`0x0810` | LINECMP | 2 | RW | 4, 3.4 |
| `0x009`–`0x00A` | `0x0910`–`0x0A10` | PALIDX | 2 | RW | 4, 6.5 |
| `0x00B` | `0x0B10` | PALDAT | 1 | RW (F) | 4, 6.5 |
| `0x00C` | `0x0C10` | DMACON | 1 | SC | 4, 6.1 |
| `0x00D`–`0x00F` | | – | | Reserved | |

DMACON's bits: SETCLR (7), DMAEN (6), BPLEN (5), COPEN (4), BLTEN (3), SPREN (2), AUDEN (1, reserved), 0 reserved: retro68k's enables in retro68k's order, in one byte (spec 4, section 6.1).

### 5.3 Sprites (`0x010`–`0x08F`)

Sprite n (0–7) at `0x010` + n × `0x10`, ports `0x1010` + n × `0x1000`: SPR0 at `0x010`, SPR7 at `0x080`.

| Offset | Name | Width | Access | Spec |
|--------|------|-------|--------|------|
| `+0x0`–`+0x2` | SPRxPT | 3 | RW, CAP; moves as fetched; from the next line | 5, 6 |
| `+0x3`–`+0x6` | SPRxH (HSTART, HSTOP) | 4 | RW; from the next line | 5, 3.1 |
| `+0x7`–`+0xA` | SPRxV (VSTART, VSTOP) | 4 | RW; from the next line | 5, 3.1 |
| `+0xB` | SPRxCTL (BPP, DEPTH, PAL) | 1 | RW; a write starts the sprite | 5, 3.3 |
| `+0xC`–`+0xF` | SPRxSTEP (XSTEP, YSTEP) | 4 | RW; from the next line | 5, 3.4 |

### 5.4 Layers (`0x090`–`0x0EF`)

Layer n (0–2) at `0x090` + n × `0x20`: L0 at `0x090` (ports `0x9010`–`0xAF10`), L1 at `0x0B0` (`0xB010`–`0xCF10`), L2 at `0x0D0` (`0xD010`–`0xEF10`).

| Offset | Name | Width | Access | Spec |
|--------|------|-------|--------|------|
| `+0x00` | CTRL0 | 1 | RW | 4, 6.4 |
| `+0x01` | CTRL1 | 1 | RW | 4, 6.4 |
| `+0x02` | CTRL2 | 1 | RW | 4, 6.4 |
| `+0x03` | CTRL3 | 1 | RW | 4, 6.4 |
| `+0x04`–`+0x05` | WINX (XEND) | 2 | RW | 4, 4.3 |
| `+0x06`–`+0x07` | WINX (XSTART) | 2 | RW | 4, 4.3 |
| `+0x08`–`+0x09` | WINY (YEND) | 2 | RW | 4, 4.3 |
| `+0x0A`–`+0x0B` | WINY (YSTART) | 2 | RW | 4, 4.3 |
| `+0x0C`–`+0x0D` | SCROLLX | 2 | RW | 4, 4.4, 4.5 |
| `+0x0E`–`+0x0F` | SCROLLY | 2 | RW | 4, 4.5 |
| `+0x10`–`+0x11` | BPLSTRIDE | 2 | RW | 4, 4.4 |
| `+0x12`–`+0x13` | – | | Reserved (retro68k's BPLDMA) | |
| `+0x14`–`+0x16` | BPL0PT | 3 | RW, CAP | 4, 4.4 |
| `+0x17` | – | | Reserved | |
| `+0x18`–`+0x1A` | MAPPT | 3 | RW | 4, 4.5 |
| `+0x1B` | – | | Reserved | |
| `+0x1C`–`+0x1E` | PATPT | 3 | RW | 4, 4.5 |
| `+0x1F` | – | | Reserved | |

### 5.5 Video read-only (`0x0F0`–`0x0FF`)

| Offset | Port | Name | Width | Access | Spec |
|--------|------|------|-------|--------|------|
| `0x0F0`–`0x0F3` | `0xF010`–`0xF310` | BEAMPOS: HPIXEL (`0x0F0`), VLINE (`0x0F2`) | 4 | R, CAP | 4, 3.3 |
| `0x0F4`–`0x0F5` | `0xF410`–`0xF510` | FRAMECOUNT | 2 | R, CAP | 4, 3.3 |
| `0x0F6`–`0x0F9` | `0xF610`–`0xF910` | VIDSIZE: HVISIBLE (`0x0F6`), VVISIBLE (`0x0F8`) | 4 | R | 4, 6.2 |
| `0x0FA`–`0x0FF` | | – | | Reserved | |

### 5.6 Copper (`0x100`–`0x11F`)

| Offset | Port | Name | Width | Access | Spec |
|--------|------|------|-------|--------|------|
| `0x100` | `0x0011` | COPCON | 1 | RW | 6, 6 |
| `0x101`–`0x103` | `0x0111`–`0x0311` | COP1LC | 3 | RW | 6, 6 |
| `0x104`–`0x106` | `0x0411`–`0x0611` | COP2LC | 3 | RW | 6, 6.5 |
| `0x107` | `0x0711` | COPJMP1 | 1 | W (S) | 6, 6 |
| `0x108` | `0x0811` | COPJMP2 | 1 | W (S) | 6, 6 |
| `0x109` | `0x0911` | COPINT | 1 | W (S) | 6, 6.4 |
| `0x10A`–`0x10C` | `0x0A11`–`0x0C11` | COPPC | 3 | R, CAP | 6, 6 |
| `0x10D` | `0x0D11` | COPSTAT | 1 | R, W1C | 6, 6.1 |
| `0x10E` | `0x0E11` | COPX | 1 | RW | 6, 4.6 |
| `0x10F` | `0x0F11` | COPY | 1 | RW | 6, 4.6 |
| `0x110` | `0x1011` | COPFLAGS | 1 | RW | 6, 4.6 |
| `0x111` | `0x1111` | COPSP | 1 | RW (any write empties the stack) | 6, 4.8 |
| `0x112`–`0x117` | | – | | Reserved | |
| `0x118`–`0x11F` | `0x1811`–`0x1F11` | COPR0–COPR7 | 1 each | RW | 6, 4.6 |

### 5.7 Sprite globals (`0x120`–`0x12F`)

| Offset | Port | Name | Width | Access | Spec |
|--------|------|------|-------|--------|------|
| `0x120`–`0x121` | `0x2011`–`0x2111` | SPRDMA (SPRDMA0, SPRDMA1) | 2 | SC | 5, 6 |
| `0x122`–`0x123` | | – | | Reserved | |
| `0x124`–`0x127` | `0x2411`–`0x2711` | SPRCOLL0–3 (SPR, L0, L1, L2) | 1 each | R, W1C | 5, 3.6 |
| `0x128`–`0x12F` | | – | | Reserved | |

### 5.8 Attribute layer (`0x130`–`0x13F`), a Spectrum extra

| Offset | Port | Name | Width | Access | Spec |
|--------|------|------|-------|--------|------|
| `0x130` | `0x3011` | ATCTL | 1 | RW (PHASE R) | 4, 7.1 |
| `0x131`–`0x133` | `0x3111`–`0x3311` | ATADDR | 3 | RW | 4, 7.1 |
| `0x134` | `0x3411` | ATSTRIDE | 1 | RW | 4, 7.1 |
| `0x135` | `0x3511` | ATSCROLL | 1 | RW | 4, 7.1 |
| `0x136`–`0x13F` | | – | | Reserved | |

### 5.9 DMA engine (`0x140`–`0x23F`)

Channel n (0–3) at `0x140` + n × `0x40`:

| Channel | Offsets | Ports | Register page |
|---------|---------|-------|---------------|
| 0 (`DMX0`) | `0x140`–`0x17F` | `0x4011`–`0x7F11` | `0x1140`–`0x117F` |
| 1 (`DMX1`) | `0x180`–`0x1BF` | `0x8011`–`0xBF11` | `0x1180`–`0x11BF` |
| 2 (`DMX2`) | `0x1C0`–`0x1FF` | `0xC011`–`0xFF11` | `0x11C0`–`0x11FF` |
| 3 (`DMX3`) | `0x200`–`0x23F` | `0x0012`–`0x3F12` | `0x1200`–`0x123F` |

| Offset | Name | Width | Access | Spec |
|--------|------|-------|--------|------|
| `+0x00`–`+0x02` | CTRL | 3 | RW (ignored while BUSY) | 14, 3 |
| `+0x03` | MINTERM | 1 | RW (ignored while BUSY) | 14, 3.1 |
| `+0x04`–`+0x06` | APT | 3 | RW (ignored while BUSY) | 14, 3 |
| `+0x07`–`+0x09` | BPT | 3 | RW (ignored while BUSY) | 14, 3 |
| `+0x0A`–`+0x0C` | DPT | 3 | RW (ignored while BUSY) | 14, 3 |
| `+0x0D`–`+0x0F` | WIDTH | 3 | RW (ignored while BUSY) | 14, 3 |
| `+0x10`–`+0x11` | HEIGHT | 2 | RW (ignored while BUSY) | 14, 3 |
| `+0x12`–`+0x13` | SHIFT (ABIT, BBIT, DBIT) | 2 | RW (ignored while BUSY) | 14, 3 |
| `+0x14`–`+0x15` | ABSTRIDE | 2 | RW (ignored while BUSY) | 14, 3 |
| `+0x16`–`+0x17` | CDSTRIDE | 2 | RW (ignored while BUSY) | 14, 3 |
| `+0x18`–`+0x1B` | VALUE | 4 | RW (ignored while BUSY) | 14, 3 |
| `+0x1C`–`+0x1E` | NEXT | 3 | RW (ignored while BUSY) | 14, 3 |
| `+0x20`–`+0x22` | CHDESC | 3 | RW (ignored while BUSY), CAP | 14, 8.1 |
| `+0x24` | CHCTRL | 1 | S (START, RUN, STOP), RW (PAUSE) | 14, 8.2 |
| `+0x28` | CHSTAT | 1 | R, W1C | 14, 8.3 |
| `+0x2C`–`+0x2E` | CHERR | 3 | R | 14, 8.1 |

`+0x1F`, `+0x23`, `+0x25`–`+0x27`, `+0x29`–`+0x2B` and `+0x2F`–`+0x3F` are reserved, except two bytes in channel 3:

| Offset | Port | Name | Width | Access | Spec |
|--------|------|------|-------|--------|------|
| `0x230` | `0x3012` | DMXINT | 1 | W1C | 14, 8.4 |
| `0x234` | `0x3412` | DMXINTEN | 1 | RW | 14, 8.4 |

### 5.10 Audio (`0x240`–`0x2FF`)

Reserved for sound (spec 13, design plan Q1), under retro68k's names when it is specified. Reads give `0xFF`; writes, including the copper's, do nothing.

### 5.11 Sprite sequencer (`0x300`–`0x30F`), a retro-z80 extra

| Offset | Port | Name | Width | Access | Spec |
|--------|------|------|-------|--------|------|
| `0x300` | `0x0013` | SEQCON | 1 | RW | 17, 8 |
| `0x301`–`0x303` | `0x0113`–`0x0313` | SEQLC | 3 | RW | 17, 8 |
| `0x304` | `0x0413` | SEQMASK | 1 | RW | 17, 8 |
| `0x305` | `0x0513` | SEQSTAT | 1 | R, W1C | 17, 8.1 |
| `0x306` | `0x0613` | SEQSKIP | 1 | R | 17, 8.1 |
| `0x307` | `0x0713` | SEQSKIPL | 1 | R | 17, 8.1 |
| `0x308`–`0x30A` | `0x0813`–`0x0A13` | SEQPT | 3 | R, CAP | 17, 8 |
| `0x30B`–`0x30F` | | – | | Reserved | |

`0x310`–`0x3FF` is free.

## 6. The register page

MMU page `0x3F8` (REGS) shows the registers as memory, in any window, for reads, writes or both (spec 2, section 10). Register r of I/O page p is at offset p × 256 + r: the port with its bytes swapped.

| Offset | I/O page | Contents | Spec |
|--------|----------|----------|------|
| `0x0000`–`0x00FF` | `0x00` | The system page: offset = register number, with the same values, MMU commits and side effects as through I/O. Includes the low-byte-only registers; offset `0x00FE` reads the keyboard with all rows selected | Section 4 |
| `0x0100`–`0x0107` | – | KEYROW0–7: membrane row r alone (with the extra keys and PS/2 keys as port `0xFE` shows them), in port `0xFE`'s read format; read only. Memory only (Spectrum extra) | 12, 8.1 |
| `0x0108`–`0x013F` | – | Reserved | |
| `0x0140`–`0x01FF` | `0x01` | The interrupt pages: register r of page `0x01` at `0x0100` + r, with the same values and commits as through I/O | Section 4.13 |
| `0x0200`–`0x023C` | `0x02` | The debug unit: register r of page `0x02` at `0x0200` + r | Section 4.14 |
| `0x023D`–`0x0FFF` | – | Reserved | |
| `0x1000`–`0x13FF` | `0x10`–`0x13` | The custom block: custom offset k at `0x1000` + k | Section 5 |
| `0x1400`–`0x16FF` | – | PALETTE0 (layer L0) | 2, 10.2; 4, 6.5 |
| `0x1700`–`0x19FF` | – | PALETTE1 (layer L1) | 2, 10.2 |
| `0x1A00`–`0x1CFF` | – | PALETTE2 (layer L2) | 2, 10.2 |
| `0x1D00`–`0x1FFF` | – | SPRPALETTE | 2, 10.2 |

- **Palettes:** entry i of palette p is at `0x1400` + p × `0x300` + 3i: blue, green, red. The blue and green bytes go into the CPU's colour assembly buffer; the red byte writes the entry whole, as rule 7 and as PALDAT. This path does not use or change PALIDX. A rising `LDIR` of 768 bytes copies a palette, and the bytes are the same stream PALDAT takes. The palettes have no I/O page of their own; I/O pages `0x03`–`0x0F` and `0x14`–`0xFF` are reserved, and so are registers `0x00`–`0x3F` of page `0x01` and `0x3D`–`0xFF` of page `0x02`.
- Reserved offsets read `0xFF` and ignore writes.
- Opcode fetches from the register page read `0xFF` (`RST 38h`) and have no side effect (spec 1, section 5.7).
- Register page accesses use no SRAM cycle.
- A window can read ROM or RAM while its writes go to the register page, so `LD (IX+d),A` stores to registers while code and tables are read from the same addresses (spec 2, section 9.6).
- The DMA engine sees the same page at physical address `0x7F0000` (MMU page `0x3F8` × `0x2000`): the custom block at `0x7F1000`, the palettes at `0x7F1400`. The system page, KEYROW and interrupt pages part (`0x7F0000`–`0x7F0FFF`) is an error for it (spec 14, section 4).

## 7. Interrupt sources

From spec 8, section 4. The number is the fixed priority (lower first) and the IM 2 table entry: vector = VECBASE + 2 × number. Source n's enable, pending and raw bits are in byte n div 7 (INTENA0–2, INTPEND0–2, INTRAW0–2), bit n mod 7.

| # | Name | From | Request while | Vector |
|---|------|------|---------------|--------|
| 0 | VBLANK | Video (spec 4) | VIDSTAT.VBLANK and VIDINTEN.VBLANK | VECBASE + 0 |
| 1 | LINE | Video (spec 4) | VIDSTAT.LINE and VIDINTEN.LINE | + 2 |
| 2 | COPPER | Copper (spec 6) | COPSTAT.IRQ and COPCON.IRQEN | + 4 |
| 3 | VIDERR | Video, sprites and the sprite sequencer (specs 4, 5, 17) | VIDSTAT OVERRUN0–2, OVERRUNA, SPRUNDER and their VIDINTEN bits; SEQSTAT.SKIP with SEQCON.IRQEN | + 6 |
| 4 | DMA0 | DMA engine channel 0 (spec 14) | DMXINT.CH0 and DMXINTEN.CH0 | + 8 |
| 5 | DMA1 | DMA engine channel 1 | DMXINT.CH1 and DMXINTEN.CH1 | + 10 |
| 6 | DMA2 | DMA engine channel 2 | DMXINT.CH2 and DMXINTEN.CH2 | + 12 |
| 7 | DMA3 | DMA engine channel 3 | DMXINT.CH3 and DMXINTEN.CH3 | + 14 |
| 8 | – | Not used, as in retro68k | – | + 16 |
| 9 | AUDIO | Reserved for sound (spec 13) | – | + 18 |
| 10 | – | Not used, as in retro68k | – | + 20 |
| 11–14 | TIMER0–TIMER3 | Timers (spec 9) | TMRn_STAT.UNDER and TMRn_CTRL.IRQ | + 22 … + 28 |
| 15 | SERIAL | USB serial (spec 10) | SERIRQ and SERIRQEN | + 30 |
| 16 | SD | Not used in version 1: the SD controller is polled (spec 11), as in retro68k's version 1 | – | + 32 |
| 17 | KEYB | PS/2 keyboard (spec 12) | KBIRQ and KBIRQEN | + 34 |
| 18 | SOFT | Software (spec 8) | SOFTINT.SET until SOFTINT.CLR | + 36 |
| 19 | GEOM | Reserved for the geometry unit (spec 15) | – | + 38 |
| 20 | – | Reserved (kept for accelerator-port pins, spec 8 I7) | – | + 40 |
| 21–22 | – | Do not exist (no enable bits) | – | + 42, + 44 |
| 23 | NONE | Spurious acknowledge, not a source | – | + 46 |

**NMI** (to `0x0066`, not maskable): the Multiface button and the USB BREAK command, allowed by NMICON and reported in NMISTAT (spec 8, section 10). By default the NMI also pages the monitor into window 0 and captures its return address (the NMI set of the interrupt pages, section 4.13; spec 7, section 10.1).

## 8. One source for the numbers

As in retro68k, every register, field, layout and named number is kept in **`fpga/regmap.def`**, a short text file. **`tools/regmap.py`** (standard Python, nothing to install) reads it.

**The file.** One item per line, as retro68k's, with the register's **width in bytes** added:

```
block  NAME PAGE SIZE "text"                    the system page, the custom block
reg    OFFSET NAME WIDTH ACCESS SPEC [fields]   a register of WIDTH bytes (1-4) in the current block
regs   NAME COUNT OFFSET WIDTH ACCESS SPEC      NAME0..NAME(COUNT-1), WIDTH bytes apart
array  NAME COUNT OFFSET STRIDE SPEC ... end    a repeated group (L, SPR, TMR, DMX, MMU)
area   NAME OFFSET SIZE ACCESS SPEC             a table in the register page (palettes, KEYROW)
port   NAME LOWBYTE REGISTER                    a low-byte-only port and its register in page 0x00
const  NAME VALUE ["text"]                      a named number
```

Access is R, W, RW, W1C, RW1C (mixed), SC (set/clear) or S (strobe), with flags: CAP (reading the low byte captures, rule 4), SEP (separate bytes, not one value), COLR (a colour: the red byte commits, rule 7), MMU (byte 1 commits), PAIR (two 2-byte values, as WINX), F (reading has an effect), LOCK (lockable), BUSY (writes ignored while the unit is busy). Fields are `FIELD=BIT` or `FIELD=HIGH:LOW`, numbered in the whole value (bit 8 is bit 0 of the second byte). For example:

```
block CUSTOM 0x10 0x400 "Custom block: port = (offset & 0xFF) << 8 | 0x10 + (offset >> 8)"
reg 0x004 BGCOLOR 3 RW,COLR 4/6.1  BLUE=7:0 GREEN=15:8 RED=23:16
reg 0x00C DMACON  1 SC     4/6.1  AUDEN=1 SPREN=2 BLTEN=3 COPEN=4 BPLEN=5 DMAEN=6 SETCLR=7
array SPR 8 0x010 0x10 5/6
  reg 0x0 PT   3 RW,CAP 5/6    ADDR=21:1
  reg 0xB CTL  1 RW     5/3.3  BPP=1:0 DEPTH=3:2 PAL=7:4
  reg 0xC STEP 4 RW     5/3.4  XSTEP=15:0 YSTEP=31:16
end
block SYSTEM 0x00 0x100 "System page: port = register << 8"
reg 0x20 TIME     4 R,CAP 9/3
reg 0x51 SERSTAT0 1 R     10/7 TXSPACE=7:0
reg 0x53 SERDATA  1 RW,F  10/7
port SERDATA 0x53 0x53
```

**Checks.** The generator checks: every register inside its block, at consecutive addresses, with no overlap; widths of 1–4 bytes; fields inside the width and not overlapping; no name generated twice; every low-byte-only port is a register of page `0x00`; no copper-written register a list needs per line (sprites, layers, video globals) above `0x0EF`; and every register against the tables in this spec (`--verify`), so the two can't disagree.

**Generated files:**

- `firmware/include/hw.inc` for sjasmplus, `firmware/include/hw.h` for C (z88dk), and `fpga/rtl/regmap.vh` for the Verilog decoders.
- **Register names.** A system register's name is its **register number**, which is also its register page offset (`INTID` = `0x0C`, `SYSID` = `0x70`): `ld a,INTID` then `in a,(SYSPAGE)`, or `REGS + INTID` through the register page. A custom register's name is its **custom offset**, which copper lists use (`CMOVE BGCOLOR,0`) and the register page uses (`REGS + REGS_CUSTOM + BGCOLOR`).
- **Ports.** `name_P` is the register's port, for `ld bc,name_P` and `OUT (C),r`: register × 256 for the system page (`SYSID_P` = `0x7000`), (offset & `0xFF`) << 8 | `0x10` + (offset >> 8) for the custom block (`BGCOLOR_P` = `0x0410`). Low-byte-only ports also get their bare port (`SERDATA_PORT` = `0x53`, `KEMPSTON_PORT` = `0x1F`, `ULA_PORT` = `0xFE`). A page `0x01` register's name is its register number, and `name_P` its port, register × 256 + `0x01` (`NMICTL` = `0x48`, `NMICTL_P` = `0x4801`), and a page `0x02` register's likewise (`DBGCTL_P` = `0x0002`). `SYSPAGE` = `0x00`, `IPPAGE` = `0x01`, `DBGPAGE` = `0x02` and `CUSTPAGE` = `0x10` are the pages.
- **Widths.** Every register has `name_N`, its width in bytes (spec 6's `CMOVEN` uses it).
- **Byte names.** Each byte of a multi-byte register has a name too, with its own `_P`: the register's name and the byte's number, lowest first: NAME0, NAME1, NAME2, NAME3 (`TIME0`–`TIME3`, `SDCON1`, `SPRDMA1`, `WDTIME1`, `TMR0_COUNT0`, `SPR0_PT0`, `L1_BPL0PT2`, `DMX2_CHDESC0`). Where the name ends in a digit, or in an index and a letter (the MMU's `MMU0` and `MMU0W`), an underscore goes before the byte's number so that it cannot be read as part of the name: `MMU0_0`, `MMU0_1` (read page), `MMU0W_0`, `MMU0W_1` (write page). Every spec uses these names; there are no L/H byte names. The interrupt pages follow the same rule: `IP0_0`, `IP0W_1`, `NMISAV0_0`, `NMISAV0W_1`. Separate byte registers (section 3.1) keep their own names: CTRL0–CTRL3, INTENA0–2, SERSTAT0 and SERSTAT1, SPRCOLL0–3, KEYMAP0–6.
- **Fields** give `name_FIELD_B` (first bit), `name_FIELD_W` (width in bits) and `name_FIELD_M` (mask), as retro68k's. Magic values are constants (`SYSRESET_MAGIC`, `WDKICK_MAGIC`).
- **Arrays** give the bases (`L0`–`L2`; `SPR0`–`SPR7`; `TMR0`–`TMR3`; `DMX0`–`DMX3`; `MMU0`–`MMU7`), `NAME_NUM` and `NAME_SPAN`, the offsets within the group (`L_BPL0PT`, `SPR_H`, `TMR_COUNT`, `DMX_CHCTRL`), and ready-added names with their ports (`L1_BPL0PT`, `L1_BPL0PT_P`, `TMR2_COUNT`, `DMX2_CHCTRL_P`).
- **Register page:** `REGS_SYSTEM` = `0x0000`, `REGS_KEYROW` = `0x0100`, `REGS_IPPAGE` = `0x0100` (add a page `0x01` register number), `REGS_DBGPAGE` = `0x0200` (add a page `0x02` register number), `REGS_CUSTOM` = `0x1000`, `REGS_PALETTE` = `0x1400`, `REGS_PAL_SPAN` = `0x300`.
- **Interrupts:** `INT_name` (the source number), `INTB_name` (its bit) and `INTR_name` (its byte), as spec 8 uses them.
- **Video constants:** `VID_X0`, `VID_Y0`, `VID_W`, `VID_H`, `BEAM_W`, `BEAM_H` (spec 4, section 3.3).
- `CPORT(offset)` gives the port of a computed custom offset (`CPORT(SPR0+SPR_H)`), in `hw.h` and in `hw.inc` (open point R1).
- `regmap.vh` also gives the capture decode and widths (rule 4), the colour, MMU and interrupt page decodes, the set/clear decodes and the low-byte-only port decode. The copper and the DMA engine need no table of widths: they write each byte directly (rule 3).

GitHub runs `python3 tools/regmap.py --verify` on every push, which fails if this spec, the `.def` file and the generated files don't all agree. `tools/README.md` explains the file format and the generated names.

## 9. Test plan

1. `regmap.py` builds from `regmap.def`, its checks pass, and `--verify` agrees with this spec, in CI.
2. **Port decode:** in simulation, every system register answers at port register × 256 and nowhere else; every custom offset at its port in pages `0x10`–`0x13`; the five low-byte-only ports answer with every high byte and also at their page form; `IN A,(page)` with A = register reads that register; every reserved page reads `0xFF` with no strobe; every unused register, offset and register page offset reads `0xFF`; write-only registers read `0x00`.
3. **Reset values:** every register reads its spec's reset value after reset.
4. **Multi-byte writes:** for each multi-byte register except the MMU pages and the colours, each byte takes effect when it is written, in any order, and reads back at once; `LD (nn),HL`, `PUSH`, `LDDR` and unrolled `OUTI`s give the same value; a copper write and a DMA write between the CPU's bytes land in bus order, and the last write to each byte wins. **MMU pages:** byte 0 alone changes nothing; byte 1 commits with the held byte 0, or the current one. **Colours:** blue and green alone change nothing; red writes the colour whole, through PALDAT, the register page and BGCOLOR, with one buffer per master, so a copper colour between the CPU's blue and red does not mix with it.
5. **Captures:** for each register of rule 4, the value read low byte first while the register changes is always a value it really had, through ports and with `LD HL,(nn)`; higher bytes of the tagged register return the capture however late; higher bytes of another register read live; reading another capturing register's low byte replaces the capture; an interrupt handler that reads a counter between a program's bytes replaces the program's capture, as rule 4 says; a DMA job's capture is separate from the CPU's; SERSTAT0 and SERSTAT1 read live.
6. **Exceptions:** each row of section 3.1 behaves as its spec says: set/clear bytes, SPRDMA1 acting on SPRDMA0, PALDAT stepping and its byte order reset by either PALIDX byte, data ports taking exactly one byte through a port and through the register page, a port `0xFE` border write showing mid-line while a BGCOLOR write waits for the next line's picture, MMU0_1 to MMU7_1 setting the write page, a sprite started by a CTL write only and stopped by the vertical blank, SDCOUNT1 starting a run, locks, busy writes ignored.
7. **Register bus:** a copper write in the same clock as a CPU strobe goes first and the CPU's access still completes in time; a DMA engine access waits for both and never delays them; with all three busy, no access is lost.
8. **Copper reach:** MOVE reaches `0x000`–`0x0EF`, MOVR `0x000`–`0x0FF` (writes to `0x0F0`–`0x0FF` ignored), MOVEF `0x000`–`0x3FF`; nothing the copper does reaches the system page.
9. **DMA engine reach:** jobs read and write the custom block and the palettes at `0x7F1000`–`0x7F1FFF`, read the boot ROM, and stop with an error on the system page and KEYROW (`0x7F0000`–`0x7F0FFF`).
10. **Register page:** each system register at its offset, each custom register at `0x1000` + offset, with the same values and side effects; an MMU page started through a port commits through memory and the other way round; `LD (nn),HL` writes a 2-byte register in one instruction; the palettes read and write at their offsets without touching PALIDX; KEYROW0–7 match port `0xFE`; opcode fetches read `0xFF`.
11. **Interrupt pages:** every register of section 4.13 at its port and at register page offset `0x0100` + register; registers `0x00`–`0x3F` of page `0x01` read `0xFF` through I/O with no strobe; the page registers commit on byte 1 through both paths; the copper and the DMA engine cannot reach them. The behaviour is tested in spec 2, section 14, and spec 1, section 13.
12. **Debug unit:** every register of section 4.14 at its port and at register page offset `0x0200` + register; registers `0x3D`–`0xFF` of page `0x02` read `0xFF`; the copper and the DMA engine cannot reach them. The behaviour is tested in spec 18, section 11.
13. **Generated files:** the sjasmplus, C and Verilog files agree with this spec; `CPORT` gives the same ports as the `_P` names; every code example in specs 1–14 assembles with `hw.inc`.

## 10. Open points

| # | Item |
|---|------|
| R1 | `CPORT(offset)` as a function-like define in sjasmplus (spec 5 uses it): to be checked. If sjasmplus cannot, `hw.inc` gives only the `_P` names and computed ports are written out as `((off & 0xFF) << 8) \| 0x10 \| (off >> 8)` |
| R2 | Bit layouts in each spec should be checked against the rules of section 3 once more when the generator is written (as retro68k's R2) |
| R3 | Closed (design plan, branch 11): register writes are direct, with no latches, for the CPU, the copper and the DMA engine (rules 2 and 3). Latches for every wide register would have cost about 1,000–2,000 LUTs. Three exceptions stay: the MMU pages (byte 1 commits), the colours (the red byte commits, one assembly buffer per master) and the captures (one tagged capture per master, rule 4). Software changes wide display registers in the vertical blank or with the copper |
| R4 | Closed: unused addresses read `0xFF` (design plan, branch 11), not 0 as in retro68k. Bytes that belong to a register read 0 in their reserved bits |
| R5 | Free space. System page: `0x17`–`0x1E`, `0x24`–`0x27`, `0x4C`–`0x4F`, `0x5F`, `0x69`–`0x6A`, `0x6E`–`0x6F`, `0xC0`–`0xFD`, `0xFF` (`0x0F` reserved). `0x7C`–`0x7F` (spec 7, SY11). Custom block: `0x00D`–`0x00F`, `0x0FA`–`0x0FF`, `0x112`–`0x117`, `0x122`–`0x123`, `0x128`–`0x12F`, `0x136`–`0x13F`, the DMA channels' reserved bytes, `0x30B`–`0x30F` (kept for the sprite sequencer), `0x310`–`0x3FF`. Page `0x01`: registers `0x00`–`0x3F` (reserved through I/O), `0x4A`–`0x4B`, `0x50`–`0x7F`. Page `0x02`: registers `0x06`–`0x0F`, the reserved bytes of each breakpoint and watchpoint, `0x3D`–`0xFF`. Register page: `0x0108`–`0x013F`, `0x023D`–`0x0FFF`. I/O pages `0x03`–`0x0F` and `0x14`–`0xFF`. A block that needs more than its range says so in its own spec and takes it from the free space, not from another block |
| R6 | The audio block (`0x240`–`0x2FF`, 192 bytes) is sized before sound is specified (spec 13, design plan Q1); if it needs more, it takes it from `0x310`–`0x3FF` |
| R7 | The geometry unit's 32 registers (`0xA0`–`0xBF`) and interrupt 19 are reserved for spec 15; its register page view (memory access with LDI and `LD (IX+d)`, design plan branch 10) is offsets `0x00A0`–`0x00BF` like any system register |
| R8 | The palette write delay after a copper WAIT (spec 6, C9) should be listed here once known (as retro68k's R3) |
| R9 | COP2LC changes by itself only at a frame restart with COPCON.RESUME (spec 6, section 6.5), so it has no capture; a CPU that reads it while a background list runs may see a mixed value. Read it while the copper runs the idle list |
| R10 | Closed: byte names are digits everywhere (design plan, branch 11). A multi-byte register's bytes are NAME0–NAME3, lowest first, with an underscore before the digit where the name ends in a digit or an index (`MMU0_0`, `MMU0W_1`); the L/H names of specs 2 and 9 are gone (section 8). The generator makes every byte name from the rule, so `regmap.def` has no `bytes` line |
| R11 | CHDESC changes by itself as a chain runs, so this spec makes it capture on a read of its low byte (rule 4; spec 14, section 8.1). CHERR is set only when a channel stops, so it needs no capture. Proposed: as written |
| R12 | PALDAT is a custom register, so `OTIR` cannot stream a palette (B is the register number). Making it a sixth low-byte-only port would let it (spec 4, V4) |
| R13 | Closed (design plan, branch 11): the DMA engine's port jobs move bytes through SERDATA and SDDATA on the register bus, paced by each unit's ready signal (spec 1, section 4.2; specs 10, 11, 14); there is no direct port path. The engine reads the boot ROM through the ROM's second block RAM port, not the register bus (section 3.2) |
| R14 | The DMA engine has one capture and one colour assembly buffer for its four channels (rules 4 and 7). Two channels that read counters, or write colours, at the same time can replace each other's capture or mix colour bytes. A capture and a buffer per channel would cost about 20 bytes more (spec 14, D11). Proposed: one each, as written; run such jobs on one channel |
| R15 | Closed: the sprite sequencer (spec 17) is a fourth register bus master, after the CPU and before the DMA engine (section 3.2), and adds one capture (SEQPT) and one more cause of VIDERR (section 7). Spec 1, section 4.2 (the bus masters), spec 2, section 5 (the free order), spec 6, section 5.1 and spec 8, section 4 (VIDERR) now include it |
| R16 | Closed (design plan, branch 17): the interrupt pages and stack capture take registers `0x40`–`0xFF` of I/O page `0x01` (section 4.13), because the system page's free registers are too few; their register page offsets `0x0140`–`0x01FF` follow the page form. The NMI monitor registers moved there from `0x7C`–`0x7F` of page `0x00`. Registers `0x00`–`0x3F` of page `0x01` stay reserved, so KEYROW0–7 keep no port |
