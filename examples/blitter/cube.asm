; Example 6-6 (docs/guide/blitter.md): a wireframe cube drawn by a chain of
; rasteriser LINE jobs. A cube turns and drifts across a 360 x 288 8 bpp
; screen, through a clip window with a frame round it. Each frame one chain
; of 24 descriptors runs: 12 lines draw last frame's cube in black, which
; removes it, and 12 draw this frame's. The points come from cube.inc,
; made by cube.py. A key ends it, and the console shows how long the chain
; took.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

ROW     equ     360                     ; bytes a row at 8 bpp

start:  ld      a,3                     ; the layer: 8 bpp,
        ld      hl,ROW                  ; 360 bytes a row
        call    scr_on
        ld      hl,clsjob               ; the blitter: black, and the frame round the window
        call    bltstart
        call    bltwait
        ld      hl,box
        call    setclip
        ld      de,cube_pts             ; the first frame: nothing to erase yet,
        ld      ix,erase                ; so the erase lines draw frame 0 in black
        call    fill
        ld      de,cube_pts
        ld      (cur),de
        ld      ix,draw
        call    fill

loop:   call    frame                   ; once a frame, in the vertical blank
        call    raswait                 ; last frame's chain is long done
        call    t0
        ld      hl,erase
        call    rasstart                ; 12 lines in black, then 12 in colour
        call    raswait
        call    t1
        ld      (took),hl
        ld      de,(cur)                ; the cube on the screen now ...
        ld      ix,erase
        call    fill                    ; ... is the one to erase next
        ld      hl,(cur)
        ld      de,32
        add     hl,de                   ; the next frame's points
        ld      de,cube_pts_end
        or      a
        sbc     hl,de
        add     hl,de
        jr      nz,.same
        ld      hl,cube_pts             ; round again
.same:  ld      (cur),hl
        ex      de,hl
        ld      ix,draw
        call    fill
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
        ret                             ; back to the monitor

; fill: the 12 edges' ends, from the frame's points at DE, into RASP0 and
; RASP1 of the 12 descriptors at IX
fill:   ld      (pts),de
        ld      iy,edges
        ld      a,12
.edge:  ex      af,af'
        push    ix
        pop     de
        inc     de
        inc     de
        inc     de
        inc     de                      ; DE = the descriptor's RASP0
        ld      a,(iy+0)
        call    .copy                   ; the first point into RASP0 ...
        ld      a,(iy+1)
        call    .copy                   ; ... and the second into RASP1
        ld      bc,32
        add     ix,bc
        inc     iy
        inc     iy
        ex      af,af'
        dec     a
        jr      nz,.edge
        ret
.copy:  add     a,a
        add     a,a                     ; 4 bytes a point: Y, X
        ld      l,a
        ld      h,0
        ld      bc,(pts)
        add     hl,bc
        ldi
        ldi
        ldi
        ldi
        ret

cur:    dw      0
pts:    dw      0
took:   dw      0
msg:    db      "The chain took ", 0
us:     db      " us", 13, 10, 0

box:    dw      24, 40, 263, 319        ; YMIN, XMIN, YMAX, XMAX, inclusive

; Point i is the corner whose x, y and z are given by its bits 0, 1 and 2,
; so an edge joins two points that differ in one bit
edges:  db      0,1, 2,3, 4,5, 6,7      ; along x
        db      0,2, 1,3, 4,6, 5,7      ; along y
        db      0,4, 1,5, 2,6, 3,7      ; along z

; 24 LINE descriptors in one chain: 12 in black, then 12 in bright cyan.
; Only their points change from frame to frame.
    MACRO EDGE colour, nxt
        dd      0xCC*MT | BPP8 | colour ; RASCTRL: D = B, 8 bpp, LINE
        dw      0, 0, 0, 0              ; RASP0, RASP1: set by fill
        dw      0, 0                    ; RASP2: not used
        dd      SCREEN                  ; RASDPT
        dd      ROW                     ; RASSTRIDE
        dd      0xFFFF                  ; RASPAT: solid
        dd      nxt                     ; RASNEXT
    ENDM
        align   2
erase:
k = 1
        DUP     12
        EDGE    0, erase + 32 * k       ; black; the last one goes on to draw
k = k + 1
        EDUP
draw:
k = 1
        DUP     11
        EDGE    13, draw + 32 * k       ; bright cyan
k = k + 1
        EDUP
        EDGE    13, 0                   ; the end of the chain

; The blitter: black, then a 1-pixel frame just outside the window, in a chain
clsjob: dd      0xCC*MT | BLTCTRL_BCONST_M | BPP8
        dd      0, SCREEN
        dw      ROW, 288
        dd      0
        dw      ROW, 0
        dw      0, 0                    ; black
        dd      .top
.top:   dd      0xCC*MT | BLTCTRL_BCONST_M | BPP8
        dd      0, SCREEN + 23 * ROW + 39
        dw      282, 1                  ; x = 39 to 320
        dd      0
        dw      ROW, 0
        dw      0x0707, 0               ; white
        dd      .bottom
.bottom: dd     0xCC*MT | BLTCTRL_BCONST_M | BPP8
        dd      0, SCREEN + 264 * ROW + 39
        dw      282, 1
        dd      0
        dw      ROW, 0
        dw      0x0707, 0
        dd      .left
.left:  dd      0xCC*MT | BLTCTRL_BCONST_M | BPP8
        dd      0, SCREEN + 24 * ROW + 39
        dw      1, 240                  ; y = 24 to 263
        dd      0
        dw      ROW, 0
        dw      0x0707, 0
        dd      .right
.right: dd      0xCC*MT | BLTCTRL_BCONST_M | BPP8
        dd      0, SCREEN + 24 * ROW + 320
        dw      1, 240
        dd      0
        dw      ROW, 0
        dw      0x0707, 0
        dd      0

        include "cube.inc"
        include "screen.inc"
