// The Z80: tv80's core with retro-z80's own copy of its synchronous wrapper
// (spec 1, section 2.1). It differs from tv80s.v in that:
//   1. cen is an input and goes to the core; the strobe flip-flops (mreq_n,
//      iorq_n, rd_n, wr_n) and the read data register change only on cen;
//   2. the core's early cycle-type outputs (mcycle, tstate, iorq, no_read,
//      write, intcycle_n) come out for the bus interface, which needs the
//      type of an M-cycle during T1;
//   3. the build defines TV80_REFRESH (sim/Makefile, fpga/lint.sh), so R
//      counts and rfsh_n works; the refresh strobe below follows it.
// Mode 0 (Z80), T2Write 1 (wr_n low from the start of T2), IOWait 1 (the
// standard I/O cycle with one automatic wait state).
//
// Not yet: nmicycle (spec 1, item 4) needs an added output port on
// tv80_core, which is left unchanged here (the NMI paging comes later).
module z80_cpu (
    input  wire        clk,
    input  wire        cen,           // one clock high per T-state
    input  wire        reset_n,
    input  wire        wait_n,
    input  wire        int_n,
    input  wire        nmi_n,
    input  wire        busrq_n,
    output wire        m1_n,
    output reg         mreq_n,
    output reg         iorq_n,
    output reg         rd_n,
    output reg         wr_n,
    output wire        rfsh_n,
    output wire        halt_n,
    output wire        busak_n,
    output wire [15:0] A,
    input  wire [7:0]  di,
    output wire [7:0]  dout,
    // Early cycle-type outputs (spec 1, section 2.1, item 2)
    output wire [6:0]  mcycle,        // one-hot: bit 0 = M1
    output wire [6:0]  tstate,        // one-hot: bit 1 = T1, bit 2 = T2 (and TW)
    output wire        iorq,          // this M-cycle is an I/O cycle
    output wire        no_read,       // ... has no read
    output wire        write,         // ... is a write
    output wire        intcycle_n     // the M1 is an interrupt acknowledge
);
    parameter Mode    = 0;
    parameter T2Write = 1;
    parameter IOWait  = 1;

    reg [7:0] di_reg;

    tv80_core #(Mode, IOWait) core (
        .cen        (cen),
        .m1_n       (m1_n),
        .iorq       (iorq),
        .no_read    (no_read),
        .write      (write),
        .rfsh_n     (rfsh_n),
        .halt_n     (halt_n),
        .wait_n     (wait_n),
        .int_n      (int_n),
        .nmi_n      (nmi_n),
        .reset_n    (reset_n),
        .busrq_n    (busrq_n),
        .busak_n    (busak_n),
        .clk        (clk),
        .IntE       (),
        .stop       (),
        .A          (A),
        .dinst      (di),
        .di         (di_reg),
        .dout       (dout),
        .mc         (mcycle),
        .ts         (tstate),
        .intcycle_n (intcycle_n)
    );

    // tv80s's strobe logic, on cen. The next values are worked out first
    // and each strobe is assigned once, so it never glitches in simulation
    // (tv80s assigns them twice in one clock).
    reg nx_rd_n, nx_wr_n, nx_iorq_n, nx_mreq_n;
    always @(*) begin
        nx_rd_n   = 1'b1;
        nx_wr_n   = 1'b1;
        nx_iorq_n = 1'b1;
        nx_mreq_n = 1'b1;
        if (mcycle[0]) begin
            if (tstate[1] || (tstate[2] && !wait_n)) begin
                nx_rd_n   = ~intcycle_n;
                nx_mreq_n = ~intcycle_n;
                nx_iorq_n = intcycle_n;
            end
            if (tstate[3])
                nx_mreq_n = 1'b0;                       // refresh (TV80_REFRESH)
        end else begin
            if ((tstate[1] || (tstate[2] && !wait_n)) && !no_read && !write) begin
                nx_rd_n   = 1'b0;
                nx_iorq_n = ~iorq;
                nx_mreq_n = iorq;
            end
            if (T2Write == 0) begin
                if (tstate[2] && write) begin
                    nx_wr_n   = 1'b0;
                    nx_iorq_n = ~iorq;
                    nx_mreq_n = iorq;
                end
            end else begin
                if ((tstate[1] || (tstate[2] && !wait_n)) && write) begin
                    nx_wr_n   = 1'b0;
                    nx_iorq_n = ~iorq;
                    nx_mreq_n = iorq;
                end
            end
        end
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            rd_n   <= 1'b1;
            wr_n   <= 1'b1;
            iorq_n <= 1'b1;
            mreq_n <= 1'b1;
            di_reg <= 8'h00;
        end else if (cen) begin
            rd_n   <= nx_rd_n;
            wr_n   <= nx_wr_n;
            iorq_n <= nx_iorq_n;
            mreq_n <= nx_mreq_n;
            if (tstate[2] && wait_n && !write && !no_read)
                di_reg <= di;
        end
    end
endmodule
