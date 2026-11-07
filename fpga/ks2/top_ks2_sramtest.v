// retro-z80 on the ZX Spectrum Next KS2 (issue 4): the SRAM timing tester
// (issue #90, design plan branch 24). Not the computer: a bitstream of its
// own, as the test pattern, that writes and reads the KS2's SRAM
// (IS61WV102416FBLL-8, 1M x 16) with every edge set at run time in steps of
// 1.25 ns, and counts the errors. tools/sramtest.py drives it over the
// FT232H and makes the maps (docs/notes/sram-ks2.md).
//
//   sramt_engine.v  settings, test patterns, cycle stepping, checks, results
//   sramt_wave.v    the pin waveforms, 8 steps a clock
//   sramt_pads.v    OSERDESE2 / IDELAYE2 / ISERDESE2 on the SRAM pins
//   sramt_link.v    the FT232H and the byte protocol
//
// Clocks, one MMCM from the 50 MHz oscillator: VCO 800 MHz; 400 MHz (the
// SERDES bit clock), 200 MHz (the output SERDES word clock and the IDELAY
// reference) and 100 MHz (everything else), all on BUFGs, rising together.
//
// The FT232H on the accelerator port, as the computer's build:
//   accel_io[7:0] D7-D0, [8] RXF#, [9] TXE#, [10] RD#, [11] WR#, [12] SIWU#
//
// Other parts are held where the test pattern holds them: video dark, flash
// and SD cards deselected, audio low, keyboard rows let go.
module top_ks2_sramtest (
    input  wire        clock_50_i,

    output wire [19:0] ram_addr_o,
    inout  wire [15:0] ram_data_io,
    output wire        ram_lb_n_o, ram_ub_n_o, ram_oe_n_o, ram_we_n_o, ram_cs_n_o,

    inout  wire [12:0] accel_io,

    // Held at safe levels
    output wire [2:0]  rgb_r_o, rgb_g_o, rgb_b_o,
    output wire        hsync_o, vsync_o,
    output wire [3:0]  hdmi_p_o, hdmi_n_o,
    output wire        flash_cs_n_o,
    output wire        sd_cs0_n_o, sd_cs1_n_o,
    output wire        audioext_l_o, audioext_r_o, audioint_o, mic_port_o,
    output wire        joysel_o,
    output wire [7:0]  keyb_row_o,
    inout  wire        bus_ramcs_io
);
    // ---------------------------------------------------------------- clocks
    wire clk50_b, fb, fb_b, c400, c200, c100, locked;
    wire clk400, clk200, clk100;
    BUFG b_in (.I(clock_50_i), .O(clk50_b));
    MMCME2_BASE #(
        .CLKIN1_PERIOD    (20.0),
        .DIVCLK_DIVIDE    (1),
        .CLKFBOUT_MULT_F  (16.0),           // VCO 800 MHz
        .CLKOUT0_DIVIDE_F (2.0),            // 400 MHz
        .CLKOUT1_DIVIDE   (4),              // 200 MHz
        .CLKOUT2_DIVIDE   (8)               // 100 MHz
    ) mmcm (
        .CLKIN1(clk50_b), .CLKFBIN(fb_b), .CLKFBOUT(fb),
        .CLKOUT0(c400), .CLKOUT1(c200), .CLKOUT2(c100), .CLKOUT3(), .CLKOUT4(),
        .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2B(), .CLKOUT3B(), .CLKFBOUTB(),
        .CLKOUT5(), .CLKOUT6(),
        .LOCKED(locked), .PWRDWN(1'b0), .RST(1'b0)
    );
    BUFG b_fb  (.I(fb),   .O(fb_b));
    BUFG b_400 (.I(c400), .O(clk400));
    BUFG b_200 (.I(c200), .O(clk200));
    BUFG b_100 (.I(c100), .O(clk100));

    // Reset: held until the MMCM locks, then 256 clocks more; the 200 MHz
    // copy for the output SERDES and the IDELAYCTRL
    (* ASYNC_REG = "TRUE" *) reg [1:0] lk_s = 2'b00;
    reg [7:0] por_cnt = 8'd0;
    reg       por = 1'b1;
    always @(posedge clk100) begin
        lk_s <= {lk_s[0], locked};
        if (!lk_s[1]) begin
            por_cnt <= 8'd0;
            por     <= 1'b1;
        end else if (por_cnt != 8'hFF)
            por_cnt <= por_cnt + 8'd1;
        else
            por <= 1'b0;
    end
    reg [1:0] por200 = 2'b11;
    always @(posedge clk200) por200 <= {por200[0], por};

    // ---------------------------------------------------------------- the tester
    wire        set_we, run, busy, taps_ld;
    wire [4:0]  set_idx, taps;
    wire [15:0] set_val;
    wire [8:0]  rd_addr;
    wire [7:0]  rd_data;
    wire [5:0]  ph, j, oe_lo, oe_hi, we_lo, we_hi, d_lo, d_hi, war_lo;
    wire [1:0]  a_kind, b_kind;
    wire        a_war, b_war;
    wire [19:0] a_addr, b_addr;
    wire [15:0] a_data, b_data;
    wire [127:0] smp;

    sramt_engine eng (
        .clk(clk100), .rst(por),
        .set_we(set_we), .set_idx(set_idx), .set_val(set_val), .run(run), .busy(busy),
        .rd_addr(rd_addr), .rd_data(rd_data),
        .ph(ph), .j(j), .a_kind(a_kind), .a_war(a_war), .a_addr(a_addr), .a_data(a_data),
        .b_kind(b_kind), .b_war(b_war), .b_addr(b_addr), .b_data(b_data),
        .oe_lo(oe_lo), .oe_hi(oe_hi), .we_lo(we_lo), .we_hi(we_hi),
        .d_lo(d_lo), .d_hi(d_hi), .war_lo(war_lo),
        .smp(smp), .taps(taps), .taps_ld(taps_ld)
    );

    wire [159:0] addr_w;
    wire [127:0] dq_w;
    wire [7:0]   cs_n_w, oe_n_w, we_n_w, be_n_w, dq_t_w;
    sramt_wave wave (
        .clk(clk100),
        .ph(ph), .j(j), .a_kind(a_kind), .a_war(a_war), .a_addr(a_addr), .a_data(a_data),
        .b_kind(b_kind), .b_war(b_war), .b_addr(b_addr), .b_data(b_data),
        .oe_lo(oe_lo), .oe_hi(oe_hi), .we_lo(we_lo), .we_hi(we_hi),
        .d_lo(d_lo), .d_hi(d_hi), .war_lo(war_lo),
        .addr_w(addr_w), .cs_n_w(cs_n_w), .oe_n_w(oe_n_w), .we_n_w(we_n_w), .be_n_w(be_n_w),
        .dq_w(dq_w), .dq_t_w(dq_t_w)
    );

    sramt_pads pads (
        .clk100(clk100), .clk200(clk200), .clk400(clk400), .rst100(por), .rst200(por200[1]),
        .addr_w(addr_w), .cs_n_w(cs_n_w), .oe_n_w(oe_n_w), .we_n_w(we_n_w), .be_n_w(be_n_w),
        .dq_w(dq_w), .dq_t_w(dq_t_w),
        .smp(smp), .taps(taps), .taps_ld(taps_ld),
        .ram_addr_o(ram_addr_o), .ram_data_io(ram_data_io),
        .ram_cs_n_o(ram_cs_n_o), .ram_oe_n_o(ram_oe_n_o), .ram_we_n_o(ram_we_n_o),
        .ram_lb_n_o(ram_lb_n_o), .ram_ub_n_o(ram_ub_n_o)
    );

    // ---------------------------------------------------------------- FT232H
    wire [7:0] ft_d_i, ft_d_o;
    wire       ft_d_oe, ft_rd_n, ft_wr_n, ft_siwu_n;
    sramt_link link (
        .clk(clk100), .rst(por),
        .ft_rxf_n(accel_io[8]), .ft_txe_n(accel_io[9]), .ft_d_i(ft_d_i), .ft_d_o(ft_d_o),
        .ft_d_oe(ft_d_oe), .ft_rd_n(ft_rd_n), .ft_wr_n(ft_wr_n), .ft_siwu_n(ft_siwu_n),
        .set_we(set_we), .set_idx(set_idx), .set_val(set_val), .run(run), .busy(busy),
        .rd_addr(rd_addr), .rd_data(rd_data)
    );
    genvar i;
    generate for (i = 0; i < 8; i = i + 1) begin : ftd
        IOBUF io (.IO(accel_io[i]), .I(ft_d_o[i]), .O(ft_d_i[i]), .T(!ft_d_oe));
    end endgenerate
    assign accel_io[8]  = 1'bz;          // RXF#, TXE#: inputs (pulled up when no module)
    assign accel_io[9]  = 1'bz;
    assign accel_io[10] = ft_rd_n;
    assign accel_io[11] = ft_wr_n;
    assign accel_io[12] = ft_siwu_n;

    // ---------------------------------------------------------------- not used: safe levels
    assign rgb_r_o = 3'd0;
    assign rgb_g_o = 3'd0;
    assign rgb_b_o = 3'd0;
    assign hsync_o = 1'b1;
    assign vsync_o = 1'b1;
    generate for (i = 0; i < 4; i = i + 1) begin : hd
        OBUFDS #(.IOSTANDARD("TMDS_33")) ob (.I(1'b0), .O(hdmi_p_o[i]), .OB(hdmi_n_o[i]));
    end endgenerate
    assign flash_cs_n_o = 1'b1;
    assign sd_cs0_n_o   = 1'b1;
    assign sd_cs1_n_o   = 1'b1;
    assign audioext_l_o = 1'b0;
    assign audioext_r_o = 1'b0;
    assign audioint_o   = 1'b0;
    assign mic_port_o   = 1'b0;
    assign joysel_o     = 1'b0;
    assign keyb_row_o   = 8'bz;
    assign bus_ramcs_io = 1'bz;
endmodule
