// For linting the fast-memory KS2 build (top_ks2.v with FASTMEM, issue #91;
// fpga/lint.sh) with the SRAM tester's stand-ins (lint_stub_sramtest.v),
// whose OSERDESE2 takes every parameter sram8_pads.v sets: the one primitive
// they lack, retro-hw's ODDR (for oddr.v). No logic; never simulated or
// synthesised.
module ODDR #(
    parameter DDR_CLK_EDGE = "OPPOSITE_EDGE",
    parameter [0:0] INIT   = 1'b0,
    parameter SRTYPE       = "SYNC"
) (
    input  wire C, CE, D1, D2, R, S,
    output wire Q
);
    assign Q = D1;
endmodule
