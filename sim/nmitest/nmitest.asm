; NMI test ROM (ticket #27): the NMI set of the interrupt pages and the
; stack capture (spec 2, sections 9.7-9.9; spec 1, sections 8.2-8.4) on the
; whole machine. Runs in place of the boot ROM (tb.v +rom=nmitest.hex) and
; prints "PASS" or "FAIL nn" (the number of the first check that failed, in
; hex). It asks tb.v for each NMI through reserved port 0x0003 (1: the
; Multiface button, 2: BREAK over USB). tb.v checks every NMI on the way:
; no request for the pushes or for RETN's stack reads, the bytes popped are
; the captured PC, and its own model of the switch and the restore.
;
; Covered: the registers' reset values, and a page register's held byte;
; an NMI with the defaults (window 0 reads ROM page 3 and writes page
; 0x0FF): NMICAPPC, NMICAPSP, INNMI, the switched and saved pages, the
; pushes not in memory, RETN back with SP and window 0 as they were; BREAK
; with SP in the register page, aimed at MMU0 (which must not change), and
; a written NMICAPPC returning elsewhere; NMICTL.EN = 0 with SP in ROM (no
; window switched, still captured); NMIMASK with window 6 switched too.
;
; The handler (the same code at 0x0066 of page 0, for EN = 0, and of page 3)
; keeps its own stack in window 4 and writes what it finds to R_*.

        DEVICE  NOSLOT64K
        include "hw.inc"

R_CAPSP equ     0x8000                  ; SRAM page 2 (window 4): what the handler saw
R_CAPPC equ     0x8002
R_CTL   equ     0x8004                  ; NMICTL
R_MMU0  equ     0x8005
R_MMU0W equ     0x8007
R_SAV0  equ     0x8009
R_SP    equ     0x800B                  ; SP in the handler
R_STAT  equ     0x800D                  ; NMISTAT
R_W6    equ     0x800E                  ; the byte at 0xC000
R_FLAG  equ     0x8010                  ; 1: the handler ran
R_MODE  equ     0x8011                  ; 1: the handler writes NMICAPPC = cont
R_TMP   equ     0x8012
HSTACK  equ     0x9F00

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
    MACRO WCHK xa, xv                   ; fail check D unless the word at xa is xv
        ld      hl,(xa)
        ld      bc,xv
        call    cmp16
    ENDM
    MACRO MCHK xa, xv                   ; fail check D unless the byte at xa is xv
        ld      a,(xa)
        cp      xv
        jp      nz,fail
    ENDM
    MACRO SETPG xp, xpg                 ; page register at port xp (byte 0) = xpg
        ld      bc,xp
        ld      a,low (xpg)
        out     (c),a
        inc     b
        ld      a,high (xpg)
        out     (c),a
    ENDM
    MACRO GETPG xp, xa                  ; page register at port xp into the word at xa
        ld      bc,xp
        in      a,(c)
        ld      (xa),a
        inc     b
        in      a,(c)
        ld      (xa + 1),a
    ENDM
    MACRO NMIASK xv                     ; ask tb.v for an NMI: 1 button, 2 BREAK
        ld      bc,0x0003
        ld      a,xv
        out     (c),a
    ENDM
    ; The handler, at 0x0066 of page 0 and of page 3
    MACRO HANDLER
        ld      (R_SP),sp
        ld      sp,HSTACK
        push    af
        push    bc
        push    hl
        GETPG   NMICAPSP0_P, R_CAPSP
        GETPG   NMICAPPC0_P, R_CAPPC
        ld      bc,NMICTL_P
        in      a,(c)
        ld      (R_CTL),a
        GETPG   MMU0_0_P, R_MMU0
        GETPG   MMU0W_0_P, R_MMU0W
        GETPG   NMISAV0_0_P, R_SAV0
        ld      bc,NMISTAT_P
        in      a,(c)
        ld      (R_STAT),a
        out     (c),a                   ; cleared
        ld      a,(0xC000)
        ld      (R_W6),a
        ld      a,0x77
        ld      (0x0100),a              ; window 0: page 0x0FF (or ignored by the ROM)
        ld      a,(R_MODE)
        or      a
        jr      z,.ret
        ld      hl,cont
        ld      bc,NMICAPPC0_P          ; return somewhere else
        out     (c),l
        inc     b
        out     (c),h
.ret:   ld      a,1
        ld      (R_FLAG),a
        pop     hl
        pop     bc
        pop     af
        ld      sp,(R_SP)
        retn
    ENDM

        ORG     0x0000

reset:  di
        jp      start

        ds      0x66 - $, 0xFF
nmi0:   HANDLER                         ; NMICTL.EN = 0: window 0 is still page 0

start:  ld      sp,0xC000               ; window 6: SRAM page 4
        WREG    SERCON_P, SERCON_EN_M | SERCON_CTLEN_M

        ; ---- check 1: reset values (spec 2, section 9.8)
        ld      d,1
        RCHK    NMICTL_P, NMICTL_EN_M
        RCHK    NMIMASK_P, 0x01
        RCHK    NMIP0_0_P, 0xFF
        RCHK    NMIP0_1_P, 0x03
        RCHK    NMIP0W_0_P, 0xFF
        RCHK    NMIP0W_1_P, 0x00
        RCHK    NMIP3_0_P, 0x01
        RCHK    NMISAV0_0_P, 0xFC
        RCHK    NMISAV0_1_P, 0x03
        RCHK    NMISAV7W_0_P, 0x05
        RCHK    NMICAPPC0_P, 0
        RCHK    NMICAPSP1_P, 0
        RCHK    0x4A01, 0xFF            ; reserved: no unit answers
        RCHK    0x3F01, 0xFF            ; registers 0x00-0x3F of page 0x01 are reserved
        ; ---- check 2: a page register's held byte, and a read page commit
        ; setting its write page
        ld      d,2
        SETPG   NMIP6_0_P, 0x010
        RCHK    NMIP6W_0_P, 0x10
        RCHK    NMIP6W_1_P, 0x00
        WREG    NMIP6W_1_P, 0x01        ; byte 1 alone: bits 7-0 kept
        RCHK    NMIP6W_0_P, 0x10
        RCHK    NMIP6W_1_P, 0x01
        RCHK    NMIP6_1_P, 0x00
        WREG    NMIP6W_0_P, 0x10
        WREG    NMIP6W_1_P, 0x00        ; NMIP6W back to 0x010

        ; ---- checks 3-5: an NMI with the defaults, from the button
        ld      a,0x3C
        ld      (0xC000),a              ; (the handler reads it)
        ld      hl,0xBFF0               ; the stack's top bytes: 0x55
        ld      b,16
.fill:  ld      (hl),0x55
        inc     hl
        djnz    .fill
        xor     a
        ld      (R_MODE),a
        ld      (R_FLAG),a
        NMIASK  1
.w2:    ld      a,(R_FLAG)
        or      a
        jr      z,.w2
.w2e:   ld      d,3
        MCHK    0xBFFE, 0x55            ; the pushes never reached memory (before any CALL)
        MCHK    0xBFFF, 0x55
        ld      (R_TMP),sp
        WCHK    R_TMP, 0xC000           ; SP as it was
        WCHK    R_CAPSP, 0xC000
        WCHK    R_SP, 0xBFFE            ; the Z80 stepped SP down by 2
        ld      hl,(R_CAPPC)            ; the PC: in the wait loop
        ld      bc,.w2
        or      a
        sbc     hl,bc
        jp      c,fail
        ld      bc,.w2e - .w2
        sbc     hl,bc
        jp      nc,fail
        ld      d,4
        MCHK    R_CTL, NMICTL_EN_M | NMICTL_INNMI_M
        RCHK    NMICTL_P, NMICTL_EN_M   ; INNMI 0 after RETN
        WCHK    R_MMU0, 0x3FF           ; window 0: ROM page 3 ...
        WCHK    R_MMU0W, 0x0FF          ; ... writing the workspace page
        WCHK    R_SAV0, 0x3FC           ; the program's page saved
        RCHK    MMU0_0_P, 0xFC          ; and back after RETN
        RCHK    MMU0_1_P, 0x03
        RCHK    MMU0W_1_P, 0x03
        MCHK    R_STAT, NMISTAT_BUTTON_M
        ld      d,5
        SETPG   MMU5_0_P, 0x0FF         ; the handler's write to 0x0100 went to page 0x0FF
        MCHK    0xA100, 0x77
        SETPG   MMU5_0_P, 0x003

        ; ---- checks 6-7: BREAK over USB, SP in the register page aimed at
        ; MMU0 (offsets 0x80-0x81), and NMICAPPC written: RETN goes to cont
        ld      d,6
        ld      a,1
        ld      (R_MODE),a
        xor     a
        ld      (R_FLAG),a
        SETPG   MMU5_0_P, 0x3F8         ; window 5: the register page
        ld      sp,0xA082
        NMIASK  2
.spin:  jr      .spin
cont:   ld      (R_TMP),sp
        ld      sp,0xC000
        SETPG   MMU5_0_P, 0x003
        WCHK    R_TMP, 0xA082
        WCHK    R_CAPSP, 0xA082
        WCHK    R_SP, 0xA080
        WCHK    R_CAPPC, start.spin
        MCHK    R_STAT, NMISTAT_USB_M
        ld      d,7
        RCHK    MMU0_0_P, 0xFC          ; MMU0 untouched by the pushes
        RCHK    MMU0_1_P, 0x03
        WCHK    R_MMU0, 0x3FF

        ; ---- check 8: NMICTL.EN = 0, SP in ROM: no window switched, still captured
        ld      d,8
        xor     a
        ld      (R_MODE),a
        ld      (R_FLAG),a
        WREG    NMICTL_P, 0
        ld      sp,0x1000
        NMIASK  1
.w4:    ld      a,(R_FLAG)
        or      a
        jr      z,.w4
        ld      (R_TMP),sp
        ld      sp,0xC000
        WCHK    R_TMP, 0x1000
        WCHK    R_CAPSP, 0x1000
        MCHK    R_CTL, NMICTL_INNMI_M
        WCHK    R_MMU0, 0x3FC
        RCHK    NMICTL_P, 0
        WREG    NMICTL_P, NMICTL_EN_M

        ; ---- check 9: NMIMASK with window 6: NMIP6 = SRAM page 0x010
        ld      d,9
        SETPG   MMU5_0_P, 0x010
        ld      a,0xA7
        ld      (0xA000),a              ; page 0x010's first byte
        SETPG   MMU5_0_P, 0x003
        WREG    NMIMASK_P, 0x41
        xor     a
        ld      (R_FLAG),a
        NMIASK  1
.w5:    ld      a,(R_FLAG)
        or      a
        jr      z,.w5
        MCHK    R_W6, 0xA7              ; the handler saw page 0x010 in window 6
        MCHK    0xC000, 0x3C            ; the program sees page 4 again (set at check 3)
        RCHK    MMU6_0_P, 0x04
        RCHK    NMISAV6_0_P, 0x04
        WCHK    R_MMU0, 0x3FF
        RCHK    MMU0_0_P, 0xFC
        WREG    NMIMASK_P, 0x01

        ; ---- checks 10-11: the default NMI at 3.57 MHz and at 2.5 MHz
        ld      d,0x10
        ld      e,CPUSPEED_SPECTRUM_M
        call    slow
        ld      d,0x11
        ld      e,7                     ; DIV = 7: 2.5 MHz
        call    slow
        WREG    CPUSPEED_P, 0

        ld      hl,pass
        call    puts
        jr      stop

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

; An NMI at CPUSPEED = E, with the defaults: switched, captured, restored
slow:   ld      bc,CPUSPEED_P
        out     (c),e
        xor     a
        ld      (R_FLAG),a
        NMIASK  1
.w:     ld      a,(R_FLAG)
        or      a
        jr      z,.w
        ld      (R_TMP),sp
        WCHK    R_TMP, 0xBFFE           ; SP back (the CALL's return address below 0xC000)
        WCHK    R_CAPSP, 0xBFFE
        WCHK    R_MMU0, 0x3FF
        WCHK    R_MMU0W, 0x0FF
        RCHK    MMU0_1_P, 0x03
        RCHK    MMU0_0_P, 0xFC
        RCHK    NMICTL_P, NMICTL_EN_M
        ret

; Fail check D unless HL = BC
cmp16:  or      a
        sbc     hl,bc
        ret     z
        pop     hl
        jp      fail

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
        ASSERT  $ <= 0x2000

; ---------------------------------------------------------------- page 3
; The NMI page: window 0 during an NMI with NMICTL.EN
        ds      0x6000 - $, 0xFF
        DISP    0x0000
        ds      0x66 - $, 0xFF
nmi3:   HANDLER
        ENT
