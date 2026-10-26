; The program link/session.py debugs (ticket #29), loaded at 8000 by an
; upload. Only instructions the bridge's stub model runs as the board does
; (tools/rz80bridge/z80.py): its data at C100, away from the console's
; window, so a watchpoint sees the program's accesses alone.
;   sjasmplus --raw=linkprog.bin --sym=linkprog.sym linkprog.asm

        DEVICE  NOSLOT64K
        ORG     0x8000
start:  ld      a,0x41
        ld      hl,0x1234
        ld      de,0
        call    sub1
bkpt:   ld      (0xC100),a              ; a breakpoint here, then a step
        inc     a
        ld      b,3
put:    rst     0x08                    ; PUTC (a breakpoint in ROM at 0008)
        djnz    put
        ld      a,(0xC100)              ; a read watchpoint stops after this
after:  ld      (0xC101),a
spin:   inc     de                      ; runs until paused
        jr      spin
sub1:   inc     a
        ret
