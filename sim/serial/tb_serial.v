// serial.v on its own (spec 10, section 4): the PC's bytes through the
// FT232H model, the escapes and the control commands C0 c ~c.
//   - a frame ending in 0x00 is all in the receive FIFO at once (the old
//     16-byte matcher held a trailing 0x00 back until the next byte)
//   - DB DC and DB DD give C0 and DB; other bytes are passed on as they are
//   - C0 01 FE, C0 02 FD, C0 03 FC give one BREAK, RESET and UPLOAD pulse,
//     and nothing reaches the FIFO; broken commands are dropped
//   - BREAK only with CTLEN; with CTLLOCK alone RESET and UPLOAD still work
//   - with CTLEN and CTLLOCK clear every byte, C0 and DB too, goes on raw
//   - KEY, C0 04 b ~b with b and ~b escaped, gives one cmd_key with b; a
//     broken KEY is dropped; KEY only with CTLEN (ticket #44)
`timescale 1ns/1ps
`include "regmap.vh"
module tb_serial;
    reg clk = 0;
    always #5 clk = !clk;
    reg rst = 1, por = 1;

    reg        rb_rd = 0, rb_wr = 0;
    reg [12:0] rb_addr = 0;
    reg [7:0]  rb_wdata = 0;
    wire [7:0] rb_rdata;
    wire       rb_hit, irq, cmd_break, cmd_reset, cmd_upload, cmd_key, p_rxv, p_txr;
    wire [7:0] key_byte;
    wire [7:0] p_rxd;

    wire [7:0] ft_d;
    wire [7:0] ft_d_o;
    wire       ft_d_oe, ft_rd_n, ft_wr_n, ft_siwu_n, ft_rxf_n, ft_txe_n;
    assign ft_d = ft_d_oe ? ft_d_o : 8'hzz;

    serial dut (.clk(clk), .rst(rst), .por(por), .us_tick(1'b0),
                .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
                .rb_rdata(rb_rdata), .rb_hit(rb_hit), .irq(irq),
                .cmd_break(cmd_break), .cmd_reset(cmd_reset), .cmd_upload(cmd_upload),
                .cmd_key(cmd_key), .key_byte(key_byte),
                .p_rxv(p_rxv), .p_rxd(p_rxd), .p_rxpop(1'b0), .p_txr(p_txr), .p_txpush(1'b0), .p_txd(8'h00),
                .ft_rxf_n(ft_rxf_n), .ft_txe_n(ft_txe_n), .ft_d_i(ft_d), .ft_d_o(ft_d_o), .ft_d_oe(ft_d_oe),
                .ft_rd_n(ft_rd_n), .ft_wr_n(ft_wr_n), .ft_siwu_n(ft_siwu_n));
    ft232h_model ft (.d(ft_d), .rxf_n(ft_rxf_n), .txe_n(ft_txe_n), .rd_n(ft_rd_n), .wr_n(ft_wr_n), .siwu_n(ft_siwu_n));

    integer errors = 0, nbrk = 0, nrst = 0, nupl = 0, nkey = 0;
    reg [7:0] keys [0:15];
    always @(posedge clk) begin
        if (cmd_key) begin keys[nkey] = key_byte; nkey = nkey + 1; end
        if (cmd_break)  nbrk = nbrk + 1;
        if (cmd_reset)  nrst = nrst + 1;
        if (cmd_upload) nupl = nupl + 1;
    end

    task wr(input [12:0] a, input [7:0] d);
        begin
            @(posedge clk); rb_addr <= a; rb_wdata <= d; rb_wr <= 1;
            @(posedge clk); rb_wr <= 0;
        end
    endtask
    reg [7:0] rd_val;
    task rd(input [12:0] a);
        begin
            @(posedge clk); rb_addr <= a; rb_rd <= 1;
            @(posedge clk); rb_rd <= 0;
            @(posedge clk); rd_val = rb_rdata;
        end
    endtask
    task idle;   // all the model's bytes read by the FPGA
        begin
            wait (ft.head == ft.tail);
            repeat (40) @(posedge clk);
        end
    endtask
    // the receive FIFO must hold exactly these n bytes
    reg [7:0] want [0:31];
    // KEY must have given exactly these n bytes since the last check
    reg [7:0] wantkey [0:15];
    task expect_keys(input integer n, input [8*40-1:0] what);
        integer i;
        begin
            idle;
            if (nkey != n) begin
                $display("FAIL %0s: %0d KEYs, not %0d", what, nkey, n);
                errors = errors + 1;
            end
            for (i = 0; i < n && i < nkey; i = i + 1)
                if (keys[i] !== wantkey[i]) begin
                    $display("FAIL %0s: KEY %0d is %h, not %h", what, i, keys[i], wantkey[i]);
                    errors = errors + 1;
                end
            nkey = 0;
        end
    endtask
    task expect_rx(input integer n, input [8*40-1:0] what);
        integer i;
        begin
            idle;
            rd(`RM_SERSTAT1);
            if (rd_val != n) begin
                $display("FAIL %0s: %0d bytes waiting, not %0d", what, rd_val, n);
                errors = errors + 1;
            end
            for (i = 0; i < n && i < rd_val; i = i + 1) begin
                rd(`RM_SERDATA);
                if (rd_val !== want[i]) begin
                    $display("FAIL %0s: byte %0d is %h, not %h", what, i, rd_val, want[i]);
                    errors = errors + 1;
                end
            end
            wr(`RM_SERCON, dut.sercon | 8'h10);   // RXFLUSH: start the next check clean
        end
    endtask
    task expect_cmds(input integer b, input integer r, input integer u, input [8*40-1:0] what);
        begin
            idle;
            if (nbrk != b || nrst != r || nupl != u) begin
                $display("FAIL %0s: BREAK %0d RESET %0d UPLOAD %0d, not %0d %0d %0d", what, nbrk, nrst, nupl, b, r, u);
                errors = errors + 1;
            end
            nbrk = 0; nrst = 0; nupl = 0;
        end
    endtask

    integer i;
    initial begin
        repeat (5) @(posedge clk);
        rst = 0; por = 0;
        wr(`RM_SERCON, 8'h03);                    // EN, CTLEN

        // 1. READREGS, SEQ 0x43: its CRC ends in 0x00, and nothing follows it
        ft.send(8'h4C); ft.send(8'h46); ft.send(8'h12); ft.send(8'h43); ft.send(8'h01);
        for (i = 0; i < 5; i = i + 1) ft.send(8'h00);
        ft.send(8'hFF); ft.send(8'hFF); ft.send(8'h55); ft.send(8'h42); ft.send(8'h14); ft.send(8'h00);
        want[0] = 8'h4C; want[1] = 8'h46; want[2] = 8'h12; want[3] = 8'h43; want[4] = 8'h01;
        for (i = 5; i < 10; i = i + 1) want[i] = 8'h00;
        want[10] = 8'hFF; want[11] = 8'hFF; want[12] = 8'h55; want[13] = 8'h42; want[14] = 8'h14; want[15] = 8'h00;
        expect_rx(16, "frame ending 0x00");

        // 2. escapes
        ft.send(8'hDB); ft.send(8'hDC); ft.send(8'h41); ft.send(8'hDB); ft.send(8'hDD); ft.send(8'hDB); ft.send(8'h42);
        want[0] = 8'hC0; want[1] = 8'h41; want[2] = 8'hDB; want[3] = 8'h42;
        expect_rx(4, "escapes");

        // 3. commands among data; nothing of them reaches the FIFO
        ft.send(8'h61); ft.send(8'hC0); ft.send(8'h01); ft.send(8'hFE); ft.send(8'h62);
        ft.send(8'hC0); ft.send(8'h02); ft.send(8'hFD);
        ft.send(8'hC0); ft.send(8'h03); ft.send(8'hFC); ft.send(8'h00);
        want[0] = 8'h61; want[1] = 8'h62; want[2] = 8'h00;
        expect_rx(3, "commands among data");
        expect_cmds(1, 1, 1, "commands among data");

        // 3b. KEY among data: A down and up, then b = C0 and b = 24 (~b = DB), escaped
        ft.send(8'h61); ft.send(8'hC0); ft.send(8'h04); ft.send(8'h1C); ft.send(8'hE3);
        ft.send(8'h62); ft.send(8'hC0); ft.send(8'h04); ft.send(8'hF0); ft.send(8'h0F);
        ft.send(8'hC0); ft.send(8'h04); ft.send(8'h1C); ft.send(8'hE3); ft.send(8'h63);
        ft.send(8'hC0); ft.send(8'h04); ft.send(8'hDB); ft.send(8'hDC); ft.send(8'h3F);
        ft.send(8'hC0); ft.send(8'h04); ft.send(8'h24); ft.send(8'hDB); ft.send(8'hDD);
        want[0] = 8'h61; want[1] = 8'h62; want[2] = 8'h63;
        expect_rx(3, "KEY among data");
        wantkey[0] = 8'h1C; wantkey[1] = 8'hF0; wantkey[2] = 8'h1C; wantkey[3] = 8'hC0; wantkey[4] = 8'h24;
        expect_keys(5, "KEY among data");
        // broken KEYs: a wrong inverse, an unescaped C0 inside (which starts a BREAK)
        ft.send(8'hC0); ft.send(8'h04); ft.send(8'h1C); ft.send(8'h00);
        ft.send(8'hC0); ft.send(8'h04); ft.send(8'h1C); ft.send(8'hC0); ft.send(8'h01); ft.send(8'hFE);
        ft.send(8'h64);
        want[0] = 8'h64;
        expect_rx(1, "broken KEY");
        expect_keys(0, "broken KEY");
        expect_cmds(1, 0, 0, "broken KEY");

        // 4. broken commands: dropped; a C0 starts again; DB then C0 is a command
        ft.send(8'hC0); ft.send(8'h05); ft.send(8'hFA);          // no such command
        ft.send(8'hC0); ft.send(8'h01); ft.send(8'hFF);          // wrong inverse
        ft.send(8'hC0); ft.send(8'h01); ft.send(8'hC0); ft.send(8'h01); ft.send(8'hFE);
        ft.send(8'hDB); ft.send(8'hC0); ft.send(8'h02); ft.send(8'hFD);
        ft.send(8'h63);
        want[0] = 8'h63;
        expect_rx(1, "broken commands");
        expect_cmds(1, 1, 0, "broken commands");

        // 5. CTLLOCK alone: RESET and UPLOAD, no BREAK; escapes still decoded
        wr(`RM_SERCON, 8'h05);                    // EN, CTLLOCK
        ft.send(8'hC0); ft.send(8'h01); ft.send(8'hFE);
        ft.send(8'hC0); ft.send(8'h02); ft.send(8'hFD);
        ft.send(8'hDB); ft.send(8'hDC);
        want[0] = 8'hC0;
        expect_rx(1, "CTLLOCK");
        expect_cmds(0, 1, 0, "CTLLOCK");
        ft.send(8'hC0); ft.send(8'h04); ft.send(8'h1C); ft.send(8'hE3);
        expect_keys(0, "KEY with CTLLOCK alone");

        // 6. raw: CTLEN and CTLLOCK clear (CTLLOCK needs a reset to clear)
        rst = 1; repeat (2) @(posedge clk); rst = 0;
        wr(`RM_SERCON, 8'h01);                    // EN only
        ft.send(8'hC0); ft.send(8'h01); ft.send(8'hFE); ft.send(8'hDB); ft.send(8'hDC);
        want[0] = 8'hC0; want[1] = 8'h01; want[2] = 8'hFE; want[3] = 8'hDB; want[4] = 8'hDC;
        expect_rx(5, "raw");
        expect_cmds(0, 0, 0, "raw");
        ft.send(8'hC0); ft.send(8'h04); ft.send(8'h1C); ft.send(8'hE3);
        want[0] = 8'hC0; want[1] = 8'h04; want[2] = 8'h1C; want[3] = 8'hE3;
        expect_rx(4, "KEY raw");
        expect_keys(0, "KEY raw");

        if (errors == 0 && ft.errors == 0) $display("TEST PASSED");
        else $display("TEST FAILED: %0d errors, %0d FT232H errors", errors, ft.errors);
        $finish;
    end
    initial begin #2000000 $display("TEST FAILED: timeout"); $finish; end
endmodule
