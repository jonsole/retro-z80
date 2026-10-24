// Unit test of the interrupt controller (fpga/rtl/intc.v, spec 8) through
// its own ports: the register bus, the request lines, the bus interface's
// vector request and acknowledge, and the NMI inputs. The whole machine
// (tv80's acknowledge cycle, IM 1 and IM 2, VBLANK) is tested by
// sim/inttest/inttest.asm in tb.v; this test covers what software cannot
// reach: every source's number and priority, the frozen choice and the
// spurious acknowledge.
`timescale 1ns/1ps
`include "regmap.vh"

module tb_intc;
    reg         clk = 0, rst = 1;
    always #5 clk = !clk;

    reg         rb_rd = 0, rb_wr = 0;
    reg  [12:0] rb_addr = 0;
    reg  [7:0]  rb_wdata = 0;
    wire [7:0]  rb_rdata;
    wire        rb_hit;
    reg  [20:0] req = 0;
    reg         vreq = 0, int_ack = 0;
    wire [7:0]  vector;
    wire        int_n, nmi_n;
    reg         nmi_button = 0, nmi_usb = 0, nmi_ack = 0;

    intc dut (
        .clk(clk), .rst(rst),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
        .rb_rdata(rb_rdata), .rb_hit(rb_hit),
        .req(req), .int_n(int_n), .vreq(vreq), .vector(vector), .int_ack(int_ack),
        .nmi_button(nmi_button), .nmi_usb(nmi_usb), .nmi_ack(nmi_ack), .nmi_n(nmi_n)
    );

    integer errors = 0, checks = 0;
    task check(input [8*48-1:0] what, input [7:0] got, input [7:0] want);
        begin
            checks = checks + 1;
            if (got !== want) begin
                $display("ERROR: %0s: %h, expected %h", what, got, want);
                errors = errors + 1;
            end
        end
    endtask

    task wr(input [12:0] a, input [7:0] d);
        begin
            @(negedge clk); rb_addr = a; rb_wdata = d; rb_wr = 1;
            @(negedge clk); rb_wr = 0;
        end
    endtask
    reg [7:0] rd_v;
    reg       rd_h;
    task rd(input [12:0] a);
        begin
            @(negedge clk); rb_addr = a; rb_rd = 1;
            @(negedge clk); rb_rd = 0; rd_v = rb_rdata; rd_h = rb_hit;
        end
    endtask
    task rdchk(input [8*48-1:0] what, input [12:0] a, input [7:0] want);
        begin
            rd(a);
            check(what, rd_v, want);
            check({what, " (answered)"}, {7'd0, rd_h}, 8'd1);
        end
    endtask
    task settle; begin repeat (3) @(negedge clk); end endtask
    // The bus interface asks for the vector (1 clock); the vector is read
    // the clock after, as bus_if.v takes it
    reg [7:0] v;
    task ask;
        begin
            @(negedge clk); vreq = 1;
            @(negedge clk); vreq = 0; v = vector;
        end
    endtask
    task ack;
        begin
            @(negedge clk); int_ack = 1;
            @(negedge clk); int_ack = 0;
        end
    endtask
    // Turn on sources: the 21-bit mask, one set/clear write per byte
    task ena(input [20:0] m, input setclr);
        begin
            wr(`RM_INTENA0, {setclr, m[6:0]});
            wr(`RM_INTENA1, {setclr, m[13:7]});
            wr(`RM_INTENA2, {setclr, m[20:14]});
        end
    endtask

    integer n, k;
    initial begin
        repeat (3) @(negedge clk);
        rst = 0;

        // ---- reset values (section 12)
        rdchk("INTCON at reset",   `RM_INTCON,   8'h00);
        rdchk("INTENA0 at reset",  `RM_INTENA0,  8'h00);
        rdchk("INTENA1 at reset",  `RM_INTENA1,  8'h00);
        rdchk("INTENA2 at reset",  `RM_INTENA2,  8'h00);
        rdchk("INTPEND0 at reset", `RM_INTPEND0, 8'h00);
        rdchk("INTRAW0 at reset",  `RM_INTRAW0,  8'h00);
        rdchk("VECBASE at reset",  `RM_VECBASE,  8'h00);
        rdchk("SOFTINT reads 0",   `RM_SOFTINT,  8'h00);
        rdchk("INTID at reset",    `RM_INTID,    8'h00);
        rdchk("NMICON at reset",   `RM_NMICON,   8'h03);
        rdchk("NMISTAT at reset",  `RM_NMISTAT,  8'h00);
        rd(13'h000F);
        check("register 0x0F not answered", {7'd0, rd_h}, 8'd0);
        rd(13'h0070);
        check("SYSID not answered", {7'd0, rd_h}, 8'd0);
        check("int_n high at reset", {7'd0, int_n}, 8'd1);
        check("nmi_n high at reset", {7'd0, nmi_n}, 8'd1);

        // ---- INTCON: MASTER only
        wr(`RM_INTCON, 8'hFF);
        rdchk("INTCON keeps MASTER only", `RM_INTCON, 8'h01);
        wr(`RM_INTCON, 8'h00);

        // ---- INTENA: set/clear, each byte alone, bit 7 reads 0
        wr(`RM_INTENA0, 8'h85);
        rdchk("INTENA0 set 0x05", `RM_INTENA0, 8'h05);
        wr(`RM_INTENA0, 8'h82);
        rdchk("INTENA0 set 0x02 more", `RM_INTENA0, 8'h07);
        wr(`RM_INTENA0, 8'h01);
        rdchk("INTENA0 clear 0x01", `RM_INTENA0, 8'h06);
        rdchk("INTENA1 untouched", `RM_INTENA1, 8'h00);
        wr(`RM_INTENA2, 8'hFF);
        rdchk("INTENA2 all set, bit 7 reads 0", `RM_INTENA2, 8'h7F);
        rdchk("INTENA0 untouched by INTENA2", `RM_INTENA0, 8'h06);
        wr(`RM_INTENA2, 8'h7F);
        rdchk("INTENA2 all cleared", `RM_INTENA2, 8'h00);
        wr(`RM_INTENA0, 8'h7F);

        // ---- VECBASE: bit 0 reads 0
        wr(`RM_VECBASE, 8'hFF);
        rdchk("VECBASE bit 0 reads 0", `RM_VECBASE, 8'hFE);
        wr(`RM_VECBASE, 8'h00);

        // ---- the request path: INTRAW = lines, INTPEND = AND INTENA AND MASTER
        req = 21'h000005;                               // VBLANK, COPPER
        settle;
        rdchk("INTRAW0 follows the lines", `RM_INTRAW0, 8'h05);
        rdchk("INTPEND0 0 with INTENA off", `RM_INTPEND0, 8'h00);
        check("int_n high, nothing pending", {7'd0, int_n}, 8'd1);
        wr(`RM_INTENA0, 8'h81);
        settle;
        rdchk("INTPEND0 0 with MASTER off", `RM_INTPEND0, 8'h00);
        check("int_n high with MASTER off", {7'd0, int_n}, 8'd1);
        wr(`RM_INTCON, 8'h01);
        settle;
        rdchk("INTPEND0 = INTRAW AND INTENA", `RM_INTPEND0, 8'h01);
        check("int_n low while pending", {7'd0, int_n}, 8'd0);
        wr(`RM_INTENA0, 8'h01);
        settle;
        check("int_n high, INTENA turned off", {7'd0, int_n}, 8'd1);
        rdchk("INTRAW0 kept with INTENA off", `RM_INTRAW0, 8'h05);
        wr(`RM_INTENA0, 8'h81);
        settle;
        check("int_n low again at once", {7'd0, int_n}, 8'd0);
        req = 0;
        settle;
        check("int_n high, the line dropped", {7'd0, int_n}, 8'd1);

        // ---- reserved and unused sources request nothing (8, 9, 10, 16, 19, 20)
        req = 21'h1FFFFF;
        settle;
        rdchk("INTRAW0, all lines", `RM_INTRAW0, 8'h7F);
        rdchk("INTRAW1, 8-10 unused", `RM_INTRAW1, 8'h71);      // 13-11 (bits 6-4), 7 (bit 0)
        rdchk("INTRAW2, 16, 18-20 not lines", `RM_INTRAW2, 8'h0B); // 14, 15, 17
        req = 0;

        // ---- SOFTINT: SET raises SOFT (18, INTRAW2 bit 4), CLR clears it
        wr(`RM_SOFTINT, 8'h01);
        settle;
        rdchk("INTRAW2 shows SOFT", `RM_INTRAW2, 8'h10);
        wr(`RM_SOFTINT, 8'h00);
        settle;
        rdchk("SOFTINT 0 leaves SOFT", `RM_INTRAW2, 8'h10);
        wr(`RM_SOFTINT, 8'h02);
        settle;
        rdchk("CLR clears SOFT", `RM_INTRAW2, 8'h00);

        // ---- vectors: each source alone gives VECBASE + 2n and INTID = n
        ena(21'h1FFFFF, 1);
        for (n = 0; n <= 20; n = n + 1)
            if (n != 8 && n != 9 && n != 10 && n != 16 && n != 18 && n != 19 && n != 20) begin
                wr(`RM_VECBASE, 8'h40);
                req = 21'd1 << n;
                settle;
                check("int_n low for the source", {7'd0, int_n}, 8'd0);
                ask;
                check("vector VECBASE + 2n", v, 8'h40 + 2 * n);
                ack;
                rdchk("INTID = n", `RM_INTID, n);
                req = 0;
            end
        wr(`RM_SOFTINT, 8'h01);
        settle;
        ask;
        check("SOFT vector", v, 8'h40 + 36);
        ack;
        rdchk("INTID = SOFT", `RM_INTID, 8'd18);
        wr(`RM_SOFTINT, 8'h02);

        // ---- a VECBASE that wraps round the page
        wr(`RM_VECBASE, 8'hF0);
        req = 21'd1 << 15;                              // SERIAL: 0xF0 + 30 = 0x10E
        settle;
        ask;
        check("vector wraps", v, 8'h0E);
        ack;
        req = 0;

        // ---- priority: the lowest number first; INTID agrees with the vector
        wr(`RM_VECBASE, 8'hD0);
        req = (21'd1 << 17) | (21'd1 << 11) | (21'd1 << 4) | (21'd1 << 3);
        wr(`RM_SOFTINT, 8'h01);
        settle;
        ask; ack; check("first VIDERR (3)", v, 8'hD0 + 6);
        rdchk("INTID 3", `RM_INTID, 8'd3);
        req[3] = 0; settle;
        ask; ack; check("then DMA0 (4)", v, 8'hD0 + 8);
        req[4] = 0; settle;
        ask; ack; check("then TIMER0 (11)", v, 8'hD0 + 22);
        req[11] = 0; settle;
        ask; ack; check("then KEYB (17)", v, 8'hD0 + 34);
        req[17] = 0; settle;
        ask; ack; check("then SOFT (18)", v, 8'hD0 + 36);
        rdchk("INTID 18", `RM_INTID, 8'd18);
        wr(`RM_SOFTINT, 8'h02);
        settle;

        // ---- frozen choice: a lower source arriving during the acknowledge
        req = 21'd1 << 12;
        settle;
        @(negedge clk); vreq = 1;
        @(negedge clk); vreq = 0; v = vector;
        req[0] = 1;
        repeat (5) begin
            @(negedge clk);
            check("vector frozen in the cycle", vector, 8'hD0 + 24);
        end
        rdchk("INTID frozen", `RM_INTID, 8'd12);
        ack;
        ask; ack;
        check("the next acknowledge takes VBLANK", v, 8'hD0);
        req = 0;
        settle;

        // ---- spurious: nothing pending when the vector is asked for
        check("int_n high", {7'd0, int_n}, 8'd1);
        ask; ack;
        check("spurious: VECBASE + 46", v, 8'hD0 + 46);
        rdchk("INTID 23 (NONE)", `RM_INTID, 8'd23);

        // ---- MASTER off keeps requests but stops them
        req = 21'd1;
        wr(`RM_INTCON, 8'h00);
        settle;
        check("int_n high, MASTER off", {7'd0, int_n}, 8'd1);
        rdchk("INTPEND0 0, MASTER off", `RM_INTPEND0, 8'h00);
        wr(`RM_INTCON, 8'h01);
        settle;
        check("int_n low, MASTER on", {7'd0, int_n}, 8'd0);
        req = 0;
        ena(21'h1FFFFF, 0);
        rdchk("INTENA0 cleared", `RM_INTENA0, 8'h00);

        // ---- NMI (section 10): one per event, NMICON gates, NMISTAT W1C
        @(negedge clk); nmi_button = 1;
        repeat (3) @(negedge clk);
        check("button: nmi_n low", {7'd0, nmi_n}, 8'd0);
        rdchk("NMISTAT.BUTTON", `RM_NMISTAT, 8'h01);
        nmi_button = 0;
        @(negedge clk); nmi_usb = 1; @(negedge clk); nmi_usb = 0;
        rdchk("NMISTAT both", `RM_NMISTAT, 8'h03);
        check("nmi_n still low: one NMI", {7'd0, nmi_n}, 8'd0);
        @(negedge clk); nmi_ack = 1; @(negedge clk); nmi_ack = 0;
        @(negedge clk);
        check("nmi_n high after the response", {7'd0, nmi_n}, 8'd1);
        wr(`RM_NMISTAT, 8'h01);
        rdchk("NMISTAT W1C", `RM_NMISTAT, 8'h02);
        wr(`RM_NMISTAT, 8'hFF);
        wr(`RM_NMICON, 8'hFE);
        rdchk("NMICON USBEN only", `RM_NMICON, 8'h02);
        @(negedge clk); nmi_button = 1; repeat (3) @(negedge clk); nmi_button = 0;
        check("button turned off: no NMI", {7'd0, nmi_n}, 8'd1);
        rdchk("button turned off: no flag", `RM_NMISTAT, 8'h00);
        rdchk("INTID not changed by the NMI", `RM_INTID, 8'd23);

        // ---- a reset puts everything back
        @(negedge clk); rst = 1; @(negedge clk); rst = 0;
        rdchk("NMICON back to 3", `RM_NMICON, 8'h03);
        rdchk("VECBASE back to 0", `RM_VECBASE, 8'h00);
        rdchk("INTID back to 0", `RM_INTID, 8'h00);

        $display("---- intc: %0d checks, %0d errors", checks, errors);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED");
        $finish;
    end
endmodule
