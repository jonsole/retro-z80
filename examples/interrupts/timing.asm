; Example 2-2 (docs/guide/interrupts.md): timing code with TIME.
; Copies 8 KB with LDIR and prints how many microseconds it took, at
; 20 MHz and again at the Spectrum speed (3.57 MHz). TIME counts
; microseconds; its low 16 bits are enough for anything under 65 ms.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

PUTDEC  equ     0x08                    ; RST 28h function: HL in decimal

start:  ld      hl,s_20
        rst     0x18                    ; PUTS
        call    measure

        ld      bc,CPUSPEED_P
        ld      a,CPUSPEED_SPECTRUM_M
        out     (c),a                   ; 3.57 MHz
        ld      hl,s_spec
        rst     0x18
        call    measure
        ld      bc,CPUSPEED_P
        xor     a
        out     (c),a                   ; 20 MHz again
        ret

measure:                                ; time the copy; print the microseconds
        di                              ; nothing else reads a counter meanwhile
        call    time
        push    hl
        ld      hl,0x2000               ; 8 KB from window 1 to window 5
        ld      de,0xA000
        ld      bc,8192
        ldir                            ; 21 T a byte, 16 for the last
        call    time
        pop     de
        or      a
        sbc     hl,de                   ; the difference is right across a wrap
        ei
        rst     0x28
        db      PUTDEC
        ld      hl,s_us
        rst     0x18
        ret

time:   ld      bc,TIME0_P              ; TIME bits 15-0 to HL
        in      l,(c)                   ; reading TIME0 captures all 32 bits
        inc     b
        in      h,(c)                   ; TIME1, from the capture
        ret

s_20:   db      13, 10, "8 KB LDIR at 20 MHz:   ", 0
s_spec: db      "8 KB LDIR at 3.57 MHz: ", 0
s_us:   db      " us", 13, 10, 0
