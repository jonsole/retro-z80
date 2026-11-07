// All clocks for the KS2 build, from the board's 50 MHz oscillator through
// two MMCMs. Adapted from retro68k's ks3_clocks.v for the XC7A15T-1, whose
// MMCM VCO range is 600-1200 MHz (the -2 part's 1440 MHz VCO for 576p is
// out of reach). tv80 runs on the system clock, so there is no 40 MHz clock.
//
// MMCM 1: 50 MHz x 20 = VCO 1000 MHz
//   clk100   100 MHz   (/10)  system, SRAM controller
// or, with SERDES (the fast-memory experiment, issue #91), as the SRAM
// tester's: 50 MHz x 16 = VCO 800 MHz
//   clk100   100 MHz   (/8)   system, SRAM controller
//   clk200   200 MHz   (/4)   the SRAM pads' output SERDES word clock, IDELAY reference
//   clk400   400 MHz   (/2)   the SRAM pads' SERDES bit clock
//   all three rising together
// MMCM 2: 50 MHz / 2 x 27 = VCO 675 MHz, for 576p (CEA-861, 27 MHz)
//   clk_pix   27 MHz   (/25)  pixel clock
//   clk_pix5 135 MHz   (/5)   HDMI serialiser (10 bits per pixel, both edges)
//
// Both come from the same oscillator, so the frequencies are exact; the
// phase between the two MMCMs is fixed but unknown, so the video side is
// an asynchronous clock domain.
module ks2_clocks #(
    parameter SERDES = 0
) (
    input  wire clk50,
    output wire clk100,
    output wire clk200,                 // with SERDES only (else 0)
    output wire clk400,                 // with SERDES only (else 0)
    output wire clk_pix,
    output wire clk_pix5,
    output wire locked
);
    wire clk50_b;
    BUFG b_in (.I(clk50), .O(clk50_b));

    // ---- MMCM 1: system clock
    wire fb1, fb1_buf, c0, c1, c2, l1;
    MMCME2_BASE #(
        .CLKIN1_PERIOD     (20.0),
        .DIVCLK_DIVIDE     (1),
        .CLKFBOUT_MULT_F   (SERDES ? 16.0 : 20.0),  // VCO 800 or 1000 MHz
        .CLKOUT0_DIVIDE_F  (SERDES ? 8.0 : 10.0),   // 100 MHz
        .CLKOUT1_DIVIDE    (SERDES ? 4 : 1),        // 200 MHz (SERDES; else not used)
        .CLKOUT2_DIVIDE    (SERDES ? 2 : 1)         // 400 MHz (SERDES; else not used)
    ) mmcm_sys (
        .CLKIN1(clk50_b), .CLKFBIN(fb1_buf), .CLKFBOUT(fb1),
        .CLKOUT0(c0), .CLKOUT1(c1), .CLKOUT2(c2), .CLKOUT3(), .CLKOUT4(),
        .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2B(), .CLKOUT3B(), .CLKFBOUTB(),
        .CLKOUT5(), .CLKOUT6(),
        .LOCKED(l1), .PWRDWN(1'b0), .RST(1'b0)
    );
    BUFG b_fb1 (.I(fb1), .O(fb1_buf));
    BUFG b0    (.I(c0), .O(clk100));
    generate if (SERDES) begin : g_serdes
        BUFG b1 (.I(c1), .O(clk200));
        BUFG b4 (.I(c2), .O(clk400));
    end else begin : g_noserdes
        assign clk200 = 1'b0;
        assign clk400 = 1'b0;
    end endgenerate

    // ---- MMCM 2: 576p pixel clocks
    wire fb2, fb2_buf, p0, p1, l2;
    MMCME2_BASE #(
        .CLKIN1_PERIOD     (20.0),
        .DIVCLK_DIVIDE     (2),             // 25 MHz into the phase detector
        .CLKFBOUT_MULT_F   (27.0),          // VCO 675 MHz
        .CLKOUT0_DIVIDE_F  (25.0),          // 27 MHz
        .CLKOUT1_DIVIDE    (5)              // 135 MHz
    ) mmcm_pix (
        .CLKIN1(clk50_b), .CLKFBIN(fb2_buf), .CLKFBOUT(fb2),
        .CLKOUT0(p0), .CLKOUT1(p1), .CLKOUT2(), .CLKOUT3(), .CLKOUT4(),
        .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2B(), .CLKOUT3B(), .CLKFBOUTB(),
        .CLKOUT5(), .CLKOUT6(),
        .LOCKED(l2), .PWRDWN(1'b0), .RST(1'b0)
    );
    BUFG b_fb2 (.I(fb2), .O(fb2_buf));
    BUFG b2    (.I(p0), .O(clk_pix));
    BUFG b3    (.I(p1), .O(clk_pix5));

    assign locked = l1 && l2;
endmodule
