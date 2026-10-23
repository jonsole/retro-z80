# Spec 8: Interrupt controller

Status: **draft**

The interrupt controller gathers the interrupt requests of every unit and passes them to the Z80's /INT input. It follows retro68k's controller (its spec 13 and the "Interrupts and Timers" chapter of its guide): each unit keeps its own flags and enables and raises one request line; the controller has a master enable, set/clear enables, pending and raw views, a vector base, a software interrupt and an ID register, with retro68k's source names and numbers. In **IM 2** it puts a vector byte on the bus during the interrupt-acknowledge cycle, so each source has its own handler. **IM 1** also works: the handler at `0x0038` reads INTID. The controller also drives /NMI, from the Multiface button and a "break" sent over USB. Its registers are system ports `0x00`–`0x0E`.

## 1. Summary

| Item | Value |
|------|-------|
| Sources | 21 numbers (0–20), retro68k's numbering; 12 in use in version 1, the rest reserved or not used |
| Request lines | Each unit raises a level line while one of its flags is set and enabled in the unit. The controller keeps no request flags of its own, except SOFT |
| Priority | Fixed: a lower source number goes first (one /INT line) |
| Enables | INTENA, three set/clear bytes (Amiga style), and INTCON.MASTER |
| IM 2 | Vector byte = VECBASE + 2 × source number, given in the acknowledge cycle |
| IM 1 | `RST 38h`; INTID gives the source chosen at that acknowledge |
| IM 0 | Not supported (section 7) |
| Spurious acknowledge | Entry 23 of the table (NONE) |
| NMI | Multiface button and USB BREAK; NMICON turns each off, NMISTAT says which. The NMI monitor paging is a Spectrum extra (spec 7, section 9.1) |
| Software interrupt | Source SOFT (18), raised and cleared through SOFTINT |
| RETI | Not needed by the controller (section 8) |
| Ports | `0x00`–`0x0E`; `0x0F` reserved. Also at register page offsets `0x000`–`0x00F` |
| Who can write them | The CPU only. The copper and the DMA engine cannot reach the system ports |
| Memory cycles | None |

## 2. Comparison with retro68k

| Feature | retro68k | retro-z80 | Why |
|---------|----------|-----------|-----|
| Sources | 24 (0–23) | 21 numbers (0–20); 21–22 do not exist, 23 is the spurious entry | Three set/clear bytes hold 7 sources each. retro68k's 21–23 are reserved there too |
| Request path | Unit flag AND unit enable → request line → INTENA → MASTER | The same | – |
| Levels | INTPRI0–2: a level 0–6 per source, set by software | None: fixed priority by source number. INTPRI0–2 are left out | Forced: the Z80 has one /INT line, not seven levels |
| Order within the CPU | Higher level interrupts a lower handler | A handler is interrupted only after it does `EI`, and then by any pending source (section 8) | Forced: the Z80 has IFF1, not a level mask |
| Vectors | VECBASE + n, one 4-byte vector each, VECBASE 64–232 | VECBASE + 2 × n, a 2-byte table entry each, low byte of the IM 2 table address | Forced: IM 2 tables hold 2-byte addresses |
| Spurious | Vector 24, the 68000's spurious vector | Source number 23 (NONE): entry VECBASE + 46 | Forced: the Z80 has no spurious vector |
| INTENA | Two 16-bit set/clear halves (bits 15 and 31) | Three 8-bit set/clear bytes, bit 7 SETCLR in each | Forced: 8-bit ports |
| INTID | For debugging only | Also how an IM 1 handler finds its source | Forced: IM 1 gives no vector. It replaces the earlier draft's INTHIGH port |
| DMA sources | DMA0–DMA3 (4–7) | DMA0 (4); 5–7 reserved | The DMA engine has one channel (spec 14) |
| AUDIO | Source 9 | Source 9 reserved | Sound is parked (design plan Q1) |
| SD | Source 16, from SDIRQ; not used in version 1 | Source 16, not used in version 1: the SD controller is polled (spec 11) | As retro68k's version 1 |
| Reserved 19–23 | Free | 19 reserved for the geometry unit (spec 15, branch 10), 20 free | Geometry unit is retro-z80 only |
| Sprites | No sprite source: a sprite running short raises VIDERR; collisions are polled | The same | – |
| Watchdog | No interrupt: it resets | The same | – |
| NMI | Level 7, vector 31 | /NMI, `0x0066` | Forced |
| NMI paging | None | Window 0 switched to the boot ROM's monitor page (spec 7, section 9.1) | Spectrum extra (Multiface style) |
| Register width | 32-bit registers | 8-bit ports, `0x00`–`0x0E` | Forced |

## 3. How an interrupt reaches the CPU

1. Something happens in a unit, for example the video reaches the start of vertical blanking. The unit sets a **status flag** (here VIDSTAT.VBLANK, spec 4). If the unit's own **enable** for that flag is on (here VIDINTEN.VBLANK), the unit raises its **request line**. INTRAW shows the request lines.
2. If the source's INTENA bit is on and INTCON.MASTER is on, the request is **pending**. INTPEND shows the pending sources.
3. While any source is pending, the controller holds /INT low.
4. The Z80 samples /INT at the end of each instruction. If its IFF1 flag is set (after `EI`), it runs an **interrupt-acknowledge cycle** (an M1 cycle with /IORQ low instead of /MREQ, spec 1, section 8.1).
5. When the bus interface asks for the vector, at the start of the acknowledge cycle, the controller picks the pending source with the **lowest number**, writes it to INTID and freezes the choice for the rest of the cycle. In IM 2 the controller drives the vector byte (section 5). In IM 1 the CPU ignores the bus and runs `RST 38h`; the handler reads INTID (section 6). The bus interface's acknowledge pulse (int_ack) at the end of the cycle ends the freeze. It clears nothing and marks nothing as "in service".
6. The handler clears the cause **in the unit**, usually by writing 1 to the unit's sticky flag (W1C). The request line drops.
7. If another source is still pending when the handler does `EI`, /INT is still low and the CPU is interrupted again at once.

Requests are **level-sensitive**: a source stays pending until its unit's flag is cleared, so no interrupt is lost while the CPU has interrupts disabled, while INTENA or MASTER is off, or while another handler runs. The other side: **a handler must clear the cause before `EI`**, or it is entered again at once.

Turning a source off in INTENA does not clear it. The unit's flag stays set, and turning the source back on gives the interrupt at once. To avoid an old event, clear the unit's flag before enabling the source.

**Spurious acknowledge:** if no source is pending when the vector is asked for (the CPU cleared the last request, or turned it off, in the instruction during which /INT was sampled), the controller gives source number 23, **NONE**: vector VECBASE + 46, and INTID = 23. Its handler simply does `EI` and `RET`.

## 4. Sources

Numbers follow retro68k. Unused numbers keep their place, so later blocks can be added without moving the others.

| Number | Name | From | Request while | Cleared in |
|--------|------|------|---------------|------------|
| 0 | VBLANK | Video: start of the frame and of vertical blanking (beam line 0) | VIDSTAT.VBLANK and VIDINTEN.VBLANK (spec 4) | VIDSTAT.VBLANK |
| 1 | LINE | Video: line compare, at the start of beam line LINECMP | VIDSTAT.LINE and VIDINTEN.LINE (spec 4) | VIDSTAT.LINE |
| 2 | COPPER | The copper wrote COPINT | COPSTAT.IRQ and COPCON.IRQEN (spec 6) | COPSTAT.IRQ |
| 3 | VIDERR | Video problems: a layer ran short (OVERRUN), the sprites ran short (spec 5) | VIDSTAT error bits and their VIDINTEN bits (spec 4) | VIDSTAT |
| 4 | DMA0 | DMA engine: a job with IRQ finished, or an error | DMXINT and DMXINTEN (spec 14) | DMXINT |
| 5–7 | – | Reserved (retro68k's DMA1–DMA3; this engine has one channel) | – | – |
| 8 | – | Not used, as in retro68k | – | – |
| 9 | AUDIO | Reserved for sound (spec 13, parked) | – | – |
| 10 | – | Not used, as in retro68k | – | – |
| 11 | TIMER0 | Timer 0 underflow | TMR0_STAT.UNDER and TMR0_CTRL.IRQ (spec 9) | TMR0_STAT.UNDER |
| 12 | TIMER1 | Timer 1 underflow | As timer 0 | TMR1_STAT.UNDER |
| 13 | TIMER2 | Timer 2 underflow | As timer 0 | TMR2_STAT.UNDER |
| 14 | TIMER3 | Timer 3 underflow | As timer 0 | TMR3_STAT.UNDER |
| 15 | SERIAL | USB serial: data received, timeout, room to send, overflow | SERIRQ and SERIRQEN (spec 10) | SERIRQ (sticky flags), or by reading or filling the FIFO |
| 16 | SD | Not used in version 1: the SD controller has no interrupt and is polled (spec 11), as in retro68k's version 1 | – | – |
| 17 | KEYB | PS/2 keyboard: byte waiting, or an error | KBIRQ and KBIRQEN (spec 12) | KBIRQ (sticky flags), or by reading the FIFO |
| 18 | SOFT | Software interrupt | Raised by SOFTINT.SET (section 9) | SOFTINT.CLR |
| 19 | GEOM | Reserved for the geometry unit (spec 15, branch 10) | – | – |
| 20 | – | Reserved | – | – |
| 21–22 | – | Do not exist (no enable bits) | – | – |
| 23 | NONE | Not a source: the spurious acknowledge (section 3) | – | – |

Reserved sources request nothing, so their INTRAW bits read 0.

**Order.** Fixed priority makes the source number the priority: video first (a VBLANK or LINE handler that starts late shows on the screen), then the DMA engine, the timers, the serial link (whose FIFOs absorb delay), the SD card, the keyboard and the software interrupt. retro68k's defaults put the timers above the video by level; here they come after it. A program that wants a timer to go first can turn the video sources off in INTENA while it waits, or nest (section 8).

## 5. IM 2 vectors

The vector byte for source n is:

    vector = (VECBASE + 2 × n) mod 256        (VECBASE bit 0 is always 0)

The CPU reads the handler address from `I × 256 + vector`. The table therefore has 24 entries of 2 bytes (48 bytes): sources 0–20, two unused entries (21–22) and the spurious entry NONE (23). VECBASE places it anywhere in the page at an even address. A VECBASE above `0xD0` makes the table wrap round to the start of the page; this works but is best avoided.

Example: I = `0xBF`, VECBASE = `0xD0`: the table is at `0xBFD0`–`0xBFFF`; VBLANK's handler address is at `0xBFD0`, TIMER0's at `0xBFE6`, the spurious one at `0xBFFE`.

The vector is driven only in the acknowledge cycle; no other read of the bus is affected. Unused entries can point at the spurious handler.

## 6. IM 1 and INTID

In IM 1 every interrupt runs `RST 38h`. The Z80 still runs an acknowledge cycle, so the controller still chooses a source and writes it to **INTID**, exactly as in IM 2. The handler reads INTID to find the source: a number 0–20, or 23 (NONE) for a spurious acknowledge.

INTID keeps its value until the next acknowledge, and the next acknowledge cannot come before the handler's `EI`. So the handler can read INTID at any point before `EI`.

```
isr38:  push af
        push hl
        in   a,(INTID)       ; source chosen at this acknowledge, 0-20 or 23
        add  a,a             ; × 2: offset in the table
        ld   l,a
        ld   h,high(table)   ; table of handler addresses, 48 bytes, not crossing a page
        ...                  ; jump through the table, as IM 2 would
```

In IM 2, INTID is useful for debugging: it says which source the last acknowledge gave.

## 7. IM 0

IM 0 is not supported. The controller does not know which mode the CPU is in, so it always drives the IM 2 vector byte in the acknowledge cycle. In IM 0 the Z80 would run that byte as an instruction. The Z80 starts in IM 0 after reset, but with interrupts disabled, INTCON.MASTER off and every INTENA bit off, so no interrupt is taken until software has chosen IM 1 or IM 2. Software must set `IM 1` or `IM 2` before the first `EI`.

## 8. EI, DI, nesting and RETI

An interrupt reaches the CPU only when four switches are all on: the unit's enable, the source's INTENA bit, INTCON.MASTER, and the Z80's IFF1.

- `DI` and `EI` control IFF1; the controller does not see them. /INT stays low while a source is pending, so a request that comes in under `DI` is taken at the first chance after `EI` (after the instruction following `EI`).
- On entry to a handler the Z80 clears IFF1, so nothing else comes in until the handler does `EI`.
- **INTCON.MASTER** turns off every interrupt except the NMI with one write. Pending requests are kept, and taken when it is turned back on.
- **Nesting:** the controller has no "in service" state. If a handler does `EI` early, any pending enabled source can interrupt it, including one with a higher number. To let only lower numbers in, the handler clears the INTENA bits of the higher-numbered sources (one set/clear write per byte), does `EI`, and sets them again before it returns. This replaces retro68k's levels.
- **RETI** is not needed. Zilog's daisy-chained peripherals watch the bus for `RETI` to end their "in service" state; this controller has none, so it ignores `RETI`. Handlers may end with `EI` then `RETI` (the usual habit, and harmless) or `EI` then `RET`.
- **HALT:** a pending interrupt (or NMI) wakes the CPU from `HALT` as usual.

## 9. Software interrupt

Writing SOFTINT with SET (bit 0) raises source 18, SOFT; writing it with CLR (bit 1) clears it. SOFTINT cannot be read; INTRAW2 bit 4 shows whether SOFT is raised. Like any source, it needs its INTENA bit and INTCON.MASTER.

SOFT has a high number, so it is chosen only when no lower-numbered source is pending. A VBLANK handler can do the urgent part, raise SOFT, clear its own flag and return; the rest then runs in the SOFT handler, after every other pending source has been served. The SOFT handler clears SOFT first, so a new request made while it runs is kept. If the SOFT handler does `EI`, other sources can interrupt it (section 8).

## 10. NMI

The Z80's /NMI is edge-triggered and cannot be masked by `DI`. The CPU jumps to `0x0066`; the handler ends with `RETN`. It is for getting control back from a hung program, for example to enter a debug monitor.

| NMI source | Event | Enable | Flag |
|------------|-------|--------|------|
| Multiface button | A press of the KS3's Multiface (NMI) button, debounced in the FPGA (spec 7, section 6) | NMICON.BUTTONEN | NMISTAT.BUTTON |
| USB break | The BREAK control command from the PC (spec 10) | NMICON.USBEN | NMISTAT.USB |

- Both enables are on after reset. INTCON.MASTER and INTENA do not affect the NMI. An event from a source that is turned off is ignored and sets no flag.
- An enabled event sets its NMISTAT flag (sticky, W1C) and sets an internal **NMI request**. The controller holds /NMI low while the request is set, and the bus interface clears the request when the CPU starts its NMI response (an nmi_ack pulse, spec 1, section 8.2). So **each press or break gives exactly one NMI**, and the handler does not have to clear anything for the NMI to stop. It should still clear NMISTAT, so that next time it can tell which source it was.
- Events that come in before the CPU has taken the request add to that one NMI; NMISTAT shows every source involved.
- **NMI monitor paging** (a Spectrum extra, spec 7, section 9.1): with NMICTL.EN = 1, taking an NMI switches window 0 to the boot ROM's monitor page, and `RETN` switches it back. While NMICTL.INNMI is 1, the controller holds /NMI high: events still set their flags and the request, and the request gives a new NMI straight after `RETN`. So the monitor is never entered twice. With NMICTL.EN = 0, INNMI stays 0 and an NMI can interrupt an NMI handler, as on a plain Z80.
- The KS3's DivMMC button is not an interrupt source; software reads it in SYSBTN (spec 7).

## 11. Latency

| Step | T-states |
|------|----------|
| Finish the current instruction | Up to 23 (for example `INC (IX+d)`); `LDIR`, `INIR`, `OTIR` and the other repeats accept interrupts between iterations |
| After `EI` | The next instruction always runs first |
| IM 2 acknowledge, push PC, read the table | 19 |
| IM 1 acknowledge, push PC | 13 |
| NMI, push PC | 11 |
| Controller | The request is registered once: 1 system clock (under 20 ns) |

| CPU speed | IM 2 worst case (23 + 19 T) | IM 1 worst case (23 + 13 T), before the dispatch code |
|-----------|-----------------------------|----------------------------------------|
| 28 MHz | 1.5 µs | 1.3 µs |
| 14 MHz | 3.0 µs | 2.6 µs |
| 7 MHz | 6.0 µs | 5.1 µs |
| 3.5 MHz | 12.0 µs | 10.3 µs |

Code that runs with interrupts disabled adds its own time. A 576p line is 32 µs, 896 T-states at 28 MHz. Effects that must land on an exact pixel belong to the copper (spec 6), not to a LINE handler.

## 12. Registers

System ports, decoded on A7–A0 (spec 3). The same registers are at register page offsets `0x000`–`0x00F`.

| Port | Name | Access | Bits | Reset | Description |
|------|------|--------|------|-------|-------------|
| `0x00` | INTCON | RW | MASTER (0) | `0x00` | All interrupts except the NMI on. Bits 7–1 read 0 |
| `0x01` | INTENA0 | Set/clear | SETCLR (7), sources 6–0 (6–0) | `0x00` | Enables of sources 0–6. Writing with SETCLR = 1 sets the bits written as 1; with SETCLR = 0 clears them; bits written as 0 are left alone. Reads give the enables, bit 7 reads 0 |
| `0x02` | INTENA1 | Set/clear | SETCLR (7), sources 13–7 (6–0) | `0x00` | As INTENA0, sources 7–13 |
| `0x03` | INTENA2 | Set/clear | SETCLR (7), sources 20–14 (6–0) | `0x00` | As INTENA0, sources 14–20 |
| `0x04` | INTPEND0 | R | Sources 6–0 (6–0) | `0x00` | Pending: requesting, enabled in INTENA, and MASTER on. Bit 7 reads 0 |
| `0x05` | INTPEND1 | R | Sources 13–7 (6–0) | `0x00` | As INTPEND0 |
| `0x06` | INTPEND2 | R | Sources 20–14 (6–0) | `0x00` | As INTPEND0 |
| `0x07` | INTRAW0 | R | Sources 6–0 (6–0) | `0x00` | Request lines, before INTENA and MASTER. Bit 7 reads 0 |
| `0x08` | INTRAW1 | R | Sources 13–7 (6–0) | `0x00` | As INTRAW0 |
| `0x09` | INTRAW2 | R | Sources 20–14 (6–0) | `0x00` | As INTRAW0 |
| `0x0A` | VECBASE | RW | VEC (7–1); bit 0 reads 0 | `0x00` | Low byte of the IM 2 table: source n uses VECBASE + 2n (section 5) |
| `0x0B` | SOFTINT | W | SET (0), CLR (1) | – | Write 1 to raise or clear the software interrupt. Reads `0x00` |
| `0x0C` | INTID | R | SRC (4–0) | `0x00` | Source given at the last acknowledge: 0–20, or 23 (NONE) for a spurious one. Not changed by the NMI. Bits 7–5 read 0 |
| `0x0D` | NMICON | RW | BUTTONEN (0), USBEN (1) | `0x03` | Allow each NMI source. Bits 7–2 read 0 |
| `0x0E` | NMISTAT | W1C | BUTTON (0), USB (1) | `0x00` | Which caused NMIs since last cleared; sticky. Bits 7–2 read 0 |
| `0x0F` | – | – | – | – | Reserved: reads `0xFF`, writes ignored (spec 3, rule 11) |

**Bit positions:** source n is in byte n div 7 (INTENA0/1/2, INTPEND0/1/2, INTRAW0/1/2), bit n mod 7. INTENA, INTPEND and INTRAW use the same positions, so a mask built for one works on the others.

**INTENA is not a multi-byte value.** Each byte takes effect when it is written, with no latch (an exception to spec 3's multi-byte rule). Never read INTENA, change a bit and write it back: write only the bits to change, with SETCLR. Two pieces of code, or a handler and the main program, can then each turn their own sources on and off safely.

**Names** (`fpga/regmap.def`, as retro68k's `hw.inc`): `INT_VBLANK` … `INT_SOFT` and `INT_NONE` = 23 are the source numbers; `INTB_name` is the bit within its byte and `INTR_name` the byte (0, 1 or 2), so a source is turned on with `INTENA0 + INTR_name` and `INTENA_SETCLR_M | (1 << INTB_name)`. `NMICON_BUTTONEN_M`, `NMISTAT_USB_M`, `SOFTINT_SET_M` and so on follow the same pattern.

**After reset:** MASTER off, every INTENA bit off, VECBASE `0x00`, SOFT not raised, both NMI sources on, NMISTAT clear. The boot ROM sets I, VECBASE and its table, chooses `IM 2`, enables the units and sources it wants, sets MASTER and then does `EI`.

**Example, IM 2 set-up and a VBLANK handler:**

```
        di
        ld   a,0xBF
        ld   i,a
        ld   a,0xD0
        out  (VECBASE),a              ; table at 0xBFD0
        im   2
        ld   bc,VIDSTAT_P             ; custom block port (spec 3, section 8)
        ld   a,VIDSTAT_VBLANK_M
        out  (c),a                    ; clear any old VBLANK flag
        ld   bc,VIDINTEN_P
        in   a,(c)
        or   VIDINTEN_VBLANK_M
        out  (c),a                    ; the unit's enable
        ld   a,INTENA_SETCLR_M|(1<<INTB_VBLANK)
        out  (INTENA0+INTR_VBLANK),a  ; the controller's enable
        ld   a,INTCON_MASTER_M
        out  (INTCON),a               ; the master enable
        ei
        ...
vbl:    push af
        push bc
        ld   bc,VIDSTAT_P
        ld   a,VIDSTAT_VBLANK_M
        out  (c),a                    ; clear the cause in the unit
        ...                           ; frame work
        pop  bc
        pop  af
        ei
        reti
```

## 13. FPGA resources

| Item | Resource |
|------|----------|
| Request registers, enables, 21-input priority encoder, vector adder, INTID, NMI request and debounce | Estimate 80–120 LUTs |
| Block RAM, DSP | None |
| Pins | Multiface button (`btn_multiface_n_i`, already in the KS3 pin list) |

## 14. Test plan

- **Vectors:** each source in use, raised by its unit (SOFT by software), gives VECBASE + 2n in IM 2 with several VECBASE values, including one that wraps; the CPU reaches the right handler.
- **Priority:** with several sources pending, they are served lowest number first; INTID agrees with the vector at every step.
- **IM 1:** `RST 38h` with INTID dispatch serves every source; a spurious acknowledge gives INTID = 23.
- **Request path:** INTRAW follows unit flag AND unit enable; INTPEND follows INTRAW AND INTENA AND MASTER; reserved sources read 0.
- **INTENA:** SETCLR = 1 sets only the bits written as 1, SETCLR = 0 clears only those; each byte acts alone; bit 7 reads 0.
- **Level-sensitive:** a request held off by `DI`, INTENA or MASTER is taken once allowed; a handler that does not clear its flag is entered again after `EI`; turning a source off and on with its flag set gives the interrupt at once.
- **Spurious:** a request cleared in the instruction during which /INT was sampled gives entry 23 and INTID = 23.
- **Frozen choice:** a lower-numbered source arriving during the acknowledge cycle does not change the vector driven in that cycle.
- **SOFTINT:** SET raises, CLR clears, the bit shows in INTRAW2; SOFT runs only after lower-numbered pending sources.
- **NMI:** the button and USB BREAK each give exactly one NMI per event and set their NMISTAT bit; a source turned off in NMICON gives none and sets nothing; MASTER and INTENA do not block it; two events before the response give one NMI; with NMICTL.EN = 1 no NMI reaches the CPU while INNMI is 1 and a request left pending gives one straight after `RETN`.
- **RETI:** handlers ending with `RET` and with `RETI` behave the same.
- **Latency:** in simulation, from a unit's flag to the first handler instruction, at each CPU speed; check against section 11.
- **ZEXDOC/ZEXALL** still pass with a timer interrupt running (handlers keep all registers).

## 15. Open points

| # | Item |
|---|------|
| I1 | Every unit spec must give its flags, enables and request line in retro68k's form: VIDSTAT/VIDINTEN (spec 4: VBLANK, LINE, the VIDERR bits including the sprites'), COPSTAT.IRQ and COPCON.IRQEN (spec 6), DMXINT/DMXINTEN (spec 14), TMRn_STAT and CTRL.IRQ (spec 9), SERIRQ/SERIRQEN (spec 10), KBIRQ/KBIRQEN (spec 12). The SD controller (spec 11) has no interrupt in version 1. The earlier draft's edge latches in the controller are gone |
| I2 | AUDIO (9) is reserved until spec 13 |
| I3 | GEOM (19): does the geometry unit need an interrupt at all? It finishes in under 1 µs (design plan, branch 10). Keep the number reserved until spec 15 decides |
| I4 | Check that tv80 samples /INT and runs the IM 2 acknowledge as a real Z80 does (design plan Q3), including the vector read timing in spec 1 |
| I5 | Should an IM 0 option drive `0xFF` (`RST 38h`) in the acknowledge, so IM 0 behaves like IM 1? Cheap, but nothing needs it now |
| I6 | Closed: IM 1 uses INTID (the source at the last acknowledge) instead of a separate "highest pending" port. INTHIGH is gone |
| I7 | Whether any accelerator-port pins should raise interrupts (retro68k I1); source 20 is free for it |
