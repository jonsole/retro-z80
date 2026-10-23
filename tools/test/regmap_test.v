// Compiles fpga/rtl/regmap.vh with Icarus and checks the decodes (spec 3, section 9,
// test 11). Run by tools/Makefile.
`timescale 1ns / 1ps
`include "regmap.vh"

module regmap_test;
    integer errors = 0;
    reg [12:0] a;
    reg [7:0] lo;

    task expect(input cond, input [8*40-1:0] what);
        if (!cond) begin
            $display("FAIL: %0s", what);
            errors = errors + 1;
        end
    endtask

    initial begin
        expect(`RM_SYSID == 13'h0070, "SYSID");
        expect(`RM_BGCOLOR == 13'h1004, "BGCOLOR bus address");
        expect(`RM_SPR_H == 8'h03, "SPR_H offset");
        expect(`RM_SPR_BASE == 13'h1010, "SPR base");
        expect(`RM_TIME_BYTES == 4, "TIME width");
        a = `RM_TIME0;       expect(`RM_IS_CAP(a) && `RM_CAP_N(a) == 4, "TIME captures 4");
        a = `RM_TIME1;       expect(!`RM_IS_CAP(a), "TIME1 does not capture");
        a = 13'h005D;        expect(`RM_IS_CAP(a) && `RM_CAP_N(a) == 2, "SDCOUNT captures 2");
        a = 13'h1160;        expect(`RM_IS_CAP(a) && `RM_CAP_N(a) == 3, "DMX0 CHDESC captures 3");
        a = 13'h0051;        expect(!`RM_IS_CAP(a), "SERSTAT0 does not capture");
        a = 13'h1006;        expect(`RM_IS_COLR(a) && `RM_IS_COLR_RED(a), "BGCOLOR red commits");
        a = 13'h1004;        expect(`RM_IS_COLR(a) && !`RM_IS_COLR_RED(a), "BGCOLOR blue waits");
        a = 13'h0086;        expect(`RM_IS_MMU(a) && !`RM_IS_MMU_COMMIT(a), "MMU3_0 held");
        a = 13'h009F;        expect(`RM_IS_MMU(a) && `RM_IS_MMU_COMMIT(a), "MMU7W_1 commits");
        a = 13'h00A0;        expect(!`RM_IS_MMU(a), "0xA0 is not MMU");
        a = 13'h0002;        expect(`RM_IS_SC(a), "INTENA1 set/clear");
        a = 13'h100C;        expect(`RM_IS_SC(a), "DMACON set/clear");
        a = 13'h1121;        expect(`RM_IS_SC(a), "SPRDMA1 set/clear");
        a = 13'h0004;        expect(!`RM_IS_SC(a), "INTPEND0 is not set/clear");
        lo = 8'h53;          expect(`RM_IS_LOWPORT(lo), "0x53 low-byte-only");
        lo = 8'hFE;          expect(`RM_IS_LOWPORT(lo), "0xFE low-byte-only");
        lo = 8'h10;          expect(!`RM_IS_LOWPORT(lo), "0x10 is a page");
        if (errors == 0) $display("TEST PASSED");
        else $display("TEST FAILED");
        $finish;
    end
endmodule
