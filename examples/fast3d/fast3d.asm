; fast3d's flight on retro-z80: forty cubes and icosahedra, each turning,
; round a circle the camera flies (examples/fast3d/README.md). The engine
; (engine/, model.py) is fast3d's from zx-spectrum-emulator, examples/fast3d,
; commit 1534bc5; this file is its demo.s, moved to retro-z80's screen, and
; timed. With GEOM, the culling and the vertices go through the geometry
; unit (geom.asm).
;
; The flight is fixed: no keys steer it. 256 pictures, a whole circle, are
; timed; then the console comes back with the results, and the program
; returns to the monitor.
;
;   python build.py [--geom] [--faces] [--phases] [--20mhz]
;   launch build/fast3d*.bin at 0x8000
;
; The screen is 256 x 192 at 1 bit a pixel, 32 bytes a line, shown at 2 x 2
; in the middle of the picture by layer L0, borrowed from the console (the
; KS2 builds one layer), as the blitter examples do. Two of them, at
; physical SCREEN0 and SCREEN1: each picture is drawn on the one not shown,
; mapped into window 7, and shown from the next vertical blank.
;
; Memory (the boot ROM's program map: a CPU address is its own physical
; address, except where this program maps windows 1 and 7):
;   0x2000  window 1: the register page
;   0x4000  the points, the objects drawn, the lines cut
;   0x7F00  the IM 2 table; the stack below it
;   0x8000  this and fast3d
;   0xE000  window 7: the screen being drawn
					DEVICE	ZXSPECTRUM48		; (sjasmplus writes the SLD only inside a DEVICE)

					INCLUDE	"hw.inc"

REGS				EQU		0x2000				; the register page, in window 1
SREG				EQU		REGS + REGS_SYSTEM
CREG				EQU		REGS + REGS_CUSTOM
PG_REGS				EQU		0x3F8
SCREEN0				EQU		0x040000			; the two screens, physical: SRAM
SCREEN1				EQU		0x042000			; pages 0x020 and 0x021
STACK				EQU		0x7F00
IM2TAB				EQU		0x7F00				; I = 0x7F, VECBASE = 0x00
EXIT				EQU		0x0040				; the ROM's exit
PUTC				EQU		0x08				; RST 08h: A
PUTS				EQU		0x18				; RST 18h: HL

PICTURES			EQU		256					; timed: a whole circle
PALOFS				EQU		15					; the screen's colours: entries
PALENT				EQU		REGS + REGS_PALETTE0 + 3 * 16 * PALOFS	; 240, 241
VIEW_LEFT			EQU		8					; the window lines are clipped to
VIEW_TOP			EQU		8
VIEW_RIGHT			EQU		247
VIEW_BOTTOM			EQU		183
WIN_X				EQU		VID_X0 + (VID_W - 512) / 2	; the window, 512 x 384
WIN_Y				EQU		VID_Y0 + (VID_H - 384) / 2

					IFNDEF	GEOM
GEOM				EQU		0					; 1: culling and vertices through the
					ENDIF								; geometry unit (spec 15)
					IF GEOM
					DEFINE	CULL_SKIP 0				; (the unit's cull is cheap: no skipping)
					ELSE
					DEFINE	CULL_SKIP 1				; skip what cannot have come into
													; view (engine/objects.s), as demo.s
					ENDIF
					IFNDEF	FACES
FACES				EQU		0					; 1: each object loses its back edges
					ENDIF								; (demo.s's --faces)
					IFNDEF	PHASES
PHASES				EQU		0					; 1: time each part of the frame
					ENDIF
					IFNDEF	SPECTRUM
SPECTRUM			EQU		1					; 1: the CPU at 3.57 MHz (CPUSPEED.
					ENDIF						; SPECTRUM, as a Spectrum); 0: 20 MHz

; T-states from microseconds: a picture's x PIC_MUL / PIC_DIV; the sum of
; PICTURES pictures' x AVG_MUL / AVG_DIV for the average. Timer 0 ticks every
; TICK_CLOCKS system clocks: 2 T-states either way.
					IF SPECTRUM
PIC_MUL				EQU		25					; 3.57 MHz: 100 / 28 = 25 / 7
PIC_DIV				EQU		7
AVG_MUL				EQU		25
AVG_DIV				EQU		7 * PICTURES
TICK_CLOCKS			EQU		56					; 28 clocks a T-state
					ELSE
PIC_MUL				EQU		20					; 20 MHz
PIC_DIV				EQU		1
AVG_MUL				EQU		5
AVG_DIV				EQU		PICTURES / 4
TICK_CLOCKS			EQU		10					; 5 clocks a T-state
					ENDIF

; The parts of a frame that PHASES times, in 2-T-state ticks of timer 0, and
; the marks into each.
PH_OTHER			EQU		0					; the loops, the boxes, the flip
PH_CAMERA			EQU		1					; set_camera, and the camera's step
PH_CULL				EQU		2					; cull_object, cull_skip_bounds, skipping
PH_MATRIX			EQU		3					; object_matrix
PH_VERTEX			EQU		4					; transform_object
PH_CUT				EQU		5					; cut_edges
PH_CLEAR			EQU		6					; clear_box
PH_CLIP				EQU		7					; clip_line
PH_LINE				EQU		8					; draw_line
PH_FACES			EQU		9					; facing_edges or geo_facing_edges
PH_WAIT				EQU		10					; waiting for the flip: not counted
PH_COUNT			EQU		11

; MARK p: from here, the time is part p's. Keeps every register and flag.
					MACRO	MARK p
					IF PHASES
					push	hl
					ld		hl,ph_sums + 8 * p
					call	mark
					pop		hl
					ENDIF
					ENDM

					ORG		0x8000

start:
					di
					ld		(exit_sp),sp
					ld		sp,STACK
					ld		bc,MMU1_0_P			; the register page into window 1
					ld		a,low PG_REGS
					out		(c),a
					inc		b
					ld		a,high PG_REGS
					out		(c),a
					ld		hl,(SREG + MMU7)	; window 7's page, for the exit
					ld		(exit_mmu7),hl
					ld		a,(SREG + CPUSPEED)	; and the CPU's speed
					ld		(exit_speed),a
					IF SPECTRUM
					ld		a,CPUSPEED_SPECTRUM_M	; 3.57 MHz from here
					ld		(SREG + CPUSPEED),a
					ENDIF
					ld		hl,CREG + L0		; the console's L0 and the two
					ld		de,save_l0			; colours, for the exit
					ld		bc,L_SPAN
					ldir
					ld		hl,PALENT
					ld		de,save_colours
					ld		bc,6
					ldir

					ld		hl,0x020			; both screens blank
					call	map_screen
					call	clear_screen
					ld		hl,0x021
					call	map_screen
					call	clear_screen
					call	demo_setup			; the window and its frame on both
					IF GEOM
					call	geo_setup
					ENDIF

					ld		hl,colours			; the colours: black, white
					ld		de,PALENT
					ld		bc,6
					ldir
					ld		hl,layer0			; L0: the screen, 2 x 2
					ld		de,CREG + L0
					ld		bc,L_SPAN
					ldir

					ld		hl,IM2TAB			; IM 2: every source to spurious
					ld		b,24
.fill:				ld		(hl),low spurious
					inc		hl
					ld		(hl),high spurious
					inc		hl
					djnz	.fill
					ld		hl,vblank
					ld		(IM2TAB + 2 * INT_VBLANK),hl
					ld		a,high IM2TAB
					ld		i,a
					ld		a,low IM2TAB
					ld		(SREG + VECBASE),a
					im		2
					ld		a,VIDSTAT_VBLANK_M
					ld		(CREG + VIDSTAT),a	; no old VBLANK
					ld		(CREG + VIDINTEN),a	; the video unit's enable
					ld		a,INTENA_SETCLR_M | (1 << INTB_VBLANK)
					ld		(SREG + INTENA0 + INTR_VBLANK),a
					ld		a,INTCON_MASTER_M
					ld		(SREG + INTCON),a

					xor		a					; timer 0: 2 T-states a tick,
					ld		(SREG + TMR0_CTRL),a	; round and round (PHASES)
					ld		a,TMR_STAT_UNDER_M
					ld		(SREG + TMR0_STAT),a
					ld		hl,TICK_CLOCKS - 1	; 2 T-states
					ld		(SREG + TMR0_PRESCALE),hl
					ld		hl,0xFFFF
					ld		(SREG + TMR0_RELOAD),hl
					ld		(SREG + TMR0_COUNT),hl
					ld		a,TMR_CTRL_EN_M | TMR_CTRL_REPEAT_M
					ld		(SREG + TMR0_CTRL),a

					ld		a,1					; screen 0 shown, draw on 1
					ld		(shown),a
					ld		a,1
					ld		(drawing),a
					ld		hl,(frames)			; the frames from here
					ld		(frames_at),hl
					ei
					MARK	PH_OTHER			; (the first mark starts the clock)

; The picture's arithmetic first, while the last one waits to be shown, as
; demo.s does; then the wait, then drawing on the screen the flip freed.
; The time of compute_frame and render_frame together is a picture's.
frame:
					call	time_now
					ld		(t_start),hl
					ld		(t_start + 2),de
					call	compute_frame
					call	time_now
					call	since
					ld		(t_work),hl			; compute_frame, in microseconds
					ld		(t_work + 2),de
					MARK	PH_WAIT
					call	wait_flip
					MARK	PH_OTHER
					ld		a,(drawing)			; the screen not shown, into
					ld		l,a					; window 7
					ld		h,0
					ld		de,0x020
					add		hl,de
					call	map_screen
					call	time_now
					ld		(t_start),hl
					ld		(t_start + 2),de
					call	render_frame
					call	time_now
					call	since
					ld		bc,(t_work)			; the picture's microseconds
					add		hl,bc
					ex		de,hl
					ld		bc,(t_work + 2)
					adc		hl,bc
					ex		de,hl
					call	tally
					ld		a,(drawing)			; show it at the next vertical
					inc		a					; blank; draw on the other next
					ld		(flip_to),a
					xor		3
					dec		a
					ld		(drawing),a
					ld		a,(reported)
					or		a
					jr		z,frame
					jp		finish

; time_now: DE:HL = TIME, microseconds. (Reading TIME0 captures all four
; bytes.)
time_now:			ld		hl,(SREG + TIME0)
					ld		de,(SREG + TIME2)
					ret

; since: DE:HL = DE:HL - t_start. Uses BC.
since:				ld		bc,(t_start)
					or		a
					sbc		hl,bc
					push	hl
					ex		de,hl
					ld		bc,(t_start + 2)
					sbc		hl,bc
					ex		de,hl
					pop		hl
					ret

; tally: DE:HL = a picture's microseconds, into the sums; after PICTURES
; of them, the timing ends.
tally:
					ld		a,(reported)
					or		a
					ret		nz
					ld		(us_pic),hl
					ld		(us_pic + 2),de
					ld		bc,(us_sum)			; the sum
					add		hl,bc
					ld		(us_sum),hl
					ex		de,hl
					ld		bc,(us_sum + 2)
					adc		hl,bc
					ld		(us_sum + 2),hl
					ld		hl,(us_least)		; the least: least - this
					ld		bc,(us_pic)
					or		a
					sbc		hl,bc
					ld		hl,(us_least + 2)
					ld		bc,(us_pic + 2)
					sbc		hl,bc
					jr		c,.not_least
					ld		hl,(us_pic)
					ld		(us_least),hl
					ld		hl,(us_pic + 2)
					ld		(us_least + 2),hl
.not_least:			ld		hl,(us_most)		; the most: most - this
					ld		bc,(us_pic)
					or		a
					sbc		hl,bc
					ld		hl,(us_most + 2)
					ld		bc,(us_pic + 2)
					sbc		hl,bc
					jr		nc,.not_most
					ld		hl,(us_pic)
					ld		(us_most),hl
					ld		hl,(us_pic + 2)
					ld		(us_most + 2),hl
.not_most:			ld		a,(drawn)			; objects drawn
					ld		e,a
					ld		d,0
					ld		hl,(drawn_sum)
					add		hl,de
					ld		(drawn_sum),hl
					ld		hl,(pictures)
					inc		hl
					ld		(pictures),hl
					ld		de,PICTURES
					or		a
					sbc		hl,de
					ret		nz
					MARK	PH_WAIT			; (the timing ends)
					ld		a,1
					ld		(reported),a
					ret

; wait_flip: until the vertical blank has shown the last picture.
wait_flip:
					ld		a,(flip_to)
					or		a
					ret		z
					halt
					jr		wait_flip

; map_screen: SRAM page HL into window 7, to draw on.
map_screen:			ld		(SREG + MMU7),hl
					ret

; clear_screen: the screen in window 7 blank.
clear_screen:
					ld		hl,0xE000
					ld		de,0xE001
					ld		(hl),0
					ld		bc,6143
					ldir
					ret

; demo_setup: the window, and its frame on both screens.
demo_setup:
					ld		b,VIEW_LEFT
					ld		c,VIEW_TOP
					ld		d,VIEW_RIGHT
					ld		e,VIEW_BOTTOM
					call	set_window
					ld		hl,0x020
					call	map_screen
					call	draw_frame_lines
					ld		hl,0x021
					call	map_screen
					jp		draw_frame_lines

; draw_frame_lines: the window's frame, a pixel outside it, on the screen in
; window 7.
draw_frame_lines:
					ld		hl,frame_lines
					ld		b,4
.line:				push	bc
					ld		b,(hl)
					inc		hl
					ld		c,(hl)
					inc		hl
					ld		d,(hl)
					inc		hl
					ld		e,(hl)
					inc		hl
					push	hl
					call	draw_line
					pop		hl
					pop		bc
					djnz	.line
					ret

frame_lines:		DB		VIEW_LEFT - 1, VIEW_TOP - 1, VIEW_RIGHT + 1, VIEW_TOP - 1
					DB		VIEW_RIGHT + 1, VIEW_TOP - 1, VIEW_RIGHT + 1, VIEW_BOTTOM + 1
					DB		VIEW_RIGHT + 1, VIEW_BOTTOM + 1, VIEW_LEFT - 1, VIEW_BOTTOM + 1
					DB		VIEW_LEFT - 1, VIEW_BOTTOM + 1, VIEW_LEFT - 1, VIEW_TOP - 1

; HL -> the box (rows, top, left column, columns) of the screen being drawn.
; Uses A.
box_of_screen:
					ld		hl,boxes
					ld		a,(drawing)
					or		a
					ret		z
					ld		hl,boxes + 4
					ret

boxes:				DB		0, 0, 0, 0			; screen 0
					DB		0, 0, 0, 0			; screen 1


; ---------------------------------------------------------------------------
; compute_frame: fly the camera on and turn the objects, and work out what
; is in view, touching no screen: each object drawn gets its points in the
; pool and an entry in `visible`, and the box round them all is new_box.

; An entry in `visible`, for an object drawn.
VIS_PAGE			EQU		0					; its points' page
VIS_BASE			EQU		1					; and its first vertex there
VIS_INSIDE			EQU		2					; non-zero: wholly in the window
VIS_EDGES			EQU		3					; how many edges, and where
VIS_SIZE			EQU		6
CUT_LINES			EQU		64					; room for lines cut at the near
												; plane (an object's are left out
												; if its edges might overflow it)

compute_frame:
					MARK	PH_CAMERA
					ld		hl,camera_angles + 1	; turning gently, always
					inc		(hl)
					IF GEOM
					call	geo_camera
					ELSE
					call	set_camera
					ENDIF
					ld		hl,camera_x			; and on, a quarter of the
					ld		de,matrix + 2		; forward column
					call	.step
					ld		hl,camera_y
					ld		de,matrix + 5
					call	.step
					ld		hl,camera_z
					ld		de,matrix + 8
					call	.step
					IF CULL_SKIP
					MARK	PH_CULL
					call	cull_skip_bounds	; how far T can have moved since
					jr		nc,.steady			; the last picture; a jump voids
					ld		ix,world			; every margin
					ld		de,OBJECT_SIZE
					ld		b,WORLD_OBJECTS
.void:				ld		(ix + OBJECT_SKIP),0
					ld		(ix + OBJECT_SKIP + 1),0
					add		ix,de
					djnz	.void
.steady:
					ENDIF
					MARK	PH_OTHER

					ld		a,255				; the box round every object
					ld		(.least_x),a		; drawn
					ld		(.least_y),a
					xor		a
					ld		(.most_x),a
					ld		(.most_y),a
					ld		(drawn),a
					ld		(cuts),a			; and no lines cut yet
					ld		hl,cut_lines
					ld		(.cut_at),hl
					IF FACES
					ld		hl,edge_pool		; and no edges kept
					ld		(.edges_at),hl
					ENDIF
					ld		hl,visible
					ld		(.entry),hl
					ld		hl,point_pool		; the pool's first page, from 0
					ld		(.slot),hl

					ld		ix,world			; every object: IX walks them,
					ld		a,WORLD_OBJECTS		; and cull_object keeps IX
					ld		(.objects_left),a
.object_loop:		ld		a,(ix + OBJECT_ANGLES)	; turned by its spin
					add		a,(ix + OBJECT_SPIN)
					ld		(ix + OBJECT_ANGLES),a
					ld		a,(ix + OBJECT_ANGLES + 1)
					add		a,(ix + OBJECT_SPIN + 1)
					ld		(ix + OBJECT_ANGLES + 1),a
					ld		a,(ix + OBJECT_ANGLES + 2)
					add		a,(ix + OBJECT_SPIN + 2)
					ld		(ix + OBJECT_ANGLES + 2),a
					IF CULL_SKIP
					MARK	PH_CULL
					ld		e,(ix + OBJECT_SKIP)	; skipping? its margin
					ld		d,(ix + OBJECT_SKIP + 1)
					ld		a,d
					or		e
					jr		z,.test
					ld		hl,(skip_odometer)	; travelled its room?
					ld		c,(ix + OBJECT_LIMIT)
					ld		b,(ix + OBJECT_LIMIT + 1)
					or		a
					sbc		hl,bc
					jp		p,.test
					ld		l,(ix + OBJECT_DIST)	; less this picture's bound
					ld		h,high skip_bounds
					ld		a,e
					sub		(hl)
					ld		e,a
					inc		hl
					ld		a,d
					sbc		a,(hl)
					ld		d,a
					jr		c,.test				; none left: test it
					or		e
					jr		z,.test
					ld		(ix + OBJECT_SKIP),e
					ld		(ix + OBJECT_SKIP + 1),d
					jp		.next_object
.test:				call	cull_object
					jr		nc,.in_view
					ld		hl,(cull_skip)		; out: for how long it can be
					ld		(ix + OBJECT_SKIP),l	; left alone, and how far
					ld		(ix + OBJECT_SKIP + 1),h
					ld		a,(cull_dist)
					ld		(ix + OBJECT_DIST),a
					ld		hl,(cull_limit)
					ld		(ix + OBJECT_LIMIT),l
					ld		(ix + OBJECT_LIMIT + 1),h
					jp		.next_object
.in_view:			ld		(ix + OBJECT_SKIP),0	; (no stale margin)
					ld		(ix + OBJECT_SKIP + 1),0
					ELSE
					MARK	PH_CULL
					IF GEOM
					call	geo_cull
					ELSE
					call	cull_object
					ENDIF
					jp		c,.next_object		; out of view
					ENDIF
					MARK	PH_OTHER
					ld		(.object),ix		; (object_matrix and
					ld		hl,drawn			; transform_object do not)
					inc		(hl)
					MARK	PH_MATRIX
					IF GEOM
					call	geo_object
					ELSE
					call	object_matrix
					ENDIF
					MARK	PH_OTHER
					ld		ix,(.object)
					ld		l,(ix + OBJECT_MODEL)
					ld		h,(ix + OBJECT_MODEL + 1)
					ld		(.model),hl
					ld		b,(hl)				; MODEL_VERTICES
					ld		de,(.slot)			; room for them on this page?
					ld		a,e
					add		a,b
					cp		65
					jr		c,.room
					inc		d					; else on the next, from 0
					ld		e,0
					ld		a,b
.room:				ld		(.first),de
					ld		e,a
					ld		(.slot),de			; where the next object's go
					ld		de,(.first)
					MARK	PH_VERTEX
					IF GEOM
					call	geo_transform
					ELSE
					call	transform_object
					ENDIF
					MARK	PH_OTHER
					IF FACES
					ld		ix,(.object)		; only the edges a face either
					ld		hl,(.first)			; side of looks towards the eye
					ld		de,(.edges_at)
					MARK	PH_FACES
					IF GEOM
					call	geo_facing_edges
					ELSE
					call	facing_edges
					ENDIF
					MARK	PH_OTHER
					ld		(.edges_at),de
					ENDIF
					ld		hl,(.model)			; into the box
					ld		b,(hl)
					ld		hl,(.first)
					call	.object_box
					ld		a,(transform_behind)	; the edges cut at the near
					or		a					; plane, if any vertex is behind
					jr		z,.cuts_done		; it and there is room for as
					ld		ix,(.object)		; many lines as it has edges
					ld		hl,(.model)			; (there always is, in this
					inc		hl					; world)
					inc		hl
					inc		hl
					ld		a,(cuts)
					add		a,(hl)				; MODEL_EDGES
					jr		c,.cuts_done
					cp		CUT_LINES + 1
					jr		nc,.cuts_done
					ld		hl,(.first)
					ld		de,(.cut_at)
					push	de
					MARK	PH_CUT
					call	cut_edges
					MARK	PH_OTHER
					ld		(.cut_at),de
					pop		hl
					ld		b,a
					ld		a,(cuts)
					add		a,b
					ld		(cuts),a
					call	.cut_box			; their cut ends into the box
.cuts_done:			ld		de,(.entry)			; and the entry
					ld		a,(.first + 1)
					ld		(de),a				; VIS_PAGE
					inc		de
					ld		a,(.first)
					ld		(de),a				; VIS_BASE
					inc		de
					ld		a,(.all_inside)
					ld		(de),a				; VIS_INSIDE
					inc		de
					ld		a,(view_edge_count)	; VIS_EDGES: the count, and
					ld		(de),a				; where they are -- all the
					inc		de					; model's, or those facing_edges
					ld		hl,(view_edges)		; kept
					ex		de,hl
					ld		(hl),e
					inc		hl
					ld		(hl),d
					inc		hl
					ld		(.entry),hl
					ld		ix,(.object)
.next_object:
					MARK	PH_OTHER
					ld		de,OBJECT_SIZE
					add		ix,de
					ld		hl,.objects_left
					dec		(hl)
					jp		nz,.object_loop

					ld		a,(.most_y)			; the box, held to the window,
					cp		VIEW_BOTTOM + 1		; in rows and columns
					jr		c,.bottom
					ld		a,VIEW_BOTTOM
.bottom:			ld		b,a
					ld		a,(.least_y)
					cp		VIEW_TOP
					jr		nc,.top
					ld		a,VIEW_TOP
.top:				ld		c,a
					ld		a,b
					sub		c
					jr		c,.no_box			; nothing drawn in the window
					inc		a
					ld		b,a					; rows
					ld		a,(.most_x)
					cp		VIEW_RIGHT + 1
					jr		c,.right
					ld		a,VIEW_RIGHT
.right:				ld		e,a
					ld		a,(.least_x)
					cp		VIEW_LEFT
					jr		nc,.left
					ld		a,VIEW_LEFT
.left:				cp		e
					jr		z,.across
					jr		nc,.no_box
.across:			rrca
					rrca
					rrca
					and		31
					ld		d,a					; first column
					ld		a,e
					rrca
					rrca
					rrca
					and		31
					sub		d
					inc		a
					ld		e,a					; columns
					ld		hl,new_box
					ld		(hl),b
					inc		hl
					ld		(hl),c
					inc		hl
					ld		(hl),d
					inc		hl
					ld		(hl),e
					ret
.no_box:			xor		a
					ld		(new_box),a
					ret

; (HL) += the signed byte at DE >> 2: a step along the camera's forward
; column. Uses A, BC.
.step:				ld		a,(de)
					sra		a
					sra		a
					ld		c,a
					add		a,a
					sbc		a,a
					ld		b,a
					ld		a,(hl)
					add		a,c
					ld		(hl),a
					inc		hl
					ld		a,(hl)
					adc		a,b
					ld		(hl),a
					ret

; The box round the B points transform_object just made from HL (L the
; first vertex, H the page), those in front of the eye, into the picture's
; box: a box round an object's vertices holds
; every line between them, and so every piece of one clipped to the window.
; Each x and y is held to 0..255 first, which keeps their order, so the
; least and most of them are the least and most of the whole, held; the end
; holds those to the window, once a picture, rather than every line end
; being measured. And .all_inside non-zero if the whole object is in the
; window -- every vertex in front of the eye and the box inside -- so that
; none of its edges needs clipping. Uses A, BC, DE, HL, IX.
.object_box:		ld		c,255				; C, D = the least x, the most
					ld		d,0
					ld		e,c					; E, IXL = the least y, the most
					ld		ixl,d
					ld		ixh,d				; IXH non-zero: one is behind
.vertex:			set		6,l
					ld		a,(hl)				; POINTS_X_HI
					res		6,l
					cp		high WIDE_BEHIND
					jr		z,.behind
					or		a
					jr		nz,.x_far
					ld		a,(hl)				; POINTS_X_LO
.x_held:			cp		c
					jr		nc,.not_least_x
					ld		c,a
.not_least_x:		cp		d
					jr		c,.not_most_x
					ld		d,a
.not_most_x:		set		7,l
					set		6,l
					ld		a,(hl)				; POINTS_Y_HI
					res		6,l
					or		a
					jr		nz,.y_far
					ld		a,(hl)				; POINTS_Y_LO
.y_held:			cp		e
					jr		nc,.not_least_y
					ld		e,a
.not_least_y:		cp		ixl
					jr		c,.not_most_y
					ld		ixl,a
.not_most_y:		res		7,l
.next_vertex:		inc		l
					djnz	.vertex

					xor		a					; all of it in the window?
					ld		(.all_inside),a
					or		ixh
					jr		nz,.merge
					ld		a,c
					cp		VIEW_LEFT
					jr		c,.merge
					ld		a,VIEW_RIGHT
					cp		d
					jr		c,.merge
					ld		a,e
					cp		VIEW_TOP
					jr		c,.merge
					ld		a,VIEW_BOTTOM
					cp		ixl
					jr		c,.merge
					ld		(.all_inside),a
.merge:				ld		hl,.least_x			; and into the screen's box
					ld		a,c
					cp		(hl)
					jr		nc,.not_least_x2
					ld		(hl),a
.not_least_x2:		inc		hl					; .least_y
					ld		a,e
					cp		(hl)
					jr		nc,.not_least_y2
					ld		(hl),a
.not_least_y2:		inc		hl					; .most_x
					ld		a,d
					cp		(hl)
					jr		c,.not_most_x2
					ld		(hl),a
.not_most_x2:		inc		hl					; .most_y
					ld		a,ixl
					cp		(hl)
					ret		c
					ld		(hl),a
					ret
.behind:			ld		ixh,1
					jr		.next_vertex

; Off the screen's 256: 0 if negative, 255 if not.
.x_far:				add		a,a
					sbc		a,a
					cpl
					jr		.x_held
.y_far:				add		a,a
					sbc		a,a
					cpl
					jr		.y_held

; The B lines cut_edges just wrote from HL: each one's second end, where it
; was cut, into the picture's box, held to 0..255 as .object_box holds the
; vertices. (The first end is a vertex, in the box already.) Uses A, BC,
; DE, HL.
.cut_box:			inc		b
					dec		b
					ret		z
.cut_end:			ld		de,4				; x1, y1
					add		hl,de
					ld		e,(hl)
					inc		hl
					ld		a,(hl)
					inc		hl
					call	.held
					ld		c,a
					ld		a,(.least_x)
					cp		c
					jr		c,.cut_not_least_x
					ld		a,c
					ld		(.least_x),a
.cut_not_least_x:	ld		a,(.most_x)
					cp		c
					jr		nc,.cut_not_most_x
					ld		a,c
					ld		(.most_x),a
.cut_not_most_x:	ld		e,(hl)
					inc		hl
					ld		a,(hl)
					inc		hl
					call	.held
					ld		c,a
					ld		a,(.least_y)
					cp		c
					jr		c,.cut_not_least_y
					ld		a,c
					ld		(.least_y),a
.cut_not_least_y:	ld		a,(.most_y)
					cp		c
					jr		nc,.cut_not_most_y
					ld		a,c
					ld		(.most_y),a
.cut_not_most_y:	djnz	.cut_end
					ret
; A:E, 16-bit, held to 0..255.
.held:				or		a
					jr		nz,.held_far
					ld		a,e
					ret
.held_far:			add		a,a					; 0 if negative, 255 if not
					sbc		a,a
					cpl
					ret

.object:			DW		0					; the one being drawn
.objects_left:		DB		0
.model:				DW		0
.entry:				DW		0					; -> the next entry in visible
.slot:				DW		0					; where the next points go: the
													; vertex, then the page
.first:				DW		0					; and where this object's went
.cut_at:			DW		0					; where the next cut line goes
.edges_at:			DW		0					; and the next edges kept (FACES)
.least_x:			DB		0
.least_y:			DB		0
.most_x:			DB		0
.most_y:			DB		0
.all_inside:		DB		0					; this object needs no clipping
drawn:				DB		0					; objects drawn this frame
cuts:				DB		0					; lines cut at the near plane
new_box:			DB		0, 0, 0, 0			; rows (0: none), top, column, columns


; ---------------------------------------------------------------------------
; render_frame: on the screen screen_high says, clear what was drawn there
; last time, and draw what compute_frame worked out.

; L = a vertex's number, H = the points' page: its x and y into TO_X and
; TO_X + 2, as clip_line takes them, or on to SKIP_TO if it is behind
; the near plane. Keeps B and C. A macro, not a call: twice an edge, a hundred
; edges a picture.
					MACRO	END_AT	TO_X, SKIP_TO
					set		6,l
					ld		a,(hl)				; POINTS_X_HI
					cp		high WIDE_BEHIND
					jr		z,SKIP_TO
					ld		d,a
					res		6,l
					ld		e,(hl)				; POINTS_X_LO
					ld		(TO_X),de
					set		7,l
					ld		e,(hl)				; POINTS_Y_LO
					set		6,l
					ld		d,(hl)				; POINTS_Y_HI
					ld		(TO_X + 2),de
					ENDM

render_frame:
					call	box_of_screen		; clear the last box here
					ld		a,(hl)
					or		a
					jr		z,.cleared
					ld		b,a
					inc		hl
					ld		c,(hl)
					inc		hl
					ld		d,(hl)
					inc		hl
					ld		e,(hl)
					MARK	PH_CLEAR
					call	clear_box
					MARK	PH_OTHER
.cleared:			call	box_of_screen		; and this picture's, for next
					ex		de,hl				; time
					ld		hl,new_box
					ldi
					ldi
					ldi
					ldi
					ld		a,(drawn)
					or		a
					ret		z
					ld		hl,visible
.object:			ld		(.objects_left),a
					ld		a,(hl)				; VIS_PAGE and VIS_BASE, into
					ld		(.page1 + 1),a		; the code below
					ld		(.page2 + 1),a
					inc		hl
					ld		a,(hl)
					ld		(.base1 + 1),a
					ld		(.base2 + 1),a
					ld		(.base3 + 1),a
					ld		(.base4 + 1),a
					inc		hl
					ld		c,(hl)				; VIS_INSIDE
					inc		hl
					ld		a,(hl)				; VIS_EDGES
					inc		hl
					ld		e,(hl)
					inc		hl
					ld		d,(hl)
					inc		hl
					ld		(.entry),hl
					ld		(.edge_at),de
					or		a					; (none kept: nothing to draw)
					jp		z,.next_object
					inc		c
					dec		c
					jr		nz,.inside_edge

; An object reaching outside the window, or behind the near plane: each
; edge clipped (and those cut at the plane drawn after every object).
.edge:				ld		(.edges_left),a
					ld		hl,(.edge_at)
					ld		a,(hl)				; its ends
					inc		hl
.base1:				add		a,0
					ld		b,a
					ld		a,(hl)
					inc		hl
					ld		(.edge_at),hl
.base2:				add		a,0
					ld		c,a
.page1:				ld		h,0
					ld		l,b
					END_AT	clip_x0, render_frame.next_edge	; neither behind the plane
					ld		l,c
					END_AT	clip_x1, render_frame.next_edge
					MARK	PH_CLIP
					call	clip_line
					MARK	PH_OTHER
					jr		c,.next_edge		; none of it in the window
					MARK	PH_LINE
					call	draw_line
					MARK	PH_OTHER
.next_edge:			ld		a,(.edges_left)
					dec		a
					jr		nz,.edge
					jr		.next_object

; An object wholly in the window: each edge's ends, their low bytes, straight
; to draw_line, as clip_line would have passed them.
.inside_edge:		ld		(.edges_left),a
					ld		hl,(.edge_at)
					ld		a,(hl)				; its ends
					inc		hl
					ld		e,(hl)
					inc		hl
					ld		(.edge_at),hl
.base3:				add		a,0
					ld		c,a
					ld		a,e
.base4:				add		a,0
					ld		l,a
.page2:				ld		h,0
					ld		d,(hl)				; POINTS_X_LO
					set		7,l
					ld		e,(hl)				; POINTS_Y_LO
					ld		l,c
					ld		b,(hl)
					set		7,l
					ld		c,(hl)
					MARK	PH_LINE
					call	draw_line
					MARK	PH_OTHER
					ld		a,(.edges_left)
					dec		a
					jr		nz,.inside_edge
.next_object:		ld		hl,(.entry)
					ld		a,(.objects_left)
					dec		a
					jp		nz,.object

; The edges cut at the near plane: each line, front end then the cut, as
; clip_line takes it.
					ld		a,(cuts)
					or		a
					ret		z
					ld		hl,cut_lines
.cut_line:			ld		(.edges_left),a
					ld		de,clip_x0
					ld		bc,8
					ldir
					ld		(.edge_at),hl
					MARK	PH_CLIP
					call	clip_line
					MARK	PH_LINE
					call	nc,draw_line
					MARK	PH_OTHER
					ld		hl,(.edge_at)
					ld		a,(.edges_left)
					dec		a
					jr		nz,.cut_line
					ret

.objects_left:		DB		0
.entry:				DW		0
.edges_left:		DB		0
.edge_at:			DW		0


; ---------------------------------------------------------------------------
; The report, on the console: a picture's T-states (compute_frame and
; render_frame, as fast3d's 468,000), the objects drawn and the pictures a
; second; with PHASES, each part's T-states a picture and its share.

report:
					ld		hl,s_pict
					rst		PUTS
					ld		hl,us_sum			; T-states, the average
					call	load_num
					ld		a,AVG_MUL
					call	mul_num
					ld		hl,AVG_DIV
					call	div_num16
					call	print_num
					ld		hl,s_least
					rst		PUTS
					ld		hl,us_least
					call	print_us_t
					ld		hl,s_most
					rst		PUTS
					ld		hl,us_most
					call	print_us_t
					ld		hl,s_drawn
					rst		PUTS
					ld		hl,(drawn_sum)		; tenths: x 10 / 256
					call	load_num16
					ld		a,10
					call	mul_num
					ld		hl,256
					call	div_num16
					call	print_tenths
					ld		hl,s_rate
					rst		PUTS
					ld		hl,(frames)			; tenths of a picture a second:
					ld		de,(frames_at)		; 256 x 50 x 10 / the frames
					or		a
					sbc		hl,de
					push	hl
					ld		hl,(PICTURES * 500) & 0xFFFF
					ld		(num),hl
					ld		hl,(PICTURES * 500) >> 16
					ld		(num + 2),hl
					pop		hl
					call	div_num16
					call	print_tenths
					ld		hl,s_crlf
					rst		PUTS
					IF PHASES
					ld		ix,ph_sums			; each part: its ticks x 2, less
					ld		b,PH_WAIT			; the marks into it, MARK_T each
.fix:				push	bc
					push	ix
					pop		hl
					ld		de,4
					add		hl,de
					call	load_num			; the marks
					ld		a,MARK_T / 2
					call	mul_num
					ld		a,2
					call	mul_num
					ld		hl,num
					ld		de,mcand2
					ld		bc,4
					ldir
					push	ix
					pop		hl
					call	load_num			; the T-states
					ld		a,2
					call	mul_num
					ld		hl,(num)			; less the marks'
					ld		de,(mcand2)
					or		a
					sbc		hl,de
					ld		(ix + 0),l
					ld		(ix + 1),h
					ld		hl,(num + 2)
					ld		de,(mcand2 + 2)
					sbc		hl,de
					jr		nc,.positive
					ld		hl,0				; (none left: 0)
					ld		(ix + 0),l
					ld		(ix + 1),h
.positive:			ld		(ix + 2),l
					ld		(ix + 3),h
					ld		de,8
					add		ix,de
					pop		bc
					djnz	.fix
					ld		hl,0				; the whole: every part but the
					ld		(ph_total),hl		; wait
					ld		(ph_total + 2),hl
					ld		(ph_marks),hl
					ld		(ph_marks + 2),hl
					ld		ix,ph_sums
					ld		b,PH_WAIT
.sum:				ld		hl,(ph_total)
					ld		e,(ix + 0)
					ld		d,(ix + 1)
					add		hl,de
					ld		(ph_total),hl
					ld		hl,(ph_total + 2)
					ld		e,(ix + 2)
					ld		d,(ix + 3)
					adc		hl,de
					ld		(ph_total + 2),hl
					ld		hl,(ph_marks)		; and the marks
					ld		e,(ix + 4)
					ld		d,(ix + 5)
					add		hl,de
					ld		(ph_marks),hl
					ld		hl,(ph_marks + 2)
					ld		e,(ix + 6)
					ld		d,(ix + 7)
					adc		hl,de
					ld		(ph_marks + 2),hl
					ld		de,8
					add		ix,de
					djnz	.sum
					ld		hl,s_parts
					rst		PUTS
					ld		ix,ph_sums
					ld		iy,ph_names			; (no ROM call uses IY's value)
					ld		b,PH_WAIT
.part:				push	bc
					ld		l,(iy + 0)
					ld		h,(iy + 1)
					rst		PUTS
					push	ix					; T-states a picture
					pop		hl
					call	load_num
					ld		hl,PICTURES
					call	div_num16
					call	print_num
					ld		hl,s_t
					rst		PUTS
					push	ix					; its share: x 100 / the whole
					pop		hl
					call	load_num
					ld		a,100
					call	mul_num
					ld		hl,(ph_total)
					ld		(den),hl
					ld		hl,(ph_total + 2)
					ld		(den + 2),hl
					call	div_num
					call	print_num
					ld		hl,s_pc
					rst		PUTS
					ld		de,8
					add		ix,de
					inc		iy
					inc		iy
					pop		bc
					djnz	.part
					ld		hl,s_whole			; and the whole, a picture
					rst		PUTS
					ld		hl,ph_total
					call	load_num
					ld		hl,PICTURES
					call	div_num16
					call	print_num
					ld		hl,s_marks
					rst		PUTS
					ld		hl,ph_marks			; marks a picture
					call	load_num
					ld		hl,PICTURES
					call	div_num16
					call	print_num
					ld		hl,s_crlf
					rst		PUTS
					ENDIF
					ret

; HL -> a picture's microseconds: print them as T-states.
print_us_t:			call	load_num
					ld		a,PIC_MUL
					call	mul_num
					ld		hl,PIC_DIV
					call	div_num16
					jp		print_num

; ---- 32-bit numbers, for the report: num, den, rem, little-endian

load_num:			ld		de,num				; num = the 4 bytes at HL
					ld		bc,4
					ldir
					ret
load_num16:			ld		(num),hl			; num = HL
					ld		hl,0
					ld		(num + 2),hl
					ret

; num = num x A
mul_num:			ld		hl,(num)
					ld		(mcand),hl
					ld		hl,(num + 2)
					ld		(mcand + 2),hl
					ld		hl,0
					ld		(num),hl
					ld		(num + 2),hl
					ld		b,8
.bit:				ld		hl,num				; num x 2
					sla		(hl)
					inc		hl
					rl		(hl)
					inc		hl
					rl		(hl)
					inc		hl
					rl		(hl)
					add		a,a
					jr		nc,.next
					ld		hl,(num)			; + mcand
					ld		de,(mcand)
					add		hl,de
					ld		(num),hl
					ld		hl,(num + 2)
					ld		de,(mcand + 2)
					adc		hl,de
					ld		(num + 2),hl
.next:				djnz	.bit
					ret

; num = num / HL, rem the remainder
div_num16:			ld		(den),hl
					ld		hl,0
					ld		(den + 2),hl
; num = num / den, rem the remainder (den below 2^31)
div_num:			ld		hl,0
					ld		(rem),hl
					ld		(rem + 2),hl
					ld		b,32
.bit:				ld		hl,num
					sla		(hl)
					inc		hl
					rl		(hl)
					inc		hl
					rl		(hl)
					inc		hl
					rl		(hl)
					ld		hl,rem
					rl		(hl)
					inc		hl
					rl		(hl)
					inc		hl
					rl		(hl)
					inc		hl
					rl		(hl)
					ld		hl,(rem)
					ld		de,(den)
					or		a
					sbc		hl,de
					ld		(trial),hl
					ld		hl,(rem + 2)
					ld		de,(den + 2)
					sbc		hl,de
					jr		c,.next
					ld		(rem + 2),hl
					ld		hl,(trial)
					ld		(rem),hl
					ld		hl,num
					set		0,(hl)
.next:				djnz	.bit
					ret

; print num in decimal (num is lost)
print_num:			ld		c,0
.digit:				ld		hl,10
					call	div_num16
					ld		a,(rem)
					push	af
					inc		c
					ld		hl,(num)
					ld		a,h
					or		l
					ld		hl,(num + 2)
					or		h
					or		l
					jr		nz,.digit
.out:				pop		af
					add		a,'0'
					rst		PUTC
					dec		c
					jr		nz,.out
					ret

; print num tenths as a number to a tenth
print_tenths:		ld		hl,10
					call	div_num16
					ld		a,(rem)
					push	af
					call	print_num
					ld		a,'.'
					rst		PUTC
					pop		af
					add		a,'0'
					rst		PUTC
					ret

num:				DS		4
den:				DS		4
rem:				DS		4
mcand:				DS		4
trial:				DW		0

; ---------------------------------------------------------------------------
; mark: MARK's call. The ticks since the last mark go to the part that
; was running; from here they go to the part whose sum HL points at.
; Timer 0 counts down, a tick every 2 T-states. Keeps everything but HL,
; which MARK keeps.
					IF PHASES
mark:				push	af
					push	de
					push	hl
					ld		hl,(SREG + TMR0_COUNT0)	; now (reading COUNT0 captures)
					ld		de,(ph_last)
					ld		(ph_last),hl
					ex		de,hl
					or		a
					sbc		hl,de				; then - now: the ticks
					ex		de,hl
					ld		hl,(ph_part)		; into the part's sum
					ld		a,(hl)
					add		a,e
					ld		(hl),a
					inc		hl
					ld		a,(hl)
					adc		a,d
					ld		(hl),a
					jr		nc,.added
					inc		hl
					inc		(hl)
					jr		nz,.added
					inc		hl
					inc		(hl)
.added:				pop		hl					; the new part, and a mark
					ld		(ph_part),hl		; into it
					ld		de,4
					add		hl,de
					inc		(hl)
					jr		nz,.counted
					inc		hl
					inc		(hl)
					jr		nz,.counted
					inc		hl
					inc		(hl)
.counted:			pop		de
					pop		af
					ret

; A mark's T-states, MARK to MARK's end, as the commonest path takes them:
; the macro 48 (PUSH, LD, CALL, POP), mark 282. The report takes MARK_T off
; each part for each mark into it: a part pays for the end of the mark that
; starts it and the start of the one that ends it.
MARK_T				EQU		330

ph_last:			DW		0
ph_part:			DW		ph_sums + 8 * PH_WAIT
ph_sums:			DS		8 * PH_COUNT		; each part: ticks, then marks
ph_total:			DS		4
ph_marks:			DS		4
mcand2:				DS		4
ph_names:			DW		s_other, s_camera, s_cull, s_matrix, s_vertex, s_cut, s_clear, s_clip, s_line, s_faces
s_faces:			DB		"  faces     ", 0
s_other:			DB		"  other     ", 0
s_camera:			DB		"  camera    ", 0
s_cull:				DB		"  cull      ", 0
s_matrix:			DB		"  matrices  ", 0
s_vertex:			DB		"  vertices  ", 0
s_cut:				DB		"  near cut  ", 0
s_clear:			DB		"  clearing  ", 0
s_clip:				DB		"  clipping  ", 0
s_line:				DB		"  lines     ", 0
s_parts:			DB		"Where the time goes (T-states a picture, the marks' taken out):", 13, 10, 0
s_pc:				DB		"%", 13, 10, 0
s_whole:			DB		"  the whole ", 0
s_marks:			DB		" T, marks a picture ", 0
					ENDIF

; ---------------------------------------------------------------------------
; The vertical blank: count it, show the picture flip_to asks for, and put
; L0's pointer back to the top of the screen shown.

vblank:				push	af
					push	hl
					ld		a,VIDSTAT_VBLANK_M
					ld		(CREG + VIDSTAT),a
					ld		hl,(frames)
					inc		hl
					ld		(frames),hl
					ld		a,(flip_to)
					or		a
					jr		z,.same
					ld		(shown),a
					xor		a
					ld		(flip_to),a
.same:				ld		a,(shown)
					ld		hl,SCREEN0 & 0xFFFF
					dec		a
					jr		z,.pointer
					ld		hl,SCREEN1 & 0xFFFF
.pointer:			ld		(CREG + L0 + L_BPL0PT),hl
					ld		a,SCREEN0 >> 16
					ld		(CREG + L0 + L_BPL0PT + 2),a
					pop		hl
					pop		af
					ei
					reti

spurious:			ei
					reti

; ---------------------------------------------------------------------------
; finish: everything as it was, the results on the console, and back to
; the monitor.

finish:
					di
					xor		a
					ld		(SREG + INTCON),a
					ld		a,1 << INTB_VBLANK	; (SETCLR clear: off)
					ld		(SREG + INTENA0 + INTR_VBLANK),a
					xor		a
					ld		(CREG + VIDINTEN),a
					ld		(SREG + TMR0_CTRL),a
					ld		a,(exit_speed)		; the CPU's speed as it was
					ld		(SREG + CPUSPEED),a
					ld		hl,save_l0 + L_SPAN - 1	; the console's L0: the last
					ld		de,CREG + L0 + L_SPAN - 1	; register first, CTRL0 last
					ld		bc,L_SPAN
					lddr
					ld		hl,save_colours
					ld		de,PALENT
					ld		bc,6
					ldir
					ld		a,0x1F				; the ROM's table again
					ld		i,a
					ld		a,0xD0
					ld		(SREG + VECBASE),a
					ld		hl,(exit_mmu7)
					ld		(SREG + MMU7),hl
					ld		hl,s_title
					rst		PUTS
					call	report
					ld		sp,(exit_sp)
					ld		bc,MMU1_0_P			; window 1 back to SRAM page 1
					ld		a,1
					out		(c),a
					inc		b
					xor		a
					out		(c),a
					ret

; ---------------------------------------------------------------------------

layer0:				DB		L_CTRL0_EN_M | (1 << L_CTRL0_HSCALE_B)	; CTRL0: 1 bpp bitmap, 2x
					DB		(1 << L_CTRL1_VSCALE_B) | (PALOFS << L_CTRL1_PALOFS_B)	; CTRL1: 2x down
					DB		0, 0				; CTRL2, CTRL3
					DW		WIN_X + 512, WIN_X	; WINX: XEND, XSTART
					DW		WIN_Y + 384, WIN_Y	; WINY: YEND, YSTART
					DW		0, 0				; SCROLLX, SCROLLY
					DW		32					; BPLSTRIDE
					DW		0
					D24		SCREEN0				; BPL0PT
					DB		0
					D24		0					; MAPPT
					DB		0
					D24		0					; PATPT
					DB		0
colours:			DB		0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF	; blue, green, red

exit_sp:			DW		0
exit_mmu7:			DW		0
save_l0:			DS		L_SPAN				; the console's L0
save_colours:		DS		6
frames:				DW		0					; vertical blanks
frames_at:			DW		0					; ... when the timing started
flip_to:			DB		0					; 1, 2: the screen the next
shown:				DB		1					; vertical blank shows
drawing:			DB		1					; 0, 1: the screen drawn on
reported:			DB		0
pictures:			DW		0
t_start:			DW		0, 0
t_work:				DW		0, 0
us_pic:				DW		0, 0
us_sum:				DW		0, 0
us_least:			DW		0xFFFF, 0xFFFF
us_most:			DW		0, 0
exit_speed:			DB		0
drawn_sum:			DW		0

s_title:			DB		13, 10, "fast3d on retro-z80, "
					IF GEOM
					DB		"culling and vertices through the geometry unit"
					ELSE
					DB		"in software"
					ENDIF
					IF FACES
					DB		", back faces removed"
					ENDIF
					IF SPECTRUM
					DB		", 3.57 MHz"
					ELSE
					DB		", 20 MHz"
					ENDIF
					IF PHASES
					DB		", timing each part"
					ENDIF
					DB		13, 10, 0
s_pict:				DB		"256 pictures. A picture: ", 0
s_least:			DB		" T-states on average", 13, 10, "  least ", 0
s_most:				DB		", most ", 0
s_drawn:			DB		13, 10, "Objects drawn a picture: ", 0
s_rate:				DB		13, 10, "Pictures a second: ", 0
s_t:				DB		" T  ", 0
s_crlf:				DB		13, 10, 0

					IF GEOM
					INCLUDE	"geom.asm"
					ENDIF
					INCLUDE	"fast3d.s"
					INCLUDE	"output/objects_gen.s"
					INCLUDE	"output/world_gen.s"

code_end:
					ASSERT	code_end <= 0xE000
					SAVEBIN	OUTPUT, 0x8000, code_end - 0x8000	; (build.py says where)

; Each object drawn: its points, from transform_object, in the four tables
; of 64 on one of these pages, and its entry; and the lines cut at the near
; plane. Not loaded: written before they are read.
					ORG		0x4000
point_pool:			DS		256 * POINT_PAGES
visible:			DS		VIS_SIZE * WORLD_OBJECTS
cut_lines:			DS		8 * CUT_LINES
					IF FACES
edge_pool:			DS		2 * WORLD_EDGES		; the edges kept, for every object
					ENDIF
					ASSERT	$ <= STACK - 512	; room for the stack
