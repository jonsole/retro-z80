; Example 6-6 (docs/guide/blitter.md): a wireframe cube drawn by EDGES jobs.
; A cube turns and drifts across a 360 x 288 8 bpp screen, through a clip
; rectangle with a frame round it. Each frame a list of two EDGES jobs
; runs: the first draws last frame's cube in black, which removes it, the
; second draws this frame's. The points come from cube.inc, made by
; cube.py. A key ends it, and the console shows how long the list took.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

ROW     equ     360                     ; bytes a row at 8 bpp

start:  ld      a,BPP8
        ld      hl,ROW
        call    scr_on
        ld      hl,clsjob               ; black, and the frame round the rectangle
        call    start2
        call    wait2
        ld      hl,box
        call    setclip
        ld      hl,cube_pts             ; the first frame: nothing to erase yet,
        ld      (erase + 4),hl          ; so erase draws frame 0 in black
        ld      (draw + 4),hl

loop:   call    frame                   ; once a frame, in the vertical blank
        call    wait2                   ; last frame's list is long done
        ld      hl,(draw + 4)           ; the cube on the screen now ...
        ld      (erase + 4),hl          ; ... is the one to erase
        ld      de,32
        add     hl,de                   ; the next frame's points
        ld      de,cube_pts_end
        or      a
        sbc     hl,de
        add     hl,de
        jr      nz,.same
        ld      hl,cube_pts             ; round again
.same:  ld      (draw + 4),hl           ; APT: POINTS
        call    t0
        ld      hl,erase
        call    start2                  ; erase, then draw
        call    wait2
        call    t1
        ld      (took),hl
        rst     20h                     ; POLLC: a key ends it
        jr      z,loop

        ld      hl,whole                ; the clip rectangle as after reset
        call    setclip
        call    scr_off
        ld      hl,msg
        rst     18h                     ; PUTS
        ld      hl,(took)
        rst     28h
        db      0x08                    ; PUTDEC
        ld      hl,us
        rst     18h
        ret                             ; back to the monitor

took:   dw      0
msg:    db      "Erase and draw took ", 0
us:     db      " us", 13, 10, 0

; setclip: the 8 bytes at HL into CLIPXMIN ... CLIPYMAX (ports in a row)
setclip:
        ld      bc,CLIPXMIN_P
.next:  ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,b
        cp      (high CLIPXMIN_P) + 8
        jr      nz,.next
        ret

box:    dw      40, 319, 24, 263        ; XMIN, XMAX, YMIN, YMAX, inclusive
whole:  dw      -32768, 32767, -32768, 32767

; t0: save TIME's low 16 bits; t1: HL = TIME now - that
t0:     ld      bc,TIME0_P
        in      e,(c)                   ; reading TIME0 captures all 4 bytes
        inc     b
        in      d,(c)
        ld      (t0time),de
        ret
t1:     ld      bc,TIME0_P
        in      l,(c)
        inc     b
        in      h,(c)
        ld      de,(t0time)
        or      a
        sbc     hl,de
        ret
t0time: dw      0

; The cube's 12 edges: the numbers of their two points. Point i is at
; x = bit 0, y = bit 1, z = bit 2 of i, so an edge joins two points that
; differ in one bit.
        align   2
edges:  db      0,1, 2,3, 4,5, 6,7      ; along x
        db      0,2, 1,3, 4,6, 5,7      ; along y
        db      0,4, 1,5, 2,6, 3,7      ; along z

        align   4
erase:  db      OP_EDGES, BPP8, 0       ; CTRL: EDGES, 8 bpp
        db      0xCA                    ; MINTERM: A ? B : C
        d24     0                       ; APT: POINTS, last frame's (set each frame)
        d24     edges                   ; BPT: EDGES
        d24     SCREEN                  ; DPT: the origin, pixel (0, 0)
        d24     12                      ; WIDTH: 12 edges
        dw      0                       ; HEIGHT: not used
        dw      0                       ; SHIFT: DBIT 0 at 8 bpp
        dw      0                       ; ABSTRIDE: not used
        dw      ROW                     ; CDSTRIDE: the screen's row length
        dd      0xFFFF0000              ; VALUE: a solid pattern, colour 0 (black)
        d24     draw                    ; NEXT
        db      0

draw:   db      OP_EDGES, BPP8, 0
        db      0xCA
        d24     0                       ; APT: POINTS, this frame's (set each frame)
        d24     edges
        d24     SCREEN
        d24     12
        dw      0, 0, 0, ROW
        dd      0xFFFF000D              ; VALUE: solid, colour 13, bright cyan
        d24     0                       ; NEXT: the end
        db      0

; Black, then a 1-pixel frame just outside the clip rectangle, in a list
clsjob: db      OP_BLIT, BPP8|BCONST, 0, 0xCC
        d24     0, 0, SCREEN
        d24     ROW
        dw      288, 0, 0, ROW
        dd      0                       ; black
        d24     .top
        db      0
.top:   db      OP_BLIT, BPP8|BCONST, 0, 0xCC
        d24     0, 0, SCREEN + 23 * ROW + 39
        d24     282                     ; x = 39 to 320
        dw      1, 0, 0, ROW
        dd      0x07070707              ; white
        d24     .bottom
        db      0
.bottom: db     OP_BLIT, BPP8|BCONST, 0, 0xCC
        d24     0, 0, SCREEN + 264 * ROW + 39
        d24     282
        dw      1, 0, 0, ROW
        dd      0x07070707
        d24     .left
        db      0
.left:  db      OP_BLIT, BPP8|BCONST, 0, 0xCC
        d24     0, 0, SCREEN + 24 * ROW + 39
        d24     1                       ; y = 24 to 263
        dw      240, 0, 0, ROW
        dd      0x07070707
        d24     .right
        db      0
.right: db      OP_BLIT, BPP8|BCONST, 0, 0xCC
        d24     0, 0, SCREEN + 24 * ROW + 320
        d24     1
        dw      240, 0, 0, ROW
        dd      0x07070707
        d24     0
        db      0

        align   2
        include "cube.inc"

        include "screen.inc"
