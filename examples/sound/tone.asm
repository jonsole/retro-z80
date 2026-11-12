; Example 10-1 (docs/guide/sound.md): a first tone. Two channels play one
; cycle of a sine wave, 32 signed 8-bit samples, over and over: channel 0
; at A (440 Hz) on the left, channel 1 at C sharp (554 Hz) on the right.
; A key stops them, and the program ends.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

; STEP: samples of the block per output sample, 4.16 fixed point. At the
; output rate after reset, 48,008 Hz, with 32 samples to a cycle:
;   STEP = f x 32 x 65536 / 48008
STEP_A  equ     19222                   ; 440.0 Hz
STEP_CS equ     24218                   ; 554.4 Hz

; A channel's registers as they lie in the custom block, CTRL to VOL:
; 19 bytes, with the empty bytes between them
    MACRO AUDCHAN ctrl, lc, len, step, vr, vl
        db      ctrl, 0, 0, 0           ; CTRL (+0x00)
        d24     lc                      ; LC   (+0x04), low byte first
        db      0
        d24     len                     ; LEN  (+0x08)
        db      0
        d24     step                    ; STEP (+0x0C)
        db      0
        db      vr, 0, vl               ; VOL  (+0x10): right, empty, left
    ENDM

start:  ld      hl,chan0                ; 1. the two channels' registers
        ld      b,high AUD0_CTRL_P
        call    setchan
        ld      hl,chan1
        ld      b,high AUD1_CTRL_P
        call    setchan

        ld      bc,AUDDMA_P             ; 2. enable channels 0 and 1 ...
        ld      a,AUDDMA_SETCLR_M | 0x03
        out     (c),a
        ld      bc,DMACON_P             ; 3. ... and sound: both start together
        ld      a,DMACON_SETCLR_M | DMACON_DMAEN_M | DMACON_AUDEN_M
        out     (c),a

        ld      hl,title
        rst     0x18                    ; PUTS
.wait:  rst     0x20                    ; POLLC: a key?
        jr      z,.wait

        ld      bc,AUDDMA_P             ; 4. stop them: SETCLR 0 clears the bits
        ld      a,0x03
        out     (c),a
        ld      bc,DMACON_P             ;    and sound off, as the program found it
        ld      a,DMACON_AUDEN_M
        out     (c),a
        ret

; Write a channel's registers from the 19-byte image at HL. B = the high
; byte of the channel's CTRL port; the low byte, 0x12, is the custom
; block's page. The empty bytes are reserved: writing them does nothing.
setchan:
        ld      c,low AUD0_CTRL_P
        ld      d,AUD_VOL + 3           ; 19 bytes
.next:  ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b                       ; the next byte's port
        dec     d
        jr      nz,.next
        ret

chan0:  AUDCHAN 0, wave, 32, STEP_A, 0, 48      ; 8-bit, interpolated; left only
chan1:  AUDCHAN 0, wave, 32, STEP_CS, 48, 0     ; right only

; one cycle of a sine, 32 signed 8-bit samples, peak 100
wave:   db      0, 20, 38, 56, 71, 83, 92, 98
        db      100, 98, 92, 83, 71, 56, 38, 20
        db      0, -20, -38, -56, -71, -83, -92, -98
        db      -100, -98, -92, -83, -71, -56, -38, -20

title:  db      13, 10, "A on the left, C sharp on the right. A key stops them.", 13, 10, 0
