; Example 6-2 (docs/guide/blitter.md): one moving object, saved, drawn and restored.
; A 32 x 32 ball bounces over a striped background. Each frame a chain of
; three blitter jobs puts back the background where the ball was,
; saves the background where it goes, and draws it there with colour 0
; transparent. A key ends it and puts the console back.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

SAVE    equ     0x060000                ; physical: 1,024 bytes for the saved background

start:  ld      a,3                     ; the layer: 8 bpp,
        ld      hl,360                  ; 360 bytes a row
        call    scr_on
        ld      hl,bands                ; the background: 8 fills in a chain
        call    bltstart
        call    bltwait
        call    place                   ; the ball's first place into the jobs
        ld      hl,save                 ; the first frame has nothing to restore
        call    bltstart

loop:   call    frame                   ; once a frame, in the vertical blank
        call    bltwait                 ; last frame's chain is long done
        ld      hl,(newpos2)            ; where the ball is now ...
        ld      (oldpos),hl
        ld      a,(newpos2+2)
        ld      (oldpos+2),a            ; ... is where to restore next
        call    move
        call    place
        ld      hl,restore              ; restore, save, draw
        call    bltstart
        rst     20h                     ; POLLC: a key ends it
        jr      z,loop
        call    scr_off
        ret

; move: the ball on by (dx, dy), bouncing at the edges
move:   ld      hl,(xpos)
        ld      de,(dx)
        add     hl,de
        ld      (xpos),hl
        ld      a,l                     ; x runs 0-328 (360 - 32)
        or      h
        jr      z,.xflip
        ld      bc,328
        or      a
        sbc     hl,bc
        jr      c,.y
.xflip: ld      hl,0
        sbc     hl,de                   ; dx = -dx (carry is clear here)
        ld      (dx),hl
.y:     ld      hl,(ypos)
        ld      de,(dy)
        add     hl,de
        ld      (ypos),hl
        ld      a,l                     ; y runs 0-256 (288 - 32)
        or      h
        jr      z,.yflip
        ld      bc,256
        or      a
        sbc     hl,bc
        ret     c
.yflip: ld      hl,0
        or      a
        sbc     hl,de
        ld      (dy),hl
        ret

; place: SCREEN + y * 360 + x into the save and draw jobs
place:  ld      hl,(ypos)
        add     hl,hl
        add     hl,hl
        add     hl,hl                   ; y * 8
        ld      d,h
        ld      e,l
        add     hl,hl
        add     hl,hl                   ; y * 32
        ld      b,h
        ld      c,l
        add     hl,hl                   ; y * 64
        add     hl,bc
        add     hl,de                   ; y * 104
        ld      de,(xpos)
        add     hl,de                   ; y * 104 + x: at most 26,952
        ld      a,(ypos)
        add     a,h
        ld      h,a                     ; + y * 256: 360 = 256 + 104
        ld      a,(ypos+1)
        adc     a,SCREEN >> 16          ; A:HL = the 24-bit address
        ld      (newpos1),hl
        ld      (newpos1+2),a
        ld      (newpos2),hl
        ld      (newpos2+2),a
        ret

xpos:   dw      40
ypos:   dw      30
dx:     dw      2
dy:     dw      1

; The three jobs, one chain. BLTNEXT and BLTDESC take a job's own address:
; in the program map it is also its physical address.
        align   2
restore: dd     0xCC*MT | BPP8          ; copy
        dd      SAVE                    ; BLTBPT: the saved background
oldpos: dd      SCREEN                  ; BLTDPT: where the ball was (set each frame)
        dw      32, 32                  ; WIDTH, HEIGHT
        dd      0
        dw      360, 32                 ; DSTRIDE: the screen's rows; BSTRIDE: SAVE's
        dw      0, 0
        dd      save                    ; BLTNEXT

save:   dd      0xCC*MT | BPP8          ; copy
newpos1: dd     SCREEN                  ; BLTBPT: where the ball goes (set each frame)
        dd      SAVE                    ; BLTDPT
        dw      32, 32
        dd      0
        dw      32, 360                 ; DSTRIDE: now SAVE's rows; BSTRIDE: the screen's
        dw      0, 0
        dd      draw

draw:   dd      0xCA*MT | MASKKEY | BPP8 ; A ? B : C, KEY 0: colour 0 is transparent
        dd      ball                    ; BLTBPT: the ball
newpos2: dd     SCREEN                  ; BLTDPT: where the ball goes (set each frame)
        dw      32, 32
        dd      0
        dw      360, 32
        dw      0, 0
        dd      0                       ; BLTNEXT: the end of the chain

; The background: eight bands of 36 rows, each a fill
    MACRO BAND n, colour
        dd      0xCC*MT | BLTCTRL_BCONST_M | BPP8
        dd      0, SCREEN + n * 36 * 360
        dw      360, 36
        dd      0
        dw      360, 0
        dw      colour * 0x0101, 0      ; VALUE: the colour in both pixels of a word
        IF n < 7
        dd      $ + 4                   ; BLTNEXT: the band after this one
        ELSE
        dd      0
        ENDIF
    ENDM
bands:  BAND    0, 1
        BAND    1, 5
        BAND    2, 4
        BAND    3, 6
        BAND    4, 3
        BAND    5, 2
        BAND    6, 1
        BAND    7, 5

; The ball: 32 x 32 at 8 bpp, bright white with a bright red rim, 0 outside
ball:
r = 0
        DUP     32
c = 0
        DUP     32
d2 = (2 * c - 31) * (2 * c - 31) + (2 * r - 31) * (2 * r - 31)
        IF d2 <= 24 * 24
        db      15
        ELSE
        IF d2 <= 31 * 31
        db      10
        ELSE
        db      0
        ENDIF
        ENDIF
c = c + 1
        EDUP
r = r + 1
        EDUP

        include "screen.inc"
