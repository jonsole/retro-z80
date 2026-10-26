; Copper unit test lists (ticket #32; spec 6, section 11), run by
; sim/cop/tb_cop.v and checked by sim/cop/copcheck.py against its model of
; the copper. Every list is built with firmware/include/copper.inc, so the
; macros are tested too.
;
; The table at 0: one entry of 8 bytes per test:
;   +0  the list (3 bytes, a physical byte address)
;   +3  flags: F_BEAM start at the frame restart (else COPJMP1 at once),
;       F_PRI1 COPCON.PRI 1, F_RES RESUME, F_STK STKKEEP, F_IRQ IRQEN,
;       F_BUSY the testbench's CPU and layer channels take every cycle they
;       own on lines 100-399, F_CUT the testbench forces three frame restarts,
;       each in the clock after a SKIP or SKIPC runs
;   +4  COP2LC (3 bytes)
;   +7  frames: 0 runs until the copper stops; n runs n frame restarts on
; ended by an entry with flags 0xFF. copcheck.py names the tests in the same
; order (TESTS). cop_hi.bin is loaded at 0x2F0000.

        INCLUDE "hw.inc"
        INCLUDE "copper.inc"

F_BEAM  equ     0x01
F_PRI1  equ     0x02
F_RES   equ     0x04
F_STK   equ     0x08
F_IRQ   equ     0x10
F_BUSY  equ     0x20
F_CUT   equ     0x40

M       equ     0x0E0                   ; marker registers 0x0E0-0x0E7 (nothing there)
HI      equ     0x2F0000                ; cop_hi.bin

        MACRO   TEST list?, flags?, list2?, frames?
        db      low (list?), high (list?), (list?) >> 16, flags?
        db      low (list2?), high (list2?), (list2?) >> 16, frames?
        ENDM

        OUTPUT  "coptest.bin"
        ORG     0
table:  TEST    t_move,   F_PRI1, 0, 0
        TEST    t_wait,   F_BEAM | F_PRI1, 0, 0
        TEST    t_never1, F_BEAM | F_PRI1, 0, 1
        TEST    t_never2, F_BEAM | F_PRI1, 0, 1
        TEST    t_skip,   F_BEAM | F_PRI1, 0, 0
        TEST    t_jump,   F_PRI1, 0, 0
        TEST    t_call,   F_PRI1, 0, 0
        TEST    t_callov, F_PRI1, 0, 0
        TEST    t_retun,  F_PRI1, 0, 0
        TEST    t_movr,   F_PRI1, 0, 0
        TEST    t_alu,    0, 0, 0
        TEST    t_skipc,  0, 0, 0
        TEST    t_copint, F_IRQ, 0, 0
        TEST    t_jmp2,   0, t_jmp2b, 0
        TEST    t_res,    F_BEAM | F_RES, t_resb, 3
        TEST    t_res,    F_BEAM, t_resb, 3
        TEST    t_res,    F_BEAM | F_RES | F_CUT, t_cutb, 6
        TEST    t_stk,    F_BEAM | F_STK, 0, 2
        TEST    t_stk,    F_BEAM, 0, 2
        TEST    t_rate,   F_BEAM | F_PRI1 | F_BUSY, 0, 0
        TEST    t_rate,   F_BEAM | F_BUSY, 0, 0
        TEST    t_bad0,   0, 0, 0
        TEST    t_bad1,   0, 0, 0
        TEST    t_bad2,   0, 0, 0
        TEST    t_bad3,   0, 0, 0
        TEST    t_bad4,   0, 0, 0
        TEST    t_bad5,   0, 0, 0
        TEST    t_bad6,   0, 0, 0
        TEST    t_bad7,   0, 0, 0
        TEST    t_bad8,   0, 0, 0
        TEST    t_bad9,   0, 0, 0
        TEST    t_bad10,  0, 0, 0
        TEST    t_bad11,  0, 0, 0
        TEST    t_bad12,  0, 0, 0
        TEST    t_bad13,  0, 0, 0
        TEST    t_bad14,  0, 0, 0
        TEST    t_bad15,  0, 0, 0
        TEST    t_bad16,  0, 0, 0
        TEST    t_bad17,  0, 0, 0
        TEST    t_bad18,  0, 0, 0
        db      0, 0, 0, 0xFF, 0, 0, 0, 0

; ---------------------------------------------------------------- MOVE and MOVEF
t_move: CMOVE   0x000, 0x01
        CMOVE   0x0EF, 0xA5             ; the last MOVE offset
        CMOVEF  0x0F0, 0x11             ; MOVEF to the read-only codes ...
        CMOVEF  0x3FF, 0x22             ; ... the last offset
        CMOVEF  0x130, 0x33             ; the attribute layer
        CMOVEW  M, 0x1234
        CMOVEA  M, 0x563412
        CMOVEL  0x0EE, 0x44332211       ; two MOVEs, then two MOVEFs
        CMOVEF  COPX, 0x5A              ; its own register ...
        CMOVR   M + 1, CX               ; ... written before the next instruction
        CMOVEF  COPR0 + 3, 0x77
        CLD     CY, CR3
        CMOVR   M + 2, CY
        CSTOP

; ---------------------------------------------------------------- WAIT
t_wait: CWAIT   10, 0
        CMOVE   M, 1
        CMOVE   M, 2
        CMOVE   M, 3
        CWAIT   49, 143                 ; the last pixel of the blank
        CMOVE   M, 4
        CMOVE   M, 5
        CWAIT   49, 144                 ; the first of the picture (already there)
        CMOVE   M, 6
        CWAIT   100, 863                ; the last pixel of a line
        CMOVE   M, 7
        CMOVE   M, 8
        CWAIT   300, 500
        CMOVE   M, 9
        CWAITP  100                     ; passed on line 300: line 301
        CMOVE   M, 10
        CWAITP  600                     ; still to come on line 301
        CMOVE   M, 11
        CWAITP  0                       ; line 302
        CMOVE   M, 12
        CWAIT   200, 0                  ; passed: at once
        CMOVE   M, 13
        CWAITB  624, 860                ; and the DMA engine idle (always, here)
        CMOVE   M, 14
        CWAIT   1023, 0                 ; the end of the list
        CMOVE   M, 15

t_never1:
        CMOVE   M, 1
        CWAITP  870                     ; pixel 864 or more: never
        CMOVE   M, 2
        CSTOP

t_never2:
        CMOVE   M, 1
        CWAIT   625, 0                  ; line 625 or more: never
        CMOVE   M, 2
        CSTOP

; ---------------------------------------------------------------- SKIP
t_skip: CWAIT   200, 400
        CSKIP   100, 0                  ; passed: skips
        CMOVE   M, 1
        CMOVE   M, 2
        CSKIP   300, 0                  ; to come
        CMOVE   M, 3
        CSKIP   200, 300                ; passed: skips a two-word instruction
        CMOVEF  M, 4
        CMOVE   M, 5
        CSKIPP  100                     ; pixel passed
        CWAIT   1023, 0
        CMOVE   M, 6
        CSKIPP  800                     ; pixel to come
        CMOVE   M, 7
        CSKIP   200, 400                ; passed: skips a SKIP, ...
        CSKIP   0, 0
        CMOVE   M, 8                    ; ... which skips nothing
        CSKIP   625, 0                  ; never
        CMOVE   M, 9
        CSKIPP  870                     ; never
        CMOVE   M, 10
        CSTOP

; ---------------------------------------------------------------- JUMP, CALL, RET
t_jump: CMOVE   M, 1
        CJUMP   .a
        CMOVE   M, 0x99
.b:     CMOVE   M, 3
        CJUMP   HI                      ; above 64 KB: all 22 bits
.a:     CMOVE   M, 2
        CJUMP   .b
t_back: CMOVE   M, 5
        CSTOP

t_call: CCALL   .s1
        CMOVE   M, 9
        CSTOP
.s1:    CMOVE   M, 1
        CCALL   .s2
        CMOVE   M, 4
        CRET
.s2:    CMOVE   M, 2
        CCALL   .s3
        CRET
.s3:    CMOVE   M, 3
        CRET

t_callov:                               ; 8 deep, then the ninth CALL: ERR
        CLDI    CX, 0
.l:     CADDI   CX, 1
        CMOVR   M, CX
        CCALL   .l

t_retun:                                ; RET with the stack empty: ERR
        CMOVE   M, 1
        CRET
        CMOVE   M, 2

; ---------------------------------------------------------------- MOVR
t_movr: CLDI    CX, 0x40
        CLDI    CY, 0x99
        CMOVX   1
        CMOVXP  2
        CMOVXRP CX
        CMOVXRP CY
        CMOVXR  CX
        CMOVXR  CY
        CMOVR   0x30, CX
        CMOVR   0xF5, CY                ; a read-only code: written, ignored there
        CLDI    CX, 0xFF
        CMOVXP  7                       ; X wraps to 0
        CMOVXR  CX
        CSTOP

; ---------------------------------------------------------------- ALU
; After each step: X, Y and the flags to M, M + 1, M + 2
        MACRO   SHOW
        CMOVR   M, CX
        CMOVR   M + 1, CY
        CST     CR6, CX
        CST     CR7, CF
        CLD     CX, CR7
        CMOVR   M + 2, CX
        CLD     CX, CR6
        ENDM

t_alu:  CLDI    CX, 0xF0
        CLDI    CY, 0x7F
        SHOW
        CADDI   CX, 0x20                ; carry
        SHOW
        CADDI   CX, 0xF0                ; 0x00 with carry: Z, C
        SHOW
        CADDI   CY, 1                   ; 0x80: N
        SHOW
        CSUBI   CY, 0x81                ; borrow: 0xFF, N, C
        SHOW
        CSUB    CY, CY                  ; 0: Z
        SHOW
        CLDI    CX, 0x3C
        CST     CR2, CX
        CLDI    CY, 0xA5
        CST     CR5, CY
        CAND    CX, CR5                 ; 0x24, C cleared
        SHOW
        CORI    CY, 0x5A                ; 0xFF: N
        SHOW
        CANDI   CY, 0                   ; Z
        SHOW
        COR     CY, CR2                 ; 0x3C
        SHOW
        CCMPI   CY, 0x3C                ; equal: Z, Y kept
        SHOW
        CCMP    CY, CR5                 ; 0x3C - 0xA5: borrow
        SHOW
        CCMPI   CY, 0x10                ; greater
        SHOW
        CLD     CX, CY
        CLD     CY, CR5
        CADD    CX, CY                  ; 0x3C + 0xA5 = 0xE1: N
        SHOW
        CADD    CY, CX                  ; 0xA5 + 0xE1 = 0x86, carry
        SHOW
        CLDI    CF, 5                   ; flags from a value
        SHOW
        CLD     CF, CR2                 ; ... from a register: 0x3C & 7 = 4 (C)
        SHOW
        CST     CR3, CF
        CLD     CX, CR3
        CMOVR   M + 3, CX
        CLDI    CY, 0x01
        CSUB    CY, CR2                 ; 0x01 - 0x3C
        SHOW
        CLD     CY, CX                  ; LD from X
        SHOW
        CST     CR4, CY
        CLD     CX, CR4
        CSTOP

; ---------------------------------------------------------------- SKIPC
; Each condition with each flag value 0-7; a skipped MOVE leaves no trace
t_skipc:
v = 0
        DUP     8
        CLDI    CF, v
c = 0
        DUP     8
        dw      0xFA00 | c
        CMOVE   M, v * 8 + c
c = c + 1
        EDUP
v = v + 1
        EDUP
        CSKIPEQ                         ; the macros' codes (flags 7: Z set)
        CMOVE   M + 1, 0
        CSKIPNE
        CMOVE   M + 1, 1
        CSKIPLO
        CMOVE   M + 1, 2
        CSKIPHS
        CMOVE   M + 1, 3
        CSKIPMI
        CMOVE   M + 1, 4
        CSKIPPL
        CMOVE   M + 1, 5
        CSKIPHI
        CMOVE   M + 1, 6
        CSKIPLS
        CMOVE   M + 1, 7
        CSTOP

; ---------------------------------------------------------------- strobes
t_copint:
        CMOVE   M, 1
        CMOVEF  COPINT, 0
        CSTOP

t_jmp2: CMOVE   M, 1
        CMOVEF  COPJMP2, 0
        CMOVE   M, 0x99                 ; never run
        CSTOP
t_jmp2b:
        CMOVE   M, 3
        CSTOP

; RESUME: list 1 starts list 2 each frame; list 2 counts lines in X
t_res:  CMOVE   M, 0x11
        CMOVEF  COPJMP2, 0
        CSTOP
t_resb: CLDI    CX, 0
.l:     CADDI   CX, 1
        CMOVR   M + 1, CX
        CWAITP  0
        CJUMP   .l

; RESUME just after a skip: list 2 must carry on past the skipped
; instruction, never run it
t_cutb: CLDI    CX, 0
.l:     CADDI   CX, 1
        CMOVR   M + 1, CX
        CLDI    CF, 1                   ; Z
        CSKIPEQ                         ; skips ...
        CMOVEF  M + 2, 0x99             ; ... a two-word instruction
        CSKIP   0, 0                    ; passed: skips ...
        CMOVE   M + 3, 0x98             ; ... a one-word one
        CJUMP   .l

; STKKEEP: one CALL a frame
t_stk:  CCALL   .s
.s:     CMOVE   M, 1
        CSTOP

; Rates: 40 MOVEs after a WAIT, on lines where the CPU and the layers take
; every cycle they own
t_rate: CWAIT   200, 0
n = 1
        DUP     40
        CMOVE   M, n
n = n + 1
        EDUP
        CSTOP

; ---------------------------------------------------------------- reserved
        MACRO   BAD w1?, w2?
        CMOVE   M, 1
        dw      w1?, w2?
        CMOVE   M, 2
        CSTOP
        ENDM
t_bad0:  BAD    0xFFFF, 0xFFFF          ; erased memory
t_bad1:  BAD    0xFD00, 0
t_bad2:  BAD    0xFE00, 0
t_bad3:  BAD    0xF010, 0               ; WAIT, bit 4
t_bad4:  BAD    0xF140, 0               ; SKIP with B
t_bad5:  BAD    0xF240, 0               ; JUMP, bit 6
t_bad6:  BAD    0xF200, 0x0101          ; JUMP to an odd address
t_bad7:  BAD    0xF301, 0               ; STOP, bit 0
t_bad8:  BAD    0xF804, 0               ; MOVR, bit 2
t_bad9:  BAD    0xF90B, 0               ; ALU source 11
t_bad10: BAD    0xF928, 0               ; ST from X
t_bad11: BAD    0xF9F8, 0               ; ST of the flags into X
t_bad12: BAD    0xF90A, 0x0100          ; a value with bits 15-8 set
t_bad13: BAD    0xFA08, 0               ; SKIPC cc 8
t_bad14: BAD    0xFB81, 0               ; RET, bit 0
t_bad15: BAD    0xFB40, 0               ; CALL, bit 6
t_bad16: BAD    0xFB00, 0x0101          ; CALL to an odd address
t_bad17: BAD    0xFC04, 0               ; MOVEF, bit 2
t_bad18: BAD    0xFF00, 0

; ---------------------------------------------------------------- at 0x2F0000
        OUTPUT  "cop_hi.bin"
        ORG     0
        CMOVE   M, 4
        CJUMP   t_back
