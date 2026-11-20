// -----------------------------------------------------------------------------
// cpu_pipeline.sv — Corvid RV32I 5-stage pipelined CPU (Phase 5 + 6 + 7 + 8)
//
// IF -> ID -> EX -> MEM -> WB, using the same verified Phase 3/4 components
// (pc, imm_gen, control_unit, regfile, alu, store_align, load_extend) plus
// four instances of the generic pipe_reg register at each stage boundary,
// a forwarding_unit (Phase 6) resolving EX/MEM and MEM/WB RAW hazards, a
// hazard_unit (Phase 7) resolving load-use hazards via a one-cycle stall,
// and (as of Phase 8) branch/jump flush: when ex_take_redirect fires, both
// IF/ID and ID/EX are flushed to a bubble the same cycle, discarding the
// two "shadow" instructions fetched during the branch's resolution
// latency. PC redirect itself (pc_next) was already correct since Phase 5
// -- only the flush was missing. This completes hazard-correct handling
// for the 5-stage pipeline (data hazards: Phase 6-7; control hazards:
// this phase).
// -----------------------------------------------------------------------------

module cpu_pipeline #(
    parameter logic [31:0] RESET_VECTOR = 32'h0000_0000
) (
    input  logic        clk,
    input  logic        reset,

    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,

    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    output logic [3:0]  dmem_byte_en,
    output logic        dmem_we,
    output logic        dmem_re,
    output logic [1:0]  dmem_size,
    input  logic [31:0] dmem_rdata
);

    localparam logic [6:0] OP_AUIPC = 7'b0010111;
    localparam logic [6:0] OP_LUI   = 7'b0110111;
    localparam logic [6:0] OP_JALR  = 7'b1100111;

    // Phase 7 adds real hazard detection (load-use stall). Declared here
    // (before the pc/pipe_reg instantiations that consume it) and driven
    // later by hazard_unit in the EX-stage section, once ex_mem_read/
    // ex_rd_addr (from the ID/EX unpack) and id_rs1_addr/id_rs2_addr (from
    // ID-stage decode) are available -- the same declare-before-use
    // pattern already established for pc_next and the Phase 6 mem_*
    // signals (see docs/phase6-forwarding.md "Icarus declare-before-use").
    logic hazard_stall;

    // Phase 8 adds branch/jump flush. Same forward-declaration pattern:
    // driven by the EX-stage branch/jump resolution logic much further
    // down, but needed here by u_ifid/u_idex (IF/ID and ID/EX must both
    // discard their "shadow" contents the same cycle a taken branch/jump
    // resolves in EX -- see docs/phase8-flush.md).
    logic ex_take_redirect;

    // =====================================================================
    // IF stage
    // =====================================================================
    logic [31:0] if_pc, if_pc4;
    logic [31:0] pc_next; // driven by EX-stage branch/jump resolution below.
                           // Declared here, BEFORE the pc instantiation that
                           // consumes it, because Icarus requires a signal's
                           // `logic` declaration to textually precede its
                           // first use in a port connection -- confirmed by
                           // a real compile failure (see docs/phase6-forwarding.md
                           // "Icarus declare-before-use" note). The actual
                           // VALUE is still driven by a continuous assign
                           // much later in this file (EX stage); only the
                           // *declaration* needed to move.

    pc #(.RESET_VECTOR(RESET_VECTOR)) u_pc (
        .clk(clk), .reset(reset),
        .stall(hazard_stall),
        .branch_redirect(1'b0),   // redirect handled via pc_next below
        .branch_target(32'b0),
        .pc_next(pc_next),
        .pc_out(if_pc)
    );

    assign imem_addr = if_pc;
    assign if_pc4    = if_pc + 32'd4;

    // ---- IF/ID pipeline register ----
    // Packed: {pc[31:0], pc4[31:0], instr[31:0]}  (96 bits)
    logic [95:0] ifid_d, ifid_q;
    assign ifid_d = {if_pc, if_pc4, imem_rdata};

    pipe_reg #(.WIDTH(96)) u_ifid (
        .clk(clk), .reset(reset), .stall(hazard_stall), .flush(ex_take_redirect),
        .d(ifid_d), .q(ifid_q)
    );

    logic [31:0] id_pc, id_pc4, id_instr;
    assign {id_pc, id_pc4, id_instr} = ifid_q;

    // =====================================================================
    // ID stage
    // =====================================================================
    logic [6:0] id_opcode, id_funct7;
    logic [4:0] id_rd_addr, id_rs1_addr, id_rs2_addr;
    logic [2:0] id_funct3;

    assign id_opcode   = id_instr[6:0];
    assign id_rd_addr  = id_instr[11:7];
    assign id_funct3   = id_instr[14:12];
    assign id_rs1_addr = id_instr[19:15];
    assign id_rs2_addr = id_instr[24:20];
    assign id_funct7   = id_instr[31:25];

    logic [31:0] id_imm;
    imm_gen u_imm_gen (.instr(id_instr), .imm(id_imm));

    logic id_reg_write, id_alu_src, id_mem_read, id_mem_write, id_mem_unsigned, id_branch, id_jump;
    logic [3:0] id_alu_op;
    logic [1:0] id_mem_size, id_wb_sel;

    control_unit u_control (
        .opcode(id_opcode), .funct3(id_funct3), .funct7(id_funct7),
        .reg_write(id_reg_write), .alu_src(id_alu_src), .alu_op(id_alu_op),
        .mem_read(id_mem_read), .mem_write(id_mem_write), .mem_size(id_mem_size),
        .mem_unsigned(id_mem_unsigned), .wb_sel(id_wb_sel),
        .branch(id_branch), .jump(id_jump), .illegal()
    );

    logic [31:0] id_rs1_rdata, id_rs2_rdata;
    logic [31:0] wb_rd_wdata;   // driven by WB stage below (forward reference)
    logic        wb_reg_write;
    logic [4:0]  wb_rd_addr;

    regfile #(.XLEN(32), .WRITE_FIRST(1'b1)) u_regfile (
        // WRITE_FIRST=1: legitimate here -- WB-stage write and ID-stage
        // read can be two DIFFERENT instructions in the same cycle now
        // that the design is pipelined. See module header and
        // docs/phase5-pipeline.md.
        .clk(clk), .reset(reset), .we(wb_reg_write),
        .rs1_addr(id_rs1_addr), .rs2_addr(id_rs2_addr), .rd_addr(wb_rd_addr),
        .rd_wdata(wb_rd_wdata),
        .rs1_rdata(id_rs1_rdata), .rs2_rdata(id_rs2_rdata)
    );

    // ---- ID/EX pipeline register ----
    // Packed: pc(32) pc4(32) imm(32) rs1_rdata(32) rs2_rdata(32) rs1_addr(5)
    // rs2_addr(5) rd_addr(5) funct3(3) opcode(7) reg_write(1) alu_src(1)
    // alu_op(4) mem_read(1) mem_write(1) mem_size(2) mem_unsigned(1)
    // wb_sel(2) branch(1) jump(1)  == 200 bits
    localparam int IDEX_W = 200;
    logic [IDEX_W-1:0] idex_d, idex_q;
    assign idex_d = {id_pc, id_pc4, id_imm, id_rs1_rdata, id_rs2_rdata,
                      id_rs1_addr, id_rs2_addr, id_rd_addr, id_funct3, id_opcode,
                      id_reg_write, id_alu_src, id_alu_op, id_mem_read, id_mem_write,
                      id_mem_size, id_mem_unsigned, id_wb_sel, id_branch, id_jump};

    pipe_reg #(.WIDTH(IDEX_W)) u_idex (
        .clk(clk), .reset(reset), .stall(1'b0), .flush(hazard_stall || ex_take_redirect),
        .d(idex_d), .q(idex_q)
    );

    logic [31:0] ex_pc, ex_pc4, ex_imm, ex_rs1_rdata, ex_rs2_rdata;
    logic [4:0]  ex_rs1_addr, ex_rs2_addr, ex_rd_addr;
    logic [2:0]  ex_funct3;
    logic [6:0]  ex_opcode;
    logic        ex_reg_write, ex_alu_src, ex_mem_read, ex_mem_write, ex_mem_unsigned, ex_branch, ex_jump;
    logic [3:0]  ex_alu_op;
    logic [1:0]  ex_mem_size, ex_wb_sel;

    assign {ex_pc, ex_pc4, ex_imm, ex_rs1_rdata, ex_rs2_rdata,
            ex_rs1_addr, ex_rs2_addr, ex_rd_addr, ex_funct3, ex_opcode,
            ex_reg_write, ex_alu_src, ex_alu_op, ex_mem_read, ex_mem_write,
            ex_mem_size, ex_mem_unsigned, ex_wb_sel, ex_branch, ex_jump} = idex_q;

    // =====================================================================
    // EX stage
    // =====================================================================

    // EX/MEM stage's OUTPUT-side signals, declared here (before first use)
    // rather than at their original position further down alongside the
    // unpack assign -- Icarus requires a signal's `logic` declaration to
    // textually precede its first use in a port connection (confirmed by
    // a real compile failure: "Unable to bind wire/reg/memory mem_rd_addr"
    // etc. at the forwarding_unit instantiation below). The actual unpack
    // assign (`assign {mem_pc4, mem_alu_result, ...} = exmem_q;`) stays in
    // its original position after the EX/MEM pipe_reg -- only the
    // *declaration* moved; no logic changed. See docs/phase6-forwarding.md.
    logic [31:0] mem_pc4, mem_alu_result, mem_rs2_rdata;
    logic [4:0]  mem_rd_addr;
    logic        mem_reg_write, mem_mem_read, mem_mem_write, mem_mem_unsigned;
    logic [1:0]  mem_mem_size, mem_wb_sel;

    // ---- Hazard detection (Phase 7) ----
    // ex_mem_read/ex_rd_addr are the ID/EX-stage instruction (about to
    // enter EX -- the potential load producer); id_rs1_addr/id_rs2_addr
    // are the ID-stage instruction currently being decoded (the potential
    // consumer). Both already available at this point in the file.
    hazard_unit u_hazard (
        .id_ex_mem_read(ex_mem_read),
        .id_ex_rd_addr(ex_rd_addr),
        .id_rs1_addr(id_rs1_addr),
        .id_rs2_addr(id_rs2_addr),
        .stall(hazard_stall)
    );

    // ---- Forwarding (Phase 6) ----
    logic [1:0] fwd_a_sel, fwd_b_sel;

    forwarding_unit u_forwarding (
        .ex_rs1_addr(ex_rs1_addr), .ex_rs2_addr(ex_rs2_addr),
        .mem_rd_addr(mem_rd_addr), .mem_reg_write(mem_reg_write),
        .wb_rd_addr(wb_rd_addr), .wb_reg_write(wb_reg_write),
        .fwd_a_sel(fwd_a_sel), .fwd_b_sel(fwd_b_sel)
    );

    logic [31:0] fwd_rs1_val, fwd_rs2_val;

    always_comb begin
        unique case (fwd_a_sel)
            2'b01:   fwd_rs1_val = mem_alu_result;  // from EX/MEM
            2'b10:   fwd_rs1_val = wb_rd_wdata;     // from MEM/WB (final writeback value)
            default: fwd_rs1_val = ex_rs1_rdata;    // no hazard -- ID/EX-captured value
        endcase
        unique case (fwd_b_sel)
            2'b01:   fwd_rs2_val = mem_alu_result;
            2'b10:   fwd_rs2_val = wb_rd_wdata;
            default: fwd_rs2_val = ex_rs2_rdata;
        endcase
    end

    logic [31:0] ex_alu_operand_a, ex_alu_operand_b;

    always_comb begin
        unique case (ex_opcode)
            OP_AUIPC: ex_alu_operand_a = ex_pc;
            OP_LUI:   ex_alu_operand_a = 32'b0;
            default:  ex_alu_operand_a = fwd_rs1_val;   // forwarded, not raw ex_rs1_rdata
        endcase
    end
    assign ex_alu_operand_b = ex_alu_src ? ex_imm : fwd_rs2_val; // forwarded, not raw ex_rs2_rdata

    logic [31:0] ex_alu_result;
    logic        ex_alu_zero;

    alu u_alu (
        .operand_a(ex_alu_operand_a), .operand_b(ex_alu_operand_b),
        .alu_op(ex_alu_op), .result(ex_alu_result), .zero(ex_alu_zero)
    );

    // Branch/jump resolution -- redirects IF-stage PC on the NEXT cycle,
    // AND (as of Phase 8) drives ex_take_redirect, which flushes both
    // IF/ID and ID/EX this same cycle -- discarding the two "shadow"
    // instructions fetched during this resolution latency. See module
    // header and docs/phase8-flush.md.
    logic ex_branch_taken, ex_take_jalr;
    logic [31:0] ex_pc_plus_imm, ex_jalr_target, ex_branch_jump_target;

    assign ex_pc_plus_imm = ex_pc + ex_imm;
    assign ex_jalr_target = {ex_alu_result[31:1], 1'b0};

    always_comb begin
        ex_branch_taken = 1'b0;
        if (ex_branch) begin
            unique case (ex_funct3)
                3'b000:  ex_branch_taken = ex_alu_zero;   // BEQ
                3'b001:  ex_branch_taken = ~ex_alu_zero;  // BNE
                default: ex_branch_taken = 1'b0;          // BLT/BGE/etc: Phase 4 scope note applies here too
            endcase
        end
    end

    assign ex_take_jalr          = ex_jump && (ex_opcode == OP_JALR);
    assign ex_take_redirect      = ex_branch_taken || ex_jump;
    assign ex_branch_jump_target = ex_take_jalr ? ex_jalr_target : ex_pc_plus_imm;
    assign pc_next               = ex_take_redirect ? ex_branch_jump_target : if_pc4;

    // ---- EX/MEM pipeline register ----
    // Packed: pc4(32) alu_result(32) rs2_rdata(32) rd_addr(5) reg_write(1)
    // mem_read(1) mem_write(1) mem_size(2) mem_unsigned(1) wb_sel(2) == 109 bits
    // NOTE: carries fwd_rs2_val (the FORWARDED value), not the raw
    // ex_rs2_rdata captured back in ID -- a store's DATA operand must
    // reflect forwarding exactly like the ALU's operands do (see Phase 6
    // "store data forwarding" test in docs/phase6-forwarding.md).
    localparam int EXMEM_W = 109;
    logic [EXMEM_W-1:0] exmem_d, exmem_q;
    assign exmem_d = {ex_pc4, ex_alu_result, fwd_rs2_val, ex_rd_addr, ex_reg_write,
                       ex_mem_read, ex_mem_write, ex_mem_size, ex_mem_unsigned, ex_wb_sel};

    pipe_reg #(.WIDTH(EXMEM_W)) u_exmem (
        .clk(clk), .reset(reset), .stall(1'b0), .flush(1'b0),
        .d(exmem_d), .q(exmem_q)
    );

    logic [31:0] mem_store_wdata_aligned;
    logic [3:0]  mem_store_byte_en;

    // Unpack EX/MEM pipeline register contents (declarations for these
    // signals were moved up before the EX-stage forwarding_unit -- see
    // note there -- this assign stays in its original position).
    assign {mem_pc4, mem_alu_result, mem_rs2_rdata, mem_rd_addr, mem_reg_write,
            mem_mem_read, mem_mem_write, mem_mem_size, mem_mem_unsigned, mem_wb_sel} = exmem_q;

    // =====================================================================
    // MEM stage
    // =====================================================================

    store_align u_store_align (
        .wdata_in(mem_rs2_rdata),
        .addr_lsbs(mem_alu_result[1:0]),
        .size(mem_mem_size),
        .wdata_aligned(mem_store_wdata_aligned),
        .byte_enable(mem_store_byte_en)
    );

    assign dmem_addr    = mem_alu_result;
    assign dmem_wdata    = mem_store_wdata_aligned;
    assign dmem_byte_en  = mem_mem_write ? mem_store_byte_en : 4'b0000;
    assign dmem_we       = mem_mem_write;
    assign dmem_re       = mem_mem_read;
    assign dmem_size     = mem_mem_size;

    // ---- MEM/WB pipeline register ----
    // Packed: pc4(32) alu_result(32) mem_rdata(32) rd_addr(5) reg_write(1)
    // wb_sel(2) mem_size(2) mem_unsigned(1) == 107 bits
    localparam int MEMWB_W = 107;
    logic [MEMWB_W-1:0] memwb_d, memwb_q;
    assign memwb_d = {mem_pc4, mem_alu_result, dmem_rdata, mem_rd_addr, mem_reg_write,
                       mem_wb_sel, mem_mem_size, mem_mem_unsigned};

    pipe_reg #(.WIDTH(MEMWB_W)) u_memwb (
        .clk(clk), .reset(reset), .stall(1'b0), .flush(1'b0),
        .d(memwb_d), .q(memwb_q)
    );

    logic [31:0] wb_pc4, wb_alu_result, wb_mem_rdata;
    logic [1:0]  wb_wb_sel, wb_mem_size;
    logic        wb_mem_unsigned;

    assign {wb_pc4, wb_alu_result, wb_mem_rdata, wb_rd_addr, wb_reg_write,
            wb_wb_sel, wb_mem_size, wb_mem_unsigned} = memwb_q;

    // =====================================================================
    // WB stage
    // =====================================================================
    logic [31:0] wb_load_data;

    load_extend u_load_extend (
        .rdata_word(wb_mem_rdata),
        .addr_lsbs(wb_alu_result[1:0]),
        .size(wb_mem_size),
        .is_unsigned(wb_mem_unsigned),
        .rdata(wb_load_data)
    );

    always_comb begin
        unique case (wb_wb_sel)
            2'b00:   wb_rd_wdata = wb_alu_result;
            2'b01:   wb_rd_wdata = wb_load_data;
            2'b10:   wb_rd_wdata = wb_pc4;
            default: wb_rd_wdata = wb_alu_result;
        endcase
    end

endmodule
