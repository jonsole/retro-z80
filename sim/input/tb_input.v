// The input units on their own (spec 12, section 9; ticket #19): the PS/2
// keyboard (ps2kb.v) against a keyboard model (ps2_model.v), the PS/2 to
// Spectrum key mapper (ps2map.v), the membrane scanner and port 0xFE
// (keys.v) against a matrix model, and the joysticks (joy.v) through a
// model of the board's multiplexer, with an Atari stick and Mega Drive 3-
// and 6-button pad models. The register bus is driven as the bus interface
// drives it: a one-clock strobe, the data the clock after.
//
// The membrane scan runs 32 times faster than the real one (ROWCLK 200);
// the joysticks at their real rate, so the Mega Drive pads see real timing.
`timescale 1ns/1ps
`include "regmap.vh"

module tb_input;
    reg clk = 1'b0;
    always #5 clk = !clk;              // 100 MHz
    reg rst = 1'b1;

    integer errors = 0;
    task check(input [255:0] what, input [7:0] got, input [7:0] want);
        if (got !== want) begin
            errors = errors + 1;
            $display("FAIL %0s: got %02x, expected %02x (t = %0t)", what, got, want, $time);
        end
    endtask

    // ---------------------------------------------------------------- the register bus
    reg         rb_rd = 1'b0, rb_wr = 1'b0;
    reg  [12:0] rb_addr = 13'd0;
    reg  [7:0]  rb_hi = 8'd0, rb_wdata = 8'd0;
    wire [7:0]  rd_kb, rd_key, rd_joy;
    wire        hit_kb, hit_key, hit_joy;
    wire [7:0]  rdata = rd_kb | rd_key | rd_joy;
    wire        hit = hit_kb | hit_key | hit_joy;

    task wr(input [12:0] a, input [7:0] d);
        begin
            @(negedge clk); rb_addr = a; rb_hi = 8'h00; rb_wdata = d; rb_wr = 1'b1;
            @(negedge clk); rb_wr = 1'b0;
        end
    endtask
    reg [7:0] v;
    reg       vhit;
    task rd(input [12:0] a, input [7:0] hi);
        begin
            @(negedge clk); rb_addr = a; rb_hi = hi; rb_rd = 1'b1;
            @(negedge clk); rb_rd = 1'b0; v = rdata; vhit = hit;
        end
    endtask
    task expect(input [255:0] what, input [12:0] a, input [7:0] hi, input [7:0] want);
        begin
            rd(a, hi);
            if (!vhit) begin
                errors = errors + 1;
                $display("FAIL %0s: no unit answered %03x", what, a);
            end
            check(what, v, want);
        end
    endtask

    // ---------------------------------------------------------------- PS/2
    wire ps2_clk_low, ps2_data_low, m_clk_low, m_data_low;
    reg  kb_plugged = 1'b1;            // 0: the keyboard model is cut off (no answer)
    wire ps2_clk  = !(ps2_clk_low  || (kb_plugged && m_clk_low));
    wire ps2_data = !(ps2_data_low || (kb_plugged && m_data_low));
    ps2_model kbm (.clk_line(ps2_clk), .data_line(ps2_data), .clk_low(m_clk_low), .data_low(m_data_low));

    wire        map_en, rx_stb, rx_on, irq;
    wire [7:0]  rx_byte;
    wire [39:0] ps2_keys;
    reg         inj_stb = 1'b0;        // KEY from the link (ticket #44)
    reg  [7:0]  inj_byte = 8'h00;
    ps2kb kb (
        .clk(clk), .rst(rst),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
        .rb_rdata(rd_kb), .rb_hit(hit_kb),
        .ps2_clk_i(ps2_clk), .ps2_data_i(ps2_data), .ps2_clk_low(ps2_clk_low), .ps2_data_low(ps2_data_low),
        .map_en(map_en), .rx_stb(rx_stb), .rx_byte(rx_byte), .rx_on(rx_on),
        .inj_stb(inj_stb), .inj_byte(inj_byte), .irq(irq)
    );
    ps2map kmap (.clk(clk), .clr(rst || !rx_on || !map_en), .stb(rx_stb), .byte_in(rx_byte), .keys(ps2_keys));

    // ---------------------------------------------------------------- the membrane
    wire [7:0]  row_low;
    reg  [55:0] mkeys = 56'd0;         // bit 7r + c: row r, column c held
    reg  [6:0]  cols;
    integer     r, c;
    always @(*) begin
        cols = 7'h7F;
        for (r = 0; r < 8; r = r + 1)
            for (c = 0; c < 7; c = c + 1)
                if (row_low[r] && mkeys[7 * r + c]) cols[c] = 1'b0;
    end
    keys #(.ROWCLK(200)) key (
        .clk(clk), .rst(rst),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_hi(rb_hi), .rb_wdata(rb_wdata),
        .rb_rdata(rd_key), .rb_hit(hit_key),
        .row_low(row_low), .col_i(cols), .ps2_keys(ps2_keys), .ps2map_en(map_en)
    );
    localparam SCAN = 8 * 200 * 10;    // ns: one whole membrane scan

    // ---------------------------------------------------------------- the joysticks
    wire joysel, sel;
    // Port 1: an Atari stick (j1: pressed, {Fire 2, Fire 1, R, L, D, U},
    // which is pin order {9, 6, 4, 3, 2, 1})
    reg  [5:0] j1 = 6'd0;
    wire [5:0] p1_n = ~j1;
    // Port 2: a Mega Drive pad. md: pressed {MODE, X, Y, Z, START, A, C, B,
    // R, L, D, U}; six: a 6-button pad
    reg  [11:0] md = 12'd0;
    reg         six = 1'b1;
    integer     mdcnt = 0;
    realtime    mdlast = 0;
    always @(negedge sel) begin
        if ($realtime - mdlast > 1500000.0) mdcnt = 0;
        mdcnt = mdcnt + 1;
        mdlast = $realtime;
    end
    // The pad's pins, pressed sense (1 = low), {9, 6, 4, 3, 2, 1}: select
    // high gives C, B, R, L, D, U (Z, Y, X, MODE on pins 1-4 after the
    // third falling edge, 6-button only); select low gives START, A, low,
    // low, D, U (all four low after the third falling edge, all high after
    // the fourth, 6-button only)
    wire [5:0] md_pins;
    assign md_pins = sel ? ((six && mdcnt == 3) ? {md[5], md[4], md[11], md[10], md[9], md[8]}
                                                : {md[5], md[4], md[3], md[2], md[1], md[0]})
                         : ((six && mdcnt == 3) ? {md[7], md[6], 4'b1111}
                         :  (six && mdcnt == 4) ? {md[7], md[6], 4'b0000}
                         :                        {md[7], md[6], 2'b11, md[1], md[0]});
    wire [5:0] p2_n = ~md_pins;
    wire [5:0] pin_n = joysel ? p2_n : p1_n;

    joy joys (
        .clk(clk), .rst(rst),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
        .rb_rdata(rd_joy), .rb_hit(hit_joy),
        .pin_n(pin_n), .joysel(joysel), .sel_o(sel)
    );

    // Select stays high for at least 1.5 ms before each burst
    realtime selrise = 0;
    always @(posedge sel) selrise = $realtime;
    always @(negedge sel)
        if (selrise > 0 && $realtime - selrise > 50000.0 && $realtime - selrise < 1500000.0) begin
            errors = errors + 1;
            $display("FAIL select high for only %0t ns before a burst", $realtime - selrise);
        end

    // ---------------------------------------------------------------- the tests
    integer i, n;
    task ps2(input [7:0] b);
        kbm.send(b, 1'b0);
    endtask
    task inject(input [7:0] b);        // one KEY, as serial.v gives it
        begin
            @(negedge clk); inj_stb = 1'b1; inj_byte = b;
            @(negedge clk); inj_stb = 1'b0;
            #100;
        end
    endtask
    task settle;
        #(3 * SCAN);
    endtask
    // A port 0xFE row: the value with columns 'cols' (bits 4-0, 1 = pressed)
    function [7:0] fe(input [4:0] pressed);
        fe = 8'hE0 | ~{3'b000, pressed} & 8'hFF;
    endfunction

    initial begin
        if ($test$plusargs("vcd")) begin $dumpfile("tb_input.vcd"); $dumpvars(0, tb_input); end
        #100 rst = 1'b0;
        #100;

        // ---- reset values
        expect("KBCON reset", `RM_KBCON, 0, 8'h00);
        expect("KEYCON reset", `RM_KEYCON, 0, 8'h07);
        expect("port 0xFE idle", `RM_ULA, 8'h00, 8'hFF);
        expect("KBSEND reads 0", `RM_KBSEND, 0, 8'h00);

        // ---- PS/2 mapper with KBCON.EN = 0: A, then released
        ps2(8'h1C);
        #1000;
        expect("PS/2 A: 0xFE row 1", `RM_ULA, 8'hFD, fe(5'b00001));
        expect("PS/2 A: other rows", `RM_ULA, 8'hFE, 8'hFF);
        expect("PS/2 A: KEYROW1", `RM_KEYROW1, 0, fe(5'b00001));
        expect("PS/2 A: KEYMAP0 unchanged", `RM_KEYMAP0, 0, 8'h00);
        expect("PS/2 A: no FIFO with EN = 0", `RM_KBSTAT, 0, 8'h00);
        ps2(8'hF0); ps2(8'h1C);
        #1000;
        expect("PS/2 A released", `RM_ULA, 8'h00, 8'hFF);

        // ---- E0 told from plain: cursor up (CAPS SHIFT + 7) against keypad 8
        ps2(8'hE0); ps2(8'h75);
        #1000;
        expect("cursor up: row 0", `RM_ULA, 8'hFE, fe(5'b00001));
        expect("cursor up: row 4", `RM_ULA, 8'hEF, fe(5'b01000));
        ps2(8'h75);
        #1000;
        expect("+ keypad 8: row 4", `RM_ULA, 8'hEF, fe(5'b01100));
        ps2(8'hE0); ps2(8'hF0); ps2(8'h75);
        #1000;
        expect("cursor up released: row 0", `RM_ULA, 8'hFE, 8'hFF);
        expect("keypad 8 still held", `RM_ULA, 8'hEF, fe(5'b00100));
        ps2(8'hF0); ps2(8'h75);
        // Fake shift ignored; two keys giving CAPS SHIFT
        ps2(8'hE0); ps2(8'h12);
        #1000;
        expect("fake shift ignored", `RM_ULA, 8'h00, 8'hFF);
        ps2(8'h12); ps2(8'h59);
        ps2(8'hF0); ps2(8'h12);
        #1000;
        expect("right shift still held", `RM_ULA, 8'hFE, fe(5'b00001));
        // AA clears every held bit
        ps2(8'h29);                    // and SPACE
        ps2(8'hAA);
        #1000;
        expect("AA clears", `RM_ULA, 8'h00, 8'hFF);
        // Backspace: CAPS SHIFT + 0; PS2MAP = 0 hides it and clears it
        ps2(8'h66);
        #1000;
        expect("backspace: row 0", `RM_ULA, 8'hFE, fe(5'b00001));
        expect("backspace: row 4", `RM_ULA, 8'hEF, fe(5'b00001));
        wr(`RM_KEYCON, 8'h03);
        expect("PS2MAP = 0", `RM_ULA, 8'h00, 8'hFF);
        wr(`RM_KEYCON, 8'h07);
        expect("PS2MAP = 1 again: cleared", `RM_ULA, 8'h00, 8'hFF);
        // Pause maps to nothing (E1 14 77 E1 F0 14 F0 77)
        ps2(8'hE1); ps2(8'h14); ps2(8'h77); ps2(8'hE1); ps2(8'hF0); ps2(8'h14); ps2(8'hF0); ps2(8'h77);
        ps2(8'h14);                    // then Ctrl: SYMBOL SHIFT
        #1000;
        expect("after Pause, Ctrl", `RM_ULA, 8'h7F, fe(5'b00010));
        ps2(8'hF0); ps2(8'h14);

        // ---- the FIFO
        wr(`RM_KBCON, 8'h01);
        wr(`RM_KBIRQEN, 8'h01);
        if (irq) begin errors = errors + 1; $display("FAIL KEYB with an empty FIFO"); end
        ps2(8'h1C); ps2(8'hF0); ps2(8'h1C);
        #1000;
        expect("COUNT 3", `RM_KBSTAT, 0, 8'h03);
        expect("KBIRQ.DATA", `RM_KBIRQ, 0, 8'h01);
        if (!irq) begin errors = errors + 1; $display("FAIL no KEYB with bytes waiting"); end
        expect("KBDATA 1", `RM_KBDATA, 0, 8'h1C);
        expect("KBDATA 2 (port 0x62)", 13'h062, 8'h03, 8'hF0);
        expect("KBDATA 3", `RM_KBDATA, 0, 8'h1C);
        expect("KBDATA empty", `RM_KBDATA, 0, 8'h00);
        expect("COUNT 0", `RM_KBSTAT, 0, 8'h00);
        #100;
        if (irq) begin errors = errors + 1; $display("FAIL KEYB stays on"); end
        // Bad parity: dropped, PARITY
        kbm.send(8'h55, 1'b1);
        #1000;
        expect("bad parity: COUNT 0", `RM_KBSTAT, 0, 8'h00);
        expect("PARITY", `RM_KBIRQ, 0, 8'h02);
        wr(`RM_KBIRQ, 8'h02);
        expect("PARITY cleared", `RM_KBIRQ, 0, 8'h00);
        // 17 bytes: 16 kept, OVERFLOW
        for (i = 0; i < 17; i = i + 1) ps2(8'h20 + i);
        #1000;
        expect("16 kept", `RM_KBSTAT, 0, 8'h10);
        expect("OVERFLOW", `RM_KBIRQ, 0, 8'h09);
        expect("the first kept", `RM_KBDATA, 0, 8'h20);
        wr(`RM_KBIRQ, 8'h08);
        ps2(8'hAA);                    // (the mapper let go of those 17 keys)
        // EN = 0 empties the FIFO
        wr(`RM_KBCON, 8'h00);
        wr(`RM_KBCON, 8'h01);
        expect("EN = 0 empties", `RM_KBSTAT, 0, 8'h00);
        // Sending: ED arrives with the right parity; TXBUSY; the answer FA
        wr(`RM_KBSEND, 8'hED);
        expect("TXBUSY", `RM_KBSTAT, 0, 8'h80);
        n = kbm.nrx;
        wait (kbm.nrx == n + 1);
        if (kbm.last_rx !== 8'hED || kbm.rx_bad != 0) begin
            errors = errors + 1; $display("FAIL sent %02x, %0d bad", kbm.last_rx, kbm.rx_bad);
        end
        #500000;
        expect("FA came back", `RM_KBSTAT, 0, 8'h01);
        expect("FA", `RM_KBDATA, 0, 8'hFA);
        // A keyboard that does not answer: TIMEOUT after 15 ms
        kb_plugged = 1'b0;
        wr(`RM_KBSEND, 8'hFF);
        #16000000;
        expect("TIMEOUT: not busy", `RM_KBSTAT, 0, 8'h00);
        expect("TIMEOUT", `RM_KBIRQ, 0, 8'h10);
        wr(`RM_KBIRQ, 8'h10);
        kb_plugged = 1'b1;
        #100000;

        // ---- KEY from the link (ticket #44): bytes taken as if received
        inject(8'h1C);                 // A down
        expect("KEY: in the FIFO", `RM_KBSTAT, 0, 8'h01);
        expect("KEY: A on port 0xFE", `RM_ULA, 8'hFD, fe(5'b00001));
        inject(8'hF0); inject(8'h1C);  // A up
        expect("KEY: A let go", `RM_ULA, 8'hFD, 8'hFF);
        expect("KEY: KBDATA 1", `RM_KBDATA, 0, 8'h1C);
        expect("KEY: KBDATA 2", `RM_KBDATA, 0, 8'hF0);
        expect("KEY: KBDATA 3", `RM_KBDATA, 0, 8'h1C);
        // on the clock a real byte is taken: both kept, the keyboard's first
        fork
            ps2(8'h32);
            begin
                @(negedge clk);
                while (!(kb.rn == 4'd10 && kb.kfall)) @(negedge clk);
                inj_stb = 1'b1; inj_byte = 8'h21;
                @(negedge clk); inj_stb = 1'b0;
            end
        join
        #1000;
        expect("KEY with a real byte: COUNT 2", `RM_KBSTAT, 0, 8'h02);
        expect("KEY with a real byte: the keyboard's", `RM_KBDATA, 0, 8'h32);
        expect("KEY with a real byte: the link's", `RM_KBDATA, 0, 8'h21);
        inject(8'hF0); inject(8'h32); inject(8'hF0); inject(8'h21);   // B and C up
        // KBCON.EN off: the mapper only
        wr(`RM_KBCON, 8'h00);
        inject(8'h3A);                 // M down
        expect("KEY, EN off: M on port 0xFE", `RM_ULA, 8'h7F, fe(5'b00100));
        expect("KEY, EN off: FIFO empty", `RM_KBSTAT, 0, 8'h00);
        inject(8'hF0); inject(8'h3A);
        expect("KEY, EN off: M let go", `RM_ULA, 8'h7F, 8'hFF);
        // nothing running (EN and PS2MAP off): ignored
        wr(`RM_KEYCON, 8'h03);
        inject(8'h1C);
        wr(`RM_KEYCON, 8'h07);
        expect("KEY, receiver off: nothing", `RM_ULA, 8'hFD, 8'hFF);
        wr(`RM_KBCON, 8'h01);
        expect("KEY, receiver off: FIFO empty", `RM_KBSTAT, 0, 8'h00);

        // ---- the membrane: A (row 1, column 0) and M (row 7, column 2)
        mkeys[7 * 1 + 0] = 1'b1;
        mkeys[7 * 7 + 2] = 1'b1;
        settle;
        expect("KEYMAP0", `RM_KEYMAP0, 0, 8'h02);
        expect("KEYMAP2", `RM_KEYMAP2, 0, 8'h80);
        expect("0xFE row 1", `RM_ULA, 8'hFD, fe(5'b00001));
        expect("0xFE row 7", `RM_ULA, 8'h7F, fe(5'b00100));
        expect("0xFE rows 1 and 7", `RM_ULA, 8'h7D, fe(5'b00101));
        expect("0xFE all rows (page form)", `RM_ULA, 8'h00, fe(5'b00101));
        expect("0xFE row 0", `RM_ULA, 8'hFE, 8'hFF);
        expect("KEYROW7", `RM_KEYROW7, 0, fe(5'b00100));
        mkeys = 56'd0;
        settle;
        expect("released", `RM_ULA, 8'h00, 8'hFF);
        // An extra key: EDIT (row 3, column 6) gives CAPS SHIFT + 1 with KXMAP
        mkeys[7 * 3 + 6] = 1'b1;
        settle;
        expect("KEYMAP6: EDIT", `RM_KEYMAP6, 0, 8'h08);
        expect("EDIT: row 0", `RM_ULA, 8'hFE, fe(5'b00001));
        expect("EDIT: row 3", `RM_ULA, 8'hF7, fe(5'b00001));
        wr(`RM_KEYCON, 8'h06);
        expect("KXMAP = 0", `RM_ULA, 8'h00, 8'hFF);
        wr(`RM_KEYCON, 8'h05);
        expect("EAR6 = 0", `RM_ULA, 8'h00, 8'hBF & fe(5'b00001));
        wr(`RM_KEYCON, 8'h07);
        mkeys = 56'd0;
        // DELETE (row 6, column 5): CAPS SHIFT + 0
        mkeys[7 * 6 + 5] = 1'b1;
        settle;
        expect("KEYMAP5: DELETE", `RM_KEYMAP5, 0, 8'h40);
        expect("DELETE: row 4", `RM_ULA, 8'hEF, fe(5'b00001));
        mkeys = 56'd0;
        settle;
        // Bounce shorter than a scan is not seen
        #(SCAN / 2);
        mkeys[7 * 2 + 4] = 1'b1;       // T
        #(SCAN / 4);
        mkeys = 56'd0;
        settle;
        expect("bounce ignored", `RM_KEYMAP4, 0, 8'h00);

        // ---- joysticks: port 1 an Atari stick, port 2 a 6-button pad
        j1 = 6'b010001;                // Fire 1, Up
        md = 12'b1100_0110_0100;       // MODE, X; A, C; L
        wr(`RM_JOYCON, 8'h02);         // port 2: Mega Drive
        #6000000;
        expect("JOY1: up, fire", `RM_JOY1, 0, 8'h18);
        expect("Kempston", `RM_KEMPSTON, 0, 8'h18);
        expect("Kempston, port 0x1F any high byte", 13'h01F, 8'h55, 8'h18);
        expect("JOY2: A, C, left", `RM_JOY2, 0, 8'h62);
        expect("JOY2X: X, MODE", `RM_JOY2X, 0, 8'h09);
        expect("JOYCON: MDPRES2, SIX2, MD2", `RM_JOYCON, 0, 8'hA2);
        expect("JOY1X 0", `RM_JOY1X, 0, 8'h00);
        j1 = 6'b101010;                // Fire 2, Right, Down
        md = 12'b0001_1001_0001;       // Z; START, B; U
        #6000000;
        expect("JOY1: fire 2, right, down", `RM_JOY1, 0, 8'h25);
        expect("JOY2: START, B, up", `RM_JOY2, 0, 8'h98);
        expect("JOY2X: Z", `RM_JOY2X, 0, 8'h04);
        // A 3-button pad: no SIX2, JOY2X 0
        six = 1'b0;
        #6000000;
        expect("3-button: JOY2", `RM_JOY2, 0, 8'h98);
        expect("3-button: JOY2X", `RM_JOY2X, 0, 8'h00);
        expect("3-button: JOYCON", `RM_JOYCON, 0, 8'h82);
        // MD2 = 0: port 2 read as an Atari stick, A and START not seen
        wr(`RM_JOYCON, 8'h00);
        #1000000;
        expect("Atari read of a pad", `RM_JOY2, 0, 8'h18);
        expect("JOYCON 0", `RM_JOYCON, 0, 8'h00);

        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end
endmodule
