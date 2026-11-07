// PS/2 keyboard (spec 12, section 3). retro68k's ps2kb.v narrowed to byte
// registers 0x60-0x65 of the system page on the 8-bit register bus. 100 MHz.
// The engine is retro-hw's ps2_core (the receiver, filter, sender, timeouts
// and the 16-byte FIFO); this wrapper holds the registers, the sticky flags
// and the interrupt.
//
// Receiving: the keyboard clocks 11-bit frames (start 0, 8 data bits
// lowest first, odd parity, stop 1) at 10-17 kHz. Good bytes go into the
// FIFO unchanged; bad ones are dropped and flagged. The receiver runs while
// KBCON.EN or KEYCON.PS2MAP (map_en) is 1; every good byte is also handed
// to the Spectrum key mapper (rx_stb, rx_byte), whether or not it fits in
// the FIFO (spec 12, section 8.3). Bytes from the link's KEY command
// (inj_stb, inj_byte; spec 10, section 4) are taken the same way, while the
// receiver runs; KEYs come at least 4 link bytes apart, so one held a clock
// behind a real byte is never overtaken.
//
// Sending (KBSEND, with KBCON.EN set): the core sends the byte; 15 ms
// without the keyboard's answer: TIMEOUT. Nothing is received while sending.
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
    output wire        ps2_clk_low,    // pull the clock line low
    output wire        ps2_data_low,   // pull the data line low

    input  wire        map_en,         // KEYCON.PS2MAP: the receiver runs for the mapper too
    output wire        rx_stb,         // 1 clock: a good byte was received ...
    output wire [7:0]  rx_byte,        // ... this one
    output wire        rx_on,          // the receiver is running

    input  wire        inj_stb,        // 1 clock: KEY from the link (spec 10), taken as if received ...
    input  wire [7:0]  inj_byte,       // ... this byte

    output wire        irq             // KEYB (spec 8, source 17)
);
    wire        sel = (rb_addr >= `RM_KBCON) && (rb_addr <= `RM_KBIRQEN);

    reg         en;
    reg  [4:0]  irqf;                  // TIMEOUT 4, OVERFLOW 3, FRAME 2, PARITY 1 (DATA, bit 0, is live)
    reg  [4:0]  irqen;
    assign      rx_on = en || map_en;

    wire        frame_err, parity_err, overflow, timeout, tx_busy;
    wire [7:0]  fifo_byte;
    wire [4:0]  fcount;

    ps2_core core (
        .clk(clk), .rst(rst),
        .en(en), .rx_en(rx_on),
        .ps2_clk_i(ps2_clk_i), .ps2_data_i(ps2_data_i),
        .ps2_clk_low(ps2_clk_low), .ps2_data_low(ps2_data_low),
        .rx_stb(rx_stb), .rx_byte(rx_byte),
        .rx_frame_err(frame_err), .rx_parity_err(parity_err),
        .ins_stb(inj_stb), .ins_byte(inj_byte),
        .fifo_byte(fifo_byte), .fifo_count(fcount),
        .fifo_pop(rb_rd && rb_addr == `RM_KBDATA),
        .fifo_overflow(overflow),
        .tx_req(rb_wr && rb_addr == `RM_KBSEND), .tx_byte(rb_wdata),
        .tx_busy(tx_busy), .tx_timeout(timeout)
    );

    assign irq = |({irqf[4:1], fcount != 5'd0} & irqen);

    always @(posedge clk) begin
        if (rst) begin
            en <= 1'b0; irqf <= 5'd0; irqen <= 5'd0;
        end else begin
            // the core's error strobes, on the clock the error is found
            if (parity_err) irqf[1] <= 1'b1;
            if (frame_err)  irqf[2] <= 1'b1;
            if (overflow)   irqf[3] <= 1'b1;
            if (timeout)    irqf[4] <= 1'b1;
            if (rb_wr) case (rb_addr)
                `RM_KBCON:   en <= rb_wdata[`RM_KBCON_EN];
                `RM_KBIRQ:   irqf <= irqf & ~rb_wdata[4:0];
                `RM_KBIRQEN: irqen <= rb_wdata[4:0];
                default: ;
            endcase
        end

        rb_rdata <= 8'd0;
        rb_hit   <= rb_rd && sel;
        if (rb_rd) case (rb_addr)
            `RM_KBCON:   rb_rdata <= {7'd0, en};
            `RM_KBSTAT:  rb_rdata <= {tx_busy, 2'd0, fcount};
            `RM_KBDATA:  rb_rdata <= fifo_byte;             // 0x00 when empty
            `RM_KBIRQ:   rb_rdata <= {3'd0, irqf[4:1], fcount != 5'd0};
            `RM_KBIRQEN: rb_rdata <= {3'd0, irqen};
            default: ;                                      // KBSEND reads 0x00
        endcase
    end
endmodule
