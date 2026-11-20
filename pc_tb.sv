// -----------------------------------------------------------------------------
// pc_tb.sv — directed testbench for pc.sv
// STATUS: NOT YET SIMULATED IN THIS ENVIRONMENT (see docs/phase2-environment.md)
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module pc_tb;

    logic clk = 0;
    logic reset, stall, branch_redirect;
    logic [31:0] branch_target, pc_next, pc_out;

    int pass_count = 0;
    int fail_count = 0;

    pc #(.RESET_VECTOR(32'h0000_0000)) dut (
        .clk(clk), .reset(reset), .stall(stall),
        .branch_redirect(branch_redirect), .branch_target(branch_target),
        .pc_next(pc_next), .pc_out(pc_out)
    );

    always #5 clk = ~clk;

    task automatic check(string name, logic [31:0] got, logic [31:0] expected);
        if (got === expected) begin
            $display("[PASS] %s", name); pass_count++;
        end else begin
            $display("[FAIL] %s : expected=0x%08h got=0x%08h", name, expected, got); fail_count++;
        end
    endtask

    initial begin
        reset = 1; stall = 0; branch_redirect = 0; branch_target = 0; pc_next = 32'h4;
        @(posedge clk); #1;
        check("reset vector", pc_out, 32'h0);

        reset = 0; pc_next = 32'h4;
        @(posedge clk); #1;
        check("advance to PC+4", pc_out, 32'h4);

        pc_next = 32'h8;
        @(posedge clk); #1;
        check("advance to PC+8", pc_out, 32'h8);

        // stall should hold current value even though pc_next changes
        stall = 1; pc_next = 32'hC;
        @(posedge clk); #1;
        check("stall holds PC", pc_out, 32'h8);

        stall = 0;
        @(posedge clk); #1;
        check("resume after stall", pc_out, 32'hC);

        // branch redirect takes priority over normal advance
        branch_redirect = 1; branch_target = 32'h1000; pc_next = 32'h10;
        @(posedge clk); #1;
        check("branch redirect", pc_out, 32'h1000);

        // branch redirect takes priority even if stall is also asserted
        branch_redirect = 1; branch_target = 32'h2000; stall = 1;
        @(posedge clk); #1;
        check("branch redirect overrides stall", pc_out, 32'h2000);

        $display("\n%0d/%0d tests passed", pass_count, pass_count + fail_count);
        if (fail_count > 0) $fatal(1, "pc testbench had failures");
        $finish;
    end

endmodule
