`timescale 1ns/1ps
// AIPKG3 scalar elementwise backend. One transaction is outstanding.
// req_op uses the profile-2 opcode for QUANT/ADD/MUL/SIGMOID/EXP/RELU;
// Arithmetic uses the shared checked npu_wide_math service; its default
// selects pipelined partial products while retaining the exact integer ABI.
// LUT data comes from the exact model CONSTANTS section: table[index] and
// table[index+1]. The provider must retain its response until accepted.
module npu_q16_elementwise #(
    parameter bit EXTERNAL_MATH = 1'b0
) (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               req_valid,
    output logic               req_ready,
    input  logic [4:0]         req_op,
    input  logic signed [63:0] req_a,
    input  logic signed [63:0] req_b,
    input  logic [6:0]         req_shift,
    input  logic               req_quant_a16,
    input  logic               req_output_i64,
    output logic               rsp_valid,
    input  logic               rsp_ready,
    output logic signed [63:0] rsp_result,
    output logic [1:0]         rsp_fault,
    output logic               lut_req_valid,
    input  logic               lut_req_ready,
    output logic [1:0]         lut_req_kind,
    output logic [12:0]        lut_req_index,
    input  logic               lut_rsp_valid,
    output logic               lut_rsp_ready,
    input  logic signed [63:0] lut_rsp_y0,
    input  logic signed [63:0] lut_rsp_y1,
    output logic               math_req_valid,
    input  logic               math_req_ready,
    output logic [2:0]         math_req_op,
    output logic signed [63:0] math_req_a,
    output logic signed [63:0] math_req_b,
    output logic [6:0]         math_req_shift,
    input  logic               math_rsp_valid,
    output logic               math_rsp_ready,
    input  logic signed [63:0] math_rsp_result,
    input  logic [1:0]         math_rsp_fault
);
    localparam logic [4:0] OP_QUANT=1, OP_ADD=4, OP_MUL=5,
        OP_SIGMOID=9, OP_EXP=10, OP_RELU=11;
    localparam logic [1:0] LUT_SIGMOID=0, LUT_EXP=1;
    typedef enum logic [2:0] {IDLE, LUT_REQUEST, LUT_WAIT, LUT_CHECK,
        MATH_REQUEST, MATH_WAIT, RESPONSE} state_t;
    state_t state;
    logic [4:0] op;
    logic output_i64, quant_a16, product_checked;
    logic [8:0] fraction;
    logic signed [63:0] lut_base;
    logic [2:0] math_op;
    logic signed [63:0] math_a, math_b;
    logic [6:0] math_shift;
    logic math_ready, math_valid;
    logic signed [63:0] math_result;
    logic [1:0] math_fault;
    logic signed [21:0] clipped;
    logic [21:0] position;
    logic [12:0] index_next;
    logic [8:0] fraction_next;
    logic signed [64:0] lut_delta, interpolation;
    logic signed [64:0] lut_delta_q;
    logic signed [63:0] finished;
    logic finish_overflow;

    npu_math_port #(.EXTERNAL_MATH(EXTERNAL_MATH)) arithmetic (
        .clk(clk), .rst_n(rst_n),
        .req_valid(state==MATH_REQUEST), .req_ready(math_ready),
        .req_op(math_op), .req_a(math_a), .req_b(math_b),
        .req_shift(math_shift), .rsp_valid(math_valid),
        .rsp_ready(state==MATH_WAIT), .rsp_result(math_result),.rsp_fault(math_fault),
        .math_req_valid(math_req_valid),.math_req_ready(math_req_ready),
        .math_req_op(math_req_op),.math_req_a(math_req_a),.math_req_b(math_req_b),
        .math_req_shift(math_req_shift),.math_rsp_valid(math_rsp_valid),.math_rsp_ready(math_rsp_ready),
        .math_rsp_result(math_rsp_result),.math_rsp_fault(math_rsp_fault)
    );

    always_comb begin
        req_ready = state==IDLE;
        rsp_valid = state==RESPONSE;
        lut_req_valid = state==LUT_REQUEST;
        lut_rsp_ready = state==LUT_WAIT;

        // Table endpoints use the penultimate index and fraction=256,
        // exactly matching Runtime.lut() rather than reading past the table.
        if (req_a < -64'sd1048576) clipped = -22'sd1048576;
        else if (req_a > 64'sd1048576) clipped = 22'sd1048576;
        else clipped = req_a[21:0];
        position = $unsigned(clipped+22'sd1048576);
        if (position>=22'd2097152) index_next = 13'd8191;
        else index_next = position[20:8];
        fraction_next = position - ({51'd0,index_next}<<8);

        lut_delta = {lut_rsp_y1[63],lut_rsp_y1} -
                    {lut_rsp_y0[63],lut_rsp_y0};
        interpolation = {lut_base[63],lut_base} +
                        {math_result[63],math_result};
        if (op==OP_SIGMOID || op==OP_EXP) begin
            finished = interpolation[63:0];
            finish_overflow = interpolation[64]!=interpolation[63];
        end else begin
            finished = math_result;
            finish_overflow = 1'b0;
        end
        if (!output_i64 && finished[63:31]!={33{finished[31]}})
            finish_overflow = 1'b1;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            rsp_result <= '0;
            rsp_fault <= '0;
            op <= '0;
            output_i64 <= 1'b0;
            quant_a16 <= 1'b0;
            product_checked <= 1'b0;
            fraction <= '0;
            lut_base <= '0;
            lut_req_kind <= '0;
            lut_req_index <= '0;
            math_op <= '0;
            math_a <= '0;
            math_b <= '0;
            math_shift <= '0;
        end else begin
            case (state)
                IDLE: if (req_valid) begin
                    op <= req_op;
                    output_i64 <= req_output_i64;
                    quant_a16 <= req_quant_a16;
                    product_checked <= 1'b0;
                    rsp_result <= '0;
                    rsp_fault <= '0;
                    math_a <= req_a;
                    math_b <= req_b;
                    math_shift <= req_shift;
                    case (req_op)
                        OP_QUANT: begin
                            // Frozen Q31 factors and the reference's checked
                            // INT32 requant input; INT32_MIN is excluded by
                            // the reference abs(x)<=2147483647 assertion.
                            if (req_a < -64'sd2147483647 ||
                                req_a > 64'sd2147483647 || req_b<=0 ||
                                req_b > 64'sd2147483647 || req_shift>62) begin
                                rsp_fault <= 2'd1;
                                state <= RESPONSE;
                            end else begin
                                math_op <= 3'd1;
                                state <= MATH_REQUEST;
                            end
                        end
                        OP_ADD: begin
                            math_op <= 3'd0;
                            state <= MATH_REQUEST;
                        end
                        OP_MUL: begin
                            math_op <= 3'd1;
                            // The frozen runtime uses a signed INT64 product.
                            // Check that product before applying the Q16 shift.
                            math_shift <= 7'd0;
                            state <= MATH_REQUEST;
                        end
                        OP_RELU: begin
                            if (req_a>64'sd2147483647 && !req_output_i64)
                                rsp_fault <= 2'd2;
                            else rsp_result <= req_a<0 ? 64'sd0 : req_a;
                            state <= RESPONSE;
                        end
                        OP_SIGMOID, OP_EXP: begin
                            lut_req_kind <= req_op==OP_SIGMOID ? LUT_SIGMOID : LUT_EXP;
                            lut_req_index <= index_next;
                            fraction <= fraction_next;
                            state <= LUT_REQUEST;
                        end
                        default: begin
                            rsp_fault <= 2'd1;
                            state <= RESPONSE;
                        end
                    endcase
                end
                LUT_REQUEST: if (lut_req_ready) state <= LUT_WAIT;
                LUT_WAIT: if (lut_rsp_valid) begin
                    lut_delta_q <= lut_delta;
                    lut_base <= lut_rsp_y0;
                    state <= LUT_CHECK;
                end
                LUT_CHECK: begin
                    if (lut_delta_q[64]!=lut_delta_q[63]) begin
                        rsp_fault <= 2'd2;
                        state <= RESPONSE;
                    end else begin
                        math_a <= lut_delta_q[63:0];
                        math_b <= $signed({55'd0,fraction});
                        math_shift <= 7'd0;
                        math_op <= 3'd1;
                        state <= MATH_REQUEST;
                    end
                end
                MATH_REQUEST: if (math_ready) state <= MATH_WAIT;
                MATH_WAIT: if (math_valid) begin
                    state <= RESPONSE;
                    if (math_fault!=0) rsp_fault <= math_fault;
                    else if (!product_checked && (op==OP_MUL || op==OP_SIGMOID ||
                             op==OP_EXP)) begin
                        product_checked <= 1'b1;
                        math_a <= math_result;
                        math_b <= '0;
                        math_op <= 3'd2;
                        math_shift <= op==OP_MUL ? 7'd16 : 7'd8;
                        state <= MATH_REQUEST;
                    end
                    else if (op==OP_QUANT) begin
                        if (quant_a16) begin
                            if (math_result>64'sd32767) rsp_result <= 64'sd32767;
                            else if (math_result < -64'sd32767) rsp_result <= -64'sd32767;
                            else rsp_result <= math_result;
                        end else begin
                            if (math_result>64'sd127) rsp_result <= 64'sd127;
                            else if (math_result < -64'sd127) rsp_result <= -64'sd127;
                            else rsp_result <= math_result;
                        end
                    end else if (finish_overflow) rsp_fault <= 2'd2;
                    else rsp_result <= finished;
                end
                RESPONSE: if (rsp_ready) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
