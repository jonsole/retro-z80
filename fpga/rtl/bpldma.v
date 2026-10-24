// Layer fetch and the layers' pointer registers (spec 4, sections 4.4 and
// 5). 100 MHz domain. retro68k's bpldma.v, chunky only and on the 8-bit
// register bus.
//
// Each layer has one live pointer BPL0PT, which counts up as words are
// fetched, and 8 data registers inside (not registers software can reach,
// spec 4, section 2). There are no other buffers: a layer's data registers
// hold its next 16-pixel group while its shifters (layer_pix.v) show the
// current one.
//
// A layer is "full" once its group is complete: when the fetcher has
// fetched the last of its words (high data register to low). The pixel side
// then takes the group into its shifters when it needs it, and the fetcher
// fetches the next group. Full and taken cross between the clock domains as
// toggles (fill_t here, take_t there).
//
// The fetcher uses the display's memory cycles (1 and 3 of each slot, and
// any cycle nobody else wants; dmac.v). Each word goes to the layer whose
// deadline is nearest (earliest deadline first): when a layer's shifters
// take a group, its countdown loads the time that group lasts (16 source
// pixels, about 59 system clocks x the horizontal scale). Layers with equal
// countdowns take turns.
//
// Line by line: at line_go (start of horizontal blank, from the pixel
// domain) the next line's fetch starts. Each word fetched moves the pointer
// on by 2. The line's first word saves the pointer (the line's start); its
// last word sets the pointer to that start + BPLSTRIDE, or back to the
// start on a repeated line of a vertically scaled layer. So how many words
// are fetched (whole groups, fine scroll) never matters, and every pointer
// move goes through the one fetch path: a CPU write in the same clock wins,
// and also sets the saved start.
//
// Registers (spec 4, section 6.3), layer n at custom 0x090 + n x 0x20:
//   +0x10-0x11  BPLSTRIDE  signed, even (bit 0 reads 0)
//   +0x14-0x16  BPL0PT     bits 21-1, live; reading +0x14 captures all three
//                          bytes, and +0x15 and +0x16 of the same layer then
//                          read the captured bytes (spec 3, rule 4)
// Each byte is written directly (spec 3, rule 2).
//
// The capture is kept here for now, as BPL0PT is the only capturing
// register built: one for the CPU, tagged with the layer. It moves to the
// bus interface's tagged capture when BEAMPOS and FRAMECOUNT come.
//
// Changed from retro68k: no planar layers (one pointer per layer, so the
// pointers and their saved starts are plain registers, not RAMs); no data
// register writes and no BPLDMA (spec 4, open point V5); byte registers;
// the urgent mark is set 2 clocks earlier, since an urgent fetch never takes
// the CPU's cycles (spec 2, open point M5).
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

    // The next line, from the pixel domain (stable when line_t toggles)
    input  wire          line_t,
    input  wire [2:0] act,          // the layer shows on the next line
    input  wire [2:0] adv,          // ... and its pointer moves on after it (last copy of a source line)
    input  wire [5:0] lbpp,       // log2 of bits per pixel: words per group = 1 << lbpp
    input  wire [5:0] hscale,     // log2 of the horizontal scale (for the deadlines)
    input  wire [11:0] wrap,       // CTRL2.WRAP: 0 off, n = the pointer wraps in 2^(n+9) bytes
    input  wire [35:0] ngroups,   // groups to fetch
    output wire          line_go,      // 1 clock: a new line started here
    output wire          line_gen,     // toggles with line_go

    // To and from the pixel domain
    output wire [383:0] dat,      // 3 layers x 8 data registers x 16 bits, layer 0 register 0 lowest
    output reg  [2:0] fill_t,
    input  wire [2:0] take_t,

    // The scheduler's layer channel (dmac.v)
    output reg           req,
    output wire          urgent,       // req must not wait
    output wire [9:0]    deadline,     // system clocks until req's data is needed
    output reg  [21:1]   addr,
    input  wire          ack,
    input  wire          rvalid,
    input  wire [15:0]   rdata
);
    // ---------------------------------------------------------------- registers
    // Layer n at custom 0x090 + n x 0x20 (bus address 0x1090 + ...)
    wire [7:0]  lo  = rb_addr[7:0] - 8'h90;
    wire [1:0]  rn  = lo[6:5];
    wire [4:0]  off = lo[4:0];
    wire        sel = (rb_addr[12:8] == 5'h10) && (rb_addr[7:0] >= 8'h90) && ({1'b0, lo[7:5]} < NL);
    wire        sel_mod = sel && (off == 5'h10 || off == 5'h11);
    wire        sel_pt  = sel && (off == 5'h14 || off == 5'h15 || off == 5'h16);

    reg  [21:0] pt  [0:2];          // BPL0PT (bit 0 always 0)
    reg  [21:0] svm [0:2];          // its saved line start
    reg  [15:0] mod [0:2];          // BPLSTRIDE (bit 0 always 0)

    // Pointer wrap (spec 4, section 4.4): only the bits below the block size
    // change; the block is aligned to its size
    wire [21:0] wmask [0:2];
    genvar g;
    generate for (g = 0; g < 3; g = g + 1) begin : wraps
        assign wmask[g] = (wrap[4*g +: 4] == 4'd0) ? 22'h3FFFFF
                        : ~(22'h3FFFFF << ({1'b0, wrap[4*g +: 4]} + 5'd9));
    end endgenerate
    function [21:0] wadd(input [21:0] p, input [21:0] d, input [21:0] m);
        wadd = (p & ~m) | ((p + d) & m);
    endfunction

    reg  [15:0] dr [0:23];         // the data registers
    generate for (g = 0; g < 24; g = g + 1) begin : dout
        assign dat[16*g +: 16] = dr[g];
    end endgenerate

    // ---------------------------------------------------------------- fetch state
    reg  [1:0]  line_s;
    assign line_go = line_s[1] != line_s[0];
    reg  [2:0] gen;
    assign line_gen = gen[0];
    (* ASYNC_REG = "TRUE" *) reg [2:0] take_s1, take_s2;
    reg  [2:0] take_s3;
    wire [2:0] full = fill_t ^ take_s2;

    reg  [11:0] left   [0:2];       // groups still to start
    reg  [11:0] ngr    [0:2];       // groups to fetch on this line
    reg  [2:0] firstg, lastg;       // the group being fetched is the line's first, last
    reg  [7:0]  rem    [0:2];       // data registers of the current group still to ask for
    reg  [2:0] busy;                // a group is on its way (until its last word arrives)
    reg  [2:0] pv_adv;              // the line being fetched: its pointer moves on after it

    // Reads on the way: layer, data register, last word of its group, generation
    reg  [1:0]  q_layer [0:3];
    reg  [2:0]  q_plane [0:3];
    reg         q_last  [0:3];
    reg         q_gen   [0:3];
    reg  [1:0]  q_h, q_t;

    // The data registers a group fills: the layer's words (1 << lbpp of them)
    reg  [7:0]  emask [0:2];
    always @(*) begin : masks
        integer m;
        for (m = 0; m < 3; m = m + 1)
            emask[m] = 8'hFF >> (3'd7 - ((3'd1 << lbpp[2*m +: 2]) - 1'b1));
    end
    function [2:0] top(input [7:0] v);                 // highest set bit
        integer b;
        begin
            top = 3'd0;
            for (b = 0; b < 8; b = b + 1) if (v[b]) top = b[2:0];
        end
    endfunction

    // Deadlines: system clocks until each layer's shifters use up the group
    // they took last, so the next one must be in by then. The line's first
    // take (the group loaded ahead of the window) sets no deadline.
    reg  [9:0]  dl [0:2];
    reg  [2:0] first_take;
    reg  [1:0]  req_layer;
    function [3:0] ones(input [7:0] v);
        integer b;
        begin
            ones = 4'd0;
            for (b = 0; b < 8; b = b + 1) ones = ones + v[b];
        end
    endfunction
    // A request is urgent when its layer's deadline is close: the words
    // still to come at 50 ns each, plus about 160 ns for the wait for a
    // display cycle, the read and the crossing back (spec 4, section 5.3;
    // retro68k's 140 ns plus one memory cycle, as an urgent fetch here never
    // takes the CPU's cycles 0 and 2)
    wire [3:0]  words_left = ones(rem[req_layer]) + 1'b1;
    assign      urgent   = req && (dl[req_layer] < 10'd16 + {words_left, 2'b00} + words_left);
    assign      deadline = dl[req_layer];

    // A fetch takes two clocks, for timing (memory cycles are two clocks
    // apart, so this costs no bandwidth):
    //   A  pick the layer and its data register, and read the pointer and
    //      the saved line start;
    //   B  work out the pointer's next value and write it, move the group
    //      counts on, and hand the request on: to req if it is free, else
    //      to a one-entry holding place (nxt).
    // B starts again from A if the line starts, or the CPU writes a pointer,
    // meanwhile.
    reg         phase;                 // 0: A, 1: B
    reg  [2:0] want;
    reg         dlt [0:8];             // dlt[3a + b]: dl[a] < dl[b]
    reg  [7:0]  em  [0:2];          // emask, registered
    reg  [1:0]  pick, last;
    integer n, k;

    // Who asks next: of the layers with a group being asked for, or able to
    // start one, the one with the nearest deadline; on a tie, the next after
    // the last one served
    always @(*) begin : choose
        integer o;
        reg [1:0] c;
        reg       found;
        found = 1'b0;
        pick  = 2'd0;
        c     = last;
        for (o = 1; o <= 3; o = o + 1) begin
            c = (c == 2'd2) ? 2'd0 : c + 1'b1;      // round-robin order after the last
            if (want[c] && (!found || dlt[3*c + pick])) begin
                found = 1'b1;
                pick  = c;
            end
        end
    end
    // The data register to fill next: high to low
    reg         gs_l [0:2];
    reg  [7:0]  gm_l [0:2], rn_l [0:2];
    reg  [2:0]  pl_l [0:2];
    always @(*) begin : nextreg
        integer m;
        for (m = 0; m < 3; m = m + 1) begin
            gs_l[m] = (rem[m] == 8'd0);                            // a new group
            gm_l[m] = gs_l[m] ? em[m] : rem[m];
            pl_l[m] = top(gm_l[m]);
            rn_l[m] = gm_l[m] & ~(8'd1 << pl_l[m]);
        end
    end
    wire        gstart  = gs_l[pick];
    wire [7:0]  gmask   = gm_l[pick];
    wire [2:0]  pl_n    = pl_l[pick];
    wire [7:0]  rem_n   = rn_l[pick];

    // The line's first and last words: the first word of its first group,
    // the last word of its last group
    wire        first_w = gstart && (left[pick] == ngr[pick]);
    wire        last_w  = (gstart ? (left[pick] == 12'd1) : lastg[pick]) && rem_n == 8'd0;

    // A CPU write to a pointer byte: the live pointer with that byte changed
    wire        cpu_pw   = rb_wr && sel_pt;
    wire [21:0] cpu_old  = pt[rn];
    wire [21:0] cpu_new  = (off == 5'h14) ? {cpu_old[21:8], rb_wdata[7:1], 1'b0} :
                           (off == 5'h15) ? {cpu_old[21:16], rb_wdata, cpu_old[7:0]} :
                                            {rb_wdata[5:0], cpu_old[15:0]};

    // A: start a fetch
    wire        a_go     = !rst && !phase && !line_go && !cpu_pw && |want && gmask != 8'd0;
    reg  [1:0]  a_pick;
    reg  [2:0]  a_pl;
    reg         a_gstart, a_first_w, a_last_w;
    reg  [7:0]  a_rem_n;
    reg  [21:0] a_pt, a_sv;
    always @(posedge clk) if (a_go) begin
        a_pick    <= pick;
        a_pl      <= pl_n;
        a_gstart  <= gstart;
        a_rem_n   <= rem_n;
        a_first_w <= first_w;
        a_last_w  <= last_w;
        a_pt      <= pt[pick];
        a_sv      <= svm[pick];
    end

    // B: finish it, if there is room for the request
    reg         nxt_v;                 // the holding place
    reg  [1:0]  nxt_layer;
    reg  [2:0]  nxt_plane;
    reg         nxt_last, nxt_gen;
    reg  [21:1] nxt_addr;
    wire        b_abort  = line_go || cpu_pw;
    wire        b_go     = !rst && phase && !b_abort && !(req && !ack && nxt_v)
                           && (!a_gstart || left[a_pick] != 12'd0);
    wire [21:0] start    = a_first_w ? a_pt : a_sv;                // this line's start
    wire [21:0] stride   = pv_adv[a_pick] ? {{6{mod[a_pick][15]}}, mod[a_pick]} : 22'd0;
    wire [21:0] pt_next  = a_last_w ? wadd(start, stride, wmask[a_pick]) : wadd(a_pt, 22'd2, wmask[a_pick]);

    always @(posedge clk) begin
        for (n = 0; n < 3; n = n + 1) begin
            em[n] <= emask[n];
            for (k = 0; k < 3; k = k + 1) dlt[3*n + k] <= dl[n] < dl[k];
            want[n] <= !rst && !line_go &&
                       ((b_go && a_pick == n) ? (a_rem_n != 8'd0)
                        : (rem[n] != 0) || (left[n] != 0 && !busy[n] && !full[n] && em[n] != 8'd0));
        end
        if (rst || line_go)  phase <= 1'b0;
        else if (a_go)       phase <= 1'b1;
        else if (b_go || b_abort) phase <= 1'b0;
    end

    always @(posedge clk) begin
        line_s  <= {line_s[0], line_t};
        take_s1 <= take_t;
        take_s2 <= take_s1;
        take_s3 <= take_s2;
        for (n = 0; n < 3; n = n + 1)
            if (take_s3[n] != take_s2[n]) begin                     // a group was taken
                dl[n] <= first_take[n] ? 10'h3FF : 10'd59 << hscale[2*n +: 2];
                first_take[n] <= 1'b0;
            end else if (dl[n] != 10'd0 && dl[n] != 10'h3FF) dl[n] <= dl[n] - 1'b1;
        if (rst) begin
            req    <= 1'b0;
            last   <= 2'd2;
            q_h    <= 2'd0;
            q_t    <= 2'd0;
            gen    <= 3'd0;
            fill_t <= 3'd0;
            busy   <= 3'd0;
            nxt_v  <= 1'b0;
            pv_adv <= 3'd0;
            lastg  <= 3'd0;
            first_take <= 3'd0;
            req_layer <= 2'd0;
            for (n = 0; n < 3; n = n + 1) begin
                left[n] <= 12'd0;  ngr[n] <= 12'd0;  rem[n] <= 8'd0;  dl[n] <= 10'h3FF;
                mod[n]  <= 16'd0;
                pt[n]   <= 22'd0;  svm[n] <= 22'd0;
            end
            for (n = 0; n < 24; n = n + 1) dr[n] <= 16'd0;
        end else begin
            // Data back from the SRAM (little-endian: the even byte, the
            // pixels further left, into the high half; spec 4, section 4.2)
            if (rvalid) begin
                if (q_gen[q_h] == gen[q_layer[q_h]]) begin
                    dr[{q_layer[q_h], q_plane[q_h]}] <= {rdata[7:0], rdata[15:8]};
                    if (q_last[q_h]) begin
                        fill_t[q_layer[q_h]] <= ~fill_t[q_layer[q_h]];
                        busy[q_layer[q_h]]   <= 1'b0;
                    end
                end
                q_h <= q_h + 1'b1;
            end

            // A request was taken
            if (ack) begin
                req <= 1'b0;
                q_t <= q_t + 1'b1;
            end

            if (line_go) begin
                // Start the next line
                for (n = 0; n < 3; n = n + 1) begin
                    left[n]   <= (enable && act[n]) ? ngroups[12*n +: 12] : 12'd0;
                    ngr[n]    <= (enable && act[n]) ? ngroups[12*n +: 12] : 12'd0;
                    rem[n]    <= 8'd0;
                    dl[n]     <= 10'h3FF;                     // no deadline until the first in-window take
                    first_take[n] <= 1'b1;
                    fill_t[n] <= take_s2[n];                 // empty: last line's spare group is dropped
                end
                pv_adv <= adv;
                busy   <= 3'd0;
                gen    <= ~gen;
                req    <= 1'b0;
                nxt_v  <= 1'b0;
            end else begin
                // The next request: from the holding place, else from B, as
                // soon as req is free (or being taken now)
                if (!req || ack) begin
                    if (nxt_v) begin
                        req       <= 1'b1;
                        req_layer <= nxt_layer;
                        addr      <= nxt_addr;
                        q_layer[q_t + (ack ? 1'b1 : 1'b0)] <= nxt_layer;
                        q_plane[q_t + (ack ? 1'b1 : 1'b0)] <= nxt_plane;
                        q_last[q_t + (ack ? 1'b1 : 1'b0)]  <= nxt_last;
                        q_gen[q_t + (ack ? 1'b1 : 1'b0)]   <= nxt_gen;
                        nxt_v     <= b_go;
                    end else if (b_go) begin
                        req       <= 1'b1;
                        req_layer <= a_pick;
                        addr      <= a_pt[21:1];
                        q_layer[q_t + (ack ? 1'b1 : 1'b0)] <= a_pick;
                        q_plane[q_t + (ack ? 1'b1 : 1'b0)] <= a_pl;
                        q_last[q_t + (ack ? 1'b1 : 1'b0)]  <= (a_rem_n == 8'd0);
                        q_gen[q_t + (ack ? 1'b1 : 1'b0)]   <= gen[a_pick];
                    end
                end else if (b_go)
                    nxt_v <= 1'b1;
                // B: the word is asked for
                if (b_go) begin
                    nxt_layer <= a_pick;
                    nxt_plane <= a_pl;
                    nxt_last  <= (a_rem_n == 8'd0);
                    nxt_gen   <= gen[a_pick];
                    nxt_addr  <= a_pt[21:1];
                    last      <= a_pick;
                    rem[a_pick] <= a_rem_n;
                    if (a_gstart) begin
                        left[a_pick]   <= left[a_pick] - 1'b1;
                        lastg[a_pick]  <= (left[a_pick] == 12'd1);
                        busy[a_pick]   <= 1'b1;
                    end
                end
            end

            // The pointer: a CPU write wins over the fetcher's own change,
            // and also sets the saved start
            if (cpu_pw) begin
                pt[rn]  <= cpu_new;
                svm[rn] <= cpu_new;
            end else if (b_go) begin
                pt[a_pick] <= pt_next;
                if (a_first_w) svm[a_pick] <= a_pt;
            end
            if (rb_wr && sel_mod) begin
                if (off == 5'h10) mod[rn][7:1]  <= rb_wdata[7:1];
                else              mod[rn][15:8] <= rb_wdata;
            end
        end
    end

    // ---------------------------------------------------------------- reads
    reg        cap_v;                  // the CPU's capture of a BPL0PT ...
    reg [1:0]  cap_l;                  // ... of this layer
    reg [21:0] cap;
    always @(posedge clk) begin
        rb_rdata <= 8'd0;
        rb_hit   <= rb_rd && (sel_mod || sel_pt);
        if (rst) cap_v <= 1'b0;
        if (rb_rd && sel_mod) rb_rdata <= (off == 5'h10) ? mod[rn][7:0] : mod[rn][15:8];
        if (rb_rd && sel_pt) case (off)
            5'h14: begin
                rb_rdata <= pt[rn][7:0];
                cap_v    <= 1'b1;
                cap_l    <= rn;
                cap      <= pt[rn];
            end
            5'h15:   rb_rdata <= (cap_v && cap_l == rn) ? cap[15:8] : pt[rn][15:8];
            default: rb_rdata <= {2'd0, (cap_v && cap_l == rn) ? cap[21:16] : pt[rn][21:16]};
        endcase
    end
endmodule
