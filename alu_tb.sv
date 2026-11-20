// -----------------------------------------------------------------------------
// alu_tb.sv — directed testbench for alu.sv
//
// STATUS: NOT YET SIMULATED IN THIS ENVIRONMENT (no iverilog/verilator
// available in the sandbox — see docs/phase2-environment.md). Written to be
// run with:
//   iverilog -g2012 -o sim/alu_tb.out rtl/alu.sv tb/alu_tb.sv
//   vvp sim/alu_tb.out
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module alu_tb;

    logic [31:0] a, b, result;
    logic [3:0]  alu_op;
    logic        zero;

    int pass_count = 0;
    int fail_count = 0;

    alu #(.XLEN(32)) dut (
        .operand_a(a),
        .operand_b(b),
        .alu_op(alu_op),
        .result(result),
        .zero(zero)
    );

    task automatic check(string name, logic [31:0] expected);
        #1;
        if (result === expected) begin
            $display("[PASS] %s", name);
            pass_count++;
        end else begin
            $display("[FAIL] %s : expected=%0d (0x%08h) got=%0d (0x%08h)",
                      name, $signed(expected), expected, $signed(result), result);
            fail_count++;
        end
    endtask

    initial begin
        // ADD
        a = 32'd10; b = 32'd5; alu_op = 4'b0000; check("ADD 10+5", 32'd15);

        // ADD overflow wraparound
        a = 32'hFFFFFFFF; b = 32'd1; alu_op = 4'b0000; check("ADD wrap", 32'd0);

        // SUB
        a = 32'd5; b = 32'd10; alu_op = 4'b0001; check("SUB 5-10", -32'sd5);

        // SLL
        a = 32'h0000_0001; b = 32'd4; alu_op = 4'b0010; check("SLL 1<<4", 32'h0000_0010);

        // SLT (signed) : -1 < 1 -> 1
        a = 32'hFFFFFFFF; b = 32'd1; alu_op = 4'b0011; check("SLT -1<1", 32'd1);

        // SLT (signed) : 5 < 3 -> 0
        a = 32'd5; b = 32'd3; alu_op = 4'b0011; check("SLT 5<3", 32'd0);

        // SLTU : 0xFFFFFFFF < 1 (unsigned) -> 0
        a = 32'hFFFFFFFF; b = 32'd1; alu_op = 4'b0100; check("SLTU max<1", 32'd0);

        // XOR
        a = 32'hAAAAAAAA; b = 32'hFFFFFFFF; alu_op = 4'b0101; check("XOR", 32'h55555555);

        // SRL (logical, zero-fill)
        a = 32'h8000_0000; b = 32'd4; alu_op = 4'b0110; check("SRL", 32'h0800_0000);

        // SRA (arithmetic, sign-fill) : -8 >>> 1 = -4
        a = -32'sd8; b = 32'd1; alu_op = 4'b0111; check("SRA -8>>>1", -32'sd4);

        // OR
        a = 32'h0F0F0F0F; b = 32'hF0F0F0F0; alu_op = 4'b1000; check("OR", 32'hFFFFFFFF);

        // AND
        a = 32'hFF00FF00; b = 32'h0FF00FF0; alu_op = 4'b1001; check("AND", 32'h0F000F00);

        // zero flag
        a = 32'd7; b = 32'd7; alu_op = 4'b0001; #1;
        if (zero) $display("[PASS] zero flag on equal SUB");
        else begin $display("[FAIL] zero flag on equal SUB"); fail_count++; end

        $display("\n%0d/%0d tests passed", pass_count, pass_count + fail_count);
        if (fail_count > 0) $fatal(1, "ALU testbench had failures");
        $finish;
    end

endmodule
