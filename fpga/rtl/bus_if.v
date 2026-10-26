// CPU bus interface (spec 1, sections 4-6): turns the Z80's memory and I/O
// cycles into requests on the chipset buses, so that the Z80 never waits.
//
// Memory (spec 1, section 5). The core's address and early cycle-type
// outputs are looked at 3 clocks after the cen edge that starts T1 (E + 3),
// the MMU gives the page, and the access goes where the page says:
//   SRAM     a request to the scheduler, standing from E + 3; the scheduler
//            gives the CPU the first of cycles 0 and 2 that comes (E + 4 or
//            E + 5 at 20 MHz), and its data comes back 4 clocks later
//   boot ROM the block RAM answers in one clock; no SRAM cycle
//   REGS     the register page (spec 1, section 5.7): one register bus
//            strobe the clock after rd_n or wr_n goes low, at A12-A0, as
//            for I/O; an opcode fetch reads 0xFF (RST 38h) with no strobe
//   others   (NONE, reserved) 0xFF
// The page is looked up in T1, from the read page for a fetch or read and
// the write page for a write, and kept for the access (spec 1, section 5.2),
// so a write that changes its own window's page goes where it was aimed.
// A write is posted 3 clocks after the cen edge that starts T2, when dout
// is valid. The byte read is held at di until the next read, so the core
// can take it at the end of T2 whatever the speed.
//
// I/O (spec 1, section 6): one register bus strobe the clock after iorq_n
// goes low with rd_n or wr_n, at the address of section 6.1's decode; read
// data (or 0xFF if no unit answered, or for a reserved page) is held at di.
//
// Interrupt acknowledge (spec 1, section 8.1): in the first T1 of the
// acknowledge cycle, at E + 3, vreq asks the interrupt controller for the
// vector; the controller chooses at that edge, and its vector is held at di
// from E + 4. tv80 makes the acknowledge's wait states by repeating T1, so
// the T1 actions must not run again in the repeats (open point B11): only a
// T1 after some other T-state asks. One int_ack pulse follows when the
// acknowledge's M1 ends.
//
// The CPU's capture (spec 3, rule 4), as retro68k's rh_valid, rh_tag and
// rh_data: a read of a capturing register's low byte comes with the whole
// value (rb_cdata, rb_cap), which is kept here tagged with that register.
// A read of a higher byte of the tagged register is answered from it,
// however late; any other read gets the unit's live byte. Both paths, ports
// and the register page, share it. Ticket #17.
//
// The NMI (spec 1, sections 8.2-8.4; ticket #27), from the core's cycles,
// with tv80 unchanged:
//   - the response: the only opcode fetch that repeats its T1 (tv80's
//     automatic wait, with intcycle_n high). At E + 3 of the second T1,
//     nmi_ack ends the controller's request and starts the switch in
//     intpages.v (while INNMI is 0). Only the first T1 of an M-cycle starts
//     a read, so the repeats ask for nothing;
//   - the stack capture: after a response taken with INNMI = 0, the next
//     two memory writes are the pushes. They make no request (no SRAM
//     cycle, ROM write or register page strobe); the first one's address
//     + 1 goes to NMICAPSP, and each byte to NMICAPPC, high byte first;
//   - the return: an opcode watcher follows the bytes the core takes in its
//     fetches (prefixes DD, FD, CB, ED; section 8.4) to find RETN (ED 45).
//     With INNMI = 1, the next two memory reads make no request: NMICAPPC's
//     low and then high byte are put at di. After the second, nmi_ret
//     restores the pages and ends INNMI.
//
// The debug unit (spec 18; dbgunit.v; ticket #28) gets the cycle's strobes
// from here (dbg_t1s, dbg_t2s, dbg_take, dbg_take_f), the opcode watcher's
// START and every RETN (with INNMI 1 or 0). When it says a breakpoint
// matches the fetch at E + 3 (dbg_bp), the byte read is replaced by 0x00
// at di: the core runs a NOP, and takes the NMI after it (section 5.2).
// I/O page 0x02 is its register page (register bus 0x200-0x2FF).
//
// The register bus (spec 1, section 4.2): the copper goes first. When the
// copper writes (cw_busy) in the clock the CPU's strobe is due, the strobe
// moves one clock later; the copper never writes two clocks running, so the
// next clock is free. rb_addr, rb_hi and rb_wdata are held until the next
// strobe, so they are still right. Ticket #32.
`include "regmap.vh"

module bus_if (
    input  wire        clk,
    input  wire        rst,            // with the core's reset
    input  wire        cen,            // the core's clock enable (a T-state per pulse)

    // The core (z80_cpu.v)
    input  wire [15:0] A,
    input  wire [7:0]  dout,
    input  wire [6:0]  mcycle,
    input  wire [6:0]  tstate,
    input  wire        iorq,
    input  wire        no_read,
    input  wire        write,
    input  wire        intcycle_n,
    input  wire        m1_n,
    input  wire        iorq_n,
    input  wire        rd_n,
    input  wire        wr_n,
    output reg  [7:0]  di,

    // MMU (mmu.v): the window and its pages
    output wire [2:0]  mmu_win,
    input  wire [9:0]  mmu_rpage,
    input  wire [9:0]  mmu_wpage,

    // Scheduler (dmac.v), CPU channel
    output reg         cpu_req,
    output reg         cpu_we,
    output reg  [21:1] cpu_addr,
    output reg  [15:0] cpu_wdata,
    output reg  [1:0]  cpu_be,
    input  wire        cpu_ack,
    input  wire        cpu_rvalid,
    input  wire [15:0] mem_rdata,

    // Boot ROM (bootrom.v)
    input  wire        romwe,          // SYSCON.ROMWE
    output reg         rom_en,
    output reg  [1:0]  rom_we,
    output reg  [14:1] rom_addr,
    output reg  [15:0] rom_wdata,
    input  wire [15:0] rom_rdata,

    // Register bus (spec 1, section 4.2), CPU as master
    output reg  [12:0] rb_addr,
    output reg  [7:0]  rb_hi,
    output wire        rb_rd,
    output wire        rb_wr,
    output reg  [7:0]  rb_wdata,
    input  wire [7:0]  rb_rdata,
    input  wire        rb_hit,
    input  wire [31:0] rb_cdata,       // with rb_rdata: a capturing register's whole value
    input  wire        rb_cap,         // ... and that rb_cdata holds one
    input  wire        cw_busy,        // the copper has the register bus this clock

    // Interrupt controller (intc.v)
    output wire        int_vreq,       // 1 clock at E + 3 of an acknowledge's first T1
    input  wire [7:0]  int_vec,        // the vector, from the clock after int_vreq
    output reg         int_ack,        // 1 clock: the acknowledge's M1 has ended

    // The NMI (intc.v, intpages.v)
    input  wire        innmi,          // NMICTL.INNMI
    input  wire [15:0] cappc,          // NMICAPPC
    output reg         nmi_ack,        // 1 clock: the NMI response's M1 seen
    output reg         nmi_ret,        // 1 clock: RETN's second stack read, from the capture
    output reg         cap_sp_ld,      // 1 clock: the first push; cap_sp = the program's SP
    output reg  [15:0] cap_sp,
    output reg         cap_pc_ld,      // 1 clock: a pushed byte at nmi_pd
    output reg         cap_pc_hi,      // ... the first push's (PC bits 15-8)
    output reg  [7:0]  nmi_pd,

    // The debug unit (dbgunit.v)
    output wire        dbg_t1s,        // E + 3 of an M-cycle's first T1
    output wire        dbg_t2s,        // E + 3 of T2
    output wire        dbg_take,       // the cen edge that ends T2
    output wire        dbg_take_f,     // ... of a fetch that is not an NMI response
    output wire        dbg_ow_start,   // the opcode watcher is in START
    output reg         dbg_retn,       // 1 clock: RETN's second byte taken
    input  wire        dbg_bp,         // with dbg_t1s of a fetch: a breakpoint matches

    // Checks: the core took a byte before it was at di (never, if the
    // timing of spec 1, section 5 holds)
    output reg         late
);
    // ---------------------------------------------------------------- timing
    // Clocks since the last cen edge: 0 in the clock just after it
    reg [2:0] tc;
    always @(posedge clk)
        if (cen)              tc <= 3'd0;
        else if (tc != 3'd7)  tc <= tc + 3'd1;
    wire at3 = (tc == 3'd2);           // the clock that ends at E + 3

    // A T1 that follows some other T-state starts an M-cycle; a repeated T1
    // (the wait states of an I/O cycle or an acknowledge) does not
    reg  was_t1;                       // the T-state before this one was a T1
    always @(posedge clk)
        if (rst)      was_t1 <= 1'b0;
        else if (at3) was_t1 <= tstate[1];
    wire first_t1 = tstate[1] && !was_t1;

    // ---------------------------------------------------------------- memory
    wire is_fetch = mcycle[0] && intcycle_n;
    wire is_ack   = mcycle[0] && !intcycle_n;
    wire is_read  = !mcycle[0] && !iorq && !no_read && !write;
    wire is_write = !mcycle[0] && !iorq && write;

    assign mmu_win = A[15:13];
    wire [9:0] page     = is_write ? mmu_wpage : mmu_rpage;
    wire       pg_sram  = !page[9];                     // 0x000-0x1FF
    wire       pg_rom   = (page[9:2] == 8'hFF);         // 0x3FC-0x3FF
    wire       pg_regs  = (page == 10'h3F8);            // REGS
    reg  [9:0] apage;                  // the page of this access, from T1
    wire       ap_sram  = !apage[9];
    wire       ap_rom   = (apage[9:2] == 8'hFF);
    wire       ap_regs  = (apage == 10'h3F8);

    reg        rd_wait;                // a read waits for its byte
    reg        rd_hi;                  // ... and wants the odd byte (A0)
    reg        rom_rd;                 // the boot ROM answers in this clock
    reg        io_rd_d;                // an I/O read strobe was sent last clock
    reg        io_none;                // an I/O read of a reserved page
    reg        vreq_d;                 // the vector was asked for last clock
    reg        in_ack;                 // between the vector request and int_ack

    // The capture (spec 3, rule 4)
    reg        cap_valid;
    reg [12:0] cap_tag;                // the low byte's bus address
    reg [2:0]  cap_n;                  // the register's width in bytes
    reg [31:0] cap_data;
    wire [12:0] cap_d   = rb_addr - cap_tag;
    wire        cap_hit = cap_valid && cap_d != 13'd0 && cap_d < {10'd0, cap_n};
    wire [7:0]  cap_byte = cap_data[8 * cap_d[1:0] +: 8];

    assign int_vreq = at3 && first_t1 && is_ack;

    // The NMI: the response, the captured pushes, the opcode watcher and
    // RETN's stack reads from the capture
    reg        m1_rep;                 // this M1 has repeated its T1
    reg [1:0]  push_n;                 // pushes still to be captured
    reg        cap_cyc;                // this M-cycle is a captured push
    reg        pop_cyc;                // ... a stack read from the capture
    reg [1:0]  pop_n;                  // RETN's stack reads still to come
    reg [1:0]  ow;                     // the opcode watcher
    localparam [1:0] OW_START = 2'd0, OW_XY = 2'd1, OW_CB = 2'd2, OW_ED = 2'd3;
    wire nmi_resp = at3 && tstate[1] && was_t1 && is_fetch && !m1_rep;
    wire pop      = at3 && first_t1 && is_read && pop_n != 2'd0;
    wire take_f   = cen && tstate[2] && is_fetch && !m1_rep;
    reg  bp_nop;                       // this fetch's byte is replaced by 0x00

    assign dbg_t1s      = at3 && first_t1;
    assign dbg_t2s      = at3 && tstate[2];
    assign dbg_take     = cen && tstate[2];
    assign dbg_take_f   = take_f;
    assign dbg_ow_start = (ow == OW_START);

    always @(posedge clk) begin
        rom_en <= 1'b0;
        rom_we <= 2'b00;
        rom_rd <= rom_en && rom_we == 2'b00;
        late   <= 1'b0;
        vreq_d <= int_vreq;
        int_ack <= 1'b0;
        nmi_ack   <= 1'b0;
        nmi_ret   <= 1'b0;
        cap_sp_ld <= 1'b0;
        cap_pc_ld <= 1'b0;
        dbg_retn  <= 1'b0;
        if (rst) begin
            m1_rep  <= 1'b0;
            push_n  <= 2'd0;
            cap_cyc <= 1'b0;
            pop_cyc <= 1'b0;
            pop_n   <= 2'd0;
            ow      <= OW_START;
            bp_nop  <= 1'b0;
            cpu_req <= 1'b0;
            cpu_we  <= 1'b0;
            rd_wait <= 1'b0;
            io_rd_d <= 1'b0;
            in_ack  <= 1'b0;
            cap_valid <= 1'b0;
            di      <= 8'hFF;
        end else begin
            if (cpu_ack) cpu_req <= 1'b0;

            if (at3 && tstate[1]) apage <= page;

            // The NMI response, and the two pushes after it
            if (at3 && first_t1) begin
                m1_rep  <= 1'b0;
                cap_cyc <= is_write && push_n != 2'd0;
                pop_cyc <= pop;
                if (is_write && push_n == 2'd2) begin
                    cap_sp_ld <= 1'b1;
                    cap_sp    <= A + 16'd1;
                end
                if (is_ack) ow <= OW_START;
            end
            if (nmi_resp) begin
                m1_rep  <= 1'b1;
                nmi_ack <= 1'b1;
                ow      <= OW_START;
                if (!innmi) push_n <= 2'd2;
            end
            if (at3 && tstate[2] && is_write && cap_cyc) begin
                cap_pc_ld <= 1'b1;
                cap_pc_hi <= (push_n == 2'd2);
                nmi_pd    <= dout;
                push_n    <= push_n - 2'd1;
            end
            // RETN's stack reads, from the capture: no request
            if (pop) begin
                di    <= (pop_n == 2'd2) ? cappc[7:0] : cappc[15:8];
                pop_n <= pop_n - 2'd1;
                if (pop_n == 2'd1) nmi_ret <= 1'b1;
            end
            // The opcode watcher, as the core takes each fetched byte
            if (take_f) case (ow)
                OW_CB: ow <= OW_START;
                OW_ED: begin
                    ow <= OW_START;
                    if (di == 8'h45 && innmi) pop_n <= 2'd2;    // RETN
                    if (di == 8'h45) dbg_retn <= 1'b1;
                end
                default:
                    if (di == 8'hDD || di == 8'hFD) ow <= OW_XY;
                    else if (di == 8'hCB)           ow <= (ow == OW_XY) ? OW_START : OW_CB;
                    else if (di == 8'hED)           ow <= OW_ED;
                    else                            ow <= OW_START;
            endcase

            if (at3 && first_t1 && (is_fetch || is_read) && !pop) begin
                rd_hi  <= A[0];
                bp_nop <= is_fetch && dbg_bp;
                if (pg_sram) begin
                    cpu_req  <= 1'b1;
                    cpu_we   <= 1'b0;
                    cpu_addr <= {page[8:0], A[12:1]};
                    cpu_be   <= 2'b11;
                    rd_wait  <= 1'b1;
                end else if (pg_rom) begin
                    rom_en   <= 1'b1;
                    rom_addr <= {page[1:0], A[12:1]};
                    rd_wait  <= 1'b1;
                end else if (pg_regs && is_read)
                    rd_wait  <= 1'b1;                   // a register bus read, at T2
                else
                    di <= (is_fetch && dbg_bp) ? 8'h00 : 8'hFF;   // NONE, reserved; a fetch from REGS
            end
            // The acknowledge: the vector at di from E + 4; int_ack once
            // the M1 is over (the core has taken the byte at the end of T2)
            if (vreq_d) di <= int_vec;
            if (int_vreq) in_ack <= 1'b1;
            else if (in_ack && !is_ack) begin
                in_ack  <= 1'b0;
                int_ack <= 1'b1;
            end

            if (at3 && tstate[2] && is_write && !cap_cyc) begin
                if (ap_sram) begin
                    cpu_req   <= 1'b1;
                    cpu_we    <= 1'b1;
                    cpu_addr  <= {apage[8:0], A[12:1]};
                    cpu_be    <= A[0] ? 2'b10 : 2'b01;
                    cpu_wdata <= {dout, dout};
                end else if (ap_rom && romwe) begin
                    rom_en    <= 1'b1;
                    rom_we    <= A[0] ? 2'b10 : 2'b01;
                    rom_addr  <= {apage[1:0], A[12:1]};
                    rom_wdata <= {dout, dout};
                end
            end

            if (cpu_rvalid && rd_wait) begin
                di      <= bp_nop ? 8'h00 : rd_hi ? mem_rdata[15:8] : mem_rdata[7:0];
                rd_wait <= 1'b0;
            end
            if (rom_rd && rd_wait) begin
                di      <= bp_nop ? 8'h00 : rd_hi ? rom_rdata[15:8] : rom_rdata[7:0];
                rd_wait <= 1'b0;
            end

            // The core takes a read's byte at the cen edge that ends T2
            if (cen && tstate[2] && (is_fetch || is_read) && rd_wait)
                late <= 1'b1;

            // I/O and register page read data, the clock after the strobe
            if (rb_rd) io_rd_d <= 1'b1;
            if (io_rd_d) begin
                di      <= cap_hit ? cap_byte : rb_hit ? rb_rdata : 8'hFF;
                if (rb_cap) begin
                    cap_valid <= 1'b1;
                    cap_tag   <= rb_addr;
                    cap_n     <= `RM_CAP_N(rb_addr);
                    cap_data  <= rb_cdata;
                end
                io_rd_d <= 1'b0;
                rd_wait <= 1'b0;
            end
            if (io_none) di <= 8'hFF;
        end
    end

    // ---------------------------------------------------------------- I/O
    // Port = register (A15-A8) : page (A7-A0), decoded as spec 1, section 6.1
    wire [7:0] lo = A[7:0];
    wire [7:0] hi = A[15:8];
    wire       p_low    = `RM_IS_LOWPORT(lo);           // 0x1F, 0x53, 0x5B, 0x62, 0xFE
    wire       p_sys    = (lo == 8'h00);
    wire       p_custom = (lo[7:2] == 6'b000100);       // 0x10-0x13
    wire       p_ip     = (lo == 8'h01) && (hi[7:6] != 2'b00);  // page 0x01, registers 0x40-0xFF
    wire       p_dbg    = (lo == 8'h02);                         // page 0x02, the debug unit
    wire [12:0] io_addr = p_low    ? {5'd0, lo} :
                          p_sys    ? {5'd0, hi} :
                          p_ip     ? {5'd1, hi} :
                          p_dbg    ? {5'd2, hi} :
                                     {3'b100, lo[1:0], hi};
    wire       io_strobe = !iorq_n && m1_n && (!rd_n || !wr_n);
    // A memory read or write (not a fetch) whose page is REGS; never a
    // captured push or a stack read from the capture
    wire       rp_strobe = iorq_n && m1_n && (!rd_n || !wr_n) && ap_regs && !cap_cyc && !pop_cyc;

    reg io_seen;                       // this I/O cycle has had its strobe
    reg q_rd, q_wr;                    // the strobe, due this clock
    reg d_rd, d_wr;                    // ... moved on a clock by a copper write
    assign rb_rd = (q_rd && !cw_busy) || d_rd;
    assign rb_wr = (q_wr && !cw_busy) || d_wr;
    always @(posedge clk) begin
        q_rd    <= 1'b0;
        q_wr    <= 1'b0;
        d_rd    <= q_rd && cw_busy;
        d_wr    <= q_wr && cw_busy;
        io_none <= 1'b0;
        if (rst) begin
            d_rd    <= 1'b0;
            d_wr    <= 1'b0;
            io_seen <= 1'b0;
            rb_addr <= 13'd0;
            rb_hi   <= 8'd0;
        end else if (!io_strobe && !rp_strobe) begin
            io_seen <= 1'b0;
        end else if (rp_strobe && !io_seen) begin
            io_seen  <= 1'b1;
            rb_addr  <= A[12:0];
            rb_hi    <= 8'h00;
            rb_wdata <= dout;
            q_rd     <= !rd_n;
            q_wr     <= !wr_n;
        end else if (!io_seen) begin
            io_seen  <= 1'b1;
            rb_addr  <= io_addr;
            rb_hi    <= p_low ? hi : 8'h00;
            rb_wdata <= dout;
            if (p_low || p_sys || p_custom || p_ip || p_dbg) begin
                q_rd <= !rd_n;
                q_wr <= !wr_n;
            end else
                io_none <= !rd_n;
        end
    end
endmodule
