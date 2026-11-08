; The fast-memory measurement (examples/fastmem/fmspeed.asm, issue #91) in
; the system testbench, in place of the boot ROM (tb.v +rom=fmsim.hex
; +print). This ROM sets up the program map, copies the program, built with
; -DSIM (2 KB in place of 512 KB, no waits for the frame, a short LDIR), to
; 0x8000 and calls it; the ROM calls it uses (RST 08h PUTC, RST 18h PUTS,
; RST 28h function 0x08 PUTDEC) print on the serial link. Then "PASS" if
; the program found no wrong words, else "FAIL".

        DEVICE  NOSLOT64K
        include "hw.inc"

        ORG     0x0000
        di
        jp      start
        ds      0x08 - $, 0xFF
        jp      putc                    ; RST 08h
        ds      0x18 - $, 0xFF
        jp      puts                    ; RST 18h
        ds      0x28 - $, 0xFF
        jp      romfn                   ; RST 28h
        ds      0x66 - $, 0xFF
        retn

start:  ld      sp,0x7F00               ; window 3 once mapped
        ld      bc,SERCON_P
        ld      a,SERCON_EN_M | SERCON_CTLEN_M
        out     (c),a
        ld      de,1                    ; windows 1-7 to SRAM pages 1-7: the program map
        ld      bc,MMU1_0_P
.map:   out     (c),e
        inc     b
        out     (c),d
        inc     b                       ; the next window's MMUn
        inc     e
        ld      a,e
        cp      8
        jr      nz,.map
        ld      hl,prog                 ; the program to 0x8000
        ld      de,0x8000
        ld      bc,PROGLEN
        ldir
        call    0x8000
        ld      hl,(0x8002)               ; the program's error count (fmspeed.asm, errs)
        ld      a,h
        or      l
        ld      hl,s_pass
        jr      z,.end
        ld      hl,s_fail
.end:   call    puts
stop:   di
        halt
        jr      stop

; romfn: RST 28h, the function number in the byte after the RST; only
; PUTDEC (0x08) is here
romfn:  ex      (sp),hl
        ld      a,(hl)                  ; the number
        inc     hl
        ex      (sp),hl
        cp      0x08
        ret     nz
        ; fall into putdec

; putdec: HL as an unsigned decimal number; registers kept but AF
putdec: push    hl
        push    de
        push    bc
        ld      b,0                     ; digits printed
        ld      de,10000
        call    .dig
        ld      de,1000
        call    .dig
        ld      de,100
        call    .dig
        ld      de,10
        call    .dig
        ld      a,l
        add     a,'0'
        call    putc
        pop     bc
        pop     de
        pop     hl
        ret
.dig:   ld      a,'0' - 1
.sub:   inc     a
        or      a
        sbc     hl,de
        jr      nc,.sub
        add     hl,de
        cp      '0'
        jr      nz,.put
        inc     b
        dec     b
        ret     z                       ; no leading zeros
.put:   ld      b,1
        jr      putc

puts:   ld      a,(hl)
        inc     hl
        or      a
        ret     z
        call    putc
        jr      puts

putc:   push    bc
        push    af
        ld      c,a
.wait:  ld      a,SERSTAT0
        in      a,(SYSPAGE)
        or      a
        jr      z,.wait
        ld      a,c
        out     (SERDATA_PORT),a
        pop     af
        pop     bc
        ret

s_pass: db      "PASS", 13, 10, 0
s_fail: db      "FAIL", 13, 10, 0

prog:   incbin  "fmspeed_sim.bin"
PROGLEN equ     $ - prog
