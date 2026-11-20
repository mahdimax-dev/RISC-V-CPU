// -----------------------------------------------------------------------------
// load_extend.sv — Corvid load data sign/zero extension unit
//
// Takes a full 32-bit word read from a word-oriented data memory plus the
// low 2 bits of the load address, selects the addressed byte/halfword, and
// sign- or zero-extends it per mem_size/mem_unsigned from the control unit.
// -----------------------------------------------------------------------------

module load_extend (
    input  logic [31:0] rdata_word,   // word read from data memory
    input  logic [1:0]  addr_lsbs,    // address[1:0] of the load
    input  logic [1:0]  size,         // 00=byte 01=half 10=word
    input  logic        is_unsigned,  // control_unit.mem_unsigned
    output logic [31:0] rdata
);

    logic [7:0]  byte_sel;
    logic [15:0] half_sel;

    always_comb begin
        unique case (addr_lsbs)
            2'b00: byte_sel = rdata_word[7:0];
            2'b01: byte_sel = rdata_word[15:8];
            2'b10: byte_sel = rdata_word[23:16];
            2'b11: byte_sel = rdata_word[31:24];
            // addr_lsbs is 2 bits so 00/01/10/11 is logically exhaustive,
            // but `unique case` can't be statically proven exhaustive by
            // Icarus without an explicit default (source of the "value is
            // unhandled" warning) -- added defensively so an X on this
            // signal doesn't leave byte_sel undriven/latched.
            default: byte_sel = 8'b0;
        endcase
        half_sel = addr_lsbs[1] ? rdata_word[31:16] : rdata_word[15:0];
    end

    always_comb begin
        unique case (size)
            2'b00:   rdata = is_unsigned ? {24'b0, byte_sel}
                                          : {{24{byte_sel[7]}}, byte_sel};
            2'b01:   rdata = is_unsigned ? {16'b0, half_sel}
                                          : {{16{half_sel[15]}}, half_sel};
            2'b10:   rdata = rdata_word;
            default: rdata = rdata_word;
        endcase
    end

endmodule
