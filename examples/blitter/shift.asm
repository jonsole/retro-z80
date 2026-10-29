; Example 6-3 (docs/guide/blitter.md): placing an image at any x, at 4 bpp.
; The screen is 360 x 288 at 4 bpp, 180 bytes a row. A yellow line marks
; x = 99, and eight 16 x 16 images go at x = 100, 101, ... 107, one under
; another, so each starts one pixel further from the line. Half of them
; start in the second pixel of a byte. A key ends it.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

ROW     equ     180                     ; bytes a row at 4 bpp

start:  ld      a,BPP4
        ld      hl,ROW
        call    scr_on
        ld      hl,jobs                 ; the background, the line, the images
        call    start2
        call    wait2
        ld      (stat),a
        call    waitkey
        call    scr_off
        ld      hl,msg
        rst     18h                     ; PUTS
        ld      a,(stat)
        rst     28h
        db      0x06                    ; PUTHEX: 02 is DONE, 06 DONE and ERR
        ld      hl,crlf
        rst     18h
        ret

stat:   db      0
msg:    db      "CHSTAT ", 0
crlf:   db      13, 10, 0

        align   4
jobs:   db      OP_BLIT, BPP4|BCONST, 0, 0xCC   ; fill with blue
        d24     0, 0, SCREEN
        d24     360
        dw      288, 0, 0, ROW
        dd      1                       ; VALUE: below 8 bpp only the low 4 bits count
        d24     line
        db      0

line:   db      OP_BLIT, BPP4|BCONST, 0, 0xCC   ; a line 1 pixel wide at x = 99
        d24     0, 0, SCREEN + 99 / 2
        d24     1
        dw      288
        dw      (99 % 2) << 8           ; SHIFT: DBIT 1, the second pixel of its byte
        dw      0, ROW
        dd      6                       ; yellow
        d24     img0
        db      0

; Image k at x = 100 + k, y = 8 + 35 k: DPT the byte holding pixel x, and
; DBIT where x falls in it
img0:
k = 0
        DUP     8
x = 100 + k
y = 8 + 35 * k
        db      OP_BLIT, BPP4|MASKKEY, 0, 0xCA  ; A ? B : C, key colour 0
        d24     0, image
        d24     SCREEN + y * ROW + x / 2        ; DPT: the byte holding pixel x
        d24     16
        dw      16
        dw      (x % 2) << 8                    ; SHIFT: DBIT = x mod 2
        dw      8, ROW                          ; ABSTRIDE: the image's rows; CDSTRIDE: the screen's
        dd      0
        IF k < 7
        d24     $ + 4                           ; NEXT: the next image
        ELSE
        d24     0
        ENDIF
        db      0
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
