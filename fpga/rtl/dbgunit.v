// Debug unit (spec 18; design plan, branch 18): single step, 4 instruction
// breakpoints and 2 watchpoints, all raising the NMI. A retro-z80 extra:
// retro68k has no debug unit in the FPGA. Registers 0x00-0x3C of I/O page
// 0x02 (register bus 0x200-0x23C). Ticket #28.
//
// It works from the core's cycles as the bus interface (bus_if.v) sees
// them, so tv80 is used unchanged. The bus interface gives the strobes:
//   t1s     the clock that ends at E + 3 of an M-cycle's first T1 (A, the
//           early cycle-type outputs and the MMU's lookup are steady)
//   t2s     the clock that ends at E + 3 of T2 (dout valid for a write)
//   take    the cen edge that ends T2 (the core takes di)
//   take_f  ... of an opcode fetch that is not an NMI response
//   ow_start  the opcode watcher is in START: a fetch starts an instruction
//   retn    RETN's second opcode byte taken, with INNMI 1 or 0
//
// Live (section 3): off at reset, at an NMI's entry (nmi_ack) and on a
// write of 0 to DBGCTL.LIVE; on at the resume M1, the first M1 after a
// RETN's two stack reads. Nothing compares while it is off.
//
// Step (section 4): with DBGCTL.STEP, the resume M1 raises the request:
// at the cen edge that ends its T2 (a fetch), or with int_ack (an
// acknowledge, only with STEPINT). /INT is held high from the write of
// STEP until the step's NMI response, unless STEPINT.
//
// Breakpoints (section 5): compared at t1s of a fetch that starts an
// instruction (not the resume M1, not an acknowledge); bp_nop tells the bus
// interface to put 0x00 at di instead of the byte read. The bits are set
// and the request raised when the core takes the byte (take_f), so an NMI
// response's dummy fetch (its T1 repeats; take_f never comes) sets nothing.
//
// Watchpoints (section 6): compared at t1s of every memory or I/O cycle
// that is not an M1; the request is raised there. The first match since
// DBGSTAT's watchpoint bits were all clear is kept: address and kind at
// t1s, the data at t2s (a write) or take (a read).
`include "regmap.vh"

module dbgunit (
    input  wire        clk,
    input  wire        rst,

    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [12:0] rb_addr,
    input  wire [7:0]  rb_wdata,
    output reg  [7:0]  rb_rdata,
    output reg         rb_hit,

    // The core's cycle, as the bus interface sees it
    input  wire [15:0] A,
    input  wire [7:0]  dout,
    input  wire [7:0]  di,             // the byte at the core's data input
    input  wire        m1,             // mcycle[0]
    input  wire        intcycle_n,
    input  wire        iorq,
    input  wire        no_read,
    input  wire        write,
    input  wire [9:0]  rpage,          // the MMU's read page for A15-A13
    input  wire        t1s,
    input  wire        t2s,
    input  wire        take,
    input  wire        take_f,
    input  wire        ow_start,
    input  wire        retn,
    input  wire        nmi_ack,
    input  wire        int_ack,

    output wire        bp_nop,         // with t1s of a fetch: a breakpoint matches
    output reg         nmi_req,        // 1 clock: ask the controller for an NMI
    output reg         int_hold        // hold the CPU's /INT high
);
    // ---------------------------------------------------------------- registers
    reg        step, stepint, live;
    reg [6:0]  stat;                   // DBGSTAT: STEP (6), WP1-0 (5-4), BP3-0 (3-0)
    reg [15:0] hitaddr;
    reg [7:0]  hitdata;
    reg [2:0]  hitkind;
    reg [15:0] bp_addr [0:3];
    reg [9:0]  bp_page [0:3];
    reg [3:0]  bp_en, bp_pgen;
    reg [15:0] wp_addr [0:1];
    reg [15:0] wp_mask [0:1];
    reg [1:0]  wp_en, wp_rd, wp_wr, wp_io;

    wire       sel  = (rb_addr[12:8] == 5'h02);
    wire [7:0] r    = rb_addr[7:0];
    // 0x10-0x2F and 0x30-0x3F, offsets 0-4 of each 8 (5-7 reserved)
    wire       s_bp = sel && r[7:6] == 2'b00 && (r[5:4] == 2'b01 || r[5:4] == 2'b10) && r[2:0] <= 3'd4;
    wire       s_wp = sel && r[7:4] == 4'h3 && r[2:0] <= 3'd4;
    wire [2:0] bp_k = r[5:3] - 3'd2;   // 0x10: 0, 0x18: 1, 0x20: 2, 0x28: 3
    wire [1:0] bp_n = bp_k[1:0];
    wire       wp_n = r[3];

    // ---------------------------------------------------------------- live and the resume M1
    reg [1:0]  rcnt;                   // RETN's stack reads still to come
    reg        rpend;                  // the next M1 is the resume M1
    reg        res_f, res_a;           // this M1 is the resume M1: a fetch, an acknowledge
    reg        swait;                  // the step NMI is asked for, its response not yet seen

    wire is_fetch = m1 && intcycle_n;
    wire is_ack   = m1 && !intcycle_n;
    wire c_rd     = !m1 && !write && !no_read;      // a memory or I/O read
    wire c_wr     = !m1 && write;

    // ---------------------------------------------------------------- compares
    wire [3:0] bp_m;
    wire [1:0] wp_m;
    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : bpc
            assign bp_m[g] = bp_en[g] && A == bp_addr[g] && (!bp_pgen[g] || rpage == bp_page[g]);
        end
        for (g = 0; g < 2; g = g + 1) begin : wpc
            assign wp_m[g] = wp_en[g] && (wp_io[g] == iorq) && ((c_rd && wp_rd[g]) || (c_wr && wp_wr[g]))
                             && ((A ^ wp_addr[g]) & wp_mask[g]) == 16'd0;
        end
    endgenerate
    wire bp_ok = live && !rpend && is_fetch && ow_start;
    assign bp_nop = bp_ok && (bp_m != 4'd0);
    wire [1:0] wp_hit = (live && t1s) ? wp_m : 2'b00;

    reg  [3:0] bp_hit;                 // breakpoints matched by this fetch
    reg        kpend, kwr;             // the kept access's data still to come; a write

    always @(posedge clk) begin
        nmi_req <= 1'b0;
        if (rst) begin
            step    <= 1'b0;
            stepint <= 1'b0;
            live    <= 1'b0;
            stat    <= 7'd0;
            hitaddr <= 16'd0;
            hitdata <= 8'd0;
            hitkind <= 3'd0;
            bp_en   <= 4'd0;
            bp_pgen <= 4'd0;
            wp_en   <= 2'd0;
            wp_rd   <= 2'd0;
            wp_wr   <= 2'd0;
            wp_io   <= 2'd0;
            bp_addr[0] <= 16'd0; bp_addr[1] <= 16'd0; bp_addr[2] <= 16'd0; bp_addr[3] <= 16'd0;
            bp_page[0] <= 10'd0; bp_page[1] <= 10'd0; bp_page[2] <= 10'd0; bp_page[3] <= 10'd0;
            wp_addr[0] <= 16'd0; wp_addr[1] <= 16'd0;
            wp_mask[0] <= 16'hFFFF; wp_mask[1] <= 16'hFFFF;
            rcnt    <= 2'd0;
            rpend   <= 1'b0;
            res_f   <= 1'b0;
            res_a   <= 1'b0;
            swait   <= 1'b0;
            bp_hit  <= 4'd0;
            kpend   <= 1'b0;
            kwr     <= 1'b0;
            int_hold <= 1'b0;
        end else begin
            // ---- registers (the CPU's writes first: the unit's own events win)
            if (rb_wr && sel) begin
                if (r == 8'h00) begin
                    step    <= rb_wdata[`RM_DBGCTL_STEP];
                    stepint <= rb_wdata[`RM_DBGCTL_STEPINT];
                    if (!rb_wdata[`RM_DBGCTL_LIVE]) live <= 1'b0;
                end
                if (r == 8'h01) stat <= stat & ~rb_wdata[6:0];
                if (s_bp) case (r[2:0])
                    3'd0: bp_addr[bp_n][7:0]  <= rb_wdata;
                    3'd1: bp_addr[bp_n][15:8] <= rb_wdata;
                    3'd2: bp_page[bp_n][7:0]  <= rb_wdata;
                    3'd3: bp_page[bp_n][9:8]  <= rb_wdata[1:0];
                    default: begin
                        bp_en[bp_n]   <= rb_wdata[`RM_DBGBP_CTL_EN];
                        bp_pgen[bp_n] <= rb_wdata[`RM_DBGBP_CTL_PAGEEN];
                    end
                endcase
                if (s_wp) case (r[2:0])
                    3'd0: wp_addr[wp_n][7:0]  <= rb_wdata;
                    3'd1: wp_addr[wp_n][15:8] <= rb_wdata;
                    3'd2: wp_mask[wp_n][7:0]  <= rb_wdata;
                    3'd3: wp_mask[wp_n][15:8] <= rb_wdata;
                    default: begin
                        wp_en[wp_n] <= rb_wdata[`RM_DBGWP_CTL_EN];
                        wp_rd[wp_n] <= rb_wdata[`RM_DBGWP_CTL_READ];
                        wp_wr[wp_n] <= rb_wdata[`RM_DBGWP_CTL_WRITE];
                        wp_io[wp_n] <= rb_wdata[`RM_DBGWP_CTL_IO];
                    end
                endcase
            end

            // ---- live: RETN, its two stack reads, the resume M1
            if (retn) rcnt <= 2'd2;
            if (t1s) begin
                res_f <= 1'b0;
                if (!m1 && c_rd && !iorq && rcnt != 2'd0) begin
                    rcnt <= rcnt - 2'd1;
                    if (rcnt == 2'd1) rpend <= 1'b1;
                end
                if (m1 && rpend) begin
                    rpend <= 1'b0;
                    live  <= 1'b1;
                    res_f <= is_fetch;
                    res_a <= is_ack;
                end
                bp_hit <= (is_fetch && bp_ok) ? bp_m : 4'd0;
            end
            if (nmi_ack) begin
                live  <= 1'b0;
                swait <= 1'b0;
            end

            // ---- step
            if ((take_f && res_f || int_ack && res_a) && step) begin
                stat[6] <= 1'b1;
                step    <= 1'b0;
                swait   <= 1'b1;
                nmi_req <= 1'b1;
            end
            if (int_ack) res_a <= 1'b0;

            // ---- breakpoints: when the core takes the NOP
            if (take_f && bp_hit != 4'd0) begin
                stat[3:0] <= stat[3:0] | bp_hit;
                nmi_req   <= 1'b1;
            end

            // ---- watchpoints, and the kept access
            if (wp_hit != 2'b00) begin
                stat[5:4] <= stat[5:4] | wp_hit;
                nmi_req   <= 1'b1;
                if (stat[5:4] == 2'b00) begin
                    hitaddr <= A;
                    hitkind <= {!wp_hit[0], iorq, c_wr};
                    kpend   <= 1'b1;
                    kwr     <= c_wr;
                end
            end
            if (kpend && kwr && t2s)   begin hitdata <= dout; kpend <= 1'b0; end
            if (kpend && !kwr && take) begin hitdata <= di;   kpend <= 1'b0; end

            int_hold <= !stepint && (step || swait);
        end

        // ---- reads
        rb_hit   <= rb_rd && (sel && r <= 8'h05 || s_bp || s_wp);
        rb_rdata <= 8'd0;
        if (rb_rd && sel) begin
            case (r)
                8'h00: rb_rdata <= {live, 5'd0, stepint, step};
                8'h01: rb_rdata <= {1'b0, stat};
                8'h02: rb_rdata <= hitaddr[7:0];
                8'h03: rb_rdata <= hitaddr[15:8];
                8'h04: rb_rdata <= hitdata;
                8'h05: rb_rdata <= {5'd0, hitkind};
                default: ;
            endcase
            if (s_bp) case (r[2:0])
                3'd0: rb_rdata <= bp_addr[bp_n][7:0];
                3'd1: rb_rdata <= bp_addr[bp_n][15:8];
                3'd2: rb_rdata <= bp_page[bp_n][7:0];
                3'd3: rb_rdata <= {6'd0, bp_page[bp_n][9:8]};
                default: rb_rdata <= {6'd0, bp_pgen[bp_n], bp_en[bp_n]};
            endcase
            if (s_wp) case (r[2:0])
                3'd0: rb_rdata <= wp_addr[wp_n][7:0];
                3'd1: rb_rdata <= wp_addr[wp_n][15:8];
                3'd2: rb_rdata <= wp_mask[wp_n][7:0];
                3'd3: rb_rdata <= wp_mask[wp_n][15:8];
                default: rb_rdata <= {4'd0, wp_io[wp_n], wp_wr[wp_n], wp_rd[wp_n], wp_en[wp_n]};
            endcase
        end
    end
endmodule
