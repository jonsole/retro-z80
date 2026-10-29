; Example 5-4 (docs/guide/copper.md): a colour changed in the middle of a
; line. The console's text colour (PALETTE0 entry 17, the ink of its
; colour pair 0) is light grey left of beam pixel 344, the console's 20th
; column, and yellow from there, on every line. The yellow's blue and green
; wait in the copper's colour assembly buffer; its red, the first write
; after the WAIT, changes the colour at the pixel. A key ends it.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"
        include "copper.inc"

INK     equ     17                      ; the console's ink: pair 0 is block 1, ink entry 1
SPLIT   equ     344                     ; the console's window starts at beam pixel 184: column 20

start:  ld      bc,COPCON_P
        xor     a
        out     (c),a
        ld      hl,mid
        ld      bc,COP1LC0_P
        out     (c),l
        inc     b
        out     (c),h
        inc     b
        out     (c),a
        ld      b,low COPCON
        ld      a,COPCON_EN_M
        out     (c),a
        ld      bc,DMACON_P
        ld      a,DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_COPEN_M
        out     (c),a

        ld      hl,title
        rst     0x18                    ; PUTS
.main:  rst     0x20                    ; POLLC
        jr      z,.main

        ld      bc,DMACON_P             ; the copper off
        ld      a,DMACON_COPEN_M
        out     (c),a
        ld      bc,COPCON_P
        xor     a
        out     (c),a
        ld      bc,PALIDX0_P            ; the ink light grey again
        ld      a,INK
        out     (c),a
        inc     b
        xor     a
        out     (c),a                   ; PALIDX1: PALETTE0
        ld      b,low PALDAT
        ld      a,0xD7
        out     (c),a                   ; blue,
        out     (c),a                   ; green,
        out     (c),a                   ; red: the entry changes
        ret

title:  db      13, 10, "Grey to the left -- yellow from here, on every line of the screen.", 13, 10
        db      "A key ends it.", 13, 10, 0

        ALIGN   2
mid:    CMOVE   PALIDX1,0               ; PALETTE0; it stays so
.line:  CMOVE   PALIDX0,INK             ; in the blank: grey for the left of the line
        CMOVE   PALDAT,0xD7             ; blue,
        CMOVE   PALDAT,0xD7             ; green,
        CMOVE   PALDAT,0xD7             ; red: changes the entry, and steps PALIDX
        CMOVE   PALIDX0,INK             ; back to the ink (and its byte counter to blue)
        CMOVE   PALDAT,0x00             ; yellow's blue and green: held in
        CMOVE   PALDAT,0xFF             ; the copper's colour assembly buffer
        CWAITP  SPLIT                   ; the split, on this line
        CMOVE   PALDAT,0xFF             ; red: yellow, from this pixel
        CWAITP  0                       ; the next line's blank
        CJUMP   .line                   ; every line, until the frame restart
