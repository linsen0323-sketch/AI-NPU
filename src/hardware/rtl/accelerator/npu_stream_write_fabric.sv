`timescale 1ns/1ps
module npu_stream_write_fabric #(
 parameter integer CLIENTS=2,parameter integer OWNER_W=(CLIENTS>1 ? $clog2(CLIENTS) : 1)
)(
 input wire clk,rst_n,
 input wire [CLIENTS-1:0] c_cmd_valid,output reg [CLIENTS-1:0] c_cmd_ready,
 input wire [CLIENTS*32-1:0] c_cmd_addr,c_cmd_bytes,
 input wire [CLIENTS-1:0] c_valid,output reg [CLIENTS-1:0] c_ready,
 input wire [CLIENTS*64-1:0] c_data,input wire [CLIENTS*8-1:0] c_keep,input wire [CLIENTS-1:0] c_last,
 output reg [CLIENTS-1:0] c_rsp_valid,input wire [CLIENTS-1:0] c_rsp_ready,output wire [3:0] c_fault,
 output wire cmd_valid,input wire cmd_ready,output wire [31:0] cmd_addr,cmd_bytes,
 output wire valid,input wire ready,output wire [63:0] data,output wire [7:0] keep,output wire last,
 input wire rsp_valid,output wire rsp_ready,input wire [3:0] fault,output wire idle
);
 reg owned,selected,found;
 reg [OWNER_W-1:0] owner,round_robin,next_owner;
 integer candidate;
 assign cmd_valid=rst_n&&selected&&!owned&&c_cmd_valid[owner];
 assign cmd_addr=c_cmd_addr[owner*32+:32];
 assign cmd_bytes=c_cmd_bytes[owner*32+:32];
 assign valid=owned&&c_valid[owner];assign data=c_data[owner*64+:64];
 assign keep=c_keep[owner*8+:8];assign last=c_last[owner];
 assign rsp_ready=owned&&c_rsp_ready[owner];assign c_fault=fault;assign idle=!owned&&!selected;
 always @*begin
  c_cmd_ready=0;c_ready=0;c_rsp_valid=0;
  found=0;next_owner=round_robin;
  for(integer n=0;n<CLIENTS;n=n+1)begin
   candidate=round_robin+n;if(candidate>=CLIENTS)candidate=candidate-CLIENTS;
   if(!found&&c_cmd_valid[candidate])begin found=1;next_owner=OWNER_W'(candidate);end
  end
  if(selected&&!owned)c_cmd_ready[owner]=cmd_ready;
  if(owned)begin c_ready[owner]=ready;c_rsp_valid[owner]=rsp_valid;end
 end
 always @(posedge clk)begin
  if(!rst_n)begin owned<=0;selected<=0;owner<=0;round_robin<=0;end
  else begin
   if(!selected&&!owned&&found)begin owner<=next_owner;selected<=1;end
   if(cmd_valid&&cmd_ready)owned<=1;
   if(owned&&rsp_valid&&rsp_ready)begin owned<=0;selected<=0;round_robin<=owner==CLIENTS-1 ? 0 : owner+1'b1;end
  end
 end
endmodule
