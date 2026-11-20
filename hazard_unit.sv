// -----------------------------------------------------------------------------
// hazard_unit.sv — Corvid Hazard Detection Unit (Phase 7)
//
// Detects the ONE hazard forwarding cannot resolve: load-use. If the
// instruction currently in ID/EX (about to enter EX) is a load, and its
// destination register matches either source register of the instruction
// currently being decoded in ID, the loaded data simply isn't available
// yet (load_extend runs in WB) -- forwarding EX/MEM's value would only
// give the raw memory address (see docs/phase6-forwarding.md). The fix:
// stall for exactly one cycle (freeze PC/IF-ID, bubble ID/EX) so the load
// reaches WB by the time the consumer reaches EX -- at which point the
// ALREADY-EXISTING MEM/WB forwarding path (Phase 6) supplies the correct,
// fully-extended loaded value. No new forwarding path was needed; one
// stall cycle changes the effective hazard distance from 1-apart
// (unresolvable by forwarding) to 2-apart (already resolved).
//
// Opcode-agnostic, like the ALU operand muxes (Phase 4) and the
// forwarding unit (Phase 6): id_rs1_addr/id_rs2_addr are read from fixed
// bit positions regardless of instruction format, so an immediate whose
// low bits coincidentally equal the load's rd can trigger an unnecessary
// (but harmless -- only a wasted cycle, never incorrect) stall. See
// docs/phase7-hazard-stall.md "known limitations".
// -----------------------------------------------------------------------------

module hazard_unit (
    input  logic       id_ex_mem_read,   // is the ID/EX-stage instruction a load
    input  logic [4:0] id_ex_rd_addr,    // its destination register
    input  logic [4:0] id_rs1_addr,      // ID-stage (currently decoding) source regs
    input  logic [4:0] id_rs2_addr,
    output logic       stall             // 1 = load-use hazard, insert one bubble
);

    assign stall = id_ex_mem_read && (id_ex_rd_addr != 5'd0) &&
                   ((id_ex_rd_addr == id_rs1_addr) || (id_ex_rd_addr == id_rs2_addr));

endmodule
