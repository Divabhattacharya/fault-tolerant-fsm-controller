`timescale 1ns/1ps
// Bitwise 2-of-3 majority voter with disagreement detection.
module tmr_voter #(
    parameter W = 1
) (
    input  wire [W-1:0] a,
    input  wire [W-1:0] b,
    input  wire [W-1:0] c,
    output wire [W-1:0] y,          // majority value
    output wire [2:0]   err,        // err[i] = 1: input i was outvoted
    output wire         mismatch    // any input disagrees
);
    assign y        = (a & b) | (b & c) | (a & c);
    assign err      = { c != y, b != y, a != y };
    assign mismatch = |err;
endmodule
