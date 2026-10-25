# Spec 16: Boot ROM

Status: **draft**

This spec covers retro-z80's boot ROM: what is in its four pages, how it starts the machine, the memory it keeps for itself, what a program finds when it starts, the ROM calls a program makes through `RST` instructions, and the Z80 parts of the monitor, the loader and the boot file. The monitor's commands, the upload protocol, the image header and the PC tool are shared with retro68k and are in the shared spec **"Monitor and upload protocol"** ([`monitor.md`](monitor.md)); this spec gives only what that spec leaves to each machine (its section 11). The hardware the ROM uses is in spec 7 (reset, the boot ROM's block RAM, the boot console, the NMI monitor paging), spec 2 (the MMU) and the specs of each unit.

The design plan's branch 16 sets the frame: the boot ROM **stays in window 0** (`0x0000`–`0x1FFF`) with RST entry points to its console routines, like a Spectrum ROM, and windows 1–7 are SRAM, so programs get 56 KB.

## 1. Summary

| Item | Value |
|------|-------|
| ROM | 32 KB of block RAM, MMU pages `0x3FC`–`0x3FF` (spec 7, section 4) |
| Page 0 | Always in window 0 while a program runs: the RST entry points, start-up, the console, the keyboards, the ROM calls, the monitor's core |
| Page 3 | The NMI monitor page (spec 7, section 10.1): the NMI entry, which then hands over to the same monitor |
| ROM calls | `RST 08h` print a character, `RST 10h` read a key, `RST 18h` print a string, `RST 20h` test for a key, `RST 28h` a numbered function (the number in the byte after it), `RST 30h` break into the monitor, `RST 38h` the trap (section 7) |
| Registers | A call keeps every register except its outputs and F; the alternate set, IX, IY and I are never touched |
| Program memory | Windows 1–7 = SRAM pages 1–7, so a CPU address is its own physical address: 56 KB, `0x2000`–`0xFFFF` |
| Stack | SP = `0xFFFE` at entry, holding the address of the ROM's exit (`0x0040`): a `RET` ends the program |
| Interrupts | IM 2, DI; I and VECBASE point at the ROM's table (`0x1FD0`); every source off at the controller. A program that uses interrupts makes its own table |
| Console | On: L0 shows the 80 × 30 text console (spec 7, section 5.1), which the ROM calls print to |
| Speed | 20 MHz (CPUSPEED 0) |
| Kept SRAM | Pages `0x0F8`–`0x0FF` (physical `0x1F0000`–`0x1FFFFF`): the resident image (BASIC), the console map and its state, the font, the monitor's workspace (section 5) |
| Start-up keys | M, U, D on the Spectrum keyboard or a PS/2 keyboard; the DivMMC button for M |
| Boot file | `BOOT.Z80` on the SD card; BASIC is `BASIC.Z80` |
| BASIC | BBC BASIC (Z80) as a resident image in write-protected SRAM; started at start-up or by `X` (section 10) |
| Debugging | Hardware breakpoints for `G addr break`, the step command `N`, and the debug stub for VS Code (`debug.md`), all on the debug unit (spec 18) and the NMI (section 8.8) |
| Without the FT232H | The monitor on the screen and keyboards; programs from the SD card or typed in. Upload needs the module |

## 2. Comparison with retro68k

| retro68k | retro-z80 | Why |
|----------|-----------|-----|
| Boot ROM at `0xF80000`, and an overlay at address 0 after reset | The ROM is MMU pages; page 0 stays in window 0 for good | Forced: the Z80's restarts and NMI are at fixed low addresses, and the MMU already maps the ROM at reset (spec 7) |
| A program calls the ROM as retro68k chooses | `RST` instructions and `RST 28h` with a function number, like a Spectrum ROM | Z80: `RST` is a one-byte call; design plan branch 16 |
| Vectors in Chip RAM at 0 | IM 2 with I and VECBASE; the ROM's table in ROM, a program's own in SRAM | Forced: the Z80's interrupt model (spec 8) |
| Supervisor mode, SR `0x2700` at entry | DI, IM 2 | Z80 |
| Console: an 8 × 16 font in a 1 bpp bitmap | An 8 × 8 font on a 1 bpp tile map, shown 2× tall (spec 7, section 5.1) | Spec 7 |
| Disassembler optional | In the ROM | Design plan branch 16 |
| A 1000 Hz timer tick set up at start-up (its spec 7) | No tick: the ROM polls, and a program starts with the timers off | The ROM needs no interrupts, so a program owns all of them |
| – | A resident image (BASIC) in write-protected SRAM | Design plan branch 13 |
| – | The NMI monitor page (a Spectrum extra) hands over to the monitor; the NMI's PC and SP come from the stack capture, not the stack | Spec 7, section 10.1; the interrupt pages are a retro-z80 extra (spec 2, section 9.7) |
| – | `P` addresses: the MMU's page space | The Z80 sees only 64 KB at a time |
| – | The `P` (ports) command | Z80 I/O space |

Everything in the shared spec is the same on both machines.

## 3. The ROM's pages

| ROM page | MMU page | ROM offset | Contents |
|----------|----------|------------|----------|
| 0 | `0x3FC` | `0x0000` | The entry table (section 3.1); start-up; the console driver; the keyboards and the serial link; the ROM calls; the monitor's core (line editor, command table, entry and exit); the IM 2 table at `0x1FD0` |
| 1 | `0x3FD` | `0x2000` | The monitor's commands, the loader and CRC-32, the SD card and FAT32 reader, the self-test (`selftest.asm`) |
| 2 | `0x3FE` | `0x4000` | The console font (the first 2 KB, offset `0x4000`), the CRC-32 table (1 KB), the disassembler and its tables, the help text |
| 3 | `0x3FF` | `0x6000` | The NMI page: the NMI entry at `0x0066` (offset `0x6066`), which saves the program's state and switches window 0 back to page 0 (section 8.6). The rest is spare |

The split between pages 1–3 is the build's; only page 0's entry table (section 3.1), the IM 2 table and the font's offset are fixed for programs.

### 3.1 The entry table: page 0, `0x0000`–`0x00FF`

| Address | Name | Contents |
|---------|------|----------|
| `0x0000` | RESET | `DI`, then the start-up code (section 4) |
| `0x0008` | `RST 08h` | PUTC (section 7) |
| `0x0010` | `RST 10h` | GETC |
| `0x0018` | `RST 18h` | PUTS |
| `0x0020` | `RST 20h` | POLLC |
| `0x0028` | `RST 28h` | CALL: a function by number |
| `0x0030` | `RST 30h` | BREAK |
| `0x0038` | `RST 38h` | TRAP |
| `0x0040` | EXIT | A jump here ends the program: `Program ended.` and the monitor. A program's first return address |
| `0x0048` | ROMID | The identity block: ASCII `RZ80` (4 bytes), version major and minor (2 bytes), the highest `RST 28h` function code (1 byte), 0 (1 byte) |
| `0x0050` | ROMDATE | The build date as ASCII `YYYY-MM-DD`, then a zero, padded with zeros to `0x005F` |
| `0x0060` | – | `JP` to the monitor's common entry: the NMI page switches window 0 back to page 0 with the `OUT` just before this address in page 3, so its next fetch is here (section 8.6) |
| `0x0066` | NMI | A jump to the monitor's NMI entry, for an NMI taken with NMICTL.EN = 0 while page 0 is in window 0 (spec 7, section 10.1) |
| `0x0069`–`0x00FF` | – | The ROM's own code |

A boot ROM image uploaded with TARGET 1 and LOAD 0 must have `RZ80` at `0x0048`, or the loader refuses it (code 2), so a file that is not a boot ROM is never written to the ROM.

## 4. Start-up

### 4.1 What the ROM does today

The boot ROM in `firmware/boot/` is the bring-up ROM of tickets #4–#21 with the first step of section 11 (ticket #22) in place of its demos: the entry table, the RST calls and the `RST 28h` functions `0x00`–`0x11`, the full start-up sequence of section 4.2 (the self-test at power-on only), and the monitor with `D E F C V S G R P H`, breakpoints, the break and the trap. The palette chart, the colour cycle, the dimming and the console's status line (tests of the hardware, #13–#19) are gone; the tape loader demo of #21 stays, as Tab (or EDIT) on an empty command line.

| File | Contents |
|------|----------|
| `boot.asm` | Page 0: the entry table, start-up, the monitor's entry (`monent`) and exit (`g_final`), the IM 2 handler and table; includes the rest |
| `console.asm`, `keys.asm` | Page 0: the console driver's core (section 7.5) and the keyboards and serial link as key codes (section 7.4) |
| `calls.asm` | Page 0: the RST entries' routines, the `RST 28h` table, GETLINE's line editor, the window borrowing (section 7.6) |
| `monitor.asm` | Page 1: the rest of start-up, the monitor's entry, the command line and the commands |
| `selftest.asm`, `tape.asm` | Page 1: the self-test; the tape loader demo |
| `font.inc`, `help.asm` | Page 2: the font at offset `0x4000`; the help text |
| `rom.inc` | The constants: the console's state, the workspace's layout, the reasons for entering the monitor |

The NMI page (section 8.6) is built since ticket #27, with the NMI wired to the Z80. Not built yet: `I` and `T` (ticket #23); `U`, `L`, `B`, `X` and functions `0x12`–`0x14` (tickets #24–#26). Those letters give `? not yet: a later ticket`.

### 4.2 The full sequence

| Step | Background | What happens |
|------|------------|--------------|
| 1 | – | `0x0000`: `DI`. SP into SRAM. Read RESETWHY |
| 2 | Blue | The beam on; SERCON = EN, CTLEN, TXDROP |
| 3 | Blue | **Power-on only** (RESETWHY.POWER): the memory and MMU self-test, with I still 0 from reset (section 7.7). On a failure: red with white stripes, and the ROM stops. Other resets skip it, so SRAM keeps what a crashed program left (spec 7, section 3.2) |
| 4 | Green | Put every unit in the state of section 6 (the ROM writes them itself, so this does not rely on reset values); the monitor's map (section 5.2); check the workspace, and set it up again if its check fails (section 5.3); IM 2 with I = `0x1F`, VECBASE = `0xD0`; CPUSPEED 0 |
| 5 | Black | The console: font to SRAM, PALETTE0's colour pairs, the map cleared, L0 on. The sign-on lines on the screen and the serial link (shared spec, section 2.3) |
| 6 | Black | Read the start-up keys for 250 ms (section 4.3) |
| 7 | Black | **Power-on only:** set SYSCON.ROMLOCK, unless D is held (section 4.5) |
| 8 | | The shared spec's start-up steps 3–7: the loader; the monitor; the boot file; BASIC; the monitor (shared spec, section 9) |

Steps 1–5 take a few milliseconds (the self-test under one; clearing the map about two); the key window of step 6 then adds 250 ms.

### 4.3 Start-up keys

| Key | From | Effect |
|-----|------|--------|
| M | The Spectrum keyboard, a PS/2 keyboard, or the DivMMC button (SYSBTN.DIVMMC) | The monitor |
| U | Either keyboard | The loader |
| D | Either keyboard | Development: ROMLOCK is not set (section 4.5) |

- **The Spectrum keyboard** is read through the key map (KEYMAP0–6, spec 12, section 5.3), which is scanned and debounced in hardware, so a key held through the reset shows at once.
- **A PS/2 keyboard** sends a key only when it goes down and then as repeats (about every 92 ms after half a second). The ROM watches the PS/2 FIFO for 250 ms after the sign-on: a key held through a reset button press or an UPLOAD is already repeating, so it shows. At **power-on** a PS/2 keyboard is still starting itself (0.5–1 s) and reports nothing, so use the Spectrum keyboard then (open point B1).
- Keys from the serial link do not count: the PC uses the UPLOAD control command, and a terminal reaches the monitor once it is up.

### 4.4 Background colours

The background (BGCOLOR, spec 4) shows progress before the console is up, and is the console's border afterwards (spec 7, section 5).

| Colour | Meaning |
|--------|---------|
| No picture | The ROM did not get as far as starting the beam |
| Blue | Start-up, and the self-test at power-on (a screen that stays blue: the Z80 stopped there) |
| Red with white stripes | The self-test failed; the number of stripes is the check's number less `0x40` (`boot.asm`) |
| Green | Set-up after the self-test, a few milliseconds |
| Black | The console is up: the normal border |
| Yellow | The loader is waiting or receiving (section 9) |
| Magenta | Reading the SD card: the boot file, a `B`, `L` or `X` |

### 4.5 ROMLOCK and development

- At **power-on** the ROM sets SYSCON.ROMLOCK unless D is held. ROMLOCK then stays set until the next power-on whatever the ROM does (spec 7, section 4.3), so it does not set it again at later resets.
- So **holding D at power-on starts a development session** that lasts until the power goes off: across every reset in it, the loader accepts a new boot ROM image (TARGET 1). Holding D at a later reset changes nothing.
- Loading the FPGA over JTAG is a power-on (RESETWHY.POWER). A boot ROM built with `-DDEVROM` never sets ROMLOCK, for development on the bench (open point B2).

## 5. Memory

### 5.1 The program map

While a program runs:

| Window | Addresses | Read page | Write page |
|--------|-----------|-----------|------------|
| 0 | `0x0000`–`0x1FFF` | `0x3FC`: boot ROM page 0 | `0x3FC` (ignores writes: ROMWE is clear) |
| 1–7 | `0x2000`–`0xFFFF` | SRAM pages `0x001`–`0x007` | The same |

Window n holds SRAM page n, so **a CPU address in `0x2000`–`0xFFFF` is also its physical address**: `0x8000` is `P008000`. A program that gives a layer, a sprite or the copper an address in its own memory uses the same number. SRAM page 0 (`P000000`–`P001FFF`) sits under the ROM and is free for programs to map.

### 5.2 The monitor's map

While the monitor, the loader or the start-up code runs:

| Window | Page | Use |
|--------|------|-----|
| 0 | `0x3FC` | ROM page 0 |
| 1 | `0x3FD` | ROM page 1 |
| 2 | `0x3FE` | ROM page 2; `0x3FF` (page 3) when its code is needed |
| 3 | `0x0FF` | The workspace (section 5.3), with the monitor's stack |
| 4 | `0x0FE` | The console map and its state |
| 5 | Any | The access window: the page holding the address a command is looking at |
| 6, 7 | The program's | Not touched |

The monitor keeps a copy of the program's 16 page registers (MMU0–MMU7 and MMU0W–MMU7W). A plain address in a command is looked up through that copy, then reached through the access window; a `P` address is reached through it directly. So the monitor sees memory exactly as the stopped program did, including a page it had in window 0.

### 5.3 SRAM the ROM keeps

| Pages | Physical | Size | Contents |
|-------|----------|------|----------|
| `0x0F8`–`0x0FB` | `0x1F0000`–`0x1F7FFF` | 32 KB | The resident image (BASIC), write page NONE while it runs (section 10). Free when there is none |
| `0x0FC`–`0x0FD` | `0x1F8000`–`0x1FBFFF` | 16 KB | Kept for the ROM's later use. Page `0x0FC` holds the debug stub's frame buffers while VS Code is attached (section 8.8); otherwise free |
| `0x0FE` | `0x1FC000`–`0x1FDFFF` | 8 KB | The console map (spec 7, section 5.1), and the console's state in its hidden columns (below) |
| `0x0FF` | `0x1FE000`–`0x1FFFFF` | 8 KB | The font (2 KB), then the monitor's workspace (6 KB) |

The console and workspace pages are at the top of the first 2 MB, so they are in the same place on 2 MB and 4 MB boards (spec 7, section 5.1). A boot ROM image sent with TARGET 1 waits in SRAM pages `0x008`–`0x00B` (`P010000`–`P017FFF`) until it is all in; any program there is lost, but the upload ends in a reset anyway.

**The console's state** lives in page `0x0FE` itself, in map columns 96–127 of map row 0 (`P1FC0C0`–`P1FC0FF`, 64 bytes). The map is 128 entries wide and the window shows columns 0–79 at SCROLLX 0, so columns 80–127 never show; 96–127 stay well clear of the fetcher. So a ROM call needs only one page mapped to print (section 7.6). The same columns of rows 1–31 (31 × 64 bytes) are kept for the console too.

| Offset in page `0x0FE` | Size | Contents |
|------------------------|------|----------|
| `0x00C0` | 1 | Marker `0x5A`: the state is valid |
| `0x00C1`–`0x00C3` | 3 | Cursor row and column; the map row at the top of the screen |
| `0x00C4` | 1 | The colour pair: PAL × 2, the entries' high byte |
| `0x00C5` | 1 | CONMODE (section 7.3) |
| `0x00C6`–`0x00CB` | 6 | The PS/2 decoder: F0 and E0 seen, Shifts, Caps Lock, the last byte |
| `0x00CC`–`0x00D2` | 7 | KEYMAP0–6 as last seen, to find keys that have just gone down |
| `0x00D3`–`0x00D7` | 5 | The serial escape decoder: bytes so far and the TIME they began |
| `0x00D8`–`0x00E0` | 9 | The map's base in the borrowed window; the cursor (drawn, and the entry under it); the membrane key that repeats, its place and when it next repeats; a key put back by the serial decoder |
| `0x00E1`–`0x00FF` | 31 | Spare |

The **last line typed** (GETLINE's Up, the monitor's too) is kept in columns 96–127 of map rows 1–4, 64 bytes a row, ending in 0.

**The workspace,** page `0x0FF`, at `0x6000` in the monitor's map:

| Offset | Size | Contents |
|--------|------|----------|
| `0x0000` | 2 KB | The console font (PATPT = `0x1FE000`) |
| `0x0800` | 256 | The monitor's state: a marker (`RZ`) and a 16-bit sum of this block, why it was entered, the program's registers, its 16 page registers, the video and system registers the monitor took over (section 8.5), the breakpoint (address and old byte), what Enter carries on |
| `0x0900` | 256 | The line being typed, E's line, the commands' temporaries. The last line (for Up) is kept in the console page instead (above), so GETLINE has it for a program too |
| `0x0A00` | 512 | The SD card's sector buffer |
| `0x0C00` | 256 | The SD card and FAT32: card type, partition, the current cluster and file |
| `0x0D00` | 256 | The loader: the header being loaded, frames so far; and the **resident image record** (its header, its pages, a CRC of the record) |
| `0x0E00` | 160 bytes | The entry frame and the MMU registers as the monitor found them (`0x0E00`–`0x0E3F`), the program's colour pairs while the monitor has the screen (`0x0E40`, 90 bytes); then the NMI save area (`0x0EA0`) |
| `0x0EA0` | 64 | The **NMI save area** (section 8.6): at `0x0EA0` the flag that the monitor itself runs (`0xA5`); at `0x0EA6` window 3's read and write pages for the exit; at `0x0EAA` HL, BC and AF, at `0x0EB0` the program's SP, as the entry saves them before it maps anything; from `0x0EB4` the exit's bytes (43, to `0x0EDE`) |
| `0x0EE0` | About 2.3 KB | Spare |
| `0x1800` | 2 KB | The monitor's stack, from `0x2000` (`0x8000` in the monitor's map) down |

**When a program takes these pages.** A program may use every page, the console's included, but then makes no ROM calls other than EXIT and RESET (section 7.3). The console's marker and the workspace's marker and sum show the damage: whenever the monitor is entered (an NMI, a break, the end of the program) and finds either one broken, it sets up the font, the map and the workspace again, losing whatever the program had there. A program that wants to be looked at after a break keeps out of pages `0x0FE`–`0x0FF`. This closes spec 7's open point SY7.

**The font as a resource.** The console font is code page 437, 8 × 8, 8 bytes a character: in ROM at offset `0x4000` (page `0x3FE`) and in SRAM at `0x1FE000` while the console runs. A program may point a tile layer's PATPT at `0x1FE000` (while it keeps page `0x0FF`), or copy the font from the ROM page.

## 6. What a program inherits

The shared spec gives the shape (its section 10); this is retro-z80's content. It holds for a program started by an upload, the boot file, `B`, `L` then `G`, or `G addr` after a load.

| Item | State at the program's first instruction |
|------|------------------------------------------|
| PC | ENTRY |
| SP | `0xFFFE`; the word at `0xFFFE` is `0x0040`, the ROM's EXIT, so a `RET` ends the program |
| Other registers | AF, BC, DE, HL, IX, IY and AF', BC', DE', HL' all 0 (or as `R` set them) |
| Interrupts | IM 2, IFF1 = IFF2 = 0 (DI). I = `0x1F`, VECBASE = `0xD0`: the ROM's table at `0x1FD0` (section 6.1). INTENA all clear, INTCON.MASTER clear, every unit's flags cleared |
| NMI | NMICTL = `0x01` (EN; the stack capture is always on) and the NMI pages at their reset values (spec 2, section 9.8: window 0 reads ROM page 3 and writes the workspace page `0x0FF`), and NMICON with both sources allowed: the Multiface button and BREAK from the PC reach the monitor |
| Interrupt pages | Off: IPCTL, IPMASK and IPDEPTH 0 |
| Speed | CPUSPEED 0: 20 MHz |
| MMU | The program map (section 5.1) |
| Boot ROM | ROMWE clear; ROMLOCK set, unless D was held at power-on |
| Video | L0 the console (1 bpp tile map, 640 × 480 window, MAPPT `0x1FC000`, PATPT `0x1FE000`); L1, L2 off; sprites off; PRIO as reset; BGCOLOR black; PALETTE0's colour pairs 0–14 (entries 16(p + 1) and 16(p + 1) + 1, spec 7, section 5.1) the console's, entries 0–15 the Spectrum colours; the other palettes as left by reset (spec 4) |
| Copper, DMA engine, sprite sequencer | Stopped |
| Timers | All four stopped; the watchdog off and unlocked; TIME counting |
| Serial | SERCON = EN, CTLEN, TXDROP; interrupts off |
| PS/2 keyboard | KBCON.EN on (receiving), its interrupt off |
| SD card | Deselected; the card started if the program came from it |
| Port `0xFE` | Border black, beeper 0 |
| SRAM | The program's image; pages `0x0F8`–`0x0FF` as section 5.3; the rest as it was (random after power-on) |

### 6.1 Interrupts

- **The ROM's table** is 24 entries at `0x1FD0`–`0x1FFF` in page 0 (spec 8, section 5). Every entry points at one handler that reads INTID, turns that source off in INTENA (a clear write), and returns with `EI` and `RETI`. A source turned on by mistake is thus switched off at its first interrupt instead of hanging the program in a loop of level-sensitive requests.
- **A program that uses interrupts** builds its own table in its SRAM, sets I and VECBASE to it, and then turns its sources on (unit enables, INTENA, INTCON.MASTER). The ROM never changes I, VECBASE or the controller while a program runs.
- **The ROM calls work with interrupts on.** They hold them off for at most about 150 µs at 20 MHz while they have a window borrowed (section 7.6), and give back the interrupt state they found.
- **IM 1** is not served while the ROM is in window 0: `0x0038` is the trap (section 7.7). A program that wants IM 1 maps its own SRAM page into window 0, with its own code at `0x0038` and `0x0066`, and then makes no ROM calls (as the playfields guide says for ported Spectrum games). Or it uses the interrupt pages (spec 2, section 9.7): with window 0 in IPMASK and its own page as IP0, the fetch at `0x0038` comes from its page while the ROM stays in window 0 for the rest of the program; its handlers then make no ROM calls.
- **Interrupt pages:** a program that makes ROM calls from its handlers leaves window 0 out of IPMASK. Its IM 2 table may then sit in a switched window (in the interrupt page) or in an unswitched one. The ROM's own table at `0x1FD0` is in window 0 and is read as usual.

### 6.2 Getting back to the monitor

| How | Then |
|-----|------|
| `RET` from the entry point, with SP back at `0xFFFE` | `Program ended.` The registers are shown; `G` runs the program again from ENTRY |
| `JP 0x0040`, or `RST 28h` function EXIT | The same, from anywhere, whatever SP holds |
| `RST 30h`, or `RST 28h` function BREAK | `Break at <addr>`; `G` goes on after the `RST` |
| A breakpoint (`G addr break`) | `Breakpoint at <break>` |
| The Multiface button, or `rlink.py break` | `NMI (button)` or `NMI (USB) at <addr>`; `G` goes on |
| A fetch of `0xFF` (`RST 38h`): a runaway program in NONE, the register page or empty memory | `Trap RST 38h at <addr>` |
| A step (`N`), with the debug unit | `Step at <addr>` (section 8.8) |
| A watchpoint set from VS Code | A STOP frame to VS Code (section 8.8) |
| `RST 28h` function RESET, or SYSRESET | A full reset (spec 7) |

A jump to `0x0000` starts the boot ROM again without a hardware reset. The ROM sets every unit itself (step 4), so this is a clean restart; but if the last reset was power-on, RESETWHY still says so and the self-test runs again, wiping SRAM pages 0–5. Programs use RESET instead.

## 7. ROM calls

### 7.1 The RST entries

| Instruction | Opcode | Name | In | Out |
|-------------|--------|------|----|-----|
| `RST 00h` | `C7` | RESET entry | – | Not a call: the start-up code (section 6.2) |
| `RST 08h` | `CF` | PUTC | A = character | – (A kept) |
| `RST 10h` | `D7` | GETC | – | A = key code (section 7.4); waits for a key |
| `RST 18h` | `DF` | PUTS | HL = a string ending in `0x00` | HL = the byte after the `0x00` |
| `RST 20h` | `E7` | POLLC | – | NZ and A = key code if a key was waiting; Z and A = 0 if not. Never waits |
| `RST 28h` | `EF` | CALL | The function number in the byte after the `RST`; arguments in registers | As the function says; returns after the number byte |
| `RST 30h` | `F7` | BREAK | – | Enters the monitor; `G` returns after the `RST` |
| `RST 38h` | `FF` | TRAP | – | Enters the monitor (section 7.7) |

A call is made with the `RST` itself; nothing needs setting up first. For example:

```
        ld      hl,msg
        rst     18h             ; PUTS
        rst     10h             ; GETC: wait for a key
        cp      'y'
        ...
        rst     28h             ; CALL
        db      0x09            ; CLS
        ret                     ; back to the monitor
msg:    db      "Clear the screen? ", 0
```

### 7.2 Calling conventions

- **Kept:** every register except those a call gives back, and F. A call that returns nothing in A keeps A. The alternate registers, IX, IY and I are never touched; R counts on as usual.
- **Stack:** a call uses up to 48 bytes of the caller's stack (GETLINE, the deepest, about 44).
- **Where things may be:** the caller's code, stack and data (a string, a line buffer) may be anywhere in `0x2000`–`0xFFFF`, under any mapping of windows 1–7 the program has made. Not in window 0.
- **Interrupts:** as the caller had them, except for at most about 150 µs at 20 MHz inside a call (section 7.6). A call never enables interrupts that were off.
- **Speed:** every call works at every CPUSPEED; it is slower at lower speeds, and its waits (the escape-sequence timeout, the cursor's blink) use TIME, so they last the same.
- **Errors:** functions that can fail return with carry set and an error code in A (section 7.3); carry clear means success.
- **Watchdog:** a call that waits (GETC, GETLINE) kicks a running watchdog while it waits.

### 7.3 `RST 28h` functions

The byte after `RST 28h` is the function number. A number above the highest one (in ROMID, `0x004E`) returns with carry set and A = 1.

| Number | Name | In | Out |
|--------|------|----|-----|
| `0x00` | VERSION | – | A = version (major in bits 7–4, minor in 3–0); B = the highest function number; HL = `0x0048` (ROMID) |
| `0x01` | PUTC | A | As `RST 08h` |
| `0x02` | GETC | – | As `RST 10h` |
| `0x03` | POLLC | – | As `RST 20h` |
| `0x04` | PUTS | HL | As `RST 18h` |
| `0x05` | GETLINE | HL = buffer, B = its size (2–255) | Reads a line with the monitor's editing (Backspace, Esc, Up; shared spec, section 2.3) and ends it with `0x00`. B = its length. Carry set (and B = 0) if Esc was pressed |
| `0x06` | PUTHEX | A | Prints A as two hex digits (A kept) |
| `0x07` | PUTHEX16 | HL | Prints HL as four hex digits |
| `0x08` | PUTDEC | HL | Prints HL as an unsigned decimal number |
| `0x09` | CLS | – | Clears the screen; the cursor to the top left |
| `0x0A` | SETPOS | H = row (0–29), L = column (0–79) | Moves the cursor; out-of-range values are cut to the edge |
| `0x0B` | GETPOS | – | H = row, L = column |
| `0x0C` | SETPAIR | A = colour pair (0–14, spec 7, section 5.1) | Characters printed from now on use it |
| `0x0D` | PUTRAW | A = any code 0–255 | Draws the font's glyph for A on the screen (codes 0–31 too) and moves the cursor on. Sends nothing on the serial link |
| `0x0E` | CONMODE | A = the new mode, or `0x80` to only read it | A = the old mode. Bit 0: print on the screen; bit 1: print on the serial link; bit 2: keys from the keyboards; bit 3: keys from the serial link. All four set at entry |
| `0x0F` | EXIT | – | Does not return: back to the monitor (as `JP 0x0040`) |
| `0x10` | BREAK | – | As `RST 30h` |
| `0x11` | RESET | – | Does not return: writes SYSRESET |
| `0x12` | LOADFILE | HL = a file name (8.3, ending in `0x00`) | Loads an image file from the SD card as `L` does (TARGET 0 only). HL = its ENTRY. Carry and A = error |
| `0x13` | READBLOCK | DE:HL = block number (DE the high word), IX = a 512-byte buffer | Reads one block of the SD card. Carry and A = error |
| `0x14` | WRITEBLOCK | As READBLOCK | Writes one block. Carry and A = error |

Functions `0x12`–`0x14` come with the SD card code (section 11). Later functions take the next numbers; none is ever renumbered.

| Error (A, with carry) | Meaning |
|-----------------------|---------|
| 1 | No such function |
| 2 | No card |
| 3 | The card did not answer, or a read or write failed |
| 4 | No such file |
| 5 | A bad image (shared spec, section 7) |
| 6 | The image's range is not allowed (section 9) |

### 7.4 Key codes

GETC, POLLC and GETLINE give one code per key, from either keyboard or the serial link:

| Code | Key | PS/2 | Spectrum keyboard | Serial link |
|------|-----|------|-------------------|-------------|
| 8 | Backspace | Backspace | CAPS SHIFT + 0 (DELETE) | 8, or 127 (most terminals send 127 for Backspace) |
| 9 | Tab | Tab | – | 9 |
| 13 | Enter | Enter, keypad Enter | ENTER | 13 (a 10 straight after it is dropped) |
| 27 | Escape | Esc | CAPS SHIFT + SPACE (BREAK) | 27 with nothing after it for 20 ms |
| 32–126 | Characters | The UK layout, Shift and Caps Lock (spec 12, section 3.3) | Plain, CAPS SHIFT (capitals) and SYMBOL SHIFT (the Spectrum's symbols) | As sent |
| 130–135 | Home, End, Page Up, Page Down, Insert, Delete | The keys of those names | – | `ESC [ H`, `ESC [ F`, `ESC [ 5 ~`, `ESC [ 6 ~`, `ESC [ 2 ~`, `ESC [ 3 ~` (and `ESC [ 1 ~`, `ESC [ 4 ~` for Home and End) |
| 136–139 | Left, Right, Down, Up | The cursor keys | CAPS SHIFT + 5, 8, 6, 7 | `ESC [ D`, `C`, `B`, `A` |
| 145–156 | F1–F12 | F1–F12 | – | `ESC O P` … `ESC O S` (F1–F4), `ESC [ 15 ~` … `ESC [ 24 ~` (F5–F12) |

These are the codes BBC BASIC's host layer expects for its line editor (section 10; open point B4). Keys with no code (Shift alone, Ctrl, Alt) give none. A key held down repeats as the PS/2 keyboard repeats it; on the Spectrum keyboard the ROM repeats it after 0.5 s, ten times a second.

### 7.5 What PUTC prints

| Code | On the screen | On the serial link |
|------|---------------|--------------------|
| 8 | Back one column (not past column 0); nothing is rubbed out | Sent as it is |
| 9 | On to the next column that is a multiple of 8 | Sent |
| 10 | Down a row; at the bottom the text scrolls up (SCROLLY, spec 7, section 5.1) | Sent |
| 12 | Clear the screen, cursor to the top left | Sent |
| 13 | Back to column 0 | Sent |
| Other codes 0–31 | Nothing (PUTRAW draws their glyphs) | Sent |
| 32–255 | The code page 437 glyph; the cursor moves on, to the next line after column 79 | Sent |

A program sends CR and LF for a new line, as the monitor does. The cursor shows, blinking, only while GETC or GETLINE waits for a key; the ROM has no interrupt to blink it otherwise.

### 7.6 How a call reaches the console

While a program runs, the console's page `0x0FE` is not in its map. A call that prints or reads a key:

1. saves the interrupt state (`LD A,I` gives IFF2 in P/V) and disables interrupts;
2. picks window 4, or window 2 when the caller's stack (SP − 48 to SP) touches window 4, and reads that window's read and write pages;
3. maps page `0x0FE` there (read and write), does the work, and puts the window's pages back exactly;
4. gives back the interrupt state.

The serial link and the keyboards are ports, so they need no window. The longest time with a window borrowed is a scroll: clearing a map row, about 3,000 T-states (150 µs at 20 MHz). Strings and line buffers are read and written a character at a time **outside** the borrowed window (PUTS calls PUTC for each character; GETLINE calls GETC and PUTC), so they may lie anywhere, the borrowed window included. GETC waits as a loop of short borrows, so interrupts are never held off while it waits. PUTC with code 12 clears the whole map in one borrow (about 5 ms with interrupts off); CLS (function `0x09`) clears a row a borrow.

### 7.7 `RST 38h`: the trap

Three things want `0x0038`:

- the **self-test's check `0x4C`**, which fetches an opcode from the register page on purpose: the fetch reads `0xFF`, which is `RST 38h`, and the test's handler (`st_rst38`) returns to the test (this is the clash noted in ticket #16);
- **IM 1**, whose interrupts all run `RST 38h`;
- **runaway programs:** a fetch from NONE, the register page or erased memory reads `0xFF` and lands there too.

The ROM has one `0x0038`, so it is the **trap**: `JP` to a handler that looks at I. **I = 0** only from reset until step 4 of start-up (section 4.2), which is when the self-test runs; then the trap returns to the self-test, as `st_rst38` does now. **Any other I** means a program or the monitor: the trap enters the monitor with `Trap RST 38h at <addr>` (the address of the `0xFF`). The ROM sets I to `0x1F` before anything else runs, and a program in IM 2 with the ROM in window 0 cannot have its table at `0x00xx`, which is ROM, so no program has I = 0 by design.

IM 1 is left to programs that put their own page in window 0 (section 6.1). Serving IM 1 from the ROM would mean a jump through a vector in RAM at every interrupt, and the ROM's RAM is not mapped while a program runs, so each interrupt would cost a window borrowed and given back (section 7.6). IM 2 costs nothing.

## 8. The monitor on the Z80

The shared spec gives the commands. Here are the Z80's parts.

### 8.1 Addresses

| Address | Reaches | Allowed |
|---------|---------|---------|
| `0000`–`1FFF` | Window 0 as the program had it: ROM page 0 normally; after an NMI, the page the program had in window 0 (NMISAV0, NMISAV0W) | Reading. Writing only if the program's write page there is SRAM |
| `2000`–`FFFF` | Windows 1–7 through the program's page registers | Reading and writing |
| `P000000`–`P3FFFFF` | SRAM, page × `0x2000` + offset; on a 2 MB board (SYSCFG.CHIPMB = 2) only up to `P1FFFFF` | Reading and writing. Pages `0x0FE`–`0x0FF` (and `0x0F8`–`0x0FB` while BASIC is resident) can be read and written, with care |
| `P7F0000`–`P7F1FFF` | The register page (spec 2, section 10) | Reading and writing; some reads have side effects (below) |
| `P7F8000`–`P7FFFFF` | Boot ROM pages 0–3 | Reading; writing only while ROMWE is set |
| Others | Reserved and NONE pages | `? address` |

`D` shows a CPU address with 4 digits and a physical one with `P` and 6 digits.

**Registers whose reads have side effects** (shared spec, section 3.2; spec 3, rules 4 and 14). `D`, `S` and `V` show `--` for these bytes and `C` refuses them (`? address`). `E` and a `P` read still reach them. The rule holds for a `P` address in the register page, for a CPU address in a window where the program had the register page (`0x3F8`) mapped, and for every port form. Ports are register (high byte) : page (low byte); custom offset k is port (k bits 7–0) × 256 + `0x10` + (k bits 9–8), and register page offset `0x1000` + k.

| Register | Port | Register page | A read |
|----------|------|---------------|--------|
| TIME0 | `0x2000` | `P7F0020` | Captures (below) |
| TMRn_COUNT0, n = 0–3 | `0x2D00`, `0x3500`, `0x3D00`, `0x4500` | `P7F002D` + n × 8 | Captures |
| SERDATA | `0x53` with any high byte | `P7F0053` | Takes a byte from the receive FIFO |
| SDDATA | `0x5B` with any high byte | `P7F005B` | With SDCON.AUTO set, starts an SPI exchange (shown `--` whatever AUTO holds) |
| SERDROP | `0x5C00` | `P7F005C` | Clears it |
| SDCOUNT0 | `0x5D00` | `P7F005D` | Captures |
| KBDATA | `0x62` with any high byte | `P7F0062` | Takes a byte from the PS/2 FIFO |
| PALDAT (custom `0x00B`) | `0x0B10` | `P7F100B` | Steps PALDAT's byte order; the red read steps PALIDX |
| SPRxPT0, x = 0–7 (custom `0x010` + x × `0x10`) | `0x1010` + x × `0x1000` | `P7F1010` + x × `0x10` | Captures |
| L0, L1, L2 BPL0PT0 (custom `0x0A4`, `0x0C4`, `0x0E4`) | `0xA410`, `0xC410`, `0xE410` | `P7F10A4`, `P7F10C4`, `P7F10E4` | Captures |
| BEAMPOS0 (custom `0x0F0`) | `0xF010` | `P7F10F0` | Captures |
| FRAMECOUNT0 (custom `0x0F4`) | `0xF410` | `P7F10F4` | Captures |
| COPPC0 (custom `0x10A`) | `0x0A11` | `P7F110A` | Captures |
| CHDESC0 of DMA channel n = 0–3 (custom `0x160` + n × `0x40`) | `0x6011`, `0xA011`, `0xE011`, `0x2012` | `P7F1160` + n × `0x40` | Captures |
| SEQPT0 (custom `0x308`) | `0x0813` | `P7F1308` | Captures |

- **Captures:** reading a capturing register's low byte replaces the CPU's one capture (spec 3, rule 4), which the stopped program may have been part-way through reading. The higher bytes have no side effect, so they are shown.
- **Not in the list:** INTID (reading it changes nothing, spec 8, section 6); the W1C status registers (reading is harmless; only writing 1 clears); port `0xFE` and KEYROW0–7; and the palettes in the register page (`P7F1400`–`P7F1FFF`), which do not use PALIDX.

### 8.2 Ports

`P port` reads with `IN A,(C)` and BC = port; `P port value` writes with `OUT (C),A`. A port is 16 bits, register (high byte) : page (low byte) (spec 3): `P 7000` reads SYSID, `P 7700 08` sets the Spectrum speed. Only `.B`. `P` is a single explicit read, so it reaches the registers in section 8.1's list, with their side effects: reading a stream port takes a byte.

### 8.3 Registers

```
AF=0044 BC=0000 DE=0000 HL=800E IX=0000 IY=0000 SP=0000 PC=0040
AF'=0000 BC'=0000 DE'=0000 HL'=0000 I=1F R=12 IFF=0 IM=2?  Z P
```

- The flags of F are spelt out at the end: S Z H P N C, each shown only when set (bits 5 and 3 are not shown).
- **IFF** is IFF1 as the program had it: read from IFF2 with `LD A,I` (an NMI copies IFF1 into IFF2). `G` puts it back with `EI` or `DI` (after an NMI, `RETN` does).
- **IM:** the Z80 cannot read its interrupt mode. The monitor never runs an `IM` instruction itself, so the program's mode survives a stop untouched. It shows the mode the program was started in (2), with `?` once the program has run. `R IM 0`, `1` or `2` makes `G` run that `IM` before it goes on.
- **R** can be set, but counts on while the monitor runs out, so it is only roughly what was set.
- `R name` shows one register as the display above does: `R HL` gives `HL=1234`, `R IM` gives `IM=2?`, and `R AF` gives `AF=0044  Z P`, with the flags.
- Names for `R name` and `R name value`: `AF BC DE HL IX IY SP PC AF' BC' DE' HL' I R IFF IM`, and `A F B C D E H L` for single bytes.

### 8.4 Disassembler

`I` shows every documented Z80 instruction, with the CB, DD, ED and FD prefixes and the DD CB and FD CB forms, in sjasmplus's syntax and with hex numbers. Undocumented forms (IXH, IXL, SLL and the like) are shown too, in sjasmplus's names; bytes that are no instruction show as `DB`. After `RST 28h` the function number shows as `DB nn` with the function's name:

```
> I 8010 4
8010  EF           RST  28h
8011  09           DB   09        ; CLS
8012  2A 00 C0     LD   HL,(C000)
8015  ED 52        SBC  HL,DE
```

### 8.5 Breaks and taking the screen

When the monitor is entered while a program is running (a break, a breakpoint, a trap, an NMI):

1. It saves the registers (after an NMI into the workspace's NMI save area through window 0, section 8.6; otherwise a few bytes on the program's stack first, then into the workspace), the 16 page registers (after an NMI, from NMISAV0–7 and NMISAV0W–7W, the program's map at the NMI), CPUSPEED, and the interrupt state, IPDEPTH included. After an NMI the program's PC and SP are NMICAPPC and NMICAPSP (spec 2, section 9.8), not words on its stack.
2. It moves to its own map (section 5.2) and its stack in the workspace, sets CPUSPEED 0, and keeps interrupts off.
3. If the console's state or the workspace is broken, it sets them up again (section 5.3).
4. It **takes the screen**: it saves L0's 32 registers, PRIO, DMACON, BGCOLOR, COPCON, VIDCON, PALIDX, PALETTE0's 30 entries of the console's colour pairs (section 6), and the console's CONMODE and colour pair; stops the copper (so a copper list does not rewrite L0), puts L0 back as the console in front of the other layers, the beam on, the border black, CONMODE all on and pair 0. Sprites, L1, L2 and the DMA engine are left as they are (open point B5).
5. It kicks a running watchdog while it waits (WDKICK; a locked watchdog cannot be stopped).

`G` puts all of it back, in reverse, and goes on: with `RET` after a break, a breakpoint or a trap; with `RETN` after an NMI, so the hardware puts window 0 and the PC back (spec 7, section 10.1). After an NMI, `G addr` or a changed PC is written to NMICAPPC, a changed window to NMISAVn, and SP is set to NMICAPSP − 2 before the `RETN`. A copper list starts again from COP1LC at the next frame.

### 8.6 The NMI monitor page

The NMI paging (spec 7, section 10.1; spec 1, section 8.2) puts ROM page 3 in window 0 for the NMI, for reading; window 0's writes go to the **workspace page `0x0FF`** (NMIP0W, spec 2, section 9.8), at the same offsets. So the monitor page can save registers and run a stack before it maps anything, and, with the NMI's stack capture, an NMI writes nothing in the program's memory. There is **one monitor**, in pages 0–2; page 3 holds only the way in:

1. At `0x0066` in page 3: save SP with `LD (0x0EB0),SP` and load SP with `0x0EB0`, so `PUSH AF`, `PUSH BC` and `PUSH HL` write the NMI save area (offsets `0x0EAA`–`0x0EB1` of page `0x0FF`, section 5.3) through window 0. Reads from window 0 still come from page 3, so the entry makes no `CALL` and no `POP` there. Read NMISTAT for the source.
2. Map the workspace page into window 3 (NMISAV3 holds the program's page there, so nothing need be saved first) and move SP to the same place through it (`0x6EAA`). Save the program's map (NMISAV0–7, NMISAV0W–7W), PC and SP (NMICAPPC, NMICAPSP) into the workspace, mapped as in section 5.2.
3. Switch window 0 from page 3 to page 0 (the switch is at the same address in both pages, so the next instruction comes from page 0), and go on in the monitor's common entry (section 8.5).

**The exit** (`G`) puts back everything but window 3, writes NMICAPPC if the PC was changed, and jumps to the exit's few bytes in the save area (`0x6EB4` through window 3). They map page `0x0FF` into window 0 for reading and writing, go on at the same bytes through window 0 (`0x0ECx`), put window 3 back, pop HL, BC and AF from the save area, reload SP from `0x0EB0` and do `RETN`. `RETN` takes its stack reads from NMICAPPC, then puts window 0 back from NMISAV0 and NMISAV0W. So neither the entry nor the exit touches the program's memory.

The NMI mode (NMICTL.INNMI) lasts until the monitor's `RETN`, which puts the program's window 0 back. If the monitor starts a **new** program after an NMI (`U`, `B`, `L` then `G`, `G addr` after a load), it first ends the NMI mode: it writes the address of a few bytes of code it has put in the workspace (window 3) to NMICAPPC and does `RETN`; that code maps ROM page 0 into window 0 again and carries on. So the new program can be broken into by the next NMI. It also puts the interrupt pages back to off (IPCTL, IPMASK and IPDEPTH 0) for the new program.

With NMICTL.EN = 0 (a program's choice), page 0's `0x0066` saves a few bytes on the program's stack, as a break does, and jumps to the same common entry; the program's window 0 is then whatever it was, and the monitor ends with `RETN` too. The PC is still captured, so on both paths the monitor reads the program's PC and SP from NMICAPPC and NMICAPSP, never from its stack, and `RETN` takes the PC from NMICAPPC.

### 8.7 Going on, and what the shared spec leaves open

- **At start-up** the program's registers are 0, SP = `0xFFFE`, PC = `0x8000` (so `G` alone runs a program typed in at `8000`), IM 2, I = `0x1F`, and the program map of section 5.1.
- **A new run.** With no program stopped (after start-up or `Program ended.`), `G` starts one: SP = `0xFFFE` with EXIT at `0xFFFE` (section 6), PC = the address given, or else ENTRY (where the last run started) once a program has ended; the other registers as `R` shows them.
- **Going on.** With a program stopped (a break, a breakpoint, a trap), `G` goes on with every register as `R` shows them; `G addr` changes only PC.
- **After `Program ended.`** the registers stay as the program left them: after its `RET`, SP = `0000` and PC = `0040`, as the shared spec's example shows.
- **The address in the message:** `Break at` gives the `RST 30h` (or the `RST 28h`) itself, with PC after it; `Trap RST 38h at` and `Breakpoint at` give the byte where PC is.
- **The breakpoint** is cleared whenever the monitor is entered, whichever way; a breakpoint is for one `G`. It is the debug unit's breakpoint 0, not a byte in the program (section 8.8).
- **`P` and the monitor's own registers.** The monitor changes the MMU and CPUSPEED for itself, so `P` on the MMU registers (`0x8000`–`0x9F00`) and CPUSPEED (`0x7700`) reads and writes the program's copy, which `G` puts back.
- **Tab or EDIT on an empty command line** plays ticket #21's tape loader demo (`tape.asm`) on the border and the beeper. It is not a command letter, so the shared command table is unchanged.
- **What D, V and S print, and how far Enter carries on,** are in the shared spec (sections 2.3 and 4.1); this ROM follows them.
- **Commands not built yet** (`I T U L B X`, section 11) answer `? not yet: a later ticket`: the shared spec's `? not yet` (section 2.3), with the reason after it.

### 8.8 The debug unit and the debug stub

The debug unit (spec 18) gives the monitor hardware breakpoints and a single step, and the **debug stub** in the monitor serves VS Code over the remote debugging protocol ([`debug.md`](debug.md)). Both run on the NMI part of branch 17 (section 8.6): a stop is an NMI, so it changes nothing in the program's memory or stack. That NMI part is built first; the maskable interrupt pages later.

- **Leaving by `RETN`.** The monitor always goes back to a program by `RETN`, after an NMI and also after a break, a trap or a load (with INNMI = 0 a `RETN` pops the PC it pushed, as a `RET` would). The debug unit goes live at the first M1 after it (spec 18, section 3). Entered by a break or a trap, the monitor first writes DBGCTL.LIVE = 0, so its own code is never compared.
- **`G addr break`** sets breakpoint 0 at break (DBGBP0_ADDR, DBGBP0_CTL.EN) instead of writing `RST 30h` there, so a breakpoint works in ROM and nothing is written into the program. On the stop the monitor sets NMICAPPC back by 1 (spec 18, section 5.2), clears breakpoint 0 and says `Breakpoint at <break>`. Still one breakpoint per `G` (section 8.7). The shared spec's section 4.3 allows both methods (agreed with retro68k).
- **`N` step** (in the shared spec's command table, agreed with retro68k, which uses its trace bit; open point B16): `N` runs one instruction of the stopped program, then shows the registers and the prompt. It clears DBGSTAT, sets DBGCTL.STEP (STEPINT = 0, so no interrupt is taken during the step) and leaves by `RETN`; the step's NMI comes back to the monitor with `Step at <addr>`. Enter on an empty line after `N` steps again, as after `D`.
- **What the NMI handler looks at.** NMISTAT (button, USB) and DBGSTAT (step, breakpoint n, watchpoint n). With a watchpoint, DBGHITADDR, DBGHITDATA and DBGHITKIND give the access. It clears both before it goes on.
- **An NMI while the monitor itself runs** (BREAK sent at the prompt, as an attach does, or the button pressed there): the monitor keeps the stopped program's saved state as it is, ends the NMI with `RETN` at once and goes back to its prompt. A flag in the monitor's state block says the monitor is running.
- **The debug stub** is the monitor in **debug mode**. At the prompt the monitor watches the serial link for a HELLO frame (debug.md, section 4.4), and then: turns the console's serial side off for the program (CONMODE), does not take the screen at stops (section 8.5, step 4, is skipped while attached), answers the debug channel's commands (debug.md, section 5) with the monitor's own code for memory, registers and the MMU copy, and sends a STOP frame at each stop. Its frame buffers (4 KB in, 2 KB out) are in SRAM page `0x0FC`, mapped into window 5 while it works; its state (attached, the last SEQ and its STATUS, the last STOP) is in the workspace's spare space at `0x0EE0`. DETACH puts the console back and takes the screen as usual.
- **Program ended, break, trap** while attached become STOP frames (EXIT, BREAK, TRAP) instead of the monitor's messages on the serial link; the screen shows nothing.

## 9. The loader and image files on the Z80

The loader and the boot file follow the shared spec (sections 5–7). retro-z80's limits:

| TARGET | LOAD | SIZE | ENTRY | Refused (code) |
|--------|------|------|-------|----------------|
| 0, PHYS clear | `0x2000` or more, with LOAD + SIZE ≤ `0xFFFE` (the last two bytes are the first stack entry) | Up to 57,342 bytes | `0x2000`–`0xFFFF` | Outside these (3) |
| 0, PHYS set | A physical SRAM address below the board's size (SYSCFG.CHIPMB), with the image clear of pages `0x0F8`–`0x0FF` | Up to the room | `0x2000`–`0xFFFF`, used only with ACTION 1 | Outside these (3) |
| 1 | A ROM offset, with LOAD + SIZE ≤ `0x8000`; with LOAD 0, `RZ80` at `0x0048` | Up to 32 KB | Ignored | ROMLOCK set (5); no `RZ80` (2) |
| 2 | `0x2000` | Up to 32 KB | `0x2000`–`0x9FFF` | Outside these (3) |

- A program (TARGET 0) is written straight to its place: the CPU address is the physical address (section 5.1), reached through the access window. With PHYS, data can go anywhere in SRAM, for example pictures for the layers, and the program loaded in a second upload.
- A boot ROM image (TARGET 1) waits in pages `0x008`–`0x00B`. At END with ACTION 1, the loader copies a few bytes of code into the workspace (window 3) and runs them there, since it cannot run from the ROM page it is rewriting (spec 7, section 4.3): set ROMWE, copy each 8 KB through window 5 with the ROM page mapped in window 4, read it back, write SYSRESET.
- A resident image (TARGET 2) goes into pages `0x0F8`–`0x0FB` (section 10).
- While the loader waits, the border is yellow and the screen shows `Waiting for upload.  Esc for the monitor.`; then the header, a count of bytes as they come, and the result.
- **The boot file** `BOOT.Z80` and other image files are read from the SD card (spec 11) by the ROM's FAT32 reader, into the same places.
- Speed: the loader takes bytes with `INIR` (spec 10, section 6) and computes CRC-32 from the table in ROM page 2, about 100 T-states a byte in all; a 48 KB program arrives and is checked in about 0.3 s at 20 MHz.

## 10. BBC BASIC as the resident image

Design plan branch 13 makes BBC BASIC (Z80) a ROM image kept in write-protected SRAM. As the boot ROM sees it:

| Item | Value |
|------|-------|
| File | `BASIC.Z80` on the SD card: an image with TARGET 2, LOAD `0x2000`, up to 32 KB (the interpreter is 16,374 bytes; the host layer the rest). Or uploaded with TARGET 2 |
| Where | SRAM pages `0x0F8`–`0x0FB` (`P1F0000`–`P1F7FFF`) |
| Record | The resident image record in the workspace (section 5.3): the header, the pages used, a CRC of the record |
| Started by | Start-up step 6 (shared spec, section 9), or `X` |
| Started how | The program environment of section 6, except that windows 1 up to 4 (as many as the image needs) hold pages `0x0F8` onwards with their **write page NONE** (`0x3FB`), so the image cannot be overwritten; the windows above hold SRAM pages as in section 5.1. With a 24 KB image, BASIC's own memory is `0x8000`–`0xFFFF` |
| Warm reset | At start-up and at `X`, a valid record and an image that still matches ICRC are used as they are: no SD read. A check that fails loads `BASIC.Z80` again |
| ROM calls | BASIC's host layer uses the RST calls for the console and keys, and its own code for the rest (VDU, files, TIME from a timer it starts) |
| Leaving | BASIC's `*BYE` (or the host layer's equivalent) returns to the monitor through EXIT |

The memory map inside BASIC (where its workspace, PAGE and HIMEM go) belongs to the BASIC tickets (open point B3). The boot ROM only promises the pages, the protection and the record.

## 11. Without the FT232H, and the order of work

The KS2 has no FT232H module yet (design plan, branch 12). Without it:

- serial output is dropped (TXDROP) and nothing arrives, so the ROM works on the screen and the keyboards alone;
- the monitor works fully on the screen and keyboards; programs come from the SD card or are typed in with `E`;
- `U`, UPLOAD and `rlink.py` wait for the module. They are tested in simulation against `ft232h_model.v` before then.

The ROM is built in this order, each step a ticket:

| Step | Contents | Needs |
|------|----------|-------|
| 1 | The entry table, the program map, the RST calls (PUTC to CONMODE, EXIT, BREAK, RESET), the start-up sequence and keys, the monitor with `D E F C V S G R P T H`, breakpoints, the trap, the NMI page | The console, keyboards and NMI paging. Built (ticket #22; the NMI page with ticket #27) but for `T` (ticket #23) |
| 2 | The disassembler (`I`) | Step 1 |
| 3 | The SD card and FAT32: `L`, `B`, the boot file, LOADFILE, READBLOCK, WRITEBLOCK | Spec 11's controller |
| 4 | The loader (`U`, UPLOAD, all three targets) and `tools/rlink.py` | Step 1; the FT232H for the board |
| 5 | The resident image and `X` | Steps 3–4; the BASIC tickets |

## 12. Test plan

- **Start-up:** each reset source; the self-test only at power-on (SRAM pages keep a pattern across a button reset); each background colour; the sign-on lines on the simulated screen (pixel checks, as `vtest bootcon`) and on the serial link.
- **Start-up keys:** M, U, D on the Spectrum keyboard and on a PS/2 keyboard (a model sending repeats) during the 250 ms window; the DivMMC button; D at power-on leaves ROMLOCK clear across later resets; without D, ROMLOCK is set and a TARGET 1 upload is refused with code 5.
- **Program environment:** a test program checks every item of section 6 at its first instruction (registers, I, VECBASE, IFF, the MMU, INTENA, CPUSPEED, ROMLOCK, the console's registers), then `RET`s to `Program ended.`
- **ROM calls:** each RST and each `RST 28h` function with the caller's stack and data in every window 1–7 and across window edges; every register the convention keeps is kept; interrupts on during calls, with a VBLANK handler counting frames and a check that none is lost and that interrupts are never off for more than 150 µs; every CPUSPEED.
- **Keys:** every code of section 7.4 from each source, including the serial escape sequences and a lone Esc; repeats.
- **Printing:** every code of section 7.5; wrap at column 79; scrolling; PUTRAW; CONMODE turning each side off.
- **Trap:** a jump into NONE, into the register page and to a byte `0xFF` each give `Trap RST 38h at` the right address; the self-test's check `0x4C` still passes at power-on.
- **In simulation now** (ticket #22): `sim/mon/` types a session over the serial link in Verilator (`make -C sim mon`, about a minute): every command and size, `P` addresses, the side-effect bytes shown `--`, E stepping, Enter carrying on, the errors; a program typed in printing through `RST 08h`, `RST 18h` and `RST 28h`; IX, IY, BC, DE and HL' kept across a ROM call; a breakpoint, `RST 30h` and the trap, each followed by `G`; and the console's 30 rows read back from its map against what was sent. `make hello` checks the sign-on and the power-on-only self-test across a RESET; `make bootkeys` types on the PS/2 and membrane models.
- **Monitor (Z80 parts):** plain and `P` addresses, including window 0 after an NMI and the register page; `P` reads and writes ports; `R` shows and sets every register, IFF and IM; `I` against a list of every opcode (checked against sjasmplus's own listing); breakpoints; a break, a trap and an NMI each followed by `G` that goes on with every register, the MMU, CPUSPEED and the screen as they were.
- **NMI page:** the NMI path through page 3 into the common monitor and out by `RETN`, with the program's stack in window 0 and elsewhere; the PC and SP shown are NMICAPPC and NMICAPSP, also with SP pointing at ROM; the entry and the exit change no byte outside page `0x0FF` (a checksum of all other SRAM before and after); with NMICTL.EN = 0, page 0's `0x0066` reaches the same monitor, the PC shown is NMICAPPC and `G` returns to it; `G addr` after an NMI carries on at addr; a new program started after an NMI can be broken into again, and starts with the interrupt pages off; an NMI inside a program's maskable handler that uses the interrupt pages shows and restores the handler's map.
- **Debug unit and stub** (section 8.8): `G addr break` in RAM and in ROM stops before the instruction with PC at break; `N` runs one instruction of each class and shows `Step at`; an NMI at the prompt goes back to the prompt with the stopped program unchanged; the monitor entered by `RST 30h` with breakpoints left on does not stop in its own code; the debug channel's tests of debug.md, section 11, with no byte outside pages `0x0FC`–`0x0FF` changed by a stop and a continue.
- **Broken workspace:** a program that overwrites pages `0x0FE`–`0x0FF` and is then broken into gets a working monitor.
- **Loader:** the shared spec's upload tests, with every range of section 9 accepted or refused; a boot ROM image written and running after the reset; in simulation with the FT232H model.
- **BASIC:** a resident image loaded, protected (writes to its windows change nothing), kept across a button reset without an SD read, loaded again when its ICRC check fails.

## 13. Open points

| # | Item |
|---|------|
| B1 | PS/2 start-up keys: a 250 ms window after the sign-on catches a key held through a reset, but not at power-on, when the keyboard is still starting. Wait longer at power-on (up to 1 s), or accept the Spectrum keyboard only then |
| B2 | Development over JTAG: every JTAG load is a power-on, so D must be held as it ends, or the ROM built with `-DDEVROM` (never sets ROMLOCK) |
| B3 | BASIC's memory map: pages `0x0F8`–`0x0FB` (32 KB) at `0x2000`–`0x9FFF`, leaving `0x8000`–`0xFFFF` with a 24 KB image. To confirm with the BASIC tickets (design plan, branch 13) |
| B4 | The key codes 130–139 and 145–156 are those BBC BASIC's line editor is believed to expect (Dean Belfield's ports); check against the host layer before it is written |
| B5 | Taking the screen at a break leaves sprites, L1, L2 and the DMA engine running; whether the monitor should also pause them (and which of their registers read back, spec 4) |
| B6 | The ROM budget: 32 KB for the console, keyboards, monitor, disassembler (about 5 KB), loader, FAT32 reader and CRC table. Measure as each step is built. After step 1 (ticket #22): page 0 2.9 KB of 8 (the entry table, start-up, the console and keyboard core, the ROM calls, the monitor's entry and exit, the IM 2 table at the top); page 1 6.0 KB (the monitor 5.0 KB: the rest of start-up, the entry, the command line and the commands; the self-test 0.9 KB; the tape demo 0.1 KB); page 2 2.7 KB (the font 2 KB, the help 0.7 KB); page 3 empty. 11.6 KB of the 32 in all |
| B7 | SRAM page 0 under the ROM and pages `0x0FC`–`0x0FD` are free; the ROM may later want them (for example for CP/M 3, design plan branch 7) |
| B8 | CP/M 3 (later) has its own BIOS in place of the RST calls; how it sits with the boot ROM is for its own spec |
| B9 | The console's state in the map's hidden columns relies on SCROLLX staying 0 for the console and on the fetcher never reading columns 96–127; spec 4's tile mode to confirm |
| B10 | Video, sprite and copper state: section 6 lists what the ROM sets; anything not listed is as reset left it. Check the list against each unit's spec when the ROM is written |
| B11 | Closed (the user confirmed): the program map of section 5.1. Windows 1–7 = SRAM pages 1–7, so a CPU address is its own physical address in RAM; SP = `0xFFFE` holding the return-to-monitor address (`0x0040`), so a `RET` ends the program |
| B12 | Closed (the user confirmed): ROMLOCK is decided at power-on only (RESETWHY.POWER): with D held it stays clear; otherwise the ROM sets it (section 4.5; shared spec, section 9) |
| B13 | Should the monitor or the ROM use the maskable interrupt pages itself (for example to serve its own interrupts from a ROM page without the program mapping anything)? Version 1: no; the ROM leaves them off and to programs (design plan, branch 17) |
| B14 | Closed (design plan, branch 17): NMIP0W resets to the workspace page `0x0FF` instead of NONE. The entry saves SP, AF, BC and HL into the NMI save area (section 5.3) through window 0 while it reads the monitor page, and the exit runs its last bytes from there, so with capture on an NMI touches no program memory at all (section 8.6) |
| B15 | Done: the shared spec's section 4.3 now says each machine chooses how its breakpoint works and whether ROM works (agreed with retro68k, 25 October 2026) |
| B16 | The step command is `N` (agreed with retro68k; added to the shared spec's command table). Its message `Step at <addr>` and Enter repeating it are proposed here |
| B17 | An NMI taken while the monitor itself runs goes back to the prompt and keeps the stopped program (section 8.8). Needed for attach (BREAK at the prompt) |
