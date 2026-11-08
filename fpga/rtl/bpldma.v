// Layer fetch and the layers' pointer registers (spec 4, sections 4.4, 4.5
// and 5). 100 MHz domain.
//
// Since issue #96, the register wrapper round retro-hw's layer_fetch core
// (fpga/retro-hw/rtl/layer_fetch.v; its spec docs/spec/layer_fetch.md),
// built with TILES, LITTLE, PW 22 and URG_BASE 17. The core holds the fetch:
// the pointers, the line state, the data registers, earliest-deadline layer
// choice, the urgent mark, and the tile mode (map entries one group ahead,
// XFLIP and YFLIP, the 1-bit byte). This file keeps retro-z80's register
// side:
//
// Registers (spec 4, section 6.3), layer n at custom 0x090 + n x 0x20:
//   +0x10-0x11  BPLSTRIDE  signed, even (bit 0 reads 0)
//   +0x14-0x16  BPL0PT     bits 21-1, live (the core's pointer); reading
//                          +0x14 hands the whole pointer to the CPU's
//                          capture in the bus interface (rb_cdata, rb_cap;
//                          spec 3, rule 4)
//   +0x18-0x1A  MAPPT      bits 21-1: the tile map's first entry
//   +0x1C-0x1E  PATPT      bits 21-1: tile 0's first byte
// Each byte is written directly (spec 3, rule 2). A BPL0PT byte is merged
// into the live pointer and written through the core's pointer port, which
// also sets the saved line start and wins over the fetch's own move.
//
// The core takes MAPPT and PATPT at the start of each line; BPLSTRIDE when
// the line's last word is asked for. The other line settings come from
// video.v, loaded once a line.
//
// The ports keep three layers' width whatever NL is; the layers not built
// are never fetched and read 0xFF.
`include "regmap.vh"

module bpldma #(
    parameter NL = 3                   // layers built (1-3): the others' registers read 0xFF and are never fetched
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          enable,       // video on, DMACON.DMAEN and BPLEN

    input  wire          rb_rd,
    input  wire          rb_wr,
    input  wire [12:0]   rb_addr,
    input  wire [7:0]    rb_wdata,
    output reg  [7:0]    rb_rdata,
    output reg           rb_hit,
    output reg  [31:0]   rb_cdata,     // with rb_rdata: BPL0PT whole, for the CPU's capture
    output reg           rb_cap,

    // The next line, from the pixel domain (stable when line_t toggles)
    input  wire          line_t,
    input  wire [2:0]    act,          // the layer shows on the next line
    input  wire [2:0]    adv,          // ... and its pointer moves on after it (last copy of a source line)
    input  wire [5:0]    lbpp,         // log2 of bits per pixel: words per group = 1 << lbpp
    input  wire [5:0]    hscale,       // log2 of the horizontal scale (for the deadlines)
    input  wire [11:0]   wrap,         // CTRL2.WRAP: 0 off, n = the pointer wraps in 2^(n+9) bytes
    input  wire [35:0]   ngroups,      // groups to fetch
    input  wire [2:0]    tile,         // CTRL0.MODE: a tile map
    input  wire [5:0]    mapw,         // CTRL3.MAPW: 32, 64, 128 (3 as 2) entries
    input  wire [29:0]   ty,           // tiles: the map line (10 bits a layer)
    input  wire [20:0]   tcol,         // tiles: the map column of the first group (7 bits a layer)
    output wire          line_go,      // 1 clock: a new line started here
    output wire          line_gen,     // toggles with line_go

    // To and from the pixel domain
    output wire [383:0]  dat,          // 3 layers x 8 data registers x 16 bits, layer 0 register 0 lowest
    output wire [29:0]   attr,         // tiles: the group's {PRI, PAL} for column 1 (9-5) and column 0 (4-0), a layer
    output wire [2:0]    fill_t,
    input  wire [2:0]    take_t,

    // The scheduler's layer requester (dmac.v)
    output wire          req,
    output wire          urgent,       // req must not wait
    output wire [21:1]   addr,
    input  wire          ack,
    input  wire          rvalid,
    input  wire [15:0]   rdata
);
    localparam LW = (NL > 1) ? $clog2(NL) : 1;

    // ---------------------------------------------------------------- registers
    // Layer n at custom 0x090 + n x 0x20 (bus address 0x1090 + ...)
    wire [7:0]  lo  = rb_addr[7:0] - 8'h90;
    wire [1:0]  rn  = lo[6:5];
    wire [4:0]  off = lo[4:0];
    wire        sel = (rb_addr[12:8] == 5'h10) && (rb_addr[7:0] >= 8'h90) && ({1'b0, lo[7:5]} < NL);
    wire        sel_mod = sel && (off == 5'h10 || off == 5'h11);
    wire        sel_pt  = sel && (off == 5'h14 || off == 5'h15 || off == 5'h16);
    wire        sel_map = sel && (off == 5'h18 || off == 5'h19 || off == 5'h1A);
    wire        sel_pat = sel && (off == 5'h1C || off == 5'h1D || off == 5'h1E);

    reg  [15:0] mod   [0:2];        // BPLSTRIDE (bit 0 always 0)
    reg  [21:0] mappt [0:2];        // MAPPT (bit 0 always 0)
    reg  [21:0] patpt [0:2];        // PATPT (bit 0 always 0)

    // BPL0PT: the core's pointer of the layer the bus names. A byte write
    // is merged into its live value
    wire [21:0] pt_live;
    wire        cpu_pw  = rb_wr && sel_pt;
    wire [21:0] cpu_new = (off == 5'h14) ? {pt_live[21:8], rb_wdata[7:1], 1'b0} :
                          (off == 5'h15) ? {pt_live[21:16], rb_wdata, pt_live[7:0]} :
                                           {rb_wdata[5:0], pt_live[15:0]};

    always @(posedge clk) begin : regs
        integer n;
        if (rst) begin
            for (n = 0; n < 3; n = n + 1) begin
                mod[n] <= 16'd0;  mappt[n] <= 22'd0;  patpt[n] <= 22'd0;
            end
        end else begin
            if (rb_wr && sel_mod) begin
                if (off == 5'h10) mod[rn][7:1]  <= rb_wdata[7:1];
                else              mod[rn][15:8] <= rb_wdata;
            end
            if (rb_wr && sel_map) case (off)
                5'h18:   mappt[rn][7:1]   <= rb_wdata[7:1];
                5'h19:   mappt[rn][15:8]  <= rb_wdata;
                default: mappt[rn][21:16] <= rb_wdata[5:0];
            endcase
            if (rb_wr && sel_pat) case (off)
                5'h1C:   patpt[rn][7:1]   <= rb_wdata[7:1];
                5'h1D:   patpt[rn][15:8]  <= rb_wdata;
                default: patpt[rn][21:16] <= rb_wdata[5:0];
            endcase
        end
    end

    // ---------------------------------------------------------------- reads
    always @(posedge clk) begin
        rb_rdata <= 8'd0;
        rb_hit   <= rb_rd && (sel_mod || sel_pt || sel_map || sel_pat);
        rb_cdata <= 32'd0;
        rb_cap   <= 1'b0;
        if (rb_rd && sel_mod) rb_rdata <= (off == 5'h10) ? mod[rn][7:0] : mod[rn][15:8];
        if (rb_rd && sel_map) case (off)
            5'h18:   rb_rdata <= mappt[rn][7:0];
            5'h19:   rb_rdata <= mappt[rn][15:8];
            default: rb_rdata <= {2'd0, mappt[rn][21:16]};
        endcase
        if (rb_rd && sel_pat) case (off)
            5'h1C:   rb_rdata <= patpt[rn][7:0];
            5'h1D:   rb_rdata <= patpt[rn][15:8];
            default: rb_rdata <= {2'd0, patpt[rn][21:16]};
        endcase
        if (rb_rd && sel_pt) case (off)
            5'h14: begin
                rb_rdata <= pt_live[7:0];
                rb_cdata <= {10'd0, pt_live};
                rb_cap   <= 1'b1;
            end
            5'h15:   rb_rdata <= pt_live[15:8];
            default: rb_rdata <= {2'd0, pt_live[21:16]};
        endcase
    end

    // ---------------------------------------------------------------- the core
    wire [3*NL-1:0]  c_depth;
    wire [16*NL-1:0] c_stride;
    wire [22*NL-1:0] c_mappt, c_patpt;
    genvar g;
    generate for (g = 0; g < NL; g = g + 1) begin : lset
        assign c_depth[3*g +: 3]   = (3'd1 << lbpp[2*g +: 2]) - 3'd1;   // words a group - 1
        assign c_stride[16*g +: 16] = mod[g];
        assign c_mappt[22*g +: 22]  = mappt[g];
        assign c_patpt[22*g +: 22]  = patpt[g];
    end endgenerate

    wire [128*NL-1:0] c_dat;
    wire [10*NL-1:0]  c_attr;
    wire [NL-1:0]     c_fill;
    wire [20:0]       c_addr;
    layer_fetch #(.NL(NL), .AW(21), .PW(22), .PLANAR(0), .TILES(1), .DATWRITE(0), .LITTLE(1),
                  .URG_BASE(11'd17), .URG_WORD(11'd5)) core (
        .clk(clk), .rst(rst), .enable(enable),
        .line_t(line_t), .line_go(line_go), .line_gen(line_gen),
        .act(act[NL-1:0]), .adv(adv[NL-1:0]), .depth(c_depth), .planar({NL{1'b0}}),
        .hscale(hscale[2*NL-1:0]), .wrap(wrap[4*NL-1:0]), .stride(c_stride),
        .ngroups(ngroups[12*NL-1:0]), .tile(tile[NL-1:0]), .mapw(mapw[2*NL-1:0]),
        .ty(ty[10*NL-1:0]), .tcol(tcol[7*NL-1:0]), .mappt(c_mappt), .patpt(c_patpt),
        .ptr_sel({rn[LW-1:0], 3'd0}), .ptr_wr(cpu_pw), .ptr_wdata(cpu_new), .ptr_rdata(pt_live),
        .dat_wr(1'b0), .dat_sel({(LW+3){1'b0}}), .dat_wdata(16'd0), .dat_be(2'b00),
        .dma_en({(8*NL){1'b1}}), .dat_rdata(),
        .dat(c_dat), .attr(c_attr), .fill_t(c_fill), .take_t(take_t[NL-1:0]),
        .req(req), .urgent(urgent), .addr(c_addr), .ack(ack), .rvalid(rvalid), .rdata(rdata)
    );
    assign addr = c_addr;

    generate if (NL < 3) begin : pad
        assign dat    = {{(128*(3-NL)){1'b0}}, c_dat};
        assign attr   = {{(10*(3-NL)){1'b0}}, c_attr};
        assign fill_t = {{(3-NL){1'b0}}, c_fill};
    end else begin : full
        assign dat    = c_dat;
        assign attr   = c_attr;
        assign fill_t = c_fill;
    end endgenerate
endmodule
