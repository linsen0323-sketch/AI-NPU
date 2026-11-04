`timescale 1ns/1ps
// Profile-1 numeric compatibility inside the unified graph backend. This is
// one shared service, independent of the old ResNet controller, tile memories
// and requant.sv. Scalar responses are held until the caller accepts them;
// optional tagged Conv results retain the original one-lane/cycle stream.
// Requant: signed40 * signed32. Residual: signed8 * signed64 + signed8 *
// signed64. Both retain the complete signed73 numerator and round ONCE.
// req_multiplier_a is sign-extended signed32 in requant mode; callers check
// this at command acceptance. Residual mode uses both complete signed64 factors.
module npu_resnet_quant #(
    parameter bit SHARED_CONV=1'b0,
    parameter integer CONV_TAG_W=19
) (
    input wire clk, rst_n,
    input wire req_valid,
    output wire req_ready,
    input wire req_residual,
    input wire signed [39:0] req_value,
    input wire signed [63:0] req_multiplier_a, req_multiplier_b,
    input wire signed [7:0] req_b, req_shift,
    output wire rsp_valid,
    input wire rsp_ready,
    output wire signed [7:0] rsp_result,
    // The streaming caller owns the pipe until pipe_busy clears. Its lane
    // stream never uses the scalar outstanding/response holding register.
    input wire conv_valid,output wire conv_ready,
    input wire signed [39:0] conv_value,
    input wire signed [63:0] conv_multiplier,
    input wire signed [7:0] conv_shift,
    input wire [CONV_TAG_W-1:0] conv_tag,
    output wire conv_rsp_valid,
    output wire signed [7:0] conv_result8,
    output wire signed [31:0] conv_result32,
    output wire conv_overflow32,
    output wire [CONV_TAG_W-1:0] conv_rsp_tag,
    output wire pipe_busy
);
    // Scalar traffic deliberately retains ONE outstanding transaction because
    // its arbiter has one owner register. Conv uses an independent tagged path
    // through these same four DSP48E1 multipliers and the full RNE pipeline.
    logic outstanding, response_valid;
    logic signed [7:0] response_result;
    localparam integer PIPE_TAG_W=CONV_TAG_W+1;
    wire product_ready, product_valid,product_busy,round_busy;
    wire signed [72:0] product_value;
    wire [PIPE_TAG_W+7:0] product_tag;
    wire [PIPE_TAG_W-1:0] round_tag;
    wire pipe_round_valid;
    wire signed [7:0] round_result;
    wire signed [31:0] round_result32;
    wire round_overflow32;
    wire conv_request=SHARED_CONV&&conv_valid;
    wire conv_fire=conv_request&&conv_ready;
    wire scalar_fire=req_valid&&req_ready;
    wire round_valid=pipe_round_valid&&!round_tag[CONV_TAG_W];
    assign conv_ready=rst_n&&SHARED_CONV&&!outstanding&&product_ready;
    assign req_ready=rst_n && !outstanding && product_ready && !conv_request;
    assign rsp_valid=rst_n && response_valid;
    assign rsp_result=response_result;
    assign conv_rsp_valid=rst_n&&SHARED_CONV&&pipe_round_valid&&round_tag[CONV_TAG_W];
    assign conv_result8=round_result;
    assign conv_result32=round_result32;
    assign conv_overflow32=round_overflow32;
    assign conv_rsp_tag=round_tag[CONV_TAG_W-1:0];
    assign pipe_busy=product_busy||round_busy;
    npu_resnet_product_pipe #(.TAG_W(PIPE_TAG_W+8)) u_product (
        .clk(clk),.rst_n(rst_n),.in_valid(conv_fire||scalar_fire),.in_ready(product_ready),
        .in_residual(conv_fire?1'b0:req_residual),.in_value(conv_fire?conv_value:req_value),
        .in_multiplier_a(conv_fire?conv_multiplier:req_multiplier_a),
        .in_multiplier_b(req_multiplier_b),.in_b(req_b),
        .in_tag(conv_fire?{1'b1,conv_tag,conv_shift}:{1'b0,{CONV_TAG_W{1'b0}},req_shift}),
        .out_valid(product_valid),.out_product(product_value),.out_tag(product_tag),.busy(product_busy));
    npu_resnet_round_pipe #(.TAG_W(PIPE_TAG_W),.MAG_W(73)) u_round (
        .clk(clk),.rst_n(rst_n),.in_valid(product_valid),
        .in_value({{23{product_value[72]}},product_value}),.in_shift($signed(product_tag[7:0])),
        .in_tag(product_tag[PIPE_TAG_W+7:8]),
        .out_valid(pipe_round_valid),.out_result8(round_result),.out_result32(round_result32),
        .out_overflow32(round_overflow32),.out_tag(round_tag),.busy(round_busy));
    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            outstanding<=0;response_valid<=0;response_result<=0;
        end else begin
            if(req_valid&&req_ready)outstanding<=1;
            if(round_valid)begin response_result<=round_result;response_valid<=1;end
            if(response_valid&&rsp_ready)begin response_valid<=0;outstanding<=0;end
        end
    end
endmodule

// Four signed25 x signed18 multipliers fit the native DSP48E1 multiplier.
// Requant decomposition is EXACT, including both most-negative operands:
//   a = unsigned(a[22:0]) + signed(a[39:23])*2^23
//   b = unsigned(b[15:0]) + signed(b[31:16])*2^16.
// Residual decomposes each complete signed64 factor as 23+23+18 bits;
// two consecutive issues form a8*ma64 + b8*mb64 in signed73. No partial
// rounding, magnitude truncation, or assumption about 64-bit factors occurs.
// Outputs never stall. Callers either reserve a response slot (the scalar
// wrapper above) or consume each result into their tagged local tile.
module npu_resnet_product_pipe #(parameter integer TAG_W=1) (
    input wire clk,rst_n,input wire in_valid,output wire in_ready,
    input wire in_residual,input wire signed [39:0] in_value,
    input wire signed [63:0] in_multiplier_a,in_multiplier_b,
    input wire signed [7:0] in_b,input wire [TAG_W-1:0] in_tag,
    output logic out_valid,output logic signed [72:0] out_product,
    output logic [TAG_W-1:0] out_tag,output wire busy
);
    logic residual_pending;
    logic signed [63:0] saved_factor;
    logic signed [7:0] saved_byte;
    logic [TAG_W-1:0] saved_tag;
    logic signed [24:0] operand_a[0:3];
    logic signed [17:0] operand_b[0:3];
    logic signed [24:0] operand_a_q[0:3];
    logic signed [17:0] operand_b_q[0:3];
    logic operand_valid,operand_residual,operand_second;
    logic [TAG_W-1:0] operand_tag;
    (* use_dsp="yes" *) logic signed [42:0] product[0:3];
    logic product_valid,product_residual,product_second;
    logic [TAG_W-1:0] product_tag;
    logic sum_valid,sum_residual,sum_second;
    logic [TAG_W-1:0] sum_tag;
    logic signed [72:0] sum_low,sum_high,residual_first;
    wire issue=residual_pending||(in_valid&&in_ready);
    wire issue_residual=residual_pending||in_residual;
    wire signed [63:0] factor=residual_pending?saved_factor:in_multiplier_a;
    wire signed [7:0] factor_byte=residual_pending?saved_byte:in_value[7:0];
    wire signed [72:0] extended_product[0:3];
    assign in_ready=rst_n&&!residual_pending;
    assign busy=residual_pending||operand_valid||product_valid||sum_valid||out_valid;
    generate for(genvar p=0;p<4;p=p+1)begin:g_extend
        assign extended_product[p]={{30{product[p][42]}},product[p]};
    end endgenerate
    always_comb begin
        for(integer p=0;p<4;p=p+1)begin operand_a[p]=0;operand_b[p]=0;end
        if(issue_residual)begin
            operand_a[0]=$signed({2'b00,factor[22:0]});
            operand_a[1]=$signed({2'b00,factor[45:23]});
            operand_a[2]=$signed({{7{factor[63]}},factor[63:46]});
            for(integer p=0;p<3;p=p+1)operand_b[p]={{10{factor_byte[7]}},factor_byte};
        end else begin
            operand_a[0]=$signed({2'b00,in_value[22:0]});operand_a[1]=operand_a[0];
            operand_a[2]=$signed({{8{in_value[39]}},in_value[39:23]});operand_a[3]=operand_a[2];
            operand_b[0]=$signed({2'b00,in_multiplier_a[15:0]});operand_b[2]=operand_b[0];
            operand_b[1]=$signed({{2{in_multiplier_a[31]}},in_multiplier_a[31:16]});operand_b[3]=operand_b[1];
        end
    end
    always_ff @(posedge clk)begin
        if(!rst_n)begin
            residual_pending<=0;operand_valid<=0;product_valid<=0;sum_valid<=0;out_valid<=0;
            operand_residual<=0;operand_second<=0;operand_tag<=0;
            product_residual<=0;product_second<=0;sum_residual<=0;sum_second<=0;
            saved_factor<=0;saved_byte<=0;saved_tag<=0;product_tag<=0;sum_tag<=0;out_tag<=0;
            sum_low<=0;sum_high<=0;residual_first<=0;out_product<=0;
        end else begin
            operand_valid<=issue;product_valid<=operand_valid;sum_valid<=product_valid;out_valid<=0;
            if(residual_pending)residual_pending<=0;
            else if(in_valid&&in_ready&&in_residual)begin
                residual_pending<=1;saved_factor<=in_multiplier_b;saved_byte<=in_b;saved_tag<=in_tag;
            end
            if(issue)begin
                // Split coefficient selection from the native DSP multiply.
                for(integer p=0;p<4;p=p+1)begin
                    operand_a_q[p]<=operand_a[p];operand_b_q[p]<=operand_b[p];
                end
                operand_residual<=issue_residual;operand_second<=residual_pending;
                operand_tag<=residual_pending?saved_tag:in_tag;
            end
            if(operand_valid)begin
                for(integer p=0;p<4;p=p+1)product[p]<=operand_a_q[p]*operand_b_q[p];
                product_residual<=operand_residual;product_second<=operand_second;
                product_tag<=operand_tag;
            end
            if(product_valid)begin
                sum_residual<=product_residual;sum_second<=product_second;sum_tag<=product_tag;
                if(product_residual)begin
                    sum_low<=extended_product[0]+(extended_product[1]<<<23);
                    sum_high<=extended_product[2]<<<46;
                end else begin
                    sum_low<=extended_product[0]+(extended_product[1]<<<16);
                    sum_high<=(extended_product[2]<<<23)+(extended_product[3]<<<39);
                end
            end
            if(sum_valid)begin
                if(sum_residual&&!sum_second)residual_first<=sum_low+sum_high;
                else begin
                    out_valid<=1;out_tag<=sum_tag;
                    out_product<=sum_low+sum_high+(sum_residual?residual_first:73'sd0);
                end
            end
        end
    end
endmodule

// Fixed-depth magnitude/RNE pipeline. Low 0..7-bit and high 8-bit-multiple
// shifts have separate registers. The guard and sticky bits survive both.
// result8 preserves every signed8 shift, including negative shifts and -128.
// result32/overflow32 are used by Q16 Conv only with nonnegative shifts.
module npu_resnet_round_pipe #(parameter integer TAG_W=1,parameter integer MAG_W=96) (
    input wire clk,rst_n,input wire in_valid,input wire signed [95:0] in_value,
    input wire signed [7:0] in_shift,input wire [TAG_W-1:0] in_tag,
    output logic out_valid,output logic signed [7:0] out_result8,
    output logic signed [31:0] out_result32,output logic out_overflow32,
    output logic [TAG_W-1:0] out_tag,output wire busy
);
    logic v0,v1,v2,negative0,negative1,negative2,left0,force0,force1,force2;
    logic [MAG_W-1:0] magnitude0,magnitude1,magnitude2;
    logic left_overflow1,left_overflow2;
    logic [7:0] amount0;
    logic [3:0] high_amount1;
    logic guard1,sticky1,guard2,sticky2;
    logic [TAG_W-1:0] tag0,tag1,tag2;
    wire [MAG_W-1:0] reversed_magnitude0,low_shift_input,low_shifted,low_shift_result;
    // Reverse bits around one right shifter to retain exact left/right shifts.
    generate for(genvar b=0;b<MAG_W;b=b+1)begin:g_low_shift
        assign reversed_magnitude0[b]=magnitude0[MAG_W-1-b];
        assign low_shift_result[b]=left0?low_shifted[MAG_W-1-b]:low_shifted[b];
    end endgenerate
    assign low_shift_input=left0?reversed_magnitude0:magnitude0;
    assign low_shifted=low_shift_input>>amount0[2:0];
    wire [31:0] negate_lo=~in_value[31:0]+32'd1;
    wire [31:0] negate_mid=~in_value[63:32]+{31'd0,(in_value[31:0]==0)};
    wire [MAG_W-65:0] negate_hi=~in_value[MAG_W-1:64]+{{(MAG_W-65){1'b0}},(in_value[63:0]==0)};
    wire [MAG_W-1:0] input_magnitude=in_value[95]?{negate_hi,negate_mid,negate_lo}:$unsigned(in_value[MAG_W-1:0]);
    wire [7:0] input_amount=in_shift[7]?(~$unsigned(in_shift)+8'd1):$unsigned(in_shift);
    wire input_large=in_value[95]?
        ((in_value[95:8]!={88{1'b1}})||(in_value[7:0]==0)):(|in_value[95:8]);
    wire [15:0] high_guard,high_sticky;
    assign high_guard[0]=guard1;assign high_sticky[0]=sticky1;
    generate for(genvar g=1;g<16;g=g+1)begin:g_high_bits
        if(g*8<=MAG_W)begin:g_in_range
            assign high_guard[g]=magnitude1[g*8-1];
            assign high_sticky[g]=sticky1||guard1||(|magnitude1[g*8-2:0]);
        end else begin:g_beyond
            assign high_guard[g]=0;
            assign high_sticky[g]=sticky1||guard1||(|magnitude1);
        end
    end endgenerate
    wire round_up=guard2&&(sticky2||magnitude2[0]);
    wire [32:0] rounded32={1'b0,magnitude2[31:0]}+{32'd0,round_up};
    // Bit 8 changes exactly when the low-byte increment carries out.
    wire [8:0] rounded8={rounded32[8]^magnitude2[8],rounded32[7:0]};
    wire signed [31:0] signed_result32=negative2?-$signed(rounded32[31:0]):$signed(rounded32[31:0]);
    wire saturation8=force2||(|magnitude2[MAG_W-1:8])||
        (negative2?(rounded8>9'd128):(rounded8>9'd127));
    wire overflow32=left_overflow2||(|magnitude2[MAG_W-1:32])||
        (negative2?(rounded32>33'd2147483648):(rounded32>33'd2147483647));
    assign busy=v0||v1||v2||out_valid;
`ifndef SYNTHESIS
    initial if(MAG_W!=73 && MAG_W!=96)$fatal(1,"MAG_W must be 73 or 96");
    always @(posedge clk) if(rst_n && in_valid && MAG_W<96 &&
        in_value[95:MAG_W-1]!={(97-MAG_W){in_value[MAG_W-1]}})
        $fatal(1,"Round input exceeds signed MAG_W contract");
`endif
    always_ff @(posedge clk)begin
        if(!rst_n)begin
            v0<=0;v1<=0;v2<=0;out_valid<=0;negative0<=0;negative1<=0;negative2<=0;
            left0<=0;force0<=0;force1<=0;force2<=0;amount0<=0;high_amount1<=0;
            magnitude0<=0;magnitude1<=0;magnitude2<=0;left_overflow1<=0;left_overflow2<=0;guard1<=0;sticky1<=0;guard2<=0;sticky2<=0;
            tag0<=0;tag1<=0;tag2<=0;out_tag<=0;out_result8<=0;out_result32<=0;out_overflow32<=0;
        end else begin
            v0<=in_valid;v1<=v0;v2<=v1;out_valid<=v2;
            if(in_valid)begin
                magnitude0<=input_magnitude;negative0<=in_value[95];left0<=in_shift[7];tag0<=in_tag;
                amount0<=(in_shift[7]&&input_amount>=8)?8'd0:input_amount;
                force0<=in_shift[7]&&(in_value!=0)&&((input_amount>=8)||input_large);
            end
            if(v0)begin
                magnitude1<=low_shift_result;
                // Narrowing may discard a left-shifted high bit. Preserve
                // its 32-bit overflow verdict; low 32 output bits are intact.
                left_overflow1<=MAG_W<96 && left0 &&
                    (|(magnitude0[MAG_W-1-:7] & (7'h7f << (3'd7-amount0[2:0]))));
                negative1<=negative0;force1<=force0;tag1<=tag0;
                high_amount1<=left0?4'd0:amount0[6:3];
                guard1<=!left0&&amount0[2:0]!=0?magnitude0[amount0[2:0]-1'b1]:1'b0;
                sticky1<=!left0&&amount0[2:0]>1?
                    (|(magnitude0[7:0]&((8'd1<<(amount0[2:0]-1'b1))-1'b1))):1'b0;
            end
            if(v1)begin
                magnitude2<=magnitude1>>{high_amount1,3'b000};
                guard2<=high_guard[high_amount1];sticky2<=high_sticky[high_amount1];
                negative2<=negative1;force2<=force1;tag2<=tag1;left_overflow2<=left_overflow1;
            end
            if(v2)begin
                out_result8<=saturation8?(negative2?-8'sd128:8'sd127):
                    $signed(signed_result32[7:0]);
                out_result32<=signed_result32;
                out_overflow32<=overflow32;out_tag<=tag2;
            end
        end
    end
endmodule

// Preserves legacy round_sat's signed8 shift domain, magnitude RNE and full
// INT8 range [-128,127]. Negative shifts saturate a nonzero result when its
// exact left-shifted magnitude cannot fit. No Q16 symmetric clipping applies.
(* use_dsp="no" *) module npu_resnet_round_sat (
    input logic clk, rst_n, start,
    input logic signed [95:0] value,
    input logic signed [7:0] shift,
    output logic busy, done,
    output logic signed [7:0] result
);
    logic [95:0] magnitude;
    logic [7:0] amount;
    logic negative,left,guard_bit,sticky,force_saturation;
    logic [3:0] step;
    wire [31:0] negate_lo=~value[31:0]+32'd1;
    wire [31:0] negate_mid=~value[63:32]+{31'd0,(value[31:0]==0)};
    wire [31:0] negate_hi=~value[95:64]+{31'd0,(value[63:0]==0)};
    wire [95:0] input_magnitude=value[95]?{negate_hi,negate_mid,negate_lo}:$unsigned(value);
    wire [7:0] input_amount=shift[7]?(~$unsigned(shift)+8'd1):$unsigned(shift);
    wire input_large=value[95]?
        ((value[95:8]!={88{1'b1}})||(value[7:0]==0)):(|value[95:8]);
    wire round_up=guard_bit&&(sticky||magnitude[0]);
    wire [8:0] rounded_low={1'b0,magnitude[7:0]}+{8'd0,round_up};
    wire saturate=force_saturation||(|magnitude[95:8])||
        (negative?(rounded_low>9'd128):(rounded_low>9'd127));
    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            busy<=0;done<=0;result<=0;magnitude<=0;amount<=0;
            negative<=0;left<=0;guard_bit<=0;sticky<=0;force_saturation<=0;step<=0;
        end else begin
            done<=0;
            if(start&&!busy) begin
                busy<=1;step<=0;magnitude<=input_magnitude;
                negative<=value[95];left<=shift[7];guard_bit<=0;sticky<=0;
                amount<=(shift[7]&&(input_amount>=8))?8'd0:input_amount;
                force_saturation<=shift[7]&&(value!=0)&&((input_amount>=8)||input_large);
            end else if(busy) begin
                if(step==7) begin
                    if(saturate)result<=negative?-8'sd128:8'sd127;
                    else result<=negative?-$signed(rounded_low[7:0]):$signed(rounded_low[7:0]);
                    busy<=0;done<=1;
                end else begin
                    step<=step+1'b1;
                    if(amount[step]) begin
                        if(left) case(step)
                            0:magnitude<=magnitude<<1;
                            1:magnitude<=magnitude<<2;
                            2:magnitude<=magnitude<<4;
                            default:magnitude<=magnitude;
                        endcase
                        else case(step)
                            0:begin magnitude<=magnitude>>1;guard_bit<=magnitude[0];sticky<=sticky|guard_bit;end
                            1:begin magnitude<=magnitude>>2;guard_bit<=magnitude[1];sticky<=sticky|guard_bit|magnitude[0];end
                            2:begin magnitude<=magnitude>>4;guard_bit<=magnitude[3];sticky<=sticky|guard_bit|(|magnitude[2:0]);end
                            3:begin magnitude<=magnitude>>8;guard_bit<=magnitude[7];sticky<=sticky|guard_bit|(|magnitude[6:0]);end
                            4:begin magnitude<=magnitude>>16;guard_bit<=magnitude[15];sticky<=sticky|guard_bit|(|magnitude[14:0]);end
                            5:begin magnitude<=magnitude>>32;guard_bit<=magnitude[31];sticky<=sticky|guard_bit|(|magnitude[30:0]);end
                            6:begin magnitude<=magnitude>>64;guard_bit<=magnitude[63];sticky<=sticky|guard_bit|(|magnitude[62:0]);end
                            default:magnitude<=magnitude;
                        endcase
                    end
                end
            end
        end
    end
endmodule
