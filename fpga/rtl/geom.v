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
    // Each row takes four products: its three entries times the vector, then
    // (2T + 1) x 0x2000, which adds the translation T << 14 and the rounding
    // constant 0x2000 together (1 x 0x2000 when there is no translation). So
    // the accumulator starts from 0 and the whole row sum fits one DSP slice.
    // One subtractor a row serves v - C, P - C (both wrapped to 16 bits) and
    // v - T (17 bits, not wrapped).
    wire [15:0] vin [0:2];
    assign vin[0] = vx;
    assign vin[1] = vy;
    assign vin[2] = vz;
    reg  [15:0] ld_a [0:8];            // row r, entry k at 3r + k
    reg  [17:0] ld_t [0:2];            // row r's fourth product: 2T + 1, or 1
    reg  [17:0] ld_b [0:2];
    reg  [17:0] dif  [0:2];            // (P or v) - (T or C)
    reg  [15:0] dmin, dsub;
    integer r, c;
    always @(*) begin
        for (r = 0; r < 3; r = r + 1) begin
            dmin   = (job == J_COMB) ? ob[9+r] : vin[r];
            dsub   = (job != J_COMB && m_inv) ? tw[r] : cm[9+r];
            dif[r] = sx18(dmin) - sx18(dsub);
            for (c = 0; c < 3; c = c + 1) ld_a[3*r+c] = cm[3*r+c];
            ld_t[r] = 18'd1;
            ld_b[r] = sx18(vin[r]);
        end
        if (job == J_COMB) begin
            for (c = 0; c < 3; c = c + 1)
                ld_b[c] = (pass == 2'd3) ? sx18(dif[c][15:0]) : sx18(ob[3*c+pass]);
        end else case ({m_cam, m_inv})
            2'b00: for (r = 0; r < 3; r = r + 1) begin
                for (c = 0; c < 3; c = c + 1) ld_a[3*r+c] = mw[3*r+c];
                ld_t[r] = {tw[r][15], tw[r], 1'b1};
            end
            2'b10: for (r = 0; r < 3; r = r + 1)
                ld_b[r] = sx18(dif[r][15:0]);
            2'b01: for (r = 0; r < 3; r = r + 1) begin
                for (c = 0; c < 3; c = c + 1) ld_a[3*r+c] = mw[3*c+r];
                ld_b[r] = dif[r];
            end
            default: for (r = 0; r < 3; r = r + 1)
                for (c = 0; c < 3; c = c + 1) ld_a[3*r+c] = cm[3*c+r];
        endcase
    end

    // ---------------------------------------------------------------- row MACs
    reg  [17:0] a_sh [0:11];           // row r: entries at 4r .. 4r + 2, then 2T + 1
    reg  [17:0] b_sh [0:3];            // the vector, then 0x2000
    wire [47:0] acc  [0:2];
    wire        mac_en  = (state == S_MAC);
    wire        mac_clr = (state == S_LOAD);
    genvar gr;
    generate for (gr = 0; gr < 3; gr = gr + 1) begin : row
        geom_mac mac (.clk(clk), .clr(mac_clr), .en(mac_en),
                      .a(a_sh[4*gr]), .b(b_sh[0]), .acc(acc[gr]));
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

    // Divider X's inputs, made positive by one negator each: DX.X and Z for a
    // vertex, DVD and DVS for the divide job
    wire [31:0] xn_src = (job == J_DIV) ? dvd : px;
    wire [15:0] xd_src = (job == J_DIV) ? dvs : zr;
    wire [31:0] xn_abs = xn_src[31] ? -xn_src : xn_src;
    wire [15:0] xd_abs = xd_src[15] ? -xd_src : xd_src;

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
            S_LOAD: begin                                 // (the accumulators clear)
                for (i = 0; i < 3; i = i + 1) begin
                    a_sh[4*i]   <= sx18(ld_a[3*i]);
                    a_sh[4*i+1] <= sx18(ld_a[3*i+1]);
                    a_sh[4*i+2] <= sx18(ld_a[3*i+2]);
                    a_sh[4*i+3] <= ld_t[i];
                    b_sh[i]     <= ld_b[i];
                end
                b_sh[3] <= 18'h02000;
                k     <= 2'd0;
                state <= S_MAC;
            end
            S_MAC: begin
                for (i = 0; i < 3; i = i + 1) begin
                    a_sh[4*i]   <= a_sh[4*i+1];
                    a_sh[4*i+1] <= a_sh[4*i+2];
                    a_sh[4*i+2] <= a_sh[4*i+3];
                end
                b_sh[0] <= b_sh[1];
                b_sh[1] <= b_sh[2];
                b_sh[2] <= b_sh[3];
                k <= k + 1'b1;
                if (k == 2'd3) state <= S_SAT;
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
                dvx_n <= xn_abs;
                dvy_n <= py[31] ? -py : py;
                dvx_d <= xd_abs;
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
                    dvx_n <= xn_abs;
                    dvx_d <= xd_abs;
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
    // Banks 0-3 read back from a shadow copy in distributed RAM, written with
    // the registers, so the bus needs no multiplexer over 40 words. LUT RAM
    // is not cleared by a reset, so a byte reads 0 until written after one
    // (sh_ok). The product bank, written by the unit, reads its registers.
    wire [6:0] sh_a  = {ctl[1:0], rn};
    wire       sh_wr = rb_wr && hit && rn < 5'd24 && !ctl[2] &&
                       (ctl[1:0] != 2'd2 || rn < 5'd10) && (ctl[1:0] != 2'd3 || rn < 5'd22);
    reg  [7:0]   shadow [0:127];
    reg  [127:0] sh_ok;
    always @(posedge clk)
        if (sh_wr) shadow[sh_a] <= rb_wdata;
    always @(posedge clk)
        if (rst)        sh_ok <= 128'd0;
        else if (sh_wr) sh_ok[sh_a] <= 1'b1;

    wire [3:0]  wi9   = wi - 4'd9;
    wire [15:0] pword = (wi < 4'd9) ? mw[wi] : tw[wi9[1:0]];      // the product bank
    always @(posedge clk) begin
        rb_hit   <= rb_rd && hit;
        rb_rdata <= 8'd0;
        if (rb_rd && hit) begin
            if (rn < 5'd24) begin
                if (!ctl[2])                rb_rdata <= sh_ok[sh_a] ? shadow[sh_a] : 8'd0;
                else if (ctl[1:0] == 2'd0)  rb_rdata <= hb ? pword[15:8] : pword[7:0];
            end else case (rn)
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

// One row's multiply-accumulate: one DSP48E1 (A and B 18 bits, P 48 bits),
// cleared by RSTP, accumulating with CEP.
module geom_mac (
    input  wire        clk,
    input  wire        clr,            // acc = 0
    input  wire        en,             // acc += a * b
    input  wire [17:0] a,
    input  wire [17:0] b,
    output reg  [47:0] acc
);
    wire signed [35:0] p = $signed(a) * $signed(b);
    always @(posedge clk)
        if (clr)     acc <= 48'd0;
        else if (en) acc <= acc + {{12{p[35]}}, p};
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
