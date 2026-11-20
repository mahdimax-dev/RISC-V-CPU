// -----------------------------------------------------------------------------
// cpu_pipeline_flush_tb.sv — Phase 8 branch/jump flush testbench
//
// STATUS: NOT YET SIMULATED IN THIS ENVIRONMENT (no iverilog in this
// sandbox). Every instruction encoding and expected value cross-checked
// against pipeline_flush_model.py (a from-scratch cycle-accurate Python
// model adding the exact IF/ID + ID/EX flush logic to Phase 7's model)
// before being written here — 9/9 scenarios passed. One scenario (JALR)
// initially failed due to my OWN math error, the same class as an earlier
// Phase 4 bug: used the jump TARGET's address instead of the JALR
// instruction's own PC+4 for the expected link value, AND placed the
// target exactly on top of where I'd put a "shadow" instruction instead
// of past it. Both caught by the model disagreeing with my hand-derived
// expectation, fixed by recomputing properly (see gen_flush_tests.py).
// The actual .sv file below was parsed back and its real assertions
// replayed through the model a second time: zero mismatches.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module cpu_pipeline_flush_tb;

    logic clk = 0;
    logic reset;

    logic [31:0] imem_addr, imem_rdata;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic [3:0]  dmem_byte_en;
    logic        dmem_we, dmem_re;
    logic [1:0]  dmem_size;

    int pass_count = 0;
    int fail_count = 0;

    logic [31:0] IMEM [0:255];
    assign imem_rdata = IMEM[imem_addr[31:2]];

    logic [31:0] DMEM [0:255];
    assign dmem_rdata = DMEM[dmem_addr[31:2]];

    always_ff @(posedge clk) begin
        if (dmem_we) begin
            if (dmem_byte_en[0]) DMEM[dmem_addr[31:2]][7:0]   <= dmem_wdata[7:0];
            if (dmem_byte_en[1]) DMEM[dmem_addr[31:2]][15:8]  <= dmem_wdata[15:8];
            if (dmem_byte_en[2]) DMEM[dmem_addr[31:2]][23:16] <= dmem_wdata[23:16];
            if (dmem_byte_en[3]) DMEM[dmem_addr[31:2]][31:24] <= dmem_wdata[31:24];
        end
    end

    cpu_pipeline #(.RESET_VECTOR(32'h0)) dut (
        .clk(clk), .reset(reset),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
        .dmem_byte_en(dmem_byte_en), .dmem_we(dmem_we), .dmem_re(dmem_re),
        .dmem_size(dmem_size), .dmem_rdata(dmem_rdata)
    );

    always #5 clk = ~clk;

    task automatic clear_mem;
        for (int i = 0; i < 256; i++) begin
            IMEM[i] = 32'h0;
            DMEM[i] = 32'h0;
        end
    endtask

    task automatic run_cycles(int n_cycles);
        reset = 1;
        @(negedge clk);
        reset = 0;
        for (int i = 0; i < n_cycles; i++) begin
            @(posedge clk);
        end
        @(negedge clk);
    endtask

    task automatic check_reg(string name, int idx, logic [31:0] expected);
        logic [31:0] got;
        got = dut.u_regfile.regs[idx];
        if (idx == 0) got = 32'b0;
        if (got === expected) begin
            $display("[PASS] %s", name); pass_count++;
        end else begin
            $display("[FAIL] %s : expected=0x%08h got=0x%08h", name, expected, got);
            fail_count++;
        end
    endtask

    initial begin
        $dumpfile("sim/cpu_pipeline_flush_tb.vcd");
        $dumpvars(0, cpu_pipeline_flush_tb);

        $display("Phase 8 Branch/Jump Flush Tests");
        $display("----------------------------------");

        // 1. BEQ taken -- shadow instructions must NOT execute
        clear_mem();
        IMEM[0]=32'h00500093; IMEM[1]=32'h00500113; IMEM[2]=32'h00208663;
        IMEM[3]=32'hfff00193; IMEM[4]=32'hfff00193; IMEM[5]=32'h02a00213;
        run_cycles(6+6);
        check_reg("BEQ taken: shadow instrs flushed (x3=0)", 3, 32'd0);
        check_reg("BEQ taken: landing instr executed", 4, 32'd42);

        // 2. BEQ not taken -- must NOT falsely flush the real next instrs
        clear_mem();
        IMEM[0]=32'h00500093; IMEM[1]=32'h00600113; IMEM[2]=32'h00208663;
        IMEM[3]=32'h06300193; IMEM[4]=32'h02a00213;
        run_cycles(5+6);
        check_reg("BEQ not taken: no false flush (x3)", 3, 32'd99);
        check_reg("BEQ not taken: no false flush (x4)", 4, 32'd42);

        // 3. BNE taken -- shadow flush
        clear_mem();
        IMEM[0]=32'h00500093; IMEM[1]=32'h00600113; IMEM[2]=32'h00209663;
        IMEM[3]=32'hfff00193; IMEM[4]=32'hfff00193; IMEM[5]=32'h00700213;
        run_cycles(6+6);
        check_reg("BNE taken: shadow instrs flushed", 3, 32'd0);
        check_reg("BNE taken: landing instr executed", 4, 32'd7);

        // 4. JAL -- always taken, shadow flush + correct link value
        clear_mem();
        IMEM[0]=32'h008000ef; IMEM[1]=32'hfff00113; IMEM[2]=32'h03700193;
        run_cycles(3+6);
        check_reg("JAL: correct link value", 1, 32'd4);
        check_reg("JAL: shadow flushed", 2, 32'd0);
        check_reg("JAL: landing instr executed", 3, 32'd55);

        // 5. JALR -- shadow flush + correct target/link
        clear_mem();
        IMEM[0]=32'h01400093; IMEM[1]=32'h00000013; IMEM[2]=32'h00000013;
        IMEM[3]=32'h00408167; IMEM[4]=32'hfff00193; IMEM[5]=32'hfff00193;
        IMEM[6]=32'h04d00213;
        run_cycles(7+7);
        check_reg("JALR: correct link value", 2, 32'd16);
        check_reg("JALR: shadow flushed", 3, 32'd0);
        check_reg("JALR: landing instr executed", 4, 32'd77);

        // 6. Forwarding still correct immediately after a flush boundary
        clear_mem();
        IMEM[0]=32'h00500093; IMEM[1]=32'h00500113; IMEM[2]=32'h00208663;
        IMEM[3]=32'hfff00193; IMEM[4]=32'hfff00193;
        IMEM[5]=32'h00900293; IMEM[6]=32'h00028333;
        run_cycles(7+8);
        check_reg("forwarding correct right after a flush: x5", 5, 32'd9);
        check_reg("forwarding correct right after a flush: x6", 6, 32'd9);

        // 7. Regression: load-use hazard still correctly resolved
        clear_mem();
        IMEM[0]=32'h10000093; IMEM[1]=32'h12300113;
        IMEM[2]=32'h00000013; IMEM[3]=32'h00000013;
        IMEM[4]=32'h0020a023; IMEM[5]=32'h0000a183; IMEM[6]=32'h00018233;
        run_cycles(7+5);
        check_reg("load-use hazard (regression)", 4, 32'h123);

        // 8. Regression: independent sequential, pipeline latency
        clear_mem();
        IMEM[0]=32'h00100093; IMEM[1]=32'h00200113;
        IMEM[2]=32'h00300193; IMEM[3]=32'h00400213;
        run_cycles(4+4);
        check_reg("independent sequential (regression)", 4, 32'd4);

        clear_mem();
        IMEM[0] = 32'h00700093;
        run_cycles(5);
        check_reg("latency: committed @5 (regression)", 1, 32'd7);

        $display("\n%0d/%0d tests passed", pass_count, pass_count + fail_count);
        if (fail_count > 0) $fatal(1, "cpu_pipeline flush testbench had failures");
        $finish;
    end

endmodule
