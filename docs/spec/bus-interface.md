# Spec 1: CPU bus interface

Status: **draft**

This spec connects the Z80 to everything else. It covers how the tv80 core is clocked and how its speed is set, how its opcode fetch, memory and I/O cycles become requests on the internal chipset buses, how each memory access is fitted into the CPU's memory cycles so that the Z80 never waits, how I/O ports are decoded, and how interrupts, NMI, reset and HALT work.

It follows retro68k's spec 1, with tv80 in place of fx68k. The memory side (the 100 MHz clock, slots, the scheduler, the SRAM controller, the MMU, the register page) is spec 2. The registers are listed in spec 3.

## 1. Summary

| Item | Value |
|------|-------|
| CPU | tv80 (Verilog Z80) inside the Artix-7 FPGA, Mode 0 (Z80), with its refresh option on |
| Clock | The 100 MHz system clock, with one clock enable (cen): a T-state per cen pulse |
| CPU speed | A T-state every 5 × n clocks, n = 1–8: 20, 10, 6.67, 5, 4, 3.33, 2.86 or 2.5 MHz, locked to the slots; or every 28 clocks, 3.57 MHz (Spectrum timing), not locked. 20 MHz after reset. Set by CPUSPEED (spec 7) |
| Slots | At 20 MHz a slot (100 ns) is exactly 2 T-states; T-states start on slot edges 0 and 5 at every locked speed |
| Memory | Every opcode fetch, read and write goes through the MMU (spec 2): reads to the window's read page, writes to its write page. An SRAM access uses one CPU memory cycle (cycle 0 or 2); boot ROM and register page accesses use none |
| Wait states | None, ever. wait_n is tied high. Every access has a CPU cycle in time at every speed (section 5) |
| I/O | Port = register (A15–A8) : page (A7–A0). Page `0x00` the system block, registers `0x40`–`0xFF` of page `0x01` the interrupt pages, pages `0x10`–`0x13` the custom block. Low-byte-only ports `0x1F`, `0x53`, `0x5B`, `0x62`, `0xFE`. Others read `0xFF` (section 6) |
| Register bus | 8-bit, one clock per access; masters the copper (first), the CPU, the sprite sequencer, the DMA engine (last) (section 4.2) |
| Refresh | The core's refresh cycles (T3–T4 of every M1) are ignored. The R register still counts |
| Interrupts | IM 2: the interrupt controller (spec 8) puts VECBASE + 2 × source on the bus in the acknowledge cycle. IM 1: the handler reads INTID. No IM 0 |
| Interrupt pages, stack capture | A retro-z80 extra: an interrupt or NMI can switch chosen windows (at the acknowledge, before its two pushes), and an NMI always keeps its pushed PC in registers instead of memory; `RETN` takes its stack reads from the capture and `RETI` through the same switched map, then each puts the program's windows back before the fetch at the return address (sections 8.3–8.6) |
| NMI paging | Spectrum extra, now the NMI set's default: window 0 to the boot ROM's monitor page, PC captured; `RETN` puts them back (section 8.2) |
| Not used | busrq_n (tied high), busak_n, halt_n, IM 0 |

### 1.1 Comparison with retro68k

| retro68k (spec 1) | retro-z80 | Why |
|-------------------|-----------|-----|
| fx68k on its own 40 MHz clock with two phase enables (enPhi1, enPhi2), a 20 MHz 68000 | tv80 on the 100 MHz system clock with one clock enable, a 20 MHz Z80 (section 2.3) | tv80 is a single-edge synchronous core: one enable per T-state. Dividers such as ÷28 need the 100 MHz grid |
| A 40/100 MHz crossing with fixed capture points and 15 ns multicycle paths | One clock domain; the core's paths are multicycle paths of 5 clocks, and the bus interface samples the core's outputs at fixed clocks after each cen (section 3.3) | The same idea: fixed points, no synchronisers |
| Fixed 20 MHz | 20 MHz ÷ n (n = 1–8), locked to the slots, or 3.57 MHz | Spectrum timing and slower games (design plan, branch 11) |
| The CPU uses cycle 0 only; a bus cycle is 2 slots | The CPU uses cycles 0 and 2, at most one per slot (section 5.5) | Z80: a read must be served 2 T-states (100 ns) after its address, from either T-state phase in the slot |
| Read data reaches fx68k 15 ns before it latches it | Read data reaches tv80 10 or 20 ns before it takes it, by phase (section 5.3) | Z80 |
| Writes posted to the next slot's cycle 0, with an early /DTACK | Writes posted to the next CPU cycle after the data is valid (T2); they end before the next M-cycle's access | The same idea; tv80 has no /DTACK, and needs none |
| Wait states: 2 when an urgent display fetch or a nasty copper takes cycle 0 | None, ever: nobody takes a cycle the CPU has asked for (spec 2, section 5.3) | The Z80 never waits (design plan, branch 11) |
| Registers in the memory map: custom block `0xE00000`, system block `0xF00000` | I/O ports in register:page form; both blocks also in the register page (spec 2, section 10) | Z80: 64 KB address space, I/O instructions |
| 32-bit register bus; the CPU first, then the copper, then the DMA engine | 8-bit register bus; the copper first, then the CPU, then the DMA engine | The Z80's I/O cycle has room for a clock's delay, and the copper's writes then always land on their pixel |
| Bus errors: unmapped addresses, ROM writes, user mode (SYSCON.PROTECT); BUSERRADDR, BUSERRWHY | None: unmapped ports and pages read `0xFF` and ignore writes | Z80: no bus error input, no user mode |
| Interrupt acknowledge: level on A3–A1, vector number from the controller, 7 levels | IM 2 acknowledge on one /INT line: vector byte VECBASE + 2 × source, fixed priority; IM 1 reads INTID (spec 8) | Z80: one /INT line |
| The RESET instruction resets the devices | No such instruction: a soft reset is a write to SYSRESET (spec 7) | Z80 |
| Double bus fault halts the CPU: SYSSTAT.HALTED, SYSCON.HALTRESET | Left out: `HALT` is an ordinary instruction that waits for an interrupt | Z80 |
| NMI (level 7) runs the program's own vector | The same, plus the NMI monitor paging (section 8.2) | Spectrum extra (the Multiface) |
| – | Interrupt pages and stack capture: the bus interface spots each response and return from outside the core, switches windows and keeps the NMI's pushed PC in registers (sections 8.3–8.6) | A retro-z80 extra (design plan, branch 17): retro68k has no MMU |
| A hardware debugger is an open point (B3) | No hardware debugger | Design plan, branch 11 |

## 2. The tv80 core

### 2.1 The wrapper

tv80 comes as a core (`tv80_core`) and a small synchronous wrapper (`tv80s`). retro-z80 uses its own copy of the wrapper, `fpga/rtl/z80_cpu.v` (as retro68k has `cpu_fx68k.v`), which differs from `tv80s` in four ways:

1. **cen** is brought out and passed to the core (`tv80s` ties it to 1). The wrapper's bus strobe flip-flops (mreq_n, iorq_n, rd_n, wr_n) and its read data register also change only on cen. Each strobe is assigned once per clock: `tv80s` assigns each one twice in a clock, which gives false edges in simulation.
2. The core's early cycle-type outputs (`mcycle`, `tstate`, `iorq`, `no_read`, `write`, `intcycle_n`) are brought out to the bus interface, which needs to know the type of an M-cycle during T1 (section 5).
3. `TV80_REFRESH` is defined, so the R register counts (games use `LD A,R` for random numbers) and rfsh_n works. It is a global define tested inside `tv80_core`, so it is set for the whole build (`-DTV80_REFRESH` in the simulation Makefile and the lint script), not inside the wrapper.
4. Nothing else is brought out: the interrupt pages, the stack capture and the NMI paging of sections 8.2–8.4 work from these outputs (the order of the cycles, the repeated T1 of a response M1, and the opcode bytes fetched), as a Multiface does, so tv80 itself is used unchanged.

Parameters: `Mode = 0` (Z80), `T2Write = 1` (wr_n low from the start of T2), `IOWait = 1` (the standard I/O cycle with one automatic wait state). tv80 makes its automatic wait states, in the I/O cycle and the interrupt acknowledge, by repeating T1, not by adding a TW after T2 (sections 6 and 8.1).

### 2.2 Signals

| Signal | Dir. | Use here |
|--------|------|----------|
| clk | in | 100 MHz system clock |
| cen | in | Clock enable: one clock high per T-state (section 3) |
| reset_n | in | System reset (spec 7), section 9 |
| wait_n | in | Tied high: the Z80 never waits |
| int_n | in | From the interrupt controller (spec 8) |
| nmi_n | in | From the interrupt controller (spec 8), falling edge taken |
| busrq_n | in | Tied high: there is no other bus master |
| m1_n | out | Opcode fetch, or with iorq_n, interrupt acknowledge |
| mreq_n | out | Memory cycle (also low in the refresh part of M1) |
| iorq_n | out | I/O cycle or interrupt acknowledge |
| rd_n, wr_n | out | Read or write strobe |
| rfsh_n | out | Refresh: marks the refresh part of M1, which is ignored |
| halt_n | out | HALT executed; not used |
| busak_n | out | Not used |
| A[15:0] | out | Address |
| di[7:0] | in | Read data, opcode, or interrupt vector |
| dout[7:0] | out | Write data |

### 2.3 Compared with fx68k's phase enables

retro68k clocks fx68k at 40 MHz with two enables, enPhi1 and enPhi2, which alternate, because the 68000 does things on both edges of its clock: one 68000 clock is two 40 MHz cycles. The 40 MHz and 100 MHz clocks come from one MMCM and line up every 50 ns, and signals cross between them only at fixed points with at least 15 ns to settle.

A real Z80 also uses both edges of its clock (memory read data is sampled on a falling edge, for example), but tv80 does not: it is a synchronous core in which everything happens on the rising edge where its enable is high. So one enable per T-state is enough, and tv80 can run straight on the 100 MHz system clock. This keeps the CPU and the slot grid in one clock domain, and lets the divider give any number of clocks per T-state: 5n for the slot-locked speeds and 28 for 3.57 MHz. A separate CPU clock, as retro68k has, would fix the speeds to divisions of that clock.

What stays the same: the CPU's timing against the memory slots is fixed by construction, every time. The CPU leaves reset at a fixed point in the slot grid (section 9), and its accesses then fall on the same slot edges in simulation and on the board.

## 3. Clock enable and speed

### 3.1 Speeds

The core runs on the 100 MHz system clock. A **T-state is one cen pulse**: the core does nothing on clocks where cen is low. cen comes from a counter in the bus interface, set by CPUSPEED (spec 7):

| CPUSPEED | Clocks per T-state | Z80 speed | T-state | Locked to the slots |
|----------|--------------------|-----------|---------|---------------------|
| DIV = 0 (n = 1, reset) | 5 | 20 MHz | 50 ns | Yes: 2 T-states per slot |
| DIV = 1 (n = 2) | 10 | 10 MHz | 100 ns | Yes |
| DIV = 2 (n = 3) | 15 | 6.67 MHz | 150 ns | Yes |
| DIV = 3 (n = 4) | 20 | 5 MHz | 200 ns | Yes |
| DIV = 4 (n = 5) | 25 | 4 MHz | 250 ns | Yes |
| DIV = 5 (n = 6) | 30 | 3.33 MHz | 300 ns | Yes |
| DIV = 6 (n = 7) | 35 | 2.86 MHz | 350 ns | Yes |
| DIV = 7 (n = 8) | 40 | 2.5 MHz | 400 ns | Yes |
| SPECTRUM = 1 | 28 | 3.57 MHz | 280 ns | No |

- **Locked to the slots:** at n = 1–8 every T-state starts on slot edge 0 or 5 (spec 2, section 3), as retro68k locks its 68000 to the slots. With odd n the T-states alternate between the two phases; with even n they all keep the phase they started on. Both phases are served in time (section 5).
- **3.57 MHz** is close to a Spectrum's 3.5 MHz, for code timed by counting T-states. A T-state can then start on any slot edge; the accesses still fit with a wide margin (section 5.4). It is not exact Spectrum timing: there is no contention and the clock is 3.571 MHz, not 3.5469.
- **Speed changes** take effect at the first T1 of the next M-cycle, so an M-cycle never changes speed half way through. The divider looks at the core's tstate at E + 3 and takes CPUSPEED in a T1 that follows some other T-state. A repeated T1 (the wait state of an I/O cycle or an acknowledge, section 6) is not a new M-cycle.
- **From 3.57 MHz to a locked speed**, that first T1 must start on slot edge 0 or 5. tv80 does not show from outside which T-state is the last of its M-cycle, and it is used unchanged, so every T-state from the CPUSPEED write up to that T1 is lined up: each ends on the first slot edge 0 or 5 at least 28 clocks on, so it takes 28–32 clocks. In practice this is the rest of the `OUT` cycle, about 3 T-states (more if the copper writes CPUSPEED). The new speed starts with the instruction after the write to CPUSPEED.

### 3.2 Timing points

All times in this spec are measured from the cen edge that starts T1 (call it edge E), in clocks of 10 ns. At 20 MHz, T2 starts at E + 5, T3 at E + 10, T4 at E + 15.

- The core changes its address and early outputs just after a cen edge, and its strobes (registered in the wrapper on cen) just after the next one.
- The core takes read data (into its read data register) at the cen edge that **ends T2**: E + 10 at 20 MHz, E + 10n at speed n, E + 56 at 3.57 MHz. An I/O cycle and an interrupt acknowledge repeat T1 for their wait states, so their T2 starts later and the byte is taken later (sections 6 and 8.1).

### 3.3 Meeting timing at 100 MHz

tv80 does not run at 100 MHz as a single-clock design, and need not. Every register in the core is enabled by cen, and cen pulses are at least 5 clocks apart, so every path from one core register to another has 50 ns. The build tells Vivado so with multicycle constraints (5 clocks set-up) on the core's registers, as retro68k gives fx68k its microcode multicycle paths and its 15 ns crossing paths.

The bus interface samples the core's outputs only at fixed clocks after a cen edge: the early cycle-type outputs and the address at E + 3 (section 5), the strobes and dout at E + 6 at the earliest. These get multicycle constraints to match (3 clocks for the early outputs). Read data into the core comes from bus interface registers loaded at least one clock before the cen edge that takes it. Confirming all this in Vivado on the XC7A35T-2 is open point B1.

## 4. The internal chipset buses

The bus interface turns Z80 cycles into requests on two internal buses. Both are plain synchronous buses in the 100 MHz domain and know nothing about the Z80.

### 4.1 Memory port (to the scheduler, spec 2)

The CPU channel of the scheduler (`dmac.v`), as retro68k's:

| Signal | Meaning |
|--------|---------|
| cpu_req | A request, held until cpu_ack |
| cpu_we | 1 = write |
| cpu_addr[21:1], cpu_be[1:0] | Physical word address from the MMU (spec 2, section 9) and the byte: both for reads, /LB or /UB for a byte write |
| cpu_wdata[15:0] | The byte to write, on both halves |
| cpu_ack | The cycle has been issued |
| cpu_rvalid, rdata[15:0] | Read data, 40 ns after the issue; the bus interface keeps the byte chosen by address bit 0 |

The MMU sends SRAM pages to the scheduler, boot ROM pages to the ROM's block RAM, and answers NONE and reserved pages with `0xFF` (spec 2, section 9.3). Accesses to the register page (REGS, `0x3F8`) do not go to the scheduler: they become register bus cycles (section 5.7).

### 4.2 Register bus

| Signal | Meaning |
|--------|---------|
| rb_addr[12:0] | The register's offset in the register page (spec 2, section 10): page × 256 + register for an I/O access (section 6.1); A12–A0 for a register page access |
| rb_hi[7:0] | A15–A8 of an I/O cycle to a low-byte-only port; used only by port `0xFE` (spec 12). `0x00` otherwise (all keyboard rows) |
| rb_wr | One-clock write strobe |
| rb_rd | One-clock read strobe. Units with read side effects (FIFO data, stepping index registers) act on it once |
| rb_wdata[7:0] | Write data |
| rb_rdata[7:0] | Read data, valid the clock after rb_rd: the OR of all units' outputs (a unit not addressed outputs 0) |
| rb_hit | Some unit decoded the address. If none did, the master gets `0xFF` |
| rb_cdata[31:0], rb_cap | With a read of a capturing register's low byte (spec 3, rule 4): the register's whole value and a flag that it is one. The reading master stores it in its one tagged capture and answers that register's higher bytes from it |

Every unit decodes rb_addr, so one address names a register however it is reached. The bus has four masters. Each access takes one clock, and in each clock the first of these that wants the bus gets it:

| Order | Master | What it reaches | Spec |
|-------|--------|-----------------|------|
| 1 | **Copper** | Writes only: custom offsets (rb_addr `0x1000`–`0x13FF`), `0x000`–`0x0EF` by MOVE, any by MOVEF | 6 |
| 2 | **CPU** (this bus interface) | Everything: I/O cycles and register page accesses | – |
| 3 | **Sprite sequencer** | Writes only: the registers of the sprites SEQMASK gives it (custom `0x010`–`0x08F`), 16 bytes per list entry, in the line before the entry's first line | 17 |
| 4 | **DMA engine** | Reads and writes of the custom block, the palettes (`0x1400`–`0x1FFF`) and the stream registers SERDATA and SDDATA for its port jobs, paced by each unit's ready signal; spec 14 lists what a job may name and stops a channel that names anything else | 14 |

- The copper goes first, so its writes always land on their pixel. It writes at most once every 2 clocks (spec 6), so the CPU's strobe moves at most one clock, which every CPU access has room for (sections 5.7 and 6).
- The sprite sequencer (a retro-z80 extra) waits a clock whenever the copper or the CPU has the bus, so it never delays either of them. In any 40 clocks it gets at least 17, enough for an entry's 16 writes (spec 17, section 5.3).
- The DMA engine waits a clock whenever the copper, the CPU or the sequencer has the bus. It never delays any of them.
- The DMA engine reaches the registers only through this bus, one byte per clock, and uses no memory cycle for them. Its SRAM accesses go through the scheduler. It reads the boot ROM, as retro68k's engine does, through the ROM's second block RAM port, one byte per clock, not through this bus (spec 2, section 2; spec 14).

### 4.3 A 6502 machine

Nothing on these buses is Z80-specific. The 6502 machine, in its own repo (design plan, branch 8), would keep them: its bus interface drives the same memory port (with the same MMU) and reaches the register bus through a page of its memory map, as it has no I/O space. A 6502 makes an access every clock and often needs the byte just read to form its next address. A read here takes 8–13 clocks from address to data, so from SRAM a 6502 runs at 10 MHz with no waits (one access a slot); retro-6502 reaches 20 MHz by putting zero page, stack and ROM in block RAM and letting SRAM accesses wait.

## 5. Memory cycles

### 5.1 What the core does

tv80's memory timing, from the cen edge that starts T1:

| Point | Opcode fetch (M1, 4 T) | Memory read (3 T) | Memory write (3 T) |
|-------|------------------------|-------------------|--------------------|
| Start of T1 | A valid, m1_n low | A valid | A valid |
| During T1 | Early outputs say "fetch" | Early outputs say "memory read" | Early outputs say "memory write" |
| Start of T2 | mreq_n, rd_n low | mreq_n, rd_n low | mreq_n, wr_n low, dout valid |
| End of T2 | Opcode taken from di | Byte taken from di | – |
| T3–T4 | Refresh: A = I and R; rfsh_n low in T3 and T4, mreq_n low in T4 only (ignored) | – | – |
| Start of T3 | | | mreq_n, wr_n high (tv80 keeps them low for T2 only) |

So **a read's data must be at di by the end of T2**, two T-states after the address appears. The strobes come only at the start of T2, which at 20 MHz is too late to ask for the CPU cycle that serves a read started on slot edge 0; so the bus interface starts SRAM and ROM reads from the early cycle-type outputs during T1. A write's address and data are both known at the start of T2.

M-cycles longer than these (extra T-states for internal work) change nothing here: their first T-states are the same.

### 5.2 Which cycle an access uses

The CPU owns **cycles 0 and 2** of every slot, issued at slot edges 0 and 4 (spec 2, section 3). A request must stand in the clock before its cycle's issue edge. The bus interface needs 3 clocks after a cen edge to decode the cycle type, look up the MMU and load cpu_req.

| Access | Cycle used | Then |
|--------|------------|------|
| Read or opcode fetch | The first CPU cycle issued at **E + 4 or later** | Data usable 4 clocks after the issue; held at di until the core takes it |
| Write | Posted: the first CPU cycle issued at **T2 + 4 or later** (T2 = the cen edge that starts T2, when dout is valid) | The core goes on at once; the write is on the pins 10–30 ns after its issue |
| Boot ROM, NONE or reserved page | No SRAM cycle: the ROM's block RAM answers in one clock; NONE and reserved give `0xFF` | The CPU cycle goes to the free pool |
| Register page | No SRAM cycle: a register bus cycle (section 5.7) | As above |
| Refresh (rfsh_n low) | None | Section 7 |

The page for an access is looked up in T1, from the window's read page for a fetch or read and its write page for a write, and kept with the request. So a posted write goes to the page that was mapped when it was made, even if the mapping changes before it reaches the SRAM (this matters for the interrupt pages, sections 8.3 and 8.4).

### 5.3 Timing at 20 MHz

At 20 MHz T1 starts on slot edge 0 or 5 of a slot k. Both cases are shown. Times are from the start of slot k.

**Read or opcode fetch, T1 on slot edge 0:**

| Edge | Time (ns) | T-state | What happens |
|------|-----------|---------|--------------|
| 0 | 0 | T1 | cen. A valid (A = PC and m1_n low for a fetch). Early outputs give the cycle type |
| 1–3 | 10–30 | | Bus interface: cycle type, MMU lookup on A15–A13; cpu_req loaded at edge 3 |
| 4 | 40 | | **Cycle 2** of slot k issued |
| 5 | 50 | T2 | cen. mreq_n, rd_n low. Address on the SRAM pins (50–70 ns) |
| 7 | 70 | | Data captured from the SRAM |
| 8 | 80 | | Byte (picked by A0) at di |
| 10 | 100 | T3 | cen. Core takes the byte (end of T2): **20 ns to spare**. For M1, refresh starts (ignored) |
| 20 | 200 | T1 | Next M-cycle after M1 (on slot edge 0 again); after a 3-T read, at 150 ns (slot edge 5) |

**Read or opcode fetch, T1 on slot edge 5:**

| Edge | Time (ns) | T-state | What happens |
|------|-----------|---------|--------------|
| 5 | 50 | T1 | cen. A valid. Early outputs give the cycle type |
| 6–8 | 60–80 | | Bus interface: cycle type, MMU lookup; cpu_req loaded at edge 8 or 9 |
| 10 | 100 | T2 | cen. mreq_n, rd_n low. **Cycle 0** of slot k + 1 issued |
| 13 | 130 | | Data captured from the SRAM |
| 14 | 140 | | Byte at di |
| 15 | 150 | T3 | cen. Core takes the byte: **10 ns to spare** |

**Write, T1 on slot edge 0:**

| Edge | Time (ns) | T-state | What happens |
|------|-----------|---------|--------------|
| 0 | 0 | T1 | cen. A valid. Early outputs say "write"; MMU gives the write page |
| 5 | 50 | T2 | cen. wr_n low, dout valid |
| 6–9 | 60–90 | | Write request built; cpu_req loaded |
| 10 | 100 | T3 | cen. **Cycle 0** of slot k + 1 issued (posted) |
| 11–13 | 110–130 | | On the SRAM pins; /WE low from 115 to 125 ns (spec 2, section 8.2) |
| 15 | 150 | T1 | Next M-cycle. If it reads, it uses cycle 0 of slot k + 2, after the write |

**Write, T1 on slot edge 5:**

| Edge | Time (ns) | T-state | What happens |
|------|-----------|---------|--------------|
| 5 | 50 | T1 | cen. A valid |
| 10 | 100 | T2 | cen. wr_n low, dout valid. Cycle 0 of slot k + 1 is issued at this edge: too early |
| 11–13 | 110–130 | | Write request built; cpu_req loaded |
| 14 | 140 | | **Cycle 2** of slot k + 1 issued (posted); on the pins 150–170 ns |
| 15 | 150 | T3 | cen |
| 20 | 200 | T1 | Next M-cycle. If it reads, it uses cycle 2 of slot k + 2, after the write |

A read that follows a write to the same address therefore always sees the new data.

### 5.4 Other speeds

**Locked speeds (n = 1–8).** T1 is always on slot edge 0 or 5, and the core takes read data at E + 10n:

| T1 on | Read issued | Data at di | Taken at | Spare |
|-------|-------------|------------|----------|-------|
| Slot edge 0 | E + 4 (cycle 2) | E + 8 | E + 10n | 2 clocks at n = 1, more above |
| Slot edge 5 | E + 5 (cycle 0) | E + 9 | E + 10n | 1 clock at n = 1, more above |

A write's T2 is on slot edge 0 or 5 too, so it is issued at T2 + 4 or T2 + 5, and is on the pins by T2 + 8, before its T3 ends (E + 15n). The next M-cycle's access is issued at its own E + 4 or later, after the write.

**3.57 MHz (÷28).** T1 can be on any slot edge. The CPU cycles are issued at slot edges 0 and 4, at most 6 edges apart, so the first one at E + 4 or later comes by E + 9 at worst:

| | Worst case | Needed by | Spare |
|---|------------|-----------|-------|
| Read issued | E + 9 | – | – |
| Data at di | E + 13 (130 ns) | E + 56 (end of T2, 560 ns) | 43 clocks |
| Write issued | T2 + 9 | Before the next M-cycle's read (E + 84 + 4 at the earliest) | Over 60 clocks |

So the Spectrum speed needs no wait either, however its T-states fall on the slots. The simulation measures the worst read margin at 3.57 MHz as 43 clocks, as above (ticket #6).

### 5.5 At most one CPU cycle per slot

Every Z80 M-cycle is at least 3 T-states, so two accesses are at least 15 clocks apart at 20 MHz. A read is issued 4 or 5 clocks after its T1, a write 4 or 5 clocks after its T2, and in the tables above the issue edges of two accesses in a row are always 10 or more clocks apart. Two CPU issue edges in one slot (edges 0 and 4) would be 4 apart, so **the CPU uses at most one of cycles 0 and 2 in any slot**, and at most two in any three slots. At slower speeds the accesses are further apart still. The other CPU cycle of each slot goes to the free pool (spec 2, section 4).

### 5.6 Byte data

The SRAM is 16 bits wide. A CPU read fetches a whole word and the bus interface keeps the byte chosen by address bit 0 (0 = low byte, D7–D0, /LB; 1 = high byte, D15–D8, /UB). A CPU write drives the byte on both halves of the data bus and pulls only /LB or /UB low. So the Z80 is little-endian in SRAM as everywhere else, and chipset units reading 16-bit words see the even byte in the low half (spec 2, section 8.4).

The byte read is held at di until the next read, so the core can take it at any point up to the end of T2 at every speed.

### 5.7 Register page accesses

A memory access whose page is REGS (`0x3F8`, spec 2, section 10) becomes one register bus cycle instead of a memory cycle. The core sees an ordinary 3-T-state memory read or write, or a 4-T-state opcode fetch, with no waits. Register page accesses use the strobes, not the early outputs, so a strobe is only ever sent for a real read or write.

| Access | What the bus interface does (20 MHz) |
|--------|---------------------------------------|
| Read | One rb_rd with rb_addr = A12–A0 and rb_hi = `0x00` at E + 6, the clock after rd_n goes low. The data is on rb_rdata at E + 7 and held at di; the core takes it at E + 10. If the copper has the bus at E + 6, the strobe moves to E + 7 and the data is at di by E + 8: still 2 clocks to spare |
| Write | One rb_wr with rb_addr = A12–A0 at E + 6, the clock after wr_n goes low and dout is valid (E + 7 if the copper has the bus) |
| Opcode fetch | No strobe. di = `0xFF` (`RST 38h`), so code that runs into the register page by mistake traps instead of reading FIFOs |

- Reading a FIFO data register through memory takes exactly one byte. A speculative read started in every T1 (the B1 fallback) is never used for the register page.
- A read uses the read page of its window and a write the write page, so in a window that reads ROM and writes REGS, `LD (HL),A` writes a register and `LD A,(HL)` reads the ROM.
- Through the register page, `LD (nn),HL` writes L to nn and then H to nn + 1: a 2-byte register in one instruction, low byte first, the order the MMU pages and the colours need (spec 3, section 3.1). Every other register takes its bytes in any order.
- At slower speeds there is more room; the strobe always comes the clock after the strobe from the core.

## 6. I/O cycles

tv80 with `IOWait = 1` makes a 4-T-state I/O cycle. A real Z80 adds an automatic wait state TW after T2; tv80 instead repeats T1: T1, T1, T2, T3. The strobes and the data come at the same times as on a real Z80. iorq_n and rd_n (or wr_n) go low at the start of the second T1; read data is taken at the end of T2. I/O cycles use no memory cycle.

| Edge (20 MHz) | Time (ns) | T-state | What happens |
|---------------|-----------|---------|--------------|
| E | 0 | T1 | A valid: page (or low-byte port) in A7–A0; B, A or the count in A15–A8, by instruction (section 6.2) |
| E + 1–4 | 10–40 | | Bus interface decodes the port into rb_addr and rb_hi (section 6.1) |
| E + 5 | 50 | T1 (repeated: the wait state) | iorq_n and rd_n or wr_n low; dout valid for OUT |
| E + 6 | 60 | | One rb_rd or rb_wr (E + 7 if the copper has the bus) |
| E + 7 | 70 | | Read data on rb_rdata (or `0xFF` if rb_hit is low), held at di (E + 8 at the latest) |
| E + 10 | 100 | T2 | |
| E + 15 | 150 | T3 | Core takes the byte (end of T2): at least 7 clocks to spare |
| E + 20 | 200 | T1 | Next M-cycle |

The repeated T1 is not a new M-cycle: the speed divider (section 3.1) tells it from a first T1 by the T-state before it.

- **One strobe per I/O cycle.** A read of a FIFO or an index register has its side effect exactly once.
- **Multi-byte values** (pointers, positions) are at consecutive registers, low byte at the lowest. Each byte is written straight through to its register when it is written; there are no latches (spec 3, rule 2). The exceptions, the MMU pages and the colours, hold their lower bytes inside their own units. The CPU's one tagged capture for live counters (spec 3, rule 4) follows retro68k's `bus_if.v` (`rh_valid`, `rh_tag`, `rh_data`). The unit hands over the whole value on rb_cdata with the low byte (section 4.2); the capture sits in the bus interface, which answers a higher byte of the tagged register from it.
- **Unmapped ports** read `0xFF` and ignore writes. No port gives an error.

### 6.1 Decoding: register and page

Every port is **register (high byte, A15–A8) : page (low byte, A7–A0)**: port = register × 256 + page. The bus interface decodes the low byte first:

| A7–A0 | A15–A8 | Goes to | rb_addr | rb_hi |
|-------|--------|---------|---------|-------|
| `0x1F`, `0x53`, `0x5B`, `0x62`, `0xFE` | Any | **Low-byte-only ports:** register A7–A0 of page `0x00`: Kempston, SERDATA, SDDATA, KBDATA, the Spectrum port | `0x00` : A7–A0 | A15–A8 |
| `0x00` | Register r | The **system block** (spec 3): interrupts, timers, serial, SD, input, system, MMU, geometry unit | `0x00` : r | `0x00` |
| `0x01` | Register r, `0x40`–`0xFF` | The **interrupt pages** (spec 2, section 9.8). Registers `0x00`–`0x3F` are reserved: no strobe | `0x01` : r | `0x00` |
| `0x10`–`0x13` | Register r | The **custom block**: custom offset (A7–A0 − `0x10`) × 256 + r (spec 3) | A7–A0 : r (`0x1000`–`0x13FF`) | `0x00` |
| Any other | – | Reserved: no strobe; reads give `0xFF`, writes are ignored | – | – |

So rb_addr is the same address the register page uses (spec 2, section 10): the port with its bytes swapped. The low-byte-only ports are also ordinary registers of page `0x00` (for example SERDATA is also port `0x5300`), and the page form reaches them with rb_hi = `0x00`; only port `0xFE` looks at rb_hi, to pick keyboard rows (spec 12). The palettes and KEYROW0–7 have no I/O page; they are reached through PALIDX and PALDAT (spec 4) and port `0xFE`.

The decode is a compare of A7–A0 against the five low-byte-only ports, then of A7–A2 against `000100`, A7–A0 against `0x00`, or A7–A0 against `0x01` with A15–A14 not `00`. It has 4 clocks before the strobe at E + 6.

### 6.2 What each instruction puts on A15–A8

| Instruction | A15–A8 | Use |
|-------------|--------|-----|
| `OUT (C),r`, `IN r,(C)` | B | **The normal way:** `LD BC,port` (B = register, C = page), then `OUT (C),A`. `INC B` steps to the next register, `DEC B` to the one before |
| `IN A,(n)` | A | **Reading:** `LD A,reg` then `IN A,(page)` reads register A of page n. With a low-byte-only port, A picks keyboard rows (port `0xFE`) or is ignored |
| `OUT (n),A` | A | Writes the value A to the register numbered A: of no use with pages. With a low-byte-only port it works as on a Spectrum: `OUT (0xFE),A` sets the border and beeper, `OUT (0x53),A` sends a byte |
| `INI`, `INIR`, `IND`, `INDR` | B before it is decremented | With C = a stream port (`0x53`, `0x5B`, `0x62`), B is a plain count: `INIR` reads B bytes. With C = a page, `INIR` reads registers B, B − 1, … 1 into rising addresses |
| `OUTI`, `OTIR`, `OUTD`, `OTDR` | B after it is decremented | With C = a stream port, `OTIR` sends B bytes. With C = a page, `OUTI` writes register B − 1 and `OTIR` writes registers B − 1, B − 2, … 0, stepping downwards to register 0. Registers are written directly (spec 3), so unrolled `OUTI`s can write a multi-byte register, its bytes held high byte first in memory; not the MMU pages or the colours, which need the low byte first. `OUT (C),r` with `INC B` is the usual way |

A 3-byte custom register (SPR0PT, a pointer at custom offset k), low byte first. Its port is (k bits 7–0) × 256 + `0x10` + (k bits 9–8); the generated headers give it as a constant (spec 3):

```
        ld   bc,SPR0_PT_P          ; B = offset bits 7-0, C = 0x10 + offset bits 9-8
        out  (c),l                 ; bits 7-0
        inc  b
        out  (c),h                 ; bits 15-8
        inc  b
        out  (c),e                 ; bits 23-16
```

A register in page `0x00`, read:

```
        ld   a,0x0C                ; INTID
        in   a,(0x00)              ; page 0x00: A = INTID
```

The copper, the DMA engine and the register page reach the same registers by address; only the CPU's I/O instructions use the port form. Full I/O access is kept alongside the register page, because the MMU must be reachable before any window shows the page.

## 7. Refresh

With `TV80_REFRESH` defined, T3 and T4 of every M1 put I and R on the address bus with rfsh_n low; tv80 drives mreq_n low in T4 only (a real Z80 has it low in both), as the ZEX bus traces show (ticket #2). The bus interface ignores any cycle with rfsh_n low: it makes no request and does not consult the MMU. The SRAM needs no refresh. R counts as on a real Z80.

## 8. Interrupts

### 8.1 Maskable interrupts (IM 2 and IM 1)

The interrupt controller (spec 8) drives int_n low while an enabled source is pending. The core takes it at the end of an instruction (if interrupts are enabled) and runs an acknowledge cycle: an M1 cycle with intcycle_n low during T1, then m1_n and iorq_n low together (no mreq_n, no rd_n), and the core's two automatic wait states. As in the I/O cycle, tv80 makes the wait states by repeating T1, so T2 comes after them.

| Edge (20 MHz) | What happens |
|---------------|--------------|
| E (T1) | intcycle_n low: the early outputs say "acknowledge". No memory request |
| E + 3 | The bus interface asks the controller for the vector. The controller picks the pending source with the lowest number, writes it to INTID and freezes its choice |
| E + 4 | The vector byte is held at di |
| End of T2 (after the repeated T1s) | The core takes the byte, as it takes an opcode: at least 16 clocks to spare |
| End of the cycle | The bus interface sends one **acknowledge pulse** (int_ack), which ends the freeze (spec 8). The acknowledge clears nothing; the handler clears its source |

- In **IM 2** the byte is VECBASE + 2 × source (spec 8), the low byte of the table address, with I as the high byte. The two writes that push PC come first, then the two reads of the table; all are ordinary memory cycles (section 5), except that the interrupt pages may switch windows in the acknowledge, before the pushes (section 8.3). A maskable response's pushes are never captured.
- In **IM 1** the byte is ignored and the core does `RST 0x38`; the handler reads INTID (register `0x0C` of page `0x00`), which the controller set in the acknowledge.
- IM 0 is not supported: the controller always drives the IM 2 byte, which IM 0 would run as an instruction (spec 8).

The acknowledge cycle uses no memory cycle and no wait states.

### 8.2 NMI

nmi_n comes from the interrupt controller, which drives it from the Multiface button and the USB serial BREAK command, as NMICON allows; NMISTAT says which (spec 8, spec 10). The core takes a falling edge, finishes the instruction, runs the NMI response (a dummy M1 at PC and two writes that push PC) and then fetches the opcode at `0x0066`. The dummy M1 is an ordinary fetch (section 5); its byte is ignored.

tv80 gives the dummy M1 the same automatic wait as an acknowledge: it repeats T1, with intcycle_n high. No other opcode fetch ever repeats T1 (wait_n is tied high, and only the acknowledge and the NMI response have automatic waits in M1), so the bus interface knows the NMI response by it, at the cen edge that starts the second T1 (E + 5n; E + 28 at 3.57 MHz). In that clock it sends **nmi_ack**, which ends the controller's NMI request (spec 8, section 10). The dummy fetch's read has already been made by then, through the program's map; it has no side effect (an opcode fetch from the register page makes no strobe).

The **NMI monitor paging** (a Spectrum extra, Multiface style) is now the NMI set's default in the interrupt pages (section 8.3; spec 2, section 9.7): for the NMI, window 0 reads the boot ROM's monitor page and writes the monitor's workspace page (`0x0FF`, spec 16, section 5.3); the program's PC and SP kept in NMICAPPC and NMICAPSP; both put back at `RETN`. The monitor itself is in spec 7, section 10.1 and spec 16, section 8.6.

What changed from the earlier NMI paging:

| Earlier | Now | Why |
|---------|-----|-----|
| Entry spotted by the first fetch at `0x0066` after a falling nmi_n edge | Entry spotted by the response's own M1 (a fetch that repeats T1); the switch is made in that M1, before the two pushes | Exact: a program that jumps to `0x0066` between the edge and the response no longer pages early. And one rule for the NMI and maskable interrupts |
| Window 0 only, fixed pages `0x3FF` and NONE | Any windows (NMIMASK), any pages (NMIP0–7, NMIP0W–7W); the reset values give the old behaviour, except the write page | Design plan, branch 17 |
| Window 0 read only during the NMI (write page NONE) | Window 0's writes go to the monitor's workspace page `0x0FF` (NMIP0W) | The monitor page saves registers and sets up its stack there, so with the capture an NMI writes nothing in the program's memory (design plan, branch 17; spec 16, section 8.6) |
| PC pushed onto the program's stack | Always kept in NMICAPPC, with the SP in NMICAPSP; `RETN` takes it from there. There is no bit to turn this off | A bad SP corrupts nothing (design plan, branch 17) |
| Window 0 put back as `RETN`'s second opcode byte is taken | Put back after `RETN`'s two stack reads, before the fetch at the return address | The stack reads use the same map as the pushes |
| NMICTL at register `0x7C` of page `0x00`; NMISAV0, NMISAVW0, NMISAVHI at `0x7D`–`0x7F`, read only, window 0 only | NMICTL at `0x48` of page `0x01`, the same EN and INNMI bits; NMISAV0–7 and NMISAV0W–7W, 2 bytes each, writable, all 16 page registers | One layout for both sets; writable so the monitor's `G` can change the program's map |
| `CB ED` followed by `45` would have ended NMI mode | The opcode watcher knows the CB prefix (section 8.4) | A fix |

**Nesting.** While INNMI is 1 the interrupt controller holds nmi_n high (spec 8), so no second NMI is taken; a pending event gives a new NMI right after `RETN`. With NMICTL.EN = 0 nothing is switched, and an NMI runs whatever window 0 holds at `0x0066`; it is still captured, INNMI is still 1 until its `RETN`, and that `RETN` still takes its stack reads from the capture.

### 8.3 Interrupt pages and stack capture: the response

This section and the next are a retro-z80 extra (design plan, branch 17). Spec 2, section 9.7 gives the programming model and section 9.8 the registers. The bus interface works from the core's cycles as seen outside it, with tv80 unchanged (section 2.1).

A **response** is, in order, with nothing between (tv80's microcode, `tv80_mcode.v`):

| Step | Maskable (IM 2) | Maskable (IM 1) | NMI |
|------|-----------------|-----------------|-----|
| 1. M1 | The acknowledge: intcycle_n low, T1 repeated (section 8.1) | The same | The dummy fetch at PC: intcycle_n high, T1 repeated (section 8.2) |
| 2. First write | PC bits 15–8 to SP − 1 | The same | The same |
| 3. Second write | PC bits 7–0 to SP − 2 | The same | The same |
| 4. Next access | Read of the table's low byte at I × 256 + vector | Fetch at `0x0038` | Fetch at `0x0066` |

So the bus interface knows each step by the order of the cycles, not by addresses: after a response M1, the **first two memory writes** are the pushes and the **first memory read or fetch** after them is the handler's. A set is **taken** when its response is the outermost (maskable: IPDEPTH = 0 and IPCTL.EN = 1; NMI: INNMI = 0, whatever NMICTL.EN holds); then, in the response M1, the bus interface notes the set's mask and EN and sets the depth to 1 (INNMI). A nested maskable response only counts IPDEPTH up (to at most 255).

**Switch (step 1),** when the taken set noted EN: in the clock after the response is seen, the copy of spec 2, section 9.9 starts. In 8 clocks, one window per clock, it saves all 16 MMU page registers into the set's saved pages and loads the masked windows from the set's pages. It is done long before the first push's T1 (section 8.5), so the pushes, the table read (or the fetch at `0x0038` or `0x0066`) and the handler all use the switched map through the ordinary lookup (section 5.2), with no multiplexer added to it. The response M1's own read (the NMI's dummy fetch) has been looked up by then, through the program's map.

**Capture (steps 2 and 3),** for every NMI response: at each push's T1 the early outputs say "write", and the bus interface, knowing it is a push, makes **no request**: no cpu_req, no ROM write, no register bus strobe, whatever page the write would go to. At the first push's T1 it loads NMICAPSP with A + 1 (the SP the program had); at each push's T2 + 1 it loads dout into NMICAPPC, high byte first. The core sees an ordinary write cycle and steps SP down by 2. A maskable response, outermost or nested, has no capture path: it pushes as normal, through the switched map. The switch and the capture are independent: with NMICTL.EN, the NMI's pushes are captured and the fetch at `0x0066` comes from the switched map.

**Why before the pushes.** The return restores the pages after its two stack reads (design plan, branch 17), so the stack reads use the switched map, and the pushes must use the same map, or the pops would not find the return address when SP is in a switched window. Switching first also lets a handler's stack live in its own bank from the first push: with SP in a switched window, the return address goes into the interrupt page, not into the program's memory (spec 2, section 9.7).

### 8.4 The return: watching opcodes

The bus interface watches the bytes taken by **opcode fetches** (M1 cycles that the early outputs call "fetch"; acknowledges, NMI dummy fetches, refresh and operand reads do not count) with a small state machine, to know where each instruction starts:

| State | Byte fetched | Next state | Meaning |
|-------|--------------|------------|---------|
| START | `DD`, `FD` | XY | Index prefix |
| START | `CB` | CB | The next fetch is the CB instruction's second byte |
| START, XY | `ED` | ED | The next fetch is the ED instruction's second byte |
| START, XY | `C9` | START | `RET` (a `DD` or `FD` before it changes nothing): returns while IPRESTORE.RET is armed |
| XY | `DD`, `FD` | XY | Another prefix: the earlier one is dropped |
| XY | `CB` | START | `DD CB d op`: d and op are operand reads, not fetches, so the next fetch is a new instruction |
| XY, START | anything else | START | |
| CB | anything | START | A CB instruction's second byte (`CB ED` is `SET 5,L`, not a prefix) |
| ED | `4D` | START | **`RETI`** |
| ED | `45` | START | **`RETN`**. The undocumented copies (`ED 55`, `ED 5D` …) do not count |
| ED | anything else | START | |

Reset and every response M1 (acknowledge or NMI) put it in START. tv80 never takes an interrupt after a prefix, so a response never comes mid-instruction.

**The return** is `RETI` while IPDEPTH ≥ 1, `C9` while IPRESTORE.RET is armed and IPDEPTH ≥ 1, or `RETN` while INNMI = 1. At the cen edge that ends T2 of that fetch, as the core takes the byte:

- `RETI` or armed `RET` with IPDEPTH ≥ 2: IPDEPTH counts down; nothing else. An armed `RET` or a `RETI` clears the arm.
- The outermost return of a set (IPDEPTH 1, or INNMI 1): the **next two memory reads** are marked as the stack reads. For `RETN` they come from the capture; if EN was noted, the windows in the noted mask are loaded from the saved pages after the second of them. The depth becomes 0 at the second of them.

The next two memory reads are the instruction's stack reads (tv80's M2 and M3 of `RET`, `RETI` and `RETN`, with nothing between). For `RETN`, each makes **no request**: the bus interface puts NMICAPPC bits 7–0, then bits 15–8, at di, as it does a ROM byte, and ignores the address. For `RETI` or an armed `RET` they are ordinary reads through the switched map, the same map the pushes used. The core steps SP up by 2, so SP is back at the program's value if the handler left it as it found it.

**The restore** starts at the cen edge that starts the second stack read's T2 (E + 5n), when that read's page has been looked up and kept with its request (section 5.2), and loads one window per clock for 8 clocks (spec 2, section 9.9). The fetch at the return address, at E + 15n, uses the program's map.

**IPRESTORE.NOW** acts in the clock after its write strobe (E + 7 of the `OUT`, or of the register page write): the count, and at 0 the restore. The copy runs from that clock for 8 clocks. The next opcode fetch is at E + 20 after an `OUT (C),r` and at E + 15 after a register page write; it is in a window outside the mask (or at the same address in both pages, spec 2, section 9.7), so it does not wait for the copy.

### 8.5 Timing at every speed

Every step is fixed to the cycle's own cen edges, so it holds at every speed. Times are from the cen edge E that starts T1 of the cycle named, at speed n (5n clocks a T-state; 28 at 3.57 MHz). A copy (the switch or the restore) loads one window per clock for 8 clocks, whatever the speed (spec 2, section 9.9).

The response M1 is 7 T-states in tv80: 5 in its microcode (`tv80_mcode.v`), with T1 taken three times by the automatic wait (section 8.1; B7). So the first push's T1 is at E + 35n (E + 196 at 3.57 MHz).

| Step | When | Needed by | Spare at 20 MHz | At speed n |
|------|------|-----------|-----------------|------------|
| INT response seen | intcycle_n in T1, sampled at E + 3 (as for the vector, section 8.1) | The switch's start | – | – |
| NMI response seen | The second T1, at E + 5n (E + 28) | The switch's start | – | – |
| Switch, INT | Windows 0–7 saved and loaded at E + 4 to E + 11 | The first push's T1, E + 35n | 24 clocks | 35n − 11 |
| Switch, NMI | At E + 5n + 1 to E + 5n + 8 (E + 6 to E + 13) | The same | 22 clocks | 30n − 8 (160 at 3.57 MHz) |
| An NMI push captured | Decided at E + 3 from the early outputs, as every request is (section 5.2); NMICAPSP loaded at E + 3; dout taken at T2 + 1 | The request it replaces would be loaded at E + 3 to E + 4 (T2 + 4 for the data) | As any write | As any write |
| Return seen | The opcode byte is at di by E + 8 or E + 9 at 20 MHz (section 5.3), and the watcher acts at E + 10n, when the core takes it | The first stack read's T1, after T3 and T4: E + 20n (E + 112) | 10 clocks | 10n |
| A `RETN` pop from the capture | The byte at di from E + 4 (a register, no memory cycle) | The core takes it at E + 10n | 6 clocks | 10n − 4 |
| Restore | From the second stack read's T2: windows 0–7 at E + 5n to E + 5n + 7 (E + 5 to E + 12) | The T1 of the fetch at the return address, E + 15n | **3 clocks** | 10n − 7 (49 at 3.57 MHz) |
| IPRESTORE.NOW | At E + 7 to E + 14 of the writing cycle (E + 8 to E + 15 if the copper has the bus) | The first access to a switched window, after the next fetch (which is outside the mask): E + 35 at the earliest | 20 clocks | More |

**At 20 MHz,** the tightest speed. The switch, with E the cen edge that starts the response M1's first T1:

| Edge | T-state | What happens |
|------|---------|--------------|
| E | T1 | intcycle_n low (INT). For the NMI, the dummy fetch is looked up through the program's map and asked for at E + 3 or E + 4 |
| E + 3 | | INT response seen; the set is taken |
| E + 4 – E + 11 | | INT copy: window k saved, and loaded if masked, at E + 4 + k |
| E + 5 | T1 (repeated) | NMI response seen; nmi_ack |
| E + 6 – E + 13 | | NMI copy: window k at E + 6 + k |
| E + 10, E + 15 | T1 (repeated), T2 | |
| E + 20, E + 25, E + 30 | T3, T4, T5 | Refresh: no lookup (section 7) |
| E + 35 | T1 of the first push | Its lookup uses the switched map: **24 clocks** after the INT copy, **22** after the NMI copy |

The restore, with E the cen edge that starts the second stack read's T1:

| Edge | T-state | What happens |
|------|---------|--------------|
| E | T1 | The stack read is looked up through the switched map (or, for `RETN`, makes no request) |
| E + 3 | | Its request loaded, with its page (E + 4 when T1 is on slot edge 5) |
| E + 5 – E + 12 | T2 from E + 5 | The copy: window k loaded from its saved pages, if in the noted mask, at E + 5 + k |
| E + 10 | T3 | The core takes the byte |
| E + 15 | T1 of the fetch at the return address | Its lookup uses the program's map: **3 clocks** after the copy |

So all eight windows fit at every speed, the restore at 20 MHz with 3 clocks to spare. At 25 MHz (section 11) the restore would have 8 clocks for its 8 windows (E + 4 to E + 12), and fit with 1 clock to spare (B13).

At 3.57 MHz the T-states do not fall on the slots, but none of these steps uses a memory cycle or a slot edge, so the only change is more room. The NMI's capture and its pops use no memory cycle at all, so the CPU uses fewer cycles than without them.

### 8.6 What the testbench must know

`sim/tb.v` checks that every byte the core takes is the memory's, through a model of the MMU it keeps from the Z80's own writes (its "never waited" checks, section 13). With interrupt pages and the NMI's capture, the model must work these out from the core's cycles too, as section 8.3 and 8.4 say, without taking them from the design:

- a copy of page `0x01` from the Z80's writes (byte 0 held, byte 1 commits, a read page commit sets the write page), and the reset values;
- the response: its M1 (an acknowledge, or a fetch with a repeated T1) and the two pushes; at the response M1 the model's MMU takes the interrupt pages and its saved pages the old ones, so the model checks the pushes, the table read and the handler through the switched map (the model switches at once; the design's copy must be done before the first push's T1, which the check of every lookup catches);
- maskable pushes: the request goes to the page the switched map gives (the interrupt page when SP is in a switched window);
- NMI pushes: no CPU request may be made for them, and the SRAM word at each push address must be unchanged afterwards;
- the opcode watcher of section 8.4, and the depth; the two stack reads of a maskable return go through the switched map (those of `RETN` come from the capture), and only after the second of them does the model's MMU take the saved pages back, so the fetch at the return address is checked through the program's map;
- popped bytes from the capture: the two stack reads of `RETN` must make no request, and the byte the core takes must be the captured PC (the model's own copy of the two pushed bytes, or of the Z80's later writes to NMICAPPC), not the memory's;
- the copy: a probe on the MMU's page registers checks that a switch and a restore each finish within 8 clocks of starting and before the next T1 that looks the MMU up, at every speed, and records the spare (section 8.5).

The scheduler check (every CPU request issued in its cycle) needs no change: the capture only removes requests. The vector check (section 8.1, B11) is unchanged: the acknowledge itself is not touched.

## 9. Reset

- The system reset (spec 7) drives reset_n. The MMU, the speed (back to 20 MHz) and the bus interface reset together with the core.
- reset_n is released so that the core's first T1 starts on **slot edge 0**, as retro68k's first bus cycle starts at a fixed point in the slot grid. Simulations then match the board cycle for cycle.
- After reset the core fetches from `0x0000`, which is boot ROM page 0 through MMU window 0 (spec 2, section 9.4).
- The core has no RESET output, and nothing in the Z80 resets the devices; a soft reset is a write to SYSRESET (spec 7).

## 10. HALT, BUSRQ and WAIT

- **HALT:** the core repeats M1 cycles (reading memory, with refresh) until an interrupt or NMI, as a real Z80 does. These reads are ordinary and harmless; the opcode watcher (section 8.4) sees their bytes, and the response M1 that ends the `HALT` puts it back in START. halt_n is not used.
- **BUSRQ:** tied high. No unit takes the Z80's bus: the chipset uses its own memory cycles.
- **WAIT:** tied high. No access ever needs a wait state.

## 11. 25 MHz (open point B10)

A T-state of 4 clocks (40 ns) would give a 25 MHz Z80. It is to be tried in simulation; this section says what it would take.

At 25 MHz the core takes read data 80 ns (8 clocks) after T1 starts. Data is usable 4 clocks after a cycle's issue, and the bus interface needs 3 clocks to make a request, so a read must be issued at exactly **E + 4**. A slot is 2.5 T-states, so T1 falls on slot edges 0, 4, 8, 2 and 6 in turn:

| T1 on slot edge | Cycle issued at E + 4 | Owner | A CPU cycle in time? |
|-----------------|-----------------------|-------|----------------------|
| 0 | Edge 4: cycle 2 | CPU | Yes |
| 2 | Edge 6: cycle 3 | Display | No |
| 4 | Edge 8: cycle 4 | Audio (reserved) / free pool | No |
| 6 | Edge 10: cycle 0 | CPU | Yes |
| 8 | Edge 12: cycle 1 | Display | No |

So three phases in five have no CPU cycle in time, and the Z80 would wait unless the cycle owners changed. The only way without waits is for the CPU to **take the cycle issued at E + 4, whoever owns it**, and give its own next cycle (20 or 40 ns later) to that owner: the cycle swap of the earlier draft, back again. Cycle 4 costs nothing guaranteed while audio is parked; a display cycle would come up to 40 ns late, and spec 4 would set its urgent mark 4 clocks earlier. The read path would have no clock to spare, tv80's paths would get 4 clocks instead of 5, and a 2-clock request path would not help (edges 2, 4 and 8 still miss). Writes and I/O fit easily. The gain is 25 %.

## 12. FPGA resources

| Item | Resource |
|------|----------|
| tv80 | About 2,000–3,000 LUTs, no block RAM (to be measured) |
| Bus interface: cen divider, request timing, port decode, register bus master and arbiter, vector path | Estimate 200–350 LUTs |
| Response and return spotting, the opcode watcher, the NMI's capture paths (the interrupt page registers themselves are in spec 2, section 13) | Estimate 40–80 LUTs |

## 13. Test plan

- **Speeds:** at every CPUSPEED setting, count clocks per T-state (5n, or 28); at n = 1–8 every cen falls on slot edge 0 or 5; a change takes effect at the first T1 of an M-cycle, never inside an M-cycle and not at a repeated T1; from 3.57 MHz to a locked speed every T-state up to that T1 is 28–32 clocks and ends on slot edge 0 or 5. Done in simulation for all nine settings (ticket #6).
- **No waits:** run code from SRAM at every speed with the display (layers at their budget, urgent fetches), sprites, the copper and the DMA engine all busy; check that every read and write is issued in the cycle of section 5.2, that wait_n is never used, and that the data is at di before the core takes it.
- **Both phases:** at 20 MHz, reads, fetches and writes with T1 on slot edges 0 and 5 use cycles 2 and 0 as in section 5.3; at 3.57 MHz, T1 on every slot edge 0–9. A T-state of 28 clocks moves 8 slot edges, so one stretch at 3.57 MHz puts T1 on only five edges, all even or all odd: the test enters 3.57 MHz from both slot phases, as the speed test ROM (`sim/speeds`) does.
- **One CPU cycle per slot:** over a long run of every instruction, the CPU never asks for both cycles of one slot. Done over the whole of ZEXDOC at 20 MHz (ticket #7).
- **Writes:** byte writes to even and odd addresses change only that byte; a read straight after a write sees the new data; a posted write goes to the page mapped in its own T1.
- **Read and write pages:** in a split window, reads and opcode fetches use the read page and writes the write page, at all speeds.
- **Register page:** reads and writes through REGS give one strobe each, at all speeds and with a copper write in the same clock; a FIFO read through memory takes one byte; an opcode fetch from REGS gives `0xFF` and no strobe; `LD (nn),HL` writes a 2-byte register, low byte first, in one instruction.
- **I/O decode:** every page `0x00` register at port r × 256, every custom offset at its port in pages `0x10`–`0x13`, with the same value as at its register page offset; `INC B` steps registers; `IN A,(0x00)` with A = r reads register r; the five low-byte-only ports answer with any high byte, and port `0xFE` gets A15–A8; other pages read `0xFF` with no strobe; `OUT (0xFE),A` sets the border.
- **Block I/O:** `INIR` and `OTIR` with C = `0x53` stream B bytes through SERDATA; with C = a page, `INI` reads register B and `OUTI` writes register B − 1 (B8); three `OUTI`s with C = a custom page write a 3-byte register from a table held high byte first.
- **Register bus:** a copper write in the same clock as a CPU strobe goes first; the CPU's strobe moves one clock and its access still completes in time; a DMA engine access waits for both and never delays them.
- **Instruction tests:** ZEXDOC and ZEXALL in Verilator, from SRAM and from the boot ROM, at 20 MHz and 3.57 MHz (design plan, Q3). Done for ZEXDOC from SRAM at 20 MHz on the whole system, with the never-waited checks of the system testbench (ticket #7, `sim/zex/RESULTS.md`); ZEXDOC and ZEXALL also pass on the bare core (ticket #2).
- **Refresh:** no memory requests during refresh; `LD A,R` returns a counting value.
- **Interrupts:** in IM 2 each source's vector (VECBASE + 2 × source) reaches the core and one int_ack is sent; IM 1 runs `RST 0x38` and INTID names the source; NMI from the button and from USB BREAK reaches `0x0066`.
- **NMI paging (the NMI set's defaults):** at 20 MHz, 3.57 MHz and n = 8, with the NMI taken during every kind of instruction, during `HALT`, in a repeat (`LDIR`) and during a posted write: the response is seen at its repeated T1 and nmi_ack sent once; the switch is made in the response M1, before the pushes; the pushes are captured (no request; memory at SP − 1 and SP − 2 unchanged; NMICAPPC and NMICAPSP right); the fetch at `0x0066` comes from page `0x3FF`; writes to window 0 go to page `0x0FF`; MMU0/MMU0W and NMISAV0/NMISAV0W are as spec 2, section 9.8 says. `ED 45` takes its two stack reads from NMICAPPC with no request (SP in window 0, elsewhere, and pointing at ROM) and restores window 0 after them, before the fetch at the return address; with NMICTL.EN = 0 nothing is switched and the pushes are still captured; `ED 4D`, `ED 55`, `DD ED 45`, `CB ED` then `45`, an `ED` data byte and `0x45` fetched without `ED` before it behave as section 8.4 says; a program that jumps to `0x0066` just after the nmi_n edge does not page early; reset ends NMI mode.
- **Interrupt pages (maskable):** IM 2 and IM 1, at every speed: the switch in the acknowledge, done before the first push's T1, so the pushes go through the switched map; the restore after the second stack read, done before the return fetch's T1 (3 clocks to spare at 20 MHz, as section 8.5); IPRESTORE.NOW through a port and through the register page, with the next fetch from an unswitched window; the pushes always make their requests (no capture path for a maskable response, at any depth); `RETI`, `DD ED 4D` and an armed `RET` (also `DD C9`) return, a conditional `RET` does not; `DD CB d op` followed by `ED 4D` is seen; the pops come from memory through the switched map; nesting counts and only the outermost returns. The testbench's model checks every byte the core takes through all of this (section 8.6).
- **Reset:** the first T1 after every reset starts on slot edge 0; the core starts at `0x0000` in the boot ROM at 20 MHz.

## 14. Open points

| # | Item |
|---|------|
| B1 | Timing in Vivado on the XC7A35T-2: tv80's register-to-register paths as 5-clock multicycle paths, and the bus interface's paths from the core's early outputs through the MMU to cpu_req in 3 clocks (section 3.3). With 3 clocks this is expected to pass easily. Fallback: start an SRAM or ROM read in every T1 whatever the cycle type (those reads have no side effects; the result is dropped for I/O and writes). Never for the register page (section 5.7) |
| B2 | Is tv80 exact enough (flags, undocumented instructions, interrupt timing)? ZEXDOC and ZEXALL in phase 1; fallback T80 (VHDL) (design plan, Q3) |
| B3 | Closed: no hardware debugger (design plan, branch 11) |
| B4 | Closed: an NMI pages the boot ROM's monitor page into window 0 and `RETN` restores it (section 8.2; spec 7), now as the NMI set's default of the interrupt pages (design plan, branch 17) |
| B5 | Closed: the 28 MHz swap is gone. At 20 MHz and below every access has a CPU cycle in time (section 5) |
| B6 | Closed: the register page read has 2 clocks to spare at 20 MHz, with a copper write in the same clock (section 5.7) |
| B7 | The NMI response is now spotted by its M1, the only opcode fetch with a repeated T1 (section 8.2), instead of by the fetch at `0x0066`. Read from `tv80_core.v` (Auto_Wait for NMICycle in M1); to be confirmed in simulation, also from `HALT` and with the edge on every T-state of a `PUSH` |
| B8 | tv80 must put B on A15–A8 as a real Z80 does in the block I/O instructions: after the decrement for `OUTI`/`OTIR`/`OUTD`/`OTDR`, before it for `INI`/`INIR`/`IND`/`INDR` (section 6.2). Check in simulation against a known-good Z80 model |
| B9 | Closed: the page decode (section 6.1) has 4 clocks before the strobe |
| B10 | 25 MHz: try in simulation (design plan, branch 11). It needs the CPU to take whichever cycle is issued 40 ns after T1 and give its next cycle back, with no clock to spare on the read path (section 11). Faster than 25 MHz is parked (design plan, Q9) |
| B11 | Closed (ticket #16): tv80's acknowledge cycle repeats T1 for its wait states (T1, T1, T1, T2, as an I/O cycle has T1, T1, T2). The bus interface asks for the vector only in a T1 that follows another T-state, holds it at di from E + 4, and sends int_ack when the M1 ends. `sim/tb.v` checks every acknowledge: one vector request, the byte taken at the end of T2 is the vector (16 clocks to spare at 20 MHz), one int_ack. A request on every T1 is caught |
| B12 | The opcode watcher and the response steps (sections 8.3 and 8.4) assume tv80 runs its cycles as a real Z80 does: both bytes of `CB` and `ED` instructions as M1 fetches; d and op of `DD CB d op` as operand reads; the two pushes as the two M-cycles after a response M1, and the stack reads of `RET`, `RETI` and `RETN` as the two M-cycles after the opcode, with nothing between. Read from `tv80_mcode.v`; to be checked in simulation over ZEXDOC with the watcher's trace |
| B13 | At 25 MHz (B10) the restore's copy would have 8 clocks for its 8 windows, from the second stack read's T2 (E + 4) to the return fetch's T1 (E + 12), so 1 clock to spare (section 8.5); to check with B10. The switch adds nothing to the lookup any more (it copies into the MMU before the pushes), and the NMI's capture and its pops need no memory cycle |
