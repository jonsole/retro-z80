; Example 6-5 (docs/guide/blitter.md): drawing lines with the rasteriser.
; A starburst of 48 lines from the centre of a 360 x 288 8 bpp screen to
; points far outside it, cut by a clip window; a frame drawn by the blitter
; shows the window. Below it, four lines with patterns, and two zig-zags
; drawn with XOR: the left one without NOLAST, so each corner is drawn twice
; and vanishes, the right one with NOLAST. A key ends it, and the console
; shows what the lines took.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

ROW     equ     360                     ; bytes a row at 8 bpp
CX      equ     180                     ; the starburst's centre
CY      equ     108

start:  ld      a,3                     ; the layer: 8 bpp,
        ld      hl,ROW                  ; 360 bytes a row
        call    scr_on
        ld      hl,clsjob               ; the blitter: black, and the frame round the window
        call    bltstart
        call    bltwait                 ; the rasteriser draws over it: wait first
        ld      hl,linejob              ; the fields every line shares
        call    rasload
        ld      hl,box
        call    setclip                 ; the clip window

        call    t0
        ld      hl,ends                 ; RASP0 is the centre: only RASP1 changes
.ray:   call    raswait                 ; the last line is drawn: its registers can change
        ld      bc,RASCTRL0_P
        ld      a,(col)
        out     (c),a                   ; the colour: RASCTRL bits 7-0
        inc     a
        cp      16
        jr      c,.col
        ld      a,9                     ; bright blue to bright white, round again
.col:   ld      (col),a
        ld      bc,RASP1_P
        call    out4                    ; the far end: Y, then X
        ld      bc,RASCMD_P
        ld      a,RASCMD_RUN_M
        out     (c),a                   ; draw it
        ld      de,ends_end
        or      a
        sbc     hl,de
        add     hl,de
        jr      nz,.ray
        call    raswait
        call    t1
        ld      (tray),hl

        call    raswait
        ld      hl,whole                ; the whole screen for the rest
        call    setclip
        ld      bc,RASCTRL0_P
        ld      a,14
        out     (c),a                   ; bright yellow
        ld      hl,dashes
.dash:  ld      bc,RASPAT_P
        call    out2                    ; the pattern
        ld      bc,RASP0_P
        call    out4                    ; both ends: RASP0, then RASP1
        call    out4
        push    hl
        call    t0
        ld      bc,RASCMD_P
        ld      a,RASCMD_RUN_M
        out     (c),a
        call    raswait
        call    t1
        ld      (tline),hl              ; the last line's time is kept
        pop     hl
        ld      de,dashes_end
        or      a
        sbc     hl,de
        add     hl,de
        jr      nz,.dash

        ; The zig-zags: XOR (minterm 0x66), each segment from point i to
        ; point i + 1, so RASP0 and RASP1 are 8 bytes of the table
        ld      bc,RASCTRL0_P
        ld      a,15
        out     (c),a                   ; bright white
        inc     b
        inc     b
        inc     b
        ld      a,0x66
        out     (c),a                   ; RASCTRL3: MINTERM B XOR C
        ld      bc,RASPAT_P
        ld      a,0xFF
        out     (c),a
        inc     b
        out     (c),a                   ; solid
        ld      hl,zigl
        call    zigzag                  ; without NOLAST
        call    raswait
        ld      bc,RASCTRL2_P
        ld      a,RASCTRL_NOLAST_M >> 16
        out     (c),a                   ; RASCTRL2: NOLAST
        ld      hl,zigr
        call    zigzag

        ; A line along row 5 from x = -32000 to 32000: 64,001 pixels
        ; stepped, 360 of them written (in black, on black)
        call    raswait
        ld      hl,farjob
        call    rasload
        call    t0
        ld      bc,RASCMD_P
        ld      a,RASCMD_RUN_M
        out     (c),a
        call    raswait
        call    t1
        ld      (tfar),hl

        call    waitkey
        call    scr_off
        ld      hl,msg1
        rst     18h                     ; PUTS
        ld      hl,(tray)
        rst     28h
        db      0x08                    ; PUTDEC
        ld      hl,msg2
        rst     18h
        ld      hl,(tline)
        rst     28h
        db      0x08
        ld      hl,msg3
        rst     18h
        ld      hl,(tfar)
        rst     28h
        db      0x08
        ld      hl,us
        rst     18h
        ret                             ; back to the monitor

; zigzag: the 8 segments of the 9 points at HL
zigzag: ld      d,8
.seg:   call    raswait
        ld      bc,RASP0_P
        call    out4                    ; point i into RASP0 ...
        call    out4                    ; ... and point i + 1 into RASP1
        dec     hl
        dec     hl
        dec     hl
        dec     hl                      ; back to point i + 1: the next segment's start
        ld      bc,RASCMD_P
        ld      a,RASCMD_RUN_M
        out     (c),a
        dec     d
        jr      nz,.seg
        ret

; out4, out2: 4 or 2 bytes from HL to the register port in BC and up
out4:   call    out2
out2:   ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ret

col:    db      9
tray:   dw      0
tline:  dw      0
tfar:   dw      0
msg1:   db      "48 rays took ", 0
msg2:   db      " us; a 300-pixel line ", 0
msg3:   db      " us; a 64001-pixel line ", 0
us:     db      " us", 13, 10, 0

box:    dw      16, 30, 199, 329        ; YMIN, XMIN, YMAX, XMAX, inclusive
whole:  dw      0, 0, 287, 359

; The rays' far ends, Y then X, round a rectangle twice the screen's size
; about the centre: from (-180, -108) to (540, 324)
ends:
k = 0
        DUP     12
        dw      CY - 216, CX - 360 + 60 * k     ; top, left to right
k = k + 1
        EDUP
k = 0
        DUP     12
        dw      CY - 216 + 36 * k, CX + 360     ; right, downwards
k = k + 1
        EDUP
k = 0
        DUP     12
        dw      CY + 216, CX + 360 - 60 * k     ; bottom, right to left
k = k + 1
        EDUP
k = 0
        DUP     12
        dw      CY + 216 - 36 * k, CX - 360     ; left, upwards
k = k + 1
        EDUP
ends_end:

; The patterned lines: RASPAT, then RASP0 and RASP1 (Y, X)
dashes: dw      0xFFFF, 212, 30, 216, 329       ; solid
        dw      0xFF00, 220, 30, 224, 329       ; long dashes
        dw      0xF0F0, 228, 30, 232, 329       ; short dashes
        dw      0xFF18, 236, 30, 240, 329       ; dash and dot
dashes_end:

; The zig-zags' 9 points each, Y then X
zigl:
k = 0
        DUP     9
        dw      252 + (k & 1) * 28, 40 + 16 * k
k = k + 1
        EDUP
zigr:
k = 0
        DUP     9
        dw      252 + (k & 1) * 28, 200 + 16 * k
k = k + 1
        EDUP

        align   2
linejob:
        dd      0xCA*MT | BPP8 | 9      ; RASCTRL: A ? B : C, 8 bpp, LINE; colour 9 (set per line)
        dw      CY, CX                  ; RASP0: Y, X: the centre
        dw      0, 0                    ; RASP1: per line
        dw      0, 0                    ; RASP2: not used by a line
        dd      SCREEN                  ; RASDPT: pixel (0, 0)
        dd      ROW                     ; RASSTRIDE: DSTRIDE
        dd      0xFFFF                  ; RASPAT: solid
        dd      0                       ; RASNEXT: none

farjob: dd      0xCC*MT | BPP8 | 0      ; D = B, colour 0
        dw      5, -32000               ; RASP0
        dw      5, 32000                ; RASP1
        dw      0, 0
        dd      SCREEN
        dd      ROW
        dd      0xFFFF
        dd      0

; The blitter: black, then a 1-pixel frame just outside the window, in a chain
clsjob: dd      0xCC*MT | BLTCTRL_BCONST_M | BPP8
        dd      0, SCREEN
        dw      ROW, 288
        dd      0
        dw      ROW, 0
        dw      0, 0                    ; black
        dd      .top
.top:   dd      0xCC*MT | BLTCTRL_BCONST_M | BPP8
        dd      0, SCREEN + 15 * ROW + 29
        dw      302, 1                  ; x = 29 to 330
        dd      0
        dw      ROW, 0
        dw      0x0707, 0               ; white
        dd      .bottom
.bottom: dd     0xCC*MT | BLTCTRL_BCONST_M | BPP8
        dd      0, SCREEN + 200 * ROW + 29
        dw      302, 1
        dd      0
        dw      ROW, 0
        dw      0x0707, 0
        dd      .left
.left:  dd      0xCC*MT | BLTCTRL_BCONST_M | BPP8
        dd      0, SCREEN + 16 * ROW + 29
        dw      1, 184                  ; y = 16 to 199
        dd      0
        dw      ROW, 0
        dw      0x0707, 0
        dd      .right
.right: dd      0xCC*MT | BLTCTRL_BCONST_M | BPP8
        dd      0, SCREEN + 16 * ROW + 330
        dw      1, 184
        dd      0
        dw      ROW, 0
        dw      0x0707, 0
        dd      0

        include "screen.inc"
