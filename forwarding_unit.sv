// -----------------------------------------------------------------------------
// forwarding_unit.sv — Corvid Forwarding Unit (Phase 6)
//
// Selects, for each EX-stage ALU source operand, between the value
// captured in ID/EX (possibly stale) and a bypass from EX/MEM (the
// producer instruction currently in MEM -- 1 instruction ahead of the
// current EX-stage consumer) or MEM/WB (producer currently in WB -- 2
// instructions ahead). Priority: EX/MEM wins over MEM/WB when both match,
// since EX/MEM is the more recently produced value.
//
// Does NOT resolve load-use hazards: for a load producer, the EX/MEM
// value is the ALU-computed memory ADDRESS (load_extend hasn't run yet --
// that happens in WB), not the loaded data. This unit forwards it anyway
// (there is no load-aware exception here), which produces a plausible-
// looking WRONG value for a load immediately followed by a dependent
// instruction -- worse than Phase 5's obviously-stale zero, and exactly
// why Phase 7's hazard-detection stall exists as a separate, necessary
// mechanism this unit cannot substitute for. See docs/phase6-forwarding.md.
// -----------------------------------------------------------------------------

module forwarding_unit (
    input  logic [4:0] ex_rs1_addr,
    input  logic [4:0] ex_rs2_addr,
    input  logic [4:0] mem_rd_addr,     // EX/MEM stage's destination register
    input  logic       mem_reg_write,
    input  logic [4:0] wb_rd_addr,      // MEM/WB stage's destination register
    input  logic       wb_reg_write,
    output logic [1:0] fwd_a_sel,       // 00=no forward 01=EX/MEM 10=MEM/WB
    output logic [1:0] fwd_b_sel
);

    always_comb begin
        if (mem_reg_write && (mem_rd_addr != 5'd0) && (mem_rd_addr == ex_rs1_addr))
            fwd_a_sel = 2'b01;
        else if (wb_reg_write && (wb_rd_addr != 5'd0) && (wb_rd_addr == ex_rs1_addr))
            fwd_a_sel = 2'b10;
        else
            fwd_a_sel = 2'b00;

        if (mem_reg_write && (mem_rd_addr != 5'd0) && (mem_rd_addr == ex_rs2_addr))
            fwd_b_sel = 2'b01;
        else if (wb_reg_write && (wb_rd_addr != 5'd0) && (wb_rd_addr == ex_rs2_addr))
            fwd_b_sel = 2'b10;
        else
            fwd_b_sel = 2'b00;
    end

endmodule
