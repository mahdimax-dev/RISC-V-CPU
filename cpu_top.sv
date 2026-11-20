// -----------------------------------------------------------------------------
// cpu_top.sv — Corvid RV32I single-cycle integrated CPU (Phase 4)
//
// Integrates the Phase 3 verified modules (pc, imm_gen, control_unit,
// regfile, alu) plus two new Phase 4 modules (store_align, load_extend)
// into a single-cycle datapath. No pipeline registers, no hazards — every
// instruction fully completes in one clock edge, per the Phase 1 plan
// ("PHASE 4 — Single-Cycle Functional Core" before pipelining in Phase 5).
//
// External memory interface is exposed rather than embedded, per the
// master spec: a word-oriented instruction memory (combinational read) and
// a word-oriented data memory with byte enables (combinational read,
// externally-clocked write). See docs/phase4-datapath.md for full
// rationale and the interface gaps this module resolves.
// -----------------------------------------------------------------------------

module cpu_top #(
    parameter logic [31:0] RESET_VECTOR = 32'h0000_0000
) (
    input  logic        clk,
    input  logic        reset,

    // Instruction memory interface (combinational read)
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,

    // Data memory interface (combinational read, byte-enabled write)
    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    output logic [3:0]  dmem_byte_en,
    output logic        dmem_we,
    output logic        dmem_re,
    output logic [1:0]  dmem_size,
    input  logic [31:0] dmem_rdata,

    // Debug/observability (not required for correctness)
    output logic         illegal_instr
);

    // Local opcode constants for datapath muxes that control_unit.sv does
    // not expose a dedicated signal for (see docs/phase4-datapath.md,
    // "Identified interface gaps"). Duplicated from control_unit.sv's
    // internal (unexported) localparams rather than modifying that
    // already-verified module — a shared rv32i_pkg.sv is a reasonable
    // follow-up cleanup, noted as a known limitation.
    localparam logic [6:0] OP_AUIPC = 7'b0010111;
    localparam logic [6:0] OP_LUI   = 7'b0110111;
    localparam logic [6:0] OP_JAL   = 7'b1101111;
    localparam logic [6:0] OP_JALR  = 7'b1100111;

    // ------------------------------------------------------------------
    // Fetch
    // ------------------------------------------------------------------
    logic [31:0] pc_out, pc_plus4, pc_next;

    pc #(.RESET_VECTOR(RESET_VECTOR)) u_pc (
        .clk(clk),
        .reset(reset),
        .stall(1'b0),            // no hazards in a single-cycle core
        .branch_redirect(1'b0),  // next-PC is fully resolved combinationally
        .branch_target(32'b0),   // below and driven through pc_next instead
        .pc_next(pc_next),
        .pc_out(pc_out)
    );

    assign imem_addr = pc_out;
    assign pc_plus4  = pc_out + 32'd4;

    logic [31:0] instr;
    assign instr = imem_rdata;

    // ------------------------------------------------------------------
    // Decode
    // ------------------------------------------------------------------
    logic [6:0] opcode;
    logic [4:0] rd_addr, rs1_addr, rs2_addr;
    logic [2:0] funct3;
    logic [6:0] funct7;

    assign opcode   = instr[6:0];
    assign rd_addr  = instr[11:7];
    assign funct3   = instr[14:12];
    assign rs1_addr = instr[19:15];
    assign rs2_addr = instr[24:20];
    assign funct7   = instr[31:25];
    // NOTE: for U-type (LUI) and J-type (JAL) instructions, bits [19:15]
    // and [24:20] are actually immediate bits, not real register
    // specifiers. rs1_rdata/rs2_rdata are still read from whatever
    // register those bits happen to name, but neither value is consumed
    // by the datapath for those opcodes (see ALU operand-A mux and
    // branch/jump target logic below) — a harmless, standard artifact of
    // a single fixed decode path, not a functional bug. See
    // docs/phase4-datapath.md "known limitations".

    logic [31:0] imm;
    imm_gen u_imm_gen (.instr(instr), .imm(imm));

    logic reg_write, alu_src, mem_read, mem_write, mem_unsigned, branch, jump;
    logic [3:0] alu_op;
    logic [1:0] mem_size, wb_sel;

    control_unit u_control (
        .opcode(opcode), .funct3(funct3), .funct7(funct7),
        .reg_write(reg_write), .alu_src(alu_src), .alu_op(alu_op),
        .mem_read(mem_read), .mem_write(mem_write), .mem_size(mem_size),
        .mem_unsigned(mem_unsigned), .wb_sel(wb_sel),
        .branch(branch), .jump(jump), .illegal(illegal_instr)
    );

    logic [31:0] rs1_rdata, rs2_rdata, rd_wdata;

    regfile #(.XLEN(32), .WRITE_FIRST(1'b0)) u_regfile (
        // WRITE_FIRST=0: this is a single-cycle core, so a read and a
        // write in the same cycle always belong to the SAME instruction.
        // RV32I semantics require that instruction's rs1/rs2 reads to see
        // the PRE-instruction register state regardless — write-first
        // bypass is a pipelined-design feature (needed from Phase 5 on,
        // where the WB-stage write and an ID-stage read belong to two
        // DIFFERENT instructions in the same cycle) and its presence here
        // created a genuine combinational cycle: rs1_rdata/rs2_rdata ->
        // alu operand mux -> alu_result -> writeback mux -> rd_wdata ->
        // (write-first bypass) -> rs1_rdata/rs2_rdata again, whenever an
        // instruction's rs1_addr/rs2_addr field numerically coincided
        // with its own rd_addr — see docs/phase4-hang-debug.md for the
        // full diagnosis (this is what hung the simulator on the branch
        // tests).
        .clk(clk), .reset(reset), .we(reg_write),
        .rs1_addr(rs1_addr), .rs2_addr(rs2_addr), .rd_addr(rd_addr),
        .rd_wdata(rd_wdata),
        .rs1_rdata(rs1_rdata), .rs2_rdata(rs2_rdata)
    );

    // ------------------------------------------------------------------
    // Execute
    // ------------------------------------------------------------------
    // ALU operand-A mux: this is the datapath-mux gap identified in
    // control_unit.sv's own comments ("PC supplied as operand_a by
    // datapath mux" for AUIPC; "0 + imm" for LUI).
    logic [31:0] alu_operand_a, alu_operand_b;

    always_comb begin
        unique case (opcode)
            OP_AUIPC: alu_operand_a = pc_out;
            OP_LUI:   alu_operand_a = 32'b0;
            default:  alu_operand_a = rs1_rdata;
        endcase
    end

    assign alu_operand_b = alu_src ? imm : rs2_rdata;

    logic [31:0] alu_result;
    logic        alu_zero;

    alu u_alu (
        .operand_a(alu_operand_a), .operand_b(alu_operand_b),
        .alu_op(alu_op), .result(alu_result), .zero(alu_zero)
    );

    // Branch/Jump resolution.
    // - Branch and JAL targets are both PC + imm (imm_gen already selects
    //   the correct B-type/J-type immediate per opcode) — one shared adder.
    // - JALR target reuses the ALU's own rs1+imm result directly, since
    //   control_unit already configures alu_src=1/alu_op=ADD for JALR —
    //   avoids a second dedicated adder.
    logic branch_taken, take_jalr;
    logic [31:0] pc_plus_imm, jalr_target, branch_jump_target;

    assign pc_plus_imm = pc_out + imm;
    assign jalr_target = {alu_result[31:1], 1'b0}; // (rs1+imm) & ~1

    always_comb begin
        branch_taken = 1'b0;
        if (branch) begin
            unique case (funct3)
                3'b000:  branch_taken = alu_zero;   // BEQ
                3'b001:  branch_taken = ~alu_zero;  // BNE
                // BLT/BGE/BLTU/BGEU: control_unit decodes these as
                // branch=1 too, but Phase 4's scope (per the task) is
                // BEQ/BNE only — see docs/phase4-datapath.md "known
                // limitations" for how these would be added.
                default: branch_taken = 1'b0;
            endcase
        end
    end

    assign take_jalr          = jump && (opcode == OP_JALR);
    assign branch_jump_target = take_jalr ? jalr_target : pc_plus_imm;
    assign pc_next             = (branch_taken || jump) ? branch_jump_target : pc_plus4;

    // ------------------------------------------------------------------
    // Memory
    // ------------------------------------------------------------------
    logic [31:0] store_wdata_aligned;
    logic [3:0]  store_byte_en;

    store_align u_store_align (
        .wdata_in(rs2_rdata),
        .addr_lsbs(alu_result[1:0]),
        .size(mem_size),
        .wdata_aligned(store_wdata_aligned),
        .byte_enable(store_byte_en)
    );

    assign dmem_addr    = alu_result;      // base + offset, computed by ALU
    assign dmem_wdata    = store_wdata_aligned;
    assign dmem_byte_en  = mem_write ? store_byte_en : 4'b0000;
    assign dmem_we       = mem_write;
    assign dmem_re       = mem_read;
    assign dmem_size     = mem_size;

    logic [31:0] load_data;

    load_extend u_load_extend (
        .rdata_word(dmem_rdata),
        .addr_lsbs(alu_result[1:0]),
        .size(mem_size),
        .is_unsigned(mem_unsigned),
        .rdata(load_data)
    );

    // ------------------------------------------------------------------
    // Writeback
    // ------------------------------------------------------------------
    always_comb begin
        unique case (wb_sel)
            2'b00:   rd_wdata = alu_result;
            2'b01:   rd_wdata = load_data;
            2'b10:   rd_wdata = pc_plus4;
            default: rd_wdata = alu_result;
        endcase
    end

endmodule
