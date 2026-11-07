// The SRAM tester (issue #90) as built for the KS2 (top_ks2_sramtest.v),
// against a timing-checking SRAM (sram_timed.v), driven over the FT232H
// model as tools/sramtest.py drives it. The Xilinx primitives are the
// behavioural models in xilinx_models.v (checked against Vivado's unisims
// by tb_lat.v); the pads add 2.5 ns out and 1 ns in.
//
// Checks: the default settings (sram_ctl's 20 ns cycle) pass with every
// sequence and data pattern, with no timing error in the SRAM; the scope
// shows the FPGA's own drive at the step the pad delays give; a capture
// sweep has its window round the default; 15 ns and 35 ns cycles pass;
// and settings outside the datasheet fail: a capture too early, a /WE
// pulse below tPWE, and driving DQ before the SRAM lets go after a read.
`timescale 1ns/1ps
module tb_sramtest;
    reg clk50 = 1'b0;
    always #10 clk50 = !clk50;

    wire [19:0] a_f;
    wire        cs_f, oe_f, we_f, lb_f, ub_f;
    wire [15:0] dq;
    wire [12:0] accel;

    top_ks2_sramtest dut (
        .clock_50_i(clk50),
        .ram_addr_o(a_f), .ram_data_io(dq),
        .ram_lb_n_o(lb_f), .ram_ub_n_o(ub_f), .ram_oe_n_o(oe_f), .ram_we_n_o(we_f), .ram_cs_n_o(cs_f),
        .accel_io(accel),
        .rgb_r_o(), .rgb_g_o(), .rgb_b_o(), .hsync_o(), .vsync_o(), .hdmi_p_o(), .hdmi_n_o(),
        .flash_cs_n_o(), .sd_cs0_n_o(), .sd_cs1_n_o(),
        .audioext_l_o(), .audioext_r_o(), .audioint_o(), .mic_port_o(),
        .joysel_o(), .keyb_row_o(), .bus_ramcs_io()
    );

    // The output pads' delay on the output-only pins (IOBUF has its own)
    reg [19:0] a_p = 20'd0;
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
    generate for (g = 0; g < 13; g = g + 1) begin : pa
        pullup (accel[g]);
    end endgenerate

    `ifndef PART
    `define PART 10
    `endif
    sram_timed #(.PART(`PART)) sram (
        .a(a_p), .dq(dq), .ce_n(cs_p), .oe_n(oe_p), .we_n(we_p), .ub_n(ub_p), .lb_n(lb_p),
        .fpga_drives(!dut.pads.dq[0].io.t_d)
    );

    ft_model ft (.d(accel[7:0]), .rxf_n(accel[8]), .txe_n(accel[9]),
                 .rd_n(accel[10]), .wr_n(accel[11]), .siwu_n(accel[12]));

    // ---------------------------------------------------------------- the link, as sramtest.py
    integer rx = 0, fails = 0;
    task get(output [7:0] b);
        begin
            wait (ft.nout > rx);
            b  = ft.from_fpga[rx];
            rx = rx + 1;
        end
    endtask
    task fail(input [8*64-1:0] what);
        begin
            $display("FAIL: %0s", what);
            fails = fails + 1;
        end
    endtask
    task setw(input [4:0] i, input [15:0] v);
        reg [7:0] r;
        begin
            ft.send("W"); ft.send({3'd0, i}); ft.send(v[7:0]); ft.send(v[15:8]);
            get(r);
            if (r != "w") fail("no reply to W");
        end
    endtask
    task runp;
        reg [7:0] r;
        begin
            ft.send("R");
            get(r);
            if (r != "r") fail("no reply to R");
        end
    endtask
    task rd32(input [8:0] ad, output [31:0] v);
        reg [7:0] b0, b1, b2, b3;
        begin
            ft.send("D"); ft.send(ad[7:0]); ft.send({7'd0, ad[8]}); ft.send(8'd4);
            get(b0); get(b1); get(b2); get(b3);
            v = {b3, b2, b1, b0};
        end
    endtask
    task rd16(input [8:0] ad, output [15:0] v);
        reg [7:0] b0, b1;
        begin
            ft.send("D"); ft.send(ad[7:0]); ft.send({7'd0, ad[8]}); ft.send(8'd2);
            get(b0); get(b1);
            v = {b1, b0};
        end
    endtask

    // The 20 ns defaults (sramt_engine.v), a region of 64 words
    task defaults;
        begin
            setw(0, 16); setw(1, 4); setw(2, 16); setw(3, 16); setw(4, 0);
            setw(5, 4); setw(6, 12); setw(7, 4); setw(8, 16); setw(9, 4); setw(10, 12);
            setw(11, 0); setw(12, 0); setw(13, 0);
            setw(14, 16'hBC00); setw(15, 16'h000A); setw(16, 64); setw(17, 0);
            setw(18, 16'h1234); setw(19, 16'h5678); setw(20, 1); setw(21, 0); setw(22, 0);
        end
    endtask

    // Results of the last run
    reg [31:0] n_err, n_bus, n_rd, n_wr, f_addr;
    task results;
        begin
            rd32(9'h004, n_err); rd32(9'h008, n_bus); rd32(9'h00C, n_rd);
            rd32(9'h018, n_wr);  rd32(9'h010, f_addr);
        end
    endtask
    // A run that must pass: no read or bus errors, no SRAM timing errors
    task pass(input [8*64-1:0] name, input [31:0] reads, input [31:0] writes);
        begin
            sram.errors = 0;
            runp;
            results;
            $display("%0s: %0d read, %0d written, %0d errors, %0d bus errors, %0d SRAM timing errors",
                     name, n_rd, n_wr, n_err, n_bus, sram.errors);
            if (n_err != 0 || n_bus != 0 || sram.errors != 0) fail(name);
            if (n_rd != reads || n_wr != writes) fail({name, ": wrong number of words"});
        end
    endtask

    reg [31:0] v;
    reg [15:0] s7, s8, sk;
    integer    c, jj;
    reg [8*48-1:0] bar;
    initial begin
        #6000;                                  // the MMCM locks at 2 us, then reset
        rd32(9'h000, v);
        if (v != 32'h31545253) fail("no SRT1");

        // ---- the defaults pass, every pattern
        defaults;
        pass("20 ns, write then read, random", 64, 64);
        setw(11, 3); setw(12, 1);
        pass("20 ns, each word written then read, 0000/FFFF", 64, 64);
        setw(11, 0); setw(12, 2); setw(13, 1);
        pass("20 ns, walking ones on address and data", 21, 21);
        setw(12, 0); setw(13, 0); setw(20, 3);
        pass("20 ns, three passes", 192, 192);
        setw(20, 1);

        // ---- the scope on a write: 0x0000 after 0xFFFF. Cycle 4 drives from
        // step 4; the pads put 2.5 + 1 + 0.6 ns between the drive and its
        // sample, so steps 0-7 still read 0xFFFF and steps 8 on 0x0000.
        setw(11, 1); setw(12, 1); setw(21, 4);
        pass("20 ns, write only, 0000/FFFF", 0, 64);
        rd32(9'h01C, v);
        jj = v[13:8];
        $display("scope: cycle kind %0d, step 0 at sample %0d", v[1:0], jj);
        rd16(9'h060 + 2 * (jj + 7), s7);
        rd16(9'h060 + 2 * (jj + 8), s8);
        $display("scope: step 7 %h, step 8 %h", s7, s8);
        if (v[1:0] != 2'd2 || s7 != 16'hFFFF || s8 != 16'h0000) fail("scope");

        // ---- a capture sweep: write once, then read at each step
        defaults;
        setw(11, 1);
        pass("20 ns, write only", 0, 64);
        setw(11, 2);
        $display("capture sweep, 20 ns (# = a word wrong):");
        for (c = 8; c <= 26; c = c + 1) begin
            setw(3, c);
            runp;
            results;
            bar = "";
            for (jj = 0; jj < 32; jj = jj + 2) if (n_err > jj) bar = {bar, "#"};
            $display("  step %2d %3d %0s", c, n_err, bar);
            // Valid from tAA after the address (2.5 + 10 + 1.6 ns: step 11.3)
            // until /OE rises at step 16 (+ 4.1 ns: step 19.3)
            if (c >= 12 && c <= 19 && n_err != 0) fail("capture window too small");
            if ((c <= 10 || c >= 21) && n_err == 0) fail("capture outside the data passed");
        end
        setw(3, 6);
        runp; results;
        $display("capture at step 6: %0d errors (must fail)", n_err);
        if (n_err == 0) fail("capture at step 6 passed");

        // ---- other cycle lengths
        defaults;
        setw(0, 12); setw(1, 2); setw(2, 12); setw(3, 12); setw(5, 2); setw(6, 10);
        setw(7, 2); setw(8, 12); setw(9, 3); setw(10, 10); setw(11, 3); setw(12, 1);
        pass("15 ns, each word written then read", 64, 64);
        defaults;
        setw(0, 28); setw(2, 28); setw(3, 28); setw(6, 24); setw(8, 28); setw(10, 24);
        pass("35 ns reference, write then read", 64, 64);

        // ---- outside the datasheet: /WE pulse 5 steps (6.25 ns < tPWE)
        defaults;
        setw(6, 9);
        sram.errors = 0;
        runp; results;
        $display("/WE pulse 6.25 ns: %0d errors, %0d SRAM timing errors (must fail)", n_err, sram.errors);
        if (n_err == 0 || sram.errors == 0) fail("short /WE passed");

        // ---- outside the datasheet: a write after a read drives at step 0,
        // 0 ns after /OE rises (tHZOE 3 ns)
        defaults;
        setw(11, 3); setw(12, 1); setw(9, 0);
        sram.errors = 0;
        runp; results;
        $display("write after read at 0 ns: %0d SRAM timing errors (must fail)", sram.errors);
        if (sram.errors == 0) fail("no contention seen");

        if (ft.errors != 0) fail("FT232H timing");
        if (fails == 0) $display("TEST PASSED");
        else            $display("TEST FAILED: %0d", fails);
        $finish;
    end
    initial begin
        #3000000;
        $display("TEST FAILED: timeout");
        $finish;
    end
endmodule
