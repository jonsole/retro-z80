; Speed test ROM (ticket #6): "hello" at every CPUSPEED setting (spec 7,
; section 6.1; spec 1, section 3). Runs in place of the boot ROM (tb.v
; +rom=speeds.hex +speeds) and prints "PASS" or "FAIL" with the number of
; the first check that failed.
;
; The program copies itself to SRAM and runs from there, so that its
; opcode fetches, stack and data are SRAM accesses at every speed. For each
; entry of the table it writes CPUSPEED, reads it back and prints "hello".
; The testbench measures the T-states (tb.v, "speed") and checks that each
; "hello" came at the speed of its entry and that every setting had one.
; The order gives every kind of change: locked to locked, locked to
; 3.57 MHz from both slot phases, and 3.57 MHz back to a locked speed.
;
; The first run (RESETWHY = POWER) ends at 3.57 MHz with a soft reset. The
; second run (RESETWHY = SOFTWARE) checks that the reset gave 20 MHz
; (CPUSPEED = 0x00), prints "hello" once more and then "PASS".

        DEVICE  NOSLOT64K
        include "hw.inc"

RUN     equ     0x4000                  ; SRAM page 0 (window 2)

        ORG     0x0000

reset:  di
        ld      sp,0x0000
        ld      bc,SERCON_P
        ld      a,SERCON_EN_M | SERCON_CTLEN_M
        out     (c),a
        ld      hl,image
        ld      de,RUN
        ld      bc,image_end - image
        ldir
        jp      RUN

image:
        DISP    RUN
run:    ld      bc,RESETWHY_P
        in      a,(c)
        cp      RESETWHY_SOFTWARE_M
        jr      z,second
        ld      d,1                     ; check 1: RESETWHY = POWER at power-on
        cp      RESETWHY_POWER_M
        jp      nz,fail
        ld      d,2                     ; check 2: CPUSPEED = 0x00 (20 MHz) at power-on
        ld      bc,CPUSPEED_P
        in      a,(c)
        or      a
        jp      nz,fail

        ld      hl,speeds               ; checks 3 up: one per table entry
.next:  ld      a,(hl)                  ; the value to write
        cp      0xFF
        jr      z,.done
        inc     hl
        inc     d
        ld      e,(hl)                  ; what it must read back
        inc     hl
        bit     0,(hl)                  ; PAD
        inc     hl
        jr      z,.go                   ; 12 T-states taken, 7 not: PAD moves the phase
.go:    ld      bc,CPUSPEED_P
        out     (c),a                   ; the new speed, from the next M-cycle
        in      a,(c)
        cp      e
        jp      nz,fail
        push    hl
        ld      hl,hello
        call    puts
        pop     hl
        jr      .next

.done:  inc     d                       ; check 18: SYSRESET did not reset
        ld      bc,SYSRESET_P
        ld      a,SYSRESET_MAGIC
        out     (c),a
        jp      fail

second: ld      d,20                    ; check 20: CPUSPEED = 0x00 (20 MHz) after the reset
        ld      bc,CPUSPEED_P
        in      a,(c)
        or      a
        jp      nz,fail
        ld      hl,hello
        call    puts
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
stop:   halt
        jr      stop

; Send A as two hex digits
puthex: push    af
        rrca
        rrca
        rrca
        rrca
        call    .nib
        pop     af
.nib:   and     0x0F
        add     a,'0'
        cp      '9'+1
        jr      c,.out
        add     a,'A'-'9'-1
.out:   jr      putc

puts:   ld      a,(hl)
        or      a
        ret     z
        call    putc
        inc     hl
        jr      puts

; Send A over USB (A, B, C changed; the byte is kept in E)
putc:   push    bc
        ld      e,a
.wait:  ld      a,SERSTAT0
        in      a,(SYSPAGE)
        or      a
        jr      z,.wait
        ld      a,e
        out     (SERDATA_PORT),a
        pop     bc
        ret

; CPUSPEED values to write, each with what it must read back and PAD; 0xFF
; ends. PAD = 1 runs 5 more T-states before the write, so that the two
; changes from 20 MHz to 3.57 MHz start on opposite slot phases and the
; T1s at 3.57 MHz fall on every slot edge (28 clocks steps 8 slot edges,
; so one run of them only reaches every other edge). The polling loop in
; putc takes an even number of T-states, so the phases do not depend on
; how long the serial link makes it wait.
speeds: db      0x00, 0x00, 0           ; 20 MHz
        db      0x01, 0x01, 0           ; 10 MHz
        db      0x02, 0x02, 0           ; 6.67 MHz
        db      0x03, 0x03, 0           ; 5 MHz
        db      0x04, 0x04, 0           ; 4 MHz
        db      0x05, 0x05, 0           ; 3.33 MHz
        db      0x06, 0x06, 0           ; 2.86 MHz
        db      0x07, 0x07, 0           ; 2.5 MHz
        db      0x08, 0x08, 1           ; 3.57 MHz, from 2.5 MHz
        db      0x00, 0x00, 0           ; 20 MHz, from 3.57 MHz
        db      0xF9, 0x09, 0           ; 3.57 MHz (DIV ignored; bits 7-4 read 0), from 20 MHz
        db      0x03, 0x03, 0           ; 5 MHz, from 3.57 MHz
        db      0x0C, 0x0C, 0           ; 3.57 MHz, from 5 MHz
        db      0x00, 0x00, 0           ; 20 MHz, from 3.57 MHz
        db      0x08, 0x08, 1           ; 3.57 MHz, from 20 MHz, the other phase
        db      0xFF

hello:  db      "hello", 13, 10, 0
pass:   db      "PASS", 13, 10, 0
failmsg: db     "FAIL ", 0
        ENT
image_end:
