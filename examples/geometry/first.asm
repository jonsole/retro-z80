; Example 9-1 (docs/guide/geometry.md): a vertex through the geometry unit.
; Sets the view, a camera at the origin looking along z, and an object 512
; units ahead; sends three of the object's vertices and prints where each
; lands on the screen. Then turns the camera 30 degrees, reads the combined
; matrix's translation back from the product bank, and sends two of the
; vertices again.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

start:  call    regs_on                 ; the register page into window 7
        ld      hl,title
        call    puts

; Step 2: the view
        ld      a,GEO_BANK_VIEW
        ld      (GEO_CTL),a
        ld      hl,view
        ld      de,GEO
        ld      bc,10
        ldir                            ; DX, DY, SCX, SCY, ZMIN

; Step 3: the camera: no turn, at the origin
        ld      a,GEO_BANK_CAM
        ld      (GEO_CTL),a
        ld      hl,identity
        ld      de,GEO
        ld      bc,24
        ldir                            ; Mc, then C

; Step 4: the object: no turn, 512 units ahead
        ld      a,GEO_BANK_OBJ
        ld      (GEO_CTL),a
        ld      hl,object
        ld      de,GEO
        ld      bc,24
        ldir                            ; Mo, then P: the unit works out M and T

; Step 5: the vertices, projected
        ld      a,GEO_BANK_OBJ | GEOCTL_PROJ_M
        ld      (GEO_CTL),a
        ld      hl,vertices
        ld      bc,3 * 6                ; three vertices of 6 bytes
        call    send

; The camera turned 30 degrees about y, and T read back
        ld      a,GEO_BANK_CAM
        ld      (GEO_CTL),a
        ld      hl,turned
        ld      de,GEO
        ld      bc,24
        ldir
        ld      hl,s_turned
        call    puts
        ld      a,GEO_BANK_PROD         ; the product bank: M, then T
        ld      (GEO_CTL),a
        ld      hl,(GEO + 18)           ; TX
        call    putsd
        ld      hl,s_comma
        call    puts
        ld      hl,(GEO + 20)           ; TY
        call    putsd
        ld      hl,s_comma
        call    puts
        ld      hl,(GEO + 22)           ; TZ
        call    putsd
        call    crlf
        ld      a,GEO_BANK_PROD | GEOCTL_PROJ_M
        ld      (GEO_CTL),a             ; (any bank will do: PROJ is what matters)
        ld      hl,vertices
        ld      bc,2 * 6
        call    send
        jp      regs_off

; send: the vertices at HL, BC bytes of them, each x, y, z as words: through
; the unit, and the result printed
send:   push    bc
        push    hl
        ld      a,'('
        rst     08h
        ld      e,(hl)                  ; x, printed
        inc     hl
        ld      d,(hl)
        inc     hl
        push    hl
        ex      de,hl
        call    putsd
        ld      hl,s_comma
        call    puts
        pop     hl
        ld      e,(hl)                  ; y
        inc     hl
        ld      d,(hl)
        inc     hl
        push    hl
        ex      de,hl
        call    putsd
        ld      hl,s_comma
        call    puts
        pop     hl
        ld      e,(hl)                  ; z
        inc     hl
        ld      d,(hl)
        ex      de,hl
        call    putsd
        ld      hl,s_arrow
        call    puts
        pop     hl
        pop     bc
        ld      de,GEO_V                ; the vertex into VX, VY, VZ, low
        ldi                             ; bytes first: VZ1 last, which starts it
        ldi
        ldi
        ldi
        ldi
        ldi                             ; (LDI counts BC down)
        push    bc
        push    hl
        ld      a,(GEO_ST)              ; done by now: NEAR?
        and     GEOSTAT_NEAR_M
        jr      z,.screen
        ld      hl,s_near
        call    puts
.screen:
        ld      hl,(GEO_V)              ; RX: sx, or X if NEAR
        call    putsd
        ld      hl,s_comma
        call    puts
        ld      hl,(GEO_V + 2)          ; RY
        call    putsd
        ld      hl,s_z
        call    puts
        ld      hl,(GEO_V + 4)          ; RZ: the depth
        call    putsd
        call    crlf
        pop     hl
        pop     bc
        ld      a,b                     ; BC = 0 after the last vertex
        or      c
        jr      nz,send
        ret

view:   dw      256, 256                ; DX, DY: 256 pixels to the screen
        dw      128, 96                 ; SCX, SCY: the screen's centre
        dw      16                      ; ZMIN: the near plane
identity:
        dw      0x4000, 0, 0            ; Mc: 1.0 on the diagonal
        dw      0, 0x4000, 0
        dw      0, 0, 0x4000
        dw      0, 0, 0                 ; C: the origin
object: dw      0x4000, 0, 0            ; Mo: no turn
        dw      0, 0x4000, 0
        dw      0, 0, 0x4000
        dw      0, 0, 512               ; P: 512 ahead
turned: dw      14189, 0, -8192         ; Mc for a camera turned 30 degrees about y:
        dw      0, 0x4000, 0            ; cos 30 = 0.866 = 14189, sin 30 = 0.5 = 8192,
        dw      8192, 0, 14189          ; transposed
        dw      0, 0, 0
vertices:
        dw      -100, 50, 0             ; up and to the left of the object's centre
        dw      100, -50, 0             ; down and to the right
        dw      0, 0, -600              ; behind the eye

title:  db      13, 10, "Vertices through the geometry unit", 13, 10, 0
s_turned: db    "The camera turned 30 degrees: T = ", 0
s_comma: db     ", ", 0
s_arrow: db     ") -> ", 0
s_near: db      "NEAR: ", 0
s_z:    db      "  z ", 0

        include "screen.inc"
