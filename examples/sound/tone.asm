; Sound on the board (ticket #113): a first listen. Two channels play a
; 32-sample sine wave from SRAM, looped: channel 0 at A (440 Hz) on the
; left, channel 1 at C sharp (554 Hz) on the right. The border turns green
; once both are started. Press the reset button to stop.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

PHYS    equ     0                       ; the program map: a Z80 address is its own physical address
; STEP is 4.16 fixed point: samples of the block moved per output sample.
; At the default 48.008 kHz, with 32 samples a cycle:
;   STEP = f x 32 / 48008 x 65536
STEP_A  equ     19222                   ; 440.0 Hz
STEP_CS equ     24218                   ; 554.4 Hz

    MACRO WREG xp, xv                   ; write xv to register port xp
        ld      bc,xp
        ld      a,xv
        out     (c),a
    ENDM
    ; One channel: 8-bit samples, looped, LC and LEN the wave, its step and
    ; volumes (0-64)
    MACRO CHAN ctrl, lc, len, step, vr, vl
        WREG    ctrl, 0                 ; CTRL: 8-bit, interpolated, looped
        WREG    ctrl + 0x0400, low (lc)
        WREG    ctrl + 0x0500, high (lc)
        WREG    ctrl + 0x0600, (lc) >> 16
        WREG    ctrl + 0x0800, low (len)
        WREG    ctrl + 0x0900, high (len)
        WREG    ctrl + 0x0A00, 0
        WREG    ctrl + 0x0C00, low (step)
        WREG    ctrl + 0x0D00, high (step)
        WREG    ctrl + 0x0E00, (step) >> 16
        WREG    ctrl + 0x1000, vr       ; VOL: R in byte 0, L in byte 2
        WREG    ctrl + 0x1100, 0
        WREG    ctrl + 0x1200, vl
    ENDM

start:  di
        CHAN    AUD0_CTRL_P, wave + PHYS, 32, STEP_A, 0, 48
        CHAN    AUD1_CTRL_P, wave + PHYS, 32, STEP_CS, 48, 0
        WREG    AUDDMA_P, AUDDMA_SETCLR_M | 0x03
        WREG    DMACON_P, DMACON_SETCLR_M | DMACON_DMAEN_M | DMACON_AUDEN_M

        ld      bc,BGCOLOR0_P           ; border green: blue, green, red
        xor     a
        out     (c),a
        ld      bc,BGCOLOR1_P
        ld      a,0xC0
        out     (c),a
        ld      bc,BGCOLOR2_P
        xor     a
        out     (c),a
        jr      $

        align   2
; one cycle of a sine, 32 signed 8-bit samples, peak 100
wave:   db      0, 20, 38, 56, 71, 83, 92, 98
        db      100, 98, 92, 83, 71, 56, 38, 20
        db      0, -20, -38, -56, -71, -83, -92, -98
        db      -100, -98, -92, -83, -71, -56, -38, -20
