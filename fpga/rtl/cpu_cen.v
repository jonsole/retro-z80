// The Z80's clock enable: the bus interface's speed divider (spec 1,
// section 3; CPUSPEED is spec 7, section 6.1). One cen pulse is one
// T-state:
//   DIV = n - 1   a T-state every 5n clocks (20 MHz / n), n = 1-8. The core
//                 leaves reset so that its first cen edge is slot edge 0, and
//                 5n keeps every edge on slot edge 0 or 5: locked to the slots
//   SPECTRUM = 1  a T-state every 28 clocks (3.57 MHz), DIV ignored; the edges
//                 fall on any slot edge
// A new speed takes effect at the next T1: the divider looks at the core's
// tstate at E + 3 (spec 1, section 3.3) and, if a T1 has just started, takes
// CPUSPEED for the whole M-cycle. tv80 makes the wait states of its I/O
// cycle and its interrupt acknowledge by repeating T1, so only a T1 after
// some other T-state starts an M-cycle. Going from 3.57 MHz to a locked speed, the
// T-states from the change to that T1 end on the first slot edge 0 or 5 at
// least 28 clocks on (up to 4 clocks late), so the T1 is on one too. The
// core's last T-state of an M-cycle is not visible outside it, so every
// T-state up to that T1 is aligned, not only the one before it.
module cpu_cen (
    input  wire       clk,
    input  wire       rst,            // with the core's reset; released at slot edge 5
    input  wire [3:0] sc,             // slot edge counter (timebase.v)
    input  wire [3:0] cpuspeed,       // CPUSPEED: SPECTRUM (3), DIV (2-0)
    input  wire       t1,             // the core is in T1 (tstate[1])
    output wire       cen
);
    reg [5:0] cnt;                    // clocks since the last cen edge: 0 in the clock after it
    reg [5:0] per;                    // clocks per T-state in this M-cycle
    reg       spectrum;               // this M-cycle runs at 3.57 MHz
    reg       was_t1;                 // the T-state before this one was a T1

    // The clock edge at the end of this clock is slot edge 0 or 5
    wire on_grid = (sc == 4'd4) || (sc == 4'd9);
    // At 3.57 MHz, with a locked speed waiting for the next T1
    wire align   = spectrum && !cpuspeed[3];

    assign cen = !rst && (align ? (cnt >= 6'd27 && on_grid) : (cnt == per - 6'd1));

    always @(posedge clk)
        if (rst) begin
            cnt      <= 6'd0;         // first cen in the clock before slot edge 0
            per      <= 6'd5;         // 20 MHz
            spectrum <= 1'b0;
            was_t1   <= 1'b0;
        end else begin
            cnt <= cen ? 6'd0 : cnt + 6'd1;
            if (cnt == 6'd2) was_t1 <= t1;
            if (cnt == 6'd2 && t1 && !was_t1) begin   // E + 3, in the first T1
                spectrum <= cpuspeed[3];
                if (cpuspeed[3])
                    per <= 6'd28;
                else case (cpuspeed[2:0])
                    3'd0: per <= 6'd5;
                    3'd1: per <= 6'd10;
                    3'd2: per <= 6'd15;
                    3'd3: per <= 6'd20;
                    3'd4: per <= 6'd25;
                    3'd5: per <= 6'd30;
                    3'd6: per <= 6'd35;
                    default: per <= 6'd40;
                endcase
            end
        end
endmodule
