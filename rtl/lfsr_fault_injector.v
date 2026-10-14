`timescale 1ns/1ps
// LFSR-driven single-event-upset injector.
//
// A 16-bit maximal-length Fibonacci LFSR (x^16 + x^14 + x^13 + x^11 + 1,
// period 65535) advances every cycle. When enabled, a fault fires on cycles
// where the low `rate` LFSR bits are all zero, i.e. with probability 2^-rate
// (rate = 0 fires every cycle, rate >= 8 means 1/256). Two other LFSR bit
// fields choose the target replica and the state bit, so each fault flips
// exactly one state bit of one replica.
module lfsr_fault_injector #(
    parameter        SW   = 3,              // state bits per replica
    parameter [15:0] SEED = 16'hACE1
) (
    input  wire            clk,
    input  wire            rst_n,
    input  wire            enable,
    input  wire [3:0]      rate,
    output wire [3*SW-1:0] seu_mask,        // {r2, r1, r0}
    output reg  [15:0]     inject_count     // faults fired (saturating)
);
    // all-zero is the LFSR lock-up state, never use it as the seed
    localparam [15:0]   SEED_NZ = (SEED == 16'd0) ? 16'h0001 : SEED;
    localparam          BW      = (SW > 1) ? $clog2(SW) : 1;
    localparam [SW-1:0] ONE     = 1;

    reg  [15:0]   lfsr_q;
    wire          feedback   = lfsr_q[15] ^ lfsr_q[13] ^ lfsr_q[12] ^ lfsr_q[10];

    wire [7:0]    rate_mask  = (rate >= 4'd8) ? 8'hFF : ((8'd1 << rate) - 8'd1);
    wire          fire       = enable && ((lfsr_q[7:0] & rate_mask) == 8'd0);
    wire [1:0]    rep_sel    = lfsr_q[11:8] % 3;
    wire [BW-1:0] bit_sel    = lfsr_q[15:12] % SW;
    wire [SW-1:0] bit_onehot = ONE << bit_sel;

    assign seu_mask = fire ? { (rep_sel == 2'd2) ? bit_onehot : {SW{1'b0}},
                               (rep_sel == 2'd1) ? bit_onehot : {SW{1'b0}},
                               (rep_sel == 2'd0) ? bit_onehot : {SW{1'b0}} }
                           : {(3*SW){1'b0}};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr_q       <= SEED_NZ;
            inject_count <= 16'd0;
        end else begin
            lfsr_q <= {lfsr_q[14:0], feedback};
            if (fire && inject_count != 16'hFFFF)
                inject_count <= inject_count + 1'b1;
        end
    end
endmodule
