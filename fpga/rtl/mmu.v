// MMU (spec 2, section 9): eight 8 KB windows (A15-A13), each with a read
// page and a write page, 10 bits each. retro-z80's own; retro68k has no MMU.
//
// The page registers are registers 0x80-0x9F of the system page (spec 3,
// section 4.10), on the register bus: MMUn_0/MMUn_1 (read page, 0x80 + 2n)
// and MMUnW_0/MMUnW_1 (write page, 0x90 + 2n). They are the one exception
// to direct writes (spec 3, section 3.1):
//   - writing byte 0 only holds it, in a held byte of that register's own;
//   - writing byte 1 commits the page with the held byte 0, which is the
//     page's current bits 7-0 if byte 0 has not been written since;
//   - committing a read page also sets the window's write page (and its
//     held byte), so one register changes a window; committing a write
//     page afterwards splits it.
// Reading gives the committed value; bits 7-2 of byte 1 read 0.
//
// Every reset puts the mapping of section 9.4 back: windows 0-1 boot ROM
// pages 0x3FC-0x3FD, windows 2-7 SRAM pages 0x000-0x005, write = read.
// What each page is (SRAM, ROM, REGS, NONE, reserved) is decoded by the bus
// interface (bus_if.v).
`include "regmap.vh"

module mmu (
    input  wire        clk,
    input  wire        rst,            // any reset

    // Register bus (spec 1, section 4.2)
    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [12:0] rb_addr,
    input  wire [7:0]  rb_wdata,
    output reg  [7:0]  rb_rdata,
    output reg         rb_hit,

    // Lookup, for the bus interface
    input  wire [2:0]  win,
    output wire [9:0]  rpage,
    output wire [9:0]  wpage
);
    reg [9:0] rp [0:7];                // committed read pages
    reg [9:0] wp [0:7];                // committed write pages
    reg [7:0] hr [0:7];                // held byte 0 of MMUn
    reg [7:0] hw [0:7];                // held byte 0 of MMUnW

    assign rpage = rp[win];
    assign wpage = wp[win];

    // Registers 0x80-0x9F: bit 4 = write page, bits 3-1 = window, bit 0 = byte
    wire       sel = `RM_IS_MMU(rb_addr);
    wire [2:0] n   = rb_addr[3:1];
    wire       isw = rb_addr[4];
    wire       b1  = rb_addr[0];

    function [9:0] reset_page(input [2:0] w);
        reset_page = (w == 3'd0) ? 10'h3FC :
                     (w == 3'd1) ? 10'h3FD : {7'd0, w - 3'd2};
    endfunction
    function [7:0] reset_lo(input [2:0] w);
        reset_lo = (w == 3'd0) ? 8'hFC :
                   (w == 3'd1) ? 8'hFD : {5'd0, w - 3'd2};
    endfunction

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 8; i = i + 1) begin
                rp[i] <= reset_page(i[2:0]);
                wp[i] <= reset_page(i[2:0]);
                hr[i] <= reset_lo(i[2:0]);
                hw[i] <= reset_lo(i[2:0]);
            end
        end else if (rb_wr && sel) begin
            case ({isw, b1})
                2'b00: hr[n] <= rb_wdata;
                2'b10: hw[n] <= rb_wdata;
                2'b01: begin                            // MMUn_1: read and write page
                    rp[n] <= {rb_wdata[1:0], hr[n]};
                    wp[n] <= {rb_wdata[1:0], hr[n]};
                    hw[n] <= hr[n];
                end
                default: wp[n] <= {rb_wdata[1:0], hw[n]};   // MMUnW_1
            endcase
        end

        rb_hit   <= rb_rd && sel;
        rb_rdata <= 8'd0;
        if (rb_rd && sel)
            case ({isw, b1})
                2'b00:   rb_rdata <= rp[n][7:0];
                2'b01:   rb_rdata <= {6'd0, rp[n][9:8]};
                2'b10:   rb_rdata <= wp[n][7:0];
                default: rb_rdata <= {6'd0, wp[n][9:8]};
            endcase
    end
endmodule
