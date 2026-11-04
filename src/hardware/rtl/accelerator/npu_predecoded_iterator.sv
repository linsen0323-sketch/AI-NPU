`timescale 1ns/1ps
// PS-normalized NPUPLN1 affine iteration. Rewinds/spans are precomputed by
// the checked compiler: no runtime multiply, wide-math client or span RAM.
// Accepted inner jobs still own the record until their terminal response.
module npu_predecoded_iterator #(
 parameter bit BORROW_RECORD=1'b0,
 parameter bit ENABLE_RESIZE_BATCH=1'b0,
 parameter bit ENABLE_AFFINE_COALESCE=1'b0,
 parameter bit REUSE_AXIS_SCAN=1'b0
) (
 input logic clk,rst_n,
 input logic cmd_valid,output logic cmd_ready,
 input logic [4095:0] cmd_record,
 input logic [31:0] cmd_constants_base,cmd_constants_bytes,
 input logic [31:0] cmd_workspace_base,cmd_workspace_bytes,
 input logic cancel_valid,output logic cancel_ready,
 output logic inner_valid,input logic inner_ready,
 output logic [4095:0] inner_record,
 output logic inner_copy_repeat2,
 output logic inner_copy_transpose2,
 input logic [31:0] inner_copy_completed,
 input logic inner_rsp_valid,output logic inner_rsp_ready,
 input logic [7:0] inner_rsp_fault,
 output logic rsp_valid,input logic rsp_ready,
 output logic [7:0] rsp_fault,output logic [31:0] rsp_completed,
 output logic busy
);
 typedef enum logic [3:0] {IDLE,CHECK,RESOLVE,RESOLVE_CHECK,RESOLVE_COMMIT,
  AXIS_CHECK,DISPATCH,WAIT_INNER,ADVANCE,ADJUST_ADDRESS,RESPONSE,ADVANCE_PREP,AXIS_PREP,ADJUST_PREP,BATCH_CHECK} state_t;
 state_t state;
 logic [4095:0] record;
 logic [2:0] engine_q;
 logic command_bad,cancelled,rewinding,pointer_bad_q;
 logic [31:0] const_base,const_bytes,work_base,work_bytes;
 logic [31:0] pointer_raw[0:9],resolved_pointer[0:8],resolved_scratch;
 logic [31:0] dimension[0:7],stride[0:2][0:7],rewind[0:2][0:7];
 logic [31:0] address[0:2],index[0:7];
 logic [3:0] pointer_index,rank,axis;
 logic [1:0] lane;
 logic [31:0] pointer_word,pointer_span,dimension_word;
 logic [31:0] axis_step[0:2];
 logic [7:0] axis_payload_nonzero;
 logic [31:0] advance_delta,advance_address,next_index_q,dimension_q,advance_delta_q;
 logic [32:0] pointer_address,region_end,pointer_address_q,region_end_q;
 logic [33:0] outer_last,outer_last_q;
 logic axes_bad,axes_bad_q;
 logic copy_batch;
 logic copy_transpose;
 wire [32:0] transpose_a_end={1'b0,resolved_pointer[0]}+33'd59136;
 wire [32:0] transpose_y_end={1'b0,resolved_pointer[2]}+33'd59136;
 // Two adjacent columns of a checked [11,1344] -> [1344,11] mapping.
 // The whole-operator envelopes prevent writing a future source column.
 wire transpose_candidate_parallel=ENABLE_AFFINE_COALESCE && engine_q==4 &&
  record[0+:32]==4 && record[3*32+:32]==13 && record[2*32+:32]==0 && rank==1 &&
  record[4*32+:32]==3 && record[5*32+:32]==3 && record[6*32+:32]==3 &&
  record[64*32+:32]==11 && record[65*32+:32]==5376 && record[66*32+:32]==0 && record[67*32+:32]==4 &&
  dimension[0]==1344 && stride[0][0]==4 && stride[1][0]==0 && stride[2][0]==44 &&
  rewind[0][0]==5372 && rewind[1][0]==0 && rewind[2][0]==59092 &&
  record[115*32+:32]==5372 && record[116*32+:32]==0 && record[117*32+:32]==59092 &&
  record[119*32+:32]==1344 && resolved_pointer[0][2:0]==0 && resolved_pointer[2][2:0]==0 &&
  transpose_a_end<=33'h100000000 && transpose_y_end<=33'h100000000 &&
  transpose_a_end<=(record[8*32+31] ? ({1'b0,const_base}+{1'b0,const_bytes}) :
     ({1'b0,work_base}+{1'b0,work_bytes})) &&
  transpose_y_end<=({1'b0,work_base}+{1'b0,work_bytes}) &&
  (transpose_a_end<={1'b0,resolved_pointer[2]} || transpose_y_end<={1'b0,resolved_pointer[0]});
 wire row16=dimension[2]==16;
 wire [32:0] batch_a_end={1'b0,resolved_pointer[0]}+(row16 ? 33'd131072 : 33'd65536);
 wire [32:0] batch_y_end={1'b0,resolved_pointer[2]}+(row16 ? 33'd524288 : 33'd262144);
 // This is a checked AFF1 address pattern, not a graph-index switch. Only
 // collapse the innermost source row; outer row/channel order stays intact.
 wire batch_candidate_parallel=ENABLE_RESIZE_BATCH && engine_q==4 &&
  record[0+:32]==4 && record[3*32+:32]==18 && record[2*32+:32]==0 && rank==3 &&
  record[4*32+:32]==3 && record[5*32+:32]==3 && record[6*32+:32]==3 &&
  record[64*32+:32]==2 && record[65*32+:32]==0 &&
  record[66*32+:32]==0 && record[67*32+:32]==4 &&
  dimension[0]==2048 && dimension[1]==2 && (dimension[2]==8 || row16) &&
  stride[0][0]==(row16 ? 64 : 32) && stride[0][1]==0 && stride[0][2]==4 &&
  record[40*32+:256]==0 && record[99*32+:256]==0 && record[116*32+:32]==0 &&
  stride[2][0]==(row16 ? 256 : 128) && stride[2][1]==(row16 ? 128 : 64) && stride[2][2]==8 &&
  rewind[0][0]==(row16 ? 131008 : 65504) && rewind[0][1]==0 && rewind[0][2]==(row16 ? 60 : 28) &&
  rewind[2][0]==(row16 ? 524032 : 262016) && rewind[2][1]==(row16 ? 128 : 64) && rewind[2][2]==(row16 ? 120 : 56) &&
  record[119*32+:32]==(row16 ? 65536 : 32768) &&
  record[115*32+:32]==(row16 ? 131068 : 65532) && record[117*32+:32]==(row16 ? 524280 : 262136) &&
  resolved_pointer[0][2:0]==0 && resolved_pointer[2][2:0]==0 &&
  batch_a_end<=33'h100000000 && batch_y_end<=33'h100000000 &&
  batch_a_end<=(record[8*32+31] ? ({1'b0,const_base}+{1'b0,const_bytes}) :
                                             ({1'b0,work_base}+{1'b0,work_bytes})) &&
  batch_y_end<=({1'b0,work_base}+{1'b0,work_bytes}) &&
  (batch_a_end<={1'b0,resolved_pointer[2]} || batch_y_end<={1'b0,resolved_pointer[0]});

 // Optional resource sharing across the existing AXIS_PREP/AXIS_CHECK
 // clocks. PREP selects strides, CHECK selects complemented rewinds through
 // the already-required axis_step muxes. No new state or command latency.
 logic batch_axes_ok,transpose_axes_ok;
 logic [31:0] expected_dim,expected_stride_a,expected_stride_y;
 logic [31:0] expected_rewind_a,expected_rewind_y;
 always_comb begin
  expected_dim=0;expected_stride_a=0;expected_stride_y=0;
  expected_rewind_a=0;expected_rewind_y=0;
  case(axis)
   0:begin expected_dim=2048;expected_stride_a=row16 ? 64:32;
    expected_stride_y=row16 ? 256:128;expected_rewind_a=row16 ? 131008:65504;
    expected_rewind_y=row16 ? 524032:262016;end
   1:begin expected_dim=2;expected_stride_y=row16 ? 128:64;expected_rewind_y=row16 ? 128:64;end
   2:begin expected_dim=row16 ? 16:8;expected_stride_a=4;expected_stride_y=8;
    expected_rewind_a=row16 ? 60:28;expected_rewind_y=row16 ? 120:56;end
   default:;
  endcase
 end
 wire batch_axis_match=axis>=3 ||
  ((rewinding || dimension_word==expected_dim) &&
   axis_step[0]==(rewinding ? ~expected_rewind_a:expected_stride_a) &&
   axis_step[1]==(rewinding ? 32'hffffffff:32'd0) &&
   axis_step[2]==(rewinding ? ~expected_rewind_y:expected_stride_y));
 wire transpose_axis_match=axis!=0 ||
  ((rewinding || dimension_word==1344) &&
   axis_step[0]==(rewinding ? ~32'd5372:32'd4) &&
   axis_step[1]==(rewinding ? 32'hffffffff:32'd0) &&
   axis_step[2]==(rewinding ? ~32'd59092:32'd44));
 // In CHECK the selected steps are complemented rewinds. Empty axes must
 // contain all-zero raw rewind payload, hence all-one selected steps.
 wire absent_rewind_bad=axis>=rank &&
  (!(&axis_step[0]) || !(&axis_step[1]) || !(&axis_step[2]));
 wire transpose_common=ENABLE_AFFINE_COALESCE && engine_q==4 &&
  record[0+:32]==4 && record[3*32+:32]==13 && record[2*32+:32]==0 && rank==1 &&
  record[4*32+:32]==3 && record[5*32+:32]==3 && record[6*32+:32]==3 &&
  record[64*32+:32]==11 && record[65*32+:32]==5376 && record[66*32+:32]==0 && record[67*32+:32]==4 &&
  record[115*32+:32]==5372 && record[116*32+:32]==0 && record[117*32+:32]==59092 &&
  record[119*32+:32]==1344 && resolved_pointer[0][2:0]==0 && resolved_pointer[2][2:0]==0 &&
  transpose_a_end<=33'h100000000 && transpose_y_end<=33'h100000000 &&
  transpose_a_end<=(record[8*32+31] ? ({1'b0,const_base}+{1'b0,const_bytes}) :
     ({1'b0,work_base}+{1'b0,work_bytes})) &&
  transpose_y_end<=({1'b0,work_base}+{1'b0,work_bytes}) &&
  (transpose_a_end<={1'b0,resolved_pointer[2]} || transpose_y_end<={1'b0,resolved_pointer[0]});
 wire batch_common=ENABLE_RESIZE_BATCH && engine_q==4 &&
  record[0+:32]==4 && record[3*32+:32]==18 && record[2*32+:32]==0 && rank==3 &&
  record[4*32+:32]==3 && record[5*32+:32]==3 && record[6*32+:32]==3 &&
  record[64*32+:32]==2 && record[65*32+:32]==0 && record[66*32+:32]==0 && record[67*32+:32]==4 &&
  record[116*32+:32]==0 && record[119*32+:32]==(row16 ? 65536:32768) &&
  record[115*32+:32]==(row16 ? 131068:65532) && record[117*32+:32]==(row16 ? 524280:262136) &&
  resolved_pointer[0][2:0]==0 && resolved_pointer[2][2:0]==0 &&
  batch_a_end<=33'h100000000 && batch_y_end<=33'h100000000 &&
  batch_a_end<=(record[8*32+31] ? ({1'b0,const_base}+{1'b0,const_bytes}) :
     ({1'b0,work_base}+{1'b0,work_bytes})) &&
  batch_y_end<=({1'b0,work_base}+{1'b0,work_bytes}) &&
  (batch_a_end<={1'b0,resolved_pointer[2]} || batch_y_end<={1'b0,resolved_pointer[0]});
 wire transpose_candidate=REUSE_AXIS_SCAN ? transpose_common&&transpose_axes_ok : transpose_candidate_parallel;
 wire batch_candidate=REUSE_AXIS_SCAN ? batch_common&&batch_axes_ok : batch_candidate_parallel;
 generate
  if(BORROW_RECORD)begin:g_borrow_record
   // Backend holds cmd_record stable through the terminal response handshake.
   assign record=cmd_record;
  end else begin:g_snapshot_record
   always_ff @(posedge clk)
    if(rst_n && cmd_valid && cmd_ready)record<=cmd_record;
  end
  for(genvar p=0;p<10;p=p+1)begin:g_pointer_alias
   assign pointer_raw[p]=record[(8+p)*32+:32];
  end
  for(genvar j=0;j<8;j=j+1)begin:g_affine_alias
   assign dimension[j]=record[(24+j)*32+:32];
   assign axis_payload_nonzero[j]=|{dimension[j],stride[0][j],stride[1][j],stride[2][j],
     rewind[0][j],rewind[1][j],rewind[2][j]};
   for(genvar p=0;p<3;p=p+1)begin:g_lane
    assign stride[p][j]=record[(32+p*8+j)*32+:32];
    assign rewind[p][j]=record[(91+p*8+j)*32+:32];
   end
  end
 endgenerate
 always_comb begin
  cmd_ready=rst_n && state==IDLE;busy=state!=IDLE;
  cancel_ready=rst_n;rsp_valid=rst_n && state==RESPONSE;
  inner_valid=rst_n && state==DISPATCH;
  inner_rsp_ready=rst_n && state==WAIT_INNER;
  inner_record=record;
  inner_copy_repeat2=copy_batch;
  inner_copy_transpose2=copy_transpose;
  if(copy_batch)inner_record[64*32+:32]=dimension[2]<<1;
  if(copy_transpose)inner_record[64*32+:32]=32'd22;
  for(integer p=0;p<9;p=p+1)inner_record[(8+p)*32+:32]=resolved_pointer[p];
  if(engine_q==5)inner_record[17*32+:32]=resolved_scratch;
  for(integer p=0;p<3;p=p+1)inner_record[(8+p)*32+:32]=address[p];
  pointer_word=pointer_index<10 ? pointer_raw[pointer_index] : 32'd0;
  pointer_span=0;
  for(integer p=0;p<3;p=p+1)
   pointer_span=pointer_span | (record[(115+p)*32+:32] & {32{pointer_index==4'(p)}});
  pointer_address={1'b0,pointer_word[30:0]}+
   (pointer_word[31] ? {1'b0,const_base} : {1'b0,work_base});
  region_end=pointer_word[31] ? ({1'b0,const_base}+{1'b0,const_bytes}) :
                               ({1'b0,work_base}+{1'b0,work_bytes});
  outer_last={1'b0,pointer_address}+{2'd0,pointer_span};
  dimension_word=dimension[axis[2:0]];
  // Select within each lane before selecting the lane. Complement rewind at
  // the leaves so one mux network serves forward and backward movement.
  for(integer p=0;p<3;p=p+1)
   axis_step[p]=rewinding ? ~rewind[p][axis[2:0]] : stride[p][axis[2:0]];
  axes_bad=axis<rank ? dimension_word<2 : REUSE_AXIS_SCAN ?
   |{dimension_word,axis_step[0],axis_step[1],axis_step[2]} : axis_payload_nonzero[axis[2:0]];
  // The PS proves rewind arithmetic. PL checks the resulting outer envelope;
  // every actual inner scalar/burst access is separately guarded downstream.
  advance_delta=axis_step[lane];
  advance_address=address[lane]+advance_delta_q+{31'd0,rewinding};
 end
 task automatic fail(input logic [7:0] f);
  begin rsp_fault<=f;state<=RESPONSE;end
 endtask
 always_ff @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;engine_q<=0;command_bad<=0;cancelled<=0;rewinding<=0;
   const_base<=0;const_bytes<=0;work_base<=0;work_bytes<=0;
   pointer_index<=0;rank<=0;axis<=0;lane<=0;resolved_scratch<=0;next_index_q<=0;
   dimension_q<=0;advance_delta_q<=0;
   copy_batch<=0;copy_transpose<=0;
     if(REUSE_AXIS_SCAN)begin batch_axes_ok<=1;transpose_axes_ok<=1;rewinding<=0;end
   rsp_fault<=0;rsp_completed<=0;
   for(integer p=0;p<9;p=p+1)resolved_pointer[p]<=0;
   for(integer p=0;p<3;p=p+1)address[p]<=0;
   for(integer j=0;j<8;j=j+1)index[j]<=0;
  end else begin
   if(cancel_valid && state!=IDLE && state!=RESPONSE)cancelled<=1;
   case(state)
    IDLE:if(cmd_valid)begin
     const_base<=cmd_constants_base;const_bytes<=cmd_constants_bytes;
     work_base<=cmd_workspace_base;work_bytes<=cmd_workspace_bytes;
     engine_q<=cmd_record[0+:3];rank<=cmd_record[7*32+:4];
     command_bad<=cmd_record[0+:32]<1 || cmd_record[0+:32]>6 || cmd_record[0+:32]==3 ||
      cmd_record[7*32+:32]>8 || cmd_record[118*32+:32]!=32'h31464641 ||
      cmd_record[119*32+:32]==0 ||
      (cmd_record[7*32+:32]==0 && cmd_record[119*32+:32]!=1) ||
      cmd_record[4*32+:32]<1 || cmd_record[4*32+:32]>4 ||
      cmd_record[5*32+:32]<1 || cmd_record[5*32+:32]>4 ||
      cmd_record[6*32+:32]<1 || cmd_record[6*32+:32]>4;
     pointer_index<=0;axis<=0;lane<=0;cancelled<=0;rsp_fault<=0;rsp_completed<=0;
     copy_batch<=0;copy_transpose<=0;
     if(REUSE_AXIS_SCAN)begin batch_axes_ok<=1;transpose_axes_ok<=1;rewinding<=0;end
     for(integer j=0;j<8;j=j+1)index[j]<=0;
     state<=CHECK;
    end
    CHECK:begin
     if(cancelled || cancel_valid)fail(8'he1);
     else if(command_bad || record[10*32+31] ||
      ({1'b0,const_base}+{1'b0,const_bytes})>33'h100000000 ||
      ({1'b0,work_base}+{1'b0,work_bytes})>33'h100000000 ||
      const_bytes==0 || work_bytes==0 ||
      (rank==0 && (record[115*32+:32]!=0 || record[116*32+:32]!=0 || record[117*32+:32]!=0)))fail(8'h01);
     else state<=RESOLVE;
    end
    RESOLVE:begin
     pointer_address_q<=pointer_address;region_end_q<=region_end;outer_last_q<=outer_last;
     state<=RESOLVE_CHECK;
    end
    RESOLVE_CHECK:begin
     pointer_bad_q<=pointer_address_q>=region_end_q || pointer_address_q[32] ||
      region_end_q>33'h100000000 || outer_last_q>={1'b0,region_end_q};
     state<=RESOLVE_COMMIT;
    end
    RESOLVE_COMMIT:begin
     if(pointer_bad_q)fail(8'h03);
     else begin
      if(pointer_index<9)begin
       for(integer p=0;p<9;p=p+1)
        if(pointer_index==4'(p))resolved_pointer[p]<=pointer_address_q[31:0];
      end else resolved_scratch<=pointer_address_q[31:0];
      for(integer p=0;p<3;p=p+1)
       if(pointer_index==4'(p))address[p]<=pointer_address_q[31:0];
      if(pointer_index==9 || (pointer_index==8 && engine_q!=5))begin axis<=0;state<=AXIS_PREP;end
      else begin pointer_index<=pointer_index+1'b1;state<=RESOLVE;end
     end
    end
    AXIS_PREP:begin
     axes_bad_q<=axes_bad;state<=AXIS_CHECK;
     if(REUSE_AXIS_SCAN)begin
      batch_axes_ok<=batch_axes_ok&&batch_axis_match;
      transpose_axes_ok<=transpose_axes_ok&&transpose_axis_match;
      rewinding<=1;
     end
    end
    AXIS_CHECK:begin
     if(REUSE_AXIS_SCAN)begin
      batch_axes_ok<=batch_axes_ok&&batch_axis_match;
      transpose_axes_ok<=transpose_axes_ok&&transpose_axis_match;
      rewinding<=0;
     end
     if(cancelled || cancel_valid)fail(8'he1);
     else if(axes_bad_q || (REUSE_AXIS_SCAN&&absent_rewind_bad))fail(8'h01);
     else if(axis==7)state<=(ENABLE_RESIZE_BATCH || ENABLE_AFFINE_COALESCE) ? BATCH_CHECK : DISPATCH;
     else begin axis<=axis+1'b1;state<=AXIS_PREP;end
    end
    BATCH_CHECK:begin
     if(cancelled || cancel_valid)fail(8'he1);
     else begin copy_batch<=batch_candidate;copy_transpose<=transpose_candidate;state<=DISPATCH;end
    end
    // VALID remains asserted under backpressure, including cancellation.
    DISPATCH:if(inner_ready)state<=WAIT_INNER;
    WAIT_INNER:if(inner_rsp_valid)begin
     if(inner_rsp_fault!=0)begin
      // Copy reports only fully acknowledged two-output pairs. A failed pair
      // is never credited, and the record still owns this fault/cancellation.
      if(copy_batch && !inner_copy_completed[0] && inner_copy_completed<=(dimension[2]<<1))
       rsp_completed<=rsp_completed+(inner_copy_completed>>1);
      if(copy_transpose && inner_copy_completed==22)rsp_completed<=rsp_completed+32'd2;
      fail(inner_rsp_fault);
     end
     else if(cancelled || cancel_valid)begin
      if(copy_batch && !inner_copy_completed[0] && inner_copy_completed<=(dimension[2]<<1))
       rsp_completed<=rsp_completed+(inner_copy_completed>>1);
      if(copy_transpose && inner_copy_completed==22)rsp_completed<=rsp_completed+32'd2;
      fail(8'he1);
     end
     else if(copy_batch && inner_copy_completed!=(dimension[2]<<1))fail(8'h01);
     else if(copy_transpose && inner_copy_completed!=22)fail(8'h01);
     else if(copy_transpose)begin
      rsp_completed<=rsp_completed+32'd2;
      if(rsp_completed+32'd2==record[119*32+:32])state<=RESPONSE;
      else if(rsp_completed+32'd2>record[119*32+:32])fail(8'h01);
      else begin address[0]<=address[0]+32'd8;address[2]<=address[2]+32'd88;state<=DISPATCH;end
     end
     else begin
      rsp_completed<=rsp_completed+(copy_batch ? dimension[2] : 32'd1);
      if(rank==0)state<=RESPONSE;
      // Batched command leaves addresses at the first inner-axis element.
      // Skip that axis entirely: no forward step and no rewind are required.
      else begin axis<=copy_batch ? rank-2'd2 : rank-1'b1;state<=ADVANCE_PREP;end
     end
    end
    ADVANCE_PREP:begin
     // Preserve the original 32-bit wrap before the unsigned dimension test.
     if(cancelled || cancel_valid)fail(8'he1);
     else begin
      next_index_q<=index[axis]+32'd1;dimension_q<=dimension_word;state<=ADVANCE;
     end
    end
    ADVANCE:begin
     if(cancelled || cancel_valid)fail(8'he1);
     else if(next_index_q<dimension_q)begin
      if(rsp_completed>=record[119*32+:32])fail(8'h01);
      else begin
       for(integer j=0;j<8;j=j+1)if(axis==4'(j))index[j]<=next_index_q;
       lane<=0;rewinding<=0;state<=ADJUST_PREP;
      end
     end else begin
      for(integer j=0;j<8;j=j+1)if(axis==4'(j))index[j]<=0;
      lane<=0;rewinding<=1;state<=ADJUST_PREP;
     end
    end
    ADJUST_PREP:begin
     if(cancelled || cancel_valid)fail(8'he1);
     else begin advance_delta_q<=advance_delta;state<=ADJUST_ADDRESS;end
    end
    ADJUST_ADDRESS:begin
     if(cancelled || cancel_valid)fail(8'he1);
     else begin
      for(integer p=0;p<3;p=p+1)if(lane==2'(p))address[p]<=advance_address;
      if(lane!=2)begin lane<=lane+1'b1;state<=ADJUST_PREP;end
      else if(!rewinding)state<=DISPATCH;
      else if(axis==0)begin
       if(rsp_completed!=record[119*32+:32])fail(8'h01);
       else state<=RESPONSE;
      end else begin axis<=axis-1'b1;state<=ADVANCE_PREP;end
     end
    end
    RESPONSE:if(rsp_ready)state<=IDLE;
    default:fail(8'h01);
   endcase
  end
 end
endmodule
