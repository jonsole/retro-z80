// DMA engine and blitter (spec 14). 100 MHz. The registers on the 8-bit
// register bus; the engine itself is retro-hw's dmx_core.v (the channels,
// the scheduler and the datapath), shared with retro68k.
//
// This wrapper keeps spec 14's register side:
//   - the job registers, laid out as the 32-byte descriptor (custom
//     0x140-0x23F, channel n at 0x140 + n x 0x40), in four byte-lane RAMs;
//     written by the CPU or copper a byte at a time, or by a descriptor
//     load a long word at a time
//   - the decode of the running channel's job onto the core's job ports,
//     a long word a clock while the core sets the job up
//   - CHDESC (read through the capture), CHCTRL, CHSTAT, CHERR, DMXINT,
//     DMXINTEN and LINE's clip rectangle
//   - the checks spec 14 adds: a non-zero CTRL2 is an error
//
// The core runs with the SRAM little-endian (LE), physical addresses, SRAM
// only (no other port), no port jobs. MASKIMG = 0 leaves the mask image
// out (about 400 LUTs), for the KS2.
`include "regmap.vh"

module dmx #(
    parameter [5:0] CHIPMB = 6'd4,     // SRAM size: addresses past it are an error
    parameter       MASKIMG = 1        // 0: no 1 bpp mask image (MASK = 1 is an error); the KS2's build
) (
    input  wire        clk,
    input  wire        rst,

    // The register bus (as every unit sees it: the CPU's and the copper's writes)
    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [12:0] rb_addr,
    input  wire [7:0]  rb_wdata,
    output reg  [7:0]  rb_rdata,
    output reg         rb_hit,
    output reg  [31:0] rb_cdata,       // with rb_rdata: CHDESC whole, for the capture
    output reg         rb_cap,

    // Memory (dmac.v BLT channel)
    output wire        mem_req,
    output wire        mem_we,
    output wire [21:1] mem_addr,
    output wire [15:0] mem_wdata,
    output wire [1:0]  mem_be,
    input  wire        mem_ack,
    input  wire        mem_rvalid,
    input  wire [15:0] mem_rdata,

    input  wire [3:0]  tmr_start,      // a timer starts channel n, as a START (spec 9)
    input  wire        blt_on,         // DMACON.DMAEN and BLTEN
    output wire        idle,           // no channel busy (the copper's WAIT B)
    output wire [3:0]  irq             // DMA0-DMA3
);
    // ================================================================ register decode
    // Custom offsets 0x140-0x23F: channel n at 0x140 + n x 0x40
    wire        in_dmx = rb_addr[12:10] == 3'b100 && rb_addr[9:0] >= 10'h140 && rb_addr[9:0] <= 10'h23F;
    wire [9:0]  rel    = rb_addr[9:0] - 10'h140;
    wire [1:0]  rch    = rel[7:6];
    wire [5:0]  ro     = rel[5:0];
    wire        sel_jr    = in_dmx && ro < 6'h1F;               // the job registers (+0x1F reserved)
    wire        sel_cd    = in_dmx && ro >= 6'h20 && ro <= 6'h22;
    wire        sel_ctl   = in_dmx && ro == 6'h24;
    wire        sel_stat  = in_dmx && ro == 6'h28;
    wire        sel_err   = in_dmx && ro >= 6'h2C && ro <= 6'h2E;
    wire        sel_int   = rb_addr == `RM_DMXINT;
    wire        sel_inten = rb_addr == `RM_DMXINTEN;
    wire        sel_clip  = in_dmx && rch == 2'd3 && ro >= 6'h38;   // 0x238-0x23F

    // ================================================================ the core
    wire [3:0]  busy, done, err, irq_set;
    wire [95:0] da_q, ea_q;
    wire [1:0]  cur;
    wire        su_v;
    wire [2:0]  su_i;
    wire        dl_v;
    wire [2:0]  dl_i;
    wire [15:0] dl_w0, dl_w1;
    reg  [3:0]  pause, dint, dinten;
    reg  [15:0] clip [0:3];            // XMIN, XMAX, YMIN, YMAX: signed, inclusive
    wire [1:0]  clip_i = ro[2:1];
    assign irq  = dint & dinten;

    // The running channel's job, decoded from its job registers (below)
    reg  [2:0]  j_op;
    reg  [7:0]  j_mt;
    reg  [1:0]  j_as;                  // ADD: SIGNED, SAT
    reg  [1:0]  j_mask, j_lb;
    reg         j_desc, j_irq, j_bc, j_c2, j_ymaj, j_xneg, j_yneg;
    reg  [31:0] j_val;
    reg  [15:0] j_sstr, j_dstr, j_height;
    reg  [23:0] j_width, j_apt, j_bpt, j_dpt, j_next;
    reg  [2:0]  j_abit, j_sbit, j_dbit;

    // Register strobes for the core's channel state
    wire        w_ctl  = rb_wr && sel_ctl;
    wire        w_stat = rb_wr && sel_stat;
    wire [3:0]  ch1    = 4'd1 << rch;
    wire [3:0]  cpu_ld  = (w_ctl && rb_wdata[0]) ? ch1 : 4'd0;
    wire [3:0]  cpu_run = (w_ctl && rb_wdata[1] && !rb_wdata[0]) ? ch1 : 4'd0;
    // CHDESC: a byte at a time (the core takes it only while the channel is idle)
    wire [23:0] cd_old  = da_q[24*rch +: 24];
    wire [23:0] cd_new  = {ro[1:0] == 2'd2 ? rb_wdata : cd_old[23:16],
                           ro[1:0] == 2'd1 ? rb_wdata : cd_old[15:8],
                           ro[1:0] == 2'd0 ? rb_wdata : cd_old[7:0]};

    wire        eng_jw_set;
    reg         eng_jw;

    dmx_core #(.CHIP_WORDS({CHIPMB[4:0], 19'd0}), .LE(1), .MASKIMG(MASKIMG), .XPORT(0), .PORTJOB(0)) core (
        .clk(clk), .rst(rst),
        .enable(blt_on), .pause(pause),
        .start_ld(tmr_start | cpu_ld), .start_run(cpu_run & ~tmr_start),
        .stop((w_ctl && rb_wdata[2]) ? ch1 : 4'd0),
        .clr_done((w_stat && rb_wdata[1]) ? ch1 : 4'd0),
        .clr_err((w_stat && rb_wdata[2]) ? ch1 : 4'd0),
        .da_we((rb_wr && sel_cd) ? ch1 : 4'd0), .da_d(cd_new),
        .busy(busy), .done(done), .err(err), .da_q(da_q), .ea_q(ea_q),
        .irq_set(irq_set), .idle(idle), .cur(cur),
        .su_v(su_v), .su_i(su_i),
        .job_op(j_op), .job_minterm(j_mt), .job_sat(j_as[0]), .job_signed(j_as[1]),
        .job_mask(j_mask), .job_bpp(j_lb), .job_desc(j_desc), .job_irq(j_irq), .job_bconst(j_bc),
        .job_ymaj(j_ymaj), .job_xneg(j_xneg), .job_yneg(j_yneg),
        .job_value(j_val), .job_bstride(j_sstr), .job_dstride(j_dstr),
        .job_width(j_width), .job_height(j_height),
        .job_aaddr(j_apt), .job_baddr(j_bpt), .job_daddr(j_dpt),
        .job_abit(j_abit), .job_bbit(j_sbit), .job_dbit(j_dbit), .job_next(j_next),
        .job_bport(1'b0), .job_dport(1'b0), .job_bad(j_c2),
        .clip_xmin(clip[0]), .clip_xmax(clip[1]), .clip_ymin(clip[2]), .clip_ymax(clip[3]),
        .dl_xok(1'b0), .dl_v(dl_v), .dl_i(dl_i), .dl_w0(dl_w0), .dl_w1(dl_w1), .dl_wait(eng_jw),
        .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_be(mem_be),
        .mem_ack(mem_ack), .mem_rvalid(mem_rvalid), .mem_rdata(mem_rdata),
        .acc_a(), .acc_we(), .xp_ok(1'b0),
        .xp_req(), .xp_we(), .xp_addr(), .xp_wdata(), .xp_be(),
        .xp_ack(1'b0), .xp_rvalid(1'b0), .xp_rdata(16'd0),
        .p_rxv(1'b0), .p_rxd(8'd0), .p_rxpop(), .p_txr(1'b0), .p_txpush(), .p_txd()
    );
    assign eng_jw_set = dl_v;

    // ================================================================ job registers
    // 4 channels x 8 long words, a RAM per byte lane, in distributed RAM.
    // Byte 4i + k of a channel's job is lane k of long word i. Written by the
    // CPU or copper a byte at a time (channel not busy) or by a descriptor
    // load a long word at a time (the even byte, at the lower address, in
    // bits 7-0); one write a clock, the register bus first (the load's write
    // waits; a long word comes at most every 4 clocks, and the bus is never
    // busy for 4 clocks running).
    reg  [7:0]  jr0 [0:31];
    reg  [7:0]  jr1 [0:31];
    reg  [7:0]  jr2 [0:31];
    reg  [7:0]  jr3 [0:31];
    wire [4:0]  cpu_ja  = {rch, ro[4:2]};
    wire        cpu_jw  = rb_wr && sel_jr && !busy[rch];
    reg  [4:0]  eng_ja;
    reg  [31:0] eng_jd;
    integer k;
    initial for (k = 0; k < 32; k = k + 1) begin jr0[k] = 8'd0; jr1[k] = 8'd0; jr2[k] = 8'd0; jr3[k] = 8'd0; end
    always @(posedge clk) begin
        if (cpu_jw) begin
            if (ro[1:0] == 2'd0) jr0[cpu_ja] <= rb_wdata;
            if (ro[1:0] == 2'd1) jr1[cpu_ja] <= rb_wdata;
            if (ro[1:0] == 2'd2) jr2[cpu_ja] <= rb_wdata;
            if (ro[1:0] == 2'd3) jr3[cpu_ja] <= rb_wdata;
        end else if (eng_jw) begin
            jr0[eng_ja] <= eng_jd[7:0];
            jr1[eng_ja] <= eng_jd[15:8];
            jr2[eng_ja] <= eng_jd[23:16];
            jr3[eng_ja] <= eng_jd[31:24];
        end
    end
    wire [7:0]  jr_byte = (ro[1:0] == 2'd0) ? jr0[cpu_ja] : (ro[1:0] == 2'd1) ? jr1[cpu_ja] :
                          (ro[1:0] == 2'd2) ? jr2[cpu_ja] : jr3[cpu_ja];
    // A loaded long word waits for a clock the bus leaves
    always @(posedge clk) begin
        if (rst)
            eng_jw <= 1'b0;
        else if (eng_jw_set) begin
            eng_jw <= 1'b1;
            eng_ja <= {cur, dl_i};
            eng_jd <= {dl_w1, dl_w0};
        end else if (eng_jw && !cpu_jw)
            eng_jw <= 1'b0;
    end

    // The running channel's job, a long word a clock as the core sets it up
    // (spec 14, section 3); bit 23 of each address is not used
    always @(posedge clk) if (su_v) begin : setup
        reg [31:0] v;
        v = {jr3[{cur, su_i}], jr2[{cur, su_i}], jr1[{cur, su_i}], jr0[{cur, su_i}]};
        case (su_i)
            3'd0: begin j_op <= v[2:0]; j_as <= v[5:4]; j_lb <= v[9:8]; j_desc <= v[10];
                        j_ymaj <= v[3]; j_xneg <= v[6]; j_yneg <= v[7];
                        j_irq <= v[11]; j_bc <= v[12]; j_mask <= v[14:13];
                        j_c2 <= (v[23:16] != 8'd0); j_mt <= v[31:24]; end
            3'd1: begin j_apt <= {1'b0, v[22:0]}; j_bpt[7:0] <= v[31:24]; end
            3'd2: begin j_bpt[23:8] <= {1'b0, v[14:0]}; j_dpt[15:0] <= v[31:16]; end
            3'd3: begin j_dpt[23:16] <= {1'b0, v[6:0]}; j_width <= v[31:8]; end
            3'd4: begin j_height <= v[15:0]; j_abit <= v[18:16]; j_sbit <= v[22:20];
                        j_dbit <= v[26:24]; end
            3'd5: begin j_sstr <= v[15:0]; j_dstr <= v[31:16]; end
            3'd6: j_val  <= v;
            default: j_next <= {1'b0, v[22:0]};
        endcase
    end

    // ================================================================ registers
    // Reads: the clock after the strobe. Reserved offsets do not answer, so
    // they read 0xFF (spec 3, rule 11). Reading CHDESC's first byte hands
    // all three to the capture (spec 3, rule 4).
    always @(posedge clk) begin
        rb_rdata <= 8'd0;
        rb_hit   <= 1'b0;
        rb_cdata <= 32'd0;
        rb_cap   <= 1'b0;
        if (rb_rd) begin
            if (sel_int) begin
                rb_hit <= 1'b1; rb_rdata <= {4'd0, dint};
            end else if (sel_inten) begin
                rb_hit <= 1'b1; rb_rdata <= {4'd0, dinten};
            end else if (sel_clip) begin
                rb_hit <= 1'b1; rb_rdata <= ro[0] ? clip[clip_i][15:8] : clip[clip_i][7:0];
            end else if (sel_jr) begin
                rb_hit <= 1'b1; rb_rdata <= jr_byte;
            end else if (sel_cd) begin
                rb_hit <= 1'b1;
                rb_rdata <= cd_old[8*ro[1:0] +: 8];
                if (ro[1:0] == 2'd0) begin
                    rb_cdata <= {8'd0, cd_old};
                    rb_cap   <= 1'b1;
                end
            end else if (sel_ctl) begin
                rb_hit <= 1'b1; rb_rdata <= {4'd0, pause[rch], 3'd0};
            end else if (sel_stat) begin
                rb_hit <= 1'b1; rb_rdata <= {4'd0, busy[rch] && pause[rch], err[rch], done[rch], busy[rch]};
            end else if (sel_err) begin
                rb_hit <= 1'b1; rb_rdata <= ea_q[24*rch + 8*ro[1:0] +: 8];
            end
        end
    end

    // Writes. A DMXINT write in the clock an interrupt comes due loses it.
    always @(posedge clk) begin
        if (rst) begin
            pause <= 4'd0; dint <= 4'd0; dinten <= 4'd0;
            clip[0] <= 16'h8000; clip[1] <= 16'h7FFF; clip[2] <= 16'h8000; clip[3] <= 16'h7FFF;
        end else begin
            if (rb_wr && sel_int) dint <= dint & ~rb_wdata[3:0];
            else                  dint <= dint | irq_set;
            if (rb_wr && sel_inten) dinten <= rb_wdata[3:0];
            if (rb_wr && sel_clip && !sel_int && !sel_inten) begin
                if (ro[0]) clip[clip_i][15:8] <= rb_wdata;
                else       clip[clip_i][7:0]  <= rb_wdata;
            end
            if (w_ctl && !sel_int && !sel_inten && !sel_clip) pause[rch] <= rb_wdata[3];
        end
    end

`ifdef DMX_TRACE
    integer tclk = 0;
    always @(posedge clk) begin
        tclk = tclk + 1;
        if (rb_wr && in_dmx) $display("%0d dmx wr ro %h ch %0d d %h", tclk, ro, rch, rb_wdata);
    end
`endif
endmodule
