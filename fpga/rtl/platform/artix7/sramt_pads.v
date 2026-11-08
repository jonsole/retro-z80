// SRAM tester (issue #90): the SRAM pins through the I/O SERDES, Artix-7.
//
// Outputs: every pin through an OSERDESE2, 4:1 DDR, CLK 400 MHz and CLKDIV
// 200 MHz, so each pin changes in steps of 1.25 ns (800 Mb/s). 4:1 rather
// than 8:1 because the tristate serialiser has only 4 bits (T1-T4): with
// CLKDIV at 200 MHz the DQ drive also moves in 1.25 ns steps. The words come
// from the 100 MHz side 8 steps at a time; a gearbox on the 200 MHz clock
// passes on the first 4 steps, then the last 4.
//
// Inputs: each DQ pin through an IDELAYE2 (0-31 taps of 78 ps, loaded at
// run time; 200 MHz reference) into an ISERDESE2, 8:1 DDR, a sample every
// 1.25 ns, presented 8 at a time on the 100 MHz clock.
//
// Latency (from Vivado's unisim models; sim/sramtest/tb_lat.v): the word
// clocked into the *_w inputs at a 100 MHz edge T leaves the OSERDESE2s from
// T + 12.5 ns, step i at T + 12.5 + 1.25i. The samples registered at edge
// T are those taken at T - 25 ns to T - 16.25 ns (at the IDELAYE2's
// output: 0.6 ns plus the taps after the pad). sramt_engine.v aligns
// the two (CAP_LAT, CAP_SKEW). All three clocks come from one MMCM, rising
// together.
module sramt_pads (
    input  wire         clk100,
    input  wire         clk200,
    input  wire         clk400,
    input  wire         rst100,      // synchronous to clk100
    input  wire         rst200,      // synchronous to clk200

    // Pin words from sramt_wave: bit 8p + i is pin p at step i
    input  wire [159:0] addr_w,
    input  wire [7:0]   cs_n_w, oe_n_w, we_n_w, be_n_w,
    input  wire [127:0] dq_w,
    input  wire [7:0]   dq_t_w,

    // DQ samples: bit 8b + k is DQ b at sample k (k = 0 the earliest)
    output reg  [127:0] smp,
    input  wire [4:0]   taps,
    input  wire         taps_ld,

    output wire [19:0]  ram_addr_o,
    inout  wire [15:0]  ram_data_io,
    output wire         ram_cs_n_o, ram_oe_n_o, ram_we_n_o, ram_lb_n_o, ram_ub_n_o
);
    // ---------------------------------------------------------------- gearbox, 100 -> 200 MHz
    // t100 toggles every 100 MHz clock. At the 200 MHz edge between two
    // 100 MHz edges, t100 has just changed and t200 not yet: take the first
    // half of the word; at the next edge (with the 100 MHz edge) the second.
    reg t100 = 1'b0;
    always @(posedge clk100) t100 <= !t100;
    reg t200 = 1'b0;
    always @(posedge clk200) t200 <= t100;
    wire first = (t100 != t200);

    // All 41 pin words in one bus: address 0-19, /CS, /OE, /WE, /LB, /UB, then DQ data, then DQ enable
    localparam NP = 20 + 5 + 16 + 1;
    wire [8*NP-1:0] w_all = {dq_t_w, dq_w, be_n_w, be_n_w, we_n_w, oe_n_w, cs_n_w, addr_w};
    reg  [4*NP-1:0] h;
    integer q;
    always @(posedge clk200)
        for (q = 0; q < NP; q = q + 1)
            h[4*q +: 4] <= first ? w_all[8*q +: 4] : w_all[8*q + 4 +: 4];

    // ---------------------------------------------------------------- outputs
    // Pins 0-24: address, /CS, /OE, /WE, /LB, /UB; idle level 0 for the
    // address, 1 for the strobes
    wire [24:0] opin;
    genvar p;
    generate for (p = 0; p < 25; p = p + 1) begin : op
        localparam [0:0] IDLE = (p >= 20) ? 1'b1 : 1'b0;
        OSERDESE2 #(
            .DATA_RATE_OQ("DDR"), .DATA_RATE_TQ("BUF"), .DATA_WIDTH(4), .TRISTATE_WIDTH(1),
            .SERDES_MODE("MASTER"), .INIT_OQ(IDLE), .SRVAL_OQ(IDLE), .INIT_TQ(1'b0), .SRVAL_TQ(1'b0)
        ) os (
            .OQ(opin[p]), .TQ(), .OFB(), .TFB(), .TBYTEOUT(), .SHIFTOUT1(), .SHIFTOUT2(),
            .CLK(clk400), .CLKDIV(clk200),
            .D1(h[4*p]), .D2(h[4*p+1]), .D3(h[4*p+2]), .D4(h[4*p+3]),
            .D5(1'b0), .D6(1'b0), .D7(1'b0), .D8(1'b0),
            .OCE(1'b1), .TCE(1'b0), .RST(rst200), .SHIFTIN1(1'b0), .SHIFTIN2(1'b0),
            .T1(1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0), .TBYTEIN(1'b0)
        );
    end endgenerate
    assign ram_addr_o = opin[19:0];
    assign ram_cs_n_o = opin[20];
    assign ram_oe_n_o = opin[21];
    assign ram_we_n_o = opin[22];
    assign ram_lb_n_o = opin[23];
    assign ram_ub_n_o = opin[24];

    // ---------------------------------------------------------------- DQ
    // One IDELAYCTRL (Vivado copies it into each clock region with IDELAYs)
    IDELAYCTRL ctl (.REFCLK(clk200), .RST(rst200), .RDY());

    // Data in h[4*(25+b)], drive enable (1 = off) in h[4*41]
    localparam TB = 4 * 41;
    wire [7:0] qs [0:15];
    generate for (p = 0; p < 16; p = p + 1) begin : dq
        wire oq, tq, din, ddly;
        OSERDESE2 #(
            .DATA_RATE_OQ("DDR"), .DATA_RATE_TQ("DDR"), .DATA_WIDTH(4), .TRISTATE_WIDTH(4),
            .SERDES_MODE("MASTER"), .INIT_OQ(1'b0), .SRVAL_OQ(1'b0), .INIT_TQ(1'b1), .SRVAL_TQ(1'b1)
        ) os (
            .OQ(oq), .TQ(tq), .OFB(), .TFB(), .TBYTEOUT(), .SHIFTOUT1(), .SHIFTOUT2(),
            .CLK(clk400), .CLKDIV(clk200),
            .D1(h[4*(25+p)]), .D2(h[4*(25+p)+1]), .D3(h[4*(25+p)+2]), .D4(h[4*(25+p)+3]),
            .D5(1'b0), .D6(1'b0), .D7(1'b0), .D8(1'b0),
            .OCE(1'b1), .TCE(1'b1), .RST(rst200), .SHIFTIN1(1'b0), .SHIFTIN2(1'b0),
            .T1(h[TB]), .T2(h[TB+1]), .T3(h[TB+2]), .T4(h[TB+3]), .TBYTEIN(1'b0)
        );
        IOBUF io (.IO(ram_data_io[p]), .I(oq), .T(tq), .O(din));
        IDELAYE2 #(
            .IDELAY_TYPE("VAR_LOAD"), .DELAY_SRC("IDATAIN"), .IDELAY_VALUE(0),
            .HIGH_PERFORMANCE_MODE("TRUE"), .REFCLK_FREQUENCY(200.0),
            .SIGNAL_PATTERN("DATA"), .CINVCTRL_SEL("FALSE"), .PIPE_SEL("FALSE")
        ) dl (
            .IDATAIN(din), .DATAIN(1'b0), .DATAOUT(ddly), .C(clk100),
            .CE(1'b0), .INC(1'b0), .LD(taps_ld), .LDPIPEEN(1'b0),
            .CNTVALUEIN(taps), .CNTVALUEOUT(), .CINVCTRL(1'b0), .REGRST(1'b0)
        );
        ISERDESE2 #(
            .DATA_RATE("DDR"), .DATA_WIDTH(8), .INTERFACE_TYPE("NETWORKING"),
            .IOBDELAY("IFD"), .NUM_CE(1), .OFB_USED("FALSE"), .SERDES_MODE("MASTER")
        ) is (
            .Q1(qs[p][7]), .Q2(qs[p][6]), .Q3(qs[p][5]), .Q4(qs[p][4]),
            .Q5(qs[p][3]), .Q6(qs[p][2]), .Q7(qs[p][1]), .Q8(qs[p][0]),   // Q8 is the earliest
            .O(), .SHIFTOUT1(), .SHIFTOUT2(),
            .BITSLIP(1'b0), .CE1(1'b1), .CE2(1'b1), .CLKDIVP(1'b0),
            .CLK(clk400), .CLKB(!clk400), .CLKDIV(clk100), .OCLK(1'b0), .OCLKB(1'b0),
            .DYNCLKDIVSEL(1'b0), .DYNCLKSEL(1'b0),
            .D(1'b0), .DDLY(ddly), .OFB(1'b0), .RST(rst100),
            .SHIFTIN1(1'b0), .SHIFTIN2(1'b0)
        );
        always @(posedge clk100) smp[8*p +: 8] <= qs[p];
    end endgenerate
endmodule
