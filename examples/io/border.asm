; Example 8-1 (docs/guide/io.md): the border from the number keys.
; Keys 0-7 set the border to that Spectrum colour, read through port 0xFE
; the way a Spectrum reads its keyboard, so the membrane, a PS/2 keyboard
; and keys typed from the PC all work. BREAK (CAPS SHIFT + SPACE, or Esc
; on a PS/2 keyboard) goes back to the monitor.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

start:
.scan:  ld      hl,keys
        ld      e,0                     ; E = the colour of the key being tested
.key:   ld      a,(hl)                  ; the row's address byte: 0 in the row's bit
        in      a,(ULA_PORT)            ; A = that row, 0 = pressed (A15-A8 pick the row)
        inc     hl
        and     (hl)                    ; this key's column
        inc     hl
        jr      nz,.next                ; 1: not pressed
        ld      a,e
        out     (ULA_PORT),a            ; bits 2-0 the border, bit 4 the beeper (0)
.next:  inc     e
        ld      a,e
        cp      8
        jr      nz,.key

        ld      a,0xFE                  ; row 0: CAPS SHIFT is bit 0
        in      a,(ULA_PORT)
        rra
        jr      c,.scan
        ld      a,0x7F                  ; row 7: SPACE is bit 0
        in      a,(ULA_PORT)
        rra
        jr      c,.scan
        ret                             ; both held: BREAK. RET goes to the ROM's EXIT

; For each colour 0-7: the row's address byte, then the key's column bit
keys:   db      0xEF, 0x01              ; 0: row 4, bit 0
        db      0xF7, 0x01              ; 1: row 3, bit 0
        db      0xF7, 0x02              ; 2
        db      0xF7, 0x04              ; 3
        db      0xF7, 0x08              ; 4
        db      0xF7, 0x10              ; 5
        db      0xEF, 0x10              ; 6: row 4, bit 4
        db      0xEF, 0x08              ; 7: row 4, bit 3
