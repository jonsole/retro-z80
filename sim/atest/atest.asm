; Sound test (spec 13; retro-hw's audio_engine). retro68k's sim/atest/atest.s
; (hw-audio, d706cd2) on the Z80.
;
; Plays the four channels from sample data that agen.py put in the SRAM,
; keeps their queues fed, and after about 3 ms prints PASS. The testbench
; (+audio) records every output sample; amodel.py must work out exactly
; the same ones. Keep the channel set-ups in step with amodel.py.
;
; Counting each channel's AUDSTAT bits (the first is its start):
;   channel 2 is one-shot: it stops by itself at the end of its block
;   channel 0, at its 4th bit: a new block, then AUDSTART (a restart while playing)
;   channel 3, at its 3rd bit: AUDDMA bit 3 off and straight on again (a restart)
;   channel 1, at its 6th bit: AUDSTOP
;
; Also checked here (FAIL nn: the check):
;   1x  the registers read back before the start: CTRL, LC, STEP, VOL
;       (with its empty middle byte), AUDRATE, AUDDMA, a reserved byte
;       (0xFF), and STEP through the register page
;   2x  at the end: AUDxPOS through the capture, by port and through the
;       register page; AUDSTAT.ACTIVE; the AUDIO interrupt (source 9)
;       raw bit with AUDINTEN, and cleared with AUDSTAT; DMACON.AUDEN off
;       stops every channel

        DEVICE  NOSLOT64K
        include "hw.inc"

S8      equ     0x040000                ; 8-bit samples (physical)
S16     equ     0x041000                ; 16-bit samples
RATE    equ     250                     ; an output sample every 2.5 us
TEND    equ     0x0C                    ; TIME1 at the end: 3072 us from power-on
W3      equ     0x6000                  ; window 3, mapped to the register page for a moment
PG_REGS equ     0x3F8
RP      equ     W3 + 0x1000             ; the custom block through the register page

qpos    equ     0xBF00                  ; 4 bytes: each channel's next queue entry
qcnt    equ     0xBF04                  ; 4 bytes: AUDSTAT bits seen per channel
mmu3    equ     0xBF08                  ; window 3's page, kept

    MACRO WREG xp, xv                   ; write xv to register port xp (A, B, C changed)
        ld      bc,xp
        ld      a,xv
        out     (c),a
    ENDM
    MACRO RCHK xp, xv                   ; fail check D unless register port xp reads xv
        ld      bc,xp
        in      a,(c)
        cp      xv
        jp      nz,fail
    ENDM
    MACRO SET1 xp, xv                   ; a set-up entry: port, byte
        dw      xp
        db      xv
    ENDM
    MACRO SET3 xp, xv                   ; ... three, low byte first
        dw      xp
        db      (xv) & 0xFF
        dw      xp + 0x100
        db      ((xv) >> 8) & 0xFF
        dw      xp + 0x200
        db      ((xv) >> 16) & 0xFF
    ENDM

        ORG     0x0000
        di
        jp      start
        ds      0x66 - $, 0xFF
        retn

start:  ld      sp,0xC000
        WREG    SERCON_P, SERCON_EN_M | SERCON_CTLEN_M
        WREG    AUDRATE0_P, RATE & 0xFF
        WREG    AUDRATE1_P, RATE >> 8
        ld      hl,setup
.set:   ld      c,(hl)                  ; port, or 0
        inc     hl
        ld      b,(hl)
        inc     hl
        ld      a,b
        or      c
        jr      z,.chk
        ld      a,(hl)
        inc     hl
        out     (c),a
        jr      .set

        ; ---- 1x: read back
.chk:   ld      d,0x10
        RCHK    AUD1_CTRL_P, AUD_CTRL_BITS16_M
        inc     d
        RCHK    AUD2_CTRL_P, AUD_CTRL_NEAREST_M | AUD_CTRL_ONESHOT_M
        inc     d
        RCHK    AUD0_LC_P, 0x01
        RCHK    AUD0_LC_P + 0x100, 0x00
        RCHK    AUD0_LC_P + 0x200, 0x04
        inc     d
        RCHK    AUD3_STEP_P, 0x66
        RCHK    AUD3_STEP_P + 0x100, 0xE6
        RCHK    AUD3_STEP_P + 0x200, 0x0F
        inc     d
        RCHK    AUD3_VOL_P, 90
        RCHK    AUD3_VOL_P + 0x100, 0
        RCHK    AUD3_VOL_P + 0x200, 33
        inc     d
        RCHK    AUDRATE0_P, RATE & 0xFF
        RCHK    AUDRATE1_P, RATE >> 8
        inc     d
        RCHK    AUDDMA_P, 0
        RCHK    AUD0_CTRL_P + 0x100, 0xFF  ; reserved
        inc     d                       ; 18: through the register page
        call    regs_on
        ld      a,(RP + AUD3_STEP1)
        cp      0xE6
        jp      nz,fail
        ld      hl,(RP + AUD1_LEN0)     ; LD rr,(nn): two reads
        ld      bc,700
        or      a
        sbc     hl,bc
        jp      nz,fail
        call    regs_off

        ; ---- go
        ld      hl,qpos                 ; each channel's next queue entry: the second
        ld      b,4
.qp:    ld      (hl),1
        inc     hl
        djnz    .qp
        ld      b,4
.qc:    ld      (hl),0
        inc     hl
        djnz    .qc
        WREG    AUDDMA_P, AUDDMA_SETCLR_M | 0x0F
        WREG    DMACON_P, DMACON_SETCLR_M | DMACON_DMAEN_M | DMACON_AUDEN_M    ; all four start

        ; keep the queues fed: when a channel takes its registers, write its
        ; next block (the last one then loops)
.loop:  ld      bc,AUDSTAT_P
        in      a,(c)
        and     0x0F
        jr      z,.next
        ld      e,a
        ld      d,0                     ; channel
.ch:    srl     e
        jr      nc,.chn
        push    de
        ld      a,d                     ; clear its bit
        or      a
        ld      a,1
        jr      z,.m1
        ld      b,d
.m0:    add     a,a
        djnz    .m0
.m1:    ld      bc,AUDSTAT_P
        out     (c),a
        call    feed
        call    events
        pop     de
.chn:   inc     d
        ld      a,d
        cp      4
        jr      nz,.ch
.next:  ld      bc,TIME0_P              ; TIME0 captures; TIME1 from the capture
        in      a,(c)
        inc     b
        in      a,(c)
        cp      TEND
        jr      c,.loop

        ; ---- 2x: at the end. Playing: 0 (its 500-sample block, looped) and 3
        ld      d,0x20                  ; AUDSTAT.ACTIVE (CH may be set)
        ld      bc,AUDSTAT_P
        in      a,(c)
        and     AUDSTAT_ACTIVE_M
        cp      0x90
        jp      nz,fail
        inc     d                       ; 21: AUD3POS by port: under 900, top byte 0
        ld      bc,AUD3_POS_P
        in      l,(c)
        inc     b
        in      h,(c)
        inc     b
        in      a,(c)
        or      a
        jp      nz,fail
        ld      bc,900
        or      a
        sbc     hl,bc
        jp      nc,fail
        inc     d                       ; 22: through the register page
        call    regs_on
        ld      hl,(RP + AUD3_POS0)
        ld      a,(RP + AUD3_POS2)
        or      a
        jp      nz,fail
        ld      bc,900
        or      a
        sbc     hl,bc
        jp      nc,fail
        call    regs_off
        inc     d                       ; 23: the interrupt's raw bit follows AUDSTAT.CH with AUDINTEN
        WREG    AUDINTEN_P, 0x08        ; channel 3: a block end every 57 samples
        WREG    AUDSTAT_P, 0x0F
        ld      bc,AUDSTAT_P
.w3:    in      a,(c)
        and     0x08
        jr      z,.w3
        ld      bc,INTRAW1_P
        in      a,(c)
        and     1 << INTB_AUDIO
        jp      z,fail
        inc     d                       ; 24: cleared, just after its block end
        WREG    AUDSTAT_P, 0x08
        ld      bc,INTRAW1_P
        in      a,(c)
        and     1 << INTB_AUDIO
        jp      nz,fail
        WREG    AUDINTEN_P, 0
        inc     d                       ; 25: DMACON.AUDEN off stops them all
        WREG    DMACON_P, DMACON_AUDEN_M
        ld      bc,AUDSTAT_P
        in      a,(c)
        and     AUDSTAT_ACTIVE_M
        jp      nz,fail
        inc     d                       ; 26: AUDDMA is kept
        RCHK    AUDDMA_P, 0x0F

        ld      hl,pass
        call    puts
stop:   di
        halt
        jr      stop

; D = channel: write its next queued block, if there is one
feed:   push    de
        push    hl
        ld      hl,qpos
        ld      a,l
        add     a,d
        ld      l,a
        ld      e,(hl)                  ; entry number
        push    hl
        ld      a,d
        add     a,a
        ld      c,a
        ld      b,0
        ld      hl,queues
        add     hl,bc
        ld      a,(hl)
        inc     hl
        ld      h,(hl)
        ld      l,a                     ; this channel's queue
        ld      a,e
        cp      (hl)                    ; number of entries
        jr      nc,.none
        inc     hl
        add     a,a
        add     a,a
        add     a,a
        ld      c,a
        ld      b,0
        add     hl,bc                   ; the entry: LC, LEN, 4 bytes each
        ld      a,d                     ; AUDnLC: port AUD0_LC_P + n x 0x2000
        rrca
        rrca
        rrca
        add     a,AUD0_LC_P >> 8
        ld      b,a
        ld      c,AUD0_LC_P & 0xFF
        ld      e,2
.reg:   ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,(hl)
        out     (c),a
        inc     hl
        inc     hl
        inc     b
        inc     b                       ; AUDnLEN
        dec     e
        jr      nz,.reg
        pop     hl
        inc     (hl)
        jr      .out
.none:  pop     hl
.out:   pop     hl
        pop     de
        ret

; D = channel, after one of its AUDSTAT bits: count it, and at the
; counts above, start, stop or restart
events: ld      hl,qcnt
        ld      a,l
        add     a,d
        ld      l,a
        inc     (hl)
        ld      a,(hl)
        ld      e,a
        ld      a,d
        or      a
        jr      nz,.c3
        ld      a,e
        cp      4
        ret     nz
        ld      hl,restart
        ld      bc,AUD0_LC_P
        ld      e,6
.r:     ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,b
        cp      (AUD0_LC_P >> 8) + 3
        jr      nz,.r1
        inc     b                       ; past LC's empty byte to LEN
.r1:    dec     e
        jr      nz,.r
        WREG    AUDSTART_P, 0x01
        ret
.c3:    cp      3
        jr      nz,.c1
        ld      a,e
        cp      3
        ret     nz
        WREG    AUDDMA_P, 0x08                          ; off ...
        WREG    AUDDMA_P, AUDDMA_SETCLR_M | 0x08        ; ... and on again
        ret
.c1:    cp      1
        ret     nz
        ld      a,e
        cp      6
        ret     nz
        WREG    AUDSTOP_P, 0x02
        ret

; Window 3 to the register page and back
regs_on:
        ld      bc,MMU3_0_P
        in      a,(c)
        ld      (mmu3),a
        inc     b
        in      a,(c)
        ld      (mmu3 + 1),a
        ld      hl,PG_REGS
        ld      bc,MMU3_0_P
        out     (c),l
        inc     b
        out     (c),h
        ret
regs_off:
        ld      hl,(mmu3)
        ld      bc,MMU3_0_P
        out     (c),l
        inc     b
        out     (c),h
        ret

fail:   ld      hl,failmsg
        call    puts
        ld      a,d
        call    puthex
        ld      a,13
        call    putc
        ld      a,10
        call    putc
        jp      stop

puts:   ld      a,(hl)
        or      a
        ret     z
        call    putc
        inc     hl
        jr      puts
puthex: push    af
        rrca
        rrca
        rrca
        rrca
        call    .nib
        pop     af
.nib:   and     0x0F
        add     a,'0'
        cp      '9' + 1
        jr      c,putc
        add     a,'A' - '9' - 1
putc:   push    bc
        ld      c,a
.wait:  ld      a,SERSTAT0
        in      a,(SYSPAGE)
        or      a
        jr      z,.wait
        ld      a,c
        out     (SERDATA_PORT),a
        pop     bc
        ret

pass:      db   "PASS", 13, 10, 0
failmsg:   db   "FAIL ", 0

; Channel 0's restart: LC, LEN, low byte first
restart:   db   (S8 + 0x400) & 0xFF, ((S8 + 0x400) >> 8) & 0xFF, (S8 + 0x400) >> 16
           db   500 & 0xFF, 500 >> 8, 0

; port, value; 0 ends
setup:  SET1    AUD0_CTRL_P, 0                                  ; 8-bit, interpolated
        SET3    AUD0_LC_P,   S8 + 1                             ; odd address
        SET3    AUD0_LEN_P,  300
        SET3    AUD0_STEP_P, 0x0B400                            ; 0.703
        SET3    AUD0_VOL_P,  (64 << 16) | 10
        SET1    AUD1_CTRL_P, AUD_CTRL_BITS16_M                  ; 16-bit, interpolated
        SET3    AUD1_LC_P,   S16
        SET3    AUD1_LEN_P,  700
        SET3    AUD1_STEP_P, 0x2C000                            ; 2.75
        SET3    AUD1_VOL_P,  (20 << 16) | 64
        SET1    AUD2_CTRL_P, AUD_CTRL_NEAREST_M | AUD_CTRL_ONESHOT_M   ; 8-bit, nearest, one-shot
        SET3    AUD2_LC_P,   S8 + 0x100
        SET3    AUD2_LEN_P,  300
        SET3    AUD2_STEP_P, 0x10000
        SET3    AUD2_VOL_P,  (64 << 16) | 64
        SET1    AUD3_CTRL_P, AUD_CTRL_BITS16_M | AUD_CTRL_NEAREST_M
        SET3    AUD3_LC_P,   S16 + 2
        SET3    AUD3_LEN_P,  1900
        SET3    AUD3_STEP_P, 0xFE666                            ; 15.9
        SET3    AUD3_VOL_P,  (33 << 16) | 90                    ; 90 acts as 64
        dw      0

; per channel: its queue; a queue: entries, then (LC, LEN) each, 4 bytes
; each. Entry 0 is the set-up above; the last entry loops. Every block
; before the last lasts over 100 output samples (250 us), so the CPU has
; written the next one long before the channel takes it.
queues: dw      q0, q1, q2, q3
q0:     db      2
        dd      S8 + 1, 300, S8 + 0x203, 61
q1:     db      3
        dd      S16, 700, S16 + 40, 600, S16 + 200, 7
q2:     db      1
        dd      S8 + 0x100, 300
q3:     db      2
        dd      S16 + 2, 1900, S16 + 0x800, 900
