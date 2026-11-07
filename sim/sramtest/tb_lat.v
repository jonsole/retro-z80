// The SERDES and IDELAY latencies the SRAM tester relies on, checked two
// ways (sim/README.md): in Vivado's xsim against the real unisim
// models, which wrote lat.ref, and in Icarus against xilinx_models.v,
// which must print the same lines (make -C sim sramtest).
//
// An OSERDESE2 (4:1 DDR) sends a one-step marker in each of the 8 step
// positions of a 10 ns word in turn, with its tristate output alike; it
// goes through an IDELAYE2 (0 taps, then 16) into an ISERDESE2 (8:1 DDR).
`timescale 1ps/1ps
module tb_lat;
    reg clk400 = 1'b1, clk200 = 1'b1, clk100 = 1'b1;   // rising together at 0, 10 ns, ...
    always #1250 clk400 = !clk400;
    always #2500 clk200 = !clk200;
    always #5000 clk100 = !clk100;

    reg        rst = 1'b1;
    reg  [3:0] d = 4'b0000, t = 4'b1111;
    wire       oq, tq, ddly;
    wire [8:1] q;
    reg  [4:0] tap = 5'd0;
    reg        ld = 1'b0;

    OSERDESE2 #(.DATA_RATE_OQ("DDR"), .DATA_RATE_TQ("DDR"), .DATA_WIDTH(4), .TRISTATE_WIDTH(4),
                .SERDES_MODE("MASTER"), .INIT_OQ(1'b0), .INIT_TQ(1'b1), .SRVAL_OQ(1'b0), .SRVAL_TQ(1'b1))
      os (.OQ(oq), .TQ(tq), .OFB(), .TFB(), .TBYTEOUT(), .SHIFTOUT1(), .SHIFTOUT2(),
          .CLK(clk400), .CLKDIV(clk200), .D1(d[0]), .D2(d[1]), .D3(d[2]), .D4(d[3]),
          .D5(1'b0), .D6(1'b0), .D7(1'b0), .D8(1'b0), .OCE(1'b1), .TCE(1'b1), .RST(rst),
          .SHIFTIN1(1'b0), .SHIFTIN2(1'b0), .T1(t[0]), .T2(t[1]), .T3(t[2]), .T4(t[3]), .TBYTEIN(1'b0));
    IDELAYE2 #(.IDELAY_TYPE("VAR_LOAD"), .DELAY_SRC("IDATAIN"), .HIGH_PERFORMANCE_MODE("TRUE"),
               .REFCLK_FREQUENCY(200.0), .SIGNAL_PATTERN("DATA"), .IDELAY_VALUE(0),
               .CINVCTRL_SEL("FALSE"), .PIPE_SEL("FALSE"))
      dl (.IDATAIN(oq), .DATAIN(1'b0), .DATAOUT(ddly), .C(clk100), .CE(1'b0), .INC(1'b0), .LD(ld),
          .LDPIPEEN(1'b0), .CNTVALUEIN(tap), .CNTVALUEOUT(), .CINVCTRL(1'b0), .REGRST(1'b0));
    IDELAYCTRL ctl (.REFCLK(clk200), .RST(rst), .RDY());
    ISERDESE2 #(.DATA_RATE("DDR"), .DATA_WIDTH(8), .INTERFACE_TYPE("NETWORKING"), .IOBDELAY("IFD"),
                .NUM_CE(1), .OFB_USED("FALSE"), .SERDES_MODE("MASTER"))
      is (.Q1(q[1]), .Q2(q[2]), .Q3(q[3]), .Q4(q[4]), .Q5(q[5]), .Q6(q[6]), .Q7(q[7]), .Q8(q[8]),
          .O(), .SHIFTOUT1(), .SHIFTOUT2(), .BITSLIP(1'b0), .CE1(1'b1), .CE2(1'b1), .CLKDIVP(1'b0),
          .CLK(clk400), .CLKB(!clk400), .CLKDIV(clk100), .OCLK(1'b0), .OCLKB(1'b0),
          .DYNCLKDIVSEL(1'b0), .DYNCLKSEL(1'b0), .D(1'b0), .DDLY(ddly), .OFB(1'b0), .RST(rst),
          .SHIFTIN1(1'b0), .SHIFTIN2(1'b0));

    // Marker m (0-15) in D[m % 4] of the 200 MHz word that starts at
    // 200 ns + 100 ns m, plus 5 ns for the second half of a 10 ns word;
    // markers 8-15 with 16 taps
    integer m;
    always @(posedge clk200) begin
        d <= 4'b0000;
        t <= 4'b1111;
        for (m = 0; m < 16; m = m + 1)
            if ($time == 195000 + 100000 * m + 5000 * ((m % 8) / 4)) begin
                d <= 4'b0001 << (m % 4);
                t <= ~(4'b0001 << (m % 4));
            end
    end
    always @(posedge clk100) if ($time == 900000) begin tap <= 5'd16; ld <= 1'b1; end
                             else ld <= 1'b0;

    always @(posedge oq)   if ($time > 150000) $display("%0d OQ rises", $time);
    always @(negedge tq)   if ($time > 150000) $display("%0d TQ falls", $time);
    always @(posedge ddly) if ($time > 150000) $display("%0d DDLY rises", $time);
    always @(q)            if ($time > 150000 && q != 8'd0) $display("%0d Q8-Q1 %b", $time, q);
    initial begin
        #100000 rst = 1'b0;
        #1750000 $finish;
    end
endmodule
