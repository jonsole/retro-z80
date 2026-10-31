; DMA engine random test (ticket #40; spec 14). dgen.py puts random data,
; descriptors and a control table in the SRAM; this program starts the 4
; channels on their chains, waits for them all, checks that none stopped
; with an error, that each is DONE and that each raised its interrupt, and
; prints PASS or FAIL nn. The testbench then dumps the SRAM (+ramout) and
; dmodel.py checks every byte. retro68k's sim/dtest/dtest.s (ac7b75a), the
; random part; the directed tests are in sim/dmx.
;
;   channels 0-2  a chain of descriptors in SRAM (CHDESC, START)
;   channel 3     its first job written into its job registers (RUN), the
;                 rest a chain in SRAM
;
; The control table (keep in step with dgen.py), physical 0x00A000, Z80
; 0xE000 in the map after reset:
CTL     equ     0xE000
C_CH0   equ     0x00                    ; channel 0's first descriptor (3 bytes)
C_CH1   equ     0x04
C_CH2   equ     0x08
C_EXPECT equ    0x0C                    ; DMXINT bits to expect
C_JOB3  equ     0x10                    ; channel 3's first job (32 bytes)
C_CLIP  equ     0x30                    ; the LINE clip rectangle (8 bytes)

        DEVICE  NOSLOT64K
        include "hw.inc"

    MACRO WREG xp, xv                   ; write xv to register port xp (A, B, C changed)
        ld      bc,xp
        ld      a,xv
        out     (c),a
    ENDM
    MACRO CHDESC xp, xo                 ; CHDESC at port xp from the table's offset xo
        ld      hl,CTL + xo
        ld      bc,xp
        ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,(hl)
        out     (c),a
    ENDM
    MACRO RCHK xp, xv                   ; fail check D unless register port xp reads xv
        ld      bc,xp
        in      a,(c)
        cp      xv
        jp      nz,fail
    ENDM

        ORG     0x0000
        di
        jp      start
        ds      0x66 - $, 0xFF
        retn

start:  ld      sp,0xC000
        WREG    SERCON_P, SERCON_EN_M | SERCON_CTLEN_M
        WREG    DMACON_P, DMACON_SETCLR_M | DMACON_DMAEN_M | DMACON_BLTEN_M
        WREG    DMXINTEN_P, 0x0F

        ld      hl,CTL + C_CLIP         ; the clip rectangle (spec 14, 8.4)
        ld      bc,CLIPXMIN_P
.clip:  ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,b
        cp      high CLIPXMIN_P + 8
        jr      nz,.clip

        ld      hl,CTL + C_JOB3         ; channel 3: its job registers
        ld      bc,DMX3_CTRL_P
.job3:  ld      a,(hl)
        out     (c),a
        inc     hl
        inc     b
        ld      a,b
        cp      high DMX3_CTRL_P + 0x20
        jr      nz,.job3

        CHDESC  DMX0_CHDESC0_P, C_CH0
        CHDESC  DMX1_CHDESC0_P, C_CH1
        CHDESC  DMX2_CHDESC0_P, C_CH2
        WREG    DMX0_CHCTRL_P, DMX_CHCTRL_START_M
        WREG    DMX1_CHCTRL_P, DMX_CHCTRL_START_M
        WREG    DMX2_CHCTRL_P, DMX_CHCTRL_START_M
        WREG    DMX3_CHCTRL_P, DMX_CHCTRL_RUN_M

        ld      d,1                     ; wait for all four
.wait:  ld      e,0
        ld      bc,DMX0_CHSTAT_P
        in      a,(c)
        or      e
        ld      e,a
        ld      bc,DMX1_CHSTAT_P
        in      a,(c)
        or      e
        ld      e,a
        ld      bc,DMX2_CHSTAT_P
        in      a,(c)
        or      e
        ld      e,a
        ld      bc,DMX3_CHSTAT_P
        in      a,(c)
        or      e
        rra
        jr      c,.wait

        ld      d,2                     ; each DONE, none with ERR
        RCHK    DMX0_CHSTAT_P, DMX_CHSTAT_DONE_M
        ld      d,3
        RCHK    DMX1_CHSTAT_P, DMX_CHSTAT_DONE_M
        ld      d,4
        RCHK    DMX2_CHSTAT_P, DMX_CHSTAT_DONE_M
        ld      d,5
        RCHK    DMX3_CHSTAT_P, DMX_CHSTAT_DONE_M
        ld      d,6                     ; the interrupts asked for
        ld      a,(CTL + C_EXPECT)
        ld      e,a
        ld      bc,DMXINT_P
        in      a,(c)
        cp      e
        jp      nz,fail

        ld      hl,pass
        call    puts
        jp      stop

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
