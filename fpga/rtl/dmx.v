// DMA engine and blitter (spec 14). 100 MHz. retro68k's dmx.v (ac7b75a,
// the Amiga-style BLIT), narrowed to spec 14 (ticket #39).
//
// Four channels share one datapath, which works on one channel at a time
// (the area technique): each channel's job registers (CPU-visible, laid out
// as a descriptor) and its progress through its job are kept in small RAMs.
// The engine picks the next channel with work (round robin), restores its
// progress, runs one group of up to 8 destination words, saves the progress
// and picks again.
//
// A job is rows of pixels, each row a stream of bits. Each destination
// pixel D is MINTERM(A, B, C) bit by bit (BLIT), or C + B (ADD): A the mask
// (a 1 bpp image, B compared with a key colour, or all ones), B the image or
// VALUE, C the destination's old contents. For each destination word of a
// row the B bits are lined up with a barrel shifter fed by the previous and
// the current B word, as in the Amiga's blitter; the A bits come from a
// 32-bit shift register, taking one bit per destination pixel, widened to
// the pixel's bits.
// A backwards (DESC) job uses the same shifter: words are bit-reversed on
// the way in and back again before the combine stage, so only the
// addresses and the edge masks run the other way.
//
// The SRAM is little-endian: the byte at an even address is the low byte of
// its word. Inside the engine every word is held the other way round (the
// even byte in bits 15-8), so that a word's bits from 15 down are the
// pixels in address order, as retro68k's datapath expects. Words are
// swapped as they arrive from memory and as they go back.
//
// A group is four phases: read up to 9 B words, read up to 9 A words (a mask
// image), read the C words that are needed (when the minterm or ADD uses C,
// and edge words that cover part of a byte), then work out and write each
// destination word. Writes are pipelined so a request is ready as each one
// is taken.
//
// Changed from retro68k: byte registers on the 8-bit register bus, laid out
// as spec 14's 32-byte descriptor (custom 0x140-0x23F); little-endian words
// and VALUE; physical addresses, SRAM only (version 1: the custom block,
// palettes, boot ROM and ports are an error, and so is a non-zero CTRL2);
// BCONST in place of the kinds; WIDTH 24 bits; no HIGH mode or CPUSHARE; no
// descriptor RAM; one start line per channel from the timers. MASKIMG = 0
// leaves the mask image out (about 400 LUTs), for the KS2.
//
// LINE (OP 2, spec 14 section 3.4; ticket #75, a retro-z80 addition) steps
// one pixel at a time: each pixel inside the clip rectangle is its word read
// (when the minterm needs C), merged through the minterm and written back.
// Its progress lives in fields the group machinery saves anyway: the pixel's
// bit address in w_dw:w_od, x in w_arow (APT), y in w_srow (BPT), the error
// term in w_sw, the pixels left in w_dleft and the pattern's place in w_ao.
//
// EDGES (OP 3, section 3.5) reads each edge (a word: two point numbers) and
// its two points (two words each), works out the line and runs it through
// LINE's stepping. Besides LINE's progress it keeps the next edge's word in
// w_aw, the edges left in w_rows, and the line's N, M and octant in
// w_carry, w_aleft and w_le, so a channel coming back mid-line carries on.
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
    output reg         mem_req,
    output reg         mem_we,
    output reg  [21:1] mem_addr,
    output reg  [15:0] mem_wdata,
    output reg  [1:0]  mem_be,
    input  wire        mem_ack,
    input  wire        mem_rvalid,
    input  wire [15:0] mem_rdata,

    input  wire [3:0]  tmr_start,      // a timer starts channel n, as a START (spec 9)
    input  wire        blt_on,         // DMACON.DMAEN and BLTEN
    output wire        idle,           // no channel busy (the copper's WAIT B)
    output wire [3:0]  irq             // DMA0-DMA3
);
    localparam [24:0] CHIP_WORDS = {CHIPMB, 19'd0};

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

    // ================================================================ channel registers
    reg  [23:0] chdesc [0:3];
    reg  [23:0] cherr  [0:3];
    reg  [3:0]  pause, busy, done, err, stopreq;
    reg  [3:0]  dint, dinten;
    reg  [1:0]  mode [0:3];            // where the channel is in its job
    localparam M_LOAD = 2'd0, M_SETUP = 2'd1, M_ROW = 2'd2, M_RUN = 2'd3;

    assign idle = ~|busy;

    // LINE's clip rectangle (spec 14, section 8.4): XMIN, XMAX, YMIN, YMAX,
    // signed, inclusive; reset to the whole range
    reg  [15:0] clip [0:3];
    wire [1:0]  clip_i = ro[2:1];
    assign irq  = dint & dinten;

    // Job registers: 4 channels x 8 long words, a RAM per byte lane, in
    // distributed RAM. Byte 4i + k of a channel's job is lane k of long word
    // i. Written by the CPU or copper a byte at a time (channel not busy) or
    // by a descriptor load a long word at a time; one write a clock, the
    // register bus first (the load's write waits; a long word comes at most
    // every 4 clocks, and the bus is never busy for 4 clocks running).
    reg  [7:0]  jr0 [0:31];
    reg  [7:0]  jr1 [0:31];
    reg  [7:0]  jr2 [0:31];
    reg  [7:0]  jr3 [0:31];
    wire [4:0]  cpu_ja  = {rch, ro[4:2]};
    wire        cpu_jw  = rb_wr && sel_jr && !busy[rch];
    reg         eng_jw;
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

    // Register reads: the clock after the strobe. Reserved offsets do not
    // answer, so they read 0xFF (spec 3, rule 11). Reading CHDESC's first
    // byte hands all three to the capture (spec 3, rule 4).
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
                rb_rdata <= chdesc[rch][8*ro[1:0] +: 8];
                if (ro[1:0] == 2'd0) begin
                    rb_cdata <= {8'd0, chdesc[rch]};
                    rb_cap   <= 1'b1;
                end
            end else if (sel_ctl) begin
                rb_hit <= 1'b1; rb_rdata <= {4'd0, pause[rch], 3'd0};
            end else if (sel_stat) begin
                rb_hit <= 1'b1; rb_rdata <= {4'd0, busy[rch] && pause[rch], err[rch], done[rch], busy[rch]};
            end else if (sel_err) begin
                rb_hit <= 1'b1; rb_rdata <= cherr[rch][8*ro[1:0] +: 8];
            end
        end
    end

    // ================================================================ the working job
    // The channel being worked on. Saved to st[] between groups.
    reg  [2:0]  w_op;
    reg  [7:0]  w_mt;                  // MINTERM
    reg  [1:0]  w_as;                  // ADD: SIGNED, SAT
    reg  [1:0]  w_mask;                // MASK: 0 none, 1 image at APT, 2 key compare
    reg  [1:0]  w_lb;                  // log2 of bits per pixel
    reg         w_desc, w_irq;
    reg         w_bc;                  // BCONST: B is VALUE
    reg  [31:0] w_val;
    reg  [15:0] w_sstr, w_dstr;
    reg  [26:0] w_nbits;               // bits per row
    reg  [23:0] w_apx;                 // pixels per row (the mask's bits)
    reg  [23:0] w_next;
    reg  [2:0]  w_sbit, w_dbit;
    reg  [15:0] w_rows;                // rows still to do, this one included
    reg  [23:0] w_srow, w_drow;        // this row's first bytes
    reg  [22:0] w_dw, w_sw;            // next destination and source words
    reg  [23:0] w_dleft, w_sleft;      // words of this row still to write and to read
    reg  [3:0]  w_od;                  // the first pixel's bit in its word (from the start side)
    reg  [3:0]  w_t;                   // the shift
    reg         w_pre;                 // read one source word ahead first
    reg         w_first;               // the next word is the row's first
    reg  [3:0]  w_le;                  // bits used in the row's last word (0 = 16)
    reg  [15:0] w_carry;               // the last source word taken
    // The mask image A (MASK = 1): a 1 bpp stream with B's stride
    reg  [23:0] w_arow;                // this row's first byte
    reg  [2:0]  w_abit;
    reg  [22:0] w_aw;                  // next word to read
    reg  [23:0] w_aleft;               // words of this row still to read
    reg  [3:0]  w_ao;                  // the row's first bit in its word (from the start side)
    reg  [31:0] w_areg;                // bits not yet used, from bit 31
    reg  [4:0]  w_acnt;                // how many
    reg         w_c2;                  // CTRL2 not 0 (checked as the job starts; not saved)
    // LINE: the octant, HEIGHT, and what the engine derives from them (not
    // saved: worked out again whenever the channel comes back)
    reg         w_ymaj, w_xneg, w_yneg;
    reg  [15:0] w_n;                   // HEIGHT: the shorter length
    reg  [17:0] l_ins, l_ind;          // E's steps: 2N, and 2(N - M)
    reg  [26:0] l_dmaj, l_dmin;        // the bit address's steps along each axis
    reg  [3:0]  l_k;                   // pixels this turn
    reg  [15:0] l_c;                   // the pixel's word as read (C)
    // EDGES: the points' and the origin's addresses (read from the job
    // registers each time), the edge's ends as read, y x stride
    reg  [22:0] w_aptf, w_dptf;
    reg  [15:0] e_ab;                  // the edge word: a in 7-0, b in 15-8
    reg  [15:0] e_x0, e_y0, e_x1, e_y1;
    reg  [31:0] e_mul;

    // Only the progress is saved: what stays the same for the whole job is
    // read again from the job registers (S_SETUP) when the channel comes
    // back after another one has run. A channel that carries on straight
    // after its own group needs neither.
    localparam SW = 16+24+24 + 23+23+24+24+4+4+1+1+4+16 + 24+23+24+4+32+5;
    wire [SW-1:0] w_pack = {w_rows, w_srow, w_drow, w_dw, w_sw, w_dleft, w_sleft,
                            w_od, w_t, w_pre, w_first, w_le, w_carry,
                            w_arow, w_aw, w_aleft, w_ao, w_areg, w_acnt};
    reg           w_live;              // the w_ registers hold channel w_ch's job and progress
    reg  [1:0]    w_ch;
    reg           su_back;             // S_SETUP: only the job's fixed fields, then on
    reg  [SW-1:0] st [0:3];
    reg  [1:0]    cur;
    initial for (k = 0; k < 4; k = k + 1) st[k] = {SW{1'b0}};

    // ================================================================ the datapath
    wire        srcmem  = !w_bc;
    wire        maskimg = MASKIMG != 0 && (w_mask == 2'd1);
    // Does a minterm nibble (the four B, C combinations) depend on C?
    function cdep(input [3:0] n);
        cdep = (n[3] ^ n[2]) | (n[1] ^ n[0]);
    endfunction
    // Where A is 0 and the minterm's low nibble is 0xA (D = C), or for ADD,
    // the pixel is left alone: at 8 bpp a byte not written, C not read
    wire        keep0   = (w_op == 3'd1) || (w_mt[3:0] == 4'hA);
    // Reads every C word: ADD, or the minterm uses C where A can be 1 (the
    // high nibble), or where A can be 0 (the low nibble, or keeping C in
    // part of a byte)
    wire        op_rd   = (w_op == 3'd1) || cdep(w_mt[7:4])
                          || (w_mask != 2'd0 && (keep0 ? (w_lb != 2'd3) : cdep(w_mt[3:0])));

    function [15:0] rev16(input [15:0] v);
        integer i;
        for (i = 0; i < 16; i = i + 1) rev16[i] = v[15 - i];
    endfunction
    // A memory word to the engine's order (the even byte in bits 15-8) and back
    function [15:0] swap(input [15:0] v);
        swap = {v[7:0], v[15:8]};
    endfunction
    // A constant B for a destination word (engine order). At 8 bpp the byte
    // at address a is VALUE's byte a mod 4, byte 0 bits 7-0 (spec 14,
    // section 3.1); odd is the word at a mod 4 = 2
    function [15:0] pattern(input [31:0] v, input [1:0] lb, input odd);
        case (lb)
            2'd3: pattern = odd ? {v[23:16], v[31:24]} : {v[7:0], v[15:8]};
            2'd2: pattern = {4{v[3:0]}};
            2'd1: pattern = {8{v[1:0]}};
            default: pattern = {16{v[0]}};
        endcase
    endfunction
    function [15:0] msbs(input [1:0] lb);      // each pixel's top bit
        case (lb)
            2'd3: msbs = 16'h8080;
            2'd2: msbs = 16'h8888;
            2'd1: msbs = 16'hAAAA;
            default: msbs = 16'hFFFF;
        endcase
    endfunction
    function [15:0] smear(input [15:0] f, input [1:0] lb);   // a pixel's top bit to the whole pixel
        integer i;
        begin
            smear = f;
            for (i = 1; i < 8; i = i + 1)
                if (i < (1 << lb)) smear = smear | (f >> i);
        end
    endfunction
    // A's bits for a destination word: bit i of t (from bit 15) to the
    // whole of pixel i
    function [15:0] widen(input [15:0] t, input [1:0] lb);
        integer i;
        for (i = 0; i < 16; i = i + 1) widen[15 - i] = t[15 - (i >> lb)];
    endfunction
    // The Amiga's minterm: each bit of the result is m[a*4 + b*2 + c]
    function [15:0] minterm(input [7:0] m, input [15:0] a, input [15:0] b, input [15:0] c);
        minterm = ({16{m[7]}} &  a &  b &  c) | ({16{m[6]}} &  a &  b & ~c)
                | ({16{m[5]}} &  a & ~b &  c) | ({16{m[4]}} &  a & ~b & ~c)
                | ({16{m[3]}} & ~a &  b &  c) | ({16{m[2]}} & ~a &  b & ~c)
                | ({16{m[1]}} & ~a & ~b &  c) | ({16{m[0]}} & ~a & ~b & ~c);
    endfunction
    // Pixels of s that are not the key colour (all their bits set)
    function [15:0] notkey(input [15:0] s, input [7:0] key, input [1:0] lb);
        reg [15:0] kk, x;
        begin
            kk = pattern({key, key, key, key}, lb, 1'b1);
            x  = s ^ kk;
            case (lb)
                2'd3: notkey = {{8{|x[15:8]}}, {8{|x[7:0]}}};
                2'd2: notkey = {{4{|x[15:12]}}, {4{|x[11:8]}}, {4{|x[7:4]}}, {4{|x[3:0]}}};
                2'd1: notkey = {{2{|x[15:14]}}, {2{|x[13:12]}}, {2{|x[11:10]}}, {2{|x[9:8]}},
                                {2{|x[7:6]}},   {2{|x[5:4]}},   {2{|x[3:2]}},   {2{|x[1:0]}}};
                default: notkey = x;
            endcase
        end
    endfunction
    // Per-pixel add, wrapping or saturating (spec 14, section 3.2)
    function [15:0] padd(input [15:0] d, input [15:0] s, input [1:0] lb, input sat, input sgn);
        reg [15:0] h, l, t, sum, co, ov, f, dneg;
        begin
            h    = msbs(lb);
            l    = ~h;
            t    = (d & l) + (s & l);                 // no carry crosses a pixel
            sum  = t ^ ((d ^ s) & h);
            co   = ((d & s) | ((d ^ s) & t)) & h;     // carry out of each pixel
            ov   = ~(d ^ s) & (d ^ sum) & h;          // signed overflow
            dneg = smear(d & h, lb);
            if (!sat)
                padd = sum;
            else if (!sgn)
                padd = sum | smear(co, lb);
            else begin
                f    = smear(ov, lb);
                padd = (sum & ~f) | (f & ((dneg & h) | (~dneg & l)));
            end
        end
    endfunction

    // Is a word address in the SRAM? (spec 14, section 4: version 1 reaches nothing else)
    function inchip(input [22:0] w);
        inchip = ({2'd0, w} < CHIP_WORDS);
    endfunction

    // ================================================================ group buffers
    reg  [15:0] sbuf [0:8];            // source words, in the order read
    reg  [15:0] abuf [0:8];            // mask words, in the order read
    reg  [3:0]  g_na;                  // mask words to read
    reg  [15:0] dbuf [0:7];            // destination words, by position in the group
    reg  [3:0]  g_n;                   // destination words in this group (1-8)
    reg  [3:0]  g_nr;                  // source words to read
    reg  [7:0]  g_dneed;               // destination words to read
    reg  [3:0]  g_last;                // the row's last word in this group (8: none)
    // Known contents from the start: a C word not read still goes through
    // the minterm (its result does not depend on it), and the simulator
    // would carry the unknown bits through
    initial for (k = 0; k < 9; k = k + 1) begin sbuf[k] = 16'd0; abuf[k] = 16'd0; end
    initial for (k = 0; k < 8; k = k + 1) dbuf[k] = 16'd0;

    // ================================================================ engine state
    localparam S_IDLE = 5'd0, S_REST = 5'd1, S_DESC = 5'd2, S_SETUP = 5'd3, S_CHECK = 5'd4,
               S_MUL = 5'd5, S_ROW1 = 5'd6, S_ROW2 = 5'd7, S_ROW3 = 5'd8, S_GRP = 5'd9,
               S_RD = 5'd10, S_DR = 5'd11, S_WR = 5'd12, S_SAVE = 5'd13, S_DRAIN = 5'd14,
               S_RA = 5'd15, S_BACK = 5'd16, S_LSET = 5'd17, S_LPIX = 5'd18, S_LRD = 5'd19,
               S_LCMB = 5'd20, S_LWR = 5'd21, S_LSTEP = 5'd22, S_EFETCH = 5'd23, S_EPTS = 5'd24,
               S_ECALC = 5'd25, S_EADDR = 5'd26;
    reg  [4:0]  es;
    reg  [1:0]  last_ch;
    wire [3:0]  runnable = busy & ~pause & {4{blt_on}};

    reg  [4:0]  r_tot, r_iss, r_got;   // reads to make, made, back
    reg  [22:0] r_a;                   // the next address (S_RD, S_RA, S_DESC)
    reg  [2:0]  q_j [0:7];             // S_DR: each read's place in the group
    reg  [15:0] d_lo;                  // S_DESC: the low half of a long word
    reg         e_bad;                 // stop: an error
    reg  [23:0] e_addr;
    reg  [2:0]  su_i;                  // S_SETUP: job register long word being read

    // S_DR: the next destination word to read
    reg  [2:0]  dr_j;
    always @(*) begin : drpick
        integer i;
        dr_j = 3'd0;
        for (i = 7; i >= 0; i = i - 1) if (g_dneed[i]) dr_j = i[2:0];
    end
    wire [22:0] dr_a = w_desc ? w_dw - dr_j : w_dw + dr_j;

    // S_WR pipeline: stage A (line up), stage B (combine), then the request
    reg  [3:0]  wj;                    // next word to start
    reg  [3:0]  sptr, aptr;
    reg         a_v, b_v;
    reg  [15:0] a_s, a_m, a_d, a_a;
    reg  [22:0] a_w, b_w;
    reg  [15:0] b_out;
    reg  [1:0]  b_be;
    reg         b_skip;

    // EDGES: the edge's point being read (S_EPTS: point a, then b, two words each)
    wire [7:0]  e_pn     = r_iss[1] ? e_ab[15:8] : e_ab[7:0];
    wire [22:0] e_pw     = {1'b0, w_aptf[22:1]} + {13'd0, e_pn, 1'b0} + {22'd0, r_iss[0]};

    // ================================================================ the access unit
    // The phase's next access (engine order: b_be[1] is the even byte)
    reg         xq_v, xq_we;
    reg  [22:0] xq_w;
    always @(*) begin
        xq_v = 1'b0; xq_we = 1'b0; xq_w = r_a;
        case (es)
            S_DESC:     xq_v = (r_iss < 5'd16) && !e_bad;
            S_RD, S_RA: xq_v = (r_iss < r_tot) && !e_bad;
            S_DR:       begin xq_v = (g_dneed != 8'd0) && !e_bad; xq_w = dr_a; end
            S_WR:       begin xq_v = b_v && !b_skip && !e_bad; xq_we = 1'b1; xq_w = b_w; end
            S_LRD:      begin xq_v = (r_iss == 5'd0) && !e_bad; xq_w = w_dw; end
            S_LWR:      begin xq_v = (r_iss == 5'd0) && !e_bad; xq_we = 1'b1; xq_w = w_dw; end
            S_EFETCH:   begin xq_v = (r_iss == 5'd0) && (w_rows != 16'd0) && !e_bad; xq_w = w_aw; end
            S_EPTS:     begin xq_v = (r_iss < 5'd4) && !e_bad; xq_w = e_pw; end
            default: ;
        endcase
    end

    reg  [4:0]  chip_out;              // SRAM reads not yet back

    wire        xq_bad  = xq_v && !inchip(xq_w);
    wire        xq_take = xq_v && !xq_bad && (!mem_req || mem_ack);
    // Reads back, in order, in the engine's order (descriptors are taken as they are)
    wire        x_rv = mem_rvalid;
    wire [15:0] x_rd = swap(mem_rdata);

    // ================================================================ the write pipeline
    wire        b_take   = b_v && (b_skip || xq_take);
    wire        a_move   = a_v && (!b_v || b_take);
    wire        a_new    = (wj < g_n) && (!a_v || a_move) && !e_bad;

    // Stage A for word wj
    wire        a_hasn   = srcmem && (sptr < g_nr);
    wire [15:0] a_B      = a_hasn ? sbuf[sptr] : 16'd0;
    wire [31:0] a_cat    = {w_carry, a_B} << w_t;
    wire [15:0] a_shp    = a_cat[31:16];
    wire [15:0] m_first  = (w_first && wj == 4'd0) ? (16'hFFFF >> w_od) : 16'hFFFF;
    wire [15:0] m_last   = (wj == g_last) ? ((w_le == 4'd0) ? 16'hFFFF : ~(16'hFFFF >> w_le)) : 16'hFFFF;
    wire [15:0] a_mp     = m_first & m_last;
    wire [22:0] a_wa     = w_desc ? w_dw - wj : w_dw + wj;
    wire [15:0] a_st     = srcmem ? (w_desc ? rev16(a_shp) : a_shp) : pattern(w_val, w_lb, a_wa[0]);
    wire [15:0] a_mt     = w_desc ? rev16(a_mp) : a_mp;
    // the mask image: take 16 >> BPP bits (one a pixel), adding a word first if short
    wire [4:0]  a_k      = 5'd16 >> w_lb;
    wire        a_ins    = (w_acnt < a_k);
    wire [15:0] a_word   = (aptr < g_na) ? abuf[aptr] : 16'd0;
    wire [31:0] a_regi   = a_ins ? (w_areg | ({a_word, 16'd0} >> w_acnt)) : w_areg;
    wire [15:0] a_wide   = widen(a_regi[31:16], w_lb);
    wire [15:0] a_at     = w_desc ? rev16(a_wide) : a_wide;

    // Stage B
    wire [15:0] b_A      = (w_mask == 2'd2) ? notkey(a_s, w_val[7:0], w_lb)
                         : (w_mask == 2'd1) ? a_a : 16'hFFFF;
    wire [15:0] res      = (w_op == 3'd1) ? padd(a_d, a_s, w_lb, w_as[0], w_as[1])
                         : minterm(w_mt, b_A, a_s, a_d);
    wire [15:0] mfin     = a_m & ~(keep0 ? ~b_A : 16'd0);

    // LINE and EDGES: the line's octant, N (the shorter length) and M (the
    // longer): LINE's from its job, EDGES' from the edge (kept in w_le,
    // w_carry and w_aleft)
    wire        is_e     = (w_op == 3'd3);
    wire        l_ymaj   = is_e ? w_le[0] : w_ymaj;
    wire        l_xneg   = is_e ? w_le[1] : w_xneg;
    wire        l_yneg   = is_e ? w_le[2] : w_yneg;
    wire [15:0] l_nn     = is_e ? w_carry : w_n;
    wire [15:0] l_mm     = is_e ? w_aleft[15:0] : w_apx[15:0] - 1'b1;
    // and what is worked out from its ends
    wire [16:0] e_dx     = {e_x1[15], e_x1} - {e_x0[15], e_x0};
    wire [16:0] e_dy     = {e_y1[15], e_y1} - {e_y0[15], e_y0};
    wire [15:0] e_ax     = e_dx[16] ? 16'd0 - e_dx[15:0] : e_dx[15:0];
    wire [15:0] e_ay     = e_dy[16] ? 16'd0 - e_dy[15:0] : e_dy[15:0];
    wire        e_ymaj   = e_ay > e_ax;
    wire [15:0] e_m      = e_ymaj ? e_ay : e_ax;
    wire [15:0] e_n      = e_ymaj ? e_ax : e_ay;
    // left out: an end outside -16384..16383 (x = 0x8000 among them), or
    // both beyond the same side of the clip rectangle
    wire        e_range  = (e_x0[15] != e_x0[14]) || (e_y0[15] != e_y0[14])
                        || (e_x1[15] != e_x1[14]) || (e_y1[15] != e_y1[14]);
    wire        e_beyond = ($signed(e_x0) < $signed(clip[0]) && $signed(e_x1) < $signed(clip[0]))
                        || ($signed(e_x0) > $signed(clip[1]) && $signed(e_x1) > $signed(clip[1]))
                        || ($signed(e_y0) < $signed(clip[2]) && $signed(e_y1) < $signed(clip[2]))
                        || ($signed(e_y0) > $signed(clip[3]) && $signed(e_y1) > $signed(clip[3]));

    // LINE: this pixel. x in w_arow, y in w_srow; the pattern's bit, from 31
    wire [15:0] l_x      = w_arow[15:0];
    wire [15:0] l_y      = w_srow[15:0];
    wire        l_in     = $signed(l_x) >= $signed(clip[0]) && $signed(l_x) <= $signed(clip[1])
                        && $signed(l_y) >= $signed(clip[2]) && $signed(l_y) <= $signed(clip[3]);
    wire        l_a      = w_val[5'd31 - {1'b0, w_ao}];
    wire        l_keep   = !l_a && (w_mt[3:0] == 4'hA);              // D = C: nothing to do
    wire        l_needc  = (w_lb != 2'd3) || cdep(l_a ? w_mt[7:4] : w_mt[3:0]);
    wire [4:0]  l_bits   = 5'd1 << w_lb;
    wire [15:0] l_pm     = (16'hFFFF >> w_od) & ~(16'hFFFF >> ({1'b0, w_od} + l_bits));
    wire [15:0] l_res    = minterm(w_mt, {16{l_a}}, pattern({4{w_val[7:0]}}, w_lb, 1'b0), l_c);
    wire [17:0] l_e      = w_sw[17:0];
    wire        l_minor  = !l_e[17] && (l_e != 18'd0);                 // E > 0: the shorter axis too

    // Job setup: OP 0 BLIT, 1 ADD and 2 LINE (3-4 reserved, 5 MIX on hold, 6
    // and 7 for 3D), MASK 3 reserved, CTRL2 for later targets. LINE: no DESC
    // or MASK, WIDTH up to 32,768, HEIGHT up to WIDTH - 1
    wire        bad_line = (w_op == 3'd2) && (w_desc || w_mask != 2'd0 || w_apx > 24'd32768
                                              || (w_apx != 24'd0 && {8'd0, w_n} > w_apx - 1'b1));
    // EDGES: no DESC or MASK, even POINTS and EDGES, up to 65,535 edges
    // (BPT is in w_srow when the job starts)
    wire        bad_edges = is_e && (w_desc || w_mask != 2'd0 || w_aptf[0] || w_srow[0] || w_apx[23:16] != 8'd0);
    wire        bad_op   = (w_op > 3'd3) || (w_mask == 2'd3) || (MASKIMG == 0 && w_mask == 2'd1) || w_c2
                        || bad_line || bad_edges;

    // Row start
    reg  [26:0] rs_sba, rs_dba, rs_aba;  // the row's first bits
    reg  [32:0] mul_s, mul_d;

`ifdef DMX_TRACE
    reg [4:0] es_d;
    integer tclk = 0;
    always @(posedge clk) begin
        tclk = tclk + 1;
        es_d <= es;
        if (es != es_d) $display("%0d dmx es %0d -> %0d cur %0d busy %b mode %0d rows %0d dleft %0d", tclk, es_d, es, cur, busy, mode[cur], w_rows, w_dleft);
        if (xq_take) $display("%0d dmx take w %h we %b", tclk, xq_w, xq_we);
        if (mem_ack) $display("%0d dmx ack", tclk);
        if (rb_wr && in_dmx) $display("%0d dmx wr ro %h ch %0d d %h", tclk, ro, rch, rb_wdata);
    end
`endif

    integer i;
    always @(posedge clk) begin
        if (eng_jw && !cpu_jw) eng_jw <= 1'b0;    // a job register write waits for a clock the bus leaves
        if (rst) begin
            eng_jw <= 1'b0;
            es <= S_IDLE;
            w_live <= 1'b0;
            mem_req <= 1'b0;
            chip_out <= 5'd0;
            busy <= 4'd0; done <= 4'd0; err <= 4'd0; pause <= 4'd0; stopreq <= 4'd0;
            dint <= 4'd0; dinten <= 4'd0;
            clip[0] <= 16'h8000; clip[1] <= 16'h7FFF; clip[2] <= 16'h8000; clip[3] <= 16'h7FFF;
            last_ch <= 2'd3;
            for (i = 0; i < 4; i = i + 1) begin
                chdesc[i] <= 24'd0; cherr[i] <= 24'd0; mode[i] <= M_LOAD;
            end
        end else begin
            // ---------------------------------------------------- the access unit
            if (xq_bad && !e_bad) begin
                e_bad  <= 1'b1;
                e_addr <= {xq_w, 1'b0};
            end
            // SRAM: one request, held until taken; words back in memory order
            if (xq_take) begin
                mem_req   <= 1'b1;
                mem_we    <= xq_we;
                mem_addr  <= xq_w[20:0];
                mem_wdata <= swap(b_out);
                mem_be    <= xq_we ? {b_be[0], b_be[1]} : 2'b11;
            end else if (mem_ack)
                mem_req <= 1'b0;
            chip_out <= chip_out + ((xq_take && !xq_we) ? 5'd1 : 5'd0)
                                 - (mem_rvalid ? 5'd1 : 5'd0);

            case (es)
            // ---------------------------------------------------- pick a channel
            S_IDLE: if (|runnable) begin : pick
                integer o;
                reg [1:0] c;
                reg       f;
                f = 1'b0;
                c = last_ch;
                for (o = 0; o < 4; o = o + 1) begin
                    c = c + 1'b1;
                    if (!f && runnable[c]) begin f = 1'b1; cur <= c; end
                end
                es <= S_REST;
            end

            S_REST: begin
                if (!(w_live && w_ch == cur))
                    {w_rows, w_srow, w_drow, w_dw, w_sw, w_dleft, w_sleft,
                     w_od, w_t, w_pre, w_first, w_le, w_carry,
                     w_arow, w_aw, w_aleft, w_ao, w_areg, w_acnt} <= st[cur];
                su_back <= 1'b0;
                last_ch <= cur;
                e_bad   <= 1'b0;
                r_tot <= 5'd0; r_iss <= 5'd0; r_got <= 5'd0;
                su_i  <= 3'd0;
                case (mode[cur])
                    M_LOAD: begin
                        // the descriptor: a multiple of 4, all 32 bytes in SRAM
                        r_a <= chdesc[cur][23:1];
                        if (chdesc[cur][1:0] != 2'd0 ||
                            !(inchip(chdesc[cur][23:1]) && inchip(chdesc[cur][23:1] + 23'd15))) begin
                            e_addr <= chdesc[cur];
                            e_bad  <= 1'b1;
                            es     <= S_SAVE;
                        end else
                            es <= S_DESC;
                    end
                    M_SETUP: es <= S_SETUP;
                    default: if (w_live && w_ch == cur)
                                 es <= (w_op == 3'd2 || w_op == 3'd3) ? S_LPIX : (mode[cur] == M_ROW) ? S_ROW1 : S_GRP;
                             else begin
                                 su_back <= 1'b1;
                                 es <= S_SETUP;
                             end
                endcase
            end

            // ---------------------------------------------------- load a descriptor
            // 16 words, each pair a job register long word, the even byte
            // first (a long word comes at most every 4 clocks: a waiting job
            // register write has landed by the next)
            S_DESC: begin
                if (xq_take) begin
                    r_a   <= r_a + 1'b1;
                    r_iss <= r_iss + 1'b1;
                end
                if (x_rv) begin
                    r_got <= r_got + 1'b1;
                    if (!r_got[0]) d_lo <= mem_rdata;
                    else begin
                        eng_jw <= 1'b1;
                        eng_ja <= {cur, r_got[3:1]};
                        eng_jd <= {mem_rdata, d_lo};
                    end
                end
                if (r_got == 5'd16 && !eng_jw) begin
                    mode[cur] <= M_SETUP;
                    su_i <= 3'd0;
                    es   <= S_SETUP;
                end
            end

            // ---------------------------------------------------- start a job
            // The job registers, long word by long word (spec 14, section 3);
            // bit 23 of each address is not used
            S_SETUP: begin : setup
                reg [31:0] v;
                v = {jr3[{cur, su_i}], jr2[{cur, su_i}], jr1[{cur, su_i}], jr0[{cur, su_i}]};
                case (su_i)
                    3'd0: begin w_op <= v[2:0]; w_as <= v[5:4]; w_lb <= v[9:8]; w_desc <= v[10];
                                w_ymaj <= v[3]; w_xneg <= v[6]; w_yneg <= v[7];
                                w_irq <= v[11]; w_bc <= v[12]; w_mask <= v[14:13];
                                w_c2 <= (v[23:16] != 8'd0); w_mt <= v[31:24]; end
                    3'd1: begin if (!su_back) begin w_arow <= {1'b0, v[22:0]}; w_srow[7:0] <= v[31:24]; end
                                w_aptf <= v[22:0]; end
                    3'd2: begin if (!su_back) begin w_srow[23:8] <= {1'b0, v[14:0]}; w_drow[15:0] <= v[31:16]; end
                                w_dptf[15:0] <= v[31:16]; end
                    3'd3: begin if (!su_back) w_drow[23:16] <= {1'b0, v[6:0]};
                                w_dptf[22:16] <= v[6:0];
                                w_nbits <= {3'd0, v[31:8]};          // the width, for now
                                w_apx <= v[31:8]; end
                    3'd4: begin if (!su_back) w_rows <= v[15:0]; w_n <= v[15:0];
                                w_abit <= v[18:16]; w_sbit <= v[22:20];
                                w_dbit <= v[26:24]; end
                    3'd5: begin w_sstr <= v[15:0]; w_dstr <= v[31:16]; end
                    3'd6: w_val  <= v;
                    3'd7: w_next <= {1'b0, v[22:0]};
                endcase
                su_i <= su_i + 1'b1;
                if (su_i == 3'd7) es <= su_back ? S_BACK : S_CHECK;
            end
            // back to a job after another channel's turn: the width in bits again
            S_BACK: begin
                w_nbits <= w_nbits << w_lb;
                es <= (w_op == 3'd2 || w_op == 3'd3) ? S_LSET : (mode[cur] == M_ROW) ? S_ROW1 : S_GRP;
            end

            S_CHECK: begin
                w_nbits <= w_nbits << w_lb;
                mul_s   <= $signed({1'b0, w_rows - 1'b1}) * $signed(w_sstr);
                mul_d   <= $signed({1'b0, w_rows - 1'b1}) * $signed(w_dstr);
                if (bad_op) begin
                    e_addr <= chdesc[cur];
                    e_bad  <= 1'b1;
                    es     <= S_SAVE;
                end else if (w_op == 3'd3) begin
                    if (w_apx == 24'd0) begin
                        w_rows <= 16'd0;             // no edges: the job ends
                        es     <= S_SAVE;
                    end else begin
                        w_rows  <= w_apx[15:0];      // the edges left
                        w_aw    <= w_srow[23:1];     // the first edge's word (BPT)
                        r_iss   <= 5'd0; r_got <= 5'd0;
                        mode[cur] <= M_RUN;
                        es      <= S_EFETCH;
                    end
                end else if (w_op == 3'd2) begin
                    if (w_apx == 24'd0) begin
                        w_rows <= 16'd0;             // nothing to do: the job ends
                        es     <= S_SAVE;
                    end else begin
                        // the first pixel; the rest is worked out in S_LSET
                        w_rows  <= 16'd1;
                        {w_dw, w_od} <= {w_drow, 3'b000} + ({24'd0, w_dbit} << w_lb);
                        w_sw    <= {5'd0, w_n, 1'b0} - {5'd0, w_apx[17:0]} + 23'd1;    // 2N - M
                        w_dleft <= w_apx;
                        w_ao    <= 4'd0;
                        mode[cur] <= M_RUN;
                        es      <= S_LSET;
                    end
                end else if (w_nbits == 27'd0 || w_rows == 16'd0) begin
                    w_rows <= 16'd0;                 // nothing to do: the job ends
                    es     <= S_SAVE;
                end else
                    es <= S_MUL;
            end

            S_MUL: begin
                // backwards: start from the last row
                if (w_desc) begin
                    w_srow <= w_srow + mul_s[23:0];
                    w_arow <= w_arow + mul_s[23:0];
                    w_drow <= w_drow + mul_d[23:0];
                end
                es <= S_ROW1;
            end

            // ---------------------------------------------------- start a row
            S_ROW1: begin
                rs_sba <= {w_srow, 3'b000} + ({24'd0, w_sbit} << w_lb);
                rs_dba <= {w_drow, 3'b000} + ({24'd0, w_dbit} << w_lb);
                rs_aba <= {w_arow, 3'b000} + {24'd0, w_abit};
                es <= S_ROW2;
            end
            S_ROW2: begin : row2
                reg [26:0] se, de, ae;
                se = rs_sba + w_nbits;
                de = rs_dba + w_nbits;
                ae = rs_aba + {3'd0, w_apx};
                if (!w_desc) begin
                    w_ao <= rs_aba[3:0];
                    w_aw <= rs_aba[26:4];
                end else begin
                    w_ao <= 4'd0 - ae[3:0];
                    /* verilator lint_off WIDTHTRUNC */ w_aw <= (ae - 1'b1) >> 4; /* verilator lint_on WIDTHTRUNC */
                end
                if (!w_desc) begin
                    w_od <= rs_dba[3:0];
                    w_dw <= rs_dba[26:4];
                    w_t  <= rs_sba[3:0];          // the source's start bit, for now
                    w_sw <= rs_sba[26:4];
                end else begin
                    w_od <= 4'd0 - de[3:0];
                    /* verilator lint_off WIDTHTRUNC */ w_dw <= (de - 1'b1) >> 4; /* verilator lint_on WIDTHTRUNC */
                    w_t  <= 4'd0 - se[3:0];
                    /* verilator lint_off WIDTHTRUNC */ w_sw <= (se - 1'b1) >> 4; /* verilator lint_on WIDTHTRUNC */
                end
                es <= S_ROW3;
            end
            S_ROW3: begin : row3
                reg [27:0] dn, sn, an;
                dn = {1'b0, w_nbits} + w_od + 4'd15;
                sn = {1'b0, w_nbits} + w_t + 4'd15;
                an = {4'd0, w_apx} + w_ao + 4'd15;
                w_dleft <= dn[27:4];
                w_sleft <= srcmem ? sn[27:4] : 24'd0;
                w_pre   <= srcmem && (w_t >= w_od);
                w_t     <= srcmem ? w_t - w_od : 4'd0;
                w_le    <= w_od + w_nbits[3:0];
                w_first <= 1'b1;
                w_aleft <= an[27:4];
                w_acnt  <= 5'd0;
                mode[cur] <= M_RUN;
                es <= S_GRP;
            end

            // ---------------------------------------------------- a group
            S_GRP: begin : grp
                reg [3:0] n, nr;
                reg [24:0] want;
                reg [7:0] need, avail, extra, na;
                integer j;
                n    = (w_dleft > 24'd8) ? 4'd8 : w_dleft[3:0];
                want = n + w_pre;
                nr   = (want > w_sleft) ? w_sleft[3:0] : want[3:0];
                // mask words: the row's first, then enough for n words of pixels
                need  = {4'd0, n} << (3'd4 - {1'b0, w_lb});
                avail = w_first ? {4'd0, w_od >> w_lb} + 8'd16 - {4'd0, w_ao} : {3'd0, w_acnt};
                extra = (need > avail) ? (need - avail + 8'd15) >> 4 : 8'd0;
                na    = extra + (w_first ? 8'd1 : 8'd0);
                g_na  <= !maskimg ? 4'd0 : ({16'd0, na} > w_aleft) ? w_aleft[3:0] : na[3:0];
                g_n  <= n;
                g_nr <= nr;
                g_last <= (w_dleft > 24'd8) ? 4'd8 : w_dleft[3:0] - 1'b1;
                for (j = 0; j < 8; j = j + 1)
                    g_dneed[j] <= (j < n) && (op_rd || (w_first && j == 0 && w_od[2:0] != 3'd0)
                                              || (j == w_dleft - 1 && w_le[2:0] != 3'd0));
                r_tot <= {1'b0, nr}; r_iss <= 5'd0; r_got <= 5'd0;
                r_a   <= w_sw;
                es    <= S_RD;
            end

            S_RD: begin
                if (xq_take) begin
                    r_a   <= w_desc ? r_a - 1'b1 : r_a + 1'b1;
                    r_iss <= r_iss + 1'b1;
                end
                if (x_rv) begin
                    sbuf[r_got[3:0]] <= w_desc ? rev16(x_rd) : x_rd;
                    r_got <= r_got + 1'b1;
                end
                // (a bad access sets e_bad the clock it is seen, so only
                // "nothing left" or e_bad need looking at here: short paths)
                if (r_got == r_iss && (r_iss == r_tot || e_bad) && !mem_req) begin
                    if (e_bad) es <= S_DRAIN;
                    else begin
                        w_sw    <= r_a;
                        w_sleft <= w_sleft - g_nr;
                        r_iss <= 5'd0; r_got <= 5'd0;
                        r_tot <= {1'b0, g_na};
                        r_a   <= w_aw;
                        es    <= (g_na != 4'd0) ? S_RA : S_DR;
                    end
                end
            end

            // the mask image's words, as S_RD
            S_RA: begin
                if (xq_take) begin
                    r_a   <= w_desc ? r_a - 1'b1 : r_a + 1'b1;
                    r_iss <= r_iss + 1'b1;
                end
                if (x_rv) begin
                    abuf[r_got[3:0]] <= w_desc ? rev16(x_rd) : x_rd;
                    r_got <= r_got + 1'b1;
                end
                if (r_got == r_iss && (r_iss == r_tot || e_bad) && !mem_req) begin
                    if (e_bad) es <= S_DRAIN;
                    else begin
                        w_aw    <= r_a;
                        w_aleft <= w_aleft - g_na;
                        r_tot <= 5'd0; r_iss <= 5'd0; r_got <= 5'd0;
                        es <= S_DR;
                    end
                end
            end

            S_DR: begin
                if (xq_take) begin
                    q_j[r_iss[2:0]] <= dr_j;
                    g_dneed[dr_j] <= 1'b0;
                    r_iss <= r_iss + 1'b1;
                end
                if (x_rv) begin
                    dbuf[q_j[r_got[2:0]]] <= x_rd;
                    r_got <= r_got + 1'b1;
                end
                if (r_got == r_iss && (g_dneed == 8'd0 || e_bad) && !mem_req) begin
                    if (e_bad) es <= S_DRAIN;
                    else begin
                        wj <= 4'd0;
                        sptr <= w_pre ? 4'd1 : 4'd0;
                        if (w_pre) w_carry <= sbuf[0];
                        // the row's first mask word: its first bit lined up
                        // with the destination's first pixel
                        aptr <= 4'd0;
                        if (w_first && maskimg) begin : apre
                            reg [3:0] pd;
                            pd = w_od >> w_lb;
                            w_areg <= ({abuf[0], 16'd0} << w_ao) >> pd;
                            w_acnt <= 5'd16 + pd - w_ao;
                            aptr   <= 4'd1;
                        end
                        a_v <= 1'b0; b_v <= 1'b0;
                        es <= S_WR;
                    end
                end
            end

            S_WR: begin
                if (b_take) b_v <= 1'b0;
                // stage B
                if (a_move) begin
                    b_v    <= 1'b1;
                    b_w    <= a_w;
                    b_out  <= (res & mfin) | (a_d & ~mfin);
                    b_be   <= {|mfin[15:8], |mfin[7:0]};
                    b_skip <= (mfin == 16'd0);
                    a_v    <= 1'b0;
                end
                // stage A
                if (a_new) begin
                    a_v <= 1'b1;
                    a_s <= a_st;
                    a_m <= a_mt;
                    a_d <= dbuf[wj[2:0]];
                    a_a <= a_at;
                    a_w <= a_wa;
                    if (maskimg) begin
                        w_areg <= a_regi << a_k;
                        w_acnt <= (a_ins ? w_acnt + 5'd16 : w_acnt) - a_k;
                        if (a_ins) aptr <= aptr + 1'b1;
                    end
                    if (a_hasn) begin
                        w_carry <= a_B;
                        sptr    <= sptr + 1'b1;
                    end
                    wj <= wj + 1'b1;
                end
                if (e_bad) begin
                    a_v <= 1'b0; b_v <= 1'b0;
                    if (!mem_req) es <= S_DRAIN;
                end else if (!a_v && !b_v && !mem_req && wj == g_n) begin
                    // the group is done
                    w_dw    <= w_desc ? w_dw - g_n : w_dw + g_n;
                    w_dleft <= w_dleft - g_n;
                    w_first <= 1'b0;
                    w_pre   <= 1'b0;
                    if (w_dleft == {20'd0, g_n}) begin
                        // the row is done
                        w_rows <= w_rows - 1'b1;
                        w_srow <= w_desc ? w_srow - {{8{w_sstr[15]}}, w_sstr} : w_srow + {{8{w_sstr[15]}}, w_sstr};
                        w_arow <= w_desc ? w_arow - {{8{w_sstr[15]}}, w_sstr} : w_arow + {{8{w_sstr[15]}}, w_sstr};
                        w_drow <= w_desc ? w_drow - {{8{w_dstr[15]}}, w_dstr} : w_drow + {{8{w_dstr[15]}}, w_dstr};
                        mode[cur] <= M_ROW;
                    end
                    es <= S_SAVE;
                end
            end

            // ---------------------------------------------------- LINE
            // E's two steps and the address's two steps, from the fixed fields
            S_LSET: begin : lset
                reg [26:0] xs, ys;
                l_ins  <= {1'b0, l_nn, 1'b0};
                l_ind  <= {1'b0, l_nn, 1'b0} - {1'b0, l_mm, 1'b0};               // 2(N - M)
                xs = {22'd0, l_bits};
                ys = {{8{w_dstr[15]}}, w_dstr, 3'b000};
                if (l_xneg) xs = 27'd0 - xs;
                if (l_yneg) ys = 27'd0 - ys;
                l_dmaj <= l_ymaj ? ys : xs;
                l_dmin <= l_ymaj ? xs : ys;
                l_k    <= 4'd0;
                es     <= S_LPIX;
            end
            // the next pixel: drawn, left alone or clipped
            S_LPIX: begin
                r_iss <= 5'd0; r_got <= 5'd0;
                l_c   <= 16'd0;                  // (C not read: the result does not use it)
                if (w_dleft == 24'd0 && is_e) begin
                    w_rows <= w_rows - 1'b1;     // EDGES: on to the next edge
                    w_aw   <= w_aw + 1'b1;
                    es     <= S_EFETCH;
                end else if (w_dleft == 24'd0) begin
                    if (!mem_req) begin          // the line is done, its last write taken
                        w_rows    <= 16'd0;
                        mode[cur] <= M_ROW;
                        es        <= S_SAVE;
                    end
                end else if (!l_in || l_keep)
                    es <= S_LSTEP;
                else
                    es <= l_needc ? S_LRD : S_LCMB;
            end
            S_LRD: begin
                if (xq_take) r_iss <= 5'd1;
                if (x_rv) begin
                    l_c   <= x_rd;
                    r_got <= 5'd1;
                end
                if (e_bad) begin
                    if (!mem_req) es <= S_DRAIN;
                end else if (r_got == 5'd1 && !mem_req)
                    es <= S_LCMB;
            end
            S_LCMB: begin
                b_out <= (l_res & l_pm) | (l_c & ~l_pm);
                b_be  <= {|l_pm[15:8], |l_pm[7:0]};
                r_iss <= 5'd0;
                es    <= S_LWR;
            end
            S_LWR: begin
                if (xq_take) r_iss <= 5'd1;
                if (e_bad) begin
                    if (!mem_req) es <= S_DRAIN;
                end else if (r_iss == 5'd1 || xq_take)
                    es <= S_LSTEP;
            end
            // on along the line (after the last pixel the count reaches 0)
            S_LSTEP: begin
                w_dleft <= w_dleft - 1'b1;
                w_ao    <= w_ao + 1'b1;
                w_sw    <= {5'd0, l_e + (l_minor ? l_ind : l_ins)};
                // 23-bit byte addresses, wrapping (spec 14, section 3.4)
                {w_dw, w_od} <= ({w_dw, w_od} + l_dmaj + (l_minor ? l_dmin : 27'd0)) & 27'h3FFFFFF;
                if (l_ymaj || l_minor) w_srow[15:0] <= l_yneg ? l_y - 1'b1 : l_y + 1'b1;
                if (!l_ymaj || l_minor) w_arow[15:0] <= l_xneg ? l_x - 1'b1 : l_x + 1'b1;
                l_k <= l_k + 1'b1;
                // a turn is 16 pixels, then the other channels have theirs
                es  <= (l_k == 4'd15) ? S_SAVE : S_LPIX;
            end

            // ---------------------------------------------------- EDGES
            // the next edge's word, or the end of the job
            S_EFETCH: begin
                if (w_rows == 16'd0) begin
                    if (!mem_req) begin          // every edge done, the last write taken
                        mode[cur] <= M_ROW;
                        es        <= S_SAVE;
                    end
                end else begin
                    if (xq_take) r_iss <= 5'd1;
                    if (x_rv) begin
                        e_ab  <= mem_rdata;       // the even byte (a) in bits 7-0
                        r_got <= 5'd1;
                    end
                    if (e_bad) begin
                        if (!mem_req) es <= S_DRAIN;
                    end else if (r_got == 5'd1 && !mem_req) begin
                        r_iss <= 5'd0; r_got <= 5'd0;
                        es    <= S_EPTS;
                    end
                end
            end
            // its two points: x and y of a, then of b
            S_EPTS: begin
                if (xq_take) r_iss <= r_iss + 1'b1;
                if (x_rv) begin
                    case (r_got[1:0])
                        2'd0: e_x0 <= mem_rdata;
                        2'd1: e_y0 <= mem_rdata;
                        2'd2: e_x1 <= mem_rdata;
                        default: e_y1 <= mem_rdata;
                    endcase
                    r_got <= r_got + 1'b1;
                end
                if (e_bad) begin
                    if (!mem_req) es <= S_DRAIN;
                end else if (r_got == 5'd4 && !mem_req)
                    es <= S_ECALC;
            end
            // left out, or set up as a line
            S_ECALC: begin
                r_iss <= 5'd0; r_got <= 5'd0;
                if (e_range || e_beyond) begin
                    w_rows <= w_rows - 1'b1;
                    w_aw   <= w_aw + 1'b1;
                    es     <= S_EFETCH;
                end else begin
                    w_le    <= {1'b0, e_dy[16], e_dx[16], e_ymaj};
                    w_carry <= e_n;
                    w_aleft <= {8'd0, e_m};
                    w_dleft <= {8'd0, e_m} + 1'b1;
                    w_sw    <= {6'd0, e_n, 1'b0} - {7'd0, e_m};        // 2N - M
                    w_ao    <= 4'd0;
                    w_arow[15:0] <= e_x0;
                    w_srow[15:0] <= e_y0;
                    e_mul   <= $signed(e_y0) * $signed(w_dstr);
                    es      <= S_EADDR;
                end
            end
            // the first pixel's bit address: origin + 8 y stride + x BPP
            S_EADDR: begin
                {w_dw, w_od} <= ({w_dptf, 3'b000} + ({24'd0, w_dbit} << w_lb) + {e_mul[23:0], 3'b000}
                                 + ({{11{e_x0[15]}}, e_x0} << w_lb)) & 27'h3FFFFFF;
                es <= S_LSET;
            end

            // after an error: wait for every read asked for to come back
            S_DRAIN: if (chip_out == 5'd0 && !mem_req) es <= S_SAVE;

            // ---------------------------------------------------- end of a group or job
            S_SAVE: begin
                st[cur] <= w_pack;
                w_live <= 1'b1;
                w_ch   <= cur;
                es <= S_IDLE;
                if (e_bad) begin
                    busy[cur]  <= 1'b0;
                    err[cur]   <= 1'b1;
                    dint[cur]  <= 1'b1;
                    cherr[cur] <= e_addr;
                end else if (w_rows == 16'd0 && (mode[cur] == M_ROW || mode[cur] == M_SETUP)) begin
                    // the job is done
                    if (w_irq) dint[cur] <= 1'b1;
                    if (w_next != 24'd0 && !stopreq[cur]) begin
                        chdesc[cur] <= w_next;
                        mode[cur]   <= M_LOAD;
                    end else begin
                        busy[cur]    <= 1'b0;
                        done[cur]    <= 1'b1;
                        stopreq[cur] <= 1'b0;
                    end
                end else if (stopreq[cur]) begin
                    busy[cur]    <= 1'b0;
                    done[cur]    <= 1'b1;
                    stopreq[cur] <= 1'b0;
                end
            end
            default: es <= S_IDLE;
            endcase

            // ---------------------------------------------------- register writes
            if (rb_wr) begin
                if (sel_int)        dint   <= dint & ~rb_wdata[3:0];
                else if (sel_inten) dinten <= rb_wdata[3:0];
                else if (sel_clip) begin
                    if (ro[0]) clip[clip_i][15:8] <= rb_wdata;
                    else       clip[clip_i][7:0]  <= rb_wdata;
                end
                else if (sel_ctl) begin
                    if ((rb_wdata[0] || rb_wdata[1]) && !busy[rch]) begin
                        busy[rch]    <= 1'b1;
                        stopreq[rch] <= 1'b0;
                        mode[rch]    <= rb_wdata[0] ? M_LOAD : M_SETUP;
                    end
                    if (rb_wdata[2] && busy[rch]) stopreq[rch] <= 1'b1;
                    pause[rch] <= rb_wdata[3];
                end else if (sel_stat) begin
                    if (rb_wdata[1]) done[rch] <= 1'b0;
                    if (rb_wdata[2]) err[rch]  <= 1'b0;
                end else if (sel_cd && !busy[rch])
                    chdesc[rch][8*ro[1:0] +: 8] <= rb_wdata;
            end
            for (i = 0; i < 4; i = i + 1)
                if (tmr_start[i] && !busy[i]) begin
                    busy[i]    <= 1'b1;
                    stopreq[i] <= 1'b0;
                    mode[i]    <= M_LOAD;
                end
        end
    end
endmodule
