# Spec 2: Memory

Status: **draft**

This spec describes how the Z80 and the chipset share the KS3's fast SRAM: the 100 MHz clock, memory cycles and slots, who owns each cycle, the scheduler that gives out every cycle, the SRAM controller and its timing, the MMU that gives the Z80 its 64 KB view, the register page, and the physical addresses the chipset uses.

It is retro68k's spec 5 (memory architecture) narrowed to an 8-bit CPU. The clock, the cycles, the slots, the scheduler (`dmac.v`) and the SRAM controller (`sram_ctl.v`) are retro68k's. The cycle owners differ in one way: the Z80 owns two cycles of each slot instead of one, and nobody takes a cycle it has asked for. The CPU side of each access (when the Z80 asks, and which cycle it uses) is spec 1, section 5.

## 1. Summary

| Item | Value |
|------|-------|
| Memory | One IS61WV204816BLL-10 SRAM on the KS3: 2M × 16 bit (4 MB), 10 ns. Some boards may have 2 MB; SYSCFG.CHIPMB reports which, as a build constant (section 11) |
| System clock | 100 MHz, as retro68k |
| Memory cycle | 20 ns = 2 clocks: one 16-bit read or write at any address (byte writes with /UB and /LB) |
| Slot | 100 ns = 5 memory cycles (numbered 0–4) = 2 Z80 T-states at 20 MHz. A 576p line is exactly 320 slots |
| Cycles 0 and 2 | CPU. A cycle the CPU has asked for is never given to anyone else |
| Cycles 1 and 3 | Display fetch: layers L0–L2, the attribute layer, sprites (hard-deadline channels, earliest deadline first) |
| Cycle 4 | Audio (reserved, spec 13); while audio is parked, the free pool |
| Free pool | The copper and the DMA engine, plus any cycle its owner leaves (section 5) |
| Z80 waits | Never (spec 1, section 5) |
| Bandwidth | 100 MB/s in all; display 40 MB/s (1,280 bytes per line, as retro68k); free pool at least about 47 MB/s |
| On and off | DMACON (spec 4) turns each memory user on and off, as retro68k's |
| MMU | Eight 8 KB windows, each with a read page and a write page; 10-bit page numbers; registers `0x80`–`0x9F` of the system page `0x00` (ports `0x8000`–`0x9F00`) |
| Interrupt pages | A retro-z80 extra: an interrupt or NMI switches chosen windows to pages of its own, and back at `RETI` or `RETN`; an NMI always keeps its return address in registers instead of on the stack (stack capture). Two sets, maskable and NMI; registers `0x40`–`0xFF` of I/O page `0x01` (sections 9.7 and 9.8) |
| Register page | MMU page `0x3F8`: page p, register r at offset p × 256 + r; KEYROW0–7 at `0x0100`; the interrupt pages at `0x0140`–`0x01FF`; the palettes at `0x1400`–`0x1FFF` (section 10) |
| Chipset addresses | 22-bit physical byte addresses straight into the SRAM, not through the MMU |
| Refresh | None needed (SRAM) |

### 1.1 Comparison with retro68k

| retro68k (spec 5) | retro-z80 | Why |
|-------------------|-----------|-----|
| Cycle 0 CPU; 1 and 3 display; 2 audio and peripherals; 4 free pool | Cycles 0 and 2 CPU; 1 and 3 display; 4 audio (reserved) and free pool | Z80: a read must be served 100 ns after its address appears, from either of the two T-state phases in a slot. Cycles 0 and 2 (40 and 60 ns apart) give every phase a cycle in time (spec 1, section 5) |
| An urgent hard-deadline fetch, or a copper at PRI 2 (nasty), may take the CPU's cycle 0; the CPU waits one slot | Nobody takes a cycle the CPU has asked for. An urgent fetch may take cycle 0 or 2 only when the CPU has not asked for it; otherwise it waits for the next cycle, a display cycle 20 ns later (section 5.3). No nasty copper | The Z80 never waits (design plan, branch 11) |
| DMA engine HIGH mode may take the CPU's cycle 0, leaving it 1 in 2, 4 or 8 (`blt_high`, `blt_share`) | Left out | Design plan, branch 11 (no HIGH, no CPUSHARE) |
| CPU uses at most 10 MB/s (one access per 200 ns bus cycle) | CPU uses at most 6.67 M accesses a second (one per 3 T-states at 20 MHz), one byte each | Z80 |
| Free pool typically 50–65 MB/s | At least about 47 MB/s, plus display cycles no layer needs | The Z80's two cycle numbers, of which it uses at most one per slot |
| Audio owns cycle 2 | Audio is parked (spec 13); cycle 4 is kept for it and is free pool meanwhile | Sound still open (design plan, Q1) |
| 24-bit CPU addresses; 4 MB of Chip RAM in the CPU's map | 64 KB through the MMU: eight 8 KB windows with read and write pages (section 9) | Z80: 64 KB address space |
| Custom and system blocks in the CPU's memory map | I/O ports in register:page form (spec 1, section 6), and the register page in any window (section 10) | Z80: 64 KB address space, I/O instructions |
| Palettes at `0xE04000`, 4-byte entries `0x00RRGGBB` | Register page `0x1400`–`0x1FFF`, packed 3-byte entries (blue, green, red) | 8 KB page: four palettes at 4 bytes per entry would not fit beside the custom block (section 10.2) |
| Boot ROM overlay at `0x000000` after reset | Boot ROM pages in windows 0 and 1 after reset (section 9.4) | MMU |
| Chip RAM past the end on a 2 MB board is a bus error | On a 2 MB build, pages `0x100`–`0x1FF` mirror pages `0x000`–`0x0FF` | Z80: no bus errors |
| DMACON 16 bits at `0xE00094` | DMACON one byte in the custom block's video globals (spec 4): the same enables in the same order | Z80 (8-bit registers) |
| – | Interrupt pages and stack capture: an interrupt or NMI switches chosen windows, and an NMI always keeps its return address in registers (sections 9.7 and 9.8). The NMI monitor paging is the NMI set's default | A retro-z80 extra (design plan, branch 17): retro68k has no MMU |

## 2. Memory types

| Memory | Where | Who can use it |
|--------|-------|----------------|
| **SRAM** ("Chip RAM" in retro68k) | The board's 4 MB (or 2 MB) SRAM | The Z80 through the MMU; the display, sprites, copper and DMA engine by physical address |
| **Boot ROM** | 32 KB of block RAM, loaded with the bitstream (spec 7) | The Z80, through MMU pages `0x3FC`–`0x3FF`; the DMA engine reads it (spec 14), as retro68k's does. Uses no SRAM cycle |
| **Register page** | Not memory: page `0x3F8` shows the registers and the palettes (section 10) | The Z80 through the MMU; the DMA engine through the register bus (spec 1, section 4.2). Uses no SRAM cycle |
| **Other block RAM** | Palettes, sprite FIFOs, serial and keyboard FIFOs, descriptor RAM if built (spec 14) | Through registers; uses no memory cycles |

There is no other RAM. All RAM is chip RAM, and the CPU gets it at full speed. Of the chipset, only the DMA engine can read the boot ROM, as in retro68k: through the ROM's second block RAM port, one byte per clock, with no SRAM cycle; it cannot write it. The display, sprites and copper cannot read it, so the boot ROM copies anything they need (such as the console font) into SRAM.

## 3. Clocks and slots

The clocks are retro68k's (its spec 5, section 4.1): the 100 MHz system clock from the first MMCM, the 27 MHz pixel clock from the second, both from the board's 50 MHz oscillator.

| Unit | System clocks | Time |
|------|---------------|------|
| System clock | 1 | 10 ns (100 MHz) |
| Memory cycle | 2 | 20 ns |
| Slot | 10 | 100 ns |
| Z80 T-state at 20 MHz | 5 | 50 ns |
| 576p line | 3,200 | 32 µs = 320 slots |
| Frame (625 lines) | 2,000,000 | 20 ms = 200,000 slots |

The clock edges in a slot are numbered 0–9 (**slot edges**; `sc` in retro68k's `timebase.v`). Memory cycle k is **issued** at slot edge 2k: the scheduler picks its owner in the clock before, from the requests standing then. In the SRAM controller's terms (section 8):

| Event | Slot edge (cycle k) | Time after issue |
|-------|---------------------|------------------|
| Issued | 2k | 0 |
| On the SRAM pins | 2k + 1 to 2k + 3 | 10–30 ns |
| Read data captured in the input pad flip-flops | 2k + 3 | 30 ns |
| Read data usable by logic | 2k + 4 | 40 ns |

So cycle 0 is issued at 0 ns, cycle 1 at 20, cycle 2 at 40, cycle 3 at 60 and cycle 4 at 80 ns into the slot.

Both MMCMs run from the same oscillator, so every line is exactly 320 slots. The slot counter (`hslot`) restarts at 0 at the start of every line of the display beam, so the display fetches at the same points on every line (spec 4). The Z80's T-states start on slot edges 0 and 5 at every slot-locked speed (spec 1, section 3).

## 4. Who owns each cycle

### 4.1 Owners

| Cycle | Issued at | Owner | Notes |
|-------|-----------|-------|-------|
| **0** | 0 ns | **CPU** | If the CPU has not asked for it, it goes to the free pool |
| 1 | 20 ns | Display fetch | Layers L0–L2, the attribute layer and sprites: the hard-deadline channels (spec 4, spec 5), earliest deadline first. If none needs it, free pool |
| **2** | 40 ns | **CPU** | As cycle 0 |
| 3 | 60 ns | Display fetch | As cycle 1. The display's two cycles are 40 and 60 ns apart, as in retro68k |
| 4 | 80 ns | Audio (reserved) | Spec 13, parked. Until then, the free pool: the copper and the DMA engine |

The Z80 makes at most one memory access every 3 T-states (150 ns at 20 MHz), so it uses at most one of its two cycles in any slot, and at most two in any three slots (spec 1, section 5.5). The other is always free for the pool.

### 4.2 Bandwidth

- Total: 5 cycles × 2 bytes per 100 ns = **100 MB/s**.
- CPU: cycles 0 and 2 offer 20 M cycles a second; a 20 MHz Z80 uses at most 6.67 M of them (one byte each), typically about 5 M. Its other cycles go to the free pool.
- Display fetch: **40 MB/s** (cycles 1 and 3), as retro68k: 1,280 bytes per line, 1.48 bytes per pixel of the 864-pixel line.
- Cycle 4: 20 MB/s, reserved for audio; free pool meanwhile.
- Free pool (copper, DMA engine): cycle 4 (20 MB/s) plus at least 13.3 M unused CPU cycles a second (26.7 MB/s), plus the display cycles no layer needs: **at least about 47 MB/s**, typically 55–70 MB/s.

## 5. The scheduler

### 5.1 Channels

One block, the DMA controller (`dmac.v`, retro68k's, the equivalent of the Amiga's Agnus), decides who gets every memory cycle. Each user is a **channel** that holds a request (address, read or write, data) until it is granted; read data comes back 40 ns after the issue (section 3). Hard-deadline channels give, with each request, the time left until the data is needed, and say when it is **urgent** (about to be late).

| Channel | What | Kind |
|---------|------|------|
| CPU | The Z80 through the bus interface (spec 1) | Cycles 0 and 2; at 3.57 MHz the first of them that comes (spec 1, section 5.4) |
| BPL | Layer fetch: L0–L2 and the attribute layer (spec 4) | Hard deadline |
| SPR | Sprites: the 8 sprite FIFOs (spec 5) | Hard deadline |
| AUD | Audio (spec 13, parked; tied off) | Soft |
| SEQ | Sprite sequencer: its list (spec 17, a retro-z80 extra) | Best effort, with a soft deadline |
| COP | Copper: its list (spec 6) | Best effort |
| BLT | DMA engine: its 4 channels take turns inside the engine (spec 14) | Best effort |
| PORT | The DMA port: a test channel, as retro68k's; used by the simulation tests | Best effort |

### 5.2 Rules

For each cycle, the first rule that finds a request wins:

0. **The CPU's own cycle.** In cycles 0 and 2, a CPU request gets the cycle. Nothing overrides this.
1. **An urgent hard-deadline request** gets the cycle, whatever its number (except as rule 0). Earliest deadline first.
2. **The cycle's default owner:**

   | Cycle | Default owner |
   |-------|---------------|
   | 0, 2 | CPU (rule 0) |
   | 1, 3 | Hard-deadline channels, earliest deadline first |
   | 4 | Audio; then the copper at COPCON.PRI 1 (spec 6) |

3. **The free order:** hard-deadline channels (earliest deadline first), audio, the sprite sequencer, copper, DMA engine, the DMA port. The sequencer goes before the copper at PRI 0, since its few reads have a deadline (the gap line), and after the copper at PRI 1 (spec 17, section 5.4). The copper at COPCON.PRI 1 (high) moves to the front of this order, as in retro68k. There is no nasty copper: PRI 2 and 3 act as 1 (spec 6, section 5.1).

So no cycle is wasted: whatever its owner leaves goes to the next channel that wants one. In particular the display can use a cycle 0 or 2 the CPU is not using, and cycle 4 when audio and the copper leave it.

The CPU's request stands in the clock before its cycle is issued (spec 1, section 5), as every channel's does, so a cycle 0 or 2 the CPU has not asked for by then goes to the others. The bus interface always asks in time for the cycle it needs, and is never turned away.

### 5.3 Urgent fetches and the Z80

In retro68k an urgent display fetch may take the CPU's cycle 0, and the 68000 then waits one slot. Here that would break the rule that the Z80 never waits, so rule 0 comes first. This costs the display little:

- The cycle after each CPU cycle is a display cycle: 0 is followed by 1, and 2 by 3. So an urgent fetch that finds the CPU in its cycle waits at most one memory cycle, **20 ns**.
- The CPU uses at most one of cycles 0 and 2 per slot, so an urgent run of fetches still gets at least 4 cycles in every 5.
- Spec 4 sets the urgent mark one memory cycle (2 clocks) earlier than retro68k's to cover the 20 ns (open point M5).

A screen within the display budget (section 7) is rarely urgent at all. On a screen over budget, late data shows as in retro68k (spec 4), and the CPU is not slowed.

### 5.4 Turning users on and off

As in retro68k, one register, **DMACON**, turns the memory users on and off with set/clear writes: DMAEN (all of them), BPLEN (layer fetch), COPEN (copper), BLTEN (DMA engine), SPREN (sprites) and AUDEN (audio, reserved). It is one byte in the custom block's video globals (`0x000`–`0x00F`); spec 4 gives its offset and bit layout. A user that is off asks for no cycles, and its cycles go to the others. Together with each layer's own enable (spec 4) and SPRDMA (spec 5), every DMA user can be turned off on its own, so the CPU or the copper can do its job instead by writing its registers. The CPU's cycles cannot be turned off.

## 6. Fixed allocation per line

Every slot of every line has the same owners, so the allocation per line is the number of slots:

| Owner | Cycles | Cycles per line (320 slots) | Bandwidth |
|-------|--------|-----------------------------|-----------|
| CPU | 0, 2 | 640 | 20 M cycles a second offered; the Z80 uses at most a third (section 4.2) |
| Display fetch | 1, 3 | 640 | 40 MB/s: 1,280 bytes a line |
| Audio (reserved) | 4 | 320 | 20 MB/s; free pool meanwhile |
| Free pool | – | At least 747 (320 from cycle 4, 427 from the CPU's) | At least about 47 MB/s, plus display cycles no layer needs |

**The CPU's needs.** A Z80 makes at most one access every 3 T-states:

| CPU speed (spec 1, section 3) | Most accesses per line | CPU cycles left to the free pool per line, at least |
|-------------------------------|------------------------|-----------------------------------------------------|
| 20 MHz (n = 1) | 213 | 427 |
| 10 MHz (n = 2) | 106 | 534 |
| 5 MHz (n = 4) | 53 | 587 |
| 2.5 MHz (n = 8) | 26 | 614 |
| 3.57 MHz (Spectrum) | 38 | 602 |

During vertical blanking (49 of the 625 lines) there is no display fetch, so cycles 1 and 3 go to the free pool too. In the horizontal blank the display fetches only the first groups of each layer's next line (spec 4).

## 7. What each owner gets

| Owner | Needs | Gets |
|-------|-------|------|
| Display (layers, attribute layer) | Depends on the layers (spec 4) | Cycles 1 and 3: 1,280 bytes a line, retro68k's budget of 1.48 bytes per pixel |
| Sprites | Their FIFOs (spec 5) | Display cycles a layer leaves, then the free pool, first; urgent when a FIFO runs low |
| Audio | Parked | Cycle 4 is kept for it |
| Copper | 2 cycles per two-word instruction, 1 per MOVE (spec 6) | The free pool, after the hard-deadline channels and audio; first with high priority |
| Sprite sequencer | 8 words per sprite reused (spec 17) | The free pool, after the hard-deadline channels and audio, before the copper at PRI 0 |
| DMA engine | – | The rest of the free pool (spec 14) |

There are no line buffers: display data is fetched just in time into each layer's data registers, as in retro68k (spec 4). Nothing is stored for a whole line.

## 8. The SRAM controller

### 8.1 Pins

As retro68k (its `top_ks3.v` and `sram_ctl.v`):

| Pin | Width | Use |
|-----|-------|-----|
| ram_addr_o | 21 | Word address (physical byte address bits 21–1). Pin 20 is unused on 2 MB boards |
| ram_data_io | 16 | Data, both ways. Low byte D7–D0 = even byte address |
| ram_cs_n_o | 1 | Chip select, low during a cycle |
| ram_oe_n_o | 1 | Output enable, for reads |
| ram_we_n_o | 1 | Write enable |
| ram_lb_n_o, ram_ub_n_o | 1 each | Byte selects: low (even) and high (odd) byte |

Address, /CS, the byte selects and write data come from flip-flops in the I/O pads, so their timing is the same in every cycle. /OE, /WE and the data bus enable come from DDR output registers (ODDR), so they can change half a clock (5 ns) into a clock. Read data is captured by the flip-flops in the input pads.

### 8.2 One memory cycle

The SRAM is asynchronous: given an address it answers within 10 ns. A cycle issued at edge E is on the pins from E + 10 to E + 30 ns:

| | E + 10 ns | E + 15 ns | E + 25 ns | E + 30 ns |
|---|---|---|---|---|
| **Read** | Address, /CS, /UB and /LB out | /OE low | | Data captured; next cycle's address out |
| **Write** | Address, /CS, one or both byte selects out | Data driven; /WE low | /WE high | Data released (if a read follows); next cycle's address out |

- Any address, any mix of reads and writes, back to back: no rows, banks or bursts.
- **Read after write:** the FPGA stops driving at E + 30 (the read's pin start); /OE goes low 5 ns later.
- **Write after read:** /OE goes high at the write's pin start; the FPGA drives data 5 ns later.
- An idle cycle leaves /CS, /OE and /WE high and the data bus undriven.

### 8.3 Margins against the datasheet

The figures are the IS61WV204816BLL-10's, as used by retro68k's SRAM simulation model (`sim/sram_model.v`). Pad and board delays still have to come off the margins (open point M1).

| Parameter | Needs (10 ns part) | Here | Spare |
|-----------|--------------------|------|-------|
| Address to data, tAA | ≤ 10 ns | Address out at E + 10, captured at E + 30: 20 ns | 10 ns, for pad out, board and pad in |
| /OE to data, tDOE | ≤ 4.5 ns | /OE low at E + 15, captured at E + 30: 15 ns | 10.5 ns |
| Data hold after address change, tOHA | ≥ 2.5 ns (it helps) | Capture at the edge where the next address leaves | Hold met by the output delay plus tOHA |
| /WE pulse, tPWE | ≥ 8 ns | E + 15 to E + 25: 10 ns | 2 ns, less pulse-width distortion in the pads |
| Address set-up to /WE, tSA | ≥ 0 | 5 ns | 5 ns |
| Address valid to /WE high, tAW | ≥ 8 ns | 15 ns | 7 ns |
| Address hold after /WE, tHA | ≥ 0 | 5 ns | 5 ns |
| Data set-up to /WE high, tSD | ≥ 6 ns | Data from E + 15: 10 ns | 4 ns |
| Data hold after /WE high, tHD | ≥ 0 | 5 ns | 5 ns |
| /OE high to SRAM off the bus, tHZOE (write after read) | ≤ 4 ns | The FPGA drives 5 ns after /OE rises | **1 ns**: the tightest point |

The tight points are tHZOE (write after read) and tPWE. retro68k meets timing at 100 MHz with this controller, and its simulation runs with these checks on; the board margins are still open there too (its M2). Driving the data later in a write that follows a read would cut tSD below 6 ns, so if the turnaround is too tight on the board the fallback is decided with retro68k, which has the same controller (open point M1).

### 8.4 Byte and word access

- **Reads** always read the whole 16-bit word (/UB and /LB both low). Chipset units use both bytes; the CPU keeps the byte chosen by address bit 0.
- **Writes** come from the CPU and the DMA engine. A byte write drives the byte on both halves of the data bus and pulls only /LB (even address) or /UB (odd address) low, so the other byte is unchanged. A word write pulls both low.
- The memory is little-endian: the byte at an even address is the low half of its word.

## 9. The MMU

### 9.1 Windows

The Z80's 64 KB address space is cut into eight 8 KB windows. Address bits A15–A13 pick the window; A12–A0 are the offset within it. Each window has **two page registers**: a **read page** (opcode fetches and reads) and a **write page** (writes). Most of the time they are the same page; splitting them gives ROM shadowing, registers behind ROM, read-only windows and similar tricks (section 9.6).

The MMU registers are in the system page `0x00` (spec 3), registers `0x80`–`0x9F`. Each is reached at port (register × 256) + `0x00` with `OUT (C),r` (spec 1, section 6), or at register page offset `0x0080`–`0x009F`.

| Window | Z80 addresses | Read page (registers) | Write page (registers) |
|--------|---------------|-----------------------|------------------------|
| 0 | `0x0000`–`0x1FFF` | MMU0 (`0x80`, `0x81`) | MMU0W (`0x90`, `0x91`) |
| 1 | `0x2000`–`0x3FFF` | MMU1 (`0x82`, `0x83`) | MMU1W (`0x92`, `0x93`) |
| 2 | `0x4000`–`0x5FFF` | MMU2 (`0x84`, `0x85`) | MMU2W (`0x94`, `0x95`) |
| 3 | `0x6000`–`0x7FFF` | MMU3 (`0x86`, `0x87`) | MMU3W (`0x96`, `0x97`) |
| 4 | `0x8000`–`0x9FFF` | MMU4 (`0x88`, `0x89`) | MMU4W (`0x98`, `0x99`) |
| 5 | `0xA000`–`0xBFFF` | MMU5 (`0x8A`, `0x8B`) | MMU5W (`0x9A`, `0x9B`) |
| 6 | `0xC000`–`0xDFFF` | MMU6 (`0x8C`, `0x8D`) | MMU6W (`0x9C`, `0x9D`) |
| 7 | `0xE000`–`0xFFFF` | MMU7 (`0x8E`, `0x8F`) | MMU7W (`0x9E`, `0x9F`) |

The MMU registers are system registers, so the copper and the DMA engine cannot reach them: a runaway list or job cannot page memory.

### 9.2 Register format

Each page register is 2 bytes. Unlike the other registers, which are written directly (spec 3, rule 2), a page register **commits on its high byte**: this is one of spec 3's three exceptions (section 3.1).

| Register | Port | Name | Access | Bits | Meaning | Reset |
|----------|------|------|--------|------|---------|-------|
| `0x80` + 2n | `0x8000` + 0x200n | MMUn_0 | RW | 7–0 | Read page bits 7–0 (held until MMUn_1 is written) | Section 9.4 |
| `0x81` + 2n | `0x8100` + 0x200n | MMUn_1 | RW | 1–0 | Read page bits 9–8; writing commits the read page **and** the write page | Section 9.4 |
| | | | | 7–2 | Unused: read 0 | |
| `0x90` + 2n | `0x9000` + 0x200n | MMUnW_0 | RW | 7–0 | Write page bits 7–0 (held until MMUnW_1 is written) | Section 9.4 |
| `0x91` + 2n | `0x9100` + 0x200n | MMUnW_1 | RW | 1–0 | Write page bits 9–8; writing commits the write page only | Section 9.4 |
| | | | | 7–2 | Unused: read 0 | |

- **Write follows read.** Committing a read page (writing MMUn_1) sets the window's write page to the same page. Ordinary code changes a window with one register, as on any 8-bit MMU. Writing MMUnW_1 afterwards sets only the write page and splits the window. The write register's held byte 0 follows too, so writing MMUnW_1 alone afterwards uses the new page's bits 7–0.
- Writing byte 0 only holds it; writing byte 1 commits the page, so a window never points at a half-changed page, even while code runs from it. Write byte 0 first: `LD (nn),HL` or `OUT (C),r` with `INC B`, not `PUSH` or `LDDR`. Writing byte 1 alone commits it with the held byte 0, which is the page's current bits 7–0 if byte 0 has not been written since the last commit. Reading returns the committed value.
- The new mapping applies from the next memory access after the commit, including the next opcode fetch. Code can change the window it runs in, as long as the next instruction is at the same address in the new page.

Changing a window through ports (38 T-states):

```
        ld   bc,0x8600             ; MMU3_0: register 0x86 of page 0x00
        out  (c),l                 ; page bits 7-0: held
        inc  b                     ; MMU3_1
        out  (c),h                 ; page bits 9-8: commits read and write page
```

Through the register page, `LD (nn),HL` writes L then H, so one instruction (16 T-states) changes a window. Full I/O access stays alongside the register page, because the MMU must be reachable before any window shows the register page.

### 9.3 Pages

| Page | Meaning |
|------|---------|
| `0x000`–`0x0FF` | SRAM, physical `0x000000`–`0x1FFFFF` (every board) |
| `0x100`–`0x1FF` | SRAM, physical `0x200000`–`0x3FFFFF` (4 MB). On a 2 MB build these mirror pages `0x000`–`0x0FF` (section 11) |
| `0x200`–`0x3F7` | Reserved: reads give `0xFF`, writes are ignored |
| `0x3F8` | **REGS: the register page** (section 10) |
| `0x3F9`–`0x3FA` | Reserved |
| `0x3FB` | **NONE:** reads give `0xFF`, writes are ignored; kept unused for ever, so it is the way to make a window read-only |
| `0x3FC`–`0x3FF` | Boot ROM pages 0–3 (ROM offsets `0x0000`–`0x7FFF`) |

The physical byte address of a Z80 access to an SRAM page is page × `0x2000` + A12–A0, that is {page[8:0], A12–A0}.

- **Read-only windows:** set the write page to NONE. Reads are normal; writes use no SRAM cycle and give no error. This keeps a ROM image (a BASIC, or a Spectrum ROM for a port) in SRAM safe.
- **Boot ROM pages** ignore writes unless SYSCON.ROMWE is set (spec 7). They use no SRAM cycle: the block RAM answers in one clock, and the CPU's cycle goes to the free pool.
- **REGS, NONE and reserved pages** use no SRAM cycle either.
- The same page can be in several windows at once, and in a window's read and write page at once.

### 9.4 Reset state

| Window | Read page | Write page |
|--------|-----------|------------|
| 0 | `0x3FC` (boot ROM page 0) | `0x3FC` |
| 1 | `0x3FD` (boot ROM page 1) | `0x3FD` |
| 2–7 | `0x000`–`0x005` (SRAM pages 0–5) | The same |

So the Z80 starts at `0x0000` in the boot ROM, with 16 KB of ROM at the bottom and 48 KB of SRAM above it, like a Spectrum 48K. Every reset (spec 7) puts the MMU back to this state. The interrupt pages' reset state is in section 9.8: maskable interrupts switch nothing, and the NMI pages the monitor into window 0, as before.

### 9.5 NMI monitor paging (Spectrum extra)

The NMI monitor paging is now one case of the interrupt pages (section 9.7): the NMI set's reset state switches window 0 to the monitor page when an NMI is taken (read `0x3FF`; write `0x0FF`, the monitor's workspace page, spec 16, section 5.3), and puts the program's pages back at `RETN`. The old paging made window 0 read only (write NONE); writing to the workspace page lets the monitor page save registers without touching the program's memory. Its registers are NMICTL, NMIMASK, NMIP0–NMIP7, NMISAV0–NMISAV7 and the capture registers in I/O page `0x01` (section 9.8). The earlier NMISAV0, NMISAVW0 and NMISAVHI at registers `0x7D`–`0x7F` of page `0x00` are gone, and NMICTL has moved from `0x7C` of page `0x00` to `0x48` of page `0x01`, with the same bits; the stack capture it adds is always on and has no bit.

### 9.6 What split read and write pages are for

| Read page | Write page | Use |
|-----------|------------|-----|
| ROM | SRAM page | Shadow the ROM: `LDIR` the window onto itself, then map the SRAM page for reads too |
| ROM | REGS | Code and tables run from ROM while plain writes in the same window go to the registers |
| SRAM | NONE | A read-only window (ROM image kept in RAM) |
| SRAM page A | SRAM page B | Read one buffer while writing another at the same addresses (copy with a transform, or draw into a back buffer behind code) |
| REGS | REGS | All registers as memory |

### 9.7 Interrupt pages and stack capture (a retro-z80 extra)

retro68k has no MMU, so this has no counterpart there (design plan, branch 17). An interrupt or an NMI can switch chosen windows to pages of its own, so that a handler, its vector table, its stack and its data live in their own bank whatever the program has mapped. An NMI also keeps its return address in registers instead of pushing it (stack capture), so a bad SP corrupts nothing. Capture is always on for the NMI, and maskable interrupts have none: their return address goes through the switched map. The bus interface does the work, from the Z80's cycles as seen outside the core (spec 1, section 8). The registers are in I/O page `0x01` (section 9.8).

**Two sets.** Maskable interrupts (IM 1 and IM 2) and the NMI each have a set of the same registers. They work alike and apart.

| | Maskable interrupts | NMI |
|---|---------------------|-----|
| Control | IPCTL: EN | NMICTL: EN, INNMI |
| Windows switched | IPMASK, one bit per window | NMIMASK |
| Interrupt pages | IP0–IP7 (read), IP0W–IP7W (write) | NMIP0–NMIP7, NMIP0W–NMIP7W |
| Saved pages | IPSAV0–IPSAV7, IPSAV0W–IPSAV7W | NMISAV0–NMISAV7, NMISAV0W–NMISAV7W |
| Depth | IPDEPTH, 0–255 | INNMI, 0 or 1: an NMI never nests (spec 8, section 10) |
| Return | `RETI`; or IPRESTORE: a `RET` armed by its RET bit, or at once by its NOW bit | `RETN` |
| Stack capture | None: the pushes and pops go through the switched map | Always: NMICAPPC (the PC), NMICAPSP (the SP) |
| After reset | Off | Window 0 reads the monitor page and writes the monitor's workspace page |

**A response** is what the Z80 does to take an interrupt: the acknowledge (IM 1 or IM 2) or the NMI's response cycle, then **two writes that push PC**, then the first read or fetch of the handler: the IM 2 vector table, or the fetch at `0x0038` (IM 1) or `0x0066` (NMI). The bus interface knows each of these cycles by its order (spec 1, section 8.3). The windows switch at the acknowledge, **before the pushes**, and switch back **after the return's two stack reads**, so the pushes and the pops go through the same map.

**Entry.** On the **outermost** response of a set (maskable: IPDEPTH = 0 and EN = 1; NMI: INNMI = 0, whatever EN holds):

1. The set notes its mask and EN as they are now. Changes to them inside the handler act at the next entry, not at this one's return.
2. The depth becomes 1 (INNMI = 1).
3. **With EN:** in the acknowledge (or the NMI's response cycle), before the first push, the hardware copies all 16 page registers (MMU0–MMU7, MMU0W–MMU7W) into the set's saved pages, and loads each window in the mask with its interrupt read page and write page (section 9.9). Everything after that uses the new pages: the pushes, the IM 2 table read (or the fetch at `0x0038` or `0x0066`) and the handler. Windows outside the mask keep their pages.
4. **NMI: stack capture.** The two pushes do not reach memory. Their bytes go into NMICAPPC (high byte first, as the Z80 pushes) and the SP the program had goes into NMICAPSP. No memory cycle, ROM write or register strobe is made, so memory at the stack is not changed, wherever SP points and whatever is mapped there. The Z80 still steps SP down by 2. **Maskable:** the pushes are ordinary writes through the switched map: into the interrupt page if SP lies in a switched window, otherwise onto the program's stack as on a plain Z80.

With IPCTL.EN = 0, a maskable response changes nothing, and the depth stays 0. An NMI with NMICTL.EN = 0 still captures and sets INNMI, and switches no window. On a **nested** response (maskable: IPDEPTH ≥ 1), the depth counts up (it stays at 255 if it is there), the pushes go to memory as normal, and no window changes. The NMI cannot nest: while INNMI is 1 the controller holds /NMI high (spec 8, section 10).

**Return.** The instruction that ends the outermost handler of a set is:

- maskable: `RETI` (`ED 4D`) when IPDEPTH is 1, or the first `RET` (`C9`) after a write of IPRESTORE.RET while IPDEPTH is 1;
- NMI: `RETN` (`ED 45`) while INNMI is 1.

The bus interface knows it as the core takes that instruction's last opcode byte (spec 1, section 8.4). Then:

1. **The two stack reads.** For `RETN`, they come from NMICAPPC (low byte, then high), not from memory; SP still steps up by 2, so it is back at the program's value. For a maskable return they are ordinary reads through the map the handler leaves, the switched one, so they find the return address where the pushes put it.
2. **After the second stack read, before the fetch at the return address,** with EN at the entry: each window in the noted mask gets its saved read and write pages back. Other windows keep what they hold.
3. The depth becomes 0 (INNMI = 0) at the second stack read.

So the pushes and the stack reads use the same switched map, and the fetch at the return address uses the program's own map. A `RETI` or armed `RET` at IPDEPTH ≥ 2 counts down and pops from memory as normal. `RETI` at depth 0, `RETN` with INNMI = 0, and every other `ED` instruction change nothing; `RETN` does not count IPDEPTH, and `RETI` does not end the NMI.

**IPRESTORE** is for maskable handlers that do not end with `RETI`. Writing it does nothing while IPDEPTH is 0.

| Bit | Name | Effect |
|-----|------|--------|
| 0 | RET | Arms the return: the next `RET` (`C9`, with or without `DD` or `FD` before it) or `RETI` fetched counts down as `RETI` does. When it takes the depth to 0, the pages are restored after its stack reads. Conditional returns do not count. For handlers that end `EI` then `RET`: write it with interrupts off, just before `EI` |
| 1 | NOW | Counts down at once. When the depth reaches 0 the pages are restored at once, in the clocks after the write: the handler then leaves by its own jump, having taken the return address off the stack before the write. The next instruction is fetched through the restored map, so the code that writes NOW must sit in a window outside the mask, or at the same address in both pages |

Writing **IPDEPTH** sets the depth and changes no window: writing 0 abandons the saved pages, for a handler that never returns (a restart, or BASIC's Escape).

**What a handler sees:**

- MMUn reads the interrupt page of a switched window. A write to MMUn of a switched window lasts until the return, which puts the saved page back; to change what the program gets back, write IPSAVn. A write to IPn changes only the next entry.
- **Stack, maskable:** the return address is pushed through the switched map. With SP in a window outside the mask it is on the program's stack, as on a plain Z80. With SP in a switched window it goes into the interrupt page at the program's SP, and so do the handler's own `PUSH`es: that window's interrupt read and write pages must then be the same RAM page, or the return address is lost (written to one page and popped from another). Or the handler loads its own SP, and puts it back before the return.
- **The pops** of a maskable return use the map the handler leaves. A maskable handler that changes MMUn of the window holding SP must put it back before the return.
- **Stack, NMI:** memory at SP is not changed. In the handler, (SP) and (SP + 1) hold whatever was there before, not the return address, which is in NMICAPPC. Code that reads or changes its return address on the stack (`EX (SP),HL`, `POP` then `JP`) must use NMICAPPC instead. Before `RETN`, SP must be back at its value at entry (NMICAPSP − 2).
- The IM 2 table is read through the switched map: when its window is in the mask, the table must be in the interrupt page.
- A nested interrupt pushes onto the handler's own stack, and its `RETI` pops from there.
- `DI`, `EI`, `HALT` and `IM` change nothing in either set. A `HALT` in a handler waits for the next interrupt, which nests.
- An NMI inside a maskable handler, or the reverse, uses its own set on top: the inner one saves the pages it finds (the outer handler's) and its return puts them back, then the outer return puts the program's back. This holds as long as the returns come in reverse order.
- The copper, the DMA engine and the sprite sequencer use physical addresses (section 11), so the switch does not affect them; page `0x01` is outside their reach (spec 3). A window can switch to any page, the register page and the boot ROM included.
- A posted write goes to the page mapped in its own T1 (spec 1, section 5.2), so the handler's last write before `RETI` goes to the interrupt page.

**The NMI's defaults** are the old NMI monitor paging, with one change: NMIMASK = `0x01`, NMIP0 = `0x3FF` (boot ROM page 3, the monitor page), NMIP0W = `0x0FF` (the monitor's workspace page, spec 16, section 5.3; the old paging had NONE), EN on. So an NMI fetches `0x0066` from the monitor page, the program's PC and SP are in NMICAPPC and NMICAPSP, and `RETN` puts window 0 back and returns. Writes to window 0 go to the workspace page, so the monitor page saves registers and sets up a stack there before it maps anything else: with the capture, an NMI writes nothing in the program's memory. Spec 7, section 10.1 and spec 16, section 8.6 use this.

**With the boot ROM** (spec 16, section 6.1): while a program keeps the ROM in window 0 and makes ROM calls from its handlers, it leaves window 0 out of IPMASK, and its IM 2 table can be in a switched window (in the interrupt page) or in an unswitched one. A program that switches window 0 to its own page gets a `0x0038` of its own, so IM 1 works with the ROM in window 0 for the program, but its handlers then make no ROM calls.

A handler with its own bank in window 6, for every maskable interrupt:

```
        ld   bc,IP6_P              ; port 0x8C01: IP6_0, register 0x8C of page 0x01
        ld   hl,0x040              ; SRAM page 0x040
        out  (c),l                 ; bits 7-0: held
        inc  b                     ; IP6_1
        out  (c),h                 ; commits IP6 and IP6W
        ld   bc,IPMASK_P
        ld   a,0x40                ; window 6 (0xC000-0xDFFF)
        out  (c),a
        ld   bc,IPCTL_P
        ld   a,IPCTL_EN_M          ; switch: SP stays outside window 6
        out  (c),a
        ...
; the handler, its table and its data in page 0x040 at 0xC000-0xDFFF
        ei
        reti                       ; window 6 back to the program's page
```

### 9.8 Interrupt page registers

Registers `0x40`–`0xFF` of I/O page `0x01` (spec 3, section 4.13): port = register × 256 + `0x01`, and register page offset `0x0100` + register (section 10). Registers `0x00`–`0x3F` of page `0x01` are reserved through I/O; their register page offsets hold KEYROW0–7 (memory only) and free space. Like the MMU, these are system registers: the copper and the DMA engine cannot reach them.

The page registers sit at the MMU's own register numbers, in another page: IPn is at `0x80` + 2n of page `0x01` as MMUn is at `0x80` + 2n of page `0x00`.

| Register | Port | Name | Access | Bits | Reset | Meaning |
|----------|------|------|--------|------|-------|---------|
| `0x40` | `0x4001` | IPCTL | RW | EN (0) | `0x00` | Maskable interrupts. EN: switch the windows in IPMASK. Looked at on the outermost entry only. Bits 7–1 read 0 |
| `0x41` | `0x4101` | IPMASK | RW | WIN (7–0) | `0x00` | Bit n = window n switches |
| `0x42` | `0x4201` | IPDEPTH | RW | DEPTH (7–0) | `0x00` | Maskable responses not yet returned from: 0 = none. Stays at 255 if it is there. Writing sets it and changes no window |
| `0x43` | `0x4301` | IPRESTORE | W (S) | RET (0), NOW (1) | – | RET: the next `RET` or `RETI` returns. NOW: count down now. Ignored at depth 0. Reads `0x00` |
| `0x44`–`0x47` | | – | | | | Reserved |
| `0x48` | `0x4801` | NMICTL | RW | EN (0), INNMI (1) | `0x01` | The NMI. EN: switch the windows in NMIMASK. INNMI: read only, 1 from an NMI's entry to its `RETN`. Stack capture is always on and has no bit. Bits 7–2 read 0 |
| `0x49` | `0x4901` | NMIMASK | RW | WIN (7–0) | `0x01` | Bit n = window n switches on an NMI |
| `0x4A`–`0x4B` | | – | | | | Reserved |
| `0x4C`–`0x4D` | `0x4C01`–`0x4D01` | NMICAPPC (NMICAPPC0, NMICAPPC1) | RW | 15–0 | `0x0000` | The return address captured at the NMI's entry; `RETN` takes it. Writable, to return somewhere else |
| `0x4E`–`0x4F` | `0x4E01`–`0x4F01` | NMICAPSP (NMICAPSP0, NMICAPSP1) | R | 15–0 | `0x0000` | The program's SP at that entry (the pushes would have gone to NMICAPSP − 1 and NMICAPSP − 2) |
| `0x50`–`0x7F` | | – | | | | Free |
| `0x80` + 2n | `0x8001` + 0x200n | IPn (IPn_0, IPn_1) | RW | 9–0 | MMUn's reset page | Window n's interrupt read page. Commits on byte 1, which also sets IPnW (section 9.2) |
| `0x90` + 2n | `0x9001` + 0x200n | IPnW (IPnW_0, IPnW_1) | RW | 9–0 | The same | Window n's interrupt write page |
| `0xA0` + 2n | `0xA001` + 0x200n | IPSAVn (IPSAVn_0, IPSAVn_1) | RW | 9–0 | The same | Window n's read page at the last switch, put back at the return if window n was in the mask |
| `0xB0` + 2n | `0xB001` + 0x200n | IPSAVnW (IPSAVnW_0, IPSAVnW_1) | RW | 9–0 | The same | Window n's write page at the last switch |
| `0xC0` + 2n | `0xC001` + 0x200n | NMIPn (NMIPn_0, NMIPn_1) | RW | 9–0 | Window 0: `0x3FF`; others as MMUn | Window n's NMI read page |
| `0xD0` + 2n | `0xD001` + 0x200n | NMIPnW (NMIPnW_0, NMIPnW_1) | RW | 9–0 | Window 0: `0x0FF` (the monitor's workspace page); others as MMUn | Window n's NMI write page |
| `0xE0` + 2n | `0xE001` + 0x200n | NMISAVn (NMISAVn_0, NMISAVn_1) | RW | 9–0 | MMUn's reset page | Window n's read page at the last NMI entry |
| `0xF0` + 2n | `0xF001` + 0x200n | NMISAVnW (NMISAVnW_0, NMISAVnW_1) | RW | 9–0 | The same | Window n's write page at the last NMI entry |

n = 0–7. MMUn's reset page is `0x3FC`, `0x3FD`, then `0x000`–`0x005` (section 9.4), so a switch with untouched interrupt pages changes nothing.

- **Page registers** (IPn, IPnW, IPSAVn, IPSAVnW and the NMI's) follow the MMU's rule, one of spec 3's exceptions (section 3.1): byte 0 is held, byte 1 commits with the held byte (or the current bits 7–0 if byte 0 has not been written since), and committing a read page also sets the write page of the same kind. Reading gives the committed value. Each register has a held byte of its own. A page register never holds half a page, even if an entry or a return comes between the two bytes. They are kept in distributed RAM, not flip-flops (section 9.9); that changes nothing a program sees.
- **Saved pages are writable,** so a handler can change what the program gets back at the return: the monitor's `G`, or a task switcher that gives each task its own map. The entry overwrites all 16 of a set's saved pages.
- **NMICAPPC and NMICAPSP** are plain registers, written directly (spec 3, rule 2). They change only at an NMI's entry, which cannot come while INNMI is 1, so they need no capture of their own. NMICAPSP is read only.
- **Reset** (spec 7) clears IPDEPTH, INNMI, the RET arm and the noted masks, and sets every register to its reset value above (the page registers while reset is held, section 9.9).
- The bus interface also keeps, for each set, the noted mask and EN, and (maskable only) the RET arm. They cannot be read.

### 9.9 How the sets are kept

The two sets' page registers are not flip-flops. Each set keeps them in **distributed RAM** (LUTs used as small RAMs), and the hardware copies them into the MMU **one window per clock** (design plan, branch 17). The MMU's own 16 page registers stay flip-flops, since every access looks them up.

| RAM (each set) | Size | Contents |
|----------------|------|----------|
| Pages | 8 words × 20 bits | Word n: window n's interrupt read and write page (IPn and IPnW, or NMIPn and NMIPnW) |
| Saved pages | 8 words × 20 bits | Word n: window n's saved read and write page (IPSAVn and IPSAVnW, or NMISAVn and NMISAVnW) |
| Held bytes | 16 words × 18 bits | The held byte 0 of each of the 32 page registers, each with a flag that it has been written since its last commit |

- **The switch** takes 8 clocks. In clock k the copy writes window k's two MMU page registers into word k of the saved pages and, if window k is in the mask, loads them from word k of the pages. So all 16 page registers are saved (open point M12) and the masked windows are loaded.
- **The restore** takes 8 clocks too: in clock k, if window k is in the noted mask, it loads window k from word k of the saved pages.
- **Timing.** The switch starts in the clock after the response is seen, in the response M1, and is done more than 20 clocks before the first push's T1 at 20 MHz. The restore starts at the second stack read's T2 and is done 3 clocks before the T1 of the fetch at the return address at 20 MHz, the tightest point. So all eight windows fit, at every speed (spec 1, section 8.5), and no set needs fewer windows.
- **One copy at a time.** One copy engine (a 3-bit count) serves both sets. Two copies never overlap, and the CPU never writes the MMU or page `0x01` during one: the CPU is in the response M1, in a stack read, or just past the IPRESTORE write, and its next register access is at least one M-cycle later (spec 1, section 8.5). The copper and the DMA engine cannot reach either. So each RAM needs only one port.
- **CPU access.** A read of a page register reads its word and picks the byte. A byte 0 write writes only the held bytes. A byte 1 write commits: it reads the word, puts in the new page (bits 7–0 from the held byte if its flag is set, otherwise the current ones), writes the word back in the same clock and clears the flag. A read page commit writes both halves of the word and clears both flags, which is the rule that the write page follows.
- **Reset.** A RAM cannot be cleared at once, so while reset is held the copy engine writes the reset values of section 9.8 into the pages and saved pages and clears the held flags, one word per clock (16 clocks; reset is held far longer, spec 7).

## 10. The register page

### 10.1 Layout

Page `0x3F8` shows the machine's registers as memory, in any window, so the Z80 can use LD, LDI, read-modify-write instructions (`SET`, `INC (HL)`, `INC (IX+d)`) and 16-bit loads on them. Register r of I/O page p is at offset **p × 256 + r**: the port number with its two bytes swapped. The registers are the same ones as through I/O ports (spec 3); both ways always work.

| Offset | I/O page | Contents |
|--------|----------|----------|
| `0x0000`–`0x00FF` | `0x00` | The **system block**: register r at offset r (spec 3). Includes the low-byte-only registers (Kempston `0x1F`, SERDATA `0x53`, SDDATA `0x5B`, KBDATA `0x62`, port `0xFE` at `0xFE`) |
| `0x0100`–`0x0107` | – | **KEYROW0–7**: the membrane keyboard's rows one by one, in port `0xFE`'s read format; read only. Memory only (a Spectrum extra, spec 12) |
| `0x0108`–`0x013F` | – | Reserved |
| `0x0140`–`0x01FF` | `0x01` | The **interrupt pages**: register r of I/O page `0x01` at `0x0100` + r (section 9.8) |
| `0x0200`–`0x0FFF` | – | Reserved |
| `0x1000`–`0x13FF` | `0x10`–`0x13` | The **custom block**: custom offset k at `0x1000` + k (spec 3) |
| `0x1400`–`0x1FFF` | – | The **palettes**, memory only (section 10.2) |

Reserved offsets read `0xFF` and ignore writes. The page is 8 KB, so in a window at `0xA000`, say, the custom block starts at `0xB000`, and custom register k is at `0xB000` + k.

**KEYROW** sits at `0x0100` because a memory read has no A15–A8 to pick keyboard rows, and page `0x00`'s registers `0x17`–`0x1E` stay free. Through I/O, port `0xFE` with A15–A8 gives the rows (spec 12); registers `0x00`–`0x3F` of I/O page `0x01` are reserved and read `0xFF`, so KEYROW has no port. Registers `0x40`–`0xFF` of page `0x01` are the interrupt pages (section 9.8).

### 10.2 The palettes

Four palettes of 256 entries, each entry 3 bytes (blue, green, red; spec 4), need 3 KB. They fill the top 3 KB of the page, packed:

| Offset | Palette |
|--------|---------|
| `0x1400`–`0x16FF` | PALETTE0 (layer L0) |
| `0x1700`–`0x19FF` | PALETTE1 (layer L1) |
| `0x1A00`–`0x1CFF` | PALETTE2 (layer L2) |
| `0x1D00`–`0x1FFF` | SPRPALETTE |

Entry i of a palette starting at base B is at B + 3i: blue at B + 3i, green at B + 3i + 1, red at B + 3i + 2. The blue and green bytes are held in the CPU's colour assembly buffer; the **red byte commits** the entry (spec 4), as through PALDAT. This is one of spec 3's three exceptions to direct writes (section 3.1). So a rising `LDIR` of 768 bytes copies a whole palette, and the byte stream is the same as PALDAT's (spec 4), so one table serves `OTIR` through PALDAT and `LDIR` through the page. This path does not use or change PALIDX.

retro68k's 4-byte entries (`0x00RRGGBB`) would need 4 KB, which does not fit beside the custom block in an 8 KB page. The palettes have no I/O page of their own (I/O pages `0x14`–`0x1F` are reserved); through I/O they are reached by PALIDX and PALDAT (spec 4).

### 10.3 Rules

- **No SRAM cycle:** register page accesses go to the register bus (spec 1, section 4.2), as I/O accesses do, and the CPU's memory cycle goes to the free pool. On that bus the copper goes first, then the CPU, then the DMA engine (spec 3, section 3.2).
- **Side effects are the same as for I/O:** reading a FIFO data register (SERDATA, KBDATA, SDDATA) through the register page takes a byte. The bus interface sends the strobe only for a real read or write (spec 1, section 5.7).
- **Opcode fetches** from the register page read `0xFF` (`RST 38h`) and have no side effect.
- **Write order:** registers are written directly (spec 3, rule 2), so any instruction works on them, in any order: `LD (nn),HL`, `LDI`, `LDIR`, `PUSH`, `LDDR`. Two exceptions need the low byte first: the MMU page registers and the interrupt pages (byte 1 commits, sections 9.2 and 9.8) and the colours (the red byte commits, section 10.2). Use `LD (nn),HL`, `LD (nn),DE`, `LDI` or `LDIR` for them, not `PUSH` or `LDDR`.
- A read uses its window's read page and a write its write page, so in a window that reads ROM and writes REGS, `LD (HL),A` writes a register and `LD A,(HL)` reads the ROM.

## 11. Physical addresses

The display, sprites, copper and DMA engine address the SRAM with 22-bit physical byte addresses, without the MMU. Their pointer registers are 3 bytes (spec 3); bits 23–22 are ignored.

| Physical address | 4 MB build | 2 MB build |
|------------------|------------|------------|
| `0x000000`–`0x1FFFFF` | SRAM pages `0x000`–`0x0FF` | SRAM, all of it |
| `0x200000`–`0x3FFFFF` | SRAM pages `0x100`–`0x1FF` | Mirror of `0x000000`–`0x1FFFFF` (bit 21 ignored) |

- Any unit can use any part of the SRAM: screens, tiles, sprite images, copper lists and DMA descriptors can be anywhere.
- The SRAM page holding an address is address ÷ `0x2000`, so a program finds the physical address of anything it has mapped from the MMU register.
- **2 MB and 4 MB:** the design is the same for both. **SYSCFG.CHIPMB is a build constant** (spec 7): 4, or 2 for a build made for a 2 MB board. It is not measured. A 1M × 16 SRAM has no A20, so on a 2 MB board the top half mirrors the bottom whatever the build says; software uses CHIPMB and must not use pages `0x100`–`0x1FF` when it reads 2.

## 12. Who uses which cycle

| Unit | Cycles | What for |
|------|--------|----------|
| CPU (spec 1) | 0 and 2 (at most one per slot) | Opcode fetches, reads, writes. Never waits |
| Layers and attribute layer (spec 4) | 1 and 3; any cycle when urgent, except one the CPU asked for; free pool first | Just-in-time fetch into each layer's data registers |
| Sprites (spec 5) | As the layers, earliest deadline first among them | The 8 sprite FIFOs |
| Audio (spec 13) | 4 (reserved) | Parked |
| Copper (spec 6) | Free pool, after the hard-deadline channels and audio | Its instruction words |
| DMA engine (spec 14) | Free pool, after the copper | Its jobs' SRAM reads and writes, and descriptors |

## 13. FPGA resources

| Item | Resource |
|------|----------|
| Scheduler and SRAM controller (`dmac.v`, `sram_ctl.v`, from retro68k without HIGH) | Estimate 150–250 LUTs |
| MMU: 16 × 10-bit page registers, held low bytes, page decode | Estimate 100–150 LUTs |
| Interrupt pages and stack capture: both sets' pages, saved pages and held bytes in distributed RAM (2 × (8 × 20 + 8 × 20 + 16 × 18) bits, section 9.9), the copy engine, one more load path into the MMU (a 20-bit bus into all 16 page registers) and the save path out of it, two masks and their noted copies, the depth, the NMI's two capture registers, the read-back of page `0x01` | Estimate 190–330 LUTs, of which about 60 are distributed RAM, and about 100 flip-flops (open point M10) |
| Boot ROM | 16 block RAMs (spec 7) |

## 14. Test plan

- **Cycle table:** each owner gets its cycles at the same `hslot` and slot edge on every line; the slot counter restarts each line; unused cycles go to the free pool in the order of section 5.2.
- **CPU never loses a cycle:** with every layer, sprite, the copper and the DMA engine busy, and layers set to make urgent fetches, every CPU request is issued in the cycle it asked for; checked at every CPUSPEED setting, including 3.57 MHz.
- **Urgent fetches:** an urgent fetch takes a cycle 0 or 2 the CPU did not ask for and cycle 4; when the CPU has the cycle, the fetch is issued in the next cycle; no layer goes late on a screen within the budget, with the CPU running at 20 MHz.
- **Free pool:** the copper and the DMA engine get cycle 4 and every unused CPU and display cycle; with everything else busy the DMA engine may get only cycle 4s the copper leaves, and nothing else is slowed.
- **DMACON:** each user turned off asks for no cycles, and its cycles go to the others; DMAEN off turns all of them off; the CPU is not affected.
- **SRAM model:** run the controller against retro68k's SRAM simulation model with the datasheet checks on (set-up, hold, pulse widths, bus turnaround), at 20 ns cycles, with every mix of reads and writes back to back.
- **Byte writes:** writing an even or odd byte changes only that byte, from the CPU and from the DMA engine; chipset word reads see even bytes in the low half.
- **MMU:** reset state; a byte 0 write alone changes nothing; the byte 1 write commits both; byte 1 written alone keeps bits 7–0; a write to another register between the two bytes changes nothing; read back; committing a read page also sets the write page; a later write-page commit splits the window, and reads and writes then go to their own pages; NONE ignores writes; ROM pages ignore writes unless ROMWE; reserved pages read `0xFF`; pages `0x100`–`0x1FF` mirror on a 2 MB build; ports `0x8000`–`0x9F00` and register page offsets `0x0080`–`0x009F` reach the same registers; `IN A,(0x00)` with A = `0x80` reads MMU0_0.
- **Register page:** every page `0x00` register answers at its offset with the same value and side effects as through I/O; every custom register answers at `0x1000` + its offset as at its port; KEYROW0–7 at `0x0100`–`0x0107` match port `0xFE`; palette entries at `0x1400` + 0x300p + 3i commit on the red byte, and an `LDIR` of 768 bytes copies a palette without touching PALIDX; reserved offsets read `0xFF`; opcode fetches read `0xFF` with no side effect; `LD (nn),HL` writes a 2-byte register in one instruction; `PUSH` writes a 2-byte custom register correctly; no SRAM cycle is used.
- **Interrupt pages, maskable:** with each IPMASK pattern (none, one window, all eight, the window holding SP, the window holding the IM 2 table, window 0), in IM 2 and IM 1, at 20 MHz, 3.57 MHz and n = 8: the two pushes go through the switched map (into the interrupt page with SP in a switched window, onto the program's stack otherwise); the table read (or the fetch at `0x0038`) and the handler come from the interrupt pages; IPSAV0–7 and IPSAV0W–7W hold the old pages; MMUn reads the interrupt pages; windows outside the mask are unchanged; `RETI` pops through the switched map and restores after its second stack read, before the fetch at the return address (SP in a switched window and elsewhere); a switched window holding SP with different read and write pages loses the return address, as section 9.7 warns; `DD ED 4D` counts, `ED 45`, `ED 5D`, `CB ED` followed by `4D`, and `DD CB d ED` followed by `4D` behave as spec 1, section 8.4 says.
- **Nesting:** with `EI` in the handler, a second interrupt counts IPDEPTH to 2 and switches nothing; its `RETI` counts to 1 and pops from memory; the outer `RETI` restores; IPDEPTH stays at 255 when pushed past it; writing IPDEPTH changes no window.
- **IPRESTORE:** RET then `EI`, `RET` restores after the `RET`'s stack reads, which come from memory through the switched map; a conditional return does not count; NOW restores at once (through a port and through the register page); both do nothing at depth 0.
- **The copy (section 9.9):** a switch and a restore each take 8 clocks, one window per clock; the switch is done before the first push's T1 and the restore before the return fetch's T1, at every speed, with the spare of spec 1, section 8.5; no CPU write to the MMU or page `0x01` falls inside a copy; reset writes the reset values into the RAMs and the held flags.
- **Stack capture (NMI only):** an NMI's two pushes make no SRAM request, no ROM write and no register strobe, and memory at SP − 1 and SP − 2 is unchanged (SP in SRAM, ROM, NONE and the register page); NMICAPPC and NMICAPSP hold the PC and SP; the handler reads the old memory at (SP); `RETN` takes its two reads from NMICAPPC with no memory request, and SP is back at the program's value; a written NMICAPPC returns there; a maskable interrupt inside the NMI handler pushes to memory; capture with NMICTL.EN on and off; a maskable response never captures, at any depth and with IPCTL.EN on or off; NMICTL bits 7–2 and IPCTL bits 7–1 read 0 whatever is written.
- **NMI set:** the defaults give the old NMI paging (spec 7, section 13), now with capture and with window 0's writes going to page `0x0FF`; an NMI and the monitor page's entry change no byte outside page `0x0FF`; NMIMASK patterns as above; an NMI inside a maskable handler and an interrupt inside an NMI handler each restore in reverse order; with EN 0 an NMI switches no window but still captures, and INNMI is 1 until its `RETN`.
- **Interrupt page registers:** every register of page `0x01` at port r × 256 + `0x01` and at register page offset `0x0100` + r; registers `0x00`–`0x3F` and reserved `0x44`–`0x47` and `0x4A`–`0x4B` read `0xFF` through I/O; the page registers commit on byte 1 and a read page commit sets its write page; each keeps its own held byte (byte 0 of IP0, byte 0 and 1 of IP1, then byte 1 of IP0 commits with IP0's held byte); an entry between the two bytes of IPn uses the old IPn; reset values.
- **Physical addresses:** a pattern written by the CPU through every page is read by the DMA port at page × `0x2000` + offset; bits 23–22 of pointers are ignored.
- **Board test:** a full RAM test from the CPU at 20 MHz and from the DMA engine at once, with the display, sprites and copper busy.

## 15. Open points

| # | Item |
|---|------|
| M1 | Check the 20 ns read and write cycles against the IS61WV204816BLL-10 datasheet with the KS3's pad and board delays (section 8.3), as retro68k's M2. The tight points are tHZOE on a write after a read (1 ns on paper) and tPWE (2 ns). Driving the data later cuts tSD below its 6 ns; a possible fallback is to give a write that follows a read a free cycle before it (the scheduler can do this by not issuing a write straight after a read). To be decided with retro68k, which has the same controller |
| M2 | Is the KS3 fitted with 4 MB or 2 MB? Shared with retro68k (its M3). Closed for the design: CHIPMB is a build constant (section 11); both builds are tested |
| M3 | Closed: a faster paging port is deferred (design plan, branch 11). A window changes with two `OUT (C)` (38 T-states with `LD BC`) or one `LD (nn),HL` through the register page (16 T-states) |
| M4 | Closed: the 28 MHz swap is gone. At 20 MHz and below every CPU access has a CPU cycle in time (spec 1, section 5). It would come back only for 25 MHz (spec 1, B10) |
| M5 | Spec 4 must set the urgent mark one memory cycle (2 clocks) earlier than retro68k's (`bpldma.v`: 14 + 5 × words left), to cover a fetch that finds the CPU in its cycle (section 5.3). To be checked in simulation with the CPU making an access every 3 T-states |
| M6 | Closed: the register page read fits easily at 20 MHz (spec 1, section 5.7) |
| M7 | Audio (spec 13, parked) has cycle 4 kept for it, as retro68k gives audio a cycle of its own (there cycle 2) |
| M8 | Closed: palettes packed at `0x1400`–`0x1FFF` (section 10.2); KEYROW0–7 at `0x0100`–`0x0107`. `0x0108`–`0x0FFF` is free for later tables |
| M9 | A descriptor RAM for the DMA engine (spec 14), if block RAM allows, would need a place in the register page; `0x0200`–`0x0FFF` is free for it |
| M10 | Decided (design plan, branch 17): the sets are kept in distributed RAM and copied into the MMU one window per clock (section 9.9), which brings the estimate down from 500–800 LUTs and about 1,300 flip-flops to 190–330 LUTs and about 100 flip-flops (section 13; the maskable set has no capture registers). All eight windows fit in time at every speed: at 20 MHz the restore, the tightest point, has 3 clocks to spare (spec 1, section 8.5), so no set has fewer windows. At 25 MHz (spec 1, B10 and B13) eight windows still fit, with 1 clock to spare. If a later change ever leaves too little room, the copy can skip the windows outside the mask (a restore then takes one clock per masked window) before any set loses windows. To be measured; on the KS2 (design plan, branch 12) the interrupt pages may still be a build option |
| M11 | IPDEPTH stays at 255 when pushed past it, with no flag, so a runaway nest restores early. A sticky overflow bit could be added if it is ever needed |
| M12 | Saved pages are a snapshot of all 16 page registers at the switch, but only the windows in the mask are put back. Proposed: as written (the monitor reads the program's whole map from one place) |
