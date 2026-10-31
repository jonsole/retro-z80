; The cube for Examples 9-2 to 9-4 (docs/guide/geometry.md): its corners,
; edges and faces, rotation matrices from the sine table, the eight
; vertices through the unit, and the edges drawn.

S       equ     90                      ; half the cube's side, in world units

; Corner i has x = +S or -S by its bit 0, y by bit 1, z by bit 2
cube_verts:
        dw      -S, -S, -S              ; 0
        dw       S, -S, -S              ; 1
        dw      -S,  S, -S              ; 2
        dw       S,  S, -S              ; 3
        dw      -S, -S,  S              ; 4
        dw       S, -S,  S              ; 5
        dw      -S,  S,  S              ; 6
        dw       S,  S,  S              ; 7

; An edge joins two corners that differ in one bit
cube_edges:
        db      0,1, 2,3, 4,5, 6,7      ; along x
        db      0,2, 1,3, 4,6, 5,7      ; along y
        db      0,4, 1,5, 2,6, 3,7      ; along z

; Each face: four corners, anticlockwise as seen from outside the cube
cube_faces:
        db      0, 2, 3, 1              ; z = -S, the face towards the eye at first
        db      4, 5, 7, 6              ; z = +S
        db      0, 4, 6, 2              ; x = -S
        db      1, 3, 7, 5              ; x = +S
        db      0, 1, 5, 4              ; y = -S
        db      2, 6, 7, 3              ; y = +S

identity:
        dw      0x4000, 0, 0            ; 1.0 on the diagonal
        dw      0, 0x4000, 0
        dw      0, 0, 0x4000
        dw      0, 0, 0                 ; at the origin

; sinof: HL = sin A in 2.14, from the table. Keeps DE, BC.
sinof:  push    de
        ld      e,a
        ld      d,0
        ld      hl,sine
        add     hl,de
        add     hl,de
        ld      a,(hl)
        inc     hl
        ld      h,(hl)
        ld      l,a
        pop     de
        ret

; rot_y: the matrix for a turn of A (0-255 round the circle) about y at DE:
;   cos  0  sin
;    0   1   0
;  -sin  0  cos
rot_y:  push    af
        add     a,64
        call    sinof                   ; cos
        ex      de,hl
        ld      (hl),e
        inc     hl
        ld      (hl),d                  ; [1,1] cos
        inc     hl
        xor     a
        ld      (hl),a
        inc     hl
        ld      (hl),a                  ; [1,2] 0
        inc     hl
        ex      de,hl
        pop     af
        push    af
        call    sinof                   ; sin
        ex      de,hl
        ld      (hl),e
        inc     hl
        ld      (hl),d                  ; [1,3] sin
        inc     hl
        xor     a
        ld      (hl),a
        inc     hl
        ld      (hl),a                  ; [2,1] 0
        inc     hl
        ld      (hl),a
        inc     hl
        ld      (hl),0x40               ; [2,2] 1.0
        inc     hl
        ld      (hl),a
        inc     hl
        ld      (hl),a                  ; [2,3] 0
        inc     hl
        ex      de,hl
        pop     af
        push    af
        add     a,128
        call    sinof                   ; -sin
        ex      de,hl
        ld      (hl),e
        inc     hl
        ld      (hl),d                  ; [3,1] -sin
        inc     hl
        xor     a
        ld      (hl),a
        inc     hl
        ld      (hl),a                  ; [3,2] 0
        inc     hl
        ex      de,hl
        pop     af
        add     a,64
        call    sinof                   ; cos
        ex      de,hl
        ld      (hl),e
        inc     hl
        ld      (hl),d                  ; [3,3] cos
        ret

; rot_x: the matrix for a turn of A about x at DE:
;    1   0    0
;    0  cos -sin
;    0  sin  cos
rot_x:  push    af
        ex      de,hl
        xor     a
        ld      (hl),a
        inc     hl
        ld      (hl),0x40               ; [1,1] 1.0
        inc     hl
        ld      b,4
.zero:  ld      (hl),a                  ; [1,2], [1,3] 0
        inc     hl
        djnz    .zero
        ld      (hl),a
        inc     hl
        ld      (hl),a                  ; [2,1] 0
        inc     hl
        ex      de,hl
        pop     af
        push    af
        add     a,64
        call    sinof                   ; cos
        ex      de,hl
        ld      (hl),e
        inc     hl
        ld      (hl),d                  ; [2,2] cos
        inc     hl
        ex      de,hl
        pop     af
        push    af
        add     a,128
        call    sinof                   ; -sin
        ex      de,hl
        ld      (hl),e
        inc     hl
        ld      (hl),d                  ; [2,3] -sin
        inc     hl
        xor     a
        ld      (hl),a
        inc     hl
        ld      (hl),a                  ; [3,1] 0
        inc     hl
        ex      de,hl
        pop     af
        push    af
        call    sinof                   ; sin
        ex      de,hl
        ld      (hl),e
        inc     hl
        ld      (hl),d                  ; [3,2] sin
        inc     hl
        ex      de,hl
        pop     af
        add     a,64
        call    sinof                   ; cos
        ex      de,hl
        ld      (hl),e
        inc     hl
        ld      (hl),d                  ; [3,3] cos
        ret

; project8: the cube's eight corners through the unit, projected, into
; points: sx, sy as words, 4 bytes a corner. The object bank is loaded
; and GEOCTL has PROJ set. A corner behind the near plane gets sx 0x8000.
project8:
        ld      hl,cube_verts
        ld      ix,points
        ld      bc,6 * 8                ; LDI counts BC down: 6 bytes a corner
.corner:
        ld      de,GEO_V
        ldi                             ; x, y, z, low byte first: VZ1 last,
        ldi                             ; which starts the vertex
        ldi
        ldi
        ldi
        ldi                             ; the sixth, VZ1: starts the vertex
        ld      a,(GEO_ST)              ; the result is ready by now
        and     GEOSTAT_NEAR_M
        jr      nz,.behind
        ld      de,(GEO_V)              ; RX: sx
        ld      (ix+0),e
        ld      (ix+1),d
        ld      de,(GEO_V + 2)          ; RY: sy
        ld      (ix+2),e
        ld      (ix+3),d
.next:  ld      de,4
        add     ix,de
        ld      a,b                     ; BC = 0 after the last corner
        or      c
        jr      nz,.corner
        ret
.behind:
        ld      (ix+1),0x80             ; not on the screen
        jr      .next

points: ds      8 * 4

; draw_edges: the B edges at HL, each two corner numbers, as lines between
; their points. An edge with an end behind the near plane is left out.
draw_edges:
        push    bc
        push    hl
        ld      a,(hl)
        inc     hl
        ld      c,(hl)
        call    point                   ; DE = the first corner's (x, y)
        jr      c,.skip
        push    de
        ld      a,c
        call    point
        pop     bc                      ; B = x0, C = y0
        jr      c,.skip
        call    line                    ; to (D, E)
.skip:  pop     hl
        inc     hl
        inc     hl
        pop     bc
        djnz    draw_edges
        ret

; point: corner A's screen point: D = x, E = y, or carry if it is off the
; screen (x or y outside 0-255 and 0-191, which takes in the 0x8000 of a
; corner behind the near plane). Keeps BC, HL.
point:  push    hl
        add     a,a
        add     a,a
        ld      l,a
        ld      h,0
        ld      de,points
        add     hl,de
        ld      e,(hl)                  ; sx low
        inc     hl
        ld      a,(hl)                  ; sx high
        inc     hl
        ld      d,e
        ld      e,(hl)                  ; sy low
        inc     hl
        or      (hl)                    ; sx high | sy high: 0 if both are 0-255
        pop     hl
        scf
        ret     nz
        ld      a,e
        cp      192                     ; carry if y is on the screen ...
        ccf                             ; ... so carry if it is not
        ret

        include "sine.inc"
