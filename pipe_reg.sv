// -----------------------------------------------------------------------------
// pipe_reg.sv — Corvid generic pipeline register
//
// One reusable, width-parameterized register used for all four pipeline
// boundaries (IF/ID, ID/EX, EX/MEM, MEM/WB) rather than four bespoke
// modules — avoids duplicated logic per the master spec's "no duplicated
// logic" requirement. Each stage boundary packs its own named fields into
// a flat vector immediately around the instantiation in cpu_pipeline.sv,
// so this module itself stays trivial and has no RV32I-specific knowledge.
//
// stall: hold current contents (used by Phase 7 hazard detection — tied
//        to 0 everywhere in Phase 5, since there's no hazard unit yet).
// flush: force contents to all-zero, i.e. a bubble/NOP (used by Phase 8
//        branch/jump flush — tied to 0 everywhere in Phase 5).
// Both ports exist now (rather than being added later) so Phase 6-8 don't
// need to re-instantiate every pipeline register — a deliberate,
// documented forward-looking choice, not scope creep: the ports are
// present but functionally inert until later phases wire them up.
// -----------------------------------------------------------------------------

module pipe_reg #(
    parameter int WIDTH = 32
) (
    input  logic             clk,
    input  logic             reset,
    input  logic             stall,   // hold current value
    input  logic             flush,   // force to all-zero bubble
    input  logic [WIDTH-1:0] d,
    output logic [WIDTH-1:0] q
);

    always_ff @(posedge clk) begin
        if (reset || flush) begin
            q <= '0;
        end else if (!stall) begin
            q <= d;
        end
        // stall && !reset && !flush: hold (no assignment needed, q keeps
        // its value automatically since no branch executes)
    end

endmodule
