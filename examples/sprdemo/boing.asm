; The sprite demo (firmware/boot/sprdemo.asm, the boot ROM's F1 / GRAPH) as
; a program to load and debug from VS Code. The same source, assembled at
; 0x2000 in RAM, with what it takes from the rest of the ROM given here.
; BREAK (or Esc) ends it, back to the monitor, which puts the console back.
;
; The KS2 builds 2 sprites while the DMA engine is in, so it shows 2 balls.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x2000

        include "hw.inc"
        include "copper.inc"

; ---- what the demo uses from the rest of the ROM
PG_REGS equ     0x3F8                   ; the register page
ivt     equ     0x1FD0                  ; the ROM's IM 2 table, in ROM page 0 (window 0 in the program map)
EXIT    equ     0x0040                  ; back to the monitor: "Program ended."
        DEFINE  BD_PAGE 0x0F0           ; the demo's two SRAM pages (0x1E0000): the ROM's
                                        ; 0x0FC holds the debug stub's buffers while stopped

start:  ld      sp,stack_top            ; the demo maps its own pages into windows 5-7,
        call    sprdemo                 ; where the program map's stack would be
        jp      EXIT

; Set the background colour from the 3 bytes at HL: blue, green, red
setbg:  ld      bc,BGCOLOR0_P
        ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,(hl)
        out     (c),a
        ret

; The console: the monitor rebuilds it when the program ends
conl0:  ret

; Any other interrupt source: turn it off in INTENA (as the ROM's ivhand)
ivhand: push    af
        push    bc
        ld      bc,INTID_P
        in      a,(c)
        cp      21
        jr      nc,.done
        ld      b,INTENA0
.d7:    cp      7
        jr      c,.bit
        sub     7
        inc     b
        jr      .d7
.bit:   ld      c,a
        ld      a,1
        inc     c
.sh:    dec     c
        jr      z,.out
        add     a,a
        jr      .sh
.out:   ld      c,SYSPAGE
        out     (c),a
.done:  pop     bc
        pop     af
        ei
        reti

T_DBUF: ds      12                      ; windows 5-7's pages, kept while it runs

        include "../../firmware/boot/sprdemo.asm"

        ds      256
stack_top:
        ASSERT  $ <= 0xA000             ; windows 1-4: the demo maps 5-7
