; Example 9-4 (docs/guide/geometry.md): the turning cube with its back faces
; hidden. Each frame, after the eight corners are projected, the unit's face
; sign job tests each of the six faces by three of its corners; an edge is
; drawn only if one of its two faces looks towards the eye. The cube's
; matrix is made as in Example 9-2 (the file has that code). A key ends it,
; and the console says how long the six face signs took a frame.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

start:  call    regs_on                 ; the register page into window 7
        call    scr_on                  ; the screen, blank

        ld      a,GEO_BANK_VIEW         ; the view: as Example 9-1
        ld      (GEO_CTL),a
        ld      hl,view
        ld      de,GEO
        ld      bc,10
        ldir

frame:  ld      a,(angle_y)             ; Mo = Ry(a) . Rx(b), by the product
        ld      de,ry                   ; bank, as Example 9-2
        call    rot_y
        ld      a,(angle_x)
        ld      de,rx
        call    rot_x
        ld      a,GEO_BANK_CAM
        ld      (GEO_CTL),a
        ld      hl,ry
        ld      de,GEO
        ld      bc,24
        ldir
        ld      a,GEO_BANK_OBJ
        ld      (GEO_CTL),a
        ld      hl,rx
        ld      de,GEO
        ld      bc,24
        ldir
        ld      a,GEO_BANK_PROD
        ld      (GEO_CTL),a
        ld      hl,GEO
        ld      de,object
        ld      bc,18
        ldir
        ld      a,GEO_BANK_CAM
        ld      (GEO_CTL),a
        ld      hl,identity
        ld      de,GEO
        ld      bc,24
        ldir
        ld      a,GEO_BANK_OBJ
        ld      (GEO_CTL),a
        ld      hl,object
        ld      de,GEO
        ld      bc,24
        ldir
        ld      a,GEO_BANK_OBJ | GEOCTL_PROJ_M
        ld      (GEO_CTL),a
        call    project8                ; the corners' screen points

; Which faces look towards the eye: each face's first three corners into
; F0, F1 and F2 of the operands bank (F2Y1 last: it starts the job), and
; GEOSTAT.FRONT kept
        call    time
        ld      (t0),hl
        ld      a,GEO_BANK_OPS
        ld      (GEO_CTL),a
        ld      hl,cube_faces
        ld      ix,front
        ld      b,6
.face:  push    bc
        ld      de,GEO                  ; F0X
        call    corner                  ; the corner at (HL)'s screen point to (DE)
        call    corner                  ; F1
        call    corner                  ; F2: F2Y1 starts the face sign
        inc     hl                      ; (the fourth corner is not needed)
        ld      a,(GEO_ST)
        and     GEOSTAT_FRONT_M
        ld      (ix+0),a                ; 0, or FRONT
        inc     ix
        pop     bc
        djnz    .face
        call    time
        ld      de,(t0)
        or      a
        sbc     hl,de
        ld      (took),hl               ; microseconds, for the end

; Draw the edges that have a face towards the eye on either side
        call    cls
        ld      hl,cube_edges
        ld      de,edge_faces
        ld      b,12
.edge:  push    bc
        push    hl
        ld      a,(de)                  ; the edge's two faces
        ld      hl,front
        add     a,l
        ld      l,a
        ld      c,(hl)
        inc     de
        ld      a,(de)
        ld      hl,front
        add     a,l
        ld      l,a
        ld      a,(hl)
        inc     de
        or      c
        pop     hl
        jr      z,.hidden               ; neither face towards the eye
        push    de
        ld      b,1
        call    draw_edges              ; the one edge at HL
        pop     de
        jr      .next
.hidden:
        inc     hl
        inc     hl
.next:  pop     bc
        djnz    .edge
        call    flip

        ld      hl,angle_y
        inc     (hl)
        inc     (hl)
        ld      hl,angle_x
        inc     (hl)
        call    key
        jp      z,frame

        call    scr_off
        ld      hl,msg
        call    puts
        ld      hl,(took)
        call    putu
        ld      hl,us
        call    puts
        jp      regs_off

; corner: the screen point of the corner numbered at (HL) to (DE): x, then
; y, 4 bytes. HL and DE move on.
corner: ld      a,(hl)
        inc     hl
        push    hl
        add     a,a
        add     a,a
        ld      l,a
        ld      h,0
        ld      bc,points
        add     hl,bc
        ld      bc,4
        ldir
        pop     hl
        ret

; Each edge's two faces, in cube_faces' order (z-, z+, x-, x+, y-, y+)
edge_faces:
        db      0,4, 0,5, 1,4, 1,5      ; along x: edges 0-1, 2-3, 4-5, 6-7
        db      0,2, 0,3, 1,2, 1,3      ; along y: 0-2, 1-3, 4-6, 5-7
        db      2,4, 3,4, 2,5, 3,5      ; along z: 0-4, 1-5, 2-6, 3-7
front:  ds      6                       ; each face: FRONT, or 0

view:   dw      256, 256, 128, 96, 16   ; DX, DY, SCX, SCY, ZMIN
object: ds      18
        dw      0, 0, 600
ry:     ds      24
rx:     ds      24
angle_y: db     0
angle_x: db     0
t0:     dw      0
took:   dw      0
msg:    db      "The six face signs took ", 0
us:     db      " us a frame", 13, 10, 0

        include "cube.inc"
        include "screen.inc"
