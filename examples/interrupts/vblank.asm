; Example 2-1 (docs/guide/interrupts.md): the vertical blank interrupt,
; and the software interrupt for the slow part. An IM 2 table in the
; program's memory; the VBLANK handler counts frames and, every 50th,
; raises SOFT; the SOFT handler steps the border colour. So the border
; changes once a second. A key ends it, with everything put back.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

TABLE   equ     0x9FD0                  ; the IM 2 table: I = 0x9F, VECBASE = 0xD0

start:  di
        ld      hl,TABLE                ; every entry to the spurious handler ...
        ld      b,24
.fill:  ld      (hl),low spurious
        inc     hl
        ld      (hl),high spurious
        inc     hl
        djnz    .fill
        ld      hl,vbl                  ; ... then the two this program uses
        ld      (TABLE+2*INT_VBLANK),hl
        ld      hl,soft
        ld      (TABLE+2*INT_SOFT),hl

        ld      a,high TABLE
        ld      i,a
        ld      bc,VECBASE_P
        ld      a,low TABLE
        out     (c),a
        im      2

        ld      bc,VIDSTAT_P            ; no old VBLANK
        ld      a,VIDSTAT_VBLANK_M
        out     (c),a
        ld      bc,VIDINTEN_P           ; 1. the unit's enable
        in      a,(c)
        or      VIDINTEN_VBLANK_M
        out     (c),a
        ld      bc,INTENA0_P+(INTR_VBLANK<<8)
        ld      a,INTENA_SETCLR_M|(1<<INTB_VBLANK)
        out     (c),a                   ; 2. the controller's enables: VBLANK ...
        ld      bc,INTENA0_P+(INTR_SOFT<<8)
        ld      a,INTENA_SETCLR_M|(1<<INTB_SOFT)
        out     (c),a                   ;    ... and SOFT
        ld      bc,INTCON_P
        ld      a,INTCON_MASTER_M
        out     (c),a                   ; 3. the master enable
        ei                              ; 4. the CPU's

        ld      hl,title
        rst     0x18                    ; PUTS: the ROM's calls work with interrupts on
.main:  rst     0x20                    ; POLLC: a key?
        jr      z,.main

        di                              ; put everything back
        ld      bc,INTCON_P
        xor     a
        out     (c),a                   ; master off
        ld      bc,INTENA0_P+(INTR_VBLANK<<8)
        ld      a,1<<INTB_VBLANK        ; SETCLR 0: clear
        out     (c),a
        ld      bc,INTENA0_P+(INTR_SOFT<<8)
        ld      a,1<<INTB_SOFT
        out     (c),a
        ld      bc,VIDINTEN_P
        in      a,(c)
        and     ~VIDINTEN_VBLANK_M
        out     (c),a
        ld      a,0x1F                  ; the ROM's table again
        ld      i,a
        ld      bc,VECBASE_P
        ld      a,0xD0
        out     (c),a
        xor     a
        out     (ULA_PORT),a            ; border black
        ret

vbl:    push    af                      ; VBLANK: 50 times a second
        push    bc
        ld      bc,VIDSTAT_P
        ld      a,VIDSTAT_VBLANK_M
        out     (c),a                   ; clear the cause first
        ld      a,(frames)
        inc     a
        cp      50
        jr      nz,.keep
        ld      bc,SOFTINT_P            ; a second gone: leave the rest to SOFT
        ld      a,SOFTINT_SET_M
        out     (c),a
        xor     a
.keep:  ld      (frames),a
        pop     bc
        pop     af
        ei
        reti

soft:   push    af                      ; SOFT: once a second, after every other source
        push    bc
        ld      bc,SOFTINT_P
        ld      a,SOFTINT_CLR_M
        out     (c),a                   ; clear it first
        ld      a,(colour)
        inc     a
        and     7
        ld      (colour),a
        out     (ULA_PORT),a            ; the next border colour
        pop     bc
        pop     af
        ei
        reti

spurious:
        ei                              ; NONE, or a source nobody asked for
        reti

frames: db      0
colour: db      0
title:  db      13, 10, "The border steps once a second. A key ends it.", 13, 10, 0
