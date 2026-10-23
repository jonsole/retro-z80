# Spec 8: Interrupt controller

Status: **draft**

The interrupt controller gathers the interrupt requests of every unit and passes them to the Z80's /INT input. In **IM 2** it puts a vector byte on the bus during the interrupt-acknowledge cycle, so each source has its own handler. **IM 1** also works: the handler at `0x0038` reads a status register that names the highest pending source. The controller also drives /NMI, from the Multiface button and from a "break" sent over USB. Its registers are ports `0x18`–`0x1E` and `0xB8`.

## 1. Summary

| Item | Value |
|------|-------|
| Sources | 12 (numbers 0–11), one reserved for sound |
| Priority | Fixed: a lower source number goes first |
| Request kinds | Event sources are latched in the controller and cleared by writing 1; level sources follow their unit's line |
| IM 2 | Vector byte = INTVEC + 2 × source number, given in the acknowledge cycle |
| IM 1 | `RST 38h`; INTHIGH (port `0xB8`) gives the highest pending source |
| IM 0 | Not supported (section 6) |
| NMI | Multiface button and USB BREAK; jumps to `0x0066`, where the boot ROM's monitor page is paged in (spec 7, section 4.4) |
| Software interrupt | Source SOFT, set by a register write |
| RETI | Not needed by the controller (section 7) |
| Ports | `0x18`–`0x1E` and `0xB8` (8 ports). Port `0x1F` is the Kempston joystick (spec 12) |
| Memory cycles | None |

## 2. How an interrupt reaches the CPU

1. A unit raises its **request line**. For an **event** source (VBLANK, a timer running out, …) the controller latches the rising edge in INTREQ, so a one-clock pulse is enough and the event is never lost. For a **level** source (serial, keyboard) the INTREQ bit simply follows the line.
2. A source is **pending** when its INTREQ bit and its INTEN bit are both 1.
3. While any source is pending, the controller holds /INT low.
4. The Z80 samples /INT at the end of each instruction. If its IFF1 flag is set (after `EI`), it starts an **interrupt-acknowledge cycle** (an M1 cycle with /IORQ low instead of /MREQ, spec 1).
5. At the start of the acknowledge cycle (when the bus interface asks for the vector, spec 1, section 8.1) the controller picks the pending source with the lowest number and freezes the choice for the rest of the cycle. The bus interface's acknowledge pulse (int_ack) ends the freeze; it marks nothing as "in service". In IM 2 it drives the vector byte onto the data bus (section 4). In IM 1 the CPU ignores the bus and runs `RST 38h`.
6. The acknowledge does **not** clear anything. The handler clears the cause: it writes 1 to the source's INTREQ bit (event sources), or services the unit until its line drops (level sources).
7. If another source is still pending when the handler re-enables interrupts, /INT is still low and the CPU is interrupted again at once.

Requests are latched or level-sensitive, so no interrupt is lost while the CPU has interrupts disabled or while a source is disabled in INTEN. INTREQ latches events even when INTEN is 0, so software can also poll a source (for example a timer) without taking interrupts.

**Spurious acknowledge:** if no source is pending at the start of the acknowledge cycle (software cleared the last request in the instruction during which /INT was sampled), the controller gives source number 15, the "none" entry (vector INTVEC + 30). Its handler simply does `EI` and `RETI`.

## 3. Sources

| Number | Name | Kind | From | Cleared by |
|--------|------|------|------|------------|
| 0 | VBLANK | Event | Video: display beam reaches line 0, the start of vertical blank (spec 4) | Write 1 to INTREQL bit 0 |
| 1 | LINE | Event | Video: line compare (spec 4) | INTREQL bit 1 |
| 2 | COPPER | Event | Copper: interrupt instruction (spec 6) | INTREQL bit 2 |
| 3 | SPRITE | Event | Sprites: collision (spec 5) | INTREQL bit 3 |
| 4 | OVERRUN | Event | Video: fetch data late (VIDSTAT.OVERRUN, spec 4) | INTREQL bit 4 |
| 5 | TIMER0 | Event | Timer 0 ran out (spec 9) | INTREQL bit 5 |
| 6 | TIMER1 | Event | Timer 1 ran out (spec 9) | INTREQL bit 6 |
| 7 | SERRX | Level | USB serial: receive level or timeout (spec 10) | Read bytes from the receive FIFO |
| 8 | SERTX | Level | USB serial: room in the transmit FIFO (spec 10) | Fill the FIFO, or clear INTENH bit 0 |
| 9 | KEYBOARD | Level | PS/2 keyboard: byte waiting or error (spec 12) | Read the FIFO; clear the error flags |
| 10 | SOUND | Event | Reserved for spec 13. Reads 0 in version 1 | INTREQH bit 2 |
| 11 | SOFT | Event | Software (section 8) | INTREQH bit 3 |
| 12–14 | – | – | Reserved; read 0 | – |
| 15 | – | – | "None": used for a spurious acknowledge | – |

**Why this order:** the video sources come first, since a VBLANK or LINE handler that starts late shows on the screen. The timers come next, then the serial link (whose FIFOs absorb delay), then the keyboard, and the software interrupt last. As the priorities are fixed, a program that needs a different order can disable sources in INTEN while a handler runs (section 7).

**Units' own flags:** a unit may also keep a status flag for the same event (for example VIDSTAT.OVERRUN). The interrupt is cleared in INTREQ; the unit's flag has its own rules in its spec. Because the controller latches the rising edge, a unit may give either a one-clock pulse or a flag that stays high: each rise gives one request.

## 4. IM 2 vectors

The vector byte for source n is:

    vector = INTVEC + 2 × n        (INTVEC bits 4–0 are always 0, so there is no carry)

With the Z80's I register, the CPU reads the handler address from `I × 256 + vector`. The table therefore has 16 entries of 2 bytes (32 bytes), entry 15 being the spurious handler. INTVEC selects which 32-byte block of the page holds it.

Example: I = `0xBF`, INTVEC = `0xE0`: the table is at `0xBFE0`–`0xBFFF`; the VBLANK handler address is at `0xBFE0`, TIMER0's at `0xBFEA`, the spurious one at `0xBFFE`.

The vector is driven only in the acknowledge cycle; all other I/O reads of the bus are unaffected. Unused table entries (reserved sources 12–14) can point at the spurious handler.

## 5. IM 1

In IM 1 every interrupt runs `RST 38h`. The handler reads **INTHIGH**, which gives the number of the highest-priority pending source (the one IM 2 would choose), or `0x8F` when none is pending. A typical handler:

```
isr38:  push af
        push hl
        in   a,(0xB8)        ; INTHIGH: source number, bit 7 = none
        add  a,a             ; × 2 (0x8F becomes 0x1E: the "none" entry)
        ld   l,a
        ld   h,high(table)   ; table aligned to 32 bytes
        ...                  ; jump through the table, as IM 2 would
```

Reading INTHIGH clears nothing. The handler still clears the source as in section 2.

INTHIGH is at `0xB8`, apart from the other interrupt ports, because `0x1F` is the Kempston joystick port (spec 12). Like the rest of the controller it is outside the copper's reach (`0x30`–`0x9F`). It can also be read through the register page at offset `0x00B8`.

## 6. IM 0

IM 0 is not supported. The controller does not know which mode the CPU is in, so it always drives the IM 2 vector byte in the acknowledge cycle. In IM 0 the Z80 would execute that byte as an instruction, which for most vector values is not a useful one. The Z80 starts in IM 0 after reset, but with interrupts disabled and every INTEN bit 0, so no interrupt is ever taken until software has chosen IM 1 or IM 2. Software must set `IM 1` or `IM 2` before the first `EI`.

## 7. EI, DI and RETI

- `DI` and `EI` control the Z80's own IFF1 flag; the controller does not see them. /INT stays low while a source is pending, so a request that comes in under `DI` is taken at the first chance after `EI`.
- On entry to a handler the Z80 clears IFF1, so no other interrupt can come in until the handler does `EI`. A handler must clear its source **before** `EI`, or it is entered again at once.
- **Nesting:** the controller has no "in service" state. If a handler does `EI` early, any pending enabled source can interrupt it, including one of lower priority. To allow only higher-priority sources, the handler clears the INTEN bits of the lower ones first and restores them before it returns.
- **RETI** is not needed. Zilog's daisy-chained peripherals watch the bus for `RETI` to end their "in service" state; this controller has none, so it ignores `RETI`. Handlers may end with `EI` then `RETI` (the usual habit, and harmless) or `EI` then `RET`.
- **HALT:** a pending interrupt (or NMI) wakes the CPU from `HALT` as usual.

## 8. Software interrupt

Writing INTREQH with bit 7 = 1 and bit 3 = 1 sets the SOFT request. It is then pending like any event source when INTENH bit 3 is set, and is cleared by writing 1 to INTREQH bit 3 (with bit 7 = 0). SOFT has the lowest priority, so a high-priority handler (for example VBLANK) can do the urgent part and set SOFT to do the rest after every other pending source has been served. The handler must have cleared its own source and done `EI` for the SOFT handler to run before it returns; otherwise SOFT runs straight after it.

## 9. NMI

The Z80's /NMI is edge-triggered and cannot be masked by `DI`. It jumps to `0x0066`; the handler ends with `RETN`. It is meant for a debug monitor that takes control of a hung program.

| NMI source | Event | Flag |
|------------|-------|------|
| Multiface button | A press of the KS3's Multiface (NMI) button, debounced in the FPGA (about 10 ms of agreement, as in retro68k) | INTREQH bit 4 (NMIBTN) |
| USB break | The BREAK control command from the PC (spec 10, section 3) | INTREQH bit 5 (NMIUSB) |

- Each source can be turned off in INTENH (bits 4 and 5, both on after reset). An event from a source that is off is ignored and sets no flag.
- An enabled event sets its flag. The controller holds /NMI low while either flag is set, so the CPU sees one falling edge when the first flag is set. The handler clears the flags it handled (write 1) and reads INTREQH again before `RETN`; a flag that is still set means a second event came in during the handler. When both flags are clear, /NMI goes high and the next event gives a new edge.
- **Monitor paging:** when the CPU takes the NMI, the bus interface switches window 0 to the boot ROM's monitor page (`0x3FF`, write page NONE) just before the fetch at `0x0066`, saves the old window-0 pages, and restores them after the handler's `RETN` (spec 1, section 8.2; ports NMICTL `0xB9` and `0xBA`–`0xBD`, spec 7, section 4.4). So the monitor comes up whatever the program has mapped into window 0, and a program needs no handler of its own.
- With NMICTL.EN = 0 (it is 1 after reset) window 0 is not changed, and the handler at `0x0066` is whatever window 0 holds. A program that turns paging off must put its own handler (or a jump to the monitor) there.
- The monitor clears the flags in INTREQH before `RETN`, as any NMI handler does.
- **No nesting in NMI mode:** while NMICTL.INNMI is 1 the controller holds /NMI high, so the monitor is never interrupted by a second NMI. Events still set their flags. When `RETN` ends NMI mode, a flag that is still set (an event that came in after the monitor cleared the flags) pulls /NMI low and gives a new NMI at once. With EN = 0, INNMI stays 0 and NMIs behave as described above.
- The KS3's DivMMC button is not an interrupt source; spec 7 covers it.

## 10. Latency

| Step | T-states |
|------|----------|
| Finish the current instruction | up to 23 (for example `INC (IX+d)`); `LDIR`, `INIR`, `OTIR` and the other repeats accept interrupts between iterations |
| After `EI` | the next instruction always runs first |
| IM 2 acknowledge, push PC, read the table | 19 |
| IM 1 acknowledge, push PC | 13 |
| NMI, push PC | 11 |
| Controller | the edge latch and /INT add 1–2 system clocks (under 40 ns) |

| CPU speed | IM 2 worst case (23 + 19 T) | IM 1 worst case (23 + 13 T), before the dispatch code |
|-----------|-----------------------------|----------------------------------------|
| 28 MHz | 1.5 µs | 1.3 µs |
| 14 MHz | 3.0 µs | 2.6 µs |
| 7 MHz | 6.0 µs | 5.1 µs |
| 3.5 MHz | 12.0 µs | 10.3 µs |

Code that runs with interrupts disabled adds its own time. A 576p line is 32 µs, 896 T-states at 28 MHz. Effects that must land on an exact pixel belong to the copper (spec 6), not to a LINE handler.

## 11. Registers

| Port | Name | Bits | Description |
|------|------|------|-------------|
| `0x18` | INTREQL | 7–0: sources 7–0 | Read: requests of sources 0–7 (latched events; the live line for SERRX), whether enabled or not. Write: each bit written as 1 clears that event; 0 leaves it. Writes to bit 7 (SERRX, a level) are ignored |
| `0x19` | INTREQH | 3–0: sources 11–8; 4: NMIBTN; 5: NMIUSB; 7: SET (write only) | Read: requests of sources 8–11 and the NMI flags; bits 7–6 read 0. Write with SET = 0: each bit written as 1 clears that event or NMI flag. Write with SET = 1: each bit written as 1 is set; only SOFT (bit 3) can be set this way, other bits ignore it. Bits 0–1 (SERTX, KEYBOARD) are levels and ignore writes |
| `0x1A` | INTENL | 7–0: sources 7–0 | Enables of sources 0–7. 0 after reset |
| `0x1B` | INTENH | 3–0: sources 11–8; 4: NMIBTNEN; 5: NMIUSBEN | Enables of sources 8–11 (0 after reset) and of the NMI sources (1 after reset). Bits 7–6 read 0 |
| `0x1C` | INTPENDL | 7–0 | Read only: INTREQL AND INTENL |
| `0x1D` | INTPENDH | 3–0 | Read only: INTREQH AND INTENH for sources 8–11; bits 7–4 read 0 |
| `0x1E` | INTVEC | 7–5 | IM 2 vector base. Bits 4–0 read 0, writes to them are ignored. `0x00` after reset |
| `0xB8` | INTHIGH | 3–0: source; 7: NONE | Read only: the highest-priority pending source, or `0x8F` when none is pending. Writes are ignored |

Port `0x1F` is not part of the controller: it reads joystick 1 (Kempston, spec 12). No interrupt port is reachable by the copper.

`fpga/regmap.def` names each bit: `INTB_VBLANK` … `INTB_SOFT` (bit numbers within their port), and `INTN_VBLANK` … `INTN_SOFT` (source numbers).

**After reset:** all requests cleared, all sources disabled, NMI sources enabled, INTVEC = `0x00`. The boot ROM sets I, INTVEC and its table, chooses `IM 2`, enables the sources it wants and then does `EI`.

**Example, IM 2 set-up and a VBLANK handler:**

```
        ld   a,0xBF
        ld   i,a
        ld   a,0xE0
        out  (0x1E),a        ; INTVEC: table at 0xBFE0
        im   2
        ld   a,1             ; INTB_VBLANK
        out  (0x1A),a        ; INTENL
        ei
        ...
vbl:    push af
        ld   a,1
        out  (0x18),a        ; clear VBLANK
        ...                  ; frame work
        pop  af
        ei
        reti
```

## 12. FPGA resources

| Item | Resource |
|------|----------|
| Edge latches, enables, 12-input priority encoder, vector mux, NMI debounce and flags | Estimate 80–120 LUTs |
| Block RAM, DSP | None |
| Pins | Multiface button (`btn_multiface_n_i`, already in the KS3 pin list) |

## 13. Test plan

- **Vectors:** each source, set by its unit (or SOFT by software), gives INTVEC + 2n in IM 2 with several INTVEC values; the CPU reaches the right handler.
- **Priority:** with several sources pending, they are served lowest number first; INTHIGH agrees with the IM 2 choice at every step.
- **IM 1:** `RST 38h` with INTHIGH dispatch serves every source; INTHIGH reads `0x8F` with nothing pending; it answers at port `0xB8` and register page offset `0x00B8`, and port `0x1F` gives joystick 1, not INTHIGH.
- **Latching:** a one-clock event pulse while the source is disabled, or under `DI`, is taken after enabling; level sources follow their lines and ignore write-1-to-clear.
- **Clearing:** writing 1 clears only the bits written; writing 0 changes nothing; SET in INTREQH sets SOFT only.
- **Spurious:** a request cleared in the instruction during which /INT was sampled gives the "none" vector (INTVEC + 30).
- **Frozen choice:** a higher source arriving during the acknowledge cycle does not change the vector driven in that cycle.
- **NMI:** no NMI edge reaches the CPU while INNMI is 1, and a flag left set gives one straight after `RETN`; the handler runs from the monitor page with NMICTL.EN = 1 and from window 0's own page with EN = 0; the button and USB BREAK each give one edge per event; a second event during the handler stays visible in INTREQH and gives a new NMI only after the flags are cleared; turned-off sources are ignored.
- **RETI:** handlers ending with `RET` and with `RETI` behave the same.
- **Latency:** in simulation, measure from a request to the first handler instruction at each CPU speed; check it against section 10.
- **ZEXDOC/ZEXALL** still pass with a timer interrupt running (handlers preserve all registers).

## 14. Open points

| # | Item |
|---|------|
| I1 | Specs 4, 5 and 6 must agree that VBLANK, LINE, COPPER, SPRITE and OVERRUN are event lines latched here and cleared in INTREQL (their own status flags, if any, are separate) |
| I2 | SOUND (source 10) is reserved until spec 13; it may become a level source |
| I3 | Should the SET mode of INTREQH also be able to set event sources 0–6 (useful for tests)? It needs a SET bit, which INTREQL has no room for |
| I4 | Check that tv80 samples /INT and runs the IM 2 acknowledge as a real Z80 does (open question Q3), including the vector read timing in spec 1 |
| I5 | Should an IM 0 option drive `0xFF` (`RST 38h`) in the acknowledge, so IM 0 behaves like IM 1? Cheap, but nothing needs it now |
| I6 | Spec 1, section 8.1 says the acknowledge pulse "marks that source as being served". In this spec it only ends the frozen choice: there is no in-service state and nothing is cleared by the acknowledge (section 7). Spec 1 should be worded to match |
