# Spec 9: Timers

Status: **draft**

The timers give software a sense of time: a steady tick for an operating system or BASIC's `TIME`, tempo for music players, timeouts, delays, and measuring how long code takes. There are two 16-bit timers and a 16-bit frame counter, in ports `0x20`–`0x27`.

## 1. Summary

| Item | Value |
|------|-------|
| General timers | 2 (TIMER0, TIMER1), each a 16-bit down counter |
| Tick sources | 1 µs, 3.5 MHz (timer 0) or timer 0 running out (timer 1), video line (32 µs), video frame (20 ms) |
| Modes | One-shot or repeating |
| When a timer runs out | Interrupt source TIMER0 or TIMER1 (spec 8), also readable by polling |
| Frame counter | 16 bits, counts video frames (50 Hz) from reset; wraps after about 22 minutes |
| Ports | `0x20`–`0x27` (8 ports) |
| Memory cycles | None |

## 2. How a timer works

Each timer has a 16-bit **COUNT** and a 16-bit **RELOAD**. While the timer runs (CTRL.EN = 1), COUNT goes down by 1 on each tick of its source. When a tick finds COUNT at 0, the timer **runs out**:

- COUNT is loaded from RELOAD.
- The timer gives a one-clock pulse on its request line, which sets its INTREQL bit in the interrupt controller (spec 8: TIMER0 is bit 5, TIMER1 bit 6).
- **Repeating mode** (CTRL.REPEAT = 1): it goes on counting. A timer with RELOAD = n runs out every n + 1 ticks.
- **One-shot mode:** CTRL.EN clears itself, so the timer stops with COUNT = RELOAD, ready to be started again with the same time.
- Timer 0 running out also counts as a tick for timer 1, if timer 1's source is "timer 0" (chaining).

**Writing the value** (TnL then TnH, the multi-byte latch rule of spec 3) sets **both RELOAD and COUNT** at the moment TnH is written. On a running timer this restarts the current period from the new value. A repeating timer's period can therefore be changed at any time; the period in progress is cut short or made longer once.

**Reading the value** gives the current COUNT. Because COUNT can change between two reads, **reading TnL captures the whole 16-bit COUNT**: TnL returns the low byte and the next TnH read returns the high byte of the same capture. Read TnL first. Each timer has its own capture; an interrupt handler that reads the same timer between a program's TnL and TnH reads spoils that program's pair, so read a timer in one place only, or with interrupts disabled. Reading TnH without a TnL read before it returns the high byte of the last capture.

**First tick:** the 1 µs, 3.5 MHz, line and frame ticks are shared by the whole machine and are not restarted when a timer starts. The first tick after starting can come at any time up to one tick period later, so a one-shot set to n ticks runs out after between n and n + 1 tick periods.

## 3. Tick sources

| SRC | Timer 0 counts | Timer 1 counts | Tick period | Longest time with 16 bits |
|-----|----------------|----------------|-------------|---------------------------|
| 0 | 1 µs tick | 1 µs tick | 1 µs (56 system clocks) | 65.5 ms |
| 1 | Video line | Video line | 32 µs | 2.1 s |
| 2 | Video frame | Video frame | 20 ms | 21.8 minutes |
| 3 | 3.5 MHz tick (56 MHz ÷ 16) | Timer 0 running out | 285.7 ns (timer 0) | 18.7 ms (timer 0) |

- The **1 µs tick** comes from the machine's timebase (56 system clocks); the same tick paces the serial receive timeout (spec 10).
- The **3.5 MHz tick** is the rate of a Spectrum's T-states. It does not follow the CPU speed setting: it is a fixed 56 MHz ÷ 16, useful for porting Spectrum code that times things in T-states, and for measuring code finely.
- The **line tick** comes at the start of each 576p line of the display beam (beam pixel 0, spec 4), as seen in the system clock domain. There are 625 per frame, 31,250 per second. A 288-line layer's line is two of these ticks.
- The **frame tick** comes at the start of each frame (line 0, the start of vertical blank), the same moment as the VBLANK request (spec 8). 50 per second.
- Line and frame ticks follow the video timing, which runs whenever the system clock runs, even if every layer is off.
- **Chaining:** timer 1 with SRC 3 counts timer 0 running out. Timer 0 at 1 µs with RELOAD 999 and timer 1 counting it gives a 1 ms tick with a 16-bit count of milliseconds; timer 0 at 3.5 MHz and RELOAD 65,535 with timer 1 counting it gives a 32-bit cycle counter (wraps after about 20 minutes).

## 4. Frame counter

FRAME counts frame ticks from reset, up by 1 each frame, and wraps from 65,535 to 0. It is read with the same capture rule as the timers (FRAMEL first) and can be written (FRAMEL then FRAMEH; the new value takes effect when FRAMEH is written), for example to start it from 0 at the beginning of a game. It never interrupts; VBLANK does that.

Uses: a frame-based clock for games ("wait until frame N"), a seed for random numbers, checking whether a game loop missed a frame, and BASIC's `TIME` (in 1/50 s, with software extending it past 16 bits).

## 5. Examples

| Want | Setting |
|------|---------|
| 100 Hz tick for BBC BASIC's `TIME` | Timer 0: SRC 0 (1 µs), value 9,999, repeating; enable TIMER0 in INTENL |
| Music at 50 Hz in step with the picture | VBLANK (spec 8), or timer 1: SRC 2, value 0, repeating |
| Music at a tempo not tied to the frame, e.g. 60 Hz | Timer 0: SRC 0, value 16,666, repeating (16,667 µs, 59.999 Hz) |
| Timeout of 2 seconds | Timer 1: SRC 1 (line), value 62,499, one-shot (62,500 × 32 µs = 2.000 s) |
| Delay of 100 µs | Timer 0: SRC 0, value 99, one-shot; poll INTREQL bit 5, or take the interrupt |
| Time a routine in Spectrum T-states | Timer 0: SRC 3, value 65,535, one-shot; start, run the routine, stop, read: ticks = 65,535 − COUNT |
| Long timeout (minutes) | Timer 1: SRC 2 (frame); or timer 0 at 1 ms chained into timer 1 |

A one-shot used for polling is started, then software watches its INTREQL bit (or CTRL.EN going to 0). The INTREQL bit is set even when the interrupt is disabled in INTENL, and is cleared by writing 1 to it.

**Example, a 100 Hz interrupt:**

```
        ld   a,low(9999)
        out  (0x20),a        ; T0L (latched)
        ld   a,high(9999)
        out  (0x21),a        ; T0H: RELOAD = COUNT = 9999
        ld   a,0x03          ; EN, REPEAT, SRC 0
        out  (0x22),a        ; T0CTRL
        in   a,(0x1A)
        or   0x20            ; INTB_TIMER0
        out  (0x1A),a        ; INTENL
```

## 6. Registers

| Port | Name | Bits | Description |
|------|------|------|-------------|
| `0x20` | T0L | 7–0 | Timer 0 value, low byte. Write: to the latch. Read: captures COUNT, returns its low byte |
| `0x21` | T0H | 7–0 | High byte. Write: RELOAD = COUNT = latch and this byte. Read: high byte of the capture |
| `0x22` | T0CTRL | EN (0), REPEAT (1), SRC (3–2) | Running; repeating mode; tick source (section 3). Bits 7–4 read 0. EN clears itself when a one-shot runs out |
| `0x23` | T1L | 7–0 | Timer 1 value, low byte (as T0L) |
| `0x24` | T1H | 7–0 | Timer 1 value, high byte (as T0H) |
| `0x25` | T1CTRL | EN (0), REPEAT (1), SRC (3–2) | As T0CTRL; SRC 3 = timer 0 running out |
| `0x26` | FRAMEL | 7–0 | Frame counter, low byte. Write: to the latch. Read: captures FRAME, returns its low byte |
| `0x27` | FRAMEH | 7–0 | High byte. Write: FRAME = latch and this byte. Read: high byte of the capture |

**After reset:** both timers stopped, CTRL = 0, COUNT = RELOAD = 0; FRAME = 0 and counting.

**A timer stopped with EN = 0** keeps its COUNT; setting EN = 1 again carries on from there. A value written while stopped is loaded into COUNT and RELOAD as usual.

**A timer with value 0** in repeating mode runs out on every tick (every 1 µs at SRC 0).

## 7. FPGA resources

| Item | Resource |
|------|----------|
| Two 16-bit counters with reload, capture latches, frame counter, tick logic | Estimate 100–150 LUTs |
| Block RAM, DSP | None |
| Request lines | TIMER0, TIMER1 (one-clock pulses) to spec 8 |

## 8. Test plan

- **Rates:** each source on each timer: a repeating timer with value n runs out every n + 1 ticks; measure in simulation against the system clock (1 µs = 56 clocks, line = 1792 clocks, frame = 1,120,000 clocks).
- **One-shot:** runs out once, clears EN, leaves COUNT = RELOAD; starting again gives the same time.
- **Writes:** the value takes effect only when the high byte is written; writing restarts a running timer from the new value.
- **Reads:** reading L then H while the counter crosses a high-byte boundary gives a consistent value; H alone returns the last capture.
- **Chaining:** timer 1 with SRC 3 counts timer 0's run-outs; the 32-bit cycle counter example works.
- **Interrupts and polling:** each run-out sets its INTREQL bit with the interrupt disabled; enabled, it gives the TIMER0 or TIMER1 vector.
- **Frame counter:** counts one per VBLANK, wraps at 65,535, write and read with the latch and capture rules.

## 9. Open points

| # | Item |
|---|------|
| T1 | The capture-on-low-byte-read rule for counters should be stated in spec 3 as a general rule for registers that change by themselves (beam position, frame counter) |
| T2 | Should the frame counter be 24 bits (93 hours)? It needs one more port, and the range has none left |
| T3 | A watchdog, as in retro68k? Left out for version 1 to keep within 8 ports; it could go in the system ports (spec 7) |
| T4 | Real-time clock: the KS3 has a battery-backed clock on I2C (retro68k spec 7). Whether retro-z80 gets an I2C master is for spec 7 |
