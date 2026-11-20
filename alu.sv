// -----------------------------------------------------------------------------
// alu.sv — Corvid RV32I Arithmetic Logic Unit
//
// Combinational ALU covering every operation required by RV32I R-type and
// I-type-immediate instructions, plus the subtract/compare ops reused by
// branch resolution in the EX stage (see docs/pipeline.md).
//
// alu_op encoding is a local design choice (not part of the RISC-V spec) —
// chosen to be dense and easy to decode from funct3/funct7 in the control
// unit. See docs/isa.md for the funct3/funct7 -> alu_op mapping table.
// -----------------------------------------------------------------------------

module alu #(
    parameter int XLEN = 32
) (
    input  logic [XLEN-1:0] operand_a,
    input  logic [XLEN-1:0] operand_b,
    input  logic [3:0]      alu_op,
    output logic [XLEN-1:0] result,
    output logic            zero        // result == 0, used for BEQ/BNE
);

    // alu_op encoding
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

    // Shift amount is only the low 5 bits of operand_b for RV32I (shamt[4:0])
    logic [4:0] shamt;
    assign shamt = operand_b[4:0];

    always_comb begin
        unique case (alu_op)
            ALU_ADD:  result = operand_a + operand_b;
            ALU_SUB:  result = operand_a - operand_b;
            ALU_SLL:  result = operand_a << shamt;
            ALU_SLT:  result = {{(XLEN-1){1'b0}}, ($signed(operand_a) < $signed(operand_b))};
            ALU_SLTU: result = {{(XLEN-1){1'b0}}, (operand_a < operand_b)};
            ALU_XOR:  result = operand_a ^ operand_b;
            ALU_SRL:  result = operand_a >> shamt;
            ALU_SRA:  result = $signed(operand_a) >>> shamt;
            ALU_OR:   result = operand_a | operand_b;
            ALU_AND:  result = operand_a & operand_b;
            default:  result = '0;
        endcase
    end

    assign zero = (result == '0);

endmodule
