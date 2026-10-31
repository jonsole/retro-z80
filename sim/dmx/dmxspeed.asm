; DMA engine speed test (spec 14, sections 6.1 and 6.2; ticket #78). Runs in
; place of the boot ROM (tb.v +rom=dmxspeed.hex): times jobs on channel 2
; with TIME and prints each in microseconds, in hex, then "PASS". With the
; layers off, the engine has every cycle the CPU leaves, so the times show
; the engine's own pace: clocks per 8 words = us x 100 x 8 / words.
;
;   F  fill, 16,384 bytes in one row (8,192 words)
;   C  copy, 16,384 bytes in one row
;   X  XOR with VALUE (reads C), 16,384 bytes in one row
;   S  copy at 4 bpp, source and destination a pixel apart, 64 rows of 256 bytes
;   K  a 32-pixel-wide 8 bpp object with a key colour (cookie-cut), 2,048 rows
;
; Each time covers RUN to BUSY clear, so it includes a few microseconds of
; polling.

        DEVICE  NOSLOT64K
        include "hw.inc"

    MACRO WREG xp, xv                   ; write xv to register port xp (A, B, C changed)
        ld      bc,xp
        ld      a,xv
        out     (c),a
    ENDM
    MACRO JOB c0, c1, mt, apt, bpt, dpt, wid, hgt, sh, abs, cds, val, nxt
        db      c0, c1, 0, mt
        d24     apt, bpt, dpt, wid
        dw      hgt, sh, abs, cds
        dd      val
        d24     nxt
        db      0
    ENDM

B8      equ     0x03                    ; CTRL1: 8 bpp
B4      equ     0x02                    ; 4 bpp
BCONST  equ     0x10
MKEY    equ     0x40

        ORG     0x0000
        di
        jp      start
        ds      0x66 - $, 0xFF
        retn

start:  ld      sp,0xC000
        WREG    SERCON_P, SERCON_EN_M | SERCON_CTLEN_M
        WREG    DMACON_P, DMACON_SETCLR_M | DMACON_DMAEN_M | DMACON_BLTEN_M
        IFDEF ONLY
        ld      hl,jobs + 33 * ONLY     ; -DONLY=n: just the nth job (testbenches without +print)
        ELSE
        ld      hl,jobs
        ENDIF
.next:  ld      a,(hl)                  ; the job's letter, 0 at the end
        or      a
        jr      z,.done
        call    putc
        ld      a,' '
        call    putc
        inc     hl
        push    hl
        call    load                    ; the job into channel 2's registers
        call    t0                      ; the clock starts at RUN ...
        WREG    DMX2_CHCTRL_P, DMX_CHCTRL_RUN_M
        ld      bc,DMX2_CHSTAT_P
.busy:  in      a,(c)
        rra
        jr      c,.busy
        call    t1                      ; ... and stops when BUSY clears
        ld      a,h
        call    puthex
        ld      a,l
        call    puthex
        ld      a,13
        call    putc
        ld      a,10
        call    putc
        pop     hl
        ld      de,32
        add     hl,de                   ; the next entry
        jr      .next
.done:  ld      hl,pass
        call    puts
stop:   di
        halt
        jr      stop

; load: the 32-byte job at HL into channel 2's registers
load:   ld      bc,DMX2_P
.copy:  ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,b
        cp      (high DMX2_P) + 32
        jr      nz,.copy
        ret

t0:     ld      bc,TIME0_P
        in      e,(c)                   ; reading TIME0 captures all 4 bytes
        inc     b
        in      d,(c)
        ld      (t0time),de
        ret
t1:     ld      bc,TIME0_P
        in      l,(c)
        inc     b
        in      h,(c)
        ld      de,(t0time)
        or      a
        sbc     hl,de
        ret

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

pass:   db      "PASS", 13, 10, 0

; Each entry: the letter, then the 32-byte job
jobs:   db      'F'
        JOB     0, B8|BCONST, 0xCC, 0, 0, 0x010000, 16384, 1, 0, 0, 16384, 0x5A5A5A5A, 0
        db      'C'
        JOB     0, B8, 0xCC, 0, 0x010000, 0x020000, 16384, 1, 0, 16384, 16384, 0, 0
        db      'X'
        JOB     0, B8|BCONST, 0x66, 0, 0, 0x020000, 16384, 1, 0, 0, 16384, 0x0F0F0F0F, 0
        db      'S'
        JOB     0, B4, 0xCC, 0, 0x010000, 0x030000, 512, 64, 0x0100, 256, 256, 0, 0
        db      'K'
        JOB     0, B8|MKEY, 0xCA, 0, 0x010000, 0x030000, 32, 2048, 0, 32, 360, 0, 0
        db      0

t0time  equ     0xBF00                  ; window 5, SRAM
