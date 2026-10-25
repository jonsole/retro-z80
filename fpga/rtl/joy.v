// The two joystick ports (spec 12, section 4) and the Kempston port 0x1F
// (section 8.5). 100 MHz.
//
// The ports share one set of FPGA inputs (pins 1, 2, 3, 4, 6, 9, active
// low) through the board's multiplexer, switched by joysel (0 = the left
// connector, joystick 1; 1 = the right, joystick 2; as the Next's
// md6_joystick_connector_x2); the Mega Drive select line (pin 7) is one
// output for both ports. Each step of the sequencer is two halves of
// HALFCLK clocks (5.12 us): joysel 0, then 1, the lines sampled at the end
// of each half, after they have settled.
//
// Steps come every 10.24 us, 200 to a period (2.048 ms). Steps 0-7 are the
// Mega Drive burst, when MD1 or MD2 is set: select high, low, high ... (spec
// 12, section 4.2's steps 1-8); the other 192 steps (1.97 ms) keep select
// high, so a 6-button pad's count resets between bursts. Without MD1 and
// MD2 select stays high all the time.
//
//   A port with MDn = 0 (an Atari stick) is updated from every sample taken
//   with select high: directions, Fire 1 (pin 6) and Fire 2 (pin 9).
//   A port with MDn = 1 is read as a Mega Drive pad and updated at the end
//   of each burst: step 0 (high) Up, Down, Left, Right, B, C; step 1 (low)
//   pins 3-4 low = a pad (MDPRESn), A, START; step 5 (low, the third
//   falling edge) pins 1-4 all low = a 6-button pad (SIXn); step 6 (high)
//   Z, Y, X, MODE on pins 1-4.
//
// Registers: JOY1 0x66, JOY2 0x67 (bit 0 Right, 1 Left, 2 Down, 3 Up, 4 Fire
// 1 / B, 5 Fire 2 / C, 6 A, 7 START; 1 = pressed), JOYCON 0x68 (MD1 0, MD2
// 1; read only SIX1 4, SIX2 5, MDPRES1 6, MDPRES2 7), JOY1X 0x6C, JOY2X 0x6D
// (X 0, Y 1, Z 2, MODE 3), KEMPSTON 0x1F (port 0x1F with any high byte, and
// 0x1F00): JOY1's value.
`include "regmap.vh"

module joy #(
    parameter HALFCLK = 512            // clocks per half step: 5.12 us
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [12:0] rb_addr,
    input  wire [7:0]  rb_wdata,
    output reg  [7:0]  rb_rdata,
    output reg         rb_hit,

    input  wire [5:0]  pin_n,          // pins 9, 6, 4, 3, 2, 1 (bits 5-0), active low
    output reg         joysel,         // 0: port 1 (left), 1: port 2 (right)
    output reg         sel_o           // pin 7, the Mega Drive select
);
    reg  [1:0] md;                     // JOYCON.MD2, MD1

    (* ASYNC_REG = "TRUE" *) reg [5:0] ps0;
    reg  [5:0] ps1;
    always @(posedge clk) begin
        ps0 <= pin_n;
        ps1 <= ps0;
    end
    // Pressed, 1 = low at the pin: u d l r b c
    wire u = !ps1[0], d = !ps1[1], l = !ps1[2], r = !ps1[3], b = !ps1[4], c = !ps1[5];

    reg  [9:0] t;
    reg  [7:0] step;
    wire       burst = (md != 2'b00) && step < 8'd8;
    wire       sel_hi = !burst || !step[0];
    wire       sample = (t == HALFCLK - 1);

    reg  [7:0] j [0:1];                // JOY1, JOY2
    reg  [3:0] jx [0:1];               // JOY1X, JOY2X
    reg  [1:0] pres, six;              // MDPRESn, SIXn
    // The burst's readings, one set per port
    reg  [5:0] m_dir [0:1];            // {C, B, U, D, L, R}
    reg  [1:0] m_as [0:1];             // {START, A}
    reg  [1:0] m_pres, m_six;
    reg  [3:0] m_x [0:1];

    integer n;
    always @(posedge clk)
        if (rst) begin
            t <= 10'd0; step <= 8'd0; joysel <= 1'b0; sel_o <= 1'b1;
            md <= 2'b00; pres <= 2'b00; six <= 2'b00; m_pres <= 2'b00; m_six <= 2'b00;
            for (n = 0; n < 2; n = n + 1) begin
                j[n] <= 8'd0; jx[n] <= 4'd0; m_dir[n] <= 6'd0; m_as[n] <= 2'd0; m_x[n] <= 4'd0;
            end
        end else begin
            if (rb_wr && rb_addr == `RM_JOYCON) md <= rb_wdata[1:0];
            sel_o <= sel_hi;
            t <= sample ? 10'd0 : t + 1'b1;
            if (sample) begin
                joysel <= !joysel;
                if (joysel) step <= (step == 8'd199) ? 8'd0 : step + 1'b1;
                // Port joysel's lines
                if (!md[joysel]) begin
                    if (sel_hi) j[joysel] <= {2'b00, c, b, u, d, l, r};
                    jx[joysel] <= 4'd0;
                    pres[joysel] <= 1'b0;
                    six[joysel] <= 1'b0;
                end else if (burst) begin
                    case (step[2:0])
                        3'd0: m_dir[joysel] <= {c, b, u, d, l, r};
                        3'd1: begin m_pres[joysel] <= l && r; m_as[joysel] <= {c, b}; end
                        3'd5: m_six[joysel] <= u && d && l && r;
                        3'd6: m_x[joysel] <= {r, u, d, l};            // MODE (pin 4), Z (1), Y (2), X (3)
                        3'd7: begin                                    // the burst's end
                            j[joysel]    <= {m_pres[joysel] ? m_as[joysel] : 2'b00, m_dir[joysel]};
                            pres[joysel] <= m_pres[joysel];
                            six[joysel]  <= m_pres[joysel] && m_six[joysel];
                            jx[joysel]   <= (m_pres[joysel] && m_six[joysel]) ? m_x[joysel] : 4'd0;
                        end
                        default: ;
                    endcase
                end
            end
        end

    wire sel = rb_addr == `RM_JOY1 || rb_addr == `RM_JOY2 || rb_addr == `RM_JOYCON ||
               rb_addr == `RM_JOY1X || rb_addr == `RM_JOY2X || rb_addr == `RM_KEMPSTON;
    always @(posedge clk) begin
        rb_rdata <= 8'd0;
        rb_hit   <= rb_rd && sel;
        if (rb_rd) case (rb_addr)
            `RM_JOY1, `RM_KEMPSTON: rb_rdata <= j[0];
            `RM_JOY2:   rb_rdata <= j[1];
            `RM_JOYCON: rb_rdata <= {pres[1], pres[0], six[1], six[0], 2'b00, md};
            `RM_JOY1X:  rb_rdata <= {4'd0, jx[0]};
            `RM_JOY2X:  rb_rdata <= {4'd0, jx[1]};
            default: ;
        endcase
    end
endmodule
