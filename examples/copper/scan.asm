; Example 5-3 (docs/guide/copper.md): scan lines with a loop. Beam lines
; 149-448 alternate between two blues, line by line; the rest is black.
; Seven instructions do the work of 600. The start-up and the ending are
; Example 5-2's.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"
        include "copper.inc"

start:  ld      bc,L0_CTRL0_P           ; the console's paper transparent
        in      a,(c)
        or      L_CTRL0_TRANSP_M
        out     (c),a

        ld      bc,COPCON_P             ; the copper off while it is set up
        xor     a
        out     (c),a
        ld      hl,scan                 ; 1. the list's address to COP1LC
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

title:  db      13, 10, "Scan lines from a copper loop. A key ends it.", 13, 10, 0

        ALIGN   2
scan:   CMOVEA  BGCOLOR,0x000000        ; black from the top
        CWAIT   149,0                   ; the blank before beam line 149
.loop:  CMOVE   BGCOLOR0,0xC0           ; even lines: blue 0xC0, into the buffer
        CMOVE   BGCOLOR2,0x00           ; red 0 commits it (green: still 0 in the buffer)
        CWAITP  0                       ; the next line's blank
        CMOVE   BGCOLOR0,0x60           ; odd lines: blue 0x60
        CMOVE   BGCOLOR2,0x00
        CWAITP  0
        CSKIP   449,0                   ; reached line 449? leave the loop
        CJUMP   .loop
        CMOVEA  BGCOLOR,0x000000        ; black again from line 449
        CSTOP
