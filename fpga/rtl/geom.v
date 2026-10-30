// The geometry unit, registers 0xA0-0xBF of the system page (spec 15).
// retro-z80 only: a Z80 has no multiply.
//
//   GEOW0-11   0xA0-0xB7  a window of twelve words onto bank GEOCTL.BANK:
//                         0 camera (Mc, C), 1 object (Mo, P), 2 view (DX, DY,
//                         SCX, SCY, ZMIN), 3 operands (face points, MA, MB,
//                         DVD, DVS), 4 the product (M, T; read only)
//   GEOVX-VZ   0xB8-0xBD  write: the vertex; GEOVZ1 starts it. Read: RX-RZ
//   GEOCTL     0xBE       BANK (2-0), PROJ (3), CAM (4), INV (5)
//   GEOSTAT    0xBF       BUSY, NEAR, SAT, DIVZ, FRONT; SATS (7) sticky, W1C
//
// The jobs (spec 15, section 4) run one at a time on a small sequencer:
//
//   combine  after any byte of the camera or the object changes: four passes
//            of the row MACs, M = Mc.Mo (three columns) and T = Mc.(P - C),
//            about 20 clocks. A job waits for it.
//   vertex   one pass (LOAD, 3 MAC clocks, SAT), then, with PROJ, the NEAR
//            test, DX.X and DY.Y, two dividers and the screen point: about
//            18 clocks from the GEOVZ1 write to the results
//   face     (x1-x0)(y2-y0) - (y1-y0)(x2-x0), FRONT = sign, about 4 clocks
//   multiply MA x MB, 2 clocks
//   divide   DVD / DVS on divider X, about 11 clocks
//
// Each row MAC (geom_mac) is one DSP slice: acc = (first ? init : acc) + a*b,
// with the rounding constant and any translation in init. A pass loads a
// shift register per row with that row's three entries and a shared one
// with the vector, and shifts them through in three clocks. The matrix and
// vector are picked at LOAD, so the transpose and the camera-only forms
// cost only the load multiplexers.
//
// A start write while a job runs is held (one, the latest) and runs after
// it. Operands are taken at LOAD, the clock after the start.
`include "regmap.vh"

module geom (
    input  wire        clk,            // 100 MHz
    input  wire        rst,

    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [12:0] rb_addr,
    input  wire [7:0]  rb_wdata,
    output reg  [7:0]  rb_rdata,
    output reg         rb_hit,

    output wire        busy            // GEOSTAT.BUSY
);
    // ---------------------------------------------------------------- decode
    wire       hit = (rb_addr[12:5] == 8'b0000_0101);   // 0x0A0-0x0BF
    wire [4:0] rn  = rb_addr[4:0];
    wire [3:0] wi  = rn[4:1];                           // window word
    wire       hb  = rn[0];                             // high byte

    // ---------------------------------------------------------------- state
    reg [15:0] cm [0:11];              // camera: Mc row by row, C
    reg [15:0] ob [0:11];              // object: Mo, P
    reg [15:0] vw [0:4];               // view: DX, DY, SCX, SCY, ZMIN
    reg [15:0] op [0:10];              // operands
    reg [15:0] mw [0:8];               // the combined matrix M
    reg [15:0] tw [0:2];               // and its translation T
    reg [15:0] vx, vy, vz;             // the vertex written
    reg [15:0] rx, ry, rz;             // results
    reg [5:0]  ctl;                    // GEOCTL
    reg        st_near, st_sat, st_divz, st_front, sats;
    reg        msat;                   // the combined matrix saturated
    reg        dirty;                  // the camera or the object changed
    reg        pend;                   // a start is held
    reg [1:0]  pend_job;

    localparam J_VERT = 3'd0, J_FACE = 3'd1, J_MUL = 3'd2, J_DIV = 3'd3, J_COMB = 3'd4;
    localparam S_IDLE = 4'd0, S_LOAD = 4'd1, S_MAC = 4'd2, S_SAT = 4'd3,
               S_P0 = 4'd4, S_P1 = 4'd5, S_PDIV = 4'd6, S_P3 = 4'd7,
               S_F1 = 4'd8, S_F2 = 4'd9, S_F3 = 4'd10, S_M1 = 4'd11, S_M2 = 4'd12,
               S_D1 = 4'd13, S_D2 = 4'd14, S_D3 = 4'd15;
    reg [3:0]  state;
    reg [2:0]  job;
    reg [1:0]  pass;                   // combine: columns 0-2, then T
    reg [1:0]  k;                      // MAC clock
    reg        m_cam, m_inv, m_proj;   // the vertex's GEOCTL bits, taken at its start

    assign busy = (state != S_IDLE) || dirty || pend;

    // ---------------------------------------------------------------- helpers
    function [16:0] sat_acc;           // {saturated, value}: a row sum >>> 14 to 16 bits
        input [47:0] a;
        sat_acc = (&a[47:29] || ~|a[47:29]) ? {1'b0, a[29:14]}
                                            : {1'b1, a[47] ? 16'h8000 : 16'h7FFF};
    endfunction
    function [16:0] sat20;             // {saturated, value}: 20 bits signed to 16
        input [19:0] v;
        sat20 = (&v[19:15] || ~|v[19:15]) ? {1'b0, v[15:0]}
                                          : {1'b1, v[19] ? 16'h8000 : 16'h7FFF};
    endfunction
    function [17:0] sx18;
        input [15:0] v;
        sx18 = {{2{v[15]}}, v};
    endfunction

    // ---------------------------------------------------------------- the pass's operands
    // What LOAD puts in the shift registers, for the job and pass in hand.
    wire [15:0] vin [0:2];
    assign vin[0] = vx;
    assign vin[1] = vy;
    assign vin[2] = vz;
    reg  [15:0] ld_a [0:8];            // row r, entry k at 3r + k
    reg  [17:0] ld_b [0:2];
    reg  [47:0] ld_i [0:2];
    integer r, c;
    always @(*) begin
        for (r = 0; r < 3; r = r + 1) begin
            for (c = 0; c < 3; c = c + 1) ld_a[3*r+c] = cm[3*r+c];
            ld_b[r] = 18'd0;
            ld_i[r] = 48'h2000;
        end
        if (job == J_COMB) begin
            for (c = 0; c < 3; c = c + 1)
                ld_b[c] = (pass == 2'd3) ? sx18(ob[9+c] - cm[9+c]) : sx18(ob[3*c+pass]);
        end else case ({m_cam, m_inv})
            2'b00: for (r = 0; r < 3; r = r + 1) begin
                for (c = 0; c < 3; c = c + 1) ld_a[3*r+c] = mw[3*r+c];
                ld_b[r] = sx18(vin[r]);
                ld_i[r] = {{18{tw[r][15]}}, tw[r], 14'd0} + 48'h2000;
            end
            2'b10: for (r = 0; r < 3; r = r + 1)
                ld_b[r] = sx18(vin[r] - cm[9+r]);
            2'b01: for (r = 0; r < 3; r = r + 1) begin
                for (c = 0; c < 3; c = c + 1) ld_a[3*r+c] = mw[3*c+r];
                ld_b[r] = sx18(vin[r]) - sx18(tw[r]);
            end
            default: for (r = 0; r < 3; r = r + 1) begin
                for (c = 0; c < 3; c = c + 1) ld_a[3*r+c] = cm[3*c+r];
                ld_b[r] = sx18(vin[r]);
            end
        endcase
    end

    // ---------------------------------------------------------------- row MACs
    reg  [15:0] a_sh [0:8];
    reg  [17:0] b_sh [0:2];
    reg  [47:0] init [0:2];
    wire [47:0] acc  [0:2];
    wire        mac_en = (state == S_MAC);
    genvar gr;
    generate for (gr = 0; gr < 3; gr = gr + 1) begin : row
        geom_mac mac (.clk(clk), .en(mac_en), .first(k == 2'd0), .init(init[gr]),
                      .a(a_sh[3*gr]), .b(b_sh[0]), .acc(acc[gr]));
    end endgenerate

    wire [16:0] sr0 = sat_acc(acc[0]), sr1 = sat_acc(acc[1]), sr2 = sat_acc(acc[2]);

    // ---------------------------------------------------------------- projection and the other jobs
    reg  [15:0] xr, yr, zr;            // the turned vertex
    reg         vsat;
    reg  signed [31:0] px, py;         // DX.X, DY.Y
    reg  signed [16:0] fd1, fd2, fd3, fd4;
    reg  signed [33:0] f1, f2;
    reg  signed [31:0] pm;
    reg         sgx, sgy;

    wire signed [15:0] zmin_s = vw[4];
    wire signed [15:0] zmin1  = (zmin_s < 16'sd1) ? 16'sd1 : zmin_s;

    // The dividers: X does the divide job too
    reg         dv_start;
    reg  [31:0] dvx_n, dvy_n;
    reg  [15:0] dvx_d, dvy_d;
    wire [17:0] qx_m, qy_m;
    wire [15:0] rx_m, ry_m;
    wire        ovx, ovy, dvx_done;
    geom_div dvx (.clk(clk), .start(dv_start), .n(dvx_n), .d(dvx_d), .done(dvx_done), .q(qx_m), .r(rx_m), .ovf(ovx));
    geom_div dvy (.clk(clk), .start(dv_start), .n(dvy_n), .d(dvy_d), .done(),         .q(qy_m), .r(ry_m), .ovf(ovy));

    // Floor of a signed quotient from its magnitude: -(q + (r != 0)) when negative
    wire [19:0] fqx = sgx ? -({2'b0, qx_m} + (rx_m != 16'd0)) : {2'b0, qx_m};
    wire [19:0] fqy = sgy ? -({2'b0, qy_m} + (ry_m != 16'd0)) : {2'b0, qy_m};
    wire [16:0] sx_scr = sat20({{4{vw[2][15]}}, vw[2]} + fqx);     // SCX + floor(DX.X / Z)
    wire [16:0] sy_scr = sat20({{4{vw[3][15]}}, vw[3]} - fqy);     // SCY - floor(DY.Y / Z)

    wire signed [34:0] fs = {f1[33], f1} - {f2[33], f2};
    wire        fs_fit = &fs[34:31] || ~|fs[34:31];
    wire [31:0] fs32   = fs_fit ? fs[31:0] : (fs[34] ? 32'h8000_0000 : 32'h7FFF_FFFF);

    wire [31:0] dvd    = {op[9], op[8]};
    wire [15:0] dvs    = op[10];
    wire        dneg   = dvd[31] ^ dvs[15];
    wire [17:0] dq_lim = dneg ? 18'd32768 : 18'd32767;

    // ---------------------------------------------------------------- the sequencer and the registers
    integer i;
    task finish(input near, input satf, input divz, input front);
        begin
            st_near  <= near;
            st_sat   <= satf;
            st_divz  <= divz;
            st_front <= front;
            if (satf) sats <= 1'b1;
            state    <= S_IDLE;
        end
    endtask

    always @(posedge clk) begin
        dv_start <= 1'b0;
        if (rst) begin
            for (i = 0; i < 12; i = i + 1) begin cm[i] <= 16'd0; ob[i] <= 16'd0; end
            for (i = 0; i < 5; i = i + 1)  vw[i] <= 16'd0;
            for (i = 0; i < 11; i = i + 1) op[i] <= 16'd0;
            for (i = 0; i < 9; i = i + 1)  mw[i] <= 16'd0;
            for (i = 0; i < 3; i = i + 1)  tw[i] <= 16'd0;
            {vx, vy, vz, rx, ry, rz} <= 96'd0;
            ctl <= 6'd0;
            {st_near, st_sat, st_divz, st_front, sats, msat} <= 6'd0;
            dirty <= 1'b0;
            pend  <= 1'b0;
            pend_job <= 2'd0;
            state <= S_IDLE;
            job   <= J_VERT;
            pass  <= 2'd0;
            k     <= 2'd0;
            {m_cam, m_inv, m_proj} <= 3'd0;
        end else begin
            // ------------------------------------------------ the sequencer
            case (state)
            S_IDLE:
                if (dirty) begin
                    dirty <= 1'b0;
                    job   <= J_COMB;
                    pass  <= 2'd0;
                    msat  <= 1'b0;
                    state <= S_LOAD;
                end else if (pend) begin
                    pend <= 1'b0;
                    job  <= {1'b0, pend_job};
                    case (pend_job)
                    2'd0: begin
                        m_proj <= ctl[3];
                        m_cam  <= ctl[4];
                        m_inv  <= ctl[5];
                        state  <= S_LOAD;
                    end
                    2'd1: state <= S_F1;
                    2'd2: state <= S_M1;
                    default: state <= S_D1;
                    endcase
                end
            S_LOAD: begin
                for (i = 0; i < 9; i = i + 1) a_sh[i] <= ld_a[i];
                for (i = 0; i < 3; i = i + 1) begin b_sh[i] <= ld_b[i]; init[i] <= ld_i[i]; end
                k     <= 2'd0;
                state <= S_MAC;
            end
            S_MAC: begin
                for (i = 0; i < 3; i = i + 1) begin
                    a_sh[3*i]   <= a_sh[3*i+1];
                    a_sh[3*i+1] <= a_sh[3*i+2];
                end
                b_sh[0] <= b_sh[1];
                b_sh[1] <= b_sh[2];
                k <= k + 1'b1;
                if (k == 2'd2) state <= S_SAT;
            end
            S_SAT:
                if (job == J_COMB) begin
                    if (pass == 2'd3) begin
                        tw[0] <= sr0[15:0];
                        tw[1] <= sr1[15:0];
                        tw[2] <= sr2[15:0];
                        state <= S_IDLE;
                    end else begin
                        mw[pass]     <= sr0[15:0];
                        mw[3 + pass] <= sr1[15:0];
                        mw[6 + pass] <= sr2[15:0];
                        state <= S_LOAD;
                    end
                    if (sr0[16] || sr1[16] || sr2[16]) msat <= 1'b1;
                    pass <= pass + 1'b1;
                end else begin
                    xr   <= (m_cam && m_inv) ? sr0[15:0] + cm[9]  : sr0[15:0];
                    yr   <= (m_cam && m_inv) ? sr1[15:0] + cm[10] : sr1[15:0];
                    zr   <= (m_cam && m_inv) ? sr2[15:0] + cm[11] : sr2[15:0];
                    vsat <= sr0[16] || sr1[16] || sr2[16] || (!m_cam && msat);
                    state <= S_P0;
                end
            S_P0:
                if (!m_proj || $signed(zr) < zmin1) begin
                    rx <= xr;
                    ry <= yr;
                    rz <= zr;
                    finish(m_proj, vsat, 1'b0, 1'b0);
                end else begin
                    px <= $signed(vw[0]) * $signed(xr);
                    py <= $signed(vw[1]) * $signed(yr);
                    state <= S_P1;
                end
            S_P1: begin
                sgx   <= px[31];
                sgy   <= py[31];
                dvx_n <= px[31] ? -px : px;
                dvy_n <= py[31] ? -py : py;
                dvx_d <= zr;
                dvy_d <= zr;
                dv_start <= 1'b1;
                state <= S_PDIV;
            end
            S_PDIV:
                if (dvx_done) state <= S_P3;
            S_P3: begin
                rx <= ovx ? (sgx ? 16'h8000 : 16'h7FFF) : sx_scr[15:0];
                ry <= ovy ? (sgy ? 16'h7FFF : 16'h8000) : sy_scr[15:0];
                rz <= zr;
                finish(1'b0, vsat || ovx || ovy || sx_scr[16] || sy_scr[16], 1'b0, 1'b0);
            end
            S_F1: begin
                fd1 <= {op[2][15], op[2]} - {op[0][15], op[0]};    // x1 - x0
                fd2 <= {op[5][15], op[5]} - {op[1][15], op[1]};    // y2 - y0
                fd3 <= {op[3][15], op[3]} - {op[1][15], op[1]};    // y1 - y0
                fd4 <= {op[4][15], op[4]} - {op[0][15], op[0]};    // x2 - x0
                state <= S_F2;
            end
            S_F2: begin
                f1 <= fd1 * fd2;
                f2 <= fd3 * fd4;
                state <= S_F3;
            end
            S_F3: begin
                rx <= fs32[15:0];
                ry <= fs32[31:16];
                finish(1'b0, !fs_fit, 1'b0, !fs[34]);
            end
            S_M1: begin
                pm <= $signed(op[6]) * $signed(op[7]);
                state <= S_M2;
            end
            S_M2: begin
                rx <= pm[15:0];
                ry <= pm[31:16];
                finish(1'b0, 1'b0, 1'b0, 1'b0);
            end
            S_D1:
                if (dvs == 16'd0) begin
                    rx <= dvd[31] ? 16'h8000 : 16'h7FFF;
                    ry <= 16'd0;
                    finish(1'b0, 1'b0, 1'b1, 1'b0);
                end else begin
                    dvx_n <= dvd[31] ? -dvd : dvd;
                    dvx_d <= dvs[15] ? -dvs : dvs;
                    dv_start <= 1'b1;
                    state <= S_D2;
                end
            S_D2:
                if (dvx_done) state <= S_D3;
            S_D3:
                if (ovx || qx_m > dq_lim) begin
                    rx <= dneg ? 16'h8000 : 16'h7FFF;
                    ry <= 16'd0;
                    finish(1'b0, 1'b1, 1'b0, 1'b0);
                end else begin
                    rx <= dneg ? -qx_m[15:0] : qx_m[15:0];
                    ry <= dvd[31] ? -rx_m : rx_m;
                    finish(1'b0, 1'b0, 1'b0, 1'b0);
                end
            default: state <= S_IDLE;
            endcase

            // ------------------------------------------------ register writes (after the sequencer, so a
            // start or a matrix byte in the same clock as the sequencer takes the last one is kept)
            if (rb_wr && hit) begin
                if (rn < 5'd24) case (ctl[2:0])
                    3'd0: begin
                        if (hb) cm[wi][15:8] <= rb_wdata; else cm[wi][7:0] <= rb_wdata;
                        dirty <= 1'b1;
                    end
                    3'd1: begin
                        if (hb) ob[wi][15:8] <= rb_wdata; else ob[wi][7:0] <= rb_wdata;
                        dirty <= 1'b1;
                    end
                    3'd2: if (wi < 4'd5) begin
                        if (hb) vw[wi[2:0]][15:8] <= rb_wdata; else vw[wi[2:0]][7:0] <= rb_wdata;
                    end
                    3'd3: if (wi < 4'd11) begin
                        if (hb) op[wi][15:8] <= rb_wdata; else op[wi][7:0] <= rb_wdata;
                        if (hb && wi == 4'd5)  begin pend <= 1'b1; pend_job <= 2'd1; end  // F2Y1: face
                        if (hb && wi == 4'd7)  begin pend <= 1'b1; pend_job <= 2'd2; end  // MB1: multiply
                        if (hb && wi == 4'd10) begin pend <= 1'b1; pend_job <= 2'd3; end  // DVS1: divide
                    end
                    default: ;                                    // the product, reserved banks
                endcase
                else case (rn)
                    5'h18: vx[7:0]  <= rb_wdata;
                    5'h19: vx[15:8] <= rb_wdata;
                    5'h1A: vy[7:0]  <= rb_wdata;
                    5'h1B: vy[15:8] <= rb_wdata;
                    5'h1C: vz[7:0]  <= rb_wdata;
                    5'h1D: begin vz[15:8] <= rb_wdata; pend <= 1'b1; pend_job <= 2'd0; end
                    5'h1E: ctl <= rb_wdata[5:0];
                    default: if (rb_wdata[`RM_GEOSTAT_SATS]) sats <= 1'b0;
                endcase
            end
        end
    end

    // ---------------------------------------------------------------- reads
    reg [15:0] wsel;
    wire [3:0] wi9    = wi - 4'd9;
    wire [1:0] wi4m9  = wi9[1:0];         // the product bank's T words
    always @(*) begin
        wsel = 16'd0;
        case (ctl[2:0])
            3'd0: wsel = cm[wi];
            3'd1: wsel = ob[wi];
            3'd2: if (wi < 4'd5)  wsel = vw[wi[2:0]];
            3'd3: if (wi < 4'd11) wsel = op[wi];
            3'd4: wsel = (wi < 4'd9) ? mw[wi] : tw[wi4m9];
            default: ;
        endcase
    end
    always @(posedge clk) begin
        rb_hit   <= rb_rd && hit;
        rb_rdata <= 8'd0;
        if (rb_rd && hit) begin
            if (rn < 5'd24) rb_rdata <= hb ? wsel[15:8] : wsel[7:0];
            else case (rn)
                5'h18: rb_rdata <= rx[7:0];
                5'h19: rb_rdata <= rx[15:8];
                5'h1A: rb_rdata <= ry[7:0];
                5'h1B: rb_rdata <= ry[15:8];
                5'h1C: rb_rdata <= rz[7:0];
                5'h1D: rb_rdata <= rz[15:8];
                5'h1E: rb_rdata <= {2'b00, ctl};
                default: rb_rdata <= {sats, 2'b00, st_front, st_divz, st_sat, st_near, busy};
            endcase
        end
    end
endmodule

// One row's multiply-accumulate: one DSP48E1 (A 16 bits, B 18 bits, P 48 bits).
module geom_mac (
    input  wire        clk,
    input  wire        en,
    input  wire        first,          // start from init, not from acc
    input  wire [47:0] init,
    input  wire [15:0] a,
    input  wire [17:0] b,
    output reg  [47:0] acc
);
    wire signed [33:0] p = $signed(a) * $signed(b);
    always @(posedge clk)
        if (en) acc <= (first ? init : acc) + {{14{p[33]}}, p};
endmodule

// Unsigned n / d by restoring division, two quotient bits a clock: 18 bits in
// 9 clocks after start. ovf when the quotient would not fit 17 bits
// (n[31:17] >= d); q and r are then meaningless. d must not be 0.
module geom_div (
    input  wire        clk,
    input  wire        start,
    input  wire [31:0] n,
    input  wire [15:0] d,
    output reg         done,           // 1 clock: q, r and ovf are ready
    output reg  [17:0] q,
    output reg  [15:0] r,
    output reg         ovf
);
    reg [17:0] nsh;
    reg [15:0] dd;
    reg [3:0]  cnt;
    wire [16:0] t1 = {r, nsh[17]};
    wire        g1 = (t1 >= {1'b0, dd});
    wire [15:0] r1 = g1 ? t1[15:0] - dd : t1[15:0];
    wire [16:0] t2 = {r1, nsh[16]};
    wire        g2 = (t2 >= {1'b0, dd});
    wire [15:0] r2 = g2 ? t2[15:0] - dd : t2[15:0];
    always @(posedge clk) begin
        done <= 1'b0;
        if (start) begin
            ovf <= (n[31:17] >= {1'b0, d});
            r   <= {2'b00, n[31:18]};
            nsh <= n[17:0];
            dd  <= d;
            q   <= 18'd0;
            cnt <= 4'd9;
        end else if (cnt != 4'd0) begin
            r   <= r2;
            nsh <= {nsh[15:0], 2'b00};
            q   <= {q[15:0], g1, g2};
            cnt <= cnt - 1'b1;
            if (cnt == 4'd1) done <= 1'b1;
        end
    end
endmodule
