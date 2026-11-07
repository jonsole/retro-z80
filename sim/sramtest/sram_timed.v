// An asynchronous 1M x 16 SRAM for the SRAM tester's testbench, after
// retro-hw's sim/sram_model.v, with two differences: a bad write stores
// undefined data (so the tester sees it as read errors, not only as a
// message), and the output holds the old data for tOHA after the address
// changes. PART picks the figures:
//   10  IS61WV204816BLL-10 (as retro-hw's model and spec 2): tAA 10, tOHA 2.5,
//       tDOE 4.5, tHZOE 3, tPWE 8, tSD 6, tAW 8
//    8  the KS2's IS61WV102416FBLL-8, as fpga/ks2/README.md quotes it
//       (approximate): tAA 8, tOHA 2.5, tDOE 4, tHZOE 3, tPWE 6.5, tSD 5,
//       tAW 6.5
// tSA, tHA and tHD are 0. Errors are counted in errors and printed. AW
// address lines: 20 (2 MB, the KS2), or 21 for the fast-memory system
// testbench's 4 MB (sim/tb.v with FASTMEM, issue #91).
`timescale 1ns/1ps
module sram_timed #(
    parameter PART = 10,
    parameter AW   = 20
) (
    input  wire [AW-1:0] a,
    inout  wire [15:0] dq,
    input  wire        ce_n, oe_n, we_n, ub_n, lb_n,
    input  wire        fpga_drives       // for the bus-contention check
);
    real tAA, tOHA, tDOE, tHZOE, tPWE, tSD, tAW;
    initial begin
        if (PART == 8) begin
            tAA = 8.0; tOHA = 2.5; tDOE = 4.0; tHZOE = 3.0; tPWE = 6.5; tSD = 5.0; tAW = 6.5;
        end else begin
            tAA = 10.0; tOHA = 2.5; tDOE = 4.5; tHZOE = 3.0; tPWE = 8.0; tSD = 6.0; tAW = 8.0;
        end
    end

    reg [15:0] mem [0:(1<<AW)-1];
    integer errors = 0;
    integer quiet  = 0;          // errors printed: the first 20
    task err(input [8*48-1:0] what, input real v);
        begin
            errors = errors + 1;
            if (quiet < 20) $display("%t SRAM ERROR: %0s (%0.2f ns)", $realtime, what, v);
            quiet = quiet + 1;
        end
    endtask

    // ---- read
    real       t_a = -100.0, t_oe = -100.0, t_oeh = -100.0, t_d = -100.0, t_we = -100.0;
    reg [AW-1:0] a_old = {AW{1'b0}}, a_now = {AW{1'b0}};
    reg        old_ok = 1'b0;
    always @(a) begin
        old_ok = ($realtime - t_a >= tAA) && !oe_n && ($realtime - t_oe >= tDOE);
        a_old  = a_now;
        a_now  = a;
        t_a    = $realtime;
    end
    always @(negedge oe_n) t_oe  = $realtime;
    always @(posedge oe_n) t_oeh = $realtime;
    always @(dq)           t_d   = $realtime;

    // Evaluated every 125 ps
    reg        drive = 1'b0;
    reg [15:0] q = 16'hxxxx;
    always #0.125 begin
        drive = !ce_n && we_n && (!oe_n || ($realtime - t_oeh < tHZOE));
        if (!oe_n && ($realtime - t_a >= tAA) && ($realtime - t_oe >= tDOE))
            q = mem[a];
        else if (!oe_n && old_ok && ($realtime - t_a < tOHA))
            q = mem[a_old];
        else
            q = 16'hxxxx;
    end
    assign dq = drive ? {ub_n ? 8'hzz : q[15:8], lb_n ? 8'hzz : q[7:0]} : 16'hzzzz;

    // ---- contention
    reg cont = 1'b0;
    always #0.125 begin
        if (drive && fpga_drives && !cont) err("bus contention (SRAM and FPGA both drive DQ)", 0.0);
        cont = drive && fpga_drives;
    end

    // ---- write, on /WE rising
    reg bad_a = 1'b0;
    always @(negedge we_n) if (!ce_n) begin t_we = $realtime; bad_a = 1'b0; end
    always @(a) if (!we_n && !ce_n) begin
        err("address changed while /WE low", 0.0);
        bad_a = 1'b1;
    end
    reg bad;
    always @(posedge we_n) if (!ce_n) begin
        bad = bad_a;
        if ($realtime - t_we < tPWE) begin err("/WE pulse < tPWE", $realtime - t_we); bad = 1'b1; end
        if ($realtime - t_a  < tAW)  begin err("address valid before /WE high < tAW", $realtime - t_a); bad = 1'b1; end
        if ($realtime - t_d  < tSD)  begin err("data valid before /WE high < tSD", $realtime - t_d); bad = 1'b1; end
        if ((!ub_n && ^dq[15:8] === 1'bx) || (!lb_n && ^dq[7:0] === 1'bx)) begin
            err("writing undefined data", 0.0);
            bad = 1'b1;
        end
        if (!ub_n) mem[a][15:8] = bad ? 8'hxx : dq[15:8];
        if (!lb_n) mem[a][7:0]  = bad ? 8'hxx : dq[7:0];
    end
endmodule
