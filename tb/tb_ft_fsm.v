`timescale 1ns/1ps
// Automated fault-injection testbench for the TMR controller (ft_fsm_top).
//
// A behavioral golden model of the unprotected FSM runs next to the DUT.
// On every cycle a checker compares:
//   * the voted state and voted outputs with the golden model
//   * every replica's state with (golden state ^ upset applied at the last
//     clock edge). This proves the upset really landed, the other replicas
//     were untouched, and the hit replica was back in step one cycle later.
//   * fault_detected with "an upset was applied at the last edge"
//
// Test suites:
//   1. reset values
//   2. fault-free functional run (directed scenario + random), arc coverage
//   3. directed single-bit upsets: every replica x bit x cycle of a scenario
//      that visits all six states
//   4. multi-bit upsets confined to one replica
//   5. LFSR-driven random campaigns at several fault rates
//   6. asynchronous reset while faults are being injected every cycle
//   7. LFSR period (maximal length)
//   8. known TMR limits: same-bit upset in two replicas (must escape, which
//      proves the checker can see a failure), and a common-mode upset into
//      an illegal state code (must fall back to IDLE)
module tb_ft_fsm;
    `include "ctrl_fsm_defs.vh"

    localparam SCEN_LEN = 16;
    localparam [15:0] SEED = 16'hACE1;

    reg        clk        = 1'b0;
    reg        rst_n      = 1'b0;
    reg        start      = 1'b0;
    reg        grant      = 1'b0;
    reg        ack        = 1'b0;
    reg        abort      = 1'b0;
    reg        inj_enable = 1'b0;
    reg  [3:0] inj_rate   = 4'd0;
    reg  [8:0] ext_mask   = 9'd0;

    wire        req, addr_en, data_en, done, err, fault_detected;
    wire [2:0]  state;
    wire [15:0] corrected_count, rep_cnt0, rep_cnt1, rep_cnt2, inject_count;

    ft_fsm_top #(.SEED(SEED)) dut (
        .clk               (clk),
        .rst_n             (rst_n),
        .start             (start),
        .grant             (grant),
        .ack               (ack),
        .abort             (abort),
        .inj_enable        (inj_enable),
        .inj_rate          (inj_rate),
        .ext_seu_mask      (ext_mask),
        .req               (req),
        .addr_en           (addr_en),
        .data_en           (data_en),
        .done              (done),
        .err               (err),
        .state             (state),
        .fault_detected    (fault_detected),
        .corrected_count   (corrected_count),
        .replica_err_count0(rep_cnt0),
        .replica_err_count1(rep_cnt1),
        .replica_err_count2(rep_cnt2),
        .inject_count      (inject_count)
    );

    always #5 clk = ~clk;

    // internal visibility
    wire [8:0]  rep_state = dut.u_ctrl.state_r;
    wire [14:0] rep_outs  = dut.u_ctrl.outs_r;
    wire [8:0]  seu_mask  = dut.seu_mask;
    wire [15:0] lfsr      = dut.u_inj.lfsr_q;
    wire [4:0]  d_outs    = {err, done, data_en, addr_en, req};

    integer seed   = 32'hFA17;
    integer errors = 0;

`ifdef DUMP
    initial begin
        $dumpfile("tb_ft_fsm.vcd");
        $dumpvars(0, tb_ft_fsm);
    end
`endif

    // ------------------------------------------------------------------
    // Golden model: the unprotected FSM, written behaviorally
    // ------------------------------------------------------------------
    reg [2:0] g_state;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            g_state <= S_IDLE;
        else begin
            case (g_state)
                S_IDLE:     if (start) g_state <= S_REQUEST;
                S_REQUEST:  if (abort) g_state <= S_ERROR;
                            else if (grant) g_state <= S_ADDRESS;
                S_ADDRESS:  g_state <= S_DATA;
                S_DATA:     if (abort) g_state <= S_ERROR;
                            else if (ack) g_state <= S_COMPLETE;
                default:    g_state <= S_IDLE;     // COMPLETE, ERROR
            endcase
        end
    end
    wire [4:0] g_outs = { g_state == S_ERROR, g_state == S_COMPLETE, g_state == S_DATA,
                          g_state == S_ADDRESS, g_state == S_REQUEST };

    task fail(input [8*56-1:0] what);
        begin
            errors = errors + 1;
            if (errors <= 25)
                $display("[%0t] FAIL %0s (state=%b golden=%b replicas=%b_%b_%b)",
                         $time, what, state, g_state,
                         rep_state[8:6], rep_state[5:3], rep_state[2:0]);
        end
    endtask

    // upset mask applied at the most recent clock edge
    reg [8:0] last_mask;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) last_mask <= 9'd0;
        else        last_mask <= seu_mask;

    // testbench's own fault tally, mirrors the DUT counters
    integer tb_faults = 0, tb_rf0 = 0, tb_rf1 = 0, tb_rf2 = 0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tb_faults = 0; tb_rf0 = 0; tb_rf1 = 0; tb_rf2 = 0;
        end else if (|seu_mask) begin
            tb_faults = tb_faults + 1;
            if (|seu_mask[2:0]) tb_rf0 = tb_rf0 + 1;
            if (|seu_mask[5:3]) tb_rf1 = tb_rf1 + 1;
            if (|seu_mask[8:6]) tb_rf2 = tb_rf2 + 1;
        end
    end

    // ------------------------------------------------------------------
    // Cycle-by-cycle checker and coverage
    // ------------------------------------------------------------------
    reg        chk_en = 1'b0;
    reg [53:0] fault_cov;          // [state*9 + replica*3 + bit]
    reg [63:0] arc_seen;           // [from*8 + to]
    reg [2:0]  g_prev;
    integer    n_cycles = 0, n_faults_seen = 0, n_active_faults = 0, n_hit_outs = 0;
    integer    cr, cb;

    always @(negedge rst_n) g_prev = S_IDLE;

    always @(negedge clk) begin
        if (rst_n && chk_en) begin
            n_cycles = n_cycles + 1;
            if (state  !== g_state) fail("voted state differs from golden");
            if (d_outs !== g_outs)  fail("voted outputs differ from golden");
            for (cr = 0; cr < 3; cr = cr + 1)
                if (rep_state[3*cr +: 3] !== (g_state ^ last_mask[3*cr +: 3]))
                    fail("replica state not as expected (upset/recovery)");
            if (fault_detected !== (|last_mask))
                fail("fault_detected wrong");

            if (|last_mask) begin
                n_faults_seen = n_faults_seen + 1;
                if (g_state != S_IDLE) n_active_faults = n_active_faults + 1;
                for (cr = 0; cr < 3; cr = cr + 1) begin
                    for (cb = 0; cb < 3; cb = cb + 1)
                        if (last_mask[3*cr + cb]) fault_cov[9*g_state + 3*cr + cb] = 1'b1;
                    // the hit replica's own outputs were wrong; the voter hid it
                    if ((|last_mask[3*cr +: 3]) && rep_outs[5*cr +: 5] !== g_outs)
                        n_hit_outs = n_hit_outs + 1;
                end
            end

            arc_seen[8*g_prev + g_state] = 1'b1;
            g_prev = g_state;
        end
    end

    function integer popcount54(input [53:0] v);
        integer j;
        begin
            popcount54 = 0;
            for (j = 0; j < 54; j = j + 1) popcount54 = popcount54 + v[j];
        end
    endfunction

    // ------------------------------------------------------------------
    // Stimulus helpers
    // ------------------------------------------------------------------
    // Directed scenario {start, grant, ack, abort}; visits all six states
    // and all eleven legal transitions.
    function [3:0] scen(input integer k);
        case (k)
            0:  scen = 4'b1000;   // IDLE     -> REQUEST
            1:  scen = 4'b0000;   // REQUEST  waits
            2:  scen = 4'b0100;   // REQUEST  -> ADDRESS
            3:  scen = 4'b0000;   // ADDRESS  -> DATA
            4:  scen = 4'b0000;   // DATA     waits
            5:  scen = 4'b0010;   // DATA     -> COMPLETE
            6:  scen = 4'b0000;   // COMPLETE -> IDLE
            7:  scen = 4'b1000;   // IDLE     -> REQUEST
            8:  scen = 4'b0001;   // REQUEST  -> ERROR (abort)
            9:  scen = 4'b0000;   // ERROR    -> IDLE
            10: scen = 4'b1000;   // IDLE     -> REQUEST
            11: scen = 4'b0100;   // REQUEST  -> ADDRESS
            12: scen = 4'b0000;   // ADDRESS  -> DATA
            13: scen = 4'b0001;   // DATA     -> ERROR (abort)
            14: scen = 4'b0000;   // ERROR    -> IDLE
            default: scen = 4'b0000;
        endcase
    endfunction

    task rand_inputs;
        begin
            start = (($random(seed) & 3) == 0);
            grant = $random(seed);
            ack   = $random(seed);
            abort = (($random(seed) & 15) == 0);
        end
    endtask

    // called on a negedge; returns just after the following negedge
    task do_reset;
        begin
            #2 rst_n = 1'b0;
            @(negedge clk);
            #1 rst_n = 1'b1;
        end
    endtask

    task check_reset_values(input [8*40-1:0] where);
        begin
            if (state !== S_IDLE || rep_state !== 9'd0) fail(where);
            if (d_outs !== 5'd0 || fault_detected !== 1'b0) fail(where);
            if (corrected_count !== 0 || rep_cnt0 !== 0 || rep_cnt1 !== 0 || rep_cnt2 !== 0)
                fail(where);
            if (inject_count !== 0 || lfsr !== SEED) fail(where);
        end
    endtask

    // Run the directed scenario from reset, applying `mask` at cycle `at`.
    task run_scenario(input [8:0] mask, input integer at);
        integer k;
        begin
            do_reset;
            for (k = 0; k < SCEN_LEN; k = k + 1) begin
                {start, grant, ack, abort} = scen(k);
                ext_mask = (k == at) ? mask : 9'd0;
                @(negedge clk);
            end
            {start, grant, ack, abort} = 4'b0000;
            ext_mask = 9'd0;
            repeat (2) @(negedge clk);
        end
    endtask

    task expect_counts(input integer n, input integer rep);
        begin
            if (corrected_count !== n)                   fail("corrected_count");
            if (rep_cnt0 !== ((rep == 0) ? n : 0))       fail("replica_err_count0");
            if (rep_cnt1 !== ((rep == 1) ? n : 0))       fail("replica_err_count1");
            if (rep_cnt2 !== ((rep == 2) ? n : 0))       fail("replica_err_count2");
        end
    endtask

    // Random-input campaign with the LFSR injector at the given rate.
    task run_campaign(input [3:0] rate, input integer cycles);
        integer k;
        begin
            do_reset;
            inj_rate   = rate;
            inj_enable = 1'b1;
            for (k = 0; k < cycles; k = k + 1) begin
                rand_inputs;
                @(negedge clk);
            end
            inj_enable = 1'b0;
            {start, grant, ack, abort} = 4'b0000;
            repeat (2) @(negedge clk);
            if (inject_count    !== tb_faults) fail("inject_count != faults applied");
            if (corrected_count !== tb_faults) fail("corrected_count != faults applied");
            if (rep_cnt0 !== tb_rf0 || rep_cnt1 !== tb_rf1 || rep_cnt2 !== tb_rf2)
                fail("per-replica counters != faults applied");
            $display("  rate 2^-%0d: %6d cycles, %6d upsets injected, %6d detected+corrected  (r0 %0d / r1 %0d / r2 %0d)",
                     rate, cycles, inject_count, corrected_count, rep_cnt0, rep_cnt1, rep_cnt2);
        end
    endtask

    // Common-mode upset of all three replicas into an illegal code.
    task illegal_recovery(input [2:0] flip);
        integer k;
        begin
            do_reset;
            for (k = 0; k <= 5; k = k + 1) begin
                {start, grant, ack, abort} = scen(k);
                ext_mask = (k == 5) ? {flip, flip, flip} : 9'd0;   // edge 5 captures COMPLETE
                @(negedge clk);
            end
            ext_mask = 9'd0;
            {start, grant, ack, abort} = 4'b0000;
            if (state !== (S_COMPLETE ^ flip) || state < 3'd6)
                fail("illegal-code upset did not land");
            if (d_outs !== 5'd0)          fail("outputs asserted in illegal state");
            @(negedge clk);
            if (state !== S_IDLE || rep_state !== 9'd0)
                fail("no recovery from illegal state");
            $display("  common-mode upset to illegal code %b -> recovered to IDLE in 1 cycle", S_COMPLETE ^ flip);
        end
    endtask

    // ------------------------------------------------------------------
    // Test sequence
    // ------------------------------------------------------------------
    integer r, b, c, i, n, period;
    integer n_directed = 0, n_multibit = 0, n_resets = 0;
    reg [15:0] lfsr_first;
    reg        lfsr_zero;
    reg [63:0] legal_arcs;
    integer    arcs_hit;

    initial begin
        legal_arcs = 64'd0;
        legal_arcs[8*S_IDLE     + S_IDLE]     = 1'b1;
        legal_arcs[8*S_IDLE     + S_REQUEST]  = 1'b1;
        legal_arcs[8*S_REQUEST  + S_REQUEST]  = 1'b1;
        legal_arcs[8*S_REQUEST  + S_ADDRESS]  = 1'b1;
        legal_arcs[8*S_REQUEST  + S_ERROR]    = 1'b1;
        legal_arcs[8*S_ADDRESS  + S_DATA]     = 1'b1;
        legal_arcs[8*S_DATA     + S_DATA]     = 1'b1;
        legal_arcs[8*S_DATA     + S_COMPLETE] = 1'b1;
        legal_arcs[8*S_DATA     + S_ERROR]    = 1'b1;
        legal_arcs[8*S_COMPLETE + S_IDLE]     = 1'b1;
        legal_arcs[8*S_ERROR    + S_IDLE]     = 1'b1;
        fault_cov = 54'd0;
        arc_seen  = 64'd0;

        // ---------------- 1. reset values ----------------
        repeat (2) @(negedge clk);
        check_reset_values("power-on reset values");
        #1 rst_n = 1'b1;
        chk_en = 1'b1;
        $display("[1] reset values checked");

        // ---------------- 2. fault-free functional ----------------
        run_scenario(9'd0, -1);
        for (i = 0; i < 20000; i = i + 1) begin
            rand_inputs;
            @(negedge clk);
        end
        {start, grant, ack, abort} = 4'b0000;
        repeat (2) @(negedge clk);
        expect_counts(0, -1);
        arcs_hit = popcount54(arc_seen[53:0] & legal_arcs[53:0]);
        if (arcs_hit != 11) fail("transition coverage incomplete");
        if (|(arc_seen & ~legal_arcs)) fail("illegal transition taken");
        $display("[2] fault-free run: %0d/11 legal transitions covered, 0 faults expected, %0d corrected",
                 arcs_hit, corrected_count);

        // ---------------- 3. directed single-bit upsets ----------------
        fault_cov = 54'd0;
        for (r = 0; r < 3; r = r + 1)
            for (b = 0; b < 3; b = b + 1)
                for (c = 0; c < SCEN_LEN; c = c + 1) begin
                    run_scenario(9'd1 << (3*r + b), c);
                    expect_counts(1, r);
                    n_directed = n_directed + 1;
                end
        if (popcount54(fault_cov) != 54) fail("directed fault coverage incomplete");
        $display("[3] directed single-bit upsets: %0d runs, (state x replica x bit) coverage %0d/54",
                 n_directed, popcount54(fault_cov));

        // ---------------- 4. multi-bit upset in one replica ----------------
        for (r = 0; r < 3; r = r + 1)
            for (b = 3; b < 8; b = b + 1)          // patterns 011,100,101,110,111
                for (c = 0; c < SCEN_LEN; c = c + 1) begin
                    run_scenario(b[2:0] << (3*r), c);
                    expect_counts(1, r);
                    n_multibit = n_multibit + 1;
                end
        $display("[4] multi-bit upsets confined to one replica: %0d runs", n_multibit);

        // ---------------- 5. LFSR random campaigns ----------------
        fault_cov = 54'd0;
        $display("[5] LFSR fault-injection campaigns (random inputs):");
        run_campaign(4'd0, 30000);
        run_campaign(4'd1, 30000);
        run_campaign(4'd2, 30000);
        run_campaign(4'd4, 30000);
        run_campaign(4'd6, 30000);
        if (popcount54(fault_cov) != 54) fail("random campaign coverage incomplete");
        $display("    (state x replica x bit) coverage %0d/54", popcount54(fault_cov));

        // ---------------- 6. reset during fault injection ----------------
        do_reset;
        inj_rate   = 4'd0;
        inj_enable = 1'b1;
        for (i = 0; i < 100; i = i + 1) begin
            n = 1 + ($random(seed) & 31);
            repeat (n) begin
                rand_inputs;
                @(negedge clk);
            end
            #2 rst_n = 1'b0;                        // asynchronous, mid-cycle
            #1 check_reset_values("reset during injection");
            n_resets = n_resets + 1;
            @(negedge clk);
            #1 rst_n = 1'b1;
        end
        repeat (200) begin
            rand_inputs;
            @(negedge clk);
        end
        inj_enable = 1'b0;
        {start, grant, ack, abort} = 4'b0000;
        repeat (2) @(negedge clk);
        if (corrected_count !== tb_faults || inject_count !== tb_faults)
            fail("counters after resets");
        $display("[6] %0d asynchronous resets during every-cycle injection: state, outputs and counters cleared",
                 n_resets);

        // ---------------- 7. LFSR period ----------------
        chk_en = 1'b0;
        do_reset;
        lfsr_first = lfsr;
        lfsr_zero  = 1'b0;
        @(negedge clk);
        period = 1;
        while (lfsr !== lfsr_first && period < 70000) begin
            if (lfsr == 16'd0) lfsr_zero = 1'b1;
            @(negedge clk);
            period = period + 1;
        end
        if (period != 65535 || lfsr_zero) fail("LFSR is not maximal length");
        $display("[7] LFSR period = %0d (maximal = 65535)", period);

        // ---------------- 8. known TMR limits ----------------
        // 8a: the same bit upset in two replicas outvotes the good one. The
        //     golden comparison must see this, otherwise the checker is blind.
        do_reset;
        for (i = 0; i <= 2; i = i + 1) begin
            {start, grant, ack, abort} = scen(i);
            ext_mask = (i == 2) ? 9'b000_001_001 : 9'd0;    // edge 2 captures ADDRESS
            @(negedge clk);
        end
        ext_mask = 9'd0;
        if (state === g_state) fail("double upset was not visible to the checker");
        else $display("[8] same-bit double upset: voted %b vs golden %b -> escape detected by checker (expected TMR limit)",
                      state, g_state);
        illegal_recovery(3'b010);
        illegal_recovery(3'b011);
        do_reset;

        // ---------------- summary ----------------
        $display("--------------------------------------------------");
        $display("cycles checked against golden model : %0d", n_cycles);
        $display("upsets applied under checker        : %0d (%0d while not IDLE)",
                 n_faults_seen, n_active_faults);
        $display("hit replica's own outputs wrong      : %0d (all masked by the voter)", n_hit_outs);
        $display("errors                               : %0d", errors);
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("TESTS FAILED");
        $finish;
    end

    initial begin
        #50_000_000;
        $display("TIMEOUT: simulation watchdog expired");
        $display("TESTS FAILED");
        $finish;
    end
endmodule
