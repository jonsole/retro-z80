// DMXINT's race (spec 14, section 8): a bit that comes due in the same
// clock as a write of 1 that clears it stays set. The blitter on its own
// with a memory that takes every request at once: it runs a one-word fill
// with IRQ set, and the testbench writes DMXINT in the very clock the core
// raises the interrupt.
`timescale 1ns/1ps
`include "regmap.vh"

module tb_dmxint;
    reg         clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;

    reg         rd = 1'b0, wr = 1'b0;
    reg  [12:0] addr = 13'd0;
    reg  [7:0]  wdata = 8'd0;
    wire [7:0]  rdata;
    wire        hit;

    // the race: a DMXINT write of race_d in the clock the interrupt comes due
    reg         race = 1'b0;
    reg  [7:0]  race_d = 8'd0;
    wire        irq_set = dut.done;
    wire        rwr   = wr || (race && irq_set);
    wire [12:0] raddr = (race && irq_set) ? `RM_DMXINT : addr;
    wire [7:0]  rwd   = (race && irq_set) ? race_d : wdata;

    wire        mem_req, mem_we;
    wire [21:1] mem_addr;
    wire [15:0] mem_wdata;
    wire [1:0]  mem_be;
    reg         mem_rvalid = 1'b0;
    always @(posedge clk) mem_rvalid <= mem_req && !mem_we;
    wire        idle;
    wire        irq;

    dmx #(.MASKIMG(0)) dut (
        .clk(clk), .rst(rst),
        .rb_rd(rd), .rb_wr(rwr), .rb_addr(raddr), .rb_wdata(rwd),
        .rb_rdata(rdata), .rb_hit(hit), .rb_cdata(), .rb_cap(),
        .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_be(mem_be),
        .mem_ack(mem_req), .mem_rvalid(mem_rvalid), .mem_rdata(16'd0),
        .blt_on(1'b1), .idle(idle), .irq(irq)
    );

    integer errors = 0;
    integer races = 0;
    always @(posedge clk) if (race && irq_set) races = races + 1;

    task wreg(input [12:0] a, input [7:0] d);
        begin
            @(negedge clk); addr = a; wdata = d; wr = 1'b1;
            @(negedge clk); wr = 1'b0;
        end
    endtask
    task rreg(input [12:0] a, output [7:0] d);
        begin
            @(negedge clk); addr = a; rd = 1'b1;
            @(negedge clk); rd = 1'b0;
            d = rdata;
        end
    endtask
    // job register byte j (BLTCTRL0 + j)
    task job(input [5:0] j, input [7:0] d);
        wreg(13'h1140 + j, d);
    endtask
    task run_job;
        begin
            wreg(`RM_BLTCMD, 8'h02);                   // BLTCMD: RUN
            @(negedge clk);
            while (!idle) @(negedge clk);
            repeat (4) @(negedge clk);
        end
    endtask
    task expect_int(input [7:0] want, input [8*40-1:0] what);
        reg [7:0] v;
        begin
            rreg(`RM_DMXINT, v);
            if (v !== want) begin
                $display("FAIL %0s: DMXINT %h, expected %h", what, v, want);
                errors = errors + 1;
            end else
                $display("ok   %0s: DMXINT %h", what, v);
        end
    endtask

    integer i;
    initial begin
        repeat (4) @(negedge clk);
        rst = 1'b0;
        repeat (2) @(negedge clk);
        // 8 bpp, IRQ, BCONST, MINTERM 0xCC (D = B): one word at 0x100
        for (i = 0; i < 32; i = i + 1) job(i, 8'd0);
        job(6'h01, 8'h33);                             // BLTCTRL: BCONST (13), IRQ (12), BPP 3 (9-8)
        job(6'h03, 8'hCC);                             // MINTERM
        job(6'h08, 8'h00); job(6'h09, 8'h01);          // BLTDPT = 0x000100
        job(6'h0C, 8'h02);                             // WIDTH = 2 pixels
        job(6'h0E, 8'h01);                             // HEIGHT = 1
        job(6'h18, 8'h5A); job(6'h19, 8'hA5);          // VALUE

        run_job;
        expect_int(8'h01, "a job's interrupt");
        wreg(`RM_DMXINT, 8'h01);
        expect_int(8'h00, "cleared by a write of 1");

        // the race with the bit clear: the write clears nothing, the bit is set
        race = 1'b1; race_d = 8'h01;
        run_job;
        race = 1'b0;
        expect_int(8'h01, "due as a write clears it (bit clear)");

        // the race with the bit set: the write would clear it, the new one stays
        race = 1'b1;
        run_job;
        race = 1'b0;
        expect_int(8'h01, "due as a write clears it (bit set)");
        wreg(`RM_DMXINT, 8'h01);
        expect_int(8'h00, "cleared afterwards");

        if (races != 2) begin
            $display("FAIL the race was forced %0d times, expected 2", races);
            errors = errors + 1;
        end
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end
    initial begin
        #200000;
        $display("TEST FAILED: timeout");
        $finish;
    end
endmodule
