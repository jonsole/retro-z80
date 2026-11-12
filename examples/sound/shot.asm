; Example 10-2 (docs/guide/sound.md): a one-shot sound effect. The program
; makes a burst of noise that dies away, 4,096 8-bit samples, and channel 2
; plays it once, in the middle, each time a key is pressed: a new press
; cuts off the one before. The AUDIO interrupt comes when the channel
; takes the block and when the block ends; the handler tells the two
; apart by AUDSTAT.ACTIVE, and the main program prints S and E. Q ends it.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

TABLE   equ     0x9FD0                  ; the IM 2 table: I = 0x9F, VECBASE = 0xD0
NOISE   equ     0xA000                  ; the sample, 4,096 bytes
NLEN    equ     4096
CH2     equ     1 << 2                  ; channel 2's bit in the AUDxxx registers

    MACRO AUDCHAN ctrl, lc, len, step, vr, vl
        db      ctrl, 0, 0, 0           ; CTRL (+0x00)
        d24     lc                      ; LC   (+0x04), low byte first
        db      0
        d24     len                     ; LEN  (+0x08)
        db      0
        d24     step                    ; STEP (+0x0C)
        db      0
        db      vr, 0, vl               ; VOL  (+0x10): right, empty, left
    ENDM

start:  di
        call    makenoise

        ld      hl,TABLE                ; the IM 2 table: every entry spurious ...
        ld      b,24
.fill:  ld      (hl),low spurious
        inc     hl
        ld      (hl),high spurious
        inc     hl
        djnz    .fill
        ld      hl,audio                ; ... but AUDIO's
        ld      (TABLE+2*INT_AUDIO),hl
        ld      a,high TABLE
        ld      i,a
        ld      bc,VECBASE_P
        ld      a,low TABLE
        out     (c),a
        im      2

        ld      hl,chan2                ; channel 2: one-shot, 1:1, centre
        ld      b,high AUD2_CTRL_P
        call    setchan
        ld      bc,AUDSTAT_P            ; no old events
        ld      a,AUDSTAT_CH_M
        out     (c),a
        ld      bc,AUDINTEN_P           ; 1. the unit: channel 2's events
        ld      a,CH2
        out     (c),a
        ld      bc,INTENA0_P+(INTR_AUDIO<<8)
        ld      a,INTENA_SETCLR_M|(1<<INTB_AUDIO)
        out     (c),a                   ; 2. the controller: AUDIO ...
        ld      bc,INTCON_P
        ld      a,INTCON_MASTER_M
        out     (c),a                   ;    ... and the master enable
        ei                              ; 3. the CPU's

        ld      hl,title
        rst     0x18                    ; PUTS
        ld      bc,AUDDMA_P             ; enable channel 2 ...
        ld      a,AUDDMA_SETCLR_M | CH2
        out     (c),a
        ld      bc,DMACON_P             ; ... and sound: it plays once now
        ld      a,DMACON_SETCLR_M | DMACON_DMAEN_M | DMACON_AUDEN_M
        out     (c),a

.main:  di                              ; an event from the handler?
        ld      a,(event)
        ld      hl,event
        ld      (hl),0
        ei
        or      a
        jr      z,.key
        rst     0x08                    ; PUTC: S or E
.key:   rst     0x20                    ; POLLC: a key?
        jr      z,.main
        and     0xDF                    ; upper case
        cp      'Q'
        jr      z,.end
        ld      bc,AUDSTART_P           ; any other: play it from the start
        ld      a,CH2
        out     (c),a
        jr      .main

.end:   di                              ; put everything back
        ld      bc,AUDDMA_P             ; channel 2 off (it stops at once) ...
        ld      a,CH2
        out     (c),a
        ld      bc,DMACON_P             ; ... and sound
        ld      a,DMACON_AUDEN_M
        out     (c),a
        ld      bc,AUDINTEN_P
        xor     a
        out     (c),a
        ld      bc,AUDSTAT_P
        ld      a,AUDSTAT_CH_M
        out     (c),a
        ld      bc,INTCON_P
        xor     a
        out     (c),a
        ld      bc,INTENA0_P+(INTR_AUDIO<<8)
        ld      a,1<<INTB_AUDIO         ; SETCLR 0: clear
        out     (c),a
        ld      a,0x1F                  ; the ROM's table again
        ld      i,a
        ld      bc,VECBASE_P
        ld      a,0xD0
        out     (c),a
        ld      hl,s_nl
        rst     0x18
        ret

; AUDIO: channel 2 took its block (it plays: S) or its one-shot block
; ended (it does not: E)
audio:  push    af
        push    bc
        ld      bc,AUDSTAT_P
        in      a,(c)
        push    af
        and     AUDSTAT_CH_M
        out     (c),a                   ; clear the events seen, first
        pop     af
        and     CH2 << AUDSTAT_ACTIVE_B ; channel 2's ACTIVE bit
        ld      a,'S'
        jr      nz,.put
        ld      a,'E'
.put:   ld      (event),a
        pop     bc
        pop     af
        ei
        reti

spurious:
        ei                              ; NONE, or a source nobody asked for
        reti

; Write a channel's registers from the 19-byte image at HL; B = the high
; byte of its CTRL port (Example 10-1)
setchan:
        ld      c,low AUD0_CTRL_P
        ld      d,AUD_VOL + 3
.next:  ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        dec     d
        jr      nz,.next
        ret

; The noise: a 16-bit xorshift generator (7, 9, 8) gives a byte a
; sample. The burst dies away in eight steps of 512 samples, each a
; right shift (6 dB) quieter than the one before.
makenoise:
        ld      hl,NOISE
        ld      de,1                    ; the generator: any value but 0
.smp:   ld      a,d                     ; DE ^= DE << 7 ...
        rra
        ld      a,e
        rra
        xor     d
        ld      d,a
        ld      a,e                     ; ... ^= DE >> 9, ^= DE << 8
        rra
        ld      a,d
        rra
        xor     e
        ld      e,a
        xor     d
        ld      d,a
        ld      a,h                     ; the step: (HL - NOISE) / 512
        sub     high NOISE
        rra
        and     7
        ld      b,a
        ld      a,e
        jr      z,.put
.quiet: sra     a
        djnz    .quiet
.put:   ld      (hl),a
        inc     hl
        ld      a,h
        cp      high (NOISE + NLEN)
        jr      nz,.smp
        ret

chan2:  AUDCHAN AUD_CTRL_ONESHOT_M, NOISE, NLEN, 0x10000, 64, 64

event:  db      0
title:  db      13, 10, "A key plays the sound, Q ends.", 13, 10, 0
s_nl:   db      13, 10, 0
