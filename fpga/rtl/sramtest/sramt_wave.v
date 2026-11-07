// SRAM tester (issue #90): the pin waveforms of one 10 ns word.
//
// Each clock (100 MHz) this unit makes the next 8 steps of 1.25 ns for every
// SRAM pin, from the cycle in progress (A), the cycle that starts next (B)
// and the timing settings. The pad layer (sramt_pads.v) sends the steps out
// in order, step 0 first.
//
// A word holds the end of cycle A and, if j <= 7, the start of cycle B from
// bit j on. Within a cycle, step 0 is where the address and byte selects
// change. Each strobe is low over a window of steps [lo, hi):
//   read  : /OE low over [oe_lo, oe_hi)
//   write : /WE low over [we_lo, we_hi); the FPGA drives DQ over
//           [d_lo, d_hi), or [war_lo, d_hi) in a write that follows a read
//   both  : /CS, /LB and /UB low for the whole cycle
//   idle  : every strobe high, DQ not driven, the address held
// Settings are 0-32; a cycle is 8-32 steps.
module sramt_wave (
    input  wire         clk,

    input  wire [5:0]   ph,         // step within cycle A at bit 0
    input  wire [5:0]   j,          // bit where cycle B starts (B is in this word only if j <= 7)
    input  wire [1:0]   a_kind,     // 0 idle, 1 read, 2 write
    input  wire         a_war,      // A is a write that follows a read
    input  wire [19:0]  a_addr,
    input  wire [15:0]  a_data,
    input  wire [1:0]   b_kind,
    input  wire         b_war,
    input  wire [19:0]  b_addr,
    input  wire [15:0]  b_data,

    input  wire [5:0]   oe_lo, oe_hi,
    input  wire [5:0]   we_lo, we_hi,
    input  wire [5:0]   d_lo, d_hi, war_lo,

    // Bit 8p + i is pin p at step i
    output reg  [159:0] addr_w,
    output reg  [7:0]   cs_n_w, oe_n_w, we_n_w, be_n_w,
    output reg  [127:0] dq_w,
    output reg  [7:0]   dq_t_w      // 1 = DQ not driven (all 16 pins alike)
);
    localparam [1:0] K_RD = 2'd1, K_WR = 2'd2;

    genvar i, p;
    generate for (i = 0; i < 8; i = i + 1) begin : st
        localparam [5:0] I = i;
        wire        inb  = (I >= j);
        wire [5:0]  s    = inb ? I - j : ph + I;
        wire [1:0]  kind = inb ? b_kind : a_kind;
        wire        war  = inb ? b_war  : a_war;
        wire [19:0] addr = inb ? b_addr : a_addr;
        wire [15:0] data = inb ? b_data : a_data;
        wire [5:0]  dlo  = war ? war_lo : d_lo;

        wire oe = (kind == K_RD) && (s >= oe_lo) && (s < oe_hi);
        wire we = (kind == K_WR) && (s >= we_lo) && (s < we_hi);
        wire dr = (kind == K_WR) && (s >= dlo)   && (s < d_hi);
        wire cs = (kind == K_RD) || (kind == K_WR);

        always @(posedge clk) begin
            cs_n_w[i] <= !cs;
            be_n_w[i] <= !cs;
            oe_n_w[i] <= !oe;
            we_n_w[i] <= !we;
            dq_t_w[i] <= !dr;
        end
        for (p = 0; p < 20; p = p + 1) begin : ap
            always @(posedge clk) addr_w[8*p + i] <= addr[p];
        end
        for (p = 0; p < 16; p = p + 1) begin : dp
            always @(posedge clk) dq_w[8*p + i] <= data[p];
        end
    end endgenerate
endmodule
