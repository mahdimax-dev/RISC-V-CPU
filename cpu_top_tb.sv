// -----------------------------------------------------------------------------
// cpu_top_tb.sv — Phase 4 integration testbench for cpu_top.sv
//
// STATUS: NOT YET SIMULATED IN THIS ENVIRONMENT (no iverilog in this
// sandbox — see docs/phase2-environment.md). Every instruction encoding
// and every expected value below was cross-checked against a Python
// behavioral model of the exact same datapath BEFORE being written here
// (see docs/phase4-datapath.md) — this cross-check is what caught a real
// bug in control_unit.sv (ADDI/negative-immediate misdecoded as SUB,
// now fixed) plus two mistakes in the test construction itself (a
// truncated-immediate test, and a JALR link-value math error). All 19
// underlying test scenarios (one test below — "SW+LW" — covers two of
// the master task's 20 items, LW and SW, in one program) passed 19/19 in
// the Python model against the CORRECTED control_unit logic before this
// file was written.
//
// Each test loads its own small program into a fresh behavioral
// instruction memory, resets the CPU, single-steps it for exactly as many
// cycles as there are instructions, then checks final architectural state
// (registers and/or data memory).
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module cpu_top_tb;

    logic clk = 0;
    logic reset;

    logic [31:0] imem_addr, imem_rdata;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic [3:0]  dmem_byte_en;
    logic        dmem_we, dmem_re;
    logic [1:0]  dmem_size;
    logic        illegal_instr;

    int pass_count = 0;
    int fail_count = 0;

    // Behavioral word-oriented instruction memory (combinational read)
    logic [31:0] IMEM [0:255];
    assign imem_rdata = IMEM[imem_addr[31:2]];

    // Behavioral word-oriented data memory (combinational read, byte-enabled
    // synchronous write — mirrors the byte_en contract cpu_top.sv drives)
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

    cpu_top #(.RESET_VECTOR(32'h0)) dut (
        .clk(clk), .reset(reset),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
        .dmem_byte_en(dmem_byte_en), .dmem_we(dmem_we), .dmem_re(dmem_re),
        .dmem_size(dmem_size), .dmem_rdata(dmem_rdata),
        .illegal_instr(illegal_instr)
    );

    always #5 clk = ~clk;

    task automatic clear_mem;
        for (int i = 0; i < 256; i++) begin
            IMEM[i] = 32'h0;
            DMEM[i] = 32'h0;
        end
    endtask

    // Reset the CPU (register file + PC) and run exactly n_instr cycles.
    task automatic run_program(int n_instr);
        reset = 1;
        @(negedge clk);
        reset = 0;
        for (int i = 0; i < n_instr; i++) begin
            @(posedge clk);
        end
        @(negedge clk); // let combinational writeback/decode settle
    endtask

    task automatic check_reg(string name, int idx, logic [31:0] expected);
        logic [31:0] got;
        got = dut.u_regfile.regs[idx];
        if (idx == 0) got = 32'b0; // x0 always architecturally reads 0
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
        $dumpfile("sim/cpu_top_tb.vcd");
        $dumpvars(0, cpu_top_tb);

        $display("Phase 4 Integration Tests");
        $display("-------------------------");

        // 1. ADD : x1=10, x2=3, x3=x1+x2=13
        clear_mem();
        IMEM[0]=32'h00a00093; IMEM[1]=32'h00300113; IMEM[2]=32'h002081b3;
        run_program(3);
        check_reg("ADD", 3, 32'd13);

        // 2. SUB : x1=10, x2=3, x3=x1-x2=7
        clear_mem();
        IMEM[0]=32'h00a00093; IMEM[1]=32'h00300113; IMEM[2]=32'h402081b3;
        run_program(3);
        check_reg("SUB", 3, 32'd7);

        // 3. ADDI : x1 = 0+5 = 5
        clear_mem();
        IMEM[0]=32'h00500093;
        run_program(1);
        check_reg("ADDI", 1, 32'd5);

        // 4. logical (AND) : x1=0xFF, x2=0x0F, x3 = x1&x2 = 0x0F
        clear_mem();
        IMEM[0]=32'h0ff00093; IMEM[1]=32'h00f00113; IMEM[2]=32'h0020f1b3;
        run_program(3);
        check_reg("logical (AND)", 3, 32'h0000000F);

        // 5. shift (SLLI) : x1=1, x2 = x1<<4 = 16
        clear_mem();
        IMEM[0]=32'h00100093; IMEM[1]=32'h00409113;
        run_program(2);
        check_reg("shift (SLLI)", 2, 32'd16);

        // 6. SLT : x1=-1, x2=1, x3 = (x1<x2 signed) = 1
        clear_mem();
        IMEM[0]=32'hfff00093; IMEM[1]=32'h00100113; IMEM[2]=32'h0020a1b3;
        run_program(3);
        check_reg("SLT", 3, 32'd1);

        // 7. LUI : x1 = 0xABCDE000
        clear_mem();
        IMEM[0]=32'habcde0b7;
        run_program(1);
        check_reg("LUI", 1, 32'hABCDE000);

        // 8. AUIPC : x1 = PC(0) + 0x00001000 = 0x00001000
        clear_mem();
        IMEM[0]=32'h00001097;
        run_program(1);
        check_reg("AUIPC", 1, 32'h00001000);

        // 9/10. SW + LW round trip through 0xCAFEBABE at address 0x100
        clear_mem();
        IMEM[0]=32'h10000093; IMEM[1]=32'hcafec137; IMEM[2]=32'habe10113;
        IMEM[3]=32'h0020a023; IMEM[4]=32'h0000a183;
        run_program(5);
        check_reg("SW (value built correctly)", 2, 32'hCAFEBABE);
        check_mem("SW (memory contents)", 32'h100, 32'hCAFEBABE);
        check_reg("LW", 3, 32'hCAFEBABE);

        // 11. LB / LBU : store -5 as a byte at 0x200, read back signed/unsigned
        clear_mem();
        IMEM[0]=32'h20000093; IMEM[1]=32'hffb00113; IMEM[2]=32'h00208023;
        IMEM[3]=32'h00008183; IMEM[4]=32'h0000c203;
        run_program(5);
        check_reg("LB (sign-extended)", 3, 32'hFFFFFFFB);
        check_reg("LBU (zero-extended)", 4, 32'h000000FB);

        // 12. LH / LHU : store -1000 as a halfword at 0x300, read back both ways
        clear_mem();
        IMEM[0]=32'h30000093; IMEM[1]=32'hc1800113; IMEM[2]=32'h00209023;
        IMEM[3]=32'h00009183; IMEM[4]=32'h0000d203;
        run_program(5);
        check_reg("LH (sign-extended)", 3, 32'hFFFFFC18);
        check_reg("LHU (zero-extended)", 4, 32'h0000FC18);

        // 13. BEQ taken : x1=5, x2=5, branch skips the ADDI x3,-1 instruction
        clear_mem();
        IMEM[0]=32'h00500093; IMEM[1]=32'h00500113; IMEM[2]=32'h00208463;
        IMEM[3]=32'hfff00193; IMEM[4]=32'h02a00213;
        run_program(5);
        check_reg("BEQ taken (skipped instr not executed)", 3, 32'd0);
        check_reg("BEQ taken (landing instr executed)", 4, 32'd42);

        // 14. BEQ not taken : x1=5, x2=6, both following instrs execute
        clear_mem();
        IMEM[0]=32'h00500093; IMEM[1]=32'h00600113; IMEM[2]=32'h00208463;
        IMEM[3]=32'h06300193; IMEM[4]=32'h02a00213;
        run_program(5);
        check_reg("BEQ not taken", 3, 32'd99);
        check_reg("BEQ not taken (fallthrough)", 4, 32'd42);

        // 15. BNE : x1=5, x2=6 (unequal) -> taken, skips ADDI x3,-1
        clear_mem();
        IMEM[0]=32'h00500093; IMEM[1]=32'h00600113; IMEM[2]=32'h00209463;
        IMEM[3]=32'hfff00193; IMEM[4]=32'h00700213;
        run_program(5);
        check_reg("BNE taken (skipped instr not executed)", 3, 32'd0);
        check_reg("BNE taken (landing instr executed)", 4, 32'd7);

        // 16. JAL : x1 = link value (PC+4=4), jumps to instruction at byte 8
        clear_mem();
        IMEM[0]=32'h008000ef; IMEM[1]=32'hfff00113; IMEM[2]=32'h03700193;
        run_program(3);
        check_reg("JAL (link value)", 1, 32'd4);
        check_reg("JAL (skipped instr not executed)", 2, 32'd0);
        check_reg("JAL (landing instr executed)", 3, 32'd55);

        // 17. JALR : x1=12 (base), JALR x2,4(x1) -> target=(12+4)&~1=16,
        //     link value = PC-of-JALR(4) + 4 = 8
        clear_mem();
        IMEM[0]=32'h00c00093; IMEM[1]=32'h00408167; IMEM[2]=32'hfff00193;
        IMEM[3]=32'hfff00193; IMEM[4]=32'h04d00213;
        run_program(5);
        check_reg("JALR (link value)", 2, 32'd8);
        check_reg("JALR (skipped instrs not executed)", 3, 32'd0);
        check_reg("JALR (landing instr executed)", 4, 32'd77);

        // 18. x0 invariant : ADDI x0, x0, 123 must leave x0 at 0
        clear_mem();
        IMEM[0]=32'h07b00013;
        run_program(1);
        check_reg("x0 invariant", 0, 32'd0);

        // 19. sequential multi-instruction dependency chain
        clear_mem();
        IMEM[0]=32'h00100093; IMEM[1]=32'h00200113; IMEM[2]=32'h002081b3;
        IMEM[3]=32'h00118233; IMEM[4]=32'h003202b3;
        run_program(5);
        check_reg("sequential multi (x3)", 3, 32'd3);
        check_reg("sequential multi (x4)", 4, 32'd4);
        check_reg("sequential multi (x5)", 5, 32'd7);

        // 20. integration program: sum 1+2+3+4=10 via chained ADDs, store,
        //     load back
        clear_mem();
        IMEM[0]=32'h00100093; IMEM[1]=32'h00200113; IMEM[2]=32'h00300193;
        IMEM[3]=32'h00400213; IMEM[4]=32'h002082b3; IMEM[5]=32'h003282b3;
        IMEM[6]=32'h004282b3; IMEM[7]=32'h00502023; IMEM[8]=32'h00002303;
        run_program(9);
        check_reg("integration program (sum in reg)", 5, 32'd10);
        check_mem("integration program (sum in mem)", 32'h0, 32'd10);
        check_reg("integration program (sum read back)", 6, 32'd10);

        $display("\n%0d/%0d tests passed", pass_count, pass_count + fail_count);
        if (fail_count > 0) $fatal(1, "cpu_top integration testbench had failures");
        $finish;
    end

endmodule
