// -----------------------------------------------------------------------------
// regfile.sv — Corvid RV32I Register File
//
// 32 x 32-bit registers, x0 hardwired to zero. Two combinational read ports,
// one synchronous write port. Optionally implements "write-first" behavior
// (WRITE_FIRST=1, the default, preserving exact Phase 3 tested behavior):
// if the same cycle both writes to address W and reads address W, the read
// returns the NEW value being written, not the stale stored value. This is
// meant for a PIPELINED design, where the WB-stage write and an ID-stage
// read in the same cycle belong to two DIFFERENT, independent instructions
// (see docs/pipeline.md section 4) — needed starting Phase 5.
//
// WRITE_FIRST=0 disables the bypass entirely: reads always return the
// stored value, ignoring rd_wdata. Added during Phase 4 debugging (see
// docs/phase4-hang-debug.md) — in a SINGLE-CYCLE core, a read and a write
// in the same cycle belong to the SAME instruction, and RV32I semantics
// require that instruction's rs1/rs2 reads see the PRE-instruction state
// regardless, so write-first bypass is not just unneeded there but
// actively wrong to enable, and its presence created a genuine
// combinational cycle back through the ALU/writeback path whenever an
// instruction's rs1_addr/rs2_addr field numerically coincided with its
// own rd_addr — including, harmlessly-in-value-but-not-in-topology,
// cases where those address bits are not even real register references
// (e.g. immediate bits for I-type instructions).
// -----------------------------------------------------------------------------

module regfile #(
    parameter int  XLEN        = 32,
    parameter bit  WRITE_FIRST = 1'b1
) (
    input  logic              clk,
    input  logic               reset,
    input  logic               we,          // write enable
    input  logic [4:0]         rs1_addr,
    input  logic [4:0]         rs2_addr,
    input  logic [4:0]         rd_addr,
    input  logic [XLEN-1:0]    rd_wdata,
    output logic [XLEN-1:0]    rs1_rdata,
    output logic [XLEN-1:0]    rs2_rdata
);

    logic [XLEN-1:0] regs [1:31];   // x0 is never stored, always reads 0

    // Synchronous write. Reset and write are mutually exclusive by
    // construction (if/else, not two independent ifs) so priority is
    // unambiguous regardless of event-ordering at the edge where reset
    // deasserts — defensive hardening after a real race was diagnosed
    // in the testbench (see docs/phase3-regfile-debug.md).
    always_ff @(posedge clk) begin
        if (reset) begin
            // no reset of the array contents is architecturally required
            // by RV32I (register state is undefined at reset), but we
            // clear on reset anyway for deterministic simulation/debug.
            for (int i = 1; i < 32; i++) regs[i] <= '0;
        end else if (we && rd_addr != 5'd0) begin
            regs[rd_addr] <= rd_wdata;
        end
    end

    // Combinational read, with write-first forwarding gated by WRITE_FIRST.
    always_comb begin
        if (rs1_addr == 5'd0)
            rs1_rdata = '0;
        else if (WRITE_FIRST && we && (rs1_addr == rd_addr))
            rs1_rdata = rd_wdata;          // write-first (pipelined use only)
        else
            rs1_rdata = regs[rs1_addr];

        if (rs2_addr == 5'd0)
            rs2_rdata = '0;
        else if (WRITE_FIRST && we && (rs2_addr == rd_addr))
            rs2_rdata = rd_wdata;          // write-first (pipelined use only)
        else
            rs2_rdata = regs[rs2_addr];
    end

endmodule
