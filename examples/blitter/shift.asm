; Example 6-3 (docs/guide/blitter.md): placing an image at any x, at 4 bpp.
; The screen is 360 x 288 at 4 bpp, 180 bytes a row. A yellow line marks
; x = 99, and eight 16 x 16 images go at x = 100, 101, ... 107, one under
; another, so each starts one pixel further from the line. Half of them
; start in the second pixel of a byte. A key ends it and prints BLTSTAT.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

ROW     equ     180                     ; bytes a row at 4 bpp

start:  ld      a,2                     ; the layer: 4 bpp,
        ld      hl,ROW                  ; 180 bytes a row
        call    scr_on
        ld      hl,jobs                 ; the background, the line, the images
        call    bltstart
        call    bltwait
        ld      (stat),a
        call    waitkey
        call    scr_off
        ld      hl,msg
        rst     18h                     ; PUTS
        ld      a,(stat)
        rst     28h
        db      0x06                    ; PUTHEX: 00 is done, 04 ERR
        ld      hl,crlf
        rst     18h
        ret

stat:   db      0
msg:    db      "BLTSTAT ", 0
crlf:   db      13, 10, 0

        align   2
jobs:   dd      0xCC*MT | BLTCTRL_BCONST_M | BPP4 ; fill with blue
        dd      0, SCREEN
        dw      360, 288                ; WIDTH in pixels, HEIGHT
        dd      0
        dw      ROW, 0
        dw      0x1111, 0               ; VALUE: colour 1 in all four pixels of the word
        dd      line

line:   dd      0xCC*MT | BLTCTRL_BCONST_M | BPP4 ; a line 1 pixel wide at x = 99
        dd      0
        dd      (SCREEN + 99 / 2) | (99 % 2) << 24 ; BLTDPT: the byte, and DBIT 1: its second pixel
        dw      1, 288
        dd      0
        dw      ROW, 0
        dw      0x6666, 0               ; yellow
        dd      img0

; Image k at x = 100 + k, y = 8 + 35 k: BLTDPT the byte holding pixel x,
; and DBIT where x falls in it
img0:
k = 0
        DUP     8
x = 100 + k
y = 8 + 35 * k
        dd      0xCA*MT | MASKKEY | BPP4        ; A ? B : C, KEY 0
        dd      image                           ; BLTBPT: the image, BBIT 0
        dd      (SCREEN + y * ROW + x / 2) | (x % 2) << 24 ; BLTDPT: the byte holding pixel x, DBIT = x mod 2
        dw      16, 16
        dd      0
        dw      ROW, 8                          ; DSTRIDE: the screen's rows; BSTRIDE: the image's
        dw      0, 0
        IF k < 7
        dd      $ + 4                           ; BLTNEXT: the next image
        ELSE
        dd      0
        ENDIF
k = k + 1
        EDUP

; The image: 16 x 16 at 4 bpp, 8 bytes a row, the left pixel in the high
; half of each byte. White with a red edge; the corners are colour 0, the
; key, so they let the background through.
image:
r = 0
        DUP     16
c = 0
        DUP     16
        IF (r == 0 || r == 15) && (c == 0 || c == 15)
v = 0                                   ; a corner: the key colour
        ELSE
        IF r == 0 || r == 15 || c == 0 || c == 15
v = 2                                   ; the edge: red
        ELSE
v = 7                                   ; inside: white
        ENDIF
        ENDIF
        IF (c & 1) == 0
hi = v                                  ; the left pixel of the byte
        ELSE
        db      hi << 4 | v             ; the left pixel in bits 7-4
        ENDIF
c = c + 1
        EDUP
r = r + 1
        EDUP

        include "screen.inc"
