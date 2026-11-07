// The SRAM pins through the I/O SERDES for the fast-memory experiment
// (issue #91; sram_ctl8.v), Artix-7. The SRAM tester's pads (sramt_pads.v,
// issue #90), as measured on the KS2, with three changes:
//   - /LB and /UB have pin words of their own (the tester drove them alike);
//   - the IDELAYE2s are fixed at TAPS (the tester loaded them at run time);
//   - the ISERDESE2s' outputs go straight out (qs), not through a register,
//     so read data is a clock earlier than the tester's smp.
//
// Outputs: every pin through an OSERDESE2, 4:1 DDR, CLK 400 MHz and CLKDIV
// 200 MHz, so each pin changes in steps of 1.25 ns. The words come from the
// 100 MHz side 8 steps at a time; a gearbox on the 200 MHz clock passes on
// the first 4 steps, then the last 4. The word clocked into the *_w inputs
// at a 100 MHz edge T leaves the OSERDESE2s from T + 12.5 ns, step i at
// T + 12.5 + 1.25i.
//
// Inputs: each DQ pin through an IDELAYE2 (TAPS taps of 78 ps; 200 MHz
// reference) into an ISERDESE2, 8:1 DDR, a sample every 1.25 ns. At a
// 100 MHz edge X, qs holds the samples taken at X - 15 ns to X - 6.25 ns
// (at the IDELAYE2's output: 0.6 ns plus the taps after the pad). All three
// clocks come from one MMCM, rising together.
module sram8_pads #(
    parameter AW   = 20,             // address pins
    parameter TAPS = 8               // IDELAY taps (more taps sample earlier)
) (
    input  wire          clk100,
    input  wire          clk200,
    input  wire          clk400,
    input  wire          rst100,     // synchronous to clk100
    input  wire          rst200,     // synchronous to clk200

    // Pin words from sram_ctl8: bit 8p + i is pin p at step i
    input  wire [8*AW-1:0] addr_w,
    input  wire [7:0]    cs_n_w, oe_n_w, we_n_w, lb_n_w, ub_n_w,
    input  wire [127:0]  dq_w,
    input  wire [7:0]    dq_t_w,

    // DQ samples: bit 8b + k is DQ b at sample k (k = 0 the earliest)
    output wire [127:0]  qs,

    output wire [AW-1:0] ram_addr_o,
    inout  wire [15:0]   ram_data_io,
    output wire          ram_cs_n_o, ram_oe_n_o, ram_we_n_o, ram_lb_n_o, ram_ub_n_o
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

    // All the pin words in one bus: address, /CS, /OE, /WE, /LB, /UB, then DQ data, then DQ enable
    localparam NO = AW + 5;                  // output-only pins
    localparam NP = NO + 16 + 1;
    wire [8*NP-1:0] w_all = {dq_t_w, dq_w, ub_n_w, lb_n_w, we_n_w, oe_n_w, cs_n_w, addr_w};
    reg  [4*NP-1:0] h;
    integer q;
    always @(posedge clk200)
        for (q = 0; q < NP; q = q + 1)
            h[4*q +: 4] <= first ? w_all[8*q +: 4] : w_all[8*q + 4 +: 4];

    // ---------------------------------------------------------------- outputs
    // Address (idle level 0) and the strobes (idle level 1)
    wire [NO-1:0] opin;
    genvar p;
    generate for (p = 0; p < NO; p = p + 1) begin : op
        localparam [0:0] IDLE = (p >= AW) ? 1'b1 : 1'b0;
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
    assign ram_addr_o = opin[AW-1:0];
    assign ram_cs_n_o = opin[AW];
    assign ram_oe_n_o = opin[AW+1];
    assign ram_we_n_o = opin[AW+2];
    assign ram_lb_n_o = opin[AW+3];
    assign ram_ub_n_o = opin[AW+4];

    // ---------------------------------------------------------------- DQ
    // One IDELAYCTRL (Vivado copies it into each clock region with IDELAYs)
    IDELAYCTRL ctl (.REFCLK(clk200), .RST(rst200), .RDY());

    // Data in h[4*(NO+b)], drive enable (1 = off) in h[4*(NO+16)]
    localparam TB = 4 * (NO + 16);
    generate for (p = 0; p < 16; p = p + 1) begin : dq
        wire oq, tq, din, ddly;
        OSERDESE2 #(
            .DATA_RATE_OQ("DDR"), .DATA_RATE_TQ("DDR"), .DATA_WIDTH(4), .TRISTATE_WIDTH(4),
            .SERDES_MODE("MASTER"), .INIT_OQ(1'b0), .SRVAL_OQ(1'b0), .INIT_TQ(1'b1), .SRVAL_TQ(1'b1)
        ) os (
            .OQ(oq), .TQ(tq), .OFB(), .TFB(), .TBYTEOUT(), .SHIFTOUT1(), .SHIFTOUT2(),
            .CLK(clk400), .CLKDIV(clk200),
            .D1(h[4*(NO+p)]), .D2(h[4*(NO+p)+1]), .D3(h[4*(NO+p)+2]), .D4(h[4*(NO+p)+3]),
            .D5(1'b0), .D6(1'b0), .D7(1'b0), .D8(1'b0),
            .OCE(1'b1), .TCE(1'b1), .RST(rst200), .SHIFTIN1(1'b0), .SHIFTIN2(1'b0),
            .T1(h[TB]), .T2(h[TB+1]), .T3(h[TB+2]), .T4(h[TB+3]), .TBYTEIN(1'b0)
        );
        IOBUF io (.IO(ram_data_io[p]), .I(oq), .T(tq), .O(din));
        IDELAYE2 #(
            .IDELAY_TYPE("FIXED"), .DELAY_SRC("IDATAIN"), .IDELAY_VALUE(TAPS),
            .HIGH_PERFORMANCE_MODE("TRUE"), .REFCLK_FREQUENCY(200.0),
            .SIGNAL_PATTERN("DATA"), .CINVCTRL_SEL("FALSE"), .PIPE_SEL("FALSE")
        ) dl (
            .IDATAIN(din), .DATAIN(1'b0), .DATAOUT(ddly), .C(1'b0),
            .CE(1'b0), .INC(1'b0), .LD(1'b0), .LDPIPEEN(1'b0),
            .CNTVALUEIN(5'd0), .CNTVALUEOUT(), .CINVCTRL(1'b0), .REGRST(1'b0)
        );
        ISERDESE2 #(
            .DATA_RATE("DDR"), .DATA_WIDTH(8), .INTERFACE_TYPE("NETWORKING"),
            .IOBDELAY("IFD"), .NUM_CE(1), .OFB_USED("FALSE"), .SERDES_MODE("MASTER")
        ) is (
            .Q1(qs[8*p+7]), .Q2(qs[8*p+6]), .Q3(qs[8*p+5]), .Q4(qs[8*p+4]),
            .Q5(qs[8*p+3]), .Q6(qs[8*p+2]), .Q7(qs[8*p+1]), .Q8(qs[8*p]),   // Q8 is the earliest
            .O(), .SHIFTOUT1(), .SHIFTOUT2(),
            .BITSLIP(1'b0), .CE1(1'b1), .CE2(1'b1), .CLKDIVP(1'b0),
            .CLK(clk400), .CLKB(!clk400), .CLKDIV(clk100), .OCLK(1'b0), .OCLKB(1'b0),
            .DYNCLKDIVSEL(1'b0), .DYNCLKSEL(1'b0),
            .D(1'b0), .DDLY(ddly), .OFB(1'b0), .RST(rst100),
            .SHIFTIN1(1'b0), .SHIFTIN2(1'b0)
        );
    end endgenerate
endmodule
