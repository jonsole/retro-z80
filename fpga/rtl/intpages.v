// Interrupt pages and the NMI's stack capture (spec 2, sections 9.7-9.9;
// design plan, branch 17). retro-z80's own: retro68k has no MMU.
//
// Ticket #27 builds the NMI set only: registers 0x48-0x4F and 0xC0-0xFF of
// I/O page 0x01 (register bus 0x148-0x14F, 0x1C0-0x1FF):
//   NMICTL    EN (0) RW; INNMI (1) read only, 1 from an NMI's entry to its
//             RETN; bits 7-2 read 0
//   NMIMASK   the windows switched on an NMI
//   NMICAPPC  the return address the NMI's two pushes would have written
//             (RW: RETN takes its two stack reads from here)
//   NMICAPSP  the SP the program had at the NMI (read only)
//   NMIPn, NMIPnW, NMISAVn, NMISAVnW  the NMI's pages and the saved pages
// The maskable set (IPCTL, IPMASK, IPDEPTH, IPRESTORE, IPn ... IPSAVnW,
// registers 0x40-0x43 and 0x80-0xBF) is not built yet: those registers do
// not answer (0xFF), and maskable interrupts switch nothing.
//
// The page registers follow the MMU's rule (spec 3, section 3.1): byte 0
// is held, byte 1 commits with the held byte (or the current bits 7-0 if
// byte 0 has not been written since), and a read page commit also sets
// the write page of the same kind. They are kept in distributed RAM
// (section 9.9): the pages and the saved pages are 8 words of 20 bits each
// ({read page, write page} of window n), the held bytes 32 x 8 with a flag
// each in flip-flops. Each RAM has one port, shared by the CPU and the
// copy engine; they never use it in the same clock (section 9.9).
//
// The copy engine moves one window a clock between the MMU (mmu.v's copy
// port) and the RAMs:
//   switch   (nmi_ack while INNMI = 0, with EN): in clock k, window k's
//            pages into the saved pages' word k, and, if window k is in
//            the mask, word k of the NMI pages into window k;
//   restore  (nmi_ret, with EN noted at the entry): in clock k, if window k
//            is in the noted mask, word k of the saved pages into window k.
// The bus interface (bus_if.v) spots the response, the pushes, RETN and its
// stack reads from the core's cycles, and hands the pushed bytes here.
//
// Reset: while rst is held the engine writes the reset values into the two
// page RAMs, one word a clock (rst is held for 512 clocks or more).
`include "regmap.vh"

module intpages (
    input  wire        clk,
    input  wire        rst,

    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [12:0] rb_addr,
    input  wire [7:0]  rb_wdata,
    output reg  [7:0]  rb_rdata,
    output reg         rb_hit,

    // From the bus interface (spec 1, sections 8.2-8.4)
    input  wire        nmi_ack,        // 1 clock: an NMI response M1 seen
    input  wire        nmi_ret,        // 1 clock: RETN's second stack read (with INNMI)
    input  wire        cap_sp_ld,      // the first push: the program's SP
    input  wire [15:0] cap_sp,
    input  wire        cap_pc_ld,      // a pushed byte
    input  wire        cap_pc_hi,      // ... the first push's: PC bits 15-8
    input  wire [7:0]  cap_d,
    output reg         innmi,          // NMICTL.INNMI
    output wire [15:0] cappc,          // NMICAPPC, for RETN's stack reads

    // The MMU's copy port (mmu.v)
    output wire [2:0]  cp_win,
    output wire        cp_ld,
    output wire [9:0]  cp_rp,
    output wire [9:0]  cp_wp,
    input  wire [9:0]  cp_cur_rp,
    input  wire [9:0]  cp_cur_wp
);
    // ---------------------------------------------------------------- registers
    reg        en;                     // NMICTL.EN
    reg [7:0]  mask;                   // NMIMASK
    reg        n_en;                   // EN and the mask, noted at the entry
    reg [7:0]  n_mask;
    reg [15:0] pc_r, sp_r;             // NMICAPPC, NMICAPSP
    assign cappc = pc_r;

    wire [7:0] r      = rb_addr[7:0];
    wire       pg01   = (rb_addr[12:8] == 5'h01);
    wire       s_ctl  = pg01 && (r == 8'h48 || r == 8'h49 || r[7:2] == 6'b010011);  // 0x48, 0x49, 0x4C-0x4F
    wire       s_pg   = pg01 && (r[7:6] == 2'b11);                                 // 0xC0-0xFF
    // Page registers: bit 5 the saved pages, bit 4 the write page, bits 3-1
    // the window, bit 0 the byte
    wire       a_sav  = r[5];
    wire       a_w    = r[4];
    wire [2:0] a_n    = r[3:1];
    wire       a_b1   = r[0];
    wire [4:0] h_i    = r[5:1];        // the held byte's index: {array, window}

    // ---------------------------------------------------------------- the RAMs
    reg [19:0] pg  [0:7];              // NMIPn, NMIPnW
    reg [19:0] sav [0:7];              // NMISAVn, NMISAVnW
    reg [7:0]  held [0:31];
    reg [31:0] hflag;

    reg        cp_on, cp_sw;           // a copy runs; it is the switch
    reg [2:0]  cp_k;
    reg [7:0]  cp_mask;
    reg [2:0]  rcnt = 3'd0;            // the reset fill

    wire [2:0]  ra    = cp_on ? cp_k : rst ? rcnt : a_n;
    wire [19:0] pg_q  = pg[ra];
    wire [19:0] sav_q = sav[ra];

    function [9:0] reset_page(input [2:0] w);
        reset_page = (w == 3'd0) ? 10'h3FC :
                     (w == 3'd1) ? 10'h3FD : {7'd0, w - 3'd2};
    endfunction

    // A CPU commit (byte 1 of a page register): the word with the new page
    wire [19:0] word   = a_sav ? sav_q : pg_q;
    wire [7:0]  cur_lo = a_w ? word[7:0] : word[17:10];
    wire [7:0]  new_lo = hflag[h_i] ? held[h_i] : cur_lo;
    wire [9:0]  newpg  = {rb_wdata[1:0], new_lo};
    wire [19:0] cword  = a_w ? {word[19:10], newpg} : {newpg, newpg};
    wire        commit = rb_wr && s_pg && a_b1 && !cp_on && !rst;

    wire        pg_we  = rst || (commit && !a_sav);
    wire        sav_we = rst || (cp_on && cp_sw) || (commit && a_sav);
    wire [19:0] rst_pg = (rcnt == 3'd0) ? {10'h3FF, 10'h0FF} : {reset_page(rcnt), reset_page(rcnt)};
    wire [19:0] pg_d   = rst ? rst_pg : cword;
    wire [19:0] sav_d  = rst ? {reset_page(rcnt), reset_page(rcnt)} :
                         cp_on ? {cp_cur_rp, cp_cur_wp} : cword;

    always @(posedge clk) begin
        if (pg_we)  pg[ra]  <= pg_d;
        if (sav_we) sav[ra] <= sav_d;
        if (rb_wr && s_pg && !a_b1) held[h_i] <= rb_wdata;
    end

    // ---------------------------------------------------------------- copy engine
    assign cp_win = cp_k;
    assign cp_ld  = cp_on && cp_mask[cp_k];
    assign cp_rp  = cp_sw ? pg_q[19:10] : sav_q[19:10];
    assign cp_wp  = cp_sw ? pg_q[9:0]   : sav_q[9:0];

    always @(posedge clk) begin
        if (rst) begin
            rcnt    <= rcnt + 3'd1;
            cp_on   <= 1'b0;
            cp_sw   <= 1'b0;
            cp_k    <= 3'd0;
            cp_mask <= 8'd0;
            en      <= 1'b1;
            mask    <= 8'h01;
            n_en    <= 1'b0;
            n_mask  <= 8'd0;
            innmi   <= 1'b0;
            pc_r    <= 16'd0;
            sp_r    <= 16'd0;
            hflag   <= 32'd0;
        end else begin
            if (cp_on) begin
                cp_k <= cp_k + 3'd1;
                if (cp_k == 3'd7) cp_on <= 1'b0;
            end
            // The entry: note EN and the mask; switch if EN
            if (nmi_ack && !innmi) begin
                innmi  <= 1'b1;
                n_en   <= en;
                n_mask <= mask;
                if (en) begin
                    cp_on   <= 1'b1;
                    cp_sw   <= 1'b1;
                    cp_k    <= 3'd0;
                    cp_mask <= mask;
                end
            end
            // The return: after RETN's second stack read
            if (nmi_ret && innmi) begin
                innmi <= 1'b0;
                if (n_en) begin
                    cp_on   <= 1'b1;
                    cp_sw   <= 1'b0;
                    cp_k    <= 3'd0;
                    cp_mask <= n_mask;
                end
            end
            // The capture
            if (cap_sp_ld) sp_r <= cap_sp;
            if (cap_pc_ld) begin
                if (cap_pc_hi) pc_r[15:8] <= cap_d;
                else           pc_r[7:0]  <= cap_d;
            end

            if (rb_wr && s_ctl) case (r)
                8'h48: en   <= rb_wdata[`RM_NMICTL_EN];
                8'h49: mask <= rb_wdata;
                8'h4C: pc_r[7:0]  <= rb_wdata;
                8'h4D: pc_r[15:8] <= rb_wdata;
                default: ;                                  // NMICAPSP is read only
            endcase
            if (rb_wr && s_pg) begin
                if (!a_b1) hflag[h_i] <= 1'b1;
                else begin
                    hflag[h_i] <= 1'b0;
                    if (!a_w) hflag[h_i | 5'b01000] <= 1'b0;  // a read page commit: its write page's too
                end
            end
        end

        rb_hit   <= rb_rd && (s_ctl || s_pg);
        rb_rdata <= 8'd0;
        if (rb_rd && s_ctl) case (r)
            8'h48:   rb_rdata <= {6'd0, innmi, en};
            8'h49:   rb_rdata <= mask;
            8'h4C:   rb_rdata <= pc_r[7:0];
            8'h4D:   rb_rdata <= pc_r[15:8];
            8'h4E:   rb_rdata <= sp_r[7:0];
            default: rb_rdata <= sp_r[15:8];
        endcase
        if (rb_rd && s_pg) begin
            if (a_w) rb_rdata <= a_b1 ? {6'd0, word[9:8]}   : word[7:0];
            else     rb_rdata <= a_b1 ? {6'd0, word[19:18]} : word[17:10];
        end
    end
endmodule
