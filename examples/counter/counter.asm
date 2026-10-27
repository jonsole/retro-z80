; A first program to debug from VS Code on the board: it counts in A and
; stores the count at 0x9000. Set a breakpoint on the INC A line, press F5.
        org     0x8000
start:  xor     a
loop:   inc     a
        ld      (count),a
        jr      loop
count   equ     0x9000
