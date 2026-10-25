// The monitor typed at over the serial link (ticket #22), in Verilator: the
// computer (fpga/rtl/retroz80.v, a 2 MB build as the KS2) runs the boot ROM,
// and a PC on the FT232H side types the lines of a session file, one at a
// time, each when the machine has gone quiet after a prompt (its last byte a
// space). Everything the machine sends is printed and written to mon.log,
// and at the end the console's map (SRAM page 0x0FE) goes to con.hex;
// sim/mon/check.py then compares both with the session's transcript.
//
// The SRAM and its pads are tb_zexsys.v's cycle model (the datasheet timing
// is checked by tb.v's runs in Icarus). The FT232H is a cycle model of its
// asynchronous FIFO mode: RXF# low while bytes wait (and high for 6 clocks
// after each read), TXE# low but for 5 clocks after each write; the byte on
// D is taken as WR# falls. The video unit's pixel clock is held, so it
// fetches nothing; the keyboards are idle.
//
//   +rom=FILE       the boot ROM ($readmemh, 16-bit words)
//   +session=FILE   the lines to type (LF ends each; CR is sent for it)
//   +maxms=N        give up after N ms of simulated time (default 2000)
//
// Prints "SESSION DONE" and finishes once every line has been typed and the
// machine is quiet after a prompt again, or "TEST FAILED: timeout".
`timescale 1ns / 1ps

module tb_mon (input clk);
    localparam [5:0] CHIPMB = 6'd2;
    localparam integer QUIET = 400000;          // 4 ms with nothing sent: a prompt is waiting

    reg  [63:0] cycles = 0;
    reg         por = 1'b1;
    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (cycles == 64'd199) por <= 1'b0;
    end

    // ---------------------------------------------------------------- DUT
    wire [20:0] a;
    wire        ce_n, ub_n, lb_n, oe_r, oe_f, we_r, we_f, t_r, t_f;
    wire [15:0] dq_o, dq_i;
    wire        ft_d_oe, ft_rd_n, ft_wr_n, ft_siwu_n;
    wire [7:0]  ft_d_o;
    reg         ft_rxf_n = 1'b1, ft_txe_n = 1'b0;
    wire [7:0]  ft_d_i;

    retroz80 #(.ROM_INIT("mon_rom.hex"), .CHIPMB(CHIPMB)) dut (
        .clk(clk), .por(por),
        .btn_reset_n(1'b1), .buttons(2'b00),
        .sram_a(a), .sram_ce_n(ce_n), .sram_ub_n(ub_n), .sram_lb_n(lb_n),
        .sram_oe_n_r(oe_r), .sram_oe_n_f(oe_f), .sram_we_n_r(we_r), .sram_we_n_f(we_f),
        .sram_dq_o(dq_o), .sram_dq_t_r(t_r), .sram_dq_t_f(t_f), .sram_dq_i(dq_i),
        .ft_rxf_n(ft_rxf_n), .ft_txe_n(ft_txe_n), .ft_d_i(ft_d_i), .ft_d_o(ft_d_o),
        .ft_d_oe(ft_d_oe), .ft_rd_n(ft_rd_n), .ft_wr_n(ft_wr_n), .ft_siwu_n(ft_siwu_n),
        .clk_pix(1'b0), .clk_pix5(1'b0), .vid_rgb(), .vid_hsync(), .vid_vsync(), .vid_de(),
        .ps2_clk_i(1'b1), .ps2_data_i(1'b1), .ps2_clk_low(), .ps2_data_low(),
        .keyb_row_low(), .keyb_col_i(7'h7F), .joy_pin_n(6'h3F), .joy_sel(), .joy_p7(),
        .audio_l(), .audio_r(), .audio_m(),
        .dma_req(1'b0), .dma_we(1'b0), .dma_addr(21'd0), .dma_wdata(16'd0),
        .dma_be(2'b11), .dma_ack(), .dma_rvalid(), .dma_rdata(),
        .dbg_sc()
    );

    // ---------------------------------------------------------------- SRAM
    reg  [15:0] mem [0:(1<<20)-1];
    reg  [19:0] pa = 0;
    reg         pce_n = 1, pub_n = 1, plb_n = 1, pwe_r = 1, pwe_f = 1;
    reg  [15:0] pdq = 0;
    always @(posedge clk) begin
        if (!pce_n && !pwe_r && pwe_f) begin
            if (!pub_n) mem[pa][15:8] <= pdq[15:8];
            if (!plb_n) mem[pa][7:0]  <= pdq[7:0];
        end
        pa    <= a[19:0];
        pce_n <= ce_n;
        pub_n <= ub_n;
        plb_n <= lb_n;
        pwe_r <= we_r;
        pwe_f <= we_f;
        pdq   <= dq_o;
    end
    assign dq_i = mem[pa];

    // ---------------------------------------------------------------- the PC's side
    reg  [7:0]  q [0:65535];                    // bytes to send
    integer     qh = 0, qt = 0;
    integer     rx_hold = 0, tx_hold = 0;
    reg         rd_q = 1'b1, wr_q = 1'b1;
    reg  [7:0]  last = 8'h00;
    integer     quiet = 0, nout = 0, logf, sess, c, nlines = 0;
    reg         sess_end = 1'b0, done = 1'b0;
    reg  [1023:0] name;
    assign ft_d_i = q[qh[15:0]];

    initial begin
        if (!$value$plusargs("session=%s", name)) name = "session.in";
        sess = $fopen(name, "r");
        if (sess == 0) begin
            $display("TEST FAILED: no session file");
            $finish;
        end
        logf = $fopen("mon.log", "wb");
    end

    // Type the next line of the session: its bytes, then CR
    task type_line;
        begin
            c = $fgetc(sess);
            if (c < 0) sess_end = 1'b1;
            else begin
                nlines = nlines + 1;
                while (c >= 0 && c != 10) begin
                    if (c != 13) begin q[qt[15:0]] = c[7:0]; qt = qt + 1; end
                    c = $fgetc(sess);
                end
                q[qt[15:0]] = 8'h0D;
                qt = qt + 1;
            end
        end
    endtask

    always @(posedge clk) if (!done) begin
        // PC -> computer
        rd_q <= ft_rd_n;
        if (rx_hold > 0) rx_hold <= rx_hold - 1;
        if (!rd_q && ft_rd_n && !por) begin     // a read ended
            qh <= qh + 1;
            rx_hold <= 6;
        end
        ft_rxf_n <= !(qh < qt && rx_hold == 0 && !(!rd_q && ft_rd_n));
        // Computer -> PC
        wr_q <= ft_wr_n;
        if (tx_hold > 0) tx_hold <= tx_hold - 1;
        ft_txe_n <= (tx_hold > 0);
        if (wr_q && !ft_wr_n && !por) begin
            $write("%c", ft_d_o);
            $fwrite(logf, "%c", ft_d_o);
            last = ft_d_o;
            nout = nout + 1;
            quiet = 0;
            tx_hold <= 5;
        end else quiet = quiet + 1;
        // The next line once a prompt has waited a while
        if (quiet == QUIET && last == 8'h20 && qh == qt) begin
            if (sess_end) begin
                $display("");
                $display("SESSION DONE: %0d lines typed, %0d bytes received, %0d clocks", nlines, nout, cycles);
                $fclose(logf);
                $writememh("con.hex", mem, 20'hFE000, 20'hFEFFF);   // the console map, page 0x0FE
                done = 1'b1;
                $finish;
            end else begin
                type_line;
                if (sess_end) quiet = QUIET - 1;
            end
        end
    end

    integer maxms;
    initial if (!$value$plusargs("maxms=%d", maxms)) maxms = 2000;
    always @(posedge clk) if (!done && cycles > 64'd100000 * maxms) begin
        $display("");
        $display("TEST FAILED: timeout after %0d ms (%0d lines typed)", maxms, nlines);
        $fclose(logf);
        $finish;
    end
endmodule
