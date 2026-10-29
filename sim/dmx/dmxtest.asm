; DMA engine directed test (ticket #39; spec 14). Runs in place of the boot
; ROM (tb.v +rom=dmxtest.hex) and prints "PASS" or "FAIL nn".
;
; Each table entry is a 16-byte source (copied to physical 0x008000), a
; 16-byte destination before the job (physical 0x009000), a 32-byte job
; written to channel 2's job registers and started with RUN, and the 16
; bytes the destination must hold after it. Then: a chain of two
; descriptors started with CHDESC and START, with IRQ; errors; register
; reads.
;
; Z80 0xC000 (window 6) is physical 0x008000, 0xD000 is 0x009000, and 0xE000
; (window 7) is 0x00A000, as after reset.

        DEVICE  NOSLOT64K
        include "hw.inc"

SRC     equ     0xC000                  ; physical 0x008000
DST     equ     0xD000                  ; physical 0x009000
DESCS   equ     0xE000                  ; physical 0x00A000
SRC_P   equ     0x008000
DST_P   equ     0x009000
DESCS_P equ     0x00A000

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
    ; A job: CTRL0, CTRL1, MINTERM, APT, BPT, DPT, WIDTH, HEIGHT, SHIFT,
    ; ABSTRIDE, CDSTRIDE, VALUE, NEXT (CTRL2 and +0x1F are 0)
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
DESC    equ     0x04
IRQ     equ     0x08
BCONST  equ     0x10
MIMG    equ     0x20                    ; MASK = 1, a 1 bpp image at APT
MKEY    equ     0x40                    ; MASK = 2, compare with the key colour
ADD     equ     0x01                    ; CTRL0: OP = ADD
SAT     equ     0x10

        ORG     0x0000
        di
        jp      start
        ds      0x66 - $, 0xFF
        retn

start:  ld      sp,0xC000
        WREG    SERCON_P, SERCON_EN_M | SERCON_CTLEN_M
        WREG    DMACON_P, DMACON_SETCLR_M | DMACON_DMAEN_M | DMACON_BLTEN_M

        ; ---- checks 1-n: the table of single jobs
        ld      a,1
        ld      (tnum),a
        ld      hl,tests
.next:  ld      a,(hl)
        cp      0xFF
        jr      z,chain
        ld      de,SRC                  ; the source
        ld      bc,16
        ldir
        ld      de,DST                  ; the destination before
        ld      bc,16
        ldir
        call    runjob                  ; HL: the job; on to the expected bytes
        ld      a,(tnum)
        ld      d,a
        call    waitch
        RCHK    DMX2_CHSTAT_P, DMX_CHSTAT_DONE_M
        WREG    DMX2_CHSTAT_P, DMX_CHSTAT_DONE_M | DMX_CHSTAT_ERR_M
        ld      de,DST
        ld      b,16
.cmp:   ld      a,(de)
        cp      (hl)
        jr      nz,.bad
        inc     de
        inc     hl
        djnz    .cmp
        ld      a,(tnum)
        inc     a
        ld      (tnum),a
        jr      .next
.bad:   ld      a,(tnum)
        ld      d,a
        jp      fail

        ; ---- a chain of two fills from descriptors, the second with IRQ
chain:  ld      d,0x20
        ld      hl,DST
        ld      de,DST+1
        ld      (hl),0xEE
        ld      bc,15
        ldir
        ld      d,0x20
        ld      hl,descs
        ld      de,DESCS
        ld      bc,64
        ldir
        ld      d,0x20
        WREG    DMXINTEN_P, 0
        WREG    DMX2_CHDESC0_P, low DESCS_P
        WREG    DMX2_CHDESC1_P, high DESCS_P
        WREG    DMX2_CHDESC2_P, DESCS_P >> 16
        WREG    DMX2_CHCTRL_P, DMX_CHCTRL_START_M
        call    waitch
        RCHK    DMX2_CHSTAT_P, DMX_CHSTAT_DONE_M
        ld      d,0x21
        RCHK    DMXINT_P, DMXINT_CH2_M  ; the second job's IRQ
        ld      d,0x22
        RCHK    DMX2_CHDESC0_P, low (DESCS_P + 32)      ; the last descriptor loaded
        RCHK    DMX2_CHDESC1_P, high (DESCS_P + 32)
        ld      d,0x23
        ld      a,(DST+1)
        cp      0x55
        jp      nz,fail
        ld      a,(DST+2)
        cp      0xEE
        jp      nz,fail
        ld      a,(DST+5)
        cp      0x66
        jp      nz,fail
        ld      d,0x24
        WREG    DMXINT_P, DMXINT_CH2_M  ; W1C
        RCHK    DMXINT_P, 0
        WREG    DMX2_CHSTAT_P, DMX_CHSTAT_DONE_M
        RCHK    DMX2_CHSTAT_P, 0

        ; ---- errors: each stops the channel with ERR, CHERR and DMXINT
        ld      d,0x30                  ; OP 2 (reserved), started with RUN: CHERR = CHDESC
        ld      hl,job_badop
        call    runjob
        call    waitch
        RCHK    DMX2_CHSTAT_P, DMX_CHSTAT_ERR_M
        RCHK    DMX2_CHERR0_P, low (DESCS_P + 32)
        RCHK    DMXINT_P, DMXINT_CH2_M
        call    clrerr
        ld      d,0x31                  ; MASK 3
        ld      hl,job_mask3
        call    runjob
        call    waitch
        RCHK    DMX2_CHSTAT_P, DMX_CHSTAT_ERR_M
        call    clrerr
        ld      d,0x32                  ; CTRL2 not 0
        ld      hl,job_ctrl2
        call    runjob
        call    waitch
        RCHK    DMX2_CHSTAT_P, DMX_CHSTAT_ERR_M
        call    clrerr
        ld      d,0x33                  ; a destination past the SRAM: CHERR its address
        ld      hl,job_far
        call    runjob
        call    waitch
        RCHK    DMX2_CHSTAT_P, DMX_CHSTAT_ERR_M
        RCHK    DMX2_CHERR0_P, 0x00
        RCHK    DMX2_CHERR1_P, 0x00
        RCHK    DMX2_CHERR2_P, 0x7F
        call    clrerr
        ld      d,0x34                  ; CHDESC not a multiple of 4
        WREG    DMX2_CHDESC0_P, 0x02
        WREG    DMX2_CHCTRL_P, DMX_CHCTRL_START_M
        call    waitch
        RCHK    DMX2_CHSTAT_P, DMX_CHSTAT_ERR_M
        RCHK    DMX2_CHERR0_P, 0x02
        call    clrerr

        ; ---- two channels at once, taking turns: channel 1 copies 300 bytes
        ; (2D, 3 rows of 100), channel 0 fills 600 bytes
        ld      d,0x38
        ld      hl,SRC                  ; a ramp to copy: 512 bytes, i mod 256
        xor     a
.ramp:  ld      (hl),a
        inc     hl
        inc     a
        jr      nz,.ramp
        bit     1,h
        jr      z,.ramp
        ld      hl,DST + 0x400          ; both areas 0xEE first
        ld      de,DST + 0x401
        ld      (hl),0xEE
        ld      bc,0x7FF
        ldir
        ld      e,high DMX1_CTRL_P
        ld      hl,job_two1
        call    loadjob
        ld      e,high DMX0_CTRL_P
        ld      hl,job_two0
        call    loadjob
        ld      d,0x38
        WREG    DMX1_CHCTRL_P, DMX_CHCTRL_RUN_M
        WREG    DMX0_CHCTRL_P, DMX_CHCTRL_RUN_M
        ld      bc,DMX1_CHSTAT_P
        call    waitbc
        ld      bc,DMX0_CHSTAT_P
        call    waitbc
        RCHK    DMX1_CHSTAT_P, DMX_CHSTAT_DONE_M
        RCHK    DMX0_CHSTAT_P, DMX_CHSTAT_DONE_M
        ld      d,0x39                  ; the copy: row r, byte i = 10 + 100 r + i, at DST + 0x400 + 128 r + i
        ld      hl,DST + 0x400
        ld      c,10
        call    chkrow
        ld      hl,DST + 0x480
        ld      c,110
        call    chkrow
        ld      hl,DST + 0x500
        ld      c,210
        call    chkrow
        ld      d,0x3A                  ; the fill
        ld      hl,DST + 0x800
        ld      bc,600
.fill:  ld      a,(hl)
        cp      0x77
        jp      nz,fail
        inc     hl
        dec     bc
        ld      a,b
        or      c
        jr      nz,.fill
        ld      a,(hl)
        cp      0xEE
        jp      nz,fail

        ; ---- registers
        ld      d,0x40                  ; the job registers read back; +0x1F is reserved
        WREG    DMX2_MINTERM_P, 0x5A
        RCHK    DMX2_MINTERM_P, 0x5A
        RCHK    DMX2_NEXT2_P + 0x0100, 0xFF
        RCHK    DMX2_CHCTRL_P + 0x0100, 0xFF
        ld      d,0x41                  ; job register writes ignored while BUSY
        ld      hl,job_long
        call    runjob
        WREG    DMX2_MINTERM_P, 0x33
        RCHK    DMX2_CHSTAT_P, DMX_CHSTAT_BUSY_M
        RCHK    DMX2_MINTERM_P, 0xCC
        call    waitch
        RCHK    DMX2_CHSTAT_P, DMX_CHSTAT_DONE_M

        ; ---- a job written as a 32-byte image through the register page
        ; (page 0x3F8 in window 7: channel 2's job registers at 0xE000 +
        ; 0x11C0), with LDIR and with LDDR
        ld      d,0x42
        WREG    MMU7_0_P, 0xF8
        WREG    MMU7_1_P, 0x03
        ld      hl,job_ldir
        ld      de,0xE000 + 0x11C0
        ld      bc,32
        ldir
        call    rungo
        ld      hl,DST + 0x10
        ld      a,0x5A
        call    chk4
        ld      d,0x43
        ld      hl,job_lddr + 31
        ld      de,0xE000 + 0x11C0 + 31
        ld      bc,32
        lddr
        call    rungo
        ld      hl,DST + 0x14
        ld      a,0xA5
        call    chk4
        WREG    MMU7_0_P, 5             ; window 7 back to page 5
        WREG    MMU7_1_P, 0

        ld      hl,pass
        call    puts
        jp      stop

; RUN channel 2's job, wait, check DONE and clear it (D: the check)
rungo:  WREG    DMX2_CHCTRL_P, DMX_CHCTRL_RUN_M
        call    waitch
        RCHK    DMX2_CHSTAT_P, DMX_CHSTAT_DONE_M
        WREG    DMX2_CHSTAT_P, DMX_CHSTAT_DONE_M
        ret

; Check the 4 bytes at HL are A
chk4:   ld      b,4
.lp:    cp      (hl)
        jp      nz,fail
        inc     hl
        djnz    .lp
        ret

; Write the 32-byte job at HL into the job registers whose CTRL port high
; byte is E (channels 0-2: port low byte 0x11). HL is left after the job.
loadjob:
        ld      c,0x11
        ld      b,e
        ld      a,e
        add     a,0x20
        ld      d,a
.lp:    ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,b
        cp      d
        jr      nz,.lp
        ret

; Check 100 bytes at HL count up from C, and the byte after them is 0xEE
chkrow: ld      b,100
.lp:    ld      a,(hl)
        cp      c
        jp      nz,fail
        inc     hl
        inc     c
        djnz    .lp
        ld      a,(hl)
        cp      0xEE
        jp      nz,fail
        ret

waitbc: in      a,(c)
        rra
        jr      c,waitbc
        ret

; Write the 32-byte job at HL into channel 2's job registers and RUN it.
; HL is left after the job.
runjob: ld      bc,DMX2_CTRL_P
.lp:    ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,b
        cp      high DMX2_CTRL_P + 0x20
        jr      nz,.lp
        ld      bc,DMX2_CHCTRL_P
        ld      a,DMX_CHCTRL_RUN_M
        out     (c),a
        ret

waitch: ld      bc,DMX2_CHSTAT_P
.w:     in      a,(c)
        rra
        jr      c,.w
        ret

clrerr: WREG    DMX2_CHSTAT_P, DMX_CHSTAT_DONE_M | DMX_CHSTAT_ERR_M
        WREG    DMXINT_P, 0x0F
        ret

fail:   ld      hl,failmsg
        call    puts
        ld      a,d
        call    puthex
        ld      a,13
        call    putc
        ld      a,10
        call    putc
stop:   di
        halt
        jr      stop

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

tnum    equ     0xBF00                  ; the check number (window 5, SRAM)

tests:
        ; 1: fill 7 bytes from an odd address: VALUE by address
        ds      16, 0
        ds      16, 0xEE
        JOB     0, B8|BCONST, 0xCC, 0, 0, DST_P+1, 7, 1, 0, 0, 0, 0x44332211, 0
        db      0xEE, 0x22, 0x33, 0x44, 0x11, 0x22, 0x33, 0x44, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE
        ; 2: a 2D copy, 3 x 2, from odd to even addresses, strides 4 and 5
        db      0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F
        ds      16, 0xEE
        JOB     0, B8, 0xCC, 0, SRC_P+1, DST_P+2, 3, 2, 0, 4, 5, 0, 0
        db      0xEE, 0xEE, 0x11, 0x12, 0x13, 0xEE, 0xEE, 0x15, 0x16, 0x17, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE
        ; 3: cookie-cut with a compare mask, key colour 0
        db      0x00, 0x21, 0x00, 0x23, 0x24, 0x00, 0x26, 0x27, 0, 0, 0, 0, 0, 0, 0, 0
        ds      16, 0xEE
        JOB     0, B8|MKEY, 0xCA, 0, SRC_P, DST_P+1, 6, 1, 0, 0, 0, 0, 0
        db      0xEE, 0xEE, 0x21, 0xEE, 0x23, 0x24, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE
        ; 4: XOR (0x66), which reads C
        db      0x0F, 0xF0, 0xAA, 0x55, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ds      16, 0xEE
        JOB     0, B8, 0x66, 0, SRC_P, DST_P+3, 4, 1, 0, 0, 0, 0, 0
        db      0xEE, 0xEE, 0xEE, 0xE1, 0x1E, 0x44, 0xBB, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE
        ; 5: 4 bpp, 3 pixels from source pixel 1 to destination pixel 1 (BBIT 1, DBIT 1)
        db      0x12, 0x34, 0x56, 0x78, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ds      16, 0xEE
        JOB     0, B4, 0xCC, 0, SRC_P, DST_P+1, 3, 1, 0x0110, 0, 0, 0, 0
        db      0xEE, 0xE2, 0x34, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE
        ; 6: cookie-cut through a 1 bpp mask image from bit 2 (ABIT 2): 1001 0111
        db      0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0xA5, 0xF0, 0, 0, 0, 0, 0, 0
        ds      16, 0xEE
        JOB     0, B8|MIMG, 0xCA, SRC_P+8, SRC_P, DST_P, 8, 1, 0x0002, 0, 0, 0, 0
        db      0x31, 0xEE, 0xEE, 0x34, 0xEE, 0x36, 0x37, 0x38, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE
        ; 7: saturating ADD of a constant, by address: + 0x20 and + 0x01
        ds      16, 0
        ds      16, 0xEE
        JOB     ADD|SAT, B8|BCONST, 0, 0, 0, DST_P+2, 2, 1, 0, 0, 0, 0x01200000, 0
        db      0xEE, 0xEE, 0xFF, 0xEF, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE
        ; 8: an overlapping copy two bytes up, backwards (DESC)
        ds      16, 0
        db      0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F
        JOB     0, B8|DESC, 0xCC, 0, DST_P, DST_P+2, 6, 1, 0, 0, 0, 0, 0
        db      0x00, 0x01, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F
        db      0xFF

descs:  JOB     0, B8|BCONST, 0xCC, 0, 0, DST_P+1, 1, 1, 0, 0, 0, 0x55555555, DESCS_P+32
        JOB     0, B8|BCONST|IRQ, 0xCC, 0, 0, DST_P+5, 1, 1, 0, 0, 0, 0x66666666, 0

job_badop:  JOB 2, B8|BCONST, 0xCC, 0, 0, DST_P, 1, 1, 0, 0, 0, 0, 0
job_mask3:  JOB 0, B8|BCONST|0x60, 0xCC, 0, 0, DST_P, 1, 1, 0, 0, 0, 0, 0
job_ctrl2:  db  0, B8|BCONST, 1, 0xCC
            d24 0, 0, DST_P, 1
            dw  1, 0, 0, 0
            dd  0
            d24 0
            db  0
job_far:    JOB 0, B8|BCONST, 0xCC, 0, 0, 0x7F0000, 1, 1, 0, 0, 0, 0, 0
job_two1:   JOB 0, B8, 0xCC, 0, SRC_P+10, DST_P+0x400, 100, 3, 0, 100, 128, 0, 0
job_two0:   JOB 0, B8|BCONST, 0xCC, 0, 0, DST_P+0x800, 600, 1, 0, 0, 0, 0x77777777, 0
job_ldir:   JOB 0, B8|BCONST, 0xCC, 0, 0, DST_P+0x10, 4, 1, 0, 0, 0, 0x5A5A5A5A, 0
job_lddr:   JOB 0, B8|BCONST, 0xCC, 0, 0, DST_P+0x14, 4, 1, 0, 0, 0, 0xA5A5A5A5, 0
job_long:   JOB 0, B8|BCONST, 0xCC, 0, 0, DST_P+0x100, 4000, 1, 0, 0, 0, 0, 0
