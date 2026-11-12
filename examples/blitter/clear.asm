; Example 6-1 (docs/guide/blitter.md): clear the screen with one blitter job.
; It shows a 360 x 288 8 bpp layer, fills it with blue from the job
; registers, and keeps the picture up until a key is pressed. Then it puts
; the console back and prints how long the fill took.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

start:  ld      a,3                     ; the layer: 8 bpp,
        ld      hl,360                  ; 360 bytes a row
        call    scr_on                  ; also sets DMACON's DMAEN and BLTEN
        call    bltwait                 ; Step 1: wait until the blitter is idle
        ld      hl,clearjob
        call    bltload                 ; Step 2: the job into the job registers
        ld      bc,TIME0_P
        in      e,(c)                   ; TIME in us: reading TIME0 captures all 4 bytes
        inc     b
        in      d,(c)
        ld      bc,BLTCMD_P
        ld      a,BLTCMD_RUN_M
        out     (c),a                   ; Step 3: go
        call    bltwait                 ; Step 4: BUSY clear, the screen is blue
        ld      bc,TIME0_P
        in      l,(c)
        inc     b
        in      h,(c)
        or      a
        sbc     hl,de
        ld      (took),hl               ; us, to print once the console is back
        call    waitkey                 ; the picture until a key is pressed
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
msg:    db      "The fill took ", 0
us:     db      " us", 13, 10, 0

clearjob:
        dd      0xCC*MT | BLTCTRL_BCONST_M | BPP8 ; BLTCTRL: D = B, B is VALUE, 8 bpp
        dd      0                       ; BLTBPT: not read
        dd      SCREEN                  ; BLTDPT: the first pixel, BIT 0
        dw      360, 288                ; BLTSIZE: WIDTH, HEIGHT
        dd      0                       ; BLTAPT: no mask image
        dw      360, 0                  ; BLTSTRIDE: DSTRIDE (the screen's rows), BSTRIDE
        dw      0x0101, 0               ; BLTVALUE: VALUE (colour 1 in both pixels), ASTRIDE
        dd      0                       ; BLTNEXT: no more jobs

        include "screen.inc"
