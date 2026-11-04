`timescale 1ns / 1ps
// DVI TMDS 8b/10b encoder. The output is registered (one pixel-cycle latency).
// A separate instance is needed for each RGB color channel.
module dvi_encoder (
    input  wire       pixel_clk,
    input  wire       reset,
    input  wire [7:0] din,
    input  wire       c0,
    input  wire       c1,
    input  wire       de,
    output reg  [9:0] dout
);
    function [3:0] count_ones;
        input [7:0] d;
        integer k;
        begin
            count_ones = 4'd0;
            for (k = 0; k < 8; k = k + 1)
                count_ones = count_ones + d[k];
        end
    endfunction

    reg [8:0] q_m;
    reg [9:0] next_symbol;
    reg signed [7:0] running_disparity;
    reg signed [7:0] next_disparity;
    reg signed [7:0] balance;
    reg [3:0] num_ones;
    reg [3:0] num_zeros;
    reg xnor_mode;
    integer i;

    always @(*) begin
        xnor_mode = (count_ones(din) > 4) ||
                    ((count_ones(din) == 4) && (din[0] == 1'b0));
        q_m[0] = din[0];
        q_m[8] = ~xnor_mode;
        for (i = 1; i < 8; i = i + 1) begin
            if (xnor_mode)
                q_m[i] = ~(q_m[i-1] ^ din[i]);
            else
                q_m[i] = q_m[i-1] ^ din[i];
        end

        num_ones  = count_ones(q_m[7:0]);
        num_zeros = 4'd8 - num_ones;
        balance   = $signed({1'b0, num_ones}) - $signed({1'b0, num_zeros});

        next_symbol    = 10'b1101010100;
        next_disparity = 8'sd0;
        if (!de) begin
            case ({c1,c0})
                2'b00: next_symbol = 10'b1101010100;
                2'b01: next_symbol = 10'b0010101011;
                2'b10: next_symbol = 10'b0101010100;
                2'b11: next_symbol = 10'b1010101011;
            endcase
            next_disparity = 8'sd0;
        end else if (running_disparity == 0 || num_ones == num_zeros) begin
            next_symbol    = {~q_m[8], q_m[8], q_m[8] ? q_m[7:0] : ~q_m[7:0]};
            next_disparity = running_disparity + (q_m[8] ? balance : -balance);
        end else if ((running_disparity > 0 && num_ones > num_zeros) ||
                     (running_disparity < 0 && num_ones < num_zeros)) begin
            next_symbol    = {1'b1, q_m[8], ~q_m[7:0]};
            next_disparity = running_disparity + (q_m[8] ? 8'sd2 : 8'sd0) - balance;
        end else begin
            next_symbol    = {1'b0, q_m[8], q_m[7:0]};
            next_disparity = running_disparity - (q_m[8] ? 8'sd0 : 8'sd2) + balance;
        end
    end

    always @(posedge pixel_clk) begin
        if (reset) begin
            dout              <= 10'b1101010100;
            running_disparity <= 8'sd0;
        end else begin
            dout              <= next_symbol;
            running_disparity <= next_disparity;
        end
    end
endmodule
