// The membrane keyboard and the Spectrum keyboard rows (spec 12, sections
// 5 and 8). 100 MHz.
//
// The scanner drives one of the membrane's 8 row lines low at a time (the
// board pads make them open drain: low or let go, pulled up) and reads the
// 7 column lines (pulled up; low = pressed) at the end of the row's 64 us,
// so a full scan takes 0.512 ms. A key's state changes only when two scans
// in a row agree (debounce). Rows are numbered as port 0xFE's (row r is the
// one selected by A(8 + r) = 0); columns 0-4 are the Spectrum keys, columns
// 5-6 the 16 extra Next keys, at the places the Next's own membrane code
// gives (spec 12, open point K1):
//
//   row   column 6     column 5
//   0     UP           EXTEND MODE
//   1     GRAPH        CAPS LOCK
//   2     INV VIDEO    TRUE VIDEO
//   3     EDIT         BREAK
//   4     "            ;
//   5     .            ,
//   6     RIGHT        DELETE
//   7     DOWN         LEFT
//
// Registers:
//   KEYMAP0-6  0x10-0x16  column c of the membrane, bit r = row r, 1 = pressed
//   KEYCON     0x6B       KXMAP (0), EAR6 (1), PS2MAP (2); reset 0x07
//   ULA        0xFE       port 0xFE read: the rows whose bit is 0 in rb_hi
//                         (A15-A8) combined; 0 = pressed in bits 4-0, bit 5
//                         1, bit 6 EAR6, bit 7 1. rb_hi is 0 for the page
//                         form 0xFE00 and the register page (all rows)
//   KEYROW0-7  0x100-0x107 (register page only) each row alone
// A key counts as pressed on port 0xFE and KEYROW0-7 if it is held on the
// membrane, given by an extra key (KXMAP, section 8.2) or by a PS/2 key
// (PS2MAP, ps2map.v). Port 0xFE writes (border, beeper) belong to other
// units and are not answered here.
`include "regmap.vh"

module keys #(
    parameter ROWCLK = 6400            // clocks per row: 64 us
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [12:0] rb_addr,
    input  wire [7:0]  rb_hi,
    input  wire [7:0]  rb_wdata,
    output reg  [7:0]  rb_rdata,
    output reg         rb_hit,

    output reg  [7:0]  row_low,        // drive row r low
    input  wire [6:0]  col_i,          // the column lines, 0 = a key pressed in the driven row

    input  wire [39:0] ps2_keys,       // from ps2map.v, k = 5 x row + column
    output wire        ps2map_en       // KEYCON.PS2MAP
);
    // ---------------------------------------------------------------- KEYCON
    reg [2:0] keycon;
    assign    ps2map_en = keycon[`RM_KEYCON_PS2MAP];

    // ---------------------------------------------------------------- the scan
    (* ASYNC_REG = "TRUE" *) reg [6:0] cs0;
    reg  [6:0]  cs1;
    always @(posedge clk) begin
        cs0 <= col_i;
        cs1 <= cs0;
    end

    reg  [12:0] t;
    reg  [2:0]  row;
    reg  [55:0] scan, prev, state;     // bit 7r + c: row r, column c; 1 = pressed

    always @(posedge clk)
        if (rst) begin
            t <= 13'd0; row <= 3'd0; row_low <= 8'h01;
            scan <= 56'd0; prev <= 56'd0; state <= 56'd0;
        end else if (t != ROWCLK - 1) begin
            t <= t + 1'b1;
        end else begin
            t <= 13'd0;
            scan[7 * row +: 7] <= ~cs1;
            row <= row + 1'b1;
            row_low <= {row_low[6:0], row_low[7]};
            if (row == 3'd7) begin
                // A whole scan: each key takes the new value where two scans agree
                prev  <= {~cs1, scan[48:0]};
                state <= ({~cs1, scan[48:0]} & prev) | (state & ({~cs1, scan[48:0]} ^ prev));
            end
        end

    // ---------------------------------------------------------------- the Spectrum keys
    // k = 5r + c for the 40 Spectrum keys; the extra keys' pairs (KXMAP)
    wire [39:0] mem40;
    wire [15:0] ex;                    // extra keys: 2r + (c - 5)
    genvar r;
    generate for (r = 0; r < 8; r = r + 1) begin : mr
        assign mem40[5 * r +: 5] = state[7 * r +: 5];
        assign ex[2 * r +: 2]    = state[7 * r + 5 +: 2];
    end endgenerate
    // ex[2r] is column 5, ex[2r + 1] column 6
    wire up = ex[1],  extend = ex[0],  graph = ex[3],  capsl = ex[2];
    wire inv = ex[5], truev = ex[4],   edit = ex[7],   brk = ex[6];
    wire quot = ex[9], semi = ex[8],   dot = ex[11],   comma = ex[10];
    wire right = ex[13], del = ex[12], down = ex[15],  left = ex[14];
    wire xcs = up | extend | graph | capsl | inv | truev | edit | brk | right | del | down | left;
    wire xss = extend | quot | semi | dot | comma;
    wire [39:0] kx;
    assign kx[0]  = xcs;               // CAPS SHIFT
    assign kx[14:1] = 14'd0;
    assign kx[15] = edit;              // 1
    assign kx[16] = capsl;             // 2
    assign kx[17] = truev;             // 3
    assign kx[18] = inv;               // 4
    assign kx[19] = left;              // 5
    assign kx[20] = del;               // 0
    assign kx[21] = graph;             // 9
    assign kx[22] = right;             // 8
    assign kx[23] = up;                // 7
    assign kx[24] = down;              // 6
    assign kx[25] = quot;              // P
    assign kx[26] = semi;              // O
    assign kx[34:27] = 8'd0;
    assign kx[35] = brk;               // SPACE
    assign kx[36] = xss;               // SYMBOL SHIFT
    assign kx[37] = dot;               // M
    assign kx[38] = comma;             // N
    assign kx[39] = 1'b0;

    // Registered, so the read path starts from flip-flops
    reg  [39:0] p;                     // pressed, as port 0xFE shows it
    always @(posedge clk)
        p <= mem40 | (keycon[`RM_KEYCON_KXMAP] ? kx : 40'd0)
                   | (keycon[`RM_KEYCON_PS2MAP] ? ps2_keys : 40'd0);

    // Port 0xFE: the rows selected by rb_hi
    reg  [4:0] sel_cols;
    integer i;
    always @(*) begin
        sel_cols = 5'd0;
        for (i = 0; i < 8; i = i + 1)
            if (!rb_hi[i]) sel_cols = sel_cols | p[5 * i +: 5];
    end
    wire [7:0] fe_hi = {1'b1, keycon[`RM_KEYCON_EAR6], 1'b1, 5'd0};

    // ---------------------------------------------------------------- registers
    wire is_map = (rb_addr >= `RM_KEYMAP0) && (rb_addr <= `RM_KEYMAP6);
    wire is_row = (rb_addr >= `RM_KEYROW0) && (rb_addr <= `RM_KEYROW7);
    wire [2:0] ri = rb_addr[2:0];
    wire [2:0] ci = rb_addr[2:0];
    reg  [7:0] colbits;
    always @(*) begin
        colbits = 8'd0;
        for (i = 0; i < 8; i = i + 1) colbits[i] = state[7 * i + ci];
    end

    always @(posedge clk) begin
        if (rst) keycon <= 3'b111;
        else if (rb_wr && rb_addr == `RM_KEYCON) keycon <= rb_wdata[2:0];

        rb_rdata <= 8'd0;
        rb_hit   <= rb_rd && (is_map || is_row || rb_addr == `RM_KEYCON || rb_addr == `RM_ULA);
        if (rb_rd) begin
            if (is_map)                      rb_rdata <= colbits;
            else if (is_row)                 rb_rdata <= fe_hi | {3'd0, ~p[5 * ri +: 5]};
            else if (rb_addr == `RM_KEYCON)  rb_rdata <= {5'd0, keycon};
            else if (rb_addr == `RM_ULA)     rb_rdata <= fe_hi | {3'd0, ~sel_cols};
        end
    end
endmodule
