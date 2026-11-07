// SRAM tester (issue #90): settings, test patterns, cycle stepping and the
// checks. Runs on the 100 MHz clock; sramt_wave.v turns the cycle state into
// pin steps and sramt_pads.v sends them out and samples DQ.
//
// Settings (16 bits each, written with set_we; defaults reproduce sram_ctl's
// 20 ns cycle, spec 2 section 8.2). Steps are 1.25 ns; a cycle's step 0 is
// where its address leaves.
//   0  NSTEP    16  steps per cycle, 8-32
//   1  OE_LO     4  read: /OE low from this step ...
//   2  OE_HI    16  ... to this one
//   3  CAP      16  read: the DQ sample checked, 0-39 (16 is the step where
//                   the next address leaves, as sram_ctl's capture)
//   4  TAPS      0  IDELAY taps, 0-31 (78 ps each; more taps sample earlier)
//   5  WE_LO     4  write: /WE low from this step ...
//   6  WE_HI    12  ... to this one
//   7  D_LO      4  write: the FPGA drives DQ from this step ...
//   8  D_HI     16  ... to this one
//   9  WAR_LO    4  the drive start in a write that follows a read
//  10  WCHK     12  write: the DQ sample compared with the data driven
//                   ("bus" errors: the bus did not hold the FPGA's data)
//  11  SEQ       0  0 write the region then read it, 1 write only, 2 read
//                   only, 3 each word written then read at once (every read
//                   follows a write and every write a read)
//  12  DATA      0  0 random (xorshift32), 1 0x0000 and 0xFFFF in turn,
//                   2 walking ones (a one in bit i mod 16, inverted for i 16-31)
//  13  ADDR      0  0 the region base .. base + count - 1, 1 walking ones:
//                   base, then base with one address bit flipped, for each of
//                   the 20 bits (21 words; COUNT ignored)
//  14  BASE_LO   0  first word address, bits 15-0
//  15  BASE_HI   0  ... bits 19-16
//  16  COUNT_LO  0  words in the region, bits 15-0
//  17  COUNT_HI 16  ... bits 20-16 (default 0x100000, all 2 MB)
//  18  SEED_LO   1  random data seed (each pass of a run adds 0x9E3779B9)
//  19  SEED_HI   0
//  20  REPEAT    1  passes per run (0 counts as 1)
//  21  SCOPE_LO  0  the cycle of the run (counted from 0) whose samples are kept
//  22  SCOPE_HI  0
//
// Results, read a byte at a time (little-endian):
//   0x000  "SRT1"
//   0x004  errors: words read wrong
//   0x008  bus errors: writes whose DQ sample differed from the data driven
//   0x00C  words read
//   0x010  first wrong read: word address, bit 31 set if there was one
//   0x014  ... the data read (2 bytes), then the data expected (2 bytes)
//   0x018  words written
//   0x01C  the scope's cycle: kind (1 read, 2 write; 0 none), its start j
//          (sample j is its step 0), its address (2 bytes, bits 15-0)
//   0x020  errors per DQ bit, 16 x 4 bytes
//   0x060  the scope: 48 samples of the 16 DQ pins, 2 bytes each
//   0x100  the settings, 32 x 2 bytes
module sramt_engine (
    input  wire         clk,
    input  wire         rst,

    input  wire         set_we,
    input  wire [4:0]   set_idx,
    input  wire [15:0]  set_val,
    input  wire         run,
    output reg          busy,
    input  wire [8:0]   rd_addr,
    output reg  [7:0]   rd_data,

    // The cycle state for sramt_wave
    output reg  [5:0]   ph,
    output reg  [5:0]   j,
    output reg  [1:0]   a_kind,
    output reg          a_war,
    output reg  [19:0]  a_addr,
    output reg  [15:0]  a_data,
    output wire [1:0]   b_kind,
    output wire         b_war,
    output reg  [19:0]  b_addr,
    output reg  [15:0]  b_data,
    output wire [5:0]   oe_lo, oe_hi, we_lo, we_hi, d_lo, d_hi, war_lo,

    // From sramt_pads
    input  wire [127:0] smp,
    output wire [4:0]   taps,
    output reg          taps_ld
);
    localparam [1:0] K_IDLE = 2'd0, K_RD = 2'd1, K_WR = 2'd2;
    // Where the samples of a word are (sramt_pads.v): the word sent at edge t
    // has its samples 0-47 in the history at edge t + CAP_LAT, from bit CAP_SKEW
    localparam CAP_LAT  = 9;
    localparam CAP_SKEW = 6;

    // ---------------------------------------------------------------- settings
    reg [15:0] st [0:31];
    integer k;
    always @(posedge clk) begin
        taps_ld <= 1'b0;
        if (rst) begin
            for (k = 0; k < 32; k = k + 1) st[k] <= 16'd0;
            st[0]  <= 16'd16;  st[1] <= 16'd4;  st[2] <= 16'd16; st[3] <= 16'd16;
            st[5]  <= 16'd4;   st[6] <= 16'd12; st[7] <= 16'd4;  st[8] <= 16'd16;
            st[9]  <= 16'd4;   st[10] <= 16'd12;
            st[17] <= 16'd16;  st[18] <= 16'd1; st[20] <= 16'd1;
            taps_ld <= 1'b1;
        end else if (set_we && !busy) begin
            st[set_idx] <= set_val;
            if (set_idx == 5'd4) taps_ld <= 1'b1;
        end
    end
    wire [5:0]  nstep = st[0][5:0];
    assign oe_lo  = st[1][5:0];
    assign oe_hi  = st[2][5:0];
    wire [5:0]  cap   = st[3][5:0];
    assign taps   = st[4][4:0];
    assign we_lo  = st[5][5:0];
    assign we_hi  = st[6][5:0];
    assign d_lo   = st[7][5:0];
    assign d_hi   = st[8][5:0];
    assign war_lo = st[9][5:0];
    wire [5:0]  wchk  = st[10][5:0];
    wire [1:0]  seq   = st[11][1:0];
    wire [1:0]  dmode = st[12][1:0];
    wire        awalk = st[13][0];
    wire [19:0] base  = {st[15][3:0], st[14]};
    wire [20:0] count = awalk ? 21'd21 : {st[17][4:0], st[16]};
    wire [31:0] seed  = {st[19], st[18]};
    wire [15:0] reps  = (st[20] == 16'd0) ? 16'd1 : st[20];
    wire [31:0] scope_n = {st[22], st[21]};

    // ---------------------------------------------------------------- the pattern
    // One cycle a clock at most (a cycle is 8 steps or more). The next cycle
    // waits in B until the stepper takes it.
    reg         g_on;           // cycles still to come in this run
    reg  [15:0] g_rep;          // pass
    reg         g_rd;           // the read half of a write-then-read pass
    reg         g_sub;          // SEQ 3: 0 the write, 1 the read
    reg  [20:0] g_i;            // word within the region
    reg  [31:0] g_x, g_x0;      // random data now, and at the start of the pass
    reg         b_valid;
    reg  [1:0]  b_k;
    reg         consume;        // (wire) the stepper takes B this clock

    function [31:0] xs;         // xorshift32
        input [31:0] v;
        reg   [31:0] a;
        begin
            a  = v ^ (v << 13);
            a  = a ^ (a >> 17);
            xs = a ^ (a << 5);
        end
    endfunction
    function [31:0] nz;         // xorshift32 never leaves 0
        input [31:0] v;
        nz = (v == 32'd0) ? 32'h1 : v;
    endfunction

    wire [19:0] g_walk = (g_i == 21'd0) ? 20'd0 : (20'd1 << (g_i[4:0] - 5'd1));
    wire [19:0] g_addr = awalk ? (base ^ g_walk) : (base + g_i[19:0]);
    wire [15:0] g_data = (dmode == 2'd1) ? {16{g_i[0]}} :
                         (dmode == 2'd2) ? ((16'd1 << g_i[3:0]) ^ {16{g_i[4]}}) :
                         (g_x[15:0] ^ g_x[31:16]);
    wire [1:0]  g_kind = (seq == 2'd3) ? (g_sub ? K_RD : K_WR) :
                         ((seq == 2'd2) || ((seq == 2'd0) && g_rd)) ? K_RD : K_WR;
    wire        g_last = (g_i == count - 21'd1) || (count == 21'd0);

    wire        start = run && !busy;
    wire [31:0] next_x0 = g_x0 + 32'h9E3779B9;

    always @(posedge clk) begin
        if (rst) begin
            g_on <= 1'b0; b_valid <= 1'b0; b_k <= K_IDLE;
            g_rep <= 16'd0; g_rd <= 1'b0; g_sub <= 1'b0; g_i <= 21'd0;
            g_x <= 32'h1; g_x0 <= 32'h1; b_addr <= 20'd0; b_data <= 16'd0;
        end else if (start) begin
            g_on  <= 1'b1;
            g_rep <= 16'd0;
            g_rd  <= 1'b0;
            g_sub <= 1'b0;
            g_i   <= 21'd0;
            g_x   <= nz(seed);
            g_x0  <= seed;
        end else if (!b_valid || consume) begin
            b_valid <= g_on;
            if (g_on) begin
                b_k    <= g_kind;
                b_addr <= g_addr;
                b_data <= g_data;
                if (seq == 2'd3 && !g_sub)
                    g_sub <= 1'b1;
                else begin
                    g_sub <= 1'b0;
                    g_i   <= g_i + 21'd1;
                    g_x   <= xs(g_x);
                    if (g_last) begin
                        g_i <= 21'd0;
                        if (seq == 2'd0 && !g_rd) begin
                            g_rd <= 1'b1;               // now read the region back
                            g_x  <= nz(g_x0);
                        end else if (g_rep + 16'd1 == reps)
                            g_on <= 1'b0;               // the run is done
                        else begin
                            g_rep <= g_rep + 16'd1;     // the next pass
                            g_rd  <= 1'b0;
                            g_x0  <= next_x0;
                            g_x   <= nz(next_x0);
                        end
                    end
                end
            end
        end
    end
    assign b_kind = b_valid ? b_k : K_IDLE;
    assign b_war  = (b_kind == K_WR) && (a_kind == K_RD);

    // ---------------------------------------------------------------- the stepper
    // ph is the step of cycle A at bit 0 of the word being made, j the bit
    // where the next cycle starts (j = nstep - ph). When j <= 8 the next
    // cycle starts in this word (or, for j = 8, at bit 0 of the next one) and
    // B becomes A; an idle cycle stands in if there is no B.
    always @(*) consume = (j <= 6'd8);

    always @(posedge clk) begin
        if (rst || start) begin
            ph <= 6'd0;
            j  <= rst ? 6'd16 : nstep;
            a_kind <= K_IDLE;
            a_war  <= 1'b0;
            if (rst) begin a_addr <= 20'd0; a_data <= 16'd0; end
        end else if (consume) begin
            ph <= 6'd8 - j;
            j  <= nstep - 6'd8 + j;
            a_kind <= b_kind;
            a_war  <= b_war;
            if (b_valid) begin
                a_addr <= b_addr;
                a_data <= b_data;
            end
        end else begin
            ph <= ph + 6'd8;
            j  <= j - 6'd8;
        end
    end

    // ---------------------------------------------------------------- what to check
    // A record for each cycle that starts, made with its word and kept for
    // CAP_LAT clocks, until that word's samples are in the history.
    localparam DW = 2 + 6 + 20 + 16 + 1;     // kind, sample offset, address, data, scope
    reg  [31:0]   cyc;                        // cycles started in this run
    reg  [DW-1:0] dl [0:CAP_LAT];
    wire          d_new = consume && b_valid;
    wire [5:0]    d_off = j + ((b_k == K_RD) ? cap : wchk);
    always @(posedge clk) begin
        if (rst || start) cyc <= 32'd0;
        else if (d_new) cyc <= cyc + 32'd1;
        dl[0] <= d_new ? {b_k, d_off, b_addr, b_data, (cyc == scope_n)} : {DW{1'b0}};
        for (k = 1; k <= CAP_LAT; k = k + 1) dl[k] <= dl[k-1];
    end
    wire [1:0]  c_kind  = dl[CAP_LAT][DW-1 -: 2];
    wire [5:0]  c_off   = dl[CAP_LAT][DW-3 -: 6];
    wire [19:0] c_addr  = dl[CAP_LAT][36:17];
    wire [15:0] c_data  = dl[CAP_LAT][16:1];
    wire        c_scope = dl[CAP_LAT][0];

    // The sample history: the last 7 words of samples, oldest first
    reg  [127:0] hs [1:6];
    always @(posedge clk) begin
        hs[1] <= smp;
        for (k = 2; k <= 6; k = k + 1) hs[k] <= hs[k-1];
    end
    wire [47:0] win [0:15];     // per DQ bit: the 48 samples of the record's word
    wire [15:0] pick;
    genvar b;
    generate for (b = 0; b < 16; b = b + 1) begin : hb
        wire [55:0] hist = {smp[8*b +: 8], hs[1][8*b +: 8], hs[2][8*b +: 8], hs[3][8*b +: 8],
                            hs[4][8*b +: 8], hs[5][8*b +: 8], hs[6][8*b +: 8]};
        assign win[b]  = hist[CAP_SKEW +: 48];
        assign pick[b] = win[b][c_off];
    end endgenerate

    // ---------------------------------------------------------------- counting
    reg  [1:0]  e_kind;
    reg  [19:0] e_addr;
    reg  [15:0] e_got, e_exp;
    reg  [31:0] n_err, n_bus, n_rd, n_wr, f_addr;
    reg  [15:0] f_got, f_exp;
    reg  [31:0] n_bit [0:15];
    reg  [767:0] scope;
    reg  [1:0]  sc_kind;
    reg  [5:0]  sc_j;
    reg  [15:0] sc_addr;
    reg  [4:0]  drain;
    wire [15:0] e_diff = e_got ^ e_exp;

    always @(posedge clk) begin
        e_kind <= c_kind;
        e_addr <= c_addr;
        e_got  <= pick;
        e_exp  <= c_data;

        if (rst || start) begin
            n_err <= 32'd0; n_bus <= 32'd0; n_rd <= 32'd0; n_wr <= 32'd0;
            f_addr <= 32'd0; f_got <= 16'd0; f_exp <= 16'd0;
            for (k = 0; k < 16; k = k + 1) n_bit[k] <= 32'd0;
            sc_kind <= K_IDLE; sc_j <= 6'd0; sc_addr <= 16'd0;
        end else begin
            if (e_kind == K_RD) begin
                n_rd <= n_rd + 32'd1;
                if (e_diff != 16'd0) begin
                    n_err <= n_err + 32'd1;
                    if (!f_addr[31]) begin
                        f_addr <= {12'h800, e_addr};
                        f_got  <= e_got;
                        f_exp  <= e_exp;
                    end
                end
                for (k = 0; k < 16; k = k + 1)
                    if (e_diff[k]) n_bit[k] <= n_bit[k] + 32'd1;
            end
            if (e_kind == K_WR) begin
                n_wr <= n_wr + 32'd1;
                if (e_diff != 16'd0) n_bus <= n_bus + 32'd1;
            end
            if (c_scope && c_kind != K_IDLE) begin
                sc_kind <= c_kind;
                sc_j    <= c_off - ((c_kind == K_RD) ? cap : wchk);
                sc_addr <= c_addr[15:0];
                for (k = 0; k < 48; k = k + 1)
                    scope[16*k +: 16] <= {win[15][k], win[14][k], win[13][k], win[12][k],
                                          win[11][k], win[10][k], win[9][k],  win[8][k],
                                          win[7][k],  win[6][k],  win[5][k],  win[4][k],
                                          win[3][k],  win[2][k],  win[1][k],  win[0][k]};
            end
        end
    end

    // Busy from the run command until the last record is counted
    always @(posedge clk) begin
        if (rst) begin
            busy  <= 1'b0;
            drain <= 5'd0;
        end else if (start) begin
            busy  <= 1'b1;
            drain <= 5'd0;
        end else if (busy) begin
            if (g_on || b_valid || a_kind != K_IDLE)
                drain <= 5'd0;
            else if (drain == 5'd20)
                busy <= 1'b0;
            else
                drain <= drain + 5'd1;
        end
    end

    // ---------------------------------------------------------------- results
    function [7:0] by;          // byte n of a 32-bit word
        input [31:0] w;
        input [1:0]  n;
        by = w[8*n +: 8];
    endfunction
    wire [1:0] bn  = rd_addr[1:0];
    wire [4:0] nb5 = rd_addr[6:2] - 5'd8;      // 0x020-0x05F: DQ bit
    always @(posedge clk) begin
        if (rd_addr[8]) begin
            rd_data <= rd_addr[0] ? st[rd_addr[5:1]][15:8] : st[rd_addr[5:1]][7:0];
        end else if (rd_addr >= 9'h060 && rd_addr < 9'h0C0) begin
            rd_data <= scope[8*(rd_addr - 9'h060) +: 8];
        end else if (rd_addr >= 9'h020 && rd_addr < 9'h060) begin
            rd_data <= by(n_bit[nb5[3:0]], bn);
        end else begin
            case (rd_addr[7:2])
                6'h00:   rd_data <= by(32'h31545253, bn);       // "SRT1"
                6'h01:   rd_data <= by(n_err, bn);
                6'h02:   rd_data <= by(n_bus, bn);
                6'h03:   rd_data <= by(n_rd, bn);
                6'h04:   rd_data <= by(f_addr, bn);
                6'h05:   rd_data <= by({f_exp, f_got}, bn);
                6'h06:   rd_data <= by(n_wr, bn);
                6'h07:   rd_data <= by({sc_addr, 2'b00, sc_j, 6'd0, sc_kind}, bn);
                default: rd_data <= 8'h00;
            endcase
        end
    end
endmodule
