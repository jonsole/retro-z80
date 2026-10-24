// Video (spec 4), first part: the 576p beam and the background colour.
// After retro68k's video.v, narrowed to byte registers on the 8-bit
// register bus. Version for ticket #11 (the KS2 bring-up build): no layers,
// sprites, palettes or interrupts yet, so the picture is BGCOLOR all over.
//
// Registers (custom block, spec 4, section 6):
//   VIDCON   0x000  EN (0) starts the beam; BLANKALL (2), DIRECT (4) and
//                   SHAREPAL (5) are kept and read back (no layers yet, so
//                   the screen is BGCOLOR either way)
//   VIDSTAT  0x001  VBLANK (0), sticky, write 1 to clear; INVBLANK (3), live
//   BGCOLOR  0x004  blue, green, red; blue and green go into the CPU's
//                   colour assembly buffer, the red byte writes all three
//                   (spec 3, rule 7)
//   VIDSIZE  0x0F6  720 x 576, read only
// Every other offset is left to other units (reads 0xFF while none answers).
// BEAMPOS and FRAMECOUNT come with the bus interface's capture (spec 3,
// rule 4).
//
// The colour assembly buffer is the CPU's, the only register bus master so
// far. When the copper and the DMA engine come, each gets its own (rb_who,
// as retro68k's palette writes).
//
// Two clock domains, asynchronous to each other (spec 4, section 3.1):
//   clk     100 MHz: registers
//   clk_pix  27 MHz: the beam and the pixel pipeline
// Crossings as retro68k: VIDCON.EN through two flip-flops; BGCOLOR is a
// setting, copied into the pixel domain at the start of each line's picture
// (beam pixel 144); the beam line is sampled on the system side until two
// samples agree; the start of a frame crosses as a toggle.
`include "regmap.vh"

module video (
    input  wire        clk,            // 100 MHz
    input  wire        rst,

    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [12:0] rb_addr,
    input  wire [7:0]  rb_wdata,
    output reg  [7:0]  rb_rdata,
    output reg         rb_hit,         // with rb_rdata: this unit answered

    output wire        frame_tick,     // 1 clock (100 MHz) at the start of each frame

    input  wire        clk_pix,        // 27 MHz
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
    reg  [23:0] bgcolor;               // RRGGBB
    reg  [15:0] cab;                   // the CPU's colour assembly buffer: green, blue

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

    wire sel = (rb_addr == `RM_VIDCON) || (rb_addr == `RM_VIDSTAT) ||
               (rb_addr >= `RM_BGCOLOR0) && (rb_addr <= `RM_BGCOLOR2) ||
               (rb_addr >= `RM_VIDSIZE0) && (rb_addr <= `RM_VIDSIZE3);

    always @(posedge clk) begin
        if (rst) begin
            vidcon    <= 6'd0;
            vs_vblank <= 1'b0;
            bgcolor   <= 24'd0;
            cab       <= 16'd0;
        end else begin
            if (frame_tick) vs_vblank <= 1'b1;
            if (rb_wr) case (rb_addr)
                `RM_VIDCON:   vidcon <= {rb_wdata[5:4], 1'b0, rb_wdata[2], 1'b0, rb_wdata[0]};
                `RM_VIDSTAT:  if (rb_wdata[`RM_VIDSTAT_VBLANK]) vs_vblank <= 1'b0;
                `RM_BGCOLOR0: cab[7:0]  <= rb_wdata;
                `RM_BGCOLOR1: cab[15:8] <= rb_wdata;
                `RM_BGCOLOR2: bgcolor   <= {rb_wdata, cab};
                default: ;
            endcase
        end

        rb_rdata <= 8'd0;
        rb_hit   <= rb_rd && sel;
        if (rb_rd) case (rb_addr)
            `RM_VIDCON:   rb_rdata <= {2'd0, vidcon};
            `RM_VIDSTAT:  rb_rdata <= {4'd0, invblank, 2'd0, vs_vblank};
            `RM_BGCOLOR0: rb_rdata <= bgcolor[7:0];
            `RM_BGCOLOR1: rb_rdata <= bgcolor[15:8];
            `RM_BGCOLOR2: rb_rdata <= bgcolor[23:16];
            `RM_VIDSIZE0: rb_rdata <= HVIS[7:0];
            `RM_VIDSIZE1: rb_rdata <= {5'd0, HVIS[10:8]};
            `RM_VIDSIZE2: rb_rdata <= VVIS[7:0];
            `RM_VIDSIZE3: rb_rdata <= {5'd0, VVIS[10:8]};
            default: ;
        endcase
    end

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

    reg [23:0] bg_l;                   // BGCOLOR, taken at the start of each line's picture
    always @(posedge clk_pix) begin
        if (!en_p) begin
            hc   <= 11'd0;
            vc   <= 11'd0;
            bg_l <= bgcolor;           // for the first line after EN is set
        end else begin
            hc <= hn;
            vc <= vn;
            if (hn == 11'd0) bg_l <= bgcolor;
        end
        p_vline <= bv;
        if (prst)
            p_vb_t <= 1'b0;
        else if (en_p && bh == 11'd0 && bv == 11'd0)   // the frame starts: (0, 0)
            p_vb_t <= ~p_vb_t;
    end

    // ---- out: black outside the picture; no sync while the beam is stopped
    wire vis0 = en_p && (hc < HVIS) && (vc < VVIS);
    wire hs0  = en_p && (hc >= HSS) && (hc < HSE);
    wire vs0  = en_p && (vc >= VSS) && (vc < VSE);
    always @(posedge clk_pix) begin
        de    <= vis0;
        hsync <= !hs0;
        vsync <= !vs0;
        rgb   <= vis0 ? bg_l : 24'd0;
    end
endmodule
