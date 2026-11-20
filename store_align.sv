// -----------------------------------------------------------------------------
// store_align.sv — Corvid store data alignment and byte-enable generator
//
// Takes the raw rs2 value and the low 2 bits of the computed store address,
// and produces a word-aligned write-data value plus a 4-bit per-byte enable
// mask, so the external data memory can be a plain word-oriented array with
// byte enables (standard BRAM-friendly interface).
// -----------------------------------------------------------------------------

module store_align (
    input  logic [31:0] wdata_in,     // raw rs2 value (source register)
    input  logic [1:0]  addr_lsbs,    // address[1:0] of the store
    input  logic [1:0]  size,         // 00=byte 01=half 10=word (control_unit.mem_size)
    output logic [31:0] wdata_aligned,
    output logic [3:0]  byte_enable
);

    always_comb begin
        unique case (size)
            2'b00: begin // byte
                byte_enable   = 4'b0001 << addr_lsbs;
                wdata_aligned = {4{wdata_in[7:0]}};
            end
            2'b01: begin // half (assumes 2-byte aligned address)
                byte_enable   = addr_lsbs[1] ? 4'b1100 : 4'b0011;
                wdata_aligned = {2{wdata_in[15:0]}};
            end
            2'b10: begin // word (assumes 4-byte aligned address)
                byte_enable   = 4'b1111;
                wdata_aligned = wdata_in;
            end
            default: begin
                byte_enable   = 4'b0000;
                wdata_aligned = 32'b0;
            end
        endcase
    end

endmodule
