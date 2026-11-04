`timescale 1ns/1ps
// One lane/cycle Conv epilogue. Each input already includes the checked K
// partial sum. Separate operand capture, bias sum and result checks. Preserve
// INT64 bias overflow, profile-1 signed40 wrap, complete
// signed40*32 products, one RNE, and profile-2's checked INT32 output domain.
// A tag identifies the local output-tile channel and spatial position, so the
// shared PE may execute the next spatial dot while these lanes finish.
// There is no output backpressure: the caller owns the output tile until busy
// clears and drains every result before starting that tile's DDR write.
module npu_conv_epilogue #(
 parameter integer TAG_W=10,parameter bit EXTERNAL_PIPE=1'b0
) (
 input wire clk,rst_n,input wire in_valid,input wire in_legacy,
 input wire signed [63:0] in_raw,in_bias,in_multiplier,in_shift,
 input wire [TAG_W-1:0] in_tag,
 output wire out_valid,output wire [31:0] out_data,
 output wire [7:0] out_fault,output wire [TAG_W-1:0] out_tag,
 output wire busy,
 output wire pipe_req_valid,
 output wire signed [39:0] pipe_req_value,
 output wire signed [63:0] pipe_req_multiplier,
 output wire signed [7:0] pipe_req_shift,
 output wire [TAG_W+8:0] pipe_req_tag,
 input wire pipe_rsp_valid,
 input wire signed [7:0] pipe_rsp_result8,
 input wire signed [31:0] pipe_rsp_result32,
 input wire pipe_rsp_overflow32,
 input wire [TAG_W+8:0] pipe_rsp_tag,
 input wire pipe_busy
);
 localparam integer PRODUCT_TAG_W=TAG_W+17, ROUND_TAG_W=TAG_W+9;
 logic operand_valid,sum_valid,bias_valid;
 logic signed [63:0] operand_raw,operand_bias,operand_multiplier,operand_shift;
 logic operand_legacy;
 logic [TAG_W-1:0] operand_tag;
 logic signed [64:0] bias_sum_q;
 logic signed [63:0] sum_multiplier;
 logic signed [7:0] sum_shift;
 logic sum_legacy;
 logic [TAG_W-1:0] sum_tag;
 logic [7:0] parameter_fault_q;
 wire signed [64:0] bias_sum={operand_raw[63],operand_raw}+{operand_bias[63],operand_bias};
 wire bias_overflow=bias_sum_q[64]!=bias_sum_q[63];
 wire bias_outside_i32=bias_sum_q[64:31]!={34{bias_sum_q[31]}};
 wire bias_is_i32_min=bias_sum_q[31]&&bias_sum_q[30:0]==31'd0;
 wire multiplier_outside_i32=operand_multiplier[63:31]!={33{operand_multiplier[31]}};
 wire multiplier_bad=multiplier_outside_i32||
     (!operand_legacy&&(operand_multiplier[63]||operand_multiplier==64'sd0));
 wire shift_bad=!operand_legacy&&(operand_shift[63:6]!=58'd0||operand_shift[5:0]==6'd63);
 logic signed [39:0] biased_value;
 logic signed [63:0] multiplier;
 logic [PRODUCT_TAG_W-1:0] bias_tag;
 logic [7:0] input_fault;
 wire product_valid,product_busy;
 wire signed [72:0] product;
 wire [PRODUCT_TAG_W-1:0] product_tag;
 wire signed [7:0] rounded8;
 wire signed [31:0] rounded32;
 wire rounded_overflow,round_busy;
 wire [ROUND_TAG_W-1:0] round_tag;
 wire legacy=round_tag[8];
 always_comb begin
  input_fault=0;
  if(bias_overflow)input_fault=8'h04;
  else if(!sum_legacy&&(bias_outside_i32||bias_is_i32_min))input_fault=8'h04;
  else input_fault=parameter_fault_q;
 end
 // Valid bits carry ownership; payload registers need no reset or enable.
 // This keeps partial-sum overflow out of the coefficient-load enable path.
 always_ff @(posedge clk)begin
  operand_raw<=in_raw;operand_bias<=in_bias;
  operand_multiplier<=in_multiplier;operand_shift<=in_shift;
  operand_legacy<=in_legacy;operand_tag<=in_tag;
  bias_sum_q<=bias_sum;sum_multiplier<=operand_multiplier;
  sum_shift<=operand_shift[7:0];sum_legacy<=operand_legacy;sum_tag<=operand_tag;
  parameter_fault_q<=(multiplier_bad||shift_bad)?8'h05:8'd0;
 end
 always_ff @(posedge clk)begin
  if(!rst_n)begin operand_valid<=0;sum_valid<=0;bias_valid<=0;biased_value<=0;multiplier<=0;bias_tag<=0;end
  else begin
   operand_valid<=in_valid;sum_valid<=operand_valid;bias_valid<=sum_valid;
   if(sum_valid)begin
    // Legacy requant wraps AFTER its checked signed64 bias addition. For
    // profile-2 the accepted signed32 bias result is exactly sign extended.
    biased_value<=bias_sum_q[39:0];multiplier<=sum_multiplier;
    bias_tag<={sum_tag,sum_legacy,input_fault,sum_shift};
   end
  end
 end
 assign pipe_req_valid=EXTERNAL_PIPE&&bias_valid;
 assign pipe_req_value=biased_value;
 assign pipe_req_multiplier=multiplier;
 assign pipe_req_shift=$signed(bias_tag[7:0]);
 assign pipe_req_tag=bias_tag[PRODUCT_TAG_W-1:8];
 generate if(EXTERNAL_PIPE)begin:g_external_pipe
  assign out_valid=pipe_rsp_valid;
  assign rounded8=pipe_rsp_result8;
  assign rounded32=pipe_rsp_result32;
  assign rounded_overflow=pipe_rsp_overflow32;
  assign round_tag=pipe_rsp_tag;
  assign product_busy=pipe_busy;
  assign round_busy=1'b0;
 end else begin:g_local_pipe
 npu_resnet_product_pipe #(.TAG_W(PRODUCT_TAG_W)) u_product (
  .clk(clk),.rst_n(rst_n),.in_valid(bias_valid),.in_ready(),.in_residual(1'b0),
  .in_value(biased_value),.in_multiplier_a(multiplier),.in_multiplier_b(64'sd0),.in_b(8'sd0),
  .in_tag(bias_tag),.out_valid(product_valid),.out_product(product),.out_tag(product_tag),.busy(product_busy));
 npu_resnet_round_pipe #(.TAG_W(ROUND_TAG_W),.MAG_W(73)) u_round (
  .clk(clk),.rst_n(rst_n),.in_valid(product_valid),.in_value({{23{product[72]}},product}),
  .in_shift($signed(product_tag[7:0])),.in_tag(product_tag[PRODUCT_TAG_W-1:8]),
  .out_valid(out_valid),.out_result8(rounded8),.out_result32(rounded32),
  .out_overflow32(rounded_overflow),.out_tag(round_tag),.busy(round_busy));
 end endgenerate
 assign out_data=legacy?{24'd0,rounded8}:rounded32;
 assign out_fault=round_tag[7:0]!=0?round_tag[7:0]:(!legacy&&rounded_overflow)?8'h04:8'd0;
 assign out_tag=round_tag[ROUND_TAG_W-1:9];
 assign busy=operand_valid||sum_valid||bias_valid||product_busy||round_busy;
endmodule
