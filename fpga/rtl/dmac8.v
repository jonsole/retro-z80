// DMA scheduler for the fast-memory experiment (issue #91): retro-hw's
// dmac.v for 8 memory cycles a slot (sram_ctl8.v) in place of 5. The rules
// and channels are dmac's (see there); the differences:
//   - the cycle masks have 8 bits, one for each of cycles 0-7;
//   - cycles can be given out at two edges in a row (sram_ctl8 starts one
//     at 8 of the 10 edges of a slot). A channel holds req until it sees
//     ack, a clock after the cycle is given out, so in that clock its req
//     is the old one: a channel whose ack is high is not looked at.
//
// The plan of retro-z80's 8-cycle build (retroz80.v):
//   cycle         0     1     2     3     4     5     6     7
//   given out at  0     1     2     4     5     6     7     9    (slot edge)
//   owner         aud   disp  free  CPU   free  disp  free  CPU
// The CPU's cycles are 50 ns apart, given out at slot edges 4 and 9, as a
// request made at E + 3 of a T1 on slot edge 0 or 5 needs (spec 1, section
// 5.3); their data is in the clock after slot edges 8 and 3 (sram_ctl8.v),
// at di at edges 9 and 4, before the core takes it at 10 and 5. The display
// keeps two cycles, 50 ns apart. Audio has none in retro-z80 yet, so its
// cycle, and the three free ones, go to the free order: the DMA engine
// first, after the display's early fetches.
module dmac8 #(
    parameter [7:0] CPU_CYCLES  = 8'b10001000,
    parameter [7:0] HARD_CYCLES = 8'b00100010,
    parameter [7:0] AUD_CYCLES  = 8'b00000001,
    parameter       CPU_FIRST   = 1,
    parameter       NASTY       = 0,
    parameter       HIGH        = 0
) (
    input  wire        clk,
    input  wire        rst,

    // From sram_ctl8: a cycle starts at the next edge, and which one
    input  wire        start_next,
    input  wire [2:0]  next_cycle,

    // CPU
    input  wire        cpu_req,
    input  wire        cpu_we,
    input  wire [21:1] cpu_addr,
    input  wire [15:0] cpu_wdata,
    input  wire [1:0]  cpu_be,
    output reg         cpu_ack,
    output wire        cpu_rvalid,

    // Layers (reads)
    input  wire        bpl_req,
    input  wire [21:1] bpl_addr,
    input  wire [9:0]  bpl_deadline,
    input  wire        bpl_urgent,
    output reg         bpl_ack,
    output wire        bpl_rvalid,

    // Sprites (reads), audio (reads), copper (reads)
    input  wire        spr_req,
    input  wire [21:1] spr_addr,
    input  wire [9:0]  spr_deadline,
    input  wire        spr_urgent,
    output reg         spr_ack,
    output wire        spr_rvalid,
    input  wire        aud_req,
    input  wire [21:1] aud_addr,
    output reg         aud_ack,
    output wire        aud_rvalid,
    input  wire        cop_req,
    input  wire [21:1] cop_addr,
    input  wire [1:0]  cop_pri,
    output reg         cop_ack,
    output wire        cop_rvalid,

    // DMA engine / blitter, and the DMA port (reads and writes)
    input  wire        blt_req,
    input  wire        blt_we,
    input  wire [21:1] blt_addr,
    input  wire [15:0] blt_wdata,
    input  wire [1:0]  blt_be,
    input  wire        blt_high,
    input  wire [1:0]  blt_share,
    output reg         blt_ack,
    output wire        blt_rvalid,
    input  wire        port_req,
    input  wire        port_we,
    input  wire [21:1] port_addr,
    input  wire [15:0] port_wdata,
    input  wire [1:0]  port_be,
    output reg         port_ack,
    output wire        port_rvalid,

    // To sram_ctl8
    output wire        go,
    output wire        go_we,
    output wire [21:1] go_addr,
    output wire [15:0] go_wdata,
    output wire [1:0]  go_be,
    output wire [2:0]  go_tag,
    input  wire        rvalid,
    input  wire [2:0]  rtag
);
    localparam C_NONE = 3'd0, C_CPU = 3'd1, C_BPL = 3'd2, C_SPR = 3'd3,
               C_AUD  = 3'd4, C_COP = 3'd5, C_BLT = 3'd6, C_PORT = 3'd7;

    // Requests not yet answered: a channel's req in the clock of its ack is
    // the one just given a cycle
    wire cpu_r  = cpu_req  && !cpu_ack;
    wire bpl_r  = bpl_req  && !bpl_ack;
    wire spr_r  = spr_req  && !spr_ack;
    wire aud_r  = aud_req  && !aud_ack;
    wire cop_r  = cop_req  && !cop_ack;
    wire blt_r  = blt_req  && !blt_ack;
    wire port_r = port_req && !port_ack;

    // The hard-deadline channel that is due first (layers on a tie)
    wire       hard_any = bpl_r || spr_r;
    wire [2:0] hard     = (spr_r && (!bpl_r || spr_deadline < bpl_deadline)) ? C_SPR : C_BPL;
    wire       urg_any  = (bpl_r && bpl_urgent) || (spr_r && spr_urgent);
    wire [2:0] urg      = (spr_r && spr_urgent && !(bpl_r && bpl_urgent && bpl_deadline <= spr_deadline))
                          ? C_SPR : C_BPL;

    // The free order (a copper at high priority goes first)
    wire       cop_hi = cop_r && cop_pri != 2'd0;
    wire [2:0] free = cop_hi   ? C_COP :
                      hard_any ? hard :
                      aud_r    ? C_AUD :
                      cop_r    ? C_COP :
                      blt_r    ? C_BLT :
                      port_r   ? C_PORT : C_NONE;

    // The owners of the cycle that starts at the next edge
    wire [7:0] cyc       = 8'd1 << next_cycle;
    wire       cpu_cycle = |(cyc & CPU_CYCLES);
    wire       hard_cyc  = |(cyc & HARD_CYCLES);
    wire       aud_cyc   = |(cyc & AUD_CYCLES);
    wire       nasty     = (NASTY != 0) && cop_r && cop_pri == 2'd2;
    wire       high      = (HIGH != 0) && blt_r && blt_high;

    // A HIGH DMA engine job and the CPU both want the CPU's cycle: the CPU
    // gets every 2nd, 4th or 8th of these, the engine the rest
    reg  [2:0] shc;
    wire [2:0] shmax    = (blt_share == 2'd0) ? 3'd1 : (blt_share == 2'd1) ? 3'd3 : 3'd7;
    wire       cpu_turn = (shc == shmax);
    always @(posedge clk)
        if (rst || HIGH == 0) shc <= 3'd0;
        else if (start_next && cpu_cycle && cpu_r && high && !urg_any && !nasty)
            shc <= cpu_turn ? 3'd0 : shc + 1'b1;

    // Who gets the cycle that starts at the next edge
    reg  [2:0] win;
    always @(*) begin
        if ((CPU_FIRST != 0) && cpu_cycle && cpu_r)
            win = C_CPU;                                    // 0: the CPU's own cycle
        else if (urg_any)
            win = urg;                                      // 1: urgent
        else if (nasty)
            win = C_COP;                                    //    the copper, nasty
        else if (cpu_cycle && cpu_r)
            win = (high && !cpu_turn) ? C_BLT : C_CPU;      // 2: the default owner
        else if (hard_cyc && hard_any)
            win = hard;
        else if (aud_cyc && aud_r)
            win = C_AUD;
        else
            win = free;                                     // 3: free
        if (!start_next) win = C_NONE;
    end

    assign go       = (win != C_NONE);
    assign go_tag   = win;
    assign go_we    = (win == C_CPU) ? cpu_we : (win == C_BLT) ? blt_we : (win == C_PORT) ? port_we : 1'b0;
    assign go_addr  = (win == C_CPU) ? cpu_addr : (win == C_BPL) ? bpl_addr : (win == C_SPR) ? spr_addr :
                      (win == C_AUD) ? aud_addr : (win == C_COP) ? cop_addr : (win == C_BLT) ? blt_addr : port_addr;
    assign go_wdata = (win == C_CPU) ? cpu_wdata : (win == C_BLT) ? blt_wdata : port_wdata;
    assign go_be    = (win == C_CPU) ? cpu_be : (win == C_BLT) ? blt_be : (win == C_PORT) ? port_be : 2'b11;

    always @(posedge clk) begin
        cpu_ack  <= !rst && win == C_CPU;
        bpl_ack  <= !rst && win == C_BPL;
        spr_ack  <= !rst && win == C_SPR;
        aud_ack  <= !rst && win == C_AUD;
        cop_ack  <= !rst && win == C_COP;
        blt_ack  <= !rst && win == C_BLT;
        port_ack <= !rst && win == C_PORT;
    end

    // Read data back to its channel (rdata itself is shared)
    assign cpu_rvalid  = rvalid && rtag == C_CPU;
    assign bpl_rvalid  = rvalid && rtag == C_BPL;
    assign spr_rvalid  = rvalid && rtag == C_SPR;
    assign aud_rvalid  = rvalid && rtag == C_AUD;
    assign cop_rvalid  = rvalid && rtag == C_COP;
    assign blt_rvalid  = rvalid && rtag == C_BLT;
    assign port_rvalid = rvalid && rtag == C_PORT;
endmodule
