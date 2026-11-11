// Sound (spec 13) and the audio output (spec 7, section 10.2). 100 MHz.
//
// Four sample channels: retro-hw's audio_engine (its docs/spec/audio_engine.md,
// revision 3), shared with retro68k, which keeps the channels' settings and
// plays them. Here, as retro68k's audio.v narrowed to bytes: the registers
// on the 8-bit register bus (custom 0x244-0x2F6), AUDRATE with its floor,
// the starts and stops from AUDDMA (with DMACON.DMAEN and AUDEN),
// AUDSTART and AUDSTOP, AUDSTAT and the AUDIO interrupt (source 9), and the
// DACs.
//
// A channel register is one of the core's fields, a 4-byte word each, low
// byte first: a write is one set_we with that byte's enable. A read is
// registered here (rb_re from a flip-flop, so the bus decode is not in the
// engine's RAM address path) and answered a clock later than other units
// answer: rb_late asks the bus interface to wait for it. Reading AUDxPOS's
// low byte hands all three bytes to the CPU's capture (spec 3, rule 4),
// since POS moves.
//
// The Spectrum-style beeper stays: bit 4 of the last write to port 0xFE
// (register 0x00FE of page 0x00, whatever the high byte holds; spec 12,
// section 8.4), 0 after reset. 0 gives -BEEPAMP and 1 +BEEPAMP, a quarter of
// full scale, on both sides, added to the channels' mix with clipping.
// Three second-order sigma-delta modulators (retro-hw's sigma_delta2) turn
// left, right and mono ((left + right) / 2) into bit streams for the
// board's RC filters: the jack and the internal speaker.
`include "regmap.vh"

module audio (
    input  wire        clk,
    input  wire        rst,

    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [12:0] rb_addr,
    input  wire [7:0]  rb_wdata,
    output wire [7:0]  rb_rdata,
    output wire        rb_hit,
    output wire [31:0] rb_cdata,       // with rb_rdata: AUDxPOS whole, for the capture
    output wire        rb_cap,
    output wire        rb_late,        // a channel register's read: its answer comes a clock later

    input  wire        aud_on,         // DMACON.DMAEN and AUDEN

    // Memory (dmac.v requester 2, AUD): reads
    output wire        mem_req,
    output wire [21:1] mem_addr,
    input  wire        mem_ack,
    input  wire        mem_rvalid,
    input  wire [15:0] mem_rdata,

    output wire        irq,            // AUDIO (source 9)

    output wire        dac_l,          // sigma-delta streams
    output wire        dac_r,
    output wire        dac_m
);
    // ================================================================ register decode
    wire        in_c  = rb_addr[12:10] == 3'b100;               // the custom block
    wire [9:0]  off   = rb_addr[9:0];
    wire        sel_c = in_c && off[9:7] == 3'b101;             // channels: 0x280-0x2FF
    wire [1:0]  cn    = off[6:5];
    wire [2:0]  fld   = off[4:2];                               // the core's field
    wire [1:0]  bi    = off[1:0];
    // The bytes the channel registers have (spec 3, section 5.10)
    wire        c_has = sel_c && (fld == 3'd0 ? bi == 2'd0 : fld <= 3'd5 && bi != 2'd3);
    wire        c_wr  = c_has && fld != 3'd5;                   // POS is read only

    wire        sel_rate  = rb_addr == `RM_AUDRATE || rb_addr == `RM_AUDRATE + 13'd1;
    wire        sel_stat  = rb_addr == `RM_AUDSTAT;
    wire        sel_inten = rb_addr == `RM_AUDINTEN;
    wire        sel_start = rb_addr == `RM_AUDSTART;
    wire        sel_stop  = rb_addr == `RM_AUDSTOP;
    wire        sel_dma   = rb_addr == `RM_AUDDMA;

    // ================================================================ globals
    reg  [15:0] rate;
    reg  [3:0]  stat, inten, dma;
    reg  [3:0]  en_d;                  // the enables a clock ago
    wire [3:0]  on, ev;                // playing (AUDSTAT.ACTIVE); a block taken, or a one-shot's end

    // Starting and stopping act as soon as they are written (spec 13, 5.2)
    wire [3:0]  en   = aud_on ? dma : 4'd0;
    wire        w_start = rb_wr && sel_start;
    wire        w_stop  = rb_wr && sel_stop;
    wire [3:0]  go   = (en & ~en_d) | (w_start ? rb_wdata[3:0] & en : 4'd0);
    wire [3:0]  halt = (~en & en_d) | (w_stop ? rb_wdata[3:0] : 4'd0);

    assign irq = |(stat & inten);
    wire [15:0] rate_c = (rate < 16'd200) ? 16'd200 : rate;

    always @(posedge clk) begin
        if (rst) begin
            rate  <= 16'd2083;
            stat  <= 4'd0;
            inten <= 4'd0;
            dma   <= 4'd0;
            en_d  <= 4'd0;
        end else begin
            en_d <= en;
            stat <= stat | ev;
            if (rb_wr) begin
                if (rb_addr == `RM_AUDRATE)          rate[7:0]  <= rb_wdata;
                if (rb_addr == `RM_AUDRATE + 13'd1)  rate[15:8] <= rb_wdata;
                // A write of 1 wins over an event in the same clock (as retro68k)
                if (sel_stat)  stat  <= (stat | ev) & ~rb_wdata[3:0];
                if (sel_inten) inten <= rb_wdata[3:0];
                if (sel_dma) begin
                    if (rb_wdata[`RM_AUDDMA_SETCLR]) dma <= dma |  rb_wdata[3:0];
                    else                              dma <= dma & ~rb_wdata[3:0];
                end
            end
        end
    end

    // ================================================================ the channels
    // CTRL's bits sit one place up in the register (BITS16 is bit 1)
    wire [23:0] rb_q;
    reg         rq, rq2;               // a channel read: the core's strobe, then its answer
    reg  [1:0]  rq_ch, rq_b;
    reg  [2:0]  rq_f;
    always @(posedge clk) begin
        rq    <= rb_rd && c_has && !rst;
        rq2   <= rq;
        if (rb_rd) begin
            rq_ch <= cn;  rq_f <= fld;  rq_b <= bi;
        end
    end
    assign rb_late = rq;

    wire signed [15:0] eng_l, eng_r;
    audio_engine #(.NCH(4), .AW(21), .LE(1), .INTERP(1), .RDBACK(1)) eng (
        .clk(clk), .rst(rst),
        .rate(rate_c), .start(go), .stop(halt), .on(on), .ev(ev),
        .set_we(rb_wr && c_wr), .set_ch(cn), .set_f(fld),
        .set_d(fld == 3'd0 ? {21'd0, rb_wdata[3:1]} : {rb_wdata, rb_wdata, rb_wdata}),
        .set_be({bi == 2'd2, bi == 2'd1, bi == 2'd0}),
        .rb_re(rq), .rb_ch(rq_ch), .rb_f(rq_f), .rb_q(rb_q),
        .mem_req(mem_req), .mem_addr(mem_addr), .mem_ack(mem_ack),
        .mem_rvalid(mem_rvalid), .mem_rdata(mem_rdata),
        .out_l(eng_l), .out_r(eng_r), .out_v()
    );

    // ================================================================ reads
    // The globals the clock after the strobe; a channel's two clocks after
    reg  [7:0]  g_q;
    reg         g_hit;
    always @(posedge clk) begin
        g_q   <= 8'd0;
        g_hit <= 1'b0;
        if (rb_rd) begin
            if (rb_addr == `RM_AUDRATE) begin
                g_hit <= 1'b1;  g_q <= rate[7:0];
            end else if (rb_addr == `RM_AUDRATE + 13'd1) begin
                g_hit <= 1'b1;  g_q <= rate[15:8];
            end else if (sel_stat) begin
                g_hit <= 1'b1;  g_q <= {on, stat};
            end else if (sel_inten) begin
                g_hit <= 1'b1;  g_q <= {4'd0, inten};
            end else if (sel_start || sel_stop) begin
                g_hit <= 1'b1;                          // write only: reads 0
            end else if (sel_dma) begin
                g_hit <= 1'b1;  g_q <= {4'd0, dma};
            end
        end
    end
    wire [7:0]  c_q = rq_f == 3'd0 ? {4'd0, rb_q[2:0], 1'b0} : rb_q[8*rq_b +: 8];
    assign rb_rdata = g_q | (rq2 ? c_q : 8'd0);
    assign rb_hit   = g_hit | rq2;
    assign rb_cap   = rq2 && rq_f == 3'd5 && rq_b == 2'd0;
    assign rb_cdata = rb_cap ? {8'd0, rb_q} : 32'd0;

    // ================================================================ the beeper and the DACs
    localparam signed [15:0] BEEPAMP = 16'sh2000;      // a quarter of full scale

    reg beep;
    always @(posedge clk)
        if (rst)                                beep <= 1'b0;
        else if (rb_wr && rb_addr == `RM_ULA)   beep <= rb_wdata[`RM_ULA_BEEPER];

    wire signed [15:0] bp = beep ? BEEPAMP : -BEEPAMP;
    function signed [15:0] clip(input signed [16:0] v);
        clip = (v > 17'sd32767) ? 16'sh7FFF : (v < -17'sd32768) ? 16'sh8000 : v[15:0];
    endfunction
    reg  signed [15:0] out_l, out_r;
    always @(posedge clk) begin
        out_l <= clip(eng_l + bp);
        out_r <= clip(eng_r + bp);
    end

    sigma_delta2 sd_l (.clk(clk), .rst(rst), .x(out_l), .y(dac_l));
    sigma_delta2 sd_r (.clk(clk), .rst(rst), .x(out_r), .y(dac_r));
    wire signed [16:0] mono = out_l + out_r;
    sigma_delta2 sd_m (.clk(clk), .rst(rst), .x(mono[16:1]), .y(dac_m));
endmodule
