`timescale 1ns/1ps
// Frozen ResNet GAP: signed40 wrapping SUM followed by the shared exact
// requantizer. This profile needs no mean, LN, Softmax, LUT, or row cache.
module npu_resnet_gap_engine (
 input logic clk,rst_n,
 input logic cmd_valid,output wire cmd_ready,input logic [31:0] cmd_tag,
 input logic [4:0] cmd_op,
 input logic [31:0] cmd_input_base,cmd_output_base,cmd_element_count,cmd_input_stride,
 input logic [2:0] cmd_input_dtype,cmd_output_dtype,
 input logic cmd_resnet_legacy,input logic signed [31:0] cmd_resnet_multiplier,
 input logic signed [7:0] cmd_resnet_shift,
 output wire mem_req_valid,input logic mem_req_ready,output wire mem_req_write,
 output wire [31:0] mem_req_addr,output wire [1:0] mem_req_size,
 output wire [63:0] mem_req_wdata,
 input logic mem_rsp_valid,output wire mem_rsp_ready,
 input logic signed [63:0] mem_rsp_rdata,input logic [3:0] mem_rsp_fault,
 output wire rsp_valid,input logic rsp_ready,output logic [31:0] rsp_tag,
 output logic [7:0] rsp_fault,output wire busy,
 output wire math_req_valid,input logic math_req_ready,output wire [2:0] math_req_op,
 output wire signed [63:0] math_req_a,math_req_b,output wire [6:0] math_req_shift,
 input logic math_rsp_valid,output wire math_rsp_ready,
 input logic signed [63:0] math_rsp_result,input logic [1:0] math_rsp_fault,
 output wire quant_req_valid,input logic quant_req_ready,output wire quant_req_residual,
 output wire signed [39:0] quant_req_value,
 output wire signed [63:0] quant_req_multiplier_a,quant_req_multiplier_b,
 output wire signed [7:0] quant_req_b,quant_req_shift,
 input logic quant_rsp_valid,output wire quant_rsp_ready,
 input logic signed [7:0] quant_rsp_result
);
 localparam [7:0] F_COMMAND=8'h01,F_DTYPE=8'h02,F_ADDRESS=8'h03,F_OVERLAP=8'h08;
 typedef enum logic [3:0] {
  IDLE,RANGE_SEND,RANGE_WAIT,CHECK_RANGE,CHECK_OVERLAP,
  READ_SEND,READ_WAIT,QUANT_SEND,QUANT_WAIT,WRITE_SEND,WRITE_WAIT,RESPONSE
 } state_t;
 state_t state;
 logic [31:0] input_base,output_base,element_count,input_stride,index,input_ptr,range_span;
 logic [32:0] input_end;
 logic signed [39:0] sum;
 logic signed [31:0] multiplier;
 logic signed [7:0] shift,result;
 wire [32:0] range_end={1'b0,input_base}+{1'b0,range_span}+33'd1;
 wire [32:0] output_end={1'b0,output_base}+33'd1;
 wire writing=state==WRITE_SEND || state==WRITE_WAIT;
 assign cmd_ready=rst_n && state==IDLE;
 assign busy=state!=IDLE;
 assign rsp_valid=rst_n && state==RESPONSE;
 assign mem_req_valid=rst_n && (state==READ_SEND || state==WRITE_SEND);
 assign mem_req_write=writing;
 assign mem_req_addr=writing ? output_base : input_ptr;
 assign mem_req_size=2'd0;
 assign mem_req_wdata={{56{result[7]}},result};
 assign mem_rsp_ready=rst_n && (state==READ_WAIT || state==WRITE_WAIT);
 assign math_req_valid=rst_n && state==RANGE_SEND;
 assign math_req_op=3'd1;
 assign math_req_a=$signed({32'd0,element_count}-64'd1);
 assign math_req_b=$signed({32'd0,input_stride});
 assign math_req_shift=7'd0;
 assign math_rsp_ready=rst_n && state==RANGE_WAIT;
 assign quant_req_valid=rst_n && state==QUANT_SEND;
 assign quant_req_residual=1'b0;
 assign quant_req_value=sum;
 assign quant_req_multiplier_a={{32{multiplier[31]}},multiplier};
 assign quant_req_multiplier_b=64'sd0;
 assign quant_req_b=8'sd0;
 assign quant_req_shift=shift;
 assign quant_rsp_ready=rst_n && state==QUANT_WAIT;
 task automatic fail(input logic [7:0] code);
  begin rsp_fault<=code;state<=RESPONSE;end
 endtask
 always_ff @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;rsp_tag<=0;rsp_fault<=0;
   input_base<=0;output_base<=0;element_count<=0;input_stride<=0;
   index<=0;input_ptr<=0;range_span<=0;input_end<=0;
   sum<=0;multiplier<=0;shift<=0;result<=0;
  end else case(state)
   IDLE:if(cmd_valid)begin
    rsp_tag<=cmd_tag;rsp_fault<=0;
    input_base<=cmd_input_base;output_base<=cmd_output_base;
    element_count<=cmd_element_count;input_stride<=cmd_input_stride;
    multiplier<=cmd_resnet_multiplier;shift<=cmd_resnet_shift;
    input_ptr<=cmd_input_base;index<=0;sum<=0;
    if(cmd_op!=5'd20 || cmd_resnet_legacy!==1'b1 || cmd_element_count==0)
     fail(F_COMMAND);
    else if(cmd_input_dtype!=3'd1 || cmd_output_dtype!=3'd1)fail(F_DTYPE);
    else if(cmd_element_count>1 && cmd_input_stride==0)fail(F_ADDRESS);
    else state<=RANGE_SEND;
   end
   RANGE_SEND:if(math_req_ready)state<=RANGE_WAIT;
   RANGE_WAIT:if(math_rsp_valid)begin
    if(math_rsp_fault!=0 || (|math_rsp_result[63:32]))fail(F_ADDRESS);
    else begin range_span<=math_rsp_result[31:0];state<=CHECK_RANGE;end
   end
   CHECK_RANGE:if(range_end>33'h100000000)fail(F_ADDRESS);
    else begin input_end<=range_end;state<=CHECK_OVERLAP;end
   CHECK_OVERLAP:if({1'b0,output_base}<input_end && {1'b0,input_base}<output_end)
    fail(F_OVERLAP);
    else state<=READ_SEND;
   READ_SEND:if(mem_req_ready)state<=READ_WAIT;
   READ_WAIT:if(mem_rsp_valid)begin
    if(mem_rsp_fault!=0)fail(8'h20|{4'd0,mem_rsp_fault});
    else begin
     // Assignment truncation preserves the original signed40 wrap per term.
     sum<=sum+$signed({{32{mem_rsp_rdata[7]}},mem_rsp_rdata[7:0]});
     if(index==element_count-1'b1)state<=QUANT_SEND;
     else begin index<=index+1'b1;input_ptr<=input_ptr+input_stride;state<=READ_SEND;end
    end
   end
   QUANT_SEND:if(quant_req_ready)state<=QUANT_WAIT;
   QUANT_WAIT:if(quant_rsp_valid)begin result<=quant_rsp_result;state<=WRITE_SEND;end
   WRITE_SEND:if(mem_req_ready)state<=WRITE_WAIT;
   WRITE_WAIT:if(mem_rsp_valid)begin
    if(mem_rsp_fault!=0)fail(8'h20|{4'd0,mem_rsp_fault});
    else state<=RESPONSE;
   end
   RESPONSE:if(rsp_ready)state<=IDLE;
   default:fail(F_COMMAND);
  endcase
 end
endmodule
