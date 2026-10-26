// Unit test of the copper (fpga/rtl/copper.v, spec 6; ticket #32) on the
// real scheduler (dmac.v), with a memory that answers as sram_ctl.v does
// (read data 4 clocks after the cycle starts) and a beam at 27/100 of the
// system clock. The testbench is the CPU: it writes and reads the copper's
// registers on the register bus, and its strobe moves a clock when the
// copper writes in the same clock (as bus_if.v).
//
// coptest.hex (sim/cop/coptest.asm) holds a table of tests and their lists;
// cop_hi.hex is loaded at 0x2F0000. For each test the testbench sets the
// copper up, starts it (at the frame restart, the beam put just before it,
// or with COPJMP1 at once), waits until it stops or the frames have passed,
// and reads its state back. cop.log has, for each test:
//   T n                                   the test starts
//   W line pixel clock offset data        each copper write (the beam and
//                                         the clock when it is on the bus)
//   F line                                a frame restart during the test
//   S stat pc x y flags sp r0 ... r7 cop2lc irq   its state at the end
// copcheck.py checks the log against its model. The register checks done
// here (CPU access, the capture of COPPC, reserved offsets, COPSTAT) end in
// TEST PASSED or TEST FAILED.
`timescale 1ns/1ps
`include "regmap.vh"

module tb_cop;
    reg clk = 0, rst = 1;
    always #5 clk = !clk;

    // ---------------------------------------------------------------- slots
    wire [3:0] sc;
    timebase tbase (.clk(clk), .rst(rst), .sc(sc));
    wire       start_next = sc[0];
    wire [2:0] next_cycle = (sc == 4'd9) ? 3'd0 : sc[3:1] + 1'b1;

    // ---------------------------------------------------------------- beam
    reg  [10:0] bv = 11'd0, bh = 11'd0;
    reg  [7:0]  acc = 8'd0;
    reg         vbl = 1'b0;
    reg         jump_beam = 1'b0;      // put the beam just before the frame restart
    reg         jump_mid = 1'b0;       // ... or at line 300, far from it
    always @(posedge clk) begin
        vbl <= 1'b0;
        if (jump_beam) begin
            bv <= 11'd624; bh <= 11'd858; acc <= 8'd0;
        end else if (jump_mid) begin
            bv <= 11'd300; bh <= 11'd0; acc <= 8'd0;
        end else if (acc + 8'd27 >= 8'd100) begin
            acc <= acc + 8'd27 - 8'd100;
            if (bh == 11'd863) begin
                bh <= 11'd0;
                if (bv == 11'd624) begin bv <= 11'd0; vbl <= 1'b1; end
                else bv <= bv + 1'b1;
            end else bh <= bh + 1'b1;
        end else acc <= acc + 8'd27;
    end

    // ---------------------------------------------------------------- the register bus
    reg         q_rd = 0, q_wr = 0, d_rd = 0, d_wr = 0;
    reg  [12:0] c_addr = 0;
    reg  [7:0]  c_wdata = 0;
    wire        cw_req;
    wire [9:0]  cw_off;
    wire [7:0]  cw_data;
    wire        rb_rd = (q_rd && !cw_req) || d_rd;
    wire        rb_wr = (q_wr && !cw_req) || d_wr || cw_req;
    wire [12:0] rb_addr  = cw_req ? {3'b100, cw_off} : c_addr;
    wire [7:0]  rb_wdata = cw_req ? cw_data : c_wdata;
    wire [7:0]  rb_rdata;
    wire        rb_hit, rb_cap;
    wire [31:0] rb_cdata;
    always @(posedge clk) begin
        d_rd <= q_rd && cw_req;
        d_wr <= q_wr && cw_req;
    end

    // ---------------------------------------------------------------- memory
    reg         busy = 1'b0;            // the CPU and layer channels ask for every cycle
    wire        go, go_we;
    wire [21:1] go_addr;
    wire [2:0]  go_tag;
    wire        cop_req, cop_ack, cop_rvalid;
    wire [21:1] cop_addr;
    wire [1:0]  cop_pri;
    reg  [15:0] mem [0:(1<<21)-1];
    reg  [3:0]  rv_p = 4'd0;
    reg  [2:0]  rt_p [0:3];
    reg  [15:0] rd_p [0:3];
    wire        rvalid = rv_p[3];
    wire [2:0]  rtag = rt_p[3];
    wire [15:0] rdata = rd_p[3];
    integer     k;
    always @(posedge clk) begin
        rv_p <= {rv_p[2:0], go};
        rt_p[0] <= go_tag; rd_p[0] <= mem[go_addr];
        for (k = 1; k < 4; k = k + 1) begin rt_p[k] <= rt_p[k-1]; rd_p[k] <= rd_p[k-1]; end
    end

    dmac sched (
        .clk(clk), .rst(rst), .start_next(start_next), .next_cycle(next_cycle),
        .cpu_req(busy), .cpu_we(1'b0), .cpu_addr(21'd0), .cpu_wdata(16'd0), .cpu_be(2'b11),
        .cpu_ack(), .cpu_rvalid(),
        .bpl_req(busy), .bpl_addr(21'd0), .bpl_deadline(10'd500), .bpl_urgent(1'b0),
        .bpl_ack(), .bpl_rvalid(),
        .spr_req(1'b0), .spr_addr(21'd0), .spr_deadline(10'd0), .spr_urgent(1'b0),
        .spr_ack(), .spr_rvalid(),
        .aud_req(1'b0), .aud_addr(21'd0), .aud_ack(), .aud_rvalid(),
        .cop_req(cop_req), .cop_addr(cop_addr), .cop_pri(cop_pri), .cop_ack(cop_ack), .cop_rvalid(cop_rvalid),
        .blt_req(1'b0), .blt_we(1'b0), .blt_addr(21'd0), .blt_wdata(16'd0), .blt_be(2'b00),
        .blt_ack(), .blt_rvalid(),
        .port_req(1'b0), .port_we(1'b0), .port_addr(21'd0), .port_wdata(16'd0), .port_be(2'b00),
        .port_ack(), .port_rvalid(),
        .go(go), .go_we(go_we), .go_addr(go_addr), .go_wdata(), .go_be(), .go_tag(go_tag),
        .rvalid(rvalid), .rtag(rtag)
    );

    reg  dma_on = 1'b1;
    wire irq;
    copper dut (
        .clk(clk), .rst(rst),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
        .rb_rdata(rb_rdata), .rb_hit(rb_hit), .rb_cdata(rb_cdata), .rb_cap(rb_cap),
        .cw_req(cw_req), .cw_off(cw_off), .cw_data(cw_data),
        .mem_req(cop_req), .mem_addr(cop_addr), .mem_pri(cop_pri), .mem_ack(cop_ack),
        .mem_rvalid(cop_rvalid), .mem_rdata(rdata),
        .beam_v(bv), .beam_h(bh), .vblank(vbl), .dma_on(dma_on), .blt_idle(1'b1),
        .irq(irq)
    );

    // ---------------------------------------------------------------- checks
    integer errors = 0, checks = 0, clocks = 0, log;
    always @(posedge clk) begin
        clocks <= clocks + 1;
        if (clocks == 150000000) begin
            $display("ERROR: timeout");
            $display("TEST FAILED");
            $finish;
        end
    end
    task check(input [8*48-1:0] what, input [31:0] got, input [31:0] want);
        begin
            checks = checks + 1;
            if (got !== want) begin
                $display("ERROR: %0s: %h, expected %h", what, got, want);
                errors = errors + 1;
            end
        end
    endtask

    // The CPU's accesses: a strobe for one clock, moved on by a copper write
    task wr(input [12:0] a, input [7:0] d);
        begin
            @(negedge clk); c_addr = a; c_wdata = d; q_wr = 1;
            @(negedge clk); q_wr = 0;
            @(negedge clk);
        end
    endtask
    reg [7:0]  rd_v;
    reg        rd_h, rd_c;
    reg [31:0] rd_cd;
    task rd(input [12:0] a);
        begin
            @(negedge clk); c_addr = a; q_rd = 1;
            @(negedge clk); q_rd = 0;
            if (d_rd) @(negedge clk);
            rd_v = rb_rdata; rd_h = rb_hit; rd_c = rb_cap; rd_cd = rb_cdata;
        end
    endtask
    task rdchk(input [8*48-1:0] what, input [12:0] a, input [7:0] want);
        begin
            rd(a);
            check(what, {rd_h, rd_v}, {1'b1, want});
        end
    endtask

    // The copper's writes, and the frame restarts
    always @(posedge clk) begin
        if (cw_req) $fwrite(log, "W %0d %0d %0d %h %h\n", bv, bh, clocks, cw_off, cw_data);
        if (vbl && dma_on) $fwrite(log, "F %0d\n", clocks);
    end

    // Its state, read on the register bus
    task state;
        integer r;
        reg [7:0] st, x, y, f, s, p0, p1, p2, l0, l1, l2;
        begin
            rd(`RM_COPSTAT); st = rd_v;
            rd(`RM_COPPC0);  p0 = rd_v;
            rd(`RM_COPPC1);  p1 = rd_v;
            rd(`RM_COPPC2);  p2 = rd_v;
            rd(`RM_COPX);    x = rd_v;
            rd(`RM_COPY);    y = rd_v;
            rd(`RM_COPFLAGS); f = rd_v;
            rd(`RM_COPSP);   s = rd_v;
            rd(`RM_COP2LC0); l0 = rd_v;
            rd(`RM_COP2LC1); l1 = rd_v;
            rd(`RM_COP2LC2); l2 = rd_v;
            $fwrite(log, "S %h %h %h %h %h %h", st, {p2, p1, p0}, x, y, f, s);
            for (r = 0; r < 8; r = r + 1) begin
                rd(`RM_COPR0 + r[12:0]);
                $fwrite(log, " %h", rd_v);
            end
            $fwrite(log, " %h %0d\n", {l2, l1, l0}, irq);
        end
    endtask

    // ---------------------------------------------------------------- the tests
    integer  n, t0, tf, fr, i;
    reg [21:0] la, l2a;
    reg [7:0]  fl, nf;
    reg        stopped;
    always @(posedge clk) busy <= tb_busy && bv >= 11'd100 && bv < 11'd400;
    reg tb_busy = 1'b0;

    initial begin
        log = $fopen("cop.log", "w");
        for (i = 0; i < (1<<21); i = i + 1) mem[i] = 16'hFFFF;
        $readmemh("coptest.hex", mem);
        $readmemh("cop_hi.hex", mem, 21'h178000);
        repeat (20) @(posedge clk);
        @(negedge clk); rst = 0;
        repeat (5) @(posedge clk);

        // ---- the registers from the CPU (spec 6, section 6)
        rdchk("COPSTAT after reset", `RM_COPSTAT, 8'h02);
        rdchk("COPCON after reset", `RM_COPCON, 8'h00);
        wr(`RM_COPCON, 8'hFF);   rdchk("COPCON", `RM_COPCON, 8'h3F);
        wr(`RM_COPCON, 8'h00);
        wr(`RM_COP1LC0, 8'hFF); wr(`RM_COP1LC1, 8'hA5); wr(`RM_COP1LC2, 8'hFF);
        rdchk("COP1LC0 (bit 0 reads 0)", `RM_COP1LC0, 8'hFE);
        rdchk("COP1LC1", `RM_COP1LC1, 8'hA5);
        rdchk("COP1LC2 (bits 21-16)", `RM_COP1LC2, 8'h3F);
        wr(`RM_COP2LC0, 8'h12); wr(`RM_COP2LC1, 8'h34); wr(`RM_COP2LC2, 8'h56);
        rdchk("COP2LC", `RM_COP2LC2, 8'h16);
        rdchk("COP2LC0", `RM_COP2LC0, 8'h12);
        wr(`RM_COPX, 8'h81); rdchk("COPX", `RM_COPX, 8'h81);
        wr(`RM_COPY, 8'h7E); rdchk("COPY", `RM_COPY, 8'h7E);
        wr(`RM_COPFLAGS, 8'hFF); rdchk("COPFLAGS", `RM_COPFLAGS, 8'h07);
        for (i = 0; i < 8; i = i + 1) wr(`RM_COPR0 + i[12:0], 8'h10 + i[7:0]);
        for (i = 0; i < 8; i = i + 1) rdchk("COPRn", `RM_COPR0 + i[12:0], 8'h10 + i[7:0]);
        rdchk("COPSP", `RM_COPSP, 8'h00);
        for (i = 12'h112; i <= 12'h117; i = i + 1) begin
            rd(13'h1000 + i[12:0]);
            check("reserved offsets are not answered", {31'd0, rd_h}, 32'd0);
        end
        rd(13'h1120);
        check("0x120 is not the copper's", {31'd0, rd_h}, 32'd0);
        rd(`RM_COPPC0);
        check("COPPC0 hands COPPC to the capture", {rd_c, rd_cd}, {1'b1, 32'd0});
        wr(`RM_COPINT, 8'h00);
        rdchk("COPSTAT.IRQ", `RM_COPSTAT, 8'h0A);
        check("irq without IRQEN", {31'd0, irq}, 32'd0);
        wr(`RM_COPCON, 8'h02);
        check("irq with IRQEN", {31'd0, irq}, 32'd1);
        wr(`RM_COPSTAT, 8'h08);
        rdchk("COPSTAT.IRQ cleared", `RM_COPSTAT, 8'h02);
        check("irq cleared", {31'd0, irq}, 32'd0);
        wr(`RM_COPCON, 8'h00);
        wr(`RM_COPX, 0); wr(`RM_COPY, 0); wr(`RM_COPFLAGS, 0);
        for (i = 0; i < 8; i = i + 1) wr(`RM_COPR0 + i[12:0], 0);
        // A COPJMP1 with the copper off does nothing
        wr(`RM_COPJMP1, 0);
        rdchk("COPJMP1 with EN clear", `RM_COPSTAT, 8'h02);

        // ---- the lists
        n = 0;
        forever begin
            la  = {mem[n*4+1][5:0], mem[n*4]};
            fl  = mem[n*4+1][15:8];
            l2a = {mem[n*4+3][5:0], mem[n*4+2]};
            nf  = mem[n*4+3][15:8];
            if (fl == 8'hFF) begin
                $fclose(log);
                $display("cop: %0d tests run, %0d register checks, %0d errors", n, checks, errors);
                if (errors == 0) $display("TEST PASSED");
                else             $display("TEST FAILED");
                $finish;
            end
            // Set up, the copper off: its registers as after reset
            wr(`RM_COPCON, 8'h00);
            wr(`RM_COPSTAT, 8'h0C);
            wr(`RM_COPSP, 8'h00);
            wr(`RM_COPX, 0); wr(`RM_COPY, 0); wr(`RM_COPFLAGS, 0);
            for (i = 0; i < 8; i = i + 1) wr(`RM_COPR0 + i[12:0], 0);
            wr(`RM_COP1LC0, la[7:0]);  wr(`RM_COP1LC1, la[15:8]);  wr(`RM_COP1LC2, {2'd0, la[21:16]});
            wr(`RM_COP2LC0, l2a[7:0]); wr(`RM_COP2LC1, l2a[15:8]); wr(`RM_COP2LC2, {2'd0, l2a[21:16]});
            tb_busy = fl[5];
            wr(`RM_COPCON, {2'd0, fl[1] ? 2'd1 : 2'd0, fl[3], fl[2], fl[4], 1'b1});
            $fwrite(log, "T %0d\n", n);
            if (fl[0]) begin
                @(negedge clk); jump_beam = 1;
                @(negedge clk); jump_beam = 0;
            end else begin
                @(negedge clk); jump_mid = 1;
                @(negedge clk); jump_mid = 0;
                wr(`RM_COPJMP1, 0);
            end
            // Run: until it stops (and no restart is due), or for the frames
            t0 = clocks;
            tf = 0;
            fr = 0;
            stopped = 0;
            while (!stopped && clocks - t0 < 12000000) begin
                @(negedge clk);
                if (vbl) begin
                    fr = fr + 1;
                    tf = clocks;
                end
                if (nf == 0) stopped = (dut.xs == 3'd0) && (!fl[0] || (fr >= 1 && clocks > tf + 4));
                else         stopped = (fr > nf);
            end
            if (!stopped) begin
                $display("ERROR: test %0d did not end", n);
                errors = errors + 1;
            end
            // Stopped: no frame restart until its state is read
            if (nf == 0) dma_on = 0;
            tb_busy = 0;
            if (nf != 0) begin                        // stop it where it is, a little into the frame
                repeat (2000) @(posedge clk);
                wr(`RM_COPCON, 8'h00);
            end
            state;
            dma_on = 1;
            n = n + 1;
        end
    end
endmodule
