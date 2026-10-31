// Video (spec 4): the 576p beam, the layers' registers and pixel pipeline,
// the palettes, priority and the background colour. retro68k's video.v,
// narrowed to byte registers on the 8-bit register bus.
//
// Layers as chunky bitmaps (ticket #13: 1, 2, 4 or 8 bits per pixel, 1x-8x,
// window, live pointer with stride and wrap, fine scroll, TRANSP, PALOFS)
// or tile maps (ticket #14: 8 x 8 tiles at 1-8 bits per pixel, MAPPT and
// PATPT, maps of 32-128 entries each way, SCROLLX and SCROLLY round the map,
// PAL, XFLIP, YFLIP, PRI), fetched just in time by bpldma.v through the
// scheduler (dmac.v), shown by layer_pix.v. NL sets how many layers are
// built (1-3): the registers of layers not built read 0xFF and PRIO naming
// them shows nothing. Not yet: direct colour (VIDCON.DIRECT is kept and
// read back) and the attribute layer. Ticket #16 added VIDINTEN and the request line to the
// interrupt controller (VBLANK); ticket #21 the border from port 0xFE
// writes. Ticket #31 added the sprites (spec 5; sprites.v, sprite_pix.v; NS
// of them built), their place among the layers by DEPTH, SPRPALETTE and
// the collisions, VIDSTAT.SPRUNDER and the VIDERR request. Ticket #32 added
// the copper's side (spec 6): the beam and the frame start for it, its own
// colour assembly buffer (rb_cop marks its writes) and DMACON.COPEN. Ticket
// #53 added BEAMPOS and FRAMECOUNT (counted on the pixel side, sampled with
// the beam, handed to the CPU's capture), LINECMP and the LINE request.
//
// Registers (custom block, spec 4, section 6):
//   VIDCON    0x000  EN (0) starts the beam; BLANKALL (2) shows BGCOLOR only;
//                    DIRECT (4) kept; SHAREPAL (5) all layers on PALETTE0
//   VIDSTAT   0x001  VBLANK (0), OVERRUN0-2 (4-6), SPRUNDER (7): sticky,
//                    write 1 to clear; INVBLANK (3), live
//   VIDINTEN  0x002  enables for VIDSTAT's flags, bits 0-2 and 4-7 (bit 3
//                    reads 0); irq is on while VBLANK and its enable are,
//                    irq_err while OVERRUN0-2 or SPRUNDER and its enable
//                    are (spec 4, section 3.4; spec 8: VBLANK is source 0,
//                    VIDERR source 3)
//   PRIO      0x003  FRONT, MIDDLE, BACK; reset 0x24
//   BGCOLOR   0x004  blue, green, red; the red byte commits (spec 3, rule 7)
//   port 0xFE        (register 0x00FE) writes: bits 2-0 set BGCOLOR to a
//                    Spectrum colour at 0xD7, shown at once, mid-line (spec
//                    4, section 7.2); keys.v answers its reads
//   PALIDX    0x009  entry (7-0), palette (9-8)
//   PALDAT    0x00B  blue, green, red of the entry at PALIDX
//   DMACON    0x00C  set/clear: DMAEN (6), BPLEN (5), COPEN, BLTEN, SPREN, AUDEN
//   sprites   0x010 + n x 0x10, SPRDMA 0x120, SPRCOLL 0x124: in sprites.v
//   layers    0x090 + n x 0x20: CTRL0-CTRL3, WINX, WINY, SCROLLX, SCROLLY
//                    here; BPLSTRIDE, BPL0PT, MAPPT and PATPT in bpldma.v
//   VIDSIZE   0x0F6  720 x 576, read only
//   palettes  register page 0x1400-0x1FFF, 3 bytes per entry (spec 4, 6.5)
//
// Blue and green bytes of a colour (BGCOLOR, PALDAT, the palettes in the
// register page) go into the CPU's colour assembly buffer; the red byte
// writes the colour whole. Each master has its own buffer: the CPU's (cab)
// and the copper's (ccab, for its writes, rb_cop); the DMA engine gets one
// when it comes. PALIDX and PALDAT's byte counter are kept per master too, as
// retro68k keeps its palette's held half per writer: the CPU reads its own.
//
// Two clock domains, asynchronous to each other (spec 4, section 3.1):
//   clk      100 MHz: registers, the layer fetch, palette writes
//   clk_pix   27 MHz: the beam and the pixel pipeline
//   clk_pix5 135 MHz: the fast synchroniser of "full" (layer_pix.v)
// Crossings as retro68k: events are toggles through two flip-flops; the
// data registers cross under the full/taken handshake (bpldma.v,
// layer_pix.v); the beam (line and pixel) is sampled on the system side
// until two samples agree; the sprites' FIFOs cross with Gray-coded
// pointers and their flushes with a toggle handshake (sprites.v); the layer settings, PRIO and BGCOLOR are settings, copied
// into the pixel domain once per line (a write that lands exactly on that
// copy may take effect one line later); a port 0xFE border write crosses as
// a toggle at 135 MHz, as "full", with its 3-bit colour beside it; the
// palette is a two-clock RAM.
`include "regmap.vh"

module video #(
    parameter NL = 1,                  // layers built (1-3)
    parameter NS = 8                   // sprites built (1-8)
) (
    input  wire        clk,            // 100 MHz
    input  wire        rst,

    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [12:0] rb_addr,
    input  wire [7:0]  rb_wdata,
    output wire [7:0]  rb_rdata,
    output wire        rb_hit,         // with rb_rdata: this unit answered
    output wire [31:0] rb_cdata,       // with rb_rdata: SPRxPT, BPL0PT, BEAMPOS or FRAMECOUNT whole, for the CPU's capture
    output wire        rb_cap,
    input  wire        rb_cop,         // the write on the bus is the copper's (its colour buffer)

    output wire        frame_tick,     // 1 clock (100 MHz) at the start of each frame
    output wire        line_tick,      // 1 clock (100 MHz) at the start of each beam line (timers, #17)
    output wire        irq,            // to the interrupt controller: source VBLANK (0)
    output wire        irq_line,       // ... source LINE (1)
    output wire        irq_err,        // ... and source VIDERR (3)

    // For the copper (spec 6): the beam as the memory side sees it, and DMACON
    output wire [10:0] beam_v,
    output wire [10:0] beam_h,
    output wire        cop_on,         // DMACON.DMAEN and COPEN
    output wire        blt_on,         // DMACON.DMAEN and BLTEN (the DMA engine, spec 14)

    // The scheduler's layer channel (dmac.v)
    output wire        disp_req,
    output wire        disp_urgent,
    output wire [9:0]  disp_deadline,
    output wire [21:1] disp_addr,
    input  wire        disp_ack,
    input  wire        disp_rvalid,
    input  wire [15:0] disp_rdata,

    // The scheduler's sprite channel (the same read data)
    output wire        spr_req,
    output wire        spr_urgent,
    output wire [9:0]  spr_deadline,
    output wire [21:1] spr_addr,
    input  wire        spr_ack,
    input  wire        spr_rvalid,

    input  wire        clk_pix,        // 27 MHz
    input  wire        clk_pix5,       // 135 MHz, edges lined up with clk_pix's
    output reg  [23:0] rgb,            // RRGGBB
    output reg         hsync,          // active low
    output reg         vsync,          // active low
    output reg         de
);
    // ================================================================ the mode (section 3.2)
    // 576p50 (CEA-861 format 17/18): 864 x 625 at 27 MHz, both syncs active low
    localparam [10:0] HVIS = 11'd720;
    localparam [10:0] HSS  = 11'd732;       // front porch 12
    localparam [10:0] HSE  = 11'd796;       // sync 64, back porch 68
    localparam [10:0] HTOT = 11'd864;
    localparam [10:0] VVIS = 11'd576;
    localparam [10:0] VSS  = 11'd581;       // front porch 5
    localparam [10:0] VSE  = 11'd586;       // sync 5, back porch 39
    localparam [10:0] VTOT = 11'd625;
    // Beam coordinates (section 3.3): (0, 0) is the start of the horizontal
    // and vertical blanks, so the picture is pixels BH0-863, lines BV0-624.
    // Inside, the counters hc and vc stay picture-relative (0 = the first
    // pixel, the first line), as in retro68k.
    localparam [10:0] BH0  = HTOT - HVIS;   // 144
    localparam [10:0] BV0  = VTOT - VVIS;   // 49

    // ================================================================ registers (100 MHz)
    reg  [5:0]  vidcon;                // SHAREPAL (5), DIRECT (4), BLANKALL (2), EN (0)
    reg         vs_vblank;             // VIDSTAT.VBLANK
    reg         vs_line;               // VIDSTAT.LINE
    reg  [10:0] lc_v;                  // LINECMP: read by the pixel side, a setting
    reg  [2:0]  vs_over;               // VIDSTAT.OVERRUN0-2
    reg         vs_sprunder;           // VIDSTAT.SPRUNDER
    reg  [5:0]  prio;
    reg  [7:0]  vidinten;              // VIDINTEN; bit 3 always 0
    reg  [23:0] bgcolor;               // RRGGBB
    reg  [15:0] cab;                   // the CPU's colour assembly buffer: green, blue
    reg  [15:0] ccab;                  // ... and the copper's
    wire [15:0] wcab = rb_cop ? ccab : cab;   // the buffer of the write on the bus
    // A port 0xFE write's colour, and its toggle to the pixel side (not
    // reset: the pixel side follows the toggle, whatever it holds)
    reg  [2:0]  fe_col = 3'd0;
    reg         fe_t = 1'b0;
    reg  [6:1]  dmacon;                // DMAEN (6), BPLEN (5), COPEN, BLTEN, SPREN, AUDEN (1)
    reg  [9:0]  palidx;
    reg  [1:0]  pcnt;                  // PALDAT's byte: 0 blue, 1 green, 2 red
    // The copper's own PALIDX and PALDAT byte (ticket #32, spec 6 C14): what
    // it writes never moves the CPU's entry or byte, nor the CPU's its
    reg  [9:0]  palidx_c;
    reg  [1:0]  pcnt_c;
    wire [9:0]  wpidx = rb_cop ? palidx_c : palidx;   // the write on the bus
    wire [1:0]  wpcnt = rb_cop ? pcnt_c : pcnt;

    // Layers: CTRL0-CTRL3, window, SCROLLX (pointer and stride in bpldma.v)
    reg  [7:0]  l_ctrl0 [0:2];      // EN (0), BPP (3-2), TRANSP (4), MODE (5), HSCALE (7-6)
    reg  [7:0]  l_ctrl1 [0:2];      // VSCALE (1-0), PALOFS (7-4)
    reg  [7:0]  l_ctrl2 [0:2];      // WRAP (7-4)
    reg  [7:0]  l_ctrl3 [0:2];      // MAPW (1-0), MAPH (3-2)
    reg  [10:0] l_xs [0:2], l_xe [0:2], l_ys [0:2], l_ye [0:2];
    reg  [9:0]  l_sx [0:2], l_sy [0:2];

    // Layer registers: custom 0x090 + n x 0x20
    wire [7:0]  ll  = rb_addr[7:0] - 8'h90;
    wire [1:0]  ln  = ll[6:5];
    wire [4:0]  lo  = ll[4:0];
    wire        sel_lay = (rb_addr[12:8] == 5'h10) && (rb_addr[7:0] >= 8'h90) && ({1'b0, ll[7:5]} < NL)
                          && (lo <= 5'h0F);

    // From the pixel domain: the beam line and pixel, and the frame count,
    // sampled until two samples agree, so a read is never torn
    reg  [10:0] p_vline, p_hpix;
    reg  [15:0] p_frames;
    reg  [37:0] bs1, bs2;
    reg  [10:0] s_vline, s_hpix;
    reg  [15:0] s_frames;
    always @(posedge clk) begin
        bs1 <= {p_frames, p_vline, p_hpix};
        bs2 <= bs1;
        if (bs1 == bs2) {s_frames, s_vline, s_hpix} <= bs2;
    end
    wire invblank = (s_vline < BV0);
    assign beam_v = s_vline;
    assign beam_h = s_hpix;

    reg        p_vb_t;                 // toggles at the start of each frame
    reg  [2:0] vb_s;
    always @(posedge clk) vb_s <= {vb_s[1:0], p_vb_t};
    assign frame_tick = vb_s[2] != vb_s[1];

    reg        p_ln_t;                 // toggles at the start of each beam line (pixel 0)
    reg  [2:0] ln_s;
    always @(posedge clk) ln_s <= {ln_s[1:0], p_ln_t};
    assign line_tick = ln_s[2] != ln_s[1];

    reg        p_lc_t;                 // toggles at the start of beam line LINECMP
    reg  [2:0] lc_s;
    always @(posedge clk) lc_s <= {lc_s[1:0], p_lc_t};
    wire       line_ev = lc_s[2] != lc_s[1];

    wire [2:0] ov_t;                // OVERRUN toggles from the layer units
    (* ASYNC_REG = "TRUE" *) reg [2:0] ov_s1, ov_s2;
    reg  [2:0] ov_s3;

    assign irq     = vs_vblank && vidinten[`RM_VIDINTEN_VBLANK];
    assign irq_line = vs_line && vidinten[`RM_VIDINTEN_LINE];
    assign irq_err = |({vs_sprunder, vs_over} & vidinten[7:4]);
    wire [7:0] p_un;                // the sprites' underrun toggles (pixel side)
    (* ASYNC_REG = "TRUE" *) reg [1:0] un_s;
    reg        un_s3;
    always @(posedge clk) begin
        un_s  <= {un_s[0], ^p_un};
        un_s3 <= un_s[1];
    end
    always @(posedge clk) begin
        ov_s1 <= ov_t;
        ov_s2 <= ov_s1;
        ov_s3 <= ov_s2;
    end
    wire [2:0] ov_ev = ov_s3 ^ ov_s2;

    // A layer is fetched, and shown, only with DMACON.DMAEN and BPLEN (spec 4,
    // section 4.1): unlike retro68k's, a layer cannot be fed by the CPU
    // (open point V5), so with its fetch off it is off, with no OVERRUN
    wire fetch_en = vidcon[0] && dmacon[6] && dmacon[5];
    assign cop_on = dmacon[6] && dmacon[4];
    assign blt_on = dmacon[6] && dmacon[3];

    wire sel_glob = (rb_addr >= `RM_VIDCON) && (rb_addr <= `RM_DMACON) ||
                    (rb_addr >= `RM_BEAMPOS0) && (rb_addr <= `RM_VIDSIZE3);

    // ---- the palettes in the register page (0x1400-0x1FFF): palette p,
    // entry i, byte b at 0x1400 + p x 0x300 + 3i + b. As the palettes are 3
    // bytes an entry and 256 entries each, offset / 3 is {p, i} and offset
    // mod 3 is b. A read looks the entry up at once (the data is due the
    // clock after the strobe); a write is decoded a clock later, for timing.
    function [11:0] div3(input [11:0] o);                 // {o / 3, o mod 3}, exact for o < 0xC00
        reg [23:0] m;
        reg [11:0] q3;
        begin
            m    = o * 12'd2731;
            q3   = {1'b0, m[22:13], 1'b0} + {2'd0, m[22:13]};
            div3 = {m[22:13], o[1:0] - q3[1:0]};
        end
    endfunction
    wire        sel_ppal = (rb_addr >= 13'h1400);
    wire [11:0] po   = rb_addr[11:0] - 12'h400;
    wire [11:0] pdr  = div3(po);
    reg         ppw;                   // a register page palette write, decoded next clock
    reg  [11:0] ppw_o;
    reg  [7:0]  ppw_d;
    wire [11:0] pdw  = div3(ppw_o);

    // Palette writes, a clock after the register bus write (two for the register page)
    reg         pw_en;
    reg  [9:0]  pw_a;
    reg  [23:0] pw_d;

    integer i;
    always @(posedge clk) begin
        pw_en <= 1'b0;
        if (rst) begin
            vidcon    <= 6'd0;
            vs_vblank <= 1'b0;
            vs_line   <= 1'b0;
            lc_v      <= 11'd0;
            vs_over   <= 3'd0;
            vs_sprunder <= 1'b0;
            prio      <= 6'b10_01_00;      // L0 in front, then L1, then L2
            vidinten  <= 8'd0;
            bgcolor   <= 24'd0;
            cab       <= 16'd0;
            ccab      <= 16'd0;
            dmacon    <= 6'd0;
            palidx    <= 10'd0;
            pcnt      <= 2'd0;
            palidx_c  <= 10'd0;
            pcnt_c    <= 2'd0;
            ppw       <= 1'b0;
            for (i = 0; i < 3; i = i + 1) begin
                l_ctrl0[i] <= 8'd0;  l_ctrl1[i] <= 8'd0;  l_ctrl2[i] <= 8'd0;  l_ctrl3[i] <= 8'd0;
                l_xs[i] <= BH0;  l_xe[i] <= HTOT;  l_ys[i] <= BV0;  l_ye[i] <= VTOT;
                l_sx[i] <= 10'd0;  l_sy[i] <= 10'd0;
            end
        end else begin
            if (frame_tick) vs_vblank <= 1'b1;
            if (line_ev)    vs_line   <= 1'b1;
            for (i = 0; i < 3; i = i + 1) if (ov_ev[i]) vs_over[i] <= 1'b1;
            if (un_s3 != un_s[1]) vs_sprunder <= 1'b1;
            if (rb_wr) case (rb_addr)
                `RM_VIDCON:   vidcon <= {rb_wdata[5:4], 1'b0, rb_wdata[2], 1'b0, rb_wdata[0]};
                `RM_VIDSTAT:  begin
                    if (rb_wdata[`RM_VIDSTAT_VBLANK]) vs_vblank <= 1'b0;
                    if (rb_wdata[`RM_VIDSTAT_LINE])   vs_line   <= 1'b0;
                    vs_over <= vs_over & ~rb_wdata[6:4];
                    if (rb_wdata[`RM_VIDSTAT_SPRUNDER]) vs_sprunder <= 1'b0;
                end
                `RM_VIDINTEN: vidinten <= rb_wdata & 8'hF7;
                `RM_PRIO:     prio <= rb_wdata[5:0];
                `RM_LINECMP0: lc_v[7:0]  <= rb_wdata;
                `RM_LINECMP1: lc_v[10:8] <= rb_wdata[2:0];
                `RM_BGCOLOR0: if (rb_cop) ccab[7:0]  <= rb_wdata; else cab[7:0]  <= rb_wdata;
                `RM_BGCOLOR1: if (rb_cop) ccab[15:8] <= rb_wdata; else cab[15:8] <= rb_wdata;
                `RM_BGCOLOR2: bgcolor   <= {rb_wdata, wcab};
                `RM_ULA:      begin                     // port 0xFE: the border, at once (spec 4, 7.2)
                    bgcolor <= spectrum({1'b0, rb_wdata[`RM_ULA_BORDER]});
                    fe_col  <= rb_wdata[`RM_ULA_BORDER];
                    fe_t    <= !fe_t;
                end
                `RM_PALIDX0:  if (rb_cop) begin palidx_c[7:0] <= rb_wdata;      pcnt_c <= 2'd0; end
                              else        begin palidx[7:0]   <= rb_wdata;      pcnt   <= 2'd0; end
                `RM_PALIDX1:  if (rb_cop) begin palidx_c[9:8] <= rb_wdata[1:0]; pcnt_c <= 2'd0; end
                              else        begin palidx[9:8]   <= rb_wdata[1:0]; pcnt   <= 2'd0; end
                `RM_PALDAT:   case (wpcnt)
                    2'd0:    if (rb_cop) begin ccab[7:0]  <= rb_wdata; pcnt_c <= 2'd1; end
                             else        begin cab[7:0]   <= rb_wdata; pcnt   <= 2'd1; end
                    2'd1:    if (rb_cop) begin ccab[15:8] <= rb_wdata; pcnt_c <= 2'd2; end
                             else        begin cab[15:8]  <= rb_wdata; pcnt   <= 2'd2; end
                    default: begin
                        pw_en  <= 1'b1;
                        pw_a   <= wpidx;
                        pw_d   <= {rb_wdata, wcab};
                        if (rb_cop) begin palidx_c <= palidx_c + 1'b1; pcnt_c <= 2'd0; end
                        else        begin palidx   <= palidx + 1'b1;   pcnt   <= 2'd0; end
                    end
                endcase
                `RM_DMACON:   if (rb_wdata[7]) dmacon <= dmacon |  rb_wdata[6:1];
                              else             dmacon <= dmacon & ~rb_wdata[6:1];
                default: ;
            endcase
            ppw   <= rb_wr && sel_ppal;
            ppw_o <= po;
            ppw_d <= rb_wdata;
            if (ppw) case (pdw[1:0])
                2'd0:    cab[7:0]  <= ppw_d;
                2'd1:    cab[15:8] <= ppw_d;
                default: begin
                    pw_en <= 1'b1;
                    pw_a  <= pdw[11:2];
                    pw_d  <= {ppw_d, cab};
                end
            endcase
            // A PALDAT read steps the byte, and the red byte the index
            if (rb_rd && rb_addr == `RM_PALDAT) begin
                pcnt <= (pcnt == 2'd2) ? 2'd0 : pcnt + 1'b1;
                if (pcnt == 2'd2) palidx <= palidx + 1'b1;
            end
            if (rb_wr && sel_lay) case (lo)
                5'h00: l_ctrl0[ln] <= {rb_wdata[7:2], 1'b0, rb_wdata[0]};
                5'h01: l_ctrl1[ln] <= {rb_wdata[7:4], 2'd0, rb_wdata[1:0]};
                5'h02: l_ctrl2[ln] <= {rb_wdata[7:4], 4'd0};
                5'h03: l_ctrl3[ln] <= {4'd0, rb_wdata[3:0]};
                5'h04: l_xe[ln][7:0]  <= rb_wdata;
                5'h05: l_xe[ln][10:8] <= rb_wdata[2:0];
                5'h06: l_xs[ln][7:0]  <= rb_wdata;
                5'h07: l_xs[ln][10:8] <= rb_wdata[2:0];
                5'h08: l_ye[ln][7:0]  <= rb_wdata;
                5'h09: l_ye[ln][10:8] <= rb_wdata[2:0];
                5'h0A: l_ys[ln][7:0]  <= rb_wdata;
                5'h0B: l_ys[ln][10:8] <= rb_wdata[2:0];
                5'h0C: l_sx[ln][7:0]  <= rb_wdata;
                5'h0D: l_sx[ln][9:8]  <= rb_wdata[1:0];
                5'h0E: l_sy[ln][7:0]  <= rb_wdata;
                5'h0F: l_sy[ln][9:8]  <= rb_wdata[1:0];
                default: ;
            endcase
        end
    end

    // ---- register reads (the palettes' are below)
    // BEAMPOS and FRAMECOUNT read live; reading the low byte also hands the
    // whole value to the CPU's capture (bus_if.v; spec 3, rule 4)
    reg  [7:0] reg_q;
    reg        reg_hit;
    reg [31:0] v_cdata;
    reg        v_cap;
    always @(posedge clk) begin
        reg_q   <= 8'd0;
        reg_hit <= rb_rd && (sel_glob || sel_lay);
        v_cdata <= 32'd0;
        v_cap   <= 1'b0;
        if (rb_rd && rb_addr == `RM_BEAMPOS0) begin
            v_cdata <= {5'd0, s_vline, 5'd0, s_hpix};
            v_cap   <= 1'b1;
        end
        if (rb_rd && rb_addr == `RM_FRAMECOUNT0) begin
            v_cdata <= {16'd0, s_frames};
            v_cap   <= 1'b1;
        end
        if (rb_rd) case (rb_addr)
            `RM_VIDCON:   reg_q <= {2'd0, vidcon};
            `RM_VIDSTAT:  reg_q <= {vs_sprunder, vs_over, invblank, 1'b0, vs_line, vs_vblank};
            `RM_VIDINTEN: reg_q <= vidinten;
            `RM_PRIO:     reg_q <= {2'd0, prio};
            `RM_LINECMP0: reg_q <= lc_v[7:0];
            `RM_LINECMP1: reg_q <= {5'd0, lc_v[10:8]};
            `RM_BEAMPOS0: reg_q <= s_hpix[7:0];
            `RM_BEAMPOS1: reg_q <= {5'd0, s_hpix[10:8]};
            `RM_BEAMPOS2: reg_q <= s_vline[7:0];
            `RM_BEAMPOS3: reg_q <= {5'd0, s_vline[10:8]};
            `RM_FRAMECOUNT0: reg_q <= s_frames[7:0];
            `RM_FRAMECOUNT1: reg_q <= s_frames[15:8];
            `RM_BGCOLOR0: reg_q <= bgcolor[7:0];
            `RM_BGCOLOR1: reg_q <= bgcolor[15:8];
            `RM_BGCOLOR2: reg_q <= bgcolor[23:16];
            `RM_PALIDX0:  reg_q <= palidx[7:0];
            `RM_PALIDX1:  reg_q <= {6'd0, palidx[9:8]};
            `RM_DMACON:   reg_q <= {1'b0, dmacon, 1'b0};
            `RM_VIDSIZE0: reg_q <= HVIS[7:0];
            `RM_VIDSIZE1: reg_q <= {5'd0, HVIS[10:8]};
            `RM_VIDSIZE2: reg_q <= VVIS[7:0];
            `RM_VIDSIZE3: reg_q <= {5'd0, VVIS[10:8]};
            default: ;
        endcase
        if (rb_rd && sel_lay) case (lo)
            5'h00: reg_q <= l_ctrl0[ln];
            5'h01: reg_q <= l_ctrl1[ln];
            5'h02: reg_q <= l_ctrl2[ln];
            5'h03: reg_q <= l_ctrl3[ln];
            5'h04: reg_q <= l_xe[ln][7:0];
            5'h05: reg_q <= {5'd0, l_xe[ln][10:8]};
            5'h06: reg_q <= l_xs[ln][7:0];
            5'h07: reg_q <= {5'd0, l_xs[ln][10:8]};
            5'h08: reg_q <= l_ye[ln][7:0];
            5'h09: reg_q <= {5'd0, l_ye[ln][10:8]};
            5'h0A: reg_q <= l_ys[ln][7:0];
            5'h0B: reg_q <= {5'd0, l_ys[ln][10:8]};
            5'h0C: reg_q <= l_sx[ln][7:0];
            5'h0D: reg_q <= {6'd0, l_sx[ln][9:8]};
            5'h0E: reg_q <= l_sy[ln][7:0];
            5'h0F: reg_q <= {6'd0, l_sy[ln][9:8]};
            default: ;
        endcase
    end

    // ================================================================ palettes
    // PALETTE0-2 (L0-L2) and SPRPALETTE (section 4.7): one RAM of 1024 x 24,
    // addressed by {palette, entry}. Kept twice, written together from the
    // system side: one copy is read back by the CPU, the other by the pixel
    // side (section 9). At configuration every palette holds the Spectrum
    // colours in entries 0-15 and black elsewhere (section 7.4); reset does
    // not change them.
    reg [23:0] pal [0:1023], pal_c [0:1023];     // RRGGBB
    function [23:0] spectrum(input [3:0] e);
        reg [7:0] l;
        begin
            l = e[3] ? 8'hFF : 8'hD7;
            spectrum = {e[1] ? l : 8'h00, e[2] ? l : 8'h00, e[0] ? l : 8'h00};
        end
    endfunction
    integer k;
    initial for (k = 0; k < 1024; k = k + 1) begin
        pal[k]   = (k % 256 < 16) ? spectrum(k[3:0]) : 24'd0;
        pal_c[k] = (k % 256 < 16) ? spectrum(k[3:0]) : 24'd0;
    end
    always @(posedge clk) if (pw_en) pal[pw_a] <= pw_d;

    // Reads: PALDAT at PALIDX, or an entry of the register page
    wire [9:0] pr_a = sel_ppal ? pdr[11:2] : palidx;
    reg [23:0] pal_qa;
    reg [1:0]  pr_b;
    reg        pal_hit;
    always @(posedge clk) begin
        if (pw_en) pal_c[pw_a] <= pw_d;
        pal_qa  <= pal_c[pr_a];
        pr_b    <= sel_ppal ? pdr[1:0] : pcnt;
        pal_hit <= rb_rd && (sel_ppal || rb_addr == `RM_PALDAT);
    end
    wire [7:0] pal_byte = !pal_hit ? 8'd0 :
                          (pr_b == 2'd0) ? pal_qa[7:0] : (pr_b == 2'd1) ? pal_qa[15:8] : pal_qa[23:16];

    wire [7:0] dma_q, spr_q;
    wire       dma_hit, spr_hit;
    assign rb_rdata = reg_q | dma_q | spr_q | pal_byte;
    wire [31:0] spr_cdata, dma_cdata;
    wire        spr_cap, dma_cap;
    assign rb_cdata = spr_cdata | dma_cdata | v_cdata;
    assign rb_cap   = spr_cap | dma_cap | v_cap;
    assign rb_hit   = reg_hit | dma_hit | spr_hit | pal_hit;

    // ================================================================ pixel domain
    reg [1:0] rst_p;
    always @(posedge clk_pix) rst_p <= {rst_p[0], rst};
    wire prst = rst_p[1];

    (* ASYNC_REG = "TRUE" *) reg [1:0] en_s;
    reg en_p;
    always @(posedge clk_pix) begin
        en_s <= {en_s[0], vidcon[0]};
        en_p <= !prst && en_s[1];
    end

    // ---- beam
    reg  [10:0] hc, vc;
    wire hlast = (hc == HTOT - 1'b1);
    wire vlast = (vc == VTOT - 1'b1);
    wire [10:0] hn = hlast ? 11'd0 : hc + 1'b1;
    wire [10:0] vn = hlast ? (vlast ? 11'd0 : vc + 1'b1) : vc;
    // The beam in beam coordinates: a beam line starts with its horizontal blank
    wire        inhb = (hc >= HVIS);
    wire [10:0] bh = inhb ? hc - HVIS : hc + BH0;
    wire [10:0] bv = inhb ? ((vc >= VVIS - 1'b1) ? vc - (VVIS - 1'b1) : vc + BV0 + 1'b1)
                          : ((vc >= VVIS) ? vc - VVIS : vc + BV0);

    // A port 0xFE write (spec 4, section 7.2): its toggle through two
    // flip-flops at 135 MHz, as "full" (layer_pix.v), then the pixel side
    // takes its colour at the next pixel, mid-line. fe_col changed with the
    // toggle, so it has been steady for more than a 135 MHz period by then
    (* ASYNC_REG = "TRUE" *) reg [1:0] fe_s = 2'b00;
    always @(posedge clk_pix5) fe_s <= {fe_s[0], fe_t};
    reg  fe_seen = 1'b0;
    wire fe_ev = fe_s[1] != fe_seen;
    wire [23:0] fe_rgb = spectrum({1'b0, fe_col});

    reg [5:0]  prio_l;                 // PRIO and BGCOLOR, taken at the start of each line's picture
    reg [23:0] bg_l;
    // The background of the pixel going out now: the new border colour from
    // the clock that sees the write
    wire [23:0] bg_now = fe_ev ? fe_rgb : bg_l;
    always @(posedge clk_pix) begin
        if (!en_p) begin
            hc     <= 11'd0;
            vc     <= 11'd0;
            bg_l   <= bgcolor;         // for the first line after EN is set
            prio_l <= prio;
        end else begin
            hc <= hn;
            vc <= vn;
            if (hn == 11'd0) begin
                bg_l   <= bgcolor;
                prio_l <= prio;
            end
        end
        fe_seen <= fe_s[1];
        if (fe_ev) bg_l <= fe_rgb;     // a port 0xFE write: kept for the rest of the line
        p_vline <= bv;
        p_hpix  <= bh;
        if (prst)
            p_vb_t <= 1'b0;
        else if (en_p && bh == 11'd0 && bv == 11'd0)   // the frame starts: (0, 0)
            p_vb_t <= ~p_vb_t;
        if (prst)
            p_frames <= 16'd0;
        else if (en_p && bh == 11'd0 && bv == 11'd0)
            p_frames <= p_frames + 1'b1;
        if (prst)
            p_lc_t <= 1'b0;
        else if (en_p && bh == 11'd0 && bv == lc_v)    // beam line LINECMP starts (above 624: never)
            p_lc_t <= ~p_lc_t;
        if (prst)
            p_ln_t <= 1'b0;
        else if (en_p && bh == 11'd0)                  // a line starts: pixel 0
            p_ln_t <= ~p_ln_t;
    end

    // ---- settings for the next line, worked out in the horizontal blank
    // (clocks HVIS to HVIS + 2), then handed to the fetcher and the layer units
    wire [10:0] next_line = vlast ? 11'd0 : vc + 1'b1;
    // The windows (in beam coordinates) on the picture: clamped to it, then picture-relative
    function [10:0] tox(input [10:0] v);
        tox = (v < BH0) ? 11'd0 : (v > HTOT) ? HVIS : v - BH0;
    endfunction
    function [10:0] toy(input [10:0] v);
        toy = (v < BV0) ? 11'd0 : (v > VTOT) ? VVIS : v - BV0;
    endfunction
    wire [10:0] w_xs [0:2], w_xe [0:2], w_ys [0:2], w_ye [0:2];
    wire [2:0] l_on;                // the layer is on: CTRL0.EN
    genvar gw;
    generate for (gw = 0; gw < 3; gw = gw + 1) begin : wins
        assign w_xs[gw] = tox(l_xs[gw]);
        assign w_xe[gw] = (tox(l_xe[gw]) < tox(l_xs[gw])) ? tox(l_xs[gw]) : tox(l_xe[gw]);
        assign w_ys[gw] = toy(l_ys[gw]);
        assign w_ye[gw] = toy(l_ye[gw]);
        assign l_on[gw] = (gw < NL) && l_ctrl0[gw][0];
    end endgenerate
    reg  [2:0]  b_vsub [0:2];       // screen lines shown of this source line
    reg  [9:0]  b_srcl [0:2];       // source lines of the window before this one
    reg  [9:0]  n_ty [0:2];         // tiles: the map line ...
    reg  [6:0]  n_tcol [0:2];       // ... and the first group's map column
    reg  [2:0] b_act, b_adv;
    reg  [3:0]  n_pos0 [0:2];
    reg  [11:0] n_groups [0:2];
    reg  [2:0] f_act, f_adv;
    reg  [11:0] f_groups [0:2];
    reg  [1:0]  f_lb [0:2], f_hs [0:2];
    reg  [3:0]  f_wrap [0:2];
    reg  [2:0]  f_tile;
    reg  [1:0]  f_mw [0:2];
    reg  [9:0]  f_ty [0:2];
    reg  [6:0]  f_tcol [0:2];
    reg         line_t;
    // This line's settings, for the layer units
    reg  [2:0] c_act, c_transp, c_tile;
    reg  [10:0] c_xs [0:2], c_xe [0:2];
    reg  [1:0]  c_lb [0:2], c_hs [0:2];
    reg  [3:0]  c_pos0 [0:2], c_palofs [0:2];

    always @(posedge clk_pix) begin : setup
        integer n;
        reg [2:0]  vmax, vs_n;
        reg [10:0] w, srcpix;
        reg [3:0]  fine;
        reg [9:0]  sl_n;
        if (prst) begin
            line_t <= 1'b0;
            c_act  <= 3'd0;
            f_act  <= 3'd0;
            f_adv  <= 3'd0;
            for (n = 0; n < 3; n = n + 1) begin b_vsub[n] <= 3'd0; b_srcl[n] <= 10'd0; end
        end else if (hc == HVIS || !en_p) begin
            // 1: which layers show on the next line, and whether their pointers move on after it
            for (n = 0; n < 3; n = n + 1) begin
                vmax = 3'd7 >> (2'd3 - l_ctrl1[n][1:0]);
                vs_n = (next_line == w_ys[n] || b_vsub[n] == vmax) ? 3'd0 : b_vsub[n] + 1'b1;
                sl_n = (next_line == w_ys[n]) ? 10'd0 : (vs_n == 3'd0) ? b_srcl[n] + 1'b1 : b_srcl[n];
                b_act[n] <= en_p && fetch_en && l_on[n] && next_line < VVIS &&
                            next_line >= w_ys[n] && next_line < w_ye[n];
                b_adv[n] <= (vs_n == vmax);
                if (next_line >= w_ys[n] && next_line < w_ye[n]) begin
                    b_vsub[n] <= vs_n;
                    b_srcl[n] <= sl_n;
                end
            end
        end else if (hc == HVIS + 1'b1) begin
            // 2: first pixel, groups to fetch: a group is 16 source pixels.
            // Tiles: the map line (SCROLLY + source line, round the map),
            // the first group's map column and the fine scroll (SCROLLX)
            for (n = 0; n < 3; n = n + 1) begin
                w      = w_xe[n] - w_xs[n];
                srcpix = (w + (3'd7 >> (2'd3 - l_ctrl0[n][7:6]))) >> l_ctrl0[n][7:6];
                fine   = l_ctrl0[n][5] ? {1'b0, l_sx[n][2:0]} : l_sx[n][3:0];
                n_ty[n]   <= (l_sy[n] + b_srcl[n]) & ((l_ctrl3[n][3:2] == 2'd0) ? 10'h0FF :
                                                      (l_ctrl3[n][3:2] == 2'd1) ? 10'h1FF : 10'h3FF);
                n_tcol[n] <= l_sx[n][9:3] & ((l_ctrl3[n][1:0] == 2'd0) ? 7'h1F :
                                             (l_ctrl3[n][1:0] == 2'd1) ? 7'h3F : 7'h7F);
                n_pos0[n]   <= fine;
                /* verilator lint_off WIDTHTRUNC */ n_groups[n] <= ({10'd0, fine} + {3'd0, srcpix} + 14'd15) >> 4; /* verilator lint_on WIDTHTRUNC */
            end
        end else if (hc == HVIS + 2'd2) begin
            // 3: hand over
            f_act  <= b_act;
            f_adv  <= b_adv;
            line_t <= ~line_t;
            c_act  <= b_act;
            for (n = 0; n < 3; n = n + 1) begin
                f_groups[n] <= n_groups[n];
                f_lb[n]     <= l_ctrl0[n][3:2];
                f_hs[n]     <= l_ctrl0[n][7:6];
                f_wrap[n]   <= l_ctrl2[n][7:4];
                f_tile[n]   <= l_ctrl0[n][5];
                f_mw[n]     <= l_ctrl3[n][1:0];
                f_ty[n]     <= n_ty[n];
                f_tcol[n]   <= n_tcol[n];
                c_tile[n]   <= l_ctrl0[n][5];
                c_xs[n]     <= w_xs[n];
                c_xe[n]     <= w_xe[n];
                c_lb[n]     <= l_ctrl0[n][3:2];
                c_transp[n] <= l_ctrl0[n][4];
                c_hs[n]     <= l_ctrl0[n][7:6];
                c_palofs[n] <= l_ctrl1[n][7:4];
                c_pos0[n]   <= n_pos0[n];
            end
        end
    end

    // ---- layer fetch and the pointer registers (100 MHz)
    wire [383:0] dat;
    wire [2:0] fill_t, take_t;
    wire          line_go, line_gen;
    wire [5:0]  fv_lb, fv_hs;
    wire [11:0]  fv_wrap;
    wire [35:0] fv_groups;
    wire [5:0]  fv_mw;
    wire [29:0] fv_ty, at;
    wire [20:0] fv_tcol;
    generate for (gw = 0; gw < 3; gw = gw + 1) begin : fvec
        assign fv_mw[2*gw +: 2]       = f_mw[gw];
        assign fv_ty[10*gw +: 10]     = f_ty[gw];
        assign fv_tcol[7*gw +: 7]     = f_tcol[gw];
        assign fv_lb[2*gw +: 2]       = f_lb[gw];
        assign fv_hs[2*gw +: 2]       = f_hs[gw];
        assign fv_wrap[4*gw +: 4]     = f_wrap[gw];
        assign fv_groups[12*gw +: 12] = f_groups[gw];
    end endgenerate
    bpldma #(.NL(NL)) dma (
        .clk(clk), .rst(rst), .enable(fetch_en),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
        .rb_rdata(dma_q), .rb_hit(dma_hit), .rb_cdata(dma_cdata), .rb_cap(dma_cap),
        .line_t(line_t), .act(f_act), .adv(f_adv),
        .lbpp(fv_lb), .hscale(fv_hs), .wrap(fv_wrap), .ngroups(fv_groups),
        .tile(f_tile), .mapw(fv_mw), .ty(fv_ty), .tcol(fv_tcol),
        .line_go(line_go), .line_gen(line_gen),
        .dat(dat), .attr(at), .fill_t(fill_t), .take_t(take_t),
        .req(disp_req), .urgent(disp_urgent), .deadline(disp_deadline), .addr(disp_addr),
        .ack(disp_ack), .rvalid(disp_rvalid), .rdata(disp_rdata)
    );

    // ---- sprites (spec 5): the fetcher and FIFOs (100 MHz), and a unit per sprite
    wire [79:0] sp_hs, sp_xe;
    wire [7:0]  sp_act;
    wire [15:0] sp_lb, sp_depth;
    wire [127:0] sp_xstep;
    wire [7:0]  sp_dma;
    wire [31:0] sp_pal;
    wire [39:0] sp_ra;
    wire [127:0] sp_rd;
    wire [47:0] sp_wpg, sp_rpg;
    wire [7:0]  sp_fl, sp_fla;
    reg  [31:0] coll_acc, coll_line;
    reg         coll_t;
    sprites #(.NS(NS)) spr (
        .clk(clk), .rst(rst),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
        .rb_rdata(spr_q), .rb_hit(spr_hit), .rb_cdata(spr_cdata), .rb_cap(spr_cap),
        .dma_on(vidcon[0] && dmacon[6] && dmacon[2]), .vblank(frame_tick), .beam_v(s_vline), .beam_h(s_hpix),
        .mem_req(spr_req), .mem_addr(spr_addr), .mem_deadline(spr_deadline), .mem_urgent(spr_urgent),
        .mem_ack(spr_ack), .mem_rvalid(spr_rvalid), .mem_rdata(disp_rdata),
        .p_hs(sp_hs), .p_xe(sp_xe), .p_act(sp_act), .p_lb(sp_lb),
        .p_xstep(sp_xstep), .p_depth(sp_depth), .p_pal(sp_pal), .p_dma(sp_dma),
        .fifo_ra(sp_ra), .fifo_rd(sp_rd), .wp_g(sp_wpg), .rp_g(sp_rpg), .flush_t(sp_fl), .flush_ack_t(sp_fla),
        .coll_line(coll_line), .coll_t(coll_t)
    );

    // A sprite's line is a beam line: from the start of its horizontal blank
    // (beam pixel 0); its settings are taken at beam pixel 12, after the
    // sprite side's line-start pass (so HSTART must be 16 or more)
    reg  [7:0]  c_sact, c_sdma;
    reg  [9:0]  c_shs [0:7], c_sxe [0:7];
    reg  [1:0]  c_slb [0:7], c_sdep [0:7];
    reg  [15:0] c_sxs [0:7];
    reg  [3:0]  c_spal [0:7];
    always @(posedge clk_pix) if (hc == HVIS + 11'd12 || !en_p) begin : sset
        integer n;
        for (n = 0; n < 8; n = n + 1) begin
            c_sact[n]  <= en_p && sp_act[n];
            c_shs[n]   <= sp_hs[10*n +: 10];
            c_sxe[n]   <= sp_xe[10*n +: 10];
            c_slb[n]   <= sp_lb[2*n +: 2];
            c_sxs[n]   <= sp_xstep[16*n +: 16];
            c_sdep[n]  <= sp_depth[2*n +: 2];
            c_spal[n]  <= sp_pal[4*n +: 4];
            c_sdma[n]  <= sp_dma[n];
        end
    end

    wire [9:0]  st_now = bh[9:0];
    wire [7:0]  s_op;                  // stage 1: each sprite's pixel
    wire [7:0]  s_idx [0:7];
    genvar sg;
    generate for (sg = 0; sg < 8; sg = sg + 1) begin : sprs
        if (sg < NS) begin : on
        wire [5:0] rpb;
        assign sp_ra[5*sg +: 5] = rpb[4:0];
        sprite_pix u (
            .clk_pix(clk_pix), .en(en_p), .t(st_now),
            .act(c_sact[sg]), .hs(c_shs[sg]), .xe(c_sxe[sg]), .lb(c_slb[sg]),
            .xstep(c_sxs[sg]), .pal(c_spal[sg]), .dma(c_sdma[sg]),
            .head(sp_rd[16*sg +: 16]), .rp(rpb), .rp_g(sp_rpg[6*sg +: 6]), .wp_g(sp_wpg[6*sg +: 6]),
            .flush_t(sp_fl[sg]), .flush_ack_t(sp_fla[sg]),
            .opaque(s_op[sg]), .idx(s_idx[sg]), .underrun_t(p_un[sg])
        );
        end else begin : off               // not built: never started, never shown
            assign sp_ra[5*sg +: 5]  = 5'd0;
            assign sp_rpg[6*sg +: 6] = 6'd0;
            assign sp_fla[sg]        = sp_fl[sg];
            assign s_op[sg]          = 1'b0;
            assign s_idx[sg]         = 8'd0;
            assign p_un[sg]          = 1'b0;
        end
    end endgenerate

    // ---- layer units: their output is stage 1
    wire [3:0]  bl_op;                 // padded to 4: PRIO value 3 names no layer
    wire [3:0]  bl_pri;
    wire [31:0] bl_idx;
    assign bl_op[3]         = 1'b0;
    assign bl_pri[3]        = 1'b0;
    assign bl_idx[31:24]    = 8'd0;
    // The layer units may take this line's first group once the fetcher has
    // restarted (line_gen caught up) and the handshake has crossed back
    (* ASYNC_REG = "TRUE" *) reg [1:0] lg_s;
    always @(posedge clk_pix) lg_s <= {lg_s[0], line_gen};
    wire       buf_ready = (lg_s[1] == line_t) && (hc >= HVIS + 4'd8 || hc < HVIS);
    genvar g;
    generate for (g = 0; g < 3; g = g + 1) begin : lay
        if (g < NL) begin : on
        layer_pix u (
            .clk_pix(clk_pix), .clk_pix5(clk_pix5), .en(en_p), .hc(hc), .hn(hn),
            .line_start(hc == HVIS), .ready(buf_ready),
            .active(c_act[g]), .xs(c_xs[g]), .xe(c_xe[g]), .lb(c_lb[g]),
            .hs(c_hs[g]), .pos0(c_pos0[g]), .transp(c_transp[g]), .palofs(c_palofs[g]),
            .tile(c_tile[g]),
            .dat(dat[128*g +: 128]), .attr(at[10*g +: 10]), .fill_t(fill_t[g]), .take_t(take_t[g]),
            .opaque(bl_op[g]), .idx(bl_idx[8*g +: 8]), .pri(bl_pri[g]), .raw(), .overrun_t(ov_t[g])
        );
        end else begin : off               // not built: never fetched, never shown
            assign bl_op[g]          = 1'b0;
            assign bl_pri[g]         = 1'b0;
            assign bl_idx[8*g +: 8]  = 8'd0;
            assign take_t[g]         = 1'b0;
            assign ov_t[g]           = 1'b0;
        end
    end endgenerate

    // ---- pipeline: 0 beam, 1 layer pixels, 2 priority, 3 palette read, 4 out
    wire       vis0 = en_p && (hc < HVIS) && (vc < VVIS);
    wire       hs0  = en_p && (hc >= HSS) && (hc < HSE);
    wire       vs0  = en_p && (vc >= VSS) && (vc < VSE);
    reg  [2:0] vis_d, hs_d, vs_d;
    reg  [9:0] pidx2;                  // {palette, entry}
    reg        opaque2, opaque3;
    reg [23:0] pal_q3;

    // Collisions (spec 5, section 3.6): gathered over a line, handed to the
    // 100 MHz side at the start of the next (beam pixel 8)
    always @(posedge clk_pix) begin : collide
        integer n, k;
        reg [3:0] c;
        reg [31:0] h;
        c = 4'd0;
        for (n = 0; n < 8; n = n + 1) c = c + {3'd0, s_op[n]};
        h = 32'd0;
        if (c > 4'd1) h[7:0] = s_op;
        for (k = 0; k < 3; k = k + 1) if (bl_op[k]) h[8*(k+1) +: 8] = s_op;
        if (!vis_d[0]) h = 32'd0;                // on the picture only
        if (!en_p) begin
            coll_acc <= 32'd0;
            coll_t   <= 1'b0;
        end else if (hc == HVIS + 11'd8) begin
            coll_line <= coll_acc | h;
            coll_acc  <= 32'd0;
            coll_t    <= ~coll_t;
        end else
            coll_acc <= coll_acc | h;
    end

    always @(posedge clk_pix) begin
        vis_d <= en_p ? {vis_d[1:0], vis0} : 3'd0;     // the beam stopped: the picture ends at once
        hs_d  <= {hs_d[1:0], hs0};
        vs_d  <= {vs_d[1:0], vs0};
        // 2: the front-most opaque layer or sprite (section 4.8; spec 5,
        // 3.5). From the back: sprites of DEPTH 3, PRIO's BACK, DEPTH 2,
        // MIDDLE, DEPTH 1, FRONT, tile pixels with PRI (among themselves in
        // PRIO's order), DEPTH 0. PRIO value 3 (or a layer not built) names
        // no layer. Among sprites of a DEPTH the lower number is in front.
        // The winner's palette goes with its index: the layer's own, or
        // SPRPALETTE (3); with VIDCON.SHAREPAL, PALETTE0 for all.
        begin : pix
            integer p, n, q;
            reg       any;
            reg [7:0] fix;
            reg [1:0] l, fpal;
            any  = 1'b0;
            fix  = 8'd0;
            fpal = 2'd0;
            for (p = 3; p >= 0; p = p - 1) begin
                for (n = 7; n >= 0; n = n - 1)
                    if (s_op[n] && c_sdep[n] == p[1:0]) begin any = 1'b1; fix = s_idx[n]; fpal = 2'd3; end
                if (p > 0) begin
                    l = prio_l[2*(p-1) +: 2];
                    if (bl_op[l]) begin any = 1'b1; fix = bl_idx[8*l +: 8]; fpal = l; end
                end
                if (p == 1)
                    for (q = 2; q >= 0; q = q - 1) begin
                        l = prio_l[2*q +: 2];
                        if (bl_op[l] && bl_pri[l]) begin any = 1'b1; fix = bl_idx[8*l +: 8]; fpal = l; end
                    end
            end
            opaque2 <= any;
            pidx2   <= {vidcon[5] ? 2'd0 : fpal, fix};
        end
        // 3
        pal_q3  <= pal[pidx2];
        opaque3 <= opaque2 && !vidcon[2];
        // 4: out; black outside the picture, no sync while the beam is stopped
        de    <= vis_d[2];
        hsync <= !hs_d[2];
        vsync <= !vs_d[2];
        rgb   <= !vis_d[2] ? 24'd0 : !opaque3 ? bg_now : pal_q3;
    end
endmodule
