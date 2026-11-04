`timescale 1ns/1ps
// NCHW output tile. Two synchronous spatial-parity RAM banks supply adjacent
// 32-bit elements every clock. A read slot, byte builder and held output beat
// overlap: aligned I32 rows can present one complete AXI64 beat per clock;
// I8 packs two pixels per cycle. Partial/unaligned beats keep exact byte masks.
module npu_conv_output_tile #(parameter bit EXTERNAL_FUSION=0) (
 input wire clk,rst_n,input wire pixel_valid,input wire pixel_page,input wire [4:0] pixel_channel,pixel_index,input wire [31:0] pixel_data,
 input wire cmd_valid,output wire cmd_ready,input wire cmd_i8,
 input wire cmd_i16,cmd_fusion,cmd_page,
 output wire fusion_valid,input wire fusion_ready,output wire [31:0] fusion_data,output wire [9:0] fusion_tag,
 input wire fusion_rsp_valid,input wire [31:0] fusion_result,input wire [9:0] fusion_rsp_tag,input wire [7:0] fusion_fault,
 input wire [31:0] cmd_base,cmd_plane,cmd_row_stride,
 input wire [3:0] cmd_width,input wire [2:0] cmd_height,input wire [5:0] cmd_channels,
 output wire wr_cmd_valid,input wire wr_cmd_ready,output reg [31:0] wr_cmd_addr,wr_cmd_bytes,
 output wire wr_valid,input wire wr_ready,output wire [63:0] wr_data,output wire [7:0] wr_keep,output wire wr_last,
 input wire wr_rsp_valid,output wire wr_rsp_ready,input wire [3:0] wr_fault,
 output wire rsp_valid,input wire rsp_ready,output reg [7:0] rsp_fault,output wire busy
);
 typedef enum logic [3:0]{IDLE,ADDRESS,SEND,STREAM,DRAIN,NEXT,RESPONSE,FUSE_READ,FUSE_SEND,FUSE_DRAIN}state_t;
 state_t state;
 reg [31:0] plane,row_stride,channel_base,row_address;
 reg i8,i16,active_page;
 reg [4:0] fuse_channel,fuse_pixel;
 reg [5:0] fuse_pixels;
 reg [10:0] fuse_retired,fuse_total;
 wire transforming=EXTERNAL_FUSION && (state==FUSE_READ || state==FUSE_SEND || state==FUSE_DRAIN);
 assign fusion_valid=rst_n && EXTERNAL_FUSION && state==FUSE_SEND;
 assign fusion_tag={fuse_channel,fuse_pixel};
 assign fusion_data=fuse_pixel[0] ? pair_data[63:32] : pair_data[31:0];
 reg [3:0] width;
 reg [2:0] height,row;
 reg [5:0] channels,channel;
 reg [5:0] row_bytes,issue_byte;
 reg [2:0] issue_lane;
 reg q_valid,q_first_odd,q_i8,q_i16,q_end,q_last;
 reg [2:0] q_lane;
 reg [3:0] q_bytes;
 reg [1:0] q_source_byte;
 wire [63:0] pair_data;
 reg [63:0] build_data,beat_data;
 reg [7:0] build_keep,beat_keep;
 reg beat_valid,beat_last;
 wire beat_fire=wr_valid&&wr_ready;
 wire consume_pair=q_valid&&(!q_end||!beat_valid||wr_ready);
 wire pair_ready=!q_valid||consume_pair;
 wire read_pair=rst_n&&state==STREAM&&issue_byte<row_bytes&&pair_ready&&wr_fault==0;
 wire [5:0] issue_pixel=i8?issue_byte:i16?(issue_byte>>1):(issue_byte>>2);
 wire [5:0] spatial_index=({3'd0,row}*{2'd0,width})+issue_pixel;
 wire [8:0] pair_index={channel[4:0],spatial_index[4:1]};
 wire [1:0] source_byte=i8?2'd0:i16?{1'b0,issue_byte[0]}:issue_byte[1:0];
 reg [3:0] issue_bytes;
 wire [3:0] issue_end_lane={1'b0,issue_lane}+issue_bytes;
 wire issue_last=({1'b0,issue_byte}+issue_bytes)=={1'b0,row_bytes};
 wire issue_end=issue_last||issue_end_lane==8;
 wire [63:0] ordered_pair=q_first_odd?{pair_data[31:0],pair_data[63:32]}:pair_data;
 wire [7:0] byte_mask;
 wire [63:0] assembled;
 // Select each destination byte directly instead of shifting two full words.
 generate for(genvar lane=0;lane<8;lane=lane+1)begin:g_assemble_byte
  wire [3:0] destination_offset=4'(lane)-{1'b0,q_lane};
  wire [3:0] source_index=destination_offset+{2'd0,q_source_byte};
  wire [7:0] selected_byte=q_i8 ?
      (destination_offset==0 ? ordered_pair[7:0] :
       destination_offset==1 ? ordered_pair[39:32] : 8'd0) : q_i16 ?
      (source_index<2 ? ordered_pair[source_index[0]*8+:8] :
       source_index<4 ? ordered_pair[32+source_index[0]*8+:8] : 8'd0) :
      (source_index[3] ? 8'd0 : ordered_pair[source_index[2:0]*8+:8]);
  assign byte_mask[lane]=!destination_offset[3] && destination_offset<q_bytes;
  assign assembled[lane*8+:8]=build_data[lane*8+:8]|
      (selected_byte&{8{byte_mask[lane]}});
 end endgenerate
 wire [7:0] assembled_keep=build_keep|byte_mask;

 // Never span more than the two available source elements in a RAM issue.
 // Tracking source bytes also preserves arbitrary I32 byte alignment across
 // beat boundaries instead of silently imposing a new command restriction.
 always_comb begin
  issue_bytes=i8?4'd2:i16?(4'd4-{2'd0,source_byte}):(4'd8-{2'd0,source_byte});
  if(issue_bytes>(4'd8-{1'b0,issue_lane}))issue_bytes=4'd8-{1'b0,issue_lane};
  if({2'd0,issue_bytes}>row_bytes-issue_byte)issue_bytes=row_bytes-issue_byte;
 end
 // Separate physical pages also separate the two write ports: the previous
 // tile's fusion responses may arrive while the next tile's epilogue writes.
 wire [63:0] page_data[0:1];
 assign pair_data=page_data[active_page];
 generate for(genvar page=0;page<2;page=page+1)begin:g_page
 for(genvar bank=0;bank<2;bank=bank+1)begin:g_bank
  (* ram_style="block" *)reg [31:0] memory[0:511];
  reg [31:0] value;
  wire [8:0] read_index=transforming ? {fuse_channel,fuse_pixel[4:1]} :
      pair_index+((bank==0&&spatial_index[0])?9'd1:9'd0);
  wire epilogue_write=pixel_valid && pixel_page==page && pixel_index[0]==bank;
  wire transform_write=rst_n && transforming && active_page==page && fusion_rsp_valid && fusion_rsp_tag[0]==bank && fusion_fault==0;
  wire [8:0] write_index=epilogue_write ? {pixel_channel,pixel_index[4:1]} : fusion_rsp_tag[9:1];
  wire [31:0] write_data=epilogue_write ? pixel_data : fusion_result;
  assign page_data[page][bank*32+:32]=value;
  always @(posedge clk)begin
   if(epilogue_write || transform_write)memory[write_index]<=write_data;
   if(active_page==page && (read_pair || (EXTERNAL_FUSION && state==FUSE_READ)))value<=memory[read_index];
  end
 end end endgenerate

 assign cmd_ready=rst_n&&state==IDLE;
 assign busy=state!=IDLE;
 assign rsp_valid=rst_n&&state==RESPONSE;
 assign wr_cmd_valid=rst_n&&state==SEND;
 assign wr_valid=rst_n&&state==STREAM&&beat_valid;
 assign wr_data=beat_data;assign wr_keep=beat_keep;assign wr_last=beat_last;
 assign wr_rsp_ready=rst_n&&state==DRAIN;

 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;plane<=0;row_stride<=0;channel_base<=0;row_address<=0;
   i8<=0;i16<=0;active_page<=0;width<=0;height<=0;row<=0;channels<=0;channel<=0;
   fuse_channel<=0;fuse_pixel<=0;fuse_pixels<=0;fuse_retired<=0;fuse_total<=0;
   row_bytes<=0;issue_byte<=0;issue_lane<=0;
   q_valid<=0;q_first_odd<=0;q_i8<=0;q_end<=0;q_last<=0;q_lane<=0;q_bytes<=0;q_source_byte<=0;
   build_data<=0;build_keep<=0;beat_valid<=0;beat_data<=0;beat_keep<=0;beat_last<=0;
   wr_cmd_addr<=0;wr_cmd_bytes<=0;rsp_fault<=0;
  end else begin
   if(transforming && fusion_rsp_valid)begin
    fuse_retired<=fuse_retired+1'b1;
    if(fusion_fault!=0 && rsp_fault==0)rsp_fault<=fusion_fault;
   end
   case(state)
   IDLE:if(cmd_valid)begin
    plane<=cmd_plane;row_stride<=cmd_row_stride;channel_base<=cmd_base;row_address<=cmd_base;active_page<=cmd_page;
    i8<=cmd_i8;i16<=EXTERNAL_FUSION && cmd_fusion && cmd_i16;
    width<=cmd_width;height<=cmd_height;channels<=cmd_channels;
    fuse_channel<=0;fuse_pixel<=0;fuse_retired<=0;
    fuse_pixels<=cmd_width*cmd_height;fuse_total<=cmd_width*cmd_height*cmd_channels;
    channel<=0;row<=0;rsp_fault<=0;q_valid<=0;beat_valid<=0;
    if(cmd_width==0||cmd_width>8||cmd_height==0||cmd_height>4||cmd_channels==0||cmd_channels>32)begin
     rsp_fault<=1;state<=RESPONSE;
    end else state<=EXTERNAL_FUSION && cmd_fusion ? FUSE_READ : ADDRESS;
   end
   FUSE_READ:state<=FUSE_SEND;
   FUSE_SEND:if(fusion_ready)begin
    if({1'b0,fuse_pixel}+1'b1==fuse_pixels)begin
     fuse_pixel<=0;
     if({1'b0,fuse_channel}+1'b1==channels)state<=FUSE_DRAIN;
     else begin fuse_channel<=fuse_channel+1'b1;state<=FUSE_READ;end
    end else begin fuse_pixel<=fuse_pixel+1'b1;state<=FUSE_READ;end
   end
   FUSE_DRAIN:if(fuse_retired==fuse_total)state<=rsp_fault!=0 ? RESPONSE : ADDRESS;
   ADDRESS:begin
    wr_cmd_addr<=row_address;
    wr_cmd_bytes<={28'd0,width}<<(i8?0:i16?1:2);
    row_bytes<={2'd0,width}<<(i8?0:i16?1:2);
    issue_byte<=0;issue_lane<=row_address[2:0];
    build_data<=0;build_keep<=0;q_valid<=0;beat_valid<=0;beat_last<=0;
    state<=SEND;
   end
   SEND:if(wr_cmd_ready)state<=STREAM;
   STREAM:begin
    // A nonzero transport fault explicitly aborts this DMA input lease;
    // its writer stops accepting input and drains already-issued AXI work.
    // Retire its terminal response before reporting the tile failure.
    if(wr_fault!=0)begin
     rsp_fault<=8'h20|{4'd0,wr_fault};q_valid<=0;beat_valid<=0;state<=DRAIN;
    end else begin
     if(beat_fire)beat_valid<=0;
     if(pair_ready)begin
      q_valid<=read_pair;
      if(read_pair)begin
       q_first_odd<=spatial_index[0];q_i8<=i8;q_i16<=i16;q_lane<=issue_lane;q_bytes<=issue_bytes;
       q_source_byte<=source_byte;q_end<=issue_end;q_last<=issue_last;
       issue_byte<=issue_byte+issue_bytes;issue_lane<=issue_end_lane[2:0];
      end
     end
     if(consume_pair)begin
      if(q_end)begin
       beat_data<=assembled;beat_keep<=assembled_keep;beat_last<=q_last;beat_valid<=1;
       build_data<=0;build_keep<=0;
      end else begin build_data<=assembled;build_keep<=assembled_keep;end
     end
     if(beat_fire&&beat_last)state<=DRAIN;
    end
   end
   DRAIN:if(wr_rsp_valid)begin
    if(wr_fault!=0||rsp_fault!=0)begin
     if(rsp_fault==0)rsp_fault<=8'h20|{4'd0,wr_fault};
     state<=RESPONSE;
    end
    else state<=NEXT;
   end
   NEXT:if(row+1<height)begin
    row<=row+1'b1;row_address<=row_address+row_stride;state<=ADDRESS;
   end else if(channel+1<channels)begin
    channel<=channel+1'b1;row<=0;channel_base<=channel_base+plane;row_address<=channel_base+plane;state<=ADDRESS;
   end else state<=RESPONSE;
   RESPONSE:if(rsp_ready)state<=IDLE;
   default:begin rsp_fault<=1;state<=RESPONSE;end
  endcase
  end
 end
endmodule
