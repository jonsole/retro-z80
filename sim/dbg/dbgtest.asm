; Debug unit test ROM (ticket #28; spec 18, section 11) on the whole
; machine. Runs in place of the boot ROM (tb.v +rom=dbgtest.hex) and prints
; "PASS" or "FAIL nn" (the number of the first check that failed, in hex).
; tb.v checks on the way: every debug NMI request comes at its time (a
; fetch's or an acknowledge's end, or E + 3 of a data cycle's T1); a step
; runs exactly one instruction (its own count of instruction starts from
; the resume M1 to the NMI response; none when the resume M1 is an
; acknowledge); the bytes the core takes are memory's, or 0x00 for a
; breakpoint's NOP.
;
; NMICTL.EN = 0, so the NMI comes to the handler at 0x0066 of this ROM; it
; notes DBGSTAT (and clears it), NMICAPPC, the kept access and the count of
; NMIs, and goes back to `back` by writing NMICAPPC. A test runs code from
; an address with `run`, which leaves by RETN (with INNMI = 0, a plain
; RETN), so the unit goes live at the first M1 of the code.
;
;   01-0F  registers: reset values, read back, reserved, the register page
;   10-1F  breakpoints: each of the 4 in RAM, in ROM, the page match, the
;          NMI's dummy fetch, the resume M1, continuation bytes, LIVE = 0
;   20-3F  single step of each instruction class at 20 MHz; 40-5F at
;          3.57 MHz; 60-7F at 2.5 MHz
;   80-8F  LDIR stepped; /INT held off (STEPINT = 0), and STEPINT = 1:
;          the step stops at the handler's first instruction (DU6)
;   90-AF  watchpoints: memory write, read, direction, opcode and operand
;          reads, mask, I/O write and read with 16-bit ports, the kept
;          access, LDIR, EX (SP),HL, OUTI; a step that hits one; DBGSTAT W1C

        DEVICE  NOSLOT64K
        include "hw.inc"

R_CHK   equ     0x8000                  ; the check being made
R_N     equ     0x8001                  ; NMIs since run started
R_STAT  equ     0x8002                  ; DBGSTAT at the NMI
R_PC    equ     0x8003                  ; 2: NMICAPPC
R_HA    equ     0x8005                  ; 2: DBGHITADDR
R_HD    equ     0x8007                  ; DBGHITDATA
R_HK    equ     0x8008                  ; DBGHITKIND
R_SP    equ     0x8009                  ; 2: the handler's SP
R_CONT  equ     0x800B                  ; 2: where the handler goes back to
R_SAVSP equ     0x800D                  ; 2: run's SP
R_TGT   equ     0x800F                  ; 2: where run starts
R_ICTL  equ     0x8011                  ; DBGCTL for run
R_IEI   equ     0x8012                  ; 1: run leaves with EI (one-shot)
R_PUSH  equ     0x8013                  ; 2: a word run pushes under the target (0: none; one-shot)
R_IBC   equ     0x8015                  ; 2: BC for run
R_AE    equ     0x8017                  ; A at back
R_BCE   equ     0x8018                  ; 2: BC at back
R_LIVE  equ     0x801A                  ; DBGCTL at back
R_EXP   equ     0x801B                  ; 2: the PC a step must stop at
R_IFL   equ     0x801D                  ; maskable interrupts taken
R_IFLN  equ     0x801E                  ; ... as the NMI found it
R_KEEP  equ     0x801F                  ; 1: the handler leaves DBGSTAT as it is
R_BASE  equ     0x8020                  ; the step table's first check number
R_SPD   equ     0x8021                  ; CPUSPEED for the code run (the handler and the tests run at 20 MHz)
SNIPA   equ     0x8100                  ; code copied here to run from RAM
DATA    equ     0x9000                  ; data the code reads and writes
IVT     equ     0x9100                  ; the IM 2 table (I = 0x91, VECBASE 0)
SRC     equ     0x9200                  ; LDIR's source
HSTACK  equ     0x9F00                  ; the handler's stack
STACK   equ     0xC000                  ; the tests' stack (window 6)

    MACRO WREG xp, xv                   ; write xv to register port xp (A, BC changed)
        ld      bc,xp
        ld      a,xv
        out     (c),a
    ENDM
    MACRO RCHK xp, xv                   ; fail unless register port xp reads xv
        ld      bc,xp
        in      a,(c)
        cp      xv
        jp      nz,fail
    ENDM
    MACRO MCHK xa, xv                   ; fail unless the byte at xa is xv
        ld      a,(xa)
        cp      xv
        jp      nz,fail
    ENDM
    MACRO WCHK xa, xv                   ; fail unless the word at xa is xv
        ld      hl,(xa)
        ld      de,xv
        or      a
        sbc     hl,de
        jp      nz,fail
    ENDM
    MACRO CHK xn                        ; the check's number
        ld      a,xn
        ld      (R_CHK),a
    ENDM
    MACRO SETBP xn, xa, xc              ; breakpoint xn at xa, DBGBPn_CTL = xc
        ld      bc,DBGBP0_ADDR0_P + (xn) * 0x800
        ld      a,low (xa)
        out     (c),a
        inc     b
        ld      a,high (xa)
        out     (c),a
        ld      b,high (DBGBP0_CTL_P + (xn) * 0x800)
        ld      a,xc
        out     (c),a
    ENDM
    MACRO SETBPPG xn, xpg               ; breakpoint xn's page
        ld      bc,DBGBP0_PAGE0_P + (xn) * 0x800
        ld      a,low (xpg)
        out     (c),a
        inc     b
        ld      a,high (xpg)
        out     (c),a
    ENDM
    MACRO SETWP xn, xa, xm, xc          ; watchpoint xn: address, mask, DBGWPn_CTL
        ld      bc,DBGWP0_ADDR0_P + (xn) * 0x800
        ld      a,low (xa)
        out     (c),a
        inc     b
        ld      a,high (xa)
        out     (c),a
        inc     b
        ld      a,low (xm)
        out     (c),a
        inc     b
        ld      a,high (xm)
        out     (c),a
        inc     b
        ld      a,xc
        out     (c),a
    ENDM
    MACRO RUNAT xt, xc                  ; run from xt with DBGCTL = xc
        ld      hl,xt
        ld      (R_TGT),hl
        ld      a,xc
        ld      (R_ICTL),a
        call    run
    ENDM
    MACRO SNIP xs, xl                   ; copy a snippet to SNIPA
        ld      hl,xs
        ld      de,SNIPA
        ld      bc,xl
        ldir
    ENDM
    ; One stop: R_N = 1, DBGSTAT xs, NMICAPPC xp
    MACRO STOP1 xs, xp
        MCHK    R_N, 1
        MCHK    R_STAT, xs
        WCHK    R_PC, xp
    ENDM

BP_EN   equ     DBGBP_CTL_EN_M
BP_PG   equ     DBGBP_CTL_EN_M | DBGBP_CTL_PAGEEN_M
WP_W    equ     DBGWP_CTL_EN_M | DBGWP_CTL_WRITE_M
WP_R    equ     DBGWP_CTL_EN_M | DBGWP_CTL_READ_M
WP_IOW  equ     WP_W | DBGWP_CTL_IO_M
WP_IOR  equ     WP_R | DBGWP_CTL_IO_M
STEP    equ     DBGCTL_STEP_M

        ORG     0x0000

reset:  di
        jp      start

; ---------------------------------------------------------------- the NMI
        ds      0x66 - $, 0xFF
nmi:    ld      (R_SP),sp
        ld      sp,HSTACK
        push    af
        push    bc
        push    hl
        WREG    CPUSPEED_P, 0
        ld      bc,DBGSTAT_P
        in      a,(c)
        ld      (R_STAT),a
        ld      l,a
        ld      a,(R_KEEP)
        or      a
        jr      nz,.keep
        out     (c),l                   ; W1C: the bits seen
.keep:  ld      bc,NMICAPPC0_P
        in      l,(c)
        inc     b
        in      h,(c)
        ld      (R_PC),hl
        ld      bc,DBGHITADDR0_P
        in      l,(c)
        inc     b
        in      h,(c)
        ld      (R_HA),hl
        ld      b,high DBGHITDATA_P
        in      a,(c)
        ld      (R_HD),a
        inc     b
        in      a,(c)
        ld      (R_HK),a
        ld      a,(R_N)
        inc     a
        ld      (R_N),a
        ld      a,(R_IFL)
        ld      (R_IFLN),a
        ld      hl,(R_CONT)             ; back to the test
        ld      bc,NMICAPPC0_P
        out     (c),l
        inc     b
        out     (c),h
        pop     hl
        pop     bc
        pop     af
        ld      sp,(R_SP)
        retn
nmi_in: equ     nmi + 3                 ; an address in the handler

; ---------------------------------------------------------------- the maskable interrupt (IM 2, SOFT)
ihand:  push    af
        push    bc
        ld      a,(R_IFL)
        inc     a
        ld      (R_IFL),a
        WREG    SOFTINT_P, SOFTINT_CLR_M
        pop     bc
        pop     af
        reti                            ; interrupts stay off

; ---------------------------------------------------------------- run
; Run from (R_TGT) with DBGCTL = (R_ICTL), BC = (R_IBC), A = 0, HL = SRC,
; DE = DATA, IX = IY = DATA, leaving by RETN (with EI first if R_IEI);
; back again at `back` after an NMI or the code's JP back
run:    ld      (R_SAVSP),sp
        ld      hl,back
        ld      (R_CONT),hl
        xor     a
        ld      (R_N),a
        WREG    DBGSTAT_P, 0x7F
        ld      a,(R_ICTL)
        ld      bc,DBGCTL_P
        out     (c),a
        ld      hl,(R_PUSH)
        ld      a,h
        or      l
        jr      z,.np
        push    hl
.np:    ld      hl,(R_TGT)
        push    hl
        ld      hl,0
        ld      (R_PUSH),hl
        ld      a,(R_SPD)               ; from the next T1
        ld      bc,CPUSPEED_P
        out     (c),a
        ld      ix,DATA
        ld      iy,DATA
        ld      hl,SRC
        ld      de,DATA
        ld      bc,(R_IBC)
        ld      a,(R_IEI)
        or      a
        ld      a,0
        ld      (R_IEI),a
        jr      z,.di
        ei
.di:    retn
back:   ld      (R_AE),a
        ld      (R_BCE),bc
        ld      sp,(R_SAVSP)
        di
        ld      bc,DBGCTL_P
        in      a,(c)
        ld      (R_LIVE),a
        ; everything off (LIVE too)
        xor     a
        out     (c),a
        ld      bc,CPUSPEED_P
        out     (c),a
        ld      bc,DBGBP0_CTL_P
        out     (c),a
        ld      b,high DBGBP1_CTL_P
        out     (c),a
        ld      b,high DBGBP2_CTL_P
        out     (c),a
        ld      b,high DBGBP3_CTL_P
        out     (c),a
        ld      b,high DBGWP0_CTL_P
        out     (c),a
        ld      b,high DBGWP1_CTL_P
        out     (c),a
        ld      bc,0
        ld      (R_IBC),bc
        ret

; ---------------------------------------------------------------- the tests
start:  ld      sp,STACK
        WREG    SERCON_P, SERCON_EN_M | SERCON_CTLEN_M
        WREG    NMICTL_P, 0             ; the NMI at 0x0066 of this page
        xor     a
        ld      hl,R_CHK
        ld      b,0x40
.clr:   ld      (hl),a
        inc     hl
        djnz    .clr
        ld      hl,DATA                 ; the data the code reads, defined
        ld      de,DATA + 1
        ld      bc,0x2FF
        ld      (hl),a
        ldir

        ; ---- 01-05: registers
        CHK     1                       ; reset values
        RCHK    DBGCTL_P, 0
        RCHK    DBGSTAT_P, 0
        RCHK    DBGHITADDR0_P, 0
        RCHK    DBGHITADDR1_P, 0
        RCHK    DBGHITDATA_P, 0
        RCHK    DBGHITKIND_P, 0
        RCHK    DBGBP3_ADDR1_P, 0
        RCHK    DBGBP3_PAGE1_P, 0
        RCHK    DBGBP0_CTL_P, 0
        RCHK    DBGWP0_MASK0_P, 0xFF
        RCHK    DBGWP0_MASK1_P, 0xFF
        RCHK    DBGWP1_MASK1_P, 0xFF
        RCHK    DBGWP1_CTL_P, 0
        CHK     2                       ; read back
        SETBP   2, 0x1234, BP_PG
        SETBPPG 2, 0x3FF
        RCHK    DBGBP2_ADDR0_P, 0x34
        RCHK    DBGBP2_ADDR1_P, 0x12
        RCHK    DBGBP2_PAGE0_P, 0xFF
        RCHK    DBGBP2_PAGE1_P, 0x03    ; bits 15-10 read 0
        RCHK    DBGBP2_CTL_P, BP_PG
        SETWP   1, 0xABCD, 0x5AA5, 0xFF
        RCHK    DBGWP1_ADDR0_P, 0xCD
        RCHK    DBGWP1_ADDR1_P, 0xAB
        RCHK    DBGWP1_MASK0_P, 0xA5
        RCHK    DBGWP1_MASK1_P, 0x5A
        RCHK    DBGWP1_CTL_P, 0x0F      ; bits 7-4 read 0
        WREG    DBGCTL_P, 0xFE          ; STEPINT; LIVE 1 does nothing
        RCHK    DBGCTL_P, DBGCTL_STEPINT_M
        WREG    DBGCTL_P, 0
        SETWP   1, 0, 0xFFFF, 0
        SETBP   2, 0, 0
        SETBPPG 2, 0
        CHK     3                       ; reserved registers
        RCHK    0x0602, 0xFF
        RCHK    0x0F02, 0xFF
        RCHK    0x1502, 0xFF
        RCHK    0x1F02, 0xFF
        RCHK    0x3D02, 0xFF
        RCHK    0x3F02, 0xFF
        RCHK    0x4002, 0xFF
        CHK     4                       ; the register page: offset 0x0200 + register
        WREG    MMU5_0_P, 0xF8          ; window 5 (0xA000): REGS, page 0x3F8
        WREG    MMU5_1_P, 0x03
        ld      a,0x5A
        ld      (0xA000 + REGS_DBGPAGE + DBGBP0_ADDR0),a
        RCHK    DBGBP0_ADDR0_P, 0x5A
        WREG    DBGBP0_ADDR1_P, 0xA5
        ld      a,(0xA000 + REGS_DBGPAGE + DBGBP0_ADDR1)
        cp      0xA5
        jp      nz,fail
        ld      a,(0xA000 + REGS_DBGPAGE + 0x06)    ; reserved
        cp      0xFF
        jp      nz,fail
        WREG    MMU5_0_P, 3             ; window 5 back to SRAM page 3
        WREG    MMU5_1_P, 0
        SETBP   0, 0, 0

        ; ---- 10-1F: breakpoints
        SNIP    b_src, B_LEN
        CHK     0x10                    ; each of the 4, in RAM; one in the handler never hits
        SETBP   0, b_1, BP_EN
        SETBP   1, nmi_in, BP_EN
        RUNAT   b_s, 0
        STOP1   DBGSTAT_BP0_M, b_2      ; NMICAPPC = the breakpoint + 1 (the NOP)
        MCHK    R_AE, 1                 ; the INC A at the breakpoint did not run
        CHK     0x11
        SETBP   1, b_1, BP_EN
        SETBP   2, nmi_in, BP_EN
        RUNAT   b_s, 0
        STOP1   DBGSTAT_BP1_M, b_2
        MCHK    R_AE, 1
        CHK     0x12
        SETBP   2, b_1, BP_EN
        SETBP   3, nmi_in, BP_EN
        RUNAT   b_s, 0
        STOP1   DBGSTAT_BP2_M, b_2
        MCHK    R_AE, 1
        CHK     0x13
        SETBP   3, b_1, BP_EN
        SETBP   0, nmi_in, BP_EN
        RUNAT   b_s, 0
        STOP1   DBGSTAT_BP3_M, b_2
        MCHK    R_AE, 1
        CHK     0x14                    ; in ROM
        SETBP   0, r_1, BP_EN
        RUNAT   r_s, 0
        STOP1   DBGSTAT_BP0_M, r_2
        MCHK    R_AE, 1
        CHK     0x15                    ; the page match: page 2 is in window 4
        SETBP   0, b_1, BP_PG
        SETBPPG 0, 2
        RUNAT   b_s, 0
        STOP1   DBGSTAT_BP0_M, b_2
        CHK     0x16                    ; ... page 3 is not
        SETBP   0, b_1, BP_PG
        SETBPPG 0, 3
        RUNAT   b_s, 0
        MCHK    R_N, 0
        MCHK    R_AE, 4
        SETBPPG 0, 0
        CHK     0x17                    ; the NMI's dummy fetch at b_2 sets no bit
        SETBP   0, b_1, BP_EN
        SETBP   1, b_2, BP_EN
        RUNAT   b_s, 0
        STOP1   DBGSTAT_BP0_M, b_2
        CHK     0x18                    ; the resume M1 never matches; the next hit stops
        SETBP   0, b_1, BP_EN
        SETBP   1, b_3, BP_EN
        RUNAT   b_1, 0
        STOP1   DBGSTAT_BP1_M, b_3 + 1
        MCHK    R_AE, 2
        CHK     0x19                    ; ... and with no other, it runs on
        SETBP   0, b_1, BP_EN
        RUNAT   b_1, 0
        MCHK    R_N, 0
        MCHK    R_AE, 3
        MCHK    R_LIVE, DBGCTL_LIVE_M   ; live after RETN
        SNIP    c_src, C_LEN
        CHK     0x1A                    ; continuation bytes: after CB, ED, DD; DD CB's
        SETBP   0, c_s + 1, BP_EN
        SETBP   1, c_s + 3, BP_EN
        SETBP   2, c_s + 5, BP_EN
        SETBP   3, c_dd + 1, BP_EN
        RUNAT   c_s, 0
        MCHK    R_N, 0
        CHK     0x1B                    ; ... its operand bytes
        SETBP   0, c_dd + 2, BP_EN
        SETBP   1, c_dd + 3, BP_EN
        RUNAT   c_s, 0
        MCHK    R_N, 0
        CHK     0x1C                    ; ... but the DD that starts it
        SETBP   0, c_dd, BP_EN
        RUNAT   c_s, 0
        STOP1   DBGSTAT_BP0_M, c_dd + 1
        CHK     0x1D                    ; LIVE = 0: nothing compares until a RETN
        ld      hl,.lv
        push    hl
        retn                            ; live from .lv
.lv:    RCHK    DBGCTL_P, DBGCTL_LIVE_M
        WREG    DBGCTL_P, 0
        RCHK    DBGCTL_P, 0
        SETBP   0, l_here, BP_EN
        xor     a
        ld      (R_N),a
l_here: nop
        SETBP   0, 0, 0
        MCHK    R_N, 0

        ; ---- 20-7F: a step of each instruction class, at three speeds
        ld      a,0x20
        ld      (R_BASE),a
        call    steps
        ld      a,CPUSPEED_SPECTRUM_M   ; 3.57 MHz
        ld      (R_SPD),a
        ld      a,0x40
        ld      (R_BASE),a
        call    steps
        ld      a,7                     ; 2.5 MHz
        ld      (R_SPD),a
        ld      a,0x60
        ld      (R_BASE),a
        call    steps
        xor     a
        ld      (R_SPD),a

        ; ---- 80-8F: LDIR stepped, and maskable interrupts during a step
        CHK     0x80                    ; LDIR: one iteration; PC on the LDIR again
        ld      hl,3
        ld      (R_IBC),hl
        RUNAT   s_ldir, STEP
        STOP1   DBGSTAT_STEP_M, s_ldir
        WCHK    R_BCE, 2
        CHK     0x81                    ; SOFT pending, IM 2
        ld      a,high IVT
        ld      i,a
        im      2
        ld      hl,ihand
        ld      (IVT + 2 * 18),hl
        WREG    VECBASE_P, 0
        WREG    INTENA2_P, 0x80 | (1 << (18 - 14))
        WREG    INTCON_P, INTCON_MASTER_M
        WREG    SOFTINT_P, SOFTINT_SET_M
        xor     a
        ld      (R_IFL),a
        ld      a,1
        ld      (R_IEI),a
        RUNAT   s_nop, STEP             ; STEPINT = 0: held off
        CHK     0x82
        STOP1   DBGSTAT_STEP_M, s_nop_e
        MCHK    R_IFLN, 0               ; none during the step
        MCHK    R_IFL, 1                ; ... taken after it, when the program went on
        CHK     0x83                    ; STEPINT = 1: the step stops at the handler's first instruction (DU6)
        WREG    SOFTINT_P, SOFTINT_SET_M
        xor     a
        ld      (R_IFL),a
        ld      a,1
        ld      (R_IEI),a
        RUNAT   s_nop, STEP | DBGCTL_STEPINT_M
        CHK     0x84
        MCHK    R_N, 1
        MCHK    R_STAT, DBGSTAT_STEP_M
        CHK     0x85
        WCHK    R_PC, ihand
        MCHK    R_IFL, 0                ; (the handler never ran: NMICAPPC was changed)
        WREG    SOFTINT_P, SOFTINT_CLR_M
        WREG    INTCON_P, 0
        WREG    INTENA2_P, 0x7F
        im      1

        ; ---- 90-AF: watchpoints
        SNIP    w1_src, W1_LEN
        CHK     0x90                    ; a memory write
        SETWP   0, DATA, 0xFFFF, WP_W
        RUNAT   w1_s, 0
        STOP1   DBGSTAT_WP0_M, w1_n     ; after the instruction
        WCHK    R_HA, DATA
        MCHK    R_HD, 0x5A
        MCHK    R_HK, DBGHITKIND_WRITE_M
        CHK     0x91                    ; the opcode fetch at w1_s does not count ...
        SETWP   0, w1_s, 0xFFFF, WP_R
        RUNAT   w1_s, 0
        MCHK    R_N, 0
        CHK     0x92                    ; ... its operand read does
        SETWP   0, w1_s + 1, 0xFFFF, WP_R
        RUNAT   w1_s, 0
        STOP1   DBGSTAT_WP0_M, w1_wr
        MCHK    R_HD, 0x5A
        MCHK    R_HK, 0
        CHK     0x93                    ; the mask: 0xFF00 watches the page
        SETWP   1, DATA + 0x80, 0xFF00, WP_W
        RUNAT   w1_s, 0
        STOP1   DBGSTAT_WP1_M, w1_n
        WCHK    R_HA, DATA
        MCHK    R_HK, DBGHITKIND_WRITE_M | DBGHITKIND_WP_M
        CHK     0x94                    ; ... and 0xFFFF one address
        SETWP   1, DATA + 1, 0xFFFF, WP_W | WP_R
        RUNAT   w1_s, 0
        MCHK    R_N, 0
        SNIP    w2_src, W2_LEN
        ld      a,0x77
        ld      (DATA),a
        CHK     0x95                    ; a memory read
        SETWP   1, DATA, 0xFFFF, WP_R
        RUNAT   w2_s, 0
        STOP1   DBGSTAT_WP1_M, w2_n
        WCHK    R_HA, DATA
        MCHK    R_HD, 0x77
        MCHK    R_HK, DBGHITKIND_WP_M
        CHK     0x96                    ; a write-only watchpoint ignores it
        SETWP   1, DATA, 0xFFFF, WP_W
        RUNAT   w2_s, 0
        MCHK    R_N, 0
        CHK     0x97                    ; ... a memory watchpoint ignores I/O
        SNIP    w3_src, W3_LEN
        SETWP   0, 0x1234, 0xFFFF, WP_W
        RUNAT   w3_s, 0
        MCHK    R_N, 0
        CHK     0x98                    ; an I/O write, the full 16-bit port
        SETWP   0, 0x1234, 0xFFFF, WP_IOW
        RUNAT   w3_s, 0
        STOP1   DBGSTAT_WP0_M, w3_n
        WCHK    R_HA, 0x1234
        MCHK    R_HD, 0x3C
        MCHK    R_HK, DBGHITKIND_WRITE_M | DBGHITKIND_IO_M
        CHK     0x99                    ; ... another high byte does not match
        SETWP   0, 0x1334, 0xFFFF, WP_IOW
        RUNAT   w3_s, 0
        MCHK    R_N, 0
        CHK     0x9A                    ; an I/O read
        SNIP    w4_src, W4_LEN
        SETWP   1, 0x5678, 0xFFFF, WP_IOR
        RUNAT   w4_s, 0
        STOP1   DBGSTAT_WP1_M, w4_n
        WCHK    R_HA, 0x5678
        MCHK    R_HD, 0xFF              ; no unit answers
        MCHK    R_HK, DBGHITKIND_IO_M | DBGHITKIND_WP_M
        CHK     0x9B                    ; the kept access is the first match
        SNIP    w5_src, W5_LEN
        SETWP   0, DATA, 0xFFFE, WP_W
        SETWP   1, DATA + 1, 0xFFFF, WP_W
        RUNAT   w5_s, 0
        STOP1   DBGSTAT_WP0_M | DBGSTAT_WP1_M, w5_n
        WCHK    R_HA, DATA
        MCHK    R_HD, 0x5A
        MCHK    R_HK, DBGHITKIND_WRITE_M
        CHK     0x9C                    ; LDIR: stops after the iteration
        SNIP    w6_src, W6_LEN
        ld      hl,0x2211
        ld      (SRC),hl
        ld      hl,0x4433
        ld      (SRC + 2),hl
        SETWP   0, DATA + 2, 0xFFFF, WP_W
        RUNAT   w6_s, 0
        STOP1   DBGSTAT_WP0_M, w6_ldir
        WCHK    R_BCE, 1
        MCHK    R_HD, 0x33
        CHK     0x9D                    ; EX (SP),HL: its stack read (SP = 0xBFFC there)
        SNIP    w7_src, W7_LEN
        SETWP   1, 0xBFFC, 0xFFFF, WP_R
        RUNAT   w7_s, 0
        STOP1   DBGSTAT_WP1_M, w7_n
        WCHK    R_HA, 0xBFFC
        MCHK    R_HD, 0x5A
        CHK     0x9E                    ; OUTI: the port after B is stepped down
        SNIP    w8_src, W8_LEN
        SETWP   1, 0x1234, 0xFFFF, WP_IOW
        RUNAT   w8_s, 0
        STOP1   DBGSTAT_WP1_M, w8_n
        WCHK    R_HA, 0x1234
        MCHK    R_HD, 0x11
        CHK     0x9F                    ; a step that hits a watchpoint: both bits, one NMI
        SNIP    w1_src, W1_LEN
        SETWP   0, DATA, 0xFFFF, WP_W
        ld      a,1
        ld      (R_KEEP),a
        RUNAT   w1_wr, STEP
        STOP1   DBGSTAT_WP0_M | DBGSTAT_STEP_M, w1_n
        CHK     0xA0                    ; DBGSTAT: write 1 to clear
        RCHK    DBGSTAT_P, DBGSTAT_WP0_M | DBGSTAT_STEP_M
        WREG    DBGSTAT_P, DBGSTAT_WP0_M
        RCHK    DBGSTAT_P, DBGSTAT_STEP_M
        WREG    DBGSTAT_P, 0x7F
        RCHK    DBGSTAT_P, 0
        xor     a
        ld      (R_KEEP),a

        CHK     0xFF
        ld      hl,pass
        call    puts
        jr      stop

fail:   ld      hl,failmsg
        call    puts
        ld      a,(R_CHK)
        call    puthex
        ld      a,13
        call    putc
        ld      a,10
        call    putc
stop:   di
        halt
        jr      stop

; ---------------------------------------------------------------- the step table
; Each: the instruction, the PC after it, a word pushed under it (RET), BC
steps:  ld      hl,steptab
        ld      a,(R_BASE)
        ld      (R_CHK),a
.l:     ld      e,(hl)
        inc     hl
        ld      d,(hl)
        inc     hl
        ld      a,d
        or      e
        ret     z
        ld      (R_TGT),de
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        inc     hl
        ld      (R_EXP),de
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        inc     hl
        ld      (R_PUSH),de
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        inc     hl
        ld      (R_IBC),de
        push    hl
        ld      a,STEP
        ld      (R_ICTL),a
        call    run
        MCHK    R_N, 1
        MCHK    R_STAT, DBGSTAT_STEP_M
        ld      hl,(R_PC)
        ld      de,(R_EXP)
        or      a
        sbc     hl,de
        jp      nz,fail
        ld      hl,R_CHK
        inc     (hl)
        pop     hl
        jr      .l

steptab:
        dw      s_nop,  s_nop_e,  0, 0          ; 1 byte
        dw      s_ldn,  s_ldn_e,  0, 0          ; 2 bytes
        dw      s_ldnn, s_ldnn_e, 0, 0          ; 3 bytes
        dw      s_ldix, s_ldix_e, 0, 0          ; 4 bytes, DD
        dw      s_cb,   s_cb_e,   0, 0          ; CB
        dw      s_ed,   s_ed_e,   0, 0          ; ED
        dw      s_fd,   s_fd_e,   0, 0          ; FD
        dw      s_ddcb, s_ddcb_e, 0, 0          ; DD CB d op, 23 T-states
        dw      s_halt, s_halt_e, 0, 0          ; HALT: stops after it
        dw      s_ei,   s_ei_e,   0, 0
        dw      s_di,   s_di_e,   0, 0
        dw      s_jp,   s_tgt,    0, 0
        dw      s_call, s_tgt,    0, 0
        dw      s_ret,  s_tgt,    s_tgt, 0
        dw      s_djnz, s_tgt,    0, 0x0200     ; DJNZ taken
        dw      s_ldir, s_ldir,   0, 2          ; LDIR: one iteration
        dw      s_ldir, s_ldir_e, 0, 1          ; ... the last one
        dw      0

; The instructions stepped (in ROM)
s_nop:  nop
s_nop_e:
s_ldn:  ld      a,0x12
s_ldn_e:
s_ldnn: ld      hl,0x1234
s_ldnn_e:
s_ldix: ld      (ix+5),0x99
s_ldix_e:
s_cb:   rlc     b
s_cb_e:
s_ed:   neg
s_ed_e:
s_fd:   ld      a,(iy+3)
s_fd_e:
s_ddcb: rlc     (ix+5)
s_ddcb_e:
s_halt: halt
s_halt_e:
s_ei:   ei
s_ei_e:
s_di:   di
s_di_e:
s_jp:   jp      s_tgt
s_call: call    s_tgt
s_ret:  ret
s_djnz: djnz    s_tgt
s_ldir: ldir
s_ldir_e:
        nop
s_tgt:  nop

; A breakpoint in ROM
r_s:    inc     a
r_1:    inc     a
r_2:    inc     a
        inc     a
        jp      back

; ---------------------------------------------------------------- snippets, copied to SNIPA
b_src:
        DISP    SNIPA
b_s:    inc     a
b_1:    inc     a
b_2:    inc     a
b_3:    inc     a
        jp      back
b_e:
        ENT
B_LEN   equ     b_e - b_s

c_src:
        DISP    SNIPA
c_s:    rlc     b
        neg
        ld      ix,DATA
c_dd:   rlc     (ix+5)
        jp      back
c_e:
        ENT
C_LEN   equ     c_e - c_s

w1_src:
        DISP    SNIPA
w1_s:   ld      a,0x5A
w1_wr:  ld      (DATA),a
w1_n:   nop
        jp      back
w1_e:
        ENT
W1_LEN  equ     w1_e - w1_s

w2_src:
        DISP    SNIPA
w2_s:   ld      a,(DATA)
w2_n:   nop
        jp      back
w2_e:
        ENT
W2_LEN  equ     w2_e - w2_s

w3_src:
        DISP    SNIPA
w3_s:   ld      bc,0x1234               ; a reserved page: no unit answers
        ld      a,0x3C
        out     (c),a
w3_n:   nop
        jp      back
w3_e:
        ENT
W3_LEN  equ     w3_e - w3_s

w4_src:
        DISP    SNIPA
w4_s:   ld      bc,0x5678
        in      a,(c)
w4_n:   nop
        jp      back
w4_e:
        ENT
W4_LEN  equ     w4_e - w4_s

w5_src:
        DISP    SNIPA
w5_s:   ld      hl,0xA55A
        ld      (DATA),hl
w5_n:   nop
        jp      back
w5_e:
        ENT
W5_LEN  equ     w5_e - w5_s

w6_src:
        DISP    SNIPA
w6_s:   ld      bc,4                    ; HL = SRC, DE = DATA from run
w6_ldir: ldir
        nop
        jp      back
w6_e:
        ENT
W6_LEN  equ     w6_e - w6_s

w7_src:
        DISP    SNIPA
w7_s:   ld      hl,0x125A
        push    hl                      ; at 0xBFFC (run's SP is 0xBFFE)
        ex      (sp),hl
w7_n:   nop
        jp      back
w7_e:
        ENT
W7_LEN  equ     w7_e - w7_s

w8_src:
        DISP    SNIPA
w8_s:   ld      bc,0x1334               ; OUTI steps B first: port 0x1234
        outi                            ; (HL) = (SRC) = 0x11
w8_n:   nop
        jp      back
w8_e:
        ENT
W8_LEN  equ     w8_e - w8_s

; ---------------------------------------------------------------- serial
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
        ASSERT  $ <= 0x4000
