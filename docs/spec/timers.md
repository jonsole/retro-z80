# Spec 9: Timers

Status: **draft**

The timers give software a sense of time: a steady tick for an operating system or BBC BASIC's `TIME`, tempo for music players, timeouts, delays and measuring how long code takes. They follow retro68k's timers (its spec 12 and the "Interrupts and Timers" chapter of its guide), narrowed to 16 bits: a free-running time counter, four general timers with prescalers, and a watchdog. They are system ports `0x20`–`0x4B`.

## 1. Summary

| Item | Value |
|------|-------|
| Time counter | TIME: 32 bits, counts microseconds from power-on, wraps after 71.6 minutes |
| General timers | 4 (TMR0–TMR3), each a 16-bit down counter with a 16-bit prescaler |
| What they count | The 56 MHz system clock ÷ (PRESCALE + 1), video lines, video frames, or the previous timer's underflow (chaining) |
| Modes | One-shot or repeating |
| At underflow | STAT.UNDER is set; an interrupt (TIMER0–TIMER3, spec 8) if CTRL.IRQ; a start of the DMA engine if CTRL.DMA (spec 14); a tick for the next timer |
| Watchdog | Resets the computer if software stops kicking it in time; RESETWHY.WATCHDOG says so afterwards (spec 7) |
| Ports | `0x20`–`0x4B` (`0x24`–`0x27` and `0x4C`–`0x4F` reserved). Also at register page offsets `0x020`–`0x04F` |
| Who can write them | The CPU only |
| Memory cycles | None |

The earlier draft's frame counter is now FRAMECOUNT in the video block (spec 4).

## 2. Comparison with retro68k

| Feature | retro68k | retro-z80 | Why |
|---------|----------|-----------|-----|
| Time counter | TIME, 64 bits, 10 ns steps (100 MHz), never wraps in practice | TIME, 32 bits, 1 µs steps, wraps after 71.6 minutes | Narrowed: 4 ports instead of 8. 1 µs suits a Z80 (28 T-states at 28 MHz); finer timing uses a timer at SRC 0 |
| Reading TIME | Reading TIMEHI captures; read high then low | Reading TIME0 (the low byte) captures; read low to high | Forced: spec 3's rule for 8-bit ports |
| Timer width | 32-bit RELOAD and COUNT | 16-bit RELOAD and COUNT | Narrowed (branch 9) |
| Prescaler | 16 bits, from 100 MHz | 16 bits, from 56 MHz | The system clock is 56 MHz. PRESCALE 55 gives exactly 1 µs, 15 gives 3.5 MHz (Spectrum T-states) |
| Longest period | About 32 days | 76.7 seconds (one timer); longer by chaining | 16-bit counter |
| DMA start | CTRL.DMA starts channel CTRL.DMACH (0–3) | CTRL.DMA starts the DMA engine; DMACH (7–6) reserved | The DMA engine has one channel (spec 14) |
| Register layout | 32-bit registers, timer n at `0x140 + n × 0x20` | 8 ports per timer, timer n at `0x28 + n × 8` | Forced: 8-bit ports |
| WDTIME | 16 bits, ms | 16 bits, ms, two ports | – |
| WDKICK | Write `0x5A5A` (16 or 32 bits); a byte write is a wrong kick | Write `0x5A` (one byte) | Forced: 8-bit ports |
| Interrupt levels | Timers at level 6 by default | Fixed priority: TIMER0–TIMER3 are sources 11–14, after the video and DMA sources | Forced: one /INT line (spec 8) |

## 3. Time counter

- **TIME** is a 32-bit counter that adds 1 every microsecond (56 system clocks) from power-on. It cannot be written. Only power-on resets it; every other reset leaves it counting.
- It sits in four ports, TIME0 (bits 7–0) to TIME3 (bits 31–24). **Reading TIME0 captures all 32 bits** at that instant; TIME1–TIME3 then return the captured bytes. Read TIME0 first, then the others. Reading TIME1–TIME3 without a TIME0 read before them returns bytes of the last capture.
- There is one capture for the whole machine. An interrupt handler that reads TIME0 between another program's TIME0 and TIME3 reads spoils that program's value. Read the time with interrupts disabled, or in one place only.
- The low 16 bits alone (TIME0, TIME1) wrap every 65.5 ms; all 32 every 71.6 minutes. Subtracting two readings gives the right interval across a wrap, as long as the interval is shorter than the wrap.
- Uses: timestamps, profiling ("how many microseconds did this routine take"), delays and timeouts that need no setting up.

```
; Read TIME into DEHL (D = bits 31-24). Interrupts off around the capture.
time:   di
        in   a,(TIME0)       ; captures all 32 bits
        ld   l,a
        in   a,(TIME1)
        ld   h,a
        in   a,(TIME2)
        ld   e,a
        in   a,(TIME3)
        ld   d,a
        ei
        ret
```

## 4. General timers

### 4.1 How a timer works

Each timer has a 16-bit **COUNT** that goes down by 1 on each tick of its source. When COUNT is 0 and another tick arrives, the timer **underflows**:

- STAT.UNDER is set.
- If CTRL.IRQ is on, the timer raises its interrupt request (TIMER0–TIMER3, spec 8) while STAT.UNDER is set.
- If CTRL.DMA is on, the timer starts the DMA engine (section 4.5).
- The next timer gets a tick, if it is counting this one (SRC 3).
- In **repeating** mode (CTRL.REPEAT = 1), COUNT is loaded from **RELOAD** and counting goes on.
- In **one-shot** mode (CTRL.REPEAT = 0), the timer stops: CTRL.EN clears itself and COUNT stays at 0.

So a timer with COUNT = n underflows after n + 1 ticks, and a repeating timer with RELOAD = n underflows every n + 1 ticks, as on the Amiga's CIA. At SRC 0:

    period = (PRESCALE + 1) × (RELOAD + 1) ÷ 56 MHz

- **Writing COUNT** sets it at once (when COUNTH is written; spec 3's multi-byte rule).
- **Writing RELOAD** changes nothing until the next underflow, so a repeating timer's period can be changed while it runs without one odd period.
- **Reading COUNT:** reading COUNTL captures the whole count, and the next COUNTH read returns the high byte of the same capture. Each timer has its own capture. Read COUNTL first.
- **Starting:** when CTRL.EN goes from 0 to 1, the timer's prescaler starts again from the beginning, so the first period at SRC 0 is as long as the others. Line and frame ticks are shared by the machine, so at SRC 1 and 2 the first tick comes at the next line or frame start.
- **Stopping:** writing CTRL.EN = 0 stops the timer and keeps COUNT; setting EN again carries on from there.
- STAT.UNDER is set at every underflow, even with CTRL.IRQ off, so software can poll a timer without taking interrupts.

### 4.2 What a timer counts

| SRC | Ticks on | Tick period | Use |
|-----|----------|-------------|-----|
| 0 | The 56 MHz system clock ÷ (PRESCALE + 1) | 17.9 ns × (PRESCALE + 1) | Fixed rates. PRESCALE 55 gives exactly 1 µs; 15 gives 3.5 MHz, a Spectrum's T-state |
| 1 | The start of each line of the draw beam (pixel 0; spec 4, section 3.3) | 32 µs (625 per frame) | Timing in lines, e.g. "every 10 lines" |
| 2 | The start of each frame (draw beam (0, 0), the start of vertical blanking) | 20 ms | Counting frames, e.g. "every 3 frames" |
| 3 | The underflow of the previous timer (timer 0 counts timer 3) | – | Chaining |

PRESCALE matters only for SRC 0. Lines and frames come from the video timing, which runs whenever the system clock runs, even with every layer off. Both follow the draw beam, the beam software sees (spec 4, section 3.3), so the line tick comes at the same moment as a LINE event would, and the frame tick with VIDSTAT.VBLANK.

### 4.3 Chaining

With SRC 3 a timer counts the underflows of the timer before it: timer 1 counts timer 0, timer 2 counts timer 1, timer 3 counts timer 2, and timer 0 counts timer 3. A timer counts the previous one's underflows whatever that timer's IRQ and DMA settings, but only while the previous timer is running.

Two chained timers make a 32-bit down counter: the low timer counts the clock with RELOAD `0xFFFF`, the high one counts its underflows. Read high, low, high again, and try again if the high count changed.

### 4.4 Examples

| Want | Setting |
|------|---------|
| 1 µs ticks | SRC 0, PRESCALE 55 |
| Operating system tick, 1000 Hz | SRC 0, PRESCALE 55, RELOAD 999, repeating, IRQ |
| BBC BASIC's `TIME`, 100 Hz | SRC 0, PRESCALE 55, RELOAD 9,999, repeating, IRQ |
| Music at 50 Hz, not tied to the frame | SRC 0, PRESCALE 55, RELOAD 19,999, repeating, IRQ |
| Music at 60 Hz | SRC 0, PRESCALE 55, RELOAD 16,666, repeating (59.999 Hz) |
| Time code in Spectrum T-states | SRC 0, PRESCALE 15, COUNT 65,535, one-shot; ticks = 65,535 − COUNT |
| Timeout of 2 seconds | SRC 0, PRESCALE 55,999 (1 ms), COUNT 1,999, one-shot; poll STAT.UNDER |
| Every 3 frames | SRC 2, RELOAD 2, repeating, IRQ |
| After n more lines | SRC 1, COUNT n − 1, one-shot |
| One interrupt a second | Timer 0 at 1000 Hz (above), timer 1 SRC 3, RELOAD 999, repeating, IRQ |

**Setting up a timer:**

1. Stop it: write 0 to CTRL.
2. Clear STAT.UNDER (write 1), so an old underflow gives no interrupt.
3. Write PRESCALE, RELOAD and COUNT (low byte, then high byte).
4. For an interrupt, set up the handler and turn the source on in INTENA and INTCON.MASTER (spec 8).
5. Write CTRL with EN and the other bits wanted, in one write.

```
; Timer 0: a 1000 Hz tick with an interrupt.
tick_on:
        xor  a
        out  (TMR0_CTRL),a           ; 1. stop
        ld   a,TMR_STAT_UNDER_M
        out  (TMR0_STAT),a           ; 2. no old underflow
        ld   a,55
        out  (TMR0_PRESCALEL),a      ; 3. 56 MHz / 56 = 1 MHz
        xor  a
        out  (TMR0_PRESCALEH),a
        ld   a,low(999)
        out  (TMR0_RELOADL),a        ;    1000 ticks a period
        ld   a,high(999)
        out  (TMR0_RELOADH),a
        ld   a,low(999)
        out  (TMR0_COUNTL),a         ;    the first period too
        ld   a,high(999)
        out  (TMR0_COUNTH),a
        ld   a,INTENA_SETCLR_M|(1<<INTB_TIMER0)
        out  (INTENA0+INTR_TIMER0),a ; 4. the controller's enable (spec 8)
        ld   a,INTCON_MASTER_M
        out  (INTCON),a
        ld   a,TMR_CTRL_EN_M|TMR_CTRL_REPEAT_M|TMR_CTRL_IRQ_M
        out  (TMR0_CTRL),a           ; 5. go
        ret

tick:   push af                      ; the handler
        ld   a,TMR_STAT_UNDER_M
        out  (TMR0_STAT),a           ; clear the cause
        ...
        pop  af
        ei
        reti
```

### 4.5 Starting the DMA engine

With CTRL.DMA set, each underflow starts the DMA engine, exactly as a CPU write of RUN to its CHCTRL would (spec 14, section 9.4). Set up the engine's job first. This is independent of the interrupt: either, both or neither. CTRL.DMACH (bits 7–6) is reserved for more channels and must be 0. A start while the engine is busy is handled as spec 14 says for a CPU start.

## 5. Watchdog

The watchdog resets the computer if software hangs.

- **WDTIME** sets the time allowed between kicks, in milliseconds, 1–65,535 (0 acts as 1). It is 1000 after reset. The time counts in whole milliseconds, so the watchdog fires between WDTIME and WDTIME + 1 ms after the last kick.
- **WDCTRL.EN** turns it on and starts the time. Writing WDCTRL also restarts the time, like a kick. A new WDTIME is used from the next kick or WDCTRL write.
- Writing **`0x5A`** to **WDKICK** kicks it: the time starts again. Writing **any other value** resets the computer at once, so a program running wild is caught quickly. While the watchdog is off, WDKICK writes are ignored.
- If the time runs out, the computer gets a full reset (spec 7, section 3), with RESETWHY.WATCHDOG set. The FPGA keeps its configuration and the SRAM its contents.
- **WDCTRL.LOCK** makes WDCTRL and WDTIME read-only until the next reset, so a program cannot turn the watchdog off by mistake. Set LOCK in the same write as EN.
- The watchdog is off after every reset, so the boot ROM and simple programs need not know about it.

Kick from the main loop, not from an interrupt handler: interrupts usually keep running when the main program hangs, so a handler that kicks would hide the hang.

## 6. Registers

System ports, decoded on A7–A0 (spec 3). The same registers are at register page offsets `0x020`–`0x04F`. Multi-byte values are low byte first; the high byte commits (spec 3).

**Time counter:**

| Port | Name | Access | Bits | Reset | Description |
|------|------|--------|------|-------|-------------|
| `0x20` | TIME0 | R | 7–0 | 0 at power-on | TIME bits 7–0. Reading captures all 32 bits |
| `0x21` | TIME1 | R | 7–0 | | TIME bits 15–8, from the capture |
| `0x22` | TIME2 | R | 7–0 | | TIME bits 23–16, from the capture |
| `0x23` | TIME3 | R | 7–0 | | TIME bits 31–24, from the capture |
| `0x24`–`0x27` | – | – | – | – | Reserved (room for a wider TIME, open point T4) |

**General timers:** timer n (0–3) at `0x28 + n × 8`: TMR0 `0x28`, TMR1 `0x30`, TMR2 `0x38`, TMR3 `0x40`.

| Offset | Name | Access | Bits | Reset | Description |
|--------|------|--------|------|-------|-------------|
| `+0` | TMR_CTRL | RW | EN (0), REPEAT (1), SRC (3–2), IRQ (4), DMA (5), DMACH (7–6) | `0x00` | Running (cleared by a one-shot underflow); repeating; source (section 4.2); interrupt request while UNDER; start the DMA engine at underflow; DMACH reserved, write 0 |
| `+1` | TMR_PRESCALEL | RW | 7–0 | `0x00` | PRESCALE bits 7–0 (latched) |
| `+2` | TMR_PRESCALEH | RW | 7–0 | `0x00` | PRESCALE bits 15–8; commits. SRC 0 ticks at 56 MHz ÷ (PRESCALE + 1) |
| `+3` | TMR_RELOADL | RW | 7–0 | `0x00` | RELOAD bits 7–0 (latched) |
| `+4` | TMR_RELOADH | RW | 7–0 | `0x00` | RELOAD bits 15–8; commits. Loaded into COUNT at each underflow in repeating mode |
| `+5` | TMR_COUNTL | RW | 7–0 | `0x00` | Write: COUNT bits 7–0 (latched). Read: captures COUNT, returns bits 7–0 |
| `+6` | TMR_COUNTH | RW | 7–0 | `0x00` | Write: commits COUNT. Read: bits 15–8 of the capture |
| `+7` | TMR_STAT | W1C | UNDER (0) | `0x00` | The timer has underflowed; sticky. Bits 7–1 read 0 |

Names in `fpga/regmap.def`, as retro68k's `hw.inc`: `TMR0` … `TMR3` (`0x28` … `0x40`), `TMR_NUM` = 4, `TMR_SPAN` = 8, the offsets `TMR_CTRL` … `TMR_STAT`, and the combined names `TMR0_CTRL`, `TMR2_COUNTL` and so on.

**Watchdog:**

| Port | Name | Access | Bits | Reset | Description |
|------|------|--------|------|-------|-------------|
| `0x48` | WDCTRL | RW (lockable) | EN (0), LOCK (1) | `0x00` | On; settings read-only until reset. Writing restarts the time. Bits 7–2 read 0 |
| `0x49` | WDTIMEL | RW (lockable) | 7–0 | `0xE8` | WDTIME bits 7–0 (latched) |
| `0x4A` | WDTIMEH | RW (lockable) | 7–0 | `0x03` | WDTIME bits 15–8; commits. Milliseconds between kicks (1000 after reset) |
| `0x4B` | WDKICK | W | 7–0 | – | `0x5A` restarts the time; any other value resets at once (while EN). Reads `0x00` |
| `0x4C`–`0x4F` | – | – | – | – | Reserved |

`WDKICK_MAGIC` = `0x5A`.

**After reset:** every timer stopped with all registers 0; watchdog off and unlocked, WDTIME 1000; TIME counting on (reset only at power-on).

**Interrupts:** each timer is its own source in the interrupt controller (spec 8): TIMER0–TIMER3, sources 11–14. A timer requests while STAT.UNDER and CTRL.IRQ are both set. The watchdog has no interrupt.

## 7. FPGA resources

| Item | Resource |
|------|----------|
| 32-bit time counter and capture, 1 µs and 1 ms dividers, 4 timers with prescalers and captures, watchdog | Estimate 250–350 LUTs |
| Block RAM, DSP | None |
| Lines out | TIMER0–TIMER3 request lines (spec 8); DMA start (spec 14); watchdog reset (spec 7) |

## 8. Test plan

- **Time counter:** counts once per 56 clocks; reading TIME0–TIME3 across a carry gives a consistent value; TIME1–3 alone return the last capture; only power-on resets it.
- **Rates:** each SRC on each timer, several PRESCALE values; a repeating timer with RELOAD n underflows every n + 1 ticks; measured in simulation against the system clock (1 µs = 56 clocks, line = 1792, frame = 1,120,000).
- **One-shot:** underflows once, clears EN, leaves COUNT = 0.
- **Writes:** COUNT changes when COUNTH is written; RELOAD changes take effect at the next underflow only; the first SRC 0 period after EN is full length.
- **Reads:** COUNTL then COUNTH while the count crosses a high-byte boundary gives a consistent value.
- **Chaining:** each timer with SRC 3 counts the one before it (timer 0 counts timer 3), only while that timer runs; the 1-second example works.
- **Interrupts and polling:** UNDER is set with IRQ off; with IRQ on, each timer gives its own vector and the request drops when UNDER is cleared.
- **DMA start:** with CTRL.DMA, an underflow starts the DMA engine as a CPU START would, with no CPU work.
- **Watchdog:** expiry resets and sets RESETWHY.WATCHDOG; a wrong kick value resets at once; kicks while off are ignored; LOCK blocks changes until reset; off after reset; fires between WDTIME and WDTIME + 1 ms after the last kick.

## 9. Open points

| # | Item |
|---|------|
| T1 | Closed: the capture-on-low-byte-read rule is spec 3's general rule (rule 4) |
| T2 | Closed: the frame counter moves to the video block as FRAMECOUNT (spec 4) |
| T3 | Closed: there is a watchdog, as in retro68k; RESETWHY.WATCHDOG is bit 1 (spec 7) |
| T4 | TIME at 32 bits wraps after 71.6 minutes. A 48-bit TIME (8.9 years) would fit in `0x24`–`0x25`. Is it worth two more ports and a wider capture? |
| T5 | Closed: spec 14, section 9.4: an underflow with CTRL.DMA acts as a write of RUN to CHCTRL, and is ignored while the engine is busy |
| T6 | Real-time clock: the KS3 has a battery-backed clock on I2C; spec 7 has the I2C master (retro68k T1) |
| T7 | Capture mode (save COUNT when a pin changes), as retro68k T2 |
