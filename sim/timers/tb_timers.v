// Unit test of the timers (fpga/rtl/timers.v, spec 9) through their own
// ports: the register bus with its capture path (rb_cdata, rb_cap), the
// microsecond, line and frame ticks, the interrupt requests, the DMA start
// lines and the watchdog's reset. The whole machine (the bus interface's
// capture, the interrupts taken, the real beam, the watchdog resetting the
// computer) is tested by sim/timertest/timertest.asm in tb.v; this test
// measures every rate to the clock, which a program cannot.
//
// Underflows are seen on the DMA start lines: with CTRL.DMA each underflow
// is a 1-clock pulse on line CTRL.DMACH, so periods are counted in clocks.
`timescale 1ns/1ps
`include "regmap.vh"

module tb_timers;
    reg         clk = 0, por = 1, rst = 1;
    always #5 clk = !clk;

    reg         rb_rd = 0, rb_wr = 0;
    reg  [12:0] rb_addr = 0;
    reg  [7:0]  rb_wdata = 0;
    wire [7:0]  rb_rdata;
    wire        rb_hit, rb_cap;
    wire [31:0] rb_cdata;
    reg         line_tick = 0, frame_tick = 0;
    wire [3:0]  irq, dma_start;
    wire        wd_reset;

    // The microsecond tick, as retroz80.v makes it
    reg  [6:0]  us_div = 0;
    wire        us_tick = (us_div == 7'd99);
    always @(posedge clk) us_div <= (por || us_tick) ? 7'd0 : us_div + 1'b1;

    timers dut (
        .clk(clk), .por(por), .rst(rst),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
        .rb_rdata(rb_rdata), .rb_hit(rb_hit), .rb_cdata(rb_cdata), .rb_cap(rb_cap),
        .us_tick(us_tick), .line_tick(line_tick), .frame_tick(frame_tick),
        .irq(irq), .dma_start(dma_start), .wd_reset(wd_reset)
    );

    integer errors = 0, checks = 0;
    task check(input [8*56-1:0] what, input [31:0] got, input [31:0] want);
        begin
            checks = checks + 1;
            if (got !== want) begin
                $display("ERROR: %0s: %0d (%h), expected %0d (%h)", what, got, got, want, want);
                errors = errors + 1;
            end
        end
    endtask
    task check_in(input [8*56-1:0] what, input [31:0] got, input [31:0] lo, input [31:0] hi);
        begin
            checks = checks + 1;
            if (got < lo || got > hi) begin
                $display("ERROR: %0s: %0d, expected %0d-%0d", what, got, lo, hi);
                errors = errors + 1;
            end
        end
    endtask

    // Clocks, counted at each falling edge, so the count is steady at the
    // rising edges where it is read
    integer clocks = 0;
    always @(negedge clk) clocks = clocks + 1;

    // Register bus: each access one clock, set up at the falling edge
    integer wr_at;                     // the clock count of the last write's edge
    task wr(input [12:0] a, input [7:0] d);
        begin
            @(negedge clk); rb_addr = a; rb_wdata = d; rb_wr = 1;
            @(posedge clk); wr_at = clocks;
            @(negedge clk); rb_wr = 0;
        end
    endtask
    reg [7:0]  rd_v;
    reg        rd_h, rd_c;
    reg [31:0] rd_cd;
    task rd(input [12:0] a);
        begin
            @(negedge clk); rb_addr = a; rb_rd = 1;
            @(negedge clk); rb_rd = 0; rd_v = rb_rdata; rd_h = rb_hit; rd_c = rb_cap; rd_cd = rb_cdata;
        end
    endtask
    task rdchk(input [8*56-1:0] what, input [12:0] a, input [7:0] want);
        begin
            rd(a);
            check(what, rd_v, want);
            check({what, " (answered)"}, rd_h, 1);
        end
    endtask

    function [12:0] T(input integer n, input [7:0] off);   // timer n's register
        T = `RM_TMR_BASE + n * `RM_TMR_SPAN + off;
    endfunction
    task tset(input integer n, input [7:0] ctrl, input [15:0] pre, input [15:0] rel, input [15:0] cnt);
        begin
            wr(T(n, `RM_TMR_CTRL), 8'h00);
            wr(T(n, `RM_TMR_STAT), 8'h01);
            wr(T(n, `RM_TMR_PRESCALE), pre[7:0]);
            wr(T(n, `RM_TMR_PRESCALE + 1), pre[15:8]);
            wr(T(n, `RM_TMR_RELOAD), rel[7:0]);
            wr(T(n, `RM_TMR_RELOAD + 1), rel[15:8]);
            wr(T(n, `RM_TMR_COUNT), cnt[7:0]);
            wr(T(n, `RM_TMR_COUNT + 1), cnt[15:8]);
            wr(T(n, `RM_TMR_CTRL), ctrl);
        end
    endtask
    localparam [7:0] EN = 8'h01, REP = 8'h02, IRQ = 8'h10, DMA = 8'h20;
    function [7:0] SRC(input integer s); SRC = s << 2; endfunction
    function [7:0] CH(input integer c);  CH = c << 6;  endfunction

    // Underflow pulses on the DMA start lines: the clock count of each
    integer pulses [0:3];
    integer last_at [0:3];
    integer prev_at [0:3];
    integer q;
    initial for (q = 0; q < 4; q = q + 1) begin pulses[q] = 0; last_at[q] = 0; prev_at[q] = 0; end
    always @(posedge clk) for (q = 0; q < 4; q = q + 1) if (dma_start[q]) begin
        pulses[q]  = pulses[q] + 1;
        prev_at[q] = last_at[q];
        last_at[q] = clocks;
    end
    task wait_pulses(input integer ch, input integer n);
        integer w;
        begin
            w = 0;
            while (pulses[ch] < n && w < 50000000) begin @(posedge clk); w = w + 1; end
            #1;
        end
    endtask
    task clear_pulses; begin for (q = 0; q < 4; q = q + 1) pulses[q] = 0; end endtask

    task line(input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                @(negedge clk); line_tick = 1;
                @(negedge clk); line_tick = 0;
                repeat (5) @(negedge clk);
            end
        end
    endtask
    task frame(input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                @(negedge clk); frame_tick = 1;
                @(negedge clk); frame_tick = 0;
                repeat (5) @(negedge clk);
            end
        end
    endtask

    integer n, p, r, t0, t1, wds, wdat, k;
    reg [31:0] tv;
    reg [15:0] cv;
    initial begin
        repeat (4) @(negedge clk);
        por = 0;
        @(negedge clk);
        rst = 0;

        // ---- reset values (section 6)
        for (n = 0; n < 4; n = n + 1)
            for (k = 0; k < 8; k = k + 1) rdchk("timer register at reset", T(n, k), 8'h00);
        rdchk("WDCTRL at reset", `RM_WDCTRL, 8'h00);
        rdchk("WDTIME0 at reset", `RM_WDTIME0, 8'hE8);
        rdchk("WDTIME1 at reset", `RM_WDTIME1, 8'h03);
        rdchk("WDKICK reads 0", `RM_WDKICK, 8'h00);
        rd(13'h024); check("register 0x24 reserved", rd_h, 0);
        rd(13'h027); check("register 0x27 reserved", rd_h, 0);
        rd(13'h04C); check("register 0x4C reserved", rd_h, 0);
        rd(13'h01F); check("register 0x1F not ours", rd_h, 0);
        rd(13'h1020); check("custom 0x020 not ours", rd_h, 0);
        check("no requests at reset", irq, 0);

        // ---- TIME: once per 100 clocks; TIME0 captures all 32 bits
        rd(`RM_TIME0);
        check("TIME0 answers", rd_h, 1);
        check("TIME0 captures", rd_c, 1);
        check("TIME0 is the capture's low byte", rd_v, rd_cd[7:0]);
        tv = rd_cd;
        repeat (1000) @(negedge clk);
        rd(`RM_TIME0);
        check_in("TIME after 1002 clocks", rd_cd - tv, 10, 11);
        rd(`RM_TIME1);
        check("TIME1 does not capture", rd_c, 0);
        rd(`RM_TIME3);
        check("TIME3 live", rd_v, 8'h00);
        // Exactly 100 clocks a microsecond, over 100 us
        @(posedge us_tick); @(negedge clk);
        rd(`RM_TIME0); tv = rd_cd;
        repeat (9998) @(negedge clk);   // the read took 2 clocks: 10,000 in all
        rd(`RM_TIME0);
        check("TIME: 100 us in 10,000 clocks", rd_cd - tv, 100);
        // TIME1 reads the live byte: TIME bits 15-8
        rd(`RM_TIME0); tv = rd_cd;
        rd(`RM_TIME1);
        check("TIME1 live", rd_v, tv[15:8]);

        // ---- byte writes: each byte alone
        wr(T(1, `RM_TMR_PRESCALE), 8'h34);
        rdchk("PRESCALE0 written alone", T(1, `RM_TMR_PRESCALE), 8'h34);
        rdchk("PRESCALE1 untouched", T(1, `RM_TMR_PRESCALE + 1), 8'h00);
        wr(T(1, `RM_TMR_PRESCALE + 1), 8'h12);
        rdchk("PRESCALE1 written", T(1, `RM_TMR_PRESCALE + 1), 8'h12);
        rdchk("PRESCALE0 kept", T(1, `RM_TMR_PRESCALE), 8'h34);
        wr(T(2, `RM_TMR_RELOAD + 1), 8'hAB);
        rdchk("RELOAD1 written alone", T(2, `RM_TMR_RELOAD + 1), 8'hAB);
        rdchk("RELOAD0 untouched", T(2, `RM_TMR_RELOAD), 8'h00);
        wr(T(3, `RM_TMR_COUNT + 1), 8'h56);
        wr(T(3, `RM_TMR_COUNT), 8'h78);
        rd(T(3, `RM_TMR_COUNT));
        check("COUNT0 read", rd_v, 8'h78);
        check("COUNT0 captures", rd_c, 1);
        check("COUNT0's capture is the count", rd_cd, 32'h5678);
        rd(T(3, `RM_TMR_COUNT + 1));
        check("COUNT1 does not capture", rd_c, 0);
        check("COUNT1 live", rd_v, 8'h56);
        wr(T(3, `RM_TMR_COUNT), 8'h00);
        rd(T(3, `RM_TMR_COUNT)); check("COUNT0 alone changes bits 7-0 only", rd_cd, 32'h5600);
        wr(T(0, `RM_TMR_CTRL), 8'hFE);
        rdchk("CTRL keeps every bit", T(0, `RM_TMR_CTRL), 8'hFE);
        wr(T(0, `RM_TMR_CTRL), 8'h00);
        for (n = 0; n < 4; n = n + 1)
            for (k = 1; k < 7; k = k + 1) wr(T(n, k), 8'h00);

        // ---- SRC 0: period (PRESCALE + 1) x (RELOAD + 1), the first one too
        for (n = 0; n < 4; n = n + 1) begin
            p = n == 0 ? 0 : n == 1 ? 1 : n == 2 ? 99 : 4;
            r = n == 0 ? 9 : n == 1 ? 0 : n == 2 ? 2 : 300;
            clear_pulses;
            tset(n, EN | REP | DMA | CH(n) | SRC(0), p, r, r);
            t0 = wr_at;
            wait_pulses(n, 1);
            // The pulse is seen a clock after the underflow's edge
            check("SRC 0: first period, from EN", last_at[n] - t0, (p + 1) * (r + 1) + 1);
            wait_pulses(n, 3);
            check("SRC 0: period", last_at[n] - prev_at[n], (p + 1) * (r + 1));
            rdchk("SRC 0: UNDER set", T(n, `RM_TMR_STAT), 8'h01);
            wr(T(n, `RM_TMR_CTRL), 8'h00);
        end
        // The 1 us tick of section 4.4: PRESCALE 99
        clear_pulses;
        tset(1, EN | REP | DMA | CH(2) | SRC(0), 99, 999, 999);
        wait_pulses(2, 2);
        check("PRESCALE 99, RELOAD 999: 1 ms", last_at[2] - prev_at[2], 100000);
        wr(T(1, `RM_TMR_CTRL), 8'h00);
        // A prescaler wider than 8 bits
        clear_pulses;
        tset(2, EN | REP | DMA | CH(3) | SRC(0), 16'h0123, 1, 1);
        wait_pulses(3, 2);
        check("PRESCALE 0x123, RELOAD 1", last_at[3] - prev_at[3], 2 * 16'h124);
        wr(T(2, `RM_TMR_CTRL), 8'h00);

        // ---- SRC 1 and 2: every RELOAD + 1 lines or frames
        for (n = 0; n < 4; n = n + 1) begin
            clear_pulses;
            tset(n, EN | REP | DMA | CH(0) | SRC(1), 0, 2, 2);
            line(8);
            check("SRC 1: RELOAD 2 underflows every 3 lines", pulses[0], 2);
            line(1);
            check("SRC 1: the third underflow at line 9", pulses[0], 3);
            frame(5);
            check("SRC 1 ignores frames", pulses[0], 3);
            clear_pulses;
            tset(n, EN | REP | DMA | CH(1) | SRC(2), 0, 1, 1);
            frame(5);
            check("SRC 2: RELOAD 1 underflows every 2 frames", pulses[1], 2);
            line(10);
            check("SRC 2 ignores lines", pulses[1], 2);
            frame(1);
            check("SRC 2: the third underflow at frame 6", pulses[1], 3);
            wr(T(n, `RM_TMR_CTRL), 8'h00);
        end

        // ---- one-shot: one underflow, EN cleared, COUNT left at 0
        clear_pulses;
        tset(2, EN | DMA | CH(2) | SRC(1), 0, 7, 3);
        line(10);
        check("one-shot: one underflow", pulses[2], 1);
        rdchk("one-shot: EN cleared", T(2, `RM_TMR_CTRL), DMA | CH(2) | SRC(1));
        rd(T(2, `RM_TMR_COUNT)); check("one-shot: COUNT stays 0", rd_cd, 0);
        // Starting again from 0: one tick to the next underflow
        wr(T(2, `RM_TMR_CTRL), EN | DMA | CH(2) | SRC(1));
        line(1);
        check("one-shot from 0: underflows at the first tick", pulses[2], 2);

        // ---- RELOAD changes only at the next underflow; stopping keeps COUNT
        clear_pulses;
        tset(0, EN | REP | DMA | CH(0) | SRC(1), 0, 4, 4);
        line(2);
        wr(T(0, `RM_TMR_RELOAD), 8'd1);
        rd(T(0, `RM_TMR_COUNT)); check("RELOAD write leaves COUNT", rd_cd, 2);
        line(3);
        check("the period running when RELOAD changed ends as it was", pulses[0], 1);
        line(4);
        check("then every RELOAD + 1 = 2 lines", pulses[0], 3);
        wr(T(0, `RM_TMR_CTRL), REP | DMA | CH(0) | SRC(1));
        rd(T(0, `RM_TMR_COUNT)); cv = rd_cd[15:0];
        line(5);
        rd(T(0, `RM_TMR_COUNT)); check("stopped: COUNT kept", rd_cd, cv);
        check("stopped: no underflow", pulses[0], 3);
        wr(T(0, `RM_TMR_CTRL), EN | REP | DMA | CH(0) | SRC(1));
        line(1);
        rd(T(0, `RM_TMR_COUNT)); check("started again: carries on", rd_cd, cv - 1);
        wr(T(0, `RM_TMR_CTRL), 8'h00);

        // ---- SRC 3: each timer counts the one before (0 counts 3)
        for (n = 0; n < 4; n = n + 1) begin
            clear_pulses;
            tset((n + 3) % 4, EN | REP | SRC(1), 0, 1, 1);         // underflows every 2 lines
            tset(n, EN | REP | DMA | CH(n) | SRC(3), 0, 2, 2);    // every 3 of those
            line(11);
            check("SRC 3: no underflow before 6 lines x ... ", pulses[n], 1);
            line(1);
            check("SRC 3: counts the previous timer's underflows", pulses[n], 2);
            // Only while the previous timer runs
            wr(T((n + 3) % 4, `RM_TMR_CTRL), REP | SRC(1));
            line(12);
            check("SRC 3: nothing while the previous timer is stopped", pulses[n], 2);
            wr(T(n, `RM_TMR_CTRL), 8'h00);
        end
        // The 1-second example, scaled: timer 0 at 1 us x 10, timer 1 counts 5 of those
        clear_pulses;
        tset(1, EN | REP | DMA | CH(1) | SRC(3), 0, 4, 4);
        tset(0, EN | REP | SRC(0), 99, 9, 9);
        wait_pulses(1, 2);
        check("chained: 10 us x 5", last_at[1] - prev_at[1], 5000);
        wr(T(0, `RM_TMR_CTRL), 8'h00);
        wr(T(1, `RM_TMR_CTRL), 8'h00);

        // ---- interrupts: UNDER with IRQ off; the request while UNDER and IRQ
        for (n = 0; n < 4; n = n + 1) begin
            tset(n, EN | SRC(1), 0, 0, 0);
            line(1);
            rdchk("UNDER set with IRQ off", T(n, `RM_TMR_STAT), 8'h01);
            check("no request with IRQ off", irq, 0);
            wr(T(n, `RM_TMR_CTRL), IRQ | SRC(1));
            @(negedge clk);
            check("request while UNDER and IRQ", irq, 1 << n);
            wr(T(n, `RM_TMR_STAT), 8'hFE);
            check("STAT: writing 0 leaves UNDER", irq, 1 << n);
            wr(T(n, `RM_TMR_STAT), 8'h01);
            check("request drops when UNDER is cleared", irq, 0);
            rdchk("UNDER cleared", T(n, `RM_TMR_STAT), 8'h00);
            wr(T(n, `RM_TMR_CTRL), 8'h00);
        end

        // ---- reading COUNT across a high-byte borrow: the capture is whole
        tset(1, EN | REP | SRC(0), 0, 16'hFFFF, 16'h0104);
        rd(T(1, `RM_TMR_COUNT));
        check("COUNT capture near a borrow", rd_cd[15:8] == 8'h01 || rd_cd[15:8] == 8'h00, 1);
        check("COUNT capture's low byte is the byte read", rd_cd[7:0], rd_v);
        wr(T(1, `RM_TMR_CTRL), 8'h00);

        // ---- a general reset stops the timers; TIME runs on
        tset(0, EN | REP | SRC(0), 7, 7, 7);
        rd(`RM_TIME0); tv = rd_cd;
        @(negedge clk); rst = 1; repeat (3) @(negedge clk); rst = 0;
        rdchk("CTRL after reset", T(0, `RM_TMR_CTRL), 8'h00);
        rdchk("PRESCALE0 after reset", T(0, `RM_TMR_PRESCALE), 8'h00);
        rd(`RM_TIME0);
        check("TIME not reset by rst", rd_cd >= tv, 1);

        // ---- watchdog
        // Off: kicks ignored, even wrong ones
        wr(`RM_WDKICK, 8'h00);
        repeat (5) @(negedge clk);
        check("watchdog off: a wrong kick is ignored", wds, 0);
        // WDTIME 2: fires 2-3 ms after the WDCTRL write
        wr(`RM_WDTIME0, 8'd2);
        wr(`RM_WDTIME1, 8'd0);
        rdchk("WDTIME0 written", `RM_WDTIME0, 8'd2);
        rdchk("WDTIME1 written", `RM_WDTIME1, 8'd0);
        wds = 0;
        wr(`RM_WDCTRL, 8'h01);
        t0 = wr_at;
        rdchk("WDCTRL.EN", `RM_WDCTRL, 8'h01);
        // Kick at 1.5 ms twice: no reset
        for (k = 0; k < 2; k = k + 1) begin
            repeat (150000) @(negedge clk);
            check("kicked in time: no reset", wds, 0);
            wr(`RM_WDKICK, 8'h5A);
            t0 = wr_at;
        end
        wait (wds == 1);
        check_in("fires 2-3 ms after the last kick", wdat - t0, 200000, 300000);
        @(negedge clk); rst = 1; repeat (3) @(negedge clk); rst = 0;
        rdchk("watchdog off after a reset", `RM_WDCTRL, 8'h00);
        rdchk("WDTIME 1000 after a reset", `RM_WDTIME0, 8'hE8);
        // WDTIME 0 acts as 1
        wr(`RM_WDTIME0, 8'd0);
        wr(`RM_WDTIME1, 8'd0);
        wds = 0;
        wr(`RM_WDCTRL, 8'h01);
        t0 = wr_at;
        wait (wds == 1);
        check_in("WDTIME 0 acts as 1: fires 1-2 ms after", wdat - t0, 100000, 200000);
        @(negedge clk); rst = 1; repeat (3) @(negedge clk); rst = 0;
        // A wrong kick value resets at once
        wds = 0;
        wr(`RM_WDCTRL, 8'h01);
        wr(`RM_WDKICK, 8'h5B);
        t0 = wr_at;
        repeat (3) @(negedge clk);
        check("a wrong kick resets at once", wds, 1);
        check("... in the clock after", wdat - t0, 1);
        @(negedge clk); rst = 1; repeat (3) @(negedge clk); rst = 0;
        // LOCK: WDCTRL and WDTIME read only until reset
        wr(`RM_WDTIME0, 8'd5);
        wr(`RM_WDCTRL, 8'h03);
        rdchk("WDCTRL EN and LOCK", `RM_WDCTRL, 8'h03);
        wr(`RM_WDCTRL, 8'h00);
        rdchk("locked: WDCTRL write ignored", `RM_WDCTRL, 8'h03);
        wr(`RM_WDTIME0, 8'd9);
        wr(`RM_WDTIME1, 8'd9);
        rdchk("locked: WDTIME0 write ignored", `RM_WDTIME0, 8'd5);
        rdchk("locked: WDTIME1 write ignored", `RM_WDTIME1, 8'h03);
        wr(`RM_WDKICK, 8'h5A);
        rdchk("locked: kicks still work", `RM_WDCTRL, 8'h03);
        @(negedge clk); rst = 1; repeat (3) @(negedge clk); rst = 0;
        rdchk("unlocked after a reset", `RM_WDCTRL, 8'h00);
        wr(`RM_WDTIME0, 8'd9);
        rdchk("WDTIME writable after a reset", `RM_WDTIME0, 8'd9);

        // ---- TIME: only power-on resets it
        rd(`RM_TIME0); tv = rd_cd;
        check("TIME is past 5 ms", tv > 5000, 1);
        @(negedge clk); por = 1; rst = 1; repeat (3) @(negedge clk); por = 0; rst = 0;
        rd(`RM_TIME0);
        check("TIME starts again at power-on", rd_cd < 2, 1);

        $display("---- %0d checks, %0d errors", checks, errors);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED");
        $finish;
    end

    // The watchdog's reset pulses
    initial wds = 0;
    always @(posedge clk) if (wd_reset) begin wds = wds + 1; wdat = clocks; end

    initial begin
        #200_000_000;
        $display("TEST FAILED: timeout");
        $finish;
    end
endmodule
