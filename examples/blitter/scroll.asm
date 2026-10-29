; Example 6-4 (docs/guide/blitter.md): scroll the screen down by 8 lines a frame.
; Each frame one backwards copy (DESC) moves the top 280 lines down by 8,
; and a fill paints the 8 new lines at the top, a new colour every three
; frames, so bands of colour roll down the screen. A key ends it and
; prints how long the last scroll took.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

start:  ld      a,BPP8
        ld      hl,360
        call    scr_on
        ld      hl,clearjob
        call    run2                    ; start from a black screen

loop:   call    frame
        ld      hl,scrolljob
        call    wait2
        call    load2
        ld      bc,TIME0_P
        in      e,(c)                   ; TIME in us: reading TIME0 captures all 4 bytes
        inc     b
        in      d,(c)
        ld      bc,DMX2_CHCTRL_P
        ld      a,DMX_CHCTRL_RUN_M
        out     (c),a                   ; the scroll
        call    wait2
        ld      bc,TIME0_P
        in      l,(c)
        inc     b
        in      h,(c)
        or      a
        sbc     hl,de
        ld      (took),hl
        call    colour                  ; this frame's colour into the fill
        ld      hl,topjob
        call    run2                    ; the 8 new lines
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

; colour: the next band's colour into topjob's VALUE, a new one every 3 frames
colour: ld      hl,count
        dec     (hl)
        jr      nz,.same
        ld      (hl),3
        ld      hl,(band)
        inc     hl
        ld      (band),hl
.same:  ld      hl,(band)
        ld      a,(hl)
        or      a
        jr      nz,.got
        ld      hl,colours              ; the end of the list: round again
        ld      (band),hl
        ld      a,(hl)
.got:   ld      hl,topjob + DMX_VALUE
        ld      (hl),a                  ; the colour in all four bytes of VALUE
        inc     hl
        ld      (hl),a
        inc     hl
        ld      (hl),a
        inc     hl
        ld      (hl),a
        ret

count:  db      3
band:   dw      colours
colours: db     1, 5, 4, 6, 3, 2, 7, 0  ; blue, cyan, green, yellow, magenta, red, white; 0 ends
took:   dw      0
msg:    db      "The last scroll took ", 0
us:     db      " us", 13, 10, 0

scrolljob:
        db      OP_BLIT, BPP8|DESC, 0, 0xCC     ; copy, backwards
        d24     0
        d24     SCREEN                          ; BPT: the top of the screen
        d24     SCREEN + 8*360                  ; DPT: 8 lines further down
        d24     360
        dw      280                             ; the 280 lines that stay visible
        dw      0
        dw      360, 360
        dd      0
        d24     0
        db      0

topjob: db      OP_BLIT, BPP8|BCONST, 0, 0xCC   ; fill the top 8 lines
        d24     0, 0, SCREEN
        d24     360
        dw      8, 0, 0, 360
        dd      0                               ; VALUE: set by colour
        d24     0
        db      0

clearjob:
        db      OP_BLIT, BPP8|BCONST, 0, 0xCC   ; the whole screen black
        d24     0, 0, SCREEN
        d24     360 * 288                       ; one row of 103,680 bytes
        dw      1, 0, 0, 0
        dd      0
        d24     0
        db      0

        include "screen.inc"
