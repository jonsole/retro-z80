// PS/2 keyboard (spec 12, section 3). retro68k's ps2kb.v narrowed to byte
// registers 0x60-0x65 of the system page on the 8-bit register bus. 100 MHz.
//
// Receiving: the keyboard clocks 11-bit frames (start 0, 8 data bits
// lowest first, odd parity, stop 1) at 10-17 kHz; a bit is taken at each
// falling edge of its clock. The clock line is filtered (it must hold a
// new level for 0.64 us) against noise. Good bytes go into a 16-byte FIFO
// unchanged; bad ones are dropped and flagged. A frame not finished within
// 2 ms is dropped (the next starts afresh). The receiver runs while
// KBCON.EN or KEYCON.PS2MAP (map_en) is 1; every good byte is also handed
// to the Spectrum key mapper (rx_stb, rx_byte), whether or not it fits in
// the FIFO (spec 12, section 8.3).
//
// Sending (KBSEND, with KBCON.EN set): hold the clock low for 100 us, pull
// data low (the start bit), let the clock go; then the keyboard clocks the
// bits in: each is put out after a falling edge (8 data bits, parity, stop
// = data let go), and the keyboard answers by pulling data low for one more
// clock. 15 ms without that: TIMEOUT. Nothing is received while sending.
//
// Both lines are open collector: the outputs say when to pull a line low.
//
// Registers (spec 12, section 6): KBCON EN (0); KBSTAT COUNT (4-0), TXBUSY
// (7); KBDATA takes a byte (0x00 when empty), also through port 0x62 with
// any high byte (the bus interface gives every path bus address 0x062);
// KBSEND; KBIRQ DATA (0, live), PARITY, FRAME, OVERFLOW, TIMEOUT (sticky,
// write 1 to clear); KBIRQEN.
`include "regmap.vh"

module ps2kb (
    input  wire        clk,
    input  wire        rst,

    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [12:0] rb_addr,
    input  wire [7:0]  rb_wdata,
    output reg  [7:0]  rb_rdata,
    output reg         rb_hit,

    input  wire        ps2_clk_i,
    input  wire        ps2_data_i,
    output reg         ps2_clk_low,    // pull the clock line low
    output reg         ps2_data_low,   // pull the data line low

    input  wire        map_en,         // KEYCON.PS2MAP: the receiver runs for the mapper too
    output reg         rx_stb,         // 1 clock: a good byte was received ...
    output reg  [7:0]  rx_byte,        // ... this one
    output wire        rx_on,          // the receiver is running

    output wire        irq             // KEYB (spec 8, source 17)
);
    wire        sel = (rb_addr >= `RM_KBCON) && (rb_addr <= `RM_KBIRQEN);

    reg         en;
    reg  [4:0]  irqf;                  // TIMEOUT 4, OVERFLOW 3, FRAME 2, PARITY 1 (DATA, bit 0, is live)
    reg  [4:0]  irqen;
    assign      rx_on = en || map_en;

    // ---------------------------------------------------------------- the lines
    (* ASYNC_REG = "TRUE" *) reg [1:0] cs, ds;
    always @(posedge clk) begin
        cs <= {cs[0], ps2_clk_i};
        ds <= {ds[0], ps2_data_i};
    end
    reg         kc;                    // the clock, filtered
    reg  [5:0]  kcn;
    always @(posedge clk)
        if (rst) begin kc <= 1'b1; kcn <= 6'd0; end
        else if (cs[1] == kc) kcn <= 6'd0;
        else if (kcn == 6'd63) begin kc <= cs[1]; kcn <= 6'd0; end
        else kcn <= kcn + 1'b1;
    reg         kc_d;
    always @(posedge clk) kc_d <= kc;
    wire        kfall = kc_d && !kc;

    // ---------------------------------------------------------------- the FIFO
    reg  [7:0]  fifo [0:15];
    reg  [3:0]  fh, ft;
    reg  [4:0]  fcount;
    wire        f_pop  = rb_rd && rb_addr == `RM_KBDATA && fcount != 5'd0;
    reg         f_push;
    reg  [7:0]  f_byte;
    assign irq = |({irqf[4:1], fcount != 5'd0} & irqen);

    // ---------------------------------------------------------------- receive and send
    reg  [3:0]  rn;                    // bits of the frame so far
    reg  [9:0]  rsh;                   // data, parity, stop (start checked on its own)
    reg  [17:0] rt;                    // time since the frame's last bit
    reg         tx, tx_ack;            // sending; waiting for the keyboard's answer
    reg  [8:0]  tsh;                   // data and parity still to send
    reg  [3:0]  tn;
    reg  [20:0] tt;                    // time: the 100 us hold, then the 15 ms limit

    wire        send_w = rb_wr && rb_addr == `RM_KBSEND && en && !tx;

    always @(posedge clk) begin
        f_push <= 1'b0;
        rx_stb <= 1'b0;
        if (rst) begin
            en <= 1'b0; irqf <= 5'd0; irqen <= 5'd0;
            fh <= 4'd0; ft <= 4'd0; fcount <= 5'd0;
            rn <= 4'd0; rt <= 18'd0; tx <= 1'b0; tx_ack <= 1'b0;
            ps2_clk_low <= 1'b0; ps2_data_low <= 1'b0;
        end else begin
            // ---- receiving
            if (!tx) begin
                if (kfall) begin
                    rt <= 18'd0;
                    if (rn == 4'd0) begin
                        if (!ds[1]) rn <= 4'd1;            // a start bit
                        else irqf[2] <= 1'b1;               // FRAME: no start bit
                    end else begin
                        rsh <= {ds[1], rsh[9:1]};
                        if (rn == 4'd10) begin
                            rn <= 4'd0;
                            // rsh holds data and parity; ds[1] is the stop bit
                            if (!ds[1])                      irqf[2] <= 1'b1;   // FRAME: bad stop bit
                            else if ((^rsh[9:1]) != 1'b1)    irqf[1] <= 1'b1;   // PARITY: data + parity must be odd
                            else begin
                                f_push  <= en;
                                f_byte  <= rsh[8:1];
                                rx_stb  <= 1'b1;
                                rx_byte <= rsh[8:1];
                            end
                        end else
                            rn <= rn + 1'b1;
                    end
                end else if (rn != 4'd0) begin
                    if (rt == 18'd200000) rn <= 4'd0;       // 2 ms without a bit: start again
                    else rt <= rt + 1'b1;
                end
            end
            // ---- sending
            if (send_w) begin
                tx <= 1'b1; tx_ack <= 1'b0;
                tsh <= {~^rb_wdata, rb_wdata};              // odd parity
                tn  <= 4'd0;
                tt  <= 21'd0;
                rn  <= 4'd0;
                ps2_clk_low  <= 1'b1;                       // hold the clock low ...
                ps2_data_low <= 1'b0;
            end else if (tx) begin
                tt <= tt + 1'b1;
                if (ps2_clk_low) begin
                    if (tt == 21'd10000) begin              // ... 100 us; then data low, clock free
                        ps2_data_low <= 1'b1;
                        ps2_clk_low  <= 1'b0;
                    end
                end else if (kfall) begin
                    if (tx_ack) begin
                        tx <= 1'b0;                         // the keyboard took it (data low on this clock)
                    end else if (tn < 4'd9) begin
                        ps2_data_low <= !tsh[0];            // data bits, then parity
                        tsh <= {1'b0, tsh[8:1]};
                        tn  <= tn + 1'b1;
                    end else begin
                        ps2_data_low <= 1'b0;               // the stop bit: let data go
                        tx_ack <= 1'b1;
                    end
                end
                if (tt == 21'd1500000) begin                // 15 ms: give up
                    tx <= 1'b0;
                    ps2_clk_low  <= 1'b0;
                    ps2_data_low <= 1'b0;
                    irqf[4] <= 1'b1;
                end
            end
            // ---- the FIFO
            if (f_push && fcount == 5'd16) irqf[3] <= 1'b1;  // OVERFLOW: the byte is dropped
            if (f_push && fcount != 5'd16) begin
                fifo[ft] <= f_byte;
                ft <= ft + 1'b1;
            end
            if (f_pop) fh <= fh + 1'b1;
            fcount <= fcount + ((f_push && fcount != 5'd16) ? 5'd1 : 5'd0) - (f_pop ? 5'd1 : 5'd0);
            // ---- registers
            if (rb_wr) case (rb_addr)
                `RM_KBCON:   en <= rb_wdata[`RM_KBCON_EN];
                `RM_KBIRQ:   irqf <= irqf & ~rb_wdata[4:0];
                `RM_KBIRQEN: irqen <= rb_wdata[4:0];
                default: ;
            endcase
            if (!en) begin                                  // off: the FIFO empty, no sending
                fh <= 4'd0; ft <= 4'd0; fcount <= 5'd0;
                tx <= 1'b0; ps2_clk_low <= 1'b0; ps2_data_low <= 1'b0;
            end
            if (!rx_on) rn <= 4'd0;
        end

        rb_rdata <= 8'd0;
        rb_hit   <= rb_rd && sel;
        if (rb_rd) case (rb_addr)
            `RM_KBCON:   rb_rdata <= {7'd0, en};
            `RM_KBSTAT:  rb_rdata <= {tx, 2'd0, fcount};
            `RM_KBDATA:  rb_rdata <= (fcount != 5'd0) ? fifo[fh] : 8'h00;
            `RM_KBIRQ:   rb_rdata <= {3'd0, irqf[4:1], fcount != 5'd0};
            `RM_KBIRQEN: rb_rdata <= {3'd0, irqen};
            default: ;                                      // KBSEND reads 0x00
        endcase
    end
endmodule
