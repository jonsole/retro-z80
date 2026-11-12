// Copper (spec 6): runs a list of 16-bit instruction words from SRAM every
// frame and writes custom registers at chosen beam positions. retro68k's
// copper.v, narrowed to 8-bit data (ticket #32). The engine (the fetch, the
// buffer, running, WAIT, jumps, the stack, the starts, the frame restart
// and RESUME) is retro-hw's copper_engine.v; this file is the wrapper: the
// registers, the decoder and the ALU.
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
// COPSTAT.ERR. SKIP and SKIPC decide only once the first word of the next
// instruction is in the buffer (a SKIP fetches a third word for it), so the
// length of what they skip is known: a skip is a jump past it, at once, and
// RESUME can never save a place inside it.
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
// that skips jumps past the next instruction, whose length it reads from
// that instruction's first word (one more word in the buffer), in place of
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
    input  wire        blt_idle,       // the blitter and rasteriser have nothing to do

    output wire        irq             // source COPPER (2)
);
    // ================================================================ registers
    reg  [5:0]  copcon;                // PRI (5:4), STKKEEP (3), RESUME (2), IRQEN (1), EN (0)
    reg  [21:1] lc1, lc2;
    reg         st_err, st_irq;
    reg  [7:0]  rx, ry;
    reg  [2:0]  rf;                    // C (2), N (1), Z (0)
    reg  [7:0]  rr [0:7];

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

    // ================================================================ engine
    // retro-hw's copper engine (copper_engine.v) does the fetch, the buffer,
    // running each instruction, WAIT and SKIP on the beam, the jumps and the
    // stack, the strobes' starts, the frame restart, RESUME and STKKEEP. This
    // file decodes the words for it and keeps the registers and the ALU.
    localparam [3:0] OP_NEXT = 4'd0, OP_WRITE = 4'd1, OP_WAIT = 4'd2, OP_SKIP = 4'd3,
                     OP_SKIPC = 4'd4, OP_JUMP = 4'd5, OP_CALL = 4'd6, OP_RET = 4'd7,
                     OP_STOP = 4'd8, OP_ERR = 4'd9, OP_MORE = 4'd10;

    wire [15:0] b0, b1, b2;            // the engine's buffer
    reg  [1:0]  need, len;
    wire [1:0]  skip_len;
    reg  [3:0]  op;
    wire        exec, more, error, save2, e_stopped, e_waiting, e_wreq, e_mreq;
    wire [21:1] save2_at, e_pc, e_maddr;
    wire [3:0]  sp;

    wire [7:0]  code = b0[15:8];
    wire [7:0]  lo   = b0[7:0];
    wire        ext  = (code[7:4] == 4'hF);

    copper_engine #(.AW(21), .VTOT(11'd625), .HTOT(11'd864), .WR_HANDSHAKE(0)) eng (
        .clk(clk), .rst(rst),
        .run(en), .frame(vblank), .start1(s_jmp1), .start2(s_jmp2),
        .list1(lc1), .list2(lc2),
        .resume(copcon[2]), .stack_keep(copcon[3]), .stack_clear(s_sp),
        .save2(save2), .save2_at(save2_at),
        .word0(b0), .word1(b1), .word2(b2),
        .need(need), .len(len), .skip_len(skip_len), .op(op),
        .target({lo[5:0], b1[15:1]}),
        .pos_line({1'b0, lo[3:2], b1[15:8]}), .pos_px({1'b0, lo[1:0], b1[7:0]}),
        .pos_rel(lo[7]), .wait_blt(lo[6]),
        .cc(lo[3:0]), .flags(rf),
        .exec(exec), .more(more), .error(error),
        .wr_req(e_wreq), .wr_go(1'b1),
        .stopped(e_stopped), .waiting(e_waiting), .pc(e_pc), .sp(sp),
        .mem_req(e_mreq), .mem_addr(e_maddr),
        .mem_ack(mem_ack), .mem_rvalid(mem_rvalid), .mem_rdata(mem_rdata),
        .beam_v(beam_v), .beam_h(beam_h), .blt_idle(blt_idle)
    );
    always @(*) begin
        cw_req   = e_wreq;
        mem_req  = e_mreq;
        mem_addr = e_maddr;
    end

    // ---------------------------------------------------------------- decode
    // Two-word instructions: WAIT, SKIP, JUMP, MOVEF, ALU with a value, CALL
    function is_two(input [15:0] w);
        is_two = (w[15:12] == 4'hF) && (w[11:8] == 4'h0 || w[11:8] == 4'h1 || w[11:8] == 4'h2 ||
                 w[11:8] == 4'hC || (w[11:8] == 4'h9 && w[3:0] == 4'd10) ||
                 (w[11:8] == 4'hB && !w[7]));
    endfunction
    wire        two    = is_two(b0);
    wire        i_skip = (code == 8'hF1);              // SKIP: needs a third word
    wire        i_skc  = (code == 8'hFA);              // SKIPC: needs a second
    // The next instruction's length, for a SKIP or SKIPC that skips it
    assign skip_len = is_two(i_skip ? b2 : b1) ? 2'd2 : 2'd1;

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

    // What the instruction does, and a register write's offset and data
    reg [9:0] w_off;
    reg [7:0] w_data;
    always @(*) begin
        need   = i_skip ? 2'd3 : (two || i_skc) ? 2'd2 : 2'd1;
        len    = two ? 2'd2 : 2'd1;
        w_off  = {2'b00, code};                                          // MOVE
        w_data = lo;
        if (!ext)     op = OP_WRITE;
        else if (bad) op = OP_ERR;
        else case (code[3:0])
            4'h0: op = (!lo[7] && lo[3:2] == 2'd3 && b1[15:8] == 8'hFF)  // WAIT for line 1023:
                       ? OP_STOP : OP_WAIT;                              // the end of the list
            4'h1: op = OP_SKIP;
            4'h2: op = OP_JUMP;
            4'h3: op = OP_STOP;
            4'h4, 4'h5: begin op = OP_WRITE; w_off = {2'b00, rx}; end        // MOVR (X) = value
            4'h6: begin op = OP_WRITE; w_off = {2'b00, lo}; w_data = rx; end // MOVR reg = X
            4'h7: begin op = OP_WRITE; w_off = {2'b00, lo}; w_data = ry; end // MOVR reg = Y
            4'h8: begin                                                      // MOVR (X) = Y or X
                op = OP_WRITE; w_off = {2'b00, rx}; w_data = lo[0] ? rx : ry;
            end
            4'h9: op = OP_MORE;                                              // ALU
            4'hA: op = OP_SKIPC;
            4'hB: op = lo[7] ? OP_RET : OP_CALL;
            4'hC: begin                                                      // MOVEF
                op = OP_WRITE; w_off = {lo[1:0], b1[15:8]}; w_data = b1[7:0];
            end
            default: op = OP_ERR;
        endcase
    end

    // The ALU, one clock after decode
    reg  [7:0]  a_op, a_val;

    // ---------------------------------------------------------------- main
    integer i;

    always @(posedge clk) begin
        if (rst) begin
            copcon <= 6'd0;
            lc1 <= 21'd0; lc2 <= 21'd0;
            st_err <= 1'b0; st_irq <= 1'b0;
            rx <= 8'd0; ry <= 8'd0; rf <= 3'd0;
            for (i = 0; i < 8; i = i + 1) rr[i] <= 8'd0;
        end else begin
            // ---- the instruction the engine runs
            if (exec) begin
                if (op == OP_WRITE) begin
                    cw_off  <= w_off;
                    cw_data <= w_data;
                end
                // MOVR (X) = value, X + 1; MOVR (X) = Y or X with the step
                if (ext && !bad && (code[3:0] == 4'h5 || (code[3:0] == 4'h8 && lo[1])))
                    rx <= rx + 8'd1;
                if (op == OP_MORE) begin
                    a_op  <= lo;
                    a_val <= b1[7:0];
                end
            end
            if (error) st_err <= 1'b1;

            if (more) begin : alu
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
            end

            // ---- RESUME: list 2's place, at the frame restart
            if (save2) lc2 <= save2_at;

            // ---- register writes (after the instructions: the bus wins)
            if (s_int) st_irq <= 1'b1;
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
    wire [21:0] pc_now = {e_pc, 1'b0};       // stopped: the STOP
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
                5'h0D: rb_rdata <= {4'd0, st_irq, st_err, e_stopped, e_waiting};
                5'h0E: rb_rdata <= rx;
                5'h0F: rb_rdata <= ry;
                5'h10: rb_rdata <= {5'd0, rf};
                5'h11: rb_rdata <= {4'd0, sp};
                5'h18, 5'h19, 5'h1A, 5'h1B, 5'h1C, 5'h1D, 5'h1E, 5'h1F: rb_rdata <= rr[ro[2:0]];
                default: rb_rdata <= 8'd0;     // the strobes read 0
            endcase
        end
    end

endmodule
