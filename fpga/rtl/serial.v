// USB serial through an FT232H in asynchronous 245 FIFO mode (spec 10).
// retro68k's serial.v with its registers narrowed to bytes: registers
// 0x50-0x57 and 0x5C of page 0x00, SERDATA also the low-byte-only port 0x53
// (the bus interface gives it the same bus address). The FT232H interface
// and the FIFOs are retro68k's, unchanged; the control commands and the
// escapes on the PC's bytes are retro-z80's (section 4).
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
    output reg         cmd_break,      // 1 clock each: control commands from the PC
    output reg         cmd_reset,
    output reg         cmd_upload,
    output reg         cmd_key,        // 1 clock: KEY, a PS/2 byte from the PC ...
    output reg  [7:0]  key_byte,       // ... this one

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
    output reg  [7:0]  ft_d_o,
    output reg         ft_d_oe,
    output reg         ft_rd_n,
    output reg         ft_wr_n,
    output reg         ft_siwu_n
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

    // ---------------------------------------------------------------- FIFOs
    reg         rx_push;  reg [7:0] rx_wdata;
    wire        rx_cpu = rb_rd && rb_addr == `RM_SERDATA;
    wire        rx_pop = rx_cpu || p_rxpop;
    wire [7:0]  rx_rdata;
    wire [12:0] rx_count;
    wire        rx_full, rx_valid;
    fifo8 #(.AW(11)) rx_fifo (.clk(clk), .rst(rst || rx_flush), .push(rx_push), .wdata(rx_wdata),
                          .pop(rx_pop), .rdata(rx_rdata), .count(rx_count), .full(rx_full),
                          .valid(rx_valid));

    wire        tx_cpu  = rb_wr && rb_addr == `RM_SERDATA;
    wire        tx_wr   = tx_cpu || p_txpush;
    reg         tx_pop_ft;
    wire [7:0]  tx_rdata;
    wire [12:0] tx_count;
    wire        tx_full, tx_valid;
    wire        tx_drop = tx_wr && tx_full && sercon[3];
    fifo8 #(.AW(11)) tx_fifo (.clk(clk), .rst(rst || tx_flush), .push(tx_wr && en),
                          .wdata(tx_cpu ? rb_wdata : p_txd),
                          .pop(tx_pop_ft || tx_drop), .rdata(tx_rdata), .count(tx_count), .full(tx_full),
                          .valid(tx_valid));

    assign p_rxv = rx_valid && !rx_cpu;
    assign p_rxd = rx_rdata;
    assign p_txr = en && !tx_full && !tx_cpu;
    wire [11:0] rxcount = (rx_count > 13'd2048) ? 12'd2048 : rx_count[11:0];
    wire [11:0] txspace = (tx_count >= 13'd2048) ? 12'd0 : 12'd2048 - tx_count[11:0];
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
            if (rx_push || rx_pop || rxcount == 0 || s_rxready) idle16 <= 8'd0;
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

    // ---------------------------------------------------------------- control commands and escapes
    // With recognition on (CTLEN or CTLLOCK) the PC's bytes are SLIP-style
    // (section 4): C0 c ~c is a control command, DB DC a data C0, DB DD a data
    // DB. Every other byte goes on at once, so no data byte waits for the next
    // one. A broken command is dropped; a C0 always starts a command again.
    // KEY is C0 04 b ~b, with b and ~b escaped like data.
    localparam [7:0] B_END = 8'hC0, B_ESC = 8'hDB, B_ESC_END = 8'hDC, B_ESC_ESC = 8'hDD;
    localparam [7:0] C_KEY = 8'd4;
    localparam [2:0] D_DATA = 3'd0, D_ESC = 3'd1, D_CMD = 3'd2, D_INV = 3'd3,
                     D_KB = 3'd4, D_KBESC = 3'd5, D_KBINV = 3'd6, D_KBINVESC = 3'd7;

    wire        match_on = sercon[1] || sercon[2];
    reg  [2:0]  ds;
    reg  [7:0]  mc;            // the command byte
    reg  [7:0]  kb;            // KEY's b

    reg         in_valid;      // a byte from the FT232H
    reg  [7:0]  in_byte;

    always @(posedge clk) begin
        rx_push    <= 1'b0;
        cmd_break  <= 1'b0;
        cmd_reset  <= 1'b0;
        cmd_upload <= 1'b0;
        cmd_key    <= 1'b0;
        if (por) begin
            ds <= D_DATA;
        end else if (in_valid) begin
            if (!match_on) begin
                rx_push <= 1'b1; rx_wdata <= in_byte;
                ds <= D_DATA;
            end else if (in_byte == B_END) begin
                ds <= D_CMD;
            end else case (ds)
                D_DATA: if (in_byte == B_ESC) ds <= D_ESC;
                        else begin rx_push <= 1'b1; rx_wdata <= in_byte; end
                D_ESC: begin
                    rx_push  <= 1'b1;
                    rx_wdata <= (in_byte == B_ESC_END) ? B_END : (in_byte == B_ESC_ESC) ? B_ESC : in_byte;
                    ds       <= D_DATA;
                end
                D_CMD: begin
                    mc <= in_byte;
                    ds <= (in_byte == C_KEY) ? D_KB : D_INV;
                end
                D_INV: begin
                    ds <= D_DATA;
                    if (in_byte == ~mc && mc >= 8'd1 && mc <= 8'd3) begin
                        cmd_break  <= (mc == 8'd1) && sercon[1];
                        cmd_reset  <= (mc == 8'd2);
                        cmd_upload <= (mc == 8'd3);
                    end
                end
                D_KB: if (in_byte == B_ESC) ds <= D_KBESC;
                      else begin kb <= in_byte; ds <= D_KBINV; end
                D_KBESC: begin
                    kb <= (in_byte == B_ESC_END) ? B_END : (in_byte == B_ESC_ESC) ? B_ESC : in_byte;
                    ds <= D_KBINV;
                end
                D_KBINV: if (in_byte == B_ESC) ds <= D_KBINVESC;
                         else begin
                             ds <= D_DATA;
                             cmd_key  <= (in_byte == ~kb) && sercon[1];
                             key_byte <= kb;
                         end
                default: begin   // D_KBINVESC
                    ds <= D_DATA;
                    cmd_key  <= (((in_byte == B_ESC_END) ? B_END : (in_byte == B_ESC_ESC) ? B_ESC : in_byte) == ~kb)
                                && sercon[1];
                    key_byte <= kb;
                end
            endcase
        end
    end

    // ---------------------------------------------------------------- FT232H
    // RXF# and TXE# are asynchronous: two-flop synchronisers.
    reg [1:0] rxf_s, txe_s;
    always @(posedge clk) begin
        rxf_s <= {rxf_s[0], ft_rxf_n};
        txe_s <= {txe_s[0], ft_txe_n};
    end
    wire rxf = !rxf_s[1];
    wire txe = !txe_s[1];

    // Read : RD# low 8 clocks (80 ns), data taken at the end, then 8 clocks high.
    // Write: data out; WR# high 3 clocks, low 5 clocks (the FT232H takes the
    //        byte as WR# falls), then data released and 8 clocks of recovery.
    localparam F_IDLE = 2'd0, F_READ = 2'd1, F_WRITE = 2'd2, F_REC = 2'd3;
    reg [1:0] fs;
    reg [3:0] ft_t;
    reg       sent;            // bytes went out since the last send-immediate
    reg [1:0] siwu_t;
    wire      rx_room = (rx_count < 13'd2030) && !in_valid;

    always @(posedge clk) begin
        in_valid  <= 1'b0;
        tx_pop_ft <= 1'b0;
        if (por) begin
            fs        <= F_IDLE;
            ft_rd_n   <= 1'b1;
            ft_wr_n   <= 1'b1;
            ft_d_oe   <= 1'b0;
            ft_siwu_n <= 1'b1;
            sent      <= 1'b0;
            siwu_t    <= 2'd0;
        end else begin
            // Send immediate: when the transmit FIFO has emptied
            if (siwu_t != 0) begin
                siwu_t <= siwu_t - 1'b1;
                if (siwu_t == 2'd1) ft_siwu_n <= 1'b1;
            end else if (sent && tx_count == 0 && fs == F_IDLE) begin
                ft_siwu_n <= 1'b0;
                siwu_t    <= 2'd3;
                sent      <= 1'b0;
            end

            case (fs)
                F_IDLE: begin
                    ft_t <= 4'd0;
                    if (en && rxf && rx_room) begin
                        ft_rd_n <= 1'b0;
                        fs      <= F_READ;
                    end else if (en && txe && tx_valid && siwu_t == 0) begin
                        ft_d_o  <= tx_rdata;
                        ft_d_oe <= 1'b1;
                        fs      <= F_WRITE;
                    end
                end
                F_READ: begin
                    ft_t <= ft_t + 1'b1;
                    if (ft_t == 4'd7) begin
                        in_byte  <= ft_d_i;
                        in_valid <= 1'b1;
                        ft_rd_n  <= 1'b1;
                        ft_t     <= 4'd0;
                        fs       <= F_REC;
                    end
                end
                F_WRITE: begin
                    ft_t <= ft_t + 1'b1;
                    if (ft_t == 4'd2) ft_wr_n <= 1'b0;
                    if (ft_t == 4'd7) begin
                        ft_wr_n   <= 1'b1;
                        ft_d_oe   <= 1'b0;
                        tx_pop_ft <= 1'b1;
                        sent      <= 1'b1;
                        ft_t      <= 4'd0;
                        fs        <= F_REC;
                    end
                end
                F_REC: begin
                    ft_t <= ft_t + 1'b1;
                    if (ft_t == 4'd7) fs <= F_IDLE;
                end
            endcase
        end
    end
endmodule
