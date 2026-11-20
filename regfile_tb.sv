// -----------------------------------------------------------------------------
// regfile_tb.sv — directed testbench for regfile.sv
// STATUS: NOT YET SIMULATED IN THIS ENVIRONMENT (see docs/phase2-environment.md)
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module regfile_tb;

    logic        clk = 0;
    logic        reset;
    logic        we;
    logic [4:0]  rs1, rs2, rd;
    logic [31:0] wd, rd1, rd2;

    int pass_count = 0;
    int fail_count = 0;

    regfile #(.XLEN(32), .WRITE_FIRST(1'b1)) dut (
        .clk(clk), .reset(reset), .we(we),
        .rs1_addr(rs1), .rs2_addr(rs2), .rd_addr(rd),
        .rd_wdata(wd), .rs1_rdata(rd1), .rs2_rdata(rd2)
    );

    always #5 clk = ~clk;

    task automatic check(string name, logic [31:0] got, logic [31:0] expected);
        if (got === expected) begin
            $display("[PASS] %s", name);
            pass_count++;
        end else begin
            $display("[FAIL] %s : expected=0x%08h got=0x%08h", name, expected, got);
            fail_count++;
        end
    endtask

    // All stimulus changes below happen on @(negedge clk), never adjacent
    // to @(posedge clk). This gives a full half-period of setup time before
    // the edge that samples them, eliminating the blocking-assignment /
    // synchronous-sampling race that caused the original failures (see
    // docs/phase3-regfile-debug.md for the full diagnosis).
    initial begin
        $dumpfile("sim/regfile_tb.vcd");
        $dumpvars(0, regfile_tb);
        reset = 1; we = 0; rs1 = 0; rs2 = 0; rd = 0; wd = 0;
        @(negedge clk); // let reset be sampled HIGH on the next posedge cleanly
        @(posedge clk); // reset applied
        @(negedge clk);
        reset = 0;       // deassert with full setup margin before next posedge

        // x0 always reads zero, even after attempted write
        we = 1; rd = 5'd0; wd = 32'hDEADBEEF;
        @(posedge clk); // write attempted (and discarded, rd=0)
        @(negedge clk);
        we = 0; rs1 = 5'd0;
        #1;
        check("x0 stays zero after write attempt", rd1, 32'd0);

        // basic write then read on a later cycle
        we = 1; rd = 5'd5; wd = 32'h0000_002A; // 42
        @(posedge clk); // write commits here
        @(negedge clk);
        we = 0; rs1 = 5'd5;
        #1;
        check("write x5=42 then read", rd1, 32'd42);

        // dual read ports simultaneously
        we = 1; rd = 5'd10; wd = 32'h0000_0064; // 100
        @(posedge clk); // write commits here
        @(negedge clk);
        we = 0; rs1 = 5'd5; rs2 = 5'd10;
        #1;
        check("dual read rs1=x5", rd1, 32'd42);
        check("dual read rs2=x10", rd2, 32'd100);

        // write-first: write x7 and read x7 in the SAME cycle (combinational
        // bypass must fire BEFORE the write commits on the next posedge)
        we = 1; rd = 5'd7; wd = 32'hCAFEBABE; rs1 = 5'd7;
        #1; // combinational read should see new value immediately (write-first)
        check("write-first same-cycle read", rd1, 32'hCAFEBABE);
        @(posedge clk); // commit the write
        @(negedge clk);
        we = 0;
        #1;
        check("write-first value persists next cycle", rd1, 32'hCAFEBABE);

        $display("\n%0d/%0d tests passed", pass_count, pass_count + fail_count);
        if (fail_count > 0) $fatal(1, "regfile testbench had failures");
        $finish;
    end

endmodule
