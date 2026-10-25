// The computer with its USB link on a TCP socket (ticket #29), built
// with Verilator. The whole machine (fpga/rtl/retroz80.v, a 2 MB build as the
// KS2) runs the boot ROM, and the PC's side of the FT232H is a byte stream
// that link_main.cpp carries to and from a socket on 127.0.0.1, so a PC
// program (the debug bridge, rlink.py) talks to the simulated machine as to
// the board (sim/README.md, "The link on a socket").
//
// The SRAM and its pads are tb_mon.v's cycle model of them, and so is the
// FT232H: RXF# low while bytes from the PC wait (and high for 6 clocks
// after each read), TXE# low but for 5 clocks after each write, the byte on
// D taken as WR# falls. The video unit's pixel clock is held; the keyboards
// are idle.
//
// The C++ side gives the next byte from the PC on pc_byte with pc_valid,
// and takes it when pc_take pulses; each byte the machine sends comes out
// on fpga_byte with fpga_strobe for one clock.
`timescale 1ns / 1ps

module tb_link (
    input            clk,
    input      [7:0] pc_byte,
    input            pc_valid,
    output reg       pc_take,
    output reg [7:0] fpga_byte,
    output reg       fpga_strobe
);
    localparam [5:0] CHIPMB = 6'd2;

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

    retroz80 #(.ROM_INIT("mon_rom.hex"), .CHIPMB(CHIPMB)) dut (
        .clk(clk), .por(por),
        .btn_reset_n(1'b1), .buttons(2'b00),
        .sram_a(a), .sram_ce_n(ce_n), .sram_ub_n(ub_n), .sram_lb_n(lb_n),
        .sram_oe_n_r(oe_r), .sram_oe_n_f(oe_f), .sram_we_n_r(we_r), .sram_we_n_f(we_f),
        .sram_dq_o(dq_o), .sram_dq_t_r(t_r), .sram_dq_t_f(t_f), .sram_dq_i(dq_i),
        .ft_rxf_n(ft_rxf_n), .ft_txe_n(ft_txe_n), .ft_d_i(pc_byte), .ft_d_o(ft_d_o),
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

    // ---------------------------------------------------------------- the FT232H's FIFO side
    integer rx_hold = 0, tx_hold = 0;
    reg     rd_q = 1'b1, wr_q = 1'b1;
    initial begin pc_take = 1'b0; fpga_strobe = 1'b0; fpga_byte = 8'h00; end
    always @(posedge clk) begin
        // PC -> computer
        rd_q <= ft_rd_n;
        pc_take <= 1'b0;
        if (rx_hold > 0) rx_hold <= rx_hold - 1;
        if (!rd_q && ft_rd_n && !por) begin     // a read ended: the byte is taken
            pc_take <= 1'b1;
            rx_hold <= 6;
        end
        ft_rxf_n <= !(pc_valid && rx_hold == 0 && !(!rd_q && ft_rd_n));
        // Computer -> PC
        wr_q <= ft_wr_n;
        fpga_strobe <= 1'b0;
        if (tx_hold > 0) tx_hold <= tx_hold - 1;
        ft_txe_n <= (tx_hold > 0);
        if (wr_q && !ft_wr_n && !por) begin
            fpga_byte <= ft_d_o;
            fpga_strobe <= 1'b1;
            tx_hold <= 5;
        end
    end
endmodule
