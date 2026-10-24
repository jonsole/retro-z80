// retro-z80 on the ZX Spectrum Next KS2 (issue 4): a test pattern on HDMI
// and VGA at once, at 576p (720x576, 50 Hz). It proves the tools, the pins,
// the clocks and both video outputs before the computer is involved
// (issue #10). Pin names follow the Next's own zxnext_top_issue4.vhd and
// zxnext_pins_issue4.xdc (fpga/ks2/ks2.xdc has the locations).
//
// The picture, with a white one-pixel frame round the 720x576 area:
//   lines   0-383  eight colour bars, 90 pixels each: white, yellow, cyan,
//                  green, magenta, red, blue, black
//   lines 384-511  ramps of 8 steps: red, green, blue, grey (32 lines each);
//                  each step is one VGA level (3 bits per colour)
//   lines 512-575  black, with a 32x32 square moving left and right, 4
//                  pixels a frame; it is white and yellow in turn, about
//                  0.67 s each, timed by the 100 MHz system clock
// A still square means a frozen picture; a square that never changes
// colour means the 100 MHz clock is not running.
//
// Colours are made as RGB333, as on the KS2's VGA; HDMI gets the same
// colours widened to 8 bits as the Next does (abc -> abcabcab).
//
// Parts not used are held where the Next's top level leaves them: SRAM
// deselected, flash and SD cards deselected, audio low, keyboard rows let
// go. Pins not named here are weakly pulled up (ks2.xdc).
module top_ks2_pattern (
    input  wire        clock_50_i,

    // Video
    output wire [2:0]  rgb_r_o, rgb_g_o, rgb_b_o,
    output wire        hsync_o, vsync_o,
    output wire [3:0]  hdmi_p_o, hdmi_n_o,

    // Held at safe levels
    output wire [19:0] ram_addr_o,
    inout  wire [15:0] ram_data_io,
    output wire        ram_lb_n_o, ram_ub_n_o, ram_oe_n_o, ram_we_n_o, ram_cs_n_o,
    output wire        flash_cs_n_o,
    output wire        sd_cs0_n_o, sd_cs1_n_o,
    output wire        audioext_l_o, audioext_r_o, audioint_o, mic_port_o,
    output wire        joysel_o,
    output wire [7:0]  keyb_row_o,
    inout  wire        bus_ramcs_io
);
    // ---------------------------------------------------------------- clocks
    wire clk100, clk_pix, clk_pix5, locked;
    ks2_clocks clocks (
        .clk50(clock_50_i), .clk100(clk100), .clk_pix(clk_pix), .clk_pix5(clk_pix5), .locked(locked)
    );

    // The 100 MHz clock's heartbeat: bit 26 of a counter, 0.67 s per half
    reg [26:0] beat = 27'd0;
    always @(posedge clk100) beat <= beat + 1'b1;

    (* ASYNC_REG = "TRUE" *) reg [1:0] beat_s = 2'b00;
    always @(posedge clk_pix) beat_s <= {beat_s[0], beat[26]};

    // Serialiser reset: held until both MMCMs lock, then released on clk_pix
    reg [2:0] prst = 3'b111;
    always @(posedge clk_pix) prst <= {prst[1:0], !locked};

    // ---------------------------------------------------------------- 576p timing
    // CEA-861 format 17: 864 x 625 at 27 MHz, both syncs active low
    // (the same numbers as retro68k's video.v)
    localparam [9:0] HVIS = 10'd720;
    localparam [9:0] HSS  = 10'd732;        // front porch 12
    localparam [9:0] HSE  = 10'd796;        // sync 64, back porch 68
    localparam [9:0] HTOT = 10'd864;
    localparam [9:0] VVIS = 10'd576;
    localparam [9:0] VSS  = 10'd581;        // front porch 5
    localparam [9:0] VSE  = 10'd586;        // sync 5, back porch 39
    localparam [9:0] VTOT = 10'd625;

    reg [9:0] hc = 10'd0, vc = 10'd0;
    reg [6:0] bx = 7'd0;                    // pixel within a 90-pixel bar
    reg [2:0] bar = 3'd0;                   // bar 0-7 across the line
    reg [9:0] sq = 10'd0;                   // the square's left edge
    reg       sq_left = 1'b0;               // moving left

    wire line_end  = (hc == HTOT - 1'b1);
    wire frame_end = line_end && (vc == VTOT - 1'b1);

    always @(posedge clk_pix) begin
        hc <= line_end ? 10'd0 : hc + 1'b1;
        if (line_end) vc <= (vc == VTOT - 1'b1) ? 10'd0 : vc + 1'b1;

        if (line_end || bx == 7'd89) begin
            bx  <= 7'd0;
            bar <= line_end ? 3'd0 : bar + 1'b1;
        end else
            bx <= bx + 1'b1;

        if (frame_end) begin
            if (sq_left) begin
                if (sq == 10'd0) sq_left <= 1'b0;
                else sq <= sq - 10'd4;
            end else begin
                if (sq == HVIS - 10'd32) sq_left <= 1'b1;
                else sq <= sq + 10'd4;
            end
        end
    end

    // ---------------------------------------------------------------- the picture
    wire       vis   = (hc < HVIS) && (vc < VVIS);
    wire       frame = (hc == 10'd0) || (hc == HVIS - 1'b1) || (vc == 10'd0) || (vc == VVIS - 1'b1);
    wire       in_sq = (hc >= sq) && (hc < sq + 10'd32) && (vc >= 10'd528) && (vc < 10'd560);

    reg [8:0] c;                            // RGB333
    always @(*) begin
        if (frame)
            c = 9'o777;
        else if (vc < 10'd384)
            c = {{3{!bar[1]}}, {3{!bar[2]}}, {3{!bar[0]}}};
        else if (vc < 10'd416)
            c = {bar, 6'o00};
        else if (vc < 10'd448)
            c = {3'o0, bar, 3'o0};
        else if (vc < 10'd480)
            c = {6'o00, bar};
        else if (vc < 10'd512)
            c = {bar, bar, bar};
        else if (in_sq)
            c = beat_s[1] ? 9'o770 : 9'o777;
        else
            c = 9'o000;
    end

    reg [8:0] pix = 9'd0;
    reg       hs = 1'b1, vs = 1'b1, de = 1'b0;
    always @(posedge clk_pix) begin
        pix <= vis ? c : 9'd0;
        hs  <= !((hc >= HSS) && (hc < HSE));
        vs  <= !((vc >= VSS) && (vc < VSE));
        de  <= vis;
    end

    // ---------------------------------------------------------------- VGA: 3 bits per colour, from the pads' flip-flops
    (* IOB = "TRUE" *) reg [8:0] vga_rgb = 9'd0;
    (* IOB = "TRUE" *) reg       vga_hs = 1'b1, vga_vs = 1'b1;
    always @(posedge clk_pix) begin
        vga_rgb <= pix;
        vga_hs  <= hs;
        vga_vs  <= vs;
    end
    assign rgb_r_o = vga_rgb[8:6];
    assign rgb_g_o = vga_rgb[5:3];
    assign rgb_b_o = vga_rgb[2:0];
    assign hsync_o = vga_hs;
    assign vsync_o = vga_vs;

    // ---------------------------------------------------------------- HDMI (DVI)
    wire [2:0]  r3 = pix[8:6], g3 = pix[5:3], b3 = pix[2:0];
    wire [23:0] rgb24 = {r3, r3, r3[2:1], g3, g3, g3[2:1], b3, b3, b3[2:1]};
    hdmi_out hdmi (
        .clk_pix(clk_pix), .clk_pix5(clk_pix5), .rst(prst[2]),
        .rgb(rgb24), .hsync(hs), .vsync(vs), .de(de),
        .tmds_p(hdmi_p_o), .tmds_n(hdmi_n_o)
    );

    // ---------------------------------------------------------------- not used: safe levels
    assign ram_addr_o   = 20'd0;
    assign ram_data_io  = 16'bz;
    assign ram_cs_n_o   = 1'b1;            // SRAM deselected
    assign ram_oe_n_o   = 1'b1;
    assign ram_we_n_o   = 1'b1;
    assign ram_lb_n_o   = 1'b1;
    assign ram_ub_n_o   = 1'b1;
    assign flash_cs_n_o = 1'b1;            // configuration flash deselected
    assign sd_cs0_n_o   = 1'b1;
    assign sd_cs1_n_o   = 1'b1;
    assign audioext_l_o = 1'b0;
    assign audioext_r_o = 1'b0;
    assign audioint_o   = 1'b0;
    assign mic_port_o   = 1'b0;
    assign joysel_o     = 1'b0;
    assign keyb_row_o   = 8'bz;            // open-drain rows, none driven
    assign bus_ramcs_io = 1'bz;            // expansion bus: pulled down, as on the Next
endmodule
