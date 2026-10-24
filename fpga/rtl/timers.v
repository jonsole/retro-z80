// Timers and watchdog, registers 0x20-0x4B of the system page (spec 9).
// retro68k's timers.v narrowed to byte registers on the 8-bit register bus:
// a 32-bit microsecond TIME, four 16-bit timers with 16-bit prescalers, and
// the watchdog.
//
//   TIME0-3     0x20-0x23  TIME, microseconds from power-on. Reading TIME0
//                          hands the whole value to the reading master's
//                          capture (rb_cdata, rb_cap; spec 3, rule 4); TIME1-3
//                          read the live bytes, the bus interface answers
//                          them from its capture when it holds TIME
//   TMRn        0x28 + 8n  CTRL, PRESCALE0-1, RELOAD0-1, COUNT0-1 (COUNT0
//                          captures, as TIME0), STAT
//   WDCTRL      0x48       EN (0), LOCK (1)
//   WDTIME0-1   0x49-0x4A  milliseconds between kicks (0 acts as 1)
//   WDKICK      0x4B       0x5A kicks; any other value resets (while EN)
// 0x24-0x27 and 0x4C-0x4F are reserved and not answered (read 0xFF).
//
// Every reset but power-on resets the timers and the watchdog (spec 7,
// section 3): every reset is a full one here. TIME runs on.
//
// A timer underflows on the tick after COUNT = 0: STAT.UNDER is set, a
// pulse goes to the DMA start line CTRL.DMACH if CTRL.DMA, and the next
// timer (SRC 3) gets a tick in the following clock. Writing CTRL with EN
// going from 0 to 1 starts the prescaler again, so the first SRC 0 period
// is full length.
`include "regmap.vh"

module timers (
    input  wire        clk,            // 100 MHz
    input  wire        por,            // power-on: TIME starts at 0
    input  wire        rst,            // any reset: timers and watchdog

    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [12:0] rb_addr,
    input  wire [7:0]  rb_wdata,
    output reg  [7:0]  rb_rdata,
    output reg         rb_hit,         // with rb_rdata: this unit answered
    output reg  [31:0] rb_cdata,       // with rb_rdata: a capturing register's whole value
    output reg         rb_cap,         // ... and that rb_cdata holds one

    input  wire        us_tick,        // 1 clock every microsecond
    input  wire        line_tick,      // 1 clock at the start of each beam line
    input  wire        frame_tick,     // 1 clock at the start of each frame

    output wire [3:0]  irq,            // TIMER0-3 (spec 8: sources 11-14)
    output reg  [3:0]  dma_start,      // 1 clock: start DMA engine channel n (spec 14)
    output reg         wd_reset        // 1 clock: the watchdog resets the computer
);
    // ---------------------------------------------------------------- decode
    wire       in_sys = (rb_addr[12:8] == 5'd0);
    wire [7:0] reg_n  = rb_addr[7:0];
    wire       is_time = in_sys && (reg_n[7:2] == 6'b001000);          // 0x20-0x23
    wire       is_tmr  = in_sys && (reg_n >= 8'h28) && (reg_n <= 8'h47);
    wire       is_wd   = in_sys && (reg_n >= 8'h48) && (reg_n <= 8'h4B);
    wire [7:0] tmr_off = reg_n - 8'h28;
    wire [1:0] t       = tmr_off[4:3]; // which timer
    wire [2:0] toff    = tmr_off[2:0]; // which of its registers

    // ---------------------------------------------------------------- time counter
    reg [31:0] time_c;
    always @(posedge clk)
        if (por)          time_c <= 32'd0;
        else if (us_tick) time_c <= time_c + 1'b1;

    // ---------------------------------------------------------------- general timers
    reg [7:0]  ctrl     [0:3];         // DMACH (7-6), DMA (5), IRQ (4), SRC (3-2), REPEAT (1), EN (0)
    reg [15:0] prescale [0:3];
    reg [15:0] pre_c    [0:3];         // the prescaler's own count
    reg [15:0] reload   [0:3];
    reg [15:0] count    [0:3];
    reg [3:0]  under;                  // STAT.UNDER, sticky
    reg [3:0]  uf;                     // underflowed last clock: a tick for the next timer

    assign irq = under & {ctrl[3][4], ctrl[2][4], ctrl[1][4], ctrl[0][4]};

    reg [3:0] tick;
    integer n;
    always @(*) for (n = 0; n < 4; n = n + 1)
        case (ctrl[n][3:2])
            2'd0: tick[n] = (pre_c[n] == 16'd0);
            2'd1: tick[n] = line_tick;
            2'd2: tick[n] = frame_tick;
            default: tick[n] = uf[(n + 3) % 4];      // the previous timer (timer 0 counts timer 3)
        endcase

    // ---------------------------------------------------------------- watchdog
    reg        wd_en, wd_lock;
    reg [15:0] wd_time, wd_left;
    reg [9:0]  ms_div;
    wire       ms_tick = us_tick && (ms_div == 10'd999);
    wire [15:0] wd_load = (wd_time == 16'd0) ? 16'd1 : wd_time;

    always @(posedge clk) begin
        uf        <= 4'd0;
        dma_start <= 4'd0;
        wd_reset  <= 1'b0;
        if (us_tick) ms_div <= (ms_div == 10'd999) ? 10'd0 : ms_div + 1'b1;
        if (rst) begin
            for (n = 0; n < 4; n = n + 1) begin
                ctrl[n]     <= 8'd0;
                prescale[n] <= 16'd0;
                pre_c[n]    <= 16'd0;
                reload[n]   <= 16'd0;
                count[n]    <= 16'd0;
            end
            under   <= 4'd0;
            wd_en   <= 1'b0;
            wd_lock <= 1'b0;
            wd_time <= 16'd1000;
            wd_left <= 16'd1000;
            ms_div  <= 10'd0;
        end else begin
            // Watchdog countdown (before the register writes, so a kick in
            // the same clock wins)
            if (wd_en && ms_tick) begin
                if (wd_left == 16'd0) wd_reset <= 1'b1;
                else                  wd_left  <= wd_left - 1'b1;
            end

            // Timers (before the register writes, so a write wins)
            for (n = 0; n < 4; n = n + 1) begin
                pre_c[n] <= (pre_c[n] == 16'd0) ? prescale[n] : pre_c[n] - 1'b1;
                if (ctrl[n][0] && tick[n]) begin
                    if (count[n] == 16'd0) begin
                        uf[n]    <= 1'b1;
                        under[n] <= 1'b1;
                        if (ctrl[n][5]) dma_start[ctrl[n][7:6]] <= 1'b1;
                        if (ctrl[n][1]) count[n]   <= reload[n];
                        else            ctrl[n][0] <= 1'b0;   // one-shot: stop
                    end else
                        count[n] <= count[n] - 1'b1;
                end
            end
            if (rb_wr && is_tmr) case (toff)
                3'd0: begin
                    ctrl[t] <= rb_wdata;
                    if (rb_wdata[0] && !ctrl[t][0]) pre_c[t] <= prescale[t];
                end
                3'd1: prescale[t][7:0]  <= rb_wdata;
                3'd2: prescale[t][15:8] <= rb_wdata;
                3'd3: reload[t][7:0]    <= rb_wdata;
                3'd4: reload[t][15:8]   <= rb_wdata;
                3'd5: count[t][7:0]     <= rb_wdata;
                3'd6: count[t][15:8]    <= rb_wdata;
                default: if (rb_wdata[`RM_TMR_STAT_UNDER]) under[t] <= 1'b0;
            endcase

            if (rb_wr && is_wd) case (reg_n[1:0])
                2'd0: if (!wd_lock) begin                     // WDCTRL: also restarts the time
                    wd_en   <= rb_wdata[`RM_WDCTRL_EN];
                    wd_lock <= rb_wdata[`RM_WDCTRL_LOCK];
                    wd_left <= wd_load;
                end
                2'd1: if (!wd_lock) wd_time[7:0]  <= rb_wdata;
                2'd2: if (!wd_lock) wd_time[15:8] <= rb_wdata;
                default: if (wd_en) begin                     // WDKICK
                    if ({24'd0, rb_wdata} == `RM_WDKICK_MAGIC) wd_left  <= wd_load;
                    else                                       wd_reset <= 1'b1;
                end
            endcase
        end

        // Reads. TIME0 and COUNT0 hand the whole value over for the capture.
        rb_rdata <= 8'd0;
        rb_cdata <= 32'd0;
        rb_cap   <= 1'b0;
        rb_hit   <= rb_rd && (is_time || is_tmr || is_wd);
        if (rb_rd && is_time) begin
            rb_rdata <= time_c[8 * reg_n[1:0] +: 8];
            if (reg_n[1:0] == 2'd0) begin
                rb_cdata <= time_c;
                rb_cap   <= 1'b1;
            end
        end
        if (rb_rd && is_tmr) case (toff)
            3'd0: rb_rdata <= ctrl[t];
            3'd1: rb_rdata <= prescale[t][7:0];
            3'd2: rb_rdata <= prescale[t][15:8];
            3'd3: rb_rdata <= reload[t][7:0];
            3'd4: rb_rdata <= reload[t][15:8];
            3'd5: begin
                rb_rdata <= count[t][7:0];
                rb_cdata <= {16'd0, count[t]};
                rb_cap   <= 1'b1;
            end
            3'd6: rb_rdata <= count[t][15:8];
            default: rb_rdata <= {7'd0, under[t]};
        endcase
        if (rb_rd && is_wd) case (reg_n[1:0])
            2'd0: rb_rdata <= {6'd0, wd_lock, wd_en};
            2'd1: rb_rdata <= wd_time[7:0];
            2'd2: rb_rdata <= wd_time[15:8];
            default: ;                                        // WDKICK reads 0
        endcase
    end
endmodule
