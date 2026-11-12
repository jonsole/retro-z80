; Example 6-8 (docs/guide/blitter.md): time blitter and rasteriser jobs with TIME.
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
NTESTS  equ     9

start:  ld      a,3                     ; the layer: 8 bpp,
        ld      hl,360                  ; 360 bytes a row
        call    scr_on
        ld      hl,whole
        call    setclip                 ; the rasteriser's window: the screen
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

; time1: run one test; HL = its job, A = 0 blitter RUN, 1 blitter START
; (a chain), 2 LDIR, 3 rasteriser RUN. Returns HL = the time in us.
time1:  push    af
        push    hl
        call    bltwait
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
        dec     a
        jr      z,.ldir
        call    rasload                 ; the rasteriser
        call    t0
        ld      bc,RASCMD_P
        ld      a,RASCMD_RUN_M
        out     (c),a
        call    raswait
        jp      t1
.ldir:  call    t0                      ; LDIR: 16,384 bytes, 0x4000 to 0xA000
        ld      hl,0x4000
        ld      de,0xA000
        ld      bc,0x4000
        ldir
        jp      t1
.start: call    t0
        call    bltstart
        jr      .wait
.run:   call    bltload
        call    t0
        ld      bc,BLTCMD_P
        ld      a,BLTCMD_RUN_M
        out     (c),a
.wait:  call    bltwait
        jp      t1

; The tests: the name, the job, how it starts (0 RUN, 1 START, 2 LDIR, 3 RAS)
tests:  dw      n_fill, fill1
        db      0
        dw      n_copy, copy1
        db      0
        dw      n_xor, xor1
        db      0
        dw      n_key, draw
        db      0
        dw      n_bob, restore
        db      1
        dw      n_empty, empty
        db      1
        dw      n_line, line1
        db      3
        dw      n_xline, line2
        db      3
        dw      n_ldir, 0
        db      2

times:  ds      NTESTS * 4              ; display on, display off

head:   db      "Job (bytes of D): us with the screen on / off", 13, 10, 0
n_fill: db      "Fill 360 x 288 (103680): ", 0
n_copy: db      "Copy 360 x 288 (103680): ", 0
n_xor:  db      "XOR, reads C (103680): ", 0
n_key:  db      "32 x 32 with a key colour (1024): ", 0
n_bob:  db      "Restore, save, draw (3 x 1024): ", 0
n_empty: db     "8 empty jobs in a chain: ", 0
n_line: db      "Line, 300 pixels: ", 0
n_xline: db     "Line, 300 pixels, XOR: ", 0
n_ldir: db      "LDIR (16384): ", 0
sep:    db      " / ", 0
crlf:   db      13, 10, 0

whole:  dw      0, 0, 287, 359          ; YMIN, XMIN, YMAX, XMAX

        align   2
fill1:  dd      0xCC*MT | BLTCTRL_BCONST_M | BPP8
        dd      0, SCREEN
        dw      360, 288
        dd      0
        dw      360, 0
        dw      0x0101, 0
        dd      0

copy1:  dd      0xCC*MT | BPP8          ; the screen to SCREEN2
        dd      SCREEN, SCREEN2
        dw      360, 288
        dd      0
        dw      360, 360
        dw      0, 0
        dd      0

xor1:   dd      0x66*MT | BLTCTRL_BCONST_M | BPP8 ; D = B XOR C: every pixel's colour XOR 7
        dd      0, SCREEN
        dw      360, 288
        dd      0
        dw      360, 0
        dw      0x0707, 0
        dd      0

; Example 6-2's three jobs, the ball at (164, 100)
restore: dd     0xCC*MT | BPP8
        dd      SAVE, SCREEN + 100 * 360 + 164
        dw      32, 32
        dd      0
        dw      360, 32
        dw      0, 0
        dd      save
save:   dd      0xCC*MT | BPP8
        dd      SCREEN + 100 * 360 + 164, SAVE
        dw      32, 32
        dd      0
        dw      32, 360
        dw      0, 0
        dd      draw
draw:   dd      0xCA*MT | MASKKEY | BPP8
        dd      ball, SCREEN + 100 * 360 + 164
        dw      32, 32
        dd      0
        dw      360, 32
        dw      0, 0
        dd      0

; Eight jobs of no width: only their descriptors are loaded
empty:
k = 1
        DUP     8
        dd      0xCC*MT | BLTCTRL_BCONST_M | BPP8
        dd      0, SCREEN
        dw      0, 1                    ; WIDTH 0: the job does nothing
        dd      0
        dw      0, 0, 0, 0
        IF k < 8
        dd      empty + 32 * k
        ELSE
        dd      0
        ENDIF
k = k + 1
        EDUP

line1:  dd      0xCC*MT | BPP8 | 14     ; D = B: a pixel is one write
        dw      20, 30, 120, 329        ; RASP0, RASP1: Y, X
        dw      0, 0
        dd      SCREEN, 360, 0xFFFF, 0

line2:  dd      0x66*MT | BPP8 | 7      ; D = B XOR C: a pixel is a read and a write
        dw      20, 30, 120, 329
        dw      0, 0
        dd      SCREEN, 360, 0xFFFF, 0

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
