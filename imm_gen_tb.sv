// -----------------------------------------------------------------------------
// imm_gen_tb.sv — directed testbench for imm_gen.sv
// STATUS: NOT YET SIMULATED IN THIS ENVIRONMENT (see docs/phase2-environment.md)
// Expected values cross-checked against a Python bit-model before writing
// this file (see docs/phase3-rtl.md).
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module imm_gen_tb;

    logic [31:0] instr, imm;
    int pass_count = 0;
    int fail_count = 0;

    imm_gen dut (.instr(instr), .imm(imm));

    task automatic check(string name, logic [31:0] expected);
        #1;
        if (imm === expected) begin
            $display("[PASS] %s", name);
            pass_count++;
        end else begin
            $display("[FAIL] %s : expected=0x%08h got=0x%08h", name, expected, imm);
            fail_count++;
        end
    endtask

    initial begin
        // I-type: ADDI x1, x2, -1   (imm = 0xFFF, opcode 0010011)
        instr = {12'hFFF, 5'd2, 3'b000, 5'd1, 7'b0010011};
        check("I-type imm = -1", 32'hFFFFFFFF);

        // I-type: ADDI x1, x2, 2047 (max positive 12-bit)
        instr = {12'h7FF, 5'd2, 3'b000, 5'd1, 7'b0010011};
        check("I-type imm = 2047", 32'd2047);

        // S-type: SW x2, 8(x1)  -> imm=8 split across [11:5] and [4:0]
        // imm[11:5]=0000000, imm[4:0]=01000
        instr = {7'b0000000, 5'd2, 5'd1, 3'b010, 5'b01000, 7'b0100011};
        check("S-type imm = 8", 32'd8);

        // B-type: BEQ x1, x2, 8 (imm=8)
        // bit12=0 bits10_5=000000 rs2=2 rs1=1 funct3=0 bits4_1=0100 bit11=0
        instr = {1'b0, 6'b000000, 5'd2, 5'd1, 3'b000, 4'b0100, 1'b0, 7'b1100011};
        check("B-type imm = 8", 32'd8);

        // B-type: BEQ x1, x2, -8 (imm=-8)
        // -8 in 13-bit signed field split: bit12=1 bits10_5=111111 (6 bits) bits4_1=1100 bit11=1
        // (verified against a Python bit-model — see docs/phase3-rtl.md; an
        // earlier draft of this line had a 7-bit-wide bits10_5 field, off by
        // one bit — caught and fixed before delivery)
        instr = {1'b1, 6'b111111, 5'd2, 5'd1, 3'b000, 4'b1100, 1'b1, 7'b1100011};
        check("B-type imm = -8", 32'hFFFFFFF8);

        // U-type: LUI x1, 0xABCDE
        instr = {20'hABCDE, 5'd1, 7'b0110111};
        check("U-type imm", 32'hABCDE000);

        // J-type: JAL x1, 4 (imm=4)
        // bit20=0 bits19_12=00000000 bit11=0 bits10_1=0000000010
        instr = {1'b0, 10'b0000000010, 1'b0, 8'b00000000, 5'd1, 7'b1101111};
        check("J-type imm = 4", 32'd4);

        $display("\n%0d/%0d tests passed", pass_count, pass_count + fail_count);
        if (fail_count > 0) $fatal(1, "imm_gen testbench had failures");
        $finish;
    end

endmodule
