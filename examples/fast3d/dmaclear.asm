; fast3d's clearing by the DMA engine (ticket #74): fast3d.asm includes this
; when DMACLEAR is 1. Instead of clear_box, a BLIT fill on channel 2 blanks
; the box of what was last drawn on a screen. The vertical blank starts it
; the moment it flips, on the screen it has just stopped showing, so the
; fill runs while the Z80 works out the next picture; render_frame only waits
; for it before drawing there.
;
; The fill is at 8 bits a pixel, so the box's byte columns are its WIDTH:
; whole bytes, so no C is read. Needs a bitstream with the DMA engine (any
; KS2 build but --geom).

; clear_setup: channel 2's fixed fields, once.
clear_setup:
					ld		hl,clear_job
					ld		de,CREG + DMX2
					ld		bc,32
					ldir
					ld		a,DMACON_SETCLR_M | DMACON_DMAEN_M | DMACON_BLTEN_M
					ld		(CREG + DMACON),a
					ret

clear_job:			DB		0					; CTRL0: BLIT
					DB		DMX_CTRL_BCONST_M >> 8 | 3	; CTRL1: 8 bpp, B is VALUE
					DB		0, 0xCC				; CTRL2; MINTERM: D = B, a fill
					D24		0					; APT
					D24		0					; BPT
					D24		SCREEN0				; DPT (the low 16 bits a box's)
					D24		0					; WIDTH: the box's columns
					DW		0, 0, 0				; HEIGHT (its rows), SHIFT, ABSTRIDE
					DW		32					; CDSTRIDE: the screen's rows
					DD		0					; VALUE: blank
					D24		0					; NEXT: none
					DB		0

; clear_start: from the vertical blank, A = the screen now shown (1, 2):
; the fill of the other one's box, if anything was drawn there. Uses A, HL.
clear_start:
					push	bc
					push	de
					ld		hl,boxes + 4		; screen 0 shown: screen 1 freed,
					ld		b,(SCREEN1 - SCREEN0) >> 8	; 0x2000 further on
					dec		a
					jr		z,.box
					ld		hl,boxes
					ld		b,0
.box:				ld		a,(hl)				; rows
					or		a
					jr		z,.done
					ld		(CREG + DMX2_HEIGHT0),a
					inc		hl
					ld		e,(hl)				; top
					inc		hl
					ld		c,(hl)				; left column
					inc		hl
					ld		a,(hl)				; columns
					ld		(CREG + DMX2_WIDTH0),a
					ld		l,e					; DPT = top x 32 + column, on
					ld		h,0					; the screen's page
					add		hl,hl
					add		hl,hl
					add		hl,hl
					add		hl,hl
					add		hl,hl
					ld		a,l
					or		c
					ld		l,a
					ld		a,h
					add		a,b
					ld		h,a
					ld		(CREG + DMX2_DPT),hl
					ld		a,DMX_CHCTRL_RUN_M
					ld		(CREG + DMX2_CHCTRL),a
.done:				pop		de
					pop		bc
					ret

; clear_wait: until channel 2's fill has finished. Uses A.
clear_wait:			ld		a,(CREG + DMX2_CHSTAT)
					rra
					jr		c,clear_wait
					ret
