# Spec 18: Debug unit

Status: **draft**

The debug unit is a retro-z80 extra in the FPGA (design plan, branch 18): **single step**, **4 instruction breakpoints** and **2 watchpoints**, all of which raise the NMI. The boot ROM's NMI handler is the debug stub: it serves the monitor's `G addr break` and step command, and VS Code through the remote debugging protocol ([`debug.md`](debug.md)). The unit sits in the bus interface, beside the opcode watcher of the interrupt pages (spec 1, section 8.4), and works from tv80's cycles as seen outside the core, so tv80 is used unchanged. Its registers are I/O page `0x02`.

## 1. Summary

| Item | Value |
|------|-------|
| Single step | An NMI after the next instruction of the program: counted from the first M1 after a `RETN` (section 4) |
| Breakpoints | 4: a 16-bit address, and optionally the 10-bit read page of that address's window. Compared on opcode fetches that start an instruction; the program stops **before** the instruction (section 5) |
| Watchpoints | 2: a 16-bit address and mask; read, write or both; memory or I/O. The program stops **after** the instruction that made the access, and the access is kept: address, data, kind (section 6) |
| How it stops the program | The NMI, as a third NMI source beside the Multiface button and USB BREAK (spec 8, section 10) |
| Which caused it | DBGSTAT, sticky, write 1 to clear |
| Maskable interrupts during a step | Held off, unless DBGCTL.STEPINT asks for them (section 4.2) |
| When it compares | Only while **live**: from the first M1 after a `RETN` to the next NMI's entry. Never while NMICTL.INNMI is 1 (section 3) |
| Registers | I/O page `0x02`, registers `0x00`–`0x3C`: port = register × 256 + `0x02`; register page offset `0x0200` + register (section 8) |
| Who can write them | The CPU only, like page `0x01` |
| Cost | About 300–400 LUTs and 270 flip-flops on the KS2 (section 9) |

## 2. Comparison with retro68k

retro68k has **no debug unit in the FPGA** for now. It debugs in software first: the 68000's trace bit (T in SR) gives a trace exception after each instruction, and its breakpoints are `ILLEGAL` instructions written into memory. A hardware debugger stays open there for later (its open point B3).

| Feature | retro68k | retro-z80 | Why |
|---------|----------|-----------|-----|
| Single step | The 68000's trace bit | The debug unit: an NMI after one instruction | Forced: the Z80 has no trace mode |
| Breakpoints | `ILLEGAL` written into RAM | 4 hardware breakpoints, with an optional page match | Branch 18: they work in ROM, and in banked code the MMU maps in and out |
| Watchpoints | None | 2, memory or I/O | Branch 18 |
| Debugger on the PC | GDB (`m68k-elf-gdb`), the GDB remote protocol, a stub in its ROM | `tools/rdebug.py` and VS Code, the debug channel of `debug.md` | Each machine's choice; both use the transport of `debug.md`, section 2 |
| Monitor's step | `N`, with the trace bit | `N`, with the debug unit (spec 16, section 8.8) | Agreed for the shared monitor spec |

## 3. Live

The unit compares only while it is **live**. This keeps it off in the NMI handler, where the stub runs (design plan, branch 18), and off in the monitor, whose code is in the same ROM pages as breakpoints may be.

| Event | Live |
|-------|------|
| Reset | Off |
| An NMI's entry: the response M1 (spec 1, section 8.2), when NMICTL.INNMI becomes 1 | Off |
| A write of 0 to DBGCTL.LIVE | Off (the monitor does this when it is entered by a break or a trap) |
| The **resume M1**: the first M1 after any `RETN`'s two stack reads (an opcode fetch at the return address, or an interrupt acknowledge) | On |

- A `RETN` is the one the bus interface's opcode watcher knows (spec 1, section 8.4), with INNMI 1 or 0. With INNMI = 1 its stack reads come from NMICAPPC; with INNMI = 0 it is a plain `RETN` and pops from the stack. The monitor and the stub always leave by `RETN`, so the unit goes live exactly as the program starts.
- So the unit is never live while INNMI is 1: the NMI handler, the stub and the monitor after an NMI are never compared, and nothing it does can ask for a second NMI.
- A program's own `RETN` while live leaves it live. Breakpoints and watchpoints that are not enabled do nothing, live or not.

## 4. Single step

### 4.1 When the step NMI comes

1. The stub sets **DBGCTL.STEP**, then leaves by `RETN`.
2. At the **resume M1**, the step's NMI request is raised:
   - an opcode fetch: at the cen edge that ends its T2 (E + 10n at speed n, E + 56 at 3.57 MHz), when the core takes the byte;
   - an interrupt acknowledge (only with STEPINT, section 4.2): at the end of the acknowledge cycle, with int_ack.
3. DBGSTAT.STEP is set and DBGCTL.STEP clears.
4. The core takes the NMI at the end of that instruction (or of that interrupt response), so the NMI's captured PC is the next instruction: the program has run **exactly one instruction**, or has entered the handler and run none of it.

**Why it is in time.** The interrupt controller registers the request in one clock and drives /NMI low by E + 10n + 2. tv80 samples nmi_n at every cen edge and notes a falling edge in NMI_s (`tv80_core.v`); it looks at NMI_s at the end of an instruction's last T-state. The shortest instruction is 4 T-states (an M1 alone), whose last T-state ends at E + 20n; NMI_s is set at E + 15n, the end of T3. So the step NMI is taken after the first instruction whatever its length, at every speed.

**Prefixes.** tv80 takes no NMI after a prefix byte (`DD`, `FD`, `CB`, `ED`), only at the end of the whole instruction, so a step runs a whole prefixed instruction. **Repeats:** `LDIR`, `LDDR`, `CPIR`, `INIR`, `OTIR` and the others are one iteration per step, as the Z80 takes interrupts between iterations; the captured PC is the instruction again until the last. **`HALT`:** the NMI ends the halt, so stepping a `HALT` stops at the instruction after it without waiting. **`EI`:** has no effect on the step, which is an NMI.

### 4.2 Maskable interrupts during a step

| DBGCTL.STEPINT | From the write of DBGCTL.STEP to the step NMI's response |
|----------------|-----------------------------------------------------------|
| 0 (default) | The unit holds the CPU's /INT high. Requests stay pending in the controller (they are level-sensitive, spec 8, section 3) and are taken after the program goes on with no step |
| 1 | /INT as usual. If the program takes an interrupt at the resume point, the resume M1 is its acknowledge, and the step stops at the first instruction of its handler (section 4.1) |

The NMI wins over /INT in tv80, so with STEPINT an interrupt pending at the end of the stepped instruction is not taken before the step NMI; the next step or continue takes it.

## 5. Breakpoints

### 5.1 What is compared

Breakpoint n (0–3) matches an **instruction fetch**: an opcode fetch (an M1 cycle the early outputs call "fetch", spec 1, section 5.1) that

- comes while the unit is live,
- is not the resume M1 (section 3): so going on from a breakpoint does not stop again at once,
- starts an instruction: the opcode watcher is in START (spec 1, section 8.4). The second byte after `CB` or `ED`, and the byte after `DD` or `FD`, are continuation fetches and never match,
- is not an interrupt acknowledge (intcycle_n low) and not an NMI response's dummy fetch (its T1 repeats, spec 1, section 8.2),
- has A15–A0 = DBGBPn_ADDR, and, with DBGBPn_CTL.PAGEEN, the read page the MMU gives for A15–A13 in that fetch's lookup = DBGBPn_PAGE.

With PAGEEN off, the address alone is compared, whatever page is mapped.

### 5.2 Stopping before the instruction

The NMI is taken only at the end of an instruction, so the unit replaces the matched instruction's first byte with a `NOP`:

| When (from E, the cen edge starting the fetch's T1) | What happens |
|-------------|--------------|
| E + 3 | The lookup gives the page; the address and page are compared. On a match the bus interface puts `0x00` at di instead of the byte read |
| E + 5n | T2 starts without a repeated T1: not a response. The match stands |
| E + 10n | The core takes `0x00`. DBGSTAT.BPn is set and the NMI request raised |
| E + 20n | The `NOP` ends; the core takes the NMI. NMICAPPC = DBGBPn_ADDR + 1 |

The stub sets NMICAPPC back by 1 when DBGSTAT shows a breakpoint, so the program is stopped at the breakpoint with the instruction not yet run. The dummy fetch of an NMI response may have its byte replaced too at E + 3, but the core ignores that byte, and no bit is set. The `NOP` steps the R register once more than the program would (open point DU3).

## 6. Watchpoints

### 6.1 What is compared

Watchpoint n (0–1) matches a CPU **data access** while the unit is live:

| DBGWPn_CTL | Compared |
|------------|----------|
| IO = 0 | Memory reads and writes: every M-cycle that is not an opcode fetch, including an instruction's operand bytes, the stack, the IM 2 table read and a maskable response's pushes. Not opcode fetches, refresh, or the NMI's captured pushes and pops (the unit is not live then) |
| IO = 1 | I/O reads and writes (`IN`, `OUT`, `INI` and the others), with the full 16-bit port on A15–A0. Not the interrupt acknowledge |
| READ, WRITE | Which directions; both for either. Neither: the watchpoint matches nothing |

It matches when (A AND DBGWPn_MASK) = (DBGWPn_ADDR AND DBGWPn_MASK). A mask bit of 1 is compared; `0xFFFF` watches one address, `0xFF00` a 256-byte page. Only the CPU's accesses are watched: the copper, the DMA engine and the sprite sequencer are not.

### 6.2 Stopping after the instruction

At E + 3 of the access's T1, from the early outputs and the address, the match is known: DBGSTAT.WPn is set and the NMI request raised. tv80 sees /NMI fall by the end of that M-cycle's T2, and takes the NMI at the end of the instruction, since every access is in an M-cycle of at least 3 T-states. NMICAPPC is then the next instruction (the same one for a repeating block instruction that goes on). An access during an interrupt response (its pushes, the table read) stops at the handler's first instruction.

### 6.3 The kept access

The first match since DBGSTAT's watchpoint bits were last all clear is kept:

| Register | Holds |
|----------|-------|
| DBGHITADDR | The address, or the 16-bit port |
| DBGHITDATA | A write: the byte written (dout at T2 + 1). A read: the byte the core took (di at the end of T2) |
| DBGHITKIND | WRITE (bit 0: 0 a read), IO (bit 1), WP (bit 2: which watchpoint) |

A second match before the bits are cleared sets its DBGSTAT bit but keeps the first access.

## 7. The NMI

The unit's request is the interrupt controller's third NMI source (spec 8, section 10):

- Each of its events (step, breakpoint, watchpoint) sets the controller's one NMI request. The bus interface's nmi_ack ends it, so each stop gives one NMI, and events in the same instruction add to it: DBGSTAT shows them all.
- NMICON has no bit for it: the unit's own enables (DBGCTL.STEP, DBGBPn_CTL.EN, DBGWPn_CTL.EN) say whether it asks.
- While INNMI is 1 the controller holds /NMI high (spec 8, section 10). The unit is not live then, so it never asks; a button press or BREAK during the handler still gives an NMI straight after `RETN`, which then shows with DBGSTAT as it is.
- The NMI's own paging and stack capture apply as for any NMI (spec 2, section 9.7). The handler tells the debug unit's NMIs from the others by DBGSTAT (any bit set) and NMISTAT (spec 8).

## 8. Registers

I/O page `0x02` (spec 3, section 4.14): port = register × 256 + `0x02`, register page offset `0x0200` + register. Registers `0x3D`–`0xFF` are reserved (read `0xFF`). Like the MMU and page `0x01`, these are system registers: the copper and the DMA engine cannot reach them. Wide registers are written directly, byte by byte (spec 3, rule 2); the stub writes them while the unit is not live, so a half-written address is never compared.

| Register | Port | Name | Access | Bits | Reset | Meaning |
|----------|------|------|--------|------|-------|---------|
| `0x00` | `0x0002` | DBGCTL | RW | STEP (0), STEPINT (1), LIVE (7) | `0x00` | STEP: step at the next `RETN` (section 4); cleared by the hardware when the step NMI is raised. STEPINT: let maskable interrupts in during the step. LIVE: reads 1 while the unit is live; writing 0 turns it off, writing 1 does nothing (section 3). Bits 6–2 read 0 |
| `0x01` | `0x0102` | DBGSTAT | W1C | BP0–BP3 (3–0), WP0 (4), WP1 (5), STEP (6) | `0x00` | What has asked for an NMI since last cleared; sticky. Bit 7 reads 0 |
| `0x02`–`0x03` | `0x0202`–`0x0302` | DBGHITADDR (DBGHITADDR0, DBGHITADDR1) | R | 15–0 | `0x0000` | The kept access's address or port (section 6.3) |
| `0x04` | `0x0402` | DBGHITDATA | R | 7–0 | `0x00` | Its data |
| `0x05` | `0x0502` | DBGHITKIND | R | WRITE (0), IO (1), WP (2) | `0x00` | Its kind. Bits 7–3 read 0 |
| `0x06`–`0x0F` | | – | | | | Reserved |
| `0x10` + 8n | `0x1002` + n × `0x800` | DBGBPn | | | | Breakpoint n, n = 0–3 (below) |
| `0x30` + 8n | `0x3002` + n × `0x800` | DBGWPn | | | | Watchpoint n, n = 0–1 (below) |

Breakpoint n (`0x10` + 8n):

| Offset | Name | Access | Bits | Reset | Meaning |
|--------|------|--------|------|-------|---------|
| `+0`–`+1` | DBGBPn_ADDR (DBGBPn_ADDR0, DBGBPn_ADDR1) | RW | 15–0 | `0x0000` | The instruction's CPU address |
| `+2`–`+3` | DBGBPn_PAGE (DBGBPn_PAGE0, DBGBPn_PAGE1) | RW | PAGE (9–0) | `0x0000` | The read page that must be in the address's window, with PAGEEN |
| `+4` | DBGBPn_CTL | RW | EN (0), PAGEEN (1) | `0x00` | EN: compare. PAGEEN: compare the page too |
| `+5`–`+7` | – | | | | Reserved |

Watchpoint n (`0x30` + 8n):

| Offset | Name | Access | Bits | Reset | Meaning |
|--------|------|--------|------|-------|---------|
| `+0`–`+1` | DBGWPn_ADDR (DBGWPn_ADDR0, DBGWPn_ADDR1) | RW | 15–0 | `0x0000` | The address or port |
| `+2`–`+3` | DBGWPn_MASK (DBGWPn_MASK0, DBGWPn_MASK1) | RW | 15–0 | `0xFFFF` | Bit 1 = compared |
| `+4` | DBGWPn_CTL | RW | EN (0), READ (1), WRITE (2), IO (3) | `0x00` | EN: compare. READ, WRITE: directions. IO: I/O instead of memory |
| `+5`–`+7` | – | | | | Reserved (DBGWP1's `+5`–`+7`, `0x3D`–`0x3F`, are past the last register) |

`DBGPAGE` = `0x02` is the page; `REGS_DBGPAGE` = `0x0200` its register page offset.

## 9. How the monitor and the stub use it

- **`G addr break`** sets breakpoint 0 at break (EN, no page match), clears DBGSTAT and leaves by `RETN`. So a breakpoint now works in ROM, and nothing is written into the program (spec 16, section 8.8; this changes monitor.md's section 4.3, open point DU1).
- **The step command `N`** (agreed with retro68k for the shared monitor spec): DBGCTL.STEP, then `RETN`; the NMI shows the registers and the prompt.
- **The debug stub** (debug.md): SETBP and SETWP write the registers; CONTINUE and STEP leave by `RETN`; a stop is an NMI, and the stub reads DBGSTAT and the kept access, sets NMICAPPC back by 1 for a breakpoint, clears DBGSTAT and sends STOP.
- **Entered by a break or a trap** (`RST 30h`, `RST 38h`, no NMI), the monitor writes DBGCTL.LIVE = 0 first, so its own code is not compared.

```
; leave the monitor and step one instruction (the program's registers restored, PC in NMICAPPC)
        ld   bc,DBGSTAT_P           ; port 0x0102
        ld   a,0x7F
        out  (c),a                  ; clear every cause
        ld   bc,DBGCTL_P            ; port 0x0002
        ld   a,DBGCTL_STEP_M        ; STEPINT = 0: interrupts held off
        out  (c),a
        ...                         ; the rest of the exit (spec 16, section 8.6)
        retn                        ; the next M1 is the resume M1
```

## 10. FPGA resources

| Item | Estimate |
|------|----------|
| Breakpoints: 4 × (16-bit address + 10-bit page compare, enables) | 50–60 LUTs; 112 flip-flops |
| Watchpoints: 2 × (16-bit masked compare, kind) | 25–30 LUTs; 72 flip-flops |
| Kept access, DBGSTAT, DBGCTL, live, step and hold-off logic | 40–60 LUTs; 40 flip-flops |
| The `NOP` at di, the /INT hold-off, the request to the controller | 10–15 LUTs |
| Register read path (about 45 bytes) and write decode | 120–170 LUTs |
| **Total** | **About 300–400 LUTs**, 260–280 flip-flops, no block RAM, no DSP |

The KS2's XC7A15T has 10,400 LUTs; the bring-up build is about 2,000 (design plan, Q11). The compares are on paths the bus interface already has (the address at E + 3, the page from the lookup), so they add one compare level, not a new path to the SRAM pads; timing to check at the build (open point DU5).

## 11. Test plan

- **Registers:** every register at its port and at register page offset `0x0200` + register, reset values, DBGSTAT write 1 to clear, DBGCTL.LIVE reads and is cleared by a write of 0, reserved registers read `0xFF`; the copper and the DMA engine cannot reach page `0x02` (spec 3).
- **Step** (`sim/dbg`, Verilator, at 20, 3.57 and 2.5 MHz): a step of each instruction class (1 to 4 bytes, each prefix, `DD CB d op`, a 23-T instruction, `HALT`, `EI`, `DI`, a `JP`, a `CALL`, a `RET`, `LDIR`) runs exactly one instruction, checked against the testbench's own count of instruction starts; NMICAPPC is the next instruction.
- **Hold-off:** with a timer interrupt pending, a step with STEPINT = 0 takes no interrupt, and the interrupt is taken after a continue; with STEPINT = 1 the step stops at the handler's first instruction, with the handler's address in NMICAPPC.
- **Breakpoints:** each of the 4 stops before its instruction, in RAM and in ROM; with the page match it stops only with that page in the window; never on a continuation byte (an address that is the second byte of `CB`, `ED`, `DD`, `FD` instructions, or a `DD CB d op` operand), the acknowledge or an NMI dummy fetch; going on from a breakpoint runs the instruction and stops at the next hit, not at once; R off by one only.
- **Watchpoints:** memory read, write and both; I/O read and write with full 16-bit ports; masks; operand reads count, opcode fetches do not; a maskable response's pushes count; the kept access's address, data and kind for the first match; stop after the instruction, including `LDIR` (one iteration), `EX (SP),HL` and `OUTI`.
- **Live:** nothing compares between an NMI's entry and its `RETN`, or after a write of 0 to LIVE until the next `RETN`; a breakpoint at an address the NMI handler runs never hits; a button press during the handler gives one NMI after `RETN`.
- **Together:** a step whose instruction hits a watchpoint sets both bits and gives one NMI; ZEXDOC passes with the unit live and nothing enabled.
- **On the KS2:** the monitor's `N` and `G addr break` in ROM and RAM; then VS Code once the FT232H is fitted.

## 12. Open points

Accepted as proposed on 25 October 2026. DU1 is done (the shared spec's section 4.3 now allows a hardware breakpoint). Ticket #28 checked DU5 and DU6:

- **DU5:** met. The KS2 build meets 100 MHz with the unit (+0.735 ns setup, +0.020 ns hold overall; the worst path is not the unit's). The breakpoint compare, from the core's address through the MMU's lookup and the address and page compares to the `NOP` flag (`bp_nop`), is single-cycle with +1.6 ns to spare; the `NOP` is chosen where the byte read is put at di, so it adds no path to the SRAM pads.
- **DU6:** confirmed in simulation (`make -C sim dbg`, check 85): with STEPINT, a step whose resume M1 is an IM 2 acknowledge stops with NMICAPPC = the handler's address, no instruction of it run; tv80 takes the NMI at the end of the interrupt response.
- **Cost:** `dbgunit.v` is about 100 LUTs and 243 flip-flops; with the bus interface's part (the compares and the `NOP` there) the build grew by about 290 LUTs (section 10's estimate 300–400).

| # | Item |
|---|------|
| DU1 | The shared monitor spec's section 4.3 describes `G addr break` with `RST 30h` written into memory, and refuses a breakpoint in ROM. With the debug unit, retro-z80's `G addr break` is a hardware breakpoint and works in ROM. monitor.md's wording should leave the method to each machine; to agree with retro68k |
| DU2 | The unit goes live at the resume M1 after **any** `RETN`, and is turned off by a write of 0 to DBGCTL.LIVE. Chosen as the simplest rule that keeps the monitor and the stub out of the compares; it relies on the monitor always leaving by `RETN` |
| DU3 | Stopping before a breakpoint's instruction feeds the core a `NOP`, so R counts one more than without the breakpoint, and the stub sets NMICAPPC back by 1. Hardware that subtracts 1 itself would cost a 16-bit adder |
| DU4 | The resume M1 never matches a breakpoint, so going on from a breakpoint (or `G` to an address that holds one) runs that instruction first. Proposed: as written |
| DU5 | Timing on the KS2: the breakpoint compare and the `NOP` multiplexer at di between E + 3 and E + 8 at 20 MHz (spec 1, section 5.3: 10 ns spare when T1 is on slot edge 5) |
| DU6 | With STEPINT, an interrupt taken at the resume point stops at its handler's first instruction: that tv80 takes the step NMI at the end of the interrupt response, before the handler's first fetch, is to be confirmed in simulation |
| DU7 | Watchpoint MASK resets to `0xFFFF` (one address); a mask bit of 1 means "compared". Proposed: as written |
| DU8 | Only the CPU's accesses are watched. Watching the DMA engine's or the copper's writes would need compares on the scheduler's port |
| DU9 | **Screen capture** (design plan, branch 18, future, not built): a separate unit that sends the final picture over the link on debug.md's VIDEO channel. Not part of this unit |
