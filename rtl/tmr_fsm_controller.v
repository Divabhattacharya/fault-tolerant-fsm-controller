`timescale 1ns/1ps
// Fault-tolerant control FSM using Triple Modular Redundancy (TMR).
//
//  * three ctrl_fsm_replica instances
//  * bitwise majority vote on the state; the voted state is fed back to all
//    three replicas, so an upset replica is rewritten with the correct state
//    on the next clock edge (recovery in one cycle, no reset needed)
//  * bitwise majority vote on the replicas' Moore outputs
//  * error counters (16-bit, saturating): cycles in which a disagreement was
//    detected and masked, and per replica the cycles it was outvoted
module tmr_fsm_controller (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire        grant,
    input  wire        ack,
    input  wire        abort,
    input  wire [8:0]  seu_mask,            // {r2, r1, r0}; 0 in normal use
    output wire        req,
    output wire        addr_en,
    output wire        data_en,
    output wire        done,
    output wire        err,
    output wire [2:0]  state,               // voted state
    output wire        fault_detected,      // replicas disagree this cycle
    output reg  [15:0] corrected_count,
    output reg  [15:0] replica_err_count0,
    output reg  [15:0] replica_err_count1,
    output reg  [15:0] replica_err_count2
);
    wire [8:0]  state_r;                    // {r2, r1, r0}
    wire [14:0] outs_r;                     // {r2, r1, r0}, 5 bits each
    wire [2:0]  voted_state;
    wire [4:0]  voted_outs;
    wire [2:0]  outvoted;
    wire        state_mismatch;
    wire        outs_mismatch;

    genvar i;
    generate
        for (i = 0; i < 3; i = i + 1) begin : g_rep
            (* keep_hierarchy = "yes", dont_touch = "true" *)
            ctrl_fsm_replica u_rep (
                .clk        (clk),
                .rst_n      (rst_n),
                .voted_state(voted_state),
                .start      (start),
                .grant      (grant),
                .ack        (ack),
                .abort      (abort),
                .seu_mask   (seu_mask[3*i +: 3]),
                .state_q    (state_r[3*i +: 3]),
                .outs       (outs_r[5*i +: 5])
            );
        end
    endgenerate

    tmr_voter #(.W(3)) u_vote_state (
        .a       (state_r[2:0]),
        .b       (state_r[5:3]),
        .c       (state_r[8:6]),
        .y       (voted_state),
        .err     (outvoted),
        .mismatch(state_mismatch)
    );

    tmr_voter #(.W(5)) u_vote_outs (
        .a       (outs_r[4:0]),
        .b       (outs_r[9:5]),
        .c       (outs_r[14:10]),
        .y       (voted_outs),
        .err     (),
        .mismatch(outs_mismatch)
    );

    assign {err, done, data_en, addr_en, req} = voted_outs;
    assign state          = voted_state;
    assign fault_detected = state_mismatch | outs_mismatch;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            corrected_count    <= 16'd0;
            replica_err_count0 <= 16'd0;
            replica_err_count1 <= 16'd0;
            replica_err_count2 <= 16'd0;
        end else begin
            if (fault_detected && corrected_count != 16'hFFFF)
                corrected_count <= corrected_count + 1'b1;
            if (outvoted[0] && replica_err_count0 != 16'hFFFF)
                replica_err_count0 <= replica_err_count0 + 1'b1;
            if (outvoted[1] && replica_err_count1 != 16'hFFFF)
                replica_err_count1 <= replica_err_count1 + 1'b1;
            if (outvoted[2] && replica_err_count2 != 16'hFFFF)
                replica_err_count2 <= replica_err_count2 + 1'b1;
        end
    end
endmodule
