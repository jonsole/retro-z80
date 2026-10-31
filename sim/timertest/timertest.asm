; Timer test ROM (ticket #17): the timers, TIME and the watchdog (spec 9)
; on the whole machine, with the CPU's capture in the bus interface (spec 3,
; rule 4). Runs in place of the boot ROM (tb.v +rom=timertest.hex) and
; prints "PASS" or "FAIL nn" (the number of the first check that failed,
; in hex).
;
; Rates are measured against TIME, which counts microseconds on its own
; divider, so a timer and TIME check each other. sim/timers measures every
; rate to the clock; here the machine's own ticks are used: the system clock,
; the display beam's lines (32 us) and its frame start (with VIDSTAT.VBLANK).
;
; The capture: a value read low byte first while it changes must be one the
; counter really had. Timer 1 counts at 100 MHz (a new value every clock),
; and a fixed loop reads it 64 times, through ports and through the register
; page; every step between two readings must be the same. Without the
; capture the high byte, read live about 145 clocks after the low byte,
; would be one less whenever the low byte was below that.
;
; The watchdog resets the machine, so the run has three parts, told apart
; by RESETWHY and a phase byte in SRAM (which a reset keeps):
;   power-on   every timer check; then the watchdog: kicks while off,
;              LOCK, kicks in time, and then no more kicks, while the time
;              is stored in SRAM over and over
;   phase 1    after the watchdog's reset: RESETWHY.WATCHDOG, the reset
;              came 2-3 ms after the last kick, the watchdog is off and
;              unlocked, TIME ran on; then a wrong kick value
;   phase 2    after that reset: RESETWHY.WATCHDOG again; PASS

        DEVICE  NOSLOT64K
        include "hw.inc"

; SRAM page 2 (window 4); a reset keeps it
LOG     equ     0x8000                  ; interrupt log
LOGP    equ     0x80F0                  ; the next free byte of the log
CHK     equ     0x80F2                  ; the check running
PHASE   equ     0x80F3                  ; 0x5A, then the phase (see above)
KICKT   equ     0x80F4                  ; TIME at the last kick (4 bytes)
LASTT   equ     0x80F8                  ; TIME, stored over and over (4 bytes)
TABLE   equ     0x8100                  ; IM 2 table: I = 0x81, VECBASE 0
BUF     equ     0x8200                  ; readings, 2 bytes each
W3      equ     0x6000                  ; window 3, mapped to the register page
PG_REGS equ     0x3F8                   ; the register page (MMU page)

PHMARK  equ     0x5A

    MACRO WREG xp, xv                   ; write xv to register port xp (A, B, C changed)
        ld      bc,xp
        ld      a,xv
        out     (c),a
    ENDM
    MACRO RCHK xp, xv                   ; fail unless register port xp reads xv
        ld      bc,xp
        in      a,(c)
        cp      xv
        jp      nz,fail
    ENDM
    MACRO RCHKM xp, xm, xv              ; fail unless register port xp, masked by xm, reads xv
        ld      bc,xp
        in      a,(c)
        and     xm
        cp      xv
        jp      nz,fail
    ENDM
    MACRO CHECK xn                      ; the check that follows is number xn
        ld      a,xn
        ld      (CHK),a
    ENDM
    MACRO RANGE xlo, xhi                ; fail unless xlo <= HL <= xhi (BC, DE changed)
        ld      bc,xlo
        ld      de,xhi
        call    range
        jp      c,fail
    ENDM
    MACRO TSET xn, xc, xp, xr, xk       ; set up timer xn: CTRL, PRESCALE, RELOAD, COUNT
        ld      a,TMR0 + (xn) * TMR_SPAN
        call    tseti
        db      xc
        dw      xp, xr, xk
    ENDM
    MACRO TSTOP xn                      ; stop timer xn
        WREG    (TMR0 + (xn) * TMR_SPAN + TMR_CTRL) << 8, 0
    ENDM
    MACRO PERIOD xn                     ; HL = microseconds between two underflows of timer xn
        ld      a,TMR0 + (xn) * TMR_SPAN + TMR_STAT
        call    period
    ENDM
    MACRO LCHK xl                       ; fail unless the log holds list xl
        ld      hl,xl
        call    chklog
        jp      nz,fail
    ENDM

EN      equ     TMR_CTRL_EN_M
REP     equ     TMR_CTRL_REPEAT_M
IRQ     equ     TMR_CTRL_IRQ_M
SRC0    equ     0 << TMR_CTRL_SRC_B     ; the system clock, prescaled
SRC1    equ     1 << TMR_CTRL_SRC_B     ; lines
SRC2    equ     2 << TMR_CTRL_SRC_B     ; frames
SRC3    equ     3 << TMR_CTRL_SRC_B     ; the previous timer

        ORG     0x0000

reset:  di
        jp      start

start:  ld      sp,0x0000
        WREG    SERCON_P, SERCON_EN_M | SERCON_CTLEN_M
        ld      bc,RESETWHY_P
        in      a,(c)
        cp      RESETWHY_WATCHDOG_M
        jp      z,afterwd
        CHECK   1                       ; check 1: RESETWHY = POWER
        cp      RESETWHY_POWER_M
        jp      nz,fail
        xor     a
        ld      (PHASE),a
        WREG    VIDCON_P, VIDCON_EN_M   ; the beam on: line ticks, and a frame at about 18 ms

        ; ---- reset values (section 6)
        CHECK   2                       ; check 2: every timer register 0
        ld      bc,TMR0_CTRL_P
.rv:    in      a,(c)
        or      a
        jp      nz,fail
        inc     b
        ld      a,b
        cp      TMR3_STAT + 1
        jr      c,.rv
        CHECK   3                       ; check 3: the watchdog; reserved registers
        RCHK    WDCTRL_P, 0
        RCHK    WDTIME0_P, 0xE8
        RCHK    WDTIME1_P, 0x03
        RCHK    WDKICK_P, 0
        RCHK    0x2400, 0xFF
        RCHK    0x2700, 0xFF
        RCHK    0x4C00, 0xFF

        ; ---- byte writes: each byte alone
        CHECK   4                       ; check 4
        WREG    TMR2_RELOAD1_P, 0x12
        RCHK    TMR2_RELOAD1_P, 0x12
        RCHK    TMR2_RELOAD0_P, 0
        WREG    TMR2_RELOAD0_P, 0x34
        RCHK    TMR2_RELOAD1_P, 0x12
        WREG    TMR3_COUNT0_P, 0x56
        RCHK    TMR3_COUNT0_P, 0x56
        RCHK    TMR3_COUNT1_P, 0
        WREG    TMR3_COUNT1_P, 0x78
        RCHK    TMR3_COUNT0_P, 0x56
        RCHK    TMR3_COUNT1_P, 0x78

        ; ---- SRC 0 against TIME: each timer, 500 us; timer 0 at 1 ms too
        CHECK   5                       ; check 5: timer 0, PRESCALE 99, RELOAD 499
        TSET    0, EN|REP|SRC0, 99, 499, 499
        PERIOD  0
        RANGE   497, 503
        TSTOP   0
        CHECK   6                       ; check 6: timer 1
        TSET    1, EN|REP|SRC0, 99, 499, 499
        PERIOD  1
        RANGE   497, 503
        TSTOP   1
        CHECK   7                       ; check 7: timer 2
        TSET    2, EN|REP|SRC0, 99, 499, 499
        PERIOD  2
        RANGE   497, 503
        TSTOP   2
        CHECK   8                       ; check 8: timer 3
        TSET    3, EN|REP|SRC0, 99, 499, 499
        PERIOD  3
        RANGE   497, 503
        TSTOP   3
        CHECK   9                       ; check 9: PRESCALE 27 (3.57 MHz), RELOAD 3571: 1000.16 us
        TSET    0, EN|REP|SRC0, 27, 3571, 3571
        PERIOD  0
        RANGE   997, 1004
        TSTOP   0
        CHECK   10                      ; check 10: PRESCALE 0x1387 (50 us), RELOAD 9: 500 us
        TSET    1, EN|REP|SRC0, 4999, 9, 9
        PERIOD  1
        RANGE   497, 503
        TSTOP   1

        ; ---- SRC 1: the beam's lines, 32 us each
        CHECK   0x11                    ; check 11: timer 2, RELOAD 9: 320 us
        TSET    2, EN|REP|SRC1, 0, 9, 9
        PERIOD  2
        RANGE   317, 323
        TSTOP   2
        CHECK   0x12                    ; check 12: timer 0, RELOAD 0: every line
        TSET    0, EN|REP|SRC1, 0, 0, 0
        PERIOD  0
        RANGE   29, 35
        TSTOP   0

        ; ---- one-shot: one underflow, EN cleared, COUNT left at 0
        CHECK   0x13                    ; check 13
        TSET    3, EN|SRC0, 99, 0, 99   ; 100 us
        ld      a,TMR3_STAT
        call    waitund
        RCHK    TMR3_CTRL_P, SRC0
        RCHK    TMR3_COUNT0_P, 0
        RCHK    TMR3_COUNT1_P, 0
        ld      hl,300
        call    waitus
        RCHK    TMR3_STAT_P, 0          ; no second underflow

        ; ---- RELOAD changes at the next underflow, not before
        CHECK   0x14                    ; check 14: 100 us, then RELOAD 199
        TSET    1, EN|REP|SRC0, 99, 99, 99
        ld      a,TMR1_STAT
        call    waitund
        call    time16
        push    hl
        WREG    TMR1_RELOAD0_P, 199
        ld      a,TMR1_STAT
        call    waitund
        call    time16
        pop     de
        or      a
        sbc     hl,de
        RANGE   97, 103                 ; the period running ends as it was
        PERIOD  1
        RANGE   197, 203                ; then the new one
        TSTOP   1

        ; ---- stopping keeps COUNT; EN again carries on
        CHECK   0x15                    ; check 15
        TSET    2, EN|SRC0, 99, 0, 0x1234
        TSTOP   2
        ld      bc,TMR2_COUNT0_P
        in      l,(c)
        inc     b
        in      h,(c)
        push    hl
        ld      hl,50
        call    waitus
        ld      bc,TMR2_COUNT0_P
        in      l,(c)
        inc     b
        in      h,(c)
        pop     de
        or      a
        sbc     hl,de
        jp      nz,fail                 ; stopped: the same count
        ex      de,hl
        RANGE   0x1230, 0x1234          ; ... and close to where it started
        WREG    TMR2_CTRL_P, EN|SRC0
        ld      hl,30
        call    waitus
        TSTOP   2
        ld      bc,TMR2_COUNT0_P
        in      l,(c)
        inc     b
        in      h,(c)
        RANGE   0x1200, 0x1216          ; it went on from there

        ; ---- chaining: each timer counts the one before (timer 0 counts timer 3)
        CHECK   0x16                    ; check 16: timer 1 counts timer 0
        TSET    1, EN|REP|SRC3, 0, 2, 2
        TSET    0, EN|REP|SRC0, 99, 99, 99
        PERIOD  1
        RANGE   297, 303
        CHECK   0x17                    ; check 17: nothing while timer 0 is stopped
        TSTOP   0
        call    chain_still1
        TSTOP   1
        CHECK   0x18                    ; check 18: timer 2 counts timer 1
        TSET    2, EN|REP|SRC3, 0, 2, 2
        TSET    1, EN|REP|SRC0, 99, 99, 99
        PERIOD  2
        RANGE   297, 303
        TSTOP   1
        TSTOP   2
        CHECK   0x19                    ; check 19: timer 3 counts timer 2
        TSET    3, EN|REP|SRC3, 0, 2, 2
        TSET    2, EN|REP|SRC0, 99, 99, 99
        PERIOD  3
        RANGE   297, 303
        TSTOP   2
        TSTOP   3
        CHECK   0x1A                    ; check 1A: timer 0 counts timer 3
        TSET    0, EN|REP|SRC3, 0, 2, 2
        TSET    3, EN|REP|SRC0, 99, 99, 99
        PERIOD  0
        RANGE   297, 303
        TSTOP   3
        TSTOP   0
        CHECK   0x1B                    ; check 1B: the 1-second example, scaled: 10 us x 50
        TSET    1, EN|REP|SRC3, 0, 49, 49
        TSET    0, EN|REP|SRC0, 99, 9, 9
        PERIOD  1
        RANGE   497, 503
        TSTOP   0
        TSTOP   1

        ; ---- the frame start: SRC 2, with VIDSTAT.VBLANK (the first frame
        ; starts about 18 ms after VIDCON.EN, about when this runs)
        CHECK   0x40                    ; check 40: SRC 2 ticks at the frame start
        WREG    VIDSTAT_P, VIDSTAT_VBLANK_M
        TSET    2, EN|SRC2, 0, 0, 0
        ld      a,TMR2_STAT
        call    waitund
        CHECK   0x41                    ; check 41: the tick came with VBLANK, in the vertical blank
        RCHKM   VIDSTAT_P, VIDSTAT_VBLANK_M | VIDSTAT_INVBLANK_M, VIDSTAT_VBLANK_M | VIDSTAT_INVBLANK_M ; LINE may be set too
        RCHK    TMR2_CTRL_P, SRC2       ; one-shot: stopped

        ; ---- TIME and the capture (spec 3, rule 4)
        CHECK   0x20                    ; check 20: TIME1 after TIME0 comes from its capture, however late
        ld      bc,TIME0_P
        in      a,(c)                   ; capture
        inc     b
        in      e,(c)                   ; E = the capture's TIME1, read at once
        ld      hl,460
        call    waitus_nocap            ; 600 us, reading no capturing register
        ld      bc,TIME1_P
        in      a,(c)
        cp      e
        jp      nz,fail
        CHECK   0x21                    ; check 21: a fresh TIME has moved on by 600 us (TIME1 by 2 or 3)
        ld      bc,TIME0_P
        in      a,(c)
        inc     b
        in      a,(c)
        sub     e
        cp      2
        jp      c,fail
        cp      4
        jp      nc,fail
        CHECK   0x22                    ; check 22: a COUNT0 read replaces the capture: TIME1 then reads live
        ld      bc,TIME0_P
        in      a,(c)
        inc     b
        in      e,(c)                   ; E = TIME1 now
        ld      bc,TMR0_COUNT0_P
        in      a,(c)                   ; the capture now holds COUNT
        ld      hl,460
        call    waitus_nocap
        ld      bc,TIME1_P
        in      a,(c)
        sub     e                       ; live: moved on by 2 or 3
        cp      2
        jp      c,fail
        cp      4
        jp      nc,fail
        CHECK   0x23                    ; check 23: COUNT1 after COUNT0 comes from the capture, however late
        TSET    1, EN|REP|SRC0, 0, 0xFFFF, 0xFFFF       ; 100 MHz
        ld      bc,TMR1_COUNT0_P
        in      a,(c)
        inc     b
        in      e,(c)                   ; E = the capture's high byte
        ld      hl,460
        call    waitus_nocap            ; the count moves on by 60,000
        ld      bc,TMR1_COUNT1_P
        in      a,(c)
        cp      e
        jp      nz,fail
        CHECK   0x24                    ; check 24: ... and a fresh read differs
        ld      bc,TMR1_COUNT0_P
        in      a,(c)
        inc     b
        in      a,(c)
        cp      e
        jp      z,fail

        ; Every reading of a counter changing every clock, low byte first, is
        ; a value it had: the steps between readings of a fixed loop are equal
        CHECK   0x25                    ; check 25: through ports
        ld      hl,BUF
        ld      e,64
.cp:    ld      bc,TMR1_COUNT0_P
        in      a,(c)
        ld      (hl),a
        inc     hl
        inc     b
        in      a,(c)
        ld      (hl),a
        inc     hl
        dec     e
        jr      nz,.cp
        call    steps
        jp      nz,fail
        RANGE   250, 500                ; 80 T-states, 400 clocks
        ; The register page in window 3
        ld      hl,PG_REGS
        ld      bc,MMU3_0_P
        out     (c),l
        inc     b
        out     (c),h
        CHECK   0x26                    ; check 26: through the register page, LD rr,(nn)
        ld      hl,BUF
        ld      b,64
.cr:    ld      de,(W3 + TMR1_COUNT0)
        ld      (hl),e
        inc     hl
        ld      (hl),d
        inc     hl
        djnz    .cr
        call    steps
        jp      nz,fail
        RANGE   250, 500                ; 59 T-states, 295 clocks
        TSTOP   1
        CHECK   0x27                    ; check 27: TIME through the register page, the same as by ports
        ld      hl,(W3 + TIME0)         ; TIME0 captures, TIME1 from the capture
        ld      de,(W3 + TIME2)         ; TIME2 and TIME3 from the capture
        ld      (STEP),hl
        ld      (BUF),de
        call    time32                  ; DEHL, by ports
        ld      bc,(BUF)
        ex      de,hl
        or      a
        sbc     hl,bc                   ; the high halves the same
        jp      nz,fail
        ex      de,hl
        ld      bc,(STEP)
        or      a
        sbc     hl,bc
        RANGE   0, 10                   ; the low halves a few us apart
        CHECK   0x28                    ; check 28: ports and the register page share the capture
        ld      bc,TIME0_P
        in      a,(c)
        inc     b
        in      e,(c)
        ld      hl,460
        call    waitus_nocap
        ld      a,(W3 + TIME1)
        cp      e
        jp      nz,fail
        ld      a,(W3 + TIME0)          ; a fresh capture, through the page
        ld      a,(W3 + TIME1)
        cp      e
        jp      z,fail
        ld      hl,0x0040               ; window 3 back to its reset page (0x040)
        ld      bc,MMU3_0_P
        out     (c),l
        inc     b
        out     (c),h

        ; ---- interrupts: TIMER0-3 (spec 8, sources 11-14), each its own vector
        call    settab
        im      2
        WREG    INTCON_P, INTCON_MASTER_M
        WREG    INTENA0_P + (INTR_TIMER0 << 8), INTENA_SETCLR_M | (1 << INTB_TIMER0)
        WREG    INTENA0_P + (INTR_TIMER1 << 8), INTENA_SETCLR_M | (1 << INTB_TIMER1)
        WREG    INTENA0_P + (INTR_TIMER2 << 8), INTENA_SETCLR_M | (1 << INTB_TIMER2)
        WREG    INTENA0_P + (INTR_TIMER3 << 8), INTENA_SETCLR_M | (1 << INTB_TIMER3)
        CHECK   0x30                    ; check 30: UNDER with IRQ off: no request
        TSET    0, EN|SRC0, 0, 0, 9
        ld      hl,5
        call    waitus
        RCHK    TMR0_STAT_P, TMR_STAT_UNDER_M
        RCHK    INTRAW0_P + (INTR_TIMER0 << 8), 0
        CHECK   0x31                    ; check 31: IRQ on: the request, while UNDER
        WREG    TMR0_CTRL_P, IRQ|SRC0
        RCHK    INTRAW0_P + (INTR_TIMER0 << 8), 1 << INTB_TIMER0
        WREG    TMR0_STAT_P, TMR_STAT_UNDER_M
        RCHK    INTRAW0_P + (INTR_TIMER0 << 8), 0
        CHECK   0x32                    ; check 32: timer 0's interrupt, by its own vector
        call    logclr
        TSET    0, EN|IRQ|SRC0, 99, 0, 19
        ei
        halt
        di
        LCHK    exp_t0
        CHECK   0x33                    ; check 33: timer 1
        call    logclr
        TSET    1, EN|IRQ|SRC0, 99, 0, 19
        ei
        halt
        di
        LCHK    exp_t1
        CHECK   0x34                    ; check 34: timer 2
        call    logclr
        TSET    2, EN|IRQ|SRC0, 99, 0, 19
        ei
        halt
        di
        LCHK    exp_t2
        CHECK   0x35                    ; check 35: timer 3
        call    logclr
        TSET    3, EN|IRQ|SRC0, 99, 0, 19
        ei
        halt
        di
        LCHK    exp_t3
        CHECK   0x36                    ; check 36: all four at once: in source order
        call    logclr
        TSET    3, EN|IRQ|SRC0, 0, 0, 9
        TSET    2, EN|IRQ|SRC0, 0, 0, 9
        TSET    1, EN|IRQ|SRC0, 0, 0, 9
        TSET    0, EN|IRQ|SRC0, 0, 0, 9
        ld      hl,5
        call    waitus
        ei
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        di
        LCHK    exp_all
        CHECK   0x37                    ; check 37: a repeating 1 kHz tick: 5 interrupts in 5.5 ms
        call    logclr
        TSET    2, EN|REP|IRQ|SRC0, 99, 999, 999
        ei
        ld      hl,5500
        call    waitus
        di
        TSTOP   2
        LCHK    exp_rep
        WREG    INTCON_P, 0

        ; ---- the watchdog (section 5)
        CHECK   0x50                    ; check 50: off: kicks of any value are ignored
        WREG    WDKICK_P, 0x00
        WREG    WDKICK_P, WDKICK_MAGIC
        RCHK    WDCTRL_P, 0
        CHECK   0x51                    ; check 51: WDTIME 2 ms; EN and LOCK
        WREG    WDTIME0_P, 2
        WREG    WDTIME1_P, 0
        WREG    WDCTRL_P, WDCTRL_EN_M | WDCTRL_LOCK_M
        RCHK    WDCTRL_P, WDCTRL_EN_M | WDCTRL_LOCK_M
        CHECK   0x52                    ; check 52: locked: WDCTRL and WDTIME read only
        WREG    WDCTRL_P, 0
        RCHK    WDCTRL_P, WDCTRL_EN_M | WDCTRL_LOCK_M
        WREG    WDTIME0_P, 0x99
        RCHK    WDTIME0_P, 2
        WREG    WDTIME1_P, 0x99
        RCHK    WDTIME1_P, 0
        CHECK   0x53                    ; check 53: kicks every 1.5 ms keep it from firing
        ld      b,3
.kick:  push    bc
        WREG    WDKICK_P, WDKICK_MAGIC
        ld      hl,1500
        call    waitus
        pop     bc
        djnz    .kick
        WREG    WDKICK_P, WDKICK_MAGIC  ; the last kick
        call    time32
        ld      (KICKT),hl
        ld      (KICKT+2),de
        ld      a,PHMARK
        ld      (PHASE),a
        CHECK   0x54                    ; check 54: the watchdog must fire within 4 ms
        ld      a,1
        ld      (PHASEN),a
.wd:    call    time32                  ; TIME, again and again, until the reset
        ld      (LASTT),hl
        ld      (LASTT+2),de
        ld      bc,(KICKT)
        or      a
        sbc     hl,bc
        ld      bc,4000
        or      a
        sbc     hl,bc
        jr      c,.wd
        xor     a
        ld      (PHASE),a
        jp      fail

; ---- after a watchdog reset
afterwd:
        CHECK   0x60                    ; check 60: a watchdog reset, in a phase we expected
        ld      a,(PHASE)
        cp      PHMARK
        jp      nz,fail
        ld      a,(PHASEN)
        cp      1
        jr      z,phase1
        cp      2
        jp      nz,fail
        xor     a
        ld      (PHASE),a
        jp      passed

phase1: CHECK   0x61                    ; check 61: the reset came 2-3 ms after the last kick
        ld      hl,(LASTT)
        ld      bc,(KICKT)
        or      a
        sbc     hl,bc
        RANGE   1980, 3000
        CHECK   0x62                    ; check 62: TIME ran on through the reset
        call    time32
        ld      bc,(LASTT)
        or      a
        sbc     hl,bc
        RANGE   1, 100
        CHECK   0x63                    ; check 63: the watchdog is off and unlocked, WDTIME 1000
        RCHK    WDCTRL_P, 0
        RCHK    WDTIME0_P, 0xE8
        RCHK    WDTIME1_P, 0x03
        WREG    WDTIME0_P, 5
        RCHK    WDTIME0_P, 5
        CHECK   0x64                    ; check 64: a wrong kick value resets at once
        ld      a,2
        ld      (PHASEN),a
        WREG    WDCTRL_P, WDCTRL_EN_M
        WREG    WDKICK_P, 0x12
        nop
        nop
        nop
        nop
        jp      fail

passed: ld      hl,pass
        call    puts
        jr      stop

fail:   ld      hl,failmsg
        call    puts
        ld      a,(CHK)
        call    puthex
        ld      a,13
        call    putc
        ld      a,10
        call    putc
stop:   di
        halt
        jr      stop

PHASEN  equ     LASTT + 4               ; the phase number

; ---- timers

; Set up a timer from the data after the call: CTRL, PRESCALE, RELOAD, COUNT
; (A = the timer's CTRL register). Stop, clear UNDER, the values, then CTRL.
tseti:  pop     hl
        ld      b,a
        ld      c,SYSPAGE
        xor     a
        out     (c),a                   ; stop
        push    bc
        ld      a,b
        add     a,TMR_STAT
        ld      b,a
        ld      a,TMR_STAT_UNDER_M
        out     (c),a                   ; no old underflow
        pop     bc
        push    bc
        ld      e,(hl)                  ; CTRL
        inc     hl
        ld      d,6
.w:     inc     b
        ld      a,(hl)
        out     (c),a                   ; PRESCALE0 ... COUNT1
        inc     hl
        dec     d
        jr      nz,.w
        pop     bc
        out     (c),e                   ; go
        jp      (hl)

; Wait for an underflow of the timer whose STAT register is A, then clear
; it; fail after about 160 ms
waitund:
        ld      b,a
        ld      c,SYSPAGE
        ld      hl,0
.p:     in      a,(c)
        rrca
        jr      c,.got
        dec     hl
        ld      a,h
        or      l
        jr      nz,.p
        jp      fail
.got:   ld      a,TMR_STAT_UNDER_M
        out     (c),a
        ret

; HL = microseconds between two underflows of the timer whose STAT register is A
period: ld      (PSTAT),a
        call    waitund
        call    time16
        push    hl
        ld      a,(PSTAT)
        call    waitund
        call    time16
        pop     de
        or      a
        sbc     hl,de
        ret
PSTAT   equ     LASTT + 5

; Timer 1 must not move for 400 us (it counts timer 0, which is stopped)
chain_still1:
        ld      bc,TMR1_COUNT0_P
        in      l,(c)
        inc     b
        in      h,(c)
        push    hl
        ld      hl,400
        call    waitus
        ld      bc,TMR1_COUNT0_P
        in      l,(c)
        inc     b
        in      h,(c)
        pop     de
        or      a
        sbc     hl,de
        jp      nz,fail
        RCHK    TMR1_STAT_P, 0
        ret

; The 64 readings at BUF (a down counter): Z if every step between two
; readings is the same; HL = the step
steps:  ld      ix,BUF
        ld      l,(ix+0)
        ld      h,(ix+1)
        ld      e,(ix+2)
        ld      d,(ix+3)
        or      a
        sbc     hl,de                   ; the first step
        ld      (STEP),hl
        ld      b,63
.s:     ld      l,(ix+0)
        ld      h,(ix+1)
        ld      e,(ix+2)
        ld      d,(ix+3)
        or      a
        sbc     hl,de
        ld      de,(STEP)
        or      a
        sbc     hl,de
        ret     nz
        inc     ix
        inc     ix
        djnz    .s
        ld      hl,(STEP)
        xor     a
        ret
STEP    equ     LASTT + 6

; ---- TIME

; HL = TIME bits 15-0 (reads TIME0, which captures)
time16: ld      bc,TIME0_P
        in      l,(c)
        inc     b
        in      h,(c)
        ret

; DEHL = TIME (reads TIME0, which captures)
time32: ld      bc,TIME0_P
        in      l,(c)
        inc     b
        in      h,(c)
        inc     b
        in      e,(c)
        inc     b
        in      d,(c)
        ret

; Wait HL microseconds (1-32767), by TIME (A, BC, DE, HL changed)
waitus: ex      de,hl
        call    time16
        add     hl,de
        ex      de,hl                   ; DE = the time to wait for
.w:     call    time16
        or      a
        sbc     hl,de
        bit     7,h
        jr      nz,.w
        ret

; Wait HL x 1.3 us without reading TIME: a 26-T-state loop at 20 MHz
; (A, HL changed)
waitus_nocap:
.w:     dec     hl                      ; 6
        ld      a,h                     ; 4
        or      l                       ; 4 (+ the jump's 12: 26 T-states, 1.3 us)
        jr      nz,.w
        ret

; Unsigned: carry set unless BC <= HL <= DE (HL kept)
range:  push    hl
        or      a
        sbc     hl,bc                   ; C if HL < BC
        jr      c,.out
        pop     hl
        push    hl
        scf
        sbc     hl,de                   ; HL - DE - 1: C if HL <= DE
        ccf
.out:   pop     hl
        ret

; ---- interrupts

; The IM 2 table at TABLE, VECBASE 0: TIMER0-3 to their own handlers, every
; other entry to hbad
settab: WREG    VECBASE_P, 0
        ld      a,TABLE >> 8
        ld      i,a
        ld      hl,TABLE
        ld      b,24
.f:     ld      (hl),hbad & 0xFF
        inc     hl
        ld      (hl),hbad >> 8
        inc     hl
        djnz    .f
        ld      hl,h0
        ld      (TABLE + 2 * INT_TIMER0),hl
        ld      hl,h1
        ld      (TABLE + 2 * INT_TIMER1),hl
        ld      hl,h2
        ld      (TABLE + 2 * INT_TIMER2),hl
        ld      hl,h3
        ld      (TABLE + 2 * INT_TIMER3),hl
        ret

; Each handler logs its timer's number and clears its UNDER
h0:     push    af
        push    bc
        push    hl
        xor     a
        ld      bc,TMR0_STAT_P
        jr      hlog
h1:     push    af
        push    bc
        push    hl
        ld      a,1
        ld      bc,TMR1_STAT_P
        jr      hlog
h2:     push    af
        push    bc
        push    hl
        ld      a,2
        ld      bc,TMR2_STAT_P
        jr      hlog
h3:     push    af
        push    bc
        push    hl
        ld      a,3
        ld      bc,TMR3_STAT_P
hlog:   call    logit
        ld      a,TMR_STAT_UNDER_M
        out     (c),a                   ; clear the cause
hdone:  pop     hl
        pop     bc
        pop     af
        ei
        reti
hbad:   push    af
        push    bc
        push    hl
        ld      a,0xEE
        call    logit
        WREG    INTCON_P, 0             ; no more
        jr      hdone

logclr: ld      hl,LOG
        ld      (LOGP),hl
        ret
logit:  ld      hl,(LOGP)               ; append A (HL changed)
        ld      (hl),a
        inc     hl
        ld      (LOGP),hl
        ret
; Z if the log holds what HL points at: a count, then the bytes (A, B, DE, HL changed)
chklog: ld      b,(hl)
        inc     hl
        push    hl
        ld      hl,(LOGP)
        ld      de,LOG
        or      a
        sbc     hl,de
        ld      a,l
        pop     hl
        cp      b
        ret     nz
        ld      a,b
        or      a
        ret     z
.cmp:   ld      a,(de)
        cp      (hl)
        ret     nz
        inc     de
        inc     hl
        djnz    .cmp
        xor     a
        ret

; ---- USB serial

; Send A as two hex digits
puthex: push    af
        rrca
        rrca
        rrca
        rrca
        call    .nib
        pop     af
.nib:   and     0x0F
        add     a,'0'
        cp      '9'+1
        jr      c,putc
        add     a,'A'-'9'-1
        jr      putc

puts:   ld      a,(hl)
        or      a
        ret     z
        call    putc
        inc     hl
        jr      puts

; Send A over USB (A, B, C changed; the byte is kept in E)
putc:   push    bc
        ld      e,a
.wait:  ld      a,SERSTAT0
        in      a,(SYSPAGE)
        or      a
        jr      z,.wait
        ld      a,e
        out     (SERDATA_PORT),a
        pop     bc
        ret

exp_t0:    db   1, 0
exp_t1:    db   1, 1
exp_t2:    db   1, 2
exp_t3:    db   1, 3
exp_all:   db   4, 0, 1, 2, 3
exp_rep:   db   5, 2, 2, 2, 2, 2
pass:      db   "PASS", 13, 10, 0
failmsg:   db   "FAIL ", 0
