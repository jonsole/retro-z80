// Copper (spec 6): runs a list of 16-bit instruction words from SRAM every
// frame and writes custom registers at chosen beam positions. retro68k's
// copper.v, narrowed to 8-bit data (ticket #32).
//
//   fetch     one 16-bit word at a time through the scheduler's copper
//             channel (dmac.v), into a buffer of two words: the next words
//             are fetched while an instruction runs (a WAIT, say). A jump
//             throws the buffer away; a word still on its way is dropped
//             when it arrives.
//   execute   one instruction at a time, as soon as all its words (one or
//             two) are in the buffer. A register write goes out on the
//             register bus at once: the copper goes first, and the CPU's
//             strobe moves one clock (bus_if.v; spec 1, section 4.2). Every
//             write is followed by one spare clock, so that a write to the
//             copper's own registers (a strobe, COPX) has taken effect
//             before the next instruction runs, and the copper writes at
//             most every second clock.
//
// The copper's own registers are written through the register bus like
// any other, whether the CPU or the copper itself (MOVEF) writes them.
//
// Instructions (spec 6, section 4.1): the high byte of the first word is the
// code. 0x00-0xEF MOVE; 0xF0 WAIT, 0xF1 SKIP, 0xF2 JUMP, 0xF3 STOP, 0xF4-0xF8
// MOVR, 0xF9 ALU, 0xFA SKIPC, 0xFB CALL and RET, 0xFC MOVEF; 0xFD-0xFF and
// any bit shown as 0 that is set are reserved: they stop the copper with
// COPSTAT.ERR. A skipped instruction is fetched whole and dropped.
//
// Registers (custom block, spec 6, section 6):
//   COPCON   0x100   EN (0), IRQEN (1), RESUME (2), STKKEEP (3), PRI (5-4)
//   COP1LC   0x101   3 bytes, bits 21-1 (bit 0 reads 0)
//   COP2LC   0x104   3 bytes; written by the hardware only with RESUME
//   COPJMP1  0x107   strobe;  COPJMP2 0x108 strobe;  COPINT 0x109 strobe
//   COPPC    0x10A   3 bytes, read only; reading 0x10A hands all three to
//                    the bus interface's capture (spec 3, rule 4)
//   COPSTAT  0x10D   WAITING (0), STOPPED (1) live; ERR (2), IRQ (3) W1C
//   COPX, COPY, COPFLAGS, COPSP  0x10E-0x111;  COPR0-7  0x118-0x11F
//
// Changed from retro68k: 16-bit words carrying 8-bit data, one-word MOVE
// (code = custom offset 0x000-0x0EF), MOVEF to any offset 0x000-0x3FF, MOVR
// with 8-bit register codes in X, ALU fn/d/source in one word with a value
// word for source 10, SKIPC, CALL and RET in words; a buffer of two words in
// place of one 32-bit instruction; 10-bit beam positions (end of list: a
// WAIT for line 1023); byte registers; the copper goes first on the register
// bus (no cw_go); no nasty mode (PRI 2 and 3 act as 1, in dmac.v). A SKIP
// drops the next instruction as it comes, whatever its length, in place of
// refetching two words on.
`include "regmap.vh"

module copper (
    input  wire        clk,            // 100 MHz
    input  wire        rst,

    // The register bus (as every unit sees it: the CPU's and the copper's writes)
    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [12:0] rb_addr,
    input  wire [7:0]  rb_wdata,
    output reg  [7:0]  rb_rdata,
    output reg         rb_hit,
    output reg  [31:0] rb_cdata,       // with rb_rdata: COPPC whole, for the capture
    output reg         rb_cap,

    // The copper's write onto the register bus (muxed in retroz80.v): on the
    // bus in the clock cw_req is high, never held off
    output reg         cw_req,
    output reg  [9:0]  cw_off,         // custom offset
    output reg  [7:0]  cw_data,

    // Memory (dmac.v copper channel)
    output reg         mem_req,
    output reg  [21:1] mem_addr,
    output wire [1:0]  mem_pri,
    input  wire        mem_ack,
    input  wire        mem_rvalid,
    input  wire [15:0] mem_rdata,

    // From the video (memory side)
    input  wire [10:0] beam_v,
    input  wire [10:0] beam_h,
    input  wire        vblank,         // 1 clock: the frame starts, beam (0, 0)
    input  wire        dma_on,         // DMACON.DMAEN and COPEN
    input  wire        blt_idle,       // the DMA engine has nothing to do

    output wire        irq             // source COPPER (2)
);
    localparam [10:0] VTOT = 11'd625, HTOT = 11'd864;

    // ================================================================ registers
    reg  [5:0]  copcon;                // PRI (5:4), STKKEEP (3), RESUME (2), IRQEN (1), EN (0)
    reg  [21:1] lc1, lc2;
    reg         st_err, st_irq;
    reg  [7:0]  rx, ry;
    reg  [2:0]  rf;                    // C (2), N (1), Z (0)
    reg  [7:0]  rr [0:7];
    reg  [21:1] stk [0:7];
    reg  [3:0]  sp;

    wire en = copcon[0] && dma_on;
    assign mem_pri = copcon[5:4];
    assign irq = st_irq && copcon[1];

    // Custom offsets 0x100-0x11F
    wire sel = (rb_addr[12:5] == 8'h88);
    wire [4:0] ro = rb_addr[4:0];
    wire wr  = rb_wr && sel;

    // Strobes act on any write
    wire s_jmp1 = wr && rb_addr == `RM_COPJMP1;
    wire s_jmp2 = wr && rb_addr == `RM_COPJMP2;
    wire s_int  = wr && rb_addr == `RM_COPINT;
    wire s_sp   = wr && rb_addr == `RM_COPSP;

    // ================================================================ state
    localparam X_OFF = 3'd0, X_RUN = 3'd1, X_WAIT = 3'd2, X_GAP = 3'd3, X_ALU = 3'd4;
    reg  [2:0]  xs;
    reg  [21:1] npc;                   // next instruction to run (the word at b0)
    reg  [21:1] xpc;                   // the instruction running
    reg         in2;                   // in list 2 (RESUME)
    reg         skip;                  // drop the next instruction

    // Fetch: a buffer of two words, and at most one word on its way
    reg  [15:0] b0, b1;
    reg  [1:0]  bn;
    reg  [21:1] fpc;                   // next word to fetch
    reg         outst;                 // a word is on its way (acked, data not back)
    reg         stale;                 // ... and it is to be dropped

    // A WAIT in progress
    reg  [10:0] w_line, w_px;
    reg         w_never, w_blt;

    // The ALU, one clock after decode
    reg  [7:0]  a_op, a_val;

    // ---------------------------------------------------------------- decode
    wire [7:0]  code = b0[15:8];
    wire [7:0]  lo   = b0[7:0];
    wire        ext  = (code[7:4] == 4'hF);
    // Two-word instructions: WAIT, SKIP, JUMP, MOVEF, ALU with a value, CALL
    wire        two  = ext && (code[3:0] == 4'h0 || code[3:0] == 4'h1 || code[3:0] == 4'h2 ||
                               code[3:0] == 4'hC || (code[3:0] == 4'h9 && lo[3:0] == 4'd10) ||
                               (code[3:0] == 4'hB && !lo[7]));
    wire        have = two ? (bn == 2'd2) : (bn != 2'd0);
    wire [21:1] npc_n = npc + (two ? 21'd2 : 21'd1);   // the instruction after this one

    // WAIT and SKIP positions: line and pixel, 10 bits each
    wire [10:0] i_line = {1'b0, lo[3:2], b1[15:8]};
    wire [10:0] i_px   = {1'b0, lo[1:0], b1[7:0]};
    wire        i_p    = lo[7];
    // Reached: the beam is at or past (line, pixel) in the frame
    wire        t_never  = (i_line >= VTOT) || (i_px >= HTOT);
    wire        t_reach  = !t_never && ((beam_v > i_line) || (beam_v == i_line && beam_h >= i_px));
    wire        t_preach = (i_px < HTOT) && (beam_h >= i_px);

    function cond(input [3:0] cc, input [2:0] f);   // f = {C, N, Z}
        case (cc)
            4'd0: cond = f[0];
            4'd1: cond = !f[0];
            4'd2: cond = f[2];
            4'd3: cond = !f[2];
            4'd4: cond = f[1];
            4'd5: cond = !f[1];
            4'd6: cond = !f[2] && !f[0];
            4'd7: cond = f[2] || f[0];
            default: cond = 1'b0;
        endcase
    endfunction

    // Reserved patterns (spec 6, section 4.9): bits shown as 0 must be 0
    reg bad;
    always @(*) begin
        bad = 1'b0;
        if (ext) case (code[3:0])
            4'h0: bad = lo[5:4] != 2'd0;                                 // WAIT
            4'h1: bad = lo[6:4] != 3'd0;                                 // SKIP (no B)
            4'h2: bad = lo[7:6] != 2'd0 || b1[0];                        // JUMP
            4'h3: bad = lo != 8'd0;                                      // STOP
            4'h8: bad = lo[7:2] != 6'd0;                                 // MOVR (X) = X or Y
            4'h9: bad = lo[3:0] > 4'd10                                  // ALU
                        || ((lo[7:5] == 3'd1 || (lo[7:5] == 3'd7 && lo[4])) && lo[3])
                        || (lo[3:0] == 4'd10 && b1[15:8] != 8'd0);
            4'hA: bad = lo[7:3] != 5'd0;                                 // SKIPC
            4'hB: bad = lo[7] ? (lo[6:0] != 7'd0) : (lo[6] || b1[0]);    // RET, CALL
            4'hC: bad = lo[7:2] != 6'd0;                                 // MOVEF
            4'hD, 4'hE, 4'hF: bad = 1'b1;
            default: ;
        endcase
    end

    // A clock that restarts the copper runs no instruction, so that a cut-off
    // never leaves one half done
    wire hold = (vblank || s_jmp1 || s_jmp2) && en;

    // ---------------------------------------------------------------- main
    integer i;
    reg        flush;                  // throw the fetched words away, fetch from f_to
    reg [21:1] f_to;
    reg [1:0]  used;                   // words taken from the buffer this clock

    always @(posedge clk) begin
        flush = 1'b0;
        f_to  = npc;
        used  = 2'd0;
        cw_req <= 1'b0;

        if (rst) begin
            copcon <= 6'd0;
            lc1 <= 21'd0; lc2 <= 21'd0;
            st_err <= 1'b0; st_irq <= 1'b0;
            rx <= 8'd0; ry <= 8'd0; rf <= 3'd0;
            for (i = 0; i < 8; i = i + 1) rr[i] <= 8'd0;
            sp <= 4'd0;
            xs <= X_OFF;
            npc <= 21'd0; xpc <= 21'd0;
            in2 <= 1'b0;
            skip <= 1'b0;
            bn <= 2'd0;
            fpc <= 21'd0;
            mem_req <= 1'b0;
            outst <= 1'b0;
            stale <= 1'b0;
        end else begin
            // ---- execute
            case (xs)
                X_RUN: if (have && !hold) begin
                    used = two ? 2'd2 : 2'd1;
                    xpc  <= npc;
                    npc  <= npc_n;
                    if (skip) begin
                        skip <= 1'b0;              // a skipped instruction: dropped whole
                    end else if (!ext) begin
                        do_write({2'b00, code}, lo);                       // MOVE
                    end else if (bad) begin
                        st_err <= 1'b1;
                        stop;
                    end else case (code[3:0])
                        4'h0: begin                                         // WAIT
                            if (!i_p && i_line == 11'd1023) stop;
                            else begin
                                w_line  <= i_p ? beam_v + {10'd0, beam_h >= i_px} : i_line;
                                w_px    <= i_px;
                                w_never <= i_p ? (i_px >= HTOT) : t_never;
                                w_blt   <= lo[6];
                                xs      <= X_WAIT;
                            end
                        end
                        4'h1: if (i_p ? t_preach : t_reach) skip <= 1'b1;   // SKIP
                        4'h2: begin flush = 1'b1; f_to = {lo[5:0], b1[15:1]}; end   // JUMP
                        4'h3: stop;                                         // STOP
                        4'h4: do_write({2'b00, rx}, lo);                    // MOVR (X) = value
                        4'h5: begin                                         // ... X + 1
                            do_write({2'b00, rx}, lo);
                            rx <= rx + 8'd1;
                        end
                        4'h6: do_write({2'b00, lo}, rx);                    // MOVR reg = X
                        4'h7: do_write({2'b00, lo}, ry);                    // MOVR reg = Y
                        4'h8: begin                                         // MOVR (X) = Y or X
                            do_write({2'b00, rx}, lo[0] ? rx : ry);
                            if (lo[1]) rx <= rx + 8'd1;
                        end
                        4'h9: begin                                         // ALU
                            a_op  <= lo;
                            a_val <= b1[7:0];
                            xs    <= X_ALU;
                        end
                        4'hA: if (cond(lo[3:0], rf)) skip <= 1'b1;          // SKIPC
                        4'hB: if (lo[7]) begin                              // RET
                            if (sp == 4'd0) begin st_err <= 1'b1; stop; end
                            else begin
                                sp <= sp - 1'b1;
                                flush = 1'b1; f_to = stk[sp[2:0] - 3'd1];
                            end
                        end else begin                                      // CALL
                            if (sp == 4'd8) begin st_err <= 1'b1; stop; end
                            else begin
                                stk[sp[2:0]] <= npc_n;
                                sp <= sp + 1'b1;
                                flush = 1'b1; f_to = {lo[5:0], b1[15:1]};
                            end
                        end
                        4'hC: do_write({lo[1:0], b1[15:8]}, b1[7:0]);       // MOVEF
                        default: ;
                    endcase
                end

                X_ALU: if (!hold) begin : alu
                    reg [8:0] r;
                    reg [7:0] d, s;
                    reg [2:0] fn;
                    fn = a_op[7:5];
                    d  = a_op[4] ? ry : rx;
                    s  = (a_op[3:0] == 4'd10) ? a_val : (a_op[3:0] == 4'd8) ? rx :
                         (a_op[3:0] == 4'd9) ? ry : rr[a_op[2:0]];
                    case (fn)
                        3'd0: if (a_op[4]) ry <= s; else rx <= s;              // LD
                        3'd1: rr[a_op[2:0]] <= d;                              // ST
                        3'd7: if (a_op[4]) rr[a_op[2:0]] <= {5'd0, rf};       // ST flags
                              else rf <= s[2:0];                               // LD flags
                        default: begin
                            case (fn)
                                3'd2: r = {1'b0, d} + {1'b0, s};
                                3'd3, 3'd6: r = {1'b0, d} - {1'b0, s};
                                3'd4: r = {1'b0, d & s};
                                default: r = {1'b0, d | s};
                            endcase
                            rf <= {r[8], r[7], r[7:0] == 8'd0};
                            if (fn != 3'd6) begin
                                if (a_op[4]) ry <= r[7:0]; else rx <= r[7:0];
                            end
                        end
                    endcase
                    xs <= X_RUN;
                end

                X_WAIT: if (!w_never && ((beam_v > w_line) || (beam_v == w_line && beam_h >= w_px))
                            && (!w_blt || blt_idle))
                    xs <= X_RUN;

                X_GAP: xs <= X_RUN;
                default: ;
            endcase

            // ---- strobes and the frame restart (after execute: they win)
            if (s_jmp1 && en) begin
                in2 <= 1'b0;
                restart(lc1);
            end
            if (s_jmp2 && en) begin
                in2 <= 1'b1;
                restart(lc2);
            end
            if (vblank && en) begin
                // RESUME: list 2's place. A WAIT still waiting, an ALU not
                // done or an instruction still to be skipped is run again
                if (copcon[2] && in2)
                    lc2 <= (xs == X_WAIT || xs == X_ALU || skip) ? xpc : npc;
                in2 <= 1'b0;
                if (!copcon[3]) sp <= 4'd0;
                restart(lc1);
            end
            if (!en) begin
                xs <= X_OFF;
                if (xs != X_OFF) flush = 1'b1;
            end

            // ---- fetch: the buffer, less the words used, plus a word arriving
            begin : fetch
                reg [15:0] n0, n1;
                reg [1:0]  nn;
                n0 = (used == 2'd1) ? b1 : b0;
                n1 = b1;
                nn = bn - used;
                if (mem_ack) begin
                    mem_req <= 1'b0;
                    outst   <= 1'b1;
                end
                if (mem_rvalid) begin
                    outst <= 1'b0;
                    if (stale) stale <= 1'b0;
                    else if (!flush) begin
                        if (nn == 2'd0) n0 = mem_rdata; else n1 = mem_rdata;
                        nn = nn + 2'd1;
                    end
                end
                b0 <= n0;
                b1 <= n1;
                bn <= nn;
            end
            if (flush) begin
                bn   <= 2'd0;
                skip <= 1'b0;
                fpc  <= f_to;
                npc  <= f_to;
                // A word asked for or on its way is dropped when it comes
                if (mem_req || mem_ack || (outst && !mem_rvalid)) stale <= 1'b1;
            end else if (!mem_req && !outst && !mem_ack && !mem_rvalid && !stale
                         && xs != X_OFF && bn != 2'd2) begin
                mem_req  <= 1'b1;
                mem_addr <= fpc;
                fpc      <= fpc + 1'b1;
            end

            // ---- register writes (after the instructions: the bus wins)
            if (s_int) st_irq <= 1'b1;
            if (s_sp) sp <= 4'd0;
            if (wr) case (ro)
                5'h00: copcon <= rb_wdata[5:0];
                5'h01: lc1[7:1]   <= rb_wdata[7:1];
                5'h02: lc1[15:8]  <= rb_wdata;
                5'h03: lc1[21:16] <= rb_wdata[5:0];
                5'h04: lc2[7:1]   <= rb_wdata[7:1];
                5'h05: lc2[15:8]  <= rb_wdata;
                5'h06: lc2[21:16] <= rb_wdata[5:0];
                5'h0D: begin
                    if (rb_wdata[`RM_COPSTAT_ERR]) st_err <= 1'b0;
                    if (rb_wdata[`RM_COPSTAT_IRQ]) st_irq <= 1'b0;
                end
                5'h0E: rx <= rb_wdata;
                5'h0F: ry <= rb_wdata;
                5'h10: rf <= rb_wdata[2:0];
                5'h18, 5'h19, 5'h1A, 5'h1B, 5'h1C, 5'h1D, 5'h1E, 5'h1F: rr[ro[2:0]] <= rb_wdata;
                default: ;
            endcase
        end
    end

    // ---- reads (1 clock); COPPC0 hands the whole value to the capture
    wire [21:0] pc_now = {(xs == X_RUN) ? npc : xpc, 1'b0};   // stopped: the STOP
    always @(posedge clk) begin
        rb_rdata <= 8'd0;
        rb_hit   <= 1'b0;
        rb_cdata <= 32'd0;
        rb_cap   <= 1'b0;
        if (rb_rd && sel && !(ro >= 5'h12 && ro <= 5'h17)) begin
            rb_hit <= 1'b1;
            case (ro)
                5'h00: rb_rdata <= {2'd0, copcon};
                5'h01: rb_rdata <= {lc1[7:1], 1'b0};
                5'h02: rb_rdata <= lc1[15:8];
                5'h03: rb_rdata <= {2'd0, lc1[21:16]};
                5'h04: rb_rdata <= {lc2[7:1], 1'b0};
                5'h05: rb_rdata <= lc2[15:8];
                5'h06: rb_rdata <= {2'd0, lc2[21:16]};
                5'h0A: begin
                    rb_rdata <= pc_now[7:0];
                    rb_cdata <= {10'd0, pc_now};
                    rb_cap   <= 1'b1;
                end
                5'h0B: rb_rdata <= pc_now[15:8];
                5'h0C: rb_rdata <= {2'd0, pc_now[21:16]};
                5'h0D: rb_rdata <= {4'd0, st_irq, st_err, xs == X_OFF, xs == X_WAIT};
                5'h0E: rb_rdata <= rx;
                5'h0F: rb_rdata <= ry;
                5'h10: rb_rdata <= {5'd0, rf};
                5'h11: rb_rdata <= {4'd0, sp};
                5'h18, 5'h19, 5'h1A, 5'h1B, 5'h1C, 5'h1D, 5'h1E, 5'h1F: rb_rdata <= rr[ro[2:0]];
                default: rb_rdata <= 8'd0;     // the strobes read 0
            endcase
        end
    end

    // A register write: one byte, at once (spec 6, section 4.2; a colour's
    // blue and green go into the copper's colour assembly buffer, video.v)
    task do_write(input [9:0] o, input [7:0] d);
        begin
            cw_req  <= 1'b1;
            cw_off  <= o;
            cw_data <= d;
            xs      <= X_GAP;
        end
    endtask

    task stop;
        begin
            xs  <= X_OFF;
            in2 <= 1'b0;
        end
    endtask

    task restart(input [21:1] to);
        begin
            xs     <= X_RUN;
            cw_req <= 1'b0;
            flush  = 1'b1;
            f_to   = to;
        end
    endtask
endmodule
