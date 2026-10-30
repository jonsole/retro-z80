// retro-z80 on the ZX Spectrum Next KS2 (issue 4): the computer (issue #11).
// After retro68k's top_ks3.v. Pin names follow the Next's own
// zxnext_top_issue4.vhd and zxnext_pins_issue4.xdc (fpga/ks2/ks2.xdc and
// ks2_machine.xdc have the locations).
//
// The computer (retroz80.v) built for the KS2's 2 MB SRAM (CHIPMB = 2;
// IS61WV102416FBLL, 1M x 16, 20 address lines), with the start of the
// video unit: the 576p beam and the background colour, on HDMI (24-bit) and
// VGA (3 bits per colour, the top bits). The boot ROM shows its progress as
// the screen's colour (firmware/boot/boot.asm, fpga/ks2/README.md).
//
// The FT232H USB module sits on the accelerator port (provisional pins, as
// retro68k's KS3 build; spec 10, open point U2):
//   accel_io[7:0] D7-D0, [8] RXF#, [9] TXE#, [10] RD#, [11] WR#, [12] SIWU#
// With no module the pull-ups make RXF# and TXE# read "not ready" and the
// link is idle.
//
// Reset: power-on (both MMCMs locked) and the board's reset button. The
// MULTIFACE and DIVMMC buttons go to SYSBTN.
//
// Input (issue #19, spec 12), pins as the Next's issue 4 files:
//   PS/2 keyboard  ps2_clk_io, ps2_data_io: open collector, pulled up (the
//                  Next's socket pins 1 and 5; its mouse pins are not used)
//   membrane       keyb_row_o[7:0] open drain (low or let go, pulled up, as
//                  the Next drives them, so two rows are never shorted
//                  through two keys of one column); keyb_col_i[6:0] pulled up
//   joysticks      joyp1_i-joyp4_i, joyp6_i, joyp9_i shared by both ports
//                  through the multiplexer, joysel_o picking the port (0 the
//                  left), joyp7_o the Mega Drive select for both
//
// Audio (issue #21, spec 7, section 10.2): the beeper's three sigma-delta
// streams at 100 MHz, from the pads' flip-flops, on the Next's issue 4 pins:
//   audioext_l_o, audioext_r_o  the audio jack (left, right; DRIVE 16)
//   audioint_o                  the internal speaker (mono; DRIVE 8, slow)
// The board's RC filters turn them into sound, as the Next's own (first
// order, 28 MHz) DAC streams.
//
// Not used yet (held where the Next's top level leaves them, as in the test
// pattern build): flash and SD cards deselected, MIC low,
// expansion bus RAMCS pulled down. Other pins are weakly pulled up
// (ks2.xdc).
module top_ks2 #(
    parameter GEOM = 0                 // 1: the geometry unit in place of the DMA engine (spec 15, section 8)
) (
    input  wire        clock_50_i,

    // SRAM
    output wire [19:0] ram_addr_o,
    inout  wire [15:0] ram_data_io,
    output wire        ram_lb_n_o, ram_ub_n_o, ram_oe_n_o, ram_we_n_o, ram_cs_n_o,

    // Video
    output wire [2:0]  rgb_r_o, rgb_g_o, rgb_b_o,
    output wire        hsync_o, vsync_o,
    output wire [3:0]  hdmi_p_o, hdmi_n_o,

    // Buttons
    input  wire        btn_reset_n_i, btn_multiface_n_i, btn_divmmc_n_i,

    // Accelerator port: the FT232H
    inout  wire [12:0] accel_io,

    // Input
    inout  wire        ps2_clk_io, ps2_data_io,
    output wire [7:0]  keyb_row_o,
    input  wire [6:0]  keyb_col_i,
    input  wire        joyp1_i, joyp2_i, joyp3_i, joyp4_i, joyp6_i, joyp9_i,
    output wire        joyp7_o,
    output wire        joysel_o,

    // Held at safe levels
    output wire        flash_cs_n_o,
    output wire        sd_cs0_n_o, sd_cs1_n_o,
    output wire        mic_port_o,
    inout  wire        bus_ramcs_io,

    // Audio (spec 7, section 10.2): sigma-delta streams to the board's RC
    // filters, the jack and the internal speaker
    output wire        audioext_l_o, audioext_r_o, audioint_o
);
    // ---------------------------------------------------------------- clocks and reset
    wire clk100, clk_pix, clk_pix5, locked;
    ks2_clocks clocks (
        .clk50(clock_50_i), .clk100(clk100), .clk_pix(clk_pix), .clk_pix5(clk_pix5), .locked(locked)
    );

    // Power-on reset: held until both MMCMs lock, then 256 more clocks
    (* ASYNC_REG = "TRUE" *) reg [1:0] lk_s = 2'b00;
    reg [7:0] por_cnt = 8'd0;
    reg       por = 1'b1;
    always @(posedge clk100) begin
        lk_s <= {lk_s[0], locked};
        if (!lk_s[1]) begin
            por_cnt <= 8'd0;
            por     <= 1'b1;
        end else if (por_cnt != 8'hFF)
            por_cnt <= por_cnt + 1'b1;
        else
            por <= 1'b0;
    end

    // Buttons: synchronise, then 2^20 clocks (10 ms) of agreement (as retro68k)
    (* ASYNC_REG = "TRUE" *) reg [2:0] btn_s0 = 3'b000;
    reg  [2:0]  btn_s1 = 3'b000, btn_q = 3'b000;    // 1 = pressed: reset, multiface, divmmc
    reg  [19:0] btn_t = 20'd0;
    wire [2:0]  btn_raw = {!btn_divmmc_n_i, !btn_multiface_n_i, !btn_reset_n_i};
    always @(posedge clk100) begin
        btn_s0 <= btn_raw;
        btn_s1 <= btn_s0;
        if (btn_s1 == btn_q) btn_t <= 20'd0;
        else if (&btn_t) begin btn_q <= btn_s1; btn_t <= 20'd0; end
        else btn_t <= btn_t + 1'b1;
    end

    // ---------------------------------------------------------------- the computer
    wire [20:0] a;
    wire        ce_n, ub_n, lb_n, oe_r, oe_f, we_r, we_f, t_r, t_f;
    wire [15:0] dq_o, dq_i;
    wire [7:0]  ft_d_i, ft_d_o;
    wire        ft_d_oe, ft_rd_n, ft_wr_n, ft_siwu_n;
    wire [23:0] rgb;
    wire        hs, vs, de;
    wire        ps2_clk_low, ps2_data_low;
    wire [7:0]  row_low;
    wire        aud_l, aud_r, aud_m;

    // 2 sprites and no DMA mask image, so the DMA engine fits (design plan, branch 21).
    // The XC7A15T has room for the DMA engine or the geometry unit, not both.
    retroz80 #(.ROM_INIT("boot.hex"), .CHIPMB(6'd2), .NSPRITES(2), .DMX_MASKIMG(0),
               .DMX(GEOM ? 0 : 1), .GEOM(GEOM)) sys (
        .clk(clk100), .por(por),
        .btn_reset_n(!btn_q[0]), .buttons(btn_q[2:1]),
        .sram_a(a), .sram_ce_n(ce_n), .sram_ub_n(ub_n), .sram_lb_n(lb_n),
        .sram_oe_n_r(oe_r), .sram_oe_n_f(oe_f), .sram_we_n_r(we_r), .sram_we_n_f(we_f),
        .sram_dq_o(dq_o), .sram_dq_t_r(t_r), .sram_dq_t_f(t_f), .sram_dq_i(dq_i),
        .ft_rxf_n(accel_io[8]), .ft_txe_n(accel_io[9]), .ft_d_i(ft_d_i), .ft_d_o(ft_d_o),
        .ft_d_oe(ft_d_oe), .ft_rd_n(ft_rd_n), .ft_wr_n(ft_wr_n), .ft_siwu_n(ft_siwu_n),
        .clk_pix(clk_pix), .clk_pix5(clk_pix5), .vid_rgb(rgb), .vid_hsync(hs), .vid_vsync(vs), .vid_de(de),
        .ps2_clk_i(ps2_clk_io), .ps2_data_i(ps2_data_io), .ps2_clk_low(ps2_clk_low), .ps2_data_low(ps2_data_low),
        .keyb_row_low(row_low), .keyb_col_i(keyb_col_i),
        .joy_pin_n({joyp9_i, joyp6_i, joyp4_i, joyp3_i, joyp2_i, joyp1_i}), .joy_sel(joysel_o), .joy_p7(joyp7_o),
        .audio_l(aud_l), .audio_r(aud_r), .audio_m(aud_m),
        .dma_req(1'b0), .dma_we(1'b0), .dma_addr(21'd0), .dma_wdata(16'd0), .dma_be(2'b00),
        .dma_ack(), .dma_rvalid(), .dma_rdata(),
        .dbg_sc()
    );

    // ---------------------------------------------------------------- SRAM pads
    // Output flip-flops in the pads (IOB), DDR registers for /OE, /WE and the
    // data bus enable; read data is taken by sram_ctl's rdata register, which
    // goes in the input pads (ks2_machine.xdc). The 2 MB build drives
    // physical address bits 20-1 (sram_a[19:0]); sram_a[20] is always 0.
    (* IOB = "TRUE" *) reg [19:0] pad_a = 20'd0;
    (* IOB = "TRUE" *) reg        pce_n = 1'b1, pub_n = 1'b1, plb_n = 1'b1;
    (* IOB = "TRUE" *) reg [15:0] pdq = 16'd0;
    always @(posedge clk100) begin
        pad_a <= a[19:0];
        pce_n <= ce_n;
        pub_n <= ub_n;
        plb_n <= lb_n;
        pdq   <= dq_o;
    end
    assign ram_addr_o = pad_a;
    assign ram_cs_n_o = pce_n;
    assign ram_ub_n_o = pub_n;
    assign ram_lb_n_o = plb_n;

    oddr #(.INIT(1'b1)) o_oe (.clk(clk100), .d_r(oe_r), .d_f(oe_f), .q(ram_oe_n_o));
    oddr #(.INIT(1'b1)) o_we (.clk(clk100), .d_r(we_r), .d_f(we_f), .q(ram_we_n_o));

    genvar i;
    generate for (i = 0; i < 16; i = i + 1) begin : dq
        wire t;
        oddr #(.INIT(1'b1)) o_t (.clk(clk100), .d_r(t_r), .d_f(t_f), .q(t));
        IOBUF io (.IO(ram_data_io[i]), .I(pdq[i]), .O(dq_i[i]), .T(t));
    end endgenerate

    // ---------------------------------------------------------------- FT232H
    generate for (i = 0; i < 8; i = i + 1) begin : ftd
        IOBUF io (.IO(accel_io[i]), .I(ft_d_o[i]), .O(ft_d_i[i]), .T(!ft_d_oe));
    end endgenerate
    assign accel_io[8]  = 1'bz;          // RXF#, TXE#: inputs (pulled up when no module)
    assign accel_io[9]  = 1'bz;
    assign accel_io[10] = ft_rd_n;
    assign accel_io[11] = ft_wr_n;
    assign accel_io[12] = ft_siwu_n;

    // ---------------------------------------------------------------- input: open-drain outputs
    assign ps2_clk_io  = ps2_clk_low  ? 1'b0 : 1'bz;
    assign ps2_data_io = ps2_data_low ? 1'b0 : 1'bz;
    generate for (i = 0; i < 8; i = i + 1) begin : krow
        assign keyb_row_o[i] = row_low[i] ? 1'b0 : 1'bz;
    end endgenerate

    // ---------------------------------------------------------------- video out
    // Serialiser reset: held until both MMCMs lock, then released on clk_pix
    reg [2:0] prst = 3'b111;
    always @(posedge clk_pix) prst <= {prst[1:0], !locked};

    hdmi_out hdmi (
        .clk_pix(clk_pix), .clk_pix5(clk_pix5), .rst(prst[2]),
        .rgb(rgb), .hsync(hs), .vsync(vs), .de(de),
        .tmds_p(hdmi_p_o), .tmds_n(hdmi_n_o)
    );

    // VGA: the top 3 bits of each colour, from the pads' flip-flops (no DAC)
    (* IOB = "TRUE" *) reg [8:0] vga_rgb = 9'd0;
    (* IOB = "TRUE" *) reg       vga_hs = 1'b1, vga_vs = 1'b1;
    always @(posedge clk_pix) begin
        vga_rgb <= {rgb[23:21], rgb[15:13], rgb[7:5]};
        vga_hs  <= hs;
        vga_vs  <= vs;
    end
    assign rgb_r_o = vga_rgb[8:6];
    assign rgb_g_o = vga_rgb[5:3];
    assign rgb_b_o = vga_rgb[2:0];
    assign hsync_o = vga_hs;
    assign vsync_o = vga_vs;

    // ---------------------------------------------------------------- audio
    // The three streams from the pads' flip-flops, as the Next registers its
    // DAC outputs (zxnext_top_issue4.vhd), so every edge leaves on the clock
    (* IOB = "TRUE" *) reg pad_aud_l = 1'b0, pad_aud_r = 1'b0, pad_aud_m = 1'b0;
    always @(posedge clk100) begin
        pad_aud_l <= aud_l;
        pad_aud_r <= aud_r;
        pad_aud_m <= aud_m;
    end
    assign audioext_l_o = pad_aud_l;
    assign audioext_r_o = pad_aud_r;
    assign audioint_o   = pad_aud_m;

    // ---------------------------------------------------------------- not used yet: safe levels
    assign flash_cs_n_o = 1'b1;            // configuration flash deselected
    assign sd_cs0_n_o   = 1'b1;
    assign sd_cs1_n_o   = 1'b1;
    assign mic_port_o   = 1'b0;
    assign bus_ramcs_io = 1'bz;            // expansion bus: pulled down, as on the Next
endmodule
