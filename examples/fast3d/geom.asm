; fast3d's flight through the geometry unit (spec 15): fast3d.asm includes
; this when GEOM is 1. The unit holds the camera and each object drawn, culls
; by an object's centre turned into camera space (CAM), and turns and
; projects the vertices (PROJ). fast3d's compute_matrix still makes the
; matrices from the angles, and the lines are drawn, clipped and cleared in
; software as before.
;
; The unit's numbers differ a little from fast3d's: its matrices are 1.0 =
; 16,383 (fast3d's 127, times 129), it works in world units, and it rounds
; once. So a point can land a pixel from where fast3d puts it.
;
; Vertices behind the near plane are dropped, with the edges to them (fast3d
; cuts them at the plane): the flight never comes near enough for that.

GEO					EQU		SREG + GEOW0		; the window, through the register page
GEO_V				EQU		SREG + GEOVX		; VX0 / RX0
GEO_CTL				EQU		SREG + GEOCTL
GEO_ST				EQU		SREG + GEOSTAT
MODEL_UNIT			EQU		26					; DW r, r sqrt 5 (world units), -> words

; geo_setup: the view, once: 256 pixels to the screen across and down, its
; centre at (128, 96), the near plane at NEAR units.
geo_setup:
					ld		a,GEO_BANK_VIEW
					ld		(GEO_CTL),a
					ld		hl,geo_view
					ld		de,GEO
					ld		bc,10
					ldir
					ld		a,GEOSTAT_SATS_M	; SATS clear
					ld		(GEO_ST),a
					ret

geo_view:			DW		256, 256, 128, 96, NEAR	; DX, DY, SCX, SCY, ZMIN

; geo_camera: the camera's matrix from camera_angles, as set_camera makes it
; (matrix is Rc, matrix_t Rc^T), and the camera bank: Mc = Rc^T and C. Uses
; everything but IY.
geo_camera:
					ld		hl,camera_angles
					ld		de,angle_x
					ld		bc,3
					ldir
					call	compute_matrix
					ld		a,GEO_BANK_CAM
					ld		(GEO_CTL),a
					ld		hl,matrix_t
					ld		de,GEO
					call	geo_put9
					ld		hl,(camera_x)		; C
					ld		(GEO + 18),hl
					ld		hl,(camera_y)
					ld		(GEO + 20),hl
					ld		hl,(camera_z)
					ld		(GEO + 22),hl
					ret

; geo_object: IX -> an object in view: its matrix Ro from its angles, and
; the object bank: Mo = Ro and P. The unit works out M and T. Keeps IX.
geo_object:
					ld		a,(ix + OBJECT_ANGLES)
					ld		(angle_x),a
					ld		a,(ix + OBJECT_ANGLES + 1)
					ld		(angle_y),a
					ld		a,(ix + OBJECT_ANGLES + 2)
					ld		(angle_z),a
					push	ix
					call	compute_matrix
					ld		a,GEO_BANK_OBJ
					ld		(GEO_CTL),a
					ld		hl,matrix
					ld		de,GEO
					call	geo_put9
					pop		ix
					ld		l,(ix + OBJECT_X)	; P
					ld		h,(ix + OBJECT_X + 1)
					ld		(GEO + 18),hl
					ld		l,(ix + OBJECT_X + 2)
					ld		h,(ix + OBJECT_X + 3)
					ld		(GEO + 20),hl
					ld		l,(ix + OBJECT_X + 4)
					ld		h,(ix + OBJECT_X + 5)
					ld		(GEO + 22),hl
					ret

; geo_put9: the 9 signed bytes at HL (127 for 1.0) to the 9 words at DE,
; 2.14 (129 times). Uses A, B, DE, HL.
geo_put9:
					ld		b,9
.entry:				ld		a,(hl)
					inc		hl
					push	hl
					ld		l,a
					ld		h,high times129
					ld		a,(hl)
					ld		(de),a
					inc		de
					inc		h
					ld		a,(hl)
					ld		(de),a
					inc		de
					pop		hl
					djnz	.entry
					ret

; geo_cull: IX -> an object; carry if it is out of view. Its centre into
; camera space by the unit, T = Mc (P - C), then fast3d's tests in world
; units: out if wholly nearer than NEAR or farther than FAR, or beyond one
; of the planes |x| = z / 2, |y| = z / 2 (2 |T| - Tz > r sqrt 5). Keeps IX.
geo_cull:
					ld		a,GEO_BANK_CAM | GEOCTL_CAM_M
					ld		(GEO_CTL),a
					ld		l,(ix + OBJECT_X)
					ld		h,(ix + OBJECT_X + 1)
					ld		(GEO_V),hl
					ld		l,(ix + OBJECT_X + 2)
					ld		h,(ix + OBJECT_X + 3)
					ld		(GEO_V + 2),hl
					ld		l,(ix + OBJECT_X + 4)
					ld		h,(ix + OBJECT_X + 5)
					ld		(GEO_V + 4),hl		; starts: T
					ld		l,(ix + OBJECT_MODEL)
					ld		h,(ix + OBJECT_MODEL + 1)
					ld		de,MODEL_UNIT
					add		hl,de
					ld		c,(hl)				; BC = r
					inc		hl
					ld		b,(hl)
					inc		hl
					ld		e,(hl)				; DE = r sqrt 5
					inc		hl
					ld		d,(hl)
					ld		hl,(GEO_V + 4)		; Tz
					push	hl
					ex		de,hl
					add		hl,de				; Tz + r sqrt 5, for the sides
					ld		(.side_room),hl
					pop		hl
					or		a					; Tz + r < NEAR: out
					adc		hl,bc
					jp		pe,.out				; (overflow: far beyond FAR)
					ld		de,NEAR
					or		a
					sbc		hl,de
					jp		pe,.out
					jp		m,.out
					ld		hl,(GEO_V + 4)		; Tz - r > FAR: out
					or		a
					sbc		hl,bc
					ld		de,FAR + 1
					or		a
					sbc		hl,de
					jp		p,.out
					ld		hl,(GEO_V)			; then x and y
					call	.side
					ret		c
					ld		hl,(GEO_V + 2)
; HL = Tx or Ty: carry if 2 |HL| > Tz + r sqrt 5 (which the tests above
; keep under 9,000).
.side:				bit		7,h
					jr		z,.positive
					xor		a
					sub		l
					ld		l,a
					sbc		a,a
					sub		h
					ld		h,a
.positive:			ld		a,h
					and		0xC0
					jr		nz,.out				; |HL| >= 16384 (or -32768)
					add		hl,hl
					ex		de,hl
					ld		hl,(.side_room)
					or		a
					sbc		hl,de
					ret
.out:				scf
					ret
.side_room:			DW		0

; geo_transform: as transform_object: IX -> an object in view (geo_object
; has loaded it), D = the points' page, E = the first vertex's place on it.
; Each vertex through the unit, projected, into the page's four tables:
; x low, x high, y low, y high; x = WIDE_BEHIND if it is behind the near
; plane. view_edges and view_edge_count: the model's edges. Uses
; everything; IX and IY too.
geo_transform:
					ld		a,GEO_BANK_OBJ | GEOCTL_PROJ_M
					ld		(GEO_CTL),a
					xor		a					; (nothing to cut: render_frame
					ld		(transform_behind),a	; leaves out an edge to a vertex
					ld		l,(ix + OBJECT_MODEL)	; behind the plane)
					ld		h,(ix + OBJECT_MODEL + 1)
					push	hl
					pop		iy					; IY -> the model
					ld		a,(iy + MODEL_EDGES)	; every edge drawn
					ld		(view_edge_count),a
					ld		a,(iy + MODEL_EDGES + 1)
					ld		(view_edges),a
					ld		a,(iy + MODEL_EDGES + 2)
					ld		(view_edges + 1),a
					ld		b,(iy + MODEL_VERTICES)
					ld		l,(iy + MODEL_UNIT + 4)	; HL -> the vertices as words
					ld		h,(iy + MODEL_UNIT + 5)
					ld		a,e					; IX -> the first point + 96: its
					add		a,96				; four tables at -96, -32, +32
					ld		ixl,a				; and +96
					ld		ixh,d
.vertex:			ld		e,(hl)
					inc		hl
					ld		d,(hl)
					inc		hl
					ld		(GEO_V),de
					ld		e,(hl)
					inc		hl
					ld		d,(hl)
					inc		hl
					ld		(GEO_V + 2),de
					ld		e,(hl)
					inc		hl
					ld		d,(hl)
					inc		hl
					ld		(GEO_V + 4),de		; VZ1 last: starts the vertex
					ld		a,(GEO_ST)
					and		GEOSTAT_NEAR_M
					jr		nz,.behind
					ld		de,(GEO_V)			; sx
					ld		(ix - 96),e
					ld		(ix - 32),d
					ld		de,(GEO_V + 2)		; sy
					ld		(ix + 32),e
					ld		(ix + 96),d
.next:				inc		ix
					djnz	.vertex
					ret
.behind:			ld		(ix - 32),high WIDE_BEHIND
					jr		.next

; geo_facing_edges: as facing_edges (FACES): IX -> an object, after
; geo_transform; HL = its points (H the page, L the first); DE -> room for
; the model's edges. Each face's sign from its first three points by the
; unit (a face looks towards the eye if the sign is 0 or more), then the
; edges with such a face either side, as pairs of vertices at DE. Out:
; view_edges, view_edge_count and A, DE past them. Uses everything; IX and
; IY too. (Every point is in front of the near plane in this flight; a
; face with a corner behind it would be judged from WIDE_BEHIND.)

; The face's corner J: its point's x and y to FJX, FJY. DE -> its index,
; B = the first point, H = the page. F2Y1, the last byte, starts the job.
					MACRO	CORNER J
					ld		a,(de)
					inc		de
					add		a,b
					ld		l,a					; x low
					ld		a,(hl)
					ld		(GEO + 4 * J),a
					set		6,l					; x high
					ld		a,(hl)
					ld		(GEO + 4 * J + 1),a
					set		7,l					; y low
					res		6,l
					ld		a,(hl)
					ld		(GEO + 4 * J + 2),a
					set		6,l					; y high
					ld		a,(hl)
					ld		(GEO + 4 * J + 3),a
					ENDM

geo_facing_edges:
					ld		(view_edges),de
					push	de
					ld		a,GEO_BANK_OPS
					ld		(GEO_CTL),a
					ld		a,l
					ld		(.first),a
					ld		e,(ix + OBJECT_MODEL)
					ld		d,(ix + OBJECT_MODEL + 1)
					push	de
					pop		iy					; IY -> the model
					ld		b,(iy + MODEL_FACES)
					ld		e,(iy + MODEL_FACES + 1)	; DE -> the faces: n, then n
					ld		d,(iy + MODEL_FACES + 2)	; vertices
					ld		ix,geo_front
.face:				push	bc
					ld		a,(.first)
					ld		b,a
					ld		a,(de)				; C = the vertices after the
					inc		de					; third
					sub		3
					ld		c,a
					CORNER	0
					CORNER	1
					CORNER	2
					ld		a,(GEO_ST)			; FRONT
					ld		(ix + 0),a
					inc		ix
					ld		a,c					; past the rest
					add		a,e
					ld		e,a
					adc		a,d
					sub		e
					ld		d,a
					pop		bc
					djnz	.face
					pop		ix					; IX -> the room
					ld		b,(iy + MODEL_EDGES)
					ld		l,(iy + MODEL_EDGES + 1)	; HL -> the edges
					ld		h,(iy + MODEL_EDGES + 2)
					ld		e,(iy + MODEL_EDGE_FACES)	; IY -> each edge's two faces
					ld		d,(iy + MODEL_EDGE_FACES + 1)
					push	de
					pop		iy
					ld		c,0					; C = the edges kept
.edge:				push	hl
					ld		h,high geo_front
					ld		l,(iy + 0)
					ld		a,(hl)
					ld		l,(iy + 1)
					or		(hl)
					inc		iy
					inc		iy
					pop		hl
					and		GEOSTAT_FRONT_M
					jr		z,.back
					ld		a,(hl)				; kept: its two vertices
					ld		(ix + 0),a
					inc		hl
					ld		a,(hl)
					ld		(ix + 1),a
					inc		hl
					inc		ix
					inc		ix
					inc		c
					djnz	.edge
					jr		.done
.back:				inc		hl
					inc		hl
					djnz	.edge
.done:				ld		a,c
					ld		(view_edge_count),a
					push	ix
					pop		de
					ret
.first:				DB		0

; 129 m for a matrix entry m: the low bytes, then the high.
					ALIGN	256
times129:
					INCLUDE	"output/times129_gen.s"
geo_front:			DS		64					; each face's GEOSTAT (page-aligned)
