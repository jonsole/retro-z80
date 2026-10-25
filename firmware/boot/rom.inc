; The boot ROM's constants (spec 16): its identity, the monitor's map, the
; console's state in the map's hidden columns and the monitor's workspace.
; Included by boot.asm.

; ---- Identity (ROMID at 0x0048, spec 16, section 3.1)
ROM_MAJOR equ   0
ROM_MINOR equ   1                       ; 0.1: the monitor's first step (ticket #22)
NFUNC   equ     0x11                    ; the highest RST 28h function

; ---- MMU pages (spec 2, section 9.3; spec 16, section 5)
PG_ROM2 equ     0x3FE
PG_ROM3 equ     0x3FF                   ; the NMI page (spec 16, section 8.6)
PG_REG  equ     0x3F8                   ; the register page
PG_CON  equ     0x0FE                   ; the console map and its state
PG_WS   equ     0x0FF                   ; the font and the monitor's workspace

; ---- The monitor's map (spec 16, section 5.2)
CMAP    equ     0x8000                  ; window 4: page 0x0FE
AWIN    equ     0xA000                  ; window 5: the access window
MSTACK  equ     0x8000                  ; the monitor's stack, down from the top of window 3

; ---- The console's state: map row 0, columns 96-127 (offset 0xC0 of page
; 0x0FE; spec 16, section 5.3). A ROM call reaches it through IY = the
; page's base + 0xC0.
CS_MARK  equ    0x00                    ; 0x5A: the state is valid
CS_ROW   equ    0x01                    ; the cursor's row on the screen, 0-29
CS_COL   equ    0x02                    ; ... and column, 0-79
CS_TOP   equ    0x03                    ; the map row at the top of the screen, 0-31
CS_ATTR  equ    0x04                    ; entries' high byte: PAL x 2
CS_MODE  equ    0x05                    ; CONMODE (spec 16, section 7.3)
CS_KF0   equ    0x06                    ; PS/2: F0 came (the next key is released)
CS_KE0   equ    0x07                    ; ... E0 came
CS_KSH   equ    0x08                    ; ... the Shifts held: bit 0 left, bit 1 right
CS_KCAPS equ    0x09                    ; ... Caps Lock in bit 0
CS_KLAST equ    0x0A                    ; ... the last byte
CS_MPREV equ    0x0C                    ; 7 bytes: KEYMAP0-6 as last seen
CS_SESC  equ    0x13                    ; the serial escape decoder: 0 idle, 1 ESC, 2 ESC [, 3 ESC O, 4 ESC [ digits
CS_SNUM  equ    0x14                    ; ... the digits so far
CS_STIME equ    0x15                    ; ... 2 bytes: TIME bits 23-8 when ESC came
CS_CRLF  equ    0x17                    ; 1: the last serial byte was CR (an LF after it is dropped)
CS_BASE  equ    0x18                    ; the map's address, high byte, in the window borrowed
CS_CUR   equ    0x19                    ; 1: the cursor is drawn
CS_UNDER equ    0x1A                    ; 2 bytes: the entry under the cursor
CS_RKEY  equ    0x1C                    ; the membrane key that repeats (0: none)
CS_RPOS  equ    0x1D                    ; ... its place, 8 x column + row
CS_RTIME equ    0x1E                    ; ... 2 bytes: when it next repeats (TIME bits 23-8)
CS_PEND  equ    0x20                    ; a key waiting to be given (0: none)
; The last line typed (GETLINE's Up) is kept in columns 96-127 of map rows
; 1-4, 64 bytes a row, ending in 0

; ---- The workspace, page 0x0FF at 0x6000 (spec 16, section 5.3)
WFONT   equ     0x6000                  ; 2 KB: the console font (PATPT 0x1FE000)
WSTATE  equ     0x6800                  ; 256: the monitor's state, with a marker and a sum
M_MARK  equ     0x6800                  ; 2: "RZ"
M_SUM   equ     0x6802                  ; 2: the sum of 0x6804-0x68FF
M_WHY   equ     0x6804                  ; why the monitor was entered (R_...)
M_RUN   equ     0x6805                  ; 1: a program was stopped part-way (G goes on)
M_IM    equ     0x6806                  ; the program's IM (bits 1-0); bit 6: set by R; bit 7: it has run ("?")
M_IFF   equ     0x6807                  ; IFF1 as the program had it
M_ENTRY equ     0x6808                  ; 2: where the program was last started
M_LAST  equ     0x680A                  ; the command Enter carries on ('D', 'S', 'I', 'N' or 0)
                                        ; 0x680B-0x680D: free (the RST 30h breakpoint's, before #28)
M_STEPF equ     0x680E                  ; 1: G leaves with DBGCTL.STEP (N)
M_SPEED equ     0x680F                  ; the program's CPUSPEED
M_AF    equ     0x6810                  ; the program's registers, 2 bytes each
M_BC    equ     0x6812
M_DE    equ     0x6814
M_HL    equ     0x6816
M_IX    equ     0x6818
M_IY    equ     0x681A
M_SP    equ     0x681C
M_PC    equ     0x681E
M_AF2   equ     0x6820
M_BC2   equ     0x6822
M_DE2   equ     0x6824
M_HL2   equ     0x6826
M_I     equ     0x6828
M_R     equ     0x6829
M_TAKEN equ     0x682A                  ; 1: the screen is taken (M_VID holds the program's)
M_NMI   equ     0x682B                  ; after an NMI: NMISTAT's BUTTON (0) and USB (1) as seen;
                                        ; bit 7: through the NMI page, so G leaves by the save area
M_SHOW  equ     0x682C                  ; 2: the address the message gives
M_MMU   equ     0x6830                  ; 32: the program's MMU0_0 ... MMU7_1, then MMU0W_0 ... MMU7W_1
M_D     equ     0x6850                  ; 4: where D carries on (low, middle, high, bit 0 physical)
M_DSZ   equ     0x6854                  ; ... and its size
M_SNEXT equ     0x6858                  ; 4: where S carries on
M_SCNT  equ     0x685C                  ; 3: ... the bytes left to search
M_SLEN  equ     0x685F                  ; ... the pattern's length
M_SPAT  equ     0x6860                  ; 32: ... the pattern
M_VID   equ     0x6890                  ; 43: L0's 32 registers, PRIO, DMACON, BGCOLOR (3), COPCON, VIDCON,
                                        ; PALIDX (2), and the console's CONMODE and colour pair
M_INEXT equ     0x68C0                  ; 4: where I carries on
M_IRST  equ     0x68C4                  ; 1: I's last instruction was RST 28h (a function number next)
M_DBG   equ     0x68C5                  ; after an NMI: DBGSTAT as seen (0 otherwise)
M_HITA  equ     0x68C6                  ; 2: ... with a watchpoint: DBGHITADDR
M_HITD  equ     0x68C8                  ; ... DBGHITDATA
M_HITK  equ     0x68C9                  ; ... DBGHITKIND
WSTATE_END equ  0x6900

LBUF    equ     0x6900                  ; the line being typed
LBUFSZ  equ     79                      ; 78 characters after "> ": one screen line
EBUF    equ     0x6960                  ; E's line, one value at a time
EBUFSZ  equ     20
T_I     equ     0x6974                  ; 2: a loop count, a start time
; The monitor's temporaries, 0x6980-0x69FF (not kept)
T_SIZE  equ     0x6980                  ; the access size: 1, 2 or 4
T_SZSET equ     0x6981                  ; 1: a size was given
T_CUR   equ     0x6982                  ; 4: the address being reached (low, middle, high, bit 0 physical)
T_A1    equ     0x6986                  ; 4: the first address
T_A2    equ     0x698A                  ; 4: the second address
T_CNT   equ     0x698E                  ; 3: a count
T_CNT2  equ     0x6991                  ; 3: ... and a copy of it
T_NUM   equ     0x6994                  ; 4: the last number read
T_PAGE  equ     0x6998                  ; 2: the page in the access window
T_N     equ     0x699A                  ; 3: a count of things found
T_COL   equ     0x699D                  ; characters printed on this line
T_VLEN  equ     0x699E                  ; the values' length in bytes
T_FLAG  equ     0x699F
T_DBUF  equ     0x69A0                  ; 16: a dump line's bytes
T_DSE   equ     0x69B0                  ; 16: ... 1 where the byte was not read (side effects)
T_VAL   equ     0x69C0                  ; 64: values to enter, fill or find
T_VMAX  equ     64
DISBUF  equ     T_VAL                   ; 48: I's line from the disassembler (in T_VAL)
DISVAR  equ     T_VAL + 48              ; 12: the disassembler's variables
; 0x6A00-0x6DFF: kept for the SD card and the loader (later tickets)
WENT    equ     0x6E00                  ; the entry frame, copied from the program's stack
WMMUT   equ     0x6E20                  ; 32: the MMU registers as found at entry
WPAL    equ     0x6E40                  ; 90: PALETTE0's console pairs as the program had them
; The NMI save area, 0x0EA0-0x0EDF of page 0x0FF (spec 16, sections 5.3 and
; 8.6): at 0x0Exx through window 0 at an NMI, at 0x6Exx through window 3.
; Not in the state block's sum: M_MON changes as G leaves.
M_MON   equ     0x6EA0                  ; MON_ON while the monitor itself runs: an NMI goes straight back
MON_ON  equ     0xA5
NMX_W3  equ     0x6EA6                  ; 2: for the exit: window 3's read page (MMU3_0, MMU3_1) ...
NMX_W3W equ     0x6EA8                  ; 2: ... and write page
NMX_HL  equ     0x6EAA                  ; 2: HL, BC and AF, as the entry pushed them through window 0
NMX_BC  equ     0x6EAC
NMX_AF  equ     0x6EAE
NMX_SP  equ     0x6EB0                  ; 2: the program's SP (NMICAPSP - 2)
NMX_CODE equ    0x6EB4                  ; the exit's bytes, up to 0x6EDF (monitor.asm, nmix)

; ---- Why the monitor was entered
R_START equ     0
R_EXIT  equ     1                       ; "Program ended."
R_BREAK equ     2                       ; RST 30h
R_FBREAK equ    3                       ; RST 28h function BREAK
R_TRAP  equ     4                       ; RST 38h
R_NMI   equ     5
R_BKPT  equ     6                       ; (not used: a breakpoint is an NMI, with DBGSTAT in M_DBG)
R_NMI3  equ     7                       ; an NMI through the NMI page (becomes R_NMI)

; ---- Colour pairs (spec 7, section 5.1): entries' high byte, PAL x 2
PAIR0   equ     1 << 1                  ; light grey on black
PAIR1   equ     2 << 1                  ; white on black
PAIR2   equ     3 << 1                  ; green on black
