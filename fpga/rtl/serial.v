// USB serial through an FT232H in asynchronous 245 FIFO mode (spec 10).
// retro68k's serial.v with its registers narrowed to bytes: registers
// 0x50-0x57 and 0x5C of page 0x00, SERDATA also the low-byte-only port 0x53
// (the bus interface gives it the same bus address). The FT232H interface,
// the FIFOs and the control-command matcher are retro68k's, unchanged.
`include "regmap.vh"

module serial (
    input  wire        clk,            // 100 MHz
    input  wire        rst,            // device reset: registers and FIFOs
    input  wire        por,            // power-on reset: the FT232H interface and the
                                       // command matcher, so the link survives other resets
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

    // ---------------------------------------------------------------- control commands
    // 00 FF "R68K-CTL" FF 00 A5 5A c ~c (section 3). Matching bytes are held
    // back; on a mismatch they are passed on (they are known constants).
    function [7:0] pattern(input [3:0] i);
        case (i)
            4'd0: pattern = 8'h00;  4'd1: pattern = 8'hFF;  4'd2: pattern = 8'h52;  4'd3: pattern = 8'h36;
            4'd4: pattern = 8'h38;  4'd5: pattern = 8'h4B;  4'd6: pattern = 8'h2D;  4'd7: pattern = 8'h43;
            4'd8: pattern = 8'h54;  4'd9: pattern = 8'h4C;  4'd10: pattern = 8'hFF; 4'd11: pattern = 8'h00;
            4'd12: pattern = 8'hA5; 4'd13: pattern = 8'h5A; default: pattern = 8'h00;
        endcase
    endfunction

    wire        match_on = sercon[1] || sercon[2];
    reg  [3:0]  mk;            // bytes matched so far (0-15)
    reg  [7:0]  mc;            // the command byte, once matched
    reg  [4:0]  flush_n;       // held bytes still to pass on
    reg  [4:0]  flush_i;
    reg         flush_cur;     // then the byte that broke the match
    reg  [7:0]  cur;
    wire        busy = (flush_n != 0) || flush_cur;

    reg         in_valid;      // a byte from the FT232H
    reg  [7:0]  in_byte;

    always @(posedge clk) begin
        rx_push    <= 1'b0;
        cmd_break  <= 1'b0;
        cmd_reset  <= 1'b0;
        cmd_upload <= 1'b0;
        if (por) begin
            mk <= 0; flush_n <= 0; flush_i <= 0; flush_cur <= 1'b0;
        end else if (flush_n != 0) begin
            rx_push  <= 1'b1;
            rx_wdata <= (flush_i == 5'd14) ? mc : pattern(flush_i[3:0]);
            flush_i  <= flush_i + 1'b1;
            flush_n  <= flush_n - 1'b1;
        end else if (flush_cur) begin
            flush_cur <= 1'b0;
            if (cur == pattern(0)) mk <= 4'd1;
            else begin rx_push <= 1'b1; rx_wdata <= cur; end
        end else if (in_valid) begin
            if (!match_on) begin
                rx_push <= 1'b1; rx_wdata <= in_byte;
            end else if (mk < 4'd14 && in_byte == pattern(mk)) begin
                mk <= mk + 1'b1;
            end else if (mk == 4'd14) begin
                mk <= 4'd15;
                mc <= in_byte;
            end else if (mk == 4'd15 && in_byte == ~mc && mc >= 8'd1 && mc <= 8'd3) begin
                mk <= 4'd0;
                cmd_break  <= (mc == 8'd1) && sercon[1];
                cmd_reset  <= (mc == 8'd2);
                cmd_upload <= (mc == 8'd3);
            end else begin
                // Mismatch: pass on the held bytes, then look at this one again
                flush_n   <= {1'b0, mk};
                flush_i   <= 5'd0;
                flush_cur <= 1'b1;
                cur       <= in_byte;
                mk        <= 4'd0;
            end
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
    wire      rx_room = (rx_count < 13'd2030) && !busy && !in_valid;

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
