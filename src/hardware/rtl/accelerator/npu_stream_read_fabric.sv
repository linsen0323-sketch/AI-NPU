`timescale 1ns/1ps
// Descriptor ownership lasts through its terminal response, including error
// drain. A stalled descriptor and every accepted stream beat stay owned.
module npu_stream_read_fabric #(
 parameter integer CLIENTS=2,parameter integer OWNER_W=(CLIENTS>1 ? $clog2(CLIENTS) : 1),
 parameter bit ENABLE_STALL_DIAG=1'b1
)(
 output wire [CLIENTS-1:0] stall_other_owner,
 input wire clk,rst_n,
 input wire [CLIENTS-1:0] c_cmd_valid,output reg [CLIENTS-1:0] c_cmd_ready,
 input wire [CLIENTS*32-1:0] c_cmd_addr,c_cmd_bytes,
 output reg [CLIENTS-1:0] c_valid,input wire [CLIENTS-1:0] c_ready,
 output wire [63:0] c_data,output wire [7:0] c_keep,output wire c_last,
 output reg [CLIENTS-1:0] c_rsp_valid,input wire [CLIENTS-1:0] c_rsp_ready,
 output wire [3:0] c_fault,
 output wire cmd_valid,input wire cmd_ready,output wire [31:0] cmd_addr,cmd_bytes,
 input wire valid,output wire ready,input wire [63:0] data,input wire [7:0] keep,input wire last,
 input wire rsp_valid,output wire rsp_ready,input wire [3:0] fault,output wire idle
);
 reg owned,selected;
 reg [OWNER_W-1:0] owner,next_owner,round_robin;
 reg found;
 integer candidate;
 always @*begin
  found=0;next_owner=round_robin;
  for(integer n=0;n<CLIENTS;n=n+1)begin
   candidate=round_robin+n;if(candidate>=CLIENTS)candidate=candidate-CLIENTS;
   if(!found&&c_cmd_valid[candidate])begin found=1;next_owner=OWNER_W'(candidate);end
  end
  c_cmd_ready=0;c_valid=0;c_rsp_valid=0;
  if(selected&&!owned)c_cmd_ready[owner]=cmd_ready;
  if(owned)begin c_valid[owner]=valid;c_rsp_valid[owner]=rsp_valid;end
 end
 assign cmd_valid=rst_n&&selected&&!owned&&c_cmd_valid[owner];
 assign cmd_addr=c_cmd_addr[owner*32+:32];assign cmd_bytes=c_cmd_bytes[owner*32+:32];
 assign c_data=data;assign c_keep=keep;assign c_last=last;assign c_fault=fault;
 assign ready=owned&&c_ready[owner];assign rsp_ready=owned&&c_rsp_ready[owner];
 assign idle=!owned&&!selected;
 always @(posedge clk)begin
  if(!rst_n)begin owned<=0;selected<=0;owner<=0;round_robin<=0;end
  else begin
   if(!owned&&!selected&&found)begin selected<=1;owner<=next_owner;end
   if(cmd_valid&&cmd_ready)owned<=1;
   if(owned&&rsp_valid&&rsp_ready)begin
    owned<=0;selected<=0;round_robin<=owner==CLIENTS-1 ? 0 : owner+1'b1;
   end
  end
 end
// STALL_DIAGNOSTIC_BEGIN
 generate if(ENABLE_STALL_DIAG)begin:g_stall_diag
 for(genvar d=0;d<CLIENTS;d=d+1)begin:g_stall_observe
  assign stall_other_owner[d]=rst_n&&c_cmd_valid[d]&&(owned||selected)&&owner!=OWNER_W'(d);
 end
 end else begin:g_no_stall_diag
  assign stall_other_owner=0;
 end endgenerate
// STALL_DIAGNOSTIC_END
endmodule
