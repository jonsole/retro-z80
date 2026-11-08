// Stand-ins for the Xilinx primitives of the SRAM tester's KS2 build
// (top_ks2_sramtest.v), for linting only (fpga/lint.sh), in the style of
// retro-hw's platform/artix7/lint_stub.v: the same ports and parameters as
// used, no logic. Never simulated or synthesised (sim/sramtest/ has
// behavioural models).
module BUFG (input wire I, output wire O);
    assign O = I;
endmodule

module OBUFDS #(parameter IOSTANDARD = "DEFAULT") (input wire I, output wire O, output wire OB);
    assign O  = I;
    assign OB = !I;
endmodule

module IOBUF (inout wire IO, input wire I, input wire T, output wire O);
    assign IO = T ? 1'bz : I;
    assign O  = IO;
endmodule

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
    output wire CLKOUT0, CLKOUT0B, CLKOUT1, CLKOUT1B, CLKOUT2, CLKOUT2B,
    output wire CLKOUT3, CLKOUT3B, CLKOUT4, CLKOUT5, CLKOUT6,
    output wire LOCKED
);
    assign {CLKFBOUT, CLKFBOUTB, CLKOUT0, CLKOUT0B, CLKOUT1, CLKOUT1B, CLKOUT2, CLKOUT2B,
            CLKOUT3, CLKOUT3B, CLKOUT4, CLKOUT5, CLKOUT6} = {13{CLKIN1}};
    assign LOCKED = CLKFBIN | PWRDWN | RST | 1'b1;
endmodule

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
    output wire OQ, OFB, TQ, TFB, TBYTEOUT, SHIFTOUT1, SHIFTOUT2
);
    assign OQ = D1 ^ D2 ^ D3 ^ D4;
    assign TQ = T1 ^ T2 ^ T3 ^ T4;
    assign {OFB, TFB, TBYTEOUT, SHIFTOUT1, SHIFTOUT2} = 5'd0;
endmodule

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
    output wire Q1, Q2, Q3, Q4, Q5, Q6, Q7, Q8, O, SHIFTOUT1, SHIFTOUT2
);
    assign {Q1, Q2, Q3, Q4, Q5, Q6, Q7, Q8} = {8{DDLY}};
    assign {O, SHIFTOUT1, SHIFTOUT2} = 3'd0;
endmodule

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
    output wire DATAOUT,
    output wire [4:0] CNTVALUEOUT
);
    assign DATAOUT     = IDATAIN;
    assign CNTVALUEOUT = CNTVALUEIN;
endmodule

module IDELAYCTRL (input wire REFCLK, RST, output wire RDY);
    assign RDY = !RST;
endmodule
