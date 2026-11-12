; Example 10-3 (docs/guide/sound.md): a double-buffered stream. The program
; makes its sound as it plays: a triangle wave, 8,000 samples a second,
; climbing a scale of C a note every quarter second. Channel 0 plays two
; 256-sample buffers in turn. Each time the channel takes one, the AUDIO
; interrupt queues the other, and the main program refills it while the
; first one plays. N switches the channel between interpolated and
; nearest; any other key ends the program.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

TABLE   equ     0x9FD0                  ; the IM 2 table: I = 0x9F, VECBASE = 0xD0
BUF0    equ     0xA000                  ; the two buffers, 256 bytes each, on 256-byte
BUF1    equ     0xA100                  ; boundaries: only LC's middle byte differs
BLEN    equ     256
STEP8K  equ     10921                   ; 8,000 Hz: 8000 x 65536 / 48008
CH0     equ     1 << 0

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

start:  di
        ld      hl,TABLE                ; the IM 2 table, as in Example 10-2
        ld      b,24
.fill:  ld      (hl),low spurious
        inc     hl
        ld      (hl),high spurious
        inc     hl
        djnz    .fill
        ld      hl,audio
        ld      (TABLE+2*INT_AUDIO),hl
        ld      a,high TABLE
        ld      i,a
        ld      bc,VECBASE_P
        ld      a,low TABLE
        out     (c),a
        im      2

        ld      hl,BUF0                 ; the first buffer's sound, before it starts
        call    fill
        ld      hl,chan0                ; channel 0 plays BUF0 first
        ld      b,high AUD0_CTRL_P
        call    setchan
        ld      bc,AUDSTAT_P            ; no old events
        ld      a,AUDSTAT_CH_M
        out     (c),a
        ld      bc,AUDINTEN_P
        ld      a,CH0
        out     (c),a
        ld      bc,INTENA0_P+(INTR_AUDIO<<8)
        ld      a,INTENA_SETCLR_M|(1<<INTB_AUDIO)
        out     (c),a
        ld      bc,INTCON_P
        ld      a,INTCON_MASTER_M
        out     (c),a
        ei

        ld      hl,title
        rst     0x18                    ; PUTS
        ld      bc,AUDDMA_P             ; channel 0 on, and sound: it starts
        ld      a,AUDDMA_SETCLR_M | CH0
        out     (c),a
        ld      bc,DMACON_P
        ld      a,DMACON_SETCLR_M | DMACON_DMAEN_M | DMACON_AUDEN_M
        out     (c),a

.main:  di                              ; a buffer to refill?
        ld      a,(pending)
        ld      hl,pending
        ld      (hl),0
        ei
        or      a
        jr      z,.key
        ld      h,a                     ; its address: A x 256
        ld      l,0
        call    fill
.key:   rst     0x20                    ; POLLC: a key?
        jr      z,.main
        and     0xDF                    ; upper case
        cp      'N'
        jr      nz,.end
        ld      bc,AUD0_CTRL_P          ; N: interpolated <-> nearest
        in      a,(c)
        xor     AUD_CTRL_NEAREST_M
        out     (c),a                   ; from the next output sample
        ld      hl,s_interp
        and     AUD_CTRL_NEAREST_M
        jr      z,.say
        ld      hl,s_near
.say:   rst     0x18
        jr      .main

.end:   di                              ; put everything back
        ld      bc,AUDDMA_P
        ld      a,CH0
        out     (c),a
        ld      bc,DMACON_P
        ld      a,DMACON_AUDEN_M
        out     (c),a
        ld      bc,AUDINTEN_P
        xor     a
        out     (c),a
        ld      bc,AUDSTAT_P
        ld      a,AUDSTAT_CH_M
        out     (c),a
        ld      bc,INTCON_P
        xor     a
        out     (c),a
        ld      bc,INTENA0_P+(INTR_AUDIO<<8)
        ld      a,1<<INTB_AUDIO
        out     (c),a
        ld      a,0x1F
        ld      i,a
        ld      bc,VECBASE_P
        ld      a,0xD0
        out     (c),a
        ret

; AUDIO: channel 0 has just taken a buffer (LC and LEN). Queue the other
; one, which it will take when this one ends, and have the main program
; refill it meanwhile.
audio:  push    af
        push    bc
        ld      bc,AUDSTAT_P
        ld      a,CH0
        out     (c),a                   ; clear the event first
        ld      a,(next)                ; the buffer to queue: its high byte
        ld      bc,AUD0_LC1_P
        out     (c),a                   ; LC's middle byte: the whole change
        ld      (pending),a             ; refill it
        xor     high BUF0 ^ high BUF1   ; the other one next time
        ld      (next),a
        pop     bc
        pop     af
        ei
        reti

spurious:
        ei
        reti

; Fill the buffer at HL (256-byte aligned) with the next 256 samples of
; the triangle wave; after every 8 buffers, the next note
fill:   ld      de,(phase)
        ld      bc,(incr)
.smp:   ex      de,hl
        add     hl,bc                   ; the phase moves on
        ex      de,hl
        ld      a,d                     ; the triangle from its top byte:
        or      a                       ; 0x00-0x7F up, 0x80-0xFF down
        jp      p,.up
        cpl
.up:    add     a,a                     ; 0, 2 ... 254
        xor     0x80                    ; signed: -128 ... 126
        ld      (hl),a
        inc     l
        jr      nz,.smp                 ; to the end of the 256 bytes
        ld      (phase),de
        ld      a,(count)
        inc     a
        and     7
        ld      (count),a
        ret     nz
        ld      a,(note)                ; 8 buffers (a quarter second): the next note
        inc     a
        and     7
        ld      (note),a
        add     a,a
        ld      l,a
        ld      h,0
        ld      de,notes
        add     hl,de
        ld      a,(hl)
        inc     hl
        ld      h,(hl)
        ld      l,a
        ld      (incr),hl
        ret

; Write a channel's registers from the 19-byte image at HL; B = the high
; byte of its CTRL port (Example 10-1)
setchan:
        ld      c,low AUD0_CTRL_P
        ld      d,AUD_VOL + 3
.next:  ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        dec     d
        jr      nz,.next
        ret

chan0:  AUDCHAN 0, BUF0, BLEN, STEP8K, 48, 48   ; 8-bit, interpolated, centre

; The phase increments of the scale of C at 8,000 Hz: f x 65536 / 8000
notes:  dw      2143, 2406, 2700, 2861, 3211, 3604, 4046, 4287

phase:  dw      0
incr:   dw      2143                    ; the first note, C
count:  db      0                       ; buffers made of this note
note:   db      0
next:   db      high BUF1               ; the buffer the handler queues next
pending: db     0                       ; a buffer for the main program to refill
title:  db      13, 10, "A scale of C. N: interpolated or nearest. Any other key ends.", 13, 10, 0
s_interp: db    "Interpolated", 13, 10, 0
s_near: db      "Nearest", 13, 10, 0
