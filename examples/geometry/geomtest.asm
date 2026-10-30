; The geometry unit's board test (spec 15, ticket #67). Not a guide example.
;
; Runs the checks tools/geom_model.py writes (build/geomvec.bin) through
; the register page in window 7: writes, reads compared with the model's
; answer, and for every job the first result read straight after the write
; that starts it (LD (HL),C then LD A,(DE), the soonest a Z80 can read
; after a write). Then it times 1,024 projected vertices with the loop of
; spec 15, section 6.2, against TIME. Prints the cases run, the errors (the
; first eight in full) and the time, then returns to the monitor.
;
;   python3 tools/geom_model.py --board examples/geometry/build/geomvec.bin --count 120
;   sjasmplus --nologo -I firmware/include --raw=examples/geometry/build/geomtest.bin \
;       --sld=examples/geometry/build/geomtest.sld examples/geometry/geomtest.asm
;
; Needs a build with the unit (KS2: fpga/ks2/build.sh --geom). Without it
; the registers read 0xFF and nearly every check fails.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

PUTHEX  equ     0x06                    ; RST 28h functions
PUTDEC  equ     0x08
EXIT    equ     0x0040
PG_REGS equ     0x3F8                   ; the register page
SREG    equ     0xE000                  ; system register r at SREG + r (window 7)
GEO     equ     SREG + GEOW0
GEO_V   equ     SREG + GEOVX
GEO_CTL equ     SREG + GEOCTL
NVERT   equ     128                     ; the timing loop's vertices, 8 times over

start:  ld      sp,0xE000               ; the stack below window 7
        ld      hl,PG_REGS
        ld      bc,MMU7_0_P
        out     (c),l
        inc     b
        out     (c),h                   ; 0xE000-0xFFFF: the registers
        ld      hl,s_title
        rst     0x18

        ; ---- the checks
        ld      ix,table
next:   ld      b,(ix+0)                ; op << 5 | register & 0x1F
        ld      c,(ix+1)                ; the value
        inc     ix
        inc     ix
        ld      a,b
        and     0x1F
        or      0xA0
        ld      l,a
        ld      h,high SREG             ; HL: the register
        ld      a,b
        rlca
        rlca
        rlca
        and     7                       ; the op
        jr      z,done
        dec     a
        jr      z,.write
        dec     a
        jr      z,.read
        dec     a
        jr      z,.fast
        ld      hl,(cases)              ; 4: the next case
        inc     hl
        ld      (cases),hl
        jr      next
.write: ld      (hl),c
        jr      next
.read:  ld      a,(hl)
        cp      c
        jr      z,next
        call    bad
        jr      next
.fast:  ld      a,(ix+0)                ; the read that follows
        and     0x1F
        or      0xA0
        ld      e,a
        ld      d,high SREG             ; DE: the register to read
        ld      b,(ix+1)                ; its expected value
        inc     ix
        inc     ix
        ld      (hl),c                  ; starts the job ...
        ld      a,(de)                  ; ... and reads at once
        cp      b
        jr      z,next
        ex      de,hl
        ld      c,b
        call    bad
        jr      next

        ; ---- the timing loop: 1,024 vertices, projected
done:   ld      a,GEO_BANK_OBJ | GEOCTL_PROJ_M
        ld      (GEO_CTL),a
        ld      hl,(SREG+TIME0)         ; reading TIME0 captures all four bytes
        ld      de,(SREG+TIME2)
        ld      (t0),hl
        ld      (t0+2),de
        ld      a,8
.round: push    af
        ld      hl,verts
        ld      ix,points
        ld      bc,6 * NVERT
.vloop: ld      de,GEO_V
        ldi                             ; x, y, z, rising: VZ1 last
        ldi
        ldi
        ldi
        ldi
        ldi                             ; starts the vertex; P/V = 0 after the last
        ld      de,(GEO_V)              ; RX
        ld      (ix+0),e
        ld      (ix+1),d
        ld      de,(GEO_V+2)            ; RY
        ld      (ix+2),e
        ld      (ix+3),d
        ld      de,(GEO_V+4)            ; RZ
        ld      (ix+4),e
        ld      (ix+5),d
        ld      de,6
        add     ix,de                   ; leaves P/V alone
        jp      pe,.vloop
        pop     af
        dec     a
        jr      nz,.round
        ld      hl,(SREG+TIME0)
        ld      de,(t0)
        or      a
        sbc     hl,de                   ; microseconds (fits 16 bits)
        push    hl

        ; ---- the report
        ld      hl,s_cases
        rst     0x18
        ld      hl,(cases)
        rst     0x28
        db      PUTDEC
        ld      hl,s_errs
        rst     0x18
        ld      hl,(errors)
        rst     0x28
        db      PUTDEC
        ld      hl,s_time
        rst     0x18
        pop     hl
        rst     0x28
        db      PUTDEC
        ld      hl,s_us
        rst     0x18
        ld      hl,(errors)
        ld      a,h
        or      l
        ld      hl,s_pass
        jr      z,.end
        ld      hl,s_fail
.end:   rst     0x18
        ld      hl,7
        ld      (SREG+MMU7),hl          ; window 7 back to SRAM page 7
        jp      EXIT

; A check failed: HL = the register, A = what it read, C = what the model says
bad:    push    af
        push    hl
        ld      hl,(errors)
        inc     hl
        ld      (errors),hl
        ld      de,9
        or      a
        sbc     hl,de
        pop     hl
        jr      nc,.quiet               ; only the first eight in full
        push    hl
        ld      hl,s_case
        rst     0x18
        ld      hl,(cases)
        rst     0x28
        db      PUTDEC
        ld      hl,s_reg
        rst     0x18
        pop     hl
        ld      a,l
        rst     0x28
        db      PUTHEX
        ld      hl,s_got
        rst     0x18
        pop     af
        rst     0x28
        db      PUTHEX
        ld      hl,s_want
        rst     0x18
        ld      a,c
        rst     0x28
        db      PUTHEX
        ld      hl,s_crlf
        rst     0x18
        ret
.quiet: pop     af
        ret

cases:  dw      0
errors: dw      0
t0:     dw      0, 0

s_title: db     13, 10, "Geometry unit board test", 13, 10, 0
s_case:  db     "  case ", 0
s_reg:   db     ": register ", 0
s_got:   db     " read ", 0
s_want:  db     ", model ", 0
s_crlf:  db     13, 10, 0
s_cases: db     "Cases: ", 0
s_errs:  db     ", errors: ", 0
s_time:  db     13, 10, "1024 projected vertices: ", 0
s_us:    db     " us", 13, 10, 0
s_pass:  db     "PASS", 13, 10, 0
s_fail:  db     "FAIL", 13, 10, 0

table:  incbin  "build/geomvec.bin"     ; the checks, then the timing loop's vertices
points:                                 ; NVERT x 6 bytes of results, after the table
verts   equ     points - 6 * NVERT      ; the last 6 x NVERT bytes of the file
