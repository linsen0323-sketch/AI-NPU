`timescale 1ns/1ps
// Exactly ONE shared array. Ownership spans first..last..result, including
// empty input gaps. busy on each client describes pipeline activity only.
module npu_shared_pe #(
 parameter integer CLIENTS = 2,
 parameter integer ACC_W = 64,
 parameter integer PHYSICAL_OUTPUTS = 32,
 parameter bit DSP_PACKING = 1'b1,
 parameter bit ENABLE_PE_SPATIAL4 = 1'b0,
 parameter bit ENABLE_WEIGHT_PRELOAD = 1'b0,
 parameter bit FACTOR_PARTIAL_VALID = 1'b0,
 parameter integer OWNER_BITS = (CLIENTS <= 1) ? 1 : $clog2(CLIENTS),
 parameter bit ENABLE_PERF_COUNTERS=1'b1,
 parameter bit SHARED_WEIGHT_SELECT=1'b0
) (
 input logic clk, rst_n,
 input logic [CLIENTS-1:0] c_req_valid,
 output logic [CLIENTS-1:0] c_req_ready,
 input logic [CLIENTS-1:0] c_req_a16, c_req_first, c_req_last,
 input logic [CLIENTS*128-1:0] c_req_act,
 input logic [CLIENTS-1:0] c_req_spatial4,
 input logic [CLIENTS*512-1:0] c_req_act4,
 input logic [CLIENTS*2048-1:0] c_req_weight,
 output logic [CLIENTS-1:0] c_rsp_valid,
 input logic [CLIENTS-1:0] c_rsp_ready,
 output logic [CLIENTS*2048-1:0] c_rsp_acc,
 output logic [CLIENTS*2-1:0] c_rsp_fault,
 output logic [CLIENTS-1:0] c_pipeline_busy,
 // Abandon only an unfinished context AFTER the client's vector FIFO and
 // read tokens drain. A presented vector is never revoked by this interface.
 input logic [CLIENTS-1:0] c_abandon_valid,
 output logic [CLIENTS-1:0] c_abandon_ready,
 output logic idle, output logic [OWNER_BITS-1:0] active_owner,
 output wire [63:0] perf_vectors,perf_wait,
 input logic [CLIENTS*2-1:0] c_req_weight_group
);
 typedef enum logic [2:0] {SELECT, DOT, LAST_WAIT, ERROR_DRAIN, RESULT} state_t;
 state_t state;
 logic [OWNER_BITS-1:0] owner, next_owner;
 logic started, dot_a16, dot_spatial4, found, framing_ok;
 wire request_spatial4=ENABLE_PE_SPATIAL4 && PHYSICAL_OUTPUTS==32 && c_req_spatial4[owner];
 integer chosen, candidate;
 logic pe_valid, pe_ready, pe_busy, pe_out_valid, pe_overflow;
 logic [2047:0] pe_acc, result_acc;
 logic [1:0] result_fault;
 always_comb begin
  found=0; chosen=0; candidate=0;
  for(integer n=0;n<CLIENTS;n=n+1) begin
   candidate=int'(next_owner)+n;
   if(candidate>=CLIENTS) candidate=candidate-CLIENTS;
   if(!found && c_req_valid[candidate] && !c_abandon_valid[candidate]) begin
    found=1; chosen=candidate;
   end
  end
  framing_ok = started ? (!c_req_first[owner] && c_req_a16[owner]==dot_a16 && request_spatial4==dot_spatial4)
                       : c_req_first[owner];
  c_req_ready=0; c_rsp_valid=0; c_rsp_acc=0; c_rsp_fault=0;
  c_pipeline_busy=0; c_abandon_ready={CLIENTS{rst_n}}; pe_valid=0;
  if(state!=SELECT) c_abandon_ready[owner]=0;
  if(rst_n && state==DOT) begin
   // Invalid framing is consumed locally, then reported after compute drain.
   c_req_ready[owner]=framing_ok ? pe_ready : !pe_busy;
   pe_valid=c_req_valid[owner] && framing_ok;
   c_abandon_ready[owner]=!c_req_valid[owner] && !pe_busy;
  end
  if(rst_n && state!=SELECT) c_pipeline_busy[owner]=pe_busy;
  // Payload is broadcast; VALID alone carries ownership. A runtime part-select
  // on the 4096-bit response otherwise synthesizes a wide barrel shifter.
  for(integer n=0;n<CLIENTS;n=n+1) begin
   c_rsp_acc[n*2048+:2048]=result_acc;
   c_rsp_fault[n*2+:2]=result_fault;
   if(rst_n && state==RESULT && owner==OWNER_BITS'(n)) c_rsp_valid[n]=1;
  end
  idle=rst_n && state==SELECT && !found && !pe_busy;
  active_owner=owner;
 end
 npu_pe_8x32 #(.SHARED_WEIGHT_SELECT(SHARED_WEIGHT_SELECT),.ACC_W(ACC_W),.PHYSICAL_OUTPUTS(PHYSICAL_OUTPUTS),.DSP_PACKING(DSP_PACKING),.ENABLE_PE_SPATIAL4(ENABLE_PE_SPATIAL4),.ENABLE_WEIGHT_PRELOAD(ENABLE_WEIGHT_PRELOAD),.FACTOR_PARTIAL_VALID(FACTOR_PARTIAL_VALID),.QUALIFIED_ACC_OUTPUT(1)) u_array (
  .clk(clk),.rst_n(rst_n),.in_valid(pe_valid),.in_ready(pe_ready),
  .in_a16(c_req_a16[owner]),.in_first(c_req_first[owner]),.in_last(c_req_last[owner]),
  .act(c_req_act[int'(owner)*128 +:128]),
  .in_spatial4(request_spatial4),.act4(c_req_act4[int'(owner)*512+:512]),
  .weight(c_req_weight[int'(owner)*2048 +:2048]),.weight_group(c_req_weight_group[int'(owner)*2+:2]),
  .busy(pe_busy),.out_valid(pe_out_valid),.acc(pe_acc),.overflow(pe_overflow)
 );
 always_ff @(posedge clk) begin
  if(!rst_n) begin
   state<=SELECT; owner<=0; next_owner<=0; started<=0; dot_a16<=0;dot_spatial4<=0;
   result_acc<=0; result_fault<=0;
  end else case(state)
   SELECT: if(found) begin
    owner<=OWNER_BITS'(chosen); started<=0; result_fault<=0; state<=DOT;
   end
   DOT: begin
    if(c_req_valid[owner] && c_req_ready[owner]) begin
     if(!framing_ok) begin result_fault<=2'b01; result_acc<=0; state<=ERROR_DRAIN; end
     else begin
      started<=1; dot_a16<=c_req_a16[owner];dot_spatial4<=request_spatial4;
      if(c_req_last[owner]) state<=LAST_WAIT;
     end
    end else if(c_abandon_valid[owner] && c_abandon_ready[owner]) begin
     next_owner<=(int'(owner)==CLIENTS-1) ? '0 : owner+1'b1;
     started<=0; state<=SELECT;
    end
   end
   LAST_WAIT: if(pe_out_valid) begin
    result_acc<=pe_acc; result_fault<={pe_overflow,1'b0}; state<=RESULT;
   end
   ERROR_DRAIN: if(!pe_busy) state<=RESULT;
   RESULT: if(c_rsp_ready[owner]) begin
    next_owner<=(int'(owner)==CLIENTS-1) ? '0 : owner+1'b1;
    state<=SELECT; started<=0;
   end
   default: state<=SELECT;
  endcase
 end
 // Observe the client admission boundary, as the pipeline did originally.
 // CLIENTS=1 is bit/cycle-identical; multi-client wait counts any blocked client.
 generate if(ENABLE_PERF_COUNTERS)begin:g_perf_counters
  reg [63:0] vectors_q,wait_q;
  always @(posedge clk)begin
   if(!rst_n)begin vectors_q<=0;wait_q<=0;end
   else begin
    if(|(c_req_valid&c_req_ready))vectors_q<=vectors_q+1'b1;
    if(|(c_req_valid&~c_req_ready))wait_q<=wait_q+1'b1;
   end
  end
  assign perf_vectors=vectors_q;assign perf_wait=wait_q;
 end else begin:g_no_perf_counters
  assign perf_vectors=0;assign perf_wait=0;
 end endgenerate
endmodule
