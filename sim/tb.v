// retro-z80 system testbench (phase 1): tv80 runs the boot ROM on the
// simulated board: SRAM model, FT232H model, optional DMA port load.
// After retro68k's sim/tb.v.
//
//   +rom=FILE    load FILE into the boot ROM (default boot.hex)
//   +hello       the boot ROM: pass when "selftest ok, N MB" (N = the
//                build's CHIPMB) and then "hello" arrive; then send the
//                RESET control command and pass when both arrive again
//   +bgcycle     with +hello, a boot ROM built with -DCYCLE_FRAMES=1: after
//                the first "hello", pass when BGCOLOR has gone from green
//                to yellow and then cyan, each change made in the
//                vertical blank (the VBLANK handler); no RESET is sent
//   +bgdim       with +hello, a boot ROM built with -DTMR_HALF=n (#17):
//                after the first "hello", pass when BGCOLOR goes from green
//                to dim green and back, 2 ms apart (timer 0's interrupt)
//   +keys        with +hello (#19): after the first "hello", once the boot
//                console has turned the PS/2 FIFO on, type "h" and "i" on
//                the PS/2 keyboard model (through the KEYB interrupt), hold
//                Z on the membrane model for 30 ms, then press Enter on
//                the PS/2 keyboard; pass when the console echoes the line
//                "hiz" back over the serial link
//   (otherwise)  pass when a line "PASS" arrives, fail on a line "FAIL"
//   +speeds      ... and take "hello" lines meanwhile; pass only if they
//                came at every CPUSPEED setting and the T-states at
//                3.57 MHz started on every slot edge 0-9
//   +failshow=N  a boot ROM built with -DFAILTEST=N: pass when it reports
//                check N (hex) as failed and then shows it on the screen
//                as N - 0x40 white stripes, 16 lines each, 16 apart, from
//                picture line 17, the same in two frames running
//                (firmware/boot/boot.asm)
//   +vidlog      print the picture's colour bands in each frame
//   +ram=FILE    load FILE ($readmemh, 16-bit words) into the SRAM first
//   +frame=G     the video test (vtest/): log every write to the video
//                unit's registers and palettes with the beam position
//                (vlog.txt), grab beam frame G (frame 0 is the one the beam
//                starts in) into frame.ppm, write the end state (vend.txt),
//                and pass if nothing else failed; vtest/vmodel.py then
//                checks the picture pixel by pixel
//   +dumpram=FILE  with +frame: the SRAM's first 2 MB into FILE at the end
//   +dma        keep the DMA port busy with random reads and writes
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
//   - every byte read is at di a set time before the core takes it, by
//     speed (spec 1, sections 5.3 and 5.4);
//   - the SRAM model's datasheet checks and the FT232H model's checks;
//   - the 576p timing from the video unit (864 pixels a line, 625 lines a
//     frame) and that the background colour changes only between lines;
//     with +hello, that the screen was blue (self-test running) and then
//     green (passed), and BGCOLOR is green at the end;
//   - every interrupt acknowledge (spec 1, section 8.1, B11): exactly one
//     vector request, in its first T1; the byte the core takes at the end
//     of T2 is the controller's vector, VECBASE + 2 x INTID, at di at
//     least 16 clocks before; and exactly one int_ack, after that.
// and that each T-state is as long as CPUSPEED says (spec 1, section 3;
// spec 7, section 6.1). The summary gives the measured rate at each speed.
`timescale 1ns/1ps
module tb #(
    parameter [5:0] CHIPMB = 6'd4             // the build's SRAM size (spec 2, section 11)
);
    reg clk = 1'b1;
    always #5 clk = ~clk;                       // 100 MHz

    // The 576p clocks, as from the board's second MMCM: 135 MHz (the fast
    // synchroniser) and 27 MHz = 135 / 5 with its edges on the 135 MHz ones;
    // free-running at an odd phase against clk, so the crossings see every
    // phase (spec 4, section 3.1). Edges at exact times (n x 1/270 MHz), so
    // the 1 ps rounding never drifts (as retro68k's tb.v).
    reg clk_pix = 1'b0, clk_pix5 = 1'b0;
    initial begin : pixclocks
        integer n, k;
        real t;
        k = 0;
        n = 0;
        forever begin
            n = n + 1;
            t = 3.1 + n * (1000.0 / 270.0);
            #(t - $realtime);
            clk_pix5 = ~clk_pix5;
            if (clk_pix5) begin
                if (k == 0) clk_pix = 1'b1;
                k = (k == 4) ? 0 : k + 1;
            end else if (k == 3) clk_pix = 1'b0;   // 2.5 fast periods after the rise
        end
    end

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
    wire [23:0] vrgb;
    wire        vhs, vvs, vde;
    wire        audio_l, audio_r, audio_m;  // the sigma-delta streams (spec 7, section 10.2)

    // ---------------------------------------------------------------- input (spec 12)
    // A PS/2 keyboard (open-collector lines), the membrane (tb_keys: bit
    // 7r + c held, row r, column c) and the two joystick ports through the
    // multiplexer (tb_joy1, tb_joy2: pins 9, 6, 4, 3, 2, 1 pressed)
    wire        ps2_clk_low, ps2_data_low, kbm_clk_low, kbm_data_low;
    wire        ps2_clk  = !(ps2_clk_low || kbm_clk_low);
    wire        ps2_data = !(ps2_data_low || kbm_data_low);
    ps2_model kbm (.clk_line(ps2_clk), .data_line(ps2_data), .clk_low(kbm_clk_low), .data_low(kbm_data_low));
    wire [7:0]  keyb_row_low;
    reg  [55:0] tb_keys = 56'd0;
    reg  [6:0]  keyb_col;
    integer     kr, kc;
    always @(*) begin
        keyb_col = 7'h7F;
        for (kr = 0; kr < 8; kr = kr + 1)
            for (kc = 0; kc < 7; kc = kc + 1)
                if (keyb_row_low[kr] && tb_keys[7 * kr + kc]) keyb_col[kc] = 1'b0;
    end
    wire        joy_sel;
    reg  [5:0]  tb_joy1 = 6'd0, tb_joy2 = 6'd0;
    wire [5:0]  joy_pin_n = ~(joy_sel ? tb_joy2 : tb_joy1);

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
        .clk_pix(clk_pix), .clk_pix5(clk_pix5), .vid_rgb(vrgb), .vid_hsync(vhs), .vid_vsync(vvs), .vid_de(vde),
        .ps2_clk_i(ps2_clk), .ps2_data_i(ps2_data), .ps2_clk_low(ps2_clk_low), .ps2_data_low(ps2_data_low),
        .keyb_row_low(keyb_row_low), .keyb_col_i(keyb_col), .joy_pin_n(joy_pin_n), .joy_sel(joy_sel), .joy_p7(),
        .audio_l(audio_l), .audio_r(audio_r), .audio_m(audio_m),
        .dbg_sc(sc)
    );

    // The boot ROM image, loaded into the design's block RAM and into a copy
    // here for the read checks
    reg [15:0] rom_ref [0:16383];
    reg [8*128-1:0] ramfile;
    initial begin
        #1;                                     // after the block RAM's own $readmemh
        $readmemh(romfile, dut.rom.mem);
        $readmemh(romfile, rom_ref);
        #1;                                     // after the DMA area is cleared
        if ($value$plusargs("ram=%s", ramfile)) $readmemh(ramfile, sram.mem);
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
    // On a 2 MB build they land in 0x180000-0x1FFFFF (pages 0x0C0-0x0FF).
    reg  [15:0] shadow [0:(1<<18)-1];
    reg  [17:0] pend_q [0:7];
    reg  [15:0] pend_v [0:7];
    integer     pend_h = 0, pend_t = 0;
    integer     dma_reads = 0, dma_writes = 0, dma_errors = 0, i;
    reg         dma_on = 0;
    initial begin
        for (i = 0; i < (1<<18); i = i + 1) shadow[i] = 16'h0000;
        for (i = 0; i < (1<<18); i = i + 1) sram.mem[(CHIPMB == 6'd2 ? 21'h0C0000 : 21'h1C0000) + i] = 16'h0000;
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

    // Interrupt acknowledges (spec 1, section 8.1; open point B11)
    integer acks = 0, vreqs = 0, int_acks = 0, ack_errors = 0, vec_since = 0;
    reg     ack_asked = 1'b0, ack_took = 1'b0;
    task ack_error(input [8*64-1:0] why);
        begin
            if (ack_errors < 10) $display("%t ACK ERROR: %0s", $realtime, why);
            ack_errors = ack_errors + 1;
        end
    endtask
    always @(posedge clk) if (dut.cpu_rst_n) begin
        vec_since = vec_since + 1;
        if (dut.int_vreq) begin
            vreqs = vreqs + 1;
            if (ack_asked) ack_error("a second vector request in one acknowledge");
            if (!(dut.cpu.mcycle[0] && !dut.cpu.intcycle_n && dut.cpu.tstate[1]))
                ack_error("a vector request outside an acknowledge's T1");
            ack_asked = 1'b1;
            vec_since = 0;
        end
        if (dut.cen && dut.cpu.tstate[2] && dut.cpu.mcycle[0] && !dut.cpu.intcycle_n) begin
            acks = acks + 1;
            if (!ack_asked) ack_error("an acknowledge with no vector request");
            if (ack_took) ack_error("an acknowledge's byte taken twice");
            if (dut.cpu.di !== dut.ic.vector ||
                dut.cpu.di !== (({dut.ic.vecbase, 1'b0} + {2'd0, dut.ic.intid, 1'b0}) & 8'hFF))
                ack_error("the byte taken is not the vector");
            if (vec_since < 16) ack_error("the vector at di less than 16 clocks");
            ack_took = 1'b1;
        end
        if (dut.int_ack) begin
            int_acks = int_acks + 1;
            if (!ack_took) ack_error("int_ack before the byte was taken");
            ack_asked = 1'b0;
            ack_took  = 1'b0;
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

    // ---------------------------------------------------------------- the picture
    // Line and frame timing, the colours seen, and the white stripes of each
    // frame (picture lines, sampled in the middle of each line)
    localparam [23:0] C_BLUE = 24'h0000FF, C_GREEN = 24'h00FF00, C_WHITE = 24'hFFFFFF;
    integer    vx = 0, vline = 0, hs_clocks = 0, hs_lines = 0, vframes = 0, vid_errors = 0;
    integer    pix_blue = 0, pix_green = 0, mixed_lines = 0, b_start = 0;
    reg        vde_d = 1'b0, vhs_d = 1'b1, vvs_d = 1'b1, hs_seen = 1'b0, vs_seen = 1'b0;
    reg        lay_line = 1'b0;                 // a layer was on during this line (its colours may change)
    reg [23:0] l_first, l_last, l_mid, l_prev;
    // White stripes in the frame: how many, where the first starts, the sum
    // of their starts, and whether any stripe or gap was not 16 lines
    integer    w_runs = 0, w_first = -1, w_sig = 0, w_bad = 0, w_start = 0, w_end = -1;
    integer    fr_runs [0:63], fr_sig [0:63], fr_bad [0:63], fr_first [0:63];
    integer    failshow = 0, fail_frame = -1;
    initial if (!$value$plusargs("failshow=%h", failshow)) failshow = 0;

    always @(posedge clk_pix) begin
        vde_d <= vde;
        vhs_d <= vhs;
        vvs_d <= vvs;
        hs_clocks = hs_clocks + 1;
        if (!dut.vid.en_p) begin                // the beam stopped (VIDCON.EN clear, or a reset)
            hs_seen = 1'b0;
            vs_seen = 1'b0;
            hs_lines = 0;
        end
        if (vhs_d && !vhs) begin                // a line: 864 pixels
            if (hs_seen && hs_clocks != 864) begin
                if (vid_errors < 10) $display("%t video: a line of %0d pixels", $realtime, hs_clocks);
                vid_errors = vid_errors + 1;
            end
            hs_seen = 1'b1;
            hs_clocks = 0;
            hs_lines = hs_lines + 1;
        end
        if (vvs_d && !vvs) begin                // a frame: 625 lines
            if (vs_seen && hs_lines != 625) begin
                if (vid_errors < 10) $display("%t video: a frame of %0d lines", $realtime, hs_lines);
                vid_errors = vid_errors + 1;
            end
            vs_seen = 1'b1;
            hs_lines = 0;
            if ($test$plusargs("vidlog") && vline > 0)
                $display("%t video: frame %0d: lines %0d-%0d %h", $realtime, vframes, b_start, vline - 1, l_prev);
            if (vframes < 64) begin
                fr_runs[vframes] = w_runs; fr_sig[vframes] = w_sig;
                fr_bad[vframes]  = w_bad;  fr_first[vframes] = w_first;
            end
            if ($test$plusargs("vidlog") || failshow != 0)
                $display("%t video: frame %0d: %0d white stripes from line %0d%0s", $realtime, vframes,
                         w_runs, w_first, w_bad ? ", not all 16 lines" : "");
            vframes = vframes + 1;
            vline = 0; b_start = 0;
            w_runs = 0; w_first = -1; w_sig = 0; w_bad = 0; w_end = -1;
        end
        if (dut.vid.c_act != 3'd0) lay_line = 1'b1;
        if (vde) begin
            if (!vde_d) begin vx = 0; l_first = vrgb; end
            if (vx == 360) l_mid = vrgb;
            l_last = vrgb;
            if (vrgb == C_BLUE)  pix_blue  = pix_blue + 1;
            if (vrgb == C_GREEN) pix_green = pix_green + 1;
            vx = vx + 1;
        end else if (vde_d) begin               // the end of a picture line
            if (!lay_line && (l_first !== l_mid || l_mid !== l_last)) begin
                if (mixed_lines < 10) $display("%t video: line %0d changes colour", $realtime, vline);
                mixed_lines = mixed_lines + 1;
            end
            if (vline > 0 && l_mid !== l_prev) begin
                if ($test$plusargs("vidlog"))
                    $display("%t video: frame %0d: lines %0d-%0d %h", $realtime, vframes, b_start, vline - 1, l_prev);
                b_start = vline;
            end
            if (l_mid == C_WHITE && (vline == 0 || l_prev != C_WHITE)) begin
                if (w_end >= 0 && vline - w_end != 16) w_bad = 1;     // the red gap
                w_start = vline;
                w_runs  = w_runs + 1;
                if (w_first < 0) w_first = vline;
                w_sig   = w_sig + vline;
            end
            if (l_mid != C_WHITE && vline > 0 && l_prev == C_WHITE) begin
                if (vline - w_start != 16) w_bad = 1;                 // the stripe
                w_end = vline;
            end
            l_prev = l_mid;
            vline = vline + 1;
            lay_line = 1'b0;
        end
    end

    // ---------------------------------------------------------------- video test
    // Beam frames, counted at the beam's (0, 0) as the video unit counts them
    integer vfr = 0;
    always @(posedge clk_pix) if (dut.vid.en_p && dut.vid.bh == 11'd0 && dut.vid.bv == 11'd0) vfr = vfr + 1;
    // Every write to the video unit (custom page 0x10, the register page
    // palettes), with the beam position at the time: "frame line pixel on\n    // address data" (on: the beam was running)
    integer vlog = 0, grab = -1;
    initial if ($value$plusargs("frame=%d", grab)) vlog = $fopen("vlog.txt", "w");
    always @(posedge clk) if (vlog != 0 && dut.rb_wr && (dut.rb_addr[12:8] == 5'h10 || dut.rb_addr >= 13'h1400))
        $fwrite(vlog, "%0d %0d %0d %0d %h %h\n", vfr, dut.vid.bv, dut.vid.bh, dut.vid.en_p, dut.rb_addr, dut.rb_wdata);
    // Frame grab: the picture of beam frame G, in the order it is sent. The
    // output lags the beam by the pipeline, so frames are counted here at
    // the start of the vertical sync, which is in the same beam frame as the
    // picture after it
    reg  [23:0] fb [0:720*576-1];
    integer     fbn = 0, ofr = 0;
    reg         ovs_d = 1'b1;
    always @(posedge clk_pix) begin
        if (ovs_d && !vvs) ofr = ofr + 1;
        ovs_d = vvs;
    end
    always @(posedge clk_pix) if (grab >= 0 && ofr == grab && vde) begin
        if (fbn < 720*576) fb[fbn] = vrgb;
        fbn = fbn + 1;
    end
    task write_frame;
        integer f, x, y;
        reg [8*128-1:0] dumpfile;
        begin
            f = $fopen("frame.ppm", "w");
            $fwrite(f, "P3\n720 576\n255\n");
            for (y = 0; y < 576; y = y + 1) begin
                for (x = 0; x < 720; x = x + 1)
                    $fwrite(f, "%0d %0d %0d ", fb[y*720+x][23:16], fb[y*720+x][15:8], fb[y*720+x][7:0]);
                $fwrite(f, "\n");
            end
            $fclose(f);
            $fclose(vlog);
            f = $fopen("vend.txt", "w");
            $fwrite(f, "pixels %0d\nvidstat %0d\n", fbn, {dut.vid.vs_over, 3'd0, dut.vid.vs_vblank});
            $fclose(f);
            if ($value$plusargs("dumpram=%s", dumpfile)) $writememh(dumpfile, sram.mem, 0, 21'hFFFFF);
            $display("---- frame.ppm: beam frame %0d, %0d pixels", grab, fbn);
        end
    endtask

    // ---------------------------------------------------------------- finish
    integer hello = 0, nhello = 0, nself = 0, scan = 0, ls = 0, lk, done = 0, ok = 0, k;
    integer spd_hello [0:8];
    integer speeds = 0, all_hello = 0, nline = 0;
    initial begin
        speeds = $test$plusargs("speeds");
        for (k = 0; k < 9; k = k + 1) spd_hello[k] = 0;
    end
    integer bgdim = 0;                          // +bgdim (#17)
    real    bgdim_at = 0.0;
    integer timeout_us = 2000, bgcycle = 0, bgwait = 0, bgsteps = 0, keys = 0;
    event   type_keys;
    reg [23:0] bg_seen;
    initial begin
        bgcycle = $test$plusargs("bgcycle") || $test$plusargs("bgdim");
        hello = $test$plusargs("hello");
        keys = $test$plusargs("keys");
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
            $display("---- interrupts: %0d acknowledges, %0d vector requests, %0d int_ack pulses, %0d errors",
                     acks, vreqs, int_acks, ack_errors);
            $display("---- speed: %0d errors; T1 at 3.57 MHz on slot edges %b (9-0)", speed_errors, spd_edges);
            $display("---- video: %0d frames, %0d timing errors, %0d lines changing colour; %0d blue and %0d green pixels; BGCOLOR %h",
                     vframes, vid_errors, mixed_lines, pix_blue, pix_green, dut.vid.bgcolor);
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
                && ack_errors == 0 && acks == vreqs && acks == int_acks
                && speed_errors == 0 && (!speeds || (all_hello && spd_edges == 10'h3FF))
                && vid_errors == 0 && mixed_lines == 0
                && (!hello || (pix_blue > 0 && pix_green > 0 && (bgcycle || dut.vid.bgcolor == C_GREEN))))
                $display("TEST PASSED");
            else if (pass && hello && !(pix_blue > 0 && pix_green > 0 && (bgcycle || dut.vid.bgcolor == C_GREEN)))
                $display("TEST FAILED: the screen was not blue, then green");
            else if (pass && (ack_errors != 0 || acks != vreqs || acks != int_acks))
                $display("TEST FAILED: interrupt acknowledges");
            else if (pass && (vid_errors != 0 || mixed_lines != 0))
                $display("TEST FAILED: video timing");
            else if (pass && speeds && !all_hello)
                $display("TEST FAILED: no \"hello\" at some speed");
            else if (pass && speeds && spd_edges != 10'h3FF)
                $display("TEST FAILED: T1 at 3.57 MHz not on every slot edge");
            else
                $display("TEST FAILED: %0s", why);
            $finish;
        end
    endtask
    always @(posedge clk) if (!done && grab >= 0 && ofr > grab) begin
        write_frame;
        finish(fbn == 720*576, "the frame grabbed is not 720 x 576");
    end
    always @(posedge clk) if (!done) begin
        // Lines from the computer: "selftest ok, N MB" and "hello", or
        // "PASS" or "FAIL"
        while (scan < ft.nout) begin
            if (scan == 0 || ft.from_fpga[scan-1] == 8'h0A) ls = scan;
            if (ft.from_fpga[scan] == 8'h0A) begin
                $write("%t PC: line \"", $realtime);
                for (lk = ls; lk < scan - 1; lk = lk + 1) $write("%c", ft.from_fpga[lk]);
                $display("\"");
                nline = nline + 1;
                if (speeds && is_line(ls, {"hello", 8'h0D, 8'h0A}, 7)) begin
                    // The speed its line feed was sent at
                    s = nline <= nlf && nline <= 64 ? lf_speed[nline-1] : 9;
                    $display("%t PC: \"hello\" at speed %0d", $realtime, s);
                    if (s < 9) spd_hello[s] = spd_hello[s] + 1;
                end else if (hello && is_line(ls, {"selftest ok, ", "0" + {2'd0, CHIPMB}, " MB", 8'h0D, 8'h0A}, 19)) begin
                    nself = nself + 1;
                    $display("%t PC: self-test passed, number %0d", $realtime, nself);
                end else if (hello && is_line(ls, {"hello", 8'h0D, 8'h0A}, 7)) begin
                    nhello = nhello + 1;
                    $display("%t PC: \"hello\" number %0d", $realtime, nhello);
                    if (nself != nhello) finish(0, "hello without the self-test");
                    else if (nhello == 1 && bgcycle) begin
                        $display("%t PC: waiting for the VBLANK colour cycle", $realtime);
                        bgwait  = 1;
                        bg_seen = dut.vid.bgcolor;
                    end else if (nhello == 1 && keys) begin
                        $display("%t PC: typing on the keyboards", $realtime);
                        -> type_keys;
                    end else if (nhello == 1) begin
                        $display("%t PC: sending the RESET control command", $realtime);
                        send_ctl(8'h02);
                    end else finish(1, "");
                end else if (keys && is_line(ls, {"hiz", 8'h0D, 8'h0A}, 5)) begin
                    $display("%t PC: the console echoed \"hiz\"", $realtime);
                    finish(1, "");
                end else if (failshow != 0 && is_line(ls, "selftest FAIL ", 14)) begin
                    $display("%t PC: the self-test failure, frame %0d", $realtime, vframes);
                    fail_frame = vframes;
                end else if (hello && is_line(ls, "selftest FAIL", 13)) finish(0, "the boot ROM self-test failed");
                else if (!hello && is_line(ls, {"PASS", 8'h0D, 8'h0A}, 6)) finish(1, "");
                else if (!hello && is_line(ls, "FAIL", 4)) finish(0, "the test ROM failed");
                else if (grab >= 0 && !is_line(ls, "selftest FAIL", 13))
                    ;                                   // a video test: the frame is what counts
                else begin
                    $display("%t PC: unexpected line", $realtime);
                    finish(0, "unexpected output");
                end
            end
            scan = scan + 1;
        end
    end
    // +keys: PS/2 "h", "i", then Z on the membrane, then PS/2 Enter
    always @(type_keys) begin
        wait (dut.kb.en);
        #1000000;
        kbm.send(8'h33, 1'b0); kbm.send(8'hF0, 1'b0); kbm.send(8'h33, 1'b0);
        kbm.send(8'h43, 1'b0); kbm.send(8'hF0, 1'b0); kbm.send(8'h43, 1'b0);
        #5000000;
        tb_keys[7 * 0 + 1] = 1'b1;
        #30000000;
        tb_keys[7 * 0 + 1] = 1'b0;
        #5000000;
        kbm.send(8'h5A, 1'b0); kbm.send(8'hF0, 1'b0); kbm.send(8'h5A, 1'b0);
    end

    initial begin
        for (k = 0; k < timeout_us && !done; k = k + 1) #1000;
        if (!done) finish(0, "timeout");
    end

    // +bgcycle: green, then yellow, then cyan, each set in the vertical blank
    always @(posedge clk) if (!done && bgwait && !bgdim && dut.vid.bgcolor !== bg_seen) begin
        $display("%t video: BGCOLOR %h, beam line %0d", $realtime, dut.vid.bgcolor, dut.vid.s_vline);
        bg_seen = dut.vid.bgcolor;
        bgsteps = bgsteps + 1;
        if (!dut.vid.invblank)
            finish(0, "a colour change outside the blank");
        else if (bgsteps == 1 && bg_seen != 24'hFFFF00)
            finish(0, "not yellow after green");
        else if (bgsteps == 2)
            finish(bg_seen == 24'h00FFFF, "not cyan after yellow");
    end

    // +bgdim (#17): timer 0 dims and brightens the background, 2 ms apart
    initial bgdim = $test$plusargs("bgdim");
    always @(posedge clk) if (!done && bgwait && bgdim && dut.vid.bgcolor !== bg_seen) begin
        $display("%t video: BGCOLOR %h", $realtime, dut.vid.bgcolor);
        bg_seen = dut.vid.bgcolor;
        bgsteps = bgsteps + 1;
        if (bgsteps == 1 && bg_seen != 24'h007F00)
            finish(0, "not dim green after green");
        else if (bgsteps == 1)
            bgdim_at = $realtime;
        else if (bgsteps == 2 && bg_seen != 24'h00FF00)
            finish(0, "not green after dim green");
        else if (bgsteps == 2)
            finish($realtime - bgdim_at > 1.99e6 && $realtime - bgdim_at < 2.01e6, "not 2 ms apart");
    end

    // +failshow: once the boot ROM has reported the failure, the second and
    // third frames that start after it must show the stripes, the same in both
    always @(posedge clk) if (!done && failshow != 0 && fail_frame >= 0 && vframes >= fail_frame + 3) begin
        if (fr_runs[fail_frame + 1] == failshow - 64 && fr_runs[fail_frame + 2] == failshow - 64 &&
            fr_bad[fail_frame + 1] == 0 && fr_bad[fail_frame + 2] == 0 &&
            fr_sig[fail_frame + 1] == fr_sig[fail_frame + 2] && fr_first[fail_frame + 1] == 17)
            finish(1, "");
        else
            finish(0, "the failure stripes are wrong");
    end
endmodule
