`timescale 1ns/1ps
// Bit-exact affine copy, including repeated scalar reads (stride_a=0).
// Outer transpose/slice/concat/split/expand/nearest loops use plan_iterator.
module npu_copy_engine #(
 parameter bit EXTERNAL_MATH = 1'b0
) (
 input logic clk,rst_n,input logic cmd_valid,output logic cmd_ready,
 input logic [31:0] cmd_tag,cmd_input_base,cmd_output_base,cmd_count,
 input logic [31:0] cmd_input_stride,cmd_output_stride,
 input logic [2:0] cmd_input_dtype,cmd_output_dtype,
 output logic mem_req_valid,input logic mem_req_ready,output logic mem_req_write,
 output logic [31:0] mem_req_addr,output logic [1:0] mem_req_size,
 output logic [63:0] mem_req_wdata,input logic mem_rsp_valid,output logic mem_rsp_ready,
 input logic signed [63:0] mem_rsp_rdata,input logic [3:0] mem_rsp_fault,
 output logic rsp_valid,input logic rsp_ready,output logic [31:0] rsp_tag,
 output logic [7:0] rsp_fault,output logic [31:0] rsp_completed,output logic busy,
 output logic math_req_valid,input logic math_req_ready,
 output logic [2:0] math_req_op,output logic signed [63:0] math_req_a,math_req_b,
 output logic [6:0] math_req_shift,input logic math_rsp_valid,output logic math_rsp_ready,
 input logic signed [63:0] math_rsp_result,input logic [1:0] math_rsp_fault
);
 typedef enum logic [3:0] {IDLE,CHECK,SPAN_REQ,SPAN_WAIT,SPAN_SUM,SPAN_CHECK,RANGE_CHECK,
  READ_REQ,READ_WAIT,WRITE_REQ,WRITE_WAIT,RESPONSE} state_t;
 state_t state;
 logic [31:0] a,y,count,as_,ys,index;
 logic [2:0] adtype,ydtype;logic [3:0] awidth,ywidth,width;
 logic [32:0] aend,yend;
 logic span_lane,math_ready,math_valid;
 logic signed [63:0] math_result;logic [1:0] math_fault;
 logic [32:0] span_base_width;
 logic [63:0] span_product;
 logic [64:0] end_check;
 always_comb begin
  awidth=(adtype>=1 && adtype<=4) ? (4'd1<<(adtype-1'b1)) : 0;
  ywidth=(ydtype>=1 && ydtype<=4) ? (4'd1<<(ydtype-1'b1)) : 0;
  width=span_lane ? ywidth : awidth;
  cmd_ready=rst_n && state==IDLE;busy=state!=IDLE;rsp_valid=rst_n && state==RESPONSE;
  mem_req_valid=rst_n && (state==READ_REQ || state==WRITE_REQ);
  mem_req_write=state==WRITE_REQ;mem_req_addr=state==WRITE_REQ ? y : a;
  mem_req_size=(state==WRITE_REQ || state==WRITE_WAIT) ? ydtype[1:0]-2'd1 : adtype[1:0]-2'd1;
  mem_rsp_ready=rst_n && (state==READ_WAIT || state==WRITE_WAIT);
 end
 npu_math_port #(.EXTERNAL_MATH(EXTERNAL_MATH)) u_span (.clk(clk),.rst_n(rst_n),
  .req_valid(rst_n && state==SPAN_REQ),.req_ready(math_ready),.req_op(3'd1),
  .req_a($signed({32'd0,count})-64'sd1),.req_b($signed({32'd0,span_lane ? ys : as_})),
  .req_shift(7'd0),.rsp_valid(math_valid),.rsp_ready(rst_n && state==SPAN_WAIT),
  .rsp_result(math_result),.rsp_fault(math_fault),
  .math_req_valid(math_req_valid),.math_req_ready(math_req_ready),
  .math_req_op(math_req_op),.math_req_a(math_req_a),.math_req_b(math_req_b),
  .math_req_shift(math_req_shift),.math_rsp_valid(math_rsp_valid),.math_rsp_ready(math_rsp_ready),
  .math_rsp_result(math_rsp_result),.math_rsp_fault(math_rsp_fault));
 task automatic fail(input logic [7:0] f);begin rsp_fault<=f;state<=RESPONSE;end endtask
 always_ff @(posedge clk) begin
  if(!rst_n) begin
   state<=IDLE;a<=0;y<=0;count<=0;as_<=0;ys<=0;index<=0;adtype<=0;ydtype<=0;
   aend<=0;yend<=0;span_lane<=0;rsp_tag<=0;rsp_fault<=0;rsp_completed<=0;mem_req_wdata<=0;
  end else case(state)
   IDLE: if(cmd_valid) begin
    a<=cmd_input_base;y<=cmd_output_base;count<=cmd_count;as_<=cmd_input_stride;
    ys<=cmd_output_stride;adtype<=cmd_input_dtype;ydtype<=cmd_output_dtype;rsp_tag<=cmd_tag;rsp_fault<=0;
    rsp_completed<=0;index<=0;span_lane<=0;state<=CHECK;
   end
   CHECK: if(count==0 || adtype<1 || adtype>4 || ydtype<1 || ydtype>4 ||
    (adtype!=ydtype && (adtype<3 || ydtype<3)) || ys<ywidth ||
    ((a|as_)&({28'd0,awidth}-32'd1))!=0 ||
    ((y|ys)&({28'd0,ywidth}-32'd1))!=0) fail(8'h01);
    else state<=SPAN_REQ;
   SPAN_REQ: if(math_ready) state<=SPAN_WAIT;
   SPAN_WAIT: if(math_valid) begin
    if(math_fault!=0 || math_result<0) fail(8'h03);
    else begin
     span_base_width<={1'b0,span_lane ? y : a}+{29'd0,width};
     span_product<=$unsigned(math_result);state<=SPAN_SUM;
    end
   end
   // These payloads are produced before their consuming states on every span.
   SPAN_SUM: begin
    end_check<={32'd0,span_base_width}+{1'b0,span_product};state<=SPAN_CHECK;
   end
   SPAN_CHECK: begin
    if(end_check>65'h100000000) fail(8'h03);
    else if(!span_lane) begin aend<=end_check[32:0];span_lane<=1;state<=SPAN_REQ;end
    else begin yend<=end_check[32:0];state<=RANGE_CHECK;end
   end
   RANGE_CHECK: if({1'b0,a}<yend && {1'b0,y}<aend && !(a==y && as_==ys && adtype==ydtype)) fail(8'h08);
    else state<=READ_REQ;
   READ_REQ: if(mem_req_ready) state<=READ_WAIT;
   READ_WAIT: if(mem_rsp_valid) begin
    if(mem_rsp_fault!=0) fail({4'h2,mem_rsp_fault});
    else if(ydtype==3 && (mem_rsp_rdata < -64'sd2147483648 || mem_rsp_rdata > 64'sd2147483647))
     fail(8'h04);
    else begin mem_req_wdata<=mem_rsp_rdata;state<=WRITE_REQ;end
   end
   WRITE_REQ: if(mem_req_ready) state<=WRITE_WAIT;
   WRITE_WAIT: if(mem_rsp_valid) begin
    if(mem_rsp_fault!=0) fail({4'h2,mem_rsp_fault});
    else begin
     rsp_completed<=rsp_completed+1'b1;
     if(index+32'd1==count) state<=RESPONSE;
     else begin index<=index+1'b1;a<=a+as_;y<=y+ys;state<=READ_REQ;end
    end
   end
   RESPONSE: if(rsp_ready) state<=IDLE;
   default: fail(8'h01);
  endcase
 end
endmodule
