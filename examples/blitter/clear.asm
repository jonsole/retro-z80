; Example 6-1 (docs/guide/blitter.md): clear the screen with one blitter job.
; It shows a 360 x 288 8 bpp layer, fills it with blue on channel 2, and
; keeps the picture up until a key is pressed. Then it puts the console back
; and prints how long the fill took.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

start:  ld      a,BPP8                  ; the layer: 8 bpp,
        ld      hl,360                  ; 360 bytes a row
        call    scr_on                  ; also sets DMACON.DMAEN and BLTEN
        call    wait2                   ; wait until channel 2 is free
        ld      hl,clearjob
        call    load2                   ; the job into channel 2's registers
        ld      bc,TIME0_P
        in      e,(c)                   ; TIME in us: reading TIME0 captures all 4 bytes
        inc     b
        in      d,(c)
        ld      bc,DMX2_CHCTRL_P
        ld      a,DMX_CHCTRL_RUN_M
        out     (c),a                   ; go
        call    wait2                   ; CHSTAT.BUSY clear: the screen is blue
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
        db      OP_BLIT, BPP8|BCONST, 0 ; CTRL: draw with the value, 8 bpp
        db      0xCC                    ; MINTERM: D = B
        d24     0                       ; APT: no mask
        d24     0                       ; BPT: not read (BCONST)
        d24     SCREEN                  ; DPT
        d24     360                     ; WIDTH
        dw      288                     ; HEIGHT
        dw      0                       ; SHIFT
        dw      0                       ; ABSTRIDE: B is not read
        dw      360                     ; CDSTRIDE: the screen's row length
        dd      0x01010101              ; VALUE: colour 1, blue, in all four bytes
        d24     0                       ; NEXT: no more jobs
        db      0

        include "screen.inc"
