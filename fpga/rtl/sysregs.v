// System control registers, 0x70-0x77 of page 0x00 (spec 7, section 11.1).
// retro68k's sysregs.v narrowed to byte registers on the 8-bit register bus.
// Version for ticket #6: SYSID, SYSVER, SYSCFG, RESETWHY, SYSCON, SYSRESET,
// SYSBTN and CPUSPEED (section 6.1; the divider that uses it is cpu_cen.v).
// The I2C master (0x78-0x7B) and the NMI monitor registers (0x7C-0x7F)
// come later.
`include "regmap.vh"

module sysregs #(
    parameter [7:0] VERSION = 8'h01,   // SYSVER: MAJOR (7-4), MINOR (3-0)
    parameter [5:0] CHIPMB  = 6'd4     // SYSCFG.CHIPMB: a build constant
) (
    input  wire        clk,
    input  wire        rst,           // any reset
    input  wire        por,           // power-on reset only (ROMLOCK)

    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [12:0] rb_addr,
    input  wire [7:0]  rb_wdata,
    output reg  [7:0]  rb_rdata,
    output reg         rb_hit,        // with rb_rdata: this unit answered

    input  wire [7:0]  resetwhy,      // RESETWHY bits, from the reset logic
    input  wire [1:0]  buttons,       // MULTIFACE (0), DIVMMC (1), 1 = pressed

    output wire        romwe,
    output reg         soft_reset,    // 1 clock: SYSRESET written with 0xA5
    output reg  [3:0]  cpuspeed       // CPUSPEED: SPECTRUM (3), DIV (2-0)
);
    reg syscon_romwe;                 // SYSCON.ROMWE (cleared by every reset)
    reg romlock;                      // SYSCON.ROMLOCK (cleared only at power-on)

    assign romwe = syscon_romwe;

    wire sel = (rb_addr >= `RM_SYSID) && (rb_addr <= `RM_CPUSPEED);
    wire [7:0] syscfg = {CHIPMB, 2'd0};                 // CPU = 0: Z80

    always @(posedge clk) begin
        soft_reset <= 1'b0;
        if (por) romlock <= 1'b0;
        if (rst) begin
            syscon_romwe <= 1'b0;
            cpuspeed     <= 4'h0;                       // 20 MHz
        end else if (rb_wr) begin
            case (rb_addr)
                `RM_SYSCON: begin
                    // ROMWE cannot be set while ROMLOCK is (or becomes) 1
                    syscon_romwe <= rb_wdata[`RM_SYSCON_ROMWE] && !romlock && !rb_wdata[`RM_SYSCON_ROMLOCK];
                    if (rb_wdata[`RM_SYSCON_ROMLOCK]) romlock <= 1'b1;
                end
                `RM_CPUSPEED: cpuspeed <= rb_wdata[3:0];  // bits 7-4 not kept
                `RM_SYSRESET: if ({24'd0, rb_wdata} == `RM_SYSRESET_MAGIC) soft_reset <= 1'b1;
                default: ;
            endcase
        end

        rb_rdata <= 8'd0;
        rb_hit   <= rb_rd && sel;
        if (rb_rd) case (rb_addr)
            `RM_SYSID:    rb_rdata <= 8'h5A;                // "Z"
            `RM_SYSVER:   rb_rdata <= VERSION;
            `RM_SYSCFG:   rb_rdata <= syscfg;
            `RM_RESETWHY: rb_rdata <= resetwhy;
            `RM_SYSCON:   rb_rdata <= {5'd0, romlock, syscon_romwe, 1'b0};
            `RM_SYSBTN:   rb_rdata <= {6'd0, buttons};
            `RM_CPUSPEED: rb_rdata <= {4'd0, cpuspeed};
            default: ;                                      // SYSRESET reads 0x00
        endcase
    end
endmodule
