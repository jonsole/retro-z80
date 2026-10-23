; Harness check for tb_zex.v: a tiny CP/M program that prints in ZEXDOC's
; format. Two tests say OK (one through BDOS function 9, one through
; function 2), then "Tests complete" and a jump to 0.

        org     0x0100
start:  ld      hl, (6)
        ld      sp, hl
        ld      de, title
        call    print
        ld      de, test1
        call    print
        ld      hl, test2
.next:  ld      a, (hl)
        or      a
        jr      z, .done
        push    hl
        ld      e, a
        ld      c, 2
        call    5
        pop     hl
        inc     hl
        jr      .next
.done:  ld      de, endmsg
        call    print
        jp      0

print:  ld      c, 9
        jp      5

title:  db      "Hello from CP/M", 10, 13, '$'
test1:  db      "first test....  OK", 10, 13, '$'
test2:  db      "second test...  OK", 10, 13, 0
endmsg: db      "Tests complete$"
