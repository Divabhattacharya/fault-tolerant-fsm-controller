`timescale 1ns/1ps
// System top: TMR controller plus the on-chip LFSR fault injector.
// ext_seu_mask is a test-access port for directed upsets; it is OR-ed with
// the injector's mask. Tie inj_enable and ext_seu_mask low in normal use.
module ft_fsm_top #(
    parameter [15:0] SEED = 16'hACE1
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire        grant,
    input  wire        ack,
    input  wire        abort,
    input  wire        inj_enable,
    input  wire [3:0]  inj_rate,
    input  wire [8:0]  ext_seu_mask,
    output wire        req,
    output wire        addr_en,
    output wire        data_en,
    output wire        done,
    output wire        err,
    output wire [2:0]  state,
    output wire        fault_detected,
    output wire [15:0] corrected_count,
    output wire [15:0] replica_err_count0,
    output wire [15:0] replica_err_count1,
    output wire [15:0] replica_err_count2,
    output wire [15:0] inject_count
);
    wire [8:0] lfsr_mask;
    wire [8:0] seu_mask = lfsr_mask | ext_seu_mask;

    lfsr_fault_injector #(.SW(3), .SEED(SEED)) u_inj (
        .clk         (clk),
        .rst_n       (rst_n),
        .enable      (inj_enable),
        .rate        (inj_rate),
        .seu_mask    (lfsr_mask),
        .inject_count(inject_count)
    );

    tmr_fsm_controller u_ctrl (
        .clk               (clk),
        .rst_n             (rst_n),
        .start             (start),
        .grant             (grant),
        .ack               (ack),
        .abort             (abort),
        .seu_mask          (seu_mask),
        .req               (req),
        .addr_en           (addr_en),
        .data_en           (data_en),
        .done              (done),
        .err               (err),
        .state             (state),
        .fault_detected    (fault_detected),
        .corrected_count   (corrected_count),
        .replica_err_count0(replica_err_count0),
        .replica_err_count1(replica_err_count1),
        .replica_err_count2(replica_err_count2)
    );
endmodule
