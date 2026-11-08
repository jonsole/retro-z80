// USB serial through an FT232H in asynchronous 245 FIFO mode (spec 10).
// retro68k's serial.v with its registers narrowed to bytes: registers
// 0x50-0x57 and 0x5C of page 0x00, SERDATA also the low-byte-only port 0x53
// (the bus interface gives it the same bus address). This file is the
// register side; the FIFOs, the control commands and escapes (section 4)
// and the FT232H interface are retro-hw's cores serial_link.v and
// ft232h_if.v.
`include "regmap.vh"

module serial (
    input  wire        clk,            // 100 MHz
    input  wire        rst,            // device reset: registers and FIFOs
    input  wire        por,            // power-on reset: the FT232H interface and the
                                       // command decoder, so the link survives other resets
    input  wire        us_tick,        // 1 clock every microsecond

    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [12:0] rb_addr,
    input  wire [7:0]  rb_wdata,
    output reg  [7:0]  rb_rdata,
    output reg         rb_hit,         // with rb_rdata: this unit answered

    output wire        irq,
    output wire        cmd_break,      // 1 clock each: control commands from the PC
    output wire        cmd_reset,
    output wire        cmd_upload,
    output wire        cmd_key,        // 1 clock: KEY, a PS/2 byte from the PC ...
    output wire [7:0]  key_byte,       // ... this one

    // DMA engine port 1 (spec 14): the CPU's own accesses go first
    output wire        p_rxv,
    output wire [7:0]  p_rxd,
    input  wire        p_rxpop,
    output wire        p_txr,
    input  wire        p_txpush,
    input  wire [7:0]  p_txd,

    // FT232H pins
    input  wire        ft_rxf_n,
    input  wire        ft_txe_n,
    input  wire [7:0]  ft_d_i,
    output wire [7:0]  ft_d_o,
    output wire        ft_d_oe,
    output wire        ft_rd_n,
    output wire        ft_wr_n,
    output wire        ft_siwu_n
);
    // ---------------------------------------------------------------- registers
    wire sel = (rb_addr >= `RM_SERCON && rb_addr <= `RM_SERIRQEN) || rb_addr == `RM_SERDROP;

    reg  [3:0]  sercon;                // TXDROP, CTLLOCK, CTLEN, EN
    reg  [3:0]  rxcode, txcode;        // SERLEVEL: 0 = off, n = 2^(n-1) bytes
    reg  [7:0]  sertime;               // in steps of 16 us
    reg  [3:0]  irqen;
    reg         f_rxtimeout, f_txovf;
    reg  [7:0]  dropcount;
    reg         rx_flush, tx_flush;    // SERCON.RXFLUSH, TXFLUSH written

    wire en = sercon[0];

    // ---------------------------------------------------------------- the link (retro-hw)
    // The FIFOs and the command decoder are retro-hw's serial_link.v, the
    // FT232H interface its ft232h_if.v. The decoder and the FT232H interface
    // are reset only by power-on (por), so the link survives other resets;
    // the FIFOs are emptied by a device reset and by RXFLUSH and TXFLUSH.
    wire        rx_cpu = rb_rd && rb_addr == `RM_SERDATA;
    wire        rx_pop = rx_cpu || p_rxpop;
    wire        rx_new;
    wire [7:0]  rx_rdata;
    wire        rx_valid;
    wire [11:0] rxcount, txspace;

    wire        tx_cpu  = rb_wr && rb_addr == `RM_SERDATA;
    wire        tx_wr   = tx_cpu || p_txpush;
    wire        tx_full, tx_drop;

    wire        fe_rx_valid, fe_rx_room, fe_tx_valid, fe_tx_pop, fe_tx_empty;
    wire [7:0]  fe_rx_byte, fe_tx_byte;

    serial_link #(.AW(11), .RX_MARGIN(18), .KEY_CMD(1)) link (
        .clk(clk), .rst(por), .rx_clear(rst || rx_flush), .tx_clear(rst || tx_flush),
        .ctl_en(sercon[1]), .ctl_lock(sercon[2]), .tx_en(en), .drop_oldest(sercon[3]),
        .fe_rx_valid(fe_rx_valid), .fe_rx_byte(fe_rx_byte), .fe_rx_room(fe_rx_room),
        .fe_tx_valid(fe_tx_valid), .fe_tx_byte(fe_tx_byte), .fe_tx_pop(fe_tx_pop),
        .fe_tx_empty(fe_tx_empty),
        .rx_valid(rx_valid), .rx_byte(rx_rdata), .rx_pop(rx_pop), .rx_new(rx_new),
        .rx_count(rxcount),
        .tx_push(tx_wr), .tx_byte(tx_cpu ? rb_wdata : p_txd), .tx_full(tx_full),
        .tx_dropped(tx_drop), .tx_space(txspace),
        .cmd_break(cmd_break), .cmd_reset(cmd_reset), .cmd_upload(cmd_upload),
        .cmd_key(cmd_key), .key_byte(key_byte)
    );

    ft232h_if ft (
        .clk(clk), .rst(por), .en(en),
        .rx_valid(fe_rx_valid), .rx_byte(fe_rx_byte), .rx_room(fe_rx_room),
        .tx_valid(fe_tx_valid), .tx_byte(fe_tx_byte), .tx_pop(fe_tx_pop), .tx_empty(fe_tx_empty),
        .ft_rxf_n(ft_rxf_n), .ft_txe_n(ft_txe_n), .ft_d_i(ft_d_i), .ft_d_o(ft_d_o),
        .ft_d_oe(ft_d_oe), .ft_rd_n(ft_rd_n), .ft_wr_n(ft_wr_n), .ft_siwu_n(ft_siwu_n)
    );

    assign p_rxv = rx_valid && !rx_cpu;
    assign p_rxd = rx_rdata;
    assign p_txr = en && !tx_full && !tx_cpu;
    // SERSTAT0 and SERSTAT1: the counts, saturating at 255
    wire [7:0]  txspace8 = (txspace > 12'd255) ? 8'd255 : txspace[7:0];
    wire [7:0]  rxcount8 = (rxcount > 12'd255) ? 8'd255 : rxcount[7:0];

    // ---------------------------------------------------------------- interrupts
    // A level code n = 1-12 means 2^(n-1) bytes; 13-15 act as 12; 0 = off
    function [11:0] level(input [3:0] code);
        level = (code == 4'd0) ? 12'd0 : (code >= 4'd12) ? 12'd2048 : 12'd1 << (code - 4'd1);
    endfunction
    wire [11:0] rxlevel = level(rxcode);
    wire [11:0] txlevel = level(txcode);
    wire s_rxready = (rxlevel != 0) && (rxcount >= rxlevel);
    wire s_txready = (txlevel != 0) && (txspace >= txlevel);
    wire [3:0] irqflags = {f_txovf, s_txready, f_rxtimeout, s_rxready};
    assign irq = |(irqflags & irqen);

    // Receive timeout: bytes waiting below RXLEVEL with nothing new for SERTIME
    // steps of 16 us, counted on a free-running 16 us tick (so a timeout of n
    // comes between 16(n - 1) and 16n us)
    reg [3:0] us16;
    wire      tick16 = us_tick && us16 == 4'd15;
    reg [7:0] idle16;

    always @(posedge clk) begin
        rx_flush <= 1'b0;
        tx_flush <= 1'b0;
        if (rst) begin
            sercon      <= 4'b0010;          // CTLEN on after reset
            rxcode      <= 4'd0;
            txcode      <= 4'd0;
            sertime     <= 8'd0;
            irqen       <= 4'd0;
            f_rxtimeout <= 1'b0;
            f_txovf     <= 1'b0;
            dropcount   <= 8'd0;
            us16        <= 4'd0;
            idle16      <= 8'd0;
        end else begin
            if (tx_wr && tx_full && !sercon[3]) f_txovf <= 1'b1;
            if (tx_drop && dropcount != 8'hFF) dropcount <= dropcount + 1'b1;

            if (us_tick) us16 <= us16 + 1'b1;
            if (rx_new || rx_pop || rxcount == 0 || s_rxready) idle16 <= 8'd0;
            else if (tick16) begin
                if (idle16 != 8'hFF) idle16 <= idle16 + 1'b1;
                if (sertime != 0 && idle16 == sertime - 1'b1) f_rxtimeout <= 1'b1;
            end

            if (rb_wr) case (rb_addr)
                `RM_SERCON: begin
                    sercon   <= {rb_wdata[3], sercon[2] | rb_wdata[2], rb_wdata[1:0]};   // CTLLOCK stays set until reset
                    rx_flush <= rb_wdata[`RM_SERCON_RXFLUSH];
                    tx_flush <= rb_wdata[`RM_SERCON_TXFLUSH];
                end
                `RM_SERLEVEL: begin
                    rxcode <= rb_wdata[`RM_SERLEVEL_RXLEVEL];
                    txcode <= rb_wdata[`RM_SERLEVEL_TXLEVEL];
                end
                `RM_SERTIME:  sertime <= rb_wdata;
                `RM_SERIRQ: begin
                    if (rb_wdata[`RM_SERIRQ_RXTIMEOUT]) f_rxtimeout <= 1'b0;
                    if (rb_wdata[`RM_SERIRQ_TXOVF])     f_txovf     <= 1'b0;
                end
                `RM_SERIRQEN: irqen <= rb_wdata[3:0];
                default: ;
            endcase
            if (rb_rd && rb_addr == `RM_SERDROP) dropcount <= 8'd0;
        end

        rb_rdata <= 8'd0;
        rb_hit   <= rb_rd && sel;
        if (rb_rd) case (rb_addr)
            `RM_SERCON:   rb_rdata <= {4'd0, sercon};
            `RM_SERSTAT0: rb_rdata <= txspace8;
            `RM_SERSTAT1: rb_rdata <= rxcount8;
            `RM_SERDATA:  rb_rdata <= rx_valid ? rx_rdata : 8'h00;
            `RM_SERLEVEL: rb_rdata <= {rxcode, txcode};
            `RM_SERTIME:  rb_rdata <= sertime;
            `RM_SERIRQ:   rb_rdata <= {4'd0, irqflags};
            `RM_SERIRQEN: rb_rdata <= {4'd0, irqen};
            `RM_SERDROP:  rb_rdata <= dropcount;
            default: ;
        endcase
    end
endmodule
