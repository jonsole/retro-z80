// retro-z80 system testbench (phase 1): tv80 runs the boot ROM on the
// simulated board: SRAM model, FT232H model, optional DMA port load.
// After retro68k's sim/tb.v.
//
//   +rom=FILE    load FILE into the boot ROM (default boot.hex)
//   +hello       the boot ROM: pass when "selftest ok, N MB" (N = the
//                build's CHIPMB) and then "hello" arrive; then send the
//                RESET control command and pass when both arrive again
//   (otherwise)  pass when a line "PASS" arrives, fail on a line "FAIL"
//   +dma         keep the DMA port busy with random reads and writes
//   +trace=N     print the first N memory and I/O accesses of the Z80
//
// Every run also checks that the Z80 never waited (spec 1, section 5):
//   - every CPU request to the scheduler is issued in the first CPU cycle
//     (0 or 2) that comes while it stands, and none is ever turned away;
//   - every byte the core takes from memory is at di before the cen edge
//     that ends T2, and is the byte the memory holds at that address, by
//     a model of the MMU kept here from the Z80's own writes to the MMU
//     registers, through ports and the register page (spec 2, section 9;
//     worked out here, not taken from the design);
//   - the SRAM model's datasheet checks and the FT232H model's checks.
`timescale 1ns/1ps
module tb #(
    parameter [5:0] CHIPMB = 6'd4             // the build's SRAM size (spec 2, section 11)
);
    reg clk = 1'b1;
    always #5 clk = ~clk;                       // 100 MHz

    // Power-on reset: last seen high by the clock edge at 2000 ns (a slot boundary)
    reg por = 1'b1;
    initial #2001 por = 1'b0;

    // ---------------------------------------------------------------- DUT
    wire [20:0] a;
    wire        ce_n, ub_n, lb_n, oe_r, oe_f, we_r, we_f, t_r, t_f;
    wire [15:0] dq_o;
    wire [15:0] dq;
    wire        ft_rxf_n, ft_txe_n, ft_d_oe, ft_rd_n, ft_wr_n, ft_siwu_n;
    wire [7:0]  ft_d, ft_d_o;

    reg         dma_req = 0, dma_we = 0;
    reg  [21:1] dma_addr = 0;
    reg  [15:0] dma_wdata = 0;
    reg  [1:0]  dma_be = 2'b11;
    wire        dma_ack, dma_rvalid;
    wire [15:0] dma_rdata;
    wire [3:0]  sc;

    reg [8*128-1:0] romfile;
    initial if (!$value$plusargs("rom=%s", romfile)) romfile = "boot.hex";

    retroz80 #(.CHIPMB(CHIPMB)) dut (
        .clk(clk), .por(por),
        .btn_reset_n(1'b1), .buttons(2'b00),
        .sram_a(a), .sram_ce_n(ce_n), .sram_ub_n(ub_n), .sram_lb_n(lb_n),
        .sram_oe_n_r(oe_r), .sram_oe_n_f(oe_f), .sram_we_n_r(we_r), .sram_we_n_f(we_f),
        .sram_dq_o(dq_o), .sram_dq_t_r(t_r), .sram_dq_t_f(t_f), .sram_dq_i(dq),
        .ft_rxf_n(ft_rxf_n), .ft_txe_n(ft_txe_n), .ft_d_i(ft_d), .ft_d_o(ft_d_o),
        .ft_d_oe(ft_d_oe), .ft_rd_n(ft_rd_n), .ft_wr_n(ft_wr_n), .ft_siwu_n(ft_siwu_n),
        .dma_req(dma_req), .dma_we(dma_we), .dma_addr(dma_addr), .dma_wdata(dma_wdata),
        .dma_be(dma_be), .dma_ack(dma_ack), .dma_rvalid(dma_rvalid), .dma_rdata(dma_rdata),
        .dbg_sc(sc)
    );
    // The boot ROM image, loaded into the design's block RAM and into a copy
    // here for the read checks
    reg [15:0] rom_ref [0:16383];
    initial begin
        #1;                                     // after the block RAM's own $readmemh
        $readmemh(romfile, dut.rom.mem);
        $readmemh(romfile, rom_ref);
    end

    // ---------------------------------------------------------------- SRAM pads
    // Output registers in the pads: 1 ns clock-to-out (as retro68k's tb.v)
    reg  [20:0] pa;   reg pce_n = 1, pub_n = 1, plb_n = 1;  reg [15:0] pdq;
    always @(posedge clk) begin
        pa    <= #1 a;
        pce_n <= #1 ce_n;
        pub_n <= #1 ub_n;
        plb_n <= #1 lb_n;
        pdq   <= #1 dq_o;
    end
    wire poe_n, pwe_n, pt;
    oddr #(.INIT(1'b1)) o_oe (.clk(clk), .d_r(oe_r), .d_f(oe_f), .q(poe_n));
    oddr #(.INIT(1'b1)) o_we (.clk(clk), .d_r(we_r), .d_f(we_f), .q(pwe_n));
    oddr #(.INIT(1'b1)) o_t  (.clk(clk), .d_r(t_r),  .d_f(t_f),  .q(pt));
    assign dq = pt ? 16'hzzzz : pdq;

    sram_model sram (.a(pa), .dq(dq), .ce_n(pce_n), .oe_n(poe_n), .we_n(pwe_n),
                     .ub_n(pub_n), .lb_n(plb_n), .fpga_drives(!pt));

    // ---------------------------------------------------------------- FT232H
    assign ft_d = ft_d_oe ? ft_d_o : 8'hzz;
    ft232h_model ft (.d(ft_d), .rxf_n(ft_rxf_n), .txe_n(ft_txe_n),
                     .rd_n(ft_rd_n), .wr_n(ft_wr_n), .siwu_n(ft_siwu_n));

    // ---------------------------------------------------------------- DMA load
    // Random word reads and writes in 0x380000-0x3FFFFF (SRAM page 0x1C0 up,
    // far from the Z80's pages), checked against a copy (as retro68k's +dma).
    reg  [15:0] shadow [0:(1<<18)-1];
    reg  [17:0] pend_q [0:7];
    reg  [15:0] pend_v [0:7];
    integer     pend_h = 0, pend_t = 0;
    integer     dma_reads = 0, dma_writes = 0, dma_errors = 0, i;
    reg         dma_on = 0;
    initial begin
        for (i = 0; i < (1<<18); i = i + 1) shadow[i] = 16'h0000;
        for (i = 0; i < (1<<18); i = i + 1) sram.mem[21'h1C0000 + i] = 16'h0000;
        dma_on = $test$plusargs("dma");
    end
    always @(posedge clk) begin
        if (dma_rvalid) begin
            dma_reads = dma_reads + 1;
            if (pend_h == pend_t) begin
                $display("%t DMA ERROR: read data with no read waiting", $realtime);
                dma_errors = dma_errors + 1;
            end else begin
                if (dma_rdata !== pend_v[pend_h % 8]) begin
                    if (dma_errors < 10)
                        $display("%t DMA ERROR: read %h, expected %h", $realtime, dma_rdata, pend_v[pend_h % 8]);
                    dma_errors = dma_errors + 1;
                end
                pend_h = pend_h + 1;
            end
        end
        if (dma_ack) begin
            if (dma_we) begin
                shadow[dma_addr[18:1]] = dma_wdata;
                dma_writes = dma_writes + 1;
            end else begin
                pend_q[pend_t % 8] = dma_addr[18:1];
                pend_v[pend_t % 8] = shadow[dma_addr[18:1]];
                pend_t = pend_t + 1;
            end
            dma_req <= 1'b0;
        end
        if (dma_on && !por && (!dma_req || dma_ack)) begin
            dma_req   <= 1'b1;
            dma_we    <= $random;
            dma_addr  <= ($random & 21'h03FFFF) | 21'h1C0000;   // byte address 0x380000 up
            dma_wdata <= $random;
        end
    end

    // ---------------------------------------------------------------- never waits
    // (1) The scheduler: a CPU request standing when a CPU cycle (0 or 2) is
    //     given out must get it. sc odd = a cycle is given out at the next edge.
    integer cpu_cycles = 0, cpu_refused = 0, cpu_issue0 = 0, cpu_issue2 = 0, wait_errors = 0;
    wire    cpu_cycle_next = sc[0] && (sc == 4'd9 || sc == 4'd3);
    always @(posedge clk) if (!por) begin
        if (dut.cpu_req && !dut.cpu_ack && cpu_cycle_next) begin
            if (dut.go && dut.go_tag == 3'd1) begin
                cpu_cycles = cpu_cycles + 1;
                if (sc == 4'd9) cpu_issue0 = cpu_issue0 + 1; else cpu_issue2 = cpu_issue2 + 1;
            end else begin
                if (cpu_refused < 5) $display("%t WAIT ERROR: CPU request turned away from its cycle", $realtime);
                cpu_refused = cpu_refused + 1;
            end
        end
        if (dut.late) begin
            $display("%t WAIT ERROR: the core took a byte before it was at di", $realtime);
            wait_errors = wait_errors + 1;
        end
        if (dut.go && dut.go_tag == 3'd1 && !cpu_cycle_next) begin
            $display("%t WAIT ERROR: CPU given a cycle that is not 0 or 2", $realtime);
            wait_errors = wait_errors + 1;
        end
    end

    // (2) The core: at the cen edge that ends T2 of a memory read (opcode
    //     fetch or read), the byte at di must be the memory's, by the MMU
    //     model below.
    //
    // MMU model (spec 2, section 9): eight windows, each with a read and a
    // write page; reset state of section 9.4. The Z80's writes to registers
    // 0x80-0x9F of page 0x00, by port or through a window whose write page is
    // the register page (0x3F8), are applied here as section 9.2 says: byte 0
    // is held, byte 1 commits, a read-page commit also sets the write page.
    reg  [9:0]  m_rp [0:7];
    reg  [9:0]  m_wp [0:7];
    reg  [7:0]  m_hr [0:7];
    reg  [7:0]  m_hw [0:7];
    integer     w;
    task mmu_reset;
        begin
            for (w = 0; w < 8; w = w + 1) begin
                m_rp[w] = (w == 0) ? 10'h3FC : (w == 1) ? 10'h3FD : w - 2;
                m_wp[w] = m_rp[w];
                m_hr[w] = m_rp[w][7:0];
                m_hw[w] = m_rp[w][7:0];
            end
        end
    endtask
    initial mmu_reset;
    task mmu_write(input [7:0] r, input [7:0] d);
        reg [2:0] n;
        begin
            n = r[3:1];
            case ({r[4], r[0]})
                2'b00: m_hr[n] = d;
                2'b10: m_hw[n] = d;
                2'b01: begin
                    m_rp[n] = {d[1:0], m_hr[n]};
                    m_wp[n] = m_rp[n];
                    m_hw[n] = m_hr[n];
                end
                2'b11: m_wp[n] = {d[1:0], m_hw[n]};
            endcase
        end
    endtask
    // The physical byte address of an SRAM page; bit 21 ignored on a 2 MB build
    function [21:0] sram_byte(input [9:0] pg, input [12:0] off);
        sram_byte = {pg[8] && CHIPMB != 6'd2, pg[7:0], off};
    endfunction

    integer reads_rom = 0, reads_sram = 0, reads_regs = 0, reads_none = 0;
    integer writes_sram = 0, writes_regs = 0, ios = 0, ntrace = 0, trace = 0;
    reg  [15:0] ad;
    reg  [7:0]  want;
    reg  [9:0]  pg;
    reg  [21:0] phys;
    reg         chk;
    reg         wr_q = 1'b1;
    initial if (!$value$plusargs("trace=%d", trace)) trace = 0;
    // ROM writes (SYSCON.ROMWE) go into the copy too; systest checks them
    always @(posedge clk) if (dut.rom_en) begin
        if (dut.rom_we[1]) rom_ref[dut.rom_addr][15:8] = dut.rom_wdata[15:8];
        if (dut.rom_we[0]) rom_ref[dut.rom_addr][7:0]  = dut.rom_wdata[7:0];
    end
    function [7:0] pick(input [15:0] w, input b);
        pick = b ? w[15:8] : w[7:0];
    endfunction
    always @(posedge clk) if (dut.cen && dut.cpu_rst_n && dut.cpu.tstate[2] && dut.cpu.rfsh_n) begin
        ad = dut.cpu.A;
        if (dut.cpu.mcycle[0] ? dut.cpu.intcycle_n
                              : (!dut.cpu.iorq && !dut.cpu.no_read && !dut.cpu.write)) begin
            pg  = m_rp[ad[15:13]];
            chk = 1'b1;
            if (!pg[9]) begin                                   // SRAM
                phys = sram_byte(pg, ad[12:0]);
                want = pick(sram.mem[phys[21:1]], phys[0]);
                reads_sram = reads_sram + 1;
            end else if (pg[9:2] == 8'hFF) begin                // boot ROM
                want = pick(rom_ref[{pg[1:0], ad[12:1]}], ad[0]);
                reads_rom = reads_rom + 1;
            end else if (pg == 10'h3F8) begin                   // register page
                want = 8'hFF;                                   // opcode fetches only
                chk  = dut.cpu.mcycle[0];
                reads_regs = reads_regs + 1;
            end else begin                                      // NONE, reserved
                want = 8'hFF;
                reads_none = reads_none + 1;
            end
            if (trace > ntrace) begin
                $display("%t  %s %h = %h (page %h)", $realtime, dut.cpu.mcycle[0] ? "F" : "R", ad, dut.cpu.di, pg);
                ntrace = ntrace + 1;
            end
            if (chk && dut.cpu.di !== want) begin
                if (wait_errors < 10)
                    $display("%t WAIT ERROR: %s at %h (page %h) took %h, memory holds %h", $realtime,
                             dut.cpu.mcycle[0] ? "fetch" : "read", ad, pg, dut.cpu.di, want);
                wait_errors = wait_errors + 1;
            end
        end
    end
    // Writes and I/O: the MMU model, the counts and the trace. A write is
    // seen the clock after wr_n falls, when A and dout are steady.
    always @(posedge clk) begin
        if (!dut.cpu_rst_n) mmu_reset;
        else if (wr_q && !dut.cpu.wr_n) begin
            ad = dut.cpu.A;
            if (!dut.cpu.mreq_n) begin
                pg = m_wp[ad[15:13]];
                if (!pg[9]) writes_sram = writes_sram + 1;
                if (pg == 10'h3F8) begin
                    writes_regs = writes_regs + 1;
                    if (ad[12:5] == 8'h04) mmu_write(ad[7:0], dut.cpu.dout);   // 0x0080-0x009F
                end
                if (trace > ntrace) begin
                    $display("%t  W %h = %h (page %h)", $realtime, ad, dut.cpu.dout, pg);
                    ntrace = ntrace + 1;
                end
            end else if (!dut.cpu.iorq_n && dut.cpu.m1_n && ad[7:0] == 8'h00 && ad[15:13] == 3'b100)
                mmu_write(ad[15:8], dut.cpu.dout);
        end
        wr_q <= dut.cpu.wr_n;
    end
    always @(negedge dut.cpu.iorq_n) if (dut.cpu.m1_n) begin
        ios = ios + 1;
        if (trace > ntrace) begin
            $display("%t  %s port %h", $realtime, dut.cpu.wr_n ? "IN " : "OUT", dut.cpu.A);
            ntrace = ntrace + 1;
        end
    end

    // ---------------------------------------------------------------- serial
    task send_ctl(input [7:0] c);
        integer m;
        begin
            for (m = 0; m < 14; m = m + 1)
                ft.send(m == 0 ? 8'h00 : m == 1 ? 8'hFF : m == 2 ? "R" : m == 3 ? "6" : m == 4 ? "8" : m == 5 ? "K" :
                        m == 6 ? "-" : m == 7 ? "C" : m == 8 ? "T" : m == 9 ? "L" : m == 10 ? 8'hFF : m == 11 ? 8'h00 :
                        m == 12 ? 8'hA5 : 8'h5A);
            ft.send(c); ft.send(~c);
        end
    endtask

    // ---------------------------------------------------------------- finish
    integer hello = 0, nhello = 0, nself = 0, scan = 0, ls = 0, lk, done = 0, ok = 0, k;
    integer timeout_us = 2000;
    initial begin
        hello = $test$plusargs("hello");
        if (!$value$plusargs("timeout=%d", timeout_us)) timeout_us = 2000;
    end
    function is_line(input integer at, input [8*24-1:0] s, input integer n);
        integer q;
        begin
            is_line = (at + n <= ft.nout);
            for (q = 0; q < n && is_line; q = q + 1)
                if (ft.from_fpga[at + q] != s[8*(n-1-q) +: 8]) is_line = 0;
        end
    endfunction
    task report;
        begin
            $display("");
            $display("---- Z80: %0d reads from the boot ROM, %0d from SRAM, %0d writes to SRAM, %0d I/O cycles",
                     reads_rom, reads_sram, writes_sram, ios);
            $display("---- Z80: register page %0d reads, %0d writes; %0d reads of NONE or reserved pages (%0d MB build)",
                     reads_regs, writes_regs, reads_none, CHIPMB);
            $display("---- scheduler: %0d CPU cycles (%0d in cycle 0, %0d in cycle 2), %0d turned away",
                     cpu_cycles, cpu_issue0, cpu_issue2, cpu_refused);
            $display("---- never waited: %0d errors", wait_errors + cpu_refused);
            $display("---- DMA: %0d reads, %0d writes, %0d errors", dma_reads, dma_writes, dma_errors);
            $display("---- SRAM timing errors: %0d, FT232H errors: %0d, send-immediate pulses: %0d",
                     sram.errors, ft.errors, ft.siwu_count);
        end
    endtask
    task finish(input pass, input [8*40-1:0] why);
        begin
            done = 1;
            report;
            if (pass && wait_errors == 0 && cpu_refused == 0 && sram.errors == 0 && ft.errors == 0
                && dma_errors == 0 && cpu_cycles > 0 && reads_sram > 0 && writes_sram > 0)
                $display("TEST PASSED");
            else
                $display("TEST FAILED: %0s", why);
            $finish;
        end
    endtask
    always @(posedge clk) if (!done) begin
        // Lines from the computer: "selftest ok, N MB" and "hello", or
        // "PASS" or "FAIL"
        while (scan < ft.nout) begin
            if (scan == 0 || ft.from_fpga[scan-1] == 8'h0A) ls = scan;
            if (ft.from_fpga[scan] == 8'h0A) begin
                $write("%t PC: line \"", $realtime);
                for (lk = ls; lk < scan - 1; lk = lk + 1) $write("%c", ft.from_fpga[lk]);
                $display("\"");
                if (hello && is_line(ls, {"selftest ok, ", "0" + {2'd0, CHIPMB}, " MB", 8'h0D, 8'h0A}, 19)) begin
                    nself = nself + 1;
                    $display("%t PC: self-test passed, number %0d", $realtime, nself);
                end else if (hello && is_line(ls, {"hello", 8'h0D, 8'h0A}, 7)) begin
                    nhello = nhello + 1;
                    $display("%t PC: \"hello\" number %0d", $realtime, nhello);
                    if (nself != nhello) finish(0, "hello without the self-test");
                    else if (nhello == 1) begin
                        $display("%t PC: sending the RESET control command", $realtime);
                        send_ctl(8'h02);
                    end else finish(1, "");
                end else if (hello && is_line(ls, "selftest FAIL", 13)) finish(0, "the boot ROM self-test failed");
                else if (!hello && is_line(ls, {"PASS", 8'h0D, 8'h0A}, 6)) finish(1, "");
                else if (!hello && is_line(ls, "FAIL", 4)) finish(0, "the test ROM failed");
                else begin
                    $display("%t PC: unexpected line", $realtime);
                    finish(0, "unexpected output");
                end
            end
            scan = scan + 1;
        end
    end
    initial begin
        for (k = 0; k < timeout_us && !done; k = k + 1) #1000;
        if (!done) finish(0, "timeout");
    end
endmodule
