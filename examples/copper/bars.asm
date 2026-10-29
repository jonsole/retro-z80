; Example 5-2 (docs/guide/copper.md): starting the copper, with the colour
; bars of Example 5-1. The background colour changes every 16 lines: 36
; bars, from blue at the top to red at the bottom. The console's paper is
; made transparent, so the bars show behind the text. A key ends it, with
; everything put back.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"
        include "copper.inc"

BAR     equ     16                      ; lines a bar

start:  ld      bc,L0_CTRL0_P           ; the console's paper transparent
        in      a,(c)
        or      L_CTRL0_TRANSP_M
        out     (c),a

        ld      bc,COPCON_P             ; the copper off while it is set up
        xor     a
        out     (c),a
        ld      hl,bars                 ; 1. the list's address to COP1LC
        ld      bc,COP1LC0_P
        out     (c),l                   ;    the program map: the Z80 address
        inc     b                       ;    is the physical address
        out     (c),h
        inc     b
        out     (c),a                   ;    bits 21-16: 0
        ld      b,low COPCON            ; 2. on, normal priority (C = 0x11 still)
        ld      a,COPCON_EN_M
        out     (c),a
        ld      bc,DMACON_P             ; 3. copper DMA on (DMAEN is on already)
        ld      a,DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_COPEN_M
        out     (c),a                   ; it starts at the next frame

        ld      hl,title
        rst     0x18                    ; PUTS
.main:  rst     0x20                    ; POLLC: a key?
        jr      z,.main

        ld      bc,DMACON_P             ; copper DMA off: it stops at once
        ld      a,DMACON_COPEN_M        ; (SETCLR 0: clear)
        out     (c),a
        ld      bc,COPCON_P
        xor     a
        out     (c),a
        ld      bc,BGCOLOR0_P           ; the last bar's colour stays: black again
        out     (c),a                   ; blue,
        inc     b
        out     (c),a                   ; green,
        inc     b
        out     (c),a                   ; red: the colour changes
        ld      bc,L0_CTRL0_P           ; the console's paper solid
        in      a,(c)
        and     ~L_CTRL0_TRANSP_M
        out     (c),a
        ret

title:  db      13, 10, "Colour bars from the copper. A key ends it.", 13, 10, 0

; Example 5-1: the list. Bar 0 is set in the vertical blank; each later
; bar's colour goes in at the start of its first line's horizontal blank.
        ALIGN   2                       ; copper instructions are words
bars:   CMOVEA  BGCOLOR,0x0000FF        ; bar 0: blue
b = 1
        DUP     35                      ; bars 1-35
        CWAIT   49+b*BAR,0              ; the blank before the bar
        CMOVEA  BGCOLOR,((b*7)<<16)|(255-b*7)   ; red rises, blue falls
b = b + 1
        EDUP
        CSTOP
