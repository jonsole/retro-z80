# Spec 15: Geometry unit

Status: **draft**

The geometry unit does a 3D engine's arithmetic for the Z80, which has no multiply. It turns a vertex by the camera and the object, projects it onto the screen, and tests which way a face looks. It also does a plain multiply and divide. It is a retro-z80 extra (design plan, branch 10): retro68k has no geometry unit, since a 68000 has MULS and DIVS.

The target is flat-shaded polygons (one colour each), as in Elite or Starglider 2, at 25–50 frames a second. There is no Z-buffer: software sorts faces back to front. Drawing help (a span fill or a triangle job in the DMA engine) is decided later, from measurements of this unit (section 10, open point G1).

The jobs were chosen by what a software engine spends its time on. In the fast3d engine (a Spectrum 128K, wireframe, 40 objects; [zx-spectrum-emulator/examples/fast3d](https://github.com/jonsole/zx-spectrum-emulator/tree/master/examples/fast3d)) an average frame of 468,000 T-states goes on culling (23%), objects' matrices (9%), vertices (28%, more than half of it projecting), lines (15%), clipping (6%) and clearing (8%). A vertex costs about 2,330 T-states there; here it costs 316 with the loop of section 6.2 and 172 with a tight one, both measured on the KS2.

## 1. Summary

| Item | Value |
|------|-------|
| Numbers | Coordinates and positions signed 16-bit integers. Matrix entries signed 2.14 fixed point (`0x4000` = 1.0, range −2.0 to +1.99994). Sums 48-bit inside; results 16-bit |
| Too big | A result that doesn't fit **saturates** to −32768 or +32767 and sets GEOSTAT.SAT and SATS. Positions wrap instead (section 3.1) |
| Matrices | Two 3×3 matrices, each with a position: the **camera** (Mc, C) and the **object** (Mo, P). The unit keeps their product, camera × object, up to date itself |
| Vertex job | Write x, y, z: the result is X = Mc·(Mo·v + P − C). Optionally the camera alone, optionally the inverse turn, optionally projected |
| Projection | sx = SCX + ⌊DX·X ÷ Z⌋, sy = SCY − ⌊DY·Y ÷ Z⌋. A vertex with Z below ZMIN sets **NEAR** and comes back unprojected |
| Other jobs | Face sign (back-face test of three screen points), 16 × 16 → 32 signed multiply, 32 ÷ 16 signed divide. A matrix product: load A as the camera and B as the object, then read A·B from the product bank |
| Registers | System page `0x00`, registers `0xA0`–`0xBF`: port = register × 256. A 24-byte window (`0xA0`–`0xB7`) shows one of five banks: camera, object, view, operands, and the product (read only). Also at register page offsets `0x00A0`–`0x00BF` |
| Starting a job | Writing the high byte of a job's last operand starts it: VZ1 a vertex, F2Y1 a face sign, MB1 a multiply, DVS1 a divide |
| Speed | Every job is done within 24 clocks (240 ns) of its start, before the CPU can read the result (at most 22 measured). GEOSTAT.BUSY is kept for safety |
| Who can reach it | The CPU only (ports and the register page). It is a system register block, out of the copper's and the DMA engine's reach |
| Memory cycles | None |
| Interrupt | None in this version. Interrupt 19 (GEOM) stays reserved for a list mode (open point G2) |
| Builds | The KS3 always. On the KS2 a build option, `GEOM = 1`, builds the unit in place of the DMA engine (section 8) |

## 2. Comparison with retro68k

retro68k has no geometry unit. A 68000 multiplies 16 × 16 in about 70 cycles (MULS) and divides in about 150 (DIVS), so software transforms are fast enough there; a Z80 needs about 150 T-states for an 8 × 8 multiply alone.

| Feature | retro68k | retro-z80 | Why |
|---------|----------|-----------|-----|
| Geometry unit | None | Section 1 | A Z80 has no multiply (design plan, branch 10) |
| Registers | – | System page `0xA0`–`0xBF`, banked | Kept in its own block, as the Spectrum extras are |
| Interrupt 19 | – | Reserved (GEOM) | For a list mode later |
| 3D drawing | DMA engine OP 6 (span fill) and OP 7 (triangle) reserved | The same, agreed (spec 14, open point D6) | Shared, so both machines draw the same way |

retro68k could take the unit on later as a memory-mapped block. Nothing in it is Z80-specific except the register layout.

## 3. The numbers

### 3.1 Positions wrap, turned values saturate

A world position (the camera's C, an object's P, a vertex's x, y, z) is a signed 16-bit number. The world is 65,536 units square and wraps: **P − C and v − C are taken modulo 65,536**, as −32,768 to +32,767. So an object just across the world's edge from the camera is seen from the other side, exactly as the same scene moved away from the edge would be. A world that does not wrap keeps its objects within 32,767 units of the camera on every axis.

Everything a matrix turns (a sum of products) is exact inside (48 bits), then rounded and **saturated** to 16 bits. Saturation sets GEOSTAT.SAT for that job and the sticky GEOSTAT.SATS.

### 3.2 Rounding

- A product with a 2.14 entry is shifted right 14 bits, **rounded to nearest, halves up** (add `0x2000` first). The sum of a row is rounded once, after it is added up, not product by product.
- A perspective divide rounds **down** (towards minus infinity), so a point moving across the screen's centre steps evenly.
- The plain divide rounds **towards zero** (as C does), with the remainder taking the dividend's sign.

### 3.3 Matrix entries

An entry is signed 2.14: `0x4000` is 1.0, `0xC000` is −1.0, `0x7FFF` is 1.99994. A rotation's entries all lie within ±1.0, so the room up to ±2.0 is for scaling: an object drawn 1.5 times its size has its matrix scaled by 1.5.

## 4. The jobs

### 4.1 The combined matrix

The unit keeps the product of the camera and the object, and recomputes it whenever any byte of either is written:

- M = Mc · Mo, each entry rounded to 2.14 and saturated to ±2.0.
- T = Mc · (P − C), with P − C wrapped (section 3.1), rounded and saturated to 16 bits.

This takes 24 clocks (four passes of 6). A write to the camera or the object restarts it. A start write comes at least one instruction after the last matrix byte (35 clocks or more), so the product is ready before the next job starts. A job started while the product is being worked out waits for it. If M or T saturated, every vertex that uses them sets SAT.

The product bank (bank 4, section 5.1) shows M and T, read only. So the unit is also a **matrix multiplier**: load A as the camera and B as the object, wait for BUSY to clear (or about 20 clocks: one instruction), and read A·B with one `LDIR` of 18 bytes. With the object's position P = B's translation and the camera's C = 0, T = A·P as well. This gives a part's matrix in a model built of parts (a turret on a tank: tank × turret), or a camera's matrix from two turns.

### 4.2 Vertex

Writing VZ1 starts a vertex with v = (VX, VY, VZ). GEOCTL picks what is done:

| GEOCTL.CAM | GEOCTL.INV | Result (X, Y, Z) | Used for |
|------------|------------|------------------|----------|
| 0 | 0 | M·v + T = Mc·(Mo·v + P − C) | An object's vertices in camera space |
| 1 | 0 | Mc·(v − C), v − C wrapped | A point in the world in camera space: an object's centre for culling |
| 0 | 1 | Mᵀ·(v − T) | The inverse turn: the eye (v = 0) in the model's space, for testing faces against the eye |
| 1 | 1 | Mcᵀ·v + C, the + C wrapped | The inverse of CAM: a camera-space point back in the world |

The transpose undoes a rotation exactly. For a matrix that also scales, INV does not undo it.

With **GEOCTL.PROJ** set, the result is then projected:

- If Z < ZMIN, GEOSTAT.NEAR is set and the result stays (X, Y, Z), unprojected, so software can cut the edges at the near plane or drop the vertex.
- Otherwise RX = SCX + ⌊DX·X ÷ Z⌋ and RY = SCY − ⌊DY·Y ÷ Z⌋, each saturated; RZ = Z.

DX and DY are the distance to the screen in pixels, across and down. They differ when the pixels are not square. ZMIN below 1 counts as 1, so the unit never divides by zero or a negative depth. Camera space has x to the right, y up and z into the screen; screen y runs down.

### 4.3 Face sign

Writing F2Y1 (in the operands bank) starts a face sign on three screen points (F0X, F0Y), (F1X, F1Y), (F2X, F2Y):

- s = (F1X − F0X)·(F2Y − F0Y) − (F1Y − F0Y)·(F2X − F0X), exact inside.
- RX = s bits 15–0, RY = s bits 31–16, saturated to 32 bits (SAT if it was).
- GEOSTAT.FRONT = 1 if s ≥ 0, from the exact value.

With the screen's y running down, a face wound anticlockwise as seen from outside gives s ≥ 0 when it looks towards the eye; an edge-on face counts as towards it. These are the same rules fast3d's `facing_edges` uses.

### 4.4 Multiply

Writing MB1 (in the operands bank) starts MA × MB, both signed 16-bit. RX = product bits 15–0, RY = bits 31–16. It never saturates.

### 4.5 Divide

Writing DVS1 (in the operands bank) starts DVD ÷ DVS: DVD is signed 32-bit (DVD0–DVD3), DVS signed 16-bit.

- RX = the quotient, rounded towards zero, saturated to 16 bits (SAT if it was).
- RY = the remainder, with the dividend's sign. When the quotient saturates, RY is 0.
- DVS = 0 sets GEOSTAT.DIVZ; RX = +32767 (dividend ≥ 0) or −32768, and RY = 0.

For the near-plane cut, t = (ZMIN − az) ÷ (bz − az) as a 16-bit fraction is DVD = (ZMIN − az) × 65,536, DVS = bz − az, with the edge's ends a and b. The quotient fits as long as t < 0.5; for longer cuts, shift both down a bit first.

### 4.6 One job at a time

A job's operands are taken when it starts, so the next vertex's bytes can be written while one is running. The results (RX, RY, RZ) and GEOSTAT's job bits (NEAR, SAT, DIVZ, FRONT) change only when a job ends, and the next job replaces them. A job that doesn't write RZ (face sign, multiply, divide) leaves it unchanged.

Every job is done within 24 clocks of its start write; the longest, a projected vertex, takes 22. The CPU cannot read sooner. The soonest read after a write is the next instruction's: `LD (HL),C` then `LD A,(DE)` through the register page, 7 T-states apart at 20 MHz, with the read about 25–30 clocks after the write. The board test reads every job's first result that way, so the CPU never sees BUSY at any speed. A start write that came while a job ran would be held and run after it. The CPU cannot make one; a list mode might (open point G2).

## 5. Registers

Registers of the system page `0x00` (spec 3): port = (register << 8) | `0x00`, written with `LD BC,port` then `OUT (C),r`. The same registers are at register page offsets `0x00A0`–`0x00BF`. Multi-byte values are low byte first; each byte is written directly (spec 3, rule 2).

**Write the starting byte last.** VZ1, F2Y1, MB1 and DVS1 start their jobs, so they are written after the rest of the job's operands, as the MMU pages and the colours need their last byte last (spec 3, rule 10). Rising writes do this: `LD (nn),HL` for each word, `LDI` or `LDIR`, or `OUT (C),r` with `INC B`. `PUSH`, `LDDR` and unrolled `OUTI`s write the high byte first, so they start the job early.

### 5.1 The window and its banks

GEOCTL.BANK picks what registers `0xA0`–`0xB7` show: twelve 16-bit words. Banks 5–7 are reserved: they read 0 and ignore writes.

| Register | Port | Bank 0: camera | Bank 1: object | Bank 2: view | Bank 3: operands | Bank 4: product (R) |
|----------|------|----------------|----------------|--------------|------------------|---------------------|
| `0xA0`–`0xA1` | `0xA000`–`0xA100` | CM11 | OM11 | DX | F0X | M11 |
| `0xA2`–`0xA3` | `0xA200`–`0xA300` | CM12 | OM12 | DY | F0Y | M12 |
| `0xA4`–`0xA5` | `0xA400`–`0xA500` | CM13 | OM13 | SCX | F1X | M13 |
| `0xA6`–`0xA7` | `0xA600`–`0xA700` | CM21 | OM21 | SCY | F1Y | M21 |
| `0xA8`–`0xA9` | `0xA800`–`0xA900` | CM22 | OM22 | ZMIN | F2X | M22 |
| `0xAA`–`0xAB` | `0xAA00`–`0xAB00` | CM23 | OM23 | – | F2Y (F2Y1 starts a face sign) | M23 |
| `0xAC`–`0xAD` | `0xAC00`–`0xAD00` | CM31 | OM31 | – | MA | M31 |
| `0xAE`–`0xAF` | `0xAE00`–`0xAF00` | CM32 | OM32 | – | MB (MB1 starts a multiply) | M32 |
| `0xB0`–`0xB1` | `0xB000`–`0xB100` | CM33 | OM33 | – | DVD0, DVD1 (dividend bits 15–0) | M33 |
| `0xB2`–`0xB3` | `0xB200`–`0xB300` | CPX | OPX | – | DVD2, DVD3 (dividend bits 31–16) | TX |
| `0xB4`–`0xB5` | `0xB400`–`0xB500` | CPY | OPY | – | DVS (DVS1 starts a divide) | TY |
| `0xB6`–`0xB7` | `0xB600`–`0xB700` | CPZ | OPZ | – | – | TZ |

- **Camera:** CM11–CM33, the camera's matrix Mc, row by row (2.14), and CPX, CPY, CPZ, its position C in the world. Mc turns world directions into camera space: for a camera turned by Rc, Mc = Rcᵀ.
- **Object:** OM11–OM33, the object's matrix Mo (2.14), and OPX, OPY, OPZ, its position P in the world.
- **View:** DX, DY (distance to the screen, in pixels across and down), SCX, SCY (the screen point straight ahead), ZMIN (the near plane). Words marked – read 0 and ignore writes.
- **Product:** M11–M33, the combined matrix M = Mc·Mo (2.14), and TX, TY, TZ, its translation T = Mc·(P − C) (section 4.1). Read only: writes are ignored. While BUSY is set for the combined matrix, a read may give an entry from before.
- **Operands:** the face sign's three points, the multiply's MA and MB, and the divide's DVD and DVS. Word 11 reads 0 and ignores writes.

Every word except the reserved ones reads back what was written. Each bank is a matrix, its position, or a set of values, so a camera or an object loads with one `LDIR` of 24 bytes through the register page. The bank changes only when GEOCTL is written.

### 5.2 Vertex, results, control and status

| Register | Port | Name | Access | Bits | Reset | Description |
|----------|------|------|--------|------|-------|-------------|
| `0xB8` | `0xB800` | VX0 / RX0 | RW | 7–0 | `0x00` | Write: x bits 7–0. Read: result RX bits 7–0 |
| `0xB9` | `0xB900` | VX1 / RX1 | RW | 7–0 | `0x00` | Write: x bits 15–8. Read: RX bits 15–8 |
| `0xBA` | `0xBA00` | VY0 / RY0 | RW | 7–0 | `0x00` | Write: y bits 7–0. Read: RY bits 7–0 |
| `0xBB` | `0xBB00` | VY1 / RY1 | RW | 7–0 | `0x00` | Write: y bits 15–8. Read: RY bits 15–8 |
| `0xBC` | `0xBC00` | VZ0 / RZ0 | RW | 7–0 | `0x00` | Write: z bits 7–0. Read: RZ bits 7–0 |
| `0xBD` | `0xBD00` | VZ1 / RZ1 | RW | 7–0 | `0x00` | Write: z bits 15–8, and **starts a vertex**. Read: RZ bits 15–8 |
| `0xBE` | `0xBE00` | GEOCTL | RW | BANK (2–0), PROJ (3), CAM (4), INV (5) | `0x00` | The window's bank (section 5.1); project vertices; the camera alone; the inverse turn (section 4.2). Bits 7–6 read 0 |
| `0xBF` | `0xBF00` | GEOSTAT | R, W1C | BUSY (0), NEAR (1), SAT (2), DIVZ (3), FRONT (4), SATS (7) | `0x00` | Section 5.3 |

The vertex registers are write-only and the results read-only, at the same addresses. Reading VX0 does not give back the x written. The results are not counters the hardware moves by itself, so a read needs no capture (spec 3, rule 4): they hold still until the next job ends.

Names in `fpga/regmap.def`: `GEOW0` … `GEOW11` (the window's words), `GEOVX`, `GEOVY`, `GEOVZ` (bytes `GEOVX0` … `GEOVZ1`; the results are read at the same numbers), `GEOCTL`, `GEOSTAT`, the field masks `GEOCTL_PROJ_M`, `GEOCTL_CAM_M`, `GEOCTL_INV_M`, `GEOSTAT_NEAR_M` and so on, the word names `GEO_CM11` … `GEO_CPZ`, `GEO_OM11` … `GEO_OPZ`, `GEO_DX` … `GEO_ZMIN`, `GEO_F0X` … `GEO_DVS` (with `GEO_DVD` and `GEO_DVDHI` for the dividend's two words) and `GEO_M11` … `GEO_TZ` (each the register of its low byte), the banks `GEO_BANK_CAM` = 0, `GEO_BANK_OBJ` = 1, `GEO_BANK_VIEW` = 2, `GEO_BANK_OPS` = 3, `GEO_BANK_PROD` = 4, and the `_P` port forms, as for the other blocks.

### 5.3 Status bits

| Bit | Name | Meaning |
|-----|------|---------|
| 0 | BUSY | A job (or the combined matrix) is being worked out. Live; the CPU never sees it set (section 4.6) |
| 1 | NEAR | The last vertex had Z < ZMIN with PROJ set: its results are X, Y, Z, unprojected |
| 2 | SAT | Some result of the last job saturated (or the combined matrix it used did) |
| 3 | DIVZ | The last job was a divide by zero |
| 4 | FRONT | The last face sign was 0 or more: the face looks towards the eye |
| 7 | SATS | Some job has saturated since SATS was last cleared. Sticky; write 1 to clear |

NEAR, SAT, DIVZ and FRONT belong to the last job and are replaced by the next; writes to them are ignored. Bits 6–5 read 0. Software that checks for saturation once per object clears SATS, runs the object's vertices, and reads it once.

**After reset:** every register 0: bank 0, no projection; matrices all 0, so every vertex gives (0, 0, 0). Software loads its matrices and view first.

## 6. Examples

The examples have the register page in window 7 (`0xE000`), so the geometry registers are at `0xE0A0`–`0xE0BF`.

```
GEO     EQU 0xE000 + GEOW0    ; the window, through the register page
GEO_V   EQU 0xE000 + GEOVX    ; VX0 / RX0
GEO_CTL EQU 0xE000 + GEOCTL
GEO_ST  EQU 0xE000 + GEOSTAT
```

### 6.1 Setting up the view

```
        LD   A,GEO_BANK_VIEW
        LD   (GEO_CTL),A
        LD   HL,view          ; DX, DY, SCX, SCY, ZMIN
        LD   DE,GEO
        LD   BC,10
        LDIR
        LD   A,GEO_BANK_CAM
        LD   (GEO_CTL),A
        LD   HL,camera        ; Mc (9 words), then C (3 words)
        LD   DE,GEO
        LD   BC,24
        LDIR                  ; 504 T-states
        ...
view:   DW   256, 256, 180, 144, 16   ; 360 x 288 screen, square pixels
```

### 6.2 An object's vertices

Load the object's bank, turn on projection, then send each vertex and read its screen point. Each vertex is 6 bytes in, 6 out.

```
        LD   A,GEO_BANK_OBJ
        LD   (GEO_CTL),A
        LD   HL,object        ; Mo (9 words), P (3 words)
        LD   DE,GEO
        LD   BC,24
        LDIR                  ; the unit works out M and T itself
        LD   A,GEO_BANK_OBJ | GEOCTL_PROJ_M
        LD   (GEO_CTL),A
        LD   HL,model         ; x, y, z words
        LD   IX,points        ; sx, sy, z words
        LD   BC,6 * NVERTS    ; LDI counts BC down, 6 a vertex
vloop:  LD   DE,GEO_V
        LDI                   ; 16 T each: x, y, z, rising, so VZ1 goes last
        LDI
        LDI
        LDI
        LDI
        LDI                   ; starts the vertex; P/V = 0 after the last one
        LD   DE,(GEO_V)       ; RX: sx (or X if NEAR)
        LD   (IX+0),E
        LD   (IX+1),D
        LD   DE,(GEO_V+2)     ; RY
        LD   (IX+2),E
        LD   (IX+3),D
        LD   DE,(GEO_V+4)     ; RZ
        LD   (IX+4),E
        LD   (IX+5),D
        LD   DE,6
        ADD  IX,DE            ; leaves P/V alone
        JP   PE,vloop
```

That is 316 T-states a vertex as written (1,024 vertices in 16,160 µs on the KS2). A tight loop that reads the model with `POP`, writes each word with `LD (nn),HL`, reads only sx and sy with `LD HL,(nn)` and `PUSH`es them back over the vertex (interrupts off) takes 172 (1,024 vertices in 8,821 µs on the KS2; `examples/geometry/geomtest.asm`). The unit's own 0.2 µs is a small part of either: the Z80's byte moves are the limit, about 16 T-states a byte. A list mode (open point G2) would remove them. fast3d's software vertex takes 2,330. The NEAR bit is worth reading only for objects that cull says reach the near plane.

### 6.3 Culling an object by its centre

```
        LD   A,GEO_BANK_CAM | GEOCTL_CAM_M   ; camera alone, no projection
        LD   (GEO_CTL),A
        LD   HL,(obj_px)
        LD   (GEO_V),HL
        LD   HL,(obj_py)
        LD   (GEO_V+2),HL
        LD   HL,(obj_pz)
        LD   (GEO_V+4),HL     ; starts: the centre in camera space
        LD   HL,(GEO_V+4)     ; Z: behind the near plane, or too far?
        ...                   ; then |X| and |Y| against Z / 2 + the radius
```

## 7. Implementation

| Part | How |
|------|-----|
| Banks | Four writable banks of twelve 16-bit words in flip-flops for the unit, with a shadow copy in distributed RAM for the bus to read back; the product bank (M and T) read from its flip-flops in distributed RAM, written by the register bus, read by the bus and by the unit |
| Multiplies | Three DSP48E1 slices, one per row, each a whole multiply-accumulate (P + A×B, cleared at the start of a pass). A row takes four products: its three entries times the vector, then (2T + 1) × `0x2000`, which adds the translation and the rounding constant in one step. A pass is 6 clocks: load, 4 products, round and saturate |
| Projection | Two dividers, one for X and one for Y, restoring, two quotient bits a clock: 18 bits in 9 clocks; DX·X and DY·Y on two more DSP slices |
| Face sign, multiply | On the row slices |
| Divide | One of the two dividers, 16 quotient bits plus a saturation check |
| A vertex | 1 to take the start, 1 to load, 4 to turn, 1 to round and saturate, 1 to test NEAR and multiply by DX and DY, 1 to start the dividers, 10 to divide, 1 to add SCX and SCY: 20–22 clocks of the 24 allowed. Without PROJ, 8 |

## 8. FPGA resources and builds

| Item | Resource |
|------|----------|
| Banks, control, rounding and saturation, two dividers, the job sequencer | 1,447 LUTs and 1,526 flip-flops on the KS2 (30 October 2026), against an estimate of 500–700 LUTs. The first build was 1,793; then the accumulators moved into their DSP slices, banks 0–3 read back from a 96-byte shadow copy in distributed RAM (16 LUTs) instead of a multiplexer over 40 words, and one subtractor a row serves v − C, P − C and v − T (open point G7) |
| DSP | 8 (of 45 on the KS2, 90 on the KS3): 3 row MACs, DX·X and DY·Y, the face sign's two products, the multiply |
| Block RAM | None |
| Lines out | None (interrupt 19 reserved) |

The KS2 has no room for the unit beside the DMA engine: that build already has 2 sprites and no mask image (design plan, branch 21). So `top_ks2.v` takes a build option, **`GEOM = 1`**, that builds the geometry unit and leaves the DMA engine out. The default KS2 build stays as it is. Without the unit (`GEOM = 0`) its registers read `0xFF` and ignore writes, as any reserved register. The KS3 builds both.

## 9. Test plan

- **Model:** `tools/geom_model.py` defines every job's result bit for bit, as fast3d's `model.py` does. Every test checks against it.
- **Unit (Verilator):** each job on random operands and on the edges: entries ±2.0, coordinates ±32767 and −32768, the largest sums (each row at its most), P − C across the wrap, Z = ZMIN − 1, ZMIN and ZMIN ≤ 0, DX·X ÷ Z past ±32767, DVS = 0, a quotient just in and just out of range, s = 0 for the face sign. Results, NEAR, SAT, DIVZ, FRONT and SATS.
- **Combined matrix:** after any one byte of the camera or the object changes, the next vertex uses the new M and T; a vertex started straight after the last byte of a 24-byte `LDIR` is right.
- **Round trips:** CAM then CAM + INV gives the point back for a rotation; INV with v = 0 gives the eye in the model's space.
- **Timing:** every job is done within 24 clocks of its start write, with and without a combined matrix pending. GEOSTAT.BUSY is set while it runs. Operands written during a job don't change it.
- **Bus:** every register through ports and through the register page; `LD (nn),HL` and `LDI` rising start a vertex after all six bytes; `PUSH` starts it after VZ1 alone (documented, not wanted); bank switching; reserved words read 0; with `GEOM = 0`, `0xFF`.
- **On the KS2 (`GEOM = 1`):** a test program sends a few thousand vertices, faces, multiplies and divides and compares each result with tables from the model, then reports over serial.
- **Benchmark:** fast3d's flight (40 objects, wireframe) ported to retro-z80 twice, the software path and the unit, timed in frames a second and T-states a frame against fast3d's 468,000. The time left in culling, line drawing and clipping answers open point G1.

## 10. Open points

| # | Item |
|---|------|
| G1 | Drawing help for filled polygons (design plan, Q10): OP 6 span fill or OP 7 triangle in the DMA engine, codes agreed with retro68k (spec 14, D6). Decided after the benchmark (section 9) shows where the time goes once vertices are cheap. Amiga-style line drawing (branch 21) is part of the same choice |
| G2 | A list mode: the unit as a bus master that turns a vertex list in SRAM and writes the screen points back, with interrupt 19 (GEOM) at the end. About 300–500 LUTs and a scheduler client. Decided after the benchmark |
| G3 | The 30-clock limit is set by the fastest CPU read after a write (section 4.6). A faster CPU (design plan, Q9) would need a check again |
| G4 | A dot product (n·v of two 3-vectors) for testing faces against the eye in 3D and for lighting. Left out for now: the inverse turn and a few multiplies do it |
| G5 | Closed (30 October 2026): the product bank (bank 4) reads M and T back, so the unit is also a 3×3 matrix multiplier; GEOCTL.BANK is 3 bits |
| G6 | The test for a face against the eye in 3D (fast3d's `FACE_EYE`) uses INV with v = 0 and then three multiplies a face. A "plane test" job (n·U > D) may be worth it once faces are filled |
| G7 | Partly done (30 October 2026): 1,793 to 1,447 LUTs (section 8). What is left is mostly the operand multiplexers into the row slices and the two dividers; sharing one divider would save about 120 LUTs but put RY about 10 clocks past the soonest read. The KS2 build is 95% full with the unit |
