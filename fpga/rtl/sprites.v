// Sprites, 100 MHz side (spec 5): the registers, on retro-hw's
// sprite_fetch core (the fetcher, the FIFOs and the deadlines). retro68k's
// sprites.v, narrowed to byte registers on the 8-bit register bus (ticket
// #31), and split into this wrapper and the core.
//
// Eight sprites (NS of them built). Each has a pointer into its image
// (SPRxPT), a window (SPRxH, SPRxV), settings (SPRxCTL) and a scale
// (SPRxSTEP), written by the CPU (later the copper), and a 32-word FIFO:
// its data registers. The core fetches each line's words during that
// line, one word at a time through the scheduler's sprite channel
// (dmac.v), the sprite with the nearest deadline first. The pixel side
// (sprite_pix.v) takes the words.
//
// This wrapper keeps the registers: SPRxH, SPRxV, SPRxCTL and SPRxSTEP in
// distributed RAM, handed to the core a sprite a clock (set_sel); SPRDMA;
// the reads. The line start (SPRxPT) lives in the core, as its line-start
// pass moves it on: a PT write merges the byte into the core's value
// (lst_cur) and writes it back whole (lst_wr). A write to SPRxCTL starts
// the sprite (start). SPRCOLL is the core's coll, cleared by byte.
//
// The core registers the settings at its input, with set_sel one sprite
// ahead (retro-hw#8), so the m_s/m_h/m_v reads here stay combinational. A
// settings write that lands in its own sprite's hand-over clock is seen at
// that sprite's next visit, NS clocks later.
//
// Registers (spec 5, section 6), sprite n at custom 0x010 + n x 0x10:
//   +0x0-0x2  SPRxPT    bits 21-1: where the next image line starts. Read:
//                       the start of the line being drawn, or the value
//                       written; reading +0x0 hands all three bytes to the
//                       bus interface's capture (spec 3, rule 4)
//   +0x3-0x6  SPRxH     HSTART (10-0), HSTOP (26-16)
//   +0x7-0xA  SPRxV     VSTART, VSTOP
//   +0xB      SPRxCTL   BPP (1-0), DEPTH (3-2), PAL (7-4); a write starts it
//   +0xC-0xF  SPRxSTEP  XSTEP (15-0), YSTEP (31-16)
//   0x120     SPRDMA0   the enables; a write holds the bits SPRDMA1 acts on
//   0x121     SPRDMA1   bit 7 SETCLR: a write sets or clears those bits
//   0x124-127 SPRCOLL0-3  SPR, L0, L1, L2 collisions, each byte W1C
// Each byte is written directly (spec 3, rule 2). A sprite not built (n >=
// NS) has no registers: they read 0xFF.
//
// Changed from retro68k: byte registers (above) in place of 32-bit words
// with byte enables; SPRxCTL is the byte retro68k's RAM keeps, stored as
// written (BPP 3 is taken as 8 bpp where it is used); no manual mode (the
// core's MANUAL off: no SPRxDAT, no FIFO writes from the bus, no FIFO
// count read); 22-bit pointers (PW 22); each word's even byte to the FIFO
// word's high half (LITTLE: the SRAM is little-endian, spec 5, section
// 3.5); the urgent mark one unit (8 clocks) earlier (URGENT 6), as an
// urgent fetch never takes the CPU's cycles (spec 2); NS sprites built (the
// others never start, fetch or show).
`include "regmap.vh"

module sprites #(
    parameter NS = 8                   // sprites built (1-8)
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [12:0] rb_addr,
    input  wire [7:0]  rb_wdata,
    output reg  [7:0]  rb_rdata,
    output reg         rb_hit,
    output reg  [31:0] rb_cdata,       // with rb_rdata: SPRxPT whole, for the capture
    output reg         rb_cap,

    input  wire        dma_on,         // DMACON.DMAEN and SPREN
    input  wire        vblank,         // 1 clock: the vertical blank starts
    input  wire [10:0] beam_v,         // the beam (memory side samples)
    input  wire [10:0] beam_h,

    // Scheduler: the sprite channel
    output wire        mem_req,
    output wire [21:1] mem_addr,
    output wire        mem_urgent,
    input  wire        mem_ack,
    input  wire        mem_rvalid,
    input  wire [15:0] mem_rdata,

    // To the pixel side: each sprite's settings (read once per line there)
    output wire [79:0] p_hs,           // 8 x 10: first pixel (0-864)
    output wire [79:0] p_xe,           // 8 x 10: pixel after the last shown (0-864)
    output wire [7:0]  p_act,          // shows on this line (set at its start)
    output wire [15:0] p_lb,           // 8 x 2: log2 bits per pixel (1-3)
    output wire [127:0] p_xstep,       // 8 x 16: XSTEP, limited (5.11 source pixels per screen pixel)
    output wire [15:0] p_depth,
    output wire [31:0] p_pal,
    output wire [7:0]  p_dma,          // fed by the DMA

    // The FIFOs, between the domains
    input  wire [39:0] fifo_ra,        // 8 x 5: read addresses (pixel side)
    output wire [127:0] fifo_rd,       // 8 x 16: the words there
    output wire [47:0] wp_g,           // 8 x 6: write pointers, Gray-coded
    input  wire [47:0] rp,             // 8 x 6: read pointers, as sprite_pix registers them (pixel clock)
    output wire [7:0]  flush_t,
    input  wire [7:0]  flush_ack_t,

    // Collisions found on a line (pixel side, stable when coll_t toggles)
    input  wire [31:0] coll_line,
    input  wire        coll_t
);
    function [1:0] bppc(input [1:0] b);        // BPP 3 is taken as 8 bits
        bppc = (b == 2'd3) ? 2'd2 : b;
    endfunction

    // ================================================================ registers
    reg  [7:0]  sprdma, sprdma_w;
    wire [31:0] coll;
    // SPRxH, SPRxV, SPRxCTL, SPRxSTEP as written, in distributed RAM (one
    // write a clock: a register write, or clearing one a clock during reset)
    reg  [21:0] m_h [0:7];                     // HSTOP (21-11), HSTART (10-0)
    reg  [21:0] m_v [0:7];                     // VSTOP (21-11), VSTART (10-0)
    reg  [7:0]  m_c [0:7];                     // PAL 7-4, DEPTH 3-2, BPP 1-0
    reg  [31:0] m_s [0:7];                     // YSTEP 31-16, XSTEP 15-0

    // The sprite registers: custom 0x010-0x08F, sprite n's 16 bytes at 0x010 + n x 0x10
    wire [3:0]  sp4   = rb_addr[7:4] - 4'd1;
    wire        sel_s = (rb_addr[12:8] == 5'h10) && (rb_addr[7:4] != 4'd0) && (rb_addr[7:4] <= 4'd8)
                        && ({28'd0, sp4} < NS);
    wire [2:0]  sn    = sp4[2:0];
    wire [3:0]  so    = rb_addr[3:0];
    wire        sel_g = (rb_addr == `RM_SPRDMA0) || (rb_addr == `RM_SPRDMA1) ||
                        (rb_addr >= `RM_SPRCOLL0 && rb_addr <= `RM_SPRCOLL3);

    wire        w_ctl = rb_wr && sel_s && so == 4'hB;
    wire        w_pt  = rb_wr && sel_s && so <= 4'h2;
    wire [2:0]  cs;                            // the sprite whose settings the core takes
    wire [21:0] lst;                           // sprite sn's line start
    // a PT write: the new line start, by bytes (bit 0 is 0: lines are words)
    wire [21:0] lst_new = (so == 4'h0) ? {lst[21:8], rb_wdata[7:1], 1'b0} :
                          (so == 4'h1) ? {lst[21:16], rb_wdata, lst[7:0]} :
                                         {rb_wdata[5:0], lst[15:0]};
    // SPRCOLL0-3: write 1 to clear, by byte
    wire [31:0] coll_clr = (rb_wr && rb_addr >= `RM_SPRCOLL0 && rb_addr <= `RM_SPRCOLL3)
                           ? ({24'd0, rb_wdata} << {rb_addr[1:0], 3'b000}) : 32'd0;

    sprite_fetch #(.NS(NS), .PW(22), .AW(21), .LITTLE(1), .URGENT(6), .MANUAL(0)) core (
        .clk(clk), .rst(rst),
        .set_sel(cs),
        .set_hstart(m_h[cs][10:0]), .set_hstop(m_h[cs][21:11]),
        .set_vstart(m_v[cs][10:0]), .set_vstop(m_v[cs][21:11]),
        .set_bpp(bppc(m_c[cs][1:0])), .set_depth(m_c[cs][3:2]), .set_pal(m_c[cs][7:4]),
        .set_xstep(m_s[cs][15:0]), .set_ystep(m_s[cs][31:16]),
        .dma_on(dma_on), .dma_mask(sprdma),
        .start(w_ctl ? (8'd1 << sn) : 8'd0),
        .sel(sn), .lst_cur(lst), .lst_wr(w_pt), .lst_new(lst_new),
        .fifo_count(), .dat_wr(1'b0), .dat(16'd0),
        .vblank(vblank), .beam_v(beam_v), .beam_h(beam_h),
        .mem_req(mem_req), .mem_addr(mem_addr), .mem_urgent(mem_urgent),
        .mem_ack(mem_ack), .mem_rvalid(mem_rvalid), .mem_rdata(mem_rdata),
        .p_hs(p_hs), .p_xe(p_xe), .p_act(p_act), .p_lb(p_lb), .p_xstep(p_xstep),
        .p_depth(p_depth), .p_pal(p_pal), .p_dma(p_dma),
        .fifo_ra(fifo_ra), .fifo_rd(fifo_rd), .wp_g(wp_g), .rp(rp),
        .flush_t(flush_t), .flush_ack_t(flush_ack_t),
        .coll_line(coll_line), .coll_t(coll_t), .coll_clr(coll_clr), .coll(coll)
    );

    // ================================================================ the RAMs
    // The registers: each byte written directly, the others kept
    wire [2:0]  ra  = rst ? cs : sn;
    always @(posedge clk) begin
        if (rst || (rb_wr && sel_s && so >= 4'h3 && so <= 4'h6))
            m_h[ra] <= rst ? 22'd0 :
                       (so == 4'h3) ? {m_h[sn][21:8], rb_wdata} :
                       (so == 4'h4) ? {m_h[sn][21:11], rb_wdata[2:0], m_h[sn][7:0]} :
                       (so == 4'h5) ? {m_h[sn][21:19], rb_wdata, m_h[sn][10:0]} :
                                      {rb_wdata[2:0], m_h[sn][18:0]};
        if (rst || (rb_wr && sel_s && so >= 4'h7 && so <= 4'hA))
            m_v[ra] <= rst ? 22'd0 :
                       (so == 4'h7) ? {m_v[sn][21:8], rb_wdata} :
                       (so == 4'h8) ? {m_v[sn][21:11], rb_wdata[2:0], m_v[sn][7:0]} :
                       (so == 4'h9) ? {m_v[sn][21:19], rb_wdata, m_v[sn][10:0]} :
                                      {rb_wdata[2:0], m_v[sn][18:0]};
        if (rst || w_ctl)
            m_c[ra] <= rst ? 8'd0 : rb_wdata;
        if (rst || (rb_wr && sel_s && so >= 4'hC))
            m_s[ra] <= rst ? 32'd0 :
                       (so == 4'hC) ? {m_s[sn][31:8], rb_wdata} :
                       (so == 4'hD) ? {m_s[sn][31:16], rb_wdata, m_s[sn][7:0]} :
                       (so == 4'hE) ? {m_s[sn][31:24], rb_wdata, m_s[sn][15:0]} :
                                      {rb_wdata, m_s[sn][23:0]};
    end
    integer ii;
    initial for (ii = 0; ii < 8; ii = ii + 1) begin
        m_h[ii] = 22'd0; m_v[ii] = 22'd0; m_c[ii] = 8'd0; m_s[ii] = 32'd0;
    end

    // ================================================================ SPRDMA and the reads
    always @(posedge clk) begin
        if (rst) begin
            sprdma   <= 8'hFF;
            sprdma_w <= 8'd0;
        end else begin
            // byte 0 holds the bits, writing byte 1 sets or clears them
            if (rb_wr && rb_addr == `RM_SPRDMA0) sprdma_w <= rb_wdata;
            if (rb_wr && rb_addr == `RM_SPRDMA1) begin
                if (rb_wdata[7]) sprdma <= sprdma |  sprdma_w;
                else             sprdma <= sprdma & ~sprdma_w;
            end
        end

        // ---- reads (1 clock)
        rb_rdata <= 8'd0;
        rb_hit   <= rb_rd && (sel_s || sel_g);
        rb_cdata <= 32'd0;
        rb_cap   <= 1'b0;
        if (rb_rd && sel_g) case (rb_addr[2:0])
            3'd0:    rb_rdata <= sprdma;
            3'd4:    rb_rdata <= coll[7:0];
            3'd5:    rb_rdata <= coll[15:8];
            3'd6:    rb_rdata <= coll[23:16];
            3'd7:    rb_rdata <= coll[31:24];
            default: rb_rdata <= 8'd0;         // SPRDMA1
        endcase
        if (rb_rd && sel_s) case (so)
            4'h0: begin
                rb_rdata <= lst[7:0];
                rb_cdata <= {10'd0, lst};
                rb_cap   <= 1'b1;
            end
            4'h1: rb_rdata <= lst[15:8];
            4'h2: rb_rdata <= {2'd0, lst[21:16]};
            4'h3: rb_rdata <= m_h[sn][7:0];
            4'h4: rb_rdata <= {5'd0, m_h[sn][10:8]};
            4'h5: rb_rdata <= m_h[sn][18:11];
            4'h6: rb_rdata <= {5'd0, m_h[sn][21:19]};
            4'h7: rb_rdata <= m_v[sn][7:0];
            4'h8: rb_rdata <= {5'd0, m_v[sn][10:8]};
            4'h9: rb_rdata <= m_v[sn][18:11];
            4'hA: rb_rdata <= {5'd0, m_v[sn][21:19]};
            4'hB: rb_rdata <= m_c[sn];
            4'hC: rb_rdata <= m_s[sn][7:0];
            4'hD: rb_rdata <= m_s[sn][15:8];
            4'hE: rb_rdata <= m_s[sn][23:16];
            default: rb_rdata <= m_s[sn][31:24];
        endcase
    end

endmodule
