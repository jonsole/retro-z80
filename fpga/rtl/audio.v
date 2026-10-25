// The audio output (spec 7, section 10.2; ticket #21). 100 MHz.
//
// Until sound (spec 13) is decided, the only source is the Spectrum-style
// beeper: bit 4 of the last write to port 0xFE (register 0x00FE of page
// 0x00, whatever the high byte holds; spec 12, section 8.4), 0 after reset.
// 0 gives -BEEPAMP and 1 +BEEPAMP, a fixed quarter of full scale, the same
// on both channels. Three second-order sigma-delta modulators (retro68k's
// sigma_delta2) turn left, right and mono ((left + right) / 2) into bit
// streams for the board's RC filters: the jack (audioext_l_o, audioext_r_o)
// and the internal speaker (audioint_o). Spec 13's left and right mixes are
// to be added to the beeper here, with clipping.
//
// Port 0xFE's other bits belong to other units: the border to video.v,
// reads to keys.v; bit 3 (MIC) is ignored. This unit answers no reads.
`include "regmap.vh"

module audio (
    input  wire        clk,
    input  wire        rst,

    input  wire        rb_wr,
    input  wire [12:0] rb_addr,
    input  wire [7:0]  rb_wdata,

    output wire        dac_l,          // sigma-delta streams
    output wire        dac_r,
    output wire        dac_m
);
    localparam signed [15:0] BEEPAMP = 16'sh2000;      // a quarter of full scale

    reg beep;
    always @(posedge clk)
        if (rst)                                beep <= 1'b0;
        else if (rb_wr && rb_addr == `RM_ULA)   beep <= rb_wdata[`RM_ULA_BEEPER];

    wire signed [15:0] out_l = beep ? BEEPAMP : -BEEPAMP;
    wire signed [15:0] out_r = out_l;

    sigma_delta2 sd_l (.clk(clk), .rst(rst), .x(out_l), .y(dac_l));
    sigma_delta2 sd_r (.clk(clk), .rst(rst), .x(out_r), .y(dac_r));
    wire signed [16:0] mono = out_l + out_r;
    sigma_delta2 sd_m (.clk(clk), .rst(rst), .x(mono[16:1]), .y(dac_m));
endmodule

// Second-order sigma-delta modulator: x (16 bits signed) at half of full
// scale, so it stays stable for every input. The average of y is
// 1/2 + x / 2^17. As retro68k's.
module sigma_delta2 (
    input  wire               clk,
    input  wire               rst,
    input  wire signed [15:0] x,
    output reg                y
);
    reg signed [23:0] i1, i2;
    wire signed [23:0] fb = y ? 24'sd65536 : -24'sd65536;
    wire signed [23:0] n1 = i1 + x - fb;
    wire signed [23:0] n2 = i2 + n1 - fb;
    always @(posedge clk) begin
        if (rst) begin
            i1 <= 24'sd0;
            i2 <= 24'sd0;
            y  <= 1'b0;
        end else begin
            i1 <= n1;
            i2 <= n2;
            y  <= !n2[23];
        end
    end
endmodule
