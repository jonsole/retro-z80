// SRAM controller for the fast-memory experiment (issue #91, design plan
// branch 24): 8 memory cycles of 12.5 ns in each 100 ns slot, in place of
// sram_ctl.v's 5 of 20 ns. The request, grant and read-data contract is
// sram_ctl's, so the scheduler (dmac8.v) and the units barely change. An
// experiment: it lives here, not in retro-hw.
//
// The SRAM pins go through the SRAM tester's SERDES pads (sram8_pads.v,
// after sramt_pads.v): every pin changes in steps of 1.25 ns. Each clock
// this unit makes the next 8 steps of every pin, a "word". A word made at
// edge E leaves the FPGA from E + 12.5 ns, step i at E + 12.5 + 1.25i (the
// tester's measured latency, sim/sramtest/lat.ref).
//
// A cycle is 10 steps. 8 cycles fill the 80 steps of a slot; cycle k starts
// at step 2 + 10k of the slot, so word m (made at slot edge m, the edge
// after which sc = m) holds the start of one cycle or of none:
//
//   word (slot edge)   0   1   2   3   4   5   6   7   8   9
//   cycle starting     0   1   2   -   3   4   5   6   -   7
//   at step of word    2   4   6   -   0   2   4   6   -   0
//
// A cycle is given out at the edge that makes its word (start_next says
// one comes at the next edge, next_cycle its number), as sram_ctl's are.
//
// The waveform within a cycle (steps from its address leaving the FPGA;
// the defaults are the middle of each window the KS2 tester measured at
// 12.5 ns, docs/notes/sram-ks2.md, which passed all 2 MB):
//   read  : /OE low from OE_LO to the cycle's end; DQ sampled at step 13
//           (3 steps into the next cycle), 8 IDELAY taps earlier (0.62 ns):
//           15.63 ns after the address, in a window of 10.00 to 21.25 ns
//   write : /WE low over [WE_LO, WE_HI); the FPGA drives DQ from D_LO (from
//           WAR_LO in a write that follows a read) to the cycle's end
//   both  : /CS low for the whole cycle; /LB and /UB low for a read, and as
//           the byte enables say for a write
//   idle  : every strobe high, DQ not driven, the address held
//
// Read data. The pads sample DQ every 1.25 ns; the ISERDESE2s give 8
// samples a clock (qs). The sample of step 13 of a cycle made at edge E is
// at edge E + 4 (cycles starting at step 0, 2 or 4 of their word) or E + 5
// (step 6). rvalid, rtag and rdata are combinational from qs in the clock
// after that edge, so a unit takes the data at E + 5 or E + 6:
//
//   cycle            0   1   2   3   4   5   6   7
//   given out at     0   1   2   4   5   6   7   9     (slot edge)
//   rvalid after     4   5   7   8   9   0   2   3     (slot edge)
//   latency          4   4   5   4   4   4   5   4     (clocks)
//
// No two read results meet in one clock. sram_ctl's latency is 3 clocks
// (rdata in the clock after E + 3), so a read here comes back 1 or 2 clocks
// later. The CPU's cycles (3 and 7) have latency 4: spec 1, section 5.3 still
// holds (dmac8.v).
module sram_ctl8 #(
    parameter AW = 21,               // SRAM address pins (21: 4 MB, 20: 2 MB)
    parameter [3:0] OE_LO  = 4'd2,   // read: /OE low from this step
    parameter [3:0] WE_LO  = 4'd3,   // write: /WE low from this step ...
    parameter [3:0] WE_HI  = 4'd7,   // ... to this one
    parameter [3:0] D_LO   = 4'd2,   // write: DQ driven from this step
    parameter [3:0] WAR_LO = 4'd3,   // ... or this one, after a read
    parameter [2:0] CAP_K0 = 3'd3    // read: the sample of step 13 in a cycle at step 0 (see above)
) (
    input  wire        clk,          // 100 MHz
    input  wire        rst,
    input  wire [3:0]  sc,           // timebase: edge index within the slot

    // The cycle the scheduler (dmac8.v) gives out at the next edge
    input  wire        go,
    input  wire        go_we,
    input  wire [21:1] go_addr,
    input  wire [15:0] go_wdata,
    input  wire [1:0]  go_be,        // [1] = upper byte (D15-8), [0] = lower byte
    input  wire [2:0]  go_tag,
    output wire        start_next,   // a new cycle starts at the next edge
    output wire [2:0]  next_cycle,   // ... and this is its number in the slot (0-7)
    output wire        rvalid,       // rdata holds read data for rtag (combinational)
    output wire [2:0]  rtag,
    output wire [15:0] rdata,

    // Pin words for sram8_pads: bit 8p + i is pin p at step i
    output reg  [8*AW-1:0] w_addr,
    output reg  [7:0]  w_cs_n, w_oe_n, w_we_n, w_lb_n, w_ub_n,
    output reg  [127:0] w_dq,
    output reg  [7:0]  w_dq_t,       // 1 = DQ not driven
    input  wire [127:0] qs           // DQ samples: bit 8b + k is DQ b at sample k (k = 0 the earliest)
);
    localparam [1:0] K_IDLE = 2'd0, K_RD = 2'd1, K_WR = 2'd2;

    // ---------------------------------------------------------------- the slot plan
    // The word made at the next edge
    wire [3:0] m = (sc == 4'd9) ? 4'd0 : sc + 4'd1;

    // Whether a cycle starts in word m, its number and its first step
    reg       st_on;
    reg [2:0] st_cyc, st_q;
    always @(*) begin
        st_on = 1'b1; st_cyc = 3'd0; st_q = 3'd0;
        case (m)
            4'd0: begin st_cyc = 3'd0; st_q = 3'd2; end
            4'd1: begin st_cyc = 3'd1; st_q = 3'd4; end
            4'd2: begin st_cyc = 3'd2; st_q = 3'd6; end
            4'd4: begin st_cyc = 3'd3; st_q = 3'd0; end
            4'd5: begin st_cyc = 3'd4; st_q = 3'd2; end
            4'd6: begin st_cyc = 3'd5; st_q = 3'd4; end
            4'd7: begin st_cyc = 3'd6; st_q = 3'd6; end
            4'd9: begin st_cyc = 3'd7; st_q = 3'd0; end
            default: st_on = 1'b0;          // words 3 and 8
        endcase
    end
    assign start_next = st_on;
    assign next_cycle = st_cyc;

    // The step within its cycle of bit i of word m: the slot's step 8m + i,
    // less the 2 steps before cycle 0, mod 10
    function [3:0] step_of(input [3:0] wm, input integer i);
        integer u;
        begin
            u = (8 * wm + i + 78) % 80;
            u = u % 10;
            step_of = u[3:0];
        end
    endfunction

    // ---------------------------------------------------------------- the cycles
    // A: the cycle in progress (it started in an earlier word); B: the one
    // that starts in word m, if any
    reg  [1:0]    a_kind;
    reg  [AW-1:0] a_addr;
    reg  [15:0]   a_data;
    reg  [1:0]    a_be;
    reg           a_war;

    wire [1:0]    b_kind = go ? (go_we ? K_WR : K_RD) : K_IDLE;
    wire [AW-1:0] b_addr = go ? go_addr[AW:1] : a_addr;
    wire          b_war  = go && go_we && a_kind == K_RD;

    always @(posedge clk) begin
        if (rst) begin
            a_kind <= K_IDLE;
            a_addr <= {AW{1'b0}};
            a_data <= 16'd0;
            a_be   <= 2'b00;
            a_war  <= 1'b0;
        end else if (st_on) begin
            a_kind <= b_kind;
            a_addr <= b_addr;
            a_war  <= b_war;
            if (go) begin
                a_data <= go_wdata;
                a_be   <= go_we ? go_be : 2'b11;
            end
        end
    end

    // ---------------------------------------------------------------- the pin words
    genvar i, p;
    generate for (i = 0; i < 8; i = i + 1) begin : st
        wire [3:0]    s    = step_of(m, i);
        wire          inb  = st_on && (s <= i);           // this step is B's
        wire [1:0]    kind = inb ? b_kind : a_kind;
        wire          war  = inb ? b_war  : a_war;
        wire [AW-1:0] addr = inb ? b_addr : a_addr;
        wire [15:0]   data = inb ? go_wdata : a_data;
        wire [1:0]    be   = inb ? (go_we ? go_be : 2'b11) : a_be;
        wire [3:0]    dlo  = war ? WAR_LO : D_LO;

        wire rd = (kind == K_RD);
        wire wr = (kind == K_WR);
        wire oe = rd && (s >= OE_LO);
        wire we = wr && (s >= WE_LO) && (s < WE_HI);
        wire dr = wr && (s >= dlo);
        wire cs = rd || wr;

        always @(posedge clk) begin
            if (rst) begin
                w_cs_n[i] <= 1'b1; w_oe_n[i] <= 1'b1; w_we_n[i] <= 1'b1;
                w_lb_n[i] <= 1'b1; w_ub_n[i] <= 1'b1; w_dq_t[i] <= 1'b1;
            end else begin
                w_cs_n[i] <= !cs;
                w_oe_n[i] <= !oe;
                w_we_n[i] <= !we;
                w_lb_n[i] <= !(rd || (wr && be[0]));
                w_ub_n[i] <= !(rd || (wr && be[1]));
                w_dq_t[i] <= !dr;
            end
        end
        for (p = 0; p < AW; p = p + 1) begin : ap
            always @(posedge clk) w_addr[8*p + i] <= addr[p];
        end
        for (p = 0; p < 16; p = p + 1) begin : dp
            always @(posedge clk) w_dq[8*p + i] <= data[p];
        end
    end endgenerate

    // ---------------------------------------------------------------- read data
    // A read's record, made with its word (at edge E, into pipe 0) and moved
    // along a clock at a time: after edge E + n it is in pipe n. It comes
    // out of pipe 4, or pipe 5 for
    // a cycle at step 6, with the sample number within qs: step 13 of a cycle
    // at step q of its word is sample CAP_K0 + q of word E + 4, mod 8 (a cycle
    // at step 6 wraps into word E + 5)
    localparam RW = 1 + 3 + 1 + 3;          // valid, tag, late (pipe 5), sample
    reg  [RW-1:0] pipe [0:5];
    wire [3:0]    kq   = {1'b0, CAP_K0} + {1'b0, st_q};
    wire          late = kq[3];              // past the end of word E + 4
    wire [RW-1:0] rec  = {st_on && go && !go_we, go_tag, late, kq[2:0]};
    integer n;
    always @(posedge clk) begin
        if (rst) begin
            for (n = 0; n <= 5; n = n + 1) pipe[n] <= {RW{1'b0}};
        end else begin
            pipe[0] <= rec;
            for (n = 1; n <= 5; n = n + 1) pipe[n] <= pipe[n-1];
        end
    end
    wire          p4_out = pipe[4][RW-1] && !pipe[4][3];
    wire          p5_out = pipe[5][RW-1] &&  pipe[5][3];
    wire [RW-1:0] out    = p5_out ? pipe[5] : pipe[4];
    wire [2:0]    k      = out[2:0];
    assign rvalid = p4_out || p5_out;
    assign rtag   = out[RW-2 -: 3];
    generate for (p = 0; p < 16; p = p + 1) begin : rd
        assign rdata[p] = qs[8*p + k];
    end endgenerate
endmodule
