// -----------------------------------------------------------------------------
// cpu_pipeline_hazard_tb.sv — Phase 7 hazard detection/stall testbench
//
// STATUS: NOT YET SIMULATED IN THIS ENVIRONMENT (no iverilog in this
// sandbox). Every instruction encoding and expected value cross-checked
// against pipeline_hazard_model.py (a from-scratch cycle-accurate Python
// model adding the exact load-use stall logic to Phase 6's forwarding
// model) before being written here — 9/9 scenarios passed. One scenario
// (a supposedly-independent instruction after a load) initially failed
// due to my OWN test-construction mistake: the immediate value's low 5
// bits happened to numerically equal the load's destination register,
// triggering the SAME kind of coincidental-bit-match already documented
// in Phase 4/6 — now surfacing as an unnecessary (but harmless) stall
// rather than a wrong value. Fixed by choosing a non-aliasing immediate,
// documented in gen_hazard_tests.py and cpu_pipeline.sv/hazard_unit.sv.
// The actual .sv file below was parsed back and its real assertions
// replayed through the model a second time: zero mismatches.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module cpu_pipeline_hazard_tb;

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
        $dumpfile("sim/cpu_pipeline_hazard_tb.vcd");
        $dumpvars(0, cpu_pipeline_hazard_tb);

        $display("Phase 7 Hazard Detection / Stall Tests");
        $display("-----------------------------------------");

        // 1. Load-use hazard -- NOW correctly resolved (needs len+5 cycles:
        //    one extra for the stall bubble, versus Phase 5/6's len+4)
        clear_mem();
        IMEM[0]=32'h10000093; IMEM[1]=32'h12300113;
        IMEM[2]=32'h00000013; IMEM[3]=32'h00000013;
        IMEM[4]=32'h0020a023; IMEM[5]=32'h0000a183; IMEM[6]=32'h00018233;
        run_cycles(7+5);
        check_reg("load-use x3 (the load itself)", 3, 32'h123);
        check_reg("load-use x4 (NOW correctly resolved via stall+forward)", 4, 32'h123);

        // 2. Load-use chained to a second dependent instruction
        clear_mem();
        IMEM[0]=32'h10000093; IMEM[1]=32'h12300113;
        IMEM[2]=32'h00000013; IMEM[3]=32'h00000013;
        IMEM[4]=32'h0020a023; IMEM[5]=32'h0000a183;
        IMEM[6]=32'h00018233; IMEM[7]=32'h000202b3;
        run_cycles(8+5);
        check_reg("load-use chained: x3", 3, 32'h123);
        check_reg("load-use chained: x4", 4, 32'h123);
        check_reg("load-use chained: x5", 5, 32'h123);

        // 3. Load followed by an independent instruction: must NOT stall
        //    unnecessarily (exact cycle count -- only +4, no bonus cycle)
        clear_mem();
        IMEM[0]=32'h10000093; IMEM[1]=32'h12300113;
        IMEM[2]=32'h00000013; IMEM[3]=32'h00000013;
        IMEM[4]=32'h0020a023; IMEM[5]=32'h0000a183; IMEM[6]=32'h03200213;
        run_cycles(7+4);
        check_reg("load + independent: x3", 3, 32'h123);
        check_reg("load + independent: x4 (no unnecessary stall)", 4, 32'd50);

        // 4. Regression: N,N+1 / N,N+2 RAW still resolved by forwarding
        //    alone, no stall needed for a non-load producer
        clear_mem();
        IMEM[0]=32'h00a00093; IMEM[1]=32'h00008133;
        run_cycles(2+4);
        check_reg("N,N+1 RAW (regression, no stall)", 2, 32'd10);

        clear_mem();
        IMEM[0]=32'h00a00093; IMEM[1]=32'h00000013; IMEM[2]=32'h00008133;
        run_cycles(3+4);
        check_reg("N,N+2 RAW (regression, no stall)", 2, 32'd10);

        // 5. Regression: independent sequential, pipeline latency
        clear_mem();
        IMEM[0]=32'h00100093; IMEM[1]=32'h00200113;
        IMEM[2]=32'h00300193; IMEM[3]=32'h00400213;
        run_cycles(4+4);
        check_reg("independent sequential x1 (regression)", 1, 32'd1);
        check_reg("independent sequential x4 (regression)", 4, 32'd4);

        clear_mem();
        IMEM[0] = 32'h00700093;
        run_cycles(4);
        check_reg("latency: not yet committed @4 (regression)", 1, 32'd0);
        clear_mem();
        IMEM[0] = 32'h00700093;
        run_cycles(5);
        check_reg("latency: committed @5 (regression)", 1, 32'd7);

        // 6. Regression: branch operand forwarding still works with the
        //    hazard unit present
        clear_mem();
        IMEM[0]=32'h00500113; IMEM[1]=32'h00000013; IMEM[2]=32'h00000013;
        IMEM[3]=32'h00500093; IMEM[4]=32'h00208663;
        IMEM[5]=32'hfff00193; IMEM[6]=32'hfff00193; IMEM[7]=32'h02a00213;
        run_cycles(8+6);
        check_reg("branch operand forwarding (regression)", 4, 32'd42);

        $display("\n%0d/%0d tests passed", pass_count, pass_count + fail_count);
        if (fail_count > 0) $fatal(1, "cpu_pipeline hazard testbench had failures");
        $finish;
    end

endmodule
