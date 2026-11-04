`timescale 1ns/1ps
// NPUPLN1 affine outer-loop expansion. No private PE. A downstream terminal
// response (including write drain) is required for every admitted inner job.
module npu_plan_iterator #(
 parameter bit EXTERNAL_MATH = 1'b0,
 // The graph backend owns its record until the terminal response handshake.
 // Standalone callers retain the ordinary snapshot-on-command contract.
 parameter bit BORROW_RECORD = 1'b0
) (
 input logic clk,rst_n,
 input logic cmd_valid,output logic cmd_ready,
 input logic [4095:0] cmd_record,
 input logic [31:0] cmd_constants_base,cmd_constants_bytes,
 input logic [31:0] cmd_workspace_base,cmd_workspace_bytes,
 input logic cancel_valid,output logic cancel_ready,
 output logic inner_valid,input logic inner_ready,
 output logic [4095:0] inner_record,
 input logic inner_rsp_valid,output logic inner_rsp_ready,
 input logic [7:0] inner_rsp_fault,
 output logic rsp_valid,input logic rsp_ready,
 output logic [7:0] rsp_fault,output logic [31:0] rsp_completed,
 output logic busy,
 output logic math_req_valid,input logic math_req_ready,
 output logic [2:0] math_req_op,
 output logic signed [63:0] math_req_a,math_req_b,
 output logic [6:0] math_req_shift,
 input logic math_rsp_valid,output logic math_rsp_ready,
 input logic signed [63:0] math_rsp_result,input logic [1:0] math_rsp_fault
);
 typedef enum logic [3:0] {IDLE,CHECK,RESOLVE,RESOLVE_CHECK,RESOLVE_COMMIT,LOOP_CHECK,MUL_SEND,MUL_WAIT,
  SPAN_CHECK,SPAN_COMMIT,DISPATCH,WAIT_INNER,ADVANCE,ADJUST_ADDRESS,RESPONSE} state_t;
 state_t state;
 logic [4095:0] record;
 // Immutable affine fields are narrow wire aliases of one owned record.
 // Only relocation results, loop counters and rewinds are stored separately;
 // runtime selections cover rank/axis/lane, not arbitrary record bit offsets.
 logic [2:0] engine_q;
 logic command_bad;
 logic [31:0] pointer_raw[0:9],resolved_pointer[0:8];
 logic [31:0] resolved_scratch;
 logic [31:0] dimension[0:7];
 logic [31:0] stride[0:2][0:7];
 logic [31:0] const_base,const_bytes,work_base,work_bytes;
 logic [31:0] address[0:2],index[0:7],rewind[0:2][0:7];
 logic [32:0] span[0:2];
 logic [3:0] pointer_index,rank,axis;
 logic [1:0] lane;
 logic cancelled;
 logic rewinding;
 logic [31:0] pointer_word,stride_word,dimension_word,rewind_word,advance_delta;
 logic [31:0] advance_address;
 logic [32:0] pointer_address,region_end;
 logic [32:0] pointer_address_q,region_end_q;
 logic pointer_bad_q;
 logic [33:0] span_sum,span_sum_q,address_sum;
 logic [31:0] rewind_q;
 logic span_bad_q;
 logic math_ready,math_valid;
 logic signed [63:0] math_result;
 logic [1:0] math_fault;
 generate
  if(BORROW_RECORD) begin : g_borrow_record
   // cmd_record must remain stable through rsp_valid && rsp_ready, including
   // cancellation and downstream drain. npu_graph_plan_backend guarantees it.
   assign record=cmd_record;
  end else begin : g_snapshot_record
   // Payload needs no reset: CHECK is reached only after the complete write.
   always_ff @(posedge clk)
    if(rst_n && cmd_valid && cmd_ready) record<=cmd_record;
  end
  // Aliases of the one immutable record, not extra registered copies of its
  // pointer/dimension/stride fields. Only relocated pointers need storage.
  for(genvar j=0;j<10;j=j+1) begin : g_pointer_alias
   assign pointer_raw[j]=record[(8+j)*32+:32];
  end
  for(genvar j=0;j<8;j=j+1) begin : g_affine_alias
   assign dimension[j]=record[(24+j)*32+:32];
   for(genvar p=0;p<3;p=p+1) begin : g_lane
    assign stride[p][j]=record[(32+p*8+j)*32+:32];
   end
  end
 endgenerate
 always_comb begin
  cmd_ready=rst_n && state==IDLE; busy=state!=IDLE;
  cancel_ready=rst_n; rsp_valid=rst_n && state==RESPONSE;
  inner_valid=rst_n && state==DISPATCH;
  inner_rsp_ready=rst_n && state==WAIT_INNER;
  inner_record=record;
  for(integer p=0;p<9;p=p+1) inner_record[(8+p)*32+:32]=resolved_pointer[p];
  // Word 17 is a scalar multiplier for elementwise jobs, a pointer only for
  // convolution. Do not overwrite a non-convolution multiplier with scratch.
  if(engine_q==5) inner_record[17*32+:32]=resolved_scratch;
  for(integer p=0;p<3;p=p+1) inner_record[(8+p)*32+:32]=address[p];
  pointer_word=0;
  for(integer p=0;p<10;p=p+1)
   pointer_word=pointer_word | (pointer_raw[p] & {32{pointer_index==4'(p)}});
  pointer_address={1'b0,pointer_word[30:0]}+
   (pointer_word[31] ? {1'b0,const_base} : {1'b0,work_base});
  region_end=pointer_word[31] ? ({1'b0,const_base}+{1'b0,const_bytes}) :
                               ({1'b0,work_base}+{1'b0,work_bytes});
  // Distinct lane/axis decodes form parallel muxes, including the zero default.
  dimension_word=0;stride_word=0;rewind_word=0;
  for(integer j=0;j<8;j=j+1)begin
   dimension_word=dimension_word | (dimension[j] & {32{axis==4'(j)}});
   for(integer p=0;p<3;p=p+1)begin
    stride_word=stride_word | (stride[p][j] & {32{lane==2'(p) && axis==4'(j)}});
    rewind_word=rewind_word | (rewind[p][j] & {32{lane==2'(p) && axis==4'(j)}});
   end
  end
  // One shared modulo-2^32 address adder. LOOP_CHECK already proves that all
  // visited addresses fit; a rewind only returns to an earlier visited point.
  advance_delta=rewinding ? ~rewind_word : stride_word;
  advance_address=address[lane]+advance_delta+{31'd0,rewinding};
  span_sum={1'b0,span[lane]}+{2'd0,math_result[31:0]};
  // Separate the two carry chains. lane/axis/address stay fixed from the
  // accepted math response through SPAN_COMMIT; no extra request is issued.
  address_sum={2'd0,address[lane]}+span_sum_q;
 end
 npu_math_port #(.EXTERNAL_MATH(EXTERNAL_MATH)) u_span (
  .clk(clk),.rst_n(rst_n),.req_valid(rst_n && state==MUL_SEND),.req_ready(math_ready),
  .req_op(3'd1),.req_a($signed({32'd0,(dimension_word-32'd1)})),
  .req_b($signed({32'd0,stride_word})),.req_shift(7'd0),
  .rsp_valid(math_valid),.rsp_ready(rst_n && state==MUL_WAIT),
  .rsp_result(math_result),.rsp_fault(math_fault),
  .math_req_valid(math_req_valid),.math_req_ready(math_req_ready),
  .math_req_op(math_req_op),.math_req_a(math_req_a),.math_req_b(math_req_b),
  .math_req_shift(math_req_shift),.math_rsp_valid(math_rsp_valid),.math_rsp_ready(math_rsp_ready),
  .math_rsp_result(math_rsp_result),.math_rsp_fault(math_rsp_fault)
 );
 task automatic fail(input logic [7:0] f);
  begin rsp_fault<=f; state<=RESPONSE; end
 endtask
 always_ff @(posedge clk) begin
  if(!rst_n) begin
   state<=IDLE; const_base<=0;const_bytes<=0;work_base<=0;work_bytes<=0;
   engine_q<=0;command_bad<=0;
   pointer_index<=0;rank<=0;axis<=0;lane<=0;cancelled<=0;rewinding<=0;
   resolved_scratch<=0;rsp_fault<=0;rsp_completed<=0;
   for(integer p=0;p<3;p=p+1) begin
    address[p]<=0;span[p]<=0;
    for(integer j=0;j<8;j=j+1) rewind[p][j]<=0;
   end
   for(integer j=0;j<9;j=j+1) resolved_pointer[j]<=0;
   for(integer j=0;j<8;j=j+1) index[j]<=0;
  end else begin
   if(cancel_valid && state!=IDLE && state!=RESPONSE) cancelled<=1;
   case(state)
    IDLE: if(cmd_valid) begin
     const_base<=cmd_constants_base;const_bytes<=cmd_constants_bytes;
     work_base<=cmd_workspace_base;work_bytes<=cmd_workspace_bytes;
     engine_q<=cmd_record[0+:3];
     command_bad<=cmd_record[0+:32]<1 || cmd_record[0+:32]>6 || cmd_record[0+:32]==3 ||
      cmd_record[7*32+:32]>8 ||
      cmd_record[4*32+:32]<1 || cmd_record[4*32+:32]>4 ||
      cmd_record[5*32+:32]<1 || cmd_record[5*32+:32]>4 ||
      cmd_record[6*32+:32]<1 || cmd_record[6*32+:32]>4;
     rank<=cmd_record[7*32+:4];
     pointer_index<=0;axis<=0;lane<=0;
     cancelled<=0;rsp_fault<=0;rsp_completed<=0;
     for(integer p=0;p<3;p=p+1) span[p]<=0;
     for(integer j=0;j<8;j=j+1) index[j]<=0;
     state<=CHECK;
    end
    CHECK: begin
     if(cancelled || cancel_valid) fail(8'he1);
     else if(command_bad || record[10*32+31] ||
       ({1'b0,const_base}+{1'b0,const_bytes})>33'h100000000 ||
       ({1'b0,work_base}+{1'b0,work_bytes})>33'h100000000 ||
       const_bytes==0 || work_bytes==0) fail(8'h01);
     else state<=RESOLVE;
    end
    RESOLVE: begin
     // End the pointer selection/addition path at payload registers. Keep
     // pointer_index fixed until commit so all results belong to one word.
     // Reset only needs to reset state: these are fully written before use.
     pointer_address_q<=pointer_address;
     region_end_q<=region_end;
     state<=RESOLVE_CHECK;
    end
    RESOLVE_CHECK: begin
     // Keep the exclusive-end comparison and overflow decision off the
     // enables of the resolved-pointer/address arrays. An end of 2^32 is
     // allowed, but the relocated pointer itself must fit in 32 bits.
     pointer_bad_q<=pointer_address_q>=region_end_q || pointer_address_q[32] ||
                    region_end_q>33'h100000000;
     state<=RESOLVE_COMMIT;
    end
    RESOLVE_COMMIT: begin
     // As before, cancellation is latched throughout relocation and checked
     // at LOOP_CHECK; address faults retain priority while resolving words.
     if(pointer_bad_q) fail(8'h03);
     else begin
      if(pointer_index<9)begin
       for(integer p=0;p<9;p=p+1)
        if(pointer_index==4'(p))resolved_pointer[p]<=pointer_address_q[31:0];
      end
      else resolved_scratch<=pointer_address_q[31:0];
      for(integer p=0;p<3;p=p+1)
       if(pointer_index==4'(p))address[p]<=pointer_address_q[31:0];
      if(pointer_index==9 || (pointer_index==8 && engine_q!=5)) begin axis<=0;lane<=0;state<=LOOP_CHECK;end
      else begin pointer_index<=pointer_index+1'b1;state<=RESOLVE;end
     end
    end
    LOOP_CHECK: begin
     if(cancelled || cancel_valid) fail(8'he1);
     else if(axis==rank) state<=DISPATCH;
     else if(dimension_word==0) fail(8'h01);
     else state<=MUL_SEND;
    end
    MUL_SEND: if(math_ready) state<=MUL_WAIT;
    MUL_WAIT: if(math_valid) begin
     // Snapshot the response before the shared math fabric changes owner.
     // These payload registers need no reset: only the following two states
     // consume them, and reset returns directly to IDLE.
     rewind_q<=math_result[31:0];
     span_sum_q<=span_sum;
     span_bad_q<=math_fault!=0 || math_result[63:32]!=0 || span_sum[33:32]!=0;
     state<=SPAN_CHECK;
    end
    SPAN_CHECK: begin
     // Register the remaining carry/overflow check before it can drive the
     // enables of the rewind array. Cancellation remains latched throughout
     // these stages and is handled at the existing loop/response boundaries.
     span_bad_q<=span_bad_q || address_sum[33:32]!=0;
     state<=SPAN_COMMIT;
    end
    SPAN_COMMIT: begin
     if(span_bad_q) fail(8'h03);
     else begin
      for(integer p=0;p<3;p=p+1)if(lane==2'(p))begin
       span[p]<=span_sum_q[32:0];
       for(integer j=0;j<8;j=j+1)
        if(axis==4'(j))rewind[p][j]<=rewind_q;
      end
      if(lane==2) begin lane<=0;axis<=axis+1'b1;state<=LOOP_CHECK;end
      else begin lane<=lane+1'b1;state<=MUL_SEND;end
     end
    end
    // Exposed VALID is retained even if cancellation arrives while stalled.
    DISPATCH: if(inner_ready) state<=WAIT_INNER;
    WAIT_INNER: if(inner_rsp_valid) begin
     if(inner_rsp_fault!=0) fail(inner_rsp_fault);
     else if(cancelled || cancel_valid) fail(8'he1);
     else begin
      rsp_completed<=rsp_completed+1'b1;
      if(rank==0) state<=RESPONSE;
      else begin axis<=rank-1'b1;state<=ADVANCE;end
     end
    end
    ADVANCE: begin
     if(cancelled || cancel_valid) fail(8'he1);
     else if(index[axis]+32'd1<dimension_word) begin
      for(integer j=0;j<8;j=j+1)
       if(axis==4'(j))index[j]<=index[j]+1'b1;
      lane<=0;rewinding<=0;state<=ADJUST_ADDRESS;
     end else begin
      for(integer j=0;j<8;j=j+1)
       if(axis==4'(j))index[j]<=0;
      lane<=0;rewinding<=1;state<=ADJUST_ADDRESS;
     end
    end
    ADJUST_ADDRESS: begin
     if(cancelled || cancel_valid) fail(8'he1);
     else begin
      for(integer p=0;p<3;p=p+1)
       if(lane==2'(p))address[p]<=advance_address;
      if(lane!=2) lane<=lane+1'b1;
      else if(!rewinding) state<=DISPATCH;
      else if(axis==0) state<=RESPONSE;
      else begin axis<=axis-1'b1;state<=ADVANCE;end
     end
    end
    RESPONSE: if(rsp_ready) state<=IDLE;
    default: fail(8'h01);
   endcase
  end
 end
endmodule
