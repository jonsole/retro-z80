; The Z80 disassembler (spec 16, section 8.4), in ROM page 2, included by
; boot.asm; sim/dis/distest.asm includes it too, to check it against a
; table of every opcode (sim/dis/disref.py).
;
; dis: one instruction as text, in sjasmplus's syntax with the monitor's
; bare hex numbers: "LD   HL,8006", "BIT  3,(IX+05)", "RES  0,(IY-02),B".
; The mnemonic is padded to 5 columns. Every documented opcode, with the
; CB, ED, DD and FD prefixes and DD CB and FD CB; the undocumented ones in
; sjasmplus's names (IXH, IXL, IYH, IYL, SLL, IN F,(C), OUT (C),0, the
; DD CB forms that also load a register, the duplicate NEG, RETN and IM
; codes). A DD or FD that changes nothing (before another prefix, or an
; instruction without H, L or HL) is "DB   DD" on its own; an ED that is
; no instruction is "DB   ED,xx", 2 bytes, as the Z80 runs it.
;
;   In:  HL = the instruction's address (for relative jumps); C bit 0 set
;        when the byte follows RST 28h: then it is the function number,
;        "DB   09        ; CLS"
;   Out: A = the instruction's length (1-4), the text at DISBUF ending in
;        0. Every register changed but IX, IY and the alternates
;
; The includer gives DISBUF (40 bytes), DISVAR (12 bytes) and disget, which
; returns the instruction's next byte in A and keeps BC, DE and HL. dis
; asks for each byte once and in order, and only for bytes it needs (but
; after a DD or FD that changes nothing it has asked for one more).

DV_PFX  equ     DISVAR + 0              ; 'X' or 'Y' after DD or FD, else 0
DV_LEN  equ     DISVAR + 1              ; the bytes fetched
DV_USED equ     DISVAR + 2              ; 1: the prefix changed something
DV_PLN  equ     DISVAR + 3              ; 1: H and L stay H and L (beside (IX+d))
DV_DOK  equ     DISVAR + 4              ; 1: the displacement is in DV_D (DD CB)
DV_D    equ     DISVAR + 5              ; the displacement
DV_OP   equ     DISVAR + 6              ; the opcode
DV_PB   equ     DISVAR + 7              ; the prefix byte
DV_ADR  equ     DISVAR + 8              ; 2: the instruction's address

dis:    ld      (DV_ADR),hl
        ld      hl,DV_PFX
        ld      b,6
.clr:   ld      (hl),0
        inc     hl
        djnz    .clr
        ld      de,DISBUF
        bit     0,c
        jr      nz,.fn
        call    dfetch
        cp      0xCB
        jr      z,.cb
        cp      0xED
        jr      z,.ed
        ld      b,'X'
        cp      0xDD
        jr      z,.ix
        inc     b
        cp      0xFD
        jr      z,.ix
        call    dmain
.end:   xor     a
        ld      (de),a
        ld      a,(DV_LEN)
        ret
.cb:    call    dfetch
        call    dcb
        jr      .end
.ed:    call    ded
        jr      .end
.ix:    ld      (DV_PB),a
        ld      a,b
        ld      (DV_PFX),a
        call    dfetch
        cp      0xCB
        jr      z,.ixcb
        cp      0xDD
        jr      z,.db
        cp      0xED
        jr      z,.db
        cp      0xFD
        jr      z,.db
        call    dmain
        ld      a,(DV_USED)
        or      a
        jr      nz,.end
.db:    ld      de,DISBUF               ; the prefix alone: DB DD
        ld      hl,DV_LEN
        ld      (hl),1
        call    dtdb
        ld      a,(DV_PB)
        call    dhex2
        jr      .end
.ixcb:  call    dfetch                   ; DD CB d op
        ld      (DV_D),a
        ld      a,1
        ld      (DV_DOK),a
        call    dfetch
        call    dcb
        jr      .end
.fn:    call    dtdb                     ; after RST 28h: DB nn, and the function's name
        call    dfetch
        push    af
        call    dhex2
        pop     af
        cp      DFNUM
        jr      nc,.end
        push    af
        ld      b,15                    ; the comment in column 15
        call    dpad
        pop     af
        ld      hl,dfnames
        call    dnth
        ld      a,';'
        call    demit
        ld      a,' '
        call    demit
        call    demits
        jp      .end

; The next byte, counted
dfetch: call    disget
        push    hl
        ld      hl,DV_LEN
        inc     (hl)
        pop     hl
        ret

; A = x (bits 7-6 of the opcode), B = y (5-3), C = z (2-0)
dxyz:   ld      a,(DV_OP)
        and     7
        ld      c,a
        ld      a,(DV_OP)
        rrca
        rrca
        rrca
        and     7
        ld      b,a
        ld      a,(DV_OP)
        rlca
        rlca
        and     3
        ret

; ---- The opcode A without CB or ED (after DD or FD with DV_PFX set)
dmain:  ld      (DV_OP),a
        call    dxyz
        dec     a
        jr      nz,.n1
        ld      a,(DV_OP)               ; x = 1: LD r,r' and HALT
        ld      l,t_halt
        cp      0x76
        jr      z,.t
        ld      a,b                     ; with (HL) on one side, H and L stay
        cp      6
        jr      z,.pl
        ld      a,c
        cp      6
        jr      nz,.np
.pl:    ld      a,1
        ld      (DV_PLN),a
.np:    ld      l,t_ldrr
        jr      .t
.n1:    dec     a
        ld      l,t_alur                ; x = 2: the ALU with r
        jr      z,.t
        rrca                            ; x = 0 or 3: the table, 64 entries each
        rrca
        and     0x40
        ld      l,a
        ld      a,c
        add     a,a
        add     a,a
        add     a,a
        or      b
        or      l
.tab:   ld      l,a                     ; the template from itab + A
        ld      h,0
        push    de
        ld      de,ditab
        add     hl,de
        pop     de
        ld      l,(hl)
.t:     ld      a,l
        jp      dtpl

; ---- CB op (after DD CB d with DV_PFX set): rotates, shifts, BIT, RES, SET
dcb:    ld      (DV_OP),a
        call    dxyz
        or      a
        jr      nz,.bit
        ld      a,b                     ; x = 0: the rotate's mnemonic
        add     a,t_rot
        call    dtpl
        jr      .opd
.bit:   add     a,t_bit - 1             ; BIT, RES, SET y,
        call    dtpl
        call    dgety
        add     a,'0'
        call    demit
        call    dcomma
.opd:   ld      a,(DV_PFX)
        or      a
        jr      z,.rz
        call    dmem                   ; (IX+d)
        ld      a,(DV_OP)
        and     0xC0                    ; BIT, or z = 6: nothing more
        cp      0x40
        ret     z
        call    dgetz
        cp      6
        ret     z
        call    dcomma                   ; the undocumented ",r"
        ld      a,1
        ld      (DV_PLN),a
.rz:    call    dgetz
        jp      dregr

; ---- ED op
ded:    call    dfetch
        ld      (DV_OP),a
        call    dxyz
        dec     a
        jr      nz,.x2
        ld      a,c                     ; x = 1: the table's third part
        add     a,a
        add     a,a
        add     a,a
        or      b
        or      0x80
        ld      l,a
        ld      h,0
        push    de
        ld      de,ditab
        add     hl,de
        pop     de
        ld      a,(hl)
        or      a
        jr      z,.db
        jp      dtpl
.x2:    dec     a                       ; x = 2, z <= 3, y >= 4: the block instructions
        jr      nz,.db
        ld      a,c
        cp      4
        jr      nc,.db
        ld      a,b
        sub     4
        jr      c,.db
        add     a,a
        add     a,a
        add     a,c
        add     a,t_bli
        jp      dtpl
.db:    call    dtdb                     ; no instruction: DB ED,op
        ld      a,0xED
        call    dhex2
        call    dcomma
        ld      a,(DV_OP)
        jp      dhex2

; ---- Templates: a string with codes below 0x20 for the operands
dtdb:   ld      a,t_db
dtpl:   ld      hl,dtpls                 ; template A
        call    dnth
.c:     ld      a,(hl)
        inc     hl
        or      a
        ret     z
        cp      0x20
        jr      c,.code
        call    demit
        jr      .c
.code:  push    hl
        call    .disp
        pop     hl
        jr      .c
.disp:  add     a,a
        ld      l,a
        ld      h,0
        push    de
        ld      de,dcodes - 2
        add     hl,de
        pop     de
        ld      a,(hl)
        inc     hl
        ld      h,(hl)
        ld      l,a
        jp      (hl)

; HL = the A-th string (from 0) of the 0-ended strings at HL
dnth:   or      a
        ret     z
        push    bc
        ld      b,a
.s:     ld      a,(hl)
        inc     hl
        or      a
        jr      nz,.s
        djnz    .s
        pop     bc
        ret

dcodes: dw      dc_tab, dc_ry, dc_rz, dc_rp, dc_rp2, dc_cc, dc_cc4, dc_n, dc_nn, dc_e, dc_hl, dc_rst, dc_alu, dc_im
K_TAB   equ     1                       ; pad the mnemonic to 5 columns
K_RY    equ     2                       ; r[y]: B C D E H L (HL) A
K_RZ    equ     3                       ; r[z]
K_RP    equ     4                       ; rp[p]: BC DE HL SP
K_RP2   equ     5                       ; rp2[p]: BC DE HL AF
K_CC    equ     6                       ; cc[y]: NZ Z NC C PO PE P M
K_CC4   equ     7                       ; cc[y - 4] (JR)
K_N     equ     8                       ; a byte
K_NN    equ     9                       ; a word
K_E     equ     10                      ; a relative jump's target
K_HL    equ     11                      ; HL, IX or IY
K_RST   equ     12                      ; y x 8, as "28h"
K_ALU   equ     13                      ; the ALU mnemonic for y
K_IM    equ     14                      ; IM's number for y

dc_tab: ld      b,5
; Spaces up to column B
dpad:   ld      a,e
        sub     low DISBUF
        cp      b
        ret     nc
        ld      a,' '
        call    demit
        jr      dpad
dc_ry:  call    dgety
        jp      dregr
dc_rz:  call    dgetz
        jp      dregr
dc_rp2: call    dgetp
        cp      3
        jr      nz,dregp
        ld      hl,ds_af
        jp      demits
dc_rp:  call    dgetp
; rp[A], HL as IX or IY
dregp:  cp      2
        jp      z,dc_hl
        ld      hl,ds_rp
        jr      dtwo
dc_cc:  call    dgety
        jr      dcc
dc_cc4: call    dgety
        sub     4
dcc:    ld      hl,ds_cc
; The A-th pair of characters at HL, the second unless it is a space
dtwo:   add     a,a
        add     a,l
        ld      l,a
        jr      nc,.n
        inc     h
.n:     ld      a,(hl)
        call    demit
        inc     hl
        ld      a,(hl)
        cp      ' '
        ret     z
        jp      demit
dc_n:   call    dfetch
        jp      dhex2
dc_nn:  call    dfetch
        push    af
        call    dfetch
        ld      h,a
        pop     af
        ld      l,a
        jp      dhex4
dc_e:   call    dfetch                   ; the address after the instruction + e
        ld      l,a
        rla
        sbc     a,a
        ld      h,a
        ld      a,(DV_LEN)
        ld      c,a
        ld      b,0
        add     hl,bc
        ld      bc,(DV_ADR)
        add     hl,bc
        jp      dhex4
dc_rst: call    dgety
        add     a,a
        add     a,a
        add     a,a
        call    dhex2
        ld      a,'h'
        jp      demit
dc_alu: call    dgety
        add     a,t_alu
        jp      dtpl
dc_im:  call    dgety
        ld      hl,ds_im
        add     a,l
        ld      l,a
        jr      nc,.n
        inc     h
.n:     ld      a,(hl)
        jp      demit

; r[A]: H and L as IXH, IXL after DD (unless DV_PLN); (HL) as (IX+d)
dregr:  cp      6
        jr      z,dmem
        ld      c,a
        sub     4
        cp      2
        jr      nc,.pl                  ; not H or L
        ld      a,(DV_PLN)
        or      a
        jr      nz,.pl
        ld      a,(DV_PFX)
        or      a
        jr      z,.pl
        call    dc_hl                    ; IX, then H or L
        ld      a,c
.pl:    ld      hl,ds_r
        ld      a,c
        add     a,l
        ld      l,a
        jr      nc,.n
        inc     h
.n:     ld      a,(hl)
        jr      demit
; (HL), or (IX+d) / (IX-d)
dmem:   ld      a,'('
        call    demit
        ld      a,(DV_PFX)
        or      a
        jr      nz,.ix
        call    dc_hl
        jr      .cl
.ix:    call    dc_hl
        ld      a,(DV_DOK)
        or      a
        ld      a,(DV_D)
        call    z,dfetch
        ld      c,'+'
        or      a
        jp      p,.pos
        neg
        ld      c,'-'
.pos:   push    af
        ld      a,c
        call    demit
        pop     af
        call    dhex2
.cl:    ld      a,')'
        jr      demit
; HL, or IX, IY after a prefix
dc_hl:  ld      a,(DV_PFX)
        or      a
        jr      nz,.ix
        ld      hl,ds_hl
        jr      demits
.ix:    ld      a,1
        ld      (DV_USED),a
        ld      a,'I'
        call    demit
        ld      a,(DV_PFX)
        jr      demit

dgety:  ld      a,(DV_OP)
        rrca
        rrca
        rrca
        and     7
        ret
dgetp:  call    dgety
        rra
        and     3
        ret
dgetz:  ld      a,(DV_OP)
        and     7
        ret

; ---- Text out at DE
dcomma: ld      a,','
demit:  ld      (de),a
        inc     de
        ret
; The string at HL, to its 0
demits: ld      a,(hl)
        or      a
        ret     z
        call    demit
        inc     hl
        jr      demits
dhex4:  ld      a,h
        call    dhex2
        ld      a,l
dhex2:  push    af
        rrca
        rrca
        rrca
        rrca
        call    .d
        pop     af
.d:     and     0x0F
        add     a,0x90                  ; 0-9 to '0'-'9', 10-15 to 'A'-'F'
        daa
        adc     a,0x40
        daa
        jr      demit

ds_r:   db      "BCDEHL A"
ds_rp:  db      "BCDEHLSP"
ds_cc:  db      "NZZ NCC POPEP M "
ds_im:  db      "00120012"
ds_hl:  db      "HL", 0
ds_af:  db      "AF", 0

; ---- The templates, numbered from 0 in order (t_... equ the number)
dtnum = 0
    MACRO TPL name
name    equ     dtnum
dtnum = dtnum + 1
    ENDM

dtpls:
        TPL     t_none                  ; 0: no instruction (ED's table)
        db      0
        TPL     t_db
        db      "DB", K_TAB, 0
        TPL     t_nop
        db      "NOP", 0
        TPL     t_exaf
        db      "EX", K_TAB, "AF,AF'", 0
        TPL     t_djnz
        db      "DJNZ", K_TAB, K_E, 0
        TPL     t_jr
        db      "JR", K_TAB, K_E, 0
        TPL     t_jrcc
        db      "JR", K_TAB, K_CC4, ",", K_E, 0
        TPL     t_ldrpnn
        db      "LD", K_TAB, K_RP, ",", K_NN, 0
        TPL     t_addhl
        db      "ADD", K_TAB, K_HL, ",", K_RP, 0
        TPL     t_ldbca
        db      "LD", K_TAB, "(BC),A", 0
        TPL     t_ldabc
        db      "LD", K_TAB, "A,(BC)", 0
        TPL     t_lddea
        db      "LD", K_TAB, "(DE),A", 0
        TPL     t_ldade
        db      "LD", K_TAB, "A,(DE)", 0
        TPL     t_ldnnhl
        db      "LD", K_TAB, "(", K_NN, "),", K_HL, 0
        TPL     t_ldhlnn
        db      "LD", K_TAB, K_HL, ",(", K_NN, ")", 0
        TPL     t_ldnna
        db      "LD", K_TAB, "(", K_NN, "),A", 0
        TPL     t_ldann
        db      "LD", K_TAB, "A,(", K_NN, ")", 0
        TPL     t_incrp
        db      "INC", K_TAB, K_RP, 0
        TPL     t_decrp
        db      "DEC", K_TAB, K_RP, 0
        TPL     t_incr
        db      "INC", K_TAB, K_RY, 0
        TPL     t_decr
        db      "DEC", K_TAB, K_RY, 0
        TPL     t_ldrn
        db      "LD", K_TAB, K_RY, ",", K_N, 0
        TPL     t_rlca
        db      "RLCA", 0
        TPL     t_rrca
        db      "RRCA", 0
        TPL     t_rla
        db      "RLA", 0
        TPL     t_rra
        db      "RRA", 0
        TPL     t_daa
        db      "DAA", 0
        TPL     t_cpl
        db      "CPL", 0
        TPL     t_scf
        db      "SCF", 0
        TPL     t_ccf
        db      "CCF", 0
        TPL     t_halt
        db      "HALT", 0
        TPL     t_ldrr
        db      "LD", K_TAB, K_RY, ",", K_RZ, 0
        TPL     t_alur
        db      K_ALU, K_RZ, 0
        TPL     t_retcc
        db      "RET", K_TAB, K_CC, 0
        TPL     t_pop
        db      "POP", K_TAB, K_RP2, 0
        TPL     t_ret
        db      "RET", 0
        TPL     t_exx
        db      "EXX", 0
        TPL     t_jphl
        db      "JP", K_TAB, "(", K_HL, ")", 0
        TPL     t_ldsp
        db      "LD", K_TAB, "SP,", K_HL, 0
        TPL     t_jpcc
        db      "JP", K_TAB, K_CC, ",", K_NN, 0
        TPL     t_jp
        db      "JP", K_TAB, K_NN, 0
        TPL     t_outn
        db      "OUT", K_TAB, "(", K_N, "),A", 0
        TPL     t_inn
        db      "IN", K_TAB, "A,(", K_N, ")", 0
        TPL     t_exsp
        db      "EX", K_TAB, "(SP),", K_HL, 0
        TPL     t_exde
        db      "EX", K_TAB, "DE,HL", 0
        TPL     t_di
        db      "DI", 0
        TPL     t_ei
        db      "EI", 0
        TPL     t_callcc
        db      "CALL", K_TAB, K_CC, ",", K_NN, 0
        TPL     t_push
        db      "PUSH", K_TAB, K_RP2, 0
        TPL     t_call
        db      "CALL", K_TAB, K_NN, 0
        TPL     t_alun
        db      K_ALU, K_N, 0
        TPL     t_rst
        db      "RST", K_TAB, K_RST, 0
        TPL     t_inc
        db      "IN", K_TAB, K_RY, ",(C)", 0
        TPL     t_inf
        db      "IN", K_TAB, "F,(C)", 0
        TPL     t_outc
        db      "OUT", K_TAB, "(C),", K_RY, 0
        TPL     t_out0
        db      "OUT", K_TAB, "(C),0", 0
        TPL     t_sbc
        db      "SBC", K_TAB, "HL,", K_RP, 0
        TPL     t_adc
        db      "ADC", K_TAB, "HL,", K_RP, 0
        TPL     t_ldnnrp
        db      "LD", K_TAB, "(", K_NN, "),", K_RP, 0
        TPL     t_ldrpmm
        db      "LD", K_TAB, K_RP, ",(", K_NN, ")", 0
        TPL     t_neg
        db      "NEG", 0
        TPL     t_retn
        db      "RETN", 0
        TPL     t_reti
        db      "RETI", 0
        TPL     t_im
        db      "IM", K_TAB, K_IM, 0
        TPL     t_ldia
        db      "LD", K_TAB, "I,A", 0
        TPL     t_ldra
        db      "LD", K_TAB, "R,A", 0
        TPL     t_ldai
        db      "LD", K_TAB, "A,I", 0
        TPL     t_ldar
        db      "LD", K_TAB, "A,R", 0
        TPL     t_rrd
        db      "RRD", 0
        TPL     t_rld
        db      "RLD", 0
        TPL     t_alu                   ; 8: the ALU's mnemonics for y
        db      "ADD", K_TAB, "A,", 0
        TPL     t_adc8
        db      "ADC", K_TAB, "A,", 0
        TPL     t_sub
        db      "SUB", K_TAB, 0
        TPL     t_sbc8
        db      "SBC", K_TAB, "A,", 0
        TPL     t_and
        db      "AND", K_TAB, 0
        TPL     t_xor
        db      "XOR", K_TAB, 0
        TPL     t_or
        db      "OR", K_TAB, 0
        TPL     t_cp
        db      "CP", K_TAB, 0
        TPL     t_rot                   ; 8: the rotates and shifts for y
        db      "RLC", K_TAB, 0
        TPL     t_rrc
        db      "RRC", K_TAB, 0
        TPL     t_rl
        db      "RL", K_TAB, 0
        TPL     t_rr
        db      "RR", K_TAB, 0
        TPL     t_sla
        db      "SLA", K_TAB, 0
        TPL     t_sra
        db      "SRA", K_TAB, 0
        TPL     t_sll
        db      "SLL", K_TAB, 0
        TPL     t_srl
        db      "SRL", K_TAB, 0
        TPL     t_bit                   ; 3: x = 1-3 after CB
        db      "BIT", K_TAB, 0
        TPL     t_res
        db      "RES", K_TAB, 0
        TPL     t_set
        db      "SET", K_TAB, 0
        TPL     t_bli                   ; 16: the block instructions, (y - 4) x 4 + z
        db      "LDI", 0, "CPI", 0, "INI", 0, "OUTI", 0
        db      "LDD", 0, "CPD", 0, "IND", 0, "OUTD", 0
        db      "LDIR", 0, "CPIR", 0, "INIR", 0, "OTIR", 0
        db      "LDDR", 0, "CPDR", 0, "INDR", 0, "OTDR", 0
        ASSERT  dtnum < 256 - 15

; The templates for x = 0 and x = 3 (z x 8 + y; x = 3 from 64), and for ED
; with x = 1 (from 128). x = 3's CB, ED, DD and FD never get here
ditab:  db      t_nop, t_exaf, t_djnz, t_jr, t_jrcc, t_jrcc, t_jrcc, t_jrcc            ; x 0, z 0
        db      t_ldrpnn, t_addhl, t_ldrpnn, t_addhl, t_ldrpnn, t_addhl, t_ldrpnn, t_addhl
        db      t_ldbca, t_ldabc, t_lddea, t_ldade, t_ldnnhl, t_ldhlnn, t_ldnna, t_ldann
        db      t_incrp, t_decrp, t_incrp, t_decrp, t_incrp, t_decrp, t_incrp, t_decrp
        db      t_incr, t_incr, t_incr, t_incr, t_incr, t_incr, t_incr, t_incr
        db      t_decr, t_decr, t_decr, t_decr, t_decr, t_decr, t_decr, t_decr
        db      t_ldrn, t_ldrn, t_ldrn, t_ldrn, t_ldrn, t_ldrn, t_ldrn, t_ldrn
        db      t_rlca, t_rrca, t_rla, t_rra, t_daa, t_cpl, t_scf, t_ccf
        db      t_retcc, t_retcc, t_retcc, t_retcc, t_retcc, t_retcc, t_retcc, t_retcc  ; x 3, z 0
        db      t_pop, t_ret, t_pop, t_exx, t_pop, t_jphl, t_pop, t_ldsp
        db      t_jpcc, t_jpcc, t_jpcc, t_jpcc, t_jpcc, t_jpcc, t_jpcc, t_jpcc
        db      t_jp, t_none, t_outn, t_inn, t_exsp, t_exde, t_di, t_ei
        db      t_callcc, t_callcc, t_callcc, t_callcc, t_callcc, t_callcc, t_callcc, t_callcc
        db      t_push, t_call, t_push, t_none, t_push, t_none, t_push, t_none
        db      t_alun, t_alun, t_alun, t_alun, t_alun, t_alun, t_alun, t_alun
        db      t_rst, t_rst, t_rst, t_rst, t_rst, t_rst, t_rst, t_rst
        db      t_inc, t_inc, t_inc, t_inc, t_inc, t_inc, t_inf, t_inc                  ; ED, x 1, z 0
        db      t_outc, t_outc, t_outc, t_outc, t_outc, t_outc, t_out0, t_outc
        db      t_sbc, t_adc, t_sbc, t_adc, t_sbc, t_adc, t_sbc, t_adc
        db      t_ldnnrp, t_ldrpmm, t_ldnnrp, t_ldrpmm, t_ldnnrp, t_ldrpmm, t_ldnnrp, t_ldrpmm
        db      t_neg, t_neg, t_neg, t_neg, t_neg, t_neg, t_neg, t_neg
        db      t_retn, t_reti, t_retn, t_retn, t_retn, t_retn, t_retn, t_retn
        db      t_im, t_im, t_im, t_im, t_im, t_im, t_im, t_im
        db      t_ldia, t_ldra, t_ldai, t_ldar, t_rrd, t_rld, t_none, t_none

; The RST 28h functions' names (spec 16, section 7.3)
dfnames: db      "VERSION", 0, "PUTC", 0, "GETC", 0, "POLLC", 0, "PUTS", 0, "GETLINE", 0
        db      "PUTHEX", 0, "PUTHEX16", 0, "PUTDEC", 0, "CLS", 0, "SETPOS", 0, "GETPOS", 0
        db      "SETPAIR", 0, "PUTRAW", 0, "CONMODE", 0, "EXIT", 0, "BREAK", 0, "RESET", 0
        db      "LOADFILE", 0, "READBLOCK", 0, "WRITEBLOCK", 0
DFNUM   equ     0x15                    ; the names above
