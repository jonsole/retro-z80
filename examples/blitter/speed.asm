; Example 6-8 (docs/guide/blitter.md): time blitter jobs with TIME.
; Each job starts on the first visible line of a frame, and TIME (in us)
; is read before RUN and after BUSY clears. Every job is timed twice: with
; the 360 x 288 8 bpp screen showing (L0 at 2x, the only layer), and with
; the layers' fetches off (DMACON.BPLEN clear). LDIR is timed the same way
; for comparison. The results are printed on the console.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

SCREEN2 equ     0x060000                ; physical: a second screen's worth of SRAM
SAVE    equ     0x07A000                ; physical: 1,024 bytes for a saved background
NTESTS  equ     7

start:  ld      a,BPP8
        ld      hl,360
        call    scr_on
        ld      ix,times                ; the display on
        call    all
        ld      bc,DMACON_P
        ld      a,DMACON_BPLEN_M        ; SETCLR 0: the layers' fetches off
        out     (c),a
        ld      ix,times + 2            ; the display off
        call    all
        ld      bc,DMACON_P
        ld      a,DMACON_SETCLR_M | DMACON_BPLEN_M
        out     (c),a
        call    scr_off

        ld      hl,head
        rst     18h                     ; PUTS
        ld      iy,tests
        ld      ix,times
        ld      d,NTESTS
.line:  ld      l,(iy+0)
        ld      h,(iy+1)
        rst     18h                     ; the test's name
        ld      l,(ix+0)
        ld      h,(ix+1)
        rst     28h
        db      0x08                    ; PUTDEC: with the display on
        ld      hl,sep
        rst     18h
        ld      l,(ix+2)
        ld      h,(ix+3)
        rst     28h
        db      0x08                    ; PUTDEC: with it off
        ld      hl,crlf
        rst     18h
        ld      bc,5
        add     iy,bc
        ld      bc,4
        add     ix,bc
        dec     d
        jr      nz,.line
        ret

; all: time every test; IX = where the first result goes (4 bytes a test)
all:    ld      iy,tests
        ld      d,NTESTS
.test:  push    de
        ld      l,(iy+2)
        ld      h,(iy+3)                ; the job
        ld      a,(iy+4)                ; how it starts
        call    time1
        ld      (ix+0),l
        ld      (ix+1),h
        ld      bc,5
        add     iy,bc
        ld      bc,4
        add     ix,bc
        pop     de
        dec     d
        jr      nz,.test
        ret

; time1: run one test; HL = its job, A = 0 RUN, 1 START (a list), 2 LDIR.
; Returns HL = the time in us.
time1:  push    af
        push    hl
        call    wait2
        call    frame                   ; the vertical blank has begun ...
        ld      bc,VIDSTAT_P
.vb:    in      a,(c)
        and     VIDSTAT_INVBLANK_M
        jr      nz,.vb                  ; ... and now it has ended: the first visible line
        pop     hl
        pop     af
        or      a
        jr      z,.run
        dec     a
        jr      z,.start
        call    t0                      ; LDIR: 16,384 bytes, 0x4000 to 0xA000
        ld      hl,0x4000
        ld      de,0xA000
        ld      bc,0x4000
        ldir
        jr      t1
.start: push    hl
        call    t0
        pop     hl
        call    start2
        jr      .wait
.run:   call    load2
        call    t0
        ld      bc,DMX2_CHCTRL_P
        ld      a,DMX_CHCTRL_RUN_M
        out     (c),a
.wait:  call    wait2
        ; fall into t1

; t1: HL = TIME now - the time t0 saved
t1:     ld      bc,TIME0_P
        in      l,(c)                   ; reading TIME0 captures all 4 bytes
        inc     b
        in      h,(c)
        ld      de,(t0time)
        or      a
        sbc     hl,de
        ret

; t0: save TIME's low 16 bits
t0:     ld      bc,TIME0_P
        in      e,(c)
        inc     b
        in      d,(c)
        ld      (t0time),de
        ret

t0time: dw      0

; The tests: the name, the job, how it starts (0 RUN, 1 START, 2 LDIR)
tests:  dw      n_fill, fill1
        db      0
        dw      n_fill2, fill2
        db      0
        dw      n_copy, copy1
        db      0
        dw      n_xor, xor1
        db      0
        dw      n_key, draw
        db      0
        dw      n_bob, restore
        db      1
        dw      n_ldir, 0
        db      2

times:  ds      NTESTS * 4              ; display on, display off

head:   db      "Job (bytes of D): us with the screen on / off", 13, 10, 0
n_fill: db      "Fill, one row (103680): ", 0
n_fill2: db     "Fill, 360 x 288 (103680): ", 0
n_copy: db      "Copy, one row (103680): ", 0
n_xor:  db      "XOR, reads C (103680): ", 0
n_key:  db      "32 x 32 with a key colour (1024): ", 0
n_bob:  db      "Restore, save, draw (3 x 1024): ", 0
n_ldir: db      "LDIR (16384): ", 0
sep:    db      " / ", 0
crlf:   db      13, 10, 0

        align   4
fill1:  db      OP_BLIT, BPP8|BCONST, 0, 0xCC
        d24     0, 0, SCREEN
        d24     360 * 288
        dw      1, 0, 0, 0
        dd      0x01010101
        d24     0
        db      0

fill2:  db      OP_BLIT, BPP8|BCONST, 0, 0xCC
        d24     0, 0, SCREEN
        d24     360
        dw      288, 0, 0, 360
        dd      0x05050505
        d24     0
        db      0

copy1:  db      OP_BLIT, BPP8, 0, 0xCC          ; the screen to SCREEN2
        d24     0, SCREEN, SCREEN2
        d24     360 * 288
        dw      1, 0, 0, 0
        dd      0
        d24     0
        db      0

xor1:   db      OP_BLIT, BPP8|BCONST, 0, 0x66   ; D = B XOR C: every pixel's colour XOR 7
        d24     0, 0, SCREEN
        d24     360 * 288
        dw      1, 0, 0, 0
        dd      0x07070707
        d24     0
        db      0

; Example 6-2's three jobs, the ball at (164, 100)
restore: db     OP_BLIT, BPP8, 0, 0xCC
        d24     0, SAVE, SCREEN + 100 * 360 + 164
        d24     32
        dw      32, 0, 32, 360
        dd      0
        d24     save
        db      0
save:   db      OP_BLIT, BPP8, 0, 0xCC
        d24     0, SCREEN + 100 * 360 + 164, SAVE
        d24     32
        dw      32, 0, 360, 32
        dd      0
        d24     draw
        db      0
draw:   db      OP_BLIT, BPP8|MASKKEY, 0, 0xCA
        d24     0, ball, SCREEN + 100 * 360 + 164
        d24     32
        dw      32, 0, 32, 360
        dd      0
        d24     0
        db      0

; The ball of Example 6-2: 32 x 32, colour 0 round it
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
