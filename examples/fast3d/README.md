# fast3d's flight on retro-z80

fast3d's demo, moved to retro-z80 as a benchmark for the geometry unit (spec 15, ticket #68): forty turning cubes and icosahedra round a circle the camera flies, wireframe, clipped to a window, each picture drawn on the screen not shown. It runs in software, as fast3d does, or with the culling and the vertices through the geometry unit. It times 256 pictures, a whole circle, prints the results on the console and returns to the monitor.

The results and what they decided are in spec 15, section 10.

## Where it comes from

fast3d is in [zx-spectrum-emulator/examples/fast3d](https://github.com/jonsole/zx-spectrum-emulator/tree/master/examples/fast3d), commit `1534bc5` (23 October 2026). Copied unchanged: `engine/*.s`, `fast3d.s` and `model.py`. Changed:

| File | From | Change |
|---|---|---|
| `build.py` | fast3d's `build.py` | The screen's row table and `draw_line`'s blocks for this screen; the models carry a radius in world units and their vertices as words for the unit; a times-129 table; one program in four builds. The check builds and the snapshot are left out |
| `fast3d.asm` | fast3d's `demo.s` | retro-z80's screen, interrupts and memory; no keys; the timing and the report; `IF GEOM` calls into `geom.asm` |
| `geom.asm` | New | The unit's camera, cull, object, vertices and back faces |

## Building and running

```
python build.py [--geom] [--faces] [--phases] [--20mhz]
```

| Option | Effect |
|---|---|
| (none) | The software engine, as fast3d: `build/fast3d.bin` |
| `--geom` | Culling and vertices through the geometry unit. Needs the KS2's `GEOM = 1` build (`fpga/ks2/build.sh --geom`) or the KS3 |
| `--faces` | Each object loses its back edges: fast3d's `facing_edges`, or with `--geom` the unit's face sign |
| `--phases` | Times each part of a picture as well |
| `--line` | Lines drawn by the DMA engine (`dmaline.asm`): each object's edges by one EDGES job (spec 14, section 3.5), its points copied into 4-byte records first; the lines cut at the near plane by LINE jobs (section 3.4); all clipped by the engine's clip rectangle. Needs the KS2's `--no-copper` build |
| `--dmaclear` | The last picture's box cleared by a DMA engine BLIT fill (`dmaclear.asm`) instead of `clear_box`: the vertical blank starts it on the screen it has just stopped showing, and `render_frame` waits for it. Needs a build with the DMA engine (any KS2 build but `--geom`) |
| `--20mhz` | The CPU at 20 MHz. Without it, every build runs at 3.57 MHz (CPUSPEED.SPECTRUM), as a Spectrum, and puts the speed back at the end |

The output is `build/fast3d[_geom][_line][_faces][_dmaclear][_phases][_20mhz].bin`, with its SLD. VS Code's Run and Debug has **Debug fast3d on the board** and **Debug fast3d with the geometry unit on the board**, which build and launch the 3.57 MHz builds.

At 3.57 MHz, timer 0 ticks every 56 system clocks, still 2 T-states, and the times are read as 32 bits, since a picture can take over 65 ms. Load and run it at `0x8000`, for example with the retro-z80 MCP's `launch`. The generated tables and code go to `output/`.

## How it works

- **The screen** is 256 × 192 at 1 bit per pixel, 32 bytes a line, shown at 2 × 2 in the middle of the picture: 6,144 bytes, like the Spectrum's, so clearing costs the same. The KS2 builds one layer, so the program borrows L0 from the console, as the blitter examples do, and gives it back at the end. Two screens, at physical `0x040000` and `0x042000`: each picture is drawn on the one not shown, mapped into window 7, and the vertical blank interrupt shows it.
- **Lines** use fast3d's unrolled blocks. Along y, fast3d stepped down a row with `INC H`; here rows are 32 bytes apart, so seven rows in eight add 32 to L and the eighth moves H on too. That costs 19 T-states a row more.
- **Memory** is the boot ROM's program map: the register page in window 1 (`0x2000`), the points and the objects drawn at `0x4000`, the stack and the IM 2 table below `0x7F00`, the code from `0x8000`, the screen being drawn in window 7 (`0xE000`).
- **Timing.** A picture's time is `compute_frame` and `render_frame`, from TIME, as fast3d's 468,000 is; the wait for the flip is not counted. With `--phases`, a mark round each part reads timer 0 (SRC 0, PRESCALE 9: 2 T-states a tick) and adds the ticks to the part that was running. A mark costs 330 T-states, and each part pays for one mark each time it starts, so the report takes that back out; the parts then add up to within 0.3% of the build without marks.
- **With the unit** (`geom.asm`): the camera bank gets Mc = Rcᵀ and C each picture; each object's centre is turned by CAM and tested against the near and far planes and the sides, as fast3d's cull does, in world units; each object drawn gets its matrix from fast3d's `compute_matrix` into the object bank, and its vertices go through PROJ into the same point tables `transform_object` fills, so drawing is unchanged. fast3d's matrix entries (127 for 1.0) become 2.14 by a table, times 129.

## Results (KS2, 30 October 2026)

| Build | T-states a picture | Pictures a second |
|---|---|---|
| fast3d on a Spectrum 128K, 3.5 MHz (its README) | 468,000 | about 7 |
| Software, 3.57 MHz | 474,395 | 7.5 |
| The unit, 3.57 MHz | 269,244 | 13.1 |
| Software, 20 MHz | 472,907 | 39.1 |
| Software, back faces removed, 20 MHz | 541,942 | 35.1 |
| The unit, 20 MHz | 268,245 | 50 |
| The unit, back faces removed, 20 MHz | 278,338 | 50 |
| Software, lines by the DMA engine (EDGES), 20 MHz | 351,912 | 47.5 |
| Software, cleared by a DMA fill, 20 MHz (31 October) | 433,002 | 41.5 |
| Software, EDGES and the DMA fill, 20 MHz (31 October) | 311,801 | 48.4 |

With `--line`, lines and clipping take 10,408 T-states a picture (copying the points into records and starting a job an object, plus 418 waiting for the engine) against 106,192 in software, and the drawing loop's other work halves, from 51,000 to 26,000. A first version with a LINE job a line took 66,391: the Z80's setup of each line cost about as much as drawing it. The engine and the unit together need the KS3.

With `--dmaclear`, clearing goes from 40,679 T-states a picture to 74: the fill runs while the Z80 works out the next picture, and has always finished by the time `render_frame` needs the screen.

A picture takes about 1,500 more T-states at 3.57 MHz than at 20 MHz (0.3%). Probably most of it is the vertical blank interrupt, which comes about six more times a picture at the slower speed; not measured.

Spec 15, section 10 has where the time goes.

## Not done

- **The near plane with the unit.** A vertex behind the near plane is left out, with its edges; fast3d cuts them at the plane. The flight never comes that close.
- **The unit with the DMA engine** (`--geom` with `--line` or `--dmaclear`). The KS2's `GEOM = 1` build has no DMA engine; the KS3 has both.
- **A check against the model.** fast3d's `check.py` compares every picture with `model.py` in SkoolKit's simulator, on the Spectrum's screen. Here the pictures were checked by eye on the board, and the objects drawn (5.1 a picture in software, as fast3d) and the times agree with fast3d's.
