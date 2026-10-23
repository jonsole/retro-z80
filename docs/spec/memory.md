# Spec 2: Memory

Status: **draft**

This spec describes how the Z80 and the chipset share the KS3's fast SRAM: memory slots and their cycles, who owns each cycle and who gets the spare ones, the SRAM controller and its timing, the MMU that gives the Z80 its 64 KB view, the register page, and the physical address map that chipset units use.

The CPU side of each access (when the Z80 asks, and which cycle it uses) is spec 1, section 5. As in retro68k (its spec 5), memory time is cut into fixed slots with fixed owners, so every user's bandwidth is guaranteed. Unlike retro68k, nobody ever takes the CPU's cycles.

## 1. Summary

| Item | Value |
|------|-------|
| Memory | One 16-bit SRAM on the KS3: IS61WV204816BLL-10, 2M × 16 (4 MB), 10 ns. Some boards have 2 MB (1M × 16); SYSCFG reports which (spec 7) |
| Memory cycle | 2 system clocks = 35.7 ns. One 16-bit read or write at any address; byte writes with /UB and /LB |
| Slot | 4 cycles = 8 clocks = 143 ns. A 576p line (32 µs) is exactly 224 slots |
| Cycle 0, 2 | CPU. Never taken by anyone else |
| Cycle 1 | Display fetch (layers 0 and 1, the attribute layer) |
| Cycle 3 | In order: a display FIFO below its low mark (urgent); copper; sprites; display top-up |
| Spare cycles | A cycle its owner leaves goes to the others, in the cycle 3 order, then the DMA engine (spec 14) |
| Z80 waits | Never (spec 1, section 5) |
| Bandwidth | 56 MB/s in all; 14 MB/s per cycle number; 448 display bytes per line guaranteed |
| On and off | DMACON (spec 4) turns each memory user on and off, as in retro68k |
| MMU | Eight 8 KB windows, each with a read page (MMU0–MMU7, ports `0x80`–`0x8F`) and a write page (MMU0W–MMU7W, ports `0x90`–`0x9F`); the write page follows the read page unless set apart. 10-bit page numbers: SRAM, boot ROM (32 KB), the register page, NONE or reserved |
| Register page | MMU page `0x3F8`: the system ports at offsets `0x0000`–`0x00FF`, the custom block at `0x1000`–`0x13FF` |
| Chipset addresses | 22-bit physical byte addresses straight into the SRAM, not through the MMU |
| Refresh | None needed |

### 1.1 Comparison with retro68k

| retro68k (spec 5) | retro-z80 | Why |
|-------------------|-----------|-----|
| Slot of 5 cycles, 100 ns (20 ns cycles at 100 MHz) | Slot of 4 cycles, 143 ns (35.7 ns cycles at 56 MHz); 224 slots a line | The 56 MHz system clock, set by the Z80's speeds (spec 1) |
| Cycle 0 CPU; 1 and 3 display; 2 audio and peripherals; 4 free pool | Cycles 0 and 2 CPU; 1 display; 3 shared (urgent display, copper, sprites, display top-up) | Bandwidth: a 28 MHz Z80 needs up to two cycles a slot; one cycle is left for the display |
| Display: 1,280 bytes a line | 448 bytes a line guaranteed (cycle 1), 896 with all of cycle 3 | Bandwidth |
| No line buffers: data fetched just in time into BPLxDAT | Display FIFOs, a repeat buffer for layers shown 2× tall, a sprite row store; the draw beam runs one line ahead (spec 4, spec 5) | Bandwidth: the fetch must spread over the whole line |
| An urgent display fetch, or a "nasty" copper (COPCON.PRI), may take the CPU's cycle 0: the CPU waits one slot | Nobody ever takes cycles 0 and 2; the CPU never waits. The copper has a fixed place in cycle 3, after urgent display fetches | Z80: no wait states (spec 1) |
| — | The swap at 28 MHz: a CPU read may use cycle 1 or 3 and give its next cycle to that cycle's owner (section 4.2) | Z80: a read must be served two T-states after its address |
| Audio has cycle 2 | Audio is parked (spec 13); its cycles are not yet assigned (open point M7) | Sound still open (design plan, Q1) |
| DMA engine: free cycles; its HIGH bit may take CPU cycles | DMA engine: spare cycles only, last in the order, never CPU cycles | Z80: no wait states |
| 24-bit CPU addresses, 4 MB of Chip RAM in the CPU's map | 64 KB through the MMU: eight 8 KB windows with read and write pages (section 6) | Z80: 64 KB address space |
| Custom and system blocks in the CPU's memory map | The register page: both blocks as memory in any window (section 6.5), besides I/O ports | Z80: 64 KB address space |
| Boot ROM overlay at `0x000000` after reset | Boot ROM pages in windows 0 and 1 after reset (section 6.4) | MMU |
| DMACON at `0xE00094` | DMACON in the custom block's video registers (spec 4): one byte, the same enables | Z80 (8-bit registers) |

## 2. Memory types

| Memory | Where | Who can use it |
|--------|-------|----------------|
| **SRAM** | The board's 4 MB (or 2 MB) SRAM | The Z80 through the MMU; the display, sprites, copper and DMA engine by physical address |
| **Boot ROM** | 32 KB of block RAM in the FPGA, loaded with the bitstream (spec 7) | The Z80 only, through MMU pages `0x3FC`–`0x3FF` |
| **Register page** | Not memory: page `0x3F8` shows the system and custom registers and the palettes (section 6.5) | The Z80 only, through the MMU; uses no SRAM cycle |
| **Other block RAM** | Palettes, line buffers, display FIFOs and repeat buffers, serial and keyboard FIFOs | Through ports, the custom block or the register page; uses no memory cycles |

There is no other RAM. The chipset cannot read the boot ROM; the boot ROM copies anything the chipset needs (such as the console font) into SRAM.

## 3. Clocks and slots

| Unit | System clocks | Time |
|------|---------------|------|
| System clock | 1 | 17.86 ns (56 MHz) |
| Memory cycle | 2 | 35.7 ns |
| Slot | 8 | 143 ns |
| 576p line | 1792 | 32 µs = 224 slots |
| Frame (625 lines) | 1,120,000 | 20 ms = 140,000 slots |

The clocks in a slot are numbered 0–7 (**slot clocks**). Cycle k is requested in slot clock 2k, is on the SRAM pins from slot clock 2k+1 to 2k+3, and its read data is captured at slot clock 2k+3 (section 5). The Z80's T-states start on even slot clocks (spec 1, section 3).

Both MMCMs run from the same 50 MHz oscillator, so every line is exactly 224 slots. The slot counter restarts at 0 at the start of every line of the draw beam (spec 4), so fetches happen at the same points of every line.

## 4. Who owns each cycle

### 4.1 Owners

| Cycle | Owner | Notes |
|-------|-------|-------|
| **0** | **CPU** | If the CPU does not need it, it is a spare cycle |
| 1 | Display fetch | Layers 0 and 1 (bitmap or tile map, and tile patterns) and the attribute layer (a Spectrum extra), each into its own display FIFO (spec 4). If no FIFO has room, a spare cycle |
| **2** | **CPU** | As cycle 0 |
| 3 | Shared | In this order: **a display FIFO below its low mark** (urgent); **copper** (spec 6); **sprites** (spec 5); **display top-up** (any FIFO with room) |

Urgent display fetches go before the copper, so the picture is never late because of the copper. The copper may slip instead (spec 6 says how that shows).

The CPU has a cycle every 2 T-states at 28 MHz, and a Z80 never touches memory more often than every 3, so it always has a cycle free. **Cycles 0 and 2 are never given to anyone else while the CPU needs them.**

### 4.2 The swap at 28 MHz

At 28 MHz a Z80 read has only one usable cycle: the one whose pins start one clock after T1 starts (spec 1, section 5.2). When that is cycle 1 or 3, the CPU takes it and gives its next cycle (2, or 0 of the next slot) to the owner of the cycle it took. The CPU is certain not to need that next cycle (spec 1, section 5.3).

So every owner keeps its number of cycles per slot, but at 28 MHz a display, copper or sprite access is sometimes one cycle (35.7 ns) later than its usual place. The fetch units are built to allow this.

### 4.3 Spare cycles

A cycle its owner does not use is a **spare cycle**. Spare cycles come from:

- cycles 0 and 2 the CPU does not need (between accesses, I/O and internal T-states, boot ROM and register page accesses, slower CPU speeds),
- cycle 1 when no display FIFO has room (blanking, layers off, the second line of a layer shown 2× tall),
- cycle 3 when nobody wants it.

Each spare cycle goes to the first that wants it of:

1. a display FIFO below its low mark;
2. the copper;
3. the sprites;
4. display top-up;
5. the **DMA engine** (spec 14).

The DMA engine has no cycle of its own: it runs only on spare cycles, after everyone else, so it never slows the CPU or the picture. Audio (spec 13) is parked; where it fits in this order is decided with it (open point M7). If nobody wants a cycle, it is idle: the SRAM is left alone.

### 4.4 Turning users on and off

As in retro68k, one register, **DMACON**, turns the memory users on and off with set/clear writes: DMAEN (all of them), BPLEN (display fetch), COPEN (copper), BLTEN (DMA engine), SPREN (sprites) and AUDEN (audio, reserved). It is in the custom block's video registers; spec 4 gives its offset and bit layout. A user that is off asks for no cycles, and its cycles become spare. The CPU's cycles cannot be turned off.

## 5. The SRAM controller

### 5.1 Pins

As in retro68k (its spec 5 and `top_ks3.v`):

| Pin | Width | Use |
|-----|-------|-----|
| ram_addr_o | 21 | Word address (physical byte address bits 21–1). Pin 20 is unused on 2 MB boards |
| ram_data_io | 16 | Data, both ways. Low byte D7–D0 = even byte address |
| ram_cs_n_o | 1 | Chip select, low during a cycle |
| ram_oe_n_o | 1 | Output enable, for reads |
| ram_we_n_o | 1 | Write enable |
| ram_lb_n_o, ram_ub_n_o | 1 each | Byte selects: low (even) and high (odd) byte |

Address, /CS, the byte selects and write data come from flip-flops in the I/O pads, so their timing is the same in every cycle. /OE, /WE and the data bus enable come from DDR output registers (ODDR), so they can change half a clock (8.9 ns) into a cycle. Read data is captured by flip-flops in the input pads.

### 5.2 One memory cycle

The SRAM is asynchronous: given an address it answers within 10 ns. A cycle on the pins lasts 2 clocks, from pin time P (slot clock 2k+1) to P + 35.7 ns.

| | P (0 ns) | P + 8.9 ns | P + 17.9 ns | P + 26.8 ns | P + 35.7 ns |
|---|---|---|---|---|---|
| **Read** | Address, /CS, /UB and /LB out; /OE low (after a write: at 8.9 ns) | | SRAM data valid (10 ns + pad delays) | | Data captured |
| **Write** | Address, /CS, one or both byte selects, data out (after a read: data from 8.9 ns) | /WE low | | /WE high | Done |

Margins against the IS61WV204816BLL-10 (to be checked against the datasheet, open point M1):

| Parameter | Needs (10 ns part) | Here |
|-----------|--------------------|------|
| Address to data, tAA | 10 ns | About 20 ns spare after pad and board delays |
| /WE pulse, tPWE | about 8 ns | 17.9 ns |
| Address set-up to /WE, tSA | 0 | 8.9 ns |
| Address hold after /WE, tHA | 0 | 8.9 ns |
| Data set-up to /WE high, tSD | about 6 ns | 26.8 ns (17.9 ns after a read) |
| Data hold after /WE high, tHD | 0 | 8.9 ns |
| /OE high to SRAM off the bus, tHZOE | about 4 ns | 8.9 ns before the FPGA drives |

- **Read after write:** the FPGA stops driving the data bus at P, and /OE goes low at P + 8.9 ns.
- **Write after read:** /OE goes high at P, and the FPGA starts driving data at P + 8.9 ns.
- So no gap cycle is needed between any two cycles. An idle cycle leaves /CS, /OE and /WE high and the data bus undriven (pulled up).

The cycle is nearly twice as long as retro68k's 20 ns, so there is plenty of margin on the KS3's wiring.

### 5.3 Byte and word access

- **Reads** always read the whole 16-bit word (/UB and /LB both low). Chipset units use both bytes; the CPU keeps the byte chosen by address bit 0.
- **Writes** come from the CPU and the DMA engine (spec 14). A byte write drives the byte on both halves of the data bus and pulls only /LB (even address) or /UB (odd address) low, so the other byte is unchanged. A word write pulls both low.
- The memory is little-endian: the byte at an even address is the low half of its word.

## 6. The MMU

### 6.1 Windows

The Z80's 64 KB address space is cut into eight 8 KB windows. Address bits A15–A13 pick the window; A12–A0 are the offset within it. Each window has **two page registers**: a **read page** (used by opcode fetches and reads) and a **write page** (used by writes). Most of the time they are the same page; splitting them gives ROM shadowing, registers behind ROM, and similar tricks (section 6.6).

| Window | Z80 addresses | Read page | Write page |
|--------|---------------|-----------|------------|
| 0 | `0x0000`–`0x1FFF` | MMU0 (`0x80`, `0x81`) | MMU0W (`0x90`, `0x91`) |
| 1 | `0x2000`–`0x3FFF` | MMU1 (`0x82`, `0x83`) | MMU1W (`0x92`, `0x93`) |
| 2 | `0x4000`–`0x5FFF` | MMU2 (`0x84`, `0x85`) | MMU2W (`0x94`, `0x95`) |
| 3 | `0x6000`–`0x7FFF` | MMU3 (`0x86`, `0x87`) | MMU3W (`0x96`, `0x97`) |
| 4 | `0x8000`–`0x9FFF` | MMU4 (`0x88`, `0x89`) | MMU4W (`0x98`, `0x99`) |
| 5 | `0xA000`–`0xBFFF` | MMU5 (`0x8A`, `0x8B`) | MMU5W (`0x9A`, `0x9B`) |
| 6 | `0xC000`–`0xDFFF` | MMU6 (`0x8C`, `0x8D`) | MMU6W (`0x9C`, `0x9D`) |
| 7 | `0xE000`–`0xFFFF` | MMU7 (`0x8E`, `0x8F`) | MMU7W (`0x9E`, `0x9F`) |

The MMU registers are system ports, so the copper and the DMA engine cannot reach them.

### 6.2 Register format

Each page register is a 2-byte value at two ports (spec 3, multi-byte rule):

| Port | Name | Access | Bits | Meaning | Reset |
|------|------|--------|------|---------|-------|
| `0x80` + 2n | MMUnL | RW | 7–0 | Read page bits 7–0 (latched) | Section 6.4 |
| `0x81` + 2n | MMUnH | RW | 1–0 | Read page bits 9–8; writing commits the read page **and** the write page | Section 6.4 |
| | | | 7–2 | Unused: write 0, read 0 | |
| `0x90` + 2n | MMUnWL | RW | 7–0 | Write page bits 7–0 (latched) | Section 6.4 |
| `0x91` + 2n | MMUnWH | RW | 1–0 | Write page bits 9–8; writing commits the write page only | Section 6.4 |
| | | | 7–2 | Unused: write 0, read 0 | |

- **Write follows read.** Committing a read page (writing MMUnH) sets the window's write page to the same page. Ordinary code therefore changes a window with one register, as on any 8-bit MMU. Writing MMUnWH afterwards sets only the write page and splits the window.
- Writing a low byte only fills the latch; writing the high byte commits, so a window never points at a half-changed page. Reading returns the committed value.
- The new mapping applies from the next memory access after the commit, including the next opcode fetch. Code can change the window it runs in, as long as the next instruction is at the same address in the new page.
- The page registers can also be written through the register page (section 6.5): `LD (nn),HL` writes the low byte then the high byte, so one instruction (16 T-states) changes a window.

### 6.3 Pages

| Page | Meaning |
|------|---------|
| `0x000`–`0x0FF` | SRAM, physical `0x000000`–`0x1FFFFF` (every board) |
| `0x100`–`0x1FF` | SRAM, physical `0x200000`–`0x3FFFFF` (4 MB boards). On 2 MB boards these mirror pages `0x000`–`0x0FF` |
| `0x200`–`0x3F7` | Reserved (for example fast RAM in block RAM later, design plan Q9): reads give `0xFF`, writes are ignored |
| `0x3F8` | **REGS: the register page** (section 6.5) |
| `0x3F9`–`0x3FA` | Reserved |
| `0x3FB` | **NONE:** reads give `0xFF`, writes are ignored; kept unused for ever, so it is the way to make a window read-only |
| `0x3FC`–`0x3FF` | Boot ROM pages 0–3 (ROM offsets `0x0000`–`0x7FFF`) |

The physical byte address of a Z80 access to an SRAM page is page × `0x2000` + A12–A0, that is {page[8:0], A12–A0}.

- **Read-only windows:** set the write page to NONE. Reads are normal; writes use no SRAM cycle and give no error. This keeps a ROM image (a BASIC, or a Spectrum ROM for a port) in SRAM safe.
- **Boot ROM pages** ignore writes unless SYSCON.ROMWE is set (spec 7). They use no SRAM cycle: the block RAM answers in one clock, and the CPU's cycle becomes spare.
- **REGS, NONE and reserved pages** use no SRAM cycle either.
- The same page can be in several windows at once, and in a window's read and write page at once.

### 6.4 Reset state

| Window | Read page | Write page |
|--------|-----------|------------|
| 0 | `0x3FC` (boot ROM page 0) | `0x3FC` |
| 1 | `0x3FD` (boot ROM page 1) | `0x3FD` |
| 2–7 | `0x000`–`0x005` (SRAM pages 0–5) | The same |

So the Z80 starts at `0x0000` in the boot ROM, with 16 KB of ROM at the bottom and 48 KB of SRAM above it, like a Spectrum 48K. Boot ROM pages 2 and 3 are reached by mapping them into a window. Every reset (spec 7) puts the MMU back to this state.

**Spectrum extra, NMI monitor paging:** when an NMI is taken, the bus interface switches window 0 to the monitor page (read `0x3FF`, write NONE) and restores it after `RETN` (spec 1, section 8.2; spec 7). MMU0 and MMU0W then read back the monitor mapping; the program's own pages are in the saved-page registers (NMISAVL, NMISAVWL, NMISAVH) in the system ports `0x70`–`0x7F` (spec 7).

### 6.5 The register page

Page `0x3F8` shows the machine's registers as memory, in any window, so the Z80 can use LD, LDI, read-modify-write instructions (`SET`, `INC (HL)`, `INC (IX+d)`) and 16-bit loads on them. The registers are the same ones as through I/O ports (spec 3); both ways of reaching them always work.

| Offset | Contents |
|--------|----------|
| `0x0000`–`0x00FF` | The **system block**: the 256 system ports, offset = port number. Offsets `0x00C0`–`0x00C3` are reserved (those port numbers are the custom block's, below) |
| `0x0100`–`0x0107` | KEYROW0–7: the membrane keyboard's rows one by one, the memory form of port `0xFE` (a Spectrum extra, spec 12) |
| `0x0108`–`0x0FFF` | Reserved |
| `0x1000`–`0x13FF` | The **custom block**: custom offset k at `0x1000` + k (`0x000`–`0x3FF`) |
| `0x1400`–`0x17FF` | Reserved |
| `0x1800`–`0x1FFF` | The palettes: entry i of palette p at `0x1800` + p × `0x200` + 2i (spec 4) |

Reserved offsets read `0xFF` and ignore writes. The page is 8 KB, so in a window at `0xA000`, say, the custom block starts at `0xB000`, and custom register k is at `0xB000` + k.

- **No SRAM cycle:** register page accesses go to the register bus, as I/O accesses do, and leave the CPU's memory cycle spare (spec 1, section 5.6).
- **Side effects are the same as for I/O:** reading a FIFO data port (SERDATA, KBDATA, SDDATA) through the register page takes a byte. The bus interface only reads the register page on a real read (spec 1).
- **Opcode fetches** from the register page read `0xFF` (`RST 38h`) and have no side effect.
- **Write order matters for multi-byte values:** `LD (nn),HL`, `LD (nn),DE`, `LDI` and `LDIR` write the low byte first and work; `PUSH` and `LDDR` write the high byte first, which commits before the low byte arrives. Don't use them on registers.

### 6.6 What split read and write pages are for

| Read page | Write page | Use |
|-----------|------------|-----|
| ROM | SRAM page | Shadow the ROM: `LDIR` the window onto itself, then map the SRAM page for reads too |
| ROM | REGS | Code and tables run from ROM while plain writes in the same window go to the registers |
| SRAM | NONE | A read-only window (ROM image kept in RAM) |
| SRAM page A | SRAM page B | Read one buffer while writing another at the same addresses (copy with a transform, or draw into a back buffer behind code) |
| REGS | REGS | All registers as memory |

## 7. Physical address map (chipset units)

The display, sprites, copper and DMA engine address the SRAM with 22-bit physical byte addresses, without the MMU. Their pointer registers are 3 bytes (spec 3); bits 23–22 are ignored.

| Physical address | 4 MB board | 2 MB board |
|------------------|------------|------------|
| `0x000000`–`0x1FFFFF` | SRAM pages `0x000`–`0x0FF` | SRAM, all of it |
| `0x200000`–`0x3FFFFF` | SRAM pages `0x100`–`0x1FF` | Mirror of `0x000000`–`0x1FFFFF` (bit 21 ignored) |

- Any unit can use any part of the SRAM: screens, tiles, sprite images and copper lists can be anywhere.
- The SRAM page holding an address is address ÷ `0x2000`, so a program finds the physical address of anything it has mapped from the MMU register.
- **2 MB vs 4 MB:** the design is the same for both; on a 2 MB board address bit 21 has no effect. SYSCFG tells software which board it is on (spec 7). Software must not use pages `0x100`–`0x1FF` on a 2 MB board.

## 8. Bandwidth

Each cycle moves 16 bits, except a CPU cycle, which moves one byte.

| | Cycles per second | Bytes per second | Cycles per line (224 slots) |
|---|---|---|---|
| All cycles | 28 M | 56 MB/s | 896 |
| CPU (cycles 0, 2) | 14 M | Up to 14 MB/s offered | 448 |
| Display (cycle 1) | 7 M | 14 MB/s | 224 (448 bytes) |
| Cycle 3 | 7 M | 14 MB/s | 224 (448 bytes) |

**The CPU's needs.** A Z80 makes at most one access every 3 T-states:

| CPU speed | Most accesses per line | CPU cycles left spare per line, at least |
|-----------|------------------------|------------------------------------------|
| 28 MHz | 298 | 150 |
| 14 MHz | 149 | 299 |
| 7 MHz | 74 | 374 |
| 3.5 MHz | 37 | 411 |

Typical code makes an access about every 4 T-states, so even at 28 MHz about half the CPU's cycles are spare. These, with the cycle 1s and 3s nobody wants, are what the DMA engine runs on (spec 14 gives its speeds).

**The display's budget** (spec 4). A layer shown 2× tall (VSCALE) fetches only on the first output line of each pair and replays its pixels from a repeat buffer on the second, so the budget is **per output line**:

| | Bytes per output line |
|---|---|
| Cycle 1 alone | 448 |
| Cycles 1 and 3 (with no copper or sprites) | 896 |
| Plus spare CPU cycles at 28 MHz | at least 300 more |

The second line of a 2×-tall pair leaves its cycles free for sprites, the copper and spare use. **Tip:** two 2×-tall layers whose windows start on lines of opposite parity fetch on alternate lines, which halves their peak.

## 9. Who uses which cycle

| Unit | Cycles | What for |
|------|--------|----------|
| CPU (spec 1) | 0 and 2; at 28 MHz sometimes 1 or 3 by the swap (section 4.2) | Opcode fetches, reads, writes. Never waits |
| Display (spec 4) | 1; 3 when a display FIFO is below its low mark (first); 3 as top-up (after sprites); spare cycles | Layers 0 and 1 and the attribute layer, into one FIFO per source, prefilled in the horizontal blank and topped up as the draw beam takes pixels |
| Copper (spec 6) | 3, after urgent display fetches; spare cycles, likewise | Its instruction words. May slip behind urgent fetches |
| Sprites (spec 5) | 3, after urgent display fetches and the copper; spare cycles | Each line's sprite rows, during the line before, into the sprite row store |
| DMA engine (spec 14) | Spare cycles only, after all the others | Copies and fills in SRAM |
| Audio (spec 13) | Parked: not yet assigned (open point M7) | |

During vertical blanking (lines 0–48) the display fetches nothing until it prefills for line 49, so cycle 1 is spare for nearly 49 lines (about 1.5 ms) of every frame.

## 10. FPGA resources

| Item | Resource |
|------|----------|
| Slot controller and SRAM controller | Estimate 150–250 LUTs |
| MMU: 16 × 10-bit page registers, latches, page decode | Estimate 100–150 LUTs |
| Boot ROM | 16 block RAMs (spec 7) |

## 11. Test plan

- **Cycle table:** each owner gets its cycles at the same slot clocks on every line; the slot counter restarts each line; spare cycles go to the right unit in the order of section 4.3, the DMA engine last; a FIFO below its low mark wins cycle 3 over a waiting copper, and the copper wins over sprites and top-up.
- **CPU never loses a cycle:** with the copper, sprites, the DMA engine and every display FIFO busy, no CPU access is ever moved; checked at all four speeds.
- **DMA engine:** gets only spare cycles; with everything else busy it may get none, and nothing else is slowed.
- **DMACON:** each user turned off asks for no cycles, and its cycles go to the others; DMAEN off turns all of them off; the CPU is not affected.
- **Swap:** at 28 MHz, a read in cycle 1 or 3 gives the next cycle to that cycle's owner, and no owner loses a cycle per slot.
- **SRAM model:** run the controller against an SRAM simulation model (from retro68k) with the datasheet checks on: set-up, hold, pulse widths, bus turnaround, at 35.7 ns cycles.
- **Byte writes:** writing an even or odd byte changes only that byte, from the CPU and from the DMA engine; chipset word reads see even bytes in the low half.
- **MMU:** reset state; a low-byte write alone changes nothing; the high-byte write commits both; read back; committing a read page also sets the write page; a later write-page commit splits the window, and reads and writes then go to their own pages; NONE ignores writes; ROM pages ignore writes unless ROMWE; reserved pages read `0xFF`; pages `0x100`–`0x1FF` mirror on a 2 MB build; ports `0x80`–`0x9F` and the same offsets of the register page reach the same registers.
- **Register page:** every system port answers at its offset with the same value and side effects as through I/O; every custom register answers at `0x1000` + its offset as through its 16-bit port; KEYROW0–7 at `0x0100`–`0x0107`; the palettes at `0x1800`–`0x1FFF`; reserved offsets (including `0x00C0`–`0x00C3`) read `0xFF`; opcode fetches read `0xFF` with no side effect; `LD (nn),HL` commits a 2-byte register; no SRAM cycle is used; a copper write in the same clock goes first.
- **Physical addresses:** a pattern written by the CPU through every page is read by a chipset test port at page × `0x2000` + offset; bits 23–22 of pointers are ignored.
- **Board test:** a full RAM test from the CPU at 28 MHz with the display, sprites, copper and DMA engine all busy.

## 12. Open points

| # | Item |
|---|------|
| M1 | Check the 35.7 ns read and write cycles and the read/write turnaround against the IS61WV204816BLL-10 datasheet and the KS3's board timing (shared with retro68k, its M2) |
| M2 | Is the KS3 fitted with 4 MB or 2 MB, and how does the design know? Proposed: a build parameter sets the SYSCFG bit; the boot ROM can also test for the mirror (design plan, Q6) |
| M3 | Changing a window takes two OUTs (22 T-states), or one `LD (nn),HL` (16 T-states) through the register page. If games need faster paging, a later version could add a port that sets page bits 7–0 and clears bits 9–8 in one write |
| M4 | The swap at 28 MHz (section 4.2) refines the fixed cycle owners of the design plan (D4); specs 4–6 must allow one cycle of delay |
| M5 | Exact display FIFO depth and low mark are set in spec 4 (about 128–256 bytes per source) |
| M6 | The register page's read must fit tv80's read window at 28 MHz, also when a copper write moves it by a clock (spec 1, B6) |
| M7 | Audio (spec 13, parked): retro68k gives it a cycle of its own (cycle 2). Here it would most likely take a few words a line from cycle 3, between the copper and the sprites, or from spare cycles; decided with spec 13 |
| M8 | Closed: spec 4 puts the palettes at `0x1800`–`0x1FFF` of the register page. `0x0108`–`0x0FFF` and `0x1400`–`0x17FF` are free for later tables |
