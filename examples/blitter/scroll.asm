; Example 6-4 (docs/guide/blitter.md): overlapping copies, scrolling two ways.
; Each frame a chain of four blitter jobs scrolls the top half of the
; screen right by 4 pixels (a copy right to left, RTL) and the bottom half
; down by 8 rows (a copy with the rows bottom-up, negative strides), and
; fills the new columns and rows with a colour that changes every three
; frames. Stripes move right across the top and bands roll down the bottom.
; A key ends it and prints how long the last frame's chain took.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

ROW     equ     360                     ; bytes a row at 8 bpp

start:  ld      a,3                     ; the layer: 8 bpp,
        ld      hl,ROW                  ; 360 bytes a row
        call    scr_on
        ld      hl,clearjob
        call    bltrun                  ; start from a black screen

loop:   call    frame
        call    colour                  ; this frame's colour into the two fills
        ld      bc,TIME0_P
        in      e,(c)                   ; TIME in us: reading TIME0 captures all 4 bytes
        inc     b
        in      d,(c)
        ld      hl,right
        call    bltstart                ; the chain: right, left edge, down, top rows
        call    bltwait
        ld      bc,TIME0_P
        in      l,(c)
        inc     b
        in      h,(c)
        or      a
        sbc     hl,de
        ld      (took),hl
        rst     20h                     ; POLLC: a key ends it
        jr      z,loop
        call    scr_off
        ld      hl,msg
        rst     18h                     ; PUTS
        ld      hl,(took)
        rst     28h
        db      0x08                    ; PUTDEC
        ld      hl,us
        rst     18h
        ret

; colour: the next colour into both fills' VALUE, a new one every 3 frames
colour: ld      hl,count
        dec     (hl)
        jr      nz,.same
        ld      (hl),3
        ld      a,(band)
        inc     a
        and     7
        ld      (band),a
.same:  ld      a,(band)
        ld      (edgejob + 0x18),a      ; VALUE: colour in both pixels of the word
        ld      (edgejob + 0x19),a
        ld      (topjob + 0x18),a
        ld      (topjob + 0x19),a
        ret

count:  db      1
band:   db      0
took:   dw      0
msg:    db      "The last frame's chain took ", 0
us:     db      " us", 13, 10, 0

        align   2
clearjob:
        dd      0xCC*MT | BLTCTRL_BCONST_M | BPP8 ; fill with colour 0
        dd      0, SCREEN
        dw      360, 288
        dd      0
        dw      ROW, 0
        dw      0, 0
        dd      0

; The top half, rows 0-143, right by 4 pixels. Source and destination share
; their rows, and the destination is to the right: so RTL, and the pointers
; name each row's last pixel (source x = 355, destination x = 359).
right:  dd      0xCC*MT | BLTCTRL_RTL_M | BPP8 ; copy, each row right to left
        dd      SCREEN + 355            ; BLTBPT: row 0's last source pixel
        dd      SCREEN + 359            ; BLTDPT: row 0's last destination pixel
        dw      356, 144                ; WIDTH, HEIGHT
        dd      0
        dw      ROW, ROW                ; DSTRIDE, BSTRIDE: rows top-down as usual
        dw      0, 0
        dd      edgejob

edgejob: dd     0xCC*MT | BLTCTRL_BCONST_M | BPP8 ; the 4 new columns on the left
        dd      0, SCREEN
        dw      4, 144
        dd      0
        dw      ROW, 0
        dw      0, 0                    ; VALUE: set by colour
        dd      down

; The bottom half, rows 144-287, down by 8 rows: source rows 144-279 to
; destination rows 152-287. The destination is below, so the rows go
; bottom-up: the pointers name the last row, and the strides are negative.
down:   dd      0xCC*MT | BPP8          ; copy
        dd      SCREEN + 279 * ROW      ; BLTBPT: the last source row
        dd      SCREEN + 287 * ROW      ; BLTDPT: the last destination row
        dw      360, 136                ; WIDTH, HEIGHT
        dd      0
        dw      -ROW, -ROW              ; DSTRIDE, BSTRIDE: up a row each time
        dw      0, 0
        dd      topjob

topjob: dd      0xCC*MT | BLTCTRL_BCONST_M | BPP8 ; the 8 new rows at the top of the half
        dd      0, SCREEN + 144 * ROW
        dw      360, 8
        dd      0
        dw      ROW, 0
        dw      0, 0                    ; VALUE: set by colour
        dd      0                       ; the end of the chain

        include "screen.inc"
