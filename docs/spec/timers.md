# Spec 9: Timers

Status: **draft**

The timers give software a sense of time: a steady tick for an operating system or BBC BASIC's `TIME`, tempo for music players, timeouts, delays and measuring how long code takes. They follow retro68k's timers (its spec 12 and the "Interrupts and Timers" chapter of its guide), narrowed to 16 bits: a free-running time counter, four general timers with prescalers, and a watchdog. They are registers `0x20`–`0x4B` of the system page `0x00` (ports `0x2000`–`0x4B00`).

## 1. Summary

| Item | Value |
|------|-------|
| Time counter | TIME: 32 bits, counts microseconds from power-on, wraps after 71.6 minutes |
| General timers | 4 (TMR0–TMR3), each a 16-bit down counter with a 16-bit prescaler |
| What they count | The 100 MHz system clock ÷ (PRESCALE + 1), display lines, display frames, or the previous timer's underflow (chaining) |
| Modes | One-shot or repeating |
| At underflow | STAT.UNDER is set; an interrupt (TIMER0–TIMER3, spec 8) if CTRL.IRQ; a START of DMA engine channel CTRL.DMACH if CTRL.DMA (spec 14); a tick for the next timer |
| Watchdog | Resets the computer if software stops kicking it in time; RESETWHY.WATCHDOG says so afterwards (spec 7) |
| Registers | System page `0x00`, registers `0x20`–`0x4B` (`0x24`–`0x27` and `0x4C`–`0x4F` reserved): port = register × 256. Also at register page offsets `0x0020`–`0x004F` |
| Who can write them | The CPU only |
| Memory cycles | None |

The earlier draft's frame counter is FRAMECOUNT in the video block (spec 4).

## 2. Comparison with retro68k

| Feature | retro68k | retro-z80 | Why |
|---------|----------|-----------|-----|
| Time counter | TIME, 64 bits, 10 ns steps (100 MHz), never wraps in practice | TIME, 32 bits, 1 µs steps, wraps after 71.6 minutes | Narrowed: 4 registers instead of 8. 1 µs suits a Z80 (20 T-states at 20 MHz); finer timing uses a timer at SRC 0. A 48-bit TIME is deferred (open point T4) |
| Reading TIME | Reading TIMEHI captures; read high then low | Reading TIME0 (the low byte) captures; read low to high | Forced: spec 3's rule for 8-bit registers |
| Timer width | 32-bit RELOAD and COUNT | 16-bit RELOAD and COUNT | Narrowed (branch 9) |
| Prescaler | 16 bits, from 100 MHz | The same | – |
| Longest period | About 32 days | 42.9 seconds (one timer); longer by chaining | 16-bit counter |
| Line and frame ticks | The display beam | The same | – |
| DMA start | CTRL.DMA starts channel CTRL.DMACH (0–3), as a START write | The same | – |
| Register layout | 32-bit registers, timer n at `0x140 + n × 0x20` | 8 registers per timer, timer n at register `0x28 + n × 8` of the system page | Forced: 8-bit registers |
| WDTIME | 16 bits, ms | 16 bits, ms, two registers | – |
| WDKICK | Write `0x5A5A` (16 or 32 bits); a byte write is a wrong kick | Write `0x5A` (one byte) | Forced: 8-bit registers |
| Interrupt levels | Timers at level 6 by default | Fixed priority: TIMER0–TIMER3 are sources 11–14, after the video and DMA sources | Forced: one /INT line (spec 8) |
| Capture mode | Open point T2 | Deferred (open point T7) | As retro68k |

## 3. Time counter

- **TIME** is a 32-bit counter that adds 1 every microsecond (100 system clocks) from power-on. It cannot be written. Only power-on resets it; every other reset leaves it counting.
- It sits in four registers, TIME0 (bits 7–0) to TIME3 (bits 31–24). **Reading TIME0 captures all 32 bits** at that instant; TIME1–TIME3 then return the captured bytes. Read TIME0 first, then the others. Reading TIME1–TIME3 without a TIME0 read before them returns bytes of the last capture.
- There is one capture for the CPU. An interrupt handler that reads TIME0 between another program's TIME0 and TIME3 reads spoils that program's value. Read the time with interrupts disabled, or in one place only.
- The low 16 bits alone (TIME0, TIME1) wrap every 65.5 ms; all 32 every 71.6 minutes. Subtracting two readings gives the right interval across a wrap, as long as the interval is shorter than the wrap.
- Uses: timestamps, profiling ("how many microseconds did this routine take"), delays and timeouts that need no setting up.

```
; Read TIME into DEHL (D = bits 31-24). Interrupts off around the capture.
time:   di
        ld   bc,TIME0_P      ; C = 0x00, the system page
        in   l,(c)           ; captures all 32 bits
        inc  b
        in   h,(c)
        inc  b
        in   e,(c)
        inc  b
        in   d,(c)
        ei
        ret
```

Through the register page, `LD HL,(REGS+TIME0)` then `LD DE,(REGS+TIME2)` does the same: each `LD rr,(nn)` reads its low byte first.

## 4. General timers

### 4.1 How a timer works

Each timer has a 16-bit **COUNT** that goes down by 1 on each tick of its source. When COUNT is 0 and another tick arrives, the timer **underflows**:

- STAT.UNDER is set.
- If CTRL.IRQ is on, the timer raises its interrupt request (TIMER0–TIMER3, spec 8) while STAT.UNDER is set.
- If CTRL.DMA is on, the timer starts DMA engine channel CTRL.DMACH (section 4.5).
- The next timer gets a tick, if it is counting this one (SRC 3).
- In **repeating** mode (CTRL.REPEAT = 1), COUNT is loaded from **RELOAD** and counting goes on.
- In **one-shot** mode (CTRL.REPEAT = 0), the timer stops: CTRL.EN clears itself and COUNT stays at 0.

So a timer with COUNT = n underflows after n + 1 ticks, and a repeating timer with RELOAD = n underflows every n + 1 ticks, as on the Amiga's CIA. At SRC 0:

    period = (PRESCALE + 1) × (RELOAD + 1) ÷ 100 MHz

- **Writing COUNT** sets it at once (when COUNTH is written; spec 3's multi-byte rule).
- **Writing RELOAD** changes nothing until the next underflow, so a repeating timer's period can be changed while it runs without one odd period.
- **Reading COUNT:** reading COUNTL captures the whole count, and the next COUNTH read returns the high byte of the same capture. Each timer has its own capture. Read COUNTL first.
- **Starting:** when CTRL.EN goes from 0 to 1, the timer's prescaler starts again from the beginning, so the first period at SRC 0 is as long as the others. Line and frame ticks are shared by the machine, so at SRC 1 and 2 the first tick comes at the next line or frame start.
- **Stopping:** writing CTRL.EN = 0 stops the timer and keeps COUNT; setting EN again carries on from there.
- STAT.UNDER is set at every underflow, even with CTRL.IRQ off, so software can poll a timer without taking interrupts.

### 4.2 What a timer counts

| SRC | Ticks on | Tick period | Use |
|-----|----------|-------------|-----|
| 0 | The 100 MHz system clock ÷ (PRESCALE + 1) | 10 ns × (PRESCALE + 1) | Fixed rates. PRESCALE 99 gives exactly 1 µs; 27 gives 3.57 MHz, the T-state of the CPU's Spectrum speed; 5n − 1 gives the T-state of CPUSPEED n (spec 7) |
| 1 | The start of each line of the display beam (pixel 0; spec 4) | 32 µs (625 per frame) | Timing in lines, e.g. "every 10 lines" |
| 2 | The start of each frame (display beam (0, 0), the start of vertical blanking) | 20 ms | Counting frames, e.g. "every 3 frames" |
| 3 | The underflow of the previous timer (timer 0 counts timer 3) | – | Chaining |

PRESCALE matters only for SRC 0. Lines and frames come from the video timing, which runs whenever the system clock runs, even with every layer off. Both follow the display beam, the beam software sees (spec 4), so the line tick comes at the same moment as a LINE event would, and the frame tick with VIDSTAT.VBLANK.

### 4.3 Chaining

With SRC 3 a timer counts the underflows of the timer before it: timer 1 counts timer 0, timer 2 counts timer 1, timer 3 counts timer 2, and timer 0 counts timer 3. A timer counts the previous one's underflows whatever that timer's IRQ and DMA settings, but only while the previous timer is running.

Two chained timers make a 32-bit down counter: the low timer counts the clock with RELOAD `0xFFFF`, the high one counts its underflows. Read high, low, high again, and try again if the high count changed.

### 4.4 Examples

| Want | Setting |
|------|---------|
| 1 µs ticks | SRC 0, PRESCALE 99 |
| Operating system tick, 1000 Hz | SRC 0, PRESCALE 99, RELOAD 999, repeating, IRQ |
| BBC BASIC's `TIME`, 100 Hz | SRC 0, PRESCALE 99, RELOAD 9,999, repeating, IRQ |
| Music at 50 Hz, not tied to the frame | SRC 0, PRESCALE 99, RELOAD 19,999, repeating, IRQ |
| Music at 60 Hz | SRC 0, PRESCALE 99, RELOAD 16,666, repeating (59.999 Hz) |
| Time code in 3.57 MHz T-states | SRC 0, PRESCALE 27, COUNT 65,535, one-shot; ticks = 65,535 − COUNT (up to 18 ms) |
| Timeout of 2 seconds | SRC 0, PRESCALE 49,999 (0.5 ms), COUNT 3,999, one-shot; poll STAT.UNDER |
| Every 3 frames | SRC 2, RELOAD 2, repeating, IRQ |
| After n more lines | SRC 1, COUNT n − 1, one-shot |
| One interrupt a second | Timer 0 at 1000 Hz (above), timer 1 SRC 3, RELOAD 999, repeating, IRQ |
| Start a DMA chain every frame, 10 lines after the start | Timer 2 SRC 1, RELOAD 624, COUNT set at a VBLANK to 9, repeating, DMA, DMACH = the channel (CHDESC set first) |

**Setting up a timer:**

1. Stop it: write 0 to CTRL.
2. Clear STAT.UNDER (write 1), so an old underflow gives no interrupt.
3. Write PRESCALE, RELOAD and COUNT (low byte, then high byte).
4. For an interrupt, set up the handler and turn the source on in INTENA and INTCON.MASTER (spec 8).
5. Write CTRL with EN and the other bits wanted, in one write.

All of the timer's registers are in the system page, so C stays `0x00` and only B changes: `LD B,register` or `INC B` to the next.

```
; Timer 0: a 1000 Hz tick with an interrupt.
tick_on:
        ld   bc,TMR0_CTRL_P          ; C = 0x00, the system page
        xor  a
        out  (c),a                   ; 1. stop
        ld   b,TMR0_STAT
        ld   a,TMR_STAT_UNDER_M
        out  (c),a                   ; 2. no old underflow
        ld   b,TMR0_PRESCALEL
        ld   a,99
        out  (c),a                   ; 3. 100 MHz / 100 = 1 MHz
        inc  b
        xor  a
        out  (c),a                   ;    PRESCALEH: commits
        inc  b
        ld   a,low 999
        out  (c),a                   ;    RELOADL: 1000 ticks a period
        inc  b
        ld   a,high 999
        out  (c),a                   ;    RELOADH: commits
        inc  b
        ld   a,low 999
        out  (c),a                   ;    COUNTL: the first period too
        inc  b
        ld   a,high 999
        out  (c),a                   ;    COUNTH: commits
        ld   b,INTENA0+INTR_TIMER0
        ld   a,INTENA_SETCLR_M|(1<<INTB_TIMER0)
        out  (c),a                   ; 4. the controller's enable (spec 8)
        ld   b,INTCON
        ld   a,INTCON_MASTER_M
        out  (c),a
        ld   b,TMR0_CTRL
        ld   a,TMR_CTRL_EN_M|TMR_CTRL_REPEAT_M|TMR_CTRL_IRQ_M
        out  (c),a                   ; 5. go
        ret

tick:   push af                      ; the handler
        push bc
        ld   bc,TMR0_STAT_P
        ld   a,TMR_STAT_UNDER_M
        out  (c),a                   ; clear the cause
        ...
        pop  bc
        pop  af
        ei
        reti
```

### 4.5 Starting a DMA engine channel

With CTRL.DMA set, each underflow acts as a write of **START** to the CHCTRL of DMA engine channel **CTRL.DMACH** (0–3), exactly as a CPU write would (spec 14, section 9.4), as in retro68k. The channel loads the descriptor at its CHDESC and runs it; if the channel is busy, the start is ignored, as for a CPU write. Set up the descriptor and CHDESC first. This is independent of the interrupt: either, both or neither.

## 5. Watchdog

The watchdog resets the computer if software hangs.

- **WDTIME** sets the time allowed between kicks, in milliseconds, 1–65,535 (0 acts as 1). It is 1000 after reset. The time counts in whole milliseconds (100,000 system clocks), so the watchdog fires between WDTIME and WDTIME + 1 ms after the last kick.
- **WDCTRL.EN** turns it on and starts the time. Writing WDCTRL also restarts the time, like a kick. A new WDTIME is used from the next kick or WDCTRL write.
- Writing **`0x5A`** to **WDKICK** kicks it: the time starts again. Writing **any other value** resets the computer at once, so a program running wild is caught quickly. While the watchdog is off, WDKICK writes are ignored.
- If the time runs out, the computer gets a full reset (spec 7, section 3), with RESETWHY.WATCHDOG set. The FPGA keeps its configuration and the SRAM its contents.
- **WDCTRL.LOCK** makes WDCTRL and WDTIME read-only until the next reset, so a program cannot turn the watchdog off by mistake. Set LOCK in the same write as EN.
- The watchdog is off after every reset, so the boot ROM and simple programs need not know about it.

Kick from the main loop, not from an interrupt handler: interrupts usually keep running when the main program hangs, so a handler that kicks would hide the hang.

## 6. Registers

Registers of the system page `0x00` (spec 3): port = (register << 8) | `0x00`, written with `LD BC,port` then `OUT (C),r`, read with `IN r,(C)` or `LD A,register` then `IN A,(0x00)`. The same registers are at register page offsets `0x0020`–`0x004F`. Multi-byte values are low byte first; the high byte commits (spec 3, rule 2).

**Time counter:**

| Register | Port | Name | Access | Bits | Reset | Description |
|----------|------|------|--------|------|-------|-------------|
| `0x20` | `0x2000` | TIME0 | R | 7–0 | 0 at power-on | TIME bits 7–0. Reading captures all 32 bits |
| `0x21` | `0x2100` | TIME1 | R | 7–0 | | TIME bits 15–8, from the capture |
| `0x22` | `0x2200` | TIME2 | R | 7–0 | | TIME bits 23–16, from the capture |
| `0x23` | `0x2300` | TIME3 | R | 7–0 | | TIME bits 31–24, from the capture |
| `0x24`–`0x27` | `0x2400`–`0x2700` | – | – | – | – | Reserved (room for a wider TIME, open point T4) |

**General timers:** timer n (0–3) at register `0x28 + n × 8`: TMR0 `0x28` (ports `0x2800`–`0x2F00`), TMR1 `0x30` (`0x3000`–`0x3700`), TMR2 `0x38` (`0x3800`–`0x3F00`), TMR3 `0x40` (`0x4000`–`0x4700`).

| Offset | Name | Access | Bits | Reset | Description |
|--------|------|--------|------|-------|-------------|
| `+0` | TMR_CTRL | RW | EN (0), REPEAT (1), SRC (3–2), IRQ (4), DMA (5), DMACH (7–6) | `0x00` | Running (cleared by a one-shot underflow); repeating; source (section 4.2); interrupt request while UNDER; start DMA engine channel DMACH at underflow (section 4.5) |
| `+1` | TMR_PRESCALEL | RW | 7–0 | `0x00` | PRESCALE bits 7–0 (latched) |
| `+2` | TMR_PRESCALEH | RW | 7–0 | `0x00` | PRESCALE bits 15–8; commits. SRC 0 ticks at 100 MHz ÷ (PRESCALE + 1) |
| `+3` | TMR_RELOADL | RW | 7–0 | `0x00` | RELOAD bits 7–0 (latched) |
| `+4` | TMR_RELOADH | RW | 7–0 | `0x00` | RELOAD bits 15–8; commits. Loaded into COUNT at each underflow in repeating mode |
| `+5` | TMR_COUNTL | RW | 7–0 | `0x00` | Write: COUNT bits 7–0 (latched). Read: captures COUNT, returns bits 7–0 |
| `+6` | TMR_COUNTH | RW | 7–0 | `0x00` | Write: commits COUNT. Read: bits 15–8 of the capture |
| `+7` | TMR_STAT | W1C | UNDER (0) | `0x00` | The timer has underflowed; sticky. Bits 7–1 read 0 |

Names in `fpga/regmap.def`, as retro68k's `hw.inc`: `TMR0` … `TMR3` (`0x28` … `0x40`), `TMR_NUM` = 4, `TMR_SPAN` = 8, the offsets `TMR_CTRL` … `TMR_STAT`, the combined names `TMR0_CTRL`, `TMR2_COUNTL` and so on (register numbers), and `TMR0_CTRL_P` and so on (ports).

**Watchdog:**

| Register | Port | Name | Access | Bits | Reset | Description |
|----------|------|------|--------|------|-------|-------------|
| `0x48` | `0x4800` | WDCTRL | RW (lockable) | EN (0), LOCK (1) | `0x00` | On; settings read-only until reset. Writing restarts the time. Bits 7–2 read 0 |
| `0x49` | `0x4900` | WDTIMEL | RW (lockable) | 7–0 | `0xE8` | WDTIME bits 7–0 (latched) |
| `0x4A` | `0x4A00` | WDTIMEH | RW (lockable) | 7–0 | `0x03` | WDTIME bits 15–8; commits. Milliseconds between kicks (1000 after reset) |
| `0x4B` | `0x4B00` | WDKICK | W | 7–0 | – | `0x5A` restarts the time; any other value resets at once (while EN). Reads `0x00` |
| `0x4C`–`0x4F` | `0x4C00`–`0x4F00` | – | – | – | – | Reserved |

`WDKICK_MAGIC` = `0x5A`.

**After reset:** every timer stopped with all registers 0; watchdog off and unlocked, WDTIME 1000; TIME counting on (reset only at power-on).

**Interrupts:** each timer is its own source in the interrupt controller (spec 8): TIMER0–TIMER3, sources 11–14. A timer requests while STAT.UNDER and CTRL.IRQ are both set. The watchdog has no interrupt.

## 7. FPGA resources

| Item | Resource |
|------|----------|
| 32-bit time counter and capture, 1 µs and 1 ms dividers, 4 timers with prescalers and captures, watchdog | Estimate 250–350 LUTs |
| Block RAM, DSP | None |
| Lines out | TIMER0–TIMER3 request lines (spec 8); 4 DMA start lines, one per channel (spec 14); watchdog reset (spec 7) |

## 8. Test plan

- **Time counter:** counts once per 100 clocks; reading TIME0–TIME3 across a carry gives a consistent value, through ports and through the register page; TIME1–3 alone return the last capture; only power-on resets it.
- **Rates:** each SRC on each timer, several PRESCALE values; a repeating timer with RELOAD n underflows every n + 1 ticks; measured in simulation against the system clock (1 µs = 100 clocks, line = 3,200, frame = 2,000,000).
- **Beam:** the SRC 1 tick comes with the LINE event at the same display beam line, the SRC 2 tick with VIDSTAT.VBLANK.
- **One-shot:** underflows once, clears EN, leaves COUNT = 0.
- **Writes:** COUNT changes when COUNTH is written; RELOAD changes take effect at the next underflow only; the first SRC 0 period after EN is full length.
- **Reads:** COUNTL then COUNTH while the count crosses a high-byte boundary gives a consistent value.
- **Chaining:** each timer with SRC 3 counts the one before it (timer 0 counts timer 3), only while that timer runs; the 1-second example works.
- **Interrupts and polling:** UNDER is set with IRQ off; with IRQ on, each timer gives its own vector and the request drops when UNDER is cleared.
- **DMA start:** with CTRL.DMA, an underflow starts channel DMACH (each of 0–3) as a CPU START would, with no CPU work; it is ignored while that channel is busy.
- **Watchdog:** expiry resets and sets RESETWHY.WATCHDOG; a wrong kick value resets at once; kicks while off are ignored; LOCK blocks changes until reset; off after reset; fires between WDTIME and WDTIME + 1 ms after the last kick.

## 9. Open points

| # | Item |
|---|------|
| T1 | Closed: the capture-on-low-byte-read rule is spec 3's general rule (rule 4) |
| T2 | Closed: the frame counter moves to the video block as FRAMECOUNT (spec 4) |
| T3 | Closed: there is a watchdog, as in retro68k; RESETWHY.WATCHDOG is bit 1 (spec 7) |
| T4 | Deferred (design plan, branch 11): a 48-bit TIME (8.9 years) would fit in registers `0x24`–`0x25` |
| T5 | Closed: an underflow with CTRL.DMA acts as a START write to channel DMACH's CHCTRL, and is ignored while that channel is busy (spec 14, section 9.4), as retro68k |
| T6 | Real-time clock: the KS3 has a battery-backed clock on I2C; spec 7 has the I2C master (retro68k T1) |
| T7 | Deferred (design plan, branch 11): capture mode (save COUNT when a pin changes), as retro68k T2 |
