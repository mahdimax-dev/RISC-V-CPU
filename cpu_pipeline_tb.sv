// -----------------------------------------------------------------------------
// cpu_pipeline_tb.sv — Phase 5 pipeline integration testbench for cpu_pipeline.sv
//
// STATUS: NOT YET SIMULATED IN THIS ENVIRONMENT (no iverilog in this
// sandbox). Every instruction encoding and every expected value below was
// cross-checked against a cycle-accurate Python model of this exact
// microarchitecture (pipeline_model.py) before being written here — 8/8
// scenarios passed, including two scenarios (load-use, back-to-back RAW)
// where the FIRST version of the test itself had construction bugs (an
// unintended extra hazard contaminating a later test, and the same
// LUI/ADDI negative-immediate gotcha caught in Phase 4) — both caught by
// the model disagreeing with my hand-derived expectation, not by guessing.
//
// Unlike cpu_top_tb.sv, several tests here check a NEGATIVE result on
// purpose: Phase 5 has no forwarding, no stall, and no flush by design
// (see cpu_pipeline.sv header). Tests 4-6 assert the CURRENT, EXPECTED-
// WRONG behavior for 1-apart / 2-apart RAW hazards and load-use hazards.
// This is not weakened verification — it's a regression lock on exactly
// what Phase 6/7 need to fix, matching the master project's phase plan.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module cpu_pipeline_tb;

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

    // Reset, then run exactly n_cycles clock edges (NOT n_instr -- Phase 5
    // tests care about exact cycle timing, e.g. "has this instruction
    // reached WB yet").
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
        $dumpfile("sim/cpu_pipeline_tb.vcd");
        $dumpvars(0, cpu_pipeline_tb);

        $display("Phase 5 Pipeline Integration Tests");
        $display("-----------------------------------");

        // 1a. Pipeline latency: single instruction NOT yet committed after
        //     only 4 cycles (IF@1 ID@2 EX@3 MEM@4 WB@5 -- result lands at
        //     the END of cycle 5, so after 4 cycles it must still be 0).
        clear_mem();
        IMEM[0] = 32'h00700093; // ADDI x1, x0, 7
        run_cycles(4);
        check_reg("latency: x1 not yet committed after 4 cycles", 1, 32'd0);

        // 1b. ...and IS committed after the 5th cycle.
        clear_mem();
        IMEM[0] = 32'h00700093;
        run_cycles(5);
        check_reg("latency: x1 committed after 5 cycles", 1, 32'd7);

        // 2. Independent sequential instructions, fully drained (N+4 cycles)
        clear_mem();
        IMEM[0]=32'h00100093; IMEM[1]=32'h00200113;
        IMEM[2]=32'h00300193; IMEM[3]=32'h00400213;
        run_cycles(4+4);
        check_reg("independent sequential x1", 1, 32'd1);
        check_reg("independent sequential x2", 2, 32'd2);
        check_reg("independent sequential x3", 3, 32'd3);
        check_reg("independent sequential x4", 4, 32'd4);

        // 3. N,N+3 RAW dependency -- resolved "for free" by regfile
        //    write-first (WB and ID land in the same cycle for this
        //    exact distance). This SHOULD be correct even in Phase 5.
        clear_mem();
        IMEM[0]=32'h00a00093; IMEM[1]=32'h00000013;
        IMEM[2]=32'h00000013; IMEM[3]=32'h00008133;
        run_cycles(4+4);
        check_reg("N,N+3 dependency (write-first) x1", 1, 32'd10);
        check_reg("N,N+3 dependency (write-first) x2", 2, 32'd10);

        // 4. N,N+1 RAW dependency -- EXPECTED WRONG (no forwarding yet,
        //    documents the exact Phase 6 requirement).
        clear_mem();
        IMEM[0]=32'h00a00093; IMEM[1]=32'h00008133;
        run_cycles(2+4);
        check_reg("N,N+1 RAW x1 (setup, correct)", 1, 32'd10);
        check_reg("N,N+1 RAW x2 (EXPECTED WRONG -- Phase 6 fixes this)", 2, 32'd0);

        // 5. N,N+2 RAW dependency -- EXPECTED WRONG, same reason.
        clear_mem();
        IMEM[0]=32'h00a00093; IMEM[1]=32'h00000013; IMEM[2]=32'h00008133;
        run_cycles(3+4);
        check_reg("N,N+2 RAW x1 (setup, correct)", 1, 32'd10);
        check_reg("N,N+2 RAW x2 (EXPECTED WRONG -- Phase 6 fixes this)", 2, 32'd0);

        // 6. Load-use hazard -- EXPECTED WRONG (Phase 7 fixes via stall).
        //    x1/x2 are spaced 4/3 instructions before first use (already
        //    safely resolved by write-first) so ONLY the LW->ADD
        //    dependency (1 apart) is actually under test here.
        clear_mem();
        IMEM[0]=32'h10000093; IMEM[1]=32'h12300113;
        IMEM[2]=32'h00000013; IMEM[3]=32'h00000013;
        IMEM[4]=32'h0020a023; IMEM[5]=32'h0000a183; IMEM[6]=32'h00018233;
        run_cycles(7+4);
        check_reg("load-use x3 (the load itself, correct)", 3, 32'h123);
        check_reg("load-use x4 (EXPECTED WRONG -- Phase 7 fixes this)", 4, 32'd0);

        // 7. Branch with no flush: the eventual landing instruction still
        //    executes correctly once the pipeline catches up. The two
        //    "shadow" instructions between the branch and its target WILL
        //    incorrectly execute (x3 ends up nonzero) -- expected per
        //    Phase 5 scope, documents the exact Phase 8 requirement. Only
        //    the landing instruction's correctness is asserted here.
        clear_mem();
        IMEM[0]=32'h00500093; IMEM[1]=32'h00500113; IMEM[2]=32'h00208663;
        IMEM[3]=32'hfff00193; IMEM[4]=32'hfff00193; IMEM[5]=32'h02a00213;
        run_cycles(6+6);
        check_reg("branch (no flush): landing instr still eventually correct", 4, 32'd42);

        $display("\n%0d/%0d tests passed", pass_count, pass_count + fail_count);
        if (fail_count > 0) $fatal(1, "cpu_pipeline integration testbench had failures");
        $finish;
    end

endmodule
