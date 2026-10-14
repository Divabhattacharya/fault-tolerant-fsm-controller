`timescale 1ns/1ps
// Production configuration of the TMR controller: upset injection tied off.
// Used by `make synth` to confirm synthesis keeps all three replicas.
module tmr_fsm_prod (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire        grant,
    input  wire        ack,
    input  wire        abort,
    output wire        req,
    output wire        addr_en,
    output wire        data_en,
    output wire        done,
    output wire        err,
    output wire        fault_detected,
    output wire [15:0] corrected_count
);
    tmr_fsm_controller u_ctrl (
        .clk               (clk),
        .rst_n             (rst_n),
        .start             (start),
        .grant             (grant),
        .ack               (ack),
        .abort             (abort),
        .seu_mask          (9'd0),
        .req               (req),
        .addr_en           (addr_en),
        .data_en           (data_en),
        .done              (done),
        .err               (err),
        .state             (),
        .fault_detected    (fault_detected),
        .corrected_count   (corrected_count),
        .replica_err_count0(),
        .replica_err_count1(),
        .replica_err_count2()
    );
endmodule
