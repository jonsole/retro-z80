// SRAM tester (issue #90): the PC link, over the FT232H in asynchronous 245
// FIFO mode, with the 245 timing of serial.v (spec 10).
//
// Commands (bytes from the PC; numbers little-endian):
//   'W' i lo hi   set setting i (0-31) to hi:lo        reply 'w'
//   'R'           run: the passes set up               reply 'r' when done
//   'D' lo hi n   read n result bytes from hi:lo       reply the n bytes
//                 (n = 0 reads 256)
// Other bytes are ignored. A command left unfinished for 10 ms is dropped,
// so the PC can get back in step by waiting. While a run goes on, no bytes
// are read; they wait in the FT232H. After each reply SIWU# is pulsed, so the
// FT232H sends it at once.
module sramt_link (
    input  wire        clk,         // 100 MHz
    input  wire        rst,

    input  wire        ft_rxf_n,
    input  wire        ft_txe_n,
    input  wire [7:0]  ft_d_i,
    output reg  [7:0]  ft_d_o,
    output reg         ft_d_oe,
    output reg         ft_rd_n,
    output reg         ft_wr_n,
    output reg         ft_siwu_n,

    output reg         set_we,
    output reg  [4:0]  set_idx,
    output reg  [15:0] set_val,
    output reg         run,
    input  wire        busy,
    output reg  [8:0]  rd_addr,
    input  wire [7:0]  rd_data
);
    // ---------------------------------------------------------------- FT232H
    reg [1:0] rxf_s = 2'b11, txe_s = 2'b11;
    always @(posedge clk) begin
        rxf_s <= {rxf_s[0], ft_rxf_n};
        txe_s <= {txe_s[0], ft_txe_n};
    end
    wire rxf = !rxf_s[1];
    wire txe = !txe_s[1];

    // Read : RD# low 8 clocks (80 ns), data taken at the end, then 8 clocks high.
    // Write: data out; WR# high 3 clocks, low 5 clocks, then data released and
    //        8 clocks of recovery.
    localparam F_IDLE = 2'd0, F_READ = 2'd1, F_WRITE = 2'd2, F_REC = 2'd3;
    reg  [1:0] fs;
    reg  [3:0] ft_t;
    reg        want_rx;         // the parser takes a byte
    reg        tx_req;          // the parser has a byte in tx_byte
    reg  [7:0] tx_byte;
    reg        rx_valid;        // 1 clock: rx_byte is new
    reg  [7:0] rx_byte;
    reg        tx_done;         // 1 clock: tx_byte went out
    reg        siwu_req;
    reg  [1:0] siwu_t;

    always @(posedge clk) begin
        rx_valid <= 1'b0;
        tx_done  <= 1'b0;
        if (rst) begin
            fs <= F_IDLE; ft_t <= 4'd0;
            ft_rd_n <= 1'b1; ft_wr_n <= 1'b1; ft_d_oe <= 1'b0; ft_siwu_n <= 1'b1;
            ft_d_o <= 8'd0; rx_byte <= 8'd0; siwu_t <= 2'd0;
        end else begin
            if (siwu_t != 2'd0) begin
                siwu_t <= siwu_t - 2'd1;
                if (siwu_t == 2'd1) ft_siwu_n <= 1'b1;
            end else if (siwu_req && fs == F_IDLE && !tx_req) begin
                ft_siwu_n <= 1'b0;
                siwu_t    <= 2'd3;
            end
            case (fs)
                F_IDLE: begin
                    ft_t <= 4'd0;
                    if (want_rx && !rx_valid && rxf) begin
                        ft_rd_n <= 1'b0;
                        fs      <= F_READ;
                    end else if (tx_req && !tx_done && txe && siwu_t == 2'd0) begin
                        ft_d_o  <= tx_byte;
                        ft_d_oe <= 1'b1;
                        fs      <= F_WRITE;
                    end
                end
                F_READ: begin
                    ft_t <= ft_t + 4'd1;
                    if (ft_t == 4'd7) begin
                        rx_byte  <= ft_d_i;
                        rx_valid <= 1'b1;
                        ft_rd_n  <= 1'b1;
                        ft_t     <= 4'd0;
                        fs       <= F_REC;
                    end
                end
                F_WRITE: begin
                    ft_t <= ft_t + 4'd1;
                    if (ft_t == 4'd2) ft_wr_n <= 1'b0;
                    if (ft_t == 4'd7) begin
                        ft_wr_n <= 1'b1;
                        ft_d_oe <= 1'b0;
                        tx_done <= 1'b1;
                        ft_t    <= 4'd0;
                        fs      <= F_REC;
                    end
                end
                default: begin
                    ft_t <= ft_t + 4'd1;
                    if (ft_t == 4'd7) fs <= F_IDLE;
                end
            endcase
        end
    end

    // ---------------------------------------------------------------- commands
    localparam P_CMD = 3'd0, P_ARG = 3'd1, P_RUN = 3'd2, P_SEND = 3'd3, P_DUMP = 3'd4, P_FETCH = 3'd5;
    reg  [2:0]  ps;
    reg  [7:0]  cmd;
    reg  [1:0]  nargs;          // argument bytes still to come
    reg  [7:0]  a0, a1;
    reg  [8:0]  left;           // dump bytes still to send
    reg  [19:0] tmo;
    reg  [1:0]  wait_c;

    always @(posedge clk) begin
        set_we   <= 1'b0;
        run      <= 1'b0;
        siwu_req <= siwu_req && siwu_t == 2'd0 && ft_siwu_n;
        if (rst) begin
            ps <= P_CMD; want_rx <= 1'b0; tx_req <= 1'b0; tx_byte <= 8'd0;
            cmd <= 8'd0; nargs <= 2'd0; a0 <= 8'd0; a1 <= 8'd0; left <= 9'd0;
            tmo <= 20'd0; wait_c <= 2'd0; siwu_req <= 1'b0;
            set_idx <= 5'd0; set_val <= 16'd0; rd_addr <= 9'd0;
        end else case (ps)
            P_CMD: begin
                want_rx <= 1'b1;
                tmo     <= 20'd0;
                if (rx_valid) begin
                    cmd <= rx_byte;
                    if (rx_byte == "W" || rx_byte == "D") begin
                        nargs <= 2'd3;
                        ps    <= P_ARG;
                    end else if (rx_byte == "R") begin
                        want_rx <= 1'b0;
                        run     <= 1'b1;
                        wait_c  <= 2'd3;
                        ps      <= P_RUN;
                    end
                end
            end
            P_ARG: begin
                tmo <= tmo + 20'd1;
                if (rx_valid) begin
                    tmo   <= 20'd0;
                    nargs <= nargs - 2'd1;
                    if (nargs == 2'd3) a0 <= rx_byte;
                    if (nargs == 2'd2) a1 <= rx_byte;
                    if (nargs == 2'd1) begin
                        want_rx <= 1'b0;
                        if (cmd == "W") begin
                            set_we  <= 1'b1;
                            set_idx <= a0[4:0];
                            set_val <= {rx_byte, a1};
                            tx_byte <= "w";
                            tx_req  <= 1'b1;
                            ps      <= P_SEND;
                        end else begin
                            rd_addr <= {a1[0], a0};
                            left    <= (rx_byte == 8'd0) ? 9'd256 : {1'b0, rx_byte};
                            wait_c  <= 2'd2;
                            ps      <= P_FETCH;
                        end
                    end
                end else if (&tmo)
                    ps <= P_CMD;
            end
            P_RUN: begin
                if (wait_c != 2'd0) wait_c <= wait_c - 2'd1;
                else if (!busy) begin
                    tx_byte <= "r";
                    tx_req  <= 1'b1;
                    ps      <= P_SEND;
                end
            end
            P_SEND: if (tx_done) begin
                tx_req   <= 1'b0;
                siwu_req <= 1'b1;
                ps       <= P_CMD;
            end
            P_FETCH: begin              // rd_data follows rd_addr a clock later
                if (wait_c != 2'd0) wait_c <= wait_c - 2'd1;
                else begin
                    tx_byte <= rd_data;
                    tx_req  <= 1'b1;
                    ps      <= P_DUMP;
                end
            end
            P_DUMP: if (tx_done) begin
                tx_req  <= 1'b0;
                left    <= left - 9'd1;
                rd_addr <= rd_addr + 9'd1;
                if (left == 9'd1) begin
                    siwu_req <= 1'b1;
                    ps       <= P_CMD;
                end else begin
                    wait_c <= 2'd2;
                    ps     <= P_FETCH;
                end
            end
            default: ps <= P_CMD;
        endcase
    end
endmodule
