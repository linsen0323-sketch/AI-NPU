`timescale 1ns/1ps

// Source-only strided scalar wrapper for the existing fixed Q16 helper.
// Descriptor capacities/ownership are checked by the caller. This module
// checks command geometry and waits for every scalar write response.
(* use_dsp = "no" *)
module npu_q16_scalar_engine #(
    parameter bit EXTERNAL_MATH = 1'b0,
    parameter bit EXTERNAL_RESNET_QUANT = 1'b0,
    parameter bit STREAMING = 1'b0,
    parameter bit EXTERNAL_FUSION = 1'b0,
    parameter bit BITWISE_RESULT_RANGE = 1'b0
) (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               cmd_valid,
    output logic               cmd_ready,
    input  logic [31:0]        cmd_tag,
    input  logic [4:0]         cmd_op,
    input  logic [31:0]        cmd_count,
    input  logic [31:0]        cmd_input_a,
    input  logic [31:0]        cmd_input_b,
    input  logic [31:0]        cmd_output_base,
    input  logic [31:0]        cmd_stride_a,
    input  logic [31:0]        cmd_stride_b,
    input  logic [31:0]        cmd_stride_output,
    input  logic [2:0]         cmd_dtype_a,
    input  logic [2:0]         cmd_dtype_b,
    input  logic [2:0]         cmd_dtype_output,
    input  logic signed [63:0] cmd_multiplier,
    input  logic [6:0]         cmd_shift,
    // NPUPLN1 word2 bit0 selects the frozen profile-1 ResNet semantics.
    // ADD becomes a*ma+b*mb followed by ONE signed-shift RNE/saturation.
    // Other legacy scalar commands are INT8 RELU; Q16 commands are unchanged.
    input  logic               cmd_resnet_legacy,
    input  logic signed [63:0] cmd_multiplier_b,
    input  logic signed [7:0]  cmd_resnet_shift,

    output logic               mem_req_valid,
    input  logic               mem_req_ready,
    output logic               mem_req_write,
    output logic [31:0]        mem_req_addr,
    output logic [1:0]         mem_req_size,
    output logic [63:0]        mem_req_wdata,
    input  logic               mem_rsp_valid,
    output logic               mem_rsp_ready,
    input  logic signed [63:0] mem_rsp_rdata,
    input  logic [3:0]         mem_rsp_fault,

    output logic               lut_req_valid,
    input  logic               lut_req_ready,
    output logic [1:0]         lut_req_kind,
    output logic [12:0]        lut_req_index,
    input  logic               lut_rsp_valid,
    output logic               lut_rsp_ready,
    input  logic signed [63:0] lut_rsp_y0,
    input  logic signed [63:0] lut_rsp_y1,
    input  logic [3:0]         lut_rsp_fault,

    output logic               rsp_valid,
    input  logic               rsp_ready,
    output logic [31:0]        rsp_tag,
    output logic [7:0]         rsp_fault,
    output logic [31:0]        rsp_completed,
    output logic               busy,
    output logic math_req_valid,input logic math_req_ready,
    output logic [2:0] math_req_op,output logic signed [63:0] math_req_a,math_req_b,
    output logic [6:0] math_req_shift,input logic math_rsp_valid,output logic math_rsp_ready,
    input logic signed [63:0] math_rsp_result,input logic [1:0] math_rsp_fault,
    output logic quant_req_valid,input logic quant_req_ready,
    output logic quant_req_residual,output logic signed [39:0] quant_req_value,
    output logic signed [63:0] quant_req_multiplier_a,quant_req_multiplier_b,
    output logic signed [7:0] quant_req_b,quant_req_shift,
    input logic quant_rsp_valid,output logic quant_rsp_ready,
    input logic signed [7:0] quant_rsp_result,
    output wire rd_cmd_valid,input wire rd_cmd_ready,output wire [31:0] rd_cmd_addr,rd_cmd_bytes,
    input wire rd_valid,output wire rd_ready,input wire [63:0] rd_data,input wire [7:0] rd_keep,input wire rd_last,
    input wire rd_rsp_valid,output wire rd_rsp_ready,input wire [3:0] rd_fault,
    output wire wr_cmd_valid,input wire wr_cmd_ready,output wire [31:0] wr_cmd_addr,wr_cmd_bytes,
    output wire wr_valid,input wire wr_ready,output wire [63:0] wr_data,output wire [7:0] wr_keep,output wire wr_last,
    input wire wr_rsp_valid,output wire wr_rsp_ready,input wire [3:0] wr_fault,
    input wire stream_lut_available,
    output wire stream_lut_req_valid,input wire stream_lut_req_ready,
    output wire [1:0] stream_lut_req_kind,output wire [12:0] stream_lut_req_index,
    input wire stream_lut_rsp_valid,output wire stream_lut_rsp_ready,
    input wire signed [63:0] stream_lut_y0,stream_lut_y1,input wire [3:0] stream_lut_fault,
    input wire fusion_active,fusion_valid,output wire fusion_ready,
    input wire [4:0] fusion_op,input wire [2:0] fusion_dtype,
    input wire signed [63:0] fusion_multiplier,input wire [6:0] fusion_shift,
    input wire signed [31:0] fusion_data,input wire [9:0] fusion_tag,
    output wire fusion_rsp_valid,output wire [31:0] fusion_result,
    output wire [9:0] fusion_rsp_tag,output wire [7:0] fusion_fault
);
    localparam logic [4:0] OP_QUANT=1, OP_ADD=4, OP_MUL=5,
        OP_SIGMOID=9, OP_EXP=10, OP_RELU=11, OP_SILU=22, OP_SILU_QUANT=23;
    localparam logic [2:0] I8=1, I16=2, I32=3, I64=4;
    localparam logic [7:0] F_COMMAND=8'h01, F_DTYPE=8'h02,
        F_ADDRESS=8'h03, F_ARITHMETIC=8'h04, F_DOMAIN=8'h05,
        F_OVERLAP=8'h08;

    typedef enum logic [4:0] {
        IDLE, CHECK_COMMAND, SPAN_REQUEST, SPAN_WAIT,
        RANGE_A_DONE, RANGE_B_DONE, RANGE_OUTPUT_DONE, RANGE_COMMIT,
        CHECK_OVERLAP, OVERLAP_COMMIT,
        READ_A_SEND, READ_A_WAIT, READ_B_SEND, READ_B_WAIT,
        HELPER_SEND, HELPER_WAIT, WRITE_SEND, WRITE_WAIT, RESPONSE, VECTOR_SEND, VECTOR_WAIT
    } state_t;
    state_t state, span_return;
    logic [4:0] op_q;
    logic [31:0] count_q, base_a_q, base_b_q, base_output_q;
    logic [31:0] stride_a_q, stride_b_q, stride_output_q;
    logic [2:0] dtype_a_q, dtype_b_q, dtype_output_q;
    logic signed [63:0] multiplier_q;
    logic signed [63:0] multiplier_b_q;
    logic signed [7:0] resnet_shift_q;
    logic resnet_legacy_q, resnet_residual;
    logic resnet_quant_ready,resnet_quant_valid;
    logic signed [7:0] resnet_quant_result;
    logic [6:0] shift_q;
    logic [31:0] index_q, pointer_a_q, pointer_b_q, pointer_output_q;
    logic [32:0] end_a_q, end_b_q, end_output_q;
    logic signed [63:0] value_a_q, value_b_q, write_value_q;

    logic [31:0] span_stride_q;
    logic signed [63:0] span_q, span_result;
    logic span_ready, span_valid;
    logic [1:0] span_fault;
    // Command preflight owns one shared endpoint datapath. Payload registers
    // need no reset: each is written in the preceding stage before use, and
    // reset returns to IDLE without exposing a memory request.
    logic [1:0] range_target_q;
    logic [31:0] range_base_q;
    logic [3:0] range_bytes_q;
    logic [32:0] range_base_end_q;
    logic [64:0] range_end_q;
    logic range_bad, overlap_bad_q;

    logic helper_ready, helper_valid;
    logic [1:0] fused_phase;
    logic [4:0] helper_op;
    logic fused_silu, fused_quant, helper_output_i64, quant_result_stage;
    logic signed [63:0] helper_a;
    logic signed [63:0] helper_b, helper_result;
    logic [1:0] helper_fault;
    logic helper_lut_req_valid, helper_lut_rsp_ready;
    logic [3:0] saved_lut_fault;
    logic [3:0] bytes_a, bytes_b, bytes_output;
    logic [1:0] size_a, size_b, size_output;
    logic uses_b, known_op, supported_output, result_in_range;
    logic overlap_a, overlap_b, inplace_a, inplace_b;
    logic [31:0] final_index;
    logic helper_math_req_valid,helper_math_req_ready,helper_math_rsp_ready;
    logic [2:0] helper_math_op;
    logic signed [63:0] helper_math_a,helper_math_b;
    logic [6:0] helper_math_shift;
    logic service_ready,service_valid;
    logic signed [63:0] service_result;
    logic [1:0] service_fault;
    wire vector_ready,vector_valid;
    wire [7:0] vector_fault;
    wire [31:0] vector_completed;
    wire vector_eligible=STREAMING && base_a_q[2:0]==0 && base_output_q[2:0]==0 &&
        (stride_a_q==0 || stride_a_q=={28'd0,bytes_a}) && stride_output_q=={28'd0,bytes_output} &&
        (dtype_a_q==I32 || (resnet_legacy_q && dtype_a_q==I8)) &&
        (!uses_b || (base_b_q[2:0]==0 && (stride_b_q==0 || stride_b_q=={28'd0,bytes_b}) &&
                    (dtype_b_q==I32 || (resnet_legacy_q && dtype_b_q==I8)))) &&
        (!(fused_silu || op_q==OP_SIGMOID || op_q==OP_EXP) || stream_lut_available);
    generate if(STREAMING) begin:g_vector
        npu_q16_vector_engine #(.EXTERNAL_FUSION(EXTERNAL_FUSION)) u_vector (
            .fusion_active(fusion_active),.fusion_valid(fusion_valid),.fusion_ready(fusion_ready),
            .fusion_op(fusion_op),.fusion_dtype(fusion_dtype),.fusion_multiplier(fusion_multiplier),.fusion_shift(fusion_shift),
            .fusion_data(fusion_data),.fusion_tag(fusion_tag),.fusion_rsp_valid(fusion_rsp_valid),.fusion_result(fusion_result),
            .fusion_rsp_tag(fusion_rsp_tag),.fusion_fault(fusion_fault),
            .clk(clk),.rst_n(rst_n),.cmd_valid(state==VECTOR_SEND),.cmd_ready(vector_ready),
            .op(op_q),.count(count_q),.base_a(base_a_q),.base_b(base_b_q),.base_y(base_output_q),
            .stride_a(stride_a_q),.stride_b(stride_b_q),.dtype_a(dtype_a_q),.dtype_b(dtype_b_q),.dtype_y(dtype_output_q),
            .legacy(resnet_legacy_q),.multiplier(multiplier_q),.multiplier_b(multiplier_b_q),.shift(shift_q),.legacy_shift(resnet_shift_q),
            .rsp_valid(vector_valid),.rsp_ready(state==VECTOR_WAIT),.rsp_fault(vector_fault),.rsp_completed(vector_completed),
            .rd_cmd_valid(rd_cmd_valid),.rd_cmd_ready(rd_cmd_ready),.rd_cmd_addr(rd_cmd_addr),.rd_cmd_bytes(rd_cmd_bytes),
            .rd_valid(rd_valid),.rd_ready(rd_ready),.rd_data(rd_data),.rd_keep(rd_keep),.rd_last(rd_last),
            .rd_rsp_valid(rd_rsp_valid),.rd_rsp_ready(rd_rsp_ready),.rd_fault(rd_fault),
            .wr_cmd_valid(wr_cmd_valid),.wr_cmd_ready(wr_cmd_ready),.wr_cmd_addr(wr_cmd_addr),.wr_cmd_bytes(wr_cmd_bytes),
            .wr_valid(wr_valid),.wr_ready(wr_ready),.wr_data(wr_data),.wr_keep(wr_keep),.wr_last(wr_last),
            .wr_rsp_valid(wr_rsp_valid),.wr_rsp_ready(wr_rsp_ready),.wr_fault(wr_fault),
            .lut_req_valid(stream_lut_req_valid),.lut_req_ready(stream_lut_req_ready),.lut_req_kind(stream_lut_req_kind),.lut_req_index(stream_lut_req_index),
            .lut_rsp_valid(stream_lut_rsp_valid),.lut_rsp_ready(stream_lut_rsp_ready),.lut_y0(stream_lut_y0),.lut_y1(stream_lut_y1),.lut_fault(stream_lut_fault));
    end else begin:g_no_vector
        assign vector_ready=0;assign vector_valid=0;assign vector_fault=0;assign vector_completed=0;
        assign rd_cmd_valid=0;assign rd_cmd_addr=0;assign rd_cmd_bytes=0;assign rd_ready=0;assign rd_rsp_ready=0;
        assign wr_cmd_valid=0;assign wr_cmd_addr=0;assign wr_cmd_bytes=0;assign wr_valid=0;
        assign wr_data=0;assign wr_keep=0;assign wr_last=0;assign wr_rsp_ready=0;
        assign stream_lut_req_valid=0;assign stream_lut_req_kind=0;assign stream_lut_req_index=0;assign stream_lut_rsp_ready=0;
        assign fusion_ready=0;assign fusion_rsp_valid=0;assign fusion_result=0;assign fusion_rsp_tag=0;assign fusion_fault=0;
    end endgenerate

    function automatic logic [3:0] dtype_bytes(input logic [2:0] dtype);
        case (dtype)
            I8: dtype_bytes=4'd1;
            I16: dtype_bytes=4'd2;
            I32: dtype_bytes=4'd4;
            I64: dtype_bytes=4'd8;
            default: dtype_bytes=4'd0;
        endcase
    endfunction

    function automatic logic [1:0] dtype_size(input logic [2:0] dtype);
        case (dtype)
            I8: dtype_size=2'd0;
            I16: dtype_size=2'd1;
            I64: dtype_size=2'd3;
            default: dtype_size=2'd2;
        endcase
    endfunction

    function automatic logic aligned(
        input logic [31:0] address,
        input logic [2:0] dtype
    );
        case (dtype)
            I8: aligned=1'b1;
            I16: aligned=!address[0];
            I32: aligned=!(|address[1:0]);
            I64: aligned=!(|address[2:0]);
            default: aligned=1'b0;
        endcase
    endfunction

    task automatic fail(input logic [7:0] code);
        begin
            rsp_fault <= code;
            state <= RESPONSE;
        end
    endtask

    task automatic start_span(
        input logic [31:0] stride,
        input state_t return_state
    );
        begin
            span_stride_q <= stride;
            span_return <= return_state;
            // Capture only the operand selection here. The short base+bytes
            // addition is registered in SPAN_REQUEST while the independent
            // span multiplication starts/waits, without adding startup states.
            case (return_state)
                RANGE_A_DONE: begin
                    range_target_q <= 2'd0;
                    range_base_q <= base_a_q;
                    range_bytes_q <= bytes_a;
                end
                RANGE_B_DONE: begin
                    range_target_q <= 2'd1;
                    range_base_q <= base_b_q;
                    range_bytes_q <= bytes_b;
                end
                RANGE_OUTPUT_DONE: begin
                    range_target_q <= 2'd2;
                    range_base_q <= base_output_q;
                    range_bytes_q <= bytes_output;
                end
                default: begin
                    range_target_q <= 2'd3;
                    range_base_q <= 32'd0;
                    range_bytes_q <= 4'd0;
                end
            endcase
            state <= SPAN_REQUEST;
        end
    endtask

    // Span checking and element evaluation cannot overlap in this FSM.
    assign span_ready=service_ready && state==SPAN_REQUEST;
    assign span_valid=service_valid && state==SPAN_WAIT;
    assign span_result=service_result;
    assign span_fault=service_fault;
    assign helper_math_req_ready=service_ready && state!=SPAN_REQUEST;
    npu_math_port #(.EXTERNAL_MATH(EXTERNAL_MATH)) span_arithmetic (
        .clk(clk), .rst_n(rst_n),
        .req_valid(rst_n && (state==SPAN_REQUEST || helper_math_req_valid)),.req_ready(service_ready),
        .req_op(state==SPAN_REQUEST ? 3'd1 : helper_math_op),
        .req_a(state==SPAN_REQUEST ? $signed({32'd0,final_index}) : helper_math_a),
        .req_b(state==SPAN_REQUEST ? $signed({32'd0,span_stride_q}) : helper_math_b),
        .req_shift(state==SPAN_REQUEST ? 7'd0 : helper_math_shift),
        .rsp_valid(service_valid),.rsp_ready(rst_n && (state==SPAN_WAIT || helper_math_rsp_ready)),
        .rsp_result(service_result),.rsp_fault(service_fault),
        .math_req_valid(math_req_valid),.math_req_ready(math_req_ready),
        .math_req_op(math_req_op),.math_req_a(math_req_a),.math_req_b(math_req_b),
        .math_req_shift(math_req_shift),.math_rsp_valid(math_rsp_valid),.math_rsp_ready(math_rsp_ready),
        .math_rsp_result(math_rsp_result),.math_rsp_fault(math_rsp_fault)
    );

    // The unchanged helper lacks a LUT fault input. Feed a zero pair on a
    // failed lookup and consume its final response before reporting failure.
    npu_q16_elementwise #(.EXTERNAL_MATH(1'b1)) elementwise (
        .clk(clk), .rst_n(rst_n),
        .req_valid(rst_n && state==HELPER_SEND && !resnet_residual), .req_ready(helper_ready),
        .req_op(helper_op), .req_a(helper_a), .req_b(helper_b),
        .req_shift(shift_q), .req_quant_a16(dtype_output_q==I16),
        .req_output_i64(helper_output_i64),
        .rsp_valid(helper_valid), .rsp_ready(rst_n && state==HELPER_WAIT && !resnet_residual),
        .rsp_result(helper_result), .rsp_fault(helper_fault),
        .lut_req_valid(helper_lut_req_valid),
        .lut_req_ready(lut_req_ready && rst_n),
        .lut_req_kind(lut_req_kind), .lut_req_index(lut_req_index),
        .lut_rsp_valid(lut_rsp_valid && rst_n),
        .lut_rsp_ready(helper_lut_rsp_ready),
        .lut_rsp_y0(lut_rsp_fault!=0 ? 64'sd0 : lut_rsp_y0),
        .lut_rsp_y1(lut_rsp_fault!=0 ? 64'sd0 : lut_rsp_y1),
        .math_req_valid(helper_math_req_valid),.math_req_ready(helper_math_req_ready),
        .math_req_op(helper_math_op),.math_req_a(helper_math_a),.math_req_b(helper_math_b),
        .math_req_shift(helper_math_shift),.math_rsp_valid(service_valid && state==HELPER_WAIT),
        .math_rsp_ready(helper_math_rsp_ready),.math_rsp_result(service_result),.math_rsp_fault(service_fault)
    );

    // The dispatch-level instance is shared by convolution, residual and GAP.
    // A local default only supports standalone module testbenches. Production
    // dispatch sets EXTERNAL_RESNET_QUANT=1; no second service is instantiated.
    generate if(EXTERNAL_RESNET_QUANT) begin:g_external_resnet_quant
        assign resnet_quant_ready=quant_req_ready;
        assign resnet_quant_valid=quant_rsp_valid;
        assign resnet_quant_result=quant_rsp_result;
    end else begin:g_local_resnet_quant
        npu_resnet_quant #(.SHARED_CONV(1'b0)) u_quant (
            .clk(clk),.rst_n(rst_n),
            .req_valid(rst_n && state==HELPER_SEND && resnet_residual),
            .req_ready(resnet_quant_ready),.req_residual(1'b1),
            .req_value(quant_req_value),.req_multiplier_a(multiplier_q),
            .req_multiplier_b(multiplier_b_q),.req_b(value_b_q[7:0]),
            .req_shift(resnet_shift_q),.rsp_valid(resnet_quant_valid),
            .rsp_ready(rst_n && state==HELPER_WAIT && resnet_residual),
            .rsp_result(resnet_quant_result),
            .conv_valid(1'b0),.conv_ready(),
            .conv_value(40'sd0),.conv_multiplier(64'sd0),
            .conv_shift(8'sd0),.conv_tag('0),
            .conv_rsp_valid(),.conv_result8(),.conv_result32(),
            .conv_overflow32(),.conv_rsp_tag(),.pipe_busy()
        );
    end endgenerate

    always_comb begin
        cmd_ready = rst_n && state==IDLE;
        busy = state!=IDLE;
        rsp_valid = rst_n && state==RESPONSE;
        resnet_residual = resnet_legacy_q && op_q==OP_ADD;
        quant_req_valid = EXTERNAL_RESNET_QUANT && rst_n && state==HELPER_SEND && resnet_residual;
        quant_req_residual = 1'b1;
        quant_req_value = {{32{value_a_q[7]}},value_a_q[7:0]};
        quant_req_multiplier_a = multiplier_q;
        quant_req_multiplier_b = multiplier_b_q;
        quant_req_b = value_b_q[7:0];
        quant_req_shift = resnet_shift_q;
        quant_rsp_ready = EXTERNAL_RESNET_QUANT && rst_n && state==HELPER_WAIT && resnet_residual;
        uses_b = op_q==OP_ADD || op_q==OP_MUL;
        fused_silu = op_q==OP_SILU || op_q==OP_SILU_QUANT;
        fused_quant = op_q==OP_SILU_QUANT;
        helper_op = fused_silu ? (fused_phase==0 ? OP_SIGMOID :
                    fused_phase==1 ? OP_MUL : OP_QUANT) : op_q;
        helper_a = fused_quant && fused_phase==2 ? write_value_q : value_a_q;
        helper_output_i64 = !fused_silu && dtype_output_q==I64;
        quant_result_stage = op_q==OP_QUANT || (fused_quant && fused_phase==2);
        known_op = op_q==OP_QUANT || uses_b || op_q==OP_SIGMOID ||
                   op_q==OP_EXP || op_q==OP_RELU || fused_silu;
        supported_output = resnet_legacy_q ? dtype_output_q==I8 : (op_q==OP_QUANT || fused_quant) ?
            (dtype_output_q==I8 || dtype_output_q==I16) :
            (dtype_output_q==I32 || dtype_output_q==I64);
        bytes_a = dtype_bytes(dtype_a_q);
        bytes_b = dtype_bytes(dtype_b_q);
        bytes_output = dtype_bytes(dtype_output_q);
        size_a = dtype_size(dtype_a_q);
        size_b = dtype_size(dtype_b_q);
        size_output = dtype_size(dtype_output_q);
        final_index = count_q-32'd1;
        helper_b = helper_op==OP_QUANT ? multiplier_q :
                   (uses_b || (fused_silu && fused_phase==1) ? value_b_q : 64'sd0);

        // An independent output guard prevents narrowing any helper result
        // without the selected dtype's exact range check.
        if (BITWISE_RESULT_RANGE) begin
            // A signed N-bit result is representable iff all bits [63:N-1]
            // equal its sign bit. Symmetric Q16 quantization excludes only
            // the most-negative code; legacy ResNet retains that code.
            // No helper arithmetic, latency, saturation or fault changes.
            if (resnet_legacy_q)
                result_in_range = (helper_result[63:7]=='0) || (&helper_result[63:7]);
            else if (fused_silu && fused_phase<2)
                result_in_range = (helper_result[63:31]=='0) || (&helper_result[63:31]);
            else if (quant_result_stage && dtype_output_q==I8)
                result_in_range = ((helper_result[63:7]=='0) || (&helper_result[63:7])) &&
                                  (!helper_result[7] || (|helper_result[6:0]));
            else if (quant_result_stage && dtype_output_q==I16)
                result_in_range = ((helper_result[63:15]=='0) || (&helper_result[63:15])) &&
                                  (!helper_result[15] || (|helper_result[14:0]));
            else if (dtype_output_q==I32)
                result_in_range = (helper_result[63:31]=='0) || (&helper_result[63:31]);
            else
                result_in_range = dtype_output_q==I64;
        end else if(resnet_legacy_q)
            result_in_range = helper_result>=-64'sd128 && helper_result<=64'sd127;
        else if (fused_silu && fused_phase<2)
            result_in_range = helper_result>=-64'sd2147483648 && helper_result<=64'sd2147483647;
        else if (quant_result_stage && dtype_output_q==I8)
            result_in_range = helper_result>=-64'sd127 && helper_result<=64'sd127;
        else if (quant_result_stage && dtype_output_q==I16)
            result_in_range = helper_result>=-64'sd32767 && helper_result<=64'sd32767;
        else if (dtype_output_q==I32)
            result_in_range = helper_result>=-64'sd2147483648 &&
                              helper_result<=64'sd2147483647;
        else
            result_in_range = dtype_output_q==I64;

        // A fixed 2^32 boundary is a bit decode, not a second carry chain.
        // Bit32 with all low bits zero is the legal exclusive end 2^32.
        range_bad = (|range_end_q[64:33]) ||
                    (range_end_q[32] && (|range_end_q[31:0]));
        // All three complete, exclusive endpoints are committed before these
        // overlap comparisons. The registered result is consumed in
        // OVERLAP_COMMIT, keeping them away from memory-admission enables.
        overlap_a = {1'b0,base_output_q}<end_a_q &&
                    {1'b0,base_a_q}<end_output_q;
        overlap_b = {1'b0,base_output_q}<end_b_q &&
                    {1'b0,base_b_q}<end_output_q;
        inplace_a = base_output_q==base_a_q && bytes_output==bytes_a &&
            ((stride_output_q==stride_a_q && stride_a_q!=0) ||
             (count_q==1 && stride_a_q==0));
        inplace_b = base_output_q==base_b_q && bytes_output==bytes_b &&
            ((stride_output_q==stride_b_q && stride_b_q!=0) ||
             (count_q==1 && stride_b_q==0));

        mem_req_valid = rst_n && (state==READ_A_SEND ||
                        state==READ_B_SEND || state==WRITE_SEND);
        mem_req_write = state==WRITE_SEND;
        mem_req_addr = state==READ_A_SEND ? pointer_a_q :
                       (state==READ_B_SEND ? pointer_b_q : pointer_output_q);
        mem_req_size = state==READ_A_SEND ? size_a :
                       (state==READ_B_SEND ? size_b : size_output);
        mem_req_wdata = write_value_q;
        mem_rsp_ready = rst_n && (state==READ_A_WAIT ||
                        state==READ_B_WAIT || state==WRITE_WAIT);
        lut_req_valid = rst_n && helper_lut_req_valid;
        lut_rsp_ready = rst_n && helper_lut_rsp_ready;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            span_return <= IDLE;
            op_q <= '0;
            count_q <= '0;
            base_a_q <= '0;
            base_b_q <= '0;
            base_output_q <= '0;
            stride_a_q <= '0;
            stride_b_q <= '0;
            stride_output_q <= '0;
            dtype_a_q <= '0;
            dtype_b_q <= '0;
            dtype_output_q <= '0;
            multiplier_q <= '0;
            multiplier_b_q <= '0;
            resnet_shift_q <= '0;
            resnet_legacy_q <= 1'b0;
            shift_q <= '0;
            index_q <= '0;
            pointer_a_q <= '0;
            pointer_b_q <= '0;
            pointer_output_q <= '0;
            end_a_q <= '0;
            end_b_q <= '0;
            end_output_q <= '0;
            value_a_q <= '0;
            value_b_q <= '0;
            write_value_q <= '0;
            span_stride_q <= '0;
            span_q <= '0;
            saved_lut_fault <= '0;
            fused_phase <= 0;
            rsp_tag <= '0;
            rsp_fault <= '0;
            rsp_completed <= '0;
        end else begin
            if (lut_rsp_valid && lut_rsp_ready && lut_rsp_fault!=0)
                saved_lut_fault <= saved_lut_fault | lut_rsp_fault;

            case (state)
                IDLE: if (cmd_valid && cmd_ready) begin
                    rsp_tag <= cmd_tag;
                    rsp_fault <= 8'd0;
                    rsp_completed <= 32'd0;
                    op_q <= cmd_op;
                    count_q <= cmd_count;
                    base_a_q <= cmd_input_a;
                    base_b_q <= cmd_input_b;
                    base_output_q <= cmd_output_base;
                    stride_a_q <= cmd_stride_a;
                    stride_b_q <= cmd_stride_b;
                    stride_output_q <= cmd_stride_output;
                    dtype_a_q <= cmd_dtype_a;
                    dtype_b_q <= cmd_dtype_b;
                    dtype_output_q <= cmd_dtype_output;
                    multiplier_q <= cmd_multiplier;
                    multiplier_b_q <= cmd_multiplier_b;
                    resnet_shift_q <= cmd_resnet_shift;
                    resnet_legacy_q <= cmd_resnet_legacy===1'b1;
                    shift_q <= cmd_shift;
                    index_q <= 32'd0;
                    pointer_a_q <= cmd_input_a;
                    pointer_b_q <= cmd_input_b;
                    pointer_output_q <= cmd_output_base;
                    saved_lut_fault <= 4'd0;
                    fused_phase <= 0;
                    state <= CHECK_COMMAND;
                end

                CHECK_COMMAND: begin
                    if (!known_op || count_q==0)
                        fail(F_COMMAND);
                    else if(resnet_legacy_q && op_q!=OP_ADD && op_q!=OP_RELU)
                        fail(F_COMMAND);
                    else if(resnet_legacy_q &&
                            (dtype_a_q!=I8 || (uses_b && dtype_b_q!=I8) || !supported_output))
                        fail(F_DTYPE);
                    else if (!resnet_legacy_q && ((dtype_a_q!=I32 && dtype_a_q!=I64) ||
                             (uses_b && dtype_b_q!=I32 && dtype_b_q!=I64) ||
                             !supported_output))
                        fail(F_DTYPE);
                    else if ((op_q==OP_QUANT || fused_quant) &&
                             (multiplier_q<=0 || multiplier_q>64'sd2147483647 || shift_q>62))
                        fail(F_DOMAIN);
                    else if(fused_silu && (resnet_legacy_q || dtype_a_q!=I32 ||
                            (!fused_quant && dtype_output_q!=I32)))
                        fail(F_DTYPE);
                    else if (!aligned(base_a_q,dtype_a_q) ||
                             (stride_a_q!=0 &&
                              (stride_a_q<{28'd0,bytes_a} || !aligned(stride_a_q,dtype_a_q))) ||
                             (uses_b && (!aligned(base_b_q,dtype_b_q) ||
                              (stride_b_q!=0 &&
                               (stride_b_q<{28'd0,bytes_b} || !aligned(stride_b_q,dtype_b_q))))) ||
                             !aligned(base_output_q,dtype_output_q) ||
                             stride_output_q<{28'd0,bytes_output} ||
                             !aligned(stride_output_q,dtype_output_q))
                        fail(F_ADDRESS);
                    else
                        start_span(stride_a_q,RANGE_A_DONE);
                end

                SPAN_REQUEST: begin
                    // A 32-bit base plus at most eight bytes needs 33 bits.
                    // Inputs were captured by start_span before this state;
                    // they remain stable if the math request is backpressured.
                    // The response is consumed in SPAN_WAIT, so this payload is
                    // always registered before a RANGE_*_DONE can use it.
                    range_base_end_q <= {1'b0,range_base_q}+{29'd0,range_bytes_q};
                    if (span_ready)
                        state <= SPAN_WAIT;
                end

                SPAN_WAIT: if (span_valid) begin
                    if (span_fault!=0 || span_result<0)
                        fail(F_ADDRESS);
                    else begin
                        span_q <= span_result;
                        state <= span_return;
                    end
                end

                RANGE_A_DONE, RANGE_B_DONE, RANGE_OUTPUT_DONE: begin
                    // SPAN_WAIT rejects a negative/failed signed64 span. This
                    // is the original full 65-bit sum with the addends
                    // regrouped; there is no narrowing before RANGE_COMMIT.
                    range_end_q <= {1'b0,$unsigned(span_q)}+{32'd0,range_base_end_q};
                    state <= RANGE_COMMIT;
                end

                RANGE_COMMIT: begin
                    // Only a registered sum and a shallow fixed-boundary bit
                    // decode reach the next-span enables; no addition occurs
                    // in this state. Error priority remains A, B, then output.
                    if (range_bad)
                        fail(F_ADDRESS);
                    else case (range_target_q)
                        2'd0: begin
                            end_a_q <= range_end_q[32:0];
                            if (uses_b)
                                start_span(stride_b_q,RANGE_B_DONE);
                            else
                                start_span(stride_output_q,RANGE_OUTPUT_DONE);
                        end
                        2'd1: begin
                            end_b_q <= range_end_q[32:0];
                            start_span(stride_output_q,RANGE_OUTPUT_DONE);
                        end
                        2'd2: begin
                            end_output_q <= range_end_q[32:0];
                            state <= CHECK_OVERLAP;
                        end
                        default: fail(F_ADDRESS);
                    endcase
                end

                CHECK_OVERLAP: begin
                    overlap_bad_q <= (overlap_a && !inplace_a) ||
                                     (uses_b && overlap_b && !inplace_b);
                    state <= OVERLAP_COMMIT;
                end

                OVERLAP_COMMIT: begin
                    if (overlap_bad_q)
                        fail(F_OVERLAP);
                    else if (vector_eligible)
                        state <= VECTOR_SEND;
                    else
                        state <= READ_A_SEND;
                end

                VECTOR_SEND: if (vector_ready) state<=VECTOR_WAIT;
                VECTOR_WAIT: if (vector_valid) begin
                    rsp_fault<=vector_fault;rsp_completed<=vector_completed;state<=RESPONSE;
                end

                READ_A_SEND: if (mem_req_ready)
                    state <= READ_A_WAIT;

                READ_A_WAIT: if (mem_rsp_valid) begin
                    if (mem_rsp_fault!=0)
                        fail(8'h20 | {4'd0,mem_rsp_fault});
                    else begin
                        value_a_q <= dtype_a_q==I8 ?
                            $signed({{56{mem_rsp_rdata[7]}},mem_rsp_rdata[7:0]}) : dtype_a_q==I32 ?
                            $signed({{32{mem_rsp_rdata[31]}},mem_rsp_rdata[31:0]}) : mem_rsp_rdata;
                        if (uses_b)
                            state <= READ_B_SEND;
                        else begin
                            saved_lut_fault <= 4'd0;
                            fused_phase <= 0;
                            state <= HELPER_SEND;
                        end
                    end
                end

                READ_B_SEND: if (mem_req_ready)
                    state <= READ_B_WAIT;

                READ_B_WAIT: if (mem_rsp_valid) begin
                    if (mem_rsp_fault!=0)
                        fail(8'h20 | {4'd0,mem_rsp_fault});
                    else begin
                        value_b_q <= dtype_b_q==I8 ?
                            $signed({{56{mem_rsp_rdata[7]}},mem_rsp_rdata[7:0]}) : dtype_b_q==I32 ?
                            $signed({{32{mem_rsp_rdata[31]}},mem_rsp_rdata[31:0]}) : mem_rsp_rdata;
                        saved_lut_fault <= 4'd0;
                        state <= HELPER_SEND;
                    end
                end

                HELPER_SEND: if (resnet_residual ? resnet_quant_ready : helper_ready)
                    state <= HELPER_WAIT;

                HELPER_WAIT: if(resnet_residual && resnet_quant_valid) begin
                    // Exact profile-1 service already applies its full-range
                    // INT8 saturation. Do not clip -128 to Q16's -127 here.
                    write_value_q <= {{56{resnet_quant_result[7]}},resnet_quant_result};
                    state <= WRITE_SEND;
                end else if (!resnet_residual && helper_valid) begin
                    // The LUT response and all helper arithmetic have already
                    // drained. A failed lookup can never cause a write.
                    if (saved_lut_fault!=0)
                        fail(8'h30 | {4'd0,saved_lut_fault});
                    else if (helper_fault!=0)
                        fail(helper_fault==1 ? F_DOMAIN : F_ARITHMETIC);
                    else if (!result_in_range)
                        fail(F_ARITHMETIC);
                    else if(fused_silu && fused_phase==0)begin
                        value_b_q <= helper_result;
                        fused_phase <= 1;
                        state <= HELPER_SEND;
                    end else if(fused_quant && fused_phase==1)begin
                        write_value_q <= helper_result;
                        fused_phase <= 2;
                        state <= HELPER_SEND;
                    end else begin
                        write_value_q <= helper_result;
                        state <= WRITE_SEND;
                    end
                end

                WRITE_SEND: if (mem_req_ready)
                    state <= WRITE_WAIT;

                WRITE_WAIT: if (mem_rsp_valid) begin
                    if (mem_rsp_fault!=0)
                        fail(8'h20 | {4'd0,mem_rsp_fault});
                    else begin
                        rsp_completed <= rsp_completed+32'd1;
                        if (index_q==final_index) begin
                            state <= RESPONSE;
                        end else begin
                            index_q <= index_q+32'd1;
                            // The complete nonnegative-stride envelopes were
                            // checked before the first memory request.
                            pointer_a_q <= pointer_a_q+stride_a_q;
                            if (uses_b)
                                pointer_b_q <= pointer_b_q+stride_b_q;
                            pointer_output_q <= pointer_output_q+stride_output_q;
                            state <= READ_A_SEND;
                        end
                    end
                end

                RESPONSE: if (rsp_ready)
                    state <= IDLE;

                default: begin
                    // Never announce a free scalar path after an invalid
                    // internal encoding; shared reset is the recovery path.
                    state <= state;
                end
            endcase
        end
    end
endmodule
