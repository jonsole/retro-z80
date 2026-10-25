// Interrupt controller (spec 8): registers 0x00-0x0E of the system page.
// retro68k's intc.v narrowed to retro-z80: byte registers on the 8-bit
// register bus, 21 source numbers (0-20) with fixed priority by number (the
// Z80 has one /INT line, so no levels), IM 2 vectors VECBASE + 2n, INTID
// for IM 1, and the spurious entry 23 (NONE).
//
// Each unit raises a level request line while one of its flags is set and
// enabled in the unit; the controller keeps no request flags of its own,
// except SOFT (18). Numbers that are not used or are reserved (8, 9, 10,
// 16, 19, 20) request nothing: their lines are ignored here, so INTRAW
// reads 0 for them. A unit that comes later adds its number to USED.
//
// The acknowledge (spec 1, section 8.1): the bus interface raises vreq for
// one clock in the first T1 of the acknowledge cycle (E + 3). At that edge
// the controller picks the pending source with the lowest number (or NONE),
// writes it to INTID and puts its vector on `vector`, which then holds
// until the next acknowledge. int_ack, at the end of the cycle, ends the
// choice's freeze; it clears nothing.
//
// The NMI (section 10): an enabled event (a press of the button, a BREAK
// from the PC) sets its NMISTAT flag and the NMI request; nmi_n is low
// while the request is set, until the bus interface's nmi_ack, and is held
// high while NMICTL.INNMI is 1 (an NMI handler is running), so an NMI
// never nests: a request made meanwhile gives a new NMI right after RETN.
// The debug unit (spec 18, section 7; ticket #28) is the third source: its
// nmi_dbg pulses set the same request, with no NMICON or NMISTAT bit (its
// own enables and DBGSTAT say what asked).
`include "regmap.vh"

module intc (
    input  wire        clk,
    input  wire        rst,

    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [12:0] rb_addr,
    input  wire [7:0]  rb_wdata,
    output reg  [7:0]  rb_rdata,
    output reg         rb_hit,         // with rb_rdata: this unit answered

    input  wire [20:0] req,            // request lines from the units (bit n = source n)
    output reg         int_n,          // to the Z80
    input  wire        vreq,           // the bus interface asks for the vector (1 clock)
    output reg  [7:0]  vector,         // from the clock after vreq until the next one
    input  wire        int_ack,        // the end of the acknowledge cycle (1 clock)

    input  wire        nmi_button,     // debounced, 1 = pressed
    input  wire        nmi_usb,        // 1-clock pulse: BREAK from the PC
    input  wire        nmi_dbg,        // 1-clock pulse: the debug unit (dbgunit.v)
    input  wire        nmi_ack,        // the CPU has started its NMI response (1 clock)
    input  wire        innmi,          // NMICTL.INNMI (intpages.v)
    output wire        nmi_n           // to the Z80
);
    localparam integer SRC_SOFT = 18;
    localparam [4:0]   SRC_NONE = 5'd23;
    // Sources with a request line: 0-7, 11-15, 17 (spec 8, section 4)
    localparam [20:0]  USED = 21'b0_0010_1111_1000_1111_1111;

    // Registers 0x00-0x0E; 0x0F is reserved and left unanswered (0xFF)
    wire sel = (rb_addr[12:4] == 9'd0) && (rb_addr[3:0] != 4'hF);

    reg         master;
    reg  [20:0] intena;
    reg  [6:0]  vecbase;               // VEC (7-1)
    reg         soft_req;
    reg  [4:0]  intid;
    reg         frozen;                // between vreq and int_ack
    reg  [1:0]  nmicon, nmistat;
    reg         nmi_pend;
    reg         btn_d;

    wire [20:0] raw = (req & USED) | ({20'd0, soft_req} << SRC_SOFT);
    // Registered once, for timing: the lines come from all over the chip and
    // the priority encoder follows (spec 8, section 11: 1 clock)
    reg  [20:0] pending;
    always @(posedge clk)
        if (rst) begin
            pending <= 21'd0;
            int_n   <= 1'b1;
        end else begin
            pending <= raw & intena & {21{master}};
            int_n   <= !(|(raw & intena & {21{master}}));
        end

    // The pending source with the lowest number, or NONE
    integer n;
    reg [4:0] pick;
    always @(*) begin
        pick = SRC_NONE;
        for (n = 20; n >= 0; n = n - 1)
            if (pending[n]) pick = n[4:0];
    end

    assign nmi_n = !(nmi_pend && !innmi);

    always @(posedge clk) begin
        btn_d <= nmi_button;
        if (rst) begin
            master   <= 1'b0;
            intena   <= 21'd0;
            vecbase  <= 7'd0;
            soft_req     <= 1'b0;
            intid    <= 5'd0;
            frozen   <= 1'b0;
            vector   <= 8'd0;
            nmicon   <= 2'b11;
            nmistat  <= 2'b00;
            nmi_pend <= 1'b0;
        end else begin
            // The acknowledge: choose, and freeze until int_ack
            if (vreq && !frozen) begin
                intid  <= pick;
                vector <= {vecbase, 1'b0} + {2'd0, pick, 1'b0};
                frozen <= 1'b1;
            end
            if (int_ack) frozen <= 1'b0;

            // NMI: one per press or break
            if (nmi_ack) nmi_pend <= 1'b0;
            if (nmi_button && !btn_d && nmicon[0]) begin nmi_pend <= 1'b1; nmistat[0] <= 1'b1; end
            if (nmi_usb && nmicon[1])              begin nmi_pend <= 1'b1; nmistat[1] <= 1'b1; end
            if (nmi_dbg)                           nmi_pend <= 1'b1;

            if (rb_wr && sel) case (rb_addr)
                `RM_INTCON:  master <= rb_wdata[`RM_INTCON_MASTER];
                // Three set/clear bytes, 7 sources each (spec 3, rule 12)
                `RM_INTENA0: intena[6:0]   <= rb_wdata[7] ? intena[6:0]   | rb_wdata[6:0]
                                                          : intena[6:0]   & ~rb_wdata[6:0];
                `RM_INTENA1: intena[13:7]  <= rb_wdata[7] ? intena[13:7]  | rb_wdata[6:0]
                                                          : intena[13:7]  & ~rb_wdata[6:0];
                `RM_INTENA2: intena[20:14] <= rb_wdata[7] ? intena[20:14] | rb_wdata[6:0]
                                                          : intena[20:14] & ~rb_wdata[6:0];
                `RM_VECBASE: vecbase <= rb_wdata[7:1];
                `RM_SOFTINT: begin
                    if (rb_wdata[`RM_SOFTINT_SET]) soft_req <= 1'b1;
                    if (rb_wdata[`RM_SOFTINT_CLR]) soft_req <= 1'b0;
                end
                `RM_NMICON:  nmicon <= rb_wdata[1:0];
                `RM_NMISTAT: nmistat <= nmistat & ~rb_wdata[1:0];
                default: ;
            endcase
        end

        rb_rdata <= 8'd0;
        rb_hit   <= rb_rd && sel;
        if (rb_rd && sel) case (rb_addr)
            `RM_INTCON:   rb_rdata <= {7'd0, master};
            `RM_INTENA0:  rb_rdata <= {1'b0, intena[6:0]};
            `RM_INTENA1:  rb_rdata <= {1'b0, intena[13:7]};
            `RM_INTENA2:  rb_rdata <= {1'b0, intena[20:14]};
            `RM_INTPEND0: rb_rdata <= {1'b0, pending[6:0]};
            `RM_INTPEND1: rb_rdata <= {1'b0, pending[13:7]};
            `RM_INTPEND2: rb_rdata <= {1'b0, pending[20:14]};
            `RM_INTRAW0:  rb_rdata <= {1'b0, raw[6:0]};
            `RM_INTRAW1:  rb_rdata <= {1'b0, raw[13:7]};
            `RM_INTRAW2:  rb_rdata <= {1'b0, raw[20:14]};
            `RM_VECBASE:  rb_rdata <= {vecbase, 1'b0};
            `RM_INTID:    rb_rdata <= {3'd0, intid};
            `RM_NMICON:   rb_rdata <= {6'd0, nmicon};
            `RM_NMISTAT:  rb_rdata <= {6'd0, nmistat};
            default: ;                                  // SOFTINT reads 0x00
        endcase
    end
endmodule
