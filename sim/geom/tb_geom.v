// Unit test of the geometry unit (fpga/rtl/geom.v, spec 15) against its
// model (tools/geom_model.py). The model writes a script of register bus
// operations (geom_vec.txt in the build folder); this bench runs it and
// checks every byte read. Results must be ready LIMIT clocks after the
// write that starts a job: the first read comes then, and BUSY must be
// clear. It also measures how long each job keeps BUSY set.
`timescale 1ns/1ps
`include "regmap.vh"

module tb_geom;
    parameter LIMIT = 24;

    reg         clk = 0, rst = 1;
    always #5 clk = !clk;

    reg         rb_rd = 0, rb_wr = 0;
    reg  [12:0] rb_addr = 0;
    reg  [7:0]  rb_wdata = 0;
    wire [7:0]  rb_rdata;
    wire        rb_hit, busy;

    geom dut (
        .clk(clk), .rst(rst),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
        .rb_rdata(rb_rdata), .rb_hit(rb_hit), .busy(busy)
    );

    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    // BUSY time of each job, from its start write
    integer start_t = 0, tracking = 0, lat, max_lat = 0, jobs = 0;
    always @(posedge clk)
        if (tracking && !busy) begin
            lat = cyc - start_t;
            if (lat > max_lat) max_lat = lat;
            tracking = 0;
        end

    integer errors = 0, reads = 0;
    reg [8*200-1:0] note;

    task bus_write(input [7:0] a, input [7:0] d);
        begin
            @(negedge clk);
            rb_wr = 1; rb_addr = {5'd0, a}; rb_wdata = d;
            @(negedge clk);
            rb_wr = 0;
        end
    endtask

    task bus_read(input [7:0] a, input [7:0] want);
        begin
            @(negedge clk);
            rb_rd = 1; rb_addr = {5'd0, a};
            @(negedge clk);
            rb_rd = 0;
            reads = reads + 1;
            if (!rb_hit || rb_rdata !== want) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("ERROR: register %h read %h (hit %b), expected %h; %0s", a, rb_rdata, rb_hit, want, note);
            end
        end
    endtask

    integer fd, n, c;
    reg [8*8-1:0] opc;
    reg [31:0] a, d;
    initial begin
        fd = $fopen("geom_vec.txt", "r");
        if (fd == 0) begin
            $display("TEST FAILED: no geom_vec.txt (make geom writes it)");
            $finish;
        end
        note = "start";
        repeat (4) @(posedge clk);
        rst = 0;
        repeat (2) @(posedge clk);

        // An address outside the unit is not answered
        @(negedge clk); rb_rd = 1; rb_addr = 13'h0C0; @(negedge clk); rb_rd = 0;
        if (rb_hit) begin errors = errors + 1; $display("ERROR: 0xC0 answered"); end

        n = $fscanf(fd, "%s", opc);
        while (n == 1 && opc != "X") begin
            case (opc)
            "C": begin n = $fgets(note, fd); end
            "W": begin n = $fscanf(fd, "%h %h", a, d); bus_write(a[7:0], d[7:0]); end
            "S": begin
                n = $fscanf(fd, "%h %h", a, d);
                bus_write(a[7:0], d[7:0]);
                start_t = cyc - 1;     // the write's clock
                tracking = 1;
                jobs = jobs + 1;
            end
            "G": begin n = $fscanf(fd, "%h", a); repeat (a) @(negedge clk); end
            "E": begin
                while (cyc - start_t < LIMIT) @(negedge clk);
                if (busy) begin
                    errors = errors + 1;
                    if (errors <= 20) $display("ERROR: still busy %0d clocks after the start; %0s", LIMIT, note);
                end
            end
            "R": begin n = $fscanf(fd, "%h %h", a, d); bus_read(a[7:0], d[7:0]); end
            default: begin
                $display("TEST FAILED: unknown operation %0s in geom_vec.txt", opc);
                $finish;
            end
            endcase
            n = $fscanf(fd, "%s", opc);
        end

        // A start held while a job runs: two vertices back to back
        bus_write(8'hBE, 8'h00);
        bus_write(8'hBD, 8'h00);
        bus_write(8'hBD, 8'h00);
        if (!busy) begin errors = errors + 1; $display("ERROR: not busy after two starts"); end
        repeat (40) @(negedge clk);
        if (busy) begin errors = errors + 1; $display("ERROR: still busy after the held start"); end

        $display("geom: %0d jobs, %0d reads; longest BUSY %0d clocks (limit %0d)", jobs, reads, max_lat, LIMIT);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end
endmodule
