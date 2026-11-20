// -----------------------------------------------------------------------------
// imm_gen.sv — Corvid RV32I Immediate Generator
//
// Pure combinational block. Extracts and sign-extends the immediate field
// for whichever instruction format the opcode indicates. See docs/isa.md
// for the bit-layout table this mirrors exactly (RV32I unprivileged spec).
// -----------------------------------------------------------------------------

module imm_gen (
    input  logic [31:0] instr,
    output logic [31:0] imm
);

    // RV32I opcode map (bits [6:0])
    localparam logic [6:0] OP_LOAD   = 7'b0000011; // I-type
    localparam logic [6:0] OP_STORE  = 7'b0100011; // S-type
    localparam logic [6:0] OP_BRANCH = 7'b1100011; // B-type
    localparam logic [6:0] OP_JALR   = 7'b1100111; // I-type
    localparam logic [6:0] OP_JAL    = 7'b1101111; // J-type
    localparam logic [6:0] OP_LUI    = 7'b0110111; // U-type
    localparam logic [6:0] OP_AUIPC  = 7'b0010111; // U-type
    localparam logic [6:0] OP_IMM    = 7'b0010011; // I-type (ALU imm)

    logic [6:0] opcode;
    assign opcode = instr[6:0];

    always_comb begin
        unique case (opcode)
            OP_LOAD, OP_JALR, OP_IMM: // I-type
                imm = {{20{instr[31]}}, instr[31:20]};

            OP_STORE: // S-type
                imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};

            OP_BRANCH: // B-type
                imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};

            OP_LUI, OP_AUIPC: // U-type
                imm = {instr[31:12], 12'b0};

            OP_JAL: // J-type
                imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

            default:
                imm = 32'b0; // R-type / unrecognized: no immediate used
        endcase
    end

endmodule
