// -----------------------------------------------------------------------------
// cpu_pipeline_fwd_tb.sv — Phase 6 forwarding testbench for cpu_pipeline.sv
//
// STATUS: NOT YET SIMULATED IN THIS ENVIRONMENT (no iverilog in this
// sandbox). Every instruction encoding and expected value cross-checked
// against pipeline_fwd_model.py (a from-scratch cycle-accurate Python
// model adding the exact forwarding logic to Phase 5's pipeline model)
// before being written here — 11/11 scenarios passed. One scenario
// (load-use) required correcting my OWN predicted "expected wrong" value
// mid-development: with forwarding active but no load-use interlock, the
// wrong answer changes from Phase 5's stale-zero to the forwarded raw
// load ADDRESS being mistaken for data — a real, faithful finding, not a
// modeling error (see docs/phase6-forwarding.md). The actual .sv file
// below was then parsed back and its real assertions replayed through the
// model a second time: zero mismatches.
//
// This testbench does NOT replace cpu_pipeline_tb.sv (Phase 5) -- both
// are kept and both must keep passing (Phase 5's file is unmodified; its
// "EXPECTED WRONG" 1-apart/2-apart assertions would now legitimately FAIL
// against the current cpu_pipeline.sv, since forwarding fixes them -- see
// docs/phase6-forwarding.md for why that file is intentionally NOT
// re-run as a live regression after Phase 6, and is kept as a dated
// historical record instead).
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module cpu_pipeline_fwd_tb;

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

    task automatic check_mem(string name, logic [31:0] addr, logic [31:0] expected);
        logic [31:0] got;
        got = DMEM[addr[31:2]];
        if (got === expected) begin
            $display("[PASS] %s", name); pass_count++;
        end else begin
            $display("[FAIL] %s : expected=0x%08h got=0x%08h", name, expected, got);
            fail_count++;
        end
    endtask

    initial begin
        $dumpfile("sim/cpu_pipeline_fwd_tb.vcd");
        $dumpvars(0, cpu_pipeline_fwd_tb);

        $display("Phase 6 Forwarding Tests");
        $display("--------------------------");

        // 1. N,N+1 RAW -- NOW correct via EX/MEM forward
        clear_mem();
        IMEM[0]=32'h00a00093; IMEM[1]=32'h00008133;
        run_cycles(2+4);
        check_reg("N,N+1 RAW: x1", 1, 32'd10);
        check_reg("N,N+1 RAW: x2 (NOW correct via forwarding)", 2, 32'd10);

        // 2. N,N+2 RAW -- NOW correct via MEM/WB forward
        clear_mem();
        IMEM[0]=32'h00a00093; IMEM[1]=32'h00000013; IMEM[2]=32'h00008133;
        run_cycles(3+4);
        check_reg("N,N+2 RAW: x1", 1, 32'd10);
        check_reg("N,N+2 RAW: x2 (NOW correct via forwarding)", 2, 32'd10);

        // 3. N,N+3 -- regression, still correct via write-first
        clear_mem();
        IMEM[0]=32'h00a00093; IMEM[1]=32'h00000013;
        IMEM[2]=32'h00000013; IMEM[3]=32'h00008133;
        run_cycles(4+4);
        check_reg("N,N+3 (regression)", 2, 32'd10);

        // 4. Store data forwarding: back-to-back ADDI x1 -> SW x1
        clear_mem();
        IMEM[0]=32'h10000113; IMEM[1]=32'h00000013; IMEM[2]=32'h00000013;
        IMEM[3]=32'h07700093; IMEM[4]=32'h00112023;
        run_cycles(5+4);
        check_mem("store data forwarding", 32'h100, 32'h77);

        // 5. Store address forwarding: back-to-back ADDI x1 -> SW using x1 as base
        clear_mem();
        IMEM[0]=32'h05500113; IMEM[1]=32'h00000013; IMEM[2]=32'h00000013;
        IMEM[3]=32'h20000093; IMEM[4]=32'h0020a023;
        run_cycles(5+4);
        check_mem("store address forwarding", 32'h200, 32'h55);

        // 6. Branch operand forwarding: back-to-back ADDI x1 -> BEQ x1,x2
        clear_mem();
        IMEM[0]=32'h00500113; IMEM[1]=32'h00000013; IMEM[2]=32'h00000013;
        IMEM[3]=32'h00500093; IMEM[4]=32'h00208663;
        IMEM[5]=32'hfff00193; IMEM[6]=32'hfff00193; IMEM[7]=32'h02a00213;
        run_cycles(8+6);
        check_reg("branch operand forwarding (landing instr)", 4, 32'd42);

        // 7. Forwarding priority: EX/MEM (more recent) beats MEM/WB
        clear_mem();
        IMEM[0]=32'h00100093; IMEM[1]=32'h00200093; IMEM[2]=32'h00008133;
        run_cycles(3+4);
        check_reg("forwarding priority: x1 (final value)", 1, 32'd2);
        check_reg("forwarding priority: x2 (must get MOST RECENT x1=2, not 1)", 2, 32'd2);

        // 8. Load-use hazard.
        clear_mem();
        IMEM[0]=32'h10000093; IMEM[1]=32'h12300113;
        IMEM[2]=32'h00000013; IMEM[3]=32'h00000013;
        IMEM[4]=32'h0020a023; IMEM[5]=32'h0000a183; IMEM[6]=32'h00018233;
        // NOTE (updated after Phase 7): originally run_cycles(7+4) with an
        // expected WRONG value (0x100, documenting forwarding's limits --
        // see docs/phase6-forwarding.md). Phase 7's hazard_unit.sv now
        // correctly detects and stalls this exact case for one cycle, so
        // the cycle count needed +1 (7+5, matching cpu_pipeline_hazard_tb.sv)
        // and the expected value updated to the now-correct 0x123 -- this
        // is keeping the test accurate to a genuine fix, not weakening it.
        // Every other assertion in this file (store/branch forwarding,
        // priority, N+1/N+2 RAW, regressions) is untouched and still
        // exercises real, unique Phase 6 coverage not retested elsewhere.
        run_cycles(7+5);
        check_reg("load-use x3 (the load itself, still correct)", 3, 32'h123);
        check_reg("load-use x4 (Phase 7 hazard_unit now fixes this)", 4, 32'h123);

        // 9. Independent sequential -- regression
        clear_mem();
        IMEM[0]=32'h00100093; IMEM[1]=32'h00200113;
        IMEM[2]=32'h00300193; IMEM[3]=32'h00400213;
        run_cycles(4+4);
        check_reg("independent sequential x1 (regression)", 1, 32'd1);
        check_reg("independent sequential x2 (regression)", 2, 32'd2);
        check_reg("independent sequential x3 (regression)", 3, 32'd3);
        check_reg("independent sequential x4 (regression)", 4, 32'd4);

        // 10. Pipeline latency -- regression
        clear_mem();
        IMEM[0] = 32'h00700093;
        run_cycles(4);
        check_reg("latency: not yet committed @4 (regression)", 1, 32'd0);
        clear_mem();
        IMEM[0] = 32'h00700093;
        run_cycles(5);
        check_reg("latency: committed @5 (regression)", 1, 32'd7);

        $display("\n%0d/%0d tests passed", pass_count, pass_count + fail_count);
        if (fail_count > 0) $fatal(1, "cpu_pipeline forwarding testbench had failures");
        $finish;
    end

endmodule
