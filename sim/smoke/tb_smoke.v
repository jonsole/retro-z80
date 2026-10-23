// Smoke test for the tool chain (ticket #1): reads the ROM image that
// sjasmplus and tools/bin2hex.py made from smoke.asm and checks its words.
// The image is little-endian: the byte at an even address is the low half.
`timescale 1ns / 1ps

module tb_smoke;
    reg [15:0] rom [0:15];
    integer errors = 0;

    task check(input integer a, input [15:0] want);
        if (rom[a] !== want) begin
            $display("word %0d: %04h, want %04h", a, rom[a], want);
            errors = errors + 1;
        end
    endtask

    initial begin
        $readmemh("smoke.hex", rom);
        // di (F3), ld sp,0 (31 00 00), jp 0 (C3 00 00), "Z80" (5A 38 30)
        check(0, 16'h31F3);
        check(1, 16'h0000);
        check(2, 16'h00C3);
        check(3, 16'h5A00);
        check(4, 16'h3038);
        if (errors == 0) $display("TEST PASSED");
        else $display("TEST FAILED: %0d words wrong", errors);
        $finish;
    end
endmodule
