; Example 5-6 (docs/guide/copper.md): a raster bar that the CPU moves
; through a storage register, with a copper interrupt. Every frame the
; copper counts COPR0 lines down from beam line 113, then calls a
; subroutine that draws a 16-line bar, yellow brightening to its middle and
; fading again. At line 600, below the console, it writes COPINT; the
; handler moves the bar for the next frame, bouncing between 0 and 255,
; while the copper is stopped. A key ends it.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"
        include "copper.inc"

TOP     equ     113                     ; the bar's line for COPR0 = 0
TABLE   equ     0x9FD0                  ; the IM 2 table: I = 0x9F, VECBASE = 0xD0

start:  di
        ld      hl,TABLE                ; every entry to the spurious handler ...
        ld      b,24
.fill:  ld      (hl),low spurious
        inc     hl
        ld      (hl),high spurious
        inc     hl
        djnz    .fill
        ld      hl,copint               ; ... but the copper's
        ld      (TABLE+2*INT_COPPER),hl
        ld      a,high TABLE
        ld      i,a
        ld      bc,VECBASE_P
        ld      a,low TABLE
        out     (c),a
        im      2

        ld      bc,L0_CTRL0_P           ; the console's paper transparent
        in      a,(c)
        or      L_CTRL0_TRANSP_M
        out     (c),a

        ld      bc,COPCON_P             ; the copper off while it is set up
        xor     a
        out     (c),a
        ld      bc,COPR0_P              ; the bar at the top
        out     (c),a
        ld      bc,COPSTAT_P            ; no old COPINT
        ld      a,COPSTAT_IRQ_M
        out     (c),a
        ld      hl,bar_list
        ld      bc,COP1LC0_P
        out     (c),l
        inc     b
        out     (c),h
        inc     b
        xor     a
        out     (c),a
        ld      b,low COPCON            ; on, and COPINT interrupts
        ld      a,COPCON_EN_M|COPCON_IRQEN_M
        out     (c),a
        ld      bc,INTENA0_P+(INTR_COPPER<<8)
        ld      a,INTENA_SETCLR_M|(1<<INTB_COPPER)
        out     (c),a
        ld      bc,INTCON_P
        ld      a,INTCON_MASTER_M
        out     (c),a
        ld      bc,DMACON_P
        ld      a,DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_COPEN_M
        out     (c),a
        ei

        ld      hl,title
        rst     0x18                    ; PUTS
.main:  rst     0x20                    ; POLLC
        jr      z,.main

        di                              ; put everything back
        ld      bc,DMACON_P
        ld      a,DMACON_COPEN_M
        out     (c),a
        ld      bc,COPCON_P
        xor     a
        out     (c),a
        ld      bc,INTCON_P
        out     (c),a
        ld      bc,INTENA0_P+(INTR_COPPER<<8)
        ld      a,1<<INTB_COPPER
        out     (c),a
        ld      a,0x1F                  ; the ROM's table again
        ld      i,a
        ld      bc,VECBASE_P
        ld      a,0xD0
        out     (c),a
        ld      bc,BGCOLOR0_P           ; black
        xor     a
        out     (c),a
        inc     b
        out     (c),a
        inc     b
        out     (c),a
        ld      bc,L0_CTRL0_P
        in      a,(c)
        and     ~L_CTRL0_TRANSP_M
        out     (c),a
        ret

copint: push    af                      ; COPPER: once a frame, at line 600
        push    bc
        ld      bc,COPSTAT_P
        ld      a,COPSTAT_IRQ_M
        out     (c),a                   ; clear the cause first
        ld      bc,COPR0_P
        in      a,(c)                   ; where the bar was
        ld      b,a
        ld      a,(step)
        add     a,b                     ; moved on
        jr      z,.turn                 ; at 0 ...
        cp      255
        jr      nz,.put                 ; ... or 255: turn round
.turn:  push    af
        ld      a,(step)
        neg
        ld      (step),a
        pop     af
.put:   ld      bc,COPR0_P
        out     (c),a                   ; next frame's line, while the copper is stopped
        pop     bc
        pop     af
        ei
        reti

spurious:
        ei
        reti

step:   db      1                       ; +1 or -1 line a frame
title:  db      13, 10, "A raster bar moved by the CPU through COPR0. A key ends it.", 13, 10, 0

        ALIGN   2
bar_list:
        CMOVEA  BGCOLOR,0x000000        ; black above the bar
        CWAIT   TOP,0                   ; the blank of line TOP
        CLD     CY,CR0                  ; Y = lines down, from the CPU
.down:  CCMPI   CY,0
        CSKIPNE                         ; not there yet: skip the CJUMP
        CJUMP   .here
        CWAITP  0                       ; the next line's blank
        CSUBI   CY,1
        CJUMP   .down
.here:  CCALL   bar                     ; the bar, from this line
        CWAIT   600,0                   ; below the console
        CMOVEF  COPINT,0                ; tell the CPU
        CSTOP

; 16 lines from the line it is called in, in its blank: red and green
; both X, from 0x1F up to 0xFF and down again. Uses X and Y.
bar:    CLDI    CY,16                   ; Y: lines left
        CLDI    CX,0x1F                 ; X: the brightness
.line:  CMOVE   BGCOLOR0,0x00           ; blue 0, held
        CMOVR   BGCOLOR1,CX             ; green, held
        CMOVR   BGCOLOR2,CX             ; red: the colour changes, from this line
        CCMPI   CY,9                    ; the top half (Y > 9): brighter
        CSKIPLS
        CADDI   CX,0x20
        CCMPI   CY,9                    ; the bottom half (Y < 9): darker
        CSKIPHS
        CSUBI   CX,0x20
        CSUBI   CY,1
        CSKIPNE                         ; lines left: skip the CJUMP
        CJUMP   .done
        CWAITP  0                       ; the next line's blank
        CJUMP   .line
.done:  CWAITP  0                       ; the line after the bar: black
        CMOVEA  BGCOLOR,0x000000
        CRET
