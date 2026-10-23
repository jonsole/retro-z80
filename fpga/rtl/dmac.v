// DMA scheduler (spec 2, section 5): decides who gets each 20 ns memory
// cycle, as the Amiga's Agnus does. sram_ctl.v does the cycle itself.
// retro68k's dmac.v, with retro-z80's cycle owners.
//
// Channels, each holding req until ack (a 1-clock pulse at the edge the
// cycle is issued); read data comes back on rdata with rvalid for that
// channel 40 ns later:
//   CPU   the Z80 (bus_if.v)
//   BPL   layer fetch: hard deadline (later; tied off)
//   SPR   sprites: hard deadline (later; tied off)
//   AUD   audio (parked; tied off)
//   COP   copper (later; tied off)
//   BLT   DMA engine (later; tied off)
//   PORT  the DMA port: a test channel, used by the simulation tests
//
// For each cycle of the 5 in a slot, the first rule that finds a request wins:
//
//   0. The CPU's own cycle: in cycles 0 and 2 a CPU request gets the cycle.
//      Nothing overrides this: the Z80 never waits.
//   1. An urgent hard-deadline request gets the cycle, whatever its number
//      (except as rule 0). Earliest deadline first.
//   2. The default owner: cycles 1 and 3 hard-deadline channels (earliest
//      deadline first); cycle 4 audio, then the copper at high priority.
//   3. The free order: hard-deadline channels (earliest deadline first),
//      AUD, COP, BLT, PORT; the copper at high priority goes first.
//
// Left out from retro68k's: the nasty copper (COPCON.PRI 2 and 3 act as 1)
// and the DMA engine's HIGH mode (blt_high, blt_share), which took the
// CPU's cycle; the CPU owns cycles 0 and 2 instead of cycle 0, and cycle 4
// (not 2) is kept for audio.
module dmac (
    input  wire        clk,
    input  wire        rst,

    // From sram_ctl: a cycle starts at the next edge, and which one
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
    input  wire [9:0]  bpl_deadline,   // system clocks until the data is needed
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
    input  wire [1:0]  cop_pri,        // COPCON.PRI: 0 normal, 1-3 high
    output reg         cop_ack,
    output wire        cop_rvalid,

    // DMA engine, and the DMA port (reads and writes)
    input  wire        blt_req,
    input  wire        blt_we,
    input  wire [21:1] blt_addr,
    input  wire [15:0] blt_wdata,
    input  wire [1:0]  blt_be,
    output reg         blt_ack,
    output wire        blt_rvalid,
    input  wire        port_req,
    input  wire        port_we,
    input  wire [21:1] port_addr,
    input  wire [15:0] port_wdata,
    input  wire [1:0]  port_be,
    output reg         port_ack,
    output wire        port_rvalid,

    // To sram_ctl
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

    // The hard-deadline channel that is due first (layers on a tie)
    wire       hard_any = bpl_req || spr_req;
    wire [2:0] hard     = (spr_req && (!bpl_req || spr_deadline < bpl_deadline)) ? C_SPR : C_BPL;
    wire       urg_any  = (bpl_req && bpl_urgent) || (spr_req && spr_urgent);
    wire [2:0] urg      = (spr_req && spr_urgent && !(bpl_req && bpl_urgent && bpl_deadline <= spr_deadline))
                          ? C_SPR : C_BPL;

    // The free order (a copper at high priority goes first)
    wire       cop_hi = cop_req && cop_pri != 2'd0;
    wire [2:0] free = cop_hi   ? C_COP :
                      hard_any ? hard :
                      aud_req  ? C_AUD :
                      cop_req  ? C_COP :
                      blt_req  ? C_BLT :
                      port_req ? C_PORT : C_NONE;

    // Who gets the cycle that starts at the next edge
    wire       cpu_cycle = (next_cycle == 3'd0) || (next_cycle == 3'd2);
    reg  [2:0] win;
    always @(*) begin
        if (cpu_cycle && cpu_req)
            win = C_CPU;                                    // 0: the CPU's own cycle
        else if (urg_any)
            win = urg;                                      // 1: urgent
        else case (next_cycle)                              // 2: the default owner, else 3: free
            3'd1, 3'd3:    win = hard_any ? hard : free;
            3'd4:          win = aud_req ? C_AUD : cop_hi ? C_COP : free;
            default:       win = free;
        endcase
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
