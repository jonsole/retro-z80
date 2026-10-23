; Harness check for tb_zex.v: one test says OK and one ERROR, so the
; testbench must report TEST FAILED.

        org     0x0100
start:  ld      hl, (6)
        ld      sp, hl
        ld      de, msg
        ld      c, 9
        call    5
        jp      0

msg:    db      "first test....  OK", 10, 13
        db      "second test...  ERROR **** crc expected:12345678 found:87654321", 10, 13
        db      "Tests complete$"
