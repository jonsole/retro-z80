# Chapter 9: Geometry Hardware

## Introduction

The **geometry unit** does a 3D engine's arithmetic. A Z80 has no multiply instruction, and a 3D picture is nothing but multiplies: turning each vertex of each object by two matrices, dividing by its depth to put it on the screen, and testing which way each face looks. In software that is about 2,300 T-states a vertex. The unit does a vertex in 0.2 µs, and the Z80's part is writing six bytes and reading four: about 170 T-states a vertex at best, 320 in a loop that keeps the depth too.

You give the unit a **camera** (where the eye is and which way it looks), an **object** (where it is and how it is turned), and a **view** (how far the screen is from the eye, and where its centre is). From then on, each vertex you write comes back as a point on the screen. Figure 9-1 shows the path a vertex takes.

```
   a vertex v          the object's          the camera's         the screen
   (x, y, z) in   ──►  matrix Mo and   ──►   matrix Mc and   ──►  sx = SCX + DX·X ÷ Z
   the model's         position P:           position C:          sy = SCY − DY·Y ÷ Z
   own units           Mo·v + P              Mc·(… − C)
                       (in the world)        (X, Y, Z: in front
                                             of the eye)

                     Figure 9-1: A Vertex's Path Through the Unit
```

The unit also multiplies the two matrices for you, tests a face's three screen points to say whether it faces the eye, and does a plain 16 × 16 multiply and a 32 ÷ 16 divide, so a program can use it as a calculator.

This chapter covers:

- the unit: its registers, the window onto its five banks, and how the numbers are written;
- a first program, step by step: the view, the camera, the object, a vertex;
- the combined matrix, and the unit as a matrix multiplier;
- turning an object, with a turning cube drawn on the screen;
- the near plane, and what to do with a vertex behind it;
- culling: deciding which objects are in view from their centres;
- which way a face looks, with a cube whose back faces are hidden;
- the inverse turn;
- multiply and divide;
- scaling, saturation, and writing the starting byte last;
- timing, measured on the board;
- what the unit cannot do, and a note for Amiga programmers;
- a summary of the registers.

You should have read Chapter 1 for the register page, which the examples use throughout, and Chapter 3 for the bitmap layer the examples draw on.

**The unit is on the KS3, and on the KS2 only in the build with it** (`fpga/ks2/build.sh --geom`), which has no blitter: the KS2 has no room for both. Without the unit its registers read `0xFF` and ignore writes. The lines in this chapter's examples are therefore drawn by the Z80; on a machine with both, the blitter's EDGES job (Chapter 6) would draw them.

---

## Conventions in This Chapter

- Examples are Z80 assembly language for sjasmplus and start with `include "hw.inc"`. Numbers are hexadecimal when they start with `0x`.
- **Registers are reached through the register page in window 7**, as Chapter 1's examples do: system register r is the byte at `0xE000 + r`, written and read with ordinary loads. The unit's registers are then at `0xE0A0`–`0xE0BF`. Each has a port too (Table 9-2), for `OUT (C),r`; the register page is used because a matrix is 24 bytes, which `LDIR` moves in one go, and a result is a word, which `LD HL,(nn)` reads in one go.
- The examples share these names, from `examples/geometry/screen.inc`:

```
SREG    equ     0xE000                  ; the system registers, in window 7
GEO     equ     SREG + GEOW0            ; the window of 12 words: 0xE0A0
GEO_V   equ     SREG + GEOVX            ; VX0, or RX0 when read: 0xE0B8
GEO_CTL equ     SREG + GEOCTL           ; 0xE0BE
GEO_ST  equ     SREG + GEOSTAT          ; 0xE0BF
```

- **Numbers are 16-bit words, low byte first.** A coordinate is a signed integer. A matrix entry is a signed **2.14** number: `0x4000` is 1.0, `0xC000` is −1.0, and the range is −2.0 to just under +2.0. "The Numbers" below has the details. In sjasmplus, `dw 0x4000` or `dw 16384` is 1.0, and `dw 16384 * 3 / 4` is 0.75.
- The complete examples are in `examples/geometry/`, built by `sh build.sh` there. Each starts with `device zxspectrum48`, `org 0x8000` and `include "hw.inc"`, runs in the boot ROM's program map, and ends by putting back what it changed and returning to the monitor.
- The examples that draw share `examples/geometry/screen.inc`, described with Example 9-2: a **256 × 192 screen at 1 bit per pixel** on L0, shown at 2× each way in the middle of the picture, white on black, with a line drawer in software. Example 9-2 also shares `cube.inc`: a cube's corners, edges and faces, rotation matrices from a sine table, and the loops that send the cube through the unit and draw it.

---

## The Unit and Its Registers

The unit is a block of 32 registers in the system page, `0xA0`–`0xBF` (Table 9-1). Nothing turns it on: it is always ready, and it never touches memory. The CPU alone reaches it; the copper and the DMA engine cannot.

**Table 9-1: The Unit's Registers**

| Register | Name | What it is for |
|----------|------|----------------|
| `0xA0`–`0xB7` | GEOW0–GEOW11 | A window of 12 words onto one of five banks: the camera, the object, the view, the operands, or the product ("The window and its banks") |
| `0xB8`–`0xBD` | GEOVX, GEOVY, GEOVZ | Written: a vertex's x, y and z; writing VZ's high byte starts the job. Read: the results RX, RY and RZ ("The vertex and its results") |
| `0xBE` | GEOCTL | Which bank the window shows, and what a vertex job does ("GEOCTL") |
| `0xBF` | GEOSTAT | What the last job found: NEAR, SAT, DIVZ, FRONT; and the sticky SATS ("GEOSTAT") |

### The window and its banks

The unit holds more values than 32 registers can show: a camera is 12 words, an object another 12, the view 5, the calculator's operands 11, and the product it works out 12. So registers `0xA0`–`0xB7` are a **window** of twelve 16-bit words, and GEOCTL's BANK field says which bank of values the window shows (Figure 9-2). Writing a word of the window writes that word of the bank; reading reads it back. The banks keep their values when the window moves on.

```
   GEOCTL.BANK = 0        1              2            3              4
                 ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐
                 │ camera   │  │ object   │  │ view     │  │ operands │  │ product  │
                 │ Mc, C    │  │ Mo, P    │  │ DX, DY,  │  │ F0–F2,   │  │ M, T     │
                 │          │  │          │  │ SCX, SCY,│  │ MA, MB,  │  │ (read    │
                 │ 12 words │  │ 12 words │  │ ZMIN     │  │ DVD, DVS │  │ only)    │
                 └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘
                      └─────────────┴─────────────┴──────┬──────┴──────────────┘
                                                         ▼
                                   registers 0xA0–0xB7: GEOW0 … GEOW11

                         Figure 9-2: The Window onto the Five Banks
```

Table 9-2 gives the window word by word. Each word is two registers, low byte first, so word n is registers `0xA0 + 2n` and `0xA1 + 2n`, and `hw.inc` names each bank's words by what they hold: `GEO_CM11` and `GEO_CPX` in the camera bank, `GEO_OM11` in the object bank, and so on, each the register of its low byte.

**Table 9-2: The Window's Words in Each Bank**

| Word | Registers | Ports | Bank 0: camera | Bank 1: object | Bank 2: view | Bank 3: operands | Bank 4: product |
|------|-----------|-------|----------------|----------------|--------------|------------------|-----------------|
| 0 | `0xA0`–`0xA1` | `0xA000`, `0xA100` | CM11 | OM11 | DX | F0X | M11 |
| 1 | `0xA2`–`0xA3` | `0xA200`, `0xA300` | CM12 | OM12 | DY | F0Y | M12 |
| 2 | `0xA4`–`0xA5` | `0xA400`, `0xA500` | CM13 | OM13 | SCX | F1X | M13 |
| 3 | `0xA6`–`0xA7` | `0xA600`, `0xA700` | CM21 | OM21 | SCY | F1Y | M21 |
| 4 | `0xA8`–`0xA9` | `0xA800`, `0xA900` | CM22 | OM22 | ZMIN | F2X | M22 |
| 5 | `0xAA`–`0xAB` | `0xAA00`, `0xAB00` | CM23 | OM23 | – | F2Y (its high byte starts a face sign) | M23 |
| 6 | `0xAC`–`0xAD` | `0xAC00`, `0xAD00` | CM31 | OM31 | – | MA | M31 |
| 7 | `0xAE`–`0xAF` | `0xAE00`, `0xAF00` | CM32 | OM32 | – | MB (its high byte starts a multiply) | M32 |
| 8 | `0xB0`–`0xB1` | `0xB000`, `0xB100` | CM33 | OM33 | – | DVD bits 15–0 | M33 |
| 9 | `0xB2`–`0xB3` | `0xB200`, `0xB300` | CPX | OPX | – | DVD bits 31–16 | TX |
| 10 | `0xB4`–`0xB5` | `0xB400`, `0xB500` | CPY | OPY | – | DVS (its high byte starts a divide) | TY |
| 11 | `0xB6`–`0xB7` | `0xB600`, `0xB700` | CPZ | OPZ | – | – | TZ |

- **The camera** (bank 0, `GEO_BANK_CAM`): the camera's matrix Mc, nine 2.14 entries row by row, then its position C in the world, three coordinates. Mc turns a direction in the world into the camera's view: for a camera turned by a rotation Rc, Mc is Rc transposed.
- **The object** (bank 1, `GEO_BANK_OBJ`): the object's matrix Mo, which turns a vertex from the model's own axes into the world's, then its position P in the world.
- **The view** (bank 2, `GEO_BANK_VIEW`): DX and DY, the distance from the eye to the screen in pixels, across and down (they differ when pixels are not square); SCX and SCY, the screen point straight ahead of the eye; and ZMIN, the **near plane**, the depth a vertex must have to be projected. Words 5–11 read 0 and ignore writes.
- **The operands** (bank 3, `GEO_BANK_OPS`): the face sign's three screen points, the multiply's two factors, and the divide's dividend and divisor ("Which Way a Face Looks", "Multiply and Divide"). Word 11 reads 0.
- **The product** (bank 4, `GEO_BANK_PROD`): the **combined matrix** M = Mc·Mo and its translation T, which the unit works out itself whenever the camera or the object changes ("The Combined Matrix"). Read only: writes are ignored.

Banks 5–7 are reserved: they read 0 and ignore writes.

A bank is laid out so that a program can keep it as 24 bytes and load it with one `LDIR`. The bytes of a word are written separately, low byte first, as for any register; nothing happens until the last byte of a bank that starts a job (below) is written.

### The vertex and its results

Registers `0xB8`–`0xBD` are a vertex on the way in and the results on the way out (Table 9-3). Writing them sets x, y and z; **writing VZ1, z's high byte, starts the job**. Reading the same registers gives the results RX, RY and RZ, which hold still until the next job ends. Reading VX0 does not give back the x you wrote.

**Table 9-3: The Vertex and Result Registers**

| Register | Port | Written | Read |
|----------|------|---------|------|
| `0xB8` | `0xB800` | VX0: x bits 7–0 | RX0: RX bits 7–0 |
| `0xB9` | `0xB900` | VX1: x bits 15–8 | RX1: RX bits 15–8 |
| `0xBA` | `0xBA00` | VY0: y bits 7–0 | RY0: RY bits 7–0 |
| `0xBB` | `0xBB00` | VY1: y bits 15–8 | RY1: RY bits 15–8 |
| `0xBC` | `0xBC00` | VZ0: z bits 7–0 | RZ0: RZ bits 7–0 |
| `0xBD` | `0xBD00` | VZ1: z bits 15–8, and **starts the vertex** | RZ1: RZ bits 15–8 |

What a vertex job does with (x, y, z) depends on GEOCTL. In the plain case it gives the vertex's place on the screen: RX = sx, RY = sy, RZ = its depth Z.

### GEOCTL

GEOCTL (Table 9-4) picks the bank the window shows and says what the next vertex job does. The bank changes only when GEOCTL is written.

**Table 9-4: GEOCTL Bits**

| Bits | Name | Meaning |
|------|------|---------|
| 7–6 | – | Read 0 |
| 5 | INV | A vertex is turned the inverse way: by the transpose of the matrix ("The Inverse Turn"; `GEOCTL_INV_M`) |
| 4 | CAM | A vertex is turned by the camera alone, as a point in the world ("Culling"; `GEOCTL_CAM_M`) |
| 3 | PROJ | A vertex is projected onto the screen after the turn ("A First Program"; `GEOCTL_PROJ_M`) |
| 2–0 | BANK | The bank the window shows: 0 camera, 1 object, 2 view, 3 operands, 4 product (`GEO_BANK_CAM` … `GEO_BANK_PROD`) |

So `GEO_BANK_OBJ | GEOCTL_PROJ_M`, `0x09`, is the setting an engine spends most of its time in: the object bank in the window, and every vertex projected.

### GEOSTAT

GEOSTAT (Table 9-5) says what the last job found. NEAR, SAT, DIVZ and FRONT belong to the last job and are replaced by the next; writes to them are ignored. SATS is **sticky**: once set it stays until you write a 1 to it.

**Table 9-5: GEOSTAT Bits**

| Bits | Name | Meaning |
|------|------|---------|
| 7 | SATS | Some job has saturated since SATS was last cleared. Write 1 to clear (`GEOSTAT_SATS_M`) |
| 6–5 | – | Read 0 |
| 4 | FRONT | The last face sign was 0 or more: the face looks towards the eye (`GEOSTAT_FRONT_M`) |
| 3 | DIVZ | The last divide was by zero (`GEOSTAT_DIVZ_M`) |
| 2 | SAT | A result of the last job did not fit 16 bits and was held at the limit (`GEOSTAT_SAT_M`) |
| 1 | NEAR | The last vertex was nearer than ZMIN with PROJ set, so it was not projected (`GEOSTAT_NEAR_M`) |
| 0 | BUSY | A job is being worked out. The CPU never sees it set: every job is done within 24 clocks of its start, before the CPU can read ("Timing") |

### The numbers

**Coordinates** are signed 16-bit integers: a vertex, an object's position P, the camera's C, and the results. The world is 65,536 units each way and **wraps**: P − C and v − C are taken as signed 16-bit numbers, so an object just across the world's edge from the camera is seen from the other side. A world that does not wrap keeps everything within 32,767 units of the camera on each axis.

**Matrix entries** are signed **2.14** fixed point: 2 bits of integer and 14 of fraction (Table 9-6). The entries of a rotation are all within ±1.0, so the room up to ±2.0 is for scaling ("Scaling").

**Table 9-6: A 2.14 Matrix Entry**

| Bits | Meaning |
|------|---------|
| 15 | The sign |
| 14 | 1.0 |
| 13–0 | The fraction: bit 13 is 0.5, bit 12 is 0.25, … bit 0 is 1/16,384 |

Some values: `0x4000` is 1.0, `0x2000` is 0.5, `0x376D` is cos 30° (0.8660), `0xC000` is −1.0, `0xE000` is −0.5, and `0x7FFF` is 1.99994. To turn a fraction into 2.14, multiply by 16,384 and round.

**Rounding.** Inside the unit a row's three products are added exactly (48 bits), then the sum is shifted down 14 bits and rounded to the nearest, halves up, once. A projection's divide rounds down (towards minus infinity), so a point crossing the screen's centre steps evenly. The plain divide rounds towards zero, as C does.

**Saturation.** A result that does not fit 16 bits is held at −32,768 or +32,767, and the job sets SAT and SATS. Positions wrap instead; only what a matrix turns saturates.

### A bank, byte by byte

Table 9-7 is the camera bank for a camera turned 30° about y, at the origin, as Example 9-1 loads it. The turn's matrix Rc has cos 30° on the diagonal and ± sin 30° in the corners; Mc is its transpose. The source form and the 24 bytes the assembler makes:

```
turned: dw      14189, 0, -8192         ; Mc row 1: cos 30, 0, -sin 30
        dw      0, 0x4000, 0            ; row 2: 0, 1.0, 0
        dw      8192, 0, 14189          ; row 3: sin 30, 0, cos 30
        dw      0, 0, 0                 ; C: the origin
```

```
        db      0x6D,0x37, 0x00,0x00, 0x00,0xE0   ; CM11 0x376D, CM12 0, CM13 0xE000
        db      0x00,0x00, 0x00,0x40, 0x00,0x00   ; CM21 0, CM22 0x4000, CM23 0
        db      0x00,0x20, 0x00,0x00, 0x6D,0x37   ; CM31 0x2000, CM32 0, CM33 0x376D
        db      0x00,0x00, 0x00,0x00, 0x00,0x00   ; CPX, CPY, CPZ: 0
```

**Table 9-7: The Camera Bank for a 30° Turn**

| Word | Name | Value | Meaning |
|------|------|-------|---------|
| 0 | CM11 | `0x376D` | cos 30° = 0.866 |
| 1 | CM12 | `0x0000` | 0 |
| 2 | CM13 | `0xE000` | −sin 30° = −0.5 |
| 3 | CM21 | `0x0000` | 0 |
| 4 | CM22 | `0x4000` | 1.0: y is not turned |
| 5 | CM23 | `0x0000` | 0 |
| 6 | CM31 | `0x2000` | sin 30° = 0.5 |
| 7 | CM32 | `0x0000` | 0 |
| 8 | CM33 | `0x376D` | cos 30° |
| 9–11 | CPX, CPY, CPZ | `0x0000` | The camera is at the origin |

With `LDIR` from `turned` to `GEO` the words go in low byte first, CPZ's high byte last. The camera bank starts no job, so the order does not matter here; it matters for the vertex and the operands, as "Writing the starting byte last" explains.

---

## A First Program

A vertex comes back as a screen point once the view, the camera and the object are loaded. Example 9-1 does that in five steps and prints what it gets.

### Step 1: The register page in window 7

As in Chapter 1, the first mapping goes through ports, since the MMU's registers are in the system page; the stack is moved below window 7 first. `regs_on` in `screen.inc` does both, and `regs_off` at the end puts SRAM page 7 back in window 7 and returns to the monitor.

### Step 2: The view

The examples' screen is 256 × 192. With DX and DY 256, a point one unit to the side at a depth of one unit lands 256 pixels across: the screen's edges, 128 pixels from the centre, are 45° from the line of sight, a 90° field of view. The centre is (128, 96), and the near plane 16 units ahead.

```
        ld      a,GEO_BANK_VIEW
        ld      (GEO_CTL),a
        ld      hl,view
        ld      de,GEO
        ld      bc,10
        ldir                            ; DX, DY, SCX, SCY, ZMIN
        ...
view:   dw      256, 256                ; DX, DY: 256 pixels to the screen
        dw      128, 96                 ; SCX, SCY: the screen's centre
        dw      16                      ; ZMIN: the near plane
```

### Step 3: The camera

A camera at the origin, looking along z, not turned: Mc is the identity, 1.0 on the diagonal.

```
        ld      a,GEO_BANK_CAM
        ld      (GEO_CTL),a
        ld      hl,identity
        ld      de,GEO
        ld      bc,24
        ldir                            ; Mc, then C
        ...
identity:
        dw      0x4000, 0, 0            ; 1.0 on the diagonal
        dw      0, 0x4000, 0
        dw      0, 0, 0x4000
        dw      0, 0, 0                 ; at the origin
```

### Step 4: The object

An object not turned either, 512 units ahead of the camera. As soon as its last byte is written, the unit works out the combined matrix.

```
        ld      a,GEO_BANK_OBJ
        ld      (GEO_CTL),a
        ld      hl,object
        ld      de,GEO
        ld      bc,24
        ldir                            ; Mo, then P
        ...
object: dw      0x4000, 0, 0
        dw      0, 0x4000, 0
        dw      0, 0, 0x4000
        dw      0, 0, 512               ; P: 512 ahead
```

### Step 5: A vertex, projected

With PROJ set, write x, y and z, low byte first: six `LDI`s do it, and the sixth, VZ1, starts the job. The result is ready before the next instruction can read it, so the screen point is read straight away. A vertex nearer than the near plane sets NEAR instead, and the results are then X, Y and Z, the vertex in front of the eye but not projected.

```
        ld      a,GEO_BANK_OBJ | GEOCTL_PROJ_M
        ld      (GEO_CTL),a
        ld      hl,vertex               ; x, y, z as words
        ld      de,GEO_V
        ldi                             ; VX0, VX1, VY0, VY1, VZ0 ...
        ldi
        ldi
        ldi
        ldi
        ldi                             ; ... VZ1: starts the vertex
        ld      a,(GEO_ST)
        and     GEOSTAT_NEAR_M
        jr      nz,behind
        ld      hl,(GEO_V)              ; RX: sx
        ld      de,(GEO_V + 2)          ; RY: sy
        ld      bc,(GEO_V + 4)          ; RZ: the depth
```

### Example 9-1: A vertex through the unit

`examples/geometry/first.asm` does the five steps, sends three vertices of the object and prints where each lands. Then it turns the camera 30° (the bank of Table 9-7), reads the combined translation T back from the product bank, and sends two of the vertices again. The console shows:

```
Vertices through the geometry unit
(-100, 50, 0) -> 78, 71  z 512
(100, -50, 0) -> 178, 121  z 512
(0, 0, -600) -> NEAR: 0, 0  z -88
The camera turned 30 degrees: T = -256, 0, 443
(-100, 50, 0) -> -96, 64  z 393
(100, -50, 0) -> 40, 122  z 493
```

The first vertex is 100 to the left of the object's centre and 50 above it, 512 ahead: 256 × 100 ÷ 512 = 50 pixels left of the centre and 25 above, (78, 71). The third is 600 behind the object's centre, 88 behind the eye: NEAR, and the unprojected (0, 0, −88) comes back. With the camera turned 30°, the object's centre is no longer straight ahead: T = Mc·(P − C) = (−256, 0, 443), 256 to the side and a little nearer (512 × cos 30° = 443), and the first vertex, now 343 to the side at a depth of 393, lands off the screen at −96. The unit does not clip: a screen point can be anywhere in −32,768 to 32,767, and the program decides what to draw.

---

## The Combined Matrix

A vertex's path (Figure 9-1) is two turns: Mo·v + P puts the model into the world, and Mc·(… − C) puts the world in front of the eye. The unit folds them into one. Whenever any byte of the camera or the object is written, it works out

- M = Mc·Mo, each entry rounded to 2.14, and
- T = Mc·(P − C), with P − C wrapped,

and a vertex job then does M·v + T in one pass. The working takes 24 clocks; a start that comes while it is in progress waits for it, and the next instruction after a 24-byte `LDIR` is already past it. If M or T saturated, every vertex that uses them sets SAT.

Bank 4, the product, shows M and T (Table 9-2), so **the unit is a 3 × 3 matrix multiplier**: load A into the camera bank and B into the object bank, and read A·B from the product bank with an `LDIR` of 18 bytes. With C = 0, T = A·P as well, which turns a position. Example 9-2 makes a two-axis turn that way, and a model built of parts (a turret on a tank) gets each part's matrix as tank × turret.

```
        ld      a,GEO_BANK_CAM
        ld      (GEO_CTL),a
        ld      hl,ry                   ; A: a turn about y, at the origin
        ld      de,GEO
        ld      bc,24
        ldir
        ld      a,GEO_BANK_OBJ
        ld      (GEO_CTL),a
        ld      hl,rx                   ; B: a turn about x
        ld      de,GEO
        ld      bc,24
        ldir
        ld      a,GEO_BANK_PROD
        ld      (GEO_CTL),a
        ld      hl,GEO
        ld      de,object
        ld      bc,18
        ldir                            ; M = A . B
```

The camera and object banks then hold A and B, not the real camera and object: load those again before the vertices.

---

## Turning an Object

An object's matrix Mo is its turn: the identity for an object that stands as it was modelled, or a rotation about one or more axes. A rotation about an axis by an angle a has cos a and sin a in four places (Table 9-8); in 2.14, from a table of 256 sines round the circle, which `tables.py` writes as `sine.inc`.

**Table 9-8: Rotation Matrices**

| About | Row 1 | Row 2 | Row 3 |
|-------|-------|-------|-------|
| x | 1, 0, 0 | 0, cos a, −sin a | 0, sin a, cos a |
| y | cos a, 0, sin a | 0, 1, 0 | −sin a, 0, cos a |
| z | cos a, −sin a, 0 | sin a, cos a, 0 | 0, 0, 1 |

The axes are x to the right, y up and z into the screen, in the model, the world and the camera's view alike; the screen's y runs down, which the projection's "SCY − …" takes care of. A turn about two axes is the product of two of these, which the unit multiplies as above. `rot_y` and `rot_x` in `cube.inc` write a 24-byte bank for a turn of A (0–255 round the circle) at the origin.

### Example 9-2: A turning cube

`examples/geometry/cube.asm` turns a cube about y and about x at once and draws it, 600 units ahead of a camera that does not move. Each frame it:

1. makes Ry(a) and Rx(b) with `rot_y` and `rot_x`, and multiplies them through the product bank, as "The Combined Matrix" shows, into the object's matrix;
2. loads the real camera (the identity, at the origin) and the object (that matrix, at P = (0, 0, 600));
3. sends the eight corners through the unit, projected, into a table of screen points (`project8`);
4. clears the screen it is about to show and draws the twelve edges between the points (`draw_edges`), then flips the screens at the vertical blank.

The cube's corners are ±90 on each axis; corner i has x = +90 if bit 0 of i is set, y by bit 1, z by bit 2, so an edge joins two corners that differ in one bit:

```
cube_verts:
        dw      -S, -S, -S              ; 0
        dw       S, -S, -S              ; 1
        ...
cube_edges:
        db      0,1, 2,3, 4,5, 6,7      ; along x
        db      0,2, 1,3, 4,6, 5,7      ; along y
        db      0,4, 1,5, 2,6, 3,7      ; along z
```

`project8` is Step 5 of the first program in a loop. `LDI` counts BC down, so BC is the bytes left, 6 a corner:

```
project8:
        ld      hl,cube_verts
        ld      ix,points
        ld      bc,6 * 8
.corner:
        ld      de,GEO_V
        ldi                             ; x, y, z, low byte first: VZ1 last,
        ldi                             ; which starts the vertex
        ldi
        ldi
        ldi
        ldi
        ld      a,(GEO_ST)              ; the result is ready by now
        and     GEOSTAT_NEAR_M
        jr      nz,.behind
        ld      de,(GEO_V)              ; RX: sx
        ld      (ix+0),e
        ld      (ix+1),d
        ld      de,(GEO_V + 2)          ; RY: sy
        ld      (ix+2),e
        ld      (ix+3),d
.next:  ld      de,4
        add     ix,de
        ld      a,b                     ; BC = 0 after the last corner
        or      c
        jr      nz,.corner
        ret
.behind:
        ld      (ix+1),0x80             ; not on the screen
        jr      .next
```

The rest is scaffolding. `screen.inc` has `regs_on` and `regs_off`; `scr_on`, which saves the console's L0 and its two colours, makes L0 the 256 × 192 bitmap at 2 × 2 and blanks both screens; `cls`, `flip` and `scr_off`; `line`, a Bresenham line in software, about 100 T-states a pixel; and `puts`, `putsd` (a signed decimal) and `time`. `cube.inc` has the cube, the sine table, `rot_y`, `rot_x`, `project8` and `draw_edges`.

On the board the cube turns smoothly at the frame rate. After a key the console shows `The matrices and 8 vertices took 345 us a frame`: 6,900 T-states for the two rotation matrices, the product, the two banks and the eight vertices. The Z80's time is in moving bytes; the unit's own work is a few microseconds of it. `line` drops a line with an end off the screen, since the Z80 has no clip rectangle: a cube that is wholly on the screen, as this one is, loses nothing.

---

## The Near Plane

A vertex behind the eye cannot be projected: dividing by a negative depth would put it on the screen upside down, and a depth of 0 is nonsense. ZMIN in the view bank is the depth a vertex must have; a ZMIN below 1 counts as 1. A vertex nearer than ZMIN sets NEAR and comes back as (X, Y, Z), not projected, so the program can decide:

- **Drop it**, with every edge to it. `project8` marks it with an x of `0x8000` and `draw_edges` skips those edges. For objects that never come close, that is enough.
- **Cut the edge at the near plane.** An edge from a vertex a in front of the plane to a vertex b behind it crosses the plane at a + t·(b − a), with t = (ZMIN − az) ÷ (bz − az). The unit's divide gives t as a 16-bit fraction: DVD = (ZMIN − az) × 65,536 and DVS = bz − az ("Multiply and Divide"), then the multiply gives t·(bx − ax) and t·(by − ay), and the cut point, at the depth ZMIN, is projected by the divide again: sx = SCX + DX·X ÷ ZMIN.

The first is what the examples do. A game that flies close to its objects needs the second, or a cull that drops any object that reaches the near plane, as fast3d does.

---

## Culling

A scene has far more objects than the screen shows, and the cheapest work is the work not done. An engine **culls**: it tests each object's centre, and only the objects in view get their vertices sent. With **CAM** set in GEOCTL, a vertex is turned by the camera alone, as a point in the world: the result is Mc·(v − C), where the object is in front of the eye, without projection. One vertex job per object gives its centre's depth Z and its offset X, Y from the line of sight, and three compares decide:

- **Behind the near plane, or too far:** Z < ZMIN + r, where r is how far the object reaches from its centre, or Z > the far limit.
- **Beyond a side:** with DX the distance to the screen and W half its width, a point is on the screen when |X| ≤ Z × W ÷ DX. The examples' view has W = DX, so the test is |X| ≤ Z + r, and |Y| ≤ Z + r for the top and bottom (looser than the screen's 96, which drops the lines off the screen instead).

```
        ld      a,GEO_BANK_CAM | GEOCTL_CAM_M   ; the camera alone, no projection
        ld      (GEO_CTL),a
        ld      hl,(centre_x)
        ld      (GEO_V),hl
        ld      hl,(centre_y)
        ld      (GEO_V + 2),hl
        ld      hl,(centre_z)
        ld      (GEO_V + 4),hl          ; VZ1: starts the job
        ld      hl,(GEO_V + 4)          ; Z: the centre's depth
        ...
```

The bank in BANK does not matter for a vertex job; CAM is what changes it. The camera bank is a handy choice, since the camera is what a frame loads first.

### Example 9-3: A ring of cubes

`examples/geometry/ring.asm` puts twelve cubes on a ring of radius 1,500 round the origin, each turning on its own, and sets the camera at the origin, turning on the spot. Each frame the camera's matrix is a turn about y: Mc is the turn transposed, which for a single axis is the turn the other way, `rot_y` of −angle. Then each cube's centre goes through the unit with CAM, and the three tests above say whether to draw it; a cube in view is loaded, projected and drawn as in Example 9-2. The cubes' positions are worked out once at the start, by the unit's multiply: RADIUS × sin and RADIUS × cos of each cube's angle round the ring.

```
.cube:  ld      a,GEO_BANK_CAM | GEOCTL_CAM_M
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
        ld      hl,(GEO_V+4)            ; the sides: |X| <= Z + MARGIN
        ld      de,MARGIN
        add     hl,de
        ex      de,hl
        ld      hl,(GEO_V)              ; X
        call    inside
        jr      c,.out
        ld      hl,(GEO_V+2)            ; and |Y| <= Z + MARGIN
        call    inside
        jr      c,.out
```

On the board the cubes come into view from the right, cross the screen and leave at the left as the camera turns, two to four at a time, each turning on its own. After a key the console said `The last frame drew 4 of the 12 cubes`. The cull costs one vertex job and a few compares a cube, so the eight or nine cubes out of view cost almost nothing; the lines of a cube half off the screen are dropped by `line`, as the blitter's clip rectangle would cut them.

---

## Which Way a Face Looks

A closed object's faces come in two kinds: those that look towards the eye, and those that look away, which are hidden behind the others. A **face sign** tells them apart from three of a face's screen points. With the points (F0X, F0Y), (F1X, F1Y) and (F2X, F2Y) in the operands bank (Table 9-2), writing F2Y's high byte starts the job:

- s = (F1X − F0X) × (F2Y − F0Y) − (F1Y − F0Y) × (F2X − F0X), worked out exactly;
- RX and RY are s's low and high words, saturated to 32 bits;
- **FRONT** in GEOSTAT is set if s ≥ 0.

With the screen's y running down, a face whose corners are listed anticlockwise as seen from outside the object gives s ≥ 0 when it looks towards the eye; an edge-on face counts as towards it. List every face's corners that way in the model, and FRONT says whether to draw it. For a wireframe, an edge is drawn if either of its two faces has FRONT; for filled faces, each face with FRONT is filled, and the test replaces a depth sort for a convex object.

```
        ld      a,GEO_BANK_OPS
        ld      (GEO_CTL),a
        ld      hl,corner0              ; x, y of the three corners, as words
        ld      de,GEO                  ; F0X, F0Y, F1X, F1Y, F2X, F2Y
        ld      bc,12
        ldir                            ; the last byte, F2Y1, starts the job
        ld      a,(GEO_ST)
        and     GEOSTAT_FRONT_M         ; NZ: the face looks towards the eye
```

### Example 9-4: The cube with its back faces hidden

`examples/geometry/faces.asm` is Example 9-2 with the face test. The cube's six faces are listed with their corners anticlockwise from outside:

```
cube_faces:
        db      0, 2, 3, 1              ; z = -S, the face towards the eye at first
        db      4, 5, 7, 6              ; z = +S
        db      0, 4, 6, 2              ; x = -S
        db      1, 3, 7, 5              ; x = +S
        db      0, 1, 5, 4              ; y = -S
        db      2, 6, 7, 3              ; y = +S
```

After the corners are projected, each face's first three corners go into F0–F2 and FRONT is kept in a table; then each edge is drawn only if one of its two faces is in the table as FRONT. On the board the cube looks solid: only the faces nearest the eye show, and as it turns a face's edges appear the moment it comes round to face the eye. After a key the console said `The six face signs took 206 us a frame`: 4,120 T-states, about 690 a face, most of it looking up and copying the three corners' points; the unit's part is 24 clocks a face.

---

## The Inverse Turn

With **INV** set, a vertex is turned by the transpose of the matrix, which undoes a rotation exactly (Table 9-9). The two uses:

- INV alone gives Mᵀ·(v − T): a point in front of the eye taken back into the model's own axes. With v = 0 that is **the eye's position in the model's space**, which is what a test of a face's plane against the eye in 3D needs, before projection.
- CAM and INV together give Mcᵀ·v + C: a point in front of the eye taken back into the world, the inverse of the cull's turn.

**Table 9-9: What a Vertex Job Does**

| CAM | INV | PROJ | Result (RX, RY, RZ) | Used for |
|-----|-----|------|---------------------|----------|
| 0 | 0 | 0 | M·v + T = Mc·(Mo·v + P − C): the vertex in front of the eye | A vertex's depth without its screen point |
| 0 | 0 | 1 | The same, then projected: (sx, sy, Z), or NEAR and (X, Y, Z) | Drawing |
| 1 | 0 | 0 | Mc·(v − C): a point in the world in front of the eye | Culling by an object's centre |
| 1 | 0 | 1 | The same, projected | A point in the world on the screen |
| 0 | 1 | 0 | Mᵀ·(v − T): the inverse of the first row | The eye in the model's space (v = 0) |
| 1 | 1 | 0 | Mcᵀ·v + C, wrapped: the inverse of CAM | A point in front of the eye back in the world |

INV with PROJ projects the inverse's result, which is rarely wanted. The transpose undoes a rotation; for a matrix that also scales, INV does not undo the scale.

---

## Multiply and Divide

The operands bank (Table 9-2) makes the unit a calculator. Both jobs leave RZ as it was.

**Multiply:** MA × MB, both signed 16-bit. Writing MB's high byte starts it; RX is the product's bits 15–0 and RY its bits 31–16. It never saturates. Two 2.14 numbers multiplied give a 4.28 product: the 2.14 answer is bits 29–14, so shift RY:RX down 14, or take RY's bits 15–0 shifted up 2 with RX's top two bits.

```
        ld      a,GEO_BANK_OPS
        ld      (GEO_CTL),a
        ld      (GEO + 12),hl           ; MA
        ld      (GEO + 14),de           ; MB: its high byte starts the multiply
        ld      hl,(GEO_V)              ; RX: the product's low word
        ld      de,(GEO_V + 2)          ; RY: the high word
```

**Divide:** DVD ÷ DVS, a signed 32-bit dividend (DVD bits 15–0 in word 8, bits 31–16 in word 9) by a signed 16-bit divisor. Writing DVS's high byte starts it:

- RX is the quotient, rounded towards zero, saturated to 16 bits (SAT if it was, and RY then 0);
- RY is the remainder, with the dividend's sign;
- a divisor of 0 sets DIVZ: RX is +32,767 for a dividend of 0 or more, −32,768 otherwise, and RY is 0.

```
        ld      hl,dividend             ; DVD0-DVD3, then DVS0, DVS1, as 6 bytes
        ld      de,GEO + 16
        ld      bc,6
        ldir                            ; the last byte starts the divide
        ld      hl,(GEO_V)              ; RX: the quotient
        ld      de,(GEO_V + 2)          ; RY: the remainder
```

### Example 9-5: The unit as a calculator

`examples/geometry/calc.asm` prints four multiplies and four divides. The console shows:

```
The geometry unit as a calculator
1234 x 567 = 000AAD1E
-1234 x 567 = FFF552E2
-32768 x -32768 = 40000000
16384 x 8192 = 08000000
0001 86A0 / 7 = 14285 remainder 5
FFFE 7960 / 7 = -14285 remainder -5
000F 4240 / 3 = 32767 remainder 0  SAT
0000 0001 / 0 = 32767 remainder 0  DIVZ
```

1234 × 567 is 699,678, `0x000AAD1E`. The fourth multiply is 1.0 × 0.5 in 2.14: `0x08000000`, whose bits 29–14 are `0x2000`, 0.5. 1,000,000 ÷ 3 is 333,333, too big for 16 bits, so RX saturates and SAT is set; 1 ÷ 0 sets DIVZ. A multiply costs the Z80 about 70 T-states for the writes and reads and a divide about 160, where a 16 × 16 multiply in software is about 600 and a 32 ÷ 16 divide about 1,200.

---

## Scaling, Saturation and the Starting Byte

### Scaling

A matrix entry goes up to just under 2.0, so an object drawn 1.5 times its size has every entry of its rotation multiplied by 1.5, and one drawn at half size by 0.5. The combined matrix M = Mc·Mo is rounded to 2.14 and saturated to ±2.0: a camera that scales and an object that scales can overflow it, and every vertex then sets SAT. Scaling by more than 2 is done on the vertices themselves: a model of half-size coordinates and a matrix of 1.0 to 2.0.

### Saturation and SATS

A result that does not fit 16 bits is held at the limit: a vertex far to the side of the eye projects to ±32,767, not to nonsense, and the program can test SAT or just draw and clip. For a whole object, clear SATS first, send the vertices, and read SATS once:

```
        ld      a,GEOSTAT_SATS_M
        ld      (GEO_ST),a              ; W1C: clear SATS
        ...                             ; the object's vertices
        ld      a,(GEO_ST)
        and     GEOSTAT_SATS_M          ; NZ: something saturated
```

### Writing the starting byte last

VZ1, F2Y1, MB1 and DVS1 start their jobs, so each must be written **after** the rest of the job's operands, as the MMU pages and the colours need their last byte last. The writes that go up through memory do this on their own: `LD (nn),HL` for each word, `LDI` and `LDIR`, `OUT (C),r` with `INC B` between. `PUSH`, `LDDR` and a run of `OUTI`s write the high byte first and would start the job with the old low byte.

A job's operands are taken the moment it starts, so the next vertex's bytes can be written while one runs; and since the results change only when a job ends, a program that reads RX after writing the next VX0 still reads the last job's result. The board test in `examples/geometry/geomtest.asm` relies on both.

---

## Timing

Every job is done within 24 clocks of its start, 240 ns, before the Z80 can read a result: the soonest read after a write is the next instruction's, `LD (HL),C` then `LD A,(DE)`, about 25–30 clocks apart at 20 MHz. So the CPU never waits, and never sees BUSY. The time a program spends is its own byte moving (Table 9-10).

**Table 9-10: What the Z80 Spends**

| Work | T-states | How |
|------|----------|-----|
| Loading a bank | about 520 | `LDIR` of 24 bytes, 21 each, plus the bank select |
| A projected vertex, keeping sx, sy and the depth | 316 | Six `LDI`s in, three `LD rr,(nn)` and six `LD (IX+d),r` out: spec 15's loop, 1,024 vertices in 16,160 µs on the KS2 |
| A projected vertex, keeping sx and sy | 172 | `POP` the vertex, `LD (nn),HL` in, `LD HL,(nn)` and `PUSH` out, interrupts off: 1,024 vertices in 8,821 µs on the KS2 |
| The same vertex in software (fast3d) | about 2,330 | A turn and a projection with 8-bit multiplies |
| A cull: one CAM vertex and the compares | about 350 | Example 9-3: the centre from an indexed table, three `LD (nn),HL` in, Z, X and Y out and compared |
| A face sign | about 690 | Example 9-4: 206 µs for six, with the corners looked up; the twelve bytes in and GEOSTAT out are about 250 of it |
| A multiply | about 70 | Two `LD (nn),HL` in, two `LD HL,(nn)` out |
| A divide | about 160 | Six bytes in by `LDIR`, two words out |
| Example 9-2's frame: two matrices, the product, two banks, eight vertices | 345 µs (6,900) | From TIME on the board |

In fast3d's flight (forty objects, wireframe, 256 pictures), the unit took the geometry from 276,000 T-states a picture to 69,000, and the whole picture from 473,000 to 268,000 (spec 15, section 10). What was left was drawing, which is Chapter 6's EDGES job's work.

---

## What the Unit Cannot Do

- **It reads no memory.** Every vertex goes in and out through the registers, by the Z80. A list mode, where the unit would turn a vertex list in SRAM on its own, is kept open (spec 15, G2); interrupt 19, GEOM, is reserved for it and never fires today.
- **One job at a time.** A start write while a job runs is held and run after it; the CPU cannot make one, since every job finishes first.
- **No clipping.** A screen point can be anywhere in ±32,767; the program, or the blitter's clip rectangle (Chapter 6), keeps the lines on the screen.
- **No cut at the near plane.** A vertex nearer than ZMIN comes back unprojected with NEAR; the program cuts the edge, or drops it.
- **No scaling beyond 2.0** in a matrix entry, and the inverse turn does not undo a scale.
- **No dot product, no plane test, no lighting.** The inverse turn and three multiplies do a face-against-the-eye test in 3D (spec 15, G4 and G6).
- **Only the CPU reaches it.** The copper and the DMA engine cannot write its registers.
- **Not on the KS2's usual build.** The KS2 builds the unit or the blitter, not both; the KS3 has both.

---

## A Note for Amiga Programmers

The Amiga had no geometry hardware: its 68000 multiplied in about 70 cycles, and games turned their vertices in software. Here the Z80 has no multiply, and the unit stands in for the 68000's MULS and DIVS as well as for the matrix work. A program that kept its objects as the Amiga's 3D games did, a list of vertices and a list of faces in whatever order, works unchanged: the vertices go through the unit, and the faces' corner order gives the face sign, as a cross product gave it there.

---

## Summary of Geometry Registers

The registers are system page registers `0xA0`–`0xBF` (port = register × 256, or `0xE000` + register through the register page in window 7). Table 9-11 lists them.

**Table 9-11: Geometry Registers**

| Register | Port | Name | Access | Bits |
|----------|------|------|--------|------|
| `0xA0`–`0xB7` | `0xA000`–`0xB700` | GEOW0–GEOW11 | RW (bank 4 R) | Twelve words of the bank GEOCTL.BANK selects: Table 9-2 |
| `0xB8`–`0xB9` | `0xB800`, `0xB900` | GEOVX / RX | W / R | A vertex's x; read: RX |
| `0xBA`–`0xBB` | `0xBA00`, `0xBB00` | GEOVY / RY | W / R | y; read: RY |
| `0xBC`–`0xBD` | `0xBC00`, `0xBD00` | GEOVZ / RZ | W / R | z, its high byte starting the vertex; read: RZ |
| `0xBE` | `0xBE00` | GEOCTL | RW | INV (5), CAM (4), PROJ (3), BANK (2–0): Table 9-4 |
| `0xBF` | `0xBF00` | GEOSTAT | R, SATS W1C | SATS (7), FRONT (4), DIVZ (3), SAT (2), NEAR (1), BUSY (0): Table 9-5 |

The full definition is spec 15, `docs/spec/geometry.md`.

### State after reset and when a program starts

After reset every register is 0: bank 0 in the window, no projection, every matrix 0, so a vertex gives (0, 0, 0). The boot ROM does not touch the unit, so a program starts with whatever the last one left, and loads its view, camera and object before its first vertex. Nothing needs putting back at the end.

### Names in `hw.inc`

- `GEOW0`–`GEOW11`: the window's words; `GEOW0_0` and `GEOW0_1` for the bytes, and `_P` for the ports.
- `GEO_CM11` … `GEO_CM33`, `GEO_CPX`, `GEO_CPY`, `GEO_CPZ`: the camera bank's words, each the register of its low byte; `GEO_OM11` … `GEO_OPZ` the object's; `GEO_DX`, `GEO_DY`, `GEO_SCX`, `GEO_SCY`, `GEO_ZMIN` the view's; `GEO_F0X` … `GEO_F2Y`, `GEO_MA`, `GEO_MB`, `GEO_DVD`, `GEO_DVDHI`, `GEO_DVS` the operands; `GEO_M11` … `GEO_TZ` the product's.
- `GEO_BANK_CAM` (0), `GEO_BANK_OBJ` (1), `GEO_BANK_VIEW` (2), `GEO_BANK_OPS` (3), `GEO_BANK_PROD` (4): GEOCTL's BANK values.
- `GEOVX`, `GEOVY`, `GEOVZ`: the vertex registers (`GEOVX0`, `GEOVX1` … for the bytes); the results are read at the same numbers.
- `GEOCTL` and `GEOCTL_BANK_M`, `GEOCTL_PROJ_M`, `GEOCTL_CAM_M`, `GEOCTL_INV_M`, with `_B` for the bit numbers.
- `GEOSTAT` and `GEOSTAT_BUSY_M`, `GEOSTAT_NEAR_M`, `GEOSTAT_SAT_M`, `GEOSTAT_DIVZ_M`, `GEOSTAT_FRONT_M`, `GEOSTAT_SATS_M`.
- `INT_GEOM` (19): the interrupt reserved for the unit, never raised today.
