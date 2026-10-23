# Spec 1: CPU bus interface

Status: **draft**

This spec connects the Z80 to everything else. It covers how the tv80 core is clocked, how its speed is set, how its memory, opcode fetch and I/O cycles become requests on the internal chipset bus, how each memory access is fitted into the CPU's memory cycles so that the Z80 never waits, and how interrupts, NMI, reset and HALT work.

The memory side (slots, the SRAM controller, the MMU) is spec 2. The I/O ports are listed in spec 3.

## 1. Summary

| Item | Value |
|------|-------|
| CPU | tv80 (Verilog Z80) inside the Artix-7 FPGA, Mode 0 (Z80), with its refresh option on |
| Clock | The 56 MHz system clock, with a clock enable (cen) |
| CPU speed | A T-state every 2, 4, 8 or 16 clocks: 28, 14, 7 or 3.5 MHz. 28 MHz after reset. Set by CPUSPEED (spec 7), taking effect at the next M-cycle |
| Memory | Every opcode fetch, read and write goes through the MMU (spec 2): reads to the window's read page, writes to its write page. SRAM accesses use one memory cycle; boot ROM and register page accesses use none |
| Wait states | None, ever. wait_n is tied high |
| I/O | IN and OUT become one strobe on the register bus. Only A7–A0 are decoded (A15–A8 are passed on for port `0xFE`). Unmapped ports read `0xFF` |
| Refresh | The core's refresh cycles (T3–T4 of every M1) are ignored. The R register still counts |
| Interrupts | IM 2: the interrupt controller (spec 8) puts the vector byte on the bus in the acknowledge cycle. IM 1 also works. NMI from the interrupt controller |
| Not used | busrq_n (tied high), busak_n, IM 0 |
| Chipset bus | A memory port to the slot controller and a byte-wide register bus. Neither depends on the Z80, so a 6502 bus interface could later sit on the same bus |

## 2. The tv80 core and its signals

tv80 comes as a core (`tv80_core`) and a small synchronous wrapper (`tv80s`). retro-z80 uses its own copy of the wrapper, `fpga/rtl/z80_cpu.v`, which differs from `tv80s` in three ways:

1. **cen** is brought out and passed to the core (`tv80s` ties it to 1). The bus strobe flip-flops in the wrapper also change only on cen.
2. The core's early cycle-type outputs (`mc`, `ts`, `iorq`, `no_read`, `write`, `intcycle_n`) are brought out to the bus interface, which needs to know the type of an M-cycle during T1 (section 5).
3. `TV80_REFRESH` is defined, so the R register counts (games use `LD A,R` for random numbers) and rfsh_n works.

Parameters: `Mode = 0` (Z80), `T2Write = 1` (wr_n low from the start of T2), `IOWait = 1` (standard I/O cycle with one automatic wait state).

| Signal | Dir. | Use here |
|--------|------|----------|
| clk | in | 56 MHz system clock |
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
| halt_n | out | HALT executed (section 10); not used in version 1 |
| busak_n | out | Not used |
| A[15:0] | out | Address |
| di[7:0] | in | Read data, opcode, or interrupt vector |
| dout[7:0] | out | Write data |

## 3. Clock enable and speed

The core runs on the 56 MHz system clock. A **T-state is one cen pulse**: the core does nothing on clocks where cen is low.

| CPUSPEED.SPEED | Clocks per T-state | Z80 speed | T-state |
|----------------|--------------------|-----------|---------|
| 3 (reset) | 2 | 28 MHz | 35.7 ns |
| 2 | 4 | 14 MHz | 71.4 ns |
| 1 | 8 | 7 MHz | 143 ns |
| 0 | 16 | 3.5 MHz | 286 ns |

- cen comes from a counter in the bus interface. cen is always high on **even** clocks of the slot grid (spec 2, section 3), so T-states start at fixed points against the memory cycles.
- At 28 MHz a T-state is exactly one memory cycle and a slot is four T-states. A 4-T-state M1 cycle is one slot.
- **Speed changes** are written to CPUSPEED (spec 7) with an OUT. The new value is copied to the cen counter at the start of the next M-cycle (the next T1). So an M-cycle never changes speed half way through, and the access rules of section 5 always hold. In practice the new speed starts with the instruction after the OUT.
- The speed is not exact Spectrum timing: there is no contention and no fixed 3.5469 MHz. Software that counts T-states for timing should use the timers (spec 9) or the beam (spec 4).

## 4. The internal chipset bus

The bus interface turns Z80 cycles into requests on two internal buses. Both are plain synchronous buses in the 56 MHz domain and know nothing about the Z80.

### 4.1 Memory port (to the slot controller, spec 2)

| Signal | Meaning |
|--------|---------|
| cpu_req | A request for this CPU cycle (held for one cycle) |
| cpu_we | 1 = write |
| cpu_page[9:0], cpu_off[12:0] | MMU page and offset within the 8 KB page (from the MMU, spec 2, section 6): the window's read page for opcode fetches and reads, its write page for writes. The early cycle-type outputs say which, in T1 |
| cpu_wdata[7:0] | Byte to write |
| cpu_rdata[7:0] | Byte read (the slot controller picks the byte from the 16-bit word by address bit 0) |
| cpu_swap | Ask for the swap of section 5.3 (28 MHz only) |

The slot controller sends SRAM pages to the SRAM, boot ROM pages to the ROM block RAM, and answers NONE and reserved pages with `0xFF` (spec 2, section 6). Accesses to the register page (REGS, `0x3F8`) do not go to the slot controller at all: the bus interface turns them into register bus cycles (section 5.6).

### 4.2 Register bus (I/O ports)

| Signal | Meaning |
|--------|---------|
| rb_addr[12:0] | Register offset: the port number (A7–A0, bits 12–8 = 0) for an I/O cycle, or the offset A12–A0 for a register page access (spec 3, section 5) |
| rb_hi[7:0] | A15–A8 for an I/O cycle, used only by port `0xFE` (spec 12); `0x00` for a register page access (all keyboard rows) |
| rb_wr | One-clock write strobe |
| rb_rd | One-clock read strobe. Units with read side effects (FIFO data, stepping index ports) act on it once |
| rb_wdata[7:0] | Write data |
| rb_rdata[7:0] | Read data, valid the clock after rb_rd: the OR of all units' outputs (a unit not addressed outputs 0) |
| rb_hit | Some unit decoded the port. If none did, the bus interface returns `0xFF` |

There are two masters: the CPU bus interface (I/O cycles and register page accesses) and the copper (spec 6, writes to ports `0x30`–`0x9F` only). If both want the register bus in the same clock, the copper goes first and the CPU's strobe moves one clock later; the I/O cycle has room for this (section 6).

### 4.3 A 6502 later

Nothing on these buses is Z80-specific. A 6502 bus interface could drive the same memory port (with an MMU of its own or the same one) and reach the register bus through a page of its memory map (design plan, Q2). With a memory access on every clock, a 6502 at 14 MHz would use cycles 0 and 2 with no waits.

## 5. Memory cycles

### 5.1 What the core does

tv80's memory timing, measured from the cen edge that starts T1:

| Point | Opcode fetch (M1, 4 T) | Memory read (3 T) | Memory write (3 T) |
|-------|------------------------|-------------------|--------------------|
| Start of T1 | A valid, m1_n low | A valid | A valid |
| During T1 | mc, ts, intcycle_n say "fetch" | mc, ts, iorq, no_read, write say "memory read" | … say "memory write" |
| Start of T2 | mreq_n, rd_n low | mreq_n, rd_n low | mreq_n, wr_n low, dout valid |
| End of T2 | Opcode taken from di | Byte taken from di | – |
| T3 | Refresh: A = I and R, mreq_n and rfsh_n low (ignored) | – | – |
| End of the cycle | | | mreq_n, wr_n high |

So **a read's data must be at di by the end of T2**, only two T-states after the address appears. The strobes come too late to start a read (mreq_n and rd_n appear only at the start of T2), so the bus interface starts reads from the core's early cycle-type outputs during T1. A write's address and data are both known at the start of T2.

M-cycles longer than these (extra T-states for internal work) change nothing here: their first T-states are the same.

### 5.2 Fitting accesses into the CPU's cycles

The CPU owns **cycles 0 and 2** of every slot (spec 2, section 4). A memory cycle is 2 clocks. On the SRAM pins, cycle k of a slot runs from slot clock 2k+1 to 2k+3; its address must be known in the clock before (spec 2, section 5).

T-states start on even slot clocks. Call the clock where T1 starts E, and the clocks per T-state T.

| Access | Which memory cycle |
|--------|--------------------|
| Read or opcode fetch, 14 MHz and slower | The first CPU cycle whose pins start at E+1 or later. With T ≥ 4 this is always E+1 or E+3, and its data is captured by E+5, before the end of T2 (E+2T) |
| Read or opcode fetch, 28 MHz | The cycle whose pins start at **E+1** (the only one whose data is ready at E+4). If that is cycle 0 or 2, the CPU just uses it. If it is cycle 1 or 3, the CPU and that cycle's owner swap (section 5.3) |
| Write, any speed | Posted: the first CPU cycle whose pins start at E+T+1 or later (after dout is valid). At 28 MHz, E+3 or E+5. It always ends before the next M-cycle's read starts |
| Boot ROM, NONE or reserved page | No SRAM cycle: the ROM's block RAM answers in one clock, at any time |
| Register page | No SRAM cycle: a register bus cycle (section 5.6) |

### 5.3 The swap at 28 MHz

At 28 MHz a T-state is one memory cycle, so T1 can start at any of the four cycles. A read starting at slot clock 0 or 4 lands on cycle 0 or 2; one starting at slot clock 2 or 6 lands on cycle 1 or 3. For those, the CPU **takes cycle 1 (or 3) and gives its next cycle, 2 (or cycle 0 of the next slot), to that cycle's owner**.

This always works because the CPU never needs that next cycle:

- After a read on pins from P, the next M-cycle starts at P+5 at the earliest (P = E+1, and a read is at least 3 T-states), so its read is at P+6 and its write at P+8 or later.
- A posted write from the M-cycle before has finished by then (section 5.2).

So the CPU still uses at most two cycles per slot, and every unit keeps its number of cycles per slot; its cycle just comes 35.7 ns later. The display FIFOs, sprite and copper fetches all have far more slack than that (specs 4–6). At 14 MHz and slower there is never a swap.

The CPU's own cycles 0 and 2 are never taken by anyone else. Only the CPU decides a swap, and only for a 28 MHz read.

### 5.4 Timing at 28 MHz

Times from the start of T1, one clock = 17.86 ns. The examples start T1 at slot clock 0, so no swap is needed.

**Opcode fetch (M1):**

| Clock | Time (ns) | T-state | What happens |
|-------|-----------|---------|--------------|
| 0 | 0 | T1 | cen. A = PC, m1_n low. Early outputs say "fetch" |
| | 0–17.9 | | Bus interface: MMU lookup on A15–A13; cpu_req for cycle 0 |
| 1 | 17.9 | | Cycle 0 on the SRAM pins: address, /CS, /OE, /UB and /LB low |
| 2 | 35.7 | T2 | cen. mreq_n, rd_n low |
| 3 | 53.6 | | Data captured from the SRAM; byte picked by A0, held at di |
| 4 | 71.4 | T3 | cen. Opcode taken into IR (end of T2). m1_n high. Refresh: mreq_n, rfsh_n low, A = I:R (ignored) |
| 6 | 107.1 | T4 | cen. Core decodes |
| 8 | 142.9 | T1 | Next M-cycle (one slot after this one) |

**Memory read (3 T):** clocks 0–4 as above, with no m1_n; the byte is taken into the core at clock 4 and used in T3 (clocks 4–6). The next T1 starts at clock 6, which is slot clock 6: if it is a read, it swaps into cycle 3.

**Memory write (3 T):**

| Clock | Time (ns) | T-state | What happens |
|-------|-----------|---------|--------------|
| 0 | 0 | T1 | cen. A valid |
| 2 | 35.7 | T2 | cen. mreq_n, wr_n low, dout valid |
| 3 | 53.6 | | Cycle 1 is not the CPU's, so the write waits |
| 5 | 89.3 | | Cycle 2 on the pins: address, data, /UB or /LB; /WE low from 98.2 to 116.1 ns (spec 2, section 5) |
| 6 | 107.1 | T1 | Next M-cycle starts; the write has another clock to finish |

At 14, 7 and 3.5 MHz the same steps happen with more clocks in between.

### 5.5 Byte data

The SRAM is 16 bits wide. A CPU read fetches a whole word and the bus interface keeps the byte chosen by address bit 0 (0 = low byte, D7–D0, /LB; 1 = high byte, D15–D8, /UB). A CPU write drives the byte on both halves of the data bus and pulls only /LB or /UB low. So the Z80 is little-endian in SRAM as everywhere else, and chipset units reading 16-bit words see the even byte in the low half (spec 2, section 5.3).

The byte read is held at di until the next read, so the core can take it at any point up to the end of T2 at every speed.

### 5.6 Register page accesses

A memory access whose page is REGS (`0x3F8`, spec 2, section 6.5) becomes one register bus cycle instead of a memory cycle. The core sees an ordinary 3-T-state memory read or write, or a 4-T-state opcode fetch, with no waits.

| Access | What the bus interface does |
|--------|-----------------------------|
| Read | One rb_rd with rb_addr = A12–A0 and rb_hi = `0x00`, sent in T1 once the early outputs say "memory read" (clock 1 at 28 MHz). The data is on rb_rdata a clock later and held at di, well before the end of T2 (clock 4). If the copper has the bus, the strobe moves one clock and the data still arrives by clock 3 |
| Write | One rb_wr with rb_addr = A12–A0 at the clock after dout is valid (clock 3 at 28 MHz), as for an OUT |
| Opcode fetch | No strobe. di = `0xFF` (`RST 38h`), so code that runs into the register page by mistake traps instead of reading FIFOs |

- The strobe is sent only when the cycle type is certain, so reading a FIFO data port through memory takes exactly one byte. This rules out the B1 fallback (a read started in every T1) for the register page; the fallback may still start SRAM and ROM reads early.
- A read uses the read page of its window and a write the write page, so in a window that reads ROM and writes REGS, `LD (HL),A` writes a register and `LD A,(HL)` reads the ROM.
- Through the register page, `LD (nn),HL` writes L to nn and then H to nn + 1, which is the low-then-high order that commits a 2-byte register (spec 3, rule 10).

## 6. I/O cycles

tv80 with `IOWait = 1` makes a 4-T-state I/O cycle: T1, T2, an automatic wait state TW, T3. iorq_n and rd_n (or wr_n) go low at the start of T2; read data is taken at the end of TW.

| Clock at 28 MHz | T-state | What happens |
|-----------------|---------|--------------|
| 0 | T1 | A valid (port in A7–A0; B, A or the count register in A15–A8 depending on the instruction) |
| 2 | T2 | iorq_n and rd_n or wr_n low, dout valid for OUT |
| 3 | | Bus interface sends one rb_rd or rb_wr, with rb_addr = A7–A0, rb_hi = A15–A8 |
| 4 | TW | Read data on rb_rdata (or `0xFF` if rb_hit is low), held at di |
| 6 | T3 | Core takes the byte (end of TW) |
| 8 | | Next M-cycle |

If the copper has the register bus at clock 3, the strobe goes at clock 4 and the data is at di by clock 5, still before clock 6. At slower speeds there is more room.

Rules (spec 3 gives the full list):

- **Only A7–A0 are decoded.** A15–A8 are ignored by every port except `0xFE`, which uses them to pick keyboard rows as on a Spectrum (spec 12). So `OUT (n),A`, `OUT (C),r` and `OTIR` (which puts the falling count in B on A15–A8) all reach the same port.
- **One strobe per I/O cycle.** A read of a FIFO or an index port has its side effect exactly once.
- **Multi-byte values** (pointers, positions) are at consecutive ports, low byte at the lowest port. Writing a lower byte only fills a latch; writing the highest byte commits the whole value at once, so the hardware never sees half a value. Reading returns the committed value. This is done inside each unit, not by the bus interface.
- **Unmapped ports** read `0xFF` and ignore writes. No port gives an error.
- I/O cycles use no memory cycle.

## 7. Refresh

With `TV80_REFRESH` defined, T3 and T4 of every M1 put I and R on the address bus with mreq_n and rfsh_n low. The bus interface ignores any cycle with rfsh_n low: it makes no memory request and the MMU is not consulted. The SRAM needs no refresh. R counts as on a real Z80.

## 8. Interrupts

### 8.1 Maskable interrupts (IM 2 and IM 1)

The interrupt controller (spec 8) drives int_n low while an enabled source is pending. The core takes it at the end of an instruction (if interrupts are enabled) and runs an acknowledge M1 cycle: intcycle_n low during T1, then m1_n and iorq_n low together from T2 (no mreq_n, no rd_n).

- The bus interface sees intcycle_n during T1, asks the interrupt controller for the vector, and holds it at di. It makes no memory request.
- The controller freezes its choice of source when asked for the vector. At the end of the cycle the bus interface sends one **acknowledge pulse** (int_ack), which ends the freeze (spec 8, section 2). The acknowledge clears nothing; the handler clears its source.
- The core takes the vector byte at the same point as an opcode. In **IM 2** it is the low byte of the table address, with I as the high byte; the two following reads of the table are ordinary memory reads. Vector values are assigned in spec 8.
- In **IM 1** the byte is ignored and the core does RST `0x38`; the handler reads the controller's status register to find the source (spec 8).
- IM 0 is not supported: the byte would be run as an instruction.

The acknowledge cycle uses no memory cycle and no wait states.

### 8.2 NMI

nmi_n comes from the interrupt controller, which drives it from the Multiface button and the USB serial BREAK command (spec 8, spec 10). The core takes a falling edge, finishes the instruction and calls `0x0066`, in whatever page MMU window 0 holds then. The MMU is not changed by an NMI (open point B4).

## 9. Reset

- The system reset (spec 7, section 2) drives reset_n. The MMU, the speed (back to 28 MHz) and the bus interface reset together with the core.
- reset_n is released on a fixed slot clock (slot clock 0 of a slot), so the core's first T1 always starts at the same point in the slot grid, and simulations match the board cycle for cycle.
- After reset the core fetches from `0x0000`, which is boot ROM page 0 through MMU window 0 (spec 2, section 6.4).
- The core has no RESET output, and nothing in the Z80 resets the devices; a soft reset is a write to SYSRESET (spec 7).

## 10. HALT, BUSRQ and WAIT

- **HALT:** the core repeats M1 cycles at the same address (reading memory, with refresh) until an interrupt or NMI, as a real Z80 does. These reads are ordinary and harmless. halt_n is not used in version 1 (a debugger could show it, open point B3).
- **BUSRQ:** tied high. No unit takes the Z80's bus: the chipset uses its own memory cycles.
- **WAIT:** tied high. No access ever needs a wait state.

## 11. FPGA resources

| Item | Resource |
|------|----------|
| tv80 | About 2,000–3,000 LUTs, no block RAM (to be measured) |
| Bus interface: cen counter, cycle fitting, register bus master, vector path | Estimate 150–300 LUTs |

## 12. Test plan

- **Speeds:** at each CPUSPEED setting, count clocks per T-state; a speed change takes effect at the next T1, never inside an M-cycle.
- **No waits:** run code from SRAM at 28 MHz with the display, sprites and copper all busy; check that every read lands in the cycle of section 5.2, that wait_n is never used, and that the CPU's cycles 0 and 2 are never given to anyone else while it needs them.
- **Swap:** with T1 on every slot clock (0, 2, 4, 6), check reads use cycle 0, 1, 2, 3, and that after a swap the owner gets the next cycle; check no unit loses a cycle per slot.
- **Writes:** byte writes to even and odd addresses change only that byte; a read straight after a write sees the new data.
- **Read and write pages:** in a split window, reads and opcode fetches use the read page and writes the write page, at all four speeds.
- **Register page:** reads and writes through REGS give one strobe each, at all four speeds and with a copper write in the same clock; a FIFO read through memory takes one byte; an opcode fetch from REGS gives `0xFF` and no strobe; `LD (nn),HL` commits a 2-byte register.
- **Instruction tests:** ZEXDOC and ZEXALL in Verilator, from SRAM and from the boot ROM, at all four speeds (design plan, Q3).
- **I/O:** one strobe per IN or OUT; A15–A8 reach port `0xFE` only; INIR and OTIR stream to one port; unmapped ports read `0xFF`; a copper write in the same clock delays the CPU's strobe by one clock and the data still arrives in time.
- **Refresh:** no memory requests during refresh; `LD A,R` returns a counting value.
- **Interrupts:** in IM 2 each source's vector reaches the core and one int_ack is sent; IM 1 runs RST `0x38`; NMI from the button and from USB BREAK reaches `0x0066`.
- **Reset:** the first T1 after every reset starts at slot clock 0; the core starts at `0x0000` in the boot ROM at 28 MHz.

## 13. Open points

| # | Item |
|---|------|
| B1 | Timing at 56 MHz of the path from the core's early cycle-type outputs (microcode decode) through the MMU to the SRAM address pads, in one clock. Fallback: start an SRAM or ROM read in every T1 whatever the cycle type (those reads have no side effects; the result is dropped for I/O and writes). Never for the register page (section 5.6) |
| B6 | The register page read path (MMU page decode, rb_rd, unit decode, rb_rdata back to di) must fit at 28 MHz, also when a copper write moves the strobe by a clock (section 5.6) |
| B2 | Is tv80 exact enough (flags, undocumented instructions, interrupt timing)? ZEXDOC and ZEXALL in phase 1; fallback T80 (VHDL) (design plan, Q3) |
| B3 | A hardware debugger: stop cen to pause the CPU, single-step, breakpoints, from the PC over USB |
| B4 | Should an NMI also page a monitor into window 0 (as the Multiface did)? Not in version 1: the NMI handler at `0x0066` is whatever window 0 holds |
| B5 | The swap at 28 MHz is a refinement of the fixed cycle owners in the design plan (D4): owners keep their number of cycles per slot but not always their exact cycle. Specs 4–6 must allow one cycle (35.7 ns) of delay |
