// CPU bus interface (spec 1, sections 4-6): turns the Z80's memory and I/O
// cycles into requests on the chipset buses, so that the Z80 never waits.
//
// Memory (spec 1, section 5). The core's address and early cycle-type
// outputs are looked at 3 clocks after the cen edge that starts T1 (E + 3),
// the MMU gives the page, and the access goes where the page says:
//   SRAM     a request to the scheduler, standing from E + 3; the scheduler
//            gives the CPU the first of cycles 0 and 2 that comes (E + 4 or
//            E + 5 at 20 MHz), and its data comes back 4 clocks later
//   boot ROM the block RAM answers in one clock; no SRAM cycle
//   others   (NONE, reserved; the register page comes with the MMU) 0xFF
// A write is posted the same way 3 clocks after the cen edge that starts
// T2, when dout is valid. The byte read is held at di until the next read,
// so the core can take it at the end of T2 whatever the speed.
//
// I/O (spec 1, section 6): one register bus strobe the clock after iorq_n
// goes low with rd_n or wr_n, at the address of section 6.1's decode; read
// data (or 0xFF if no unit answered, or for a reserved page) is held at di.
//
// Version for ticket #4: no register bus arbiter yet (the CPU is the only
// master), no capture (spec 3, rule 4), no interrupt vector (an acknowledge
// reads 0xFF), no NMI paging and no register page.
`include "regmap.vh"

module bus_if (
    input  wire        clk,
    input  wire        rst,            // with the core's reset
    input  wire        cen,            // the core's clock enable (a T-state per pulse)

    // The core (z80_cpu.v)
    input  wire [15:0] A,
    input  wire [7:0]  dout,
    input  wire [6:0]  mcycle,
    input  wire [6:0]  tstate,
    input  wire        iorq,
    input  wire        no_read,
    input  wire        write,
    input  wire        intcycle_n,
    input  wire        m1_n,
    input  wire        iorq_n,
    input  wire        rd_n,
    input  wire        wr_n,
    output reg  [7:0]  di,

    // MMU (mmu.v): the window and its pages
    output wire [2:0]  mmu_win,
    input  wire [9:0]  mmu_rpage,
    input  wire [9:0]  mmu_wpage,

    // Scheduler (dmac.v), CPU channel
    output reg         cpu_req,
    output reg         cpu_we,
    output reg  [21:1] cpu_addr,
    output reg  [15:0] cpu_wdata,
    output reg  [1:0]  cpu_be,
    input  wire        cpu_ack,
    input  wire        cpu_rvalid,
    input  wire [15:0] mem_rdata,

    // Boot ROM (bootrom.v)
    input  wire        romwe,          // SYSCON.ROMWE
    output reg         rom_en,
    output reg  [1:0]  rom_we,
    output reg  [14:1] rom_addr,
    output reg  [15:0] rom_wdata,
    input  wire [15:0] rom_rdata,

    // Register bus (spec 1, section 4.2), CPU as master
    output reg  [12:0] rb_addr,
    output reg  [7:0]  rb_hi,
    output reg         rb_rd,
    output reg         rb_wr,
    output reg  [7:0]  rb_wdata,
    input  wire [7:0]  rb_rdata,
    input  wire        rb_hit,

    // Checks: the core took a byte before it was at di (never, if the
    // timing of spec 1, section 5 holds)
    output reg         late
);
    // ---------------------------------------------------------------- timing
    // Clocks since the last cen edge: 0 in the clock just after it
    reg [2:0] tc;
    always @(posedge clk)
        if (cen)              tc <= 3'd0;
        else if (tc != 3'd7)  tc <= tc + 3'd1;
    wire at3 = (tc == 3'd2);           // the clock that ends at E + 3

    // ---------------------------------------------------------------- memory
    wire is_fetch = mcycle[0] && intcycle_n;
    wire is_ack   = mcycle[0] && !intcycle_n;
    wire is_read  = !mcycle[0] && !iorq && !no_read && !write;
    wire is_write = !mcycle[0] && !iorq && write;

    assign mmu_win = A[15:13];
    wire [9:0] page     = is_write ? mmu_wpage : mmu_rpage;
    wire       pg_sram  = !page[9];                     // 0x000-0x1FF
    wire       pg_rom   = (page[9:2] == 8'hFF);         // 0x3FC-0x3FF

    reg        rd_wait;                // a read waits for its byte
    reg        rd_hi;                  // ... and wants the odd byte (A0)
    reg        rom_rd;                 // the boot ROM answers in this clock
    reg        io_rd_d;                // an I/O read strobe was sent last clock
    reg        io_none;                // an I/O read of a reserved page

    always @(posedge clk) begin
        rom_en <= 1'b0;
        rom_we <= 2'b00;
        rom_rd <= rom_en && rom_we == 2'b00;
        late   <= 1'b0;
        if (rst) begin
            cpu_req <= 1'b0;
            cpu_we  <= 1'b0;
            rd_wait <= 1'b0;
            io_rd_d <= 1'b0;
            di      <= 8'hFF;
        end else begin
            if (cpu_ack) cpu_req <= 1'b0;

            if (at3 && tstate[1] && (is_fetch || is_read)) begin
                rd_hi <= A[0];
                if (pg_sram) begin
                    cpu_req  <= 1'b1;
                    cpu_we   <= 1'b0;
                    cpu_addr <= {page[8:0], A[12:1]};
                    cpu_be   <= 2'b11;
                    rd_wait  <= 1'b1;
                end else if (pg_rom) begin
                    rom_en   <= 1'b1;
                    rom_addr <= {page[1:0], A[12:1]};
                    rd_wait  <= 1'b1;
                end else
                    di <= 8'hFF;                        // NONE, reserved
            end
            if (at3 && tstate[1] && is_ack)
                di <= 8'hFF;                            // no interrupt controller yet

            if (at3 && tstate[2] && is_write) begin
                if (pg_sram) begin
                    cpu_req   <= 1'b1;
                    cpu_we    <= 1'b1;
                    cpu_addr  <= {page[8:0], A[12:1]};
                    cpu_be    <= A[0] ? 2'b10 : 2'b01;
                    cpu_wdata <= {dout, dout};
                end else if (pg_rom && romwe) begin
                    rom_en    <= 1'b1;
                    rom_we    <= A[0] ? 2'b10 : 2'b01;
                    rom_addr  <= {page[1:0], A[12:1]};
                    rom_wdata <= {dout, dout};
                end
            end

            if (cpu_rvalid && rd_wait) begin
                di      <= rd_hi ? mem_rdata[15:8] : mem_rdata[7:0];
                rd_wait <= 1'b0;
            end
            if (rom_rd && rd_wait) begin
                di      <= rd_hi ? rom_rdata[15:8] : rom_rdata[7:0];
                rd_wait <= 1'b0;
            end

            // The core takes a read's byte at the cen edge that ends T2
            if (cen && tstate[2] && (is_fetch || is_read) && rd_wait)
                late <= 1'b1;

            // I/O read data, the clock after the strobe
            if (rb_rd) io_rd_d <= 1'b1;
            if (io_rd_d) begin
                di      <= rb_hit ? rb_rdata : 8'hFF;
                io_rd_d <= 1'b0;
            end
            if (io_none) di <= 8'hFF;
        end
    end

    // ---------------------------------------------------------------- I/O
    // Port = register (A15-A8) : page (A7-A0), decoded as spec 1, section 6.1
    wire [7:0] lo = A[7:0];
    wire [7:0] hi = A[15:8];
    wire       p_low    = `RM_IS_LOWPORT(lo);           // 0x1F, 0x53, 0x5B, 0x62, 0xFE
    wire       p_sys    = (lo == 8'h00);
    wire       p_custom = (lo[7:2] == 6'b000100);       // 0x10-0x13
    wire [12:0] io_addr = p_low    ? {5'd0, lo} :
                          p_sys    ? {5'd0, hi} :
                                     {3'b100, lo[1:0], hi};
    wire       io_strobe = !iorq_n && m1_n && (!rd_n || !wr_n);

    reg io_seen;                       // this I/O cycle has had its strobe
    always @(posedge clk) begin
        rb_rd   <= 1'b0;
        rb_wr   <= 1'b0;
        io_none <= 1'b0;
        if (rst) begin
            io_seen <= 1'b0;
            rb_addr <= 13'd0;
            rb_hi   <= 8'd0;
        end else if (!io_strobe) begin
            io_seen <= 1'b0;
        end else if (!io_seen) begin
            io_seen  <= 1'b1;
            rb_addr  <= io_addr;
            rb_hi    <= p_low ? hi : 8'h00;
            rb_wdata <= dout;
            if (p_low || p_sys || p_custom) begin
                rb_rd <= !rd_n;
                rb_wr <= !wr_n;
            end else
                io_none <= !rd_n;
        end
    end
endmodule
