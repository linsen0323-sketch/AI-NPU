`timescale 1ns/1ps
// Non-stalling, tagged lane. The tile controller reserves every result slot
// before issue. Commands remain stable until the entire tile has drained.
module npu_q16_vector_pipe #(parameter integer TAG_W=7) (
    input wire clk,rst_n,
    input wire [4:0] op,
    input wire legacy,input wire [2:0] output_dtype,
    input wire signed [63:0] multiplier,multiplier_b,
    input wire [6:0] shift,input wire signed [7:0] legacy_shift,
    input wire in_valid,output wire in_ready,
    input wire signed [31:0] in_a,in_b,input wire [TAG_W-1:0] in_tag,
    output wire out_valid,output wire signed [63:0] out_value,
    output wire [TAG_W-1:0] out_tag,output wire [7:0] out_fault,
    output wire lut_req_valid,input wire lut_req_ready,
    output wire [1:0] lut_req_kind,output wire [12:0] lut_req_index,
    input wire lut_rsp_valid,output wire lut_rsp_ready,
    input wire signed [63:0] lut_y0,lut_y1,input wire [3:0] lut_fault
);
    localparam [4:0] QUANT=1,ADD=4,MUL=5,SIGMOID=9,EXP=10,RELU=11,SILU=22,SILU_QUANT=23;
    wire activation=op==SIGMOID || op==EXP || op==SILU || op==SILU_QUANT;
    wire fused=op==SILU || op==SILU_QUANT;
    wire quantized=op==QUANT || op==SILU_QUANT;
    wire residual=legacy && op==ADD;
    wire secondary_ready,secondary_valid,secondary_busy;
    wire signed [72:0] secondary_product;
    wire [TAG_W+8:0] secondary_tag;
    reg head_valid;
    wire head_ready=!activation || lut_req_ready;
    assign in_ready=rst_n && (residual ? secondary_ready : (!head_valid || head_ready));
    wire fire=in_valid && in_ready;
    wire head_fire=head_valid && head_ready;
    reg [12:0] head_index;
    assign lut_req_valid=rst_n && !residual && activation && head_valid;
    assign lut_req_kind=op==EXP ? 2'd1 : 2'd0;
    assign lut_rsp_ready=rst_n;
    // Inside [-2^20,2^20), adding 2^20 only flips bit20. Fixed
    // thresholds avoid a carry chain after the tile RAM's lane selector.
    wire below=in_a[31] && !(&in_a[30:20]);
    wire above=!in_a[31] && (|in_a[30:20]);
    wire [12:0] input_index=above ? 13'd8191 : below ? 13'd0 : {~in_a[20],in_a[19:8]};
    assign lut_req_index=head_index;
    wire [8:0] fraction=above ? 9'd256 : below ? 9'd0 : {1'b0,in_a[7:0]};

    function automatic signed [63:0] rne8(input logic signed [63:0] x);
        rne8=(x>>>8)+$signed({63'd0,(x[7] && ((|x[6:0]) || x[8]))});
    endfunction
    function automatic signed [63:0] rne16(input logic signed [63:0] x);
        rne16=(x>>>16)+$signed({63'd0,(x[15] && ((|x[14:0]) || x[16]))});
    endfunction
    function automatic logic fits32(input logic signed [63:0] x);
        fits32=x[63:31]=={33{x[31]}};
    endfunction
    // Exact fits32(rne16(x)), without a rounded-value carry chain followed
    // by a range reduction. Floor fits except max+carry; min-1 is recovered
    // only by rounding up. The asymmetric half ties follow round-to-even.
    function automatic logic fits32_rne16(input logic signed [63:0] x);
        logic increment,floor_fits,positive_edge,negative_recover;
        begin
            increment=x[15] && ((|x[14:0]) || x[16]);
            floor_fits=x[63:47]=={17{x[47]}};
            positive_edge=x[47:16]==32'h7fffffff;
            negative_recover=x[63:16]==48'hffff7fffffff;
            fits32_rne16=(floor_fits && !(positive_edge && increment)) ||
                         (negative_recover && increment);
        end
    endfunction

    typedef struct packed {
        logic signed [31:0] a,b;
        logic [TAG_W-1:0] tag;
        logic [8:0] fraction;
        logic [7:0] fault;
    } context_t;
    context_t head,c0,c1,c2,c3,c4,c5,c6,c7;
    logic v0,v1,v2,v3,v4,v5,v6,v7;
    logic signed [64:0] delta2,interpolation4;
    logic signed [63:0] base2,base3,interpolation5,selected6,evaluated7;
    (* use_dsp="yes" *) logic signed [73:0] interpolation_product3;
    (* use_dsp="yes" *) logic signed [63:0] product6;
    // Mode is held by the owner while the lane drains. Decode it alongside
    // the stage-5 operands, before the DSP multiplier/cascade path. The v4/v5
    // payload boundary already exists, so this adds no issue/result cycle.
    (* keep="true" *) logic product_fused5,product_quant5;
    (* keep="true" *) logic product_quant6,product_scaled6,product_requires32_6;
    logic [7:0] delta_fault3,interpolation_fault4,interpolation_fault5;
    wire signed [63:0] rounded_interpolation=rne8(interpolation_product3[63:0]);
    wire signed [64:0] interpolated_sum={base3[63],base3}+{rounded_interpolation[63],rounded_interpolation};
    wire signed [63:0] evaluated6=product_quant6 ? product6 :
        product_scaled6 ? rne16(product6) : selected6;
    wire evaluated_fits32=product_scaled6 ? fits32_rne16(product6) : fits32(selected6);
    always @(posedge clk) begin
        if (!rst_n) begin
            head_valid<=0;v0<=0;v1<=0;v2<=0;v3<=0;v4<=0;v5<=0;v6<=0;v7<=0;
        end else begin
            if (!residual && in_ready) begin
                head_valid<=in_valid;
                if (in_valid) begin
                    head.a<=in_a;head.b<=in_b;head.tag<=in_tag;head.fraction<=fraction;
                    head.fault<=op==QUANT && in_a==32'sh80000000 ? 8'h05 : 8'd0;
                    head_index<=input_index;
                end
            end
            v0<=head_fire && !residual;v1<=v0;
            v2<=activation ? lut_rsp_valid : v1;
            v3<=v2;v4<=v3;v5<=v4;v6<=v5;v7<=v6;
            if (head_fire && !residual) c0<=head;
            if (v0) c1<=c0;
            if (activation ? lut_rsp_valid : v1) begin
                c2<=c1;
                delta2<={lut_y1[63],lut_y1}-{lut_y0[63],lut_y0};
                base2<=lut_y0;
                if (activation && lut_fault!=0) c2.fault<=8'h30|{4'd0,lut_fault};
            end
            if (v2) begin
                c3<=c2;base3<=base2;
                interpolation_product3<=$signed(delta2[63:0])*$signed({1'b0,c2.fraction});
                delta_fault3<=delta2[64]!=delta2[63] ? 8'h04 : 8'd0;
            end
            if (v3) begin
                c4<=c3;interpolation4<=interpolated_sum;
                interpolation_fault4<=delta_fault3!=0 ||
                    interpolation_product3[73:63]!={11{interpolation_product3[63]}} ? 8'h04 : 8'd0;
            end
            if (v4) begin
                c5<=c4;interpolation5<=interpolation4[63:0];
                product_fused5<=fused;product_quant5<=op==QUANT;
                interpolation_fault5<=interpolation_fault4!=0 || interpolation4[64]!=interpolation4[63] ||
                    ((fused || output_dtype!=4) && !fits32(interpolation4[63:0])) ? 8'h04 : 8'd0;
            end
            if (v5) begin
                c6<=c5;
                product_quant6<=product_quant5;
                product_scaled6<=op==MUL || product_fused5;
                product_requires32_6<=op!=QUANT && (fused || output_dtype!=4);
                if (activation && c5.fault==0 && interpolation_fault5!=0) c6.fault<=interpolation_fault5;
                product6<=$signed(c5.a)*$signed(product_fused5 ? interpolation5[31:0] : product_quant5 ? multiplier[31:0] : c5.b);
                selected6<=activation ? interpolation5 : op==ADD ?
                    $signed({{32{c5.a[31]}},c5.a})+$signed({{32{c5.b[31]}},c5.b}) :
                    c5.a<0 ? 64'sd0 : $signed({{32{c5.a[31]}},c5.a});
            end
            if (v6) begin
                c7<=c6;evaluated7<=evaluated6;
                if (c6.fault==0 && product_requires32_6 && !evaluated_fits32)
                    c7.fault<=8'h04;
            end
        end
    end
    wire secondary_request=residual ? fire : (op==SILU_QUANT && v7);
    wire [7:0] quant_fault=c7.fault==0 && evaluated7==-64'sd2147483648 ? 8'h05 : c7.fault;
    // Residual ADD and fused requantization are mutually exclusive commands.
    // Both use the registered native-DSP partial products in this lane.
    npu_resnet_product_pipe #(.TAG_W(TAG_W+9)) u_secondary_product (
        .clk(clk),.rst_n(rst_n),.in_valid(secondary_request),.in_ready(secondary_ready),
        .in_residual(residual),.in_value(residual ? {{32{in_a[7]}},in_a[7:0]} : {{8{evaluated7[31]}},evaluated7[31:0]}),
        .in_multiplier_a(multiplier),.in_multiplier_b(multiplier_b),.in_b(in_b[7:0]),
        .in_tag(residual ? {1'b0,8'd0,in_tag} : {evaluated7[63],quant_fault,c7.tag}),
        .out_valid(secondary_valid),.out_product(secondary_product),
        .out_tag(secondary_tag),.busy(secondary_busy));
    wire secondary_round=residual || op==SILU_QUANT;
    wire round_valid,round_overflow,round_busy;
    wire signed [7:0] round8;
    wire signed [31:0] round32;
    wire [TAG_W+8:0] round_tag;
    npu_resnet_round_pipe #(.TAG_W(TAG_W+9),.MAG_W(73)) u_round (
        .clk(clk),.rst_n(rst_n),.in_valid(secondary_round ? secondary_valid : (op==QUANT && v7)),
        .in_value(secondary_round ? {{23{secondary_product[72]}},secondary_product} : {{32{evaluated7[63]}},evaluated7}),
        .in_shift(residual ? legacy_shift : $signed({1'b0,shift})),
        .in_tag(secondary_round ? secondary_tag : {evaluated7[63],c7.fault,c7.tag}),
        .out_valid(round_valid),.out_result8(round8),.out_result32(round32),
        .out_overflow32(round_overflow),.out_tag(round_tag),.busy(round_busy));
    wire signed [63:0] symmetric8=round8==-8'sd128 ? -64'sd127 : $signed(round8);
    wire signed [63:0] symmetric16=round_overflow ? (round_tag[TAG_W+8] ? -64'sd32767 : 64'sd32767) :
        round32>32'sd32767 ? 64'sd32767 : round32 < -32'sd32767 ? -64'sd32767 : $signed(round32);
    assign out_valid=rst_n && ((residual || quantized) ? round_valid : v7);
    assign out_tag=(residual || quantized) ? round_tag[TAG_W-1:0] : c7.tag;
    assign out_fault=(residual || quantized) ? round_tag[TAG_W+:8] : c7.fault;
    assign out_value=residual ? $signed(round8) : quantized ?
        (output_dtype==1 ? symmetric8 : symmetric16) : evaluated7;
`ifndef SYNTHESIS
    always @(posedge clk) if (rst_n && secondary_request && !secondary_ready)
        $fatal(1,"Secondary product lane overrun");
`endif
endmodule
