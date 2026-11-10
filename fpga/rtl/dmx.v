// The blitter (spec 14): the registers on the 8-bit register bus; the work
// is retro-hw's blitter core (fpga/retro-hw/docs/spec/blitter.md), shared
// with retro68k.
//
// Kept here, as retro68k's dmx.v narrowed to bytes:
//   - the job registers: eight 4-byte words laid out as a descriptor
//     (custom 0x140-0x15F, low byte first), wired straight to the core's
//     job ports. The CPU or the copper writes them a byte at a time while
//     no job runs; a descriptor the core loads from SRAM is stored into
//     them a word at a time. Reserved bits are not stored and read 0.
//   - BLTDESC (read through the capture), BLTCMD, BLTSTAT, DMXINT, DMXINTEN
//
// The SRAM is little-endian (LE 1). MASKIMG 0 leaves the 1 bpp mask image
// out, for the KS2. Addresses above the SRAM are not checked: their high
// bits are ignored.
`include "regmap.vh"

module dmx #(
    parameter MASKIMG = 1              // 0: no 1 bpp mask image (MASK = 1 is an error); the KS2's build
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

    // Memory (dmac.v BLT channel)
    output wire        mem_req,
    output wire        mem_we,
    output wire [21:1] mem_addr,
    output wire [15:0] mem_wdata,
    output wire [1:0]  mem_be,
    input  wire        mem_ack,
    input  wire        mem_rvalid,
    input  wire [15:0] mem_rdata,

    input  wire        blt_on,         // DMACON.DMAEN and BLTEN
    output wire        idle,           // no job running (the copper's WAIT B)
    output wire        irq             // BLT
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

    // ================================================================ the core
    wire        busy, done, err;
    wire [23:0] da_q;
    wire        dl_v;
    wire [2:0]  dl_i;
    wire [15:0] dl_w0, dl_w1;
    assign idle = !busy;

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

    // DMXINT.BLT: set by the core's done; a flag due in the clock a write of
    // 1 clears it stays set, so a new interrupt is never lost
    reg         dint, dinten;
    assign irq = dint && dinten;
    always @(posedge clk) begin
        if (rst) begin
            dint <= 1'b0;  dinten <= 1'b0;
        end else begin
            dint <= (dint && !(rb_wr && sel_int && rb_wdata[`RM_DMXINT_BLT])) || done;
            if (rb_wr && sel_inten) dinten <= rb_wdata[`RM_DMXINTEN_BLT];
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
            end else if (sel_cmd) begin
                rb_hit <= 1'b1;                              // write only: reads 0
            end else if (sel_stat) begin
                rb_hit <= 1'b1;  rb_rdata <= {5'd0, err, 1'b0, busy};
            end else if (sel_int) begin
                rb_hit <= 1'b1;  rb_rdata <= {7'd0, dint};
            end else if (sel_inten) begin
                rb_hit <= 1'b1;  rb_rdata <= {7'd0, dinten};
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
endmodule
