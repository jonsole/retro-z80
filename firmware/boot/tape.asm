; The port 0xFE demo (ticket #21), in ROM page 1, included by boot.asm: a
; Spectrum "tape loader" on the border and the beeper, then a clean beep.
; The monitor runs it for Tab on an empty command line (a PS/2 keyboard's
; Tab key, Tab over the serial link, or EDIT on the membrane: CAPS SHIFT +
; 1, or the Next's EDIT key).
;
; Each edge of the "tape" is one OUT (0xFE),A that changes the border colour
; and the beeper bit together, as a Spectrum's loader does, so the border
; shows stripes whose edges fall in the middle of lines (spec 4, section
; 7.2) and the beeper plays the tape's tone (spec 7, section 10.2):
;
;   Pilot   2400 edges of 2168 Spectrum T-states (about 620 us): red and
;           cyan stripes, about 19 picture lines each, and an 807 Hz tone,
;           for 1.5 s
;   Sync    two short edges (667 and 735 T-states)
;   Data    256 bytes (the boot ROM's own first bytes), each bit two edges
;           of 855 T-states (0) or 1710 (1), most significant bit first:
;           blue and yellow stripes, 8-15 lines each, and the data's rasp,
;           for about 1.5 s
;   Pause   about 0.17 s, black and quiet
;   Beep    0.4 s of 880 Hz with the border black
;
; Then the beeper is left low and the border black again (BGCOLOR).
; Interrupts are off throughout (about 3.6 s; the monitor runs with them
; off anyway), so the timing is exact: the delays are counted for the
; monitor's 20 MHz (CPUSPEED 0x00), a T-state here being 50 ns, a
; Spectrum's 286 ns. The PS/2 FIFO holds 16 bytes meanwhile.

; Delay counts (26 T-states each, less the edge's own ~100)
TP_PILOT  equ   473                     ; 12389 T: 2168 Spectrum T-states
TP_SYNC1  equ   143                     ;  3812 T:  667
TP_SYNC2  equ   158                     ;  4200 T:  735
TP_BIT0   equ   184                     ;  4886 T:  855
TP_BIT1   equ   372                     ;  9771 T: 1710
TP_BEEP   equ   433                     ; 11364 T: 880 Hz
TP_NPIL   equ   2400                    ; pilot edges
TP_NBEEP  equ   704                     ; beep edges: 0.4 s

TP_RC     equ   0x02                    ; red, beeper low; xor 0x17: cyan, beeper high
TP_BY     equ   0x01                    ; blue, beeper low; xor 0x17: yellow, beeper high
TP_FLIP   equ   0x17

; A, B, C, D, E, HL and IX changed
tape:   di
        ld      c,TP_RC                 ; ---- pilot
        ld      hl,TP_NPIL
.pil:   ld      de,TP_PILOT
        call    tpedge
        dec     hl
        ld      a,h
        or      l
        jr      nz,.pil
        ld      de,TP_SYNC1             ; ---- sync
        call    tpedge
        ld      de,TP_SYNC2
        call    tpedge
        ld      c,TP_BY                 ; ---- data
        ld      ix,0                    ; the boot ROM's first 256 bytes
        ld      h,0
.byte:  ld      l,(ix + 0)
        inc     ix
        ld      b,8
.bit:   ld      de,TP_BIT0
        rlc     l
        jr      nc,.b0
        ld      de,TP_BIT1
.b0:    push    de
        call    tpedge
        pop     de
        call    tpedge
        djnz    .bit
        dec     h
        jr      nz,.byte
        xor     a                       ; ---- pause: black, beeper low
        out     (ULA_PORT),a
        ld      de,0                    ; 2 x 65536 x 26 T: 0.17 s
        call    tpwait
        ld      de,0
        call    tpwait
        ld      c,0                     ; ---- beep: black, the beeper toggling
        ld      hl,TP_NBEEP
.bp:    ld      a,c
        out     (ULA_PORT),a
        xor     ULA_BEEPER_M
        ld      c,a
        ld      de,TP_BEEP
        call    tpwait
        dec     hl
        ld      a,h
        or      l
        jr      nz,.bp
        xor     a                       ; beeper low, then the border black
        out     (ULA_PORT),a
        ld      hl,col_black
        jp      setbg

; One edge: port 0xFE = C, C flipped for the next one, then DE x 26 T-states
; (A, C, DE changed)
tpedge: ld      a,c
        out     (ULA_PORT),a
        xor     TP_FLIP
        ld      c,a
        ; on into tpwait

; DE x 26 T-states (DE = 0: 65536 x 26); A, DE changed
tpwait: dec     de
        ld      a,d
        or      e
        jr      nz,tpwait
        ret
