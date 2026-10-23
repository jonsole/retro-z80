; R register check for tb_zex.v, in ZEXDOC's output format. BBC BASIC (Z80)
; waits in RUN for LD A,R to give a non-zero value, so R must count: its low
; 7 bits go up by one for every M1 (opcode or prefix fetch), and bit 7 keeps
; what LD R,A wrote. Expected values are a real Z80's (Zilog's Z80 user
; manual; "The Undocumented Z80 Documented", section 6.1).

        org     0x0100
start:  ld      hl, (6)
        ld      sp, hl
        ld      de, title
        call    print

        ; 1. LD A,R reads R after its own two M1s: 0x80 + 2
        ld      de, t1
        call    print
        ld      a, 0x80
        ld      r, a
        ld      a, r
        ld      b, 0x82
        call    check

        ; 2. The low 7 bits wrap and bit 7 is kept: 0x7F + 200 NOPs + 2
        ;    = 0x49 in the low 7 bits, with bit 7 set
        ld      de, t2
        call    print
        ld      a, 0xFF
        ld      r, a
        ds      200, 0          ; 200 NOPs
        ld      a, r
        ld      b, 0xC9
        call    check

        ; 3. Two reads three M1s apart differ by 3 (what RUN relies on)
        ld      de, t3
        call    print
        ld      a, r
        ld      b, a
        ld      a, r
        sub     b
        ld      b, 3
        call    check

        ; 4. A DD prefix is an M1: INC IX counts 2
        ld      de, t4
        call    print
        xor     a
        ld      r, a
        inc     ix
        ld      a, r
        ld      b, 4
        call    check

        ; 5. DD CB d op counts 2: the opcode after the offset is no M1
        ld      de, t5
        call    print
        ld      ix, start
        xor     a
        ld      r, a
        bit     0, (ix + 0)
        ld      a, r
        ld      b, 4
        call    check

        ld      de, endmsg
        call    print
        jp      0

; A = found, B = expected
check:  cp      b
        ld      de, okmsg
        jr      z, print
        push    af
        ld      de, ermsg
        call    print
        pop     af
        call    phex
        ld      de, crlf
print:  ld      c, 9
        jp      5

phex:   push    af
        rrca
        rrca
        rrca
        rrca
        call    .nib
        pop     af
.nib:   and     0x0F
        add     a, '0'
        cp      '9' + 1
        jr      c, .out
        add     a, 7
.out:   ld      e, a
        ld      c, 2
        jp      5

title:  db      "R register", 10, 13, '$'
t1:     db      "ld r,a; ld a,r.......$"
t2:     db      "bit 7 kept, wrap.....$"
t3:     db      "reads 3 M1s apart....$"
t4:     db      "DD prefix............$"
t5:     db      "DD CB d op...........$"
okmsg:  db      "  OK", 10, 13, '$'
ermsg:  db      "  ERROR **** found:$"
crlf:   db      10, 13, '$'
endmsg: db      "Tests complete$"
