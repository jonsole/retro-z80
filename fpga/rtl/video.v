// Video (spec 4): the 576p beam, the layers' registers and pixel pipeline,
// the palettes, priority and the background colour. retro68k's video.v,
// narrowed to byte registers on the 8-bit register bus.
//
// Version for ticket #13: layers as chunky bitmaps (1, 2, 4 or 8 bits per
// pixel, 1x-8x, window, live pointer with stride and wrap, fine scroll,
// TRANSP, PALOFS), fetched just in time by bpldma.v through the scheduler
// (dmac.v), shown by layer_pix.v. NL sets how many layers are built (1-3):
// the registers of layers not built read 0xFF and PRIO naming them shows
// nothing. Not yet: tile mode (CTRL0.MODE = 1 layers are not fetched),
// sprites, direct colour (VIDCON.DIRECT is kept and read back), the
// attribute layer, LINECMP, the LINE and VIDERR requests, BEAMPOS and
// FRAMECOUNT, port 0xFE. Ticket #16 added VIDINTEN and the request line to
// the interrupt controller (VBLANK).
//
// Registers (custom block, spec 4, section 6):
//   VIDCON    0x000  EN (0) starts the beam; BLANKALL (2) shows BGCOLOR only;
//                    DIRECT (4) kept; SHAREPAL (5) all layers on PALETTE0
//   VIDSTAT   0x001  VBLANK (0), OVERRUN0-2 (4-6): sticky, write 1 to clear;
//                    INVBLANK (3), live
//   VIDINTEN  0x002  enables for VIDSTAT's flags, bits 0-2 and 4-7 (bit 3
//                    reads 0); irq is on while VBLANK and its enable are
//                    (spec 4, section 3.4; spec 8: VBLANK is source 0)
//   PRIO      0x003  FRONT, MIDDLE, BACK; reset 0x24
//   BGCOLOR   0x004  blue, green, red; the red byte commits (spec 3, rule 7)
//   PALIDX    0x009  entry (7-0), palette (9-8)
//   PALDAT    0x00B  blue, green, red of the entry at PALIDX
//   DMACON    0x00C  set/clear: DMAEN (6), BPLEN (5), COPEN, BLTEN, SPREN, AUDEN
//   layers    0x090 + n x 0x20: CTRL0-CTRL3, WINX, WINY, SCROLLX here;
//                    BPLSTRIDE and BPL0PT in bpldma.v
//   VIDSIZE   0x0F6  720 x 576, read only
//   palettes  register page 0x1400-0x1FFF, 3 bytes per entry (spec 4, 6.5)
//
// Blue and green bytes of a colour (BGCOLOR, PALDAT, the palettes in the
// register page) go into the CPU's colour assembly buffer; the red byte
// writes the colour whole. The CPU is the only register bus master so far;
// the copper and the DMA engine get their own buffers when they come.
//
// Two clock domains, asynchronous to each other (spec 4, section 3.1):
//   clk      100 MHz: registers, the layer fetch, palette writes
//   clk_pix   27 MHz: the beam and the pixel pipeline
//   clk_pix5 135 MHz: the fast synchroniser of "full" (layer_pix.v)
// Crossings as retro68k: events are toggles through two flip-flops; the
// data registers cross under the full/taken handshake (bpldma.v,
// layer_pix.v); the beam line is sampled on the system side until two
// samples agree; the layer settings, PRIO and BGCOLOR are settings, copied
// into the pixel domain once per line (a write that lands exactly on that
// copy may take effect one line later); the palette is a two-clock RAM.
`include "regmap.vh"

module video #(
    parameter NL = 1                   // layers built (1-3)
) (
    input  wire        clk,            // 100 MHz
    input  wire        rst,

    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [12:0] rb_addr,
    input  wire [7:0]  rb_wdata,
    output wire [7:0]  rb_rdata,
    output wire        rb_hit,         // with rb_rdata: this unit answered

    output wire        frame_tick,     // 1 clock (100 MHz) at the start of each frame
    output wire        line_tick,      // 1 clock (100 MHz) at the start of each beam line (timers, #17)
    output wire        irq,            // to the interrupt controller: source VBLANK (0)

    // The scheduler's layer channel (dmac.v)
    output wire        disp_req,
    output wire        disp_urgent,
    output wire [9:0]  disp_deadline,
    output wire [21:1] disp_addr,
    input  wire        disp_ack,
    input  wire        disp_rvalid,
    input  wire [15:0] disp_rdata,

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
    reg  [2:0]  vs_over;               // VIDSTAT.OVERRUN0-2
    reg  [5:0]  prio;
    reg  [7:0]  vidinten;              // VIDINTEN; bit 3 always 0
    reg  [23:0] bgcolor;               // RRGGBB
    reg  [15:0] cab;                   // the CPU's colour assembly buffer: green, blue
    reg  [6:1]  dmacon;                // DMAEN (6), BPLEN (5), COPEN, BLTEN, SPREN, AUDEN (1)
    reg  [9:0]  palidx;
    reg  [1:0]  pcnt;                  // PALDAT's byte: 0 blue, 1 green, 2 red

    // Layers: CTRL0-CTRL3, window, SCROLLX (pointer and stride in bpldma.v)
    reg  [7:0]  l_ctrl0 [0:2];      // EN (0), BPP (3-2), TRANSP (4), MODE (5), HSCALE (7-6)
    reg  [7:0]  l_ctrl1 [0:2];      // VSCALE (1-0), PALOFS (7-4)
    reg  [7:0]  l_ctrl2 [0:2];      // WRAP (7-4)
    reg  [7:0]  l_ctrl3 [0:2];      // MAPW (1-0), MAPH (3-2): kept for tile mode
    reg  [10:0] l_xs [0:2], l_xe [0:2], l_ys [0:2], l_ye [0:2];
    reg  [9:0]  l_sx [0:2];

    // Layer registers: custom 0x090 + n x 0x20
    wire [7:0]  ll  = rb_addr[7:0] - 8'h90;
    wire [1:0]  ln  = ll[6:5];
    wire [4:0]  lo  = ll[4:0];
    wire        sel_lay = (rb_addr[12:8] == 5'h10) && (rb_addr[7:0] >= 8'h90) && ({1'b0, ll[7:5]} < NL)
                          && (lo <= 5'h0D);

    // From the pixel domain: the beam line, sampled until two samples agree
    reg  [10:0] p_vline;
    reg  [10:0] bs1, bs2, s_vline;
    always @(posedge clk) begin
        bs1 <= p_vline;
        bs2 <= bs1;
        if (bs1 == bs2) s_vline <= bs2;
    end
    wire invblank = (s_vline < BV0);

    reg        p_vb_t;                 // toggles at the start of each frame
    reg  [2:0] vb_s;
    always @(posedge clk) vb_s <= {vb_s[1:0], p_vb_t};
    assign frame_tick = vb_s[2] != vb_s[1];

    reg        p_ln_t;                 // toggles at the start of each beam line (pixel 0)
    reg  [2:0] ln_s;
    always @(posedge clk) ln_s <= {ln_s[1:0], p_ln_t};
    assign line_tick = ln_s[2] != ln_s[1];

    wire [2:0] ov_t;                // OVERRUN toggles from the layer units
    (* ASYNC_REG = "TRUE" *) reg [2:0] ov_s1, ov_s2;
    reg  [2:0] ov_s3;

    assign irq = vs_vblank && vidinten[`RM_VIDINTEN_VBLANK];
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

    wire sel_glob = (rb_addr >= `RM_VIDCON) && (rb_addr <= `RM_DMACON) &&
                    (rb_addr != `RM_LINECMP0) && (rb_addr != `RM_LINECMP1) ||
                    (rb_addr >= `RM_VIDSIZE0) && (rb_addr <= `RM_VIDSIZE3);

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
            vs_over   <= 3'd0;
            prio      <= 6'b10_01_00;      // L0 in front, then L1, then L2
            vidinten  <= 8'd0;
            bgcolor   <= 24'd0;
            cab       <= 16'd0;
            dmacon    <= 6'd0;
            palidx    <= 10'd0;
            pcnt      <= 2'd0;
            ppw       <= 1'b0;
            for (i = 0; i < 3; i = i + 1) begin
                l_ctrl0[i] <= 8'd0;  l_ctrl1[i] <= 8'd0;  l_ctrl2[i] <= 8'd0;  l_ctrl3[i] <= 8'd0;
                l_xs[i] <= BH0;  l_xe[i] <= HTOT;  l_ys[i] <= BV0;  l_ye[i] <= VTOT;
                l_sx[i] <= 10'd0;
            end
        end else begin
            if (frame_tick) vs_vblank <= 1'b1;
            for (i = 0; i < 3; i = i + 1) if (ov_ev[i]) vs_over[i] <= 1'b1;
            if (rb_wr) case (rb_addr)
                `RM_VIDCON:   vidcon <= {rb_wdata[5:4], 1'b0, rb_wdata[2], 1'b0, rb_wdata[0]};
                `RM_VIDSTAT:  begin
                    if (rb_wdata[`RM_VIDSTAT_VBLANK]) vs_vblank <= 1'b0;
                    vs_over <= vs_over & ~rb_wdata[6:4];
                end
                `RM_VIDINTEN: vidinten <= rb_wdata & 8'hF7;
                `RM_PRIO:     prio <= rb_wdata[5:0];
                `RM_BGCOLOR0: cab[7:0]  <= rb_wdata;
                `RM_BGCOLOR1: cab[15:8] <= rb_wdata;
                `RM_BGCOLOR2: bgcolor   <= {rb_wdata, cab};
                `RM_PALIDX0:  begin palidx[7:0] <= rb_wdata;      pcnt <= 2'd0; end
                `RM_PALIDX1:  begin palidx[9:8] <= rb_wdata[1:0]; pcnt <= 2'd0; end
                `RM_PALDAT:   case (pcnt)
                    2'd0:    begin cab[7:0]  <= rb_wdata; pcnt <= 2'd1; end
                    2'd1:    begin cab[15:8] <= rb_wdata; pcnt <= 2'd2; end
                    default: begin
                        pw_en  <= 1'b1;
                        pw_a   <= palidx;
                        pw_d   <= {rb_wdata, cab};
                        palidx <= palidx + 1'b1;
                        pcnt   <= 2'd0;
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
                default: ;
            endcase
        end
    end

    // ---- register reads (the palettes' are below)
    reg  [7:0] reg_q;
    reg        reg_hit;
    always @(posedge clk) begin
        reg_q   <= 8'd0;
        reg_hit <= rb_rd && (sel_glob || sel_lay);
        if (rb_rd) case (rb_addr)
            `RM_VIDCON:   reg_q <= {2'd0, vidcon};
            `RM_VIDSTAT:  reg_q <= {1'b0, vs_over, invblank, 2'd0, vs_vblank};
            `RM_VIDINTEN: reg_q <= vidinten;
            `RM_PRIO:     reg_q <= {2'd0, prio};
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

    wire [7:0] dma_q;
    wire       dma_hit;
    assign rb_rdata = reg_q | dma_q | pal_byte;
    assign rb_hit   = reg_hit | dma_hit | pal_hit;

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

    reg [5:0]  prio_l;                 // PRIO and BGCOLOR, taken at the start of each line's picture
    reg [23:0] bg_l;
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
        p_vline <= bv;
        if (prst)
            p_vb_t <= 1'b0;
        else if (en_p && bh == 11'd0 && bv == 11'd0)   // the frame starts: (0, 0)
            p_vb_t <= ~p_vb_t;
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
    wire [2:0] l_on;                // the layer is on: CTRL0.EN, bitmap mode
    genvar gw;
    generate for (gw = 0; gw < 3; gw = gw + 1) begin : wins
        assign w_xs[gw] = tox(l_xs[gw]);
        assign w_xe[gw] = (tox(l_xe[gw]) < tox(l_xs[gw])) ? tox(l_xs[gw]) : tox(l_xe[gw]);
        assign w_ys[gw] = toy(l_ys[gw]);
        assign w_ye[gw] = toy(l_ye[gw]);
        assign l_on[gw] = (gw < NL) && l_ctrl0[gw][0] && !l_ctrl0[gw][5];
    end endgenerate
    reg  [2:0]  b_vsub [0:2];       // screen lines shown of this source line
    reg  [2:0] b_act, b_adv;
    reg  [3:0]  n_pos0 [0:2];
    reg  [11:0] n_groups [0:2];
    reg  [2:0] f_act, f_adv;
    reg  [11:0] f_groups [0:2];
    reg  [1:0]  f_lb [0:2], f_hs [0:2];
    reg  [3:0]  f_wrap [0:2];
    reg         line_t;
    // This line's settings, for the layer units
    reg  [2:0] c_act, c_transp;
    reg  [10:0] c_xs [0:2], c_xe [0:2];
    reg  [1:0]  c_lb [0:2], c_hs [0:2];
    reg  [3:0]  c_pos0 [0:2], c_palofs [0:2];

    always @(posedge clk_pix) begin : setup
        integer n;
        reg [2:0]  vmax, vs_n;
        reg [10:0] w, srcpix;
        reg [3:0]  fine;
        if (prst) begin
            line_t <= 1'b0;
            c_act  <= 3'd0;
            f_act  <= 3'd0;
            f_adv  <= 3'd0;
            for (n = 0; n < 3; n = n + 1) b_vsub[n] <= 3'd0;
        end else if (hc == HVIS || !en_p) begin
            // 1: which layers show on the next line, and whether their pointers move on after it
            for (n = 0; n < 3; n = n + 1) begin
                vmax = 3'd7 >> (2'd3 - l_ctrl1[n][1:0]);
                vs_n = (next_line == w_ys[n] || b_vsub[n] == vmax) ? 3'd0 : b_vsub[n] + 1'b1;
                b_act[n] <= en_p && fetch_en && l_on[n] && next_line < VVIS &&
                            next_line >= w_ys[n] && next_line < w_ye[n];
                b_adv[n] <= (vs_n == vmax);
                if (next_line >= w_ys[n] && next_line < w_ye[n]) b_vsub[n] <= vs_n;
            end
        end else if (hc == HVIS + 1'b1) begin
            // 2: first pixel, groups to fetch: a group is 16 source pixels
            for (n = 0; n < 3; n = n + 1) begin
                w      = w_xe[n] - w_xs[n];
                srcpix = (w + (3'd7 >> (2'd3 - l_ctrl0[n][7:6]))) >> l_ctrl0[n][7:6];
                fine   = l_sx[n][3:0];
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
    generate for (gw = 0; gw < 3; gw = gw + 1) begin : fvec
        assign fv_lb[2*gw +: 2]       = f_lb[gw];
        assign fv_hs[2*gw +: 2]       = f_hs[gw];
        assign fv_wrap[4*gw +: 4]     = f_wrap[gw];
        assign fv_groups[12*gw +: 12] = f_groups[gw];
    end endgenerate
    bpldma #(.NL(NL)) dma (
        .clk(clk), .rst(rst), .enable(fetch_en),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
        .rb_rdata(dma_q), .rb_hit(dma_hit),
        .line_t(line_t), .act(f_act), .adv(f_adv),
        .lbpp(fv_lb), .hscale(fv_hs), .wrap(fv_wrap), .ngroups(fv_groups),
        .line_go(line_go), .line_gen(line_gen),
        .dat(dat), .fill_t(fill_t), .take_t(take_t),
        .req(disp_req), .urgent(disp_urgent), .deadline(disp_deadline), .addr(disp_addr),
        .ack(disp_ack), .rvalid(disp_rvalid), .rdata(disp_rdata)
    );

    // ---- layer units: their output is stage 1
    wire [3:0]  bl_op;                 // padded to 4: PRIO value 3 names no layer
    wire [31:0] bl_idx;
    assign bl_op[3]         = 1'b0;
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
            .dat(dat[128*g +: 128]), .fill_t(fill_t[g]), .take_t(take_t[g]),
            .opaque(bl_op[g]), .idx(bl_idx[8*g +: 8]), .raw(), .overrun_t(ov_t[g])
        );
        end else begin : off               // not built: never fetched, never shown
            assign bl_op[g]          = 1'b0;
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

    always @(posedge clk_pix) begin
        vis_d <= en_p ? {vis_d[1:0], vis0} : 3'd0;     // the beam stopped: the picture ends at once
        hs_d  <= {hs_d[1:0], hs0};
        vs_d  <= {vs_d[1:0], vs0};
        // 2: the front-most opaque layer (section 4.8): PRIO's FRONT, then
        // MIDDLE, then BACK; 3 (or a layer not built) names no layer. Its
        // palette goes with its index; with VIDCON.SHAREPAL, PALETTE0 for all.
        begin : pix
            integer p;
            reg       any;
            reg [7:0] fix;
            reg [1:0] l, fpal;
            any  = 1'b0;
            fix  = 8'd0;
            fpal = 2'd0;
            for (p = 2; p >= 0; p = p - 1) begin
                l = prio_l[2*p +: 2];
                if (bl_op[l]) begin any = 1'b1; fix = bl_idx[8*l +: 8]; fpal = l; end
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
        rgb   <= !vis_d[2] ? 24'd0 : !opaque3 ? bg_l : pal_q3;
    end
endmodule
