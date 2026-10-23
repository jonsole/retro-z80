# Spec 3: Register map

Status: **draft**

## 1. Summary

This is the one place that lists every port in the machine and the rules every register follows. Bit layouts stay in each block's spec, linked from here, so each is described only once.

| Item | Value |
|------|-------|
| Where | Z80 I/O space, and also memory through the register page (MMU page `0x3F8`) in any window. Both ways reach the same registers |
| Decoding | Low 8 bits of the port address (A7–A0); A15–A8 are ignored, except at port `0xFE` (spec 12) |
| Size | Every register is 8 bits; wider values are 2 or 3 consecutive ports |
| Unmapped and reserved ports | Read `0xFF`; writes are ignored |
| Copper reach | Ports `0x30`–`0x9F` (spec 6) |
| Source file | `fpga/regmap.def`, turned into `hw.inc` (sjasmplus), `hw.h` (C) and `regmap.vh` (Verilog) by `tools/regmap.py` |

## 2. Memory map

The Z80's 64 KB is eight 8 KB windows (spec 2, section 6). Each window has a read page and a write page; committing the read page also sets the write page.

| Z80 address | Window | Reset mapping (read and write) |
|-------------|--------|-------------------------------|
| `0x0000`–`0x1FFF` | 0 | Boot ROM page `0x3FC` |
| `0x2000`–`0x3FFF` | 1 | Boot ROM page `0x3FD` |
| `0x4000`–`0x5FFF` | 2 | SRAM page `0x000` |
| `0x6000`–`0x7FFF` | 3 | SRAM page `0x001` |
| `0x8000`–`0x9FFF` | 4 | SRAM page `0x002` |
| `0xA000`–`0xBFFF` | 5 | SRAM page `0x003` |
| `0xC000`–`0xDFFF` | 6 | SRAM page `0x004` |
| `0xE000`–`0xFFFF` | 7 | SRAM page `0x005` |

| Page | Meaning |
|------|---------|
| `0x000`–`0x1FF` | SRAM, 8 KB each (4 MB); on a 2 MB board `0x100`–`0x1FF` mirror `0x000`–`0x0FF` |
| `0x200`–`0x3F7` | Reserved: reads give `0xFF`, writes are ignored |
| `0x3F8` | REGS: the register page (section 5) |
| `0x3F9`–`0x3FA` | Reserved |
| `0x3FB` | NONE: reads give `0xFF`, writes are ignored (a write page of NONE makes a window read-only) |
| `0x3FC`–`0x3FF` | Boot ROM (32 KB of block RAM) |

The chipset (video, sprites, copper) uses 22-bit physical SRAM byte addresses, not the MMU: physical address = page × 8192 + offset. It cannot see the register page.

## 3. Rules for all registers

1. **Decoding.** Only A7–A0 select a port, so `OUT (n),A`, `OUT (C),r` with any B, `OTIR` and `INIR` all reach the same port. Port `0xFE` also reads A15–A8 as the Spectrum keyboard row select.
2. **Multi-byte values.** A value wider than 8 bits sits at consecutive ports, **low byte at the lowest port**. Writing a lower byte puts it in a latch; writing the **highest byte commits the whole value at once**, using the latched lower bytes. So the hardware never sees half a value. To change only the high byte, write just the high byte; the latch keeps the last lower bytes written.
3. **The copper has its own latch**, separate from the CPU's, so a copper write never mixes with half a CPU write (spec 6).
4. **Reading a multi-byte value.** Reading gives the committed value, not the latch. For values that change by themselves (timers, the frame counter, the beam), **reading the lowest byte captures the whole value**, and the higher bytes read the captured copy; read low byte first.
5. **Status bits.** Sticky flags are cleared by writing 1 to them; writing 0 leaves them alone. Live bits ignore writes.
6. **Reserved bits** read 0 and should be written 0.
7. **Index and data ports.** Big tables (palette, sprite attributes) are reached through an index port and a data port. The index steps after each data access, so `OTIR` and `INIR` stream a whole table.
8. **Bus timing.** An I/O access takes the Z80's normal 4 T-states (one automatic wait), with no extra waits; a register page access takes a normal 3 T-state memory cycle. If the copper writes a register in the same clock, the copper goes first and the CPU's access slips by one clock, inside its spare time (spec 1).
9. **I/O and memory are the same registers.** A write through a port and a write through the register page go to the same register and the same CPU latch, so a value can even be started through one and committed through the other. Reads have the same side effects both ways.
10. **Write order through memory.** `LD (nn),HL`, `LD (nn),DE/BC/IX/IY`, `LDI` and `LDIR` write the low byte first, so they write multi-byte registers correctly. `PUSH`, `EX (SP),HL` and `LDDR` write the high byte first: don't use them on registers.

### 3.1 Exceptions

| Port | Exception | Why | Spec |
|------|-----------|-----|------|
| `0x19` INTREQH | Bit 7 = 1 sets the software interrupt instead of clearing bits | No room for a separate SET port | 8 |
| `0x46` PALDAT | One port for 2-byte entries: the low byte is held, the high byte commits the entry and steps the index | Lets `OTIR` stream the palette | 4 |
| `0x80` SPRIDX | Not latched: a write sets index bits 7–0 at once and clears bit 8 | One write reaches sprites 0–15 | 5 |
| `0x82` SPRDATA | Attribute bytes are written one by one; each multi-byte field commits on its highest byte (XH, YH, pointer byte 6, step high bytes). Writes made during the sprite scan (the last 32 clocks of a line) are queued and applied after it; reads meanwhile return the old value | Same rule, inside the table; the scan must see a stable table | 5 |
| `0x28`, `0x2C`, `0xA0` | Data ports read from or write to a FIFO or a shift register; reading has an effect | They are streams, not values | 10, 11, 12 |

## 4. Port list

### 4.1 System and MMU (`0x00`–`0x17`), not reachable by the copper

| Port | Name | Access | Meaning | Spec |
|------|------|--------|---------|------|
| `0x00` | SYSID | R | `0x5A` ("Z") | 7 |
| `0x01` | SYSVER | R | Build version: major (7–4), minor (3–0) | 7 |
| `0x02` | CPUSPEED | R/W | 0 = 3.5, 1 = 7, 2 = 14, 3 = 28 MHz; reset 3 | 1, 7 |
| `0x03` | RESETWHY | R | Cause of the last reset | 7 |
| `0x04` | SYSCFG | R | RAM size, CPU type | 7 |
| `0x05` | SYSCON | R/W | ROMWE, ROMLOCK | 7 |
| `0x06` | SYSRESET | W | `0xA5` = soft reset | 7 |
| `0x07` | SYSBTN | R | Multiface and DivMMC buttons | 7 |
| `0x08`+2n | MMUnL | R/W | Window n page, bits 7–0 (latched) | 2 |
| `0x09`+2n | MMUnH | R/W | Page bits 9–8 (bits 1–0); commits the read page and sets the write page to it | 2 |

### 4.2 Interrupts and timers (`0x18`–`0x27`), not reachable by the copper

| Port | Name | Access | Meaning | Spec |
|------|------|--------|---------|------|
| `0x18` | INTREQL | R/W1C | Requests, sources 0–7 | 8 |
| `0x19` | INTREQH | R/W | Requests, sources 8–11; NMI flags; SET (bit 7) | 8 |
| `0x1A` | INTENL | R/W | Enables, sources 0–7 | 8 |
| `0x1B` | INTENH | R/W | Enables, sources 8–11 and the NMI sources | 8 |
| `0x1C` | INTPENDL | R | Request AND enable, 0–7 | 8 |
| `0x1D` | INTPENDH | R | Request AND enable, 8–11 | 8 |
| `0x1E` | INTVEC | R/W | IM 2 vector base (bits 7–5) | 8 |
| `0x1F` | KEMPSTON | R | Joystick 1, same value as JOY1 (`0xA5`), at the Spectrum's Kempston port; writes ignored. Owned by spec 12 | 12 |
| `0x20`–`0x21` | T0L, T0H | R/W | Timer 0 | 9 |
| `0x22` | T0CTRL | R/W | Timer 0 control | 9 |
| `0x23`–`0x24` | T1L, T1H | R/W | Timer 1 | 9 |
| `0x25` | T1CTRL | R/W | Timer 1 control (can chain from timer 0) | 9 |
| `0x26`–`0x27` | FRAMEL, FRAMEH | R/W | 16-bit frame counter | 9 |

### 4.3 Serial and SD card (`0x28`–`0x2F`), not reachable by the copper

| Port | Name | Access | Meaning | Spec |
|------|------|--------|---------|------|
| `0x28` | SERDATA | R/W | Receive / transmit FIFO | 10 |
| `0x29` | SERSTAT | R/W1C | FIFO status, TXOVF | 10 |
| `0x2A` | SERCTL | R/W | Enable, control sequences, flushes | 10 |
| `0x2B` | SERLEVEL | R/W | Interrupt levels, receive timeout | 10 |
| `0x2C` | SDDATA | R/W | SPI byte exchange | 11 |
| `0x2D` | SDCTL | R/W | CS0, CS1, AUTO | 11 |
| `0x2E` | SDDIV | R/W | SPI clock divider | 11 |
| `0x2F` | SDSTAT | R | BUSY, MISO | 11 |

### 4.4 Sound (`0x30`–`0x3F`)

Reserved until sound is decided (spec 13). Reads give `0xFF`; copper writes do nothing.

### 4.5 Video (`0x40`–`0x7F`)

| Port | Name | Meaning | Spec 4 |
|------|------|---------|--------|
| `0x40` | VIDCTL | Layer enables: bitmap, tiles, attributes; BMFRONT (bit 3): bitmap in front of the tiles | 9 |
| `0x41` | VIDSTAT | VBLANK, LINE, OVERRUN and per-layer late flags (W1C); FLASH, INVBL (live) | 8 |
| `0x42`–`0x43` | BGCOL0–1 | Background colour, `0x0RGB` | 3 |
| `0x44`–`0x45` | PALIDX0–1 | Palette index, 9 bits | 3.3 |
| `0x46` | PALDAT | Palette data (see 3.1) | 3.3 |
| `0x47`–`0x48` | LINECMP0–1 | Line compare | 8 |
| `0x49`–`0x4A` | HBEAM0–1 | Display beam pixel (R; reading HBEAM0 captures all four bytes) | 8 |
| `0x4B`–`0x4C` | VBEAM0–1 | Display beam line (R) | 8 |
| `0x4D` | ATCTL | Attribute target, cell height, flash, flash rate | 7 |
| `0x4E`–`0x50` | ATADDR0–2 | Attribute map address | 7 |
| `0x51` | ATSTRIDE | Bytes per cell row | 7 |
| `0x52` | ATSCROLL | Fine X and Y | 7 |
| `0x53` | BMCTL | Depth, hi-res, 576 lines, transparency, X wrap | 5.5 |
| `0x54` | BMBANK | Bitmap palette bank | 5 |
| `0x55`–`0x57` | BMADDR0–2 | Bitmap address (line address base) | 5.2 |
| `0x58`–`0x59` | BMSTRIDE0–1 | Line stride, signed | 5.2 |
| `0x5A`–`0x5B` | BMSCRX0–1 | X scroll | 5.3 |
| `0x5C`–`0x5D` | BMSCRY0–1 | Y scroll | 5.2 |
| `0x5E`–`0x5F` | BMHEIGHT0–1 | Y wrap line count | 5.2 |
| `0x60` | TLCTL | Depth, hi-res, 576 lines, transparency; MAPW (bits 6–5: 32/64/128 wide), MAPH (bit 7: 32/64 high) | 6.3 |
| `0x61` | TLBANK | Tile palette bank, high bits | 6.3 |
| `0x62`–`0x64` | TLMAP0–2 | Map address | 6.1 |
| `0x65`–`0x67` | TLTILE0–2 | Tile pattern address | 6.1 |
| `0x68`–`0x69` | TLSCRX0–1 | Tile X scroll | 6 |
| `0x6A`–`0x6B` | TLSCRY0–1 | Tile Y scroll, 9 bits | 6 |
| `0x6C`–`0x6F` | | Reserved | |
| `0x70`–`0x77` | BMXS, BMXE, BMYS, BMYE | Bitmap window, 2 bytes each | 5.4 |
| `0x78`–`0x7F` | TLXS, TLXE, TLYS, TLYE | Tile window, 2 bytes each (also the attribute layer's when it targets tiles) | 6 |

### 4.6 Sprites (`0x80`–`0x8F`)

| Port | Name | Meaning | Spec 5 |
|------|------|---------|--------|
| `0x80` | SPRIDX | Attribute index bits 7–0 (sprite × 16 + byte); clears bit 8 | 6 |
| `0x81` | SPRIDXH | Index bit 8 | 6 |
| `0x82` | SPRDATA | Attribute data, index steps | 2.1 |
| `0x83` | SPRCTL | Sprites on; which layers count for collisions | 6 |
| `0x84` | SPRSTAT | COLL, PFCOLL, DROP, WIDE, LATE (W1C) | 6 |
| `0x85` | SPRIEN | Interrupt enable per SPRSTAT bit | 6 |
| `0x86` | SPRLIMIT | Fetch budget, cycles per line | 5.2 |
| `0x87` | SPRDROP | First sprite left out or cut, and why (R) | 5 |
| `0x88`–`0x8B` | SPRCOLL0–3 | Sprite–sprite collision bits (W1C) | 3 |
| `0x8C`–`0x8F` | SPRPFC0–3 | Sprite–playfield collision bits (W1C) | 3 |

### 4.7 Copper (`0x90`–`0x9F`)

| Port | Name | Meaning | Spec 6 |
|------|------|---------|--------|
| `0x90` | COPCTRL | Copper on | |
| `0x91` | COPSTAT | WAITING, STOPPED (live); ERR, IRQ, LATE, OVER (W1C) | |
| `0x92` | COPC | Counter C | |
| `0x93`–`0x95` | COPLC0–2 | Program start address | |
| `0x96`–`0x98` | COPX0–2 | Pointer X | |
| `0x99`–`0x9B` | COPY0–2 | Pointer Y | |
| `0x9C` | COPD | Counter D | |
| `0x9D`–`0x9F` | COPPC0–2 | Current address (R); writing the high byte jumps | |

### 4.8 Input (`0xA0`–`0xA7`, `0xFE`), not reachable by the copper

| Port | Name | Meaning | Spec 12 |
|------|------|---------|---------|
| `0xA0` | KBDATA | PS/2 FIFO read; write sends to the keyboard | |
| `0xA1` | KBSTAT | AVAIL, TXBUSY; error flags (W1C) | |
| `0xA2` | KBCTL | Enable, error interrupt, flush | |
| `0xA3` | KEYX5 | Extra Next keys, column 5 | |
| `0xA4` | KEYX6 | Extra Next keys, column 6 | |
| `0xA5` | JOY1 | Joystick 1, Kempston bit order, 1 = pressed | |
| `0xA6` | JOY2 | Joystick 2 | |
| `0xA7` | INCTL | Mega Drive pads, extra-key mapping, bit 6 of `0xFE` | |
| `0xFE` | KEYROWS | Read: Spectrum keyboard, A15–A8 select rows, bits 4–0 active low. Write: bits 2–0 border (sets BGCOL to a Spectrum colour, spec 4), bit 4 beeper | |

### 4.9 MMU write pages (`0xA8`–`0xB7`), not reachable by the copper

| Port | Name | Access | Meaning | Spec |
|------|------|--------|---------|------|
| `0xA8`+2n | MMUnWL | R/W | Window n write page, bits 7–0 (latched) | 2 |
| `0xA9`+2n | MMUnWH | R/W | Write page bits 9–8 (bits 1–0); commits the write page only | 2 |

### 4.10 Interrupt and NMI extras (`0xB8`–`0xBD`), not reachable by the copper

| Port | Name | Access | Meaning | Spec |
|------|------|--------|---------|------|
| `0xB8` | INTHIGH | R | Highest pending interrupt source, `0x8F` if none (moved from `0x1F`) | 8 |
| `0xB9` | NMICTL | R/W | EN (bit 0, 1 after reset): page the monitor in on NMI; INNMI (bit 1, read only) | 7 |
| `0xBA`–`0xBB` | NMISAVL, NMISAVH | R | Window 0's read page saved at the last NMI | 7 |
| `0xBC`–`0xBD` | NMISAVWL, NMISAVWH | R | Window 0's write page saved at the last NMI | 7 |

### 4.11 Reserved

`0xBE`–`0xFD` and `0xFF`: reserved for the DMA engine, sound and later blocks.

## 5. The register page

MMU page `0x3F8` (REGS) shows the registers as memory. Map it into any window, for reads, writes or both (spec 2, section 6.6).

| Offset | Contents | Notes |
|--------|----------|-------|
| `0x0000`–`0x00FF` | Ports `0x00`–`0xFF` | Offset = port number; same values, latches and side effects as I/O. Offset `0x00FE` reads the keyboard with all rows selected (any key) |
| `0x0100`–`0x0107` | KEYROW0–7 | Spectrum keyboard row r alone, in port `0xFE`'s format (bits 4–0 active low, bit 6 from INCTL.EAR6, bits 7 and 5 = 1); read only. Row r is the row port `0xFE` selects with address line A(8 + r) = 0 (spec 12) |
| `0x0108`–`0x01FF` | Reserved | |
| `0x0200`–`0x03FF` | Sprite attribute table | Sprite n at `0x0200` + 16n, in spec 5's byte layout and with its commit rules; no index port needed |
| `0x0400`–`0x07FF` | Palette | Entry n at `0x0400` + 2n: the even byte (green, blue) is held, the odd byte (red) commits the entry (spec 4). Does not touch PALIDX |
| `0x0800`–`0x1FFF` | Reserved | Read `0xFF`, writes ignored (room for later tables: copper, DMA engine, sound) |

- Opcode fetches from the register page read `0xFF` and have no side effect.
- Register page accesses use no SRAM cycle.
- Because a window's read and write pages are separate, a window can read ROM or RAM while its writes go to the registers: for example `LD (IX+d),A` stores to registers while code and tables are read from the same addresses.

## 6. Interrupt sources

Numbers are the fixed priority (lower first); the IM 2 vector is INTVEC + 2 × number (spec 8).

| # | Source | Kind | From |
|---|--------|------|------|
| 0 | VBLANK | Event | Spec 4 |
| 1 | LINE | Event | Spec 4 |
| 2 | COPPER | Event | Spec 6 |
| 3 | SPRITE | Event | Spec 5 |
| 4 | OVERRUN | Event | Spec 4 |
| 5 | TIMER0 | Event | Spec 9 |
| 6 | TIMER1 | Event | Spec 9 |
| 7 | SERRX | Level | Spec 10 |
| 8 | SERTX | Level | Spec 10 |
| 9 | KEYBOARD | Level | Spec 12 |
| 10 | SOUND | Reserved | Spec 13 |
| 11 | SOFT | Event | Spec 8 |

NMI (to `0x0066`): Multiface button, USB BREAK.

## 7. regmap.def

As in retro68k, `fpga/regmap.def` is the source of truth. Each line names a port, its width in bytes, its access and its block; `tools/regmap.py` checks that no two registers overlap, that multi-byte values are consecutive, and that the copper's reach is right, then writes:

- `firmware/include/hw.inc` for sjasmplus (`PORT_BMADDR0 EQU 0x55`, bit masks)
- `firmware/include/hw.h` for z88dk C
- `fpga/rtl/regmap.vh` for the Verilog decoders

## 8. Test plan

1. `regmap.py` builds from `regmap.def` and its checks pass in CI.
2. In simulation, every port in this list answers at its address and nowhere else; reserved ports read `0xFF`; A15–A8 do not change any port but `0xFE`.
3. For each multi-byte register: writing only the low byte changes nothing; writing the high byte commits; a copper write between the CPU's two writes does not disturb either.
4. For counters and the beam: reading the low byte captures; the high byte read later matches the capture.
5. The copper can only name ports `0x30`–`0x9F` (its 7-bit port field); the reserved port codes stop it and set COPSTAT.ERR (spec 6).
6. Register page: each port answers at its offset with the same value and side effects as through I/O; a 2-byte value started through a port commits through memory and the other way round; `LD (nn),HL` commits a 2-byte register in one instruction; the sprite table and palette read and write at their offsets; KEYROW0–7 match port `0xFE`; opcode fetches read `0xFF`.

## 9. Open points

| # | Item | Plan |
|---|------|------|
| R1 | Kempston joysticks at port `0x1F` | Closed: `0x1F` reads joystick 1; INTHIGH moved to `0xB8` |
| R2 | Port `0xFE` writes | Closed: border (bits 2–0) and beeper (bit 4), spec 12 |
| R3 | 60 of 64 video ports are used, 16 of 16 sprite ports | A second video bank or index port if later features need more |
| R4 | DMA engine ports | Take from `0xBE` up when it is specified |
| R5 | Should the copper and DMA engine also see the palette and sprite table directly (as in the register page) rather than through index ports? | Not needed for version 1 |
