# Chapter 7: The USB Serial Link and Debugging

## Introduction

The **USB serial link** connects the computer to a PC through a small FT232H USB module on the board's accelerator header. It carries the console (text in and out), program uploads and the debugger, and the boot ROM turns it on first thing. The PC can also use it to stop, reset or type on the computer, even when the program has crashed.

This chapter covers:

- how the link works;
- turning it on, and taking it over from the boot ROM's console;
- sending and receiving bytes, one at a time and in blocks with `OTIR` and `INIR`;
- flow control, and what happens when nobody is listening on the PC;
- serial interrupts, with an interrupt-driven console;
- the commands the PC can send: BREAK, RESET, UPLOAD and KEY;
- uploading programs from the PC;
- debugging on the board from VS Code, and over MCP;
- a summary of the registers.

You should know how to reach the registers through ports (Chapter 1, "The Hardware Registers"). The section on serial interrupts uses Chapter 2.

### Conventions in this chapter

- Examples are Z80 assembly language for sjasmplus and start with `include "hw.inc"`.
- The serial registers are in the **system page**: port = register × 256 + `0x00`, so `LD BC,SERSTAT1_P` then `IN A,(C)`. SERDATA is also port `0x53` whatever the high byte, so `IN A,(0x53)` and `OUT (0x53),A` reach it directly; `hw.inc` calls it `SERDATA_PORT`.
- The complete examples are in `examples/serial/`, loaded at `0x8000`. They talk to the PC while the boot ROM's console keeps the screen.
- On the PC, the link is the FT232H's serial port: `COM3` on Windows, `/dev/ttyUSB1` on Linux, or whatever name it is given.

---

## How the Link Works

On the PC, the link is an ordinary serial port, so any terminal program can use it. Underneath it is not a serial line at all: the FT232H passes bytes to the FPGA eight bits at a time, through a FIFO interface. The baud rate set on the PC is ignored.

```
      PC                   FT232H module                     FPGA
 +-----------+   USB   +----------------+   8-bit FIFO   +-----------------------+
 | terminal, |<------->| 1 KB buffer    |<-------------->| command decoder       |
 | rlink.py  |         | each way       |   D7-D0        |          |            |
 | or the    |         |                |   RXF# RD#     | receive FIFO, 2 KB    |---> SERDATA (read)
 | bridge    |         |                |   TXE# WR#     | transmit FIFO, 2 KB   |<--- SERDATA (write)
 +-----------+         +----------------+   SIWU#        +-----------------------+

                  Figure 7-1: The USB Serial Link
```

Each direction has a 2 KB FIFO in the FPGA and another 1 KB in the FT232H. The hardware moves bytes between them by itself; a program only reads and writes the FIFOs, through one register, SERDATA. The Z80 never waits for the link: it reads how many bytes are waiting, or how much room there is, and moves that many.

Between the FT232H and the receive FIFO, the **command decoder** takes out the PC's control commands (BREAK, RESET, UPLOAD, KEY) and its escapes, so a program sees only the data ("Commands from the PC").

---

## Turning the Link On

SERCON (register `0x50`, port `0x5000`) controls the link:

**Table 7-1: SERCON Bits**

| Bits | Name | Meaning |
|------|------|---------|
| 7–6 | – | Read 0 |
| 5 | TXFLUSH | Write 1: empty the transmit FIFO. Reads 0 |
| 4 | RXFLUSH | Write 1: empty the receive FIFO. Reads 0 |
| 3 | TXDROP | 1: when the transmit FIFO is full, drop the oldest byte to make room ("When nobody is listening") |
| 2 | CTLLOCK | 1: keep RESET and UPLOAD working even with CTLEN 0. Once set, software cannot clear it; a reset does |
| 1 | CTLEN | 1: recognise commands from the PC. On after reset |
| 0 | EN | 1: the link moves data. While EN is 0, nothing is sent or received, and bytes written are thrown away |

The boot ROM writes SERCON at start-up with EN, CTLEN and TXDROP set, so the link is on when a program starts, and the boot ROM never waits for a PC that isn't there. A program that writes SERCON itself writes it in full:

```asm
        ld      bc,SERCON_P
        ld      a,SERCON_EN_M|SERCON_CTLEN_M|SERCON_TXDROP_M    ; 0x0B: bits 3, 1 and 0
        out     (c),a
```

A reset does not disturb the FT232H or the PC's port, so a terminal stays connected while the computer restarts. Bytes the PC sends meanwhile wait in the FT232H until the boot ROM turns the link on again.

### Taking the link from the console

The boot ROM's console prints on the screen **and** on the link, and reads keys from the keyboards **and** from the link. A program that talks to the PC itself first turns the console's link side off, with the ROM call CONMODE (`RST 28h` function `0x0E`):

**Table 7-2: CONMODE Bits**

| Bits | Meaning |
|------|---------|
| 7–4 | 0 (on a call, A = `0x80` only reads the mode) |
| 3 | Keys from the link |
| 2 | Keys from the keyboards |
| 1 | Print on the link |
| 0 | Print on the screen |

All four are set when a program starts. Mode `0x05` keeps the screen and the keyboards and gives the link to the program; `PUTS`, `PUTC` and `POLLC` then leave the link alone. CONMODE returns the old mode in A, so the program can put it back before it ends:

```asm
        ld      a,0x05                  ; the screen and the keyboards only
        rst     0x28
        db      0x0E                    ; CONMODE: A = the old mode
        ld      (oldmode),a
        ...
        ld      a,(oldmode)             ; as it was
        rst     0x28
        db      0x0E
```

### On the PC

Anything that opens the port can talk to the machine:

- **`tools/rlink.py term`**: a terminal. `python tools/rlink.py -p COM3 term` shows what the machine sends and sends what is typed. Ctrl-] then `r` sends RESET, `b` BREAK, `u` uploads a file, `q` quits.
- **The VS Code extension's console**: the command **retro-z80: Console** opens a terminal joined to the bridge ("Debugging from VS Code"). It is the way in while the bridge has the port, since only one program can open it.
- **Any terminal program** (PuTTY, picocom, screen), in raw mode. It sends bytes as they are, which is fine for ASCII; see "Escapes" below for what else to watch.

---

## Sending Bytes

To send a byte, write it to SERDATA. It goes into the transmit FIFO and the hardware sends it on. **SERSTAT0** (TXSPACE) says how much room there is in the FIFO: 0 to 255, where 255 means 255 or more. A byte written with no room is lost, and SERIRQ.TXOVF is set, unless SERCON.TXDROP is set.

```asm
; Send A to the PC, waiting for room. A kept; B, C, E changed.
putc:   ld      e,a
.wait:  ld      bc,SERSTAT0_P           ; TXSPACE: room in the transmit FIFO
        in      a,(c)
        or      a
        jr      z,.wait                 ; none yet
        ld      a,e
        out     (SERDATA_PORT),a        ; port 0x53, whatever the high byte
        ret
```

Short messages reach the PC at once. An FT232H normally holds a few bytes for up to 16 ms before passing them on; whenever the transmit FIFO empties, the FPGA tells it to send what it holds straight away.

### Sending a block with OTIR

Checking TXSPACE before every byte is slow. Read it once, and write that many bytes without checking. Because SERDATA answers on port `0x53` whatever the high byte, `OTIR`, which puts its count B on the high byte of the port, reaches it at every step, and TXSPACE never goes above 255, so it goes straight into B:

```asm
; Send DE bytes from HL, as many at a time as there is room for.
; A, B, C, D, E, H, L changed.
sendblk:
.more:  ld      bc,SERSTAT0_P           ; TXSPACE: 0-255 (255: 255 or more)
        in      a,(c)
        or      a
        jr      z,.more                 ; no room yet
        ld      b,a                     ; B = the room ...
        ld      a,d
        or      a
        jr      nz,.go                  ; ... 256 or more left: all of it
        ld      a,e
        cp      b
        jr      nc,.go
        ld      b,e                     ; ... but no more than are left
.go:    ld      a,e                     ; DE = DE - B
        sub     b
        ld      e,a
        jr      nc,.nc
        dec     d
.nc:    ld      c,SERDATA_PORT          ; port 0x53: OTIR puts B on A15-A8
        otir                            ; 21 T-states a byte
        ld      a,d
        or      e
        jr      nz,.more
        ret
```

Room never shrinks by itself (only the program fills the FIFO), so a block of TXSPACE bytes never overruns it.

---

## Receiving Bytes

Reading SERDATA takes the next byte from the receive FIFO. **SERSTAT1** (RXCOUNT) says how many are waiting: 0 to 255, where 255 means 255 or more. **Check RXCOUNT before reading SERDATA**: a read of an empty FIFO gives `0x00` and takes nothing, and that cannot be told from a received `0x00`.

```asm
; Wait for a byte from the PC: A = the byte. B, C changed.
getc:   ld      bc,SERSTAT1_P           ; RXCOUNT: bytes waiting
        in      a,(c)
        or      a
        jr      z,getc                  ; nothing yet: SERDATA would read 0x00
        in      a,(SERDATA_PORT)        ; take one
        ret
```

Every read of SERDATA takes a byte, whether through port `0x53`, port `0x5300` or the register page. Don't use instructions that read and then write (`INC (HL)`, `SET b,(HL)`) on it in the register page.

### Receiving a block with INIR

As with sending, read RXCOUNT once and take that many with `INIR`. Bytes only arrive, so the count never goes down while the block is read, and `INIR` never reads an empty FIFO:

```asm
        ld      bc,SERSTAT1_P           ; RXCOUNT
        in      a,(c)
        or      a
        jr      z,.none
        ld      b,a                     ; the count, 1-255
        ld      c,SERDATA_PORT
        inir                            ; to (HL) and up, 21 T-states a byte
```

**Table 7-3: Block Transfer Speeds**

| Method | T-states a byte | At 20 MHz | At 3.57 MHz |
|--------|-----------------|-----------|-------------|
| `INIR` / `OTIR` | 21 | 0.95 MB/s | 170 KB/s |
| Unrolled `INI` / `OUTI` | 16 | 1.25 MB/s | 223 KB/s |
| A loop that tests each byte, as `getc` | about 40–50 | 0.4–0.5 MB/s | 71–89 KB/s |

These are the Z80's own limits. The link must also carry the bytes: Example 7-2 measures it.

### Example 7-1: Echo in capitals

The program takes the link from the console, then sends back in capitals every byte the PC sends, and shows it on the screen too. Esc from the PC ends it, and the console gets the link back.

```asm
; Example 7-1: sending and receiving bytes. The program takes the link
; from the boot ROM's console (CONMODE: the screen and the keyboards only),
; then sends back in capitals every byte the PC sends, and shows it on the
; screen too. Esc from the PC ends it.

        device  zxspectrum48            ; sjasmplus writes source lines (--sld) only inside a DEVICE
        org     0x8000

        include "hw.inc"

CONMODE equ     0x0E                    ; RST 28h functions
PUTDEC  equ     0x08
ESC     equ     27

start:  ld      hl,title
        rst     0x18                    ; PUTS, on the screen and the link
        ld      a,0x05                  ; the console: print on the screen (bit 0),
        rst     0x28                    ; keys from the keyboards (bit 2); the link
        db      CONMODE                 ; is the program's
        ld      (oldmode),a

        ld      hl,hello                ; straight to the PC
        call    sputs
.loop:  call    getc                    ; a byte from the PC
        cp      ESC
        jr      z,.end
        cp      'a'                     ; small letters to capitals
        jr      c,.put
        cp      'z'+1
        jr      nc,.put
        sub     'a'-'A'
.put:   call    putc                    ; back to the PC ...
        rst     0x08                    ; ... and on the screen (PUTC: the screen only now)
        ld      hl,(count)
        inc     hl
        ld      (count),hl
        jr      .loop

.end:   ld      hl,bye
        call    sputs
        ld      a,(oldmode)             ; the console as it was
        rst     0x28
        db      CONMODE
        ld      hl,s_count
        rst     0x18
        ld      hl,(count)
        rst     0x28
        db      PUTDEC
        ld      hl,s_bytes
        rst     0x18
        ret

; putc and getc as above

; Send the string at HL, ending with 0x00.
sputs:  ld      a,(hl)
        or      a
        ret     z
        call    putc
        inc     hl
        jr      sputs

oldmode: db     0
count:  dw      0
title:  db      13, 10, "Echoing the link in capitals. Esc from the PC ends it.", 13, 10, 0
hello:  db      "Type something; it comes back in capitals.", 13, 10, 0
bye:    db      13, 10, "Bye.", 13, 10, 0
s_count: db     13, 10, "Echoed ", 0
s_bytes: db     " bytes.", 13, 10, 0
```

Typing `hello, z80!` and Enter in a terminal on the PC gives back `HELLO, Z80!`, on the PC and on the board's screen. After Esc the board prints "Echoed 12 bytes." (the Enter is the twelfth).

### Example 7-2: Sending 16 KB with OTIR

The program fills 16 KB with 256 lines of text, sends them with `sendblk`, and times it with TIME (Chapter 2). The whole program is `examples/serial/blast.asm`:

```asm
        ld      de,BUF                  ; 256 lines of 64 bytes
.fill:  ld      hl,line
        ld      bc,64
        ldir
        ld      a,d
        cp      high (BUF+LEN)
        jr      nz,.fill

        call    time
        push    hl
        ld      hl,BUF
        ld      de,LEN
        call    sendblk
        call    time
        pop     de
        or      a
        sbc     hl,de                   ; microseconds, under 65 ms
```

On the board, with the VS Code bridge reading the port, the 16,384 bytes took **45,366 µs**, about 360 KB/s, and all 256 lines arrived. That is well below what `OTIR` can do: the FIFO filled, and the program waited for room. So here the PC's end sets the pace, not the Z80. Where exactly the limit is (the FT232H's driver, or the program reading on the PC) is still to be measured, in both directions.

---

## Flow Control

The link has flow control in hardware, both ways, so there is no XON/XOFF or RTS/CTS to set up.

- **From the PC.** The FPGA reads from the FT232H only while the receive FIFO has room. When it is full, the FT232H's buffer fills, and USB then holds the PC back. Nothing is lost, however fast the PC sends and however slowly the program reads.
- **To the PC.** The FPGA writes to the FT232H only when it has room. If the program on the PC stops reading, the FT232H's buffer fills, then the transmit FIFO; TXSPACE drops to 0, and `putc` waits.

### When nobody is listening

If no program on the PC has the port open, nothing drains the transmit FIFO. A program that only prints messages should not stop because of that. Two choices:

- **Treat a full FIFO as "nobody listening".** If TXSPACE stays at 0 for a long time, stop sending.
- **Set SERCON.TXDROP**, as the boot ROM does. When the FIFO is full, each new byte pushes out the oldest, so writes never wait, and the PC sees the latest output when it opens the port. **SERDROP** counts the bytes dropped since it was last read, up to 255; reading it sets it back to 0.

Without TXDROP, a byte written to a full FIFO is lost, and the sticky flag SERIRQ.TXOVF says so.

---

## Serial Interrupts

Polling suits a monitor or a simple tool, but a program with other work can let the link interrupt it. The link has four flags, in **SERIRQ**:

**Table 7-4: SERIRQ Bits**

| Bits | Name | Set when | Cleared |
|------|------|----------|---------|
| 7–4 | – | Read 0 | – |
| 3 | TXOVF | A byte was written to a full transmit FIFO, and lost | Sticky: write 1 |
| 2 | TXREADY | At least TXLEVEL bytes of room are free | By itself, when the room drops below TXLEVEL |
| 1 | RXTIMEOUT | At least one byte has waited for SERTIME without reaching RXLEVEL, and no byte has arrived or been read meanwhile | Sticky: write 1 |
| 0 | RXREADY | At least RXLEVEL bytes are waiting | By itself, when the count drops below RXLEVEL |

The levels are in **SERLEVEL**, as codes:

**Table 7-5: SERLEVEL Bits**

| Bits | Name | Meaning |
|------|------|---------|
| 7–4 | RXLEVEL | RXREADY's level: 0 off; n = 1–12 means 2^(n−1) bytes waiting (1, 2, 4 … 2,048); 13–15 act as 12 |
| 3–0 | TXLEVEL | TXREADY's level, coded the same, in bytes of room |

A level of 1 byte each way is code 1 in both fields, `0x11`:

```asm
        ld      bc,SERLEVEL_P
        ld      a,(1<<SERLEVEL_RXLEVEL_B)|(1<<SERLEVEL_TXLEVEL_B)  ; 0x11
        out     (c),a
```

**SERTIME** is the timeout in steps of 16 µs (1–255: 16 µs to about 4 ms); 0 turns RXTIMEOUT off.

RXREADY and TXREADY follow the FIFOs: they stay set as long as the condition holds, and writing them does nothing. So a handler must make the condition go away, by reading the bytes or by turning the enable off. The timeout catches the end of a message shorter than RXLEVEL, so a large RXLEVEL can be used for bulk data with no polling for the last few bytes.

**Table 7-6: Interrupt Settings for Common Uses**

| Use | Settings |
|-----|----------|
| A console | RXLEVEL code 1 (1 byte): an interrupt for every key |
| Bulk receive | RXLEVEL code 9 (256 bytes) and SERTIME 7 (about 100 µs): one `INIR` an interrupt, and the timeout catches the tail |
| Sending | TXREADY enabled only while there is something to send, or it interrupts for ever |
| Waiting for the FIFO to drain | TXLEVEL code 12 (2,048 bytes of room): TXREADY means the transmit FIFO is empty |

**SERIRQEN** has the same layout. The link asks for an interrupt while any flag is set in both SERIRQ and SERIRQEN. It is source **SERIAL**, 15, in the interrupt controller: INTENA byte 2, bit 1 (`INTR_SERIAL`, `INTB_SERIAL`), IM 2 table entry 15.

To take serial interrupts:

1. Put the handler's address in the IM 2 table, at entry 15 (`INT_SERIAL`).
2. Set the levels in SERLEVEL, and SERTIME if RXTIMEOUT is used.
3. Set the flags wanted in SERIRQEN.
4. Enable SERIAL in INTENA, set INTCON.MASTER, and `EI`.

In the handler:

1. Read every byte waiting, and send what there is room for.
2. Turn TXREADY off in SERIRQEN when there is nothing more to send.
3. Clear RXTIMEOUT and TXOVF by writing 1 to them, if they are used.
4. `EI`, `RETI`.

### Example 7-3: An interrupt-driven console

This driver keeps a 256-byte ring buffer each way. The handler fills the receive ring and empties the transmit ring; the program calls `sgetc` and `sputc`, which never touch the FIFOs. The rings start on 256-byte boundaries, so an 8-bit index wraps by itself. Each index is written by only one side: the handler moves `rx_head` and `tx_tail`, the program `rx_tail` and `tx_head`. The steps are those above: the IM 2 table entry, SERLEVEL `0x11` (both levels 1 byte), SERIRQEN with RXREADY, INTENA and MASTER, then `EI`. The main program is Example 7-1's echo, with `sgetc` and `sputc` in place of `getc` and `putc`; the whole program is `examples/serial/serint.asm`.

```asm
RXBUF   equ     0x9000                  ; 256 bytes each, on 256-byte boundaries,
TXBUF   equ     0x9100                  ; so an 8-bit index wraps by itself

        ; the set-up, after the IM 2 table (entry INT_SERIAL = serint)
        ld      bc,SERLEVEL_P           ; RXLEVEL 1 byte, TXLEVEL 1 byte (codes 1)
        ld      a,(1<<SERLEVEL_RXLEVEL_B)|(1<<SERLEVEL_TXLEVEL_B)
        out     (c),a
        ld      bc,SERIRQEN_P           ; RXREADY only: TXREADY when there is something to send
        ld      a,SERIRQEN_RXREADY_M
        out     (c),a
        ld      bc,INTENA0_P+(INTR_SERIAL<<8)
        ld      a,INTENA_SETCLR_M|(1<<INTB_SERIAL)
        out     (c),a
        ld      bc,INTCON_P
        ld      a,INTCON_MASTER_M
        out     (c),a
        ei

; SERIAL: take every byte waiting, send what the FIFO has room for.
serint: push    af
        push    bc
        push    hl
.rx:    ld      a,(rx_head)
        ld      l,a
        inc     a                       ; the next place
        ld      h,a
        ld      a,(rx_tail)
        cp      h
        jr      z,.full                 ; ring full: leave the rest in the FIFO
        ld      bc,SERSTAT1_P           ; RXCOUNT
        in      a,(c)
        or      a
        jr      z,.tx                   ; all taken: RXREADY goes off by itself
        ld      a,h
        ld      (rx_head),a             ; (the byte is stored before sgetc can look:
        ld      h,high RXBUF            ;  interrupts are off in here)
        in      a,(SERDATA_PORT)
        ld      (hl),a
        jr      .rx
.full:  ld      bc,SERIRQEN_P           ; RXREADY off until sgetc makes room
        in      a,(c)
        and     ~SERIRQEN_RXREADY_M
        out     (c),a
.tx:    ld      a,(tx_tail)
        ld      l,a
        ld      h,high TXBUF
.txl:   ld      a,(tx_head)
        cp      l
        jr      z,.txoff                ; the ring is empty
        ld      bc,SERSTAT0_P           ; TXSPACE
        in      a,(c)
        or      a
        jr      z,.txend                ; the FIFO is full: TXREADY brings us back
        ld      a,(hl)
        out     (SERDATA_PORT),a
        inc     l
        jr      .txl
.txoff: ld      bc,SERIRQEN_P           ; nothing to send: TXREADY off, or it never stops
        in      a,(c)
        and     ~SERIRQEN_TXREADY_M
        out     (c),a
.txend: ld      a,l
        ld      (tx_tail),a
        pop     hl
        pop     bc
        pop     af
        ei
        reti

; Queue A to send, waiting while the ring is full. Registers kept.
sputc:  push    af
        push    bc
        push    hl
        ld      c,a
        ld      a,(tx_head)
        ld      l,a
        ld      h,high TXBUF
        ld      (hl),c
        inc     a
        ld      b,a
.full:  ld      a,(tx_tail)
        cp      b
        jr      z,.full                 ; full: wait for the handler
        ld      a,b
        ld      (tx_head),a
        di                              ; TXREADY on, after tx_head has moved
        ld      bc,SERIRQEN_P           ; (SERIRQEN's other bits kept)
        in      a,(c)
        or      SERIRQEN_TXREADY_M
        out     (c),a
        ei
        pop     hl
        pop     bc
        pop     af
        ret

; A = the next byte received, with NZ; Z if there is none. B, C, H, L changed.
sgetc:  ld      a,(rx_head)
        ld      b,a
        ld      a,(rx_tail)
        cp      b
        ret     z                       ; empty
        ld      l,a
        ld      h,high RXBUF
        inc     a
        ld      (rx_tail),a             ; room again: RXREADY back on
        di                              ; (SERIRQEN's other bits kept)
        ld      bc,SERIRQEN_P
        in      a,(c)
        or      SERIRQEN_RXREADY_M
        out     (c),a
        ei
        ld      a,(hl)
        or      0xFF                    ; NZ ...
        ld      a,(hl)                  ; ... with the byte (LD keeps the flags)
        ret

rx_head: db     0                       ; written by the handler
rx_tail: db     0                       ; written by the program
tx_head: db     0                       ; written by the program
tx_tail: db     0                       ; written by the handler
```

**When the receive ring is full** the handler stops taking bytes: it leaves them in the FIFO and turns RXREADY off. The link's flow control then holds the PC back, and nothing is lost. `sgetc` turns RXREADY on again as soon as it has made room. Throwing bytes away instead would be simpler, but a burst bigger than the ring would then lose its end. On the board, 40 lines sent at once (1,160 bytes, over four times the ring) all came back, while the program printed each character on the screen as well.

The handler and the program each change only their own bit of SERIRQEN, reading it and writing it back with interrupts off, so neither undoes the other. The program turns TXREADY on only after it has moved `tx_head`, so the handler always finds the new byte. Before it ends, the program waits for the transmit ring to empty, so that its last message is not cut off.

---

## Commands from the PC

The PC can control the computer through the link, even when the Z80 has crashed with interrupts off. The FT232H has no separate break signal, so the commands travel in the data, and the FPGA's command decoder takes them out. Two byte values are kept for this, SLIP-style:

**Table 7-7: Bytes from the PC**

| Bytes from the PC | Reach the FIFO as | Meaning |
|-------------------|-------------------|---------|
| `C0 c ~c` | Nothing | A control command c, followed by its inverse |
| `C0 04 b ~b` | Nothing | KEY: the byte b to the PS/2 keyboard |
| `DB DC` | `C0` | An escaped data byte |
| `DB DD` | `DB` | An escaped data byte |
| Any other byte | Itself, at once | Data |

**Table 7-8: Control Commands**

| c | ~c | Command | Effect |
|---|----|---------|--------|
| `0x01` | `0xFE` | BREAK | An NMI, with NMISTAT.USB set: the monitor stops the program. Only while NMICON.USBEN is set |
| `0x02` | `0xFD` | RESET | Resets the computer, with RESETWHY.USB set |
| `0x03` | `0xFC` | UPLOAD | Resets the computer with RESETWHY.UPLOAD set, so the boot ROM waits for a program over the link |
| `0x04` | – | KEY | `C0 04 b ~b`: b is taken as if the PS/2 keyboard had sent it |

- The commands and escapes are handled in hardware, so they work when the Z80 has crashed, with interrupts off or in `HALT`.
- A program sees only the data, in order. No data byte waits for the next one: the PC always sends a command or an escape whole.
- A broken command (a wrong inverse, an unknown code) is dropped. A `C0` always starts a command afresh.
- The decoder works while CTLEN is set (it is after reset), or, for RESET and UPLOAD alone, while CTLLOCK is set.

So RESET is the three bytes `C0 02 FD`. Pressing and letting go of the A key, whose PS/2 make code is `0x1C`, is two KEYs for the press and up, and three bytes each:

```
C0 04 1C E3                   KEY 0x1C: A goes down (0xE3 is 0x1C inverted)
C0 04 F0 0F  C0 04 1C E3      KEY 0xF0, KEY 0x1C: A comes up
```

### Escapes

Because `C0` and `DB` are kept, the PC escapes them in everything else it sends: `C0` as `DB DC`, `DB` as `DB DD`. The tools do this for you (`rlink.py`, the bridge and its console). Random data grows by about 0.8%.

A plain terminal program does not escape. That does not matter for ASCII, which never contains `C0` or `DB`. In UTF-8, `C0` never appears, but `DB` starts some characters (U+06C0–U+06FF), which would be decoded wrongly. For binary data or other text, use `rlink.py term` or the bridge's console.

### Sending a command from the PC

```
python tools/rlink.py -p COM3 reset             RESET
python tools/rlink.py -p COM3 break             BREAK
python tools/rlink.py -p COM3 uploadmode        UPLOAD: the loader waits
```

Or from Python, for a port no other program has open:

```python
import serial                                   # pyserial
with serial.Serial("COM3") as port:
    port.write(bytes([0xC0, 0x02, 0xFD]))       # RESET
```

### Handling BREAK

BREAK arrives as the Z80's NMI, the same as the Multiface (NMI) button. Normally the boot ROM's NMI handler takes it, stops the program and enters the monitor, which prints where it stopped (`NMI (USB) at 807B`); the monitor's `G` carries on. This is how the debugger stops a running program. A program can take the NMI itself, as Chapter 2 ("The Nonmaskable Interrupt") explains: NMISTAT says which it was, bit 0 (BUTTON) for the button and bit 1 (USB, `NMISTAT_USB_M`) for BREAK. Clearing NMICON.USBEN turns BREAK off.

### Handling RESET and UPLOAD

RESET and UPLOAD reset the computer like the reset button. RESETWHY tells the start-up code which it was: `RESETWHY_USB_M` for RESET, `RESETWHY_UPLOAD_M` for UPLOAD. After UPLOAD the boot ROM's loader waits for a program ("Uploading Programs"); after RESET it starts as usual, and says "Reset: USB." on the screen.

### KEY: typing on the board from the PC

KEY puts a byte into the PS/2 keyboard's receiver as if a keyboard had sent it. The PC sends a key's make code as it goes down and its break code (`F0`, after `E0` for an extended key) as it comes up, one KEY a byte. So the boot ROM, programs that read the PS/2 keyboard, and Spectrum-style programs that read port `0xFE` through the key mapper all see the keys, whether a debugger is attached or not. Programs cannot tell them from a real keyboard. VS Code's Show Screen tab and the MCP tools `key_down`, `key_up` and `type_text` send them ("Debugging from VS Code").

### Turning commands off

Some programs need every byte the PC sends unchanged: their own protocol, say. Clearing SERCON.CTLEN turns the decoder off, and BREAK and KEY with it; `C0` and `DB` then reach the FIFO as they are, and the PC must not escape. To keep a way to reset the machine from the PC, set CTLLOCK first: RESET and UPLOAD then still work.

```asm
        ld      bc,SERCON_P
        ld      a,SERCON_EN_M|SERCON_CTLLOCK_M|SERCON_TXDROP_M  ; CTLEN off, CTLLOCK on
        out     (c),a
```

---

## Uploading Programs

Programs reach the board over the link. The PC sends UPLOAD; the boot ROM resets, says `LOAD Z80 1` on the link, and its loader takes the program in checked frames, then starts it. `tools/rlink.py` does all of this:

```
sjasmplus --raw=build/echo.bin echo.asm
python tools/rlink.py image build/echo.bin -o build/echo.rimg --machine z80 --load 8000
python tools/rlink.py -p COM3 upload build/echo.rimg --term
```

- `image` wraps the binary in a 32-byte header: the machine, the load and entry addresses, the size and two CRCs. The same file goes on the SD card.
- `upload` sends UPLOAD, waits for the loader, checks the header against the machine, sends the program and starts it. `--term` stays on as a terminal afterwards; `--no-run` leaves the program loaded and stopped at the monitor.
- `upload BIN --load ADDR` sends a raw binary, making the header on the fly.
- The monitor's `U` command waits for an upload too; `rlink.py upload --no-reset` then skips the reset.

A program starts in the **program map** (Chapter 1, "Programs"), with the console on, the link on and interrupts off. It ends by returning, or with `RST 28h` function EXIT, and the monitor says "Program ended."

---

## Debugging from VS Code

The VS Code extension in `tools/vscode/` debugs programs on the board, over the link: upload and stop at the entry, source breakpoints, watchpoints, stepping, the registers, memory, the MMU windows and the disassembly. Its README says how to install it.

### The bridge

One program, the **bridge** (`tools/rz80_bridge.py`), owns the serial port. VS Code, the console terminal and Claude (over MCP) all talk to the board through it, at the same time. VS Code starts it the first time it is needed and leaves it running. Set the port once, in the setting **retroz80.bridge.serialPort** (`COM3`).

### A launch configuration

In `.vscode/launch.json`:

```json
{
  "type": "retro-z80",
  "request": "launch",
  "name": "Debug echo on the board",
  "program": "${workspaceFolder}/examples/serial/build/echo.rimg",
  "sld": "${workspaceFolder}/examples/serial/build/echo.sld",
  "stopOnEntry": true,
  "preLaunchTask": "build echo"
}
```

and the build task in `.vscode/tasks.json`:

```json
{
  "label": "build echo",
  "type": "retro-z80-build",
  "source": "examples/serial/echo.asm",
  "load": "8000",
  "includes": ["firmware/include"],
  "problemMatcher": "$sjasmplus"
}
```

The task runs sjasmplus with `--sld` (the symbol and source-line file the debugger needs) and `rlink.py image`. F5 builds, uploads and stops at the entry. `"request": "attach"` instead stops a program already running, where it is, with BREAK.

### What it does

**Table 7-9: What the Debugger Does on the Board**

| Feature | On the board |
|---------|--------------|
| Breakpoints | The board's debug unit has **4** hardware breakpoints, so they work in ROM too. A fifth is refused |
| Watchpoints | **2**, on memory or on ports, for reads, writes or both, over a power-of-two length. VS Code's data breakpoints, and the Board Watchpoints view |
| Stepping | Step in; step over and step out (the debugger uses a spare breakpoint for them, while a step needs it) |
| Registers | The main and alternate registers, I, R, IM, IFF, the flags spelled out |
| Memory | Z80 addresses, or physical ones with `P` (`P012000`) |
| MMU | Each window's read and write page |
| Debug console | A monitor command line (`D 8000 40`, `P 5600`) |
| Pause | BREAK: the program stops where it is |

The program's own `RST 30h` (the break call) stops it in the debugger too.

**While attached, the console is on the screen only.** The link carries only the debugger's frames. A program that prints through the ROM prints on the board's screen; one that writes SERDATA itself still can, and the bytes show in the debug console as the program's output. The examples in this chapter, which use the link themselves, are best run without the debugger, or detached after the launch.

### The Board Screen and keys

**retro-z80: Show Screen** shows the board's HDMI picture in a tab, through a USB HDMI capture device. Click the tab, and the keys pressed go to the board, through KEY, as a PS/2 keyboard's would. **retro-z80: Console** opens a terminal on the monitor's console while no debugger is attached.

### Claude, over MCP

The bridge also serves MCP, so Claude can drive the board as VS Code does, at the same time: `launch`, `attach`, `detach`, `run`, `pause`, `step`, breakpoints and watchpoints (from the same pool of 4 and 2), `get_registers`, `read_memory`, `monitor` (a monitor command line), `send_console` and `read_console` (the console, while not attached), `screen_capture` and `screen_record` (the Board Screen's picture), and `key_down`, `key_up` and `type_text`. The examples in this guide were all checked this way.

---

## Bulk Transfers with DMA

The DMA engine's **port 1** is meant to be this link: a channel copying from the receive FIFO to SRAM, or from SRAM to the transmit FIFO, paced by the FIFOs, while the Z80 does other work. It is not built yet. Until it is, move blocks with `INIR` and `OTIR`.

---

## Summary of Serial Registers

System page: port = register × 256 + `0x00`. SERDATA is also port `0x53` with any high byte.

**Table 7-10: Serial Registers**

| Register | Port | Name | Access | Function |
|----------|------|------|--------|----------|
| `0x50` | `0x5000` | SERCON | RW | TXFLUSH (5), RXFLUSH (4) write 1 to empty a FIFO; TXDROP (3) drop the oldest when full; CTLLOCK (2) keep RESET and UPLOAD (set only); CTLEN (1) recognise PC commands; EN (0) the link on |
| `0x51` | `0x5100` | SERSTAT0 | R | TXSPACE: room in the transmit FIFO, 0–255 (255: 255 or more) |
| `0x52` | `0x5200` | SERSTAT1 | R | RXCOUNT: bytes in the receive FIFO, 0–255 (255: 255 or more) |
| `0x53` | `0x5300`, `0x53` | SERDATA | RW | Read: takes a byte (`0x00` if empty: check RXCOUNT first). Write: sends a byte |
| `0x54` | `0x5400` | SERLEVEL | RW | RXLEVEL (7–4), TXLEVEL (3–0): 0 off, n = 2^(n−1) bytes |
| `0x55` | `0x5500` | SERTIME | RW | The receive timeout in steps of 16 µs; 0 off |
| `0x56` | `0x5600` | SERIRQ | R, W1C | TXOVF (3, W1C), TXREADY (2), RXTIMEOUT (1, W1C), RXREADY (0) |
| `0x57` | `0x5700` | SERIRQEN | RW | The interrupt enables, as SERIRQ |
| `0x5C` | `0x5C00` | SERDROP | R | Bytes dropped by TXDROP since the last read, up to 255; reading clears it |

SERSTAT0 and SERSTAT1 are two separate counts, each read live. SERDATA and SERDROP have side effects when read: the debugger's memory views read them as `0xFF` unless asked otherwise.

**Table 7-11: The Link at a Glance**

| Item | Value |
|------|-------|
| Interrupt | Source 15, SERIAL: INTENA byte 2, bit 1; IM 2 table entry 15 |
| Commands | `C0 01 FE` BREAK, `C0 02 FD` RESET, `C0 03 FC` UPLOAD, `C0 04 b ~b` KEY |
| Escapes | `C0` as `DB DC`, `DB` as `DB DD` |
| FIFOs | 2 KB each way in the FPGA, 1 KB each way in the FT232H |
| After reset | The link off, CTLEN on, the FIFOs empty; the boot ROM then sets EN, CTLEN and TXDROP |
| When a program starts | EN, CTLEN, TXDROP; CONMODE `0x0F` (the console on the screen and the link) |

### Equates in hw.inc

**Table 7-12: Serial Equates in hw.inc**

| Name | Meaning |
|------|---------|
| `SERCON_P` … `SERDROP_P` | The registers' ports |
| `SERDATA_PORT` | `0x53`: SERDATA with any high byte |
| `SERCON_EN_M`, `SERCON_CTLEN_M`, `SERCON_CTLLOCK_M`, `SERCON_TXDROP_M`, `SERCON_RXFLUSH_M`, `SERCON_TXFLUSH_M` | SERCON's bits |
| `SERLEVEL_RXLEVEL_B`, `SERLEVEL_TXLEVEL_B` | SERLEVEL's fields (4 and 0) |
| `SERIRQ_RXREADY_M` … `SERIRQ_TXOVF_M`, `SERIRQEN_RXREADY_M` … | The flags and their enables |
| `INT_SERIAL`, `INTR_SERIAL`, `INTB_SERIAL` | The interrupt source, its INTENA byte and bit |
| `NMISTAT_USB_M`, `NMICON_USBEN_M`, `RESETWHY_USB_M`, `RESETWHY_UPLOAD_M` | BREAK, RESET and UPLOAD seen by the program |
