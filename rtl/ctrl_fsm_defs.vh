// State encoding of the protected bus-transaction controller (3 bits).
// Codes 3'b110 and 3'b111 are unused; the FSM falls back to IDLE from them.
localparam [2:0] S_IDLE     = 3'd0,
                 S_REQUEST  = 3'd1,
                 S_ADDRESS  = 3'd2,
                 S_DATA     = 3'd3,
                 S_COMPLETE = 3'd4,
                 S_ERROR    = 3'd5;
