`timescale 1ns/1ps
// NCHW -> channel-bank input tile. The immutable model/workspace layout is
// preserved. Nearby clipped rows share a bounded DMA descriptor; inter-row
// gaps are discarded locally. The shared transport retains burst splitting.
module npu_input_tile_loader #(
 // Keep the original six-bit interface for existing standalone users. The
 // streaming convolution selects seven bits to represent a full 64-column
 // stripe without using zero as a special width encoding.
 parameter integer WIDTH_W=6,
 parameter bit ENABLE_STALL_DIAG=1'b1,
 parameter bit SHARE_GEOMETRY_MULTIPLIER=1'b0,
 parameter bit ENABLE_ROW_COALESCE=1'b1,
 parameter integer MAX_COALESCE_BYTES=512
) (
 output wire [4:0] stall_window_count,
 output reg [84:0] stall_events,
 input wire clk,rst_n,
 input wire cmd_valid,output wire cmd_ready,input wire cmd_page,cmd_a16,
 input wire [31:0] cmd_base,cmd_ih,cmd_iw,cmd_channel_start,cmd_channels,
 input wire signed [31:0] cmd_y,cmd_x,
 input wire [5:0] cmd_height,
 input wire [WIDTH_W-1:0] cmd_width,
 output wire wr_valid,input wire wr_ready,output wire wr_page,
 output wire [2:0] wr_bank,output wire [7:0] wr_word,output wire [63:0] wr_data,
 output wire rd_cmd_valid,input wire rd_cmd_ready,
 output wire [31:0] rd_cmd_addr,rd_cmd_bytes,
 input wire rd_valid,output wire rd_ready,input wire [63:0] rd_data,
 input wire [7:0] rd_keep,input wire rd_last,
 input wire rd_rsp_valid,output wire rd_rsp_ready,input wire [3:0] rd_fault,
 output wire rsp_valid,input wire rsp_ready,output reg [3:0] rsp_fault,
 output wire busy,output reg [7:0] row_words
);
 typedef enum logic [4:0]{IDLE,CHECK,CAP_HEIGHT,CAP_WORDS,CAP_CHECK,
  ROW_BEGIN,ROW_PRODUCT,ROW_OFFSET,ROW_ADDR,ROW_END,ROW_ADDR_CHECK,
  SEND,BUILD,STORE,ROW_DRAIN,NEXT_ROW,DRAIN,RESPONSE,
  SETUP,CHANNEL_OFFSET,OFFSET_DONE,COALESCE,ROW_GAP}state_t;
 state_t state,after_store;
 reg page,a16,row_has_data;
 reg [31:0] base;
 // Store validated geometry at its proven width. Full 32-bit command checks
 // are captured before truncation; invalid descriptors still fail in CHECK.
 // Explicit 32-bit views keep expression sizing/signedness unchanged.
 reg geometry_bad;
 reg [12:0] ih_q,iw_q;
 reg [11:0] cstart_q;
 reg [5:0] channels_q,channel_q;
 reg signed [14:0] origin_y_q,origin_x_q,global_y_q,left_x_q,right_x_q;
 wire [31:0] ih={19'd0,ih_q},iw={19'd0,iw_q},cstart={20'd0,cstart_q};
 wire [31:0] channels={26'd0,channels_q},channel={26'd0,channel_q};
 wire signed [31:0] origin_y={{17{origin_y_q[14]}},origin_y_q};
 wire signed [31:0] origin_x={{17{origin_x_q[14]}},origin_x_q};
 wire signed [31:0] global_y={{17{global_y_q[14]}},global_y_q};
 wire signed [31:0] left_x={{17{left_x_q[14]}},left_x_q};
 wire signed [31:0] right_x={{17{right_x_q[14]}},right_x_q};
 wire [12:0] cmd_channel_end={1'b0,cmd_channel_start[11:0]}+{7'd0,cmd_channels[5:0]};
 wire cmd_geometry_bad=cmd_channels==0||cmd_channels>32||cmd_ih==0||cmd_iw==0||
  cmd_ih>4096||cmd_iw>4096||cmd_height==0||cmd_width==0||cmd_width>64||
  cmd_channel_start>=4096||cmd_channel_end>13'd4096||
  cmd_y < -4096||cmd_x < -4096||cmd_y>8192||cmd_x>8192;
 reg [5:0] height,row;
 reg [WIDTH_W-1:0] width;
 reg [8:0] row_byte,logical_bytes;
 reg [31:0] row_address,row_length;
 reg [8:0] clipped_bytes;
 reg [9:0] burst_useful_bytes;
 reg [1:0] coalesced_left;
 reg [13:0] gap_remaining;
 wire [13:0] source_row_bytes={1'b0,iw_q}<<a16;
 wire [32:0] extended_length={1'b0,row_length}+{19'd0,source_row_bytes};
 wire [10:0] extended_useful={1'b0,burst_useful_bytes}+{2'd0,clipped_bytes};
 wire [6:0] next_coalesced_row={1'b0,row}+{5'd0,coalesced_left}+7'd1;
 wire signed [15:0] next_coalesced_y=$signed({global_y_q[14],global_y_q})+
     $signed({14'd0,coalesced_left})+16'sd1;
 reg [31:0] plane_bytes;
 reg [25:0] plane_product;
 reg [2:0] channel_groups;
 reg [8:0] group_rows;
 reg [13:0] capacity_words;
 reg [44:0] channel_base,skip_term;
 reg [12:0] skip_bits;
 reg [25:0] row_product;
 // CHECK and ROW_PRODUCT are disjoint existing states. Only the selected
 // registered destination consumes this unsigned 13x13 result. Retain both
 // original payload registers and every original capture/use clock.
 // Reuse the existing global_y register as the shared multiplier factor.
 // IDLE prepares ih for CHECK; ROW_BEGIN prepares origin_y+row for
 // ROW_PRODUCT. Both precede the original destination capture clocks.
 wire [12:0] geometry_factor=global_y[12:0];
 (* use_dsp="no" *) wire [25:0] shared_geometry_product=geometry_factor*iw[12:0];
 reg [7:0] target_word,group_word_base;
 reg [27:0] row_offset;
 reg [32:0] row_span_bytes;
 reg [44:0] row_start_address,row_end_address;
 // Elastic byte window plus a registered wide BRAM output. Source keeps are
 // contiguous ranges supplied by the existing bulk transport. Neither a
 // stalled output nor a partial input word can overwrite live bytes.
 reg [127:0] bytes_q;
 reg [4:0] bytes_count;
 reg [2:0] source_skip;
 reg output_valid;
 reg [63:0] output_data;
 reg [7:0] output_word;
 reg [8:0] valid_byte_first,valid_byte_end;
 reg [3:0] take_bytes,input_bytes;
 reg [3:0] next_take_bytes,left_padding;
 reg [7:0] output_byte_mask,next_output_byte_mask;
 reg [3:0] next_left_padding;
 reg [63:0] formatted_word;
 reg [8:0] first_byte,end_byte;
 initial begin
  if(WIDTH_W<6||WIDTH_W>7)$fatal(1,"npu_input_tile_loader: WIDTH_W must be 6 or 7");
  if(MAX_COALESCE_BYTES<1||MAX_COALESCE_BYTES>4096)
   $fatal(1,"npu_input_tile_loader: MAX_COALESCE_BYTES must be 1..4096");
 end
 wire output_room=!output_valid||wr_ready;
 wire emit=rst_n&&state==BUILD&&output_room&&bytes_count>=take_bytes&&
     (!row_has_data||rd_fault==0);
 wire input_fire=rd_valid&&rd_ready&&(state==BUILD||state==ROW_GAP);
 // Speculate the small counts before late wr_ready/fault/emit decisions.
 // Handshake selects a completed sum rather than enabling a subtract/add
 // chain. Input acceptance remains identical, including simultaneous emit.
 wire [4:0] count_after_emit=bytes_count-{1'b0,take_bytes};
 wire [4:0] count_after_input=bytes_count+{1'b0,input_bytes};
 wire [4:0] count_after_both=count_after_emit+{1'b0,input_bytes};
 // Gap consumption is limited to eight bytes, preserving the existing
 // four-bit byte shifter and the parallel count/ready preparation.
 wire [3:0] gap_limit=gap_remaining>=14'd8 ? 4'd8 : gap_remaining[3:0];
 wire [3:0] discard_bytes=bytes_count>={1'b0,gap_limit} ? gap_limit : bytes_count[3:0];
 wire [4:0] count_after_gap=bytes_count-{1'b0,discard_bytes};
 wire [4:0] count_after_gap_input=count_after_gap+{1'b0,input_bytes};
 wire [4:0] kept_bytes=state==ROW_GAP ? count_after_gap : (emit ? count_after_emit : bytes_count);
 wire input_room=(bytes_count<=5'd8) || (state==ROW_GAP ?
     bytes_count<=({1'b0,discard_bytes}+5'd8) :
     (emit && bytes_count<=({1'b0,take_bytes}+5'd8)));
 wire [3:0] consume_bytes=state==ROW_GAP ? discard_bytes : (emit?take_bytes:4'd0);
 wire [127:0] consumed_bytes=bytes_q>>{consume_bytes,3'b000};
 wire [63:0] incoming_word=rd_data>>{source_skip,3'b000};
 wire [63:0] incoming_mask=64'hffffffffffffffff>>{(4'd8-input_bytes),3'b000};
 // Per-word clipping is prepared before BUILD, and one word ahead on emit.
 // DMA look-ahead ready therefore uses registered clipping, rather than
 // chaining row-address comparisons and subtraction into a remote FIFO CE.
 wire [8:0] window_row_byte=state==ROW_GAP ? 9'd0 : row_byte+(state==BUILD ? 9'd8 : 9'd0);
 wire [14:0] unclipped_first=origin_x<0 ? $unsigned(-origin_x)<<a16 : 15'd0;
 wire [14:0] unclipped_end=origin_x<$signed(iw) ? (iw-$unsigned(origin_x))<<a16 : 15'd0;
 wire [63:0] positioned_word=bytes_q[63:0]<<{left_padding,3'b000};
 // Padding, including the rounded row tail, is written as actual zero data.
 // Existing row_words/address generation and PE byte order stay unchanged.
 always @* begin
  first_byte=window_row_byte;
  if(valid_byte_first>first_byte)first_byte=valid_byte_first;
  end_byte=window_row_byte+9'd8;
  if(logical_bytes<end_byte)end_byte=logical_bytes;
  if(valid_byte_end<end_byte)end_byte=valid_byte_end;
  next_take_bytes=0;
  if(row_has_data&&end_byte>first_byte)next_take_bytes=end_byte-first_byte;
  next_left_padding=first_byte-window_row_byte;
  next_output_byte_mask=0;
  for(integer b=0;b<8;b=b+1)
   next_output_byte_mask[b]=row_has_data&&(window_row_byte+b)>=first_byte&&(window_row_byte+b)<end_byte;
  input_bytes=0;
  for(integer b=0;b<8;b=b+1)input_bytes=input_bytes+rd_keep[b];
  formatted_word=0;
  for(integer b=0;b<8;b=b+1)
   if(output_byte_mask[b])
    formatted_word[b*8+:8]=positioned_word[b*8+:8];
 end
 // The row setup/SEND clocks initialize all metadata before first use. On a
 // stalled BUILD word it holds; an accepted emit prepares exactly its successor.
 // Final-word successor metadata is discarded by ROW_DRAIN.
 always @(posedge clk)if(state!=BUILD||emit)begin
  take_bytes<=next_take_bytes;left_padding<=next_left_padding;
  output_byte_mask<=next_output_byte_mask;
 end
 // CHECK rejects channels>32/cstart>=4096 before this narrow sum is used.
 // Its complete 13-bit range includes the legal exclusive channel end 4096.
 wire [12:0] channel_end={1'b0,cstart[11:0]}+{7'd0,channels[5:0]};
 assign cmd_ready=rst_n&&state==IDLE;assign busy=state!=IDLE;assign rsp_valid=rst_n&&state==RESPONSE;
 assign wr_valid=rst_n&&output_valid;assign wr_page=page;assign wr_bank=channel[2:0];
 assign wr_word=output_word;assign wr_data=output_data;
 assign rd_cmd_valid=rst_n&&state==SEND&&row_has_data;assign rd_cmd_addr=row_address;assign rd_cmd_bytes=row_length;
 assign rd_ready=rst_n&&(state==DRAIN||((state==BUILD||state==ROW_GAP)&&row_has_data&&rd_fault==0&&input_room));
 assign rd_rsp_ready=rst_n&&!output_valid&&(state==ROW_DRAIN||state==DRAIN);
 // Only control/valid needs reset. These payloads are fully written by the
 // preceding named stage before use; a reset discards their command via IDLE.
 // Do not route the reset or geometry verdict through their register enables.
 always @(posedge clk)begin
  case(state)
   IDLE:if(cmd_valid)group_word_base<=0;
   CHECK:begin
    channel_groups<=({1'b0,channels[5:0]}+7'd7)>>3;
    plane_product<=SHARE_GEOMETRY_MULTIPLIER ? shared_geometry_product : ih[12:0]*iw[12:0];
   end
   CAP_HEIGHT:group_rows<=channel_groups*height;
   CAP_WORDS:capacity_words<=group_rows*row_words[4:0];
   ROW_BEGIN:begin
    // Validated x is in [-4096,8192] and iw in [1,4096]. Byte endpoints
    // therefore fit 15 bits; row_has_data excludes a negative right end.
    // No word can consume bytes outside [0,logical_bytes). Saturating here
    // preserves an empty/outside window while bounding later arithmetic to 9b.
    valid_byte_first<=unclipped_first>logical_bytes ? logical_bytes : unclipped_first[8:0];
    valid_byte_end<=unclipped_end>logical_bytes ? logical_bytes : unclipped_end[8:0];
   end
   ROW_OFFSET:begin
    row_offset<=({2'd0,row_product}+{15'd0,left_x[12:0]})<<a16;
    row_span_bytes<={1'b0,$unsigned(right_x-left_x)}<<a16;
   end
   ROW_ADDR:row_start_address<=channel_base+{17'd0,row_offset};
   ROW_END:row_end_address<=row_start_address+{12'd0,row_span_bytes};
   // Intermediate row endpoints of bank7 are not consumed as a group base.
   // Its last row refreshes the complete endpoint before channel8 can use it.
   NEXT_ROW:begin
    if(channel[2:0]==3'd7)group_word_base<=target_word;
    if(row+1<height&&row_has_data&&global_y+1<$signed(ih))begin
     row_start_address<=row_start_address+{31'd0,source_row_bytes};
     row_end_address<=row_end_address+{31'd0,source_row_bytes};
    end
   end
   ROW_GAP:if(rd_fault==0&&gap_remaining<={10'd0,discard_bytes})begin
    row_start_address<=row_start_address+{31'd0,source_row_bytes};
    row_end_address<=row_end_address+{31'd0,source_row_bytes};
   end
   default:;
  endcase
 end
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;after_store<=BUILD;geometry_bad<=0;page<=0;a16<=0;base<=0;ih_q<=0;iw_q<=0;cstart_q<=0;channels_q<=0;channel_q<=0;
   origin_y_q<=0;origin_x_q<=0;height<=0;width<=0;row<=0;row_words<=0;row_byte<=0;logical_bytes<=0;
   global_y_q<=0;left_x_q<=0;right_x_q<=0;row_has_data<=0;row_address<=0;row_length<=0;target_word<=0;
   bytes_q<=0;bytes_count<=0;source_skip<=0;output_valid<=0;rsp_fault<=0;
   plane_bytes<=0;channel_base<=0;skip_term<=0;skip_bits<=0;row_product<=0;
   clipped_bytes<=0;burst_useful_bytes<=0;coalesced_left<=0;gap_remaining<=0;
  end else begin
   if(output_room)begin
    output_valid<=emit;
    if(emit)begin output_data<=formatted_word;output_word<=target_word;end
   end
   if(state==BUILD||state==ROW_GAP)begin
    if(state==ROW_GAP)bytes_count<=input_fire ? count_after_gap_input : count_after_gap;
    else begin
     case({emit,input_fire})
      2'b01:bytes_count<=count_after_input;
      2'b10:bytes_count<=count_after_emit;
      2'b11:bytes_count<=count_after_both;
      default:;
     endcase
    end
    bytes_q<=consumed_bytes | (input_fire ? ({64'd0,(incoming_word&incoming_mask)}<<{kept_bytes,3'b000}) : 128'd0);
    if(input_fire)source_skip<=0;
   end
   case(state)
    IDLE:if(cmd_valid)begin
     if(SHARE_GEOMETRY_MULTIPLIER)global_y_q<=$signed({2'd0,cmd_ih[12:0]});
     geometry_bad<=cmd_geometry_bad;
     page<=cmd_page;a16<=cmd_a16;base<=cmd_base;ih_q<=cmd_ih;iw_q<=cmd_iw;cstart_q<=cmd_channel_start;channels_q<=cmd_channels;
     origin_y_q<=cmd_y;origin_x_q<=cmd_x;height<=cmd_height;width<=cmd_width;
     row_words<=((({{(32-WIDTH_W){1'b0}},cmd_width}<<(cmd_a16 ? 1 : 0))+7)>>3);
     logical_bytes<={{(9-WIDTH_W){1'b0}},cmd_width}<<(cmd_a16 ? 1 : 0);
     row<=0;channel_q<=0;target_word<=0;
     bytes_count<=0;bytes_q<=0;rsp_fault<=0;state<=CHECK;
    end
    CHECK:begin
     if(geometry_bad)begin rsp_fault<=1;state<=RESPONSE;end
     else begin
      // Only validated geometry reaches the three capacity stages. Keep each
      // product and its comparison on separate clock edges, rather than
      // channel rounding -> two multiplies -> fault/state enables in one path.
      state<=CAP_HEIGHT;
     end
    end
    CAP_HEIGHT:state<=CAP_WORDS;
    CAP_WORDS:state<=CAP_CHECK;
    CAP_CHECK:if(capacity_words>14'd256)begin rsp_fault<=1;state<=RESPONSE;end
     else begin
      // 13x13 product is already registered; shifting cannot chain into it.
      plane_bytes<={6'd0,plane_product}<<a16;state<=SETUP;
     end
    SETUP:begin channel_base<={13'd0,base};skip_term<={13'd0,plane_bytes};skip_bits<=cstart[12:0];state<=CHANNEL_OFFSET;end
    CHANNEL_OFFSET:if(skip_bits==0)state<=OFFSET_DONE;
     else begin
      if(skip_bits[0])channel_base<=channel_base+skip_term;
      skip_term<=skip_term<<1;skip_bits<=skip_bits>>1;
     end
    OFFSET_DONE:if(channel_base>=45'h100000000)begin rsp_fault<=1;state<=RESPONSE;end else state<=ROW_BEGIN;
    ROW_BEGIN:begin
     global_y_q<=origin_y+$signed({26'd0,row});
     left_x_q<=origin_x<0 ? 0 : origin_x;
     right_x_q<=origin_x+$signed({{(32-WIDTH_W){1'b0}},width})>$signed(iw) ? $signed(iw) : origin_x+$signed({{(32-WIDTH_W){1'b0}},width});
     // STORE increments target_word exactly ceil(logical_bytes/8) times per
     // row. Keeping that endpoint replaces the old row-index double product.
     row_byte<=0;bytes_q<=0;bytes_count<=0;state<=ROW_PRODUCT;
     row_has_data<=origin_y+$signed({26'd0,row})>=0 && origin_y+$signed({26'd0,row})<$signed(ih)&&
      origin_x<$signed(iw)&&origin_x+$signed({{(32-WIDTH_W){1'b0}},width})>0;
    end
    ROW_PRODUCT:begin row_product<=SHARE_GEOMETRY_MULTIPLIER ? shared_geometry_product : global_y[12:0]*iw[12:0];state<=ROW_OFFSET;end
    ROW_OFFSET:begin
     // Preserve complete intermediate widths, even for an ignored padding row.
     state<=ROW_ADDR;
    end
    ROW_ADDR:begin
     state<=ROW_END;
    end
    ROW_END:begin
     state<=ROW_ADDR_CHECK;
    end
    ROW_ADDR_CHECK:if(row_has_data&&(row_start_address>=45'h100000000||row_end_address>45'h100000000))begin rsp_fault<=1;state<=RESPONSE;end
     else begin
     // Address is staged once before VALID, and remains stable through stalls.
     row_address<=row_start_address[31:0];row_length<=row_span_bytes[31:0];source_skip<=row_start_address[2:0];
     clipped_bytes<=row_span_bytes[8:0];burst_useful_bytes<={1'b0,row_span_bytes[8:0]};coalesced_left<=0;
     state<=row_has_data ? (ENABLE_ROW_COALESCE ? COALESCE : SEND) : BUILD;
    end
    COALESCE:begin
     // At most four rows, <=512 bytes by default and <=2x useful bytes.
     // Stay within the same channel and valid source rows. Endpoint checks
     // retain the full exclusive 2^32 bound before publishing a descriptor.
     if(ENABLE_ROW_COALESCE&&coalesced_left<3&&next_coalesced_row<{1'b0,height}&&
        next_coalesced_y>=0&&next_coalesced_y<$signed({3'd0,ih_q})&&
        extended_length<=MAX_COALESCE_BYTES&&
        extended_length<={21'd0,extended_useful,1'b0}&&
        row_start_address+{12'd0,extended_length}<=45'h100000000)begin
      row_length<=extended_length[31:0];burst_useful_bytes<=extended_useful[9:0];
      coalesced_left<=coalesced_left+1'b1;
     end else state<=SEND;
    end
    SEND:if(rd_cmd_ready)state<=BUILD;
    BUILD:begin
     if(rd_fault!=0&&row_has_data)begin rsp_fault<=rd_fault;bytes_count<=0;state<=DRAIN;end
     else if(emit)begin
      target_word<=target_word+1'b1;
      if(row_byte+9'd8>=logical_bytes)begin
       if(coalesced_left!=0)begin
        gap_remaining<=source_row_bytes-{5'd0,clipped_bytes};state<=ROW_GAP;
       end else state<=ROW_DRAIN;
      end
      else row_byte<=row_byte+9'd8;
     end
    end
    ROW_GAP:begin
     // Keep any following-row bytes already in the 16-byte window. The
     // registered clipping block prepares that row's first output word here.
     if(rd_fault!=0)begin rsp_fault<=rd_fault;bytes_count<=0;state<=DRAIN;end
     else begin
      gap_remaining<=gap_remaining-{10'd0,discard_bytes};
      if(gap_remaining<={10'd0,discard_bytes})begin
       row<=row+1'b1;global_y_q<=global_y+1;row_byte<=0;
       coalesced_left<=coalesced_left-1'b1;state<=BUILD;
      end
     end
    end
    ROW_DRAIN:begin
     bytes_count<=0;bytes_q<=0;
     if(!row_has_data&&!output_valid)state<=NEXT_ROW;
     else if(rd_rsp_valid&&rd_rsp_ready)begin
      if(rd_fault!=0)begin rsp_fault<=rd_fault;state<=RESPONSE;end else state<=NEXT_ROW;
     end
    end
    NEXT_ROW:if(row+1<height)begin
      row<=row+1'b1;
      // Adjacent valid rows reuse checked x geometry and advance only the
      // source stride. Padding borders still take the complete setup path.
      if(row_has_data&&global_y+1<$signed(ih))begin
       global_y_q<=global_y+1;row_byte<=0;bytes_q<=0;bytes_count<=0;state<=ROW_ADDR_CHECK;
      end else state<=ROW_BEGIN;
     end
     else if(channel+1<channels)begin
      channel_q<=channel+1'b1;channel_base<=channel_base+{13'd0,plane_bytes};row<=0;
      // Banks0..7 share one word range. At an eight-channel boundary the
      // preceding row endpoint is the next group's base; otherwise rewind.
      // CAP_CHECK guarantees every issued word fits 0..255. An endpoint of
      // 256 may wrap only in the final group, never before another group.
      if(channel[2:0]!=3'd7)target_word<=group_word_base;
      state<=ROW_BEGIN;
     end
     else state<=RESPONSE;
    DRAIN:if(rd_rsp_valid&&rd_rsp_ready)state<=RESPONSE;
    RESPONSE:if(rsp_ready)state<=IDLE;
    default:state<=IDLE;
   endcase
  end
 end
// STALL_DIAGNOSTIC_BEGIN
 generate if(ENABLE_STALL_DIAG)begin:g_stall_diag
 assign stall_window_count=bytes_count;
 reg stall_prev_request;
 always @(posedge clk)if(!rst_n)stall_prev_request<=0;else stall_prev_request<=rd_cmd_valid;
 always @* begin
  stall_events=0;
  stall_events[7]=busy;
  stall_events[8]=rd_cmd_valid&&!stall_prev_request;
  stall_events[9]=rd_cmd_valid&&rd_cmd_ready;
  stall_events[10]=rd_rsp_valid&&rd_rsp_ready;
  stall_events[11]=stall_events[9];
  stall_events[12]=rd_valid&&rd_ready;
  stall_events[14]=wr_valid&&wr_ready;
  stall_events[24]=state==BUILD;
  stall_events[25]=(state==BUILD||state==ROW_GAP)&&row_has_data&&!input_room;
  stall_events[28]=state==BUILD||state==ROW_GAP;
  stall_events[26]=state==ROW_BEGIN;
  stall_events[66]=state==ROW_BEGIN||state==ROW_PRODUCT||state==ROW_OFFSET||state==ROW_ADDR||state==ROW_END||state==ROW_ADDR_CHECK||state==COALESCE;
  stall_events[77]=state==ROW_DRAIN||state==NEXT_ROW;
  stall_events[70]=state==BUILD&&row_has_data&&bytes_count<take_bytes;
  // Exactly one bucket for every busy cycle, including response/abort drain.
  if(busy)begin
   if(wr_valid&&!wr_ready)stall_events[18]=1;
   else if(state==CHECK||state==CAP_HEIGHT||state==CAP_WORDS||state==CAP_CHECK||
    state==ROW_BEGIN||state==ROW_PRODUCT||state==ROW_OFFSET||state==ROW_ADDR||
    state==ROW_END||state==ROW_ADDR_CHECK||state==NEXT_ROW||state==SETUP||
    state==CHANNEL_OFFSET||state==OFFSET_DONE||state==COALESCE)stall_events[16]=1;
   else if(state==SEND&&!rd_cmd_ready)stall_events[17]=1;
   else if(state==DRAIN)stall_events[22]=1;
   else if(state==ROW_DRAIN&&row_has_data&&rd_rsp_ready&&!rd_rsp_valid)stall_events[21]=1;
   else if((state==BUILD||state==ROW_GAP)&&row_has_data&&rd_fault==0&&rd_ready&&!rd_valid&&
       (state==ROW_GAP||bytes_count<take_bytes))stall_events[19]=1;
   else if(state==BUILD||state==ROW_GAP||state==ROW_DRAIN||state==SEND)stall_events[20]=1;
   else stall_events[23]=1;
  end
 end
 end else begin:g_no_stall_diag
 assign stall_events=0;assign stall_window_count=0;
 end endgenerate
// STALL_DIAGNOSTIC_END
endmodule
