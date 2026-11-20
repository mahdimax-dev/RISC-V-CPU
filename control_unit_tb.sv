// -----------------------------------------------------------------------------
// control_unit_tb.sv — directed testbench for control_unit.sv
// STATUS: NOT YET SIMULATED IN THIS ENVIRONMENT (see docs/phase2-environment.md)
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module control_unit_tb;

    logic [6:0] opcode, funct7;
    logic [2:0] funct3;
    logic reg_write, alu_src, mem_read, mem_write, mem_unsigned, branch, jump, illegal;
    logic [3:0] alu_op;
    logic [1:0] mem_size, wb_sel;

    int pass_count = 0;
    int fail_count = 0;

    control_unit dut (
        .opcode(opcode), .funct3(funct3), .funct7(funct7),
        .reg_write(reg_write), .alu_src(alu_src), .alu_op(alu_op),
        .mem_read(mem_read), .mem_write(mem_write), .mem_size(mem_size),
        .mem_unsigned(mem_unsigned), .wb_sel(wb_sel),
        .branch(branch), .jump(jump), .illegal(illegal)
    );

    task automatic check(string name, logic got, logic expected);
        if (got === expected) begin
            $display("[PASS] %s", name); pass_count++;
        end else begin
            $display("[FAIL] %s : expected=%b got=%b", name, expected, got); fail_count++;
        end
    endtask

    task automatic check4(string name, logic [3:0] got, logic [3:0] expected);
        if (got === expected) begin
            $display("[PASS] %s", name); pass_count++;
        end else begin
            $display("[FAIL] %s : expected=%b got=%b", name, expected, got); fail_count++;
        end
    endtask

    initial begin
        // ADD (R-type, funct3=000, funct7=0000000)
        opcode = 7'b0110011; funct3 = 3'b000; funct7 = 7'b0000000; #1;
        check("ADD reg_write", reg_write, 1'b1);
        check4("ADD alu_op", alu_op, 4'b0000);
        check("ADD alu_src=0 (reg)", alu_src, 1'b0);

        // SUB (R-type, funct3=000, funct7=0100000 -> funct7[5]=1)
        opcode = 7'b0110011; funct3 = 3'b000; funct7 = 7'b0100000; #1;
        check4("SUB alu_op", alu_op, 4'b0001);

        // ADDI (I-type ALU, funct3=000)
        opcode = 7'b0010011; funct3 = 3'b000; funct7 = 7'b0000000; #1;
        check("ADDI alu_src=1 (imm)", alu_src, 1'b1);
        check4("ADDI alu_op", alu_op, 4'b0000);

        // SRAI (I-type ALU, funct3=101, funct7[5]=1)
        opcode = 7'b0010011; funct3 = 3'b101; funct7 = 7'b0100000; #1;
        check4("SRAI alu_op", alu_op, 4'b0111);

        // LW (load, funct3=010)
        opcode = 7'b0000011; funct3 = 3'b010; #1;
        check("LW mem_read", mem_read, 1'b1);
        check("LW reg_write", reg_write, 1'b1);
        check("LW wb_sel=mem(01)", wb_sel[0], 1'b1);

        // LBU (load, funct3=100 -> byte, unsigned)
        opcode = 7'b0000011; funct3 = 3'b100; #1;
        check("LBU mem_unsigned", mem_unsigned, 1'b1);

        // SW (store, funct3=010)
        opcode = 7'b0100011; funct3 = 3'b010; #1;
        check("SW mem_write", mem_write, 1'b1);
        check("SW reg_write=0", reg_write, 1'b0);

        // BEQ (branch)
        opcode = 7'b1100011; funct3 = 3'b000; #1;
        check("BEQ branch=1", branch, 1'b1);
        check("BEQ reg_write=0", reg_write, 1'b0);

        // JAL
        opcode = 7'b1101111; #1;
        check("JAL jump=1", jump, 1'b1);
        check("JAL reg_write=1 (link)", reg_write, 1'b1);

        // JALR
        opcode = 7'b1100111; funct3 = 3'b000; #1;
        check("JALR jump=1", jump, 1'b1);
        check("JALR alu_src=1", alu_src, 1'b1);

        // LUI
        opcode = 7'b0110111; #1;
        check("LUI reg_write=1", reg_write, 1'b1);

        // unrecognized opcode -> illegal
        opcode = 7'b1111111; #1;
        check("illegal opcode flagged", illegal, 1'b1);

        // --- REGRESSION (added after Phase 4 integration testing found a
        // real bug — see docs/phase4-datapath.md "Critical bug found") ---
        // ADDI with an immediate whose bit 10 is set (e.g. imm=-1, giving
        // raw instruction bits funct7=0b1111111) must still decode as ADD,
        // never SUB. This is the exact case that silently broke before
        // the fix: funct7[5] is part of the immediate here, not a real
        // opcode-select field, for every I-type ALU op except SRLI/SRAI.
        opcode = 7'b0010011; funct3 = 3'b000; funct7 = 7'b1111111; #1;
        check4("ADDI with imm-bit10=1 still selects ADD (regression)", alu_op, 4'b0000);

        // SRLI/SRAI must still correctly use funct7[5] after the fix
        // (funct3=101 is the one case where it's legitimate).
        opcode = 7'b0010011; funct3 = 3'b101; funct7 = 7'b0000000; #1;
        check4("SRLI (funct7[5]=0) still selects SRL (regression)", alu_op, 4'b0110);
        opcode = 7'b0010011; funct3 = 3'b101; funct7 = 7'b0100000; #1;
        check4("SRAI (funct7[5]=1) still selects SRA (regression)", alu_op, 4'b0111);

        $display("\n%0d/%0d tests passed", pass_count, pass_count + fail_count);
        if (fail_count > 0) $fatal(1, "control_unit testbench had failures");
        $finish;
    end

endmodule
