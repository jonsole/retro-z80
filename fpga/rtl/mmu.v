// MMU (spec 2, section 9), version for ticket #4: only the reset mapping
// (section 9.4), with no page registers yet. Window w = A15-A13.
//
//   window 0-1: boot ROM pages 0x3FC-0x3FD; window 2-7: SRAM pages 0x000-0x005
//   each window's write page is its read page
//
// The page registers MMUn / MMUnW and the register page come with the full
// MMU. Page types (section 9.3) are decoded here for the bus interface.
module mmu (
    input  wire [2:0] win,
    output wire [9:0] rpage,
    output wire [9:0] wpage
);
    assign rpage = (win == 3'd0) ? 10'h3FC :
                   (win == 3'd1) ? 10'h3FD : {7'd0, win} - 10'd2;
    assign wpage = rpage;
endmodule
