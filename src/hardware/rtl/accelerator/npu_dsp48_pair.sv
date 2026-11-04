`timescale 1ns/1ps
// One DSP48E1, two signed INT8 weights, one shared activation byte.
// x accepts signed INT8 (-128..127) or unsigned low byte (0..255).
// Both products fit signed 16 bits. CORRECT_HIGH=0 leaves the upper product
// one below its true value when p0 is negative; the array folds that correction
// into its reduction tree instead of duplicating a 16-bit increment per DSP.
// Input accepted at E; out_valid/products update at E+2. No backpressure.
module npu_dsp48_pair #(
    parameter bit CORRECT_HIGH = 1'b1
) (
    input  logic clk,
    input  logic rst_n,
    input  logic in_valid,
    input  logic weight_load,
    input  logic signed [8:0] x,
    input  logic signed [7:0] w0,
    input  logic signed [7:0] w1,
    output logic out_valid,
    output logic signed [15:0] p0,
    output logic signed [15:0] p1
);
    logic signed [23:0] a_reg,d_reg;
    logic signed [17:0] b_reg;
    (* use_dsp = "yes" *) logic signed [47:0] packed_product;
    logic [2:0] valid_pipe;
    // Two signed 24-bit operands and a 25-bit result express the native
    // pre-adder width. In particular (-128<<16)+negative w0 needs bit 24.
    wire signed [24:0] preadded = $signed({a_reg[23],a_reg}) +
                                 $signed({d_reg[23],d_reg});

    // Data registers deliberately have no reset, allowing DSP register packing.
    // Output values are meaningful only when out_valid is asserted.
    always_ff @(posedge clk) begin
        // Repeated activation phases may retain the last accepted weight pair.
        if (in_valid && weight_load) begin
            a_reg <= {{16{w0[7]}},w0};
            d_reg <= {w1,16'd0};
        end
        if (in_valid) b_reg <= {{9{x[8]}},x};
        if (valid_pipe[0]) packed_product <= preadded * b_reg;
        if (valid_pipe[1]) begin
            p0 <= $signed(packed_product[15:0]);
            if(CORRECT_HIGH)
                p1 <= $signed(packed_product[31:16]) +
                      (packed_product[15] ? 16'sd1 : 16'sd0);
            else p1 <= $signed(packed_product[31:16]);
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) valid_pipe <= '0;
        else valid_pipe <= {valid_pipe[1:0],in_valid};
    end
    assign out_valid = valid_pipe[2];
endmodule
