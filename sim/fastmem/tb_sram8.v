// The fast-memory SRAM controller on its own (issue #91): sram_ctl8.v and
// the SERDES pads (sram8_pads.v, on sramtest/xilinx_models.v) against the
// timing-checking SRAM (sramtest/sram_timed.v, the KS2's -8 part). Every
// cycle the controller offers is given a random read, write (either byte,
// or both) or nothing, over a small region, kept in a copy here.
//
// Checks: each read's data comes back once, in order, with its tag, at the
// latency the slot plan says (4 clocks, 5 for cycles 2 and 6), and is the
// copy's word; no two results in one clock; no SRAM timing error or bus
// contention; the CPU's cycles (3 and 7) come at slot edges 4 and 9.
// /WE is low over steps 2-8 here (the system testbench's), within the
// -8 part's datasheet; the KS2 build's 3-7 is shorter than its tPWE.
`timescale 1ns/1ps
module tb_sram8;
    reg clk = 1'b1, clk200 = 1'b1, clk400 = 1'b1;
    always #5    clk    = ~clk;
    always #2.5  clk200 = ~clk200;
    always #1.25 clk400 = ~clk400;

    reg rst = 1'b1;
    reg [1:0] rst200 = 2'b11;
    always @(posedge clk200) rst200 <= {rst200[0], rst};

    reg [3:0] sc = 4'd0;
    always @(posedge clk) sc <= rst ? 4'd0 : (sc == 4'd9) ? 4'd0 : sc + 4'd1;

    reg         go = 1'b0, go_we = 1'b0;
    reg  [21:1] go_addr = 21'd0;
    reg  [15:0] go_wdata = 16'd0;
    reg  [1:0]  go_be = 2'b11;
    reg  [2:0]  go_tag = 3'd0;
    wire        start_next, rvalid;
    wire [2:0]  next_cycle, rtag;
    wire [15:0] rdata;
    wire [167:0] w_a;
    wire [7:0]  w_cs, w_oe, w_we, w_lb, w_ub, w_t;
    wire [127:0] w_dq, qs;

    sram_ctl8 #(.AW(21), .WE_LO(4'd2), .WE_HI(4'd8)) ctl (
        .clk(clk), .rst(rst), .sc(sc),
        .go(go), .go_we(go_we), .go_addr(go_addr), .go_wdata(go_wdata), .go_be(go_be), .go_tag(go_tag),
        .start_next(start_next), .next_cycle(next_cycle), .rvalid(rvalid), .rtag(rtag), .rdata(rdata),
        .w_addr(w_a), .w_cs_n(w_cs), .w_oe_n(w_oe), .w_we_n(w_we), .w_lb_n(w_lb), .w_ub_n(w_ub),
        .w_dq(w_dq), .w_dq_t(w_t), .qs(qs)
    );

    wire [20:0] a_f;
    wire [15:0] dq;
    wire        cs_f, oe_f, we_f, lb_f, ub_f;
    sram8_pads #(.AW(21), .TAPS(8)) pads (
        .clk100(clk), .clk200(clk200), .clk400(clk400), .rst100(rst), .rst200(rst200[1]),
        .addr_w(w_a), .cs_n_w(w_cs), .oe_n_w(w_oe), .we_n_w(w_we), .lb_n_w(w_lb), .ub_n_w(w_ub),
        .dq_w(w_dq), .dq_t_w(w_t), .qs(qs),
        .ram_addr_o(a_f), .ram_data_io(dq),
        .ram_cs_n_o(cs_f), .ram_oe_n_o(oe_f), .ram_we_n_o(we_f), .ram_lb_n_o(lb_f), .ram_ub_n_o(ub_f)
    );
    reg [20:0] a_p = 21'd0;
    reg        cs_p = 1'b1, oe_p = 1'b1, we_p = 1'b1, lb_p = 1'b1, ub_p = 1'b1;
    always @(a_f)  a_p  <= #2.5 a_f;
    always @(cs_f) cs_p <= #2.5 cs_f;
    always @(oe_f) oe_p <= #2.5 oe_f;
    always @(we_f) we_p <= #2.5 we_f;
    always @(lb_f) lb_p <= #2.5 lb_f;
    always @(ub_f) ub_p <= #2.5 ub_f;
    genvar g;
    generate for (g = 0; g < 16; g = g + 1) begin : pu
        pullup (dq[g]);
    end endgenerate
    sram_timed #(.PART(8), .AW(21)) sram (
        .a(a_p), .dq(dq), .ce_n(cs_p), .oe_n(oe_p), .we_n(we_p), .ub_n(ub_p), .lb_n(lb_p),
        .fpga_drives(!pads.dq[0].io.t_d)
    );

    // ---------------------------------------------------------------- stimulus and checks
    // The region: words 0x1FFF0-0x2000F (address bit 16 and 17 both ways)
    // and the top word, so every address line moves
    reg  [15:0] copy [0:63];
    reg  [5:0]  q_slot [0:63];          // reads waiting: copy slot ...
    reg  [15:0] q_want [0:63];          // ... the word expected, its tag, the clock it is due
    reg  [2:0]  q_tag  [0:63];
    integer     q_due  [0:63];
    integer     qh = 0, qt = 0, clocks = 0, nrd = 0, nwr = 0, errors = 0, k, phase;
    integer     cpu_seen = 0;
    reg  [5:0]  slot;
    reg         rnd_we;
    reg  [1:0]  rnd_be;
    reg  [15:0] w;
    function [20:0] word_of(input [5:0] s);
        word_of = (s == 6'd63) ? 21'h1FFFFF : 21'h1FFF0 + s;
    endfunction
    task fail(input [8*64-1:0] what);
        begin
            if (errors < 20) $display("%t FAIL: %0s", $realtime, what);
            errors = errors + 1;
        end
    endtask

    integer seed = 1;
    reg     stopping = 1'b0;            // no new cycles: the last reads come back
    always @(posedge clk) begin
        clocks = clocks + 1;
        // Results: one at a time, in order, on time, right
        if (!rst && rvalid) begin
            if (qh == qt) fail("read data with no read waiting");
            else begin
                if (rtag !== q_tag[qh % 64]) fail("read data with the wrong tag");
                if (clocks != q_due[qh % 64]) begin
                    $display("%t   due %0d, came %0d", $realtime, q_due[qh % 64], clocks);
                    fail("read data at the wrong clock");
                end
                if (rdata !== q_want[qh % 64]) begin
                    $display("%t   word %h: read %h, expected %h", $realtime, word_of(q_slot[qh % 64]),
                             rdata, q_want[qh % 64]);
                    fail("read data wrong");
                end
                qh = qh + 1;
            end
        end
    end
    // The next cycle: decided in the clock before its edge, as dmac8 does
    // (here at the falling edge, where sc is this clock's)
    always @(negedge clk) begin
        go <= 1'b0;
        if (!rst && !stopping && start_next && clocks > 40) begin
            if ((next_cycle == 3'd3 || next_cycle == 3'd7) && !(sc == 4'd3 || sc == 4'd8))
                fail("cycle 3 or 7 not at slot edge 4 or 9");
            if (next_cycle == 3'd3 || next_cycle == 3'd7) cpu_seen = cpu_seen + 1;
            phase = $random(seed) & 7;
            if (phase != 0) begin
                slot   = $random(seed);
                rnd_we = $random(seed);
                rnd_be = $random(seed);
                if (rnd_be == 2'b00) rnd_be = 2'b11;
                w      = $random(seed);
                go       <= 1'b1;
                go_we    <= rnd_we;
                go_addr  <= word_of(slot);
                go_wdata <= w;
                go_be    <= rnd_we ? rnd_be : 2'b11;
                go_tag   <= next_cycle;
                if (rnd_we) begin
                    if (rnd_be[0]) copy[slot][7:0]  = w[7:0];
                    if (rnd_be[1]) copy[slot][15:8] = w[15:8];
                    nwr = nwr + 1;
                end else begin
                    q_slot[qt % 64] = slot;
                    q_want[qt % 64] = copy[slot];
                    q_tag[qt % 64]  = next_cycle;
                    // given out at the coming edge, number clocks + 1; data
                    // in the clock after that edge + 4 (+ 5 for cycles 2
                    // and 6), seen at the edge after
                    q_due[qt % 64]  = clocks + 2 + ((next_cycle == 3'd2 || next_cycle == 3'd6) ? 5 : 4);
                    qt = qt + 1;
                    nrd = nrd + 1;
                end
            end
        end
    end

    initial begin
        // Every word of the region written first, so reads have data
        for (k = 0; k < 64; k = k + 1) begin
            copy[k] = 16'h1234 ^ (k * 16'h0F1F);
            sram.mem[word_of(k[5:0])] = copy[k];
        end
        #2001 rst = 1'b0;
        #399000 stopping = 1'b1;
        #1000;
        if (qh != qt) fail("reads still waiting at the end");
        if (cpu_seen == 0) fail("no CPU cycles");
        $display("---- %0d reads, %0d writes, %0d SRAM errors", nrd, nwr, sram.errors);
        if (errors == 0 && sram.errors == 0) $display("TEST PASSED");
        else $display("TEST FAILED: %0d errors", errors + sram.errors);
        $finish;
    end
endmodule
