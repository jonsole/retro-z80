// Behavioural stand-ins for the Xilinx primitives of the SRAM tester
// (top_ks2_sramtest.v), for Icarus, which cannot run Vivado's unisims.
// Only the modes the tester uses, at its clocks (400, 200 and 100 MHz
// rising together). Latencies copy Vivado's unisim models, measured with
// tb_lat.v (sim/README.md):
//   OSERDESE2 4:1 DDR  D1 on OQ 2.5 ns (+0.1) after the CLKDIV edge that
//                      takes it, then D2-D4 every 1.25 ns; TQ the same
//   ISERDESE2 8:1 DDR  at a CLKDIV edge E, Q8..Q1 are the samples taken at
//                      E - 15 ns .. E - 6.25 ns (Q8 the earliest)
//   IDELAYE2           0.6 ns plus 78 ps a tap
// The pads add delays the unisims leave out: IOBUF here drives its pin
// `SRT_TOUT after its inputs and passes the pin in `SRT_TIN later; the
// testbench delays the output-only pins by the same `SRT_TOUT.
`timescale 1ps/1ps
`ifndef SRT_TOUT
`define SRT_TOUT 2500
`endif
`ifndef SRT_TIN
`define SRT_TIN 1000
`endif

module BUFG (input wire I, output wire O);
    assign O = I;
endmodule

module OBUFDS #(parameter IOSTANDARD = "DEFAULT") (input wire I, output wire O, output wire OB);
    assign O  = I;
    assign OB = !I;
endmodule

// A pad: an undefined level on the pin is read as a random bit, as a real
// input flip-flop would settle one way or the other
module IOBUF (inout wire IO, input wire I, input wire T, output wire O);
    reg i_d = 1'b0, t_d = 1'b1, o_d = 1'b1;
    always @(I) i_d <= #(`SRT_TOUT) I;
    always @(T) t_d <= #(`SRT_TOUT) T;
    assign IO = t_d ? 1'bz : i_d;
    always @(IO) o_d <= #(`SRT_TIN) ((IO === 1'b0 || IO === 1'b1) ? IO : $random);
    assign O = o_d;
endmodule

// Clocks from the parameters, all rising together, LOCKED after 2 us
module MMCME2_BASE #(
    parameter real    CLKIN1_PERIOD    = 0.0,
    parameter integer DIVCLK_DIVIDE    = 1,
    parameter real    CLKFBOUT_MULT_F  = 5.0,
    parameter real    CLKOUT0_DIVIDE_F = 1.0,
    parameter integer CLKOUT1_DIVIDE   = 1,
    parameter integer CLKOUT2_DIVIDE   = 1
) (
    input  wire CLKIN1, CLKFBIN, PWRDWN, RST,
    output wire CLKFBOUT, CLKFBOUTB,
    output reg  CLKOUT0, CLKOUT1, CLKOUT2,
    output wire CLKOUT0B, CLKOUT1B, CLKOUT2B,
    output wire CLKOUT3, CLKOUT3B, CLKOUT4, CLKOUT5, CLKOUT6,
    output reg  LOCKED
);
    // VCO period in ps
    localparam real VCO = CLKIN1_PERIOD * 1000.0 * DIVCLK_DIVIDE / CLKFBOUT_MULT_F;
    assign {CLKFBOUT, CLKFBOUTB, CLKOUT3, CLKOUT3B, CLKOUT4, CLKOUT5, CLKOUT6} = 7'd0;
    assign CLKOUT0B = !CLKOUT0;
    assign CLKOUT1B = !CLKOUT1;
    assign CLKOUT2B = !CLKOUT2;
    initial begin : mm
        CLKOUT0 = 1'b0; CLKOUT1 = 1'b0; CLKOUT2 = 1'b0; LOCKED = 1'b0;
        if (VCO <= 0.0) disable mm;        // not set up (or not used)
        #1000000;
        fork
            forever begin CLKOUT0 = 1'b1; #(VCO * CLKOUT0_DIVIDE_F / 2.0); CLKOUT0 = 1'b0; #(VCO * CLKOUT0_DIVIDE_F / 2.0); end
            forever begin CLKOUT1 = 1'b1; #(VCO * CLKOUT1_DIVIDE / 2.0);   CLKOUT1 = 1'b0; #(VCO * CLKOUT1_DIVIDE / 2.0); end
            forever begin CLKOUT2 = 1'b1; #(VCO * CLKOUT2_DIVIDE / 2.0);   CLKOUT2 = 1'b0; #(VCO * CLKOUT2_DIVIDE / 2.0); end
            begin #1000000; LOCKED = 1'b1; end
        join
    end
endmodule

// 4:1 DDR only (CLK 400 MHz, CLKDIV 200 MHz); TQ DDR (width 4) or BUF
module OSERDESE2 #(
    parameter DATA_RATE_OQ   = "DDR",
    parameter DATA_RATE_TQ   = "DDR",
    parameter integer DATA_WIDTH     = 4,
    parameter SERDES_MODE    = "MASTER",
    parameter integer TRISTATE_WIDTH = 4,
    parameter [0:0] INIT_OQ  = 1'b0,
    parameter [0:0] INIT_TQ  = 1'b0,
    parameter [0:0] SRVAL_OQ = 1'b0,
    parameter [0:0] SRVAL_TQ = 1'b0
) (
    input  wire CLK, CLKDIV, D1, D2, D3, D4, D5, D6, D7, D8,
    input  wire SHIFTIN1, SHIFTIN2, OCE, RST, T1, T2, T3, T4, TCE, TBYTEIN,
    output reg  OQ, TQ,
    output wire OFB, TFB, TBYTEOUT, SHIFTOUT1, SHIFTOUT2
);
    assign {OFB, TFB, TBYTEOUT, SHIFTOUT1, SHIFTOUT2} = 5'd0;
    initial begin
        OQ = INIT_OQ; TQ = INIT_TQ;
        if (DATA_RATE_OQ != "DDR" || DATA_WIDTH != 4)
            $display("OSERDESE2 model: only 4:1 DDR is modelled (%m)");
    end
    reg [3:0] d, t;
    always @(posedge CLKDIV) begin
        d = RST ? {4{SRVAL_OQ}} : {D4, D3, D2, D1};
        t = RST ? {4{SRVAL_TQ}} : (DATA_RATE_TQ == "DDR") ? {T4, T3, T2, T1} : {4{T1}};
        OQ <= #2600 d[0];  OQ <= #3850 d[1];  OQ <= #5100 d[2];  OQ <= #6350 d[3];
        TQ <= #2600 t[0];  TQ <= #3850 t[1];  TQ <= #5100 t[2];  TQ <= #6350 t[3];
    end
    // The model assumes a 400 MHz CLK
    real tc = 0.0;
    always @(posedge CLK) begin
        if (tc > 0.0 && ($realtime - tc) != 2500.0)
            $display("OSERDESE2 model: CLK period %0.1f ps, not 2500 (%m)", $realtime - tc);
        tc = $realtime;
    end
endmodule

// 8:1 DDR, NETWORKING, from DDLY
module ISERDESE2 #(
    parameter DATA_RATE      = "DDR",
    parameter integer DATA_WIDTH = 4,
    parameter INTERFACE_TYPE = "MEMORY",
    parameter IOBDELAY       = "NONE",
    parameter integer NUM_CE = 2,
    parameter OFB_USED       = "FALSE",
    parameter SERDES_MODE    = "MASTER"
) (
    input  wire BITSLIP, CE1, CE2, CLKDIVP, CLK, CLKB, CLKDIV, OCLK, OCLKB,
    input  wire DYNCLKDIVSEL, DYNCLKSEL, D, DDLY, OFB, RST, SHIFTIN1, SHIFTIN2,
    output reg  Q1, Q2, Q3, Q4, Q5, Q6, Q7, Q8,
    output wire O, SHIFTOUT1, SHIFTOUT2
);
    assign {O, SHIFTOUT1, SHIFTOUT2} = 3'd0;
    initial begin
        {Q1, Q2, Q3, Q4, Q5, Q6, Q7, Q8} = 8'd0;
        if (DATA_WIDTH != 8 || IOBDELAY != "IFD")
            $display("ISERDESE2 model: only 8:1 DDR from DDLY is modelled (%m)");
    end
    // sr[0] is the newest sample; at a CLKDIV edge the edge's own sample is
    // not in yet, so sr[k] was taken 1.25 (k + 1) ns before
    reg [11:0] sr = 12'd0;
    always @(posedge CLK or negedge CLK) sr <= {sr[10:0], DDLY};
    always @(posedge CLKDIV)
        if (RST) {Q8, Q7, Q6, Q5, Q4, Q3, Q2, Q1} <= #100 8'd0;
        else     {Q8, Q7, Q6, Q5, Q4, Q3, Q2, Q1} <= #100 sr[11:4];
endmodule

// VAR_LOAD only
module IDELAYE2 #(
    parameter IDELAY_TYPE           = "FIXED",
    parameter DELAY_SRC             = "IDATAIN",
    parameter integer IDELAY_VALUE  = 0,
    parameter HIGH_PERFORMANCE_MODE = "FALSE",
    parameter real REFCLK_FREQUENCY = 200.0,
    parameter SIGNAL_PATTERN        = "DATA",
    parameter CINVCTRL_SEL          = "FALSE",
    parameter PIPE_SEL              = "FALSE"
) (
    input  wire IDATAIN, DATAIN, C, CE, INC, LD, LDPIPEEN, CINVCTRL, REGRST,
    input  wire [4:0] CNTVALUEIN,
    output reg  DATAOUT,
    output wire [4:0] CNTVALUEOUT
);
    reg [4:0] tap = IDELAY_VALUE;
    assign CNTVALUEOUT = tap;
    always @(posedge C) if (LD) tap <= CNTVALUEIN;
    initial DATAOUT = 1'b1;
    always @(IDATAIN) DATAOUT <= #(600.0 + 78.0 * tap) IDATAIN;
endmodule

module IDELAYCTRL (input wire REFCLK, RST, output wire RDY);
    assign RDY = !RST;
endmodule
