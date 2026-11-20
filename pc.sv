// -----------------------------------------------------------------------------
// pc.sv — Corvid Program Counter
//
// Simple synchronous register with:
//   - stall: hold current value (used when a load-use hazard freezes IF)
//   - branch redirect: load a new target (from EX-stage branch/jump resolution)
//   - otherwise: advance to pc_next (PC+4, supplied externally by IF stage)
//
// Priority: branch redirect wins over stall, since a resolved taken branch
// in EX must redirect fetch even if a hazard-driven stall is also asserted
// for the (now-to-be-flushed) instructions currently in the front of the
// pipeline. See docs/pipeline.md for the full hazard/flush interaction.
// -----------------------------------------------------------------------------

module pc #(
    parameter logic [31:0] RESET_VECTOR = 32'h0000_0000
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        stall,
    input  logic         branch_redirect,
    input  logic [31:0]  branch_target,
    input  logic [31:0]  pc_next,       // normally PC+4, supplied by IF stage
    output logic [31:0]  pc_out
);

    always_ff @(posedge clk) begin
        if (reset) begin
            pc_out <= RESET_VECTOR;
        end else if (branch_redirect) begin
            pc_out <= branch_target;
        end else if (stall) begin
            pc_out <= pc_out; // hold
        end else begin
            pc_out <= pc_next;
        end
    end

endmodule
