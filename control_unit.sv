// -----------------------------------------------------------------------------
// control_unit.sv — Corvid RV32I Control Unit
//
// Pure combinational decode of opcode/funct3/funct7 into the control signals
// consumed by the rest of the pipeline. Implemented as an explicit case-based
// decode table (not a black-box PLA) so it's directly traceable against the
// RV32I opcode map documented in docs/isa.md.
//
// alu_op values match the encoding defined in rtl/alu.sv.
// -----------------------------------------------------------------------------

module control_unit (
    input  logic [6:0] opcode,
    input  logic [2:0] funct3,
    input  logic [6:0] funct7,

    output logic       reg_write,   // write result back to register file
    output logic       alu_src,     // 0 = second ALU operand is rs2, 1 = immediate
    output logic [3:0] alu_op,      // see rtl/alu.sv encoding
    output logic       mem_read,
    output logic       mem_write,
    output logic [1:0] mem_size,    // 00=byte 01=half 10=word
    output logic       mem_unsigned,// zero-extend load (LBU/LHU) vs sign-extend
    output logic [1:0] wb_sel,      // 00=ALU result, 01=mem data, 10=PC+4 (link)
    output logic       branch,      // instruction is a conditional branch
    output logic       jump,        // instruction is JAL or JALR
    output logic       illegal      // decode did not recognize the opcode
);

    // RV32I opcode map
    localparam logic [6:0] OP_RTYPE  = 7'b0110011;
    localparam logic [6:0] OP_ITYPE  = 7'b0010011; // ALU-immediate
    localparam logic [6:0] OP_LOAD   = 7'b0000011;
    localparam logic [6:0] OP_STORE  = 7'b0100011;
    localparam logic [6:0] OP_BRANCH = 7'b1100011;
    localparam logic [6:0] OP_JAL    = 7'b1101111;
    localparam logic [6:0] OP_JALR   = 7'b1100111;
    localparam logic [6:0] OP_LUI    = 7'b0110111;
    localparam logic [6:0] OP_AUIPC  = 7'b0010111;
    localparam logic [6:0] OP_SYSTEM = 7'b1110011; // ECALL/EBREAK stub

    // alu_op encoding (must match rtl/alu.sv)
    localparam logic [3:0] ALU_ADD  = 4'b0000;
    localparam logic [3:0] ALU_SUB  = 4'b0001;
    localparam logic [3:0] ALU_SLL  = 4'b0010;
    localparam logic [3:0] ALU_SLT  = 4'b0011;
    localparam logic [3:0] ALU_SLTU = 4'b0100;
    localparam logic [3:0] ALU_XOR  = 4'b0101;
    localparam logic [3:0] ALU_SRL  = 4'b0110;
    localparam logic [3:0] ALU_SRA  = 4'b0111;
    localparam logic [3:0] ALU_OR   = 4'b1000;
    localparam logic [3:0] ALU_AND  = 4'b1001;

    // funct3-> ALU op for R-type / I-type ALU ops (funct7 bit 5 distinguishes
    // SUB from ADD, and SRA from SRL)
    function automatic logic [3:0] alu_op_from_funct(
        input logic [2:0] f3, input logic funct7_bit5
    );
        unique case (f3)
            3'b000:  alu_op_from_funct = funct7_bit5 ? ALU_SUB : ALU_ADD;
            3'b001:  alu_op_from_funct = ALU_SLL;
            3'b010:  alu_op_from_funct = ALU_SLT;
            3'b011:  alu_op_from_funct = ALU_SLTU;
            3'b100:  alu_op_from_funct = ALU_XOR;
            3'b101:  alu_op_from_funct = funct7_bit5 ? ALU_SRA : ALU_SRL;
            3'b110:  alu_op_from_funct = ALU_OR;
            3'b111:  alu_op_from_funct = ALU_AND;
            default: alu_op_from_funct = ALU_ADD;
        endcase
    endfunction

    always_comb begin
        // Safe defaults (NOP-like, all effects off)
        reg_write    = 1'b0;
        alu_src      = 1'b0;
        alu_op       = ALU_ADD;
        mem_read     = 1'b0;
        mem_write    = 1'b0;
        mem_size     = 2'b10; // word
        mem_unsigned = 1'b0;
        wb_sel       = 2'b00;
        branch       = 1'b0;
        jump         = 1'b0;
        illegal      = 1'b0;

        unique case (opcode)
            OP_RTYPE: begin
                reg_write = 1'b1;
                alu_src   = 1'b0;
                // funct7[5] is bit 5 of the 7-bit funct7 field (i.e. instr[30])
                alu_op    = alu_op_from_funct(funct3, funct7[5]);
                wb_sel    = 2'b00;
            end

            OP_ITYPE: begin
                reg_write = 1'b1;
                alu_src   = 1'b1;
                // BUG FIX (found during Phase 4 integration testing, see
                // docs/phase4-datapath.md "Critical bug found"): only
                // SRLI/SRAI (funct3=101) legitimately use funct7[5] to pick
                // shift direction, mirroring the R-type shift-immediate
                // encoding. For every OTHER I-type ALU-immediate op
                // (notably ADDI, funct3=000) the bit position that would be
                // funct7 in an R-type instruction is actually part of the
                // sign-extended 12-bit immediate — NOT a real opcode-select
                // field. The previous version called
                // alu_op_from_funct(funct3, funct7[5]) unconditionally,
                // which silently turned ADDI into SUB whenever immediate
                // bit 10 (instruction bit 30) was 1 — i.e. for roughly half
                // of all negative immediates. There is no "SUBI" in RV32I;
                // forcing the SUB-selector bit to 0 for every funct3 except
                // 101 makes this correct by construction rather than by
                // trusting the caller to pre-mask funct7 before calling in.
                alu_op    = alu_op_from_funct(funct3, (funct3 == 3'b101) ? funct7[5] : 1'b0);
                wb_sel    = 2'b00;
            end

            OP_LOAD: begin
                reg_write    = 1'b1;
                alu_src      = 1'b1;       // base + offset
                alu_op       = ALU_ADD;
                mem_read     = 1'b1;
                wb_sel       = 2'b01;      // memory data
                mem_unsigned = funct3[2];  // LBU/LHU have funct3[2]=1
                unique case (funct3[1:0])
                    2'b00:   mem_size = 2'b00; // byte  (LB/LBU)
                    2'b01:   mem_size = 2'b01; // half  (LH/LHU)
                    2'b10:   mem_size = 2'b10; // word  (LW)
                    default: mem_size = 2'b10;
                endcase
            end

            OP_STORE: begin
                alu_src   = 1'b1;
                alu_op    = ALU_ADD;
                mem_write = 1'b1;
                unique case (funct3[1:0])
                    2'b00:   mem_size = 2'b00; // SB
                    2'b01:   mem_size = 2'b01; // SH
                    2'b10:   mem_size = 2'b10; // SW
                    default: mem_size = 2'b10;
                endcase
            end

            OP_BRANCH: begin
                alu_src = 1'b0;
                branch  = 1'b1;
                // ALU used for the comparison; exact op selected by
                // branch/jump logic in EX based on funct3 (BEQ/BNE/BLT/...).
                alu_op  = ALU_SUB;
            end

            OP_JAL: begin
                reg_write = 1'b1;
                jump      = 1'b1;
                wb_sel    = 2'b10; // link value PC+4
            end

            OP_JALR: begin
                reg_write = 1'b1;
                alu_src   = 1'b1;  // rs1 + imm for target
                alu_op    = ALU_ADD;
                jump      = 1'b1;
                wb_sel    = 2'b10; // link value PC+4
            end

            OP_LUI: begin
                reg_write = 1'b1;
                alu_src   = 1'b1;
                alu_op    = ALU_ADD; // ALU passes imm through: 0 + imm
                wb_sel    = 2'b00;
            end

            OP_AUIPC: begin
                reg_write = 1'b1;
                alu_src   = 1'b1;
                alu_op    = ALU_ADD; // PC + imm; PC supplied as operand_a by datapath mux
                wb_sel    = 2'b00;
            end

            OP_SYSTEM: begin
                // ECALL/EBREAK: decoded but treated as architectural NOP stub
                // in v1 (no trap/exception handling yet — see docs/architecture.md
                // non-goals). Explicitly flagged, not silently ignored.
                illegal = 1'b0; // recognized, just not fully implemented
            end

            default: begin
                illegal = 1'b1;
            end
        endcase
    end

endmodule
