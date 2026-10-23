// Timebase (spec 2, section 3): the slot edge counter.
//
// The last edge that sees "rst" high must be the start of a slot, so the
// counter knows where it is on the 100 ns grid. Only the power-on reset
// resets the timebase.
//
//   sc : which 100 MHz edge started the current clock, 0-9 within the slot
//        (memory cycle n = sc 2n and 2n+1)
module timebase (
    input  wire       clk,      // 100 MHz
    input  wire       rst,      // power-on reset, last seen high on a slot boundary
    output reg  [3:0] sc
);
    always @(posedge clk) begin
        if (rst) sc <= 4'd0;
        else     sc <= (sc == 4'd9) ? 4'd0 : sc + 4'd1;
    end
endmodule
