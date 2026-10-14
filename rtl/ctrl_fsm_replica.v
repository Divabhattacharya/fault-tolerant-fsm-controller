`timescale 1ns/1ps
// One copy of the protected control FSM: a bus-transaction sequencer.
//
//   IDLE     --start-->  REQUEST   (req=1, wait for grant; abort -> ERROR)
//   REQUEST  --grant-->  ADDRESS   (addr_en=1 for one cycle)
//   ADDRESS  ------->    DATA      (data_en=1, wait for ack; abort -> ERROR)
//   DATA     --ack--->   COMPLETE  (done=1 for one cycle)  -> IDLE
//   ERROR    (err=1 for one cycle) -> IDLE
//
// The next state is computed from the *voted* state rather than this
// replica's own register. A replica whose register was upset is therefore
// rewritten with the correct next state on the following clock edge
// (TMR with voter feedback).
//
// Outputs are Moore-decoded from this replica's own register and are voted
// at the top level, so the output decoder is triplicated as well.
//
// seu_mask models a single-event upset: every bit set in it is flipped in the
// value the state register captures. Tie it to zero in a production build.
//
// keep_hierarchy / dont_touch: with seu_mask tied to zero the three replicas
// are logically identical, and a flattening synthesis run would merge them
// into one register, silently removing the redundancy. Keeping each replica
// as its own hierarchy block prevents that.
(* keep_hierarchy = "yes", dont_touch = "true" *)
module ctrl_fsm_replica (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [2:0] voted_state,
    input  wire       start,
    input  wire       grant,
    input  wire       ack,
    input  wire       abort,
    input  wire [2:0] seu_mask,
    output reg  [2:0] state_q,
    output wire [4:0] outs              // {err, done, data_en, addr_en, req}
);
    `include "ctrl_fsm_defs.vh"

    reg [2:0] next_state;

    always @* begin
        case (voted_state)
            S_IDLE:     next_state = start ? S_REQUEST : S_IDLE;
            S_REQUEST:  next_state = abort ? S_ERROR : (grant ? S_ADDRESS : S_REQUEST);
            S_ADDRESS:  next_state = S_DATA;
            S_DATA:     next_state = abort ? S_ERROR : (ack ? S_COMPLETE : S_DATA);
            S_COMPLETE: next_state = S_IDLE;
            S_ERROR:    next_state = S_IDLE;
            default:    next_state = S_IDLE;    // illegal codes recover to IDLE
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state_q <= S_IDLE;
        else
            state_q <= next_state ^ seu_mask;
    end

    assign outs = { state_q == S_ERROR,
                    state_q == S_COMPLETE,
                    state_q == S_DATA,
                    state_q == S_ADDRESS,
                    state_q == S_REQUEST };
endmodule
