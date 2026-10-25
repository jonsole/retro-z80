// Port 0xFE writes on their own (ticket #21): the border (video.v; spec 4,
// section 7.2) and the beeper (audio.v; spec 7, section 10.2). The register
// bus is driven as the bus interface drives it: a one-clock strobe, the
// data the clock after. Writes to register 0x00FE stand for every form of
// port 0xFE (bus_if.v sends them all there, as the system test checks).
//
//   Border    with the beam running and no layers on, a port 0xFE write in
//             the middle of a line shows on the picture output 7-60 ns
//             after the clock that takes the write, at many phases of the
//             pixel clock against the system clock; bits 7-3 do not change
//             the colour; BGCOLOR reads back the Spectrum colour at 0xD7;
//             the colour assembly buffer is kept; a BGCOLOR register write
//             still waits for the next line; the next line keeps the 0xFE
//             colour
//   Beeper    the three sigma-delta streams average 1/2 + 1/16 with bit 4
//             set and 1/2 - 1/16 with it clear (a quarter of full scale),
//             whatever bits 3 and 5-7 hold
`timescale 1ns/1ps
`include "regmap.vh"

module tb_fe;
    reg clk = 1'b1;
    always #5 clk = ~clk;              // 100 MHz
    reg rst = 1'b1;

    // The 576p clocks, as tb.v's: 135 MHz and 27 MHz with edges on it, at
    // an odd phase against clk
    reg clk_pix = 1'b0, clk_pix5 = 1'b0;
    initial begin : pixclocks
        integer n, k;
        real t;
        k = 0;
        n = 0;
        forever begin
            n = n + 1;
            t = 3.1 + n * (1000.0 / 270.0);
            #(t - $realtime);
            clk_pix5 = ~clk_pix5;
            if (clk_pix5) begin
                if (k == 0) clk_pix = 1'b1;
                k = (k == 4) ? 0 : k + 1;
            end else if (k == 3) clk_pix = 1'b0;
        end
    end

    integer errors = 0;
    task check(input [255:0] what, input [23:0] got, input [23:0] want);
        if (got !== want) begin
            errors = errors + 1;
            $display("FAIL %0s: got %06x, expected %06x (t = %0t)", what, got, want, $time);
        end
    endtask

    // ---------------------------------------------------------------- the register bus
    reg         rb_rd = 1'b0, rb_wr = 1'b0;
    reg  [12:0] rb_addr = 13'd0;
    reg  [7:0]  rb_wdata = 8'd0;
    wire [7:0]  rd_vid;
    wire        hit_vid;
    realtime    t_wr;                  // the clock edge that takes the last write

    task wr(input [12:0] a, input [7:0] d);
        begin
            @(negedge clk); rb_addr = a; rb_wdata = d; rb_wr = 1'b1;
            @(posedge clk); t_wr = $realtime;
            @(negedge clk); rb_wr = 1'b0;
        end
    endtask
    reg [7:0] v;
    task rd(input [12:0] a);
        begin
            @(negedge clk); rb_addr = a; rb_rd = 1'b1;
            @(negedge clk); rb_rd = 1'b0; v = rd_vid;
        end
    endtask
    reg [23:0] bg;
    task rdbg;
        begin
            rd(`RM_BGCOLOR0); bg[7:0]   = v;
            rd(`RM_BGCOLOR1); bg[15:8]  = v;
            rd(`RM_BGCOLOR2); bg[23:16] = v;
        end
    endtask

    // ---------------------------------------------------------------- the units
    wire [23:0] rgb;
    wire        hs, vs, de;
    video #(.NL(1)) vid (
        .clk(clk), .rst(rst),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
        .rb_rdata(rd_vid), .rb_hit(hit_vid), .rb_cdata(), .rb_cap(),
        .frame_tick(), .line_tick(), .irq(), .irq_err(),
        .disp_req(), .disp_urgent(), .disp_deadline(), .disp_addr(),
        .disp_ack(1'b0), .disp_rvalid(1'b0), .disp_rdata(16'd0),
        .spr_req(), .spr_urgent(), .spr_deadline(), .spr_addr(),
        .spr_ack(1'b0), .spr_rvalid(1'b0),
        .clk_pix(clk_pix), .clk_pix5(clk_pix5),
        .rgb(rgb), .hsync(hs), .vsync(vs), .de(de)
    );

    wire dac_l, dac_r, dac_m;
    audio aud (
        .clk(clk), .rst(rst),
        .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
        .dac_l(dac_l), .dac_r(dac_r), .dac_m(dac_m)
    );

    // The picture output: when it last changed, at a pixel clock edge
    realtime t_rgb;
    reg [23:0] rgb_q = 24'd0;
    always @(posedge clk_pix) begin
        #0.1;
        if (rgb !== rgb_q) t_rgb = $realtime;
        rgb_q = rgb;
    end

    function [23:0] spec(input [2:0] c);
        spec = {c[1] ? 8'hD7 : 8'h00, c[2] ? 8'hD7 : 8'h00, c[0] ? 8'hD7 : 8'h00};
    endfunction

    // Wait until the beam is at pixel x of a picture line, then n system clocks
    task at_x(input integer x, input integer n);
        integer j;
        begin
            @(posedge clk_pix);
            while (!(vid.hc == x && vid.vc > 10 && vid.vc < 560)) @(posedge clk_pix);
            for (j = 0; j < n; j = j + 1) @(posedge clk);
        end
    endtask

    // Count the ones of each stream over 2^16 clocks
    integer n_l, n_r, n_m;
    task count;
        integer j;
        begin
            n_l = 0; n_r = 0; n_m = 0;
            for (j = 0; j < 65536; j = j + 1) begin
                @(posedge clk); #1;
                n_l = n_l + dac_l; n_r = n_r + dac_r; n_m = n_m + dac_m;
            end
        end
    endtask
    task beep(input [255:0] what, input [7:0] d, input integer want);
        begin
            wr(`RM_ULA, d);
            repeat (1000) @(posedge clk);  // the modulators settle
            count;
            // 2^16 x (1/2 +- 1/16) = 32768 +- 4096; a few ones either way
            if (n_l < want - 8 || n_l > want + 8 || n_r < want - 8 || n_r > want + 8 ||
                n_m < want - 8 || n_m > want + 8) begin
                errors = errors + 1;
                $display("FAIL %0s: ones %0d %0d %0d of 65536, expected %0d", what, n_l, n_r, n_m, want);
            end else
                $display("%0s: ones %0d %0d %0d of 65536 (expected %0d)", what, n_l, n_r, n_m, want);
        end
    endtask

    integer i, dmin, dmax, d;
    reg [2:0] c;
    initial begin
        repeat (20) @(posedge clk);
        rst = 1'b0;
        repeat (20) @(posedge clk);
        wr(`RM_VIDCON, 8'h01);         // the beam on, no layers: the background everywhere

        // ---- border: mid-line, at many phases
        dmin = 1000; dmax = 0;
        for (i = 0; i < 64; i = i + 1) begin
            c = (i % 7) + 1;           // never the colour already shown
            if (spec(c) == rgb_q) c = c + 1;
            at_x(200 + 7 * i, i % 11);
            wr(`RM_ULA, {i[4:0], c});  // bits 7-3 vary: no effect on the colour
            wait (rgb_q == spec(c) && t_rgb > t_wr);
            d = (t_rgb - t_wr);
            if (d < dmin) dmin = d;
            if (d > dmax) dmax = d;
            if (d < 7 || d > 60 || !de) begin
                errors = errors + 1;
                $display("FAIL border %0d: colour %0d shown %0d ns after the write (de %b)", i, c, d, de);
            end
            rdbg;
            check("BGCOLOR after port 0xFE", bg, spec(c));
        end
        $display("border: 64 mid-line writes shown %0d-%0d ns after the write", dmin, dmax);

        // ---- the next line keeps the colour; BGCOLOR writes wait for the next line
        wr(`RM_ULA, 8'h05);            // cyan
        at_x(100, 0);
        check("next line after port 0xFE", rgb_q, spec(3'd5));
        wr(`RM_BGCOLOR0, 8'h11);
        wr(`RM_BGCOLOR1, 8'h22);
        wr(`RM_ULA, 8'h02);            // red at once; the buffer kept
        at_x(300, 0);
        check("port 0xFE between buffer writes", rgb_q, spec(3'd2));
        wr(`RM_BGCOLOR2, 8'h33);
        rdbg;
        check("colour assembly buffer kept", bg, 24'h332211);
        repeat (20) @(posedge clk_pix);
        check("BGCOLOR waits for the next line", rgb_q, spec(3'd2));
        at_x(100, 0);
        check("BGCOLOR on the next line", rgb_q, 24'h332211);
        wr(`RM_ULA, 8'h07);            // white, after a BGCOLOR write in the same line
        at_x(400, 0);
        check("port 0xFE after BGCOLOR", rgb_q, spec(3'd7));

        // ---- beeper
        beep("beeper 0", 8'h00, 28672);
        beep("beeper 1", 8'h10, 36864);
        beep("beeper 1, other bits set", 8'hFF, 36864);
        beep("beeper 0, other bits set", 8'hEF, 28672);

        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("TEST FAILED: timeout");
        $finish;
    end
endmodule
