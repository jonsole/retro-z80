; copper.inc: the copper's instructions as sjasmplus macros (spec 6,
; section 7), after retro68k's copper.inc. Register names are the custom
; offsets of hw.inc. Each macro emits DW words as spec 6, section 4.1; put
; lists on even addresses (ALIGN 2).
;
;   CMOVE reg,value        MOVE: one byte to offset 0x000-0x0EF (1 word)
;   CMOVEF reg,value       MOVEF: one byte to any custom offset (2 words)
;   CMOVEB reg,value       either, as the offset needs
;   CMOVEW / CMOVEA / CMOVEL reg,value   a 2-, 3- or 4-byte register, low byte first
;   CMOVEN reg,value,n     an n-byte register (n = 1-4)
;   CWAIT line,pixel   CWAITP pixel   CWAITB line,pixel
;   CSKIP line,pixel   CSKIPP pixel
;   CJUMP address   CSTOP   CCALL address   CRET
;   CMOVX value   CMOVXP value   CMOVR reg,CX   CMOVR reg,CY   CMOVXR src   CMOVXRP src
;   CLDI d,value   CLD d,src   CST CRn,d   (d: CX, CY or CF)
;   CADDI CADD CSUBI CSUB CANDI CAND CORI COR CCMPI CCMP   d,value / d,src
;   CSKIPEQ CSKIPNE CSKIPLO CSKIPHS CSKIPMI CSKIPPL CSKIPHI CSKIPLS
;
; Addresses (CJUMP, CCALL) are 22-bit physical SRAM byte addresses, even.

        IFNDEF  COPPER_INC
        DEFINE  COPPER_INC

; Operands: the ALU's source numbers (CR0-CR7 0-7, CX 8, CY 9); CF the flags
CR0     equ     0
CR1     equ     1
CR2     equ     2
CR3     equ     3
CR4     equ     4
CR5     equ     5
CR6     equ     6
CR7     equ     7
CX      equ     8
CY      equ     9
CF      equ     16

; Fields
COP_P           equ     0x0080          ; WAIT, SKIP: pixel only
COP_B           equ     0x0040          ; WAIT: and the DMA engine idle
COP_FN_LD       equ     0
COP_FN_ST       equ     1
COP_FN_ADD      equ     2
COP_FN_SUB      equ     3
COP_FN_AND      equ     4
COP_FN_OR       equ     5
COP_FN_CMP      equ     6
COP_FN_FLAGS    equ     7
COP_SRC_VAL     equ     10
COP_CC_EQ       equ     0
COP_CC_NE       equ     1
COP_CC_LO       equ     2
COP_CC_HS       equ     3
COP_CC_MI       equ     4
COP_CC_PL       equ     5
COP_CC_HI       equ     6
COP_CC_LS       equ     7

; ---------------------------------------------------------------- MOVE
        MACRO   CMOVE reg?, value?
        ASSERT  (reg?) >= 0 && (reg?) < 0x0F0
        dw      ((reg?) << 8) | ((value?) & 0xFF)
        ENDM

        MACRO   CMOVEF reg?, value?
        ASSERT  (reg?) >= 0 && (reg?) < 0x400
        dw      0xFC00 | ((reg?) >> 8)
        dw      (((reg?) & 0xFF) << 8) | ((value?) & 0xFF)
        ENDM

        MACRO   CMOVEB reg?, value?
        IF      (reg?) < 0x0F0
        CMOVE   reg?, value?
        ELSE
        CMOVEF  reg?, value?
        ENDIF
        ENDM

        MACRO   CMOVEN reg?, value?, n?
        ASSERT  (n?) >= 1 && (n?) <= 4
        CMOVEB  (reg?), (value?)
        IF      (n?) >= 2
        CMOVEB  (reg?) + 1, (value?) >> 8
        ENDIF
        IF      (n?) >= 3
        CMOVEB  (reg?) + 2, (value?) >> 16
        ENDIF
        IF      (n?) >= 4
        CMOVEB  (reg?) + 3, (value?) >> 24
        ENDIF
        ENDM

        MACRO   CMOVEW reg?, value?
        CMOVEN  reg?, value?, 2
        ENDM

        MACRO   CMOVEA reg?, value?
        CMOVEN  reg?, value?, 3
        ENDM

        MACRO   CMOVEL reg?, value?
        CMOVEN  reg?, value?, 4
        ENDM

; ---------------------------------------------------------------- WAIT, SKIP
        MACRO   COPPOS code?, flags?, line?, pixel?
        ASSERT  (line?) >= 0 && (line?) < 1024 && (pixel?) >= 0 && (pixel?) < 1024
        dw      ((code?) << 8) | (flags?) | (((line?) >> 8) << 2) | ((pixel?) >> 8)
        dw      (((line?) & 0xFF) << 8) | ((pixel?) & 0xFF)
        ENDM

        MACRO   CWAIT line?, pixel?
        COPPOS  0xF0, 0, line?, pixel?
        ENDM

        MACRO   CWAITP pixel?
        COPPOS  0xF0, COP_P, 0, pixel?
        ENDM

        MACRO   CWAITB line?, pixel?
        COPPOS  0xF0, COP_B, line?, pixel?
        ENDM

        MACRO   CSKIP line?, pixel?
        COPPOS  0xF1, 0, line?, pixel?
        ENDM

        MACRO   CSKIPP pixel?
        COPPOS  0xF1, COP_P, 0, pixel?
        ENDM

; ---------------------------------------------------------------- JUMP, STOP, CALL, RET
        MACRO   CJUMP address?
        ASSERT  ((address?) & 1) == 0
        dw      0xF200 | (((address?) >> 16) & 0x3F)
        dw      (address?) & 0xFFFE
        ENDM

        MACRO   CSTOP
        dw      0xF300
        ENDM

        MACRO   CCALL address?
        ASSERT  ((address?) & 1) == 0
        dw      0xFB00 | (((address?) >> 16) & 0x3F)
        dw      (address?) & 0xFFFE
        ENDM

        MACRO   CRET
        dw      0xFB80
        ENDM

; ---------------------------------------------------------------- MOVR
        MACRO   CMOVX value?
        dw      0xF400 | ((value?) & 0xFF)
        ENDM

        MACRO   CMOVXP value?
        dw      0xF500 | ((value?) & 0xFF)
        ENDM

        MACRO   CMOVR reg?, src?
        ASSERT  (reg?) >= 0 && (reg?) < 0x100 && ((src?) == CX || (src?) == CY)
        dw      (0xF600 + ((((src?) == CY) & 1) << 8)) | (reg?)
        ENDM

        MACRO   CMOVXR src?
        ASSERT  (src?) == CX || (src?) == CY
        dw      0xF800 | (((src?) == CX) & 1)
        ENDM

        MACRO   CMOVXRP src?
        ASSERT  (src?) == CX || (src?) == CY
        dw      0xF802 | (((src?) == CX) & 1)
        ENDM

; ---------------------------------------------------------------- ALU
; COPALU fn, d (CX or CY), source; COPALUI fn, d, value
        MACRO   COPALU fn?, d?, src?
        ASSERT  ((d?) == CX || (d?) == CY) && (src?) >= 0 && (src?) <= CY
        dw      0xF900 | ((fn?) << 5) | ((((d?) == CY) & 1) << 4) | (src?)
        ENDM

        MACRO   COPALUI fn?, d?, value?
        ASSERT  (d?) == CX || (d?) == CY
        dw      0xF900 | ((fn?) << 5) | ((((d?) == CY) & 1) << 4) | COP_SRC_VAL
        dw      (value?) & 0xFF
        ENDM

        MACRO   CLDI d?, value?
        IF      (d?) == CF
        dw      0xF900 | (COP_FN_FLAGS << 5) | COP_SRC_VAL
        dw      (value?) & 0x07
        ELSE
        COPALUI COP_FN_LD, d?, value?
        ENDIF
        ENDM

        MACRO   CLD d?, src?
        IF      (d?) == CF
        ASSERT  (src?) >= 0 && (src?) <= CY
        dw      0xF900 | (COP_FN_FLAGS << 5) | (src?)
        ELSE
        COPALU  COP_FN_LD, d?, src?
        ENDIF
        ENDM

        MACRO   CST rn?, d?
        ASSERT  (rn?) >= CR0 && (rn?) <= CR7
        IF      (d?) == CF
        dw      0xF900 | (COP_FN_FLAGS << 5) | 0x10 | (rn?)
        ELSE
        COPALU  COP_FN_ST, d?, rn?
        ENDIF
        ENDM

        MACRO   CADDI d?, value?
        COPALUI COP_FN_ADD, d?, value?
        ENDM
        MACRO   CADD d?, src?
        COPALU  COP_FN_ADD, d?, src?
        ENDM
        MACRO   CSUBI d?, value?
        COPALUI COP_FN_SUB, d?, value?
        ENDM
        MACRO   CSUB d?, src?
        COPALU  COP_FN_SUB, d?, src?
        ENDM
        MACRO   CANDI d?, value?
        COPALUI COP_FN_AND, d?, value?
        ENDM
        MACRO   CAND d?, src?
        COPALU  COP_FN_AND, d?, src?
        ENDM
        MACRO   CORI d?, value?
        COPALUI COP_FN_OR, d?, value?
        ENDM
        MACRO   COR d?, src?
        COPALU  COP_FN_OR, d?, src?
        ENDM
        MACRO   CCMPI d?, value?
        COPALUI COP_FN_CMP, d?, value?
        ENDM
        MACRO   CCMP d?, src?
        COPALU  COP_FN_CMP, d?, src?
        ENDM

; ---------------------------------------------------------------- SKIPC
        MACRO   CSKIPEQ
        dw      0xFA00 | COP_CC_EQ
        ENDM
        MACRO   CSKIPNE
        dw      0xFA00 | COP_CC_NE
        ENDM
        MACRO   CSKIPLO
        dw      0xFA00 | COP_CC_LO
        ENDM
        MACRO   CSKIPHS
        dw      0xFA00 | COP_CC_HS
        ENDM
        MACRO   CSKIPMI
        dw      0xFA00 | COP_CC_MI
        ENDM
        MACRO   CSKIPPL
        dw      0xFA00 | COP_CC_PL
        ENDM
        MACRO   CSKIPHI
        dw      0xFA00 | COP_CC_HI
        ENDM
        MACRO   CSKIPLS
        dw      0xFA00 | COP_CC_LS
        ENDM

        ENDIF
