// ZEX on the whole system (ticket #7): the computer (fpga/rtl/retroz80.v) runs
// a CP/M .COM program at 20 MHz, in Verilator.
//
// tv80 behind the bus interface, the MMU, the scheduler and the SRAM
// controller, as in tb.v, with a cycle model of the SRAM pads and the SRAM
// in place of tb.v's timed models (Verilator runs it without its timing
// scheduler; the datasheet timing of the SRAM pins is checked by tb.v's
// runs in Icarus, and does not depend on what the Z80 runs). The FT232H is
// left idle.
//
// The boot ROM is the loader zexboot.asm (zexboot.hex): it maps windows 0-7
// to SRAM pages 0-7 and jumps to 0x0100. Before the run the testbench puts
// the CP/M image (cpm.asm built with CONSOLE = 0x01: page zero and a BDOS at
// 0xFF00) at physical 0x000000 and the program at 0x000100. The BDOS writes
// each character to port 0x01, which the machine ignores (a reserved page,
// spec 1, section 6.1); the testbench takes it from the core's pins. The run
// ends at the program's jump to 0 (the second opcode fetch from 0x0000; the
// first is the reset's, from the boot ROM).
//
//   +cpm=FILE       CP/M image, loaded at 0x0000
//   +com=FILE       program, loaded at 0x0100
//   +tests=N        number of tests that must print "OK"
//   +only=K         ZEXDOC and ZEXALL: run only test K (0 to 66)
//   +dma            keep the DMA port busy with random reads and writes
//   +maxcycles=N    give up after N clocks (default: no limit)
//   +trace=N        print the first N memory and I/O accesses of the Z80
//
// PASS when N tests print "OK", none prints "ERROR", "Tests complete" is
// printed before the jump to 0, and the Z80 never waited (as tb.v checks it,
// spec 1, section 5):
//   - every CPU request to the scheduler is issued in the first CPU cycle
//     (0 or 2) that comes while it stands, and none is turned away; the CPU
//     is given no other cycle;
//   - the bus interface's late flag never rises (the core took a byte
//     before it was at di);
//   - every byte the core takes from memory is at di before the cen edge
//     that ends T2, at least 1 clock before it (10n - 9 at 20 MHz, n = 1),
//     and is the byte the memory holds at that address, by a model of the
//     MMU kept here from the Z80's own writes to the MMU registers (spec 2,
//     section 9; worked out here, not taken from the design);
//   - the CPU never has both of a slot's CPU cycles (spec 1, section 13);
//   - every T-state is 5 clocks and ends on slot edge 0 or 5 (20 MHz);
//   - with +dma, every DMA read gives the word last written there.
//
// The clock comes from zexsys_main.cpp.
`timescale 1ns / 1ps

module tb_zexsys (input clk);
    localparam [5:0] CHIPMB  = 6'd4;
    localparam [7:0] CONSOLE = 8'h01;

    reg  [63:0] cycles = 0;                     // clocks since the start
    reg         por = 1'b1;                     // last seen high by edge 199
    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (cycles == 64'd199) por <= 1'b0;
    end

    // ---------------------------------------------------------------- DUT
    wire [20:0] a;
    wire        ce_n, ub_n, lb_n, oe_r, oe_f, we_r, we_f, t_r, t_f;
    wire [15:0] dq_o;
    wire [15:0] dq_i;
    wire        ft_d_oe, ft_rd_n, ft_wr_n, ft_siwu_n;
    wire [7:0]  ft_d_o;

    reg         dma_req = 0, dma_we = 0;
    reg  [21:1] dma_addr = 0;
    reg  [15:0] dma_wdata = 0;
    wire        dma_ack, dma_rvalid;
    wire [15:0] dma_rdata;
    wire [3:0]  sc;

    retroz80 #(.ROM_INIT("zexboot.hex"), .CHIPMB(CHIPMB)) dut (
        .clk(clk), .por(por),
        .btn_reset_n(1'b1), .buttons(2'b00),
        .sram_a(a), .sram_ce_n(ce_n), .sram_ub_n(ub_n), .sram_lb_n(lb_n),
        .sram_oe_n_r(oe_r), .sram_oe_n_f(oe_f), .sram_we_n_r(we_r), .sram_we_n_f(we_f),
        .sram_dq_o(dq_o), .sram_dq_t_r(t_r), .sram_dq_t_f(t_f), .sram_dq_i(dq_i),
        .ft_rxf_n(1'b1), .ft_txe_n(1'b1), .ft_d_i(8'h00), .ft_d_o(ft_d_o),
        .ft_d_oe(ft_d_oe), .ft_rd_n(ft_rd_n), .ft_wr_n(ft_wr_n), .ft_siwu_n(ft_siwu_n),
        .dma_req(dma_req), .dma_we(dma_we), .dma_addr(dma_addr), .dma_wdata(dma_wdata),
        .dma_be(2'b11), .dma_ack(dma_ack), .dma_rvalid(dma_rvalid), .dma_rdata(dma_rdata),
        .dbg_sc(sc)
    );

    // The boot ROM image, also kept here for the read checks
    reg [15:0] rom_ref [0:16383];
    initial $readmemh("zexboot.hex", rom_ref);

    // ---------------------------------------------------------------- SRAM
    // The pads register the controller's pin outputs, so the pins show in
    // each clock what the controller set at the edge before (tb.v's output
    // flip-flops and ODDRs; *_r is the first half of the clock, *_f the
    // second). /WE low in the first half and high in the second is a write's
    // rising edge (spec 5): the SRAM takes the data then. A read gives the
    // word at the address on the pins; the controller samples it at the end
    // of the cycle's second clock on the pins.
    reg  [15:0] mem [0:(1<<21)-1];
    reg  [20:0] pa = 0;
    reg         pce_n = 1, pub_n = 1, plb_n = 1, pwe_r = 1, pwe_f = 1;
    reg  [15:0] pdq = 0;
    always @(posedge clk) begin
        if (!pce_n && !pwe_r && pwe_f) begin
            if (!pub_n) mem[pa][15:8] <= pdq[15:8];
            if (!plb_n) mem[pa][7:0]  <= pdq[7:0];
        end
        pa    <= a;
        pce_n <= ce_n;
        pub_n <= ub_n;
        plb_n <= lb_n;
        pwe_r <= we_r;
        pwe_f <= we_f;
        pdq   <= dq_o;
    end
    assign dq_i = mem[pa];

    // ---------------------------------------------------------------- loading
    // The 64 KB the Z80 sees: physical 0x000000-0x00FFFF (pages 0-7)
    reg  [7:0]  img [0:65535];
    reg [1023:0] name;
    integer fd, c, i, n;

    task load(input [1023:0] file, input integer at);
        begin
            fd = $fopen(file, "rb");
            if (fd == 0) begin
                $display("TEST FAILED: cannot open %0s", file);
                $finish;
            end
            n = 0;
            c = $fgetc(fd);
            while (c >= 0 && at + n < 65536) begin
                img[at + n] = c[7:0];
                n = n + 1;
                c = $fgetc(fd);
            end
            $fclose(fd);
        end
    endtask

    // ZEX's start code ends with "ld hl,tests" (0x21) 12 bytes in; the test
    // table is a list of descriptor addresses ending in 0. Keep entry K only
    // (as tb_zex.v).
    integer start, tbl, only;
    task only_one(input integer k);
        begin
            start = {img[16'h0102], img[16'h0101]};
            if (img[start] != 8'h2A || img[start + 3] != 8'hF9 || img[start + 12] != 8'h21) begin
                $display("TEST FAILED: +only needs ZEXDOC or ZEXALL");
                $finish;
            end
            tbl = {img[start + 14], img[start + 13]};
            img[tbl]     = img[tbl + 2 * k];
            img[tbl + 1] = img[tbl + 2 * k + 1];
            img[tbl + 2] = 8'h00;
            img[tbl + 3] = 8'h00;
        end
    endtask

    integer tests = 0, trace = 0;
    reg [63:0] maxcycles = 0;
    reg        dma_on = 0;
    initial begin
        for (i = 0; i < (1<<21); i = i + 1) mem[i] = 16'h0000;
        for (i = 0; i < 65536; i = i + 1) img[i] = 8'h00;
        if (!$value$plusargs("cpm=%s", name)) name = "cpmsys.bin";
        load(name, 0);
        if (!$value$plusargs("com=%s", name)) begin
            $display("TEST FAILED: no +com=FILE");
            $finish;
        end
        load(name, 16'h0100);
        $display("Loaded %0d bytes at 0x0100", n);
        if ($value$plusargs("only=%d", only)) only_one(only);
        for (i = 0; i < 32768; i = i + 1) mem[i] = {img[2 * i + 1], img[2 * i]};   // little-endian
        if (!$value$plusargs("tests=%d", tests)) tests = 0;
        if (!$value$plusargs("maxcycles=%d", maxcycles)) maxcycles = 0;
        if (!$value$plusargs("trace=%d", trace)) trace = 0;
        dma_on = $test$plusargs("dma");
    end

    // ---------------------------------------------------------------- DMA load
    // Random word reads and writes in 0x380000-0x3FFFFF (SRAM page 0x1C0 up,
    // far from the Z80's pages), checked against a copy (as tb.v's +dma).
    reg  [15:0] shadow [0:(1<<18)-1];
    reg  [15:0] pend_v [0:7];
    reg  [63:0] pend_h = 0, pend_t = 0;          // 64 bits: long runs pass 2^31
    reg  [63:0] dma_reads = 0, dma_writes = 0, dma_errors = 0;
    initial for (i = 0; i < (1<<18); i = i + 1) shadow[i] = 16'h0000;
    always @(posedge clk) begin
        if (dma_rvalid) begin
            dma_reads = dma_reads + 1;
            if (pend_h == pend_t) begin
                $display("DMA ERROR: read data with no read waiting");
                dma_errors = dma_errors + 1;
            end else begin
                if (dma_rdata !== pend_v[pend_h % 8]) begin
                    if (dma_errors < 10)
                        $display("DMA ERROR: read %h, expected %h", dma_rdata, pend_v[pend_h % 8]);
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
    // (1) The scheduler (as tb.v): a CPU request standing when a CPU cycle
    //     (0 or 2) is given out must get it; sc 9 or 3 = a CPU cycle starts
    //     at the next edge.
    //     Spec 1, section 13 ("one CPU cycle per slot"): the CPU never gets
    //     both cycles of one slot (cycle 0 and then cycle 2).
    reg  [63:0] cpu_cycles = 0, cpu_refused = 0, cpu_issue0 = 0, cpu_issue2 = 0, wait_errors = 0;
    reg  [63:0] both_cycles = 0;
    reg     slot_had0 = 1'b0;
    wire    cpu_cycle_next = sc == 4'd9 || sc == 4'd3;
    always @(posedge clk) if (!por) begin
        if (sc == 4'd9) slot_had0 = 1'b0;               // a new slot starts at the next edge
        if (dut.cpu_req && !dut.cpu_ack && cpu_cycle_next) begin
            if (dut.go && dut.go_tag == 3'd1) begin
                cpu_cycles = cpu_cycles + 1;
                if (sc == 4'd9) begin
                    cpu_issue0 = cpu_issue0 + 1;
                    slot_had0  = 1'b1;
                end else begin
                    cpu_issue2 = cpu_issue2 + 1;
                    if (slot_had0) begin
                        if (both_cycles < 5) $display("SLOT ERROR: the CPU had both cycles of one slot, clock %0d", cycles);
                        both_cycles = both_cycles + 1;
                    end
                end
            end else begin
                if (cpu_refused < 5) $display("WAIT ERROR: CPU request turned away from its cycle at clock %0d", cycles);
                cpu_refused = cpu_refused + 1;
            end
        end
        if (dut.late) begin
            if (wait_errors < 10) $display("WAIT ERROR: the core took a byte before it was at di, clock %0d", cycles);
            wait_errors = wait_errors + 1;
        end
        if (dut.go && dut.go_tag == 3'd1 && !cpu_cycle_next) begin
            if (wait_errors < 10) $display("WAIT ERROR: CPU given a cycle that is not 0 or 2, clock %0d", cycles);
            wait_errors = wait_errors + 1;
        end
    end

    // (2) MMU model (spec 2, section 9), as tb.v's: eight windows, each with
    //     a read and a write page; byte 0 held, byte 1 commits, a read-page
    //     commit also sets the write page. Fed by the Z80's I/O writes to
    //     registers 0x80-0x9F of page 0x00 and its memory writes there
    //     through a window whose write page is the register page (0x3F8).
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
        reg [2:0] nw;
        begin
            nw = r[3:1];
            case ({r[4], r[0]})
                2'b00: m_hr[nw] = d;
                2'b10: m_hw[nw] = d;
                2'b01: begin
                    m_rp[nw] = {d[1:0], m_hr[nw]};
                    m_wp[nw] = m_rp[nw];
                    m_hw[nw] = m_hr[nw];
                end
                default: m_wp[nw] = {d[1:0], m_hw[nw]};
            endcase
        end
    endtask
    function [7:0] pick(input [15:0] wd, input b);
        pick = b ? wd[15:8] : wd[7:0];
    endfunction

    // (3) At the cen edge that ends T2 of a memory read (opcode fetch or
    //     read), the byte at di must be the memory's, and must have been
    //     there at least a clock. The end of the run is found here too.
    reg  [63:0] tstates = 0;
    reg  [63:0] reads_rom = 0, reads_sram = 0, reads_other = 0, writes_sram = 0;
    integer ntrace = 0;
    integer rd_since = 0, spare = 9999, zero_fetches = 0, spd_clk = 0;
    reg  [63:0] speed_errors = 0;
    reg  [15:0] ad;
    reg  [7:0]  want;
    reg  [9:0]  pg;
    reg  [21:0] phys;
    wire        take = dut.cen && dut.cpu_rst_n && dut.cpu.tstate[2] && dut.cpu.rfsh_n &&
                       (dut.cpu.mcycle[0] ? dut.cpu.intcycle_n
                                          : (!dut.cpu.iorq && !dut.cpu.no_read && !dut.cpu.write));
    always @(posedge clk) begin
        if (dut.bif.rd_wait) rd_since = 0; else rd_since = rd_since + 1;
        if (take) begin
            ad = dut.cpu.A;
            pg = m_rp[ad[15:13]];
            if (!pg[9]) begin                                   // SRAM
                phys = {pg[8], pg[7:0], ad[12:0]};
                want = pick(mem[phys[21:1]], phys[0]);
                reads_sram = reads_sram + 1;
            end else if (pg[9:2] == 8'hFF) begin                // boot ROM
                want = pick(rom_ref[{pg[1:0], ad[12:1]}], ad[0]);
                reads_rom = reads_rom + 1;
            end else begin                                      // nothing else is mapped here
                want = 8'hFF;
                reads_other = reads_other + 1;
            end
            if (trace > ntrace) begin
                $display("%0d  %s %h = %h (page %h)", cycles, dut.cpu.mcycle[0] ? "F" : "R", ad, dut.cpu.di, pg);
                ntrace = ntrace + 1;
            end
            if (dut.cpu.di !== want) begin
                if (wait_errors < 10)
                    $display("WAIT ERROR: %s at %h (page %h) took %h, memory holds %h, clock %0d",
                             dut.cpu.mcycle[0] ? "fetch" : "read", ad, pg, dut.cpu.di, want, cycles);
                wait_errors = wait_errors + 1;
            end
            if (rd_since < spare) spare = rd_since;
            if (rd_since < 1) begin
                if (wait_errors < 10)
                    $display("WAIT ERROR: a byte at di only %0d clocks before the core took it, clock %0d",
                             rd_since, cycles);
                wait_errors = wait_errors + 1;
            end
            if (dut.cpu.mcycle[0] && ad == 16'h0000) begin
                zero_fetches = zero_fetches + 1;
                if (zero_fetches == 2) finish_run;
            end
        end
        // (4) 20 MHz: every T-state is 5 clocks and ends on slot edge 0 or 5
        if (!dut.cpu_rst_n) spd_clk = 0;
        else begin
            spd_clk = spd_clk + 1;
            if (dut.cen) begin
                if (spd_clk != 5 || (sc != 4'd4 && sc != 4'd9)) begin
                    if (speed_errors < 10)
                        $display("SPEED ERROR: a T-state of %0d clocks, ending on slot edge %0d, clock %0d",
                                 spd_clk, (sc + 1) % 10, cycles);
                    speed_errors = speed_errors + 1;
                end
                tstates = tstates + 1;
                spd_clk = 0;
            end
        end
        if (maxcycles != 0 && cycles >= maxcycles) begin
            $display("");
            $display("TEST FAILED: no jump to 0 after %0d clocks", cycles);
            report;
            $finish;
        end
    end

    // Writes and I/O: the MMU model, the console and the trace. A write is
    // seen the clock after wr_n falls, when A and dout are steady.
    reg         wr_q = 1'b1;
    reg  [15:0] aw;
    reg  [9:0]  pw;
    reg [111:0] tail = 0;
    reg  [63:0] oks = 0, errors = 0;
    reg         complete = 1'b0;
    always @(posedge clk) begin
        if (!dut.cpu_rst_n) mmu_reset;
        else if (wr_q && !dut.cpu.wr_n) begin
            aw = dut.cpu.A;
            if (!dut.cpu.mreq_n) begin
                pw = m_wp[aw[15:13]];
                if (!pw[9]) writes_sram = writes_sram + 1;
                if (pw == 10'h3F8 && aw[12:5] == 8'h04) mmu_write(aw[7:0], dut.cpu.dout);
                if (trace > ntrace) begin
                    $display("%0d  W %h = %h (page %h)", cycles, aw, dut.cpu.dout, pw);
                    ntrace = ntrace + 1;
                end
            end else if (!dut.cpu.iorq_n && dut.cpu.m1_n) begin
                if (aw[7:0] == 8'h00 && aw[15:13] == 3'b100) mmu_write(aw[15:8], dut.cpu.dout);
                if (trace > ntrace) begin
                    $display("%0d  OUT %h = %h", cycles, aw, dut.cpu.dout);
                    ntrace = ntrace + 1;
                end
                if (aw[7:0] == CONSOLE) begin
                    if (dut.cpu.dout != 8'h0D) $write("%c", dut.cpu.dout);
                    tail = {tail[103:0], dut.cpu.dout};
                    if (tail[15:0] == "OK") oks = oks + 1;
                    if (tail[39:0] == "ERROR") errors = errors + 1;
                    if (tail == "Tests complete") complete = 1'b1;
                end
            end
        end
        wr_q <= dut.cpu.wr_n;
    end

    // ---------------------------------------------------------------- finish
    task report;
        begin
            $display("---- %0d clocks, %0d T-states", cycles, tstates);
            $display("---- Z80: %0d reads from the boot ROM, %0d from SRAM, %0d of other pages, %0d writes to SRAM",
                     reads_rom, reads_sram, reads_other, writes_sram);
            $display("---- scheduler: %0d CPU cycles (%0d in cycle 0, %0d in cycle 2), %0d turned away, %0d slots with both",
                     cpu_cycles, cpu_issue0, cpu_issue2, cpu_refused, both_cycles);
            $display("---- never waited: %0d errors; read data at di %0d+ clocks before taken",
                     wait_errors + cpu_refused, spare);
            $display("---- speed: %0d errors; DMA: %0d reads, %0d writes, %0d errors",
                     speed_errors, dma_reads, dma_writes, dma_errors);
        end
    endtask
    task finish_run;
        begin
            $display("");
            $display("%0d T-states, %0d tests OK, %0d ERROR", tstates, oks, errors);
            report;
            if (wait_errors != 0 || cpu_refused != 0 || cpu_cycles == 0)
                $display("TEST FAILED: the Z80 waited");
            else if (both_cycles != 0)
                $display("TEST FAILED: the CPU had both cycles of a slot");
            else if (speed_errors != 0 || dma_errors != 0)
                $display("TEST FAILED: speed or DMA errors");
            else if (!complete)
                $display("TEST FAILED: no \"Tests complete\"");
            else if (errors != 0 || oks != tests || tests == 0)
                $display("TEST FAILED: %0d of %0d tests OK, %0d ERROR", oks, tests, errors);
            else
                $display("TEST PASSED");
            $finish;
        end
    endtask
endmodule
