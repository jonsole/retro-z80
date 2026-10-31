; fast3d's lines drawn by the DMA engine's LINE job (spec 14, section 3.4;
; ticket #75): fast3d.asm includes this when LINE is 1. Each line goes to
; channel 0 as it is, 16-bit ends and all; the engine's clip rectangle is
; the window, so clip_line is not needed. Software only leaves out a line
; wholly beyond one edge of the window. The Z80 works out the next line
; while the engine draws the last.
;
; Needs a bitstream with the DMA engine and LINE: on the KS2 the build
; without the copper (fpga/ks2/build.sh --no-copper).

; dma_setup: channel 0's fixed fields and the clip rectangle, once.
dma_setup:
					ld		hl,line_job
					ld		de,CREG + DMX0
					ld		bc,32
					ldir
					ld		hl,line_clip
					ld		de,CREG + CLIPXMIN
					ld		bc,8
					ldir
					ld		a,DMACON_SETCLR_M | DMACON_DMAEN_M | DMACON_BLTEN_M
					ld		(CREG + DMACON),a
					ret

line_job:			DB		2, 0, 0, 0xCA		; CTRL: LINE, 1 bpp; D = A ? B : C
					DS		3 + 3 + 3 + 3		; APT (LX), BPT (LY), DPT, WIDTH
					DW		0, 0, 0			; HEIGHT, SHIFT, ABSTRIDE
					DW		32					; CDSTRIDE: the screen's rows
					DD		0xFFFF0001			; VALUE: a solid pattern, colour 1
					DS		4					; NEXT: none
line_clip:			DW		VIEW_LEFT, VIEW_RIGHT, VIEW_TOP, VIEW_BOTTOM

; dma_wait: until channel 0 has finished its line. Uses A.
dma_wait:			ld		a,(CREG + DMX0_CHSTAT)
					rra
					jr		c,dma_wait
					ret

; dma_line8: the line from (B, C) to (D, E), 0..255 each, as draw_line
; takes it: an object wholly inside the window, so no compares, and the
; address from ROW_TABLE. Uses everything but IX and IY.
dma_line8:
					ld		h,2					; H = CTRL0: OP 2, LINE
					ld		a,d					; |dx|
					sub		b
					jr		nc,.right
					neg
					set		DMX_CTRL_XNEG_B,h
.right:				ld		l,a					; L = |dx|
					ld		a,e					; |dy|
					sub		c
					jr		nc,.down
					neg
					set		DMX_CTRL_YNEG_B,h
.down:				cp		l
					jr		c,.along_x			; |dy| < |dx|
					jr		z,.along_x
					set		DMX_CTRL_YMAJOR_B,h
					ld		d,a					; D = WIDTH - 1, E = HEIGHT
					ld		e,l
					jr		.lengths
.along_x:			ld		d,l
					ld		e,a
.lengths:			ld		a,h
					ld		(.ctrl),a
					ld		l,c					; DPT: row y0's address in window
					ld		h,high ROW_TABLE	; 7, + x0 / 8, made physical
					ld		a,(hl)
					inc		h
					ld		h,(hl)
					ld		l,a
					ld		a,b
					rrca
					rrca
					rrca
					and		31
					or		l
					ld		l,a
					ld		a,(drawing)			; 0x00 or 0x20 more for screen 1
					rrca
					rrca
					rrca
					add		a,h
					sub		0xE0 - ((SCREEN0 >> 8) & 0xFF)
					ld		h,a
					call	dma_wait
					ld		(CREG + DMX0_DPT),hl
					ld		a,SCREEN0 >> 16
					ld		(CREG + DMX0_DPT2),a
					ld		a,(.ctrl)
					ld		(CREG + DMX0_CTRL0),a
					ld		h,0
					ld		l,b
					ld		(CREG + DMX0_APT),hl	; LX
					ld		l,c
					ld		(CREG + DMX0_BPT),hl	; LY
					ld		l,e
					ld		(CREG + DMX0_HEIGHT),hl
					ld		l,d
					inc		hl
					ld		(CREG + DMX0_WIDTH),hl
					ld		a,b
					and		7
					ld		(CREG + DMX0_SHIFT1),a	; DBIT
					ld		a,DMX_CHCTRL_RUN_M
					ld		(CREG + DMX0_CHCTRL),a
					ret
.ctrl:				DB		0

; dma_line: the line from (clip_x0, clip_y0) to (clip_x1, clip_y1), 16-bit
; signed, as clip_line takes it, on the screen being drawn. Uses
; everything but IX and IY.
dma_line:
					ld		hl,(clip_x0)		; wholly beyond an edge: nothing
					ld		de,(clip_x1)
					ld		bc,VIEW_LEFT
					call	.both_below
					ret		c
					ld		bc,VIEW_RIGHT + 1
					call	.both_at_or_above
					ret		c
					ld		hl,(clip_y0)
					ld		de,(clip_y1)
					ld		bc,VIEW_TOP
					call	.both_below
					ret		c
					ld		bc,VIEW_BOTTOM + 1
					call	.both_at_or_above
					ret		c

					ld		c,2					; C = CTRL0: OP 2, LINE, and the octant
					ld		hl,(clip_x1)		; |dx|
					ld		de,(clip_x0)
					or		a
					sbc		hl,de
					jp		p,.right
					call	.negate
					set		DMX_CTRL_XNEG_B,c
.right:				ld		(.ax),hl
					ld		hl,(clip_y1)		; |dy|
					ld		de,(clip_y0)
					or		a
					sbc		hl,de
					jp		p,.down
					call	.negate
					set		DMX_CTRL_YNEG_B,c
.down:				ld		de,(.ax)			; the longer is WIDTH - 1, the
					push	hl					; shorter HEIGHT
					or		a
					sbc		hl,de
					pop		hl					; (keeps the flags)
					jr		c,.along_x			; |dy| < |dx|
					jr		z,.along_x			; equal: along x
					set		DMX_CTRL_YMAJOR_B,c	; HL = |dy|, DE = |dx|
					jr		.lengths
.along_x:			ex		de,hl				; HL = |dx|, DE = |dy|
.lengths:			inc		hl					; HL = WIDTH, DE = HEIGHT
					ld		(.width),hl
					ld		(.height),de
					ld		a,c
					ld		(.ctrl),a

					ld		hl,(clip_y0)		; DPT = the screen + 32 y0 + x0 / 8
					ld		a,h					; E:HL = 32 y0, 24 bits
					rla
					sbc		a,a
					ld		e,a
					ld		b,5
.times32:			add		hl,hl
					rl		e
					djnz	.times32
					ld		bc,(clip_x0)		; + x0 / 8, rounded down
					ld		a,c
					and		7
					ld		(.dbit),a
					sra		b
					rr		c
					sra		b
					rr		c
					sra		b
					rr		c
					ld		a,b
					rla
					sbc		a,a
					ld		d,a
					add		hl,bc
					ld		a,e
					adc		a,d
					ld		e,a
					ld		a,(drawing)			; + the screen being drawn
					or		a
					ld		bc,SCREEN0 & 0xFFFF
					jr		z,.screen
					ld		bc,SCREEN1 & 0xFFFF
.screen:			add		hl,bc
					ld		a,e
					adc		a,SCREEN0 >> 16
					and		0x7F				; 23 bits, wrapping
					ld		e,a

					MARK	PH_DWAIT
					call	dma_wait			; the last line done: the job
					MARK	PH_LINE
					ld		(CREG + DMX0_DPT),hl	; registers take writes again
					ld		a,e
					ld		(CREG + DMX0_DPT2),a
					ld		a,(.ctrl)
					ld		(CREG + DMX0_CTRL0),a
					ld		hl,(clip_x0)
					ld		(CREG + DMX0_APT),hl	; LX
					ld		hl,(clip_y0)
					ld		(CREG + DMX0_BPT),hl	; LY
					ld		hl,(.width)
					ld		(CREG + DMX0_WIDTH),hl
					ld		hl,(.height)
					ld		(CREG + DMX0_HEIGHT),hl
					ld		a,(.dbit)
					ld		(CREG + DMX0_SHIFT1),a	; DBIT
					ld		a,DMX_CHCTRL_RUN_M
					ld		(CREG + DMX0_CHCTRL),a
					ret

.negate:			xor		a					; HL = -HL
					sub		l
					ld		l,a
					sbc		a,a
					sub		h
					ld		h,a
					ret

; carry if HL < BC and DE < BC, signed
.both_below:		call	.less
					ret		nc
					ex		de,hl
					call	.less
					ex		de,hl
					ret
; carry if HL >= BC and DE >= BC, signed
.both_at_or_above:	call	.less
					jr		c,.no
					ex		de,hl
					call	.less
					ex		de,hl
					ccf
					ret
.no:				or		a
					ret
; carry if HL < BC, signed. Keeps HL, BC, DE.
.less:				ld		a,h
					xor		b
					jp		m,.signs
					push	hl
					or		a
					sbc		hl,bc
					pop		hl
					ret
.signs:				ld		a,h					; signs differ: HL < BC if HL
					rla							; is the negative one
					ret

.ax:				DW		0
.width:				DW		0
.height:			DW		0
.ctrl:				DB		0
.dbit:				DB		0

; render_edges: render_frame's objects, from HL -> the first entry of
; visible and A objects: each object's points copied from fast3d's four
; tables into 4-byte records (x, y), then one EDGES job (spec 14, section
; 3.5) draws all its edges, clipped, while the Z80 copies the next. Then
; the lines cut at the near plane, as LINE jobs. Uses everything but IY.
render_edges:
					MARK	PH_LINE
					ld		(.left),a
					ld		de,records
.object:			ld		a,(hl)				; VIS_PAGE
					ld		b,a
					inc		hl
					ld		c,(hl)				; VIS_BASE
					inc		hl
					inc		hl					; (VIS_INSIDE: the engine clips)
					ld		a,(hl)				; VIS_EDGES
					ld		(.count),a
					inc		hl
					ld		a,(hl)
					ld		(.edges),a
					inc		hl
					ld		a,(hl)
					ld		(.edges + 1),a
					inc		hl
					ld		a,(hl)				; VIS_VERTS
					inc		hl
					ld		(.entry),hl
					ld		h,b
					ld		l,c
					ld		b,a
					ld		(.points),de
					ld		a,(.count)
					or		a
					jr		z,.next				; no edges kept
.point:				ld		a,(hl)				; x low
					ld		(de),a
					inc		de
					set		6,l					; x high
					ld		a,(hl)
					ld		(de),a
					inc		de
					set		7,l					; y low
					res		6,l
					ld		a,(hl)
					ld		(de),a
					inc		de
					set		6,l					; y high
					ld		a,(hl)
					ld		(de),a
					inc		de
					ld		a,l
					and		0x3F
					inc		a
					ld		l,a
					djnz	.point
					push	de
					MARK	PH_DWAIT
					call	dma_wait
					MARK	PH_LINE
					ld		hl,(.points)		; POINTS
					ld		(CREG + DMX0_APT),hl
					xor		a
					ld		(CREG + DMX0_APT2),a
					ld		(CREG + DMX0_BPT2),a
					ld		(CREG + DMX0_HEIGHT + 1),a
					ld		(CREG + DMX0_SHIFT1),a	; the origin's DBIT
					ld		hl,(.edges)			; EDGES
					ld		(CREG + DMX0_BPT),hl
					ld		a,(.count)
					ld		l,a
					ld		h,0
					ld		(CREG + DMX0_WIDTH),hl
					ld		a,(drawing)			; the origin: the screen being drawn
					or		a
					ld		hl,SCREEN0 & 0xFFFF
					jr		z,.origin
					ld		hl,SCREEN1 & 0xFFFF
.origin:			ld		(CREG + DMX0_DPT),hl
					ld		a,SCREEN0 >> 16
					ld		(CREG + DMX0_DPT2),a
					ld		a,3					; CTRL0: OP 3, EDGES
					ld		(CREG + DMX0_CTRL0),a
					ld		a,DMX_CHCTRL_RUN_M
					ld		(CREG + DMX0_CHCTRL),a
					pop		de
.next:				ld		hl,(.entry)
					ld		a,(.left)
					dec		a
					ld		(.left),a
					jp		nz,.object

					ld		a,(cuts)			; the lines cut at the near plane
					or		a
					jr		z,.done
					ld		hl,cut_lines
.cut:				ld		(.left),a
					ld		de,clip_x0
					ld		bc,8
					ldir
					ld		(.entry),hl
					call	dma_line
					ld		hl,(.entry)
					ld		a,(.left)
					dec		a
					jr		nz,.cut
.done:				MARK	PH_OTHER
					ret

.left:				DB		0
.count:				DB		0
.edges:				DW		0
.entry:				DW		0
.points:			DW		0
