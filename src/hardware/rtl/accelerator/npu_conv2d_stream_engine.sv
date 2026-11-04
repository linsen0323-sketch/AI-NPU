`timescale 1ns/1ps
// Streaming OIHW/NCHW Conv: 8x4 spatial tiles, channel-bank A8/A16 IBUF,
// Resident/ping-pong WBUF, ping-pong IBUF and local INT64 PSum. K is channel-minor inside
// each kernel plane; integer accumulation/legacy wrap and RNE are unchanged.
// One EXTERNAL shared PE. Fallback next-K DMA overlaps current compute;
// eligible WPK1 commands preload four weight slots per output-channel block.
// the next spatial dot overlaps a tagged DSP/RNE epilogue. Only ordinary
// groups=1 convolutions used by ResNet18 and YOLOX are accepted.
(* use_dsp="no" *)
module npu_conv2d_stream_engine #(
 parameter bit EXTERNAL_MATH = 1'b0,
 parameter bit EXTERNAL_RESNET_QUANT = 1'b0,
 parameter bit EXTERNAL_EPILOGUE = 1'b0,
 parameter bit EXTERNAL_FUSION = 1'b0,
 parameter bit ENABLE_INPUT_STRIPE = 1'b1,
 parameter bit ENABLE_WEIGHT_RESIDENCY = 1'b1,
 parameter bit ENABLE_PE_SPATIAL4 = 1'b0,
 parameter bit ENABLE_PROFILE_TRACE=1'b1,ENABLE_STALL_DIAG=1'b1,
 parameter bit SHARED_WEIGHT_SELECT=1'b0
) (
 input logic clk,rst_n,input logic cmd_valid,output logic cmd_ready,
 input logic [31:0] cmd_tag,input logic [4095:0] cmd_record,
 output logic mem_req_valid,input logic mem_req_ready,output logic mem_req_write,
 output logic [31:0] mem_req_addr,output logic [1:0] mem_req_size,
 output logic [63:0] mem_req_wdata,input logic mem_rsp_valid,output logic mem_rsp_ready,
 input logic signed [63:0] mem_rsp_rdata,input logic [3:0] mem_rsp_fault,
 output logic packed_req_valid,input logic packed_req_ready,
 output logic packed_req_a16,packed_req_first,packed_req_last,
 output logic [127:0] packed_req_act,output logic [2047:0] packed_req_weight,
 output wire packed_req_spatial4,output wire [511:0] packed_req_act4,
 input logic packed_rsp_valid,output logic packed_rsp_ready,
 input logic [2047:0] packed_rsp_acc,input logic [1:0] packed_rsp_fault,
 input logic packed_busy,output logic packed_abandon_valid,input logic packed_abandon_ready,
 output logic rsp_valid,input logic rsp_ready,output logic [31:0] rsp_tag,
 output logic [7:0] rsp_fault,output logic [31:0] rsp_completed,output logic busy,
 output logic math_req_valid,input logic math_req_ready,
 output logic [2:0] math_req_op,output logic signed [63:0] math_req_a,math_req_b,
 output logic [6:0] math_req_shift,input logic math_rsp_valid,output logic math_rsp_ready,
 input logic signed [63:0] math_rsp_result,input logic [1:0] math_rsp_fault,
 output logic quant_req_valid,input logic quant_req_ready,
 output logic quant_req_residual,output logic signed [39:0] quant_req_value,
 output logic signed [63:0] quant_req_multiplier_a,quant_req_multiplier_b,
 output logic signed [7:0] quant_req_b,quant_req_shift,
 input logic quant_rsp_valid,output logic quant_rsp_ready,input logic signed [7:0] quant_rsp_result,
 output wire rd_cmd_valid,input wire rd_cmd_ready,output wire [31:0] rd_cmd_addr,rd_cmd_bytes,
 input wire rd_valid,output wire rd_ready,input wire [63:0] rd_data,input wire [7:0] rd_keep,input wire rd_last,
 input wire rd_rsp_valid,output wire rd_rsp_ready,input wire [3:0] rd_fault,
 output wire wr_cmd_valid,input wire wr_cmd_ready,output wire [31:0] wr_cmd_addr,wr_cmd_bytes,
 output wire wr_valid,input wire wr_ready,output wire [63:0] wr_data,output wire [7:0] wr_keep,output wire wr_last,
 input wire wr_rsp_valid,output wire wr_rsp_ready,input wire [3:0] wr_fault,
 output wire epilogue_req_valid,
 output wire signed [39:0] epilogue_req_value,
 output wire signed [63:0] epilogue_req_multiplier,
 output wire signed [7:0] epilogue_req_shift,
 output wire [18:0] epilogue_req_tag,
 input wire epilogue_rsp_valid,
 input wire signed [7:0] epilogue_rsp_result8,
 input wire signed [31:0] epilogue_rsp_result32,
 input wire epilogue_rsp_overflow32,
 input wire [18:0] epilogue_rsp_tag,
 input wire epilogue_pipe_busy,
 input wire fusion_available,
 output wire fusion_valid,input wire fusion_ready,output wire [31:0] fusion_data,output wire [9:0] fusion_tag,
 input wire fusion_rsp_valid,input wire [31:0] fusion_result,input wire [9:0] fusion_rsp_tag,input wire [7:0] fusion_fault,
 output wire [84:0] stall_events,
 output wire [31:0] stall_input_bytes,stall_weight_bytes,
 output wire [4:0] stall_window_count,
 output wire [4:0] perf_events,
 output logic [1:0] packed_req_weight_group
);
 localparam integer ROW_W=7, TILE_K=1024;
 localparam logic [ROW_W-1:0] WEIGHT_SLOT_ROWS=7'd36;
 typedef enum logic [6:0] {IDLE,CHECK,INITIAL_LOAD,WAIT_TILE,TILE_BEGIN,K_SPLIT_C,K_SPLIT_Y,
  BEGIN_PIXEL,GATHER_SELECT,GATHER_ADDR,GATHER_SAVE,GATHER_ADVANCE,
  BANK_REQ,BANK_WAIT,PE_SEND,PE_WAIT,COMBINE,ADD_PARTIAL,FINAL_CHECK,
  BIAS_VALUE,BIAS_SUM,MULT_VALUE,SHIFT_VALUE,REQUANT_VALUE,NEXT_LANE,
  TILE_FINISH,NEXT_OC,ERROR_DRAIN,MEM_REQUEST,MEM_WAIT,MATH_REQUEST,MATH_WAIT,
  GEOMETRY_SEND,GEOMETRY_VALUE,REGION_CHECK,TILE_INPUT_VALUE,TILE_DY_VALUE,
  TILE_DX_VALUE,GATHER_BEGIN,QUANT_REQUEST,QUANT_WAIT,RESPONSE,
  REGION_SUM,REGION_VALIDATE,PARAM_BIAS,PARAM_MULT,PARAM_SHIFT,STREAM_CONFIG,START_SPATIAL,INPUT_READ,INPUT_WAIT,PSUM_READ,PSUM_VALUE,OUTPUT_COMMAND,OUTPUT_RESPONSE,ADVANCE_SPATIAL,TILE_SIZE,KCOUNT_SETUP,GEOMETRY_CHECK,TILE_CAP_HEIGHT,TILE_CAP_WORDS,WEIGHT_PRELOAD,WEIGHT_PRELOAD_WAIT} state_t;
 state_t state,mem_return,math_return;
 logic [31:0] a_base,y_base,weight_base,bias_base,mult_base,shift_base,scratch_base;
 // CHECK rejects the full 32-bit command fields before any geometry work.
 // Keep their accepted ranges in narrow storage, with 32-bit aliases so the
 // existing shifts, signed casts and address expressions keep their widths.
 // Dimensions and padding include 4096, so they require all 13 bits.
 logic [12:0] ic_q,ih_q,iw_q,oc_q,oh_q,ow_q,pt_q,pl_q;
 logic [2:0] kh_q,kw_q;
 logic [1:0] sh_q,sw_q;
 logic dh_q,dw_q;
 wire [31:0] ic={19'd0,ic_q},ih={19'd0,ih_q},iw={19'd0,iw_q};
 wire [31:0] oc={19'd0,oc_q},oh={19'd0,oh_q},ow={19'd0,ow_q};
 wire [31:0] pt={19'd0,pt_q},pl={19'd0,pl_q};
 wire [31:0] kh={29'd0,kh_q},kw={29'd0,kw_q};
 wire [31:0] sh={30'd0,sh_q},sw={30'd0,sw_q};
 wire [31:0] dh={31'd0,dh_q},dw={31'd0,dw_q};
 logic [31:0] full_k,aplane,yplane;
 logic [2:0] bdtype,mdtype,sdtype;
 logic packed_weights,packed_bad;
 logic [31:0] packed_bank_stride;
 wire [31:0] weight_bank_stride=packed_weights?packed_bank_stride:full_k;
 (* keep="true" *) logic [2:0] shape_bad;
 function automatic logic [31:0] command_word(input integer index);
  command_word=cmd_record[index*32+:32];
 endfunction
 logic geometry_match;
 logic [7:0] capacity_group_rows;
 logic [9:0] capacity_weights;
 logic [10:0] capacity_inputs;
 logic a16,resnet_legacy;
 logic fused_output;
 logic [2:0] final_dtype;
 logic [31:0] final_base;
 logic [31:0] final_block_y,stream_final_base;
 wire [1:0] final_size=final_dtype==1 ? 2'd0 : final_dtype==2 ? 2'd1 : 2'd2;
 wire [1:0] output_scale=fused_output ? 2'd2-final_size : 2'd0;
 wire [31:0] final_plane=yplane>>output_scale;
 logic [64:0] final_end;
 logic signed [7:0] resnet_shift;
 logic command_bad;
 logic [31:0] oc_global,block_w,block_y;
 logic [5:0] channels;
 logic page;
 logic [31:0] kbase,kcount,split_k,tile_c,tile_ky,tile_kx;
 logic [31:0] oy,ox,pixel,scratch_pixel;
 logic signed [31:0] origin_y,origin_x;
 logic [ROW_W:0] vector_row,vector_rows;
 logic [3:0] input_lane;
 logic [5:0] output_lane;
 logic [31:0] gather_cptr,gather_ky,gather_kx,kcursor;
 logic [31:0] row_bytes,dilation_row_step,output_row_step,padding_rows;
 logic [31:0] pixel_row_offset,tile_row_offset,gather_row_offset;
 logic [10:0] tile_dy,tile_dx,gather_dy,gather_dx;
 logic [31:0] lane_output_address;
 logic signed [31:0] iy,ix;
 logic signed [63:0] accum[0:31],raw,biased,multiplier;
 logic signed [63:0] mem_value,math_value;
 logic [63:0] input_bytes,output_bytes,weight_bytes;
 logic [3:0] geometry_index;
 logic [31:0] kernel_area,tile_a;
 logic signed [63:0] geometry_a,geometry_b;
 logic [64:0] aend,yend,wend,scratch_end;
 logic region_bad;
 // Coefficients belong to an output-channel block, not to a spatial pixel.
 // Preload once and reuse for every pixel and K fragment of that block.
 (* ram_style="distributed" *) logic signed [63:0] bias_cache[0:31],mult_cache[0:31],shift_cache[0:31];

 logic output_ready,output_rsp_valid,output_busy;
 logic [7:0] output_fault;
 logic output_page;
 logic [7:0] output_fault_q;
 logic [31:0] stream_output_base;
 logic [5:0] cin_limit,cin_count;
 logic [12:0] cin_start;
 logic [23:0] tile_first_pixel;
 wire [12:0] remaining_c=ic[12:0]-cin_start-{7'd0,cin_count};
 wire [5:0] next_c=remaining_c>{7'd0,cin_limit} ? cin_limit : remaining_c[5:0];
 wire [3:0] limit_groups=({1'b0,cin_limit}+7'd7)>>3;
 wire [3:0] cin_groups=({1'b0,cin_count}+7'd7)>>3;
 logic [31:0] tile_x,tile_y,tile_width,tile_height;
 logic [31:0] tile_last_x,tile_last_y;
 logic [31:0] tile_after_x,tile_after_y,tile_next_width,tile_next_height;
 logic tile_more_x,tile_more_y;
 logic [6:0] input_width;
 logic [5:0] input_height;
 // Command-scoped 1x1/s1/p0 row reuse for IC<=64, IW<=64, A8/A16.
 // Up to two Cin pages retain all X tiles; small planes retain all Y/OC.
 // The admitted footprints remain <=256 words per channel bank and page.
 logic input_stripe,input_plane_cache;
 logic input_fill_page;
 logic [5:0] input_cached_y[0:1];
 logic [7:0] input_row_words;
 logic [31:0] vector_cgroup,vector_ky,vector_kx,local_pixel;
 // The same 32 PE result lanes mean [space][8Cout] in spatial mode.
 // Tiles with column/channel tails use the original organization.
 // Geometry is fixed for a tile. Capture its mode before any input/weight
 // read starts, so full-width stride comparisons do not feed the shared
 // PE/BRAM/DMA ready chain on every vector.
 logic spatial4;
 logic [1:0] cout_subgroup;
 // Four reserved activation slots decouple the single IBUF reader from PE
 // admission. Keep range_decode's 128-bit IBUF selector: four in-order
 // reads fill one vector, with no raw-bank replication or wide shifter.
 // Four step banks retain the complete A8/A16 payload for four slots.
 logic [ROW_W-1:0] spatial_rows[0:3];
 logic [3:0] spatial_act_valid,spatial_weight_issued,spatial_first,spatial_last;
 logic [1:0] spatial_tail,spatial_weight_head,spatial_sent;
 logic spatial_gather;
 // IBUF always drains in spatial mode. These two four-bit tags mirror its
 // existing two elastic stages and associate each response with slot/lane.
 logic [3:0] spatial_read_tag,spatial_response_tag;
 wire [1:0] spatial_response_slot=spatial_response_tag[3:2];
 wire [1:0] spatial_response_lane=spatial_response_tag[1:0];
 wire [1:0] bank_spatial_slot;
 wire bank_first,bank_last;
 wire [511:0] spatial_act;
 wire [4:0] result_channel=spatial4 ? {cout_subgroup,output_lane[2:0]} : output_lane[4:0];
 wire [4:0] result_pixel=local_pixel[4:0]+(spatial4 ? {3'd0,output_lane[4:3]} : 5'd0);
 logic [31:0] span_y,span_x,input_linear,input_word_address;
 logic input_pending,input_load_ready,input_load_rsp,input_loader_busy;
 logic [3:0] input_load_fault;
 logic [1:0] input_loaded;
 logic input_wr_valid,input_wr_ready,input_wr_page;
 logic [2:0] input_wr_bank;
 logic [7:0] input_wr_word;
 logic [63:0] input_wr_data;
 logic input_rd_ready,input_rsp_valid;
 wire feed_first=bank_first,feed_last=bank_last;
 logic [2:0] feed_pending;
 logic [127:0] input_rsp_data;
 logic [7:0] input_mask;
 logic feed_active;
 logic [31:0] feed_y,feed_x;
 // Reuse addressing remains narrow. Shape/capacity checks bound row<=31,
 // row_words<=16 and the complete per-bank word offset to 0..255.
 wire [6:0] input_cache_byte=({1'b0,feed_x[5:0]}+
     (spatial4 ? {5'd0,spatial_sent} : 7'd0))<<a16;
 wire [4:0] input_cache_row=(vector_cgroup[1:0]*input_height[3:0])+
     (input_plane_cache ? {2'd0,feed_y[2:0]} : {3'd0,feed_y[1:0]});
 wire [8:0] input_cache_word=input_cache_row*input_row_words[4:0]+{5'd0,input_cache_byte[6:3]};
 wire epilogue_valid,epilogue_busy;
 wire [31:0] epilogue_data;
 wire [9:0] epilogue_tag;
 wire [7:0] epilogue_fault;
 logic [7:0] epilogue_fault_q;
 logic [7:0] load_rsp_fault,loader_fault;
 wire [7:0] deferred_fault=loader_fault!=0?loader_fault:epilogue_fault_q!=0?epilogue_fault_q:output_fault_q;
 logic [1:0] bulk_cmd_valid,bulk_cmd_ready,bulk_valid,bulk_ready,bulk_rsp_valid,bulk_rsp_ready;
 logic [63:0] bulk_cmd_addr,bulk_cmd_bytes,bulk_data;
 logic [7:0] bulk_keep;
 logic bulk_last,bulk_idle;
 logic [3:0] bulk_fault;
 (* ram_style="block" *) logic signed [63:0] psum[0:1023];
 logic signed [63:0] psum_q;
 logic partial_valid,partial_final;
 logic signed [63:0] partial_acc;
 logic [4:0] partial_lane,partial_pixel;
 logic partial_add_valid,partial_add_final,partial_sum_valid,partial_sum_final;
 logic [4:0] partial_add_lane,partial_add_pixel,partial_sum_lane,partial_sum_pixel;
 logic [32:0] partial_low_sum,partial_high_sum;
 logic signed [64:0] partial_sum;
 wire [32:0] partial_high_with_carry=partial_high_sum+{32'd0,partial_low_sum[32]};
 wire partial_busy=partial_valid||partial_add_valid||partial_sum_valid;
 wire [9:0] psum_index={result_pixel,result_channel};
 wire partial_read_fire=rst_n&&state==PSUM_READ&&deferred_fault==0;
 wire partial_overflow=partial_sum[64]!=partial_sum[63];
 wire signed [63:0] partial_value=resnet_legacy?wrap40(partial_sum[63:0]):partial_sum[63:0];
 logic psum_write_enable;
 logic [9:0] psum_write_address;
 logic signed [63:0] psum_write_data;
 // Validated geometry: <=4 Cin groups, <=13 rows, <=16 words per row.
 // Existing 8/10/11-bit capacity registers include the 256-word stripe.
 // Both preparation states run before this payload is consumed.
 always_ff @(posedge clk)begin
  if(state==TILE_CAP_HEIGHT)begin
   capacity_group_rows<=limit_groups*input_height[3:0];
   capacity_weights<=limit_groups*kernel_area[5:0];
  end
  if(state==TILE_CAP_WORDS)capacity_inputs<=capacity_group_rows*input_row_words[4:0];
 end
 // Capture the exact original full-width comparison before it drives the
 // FSM. This payload is consumed only by the following GEOMETRY_CHECK state.
 always_ff @(posedge clk)if(state==GEOMETRY_VALUE)begin
  case(geometry_index)
   3:geometry_match<=math_value==$signed({32'd0,full_k});
   4:geometry_match<=(math_value<<(a16 ? 1 : 0))==$signed({32'd0,aplane});
   5:geometry_match<=(math_value<<(resnet_legacy ? 0 : 2))==$signed({32'd0,yplane});
   default:geometry_match<=0;
  endcase
 end
 always_comb begin
  psum_write_enable=0;psum_write_address=0;psum_write_data=0;
  if(rst_n&&state==FINAL_CHECK&&kbase==0&&kcount<full_k&&deferred_fault==0)begin
   psum_write_enable=1;psum_write_address=psum_index;
   psum_write_data=resnet_legacy?wrap40(accum[output_lane]):accum[output_lane];
  end else if(rst_n&&partial_sum_valid&&!partial_sum_final&&!partial_overflow&&deferred_fault==0)begin
   psum_write_enable=1;psum_write_address={partial_sum_pixel,partial_sum_lane};psum_write_data=partial_value;
  end
 end
 always_ff @(posedge clk) begin
  // Expose a single write port after the prioritized source selection.
  if(partial_read_fire)psum_q<=psum[psum_index];
  if(psum_write_enable)psum[psum_write_address]<=psum_write_data;
 end
 always_ff @(posedge clk) begin
  // Tags and the matching accumulator retain the synchronous read timing.
  if(!rst_n)begin
   partial_valid<=0;partial_final<=0;partial_acc<=0;partial_lane<=0;partial_pixel<=0;
   partial_add_valid<=0;partial_sum_valid<=0;
  end
  else begin
   partial_valid<=partial_read_fire;
   partial_add_valid<=partial_valid;partial_sum_valid<=partial_add_valid;
   if(partial_read_fire)begin
    partial_acc<=accum[output_lane];partial_lane<=result_channel;partial_pixel<=result_pixel;
    partial_final<=kbase+kcount==full_k;
   end
  end
 end
 always_ff @(posedge clk) begin
  // Split the exact signed65 addition at bit32. The high sum includes sign
  // extension; only the registered low carry is added in the second stage.
  // Payload stages need no reset or enable: valid bits own every consumer.
  partial_low_sum<={1'b0,partial_acc[31:0]}+{1'b0,psum_q[31:0]};
  partial_high_sum<={partial_acc[63],partial_acc[63:32]}+{psum_q[63],psum_q[63:32]};
  partial_add_final<=partial_final;partial_add_lane<=partial_lane;partial_add_pixel<=partial_pixel;
  partial_sum<={partial_high_with_carry,partial_low_sum[31:0]};
  partial_sum_final<=partial_add_final;partial_sum_lane<=partial_add_lane;partial_sum_pixel<=partial_add_pixel;
 end
 logic load_pending,load_page,load_ready,load_rsp_valid,loader_busy;
 logic [31:0] load_w,load_start,load_count;
 logic [1:0] loaded;
 // The fallback retains the original two page-local fragment tags.
 logic [12:0] cached_start[0:1];
 logic [5:0] cached_count[0:1];
 // IC128/OC128 WPK1 3x3: four 32Cin fragments occupy 36 rows each.
 // Slot[0] selects the physical page; slot[1] selects row base 0 or 36.
 // Preload serially with no PE reads, then retain all slots for this OC block.
 logic weight_residency;
 logic [3:0] resident_valid;
 logic [6:0] resident_start[0:3];
 logic [1:0] weight_preload_slot,weight_fill_slot;
 wire [1:0] weight_read_slot=cin_start[6:5];
 wire [1:0] weight_next_slot=weight_read_slot+2'd1;
 wire resident_block_ready=(&resident_valid) && resident_start[0]==7'd0 &&
     resident_start[1]==7'd32 && resident_start[2]==7'd64 && resident_start[3]==7'd96;
 wire weight_fragment_ready=weight_residency ?
     resident_valid[weight_read_slot] && resident_start[weight_read_slot]==cin_start[6:0] &&
     cin_start[12:7]==0 && cin_count==32 : loaded[page];
 wire first_weight_hit=weight_residency ?
     resident_valid[0] && resident_start[0]==0 && cin_limit==32 :
     loaded[0] && cached_start[0]==0 && cached_count[0]==(ic<cin_limit ? ic[5:0] : cin_limit);
 wire next_weight_hit=weight_residency ?
     resident_valid[weight_next_slot] && {6'd0,resident_start[weight_next_slot]}==cin_start+cin_count && next_c==32 :
     loaded[!page] && cached_start[!page]==cin_start+cin_count && cached_count[!page]==next_c;
 // Input prefetch keeps load_page/load_start/load_count. A resident weight
 // command instead owns its independent preload slot until terminal response.
 wire weight_load_page=weight_residency ? weight_preload_slot[0] : load_page;
 wire [31:0] weight_load_start=weight_residency ? {25'd0,weight_preload_slot,5'd0} : load_start;
 wire [5:0] weight_load_count=weight_residency ? 6'd32 : load_count[5:0];
 wire weight_read_page=weight_residency ? weight_read_slot[0] : page;
 wire [ROW_W-1:0] weight_read_row_base=weight_residency && weight_read_slot[1] ? WEIGHT_SLOT_ROWS : 7'd0;
 wire [ROW_W-1:0] weight_store_row_base=weight_residency && weight_fill_slot[1] ? WEIGHT_SLOT_ROWS : 7'd0;
 wire [ROW_W:0] weight_read_row={1'b0,weight_read_row_base}+{1'b0,vector_row[ROW_W-1:0]};
 // The command shape fixes the Cin-to-page tags. The row tag and valid bit
 // become reusable only after the entire input-loader response succeeds.
 wire first_input_hit=input_stripe && cin_limit==32 && input_loaded[0] &&
     (input_plane_cache || input_cached_y[0]==tile_y[5:0]);
 wire next_input_hit=input_stripe && !page && cin_start==0 && cin_count==32 &&
     next_c!=0 && input_loaded[1] && (input_plane_cache || input_cached_y[1]==tile_y[5:0]);
 wire reuse_first=state==TILE_INPUT_VALUE && capacity_weights<=128 && capacity_inputs<=256 && cin_limit!=0 && first_weight_hit;
 wire reuse_next=state==TILE_BEGIN && kbase+kcount<full_k && next_weight_hit;
 // These are event pulses / cycle predicates, not disjoint time buckets.
 // WAIT_TILE excludes preload time; use loader busy and total operator cycles.
 wire [4:0] observation_events;
 generate if(ENABLE_PROFILE_TRACE || ENABLE_STALL_DIAG)begin:g_observation_events
 assign observation_events={reuse_first||reuse_next,load_pending&&load_ready,
     state==OUTPUT_COMMAND&&!output_ready,
     state==WAIT_TILE&&(!weight_fragment_ready||!input_loaded[page]),
     output_busy&&packed_req_valid&&packed_req_ready};
 end else begin:g_no_observation_events
  assign observation_events=0;
 end endgenerate
 assign perf_events=ENABLE_PROFILE_TRACE ? observation_events : 5'd0;
 logic weight_wr_valid,weight_wr_ready,weight_wr_page;
 logic [4:0] weight_wr_bank;
 logic [ROW_W-1:0] weight_wr_row;
 // Keep loader-relative row progression and WPK1 byte order unchanged.
 // The accepted fill slot remains fixed through every stalled BRAM write.
 wire [ROW_W:0] weight_store_row={1'b0,weight_store_row_base}+{1'b0,weight_wr_row};
 logic [63:0] weight_wr_data;
 logic [7:0] weight_wr_strb;
 logic bank_ready,bank_rsp_valid;
 // At most one spatial dot is prefetched beyond the epilogue. Its result is
 // retained by the shared PE until PE_WAIT consumes it; accum is never
 // overwritten while its current lanes are still being submitted.
 wire feed_candidate=rst_n&&feed_active&&state!=ERROR_DRAIN&&deferred_fault==0&&vector_row<vector_rows;
 wire spatial_candidate=feed_candidate&&!spatial_gather&&feed_pending<3'd4;
 wire feed_launch=spatial4 ? spatial_candidate&&input_rd_ready :
     feed_candidate&&bank_ready&&input_rd_ready;
 // Finish all four reads of an allocated vector even after cancellation.
 // The descriptor/page lease cannot be released while any slot is live.
 wire spatial_read_next=rst_n&&feed_active&&spatial4&&spatial_gather;
 wire input_read_valid=spatial4 ? (spatial_candidate||spatial_read_next) : feed_candidate;
 wire spatial_input_fire=spatial4&&input_read_valid&&input_rd_ready;
 wire spatial_issue_done=spatial_input_fire&&spatial_gather&&spatial_sent==3;
 // A ready activation slot owns one narrow WBUF row descriptor. Weight
 // payload stays in the original BRAM latch/output registers until PE
 // admission; do not add a replicated 2048-bit queue or Cout selector.
 wire weight_read_valid=spatial4 ?
     (rst_n&&feed_active&&spatial_act_valid[spatial_weight_head]&&!spatial_weight_issued[spatial_weight_head]) :
     feed_candidate;
 wire input_response_ready=rst_n&&feed_active&&(spatial4 || (bank_rsp_valid&&packed_req_ready));
 wire weight_response_ready=rst_n&&feed_active&&packed_req_ready&&
     (spatial4 ? spatial_act_valid[bank_spatial_slot] : input_rsp_valid);
 wire spatial_pop=spatial4&&packed_req_valid&&packed_req_ready;

 logic [2047:0] bank_data;

 logic [1:0] c_req_valid,c_req_ready,c_req_write,c_rsp_valid,c_rsp_ready;
 logic [63:0] c_req_addr;
 logic [3:0] c_req_size;
 logic [127:0] c_req_wdata,c_rsp_rdata;
 logic [7:0] c_rsp_fault;
 logic memory_idle;
 logic main_write;logic [31:0] main_addr;logic [1:0] main_size;logic [63:0] main_data;
 logic math_ready,math_valid;logic [2:0] math_op;
 logic signed [63:0] math_a,math_b,math_result;
 logic [6:0] math_shift;logic [1:0] math_fault;
 wire direct_epilogue=rst_n&&state==FINAL_CHECK&&kbase==0&&kcount==full_k;
 wire partial_epilogue=partial_sum_valid&&partial_sum_final;
 wire signed [63:0] epilogue_raw=partial_epilogue?partial_value:
     (resnet_legacy?wrap40(accum[output_lane]):accum[output_lane]);
 // Coefficient/tag selection depends only on registered ownership. Overflow
 // suppresses validity without entering the bias-cache address mux.
 wire epilogue_input_valid=(direct_epilogue||(partial_epilogue&&!partial_overflow))&&deferred_fault==0;
 wire [4:0] epilogue_coefficient=partial_epilogue?partial_sum_lane:result_channel;
 wire [9:0] epilogue_input_tag=partial_epilogue?{partial_sum_lane,partial_sum_pixel}:
     {result_channel,result_pixel};
 npu_conv_epilogue #(.EXTERNAL_PIPE(EXTERNAL_EPILOGUE)) u_epilogue (
  .clk(clk),.rst_n(rst_n),.in_valid(epilogue_input_valid),.in_legacy(resnet_legacy),
  .in_raw(epilogue_raw),.in_bias(bias_cache[epilogue_coefficient]),.in_multiplier(mult_cache[epilogue_coefficient]),.in_shift(shift_cache[epilogue_coefficient]),
  .in_tag(epilogue_input_tag),
  .out_valid(epilogue_valid),.out_data(epilogue_data),.out_fault(epilogue_fault),.out_tag(epilogue_tag),.busy(epilogue_busy),
  .pipe_req_valid(epilogue_req_valid),.pipe_req_value(epilogue_req_value),.pipe_req_multiplier(epilogue_req_multiplier),
  .pipe_req_shift(epilogue_req_shift),.pipe_req_tag(epilogue_req_tag),
  .pipe_rsp_valid(epilogue_rsp_valid),.pipe_rsp_result8(epilogue_rsp_result8),.pipe_rsp_result32(epilogue_rsp_result32),
  .pipe_rsp_overflow32(epilogue_rsp_overflow32),.pipe_rsp_tag(epilogue_rsp_tag),.pipe_busy(epilogue_pipe_busy));
 wire output_pixel_valid=epilogue_valid&&epilogue_fault==0&&epilogue_fault_q==0&&state!=ERROR_DRAIN;
 npu_conv_output_tile #(.EXTERNAL_FUSION(EXTERNAL_FUSION)) u_output (
  .cmd_fusion(fused_output),.cmd_i16(fused_output && final_dtype==2),
  .fusion_valid(fusion_valid),.fusion_ready(fusion_ready),.fusion_data(fusion_data),.fusion_tag(fusion_tag),
  .fusion_rsp_valid(fusion_rsp_valid),.fusion_result(fusion_result),.fusion_rsp_tag(fusion_rsp_tag),.fusion_fault(fusion_fault),
  .clk(clk),.rst_n(rst_n),.pixel_valid(output_pixel_valid),.pixel_channel(epilogue_tag[9:5]),.pixel_index(epilogue_tag[4:0]),
  .pixel_data(epilogue_data),.pixel_page(output_page),.cmd_page(output_page),
  .cmd_valid(rst_n&&state==OUTPUT_COMMAND),.cmd_ready(output_ready),.cmd_i8(resnet_legacy || (fused_output && final_dtype==1)),
  .cmd_base((fused_output ? stream_final_base : stream_output_base)+
            ({8'd0,tile_first_pixel}<<(resnet_legacy ? 0 : fused_output ? final_size : 2))),
  .cmd_plane(final_plane),.cmd_row_stride(ow<<(resnet_legacy ? 0 : fused_output ? final_size : 2)),
  .cmd_width(tile_width[3:0]),.cmd_height(tile_height[2:0]),.cmd_channels(channels),
  .wr_cmd_valid(wr_cmd_valid),.wr_cmd_ready(wr_cmd_ready),.wr_cmd_addr(wr_cmd_addr),.wr_cmd_bytes(wr_cmd_bytes),
  .wr_valid(wr_valid),.wr_ready(wr_ready),.wr_data(wr_data),.wr_keep(wr_keep),.wr_last(wr_last),
  .wr_rsp_valid(wr_rsp_valid),.wr_rsp_ready(wr_rsp_ready),.wr_fault(wr_fault),
  .rsp_valid(output_rsp_valid),.rsp_ready(1'b1),.rsp_fault(output_fault),.busy(output_busy));
 function automatic logic signed [63:0] wrap40(input logic signed [63:0] value);
  wrap40={{24{value[39]}},value[39:0]};
 endfunction
 function automatic logic [1:0] size_of(input logic [2:0] dtype);
  size_of=(dtype==4) ? 2'd3 : 2'd2;
 endfunction
 function automatic logic [31:0] param_address(input logic [31:0] base,input logic [2:0] dtype);
  param_address=base+((oc_global+{26'd0,output_lane})<<(dtype==4 ? 3 : 2));
 endfunction
 task automatic fail(input logic [7:0] code);
  begin
   if(rsp_fault==0) rsp_fault<=code;
   // Invalidate reuse, but preserve geometry and every pending loader request
   // until its normal terminal response. No stalled VALID is revoked.
   input_loaded<=0;resident_valid<=0;state<=ERROR_DRAIN;
  end
 endtask
 task automatic memory(input logic write_enable,input logic [31:0] address,
  input logic [1:0] size,input logic signed [63:0] data,input state_t destination);
  begin main_write<=write_enable;main_addr<=address;main_size<=size;main_data<=data;
   mem_return<=destination;state<=MEM_REQUEST;end
 endtask
 task automatic arithmetic(input logic [2:0] operation,input logic signed [63:0] a,b,
  input logic [6:0] shift,input state_t destination);
  begin math_op<=operation;math_a<=a;math_b<=b;math_shift<=shift;
   math_return<=destination;state<=MATH_REQUEST;end
 endtask
 task automatic start_dot(input logic [31:0] next_y,next_x);
  begin
   feed_y<=next_y;feed_x<=next_x;feed_active<=1;
   vector_row<=0;vector_rows<=cin_groups*kernel_area[5:0];
   vector_cgroup<=0;vector_ky<=0;vector_kx<=0;
   spatial_tail<=0;spatial_weight_head<=0;spatial_sent<=0;spatial_gather<=0;
   spatial_act_valid<=0;spatial_weight_issued<=0;
  end
 endtask
 task automatic advance_lane(input state_t next_lane_state);
  begin
   if(spatial4)begin
    if(output_lane!=31)begin output_lane<=output_lane+1'b1;state<=next_lane_state;end
    else if(cout_subgroup!=3)begin
     cout_subgroup<=cout_subgroup+1'b1;state<=BEGIN_PIXEL;
    end else begin
     cout_subgroup<=0;
     if(kbase+kcount==full_k && ox+4==ow && oy+1==oh)begin
      block_w<=block_w+(weight_bank_stride<<5);block_y<=block_y+(yplane<<5);
      final_block_y<=final_block_y+(final_plane<<5);
     end
     if(ox+3<tile_last_x)begin
      ox<=ox+4;pixel<=pixel+4;local_pixel<=local_pixel+4;state<=BEGIN_PIXEL;
     end else if(oy<tile_last_y)begin
      ox<=tile_x;oy<=oy+1'b1;pixel<=pixel+ow-(ox-tile_x);
      local_pixel<=local_pixel+4;state<=BEGIN_PIXEL;
     end else state<=TILE_FINISH;
    end
   end else begin
   lane_output_address<=lane_output_address+yplane;
   if(kbase+kcount==full_k && ox+1==ow && oy+1==oh)begin
    block_w<=block_w+weight_bank_stride;block_y<=block_y+yplane;
    final_block_y<=final_block_y+final_plane;
   end
   if(output_lane+1'b1<channels)begin
    output_lane<=output_lane+1'b1;state<=next_lane_state;
   end else if(ox<tile_last_x)begin
    ox<=ox+1'b1;pixel<=pixel+1'b1;local_pixel<=local_pixel+1'b1;state<=PE_WAIT;
   end else if(oy<tile_last_y)begin
    // pixel=oy*ow+ox; remove the completed tile-column offset for the next row.
    ox<=tile_x;oy<=oy+1'b1;pixel<=pixel+ow-(ox-tile_x);
    local_pixel<=local_pixel+1'b1;state<=PE_WAIT;
   end else state<=TILE_FINISH;
   end
  end
 endtask
 always_comb begin
  cmd_ready=rst_n && state==IDLE;busy=state!=IDLE;rsp_valid=rst_n && state==RESPONSE;
  row_bytes=iw<<(a16 ? 1 : 0);
  geometry_a=0;geometry_b=0;
  case(geometry_index)
   1: begin geometry_a=$signed({32'd0,((ic+32'd7)>>3)});geometry_b=$signed({32'd0,(kernel_area<<3)});end
   2: begin geometry_a=$signed({32'd0,kh});geometry_b=$signed({32'd0,kw});end
   3: begin geometry_a=$signed({32'd0,ic});geometry_b=$signed({32'd0,kernel_area});end
   4: begin geometry_a=$signed({32'd0,ih});geometry_b=$signed({32'd0,iw});end
   5: begin geometry_a=$signed({32'd0,oh});geometry_b=$signed({32'd0,ow});end
   6: begin geometry_a=$signed({32'd0,ic});geometry_b=$signed({32'd0,aplane});end
   7: begin geometry_a=$signed({32'd0,oc});geometry_b=$signed({32'd0,yplane});end
   8: begin geometry_a=$signed({32'd0,oc});geometry_b=$signed({32'd0,weight_bank_stride});end
   10: begin geometry_a=$signed({32'd0,dh});geometry_b=$signed({32'd0,row_bytes});end
   11: begin geometry_a=$signed({32'd0,sh});geometry_b=$signed({32'd0,row_bytes});end
   12: begin geometry_a=$signed({32'd0,pt});geometry_b=$signed({32'd0,row_bytes});end
   default: begin end
  endcase
  packed_req_valid=rst_n && feed_active && bank_rsp_valid &&
      (spatial4 ? spatial_act_valid[bank_spatial_slot] : input_rsp_valid);packed_req_a16=a16;
  packed_req_first=feed_first;packed_req_last=feed_last;
  packed_rsp_ready=rst_n && (state==PE_WAIT || state==ERROR_DRAIN);
  packed_abandon_valid=rst_n && state==ERROR_DRAIN && !packed_busy && !feed_active;
  // Conv now owns a streaming epilogue. Keep the existing shared-quant ABI
  // quiet; residual and GAP clients continue to use that checked service.
  quant_req_valid=0;quant_rsp_ready=1;
  quant_req_residual=0;quant_req_value=0;quant_req_multiplier_a=0;
  quant_req_multiplier_b=0;quant_req_b=0;quant_req_shift=0;
  c_req_valid[1]=rst_n && state==MEM_REQUEST;c_req_write[1]=main_write;
  c_req_addr[63:32]=main_addr;c_req_size[3:2]=main_size;c_req_wdata[127:64]=main_data;
  c_rsp_ready[1]=rst_n && state==MEM_WAIT;
 end
 npu_math_port #(.EXTERNAL_MATH(EXTERNAL_MATH)) u_math (.clk(clk),.rst_n(rst_n),
  .req_valid(rst_n && state==MATH_REQUEST),.req_ready(math_ready),
  .req_op(math_op),.req_a(math_a),.req_b(math_b),.req_shift(math_shift),
  .rsp_valid(math_valid),.rsp_ready(rst_n && state==MATH_WAIT),.rsp_result(math_result),.rsp_fault(math_fault),
  .math_req_valid(math_req_valid),.math_req_ready(math_req_ready),
  .math_req_op(math_req_op),.math_req_a(math_req_a),.math_req_b(math_req_b),
  .math_req_shift(math_req_shift),.math_rsp_valid(math_rsp_valid),.math_rsp_ready(math_rsp_ready),
  .math_rsp_result(math_rsp_result),.math_rsp_fault(math_rsp_fault));
 assign c_req_valid[0]=0;assign c_req_write[0]=0;assign c_req_addr[31:0]=0;
 assign c_req_size[1:0]=0;assign c_req_wdata[63:0]=0;assign c_rsp_ready[0]=1;
 wire [84:0] stall_i,stall_w;wire [1:0] stall_owner;wire [4:0] stall_input_window;wire stall_wbuf_conflict;
 npu_stream_weight_loader #(.ENABLE_STALL_DIAG(ENABLE_STALL_DIAG)) u_loader (
  .stall_events(stall_w),
  .clk(clk),.rst_n(rst_n),.stop(state==ERROR_DRAIN),.cmd_valid(load_pending),.cmd_ready(load_ready),
  .cmd_page(weight_load_page),.cmd_base(load_w),.cmd_full_k(full_k),.cmd_start_c(weight_load_start),
  .cmd_packed(packed_weights),.cmd_bank_stride(packed_bank_stride),
  .cmd_channels(channels),.cmd_cin(weight_load_count),.cmd_area(kernel_area[5:0]),
  .wr_valid(weight_wr_valid),.wr_ready(weight_wr_ready),.wr_page(weight_wr_page),.wr_bank(weight_wr_bank),.wr_row(weight_wr_row),
  .wr_data(weight_wr_data),.wr_strb(weight_wr_strb),.rd_cmd_valid(bulk_cmd_valid[0]),.rd_cmd_ready(bulk_cmd_ready[0]),
  .rd_cmd_addr(bulk_cmd_addr[0+:32]),.rd_cmd_bytes(bulk_cmd_bytes[0+:32]),
  .rd_valid(bulk_valid[0]),.rd_ready(bulk_ready[0]),.rd_data(bulk_data),.rd_keep(bulk_keep),.rd_last(bulk_last),
  .rd_rsp_valid(bulk_rsp_valid[0]),.rd_rsp_ready(bulk_rsp_ready[0]),.rd_fault(bulk_fault),
  .rsp_valid(load_rsp_valid),.rsp_ready(1'b1),.rsp_fault(load_rsp_fault),.busy(loader_busy));
 npu_input_tile_loader #(.SHARE_GEOMETRY_MULTIPLIER(1),.WIDTH_W(7),.ENABLE_STALL_DIAG(ENABLE_STALL_DIAG)) u_input_loader (
  .stall_events(stall_i),.stall_window_count(stall_input_window),
  .clk(clk),.rst_n(rst_n),.cmd_valid(input_pending),.cmd_ready(input_load_ready),
  .cmd_page(load_page),.cmd_a16(a16),.cmd_base(a_base),.cmd_ih(ih),.cmd_iw(iw),
  .cmd_channel_start(load_start),.cmd_channels(load_count),
  .cmd_y(input_plane_cache ? 32'sd0 : ($signed(tile_y<<sh[1])-$signed(pt))),
  .cmd_x(input_stripe ? 32'sd0 : ($signed(tile_x<<sw[1])-$signed(pl))),
  .cmd_height(input_height),.cmd_width(input_width),
  .wr_valid(input_wr_valid),.wr_ready(input_wr_ready),.wr_page(input_wr_page),.wr_bank(input_wr_bank),
  .wr_word(input_wr_word),.wr_data(input_wr_data),
  .rd_cmd_valid(bulk_cmd_valid[1]),.rd_cmd_ready(bulk_cmd_ready[1]),
  .rd_cmd_addr(bulk_cmd_addr[32+:32]),.rd_cmd_bytes(bulk_cmd_bytes[32+:32]),
  .rd_valid(bulk_valid[1]),.rd_ready(bulk_ready[1]),.rd_data(bulk_data),.rd_keep(bulk_keep),.rd_last(bulk_last),
  .rd_rsp_valid(bulk_rsp_valid[1]),.rd_rsp_ready(bulk_rsp_ready[1]),.rd_fault(bulk_fault),
  .rsp_valid(input_load_rsp),.rsp_ready(1'b1),.rsp_fault(input_load_fault),.busy(input_loader_busy),.row_words());
 npu_stream_read_fabric #(.ENABLE_STALL_DIAG(ENABLE_STALL_DIAG)) u_bulk (
  .stall_other_owner(stall_owner),
  .clk(clk),.rst_n(rst_n),.c_cmd_valid(bulk_cmd_valid),.c_cmd_ready(bulk_cmd_ready),
  .c_cmd_addr(bulk_cmd_addr),.c_cmd_bytes(bulk_cmd_bytes),.c_valid(bulk_valid),.c_ready(bulk_ready),
  .c_data(bulk_data),.c_keep(bulk_keep),.c_last(bulk_last),.c_rsp_valid(bulk_rsp_valid),
  .c_rsp_ready(bulk_rsp_ready),.c_fault(bulk_fault),
  .cmd_valid(rd_cmd_valid),.cmd_ready(rd_cmd_ready),.cmd_addr(rd_cmd_addr),.cmd_bytes(rd_cmd_bytes),
  .valid(rd_valid),.ready(rd_ready),.data(rd_data),.keep(rd_keep),.last(rd_last),
  .rsp_valid(rd_rsp_valid),.rsp_ready(rd_rsp_ready),.fault(rd_fault),.idle(bulk_idle));
 assign packed_req_act=input_rsp_data;
 assign packed_req_spatial4=spatial4;
 assign packed_req_act4=spatial_act;
 // Spatial mode consumes only lanes 0..7 and broadcasts them inside the PE.
 // Leave the unused upper lanes connected directly to the WBUF instead of
 // inserting 1536 zero-selection gates. Legacy mode still receives all lanes.
 // Both modes use one 4:1 data selector. Encode the legacy identity
 // selection into the two-bit read tag, instead of placing another 512-bit
 // mode mux after Cout selection. The read response owns this selector until
 // PE acceptance; geometry/Cout control no longer fans out into its data cone.
 logic [1:0] weight_response_group;
 always_ff @(posedge clk) begin
  if(weight_read_valid && bank_ready)
   weight_response_group <= spatial4 ? cout_subgroup : 2'd0;
 end
 // Carry only the two-bit read-owned selection tag to the PE. In the
 // optional shared-selector mode the 2048-bit bank order stays natural and
 // exactly one 512-bit selector is shared with native weight preloading.
 assign packed_req_weight_group=SHARED_WEIGHT_SELECT ? weight_response_group : 2'd0;
 assign packed_req_weight=SHARED_WEIGHT_SELECT ? bank_data :
     {bank_data[2047:512],bank_data[{weight_response_group,9'd0}+:512]};
 always_comb begin
  // Spatial tile origins are multiples of 4 rows / 8 columns. CHECK
  // restricts stride to 1/2 and dilation to 1; no wide address multiplier.
  span_y=({3'd0,feed_y[1:0]}<<sh[1])+{2'd0,vector_ky[2:0]};
  // Each spatial lane uses the existing IBUF byte selector and read port.
  // Increment the pixel coordinate before word/byte decomposition, including
  // crossings, instead of independently shifting four 64-bit bank outputs.
  span_x=({2'd0,feed_x[2:0]}<<sw[1])+{2'd0,vector_kx[2:0]}+
      (spatial4 ? {30'd0,spatial_sent[1:0]} : 32'd0);
  input_linear=span_x<<(a16 ? 1 : 0);
  input_word_address=(vector_cgroup[1:0]*input_height[3:0]+span_y[3:0])*input_row_words[2:0]+(input_linear>>3);
  if(input_stripe)begin
   // X is global within the cached row; Y is global only for small planes.
   // Use the existing IBUF byte selector for each of the four space lanes.
   input_linear={25'd0,input_cache_byte};
   input_word_address={23'd0,input_cache_word};
  end
  input_mask=0;
  for(integer n=0;n<8;n=n+1)input_mask[n]=({vector_cgroup[1:0],3'b000}+n)<cin_count;
 end
 // feed_active is a registered tile/dot lease. It is asserted only after
 // input fill completes and remains live until presented reads/PE requests
 // drain, including cancellation. Page changes occur after that lease ends.
 npu_stream_ibuf #(.RESERVE_PENDING_READ_PAGE(1),.READ_LATENCY(2),.EXTERNAL_READ_RESERVATION(1)) u_input (
  .reserve_valid(feed_active),.reserve_page(page),
  .clk(clk),.rst_n(rst_n),.wr_valid(input_wr_valid),.wr_ready(input_wr_ready),.wr_page(input_wr_page),
  .wr_bank(input_wr_bank),.wr_word(input_wr_word),.wr_data(input_wr_data),
  .rd_valid(input_read_valid),.rd_ready(input_rd_ready),.rd_page(page),
  .rd_word(input_word_address[7:0]),
  .rd_byte(input_linear[2:0]),.rd_a16(a16),.rd_mask(input_mask),
  .rsp_valid(input_rsp_valid),.rsp_ready(input_response_ready),.rsp_data(input_rsp_data),.rsp_words());
 npu_banked_buffer #(.BANKS(32),.DATA_W(64),.ROW_W(ROW_W),.TAG_W(4),.RESERVE_PENDING_READ_PAGE(1),.READ_LATENCY(2),.ENABLE_READ_BANK_MASK(1'b0)) u_weights (
  .clk(clk),.rst_n(rst_n),.wr_valid(weight_wr_valid),.wr_ready(weight_wr_ready),.wr_page(weight_wr_page),
  .wr_bank(weight_wr_bank),.wr_row(weight_store_row[ROW_W-1:0]),.wr_data(weight_wr_data),.wr_strb(weight_wr_strb),
  .rd_valid(weight_read_valid),.rd_ready(bank_ready),.rd_page(weight_read_page),
  .rd_row(spatial4 ? spatial_rows[spatial_weight_head] : weight_read_row[ROW_W-1:0]),
  .rd_tag(spatial4 ? {spatial_first[spatial_weight_head],spatial_last[spatial_weight_head],spatial_weight_head} :
      {vector_row==0,vector_row+1'b1==vector_rows,2'd0}),.rsp_valid(bank_rsp_valid),
  .rd_bank_mask(spatial4 ? (32'h000000ff<<{cout_subgroup,3'b000}) : 32'hffffffff),
  .rsp_ready(weight_response_ready),.rsp_data(bank_data),.rsp_tag({bank_first,bank_last,bank_spatial_slot}),.page_conflict(stall_wbuf_conflict));
 npu_scalar_fabric #(.CLIENTS(2)) u_memory (
  .clk(clk),.rst_n(rst_n),.c_req_valid(c_req_valid),.c_req_ready(c_req_ready),
  .c_req_write(c_req_write),.c_req_addr(c_req_addr),.c_req_size(c_req_size),.c_req_wdata(c_req_wdata),
  .c_rsp_valid(c_rsp_valid),.c_rsp_ready(c_rsp_ready),.c_rsp_rdata(c_rsp_rdata),.c_rsp_fault(c_rsp_fault),
  .req_valid(mem_req_valid),.req_ready(mem_req_ready),.req_write(mem_req_write),.req_addr(mem_req_addr),
  .req_size(mem_req_size),.req_wdata(mem_req_wdata),.rsp_valid(mem_rsp_valid),.rsp_ready(mem_rsp_ready),
  .rsp_rdata(mem_rsp_rdata),.rsp_fault(mem_rsp_fault),.idle(memory_idle),.active_owner());

 // Each accepted IBUF response updates one full-width word in one step
 // bank. Slot is the only write address; data needs no reset. Asynchronous
 // reads retain the existing zero-latency PE payload and all A16 bits.
 generate for(genvar step=0;step<4;step=step+1)begin:g_spatial_payload
  (* ram_style="distributed" *) logic [127:0] words[0:3];
  always_ff @(posedge clk)begin
   if(rst_n && spatial4 && input_rsp_valid && input_response_ready &&
      spatial_response_lane==2'(step))
    words[spatial_response_slot]<=input_rsp_data;
  end
  assign spatial_act[step*128+:128]=words[bank_spatial_slot];
 end endgenerate

 always_ff @(posedge clk) begin
  if(!rst_n) begin
   tile_first_pixel<=0;stream_output_base<=0;cin_limit<=0;cin_count<=0;cin_start<=0;tile_x<=0;tile_y<=0;tile_width<=0;tile_height<=0;
   input_width<=0;input_height<=0;input_row_words<=0;input_pending<=0;input_loaded<=0;
   input_stripe<=0;input_plane_cache<=0;input_fill_page<=0;input_cached_y[0]<=0;input_cached_y[1]<=0;
   vector_cgroup<=0;vector_ky<=0;vector_kx<=0;local_pixel<=0;
   cout_subgroup<=0;spatial_tail<=0;spatial_weight_head<=0;spatial_sent<=0;spatial_gather<=0;spatial4<=0;
   spatial_act_valid<=0;spatial_weight_issued<=0;spatial_first<=0;spatial_last<=0;
   spatial_read_tag<=0;spatial_response_tag<=0;
   state<=IDLE;mem_return<=IDLE;math_return<=IDLE;rsp_tag<=0;rsp_fault<=0;rsp_completed<=0;
   a_base<=0;y_base<=0;weight_base<=0;bias_base<=0;mult_base<=0;shift_base<=0;scratch_base<=0;
   ic_q<=0;ih_q<=0;iw_q<=0;oc_q<=0;oh_q<=0;ow_q<=0;kh_q<=0;kw_q<=0;sh_q<=0;sw_q<=0;pt_q<=0;pl_q<=0;dh_q<=0;dw_q<=0;
   full_k<=0;aplane<=0;yplane<=0;bdtype<=0;mdtype<=0;sdtype<=0;a16<=0;command_bad<=0;shape_bad<=0;
   packed_weights<=0;packed_bad<=0;packed_bank_stride<=0;
   fused_output<=0;final_dtype<=3;final_base<=0;final_end<=0;
   final_block_y<=0;stream_final_base<=0;
   resnet_legacy<=0;resnet_shift<=0;
   oc_global<=0;block_w<=0;block_y<=0;channels<=0;
   page<=0;kbase<=0;kcount<=0;split_k<=0;tile_c<=0;tile_ky<=0;tile_kx<=0;
   oy<=0;ox<=0;pixel<=0;scratch_pixel<=0;vector_row<=0;vector_rows<=0;input_lane<=0;output_lane<=0;
   origin_y<=0;origin_x<=0;dilation_row_step<=0;output_row_step<=0;padding_rows<=0;
   pixel_row_offset<=0;tile_row_offset<=0;gather_row_offset<=0;
   tile_dy<=0;tile_dx<=0;gather_dy<=0;gather_dx<=0;lane_output_address<=0;
   gather_cptr<=0;gather_ky<=0;gather_kx<=0;kcursor<=0;iy<=0;ix<=0;
   raw<=0;biased<=0;multiplier<=0;mem_value<=0;math_value<=0;
    geometry_index<=0;kernel_area<=0;tile_a<=0;input_bytes<=0;output_bytes<=0;weight_bytes<=0;
   aend<=0;yend<=0;wend<=0;scratch_end<=0;region_bad<=0;
   load_pending<=0;load_page<=0;load_w<=0;load_start<=0;load_count<=0;loaded<=0;loader_fault<=0;
   main_write<=0;main_addr<=0;main_size<=0;main_data<=0;
   math_op<=0;math_a<=0;math_b<=0;math_shift<=0;
   feed_pending<=0;
   feed_active<=0;feed_y<=0;feed_x<=0;epilogue_fault_q<=0;
   output_page<=0;output_fault_q<=0;
   cached_start[0]<=0;cached_start[1]<=0;cached_count[0]<=0;cached_count[1]<=0;
   weight_residency<=0;resident_valid<=0;weight_preload_slot<=0;weight_fill_slot<=0;
   for(integer j=0;j<4;j=j+1)resident_start[j]<=0;
   for(integer j=0;j<32;j=j+1) accum[j]<=0;
  end else begin
   if(output_rsp_valid&&output_fault!=0&&output_fault_q==0)output_fault_q<=output_fault;
   if(partial_sum_valid&&partial_overflow&&epilogue_fault_q==0)epilogue_fault_q<=8'h04;
   if(epilogue_valid)begin
    if(epilogue_fault!=0&&epilogue_fault_q==0)epilogue_fault_q<=epilogue_fault;
    if(output_pixel_valid)rsp_completed<=rsp_completed+1'b1;
   end
   case({feed_launch,packed_req_valid&&packed_req_ready})
    2'b10:feed_pending<=feed_pending+1'b1;
    2'b01:feed_pending<=feed_pending-1'b1;
    default:;
   endcase
   if((!spatial4&&feed_launch) || spatial_issue_done)begin
    vector_row<=vector_row+1'b1;
    if(vector_kx+1<kw)vector_kx<=vector_kx+1'b1;
    else begin vector_kx<=0;
     if(vector_ky+1<kh)vector_ky<=vector_ky+1'b1;
     else begin vector_ky<=0;vector_cgroup<=vector_cgroup+1'b1;end
    end
   end
   if(spatial4)begin
    if(feed_launch)begin
     spatial_gather<=1;spatial_sent<=1;
     spatial_act_valid[spatial_tail]<=0;spatial_weight_issued[spatial_tail]<=0;
     spatial_rows[spatial_tail]<=weight_read_row[ROW_W-1:0];
     spatial_first[spatial_tail]<=vector_row==0;
     spatial_last[spatial_tail]<=vector_row+1'b1==vector_rows;
    end
    if(spatial_read_next&&input_rd_ready)begin
     if(spatial_sent==3)begin spatial_gather<=0;spatial_sent<=0;spatial_tail<=spatial_tail+1'b1;end
     else spatial_sent<=spatial_sent+1'b1;
    end
    if(spatial_input_fire)spatial_read_tag<={spatial_tail,spatial_sent};
    // Spatial response READY is always asserted for the active lease, so
    // tag advancement exactly mirrors the IBUF's native second stage.
    spatial_response_tag<=spatial_read_tag;
    if(input_rsp_valid&&input_response_ready)begin
     if(spatial_response_lane==3)spatial_act_valid[spatial_response_slot]<=1;
    end
    if(weight_read_valid&&bank_ready)begin
     spatial_weight_issued[spatial_weight_head]<=1;
     spatial_weight_head<=spatial_weight_head+1'b1;
    end
    if(spatial_pop)spatial_act_valid[bank_spatial_slot]<=0;
   end
   if(packed_req_valid&&packed_req_ready&&feed_last)feed_active<=0;
   // An error may stop an unfinished prefetched dot. Preserve every held
   // IBUF/WBUF response and presented PE request, then abandon only after
   // both BRAM read stages and the PE pipeline have drained. feed_pending
   // also counts a response still inside the latch before rsp_valid rises.
   if(state==ERROR_DRAIN&&feed_pending==0&&!input_rsp_valid&&!bank_rsp_valid)feed_active<=0;
   if(load_pending && load_ready)begin
    load_pending<=0;
    if(weight_residency)begin
     resident_valid[weight_preload_slot]<=0;weight_fill_slot<=weight_preload_slot;
     resident_start[weight_preload_slot]<=weight_load_start[6:0];
    end else begin
     loaded[load_page]<=0;
     cached_start[load_page]<=load_start[12:0];cached_count[load_page]<=load_count[5:0];
    end
   end
   if(input_pending && input_load_ready)begin
    input_pending<=0;input_loaded[load_page]<=0;
    input_fill_page<=load_page;input_cached_y[load_page]<=tile_y[5:0];
   end
   if(input_load_rsp)begin
    if(input_load_fault!=0)begin if(loader_fault==0)loader_fault<={4'h2,input_load_fault};end
    else if(state!=ERROR_DRAIN)input_loaded[input_fill_page]<=1;
   end
   if(load_rsp_valid) begin
    if(load_rsp_fault!=0) begin if(loader_fault==0) loader_fault<=load_rsp_fault;end
    else if(weight_residency)begin
     if(state!=ERROR_DRAIN)resident_valid[weight_fill_slot]<=1;
    end
    else loaded[load_page]<=1;
   end
   // Never revoke a stalled memory/math/PE request. At the next safe state,
   // stop issuing work, drain the prefetcher and discard unfinished dot state.
   if(deferred_fault!=0 && state!=IDLE && state!=RESPONSE && state!=ERROR_DRAIN &&
     state!=MEM_REQUEST && state!=MEM_WAIT && state!=MATH_REQUEST && state!=MATH_WAIT &&
     state!=PE_SEND && state!=BANK_REQ && state!=BANK_WAIT &&
     state!=QUANT_REQUEST && state!=QUANT_WAIT)
    fail(deferred_fault);
   else case(state)
    IDLE: if(cmd_valid) begin
     rsp_tag<=cmd_tag;rsp_fault<=0;rsp_completed<=0;
     epilogue_fault_q<=0;feed_active<=0;output_page<=0;output_fault_q<=0;
     a_base<=cmd_record[8*32+:32];y_base<=cmd_record[10*32+:32];weight_base<=cmd_record[11*32+:32];
     bias_base<=cmd_record[12*32+:32];mult_base<=cmd_record[13*32+:32];shift_base<=cmd_record[14*32+:32];
     scratch_base<=cmd_record[17*32+:32];a16<=cmd_record[20*32+:32]==16;
     // Reserved AFF1 words120/121 carry the optional WPK1 layout marker
     // and padded bytes per output-channel bank. Raw OIHW remains supported.
     packed_weights<=command_word(120)==32'h314b5057;
     packed_bank_stride<=command_word(121);
     packed_bad<=(command_word(120)!=0&&command_word(120)!=32'h314b5057)||
      (command_word(120)==0&&command_word(121)!=0)||
      (command_word(120)==32'h314b5057&&
       (command_word(70)!=3||command_word(71)!=3||(command_word(11)&7)!=0));
     resnet_legacy<=cmd_record[2*32];
     fused_output<=EXTERNAL_FUSION && cmd_record[2*32+:32]!=0 && !cmd_record[2*32];
     final_base<=cmd_record[15*32+:32];final_dtype<=cmd_record[21*32+:3];
     command_bad<=cmd_record[0+:32]!=5 ||
      (cmd_record[2*32+:32]>1 && !(EXTERNAL_FUSION && fusion_available &&
        (cmd_record[2*32+:32]==8 || cmd_record[2*32+:32]==16 || cmd_record[2*32+:32]==24) &&
        (cmd_record[2*32+:32]==16 ? cmd_record[21*32+:32]==3 :
         ((cmd_record[21*32+:32]==1 || cmd_record[21*32+:32]==2) &&
           cmd_record[18*32+:32]!=0 && !cmd_record[18*32+31] && cmd_record[19*32+:32]<=62)))) ||
      cmd_record[78*32+:32]!=1 || cmd_record[84*32+:32]!=cmd_record[64*32+:32] ||
      cmd_record[85*32+:32]!=cmd_record[67*32+:32] ||
      (cmd_record[2*32] ? (cmd_record[6*32+:32]!=1 || cmd_record[20*32+:32]!=8) : cmd_record[6*32+:32]!=3) ||
      !((cmd_record[20*32+:32]==8 && cmd_record[4*32+:32]==1) ||
        (cmd_record[20*32+:32]==16 && cmd_record[4*32+:32]==2));
     ic_q<=cmd_record[64*32+:13];ih_q<=cmd_record[65*32+:13];iw_q<=cmd_record[66*32+:13];oc_q<=cmd_record[67*32+:13];
     oh_q<=cmd_record[68*32+:13];ow_q<=cmd_record[69*32+:13];kh_q<=cmd_record[70*32+:3];kw_q<=cmd_record[71*32+:3];
     sh_q<=cmd_record[72*32+:2];sw_q<=cmd_record[73*32+:2];pt_q<=cmd_record[74*32+:13];pl_q<=cmd_record[75*32+:13];
     dh_q<=cmd_record[76*32];dw_q<=cmd_record[77*32];
     bdtype<=cmd_record[80*32+:3];mdtype<=cmd_record[81*32+:3];sdtype<=cmd_record[82*32+:3];
     // Validate in parallel with the descriptor registers, on the SAME
     // acceptance edge. CHECK consumes only these registered predicates,
     // rather than a wide shape comparison plus the FSM decode. Preserve
     // the original low-three-bit coefficient dtype and legacy semantics.
     shape_bad[0]<=command_word(64)==0 || command_word(67)==0 ||
      command_word(65)==0 || command_word(66)==0 || command_word(68)==0 || command_word(69)==0 ||
      command_word(64)>4096 || command_word(67)>4096 || command_word(65)>4096 ||
      command_word(66)>4096 || command_word(68)>4096 || command_word(69)>4096;
     shape_bad[1]<=command_word(70)==0 || command_word(71)==0 ||
      command_word(72)==0 || command_word(73)==0 || command_word(76)!=1 || command_word(77)!=1 ||
      command_word(70)>7 || command_word(71)>7 || command_word(72)>2 || command_word(73)>2 ||
      command_word(74)>4096 || command_word(75)>4096 ||
      ((command_word(80)&7)!=3 && (command_word(80)&7)!=4) ||
      ((command_word(81)&7)!=3 && (command_word(81)&7)!=4) ||
      ((command_word(82)&7)!=3 && (command_word(82)&7)!=4);
     shape_bad[2]<=cmd_record[2*32] && (command_word(20)==16 ||
      command_word(64)>512 || command_word(67)>512 || command_word(65)>224 || command_word(66)>224 ||
      (command_word(70)!=1 && command_word(70)!=3 && command_word(70)!=7) || command_word(71)!=command_word(70) ||
      command_word(72)>2 || command_word(73)>2 || command_word(76)!=1 || command_word(77)!=1 ||
      (command_word(80)&7)!=3 || (command_word(81)&7)!=3 || (command_word(82)&7)!=3);
     full_k<=cmd_record[86*32+:32];
     aplane<=cmd_record[87*32+:32];yplane<=cmd_record[88*32+:32];
     loaded<=0;resident_valid<=0;weight_residency<=0;
     input_loaded<=0;input_stripe<=0;input_plane_cache<=0;loader_fault<=0;state<=CHECK;
    end
    CHECK: begin
     if(command_bad || (|shape_bad) || packed_bad) fail(8'h01);
     else begin geometry_index<=2;state<=GEOMETRY_SEND;end
    end
    GEOMETRY_SEND: arithmetic(3'd1,geometry_a,geometry_b,7'd0,GEOMETRY_VALUE);
    GEOMETRY_VALUE: begin
     case(geometry_index)
      1:if(math_value!=$signed({32'd0,packed_bank_stride}))fail(8'h01);
       else begin geometry_index<=3;state<=GEOMETRY_SEND;end
      2: begin kernel_area<=math_value[31:0];geometry_index<=packed_weights?1:3;state<=GEOMETRY_SEND;end
      3,4,5: state<=GEOMETRY_CHECK;
      6: begin input_bytes<=$unsigned(math_value);geometry_index<=7;state<=GEOMETRY_SEND;end
      7: begin output_bytes<=$unsigned(math_value);geometry_index<=8;state<=GEOMETRY_SEND;end
      8: begin weight_bytes<=$unsigned(math_value);geometry_index<=10;state<=GEOMETRY_SEND;end
      10: begin dilation_row_step<=math_value[31:0];geometry_index<=11;state<=GEOMETRY_SEND;end
      11: begin output_row_step<=math_value[31:0];geometry_index<=12;state<=GEOMETRY_SEND;end
      12: begin padding_rows<=math_value[31:0];state<=REGION_SUM;end
      default: fail(8'h01);
     endcase
    end
    GEOMETRY_CHECK:if(!geometry_match)fail(8'h01);
     else begin geometry_index<=geometry_index+1'b1;state<=GEOMETRY_SEND;end
    // Separate the full-width sums, bounds/overlap comparisons and commit
    // enable. Keep 65 bits so malformed descriptors cannot wrap a region end.
    REGION_SUM: begin
     aend<={33'd0,a_base}+{1'b0,input_bytes};
     yend<={33'd0,y_base}+{1'b0,output_bytes};
     final_end<={33'd0,final_base}+{1'b0,(output_bytes>>output_scale)};
     wend<={33'd0,weight_base}+{1'b0,weight_bytes};
     // Scratch always stores 32 INT64 lanes per spatial pixel, independent of
     // whether the final output plane contains I8 or I32 elements.
     scratch_end<={33'd0,scratch_base}+({33'd0,yplane}<<(resnet_legacy ? 8 : 6));
     state<=REGION_VALIDATE;
    end
    REGION_VALIDATE: begin
     region_bad<=aend>65'h100000000 || yend>65'h100000000 || wend>65'h100000000 ||
       (fused_output && (final_end>65'h100000000 ||
         ({33'd0,final_base}<aend && {33'd0,a_base}<final_end) ||
         (full_k>TILE_K && {33'd0,final_base}<scratch_end && {33'd0,scratch_base}<final_end))) ||
       (full_k>TILE_K && (scratch_base[2:0]!=0 || scratch_end>65'h100000000 ||
        ({33'd0,scratch_base}<aend && {33'd0,a_base}<scratch_end) ||
        ({33'd0,scratch_base}<yend && {33'd0,y_base}<scratch_end))) ||
       ({33'd0,a_base}<yend && {33'd0,y_base}<aend);
     state<=REGION_CHECK;
    end
    REGION_CHECK: begin
     if(region_bad) fail(8'h01);
     else begin
      oc_global<=0;block_w<=weight_base;block_y<=y_base;
      final_block_y<=final_base;
      // Validated, disjoint tensor regions and immutable command geometry
      // scope the cache. All other shapes retain the original tile loader.
      input_stripe<=ENABLE_INPUT_STRIPE && ic<=64 && iw<=64 && oh==ih && ow==iw &&
       kh==1 && kw==1 && sh==1 && sw==1 && pt==0 && pl==0 && dh==1 && dw==1;
      // Four Cin groups * eight rows * eight A16 words is 256 words/bank.
      // Immutable, disjoint input pages can therefore survive all Y/OC tiles.
      input_plane_cache<=ENABLE_INPUT_STRIPE && ic<=64 && ih<=8 && iw<=32 && oh==ih && ow==iw &&
       kh==1 && kw==1 && sh==1 && sw==1 && pt==0 && pl==0 && dh==1 && dw==1;
      // Both A8 and A16 are already validated. For 3x3/stride<=2, the
      // largest 32Cin input tile needs <=4*9*5=180 IBUF words per bank.
      // WPK1 validation fixes each resident weight fragment at 36 rows.
      weight_residency<=ENABLE_WEIGHT_RESIDENCY && !resnet_legacy && packed_weights &&
       ic==128 && oc==128 && kh==3 && kw==3 && full_k==1152 && packed_bank_stride==1152 &&
       (2*WEIGHT_SLOT_ROWS<=(1<<ROW_W));
      channels<=oc<32 ? oc[5:0] : 6'd32;state<=STREAM_CONFIG;
     end
    end
    STREAM_CONFIG:begin
     stream_output_base<=block_y;
     stream_final_base<=final_block_y;
     resident_valid<=0;weight_preload_slot<=0;
     if(!input_plane_cache)input_loaded<=0;
     tile_x<=0;tile_y<=0;tile_width<=ow<8 ? ow : 8;tile_height<=oh<4 ? oh : 4;
     // At most four groups of eight channels, limited by WBUF rows and
     // the padded spatial extent in one 16-KiB IBUF page.
     cin_limit<=32;state<=INITIAL_LOAD;
    end
    INITIAL_LOAD: begin
     output_lane<=0;
     memory(0,bias_base+(oc_global<<(bdtype==4 ? 3 : 2)),size_of(bdtype),64'sd0,PARAM_BIAS);
    end
    PARAM_BIAS:begin
     bias_cache[output_lane]<=mem_value;
     memory(0,param_address(mult_base,mdtype),size_of(mdtype),64'sd0,PARAM_MULT);
    end
    PARAM_MULT:begin
     mult_cache[output_lane]<=mem_value;
     memory(0,param_address(shift_base,sdtype),size_of(sdtype),64'sd0,PARAM_SHIFT);
    end
    PARAM_SHIFT:begin
     shift_cache[output_lane]<=mem_value;
     if(output_lane+1'b1<channels)begin
      output_lane<=output_lane+1'b1;state<=PARAM_BIAS;
      // Address for the NEXT channel is staged before entering MEM_REQUEST.
      memory(0,bias_base+((oc_global+{26'd0,output_lane}+1'b1)<<(bdtype==4 ? 3 : 2)),size_of(bdtype),64'sd0,PARAM_BIAS);
     end else begin
      output_lane<=0;
      state<=weight_residency ? WEIGHT_PRELOAD : START_SPATIAL;
     end
    end
    WEIGHT_PRELOAD:begin
     // No refill is allowed once this block starts computing. The old
     // page-granular read/write exclusion remains sufficient for all slots.
     if(!load_pending && !loader_busy && !input_pending && !input_loader_busy && bulk_idle &&
        !feed_active && feed_pending==0 && !input_rsp_valid && !bank_rsp_valid && !packed_busy)begin
      load_w<=block_w;load_pending<=1;state<=WEIGHT_PRELOAD_WAIT;
     end
    end
    WEIGHT_PRELOAD_WAIT:if(load_rsp_valid && load_rsp_fault==0)begin
     // The loader response follows every bank's final BRAM write and DMA
     // terminal response. Changing the next slot cannot retarget live work.
     if(weight_preload_slot==2'd3)state<=START_SPATIAL;
     else begin weight_preload_slot<=weight_preload_slot+1'b1;state<=WEIGHT_PRELOAD;end
    end
    START_SPATIAL:begin
     spatial4<=ENABLE_PE_SPATIAL4 && sh==1 && sw==1 && channels==32 &&
       (tile_width==8 || tile_width==4);
     tile_after_x<=tile_x+tile_width;
     tile_after_y<=tile_y+tile_height;
     input_width<=input_stripe ? iw[6:0] :
       ((({2'd0,tile_width[3:0]}-6'd1)<<sw[1])+{3'd0,kw[2:0]});
     input_height<=input_plane_cache ? ih[5:0] :
       (({3'd0,tile_height[2:0]}-6'd1)<<sh[1])+{3'd0,kh[2:0]};
     tile_first_pixel<=tile_y[11:0]*ow[12:0]+tile_x[11:0];state<=TILE_SIZE;
    end
    TILE_SIZE:begin
     // Tile geometry is immutable until ADVANCE_SPATIAL consumes these flags.
     tile_last_x<=tile_after_x-1'b1;tile_last_y<=tile_after_y-1'b1;
     tile_more_x<=tile_after_x<ow;tile_more_y<=tile_after_y<oh;
     tile_next_width<=(ow-tile_after_x)<8 ? ow-tile_after_x : 8;
     tile_next_height<=(oh-tile_after_y)<4 ? oh-tile_after_y : 4;
     input_row_words<=(({1'b0,input_width}<<a16)+7'd7)>>3;state<=TILE_CAP_HEIGHT;
    end
    TILE_CAP_HEIGHT:state<=TILE_CAP_WORDS;
    TILE_CAP_WORDS:state<=TILE_INPUT_VALUE;
    TILE_INPUT_VALUE:begin
     if(capacity_weights>10'd128 || capacity_inputs>11'd256)begin
      cin_limit<=cin_limit-8;state<=TILE_CAP_HEIGHT;
     end
     else if(cin_limit==0)fail(8'h01);
     else if(weight_residency && (cin_limit!=32 || !resident_block_ready))fail(8'h01);
     else begin
      cin_start<=0;cin_count<=ic<cin_limit ? ic[5:0] : cin_limit;
      kbase<=0;
      load_start<=0;load_count<=ic<cin_limit ? ic[5:0] : cin_limit;
      load_w<=block_w;load_page<=0;page<=0;
      if(!input_stripe)input_loaded<=0;
      else if(!first_input_hit)input_loaded[0]<=0;
      load_pending<=!weight_residency && !first_weight_hit;input_pending<=!first_input_hit;state<=KCOUNT_SETUP;
     end
    end
    KCOUNT_SETUP:begin kcount<=cin_count*kernel_area[5:0];state<=WAIT_TILE;end
    WAIT_TILE:if(weight_fragment_ready&&input_loaded[page])state<=TILE_BEGIN;
    TILE_BEGIN:begin
     if(kbase+kcount<full_k)begin
      load_pending<=!weight_residency && !next_weight_hit;input_pending<=!next_input_hit;load_page<=!page;load_w<=block_w;
      if(!next_input_hit)input_loaded[!page]<=0;
      load_start<=cin_start+cin_count;
      load_count<=next_c;
     end
     oy<=tile_y;ox<=tile_x;local_pixel<=0;pixel<={8'd0,tile_first_pixel};cout_subgroup<=0;state<=BEGIN_PIXEL;
    end
    BEGIN_PIXEL:begin
     start_dot(oy,ox);state<=INPUT_READ;
    end
    INPUT_READ:begin
     if(packed_req_valid&&packed_req_ready&&feed_last)state<=PE_WAIT;
    end
    PE_WAIT: if(packed_rsp_valid) begin
     if(packed_rsp_fault!=0) fail(8'h04);
     else begin
      for(integer j=0;j<32;j=j+1) accum[j]<=$signed(packed_rsp_acc[j*64+:64]);
      output_lane<=0;lane_output_address<=block_y+(pixel<<(resnet_legacy ? 0 : 2));state<=kbase==0?COMBINE:PSUM_READ;
      if(deferred_fault==0 && !spatial4)begin
       if(ox<tile_last_x)start_dot(oy,ox+1'b1);
       else if(oy<tile_last_y)start_dot(oy+1'b1,tile_x);
      end
     end
    end
    COMBINE: if(kbase==0) begin raw<=resnet_legacy ? wrap40(accum[output_lane]) : accum[output_lane];state<=FINAL_CHECK;end
     else state<=PSUM_READ;
    PSUM_READ:advance_lane(PSUM_READ);
    FINAL_CHECK: begin
     // Partial K fragments update local PSum. The final fragment submits one
     // tagged lane to the independent epilogue and immediately advances.
     // The first K fragment also writes one local PSum per cycle. Subsequent
     // fragments run the independent synchronous read/add/write pipeline.
     advance_lane(FINAL_CHECK);
    end
    NEXT_LANE:advance_lane(COMBINE);
    TILE_FINISH:if(!epilogue_busy&&!partial_busy)begin
     if(!input_stripe)input_loaded[page]<=0;
     if(kbase+kcount<full_k)begin
      kbase<=kbase+kcount;cin_start<=cin_start+cin_count;
      cin_count<=next_c;
      page<=!page;state<=KCOUNT_SETUP;
     end else state<=OUTPUT_COMMAND;
    end
    // The accepted descriptor owns the sealed page until its terminal write
    // response. The compute FSM moves to the other page immediately. If the
    // writer is slower, OUTPUT_COMMAND holds the second page without reuse.
    OUTPUT_COMMAND:if(output_ready)begin output_page<=!output_page;state<=ADVANCE_SPATIAL;end
    ADVANCE_SPATIAL:if(tile_more_x)begin
      tile_x<=tile_after_x;tile_width<=tile_next_width;
      state<=START_SPATIAL;
     end else if(tile_more_y)begin
       // Row stripes change their Y tag; complete small planes remain valid.
       if(!input_plane_cache)input_loaded<=0;
      tile_x<=0;tile_width<=ow<8 ? ow : 8;tile_y<=tile_after_y;
      tile_height<=tile_next_height;state<=START_SPATIAL;
     end else state<=NEXT_OC;
    NEXT_OC: begin
     resident_valid<=0;
     if(oc_global+channels==oc) begin
      if(!load_pending && !loader_busy && !input_pending && !input_loader_busy && !output_busy && bulk_idle && memory_idle) state<=RESPONSE;
     end else begin
      oc_global<=oc_global+channels;
      channels<=(oc-oc_global-channels)<32 ? (oc-oc_global-channels) : 6'd32;
      loaded<=0;state<=STREAM_CONFIG;
     end
    end
    MEM_REQUEST: if(c_req_ready[1]) state<=MEM_WAIT;
    MEM_WAIT: if(c_rsp_valid[1]) begin
     if(c_rsp_fault[7:4]!=0) fail({4'h2,c_rsp_fault[7:4]});
     else begin mem_value<=c_rsp_rdata[127:64];state<=mem_return;end
    end
    MATH_REQUEST: if(math_ready) state<=MATH_WAIT;
    MATH_WAIT: if(math_valid) begin
     if(math_fault!=0) fail(8'h04);
     else begin math_value<=math_result;state<=math_return;end
    end
    ERROR_DRAIN: begin
     input_loaded<=0;resident_valid<=0;
     if(!load_pending && !loader_busy && !input_pending && !input_loader_busy && !output_busy && !epilogue_busy && !partial_busy &&
                   !feed_active && feed_pending==0 && !input_rsp_valid && !bank_rsp_valid && bulk_idle && memory_idle && !packed_busy && packed_abandon_ready)
     state<=RESPONSE;
    end
    RESPONSE: begin input_loaded<=0;resident_valid<=0;if(rsp_ready) state<=IDLE;end
    default: fail(8'h01);
   endcase
  end
 end
// STALL_DIAGNOSTIC_BEGIN
 generate if(ENABLE_STALL_DIAG)begin:g_stall_diag
 reg [84:0] stall_conv;
 always @*begin
  stall_conv=0;
  stall_conv[1]=observation_events[1];
  stall_conv[2]=state==WAIT_TILE&&!input_loaded[page]&&weight_fragment_ready;
  stall_conv[3]=state==WAIT_TILE&&input_loaded[page]&&!weight_fragment_ready;
  stall_conv[4]=state==WAIT_TILE&&!input_loaded[page]&&!weight_fragment_ready;
  stall_conv[5]=observation_events[3];stall_conv[6]=observation_events[4];
  stall_conv[67]=stall_owner[1];stall_conv[68]=stall_owner[0];
  stall_conv[76]=stall_wbuf_conflict;
  // Slot78 is supplied by the dispatch arbitration observer.
  stall_conv[79]=packed_req_valid&&packed_req_ready;
 end
 assign stall_events=stall_i|stall_w|stall_conv;
 assign stall_input_bytes=bulk_cmd_bytes[63:32];
 assign stall_weight_bytes=bulk_cmd_bytes[31:0];
 assign stall_window_count=stall_input_window;
 end else begin:g_no_stall_diag
 assign stall_events=0;assign stall_input_bytes=0;assign stall_weight_bytes=0;assign stall_window_count=0;
 end endgenerate
// STALL_DIAGNOSTIC_END
endmodule
