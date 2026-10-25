// MMU (spec 2, section 9): eight 8 KB windows (A15-A13), each with a read
// page and a write page, 10 bits each. retro-z80's own; retro68k has no MMU.
//
// The page registers are registers 0x80-0x9F of the system page (spec 3,
// section 4.10), on the register bus: MMUn_0/MMUn_1 (read page, 0x80 + 2n)
// and MMUnW_0/MMUnW_1 (write page, 0x90 + 2n). They are the one exception
// to direct writes (spec 3, section 3.1):
//   - writing byte 0 only holds it, in a held byte of that register's own;
//   - writing byte 1 commits the page with the held byte 0, or with the
//     page's current bits 7-0 if byte 0 has not been written since the
//     last commit (a flag for each held byte);
//   - committing a read page also sets the window's write page (and drops
//     its held byte), so one register changes a window; committing a write
//     page afterwards splits it.
// Reading gives the committed value; bits 7-2 of byte 1 read 0.
//
// Every reset puts the mapping of section 9.4 back: windows 0-1 boot ROM
// pages 0x3FC-0x3FD, windows 2-7 SRAM pages 0x000-0x005, write = read.
// What each page is (SRAM, ROM, REGS, NONE, reserved) is decoded by the bus
// interface (bus_if.v).
//
// The copy port (spec 2, section 9.9; ticket #27): the interrupt pages'
// copy engine (intpages.v) reads window cp_win's two pages and, with cp_ld,
// loads them, one window per clock. A load leaves the held bytes alone, so
// a byte 0 written before an NMI still counts after its return. The CPU
// never writes the MMU during a copy.
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
    output wire [9:0]  wpage,

    // Copy port, for the interrupt pages (intpages.v)
    input  wire [2:0]  cp_win,
    input  wire        cp_ld,
    input  wire [9:0]  cp_rp,
    input  wire [9:0]  cp_wp,
    output wire [9:0]  cp_cur_rp,
    output wire [9:0]  cp_cur_wp
);
    reg [9:0] rp [0:7];                // committed read pages
    reg [9:0] wp [0:7];                // committed write pages
    reg [7:0] hr [0:7];                // held byte 0 of MMUn
    reg [7:0] hw [0:7];                // held byte 0 of MMUnW
    reg [7:0] fr, fw;                  // ... written since the last commit

    assign rpage = rp[win];
    assign wpage = wp[win];
    assign cp_cur_rp = rp[cp_win];
    assign cp_cur_wp = wp[cp_win];

    // Registers 0x80-0x9F: bit 4 = write page, bits 3-1 = window, bit 0 = byte
    wire       sel = `RM_IS_MMU(rb_addr);
    wire [2:0] n   = rb_addr[3:1];
    wire       isw = rb_addr[4];
    wire       b1  = rb_addr[0];
    // The bits 7-0 a byte 1 commits with: the held byte, or the page's own
    wire [7:0] lo_r = fr[n] ? hr[n] : rp[n][7:0];
    wire [7:0] lo_w = fw[n] ? hw[n] : wp[n][7:0];

    function [9:0] reset_page(input [2:0] w);
        reset_page = (w == 3'd0) ? 10'h3FC :
                     (w == 3'd1) ? 10'h3FD : {7'd0, w - 3'd2};
    endfunction

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 8; i = i + 1) begin
                rp[i] <= reset_page(i[2:0]);
                wp[i] <= reset_page(i[2:0]);
            end
            fr <= 8'd0;
            fw <= 8'd0;
        end else if (rb_wr && sel) begin
            case ({isw, b1})
                2'b00: begin hr[n] <= rb_wdata; fr[n] <= 1'b1; end
                2'b10: begin hw[n] <= rb_wdata; fw[n] <= 1'b1; end
                2'b01: begin                            // MMUn_1: read and write page
                    rp[n] <= {rb_wdata[1:0], lo_r};
                    wp[n] <= {rb_wdata[1:0], lo_r};
                    fr[n] <= 1'b0;
                    fw[n] <= 1'b0;
                end
                default: begin                          // MMUnW_1
                    wp[n] <= {rb_wdata[1:0], lo_w};
                    fw[n] <= 1'b0;
                end
            endcase
        end
        // A copy loads only the pages; held bytes stay with their registers
        if (!rst && cp_ld) begin
            rp[cp_win] <= cp_rp;
            wp[cp_win] <= cp_wp;
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
