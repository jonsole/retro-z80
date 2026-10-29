; Example 2-3 (docs/guide/interrupts.md): a timer interrupt.
; Timer 0 ticks at 10 Hz: 100 MHz / 10,000 (PRESCALE 9,999) is 10 kHz,
; and RELOAD 999 underflows every 1,000 of those. Its handler only counts;
; the main program waits for the count and prints the seconds, 1 to 5,
; then stops the timer and ends.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

PUTDEC  equ     0x08                    ; RST 28h function: HL in decimal
TABLE   equ     0x9FD0                  ; I = 0x9F, VECBASE = 0xD0

start:  di
        ld      hl,TABLE
        ld      b,24
.fill:  ld      (hl),low spurious
        inc     hl
        ld      (hl),high spurious
        inc     hl
        djnz    .fill
        ld      hl,tick
        ld      (TABLE+2*INT_TIMER0),hl
        ld      a,high TABLE
        ld      i,a
        ld      bc,VECBASE_P
        ld      a,low TABLE
        out     (c),a
        im      2

        ld      bc,TMR0_CTRL_P          ; C = 0x00 for the whole timer
        xor     a
        out     (c),a                   ; 1. stop
        ld      b,TMR0_STAT
        ld      a,TMR_STAT_UNDER_M
        out     (c),a                   ; 2. no old underflow
        ld      b,TMR0_PRESCALE0
        ld      hl,9999                 ; 3. 10 kHz ...
        out     (c),l
        inc     b
        out     (c),h
        inc     b                       ;    RELOAD
        ld      hl,999                  ;    ... / 1,000 = 10 Hz
        out     (c),l
        inc     b
        out     (c),h
        inc     b                       ;    COUNT: the first period too
        out     (c),l
        inc     b
        out     (c),h
        ld      b,INTENA0+INTR_TIMER0   ; 4. the controller
        ld      a,INTENA_SETCLR_M|(1<<INTB_TIMER0)
        out     (c),a
        ld      b,INTCON
        ld      a,INTCON_MASTER_M
        out     (c),a
        ld      b,TMR0_CTRL             ; 5. go: repeating, with its interrupt
        ld      a,TMR_CTRL_EN_M|TMR_CTRL_REPEAT_M|TMR_CTRL_IRQ_M
        out     (c),a
        ei

        ld      hl,title
        rst     0x18                    ; PUTS
        ld      hl,1                    ; HL = the next second to print
.wait:  ld      a,(ticks)
        cp      10                      ; 10 ticks: a second
        jr      c,.wait
        di
        sub     10
        ld      (ticks),a
        ei
        push    hl
        rst     0x28
        db      PUTDEC
        ld      a,' '
        rst     0x08                    ; PUTC
        pop     hl
        inc     hl
        ld      a,l
        cp      6
        jr      nz,.wait

        di                              ; stop and put things back
        ld      bc,TMR0_CTRL_P
        xor     a
        out     (c),a
        ld      bc,INTCON_P
        out     (c),a
        ld      bc,INTENA0_P+(INTR_TIMER0<<8)
        ld      a,1<<INTB_TIMER0
        out     (c),a
        ld      a,0x1F
        ld      i,a
        ld      bc,VECBASE_P
        ld      a,0xD0
        out     (c),a
        ld      hl,s_nl
        rst     0x18
        ret

tick:   push    af                      ; timer 0's underflow: 10 times a second
        push    bc
        ld      bc,TMR0_STAT_P
        ld      a,TMR_STAT_UNDER_M
        out     (c),a                   ; clear the cause
        ld      a,(ticks)
        inc     a
        ld      (ticks),a
        pop     bc
        pop     af
        ei
        reti

spurious:
        ei
        reti

ticks:  db      0
title:  db      13, 10, "Seconds: ", 0
s_nl:   db      13, 10, 0
