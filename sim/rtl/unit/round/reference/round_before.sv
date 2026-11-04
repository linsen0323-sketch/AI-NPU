`timescale 1ns/1ps
module npu_resnet_round_pipe_before #(parameter integer TAG_W=1) (
    input wire clk,rst_n,input wire in_valid,input wire signed [95:0] in_value,
    input wire signed [7:0] in_shift,input wire [TAG_W-1:0] in_tag,
    output logic out_valid,output logic signed [7:0] out_result8,
    output logic signed [31:0] out_result32,output logic out_overflow32,
    output logic [TAG_W-1:0] out_tag,output wire busy
);
    logic v0,v1,v2,negative0,negative1,negative2,left0,force0,force1,force2;
    logic [95:0] magnitude0,magnitude1,magnitude2;
    logic [7:0] amount0;
    logic [3:0] high_amount1;
    logic guard1,sticky1,guard2,sticky2;
    logic [TAG_W-1:0] tag0,tag1,tag2;
    wire [95:0] reversed_magnitude0,low_shift_input,low_shifted,low_shift_result;
    // Reverse bits around one right shifter to retain exact left/right shifts.
    generate for(genvar b=0;b<96;b=b+1)begin:g_low_shift
        assign reversed_magnitude0[b]=magnitude0[95-b];
        assign low_shift_result[b]=left0?low_shifted[95-b]:low_shifted[b];
    end endgenerate
    assign low_shift_input=left0?reversed_magnitude0:magnitude0;
    assign low_shifted=low_shift_input>>amount0[2:0];
    wire [31:0] negate_lo=~in_value[31:0]+32'd1;
    wire [31:0] negate_mid=~in_value[63:32]+{31'd0,(in_value[31:0]==0)};
    wire [31:0] negate_hi=~in_value[95:64]+{31'd0,(in_value[63:0]==0)};
    wire [95:0] input_magnitude=in_value[95]?{negate_hi,negate_mid,negate_lo}:$unsigned(in_value);
    wire [7:0] input_amount=in_shift[7]?(~$unsigned(in_shift)+8'd1):$unsigned(in_shift);
    wire input_large=in_value[95]?
        ((in_value[95:8]!={88{1'b1}})||(in_value[7:0]==0)):(|in_value[95:8]);
    wire [15:0] high_guard,high_sticky;
    assign high_guard[0]=guard1;assign high_sticky[0]=sticky1;
    generate for(genvar g=1;g<16;g=g+1)begin:g_high_bits
        if(g*8<=96)begin:g_in_range
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
    wire saturation8=force2||(|magnitude2[95:8])||
        (negative2?(rounded8>9'd128):(rounded8>9'd127));
    wire overflow32=(|magnitude2[95:32])||
        (negative2?(rounded32>33'd2147483648):(rounded32>33'd2147483647));
    assign busy=v0||v1||v2||out_valid;
    always_ff @(posedge clk)begin
        if(!rst_n)begin
            v0<=0;v1<=0;v2<=0;out_valid<=0;negative0<=0;negative1<=0;negative2<=0;
            left0<=0;force0<=0;force1<=0;force2<=0;amount0<=0;high_amount1<=0;
            magnitude0<=0;magnitude1<=0;magnitude2<=0;guard1<=0;sticky1<=0;guard2<=0;sticky2<=0;
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
                negative1<=negative0;force1<=force0;tag1<=tag0;
                high_amount1<=left0?4'd0:amount0[6:3];
                guard1<=!left0&&amount0[2:0]!=0?magnitude0[amount0[2:0]-1'b1]:1'b0;
                sticky1<=!left0&&amount0[2:0]>1?
                    (|(magnitude0[7:0]&((8'd1<<(amount0[2:0]-1'b1))-1'b1))):1'b0;
            end
            if(v1)begin
                magnitude2<=magnitude1>>{high_amount1,3'b000};
                guard2<=high_guard[high_amount1];sticky2<=high_sticky[high_amount1];
                negative2<=negative1;force2<=force1;tag2<=tag1;
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
