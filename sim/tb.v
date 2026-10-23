// retro-z80 system testbench (phase 1): tv80 runs the boot ROM on the
// simulated board: SRAM model, FT232H model, optional DMA port load.
// After retro68k's sim/tb.v.
//
//   +rom=FILE    load FILE into the boot ROM (default boot.hex)
//   +hello       pass when "hello" arrives; then send the RESET control
//                command and pass when "hello" arrives a second time
//   (otherwise)  pass when a line "PASS" arrives, fail on a line "FAIL"
//   +speeds      ... and take "hello" lines meanwhile; pass only if they
//                came at every CPUSPEED setting and the T-states at
//                3.57 MHz started on every slot edge 0-9
//   +dma        keep the DMA port busy with random reads and writes
//   +trace=N     print the first N memory and I/O accesses of the Z80
//
// Every run also checks that the Z80 never waited (spec 1, section 5):
//   - every CPU request to the scheduler is issued in the first CPU cycle
//     (0 or 2) that comes while it stands, and none is ever turned away;
//   - every byte the core takes from memory is at di before the cen edge
//     that ends T2, and is the byte the memory holds at that address, by
//     the reset mapping of spec 2, section 9.4 (worked out here, not taken
//     from the design);
//   - every byte read is at di a set time before the core takes it, by
//     speed (spec 1, sections 5.3 and 5.4);
//   - the SRAM model's datasheet checks and the FT232H model's checks.
// and that each T-state is as long as CPUSPEED says (spec 1, section 3;
// spec 7, section 6.1). The summary gives the measured rate at each speed.
`timescale 1ns/1ps
module tb;
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

    retroz80 dut (
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
    //     fetch or read), the byte at di must be the memory's.
    //     Reset mapping (spec 2, section 9.4): windows 0-1 boot ROM pages 0-1,
    //     windows 2-7 SRAM pages 0-5.
    integer reads_rom = 0, reads_sram = 0, writes_sram = 0, ios = 0, ntrace = 0, trace = 0;
    reg  [15:0] ad;
    reg  [7:0]  want;
    reg  [21:0] phys;
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
            if (ad[15:14] == 2'b00) begin
                want = pick(rom_ref[ad[13:1]], ad[0]);
                reads_rom = reads_rom + 1;
            end else begin
                phys = {9'd0, ad[12:0]} + ({19'd0, ad[15:13]} - 22'd2) * 22'h2000;
                want = pick(sram.mem[phys[21:1]], phys[0]);
                reads_sram = reads_sram + 1;
            end
            if (trace > ntrace) begin
                $display("%t  %s %h = %h", $realtime, dut.cpu.mcycle[0] ? "F" : "R", ad, dut.cpu.di);
                ntrace = ntrace + 1;
            end
            if (dut.cpu.di !== want) begin
                if (wait_errors < 10)
                    $display("%t WAIT ERROR: %s at %h took %h, memory holds %h", $realtime,
                             dut.cpu.mcycle[0] ? "fetch" : "read", ad, dut.cpu.di, want);
                wait_errors = wait_errors + 1;
            end
        end
    end
    // ---------------------------------------------------------------- speed
    // (3) The T-state rate (spec 1, section 3; spec 7, section 6.1), worked
    //     out here from the CPUSPEED writes seen on the core's pins:
    //   - a speed takes effect at the next T1 (the first, for an M-cycle with
    //     wait states) and holds for the whole M-cycle;
    //   - at DIV = n - 1 every T-state is 5n clocks and ends on slot edge 0
    //     or 5; with SPECTRUM every T-state is 28 clocks, except that while
    //     a change back to a locked speed waits for its T1, the T-states
    //     end on slot edge 0 or 5, up to 4 clocks late;
    //   - every byte read is at di at least 10n - 9 clocks (locked) or 43
    //     clocks (3.57 MHz, spec 1, section 5.4) before the core takes it.
    // Speeds are numbered 0-7 (DIV) and 8 (SPECTRUM). Slot edge k is the
    // clock edge after which sc = k.
    reg  [3:0] spd_set = 0;                     // CPUSPEED as last written
    reg  [3:0] spd_on  = 0;                     // the current M-cycle's speed
    reg        spd_t   = 0;                     // the clock after a cen edge
    reg        spd_t1  = 0;                     // the T-state before was a T1
    reg        io_wr_d = 0;                     // an I/O write was on the pins last clock
    integer    spd_clk = 0;                     // clocks since the last cen edge
    integer    spd_tstates [0:8], spd_clocks [0:8], spd_spare [0:8];
    integer    speed_errors = 0, rd_since = 0, s;
    reg  [9:0] spd_edges = 0;                   // slot edges of T1 at 3.57 MHz
    reg  [3:0] lf_speed [0:63];                 // the speed each line feed was sent at
    integer    nlf = 0;
    function [3:0] spd_of(input [7:0] v);
        spd_of = v[3] ? 4'd8 : {1'b0, v[2:0]};
    endfunction
    initial for (s = 0; s < 9; s = s + 1) begin
        spd_tstates[s] = 0; spd_clocks[s] = 0; spd_spare[s] = 9999;
    end
    always @(posedge clk) begin
        if (!dut.cpu_rst_n) begin
            spd_set = 0; spd_on = 0; spd_t = 0; spd_t1 = 0; spd_clk = 0; io_wr_d = 0;
        end else begin
            spd_clk = spd_clk + 1;
            // An OUT, once, as it starts
            if (!dut.cpu.iorq_n && !dut.cpu.wr_n && dut.cpu.m1_n && !io_wr_d) begin
                if (dut.cpu.A == 16'h7700) spd_set = spd_of(dut.cpu.dout);
                if (dut.cpu.A[7:0] == 8'h53 && dut.cpu.dout == 8'h0A) begin
                    if (nlf < 64) lf_speed[nlf] = spd_on;
                    nlf = nlf + 1;
                end
            end
            io_wr_d = !dut.cpu.iorq_n && !dut.cpu.wr_n;
            // The T-state started by the last cen edge (slot edge sc). An
            // M-cycle starts with T1; tv80's I/O cycle and acknowledge repeat
            // T1 for their wait states, which are not a new M-cycle.
            if (spd_t) begin
                if (dut.cpu.tstate[1] && !spd_t1) begin
                    spd_on = spd_set;
                    if (spd_on == 8) spd_edges[sc] = 1'b1;
                end
                spd_t1 = dut.cpu.tstate[1];
            end
            spd_t = 0;
            if (dut.cen) begin
                // This edge (slot edge sc + 1) ends a T-state of spd_clk clocks
                if (spd_on < 8 ? (spd_clk != 5 * (spd_on + 1) || (sc != 4'd4 && sc != 4'd9))
                               : (spd_set == 8 ? spd_clk != 28
                                               : (spd_clk < 28 || spd_clk > 32))) begin
                    if (speed_errors < 10)
                        $display("%t SPEED ERROR: a T-state of %0d clocks at speed %0d, ending on slot edge %0d",
                                 $realtime, spd_clk, spd_on, (sc + 1) % 10);
                    speed_errors = speed_errors + 1;
                end
                spd_tstates[spd_on] = spd_tstates[spd_on] + 1;
                spd_clocks[spd_on]  = spd_clocks[spd_on] + spd_clk;
                spd_clk = 0;
                spd_t   = 1;
            end
        end
    end
    // How long each byte read has been at di when the core takes it
    always @(posedge clk) begin
        if (dut.bif.rd_wait) rd_since = 0; else rd_since = rd_since + 1;
        if (dut.cen && dut.cpu_rst_n && dut.cpu.tstate[2] && dut.cpu.rfsh_n &&
            (dut.cpu.mcycle[0] ? dut.cpu.intcycle_n
                               : (!dut.cpu.iorq && !dut.cpu.no_read && !dut.cpu.write))) begin
            if (rd_since < spd_spare[spd_on]) spd_spare[spd_on] = rd_since;
            if (rd_since < (spd_on == 8 ? 43 : 10 * (spd_on + 1) - 9)) begin
                if (wait_errors < 10)
                    $display("%t WAIT ERROR: a byte at di only %0d clocks before the core took it, at speed %0d",
                             $realtime, rd_since, spd_on);
                wait_errors = wait_errors + 1;
            end
        end
    end

    // Writes and I/O, for the counts and the trace
    always @(negedge dut.cpu.wr_n) if (!dut.cpu.mreq_n) begin
        if (dut.cpu.A[15:14] != 2'b00) writes_sram = writes_sram + 1;
        if (trace > ntrace) begin
            $display("%t  W %h = %h", $realtime, dut.cpu.A, dut.cpu.dout);
            ntrace = ntrace + 1;
        end
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
    integer hello = 0, nhello = 0, scan = 0, ls = 0, done = 0, ok = 0, k;
    integer spd_hello [0:8];
    integer speeds = 0, all_hello = 0, nline = 0;
    initial begin
        speeds = $test$plusargs("speeds");
        for (k = 0; k < 9; k = k + 1) spd_hello[k] = 0;
    end
    integer timeout_us = 2000;
    initial begin
        hello = $test$plusargs("hello");
        if (!$value$plusargs("timeout=%d", timeout_us)) timeout_us = 2000;
    end
    function is_line(input integer at, input [8*7-1:0] s, input integer n);
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
            $display("---- scheduler: %0d CPU cycles (%0d in cycle 0, %0d in cycle 2), %0d turned away",
                     cpu_cycles, cpu_issue0, cpu_issue2, cpu_refused);
            $display("---- never waited: %0d errors", wait_errors + cpu_refused);
            $display("---- DMA: %0d reads, %0d writes, %0d errors", dma_reads, dma_writes, dma_errors);
            $display("---- SRAM timing errors: %0d, FT232H errors: %0d, send-immediate pulses: %0d",
                     sram.errors, ft.errors, ft.siwu_count);
            $display("---- speed: %0d errors; T1 at 3.57 MHz on slot edges %b (9-0)", speed_errors, spd_edges);
            for (s = 0; s < 9; s = s + 1)
                if (spd_tstates[s] > 0)
                    $display("----   %s: %0d T-states, %0d clocks: %0.3f MHz; read data at di %0d+ clocks before taken; %0d \"hello\"",
                             s == 8 ? "SPECTRUM" : s == 0 ? "DIV = 0 " : s == 1 ? "DIV = 1 " : s == 2 ? "DIV = 2 " :
                             s == 3 ? "DIV = 3 " : s == 4 ? "DIV = 4 " : s == 5 ? "DIV = 5 " : s == 6 ? "DIV = 6 " : "DIV = 7 ",
                             spd_tstates[s], spd_clocks[s], 100.0 * spd_tstates[s] / spd_clocks[s], spd_spare[s],
                             spd_hello[s]);
        end
    endtask
    task finish(input pass, input [8*40-1:0] why);
        begin
            done = 1;
            report;
            all_hello = 1;
            for (s = 0; s < 9; s = s + 1) if (spd_hello[s] == 0) all_hello = 0;
            if (pass && wait_errors == 0 && cpu_refused == 0 && sram.errors == 0 && ft.errors == 0
                && dma_errors == 0 && cpu_cycles > 0 && reads_sram > 0 && writes_sram > 0
                && speed_errors == 0 && (!speeds || (all_hello && spd_edges == 10'h3FF)))
                $display("TEST PASSED");
            else if (pass && speeds && !all_hello)
                $display("TEST FAILED: no \"hello\" at some speed");
            else if (pass && speeds && spd_edges != 10'h3FF)
                $display("TEST FAILED: T1 at 3.57 MHz not on every slot edge");
            else
                $display("TEST FAILED: %0s", why);
            $finish;
        end
    endtask
    always @(posedge clk) if (!done) begin
        // Lines from the computer: "hello", "PASS" or "FAIL"
        while (scan < ft.nout) begin
            if (scan == 0 || ft.from_fpga[scan-1] == 8'h0A) ls = scan;
            if (ft.from_fpga[scan] == 8'h0A) begin
                nline = nline + 1;
                if (speeds && is_line(ls, {"hello", 8'h0D, 8'h0A}, 7)) begin
                    // The speed its line feed was sent at
                    s = nline <= nlf && nline <= 64 ? lf_speed[nline-1] : 9;
                    $display("%t PC: \"hello\" at speed %0d", $realtime, s);
                    if (s < 9) spd_hello[s] = spd_hello[s] + 1;
                end else if (hello && is_line(ls, {"hello", 8'h0D, 8'h0A}, 7)) begin
                    nhello = nhello + 1;
                    $display("%t PC: \"hello\" number %0d", $realtime, nhello);
                    if (nhello == 1) begin
                        $display("%t PC: sending the RESET control command", $realtime);
                        send_ctl(8'h02);
                    end else finish(1, "");
                end else if (!hello && is_line(ls, {"PASS", 8'h0D, 8'h0A}, 6)) finish(1, "");
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
