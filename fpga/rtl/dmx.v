// The blitter (spec 14) and the rasteriser (spec 19): the registers on the
// 8-bit register bus; the work is retro-hw's blitter and raster cores
// (fpga/retro-hw/docs/spec/blitter.md and raster.md), shared with retro68k.
//
// Kept here, as retro68k's dmx.v narrowed to bytes, for the blitter:
//   - the job registers: eight 4-byte words laid out as a descriptor
//     (custom 0x140-0x15F, low byte first), wired straight to the core's
//     job ports. The CPU or the copper writes them a byte at a time while
//     no job runs; a descriptor the core loads from SRAM is stored into
//     them a word at a time. Reserved bits are not stored and read 0.
//   - BLTDESC (read through the capture), BLTCMD, BLTSTAT
// and the same for the rasteriser (custom 0x180-0x1A8), with its clip
// window (RASCLIPMIN, RASCLIPMAX), shared by every job. DMXINT and DMXINTEN
// are shared. Each core has its own memory port (requesters 5 and 6 of the
// scheduler), so both can run at once.
//
// The SRAM is little-endian (LE 1). MASKIMG 0 leaves the 1 bpp mask image
// out, for the KS2. Addresses above the SRAM are not checked: their high
// bits are ignored.
`include "regmap.vh"

module dmx #(
    parameter MASKIMG = 1,             // 0: no 1 bpp mask image (MASK = 1 is an error); the KS2's build
    parameter TRI     = 1              // 0: the rasteriser draws lines only (a TRI job is an error)
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
    output reg  [31:0] rb_cdata,       // with rb_rdata: BLTDESC whole, for the capture
    output reg         rb_cap,

    // Memory (dmac.v BLT requester)
    output wire        mem_req,
    output wire        mem_we,
    output wire [21:1] mem_addr,
    output wire [15:0] mem_wdata,
    output wire [1:0]  mem_be,
    input  wire        mem_ack,
    input  wire        mem_rvalid,
    input  wire [15:0] mem_rdata,

    // Memory (dmac.v RAS requester); read data is mem_rdata
    output wire        ras_req,
    output wire        ras_we,
    output wire [21:1] ras_addr,
    output wire [15:0] ras_wdata,
    output wire [1:0]  ras_be,
    input  wire        ras_ack,
    input  wire        ras_rvalid,

    input  wire        blt_on,         // DMACON.DMAEN and BLTEN
    output wire        idle,           // no job running in either (the copper's WAIT B)
    output wire        irq             // BLT or RAS (interrupt source 4)
);
    // ================================================================ register decode
    wire        in_c   = rb_addr[12:10] == 3'b100;              // the custom block
    wire [9:0]  off    = rb_addr[9:0];
    wire        sel_jr = in_c && off[9:5] == 5'b01010;           // 0x140-0x15F
    wire [2:0]  ri     = off[4:2];
    wire [1:0]  bi     = off[1:0];
    wire        sel_ds = in_c && off >= 10'h160 && off <= 10'h162;
    wire        sel_cmd  = rb_addr == `RM_BLTCMD;
    wire        sel_stat = rb_addr == `RM_BLTSTAT;
    wire        sel_rj = in_c && off[9:5] == 5'b01100;           // 0x180-0x19F
    wire        sel_rd = in_c && off >= 10'h1A0 && off <= 10'h1A2;
    wire        sel_rcmd  = rb_addr == `RM_RASCMD;
    wire        sel_rstat = rb_addr == `RM_RASSTAT;
    wire        sel_clip  = in_c && off >= 10'h1AC && off <= 10'h1B3;
    wire        sel_int  = rb_addr == `RM_DMXINT;
    wire        sel_inten = rb_addr == `RM_DMXINTEN;

    // The bits each job word holds (spec 14, section 3); the rest are reserved
    function [31:0] used(input [2:0] i);
        case (i)
            3'd0:              used = 32'hFF06_37FF;   // KEY BPP RTL IRQ BCONST MASK MINTERM
            3'd1, 3'd2, 3'd4:  used = 32'h07FF_FFFF;   // ADDR BIT
            3'd7:              used = 32'h00FF_FFFF;   // ADDR
            default:           used = 32'hFFFF_FFFF;   // SIZE, STRIDE, VALUE
        endcase
    endfunction

    // The rasteriser's: RASCTRL keeps its reserved bits (one set is an error,
    // as retro68k), though they read 0
    function [31:0] r_used(input [2:0] i);
        case (i)
            3'd0:       r_used = 32'hFF03_13FF;         // VALUE BPP IRQ TRI NOLAST MINTERM
            3'd4, 3'd7: r_used = 32'h00FF_FFFF;         // ADDR
            3'd5, 3'd6: r_used = 32'h0000_FFFF;         // DSTRIDE, PATTERN
            default:    r_used = 32'hFFFF_FFFF;         // the points
        endcase
    endfunction
    function [31:0] r_kept(input [2:0] i);
        r_kept = (i == 3'd0) ? 32'hFFFF_FFFF : r_used(i);
    endfunction

    // ================================================================ the blitter
    wire        busy, done, err;
    wire [23:0] da_q;
    wire        dl_v;
    wire [2:0]  dl_i;
    wire [15:0] dl_w0, dl_w1;

    // The job registers. Written by the CPU or the copper while no job runs,
    // and by a descriptor load (only while one does). A loaded word is
    // little-endian: the first (lower) memory word is bits 15-0.
    reg  [31:0] jr [0:7];
    wire [31:0] w_used = used(ri);
    integer k;
    initial for (k = 0; k < 8; k = k + 1) jr[k] = 32'd0;
    always @(posedge clk) begin
        if (dl_v)
            jr[dl_i] <= {dl_w1, dl_w0} & used(dl_i);
        else if (rb_wr && sel_jr && !busy)
            jr[ri][8*bi +: 8] <= rb_wdata & w_used[8*bi +: 8];
    end

    // BLTCMD's strobes; BLTDESC a byte at a time (the core takes it only while idle)
    wire        w_cmd  = rb_wr && sel_cmd;
    wire [23:0] desc_v = {off[1:0] == 2'd2 ? rb_wdata : da_q[23:16],
                          off[1:0] == 2'd1 ? rb_wdata : da_q[15:8],
                          off[1:0] == 2'd0 ? rb_wdata : da_q[7:0]};

    // ================================================================ the rasteriser
    wire        r_busy, r_done, r_err;
    wire [23:0] r_da_q;
    wire        r_dl_v;
    wire [2:0]  r_dl_i;
    wire [15:0] r_dl_w0, r_dl_w1;

    reg  [31:0] rj [0:7];
    wire [31:0] w_rkept = r_kept(ri);
    wire [31:0] w_rused = r_used(ri);
    initial for (k = 0; k < 8; k = k + 1) rj[k] = 32'd0;
    always @(posedge clk) begin
        if (r_dl_v)
            rj[r_dl_i] <= {r_dl_w1, r_dl_w0} & r_kept(r_dl_i);
        else if (rb_wr && sel_rj && !r_busy)
            rj[ri][8*bi +: 8] <= rb_wdata & w_rkept[8*bi +: 8];
    end
    // A reserved bit of RASCTRL set: a blitter descriptor given to the
    // rasteriser by mistake, or a job for a later version
    wire        r_bad = |(rj[0] & ~r_used(3'd0));

    // The clip window, shared by every job (not in a descriptor): YMIN, XMIN
    // at RASCLIPMIN, YMAX, XMAX at RASCLIPMAX, inclusive. Held while a job runs
    reg  [7:0]  clip [0:7];
    initial for (k = 0; k < 8; k = k + 1) clip[k] = 8'd0;
    wire [2:0]  ci = off[2:0] - 3'd4;                  // 0x1AC-0x1B3: bytes 0-7
    always @(posedge clk) if (rb_wr && sel_clip && !r_busy) clip[ci] <= rb_wdata;
    wire [15:0] c_ymin = {clip[1], clip[0]}, c_xmin = {clip[3], clip[2]};
    wire [15:0] c_ymax = {clip[5], clip[4]}, c_xmax = {clip[7], clip[6]};

    wire        w_rcmd  = rb_wr && sel_rcmd;
    wire [23:0] rdesc_v = {off[1:0] == 2'd2 ? rb_wdata : r_da_q[23:16],
                           off[1:0] == 2'd1 ? rb_wdata : r_da_q[15:8],
                           off[1:0] == 2'd0 ? rb_wdata : r_da_q[7:0]};

    // ================================================================ shared
    // DMXINT (BLT, RAS): set by each core's done; a flag due in the clock a
    // write of 1 clears it stays set, so a new interrupt is never lost
    reg  [1:0]  dint, dinten;
    assign irq  = |(dint & dinten);
    assign idle = !busy && !r_busy;
    always @(posedge clk) begin
        if (rst) begin
            dint <= 2'b00;  dinten <= 2'b00;
        end else begin
            dint <= (dint & ~((rb_wr && sel_int) ? rb_wdata[1:0] : 2'b00)) | {r_done, done};
            if (rb_wr && sel_inten) dinten <= rb_wdata[1:0];
        end
    end

    // Reads: the clock after the strobe. Reading BLTDESC's low byte hands all
    // three to the capture (spec 3, rule 4).
    always @(posedge clk) begin
        rb_rdata <= 8'd0;
        rb_hit   <= 1'b0;
        rb_cdata <= 32'd0;
        rb_cap   <= 1'b0;
        if (rb_rd) begin
            if (sel_jr) begin
                rb_hit <= 1'b1;  rb_rdata <= jr[ri][8*bi +: 8];
            end else if (sel_ds) begin
                rb_hit   <= 1'b1;
                rb_rdata <= da_q[8*off[1:0] +: 8];
                if (off[1:0] == 2'd0) begin
                    rb_cdata <= {8'd0, da_q};
                    rb_cap   <= 1'b1;
                end
            end else if (sel_rj) begin
                rb_hit <= 1'b1;  rb_rdata <= rj[ri][8*bi +: 8] & w_rused[8*bi +: 8];
            end else if (sel_rd) begin
                rb_hit   <= 1'b1;
                rb_rdata <= r_da_q[8*off[1:0] +: 8];
                if (off[1:0] == 2'd0) begin
                    rb_cdata <= {8'd0, r_da_q};
                    rb_cap   <= 1'b1;
                end
            end else if (sel_clip) begin
                rb_hit <= 1'b1;  rb_rdata <= clip[ci];
            end else if (sel_cmd || sel_rcmd) begin
                rb_hit <= 1'b1;                              // write only: reads 0
            end else if (sel_stat) begin
                rb_hit <= 1'b1;  rb_rdata <= {5'd0, err, 1'b0, busy};
            end else if (sel_rstat) begin
                rb_hit <= 1'b1;  rb_rdata <= {5'd0, r_err, 1'b0, r_busy};
            end else if (sel_int) begin
                rb_hit <= 1'b1;  rb_rdata <= {6'd0, dint};
            end else if (sel_inten) begin
                rb_hit <= 1'b1;  rb_rdata <= {6'd0, dinten};
            end
        end
    end

    blitter #(.AW(21), .LE(1), .MASKIMG(MASKIMG)) core (
        .clk(clk), .rst(rst),
        .enable(blt_on),
        .start_ld(w_cmd && rb_wdata[`RM_BLTCMD_START]),
        .start_run(w_cmd && rb_wdata[`RM_BLTCMD_RUN] && !rb_wdata[`RM_BLTCMD_START]),
        .stop(w_cmd && rb_wdata[`RM_BLTCMD_STOP]),
        .da_we(rb_wr && sel_ds), .da_d(desc_v), .da_q(da_q),
        .busy(busy), .done(done), .err(err),
        .su_v(), .su_i(),
        .job_minterm(jr[0][`RM_BLTCTRL_MINTERM]), .job_mask(jr[0][`RM_BLTCTRL_MASK]),
        .job_bpp(jr[0][`RM_BLTCTRL_BPP]), .job_rtl(jr[0][`RM_BLTCTRL_RTL]),
        .job_bconst(jr[0][`RM_BLTCTRL_BCONST]), .job_irq(jr[0][`RM_BLTCTRL_IRQ]),
        .job_value(jr[6][`RM_BLTVALUE_VALUE]), .job_key(jr[0][`RM_BLTCTRL_KEY]),
        .job_astride(jr[6][`RM_BLTVALUE_ASTRIDE]),
        .job_bstride(jr[5][`RM_BLTSTRIDE_BSTRIDE]), .job_dstride(jr[5][`RM_BLTSTRIDE_DSTRIDE]),
        .job_width(jr[3][`RM_BLTSIZE_WIDTH]), .job_height(jr[3][`RM_BLTSIZE_HEIGHT]),
        .job_aaddr(jr[4][`RM_BLTAPT_ADDR]), .job_baddr(jr[1][`RM_BLTBPT_ADDR]), .job_daddr(jr[2][`RM_BLTDPT_ADDR]),
        .job_abit(jr[4][`RM_BLTAPT_BIT]), .job_bbit(jr[1][`RM_BLTBPT_BIT]), .job_dbit(jr[2][`RM_BLTDPT_BIT]),
        .job_next(jr[7][`RM_BLTNEXT_ADDR]), .job_bad(1'b0),
        .dl_v(dl_v), .dl_i(dl_i), .dl_w0(dl_w0), .dl_w1(dl_w1), .dl_wait(1'b0),
        .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_be(mem_be),
        .mem_ack(mem_ack), .mem_rvalid(mem_rvalid), .mem_rdata(mem_rdata)
    );

    raster #(.AW(21), .LE(1), .TRI(TRI)) rcore (
        .clk(clk), .rst(rst),
        .enable(blt_on),
        .start_ld(w_rcmd && rb_wdata[`RM_RASCMD_START]),
        .start_run(w_rcmd && rb_wdata[`RM_RASCMD_RUN] && !rb_wdata[`RM_RASCMD_START]),
        .stop(w_rcmd && rb_wdata[`RM_RASCMD_STOP]),
        .da_we(rb_wr && sel_rd), .da_d(rdesc_v), .da_q(r_da_q),
        .busy(r_busy), .done(r_done), .err(r_err),
        .su_v(), .su_i(),
        .job_tri(rj[0][`RM_RASCTRL_TRI]), .job_minterm(rj[0][`RM_RASCTRL_MINTERM]),
        .job_bpp(rj[0][`RM_RASCTRL_BPP]), .job_value(rj[0][`RM_RASCTRL_VALUE]),
        .job_pattern(rj[6][`RM_RASPAT_PATTERN]), .job_nolast(rj[0][`RM_RASCTRL_NOLAST]),
        .job_irq(rj[0][`RM_RASCTRL_IRQ]),
        .job_x0(rj[1][`RM_RASP0_X]), .job_y0(rj[1][`RM_RASP0_Y]),
        .job_x1(rj[2][`RM_RASP1_X]), .job_y1(rj[2][`RM_RASP1_Y]),
        .job_x2(rj[3][`RM_RASP2_X]), .job_y2(rj[3][`RM_RASP2_Y]),
        .job_daddr(rj[4][`RM_RASDPT_ADDR]), .job_dstride(rj[5][`RM_RASSTRIDE_DSTRIDE]),
        .clip_xmin(c_xmin), .clip_xmax(c_xmax), .clip_ymin(c_ymin), .clip_ymax(c_ymax),
        .job_next(rj[7][`RM_RASNEXT_ADDR]), .job_bad(r_bad),
        .dl_v(r_dl_v), .dl_i(r_dl_i), .dl_w0(r_dl_w0), .dl_w1(r_dl_w1), .dl_wait(1'b0),
        .mem_req(ras_req), .mem_we(ras_we), .mem_addr(ras_addr), .mem_wdata(ras_wdata), .mem_be(ras_be),
        .mem_ack(ras_ack), .mem_rvalid(ras_rvalid), .mem_rdata(mem_rdata)
    );
endmodule
