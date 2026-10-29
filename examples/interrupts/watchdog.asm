; Example 2-4 (docs/guide/interrupts.md): the watchdog.
; Turns the watchdog on with half a second's grace, kicks it every frame
; for two seconds, then stops kicking, as a hung program would. Half a
; second later the computer resets, and the boot ROM says
; "Reset: watchdog."

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

start:  ld      hl,title
        rst     0x18                    ; PUTS

        ld      bc,WDTIME0_P            ; 500 ms between kicks
        ld      hl,500
        out     (c),l
        inc     b
        out     (c),h
        ld      bc,WDCTRL_P
        ld      a,WDCTRL_EN_M
        out     (c),a                   ; on: the time starts

        ld      e,100                   ; 100 frames: 2 seconds
.frame: ld      bc,VIDSTAT_P            ; wait for the next frame
        ld      a,VIDSTAT_VBLANK_M
        out     (c),a
.wait:  in      a,(c)
        and     VIDSTAT_VBLANK_M
        jr      z,.wait
        ld      bc,WDKICK_P
        ld      a,WDKICK_MAGIC
        out     (c),a                   ; kick: 0x5A, and only 0x5A
        dec     e
        jr      nz,.frame

        ld      hl,s_hang
        rst     0x18
.hang:  jr      .hang                   ; no more kicks: reset in 500 ms

title:  db      13, 10, "Kicking the watchdog for 2 seconds ...", 13, 10, 0
s_hang: db      "... and now not.", 13, 10, 0
