// ZEX testbench (ticket #2): the bare tv80 core runs a CP/M .COM program.
//
// tv80s (Mode 0, T2Write 1, IOWait 1, TV80_REFRESH; spec 1) with one clock
// per T-state and a flat 64 KB RAM that answers in the same clock. The RAM
// starts with the CP/M image (cpm.asm: page zero and a BDOS at 0xFF00), then
// the program goes in at 0x0100. The BDOS writes each character to I/O port
// 0x00; the testbench prints it. The run ends at the jump to 0 (warm boot).
//
//   +cpm=FILE       CP/M image, loaded at 0x0000
//   +com=FILE       program, loaded at 0x0100
//   +tests=N        number of tests that must print "OK"
//   +maxcycles=N    give up after N clocks (default: no limit)
//   +only=K         ZEXDOC and ZEXALL: run only test K (0 to 66), so that the
//                   tests can run as separate processes side by side
//   +trace=N        print the bus for the first N clocks
//
// PASS when N tests print "OK", none prints "ERROR" and "Tests complete" is
// printed before the jump to 0 (ZEXDOC's and ZEXALL's output format).
//
// The clock comes from zex_main.cpp: Verilator's timing scheduler (an
// "always #5" clock with --binary) runs this design about 3 times slower.
`timescale 1ns / 1ps

module tb_zex (input clk);
    reg  [63:0] cycles = 0;            // clocks since the start
    wire        reset_n = cycles >= 4;

    wire        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, busak_n;
    wire [15:0] A;
    wire [7:0]  dout;
    reg  [7:0]  mem [0:65535];
    wire [7:0]  di = mem[A];

    tv80s #(.Mode(0), .T2Write(1), .IOWait(1)) cpu (
        .reset_n(reset_n), .clk(clk), .wait_n(1'b1), .int_n(1'b1),
        .nmi_n(1'b1), .busrq_n(1'b1), .m1_n(m1_n), .mreq_n(mreq_n),
        .iorq_n(iorq_n), .rd_n(rd_n), .wr_n(wr_n), .rfsh_n(rfsh_n),
        .halt_n(halt_n), .busak_n(busak_n), .A(A), .di(di), .dout(dout));

    always @(posedge clk)
        if (reset_n && !mreq_n && !wr_n) mem[A] <= dout;

    // Loading
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
                mem[at + n] = c[7:0];
                n = n + 1;
                c = $fgetc(fd);
            end
            $fclose(fd);
        end
    endtask

    // ZEX's start code ends with "ld hl,tests" (0x21) 12 bytes in; the test
    // tbl is a list of descriptor addresses ending in 0. Keep entry K only.
    integer start, tbl, only;
    task only_one(input integer k);
        begin
            start = {mem[16'h0102], mem[16'h0101]};
            if (mem[start] != 8'h2A || mem[start + 3] != 8'hF9 || mem[start + 12] != 8'h21) begin
                $display("TEST FAILED: +only needs ZEXDOC or ZEXALL");
                $finish;
            end
            tbl = {mem[start + 14], mem[start + 13]};
            mem[tbl]     = mem[tbl + 2 * k];
            mem[tbl + 1] = mem[tbl + 2 * k + 1];
            mem[tbl + 2] = 8'h00;
            mem[tbl + 3] = 8'h00;
        end
    endtask

    integer tests = 0;
    reg [63:0] maxcycles = 0;
    initial begin
        for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
        if (!$value$plusargs("cpm=%s", name)) name = "cpm.bin";
        load(name, 0);
        if (!$value$plusargs("com=%s", name)) begin
            $display("TEST FAILED: no +com=FILE");
            $finish;
        end
        load(name, 16'h0100);
        $display("Loaded %0d bytes at 0x0100", n);
        if ($value$plusargs("only=%d", only)) only_one(only);
        if (!$value$plusargs("tests=%d", tests)) tests = 0;
        if (!$value$plusargs("maxcycles=%d", maxcycles)) maxcycles = 0;
        if (!$value$plusargs("trace=%d", trace)) trace = 0;
    end

    // +trace=N: the bus strobes, address and data for the first N clocks
    integer trace = 0;
    always @(posedge clk)
        if (reset_n && cycles < trace)
            $display("%0d m1=%b mreq=%b iorq=%b rd=%b wr=%b rfsh=%b A=%h di=%h do=%h",
                     cycles, m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, A, di, dout);

    // Console: I/O writes to port 0x00. Keep the last 14 characters of the
    // output to find "OK", "ERROR" and "Tests complete".
    reg        io_wr_d = 1'b0;
    wire       io_wr = reset_n && !iorq_n && !wr_n;
    reg [111:0] tail = 0;
    integer    oks = 0, errors = 0;
    reg        complete = 1'b0;

    always @(posedge clk) begin
        io_wr_d <= io_wr;
        if (io_wr && !io_wr_d && A[7:0] == 8'h00) begin
            if (dout != 8'h0D) $write("%c", dout);
            tail = {tail[103:0], dout};
            if (tail[15:0] == "OK") oks = oks + 1;
            if (tail[39:0] == "ERROR") errors = errors + 1;
            if (tail == "Tests complete") complete = 1'b1;
        end
    end

    // End: the second opcode fetch from 0x0000 (the first is the reset).
    // The core's strobes start at 0 in Verilator, so ignore them in reset
    // (as the RAM and the console do).
    reg        fetch_d = 1'b0;
    wire       fetch = reset_n && !m1_n && !mreq_n && !rd_n;
    integer    zero_fetches = 0;

    always @(posedge clk) begin
        cycles <= cycles + 1;
        fetch_d <= fetch;
        if (fetch && !fetch_d && A == 16'h0000) begin
            zero_fetches = zero_fetches + 1;
            if (zero_fetches == 2) finish_run;
        end
        if (maxcycles != 0 && cycles >= maxcycles) begin
            $display("");
            $display("TEST FAILED: no jump to 0 after %0d clocks", cycles);
            $finish;
        end
    end

    task finish_run;
        begin
            $display("");
            $display("%0d clocks (T-states), %0d tests OK, %0d ERROR",
                     cycles, oks, errors);
            if (complete && errors == 0 && oks == tests && tests > 0)
                $display("TEST PASSED");
            else if (!complete)
                $display("TEST FAILED: no \"Tests complete\"");
            else
                $display("TEST FAILED: %0d of %0d tests OK, %0d ERROR",
                         oks, tests, errors);
            $finish;
        end
    endtask
endmodule
