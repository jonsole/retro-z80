; Example 9-3 (docs/guide/geometry.md): a ring of twelve cubes round the
; camera, which turns on the spot. Each frame the camera's matrix is a turn
; about y; each cube's centre goes through the unit with CAM set, and the
; cube is drawn only if its centre is in front of the near plane and inside
; the view, which is how an engine culls. The cubes in view are turned,
; projected and drawn as in Example 9-2. A key ends it; the console then
; says how many cubes the last frame drew.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

CUBES   equ     12
RADIUS  equ     1500                    ; the ring's radius, in world units
MARGIN  equ     160                     ; a cube reaches this far from its centre

start:  call    regs_on                 ; the register page into window 7
        call    scr_on                  ; the screen, blank

        ld      a,GEO_BANK_VIEW         ; the view: as Example 9-1
        ld      (GEO_CTL),a
        ld      hl,view
        ld      de,GEO
        ld      bc,10
        ldir
        call    place                   ; the cubes round the ring

frame:  call    cls
        xor     a
        ld      (drawn),a

; The camera: turned by `angle` about y. Mc is the turn's transpose, which
; for a turn about y is the turn the other way: rot_y of -angle.
        ld      a,(angle)
        neg
        ld      de,camera
        call    rot_y
        ld      a,GEO_BANK_CAM
        ld      (GEO_CTL),a
        ld      hl,camera
        ld      de,GEO
        ld      bc,24
        ldir                            ; Mc, and C = the origin

; Each cube: its centre into camera space, and the tests
        ld      ix,cubes
        ld      b,CUBES
.cube:  push    bc
        ld      a,GEO_BANK_CAM | GEOCTL_CAM_M   ; the camera alone, no projection
        ld      (GEO_CTL),a
        ld      l,(ix+0)                ; the centre P: x
        ld      h,(ix+1)
        ld      (GEO_V),hl
        ld      l,(ix+2)                ; y
        ld      h,(ix+3)
        ld      (GEO_V+2),hl
        ld      l,(ix+4)                ; z: VZ1 starts the job
        ld      h,(ix+5)
        ld      (GEO_V+4),hl
        ld      hl,(GEO_V+4)            ; Z, the depth: behind the near
        ld      de,16 + MARGIN          ; plane, or too close?
        or      a
        sbc     hl,de
        jp      m,.out
        ld      hl,(GEO_V+4)            ; the sides: |X| <= Z + MARGIN, since
        ld      de,MARGIN               ; DX is half the screen's width ...
        add     hl,de
        ex      de,hl                   ; DE = Z + MARGIN
        ld      hl,(GEO_V)              ; X
        call    inside
        jr      c,.out
        ld      hl,(GEO_V+2)            ; ... and |Y| <= Z + MARGIN too (the
        call    inside                  ; screen is lower than it is wide, so
        jr      c,.out                  ; this lets a few through; the lines
                                        ; off the screen are dropped)
; In view: turned about y by its own angle, at its centre, and drawn
        ld      a,(ix+6)
        ld      de,object
        call    rot_y
        ld      l,(ix+0)
        ld      h,(ix+1)
        ld      (object+18),hl          ; P
        ld      l,(ix+2)
        ld      h,(ix+3)
        ld      (object+20),hl
        ld      l,(ix+4)
        ld      h,(ix+5)
        ld      (object+22),hl
        ld      a,GEO_BANK_OBJ
        ld      (GEO_CTL),a
        ld      hl,object
        ld      de,GEO
        ld      bc,24
        ldir
        ld      a,GEO_BANK_OBJ | GEOCTL_PROJ_M
        ld      (GEO_CTL),a
        push    ix
        call    project8
        ld      hl,cube_edges
        ld      b,12
        call    draw_edges
        pop     ix
        ld      hl,drawn
        inc     (hl)
.out:   ld      a,(ix+6)                ; the cube turns on
        add     a,3
        ld      (ix+6),a
        ld      de,8
        add     ix,de
        pop     bc
        dec     b
        jp      nz,.cube
        call    flip

        ld      hl,angle                ; the camera turns
        inc     (hl)
        call    key
        jp      z,frame

        call    scr_off
        ld      hl,msg
        call    puts
        ld      a,(drawn)
        ld      l,a
        ld      h,0
        call    putu
        ld      hl,msg2
        call    puts
        jp      regs_off

; inside: carry if |HL| > DE
inside: bit     7,h
        jr      z,.pos
        xor     a                       ; -HL
        sub     l
        ld      l,a
        sbc     a,a
        sub     h
        ld      h,a
.pos:   ex      de,hl
        push    hl
        or      a
        sbc     hl,de                   ; DE - |HL|: carry if |HL| is more
        pop     hl
        ex      de,hl
        ret

; place: the cubes' centres, every 30 degrees round a ring of RADIUS about
; the origin, at a height that goes up and down round the ring
place:  ld      ix,cubes
        ld      c,0                     ; the angle round the ring
        ld      b,CUBES
.each:  push    bc
        ld      a,c
        call    sinof                   ; x = RADIUS sin
        call    times_radius
        ld      (ix+0),l
        ld      (ix+1),h
        ld      a,c
        add     a,a
        call    sinof                   ; y = 100 sin 2a, roughly
        sra     h                       ; (2.14 / 2^7 / 2^7 = 1.0 -> 128: close enough)
        rr      l
        sra     h
        rr      l
        sra     h
        rr      l
        sra     h
        rr      l
        sra     h
        rr      l
        sra     h
        rr      l
        sra     h
        rr      l
        ld      (ix+2),l
        ld      (ix+3),h
        ld      a,c
        add     a,64
        call    sinof                   ; z = RADIUS cos
        call    times_radius
        ld      (ix+4),l
        ld      (ix+5),h
        ld      a,c
        ld      (ix+6),a                ; its own turn starts at its place
        ld      de,8
        add     ix,de
        pop     bc
        ld      a,c                     ; on round the ring
        add     a,256 / CUBES
        ld      c,a
        djnz    .each
        ret

; times_radius: HL = HL (2.14, -1.0 to 1.0) x RADIUS, by the unit's multiply:
; RADIUS x HL gives RADIUS x 16384 x the fraction, so the product's high
; word, read from RY, is RADIUS x fraction / 4: shifted up 2
times_radius:
        ld      a,GEO_BANK_OPS
        ld      (GEO_CTL),a
        ld      (GEO + 12),hl           ; MA
        ld      hl,RADIUS
        ld      (GEO + 14),hl           ; MB: MB1 starts the multiply
        ld      hl,(GEO_V+2)            ; RY: the product's bits 31-16
        ld      de,(GEO_V)              ; RX: bits 15-0
        add     hl,hl                   ; x 4: carry from the low word's top two bits
        add     hl,hl
        ld      a,d
        rlca
        rlca
        and     3
        or      l
        ld      l,a
        ret

cubes:  ds      8 * CUBES               ; each: x, y, z, its angle, spare
camera: ds      24
object: ds      24
angle:  db      0
drawn:  db      0
view:   dw      256, 256, 128, 96, 16   ; DX, DY, SCX, SCY, ZMIN
msg:    db      "The last frame drew ", 0
msg2:   db      " of the 12 cubes", 13, 10, 0

        include "cube.inc"
        include "screen.inc"
