`timescale 1ns/1ps
// One scalar access, with two immutable RO windows and one mutable RW window.
// This is a logical byte permission check; transport performs lane/strobe maps.
module npu_scalar_guard (
 input logic clk,rst_n,
 input logic [31:0] model_base,model_bytes,plan_base,plan_bytes,workspace_base,workspace_bytes,
 input logic req_valid,output logic req_ready,input logic req_write,
 input logic [31:0] req_addr,input logic [1:0] req_size,input logic [63:0] req_wdata,
 output logic rsp_valid,input logic rsp_ready,output logic signed [63:0] rsp_rdata,output logic [3:0] rsp_fault,
 output logic mem_req_valid,input logic mem_req_ready,output logic mem_req_write,
 output logic [31:0] mem_req_addr,output logic [1:0] mem_req_size,output logic [63:0] mem_req_wdata,
 input logic mem_rsp_valid,output logic mem_rsp_ready,input logic signed [63:0] mem_rsp_rdata,
 input logic [3:0] mem_rsp_fault,output logic idle
);
 typedef enum logic [2:0] {IDLE,CHECK_ACCESS,SEND,WAIT_RESPONSE,REJECT} state_t;
 state_t state;
 logic [32:0] transfer_end,model_end,plan_end,workspace_end;
 logic [2:0] start_inside;
 logic allowed;
 always_comb begin
  allowed=transfer_end<=33'h100000000 &&
   ((start_inside[2] && transfer_end<=workspace_end && workspace_end<=33'h100000000) ||
    (!mem_req_write && ((start_inside[0] && transfer_end<=model_end && model_end<=33'h100000000) ||
                       (start_inside[1] && transfer_end<=plan_end && plan_end<=33'h100000000))));
  req_ready=rst_n && state==IDLE;idle=rst_n && state==IDLE && !req_valid;
  mem_req_valid=rst_n && state==SEND;
  mem_rsp_ready=rst_n && state==WAIT_RESPONSE && rsp_ready;
  rsp_valid=rst_n && (state==REJECT || (state==WAIT_RESPONSE && mem_rsp_valid));
  rsp_rdata=state==REJECT ? 64'sd0 : mem_rsp_rdata;
  rsp_fault=state==REJECT ? 4'b0010 : mem_rsp_fault;
 end
 // Capture the permission window with the request, independently of later
 // upstream window changes. CHECK_ACCESS consumes only this request snapshot.
 always_ff @(posedge clk) begin
  if(state==IDLE&&req_valid)begin
   transfer_end<={1'b0,req_addr}+(33'd1<<req_size);
   model_end<={1'b0,model_base}+{1'b0,model_bytes};plan_end<={1'b0,plan_base}+{1'b0,plan_bytes};
   workspace_end<={1'b0,workspace_base}+{1'b0,workspace_bytes};
   start_inside[0]<=req_addr>=model_base;start_inside[1]<=req_addr>=plan_base;
   start_inside[2]<=req_addr>=workspace_base;
  end
 end
 always_ff @(posedge clk) begin
  if(!rst_n) begin state<=IDLE;mem_req_write<=0;mem_req_addr<=0;mem_req_size<=0;mem_req_wdata<=0;end
  else case(state)
   IDLE: if(req_valid) begin
    mem_req_write<=req_write;mem_req_addr<=req_addr;mem_req_size<=req_size;
    mem_req_wdata<=req_wdata;state<=CHECK_ACCESS;
   end
   CHECK_ACCESS:state<=allowed ? SEND : REJECT;
   SEND: if(mem_req_ready) state<=WAIT_RESPONSE;
   WAIT_RESPONSE: if(mem_rsp_valid && rsp_ready) state<=IDLE;
   REJECT: if(rsp_ready) state<=IDLE;
   default: state<=IDLE;
  endcase
 end
endmodule
