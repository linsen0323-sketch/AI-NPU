`timescale 1ns/1ps
// One held scalar transaction at a time. All clients and the transport must
// share reset: resetting this arbiter alone would lose an accepted AXI owner.
module npu_scalar_fabric #(
 parameter integer CLIENTS = 4,
 parameter integer OWNER_BITS = (CLIENTS <= 1) ? 1 : $clog2(CLIENTS)
) (
 input logic clk, rst_n,
 input logic [CLIENTS-1:0] c_req_valid,
 output logic [CLIENTS-1:0] c_req_ready,
 input logic [CLIENTS-1:0] c_req_write,
 input logic [CLIENTS*32-1:0] c_req_addr,
 input logic [CLIENTS*2-1:0] c_req_size,
 input logic [CLIENTS*64-1:0] c_req_wdata,
 output logic [CLIENTS-1:0] c_rsp_valid,
 input logic [CLIENTS-1:0] c_rsp_ready,
 output logic [CLIENTS*64-1:0] c_rsp_rdata,
 output logic [CLIENTS*4-1:0] c_rsp_fault,
 output logic req_valid, input logic req_ready,
 output logic req_write, output logic [31:0] req_addr,
 output logic [1:0] req_size, output logic [63:0] req_wdata,
 input logic rsp_valid, output logic rsp_ready,
 input logic signed [63:0] rsp_rdata, input logic [3:0] rsp_fault,
 output logic idle, output logic [OWNER_BITS-1:0] active_owner
);
 typedef enum logic [1:0] {SELECT, SEND, RESPONSE} state_t;
 state_t state;
 logic [OWNER_BITS-1:0] owner, next_owner;
 logic [OWNER_BITS-1:0] chosen;
 logic [CLIENTS-1:0] eligible,grant;
 logic selected_write;
 logic [31:0] selected_addr;
 logic [1:0] selected_size;
 logic [63:0] selected_wdata;
 logic found;
 // Prefer the first request at/above next_owner, then wrap to the first.
 // Fixed prefix reductions avoid dynamically indexing the request vector.
 for(genvar g=0;g<CLIENTS;g=g+1)begin:g_grant
  assign eligible[g]=c_req_valid[g] && next_owner<=OWNER_BITS'(g);
  if(g==0)begin:g_first
   assign grant[g]=eligible[g] || (!(|eligible) && c_req_valid[g]);
  end else begin:g_later
   assign grant[g]=(eligible[g] && !(|eligible[g-1:0])) ||
     (!(|eligible) && c_req_valid[g] && !(|c_req_valid[g-1:0]));
  end
 end
 always_comb begin
  chosen='0;found=|c_req_valid;
  selected_write=0;selected_addr=0;selected_size=0;selected_wdata=0;
  for(integer n=0; n<CLIENTS; n=n+1) begin
   chosen=chosen | (OWNER_BITS'(n) & {OWNER_BITS{grant[n]}});
   selected_write=selected_write | (c_req_write[n] && grant[n]);
   selected_addr=selected_addr | (c_req_addr[n*32+:32] & {32{grant[n]}});
   selected_size=selected_size | (c_req_size[n*2+:2] & {2{grant[n]}});
   selected_wdata=selected_wdata | (c_req_wdata[n*64+:64] & {64{grant[n]}});
  end
  c_req_ready=0; c_rsp_valid=0; c_rsp_rdata=0; c_rsp_fault=0;
  if(rst_n && state == SELECT) c_req_ready=grant;
  req_valid=rst_n && state == SEND;
  rsp_ready=0;
  for(integer n=0;n<CLIENTS;n=n+1) begin
   c_rsp_rdata[n*64+:64]=rsp_rdata;
   c_rsp_fault[n*4+:4]=rsp_fault;
   if(rst_n && state==RESPONSE && owner==OWNER_BITS'(n)) begin
    c_rsp_valid[n]=rsp_valid;rsp_ready=c_rsp_ready[n];
   end
  end
  idle=rst_n && state == SELECT && !(|c_req_valid);
  active_owner=owner;
 end
 always_ff @(posedge clk) begin
  if(!rst_n) begin
   state<=SELECT; owner<=0; next_owner<=0;
   req_write<=0; req_addr<=0; req_size<=0; req_wdata<=0;
  end else case(state)
   SELECT: if(found) begin
    owner<=chosen;
    req_write<=selected_write;req_addr<=selected_addr;
    req_size<=selected_size;req_wdata<=selected_wdata;
    state<=SEND;
   end
   SEND: if(req_ready) state<=RESPONSE;
   RESPONSE: if(rsp_valid && rsp_ready) begin
    next_owner <= (int'(owner) == CLIENTS-1) ? '0 : owner+1'b1;
    state<=SELECT;
   end
   default: state<=SELECT;
  endcase
 end
endmodule
