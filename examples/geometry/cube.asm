; Example 9-2 (docs/guide/geometry.md): a turning cube. Each frame the cube's
; matrix is made from two turns, about y and about x, by the unit's own
; matrix multiplier (the product bank); then its eight corners go through
; the unit, projected, and the Z80 draws the twelve edges. A key ends it,
; and the console says how long the matrices and the vertices took a frame.

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

frame:  call    time
        ld      (t0),hl

; The object's matrix Mo = Ry(a) . Rx(b): the two turns into the camera
; and object banks, and their product read back from the product bank
        ld      a,(angle_y)
        ld      de,ry                   ; Ry(a)
        call    rot_y
        ld      a,(angle_x)
        ld      de,rx                   ; Rx(b)
        call    rot_x
        ld      a,GEO_BANK_CAM
        ld      (GEO_CTL),a
        ld      hl,ry
        ld      de,GEO
        ld      bc,24
        ldir                            ; the camera: Ry, at the origin
        ld      a,GEO_BANK_OBJ
        ld      (GEO_CTL),a
        ld      hl,rx
        ld      de,GEO
        ld      bc,24
        ldir                            ; the object: Rx, at the origin
        ld      a,GEO_BANK_PROD
        ld      (GEO_CTL),a
        ld      hl,GEO
        ld      de,object
        ld      bc,18
        ldir                            ; M = Ry . Rx: the cube's matrix

; Now the real camera and the real object
        ld      a,GEO_BANK_CAM
        ld      (GEO_CTL),a
        ld      hl,identity
        ld      de,GEO
        ld      bc,24
        ldir                            ; no turn, at the origin
        ld      a,GEO_BANK_OBJ
        ld      (GEO_CTL),a
        ld      hl,object
        ld      de,GEO
        ld      bc,24
        ldir                            ; the cube's matrix, 600 ahead

; The corners through the unit, projected
        ld      a,GEO_BANK_OBJ | GEOCTL_PROJ_M
        ld      (GEO_CTL),a
        call    project8
        call    time
        ld      de,(t0)
        or      a
        sbc     hl,de
        ld      (took),hl               ; microseconds, for the end

; Draw it
        call    cls
        ld      hl,cube_edges
        ld      b,12
        call    draw_edges
        call    flip

        ld      hl,angle_y              ; on round the circle
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

view:   dw      256, 256, 128, 96, 16   ; DX, DY, SCX, SCY, ZMIN
object: ds      18                      ; Mo, from the product bank, then
        dw      0, 0, 600               ; P: 600 units ahead
ry:     ds      24                      ; Ry(a), at the origin
rx:     ds      24                      ; Rx(b)
angle_y: db     0
angle_x: db     0
t0:     dw      0
took:   dw      0
msg:    db      "The matrices and 8 vertices took ", 0
us:     db      " us a frame", 13, 10, 0

        include "cube.inc"
        include "screen.inc"
