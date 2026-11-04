`timescale 1ns/1ps
// Burst OIHW reader. Transpose only inside WBUF: row=(Cin/8)*KH*KW+kernel,
// byte=Cin%8. No model bytes or coefficient arithmetic are changed.
// Tiny setup products/additions retain their staged fabric registers. Avoid
// merging their enables into DSP input registers across the command boundary.
(* use_dsp="no" *) module npu_stream_weight_loader #(
 parameter bit ENABLE_STALL_DIAG=1'b1,
 parameter bit ENABLE_RAW_TRANSPOSE=1'b1
) (
 output reg [84:0] stall_events,
 input wire clk,rst_n,stop,input wire cmd_valid,output wire cmd_ready,
 input wire cmd_page,input wire [31:0] cmd_base,cmd_full_k,cmd_start_c,
 input wire cmd_packed,input wire [31:0] cmd_bank_stride,
 input wire [5:0] cmd_channels,cmd_cin,input wire [5:0] cmd_area,
 output wire wr_valid,input wire wr_ready,output reg wr_page,
 output reg [4:0] wr_bank,output wire [6:0] wr_row,
 output wire [63:0] wr_data,output wire [7:0] wr_strb,
 output wire rd_cmd_valid,input wire rd_cmd_ready,
 output wire [31:0] rd_cmd_addr,rd_cmd_bytes,
 input wire rd_valid,output wire rd_ready,input wire [63:0] rd_data,
 input wire [7:0] rd_keep,input wire rd_last,
 input wire rd_rsp_valid,output wire rd_rsp_ready,input wire [3:0] rd_fault,
 output wire rsp_valid,input wire rsp_ready,output reg [7:0] rsp_fault,output wire busy
);
 typedef enum logic [3:0]{IDLE,CHECK,GEOMETRY_PRODUCT,GEOMETRY_SUM,GEOMETRY_CHECK,
  CLEAR,ADDRESS,SEND,DATA,TRANSPOSE_READ,TRANSPOSE_WRITE,FINISH,DRAIN,RESPONSE}state_t;
 state_t state;
 reg [31:0] bank_base,full_k,start_c,address;
 reg [10:0] length;
 reg [3:0] channel_groups;
 reg [17:0] start_offset;
 reg [18:0] end_offset;
 reg [5:0] channels,cin,area,c,k;
 reg [7:0] rows,clear_row;
 reg [6:0] data_row,group_row_base;
 reg [63:0] held;
 reg [7:0] keep;
 reg [2:0] byte_index;
 reg have,stopped;
 reg packed_layout;
 reg [31:0] bank_stride;
 reg raw_fast;
 reg [3:0] transpose_beat,transpose_word;
 wire [63:0] transpose_data[0:8];
 reg [63:0] transpose_selected;
 // A raw group contains eight channels x nine kernel bytes. Every target
 // byte has one CONSTANT source beat and byte lane. No variable-index write,
 // byte barrel shifter, multiwrite priority mux or payload reset is needed.
 wire raw_expected_last=transpose_beat==4'd8&&({1'b0,data_row}+8'd9)==rows;
 wire raw_packet_bad=rd_keep!=8'hff||rd_last!=raw_expected_last;
 wire raw_capture=rst_n&&state==TRANSPOSE_READ&&!stopped&&!stop&&rd_fault==0&&
     rd_valid&&rd_ready&&!raw_packet_bad;
 generate for(genvar kernel=0;kernel<9;kernel=kernel+1)begin:g_raw_kernel
  for(genvar lane=0;lane<8;lane=lane+1)begin:g_raw_lane
   localparam integer SOURCE_OFFSET=lane*9+kernel;
   localparam [3:0] SOURCE_BEAT=4'(SOURCE_OFFSET/8);
   localparam integer SOURCE_LANE=SOURCE_OFFSET%8;
   reg [7:0] payload;
   always @(posedge clk)if(raw_capture&&transpose_beat==SOURCE_BEAT)
    payload<=rd_data[SOURCE_LANE*8+:8];
   assign transpose_data[kernel][lane*8+:8]=payload;
  end
 end endgenerate
 // Only a fixed nine-word read selector remains. Payload is fully replaced
 // by nine accepted beats before this selector can drive a valid write.
 always @* begin
  transpose_selected=0;
  case(transpose_word)
   4'd0:transpose_selected=transpose_data[0];
   4'd1:transpose_selected=transpose_data[1];
   4'd2:transpose_selected=transpose_data[2];
   4'd3:transpose_selected=transpose_data[3];
   4'd4:transpose_selected=transpose_data[4];
   4'd5:transpose_selected=transpose_data[5];
   4'd6:transpose_selected=transpose_data[6];
   4'd7:transpose_selected=transpose_data[7];
   4'd8:transpose_selected=transpose_data[8];
   default:;
  endcase
 end
 // For 1x1 OIHW, adjacent Cin bytes already form one WBUF word. Transfer a
 // contiguous segment per cycle; split only at source/destination word edges.
 // Other kernels retain their checked byte-wise transpose.
 reg [3:0] word_bytes;
 wire word_path=area==1;
 always_comb begin
  // The transport's keep describes a contiguous requested byte range. cin-c
  // bounds its final beat; leading masked bytes use the ordinary skip path.
  word_bytes=4'd8-{1'b0,byte_index};
  if(word_bytes>4'd8-{1'b0,c[2:0]})word_bytes=4'd8-{1'b0,c[2:0]};
  if({2'd0,word_bytes}>cin-c)word_bytes=cin-c;
 end
 wire live_byte=have&&keep[byte_index];
 wire [7:0] selected_byte=held[byte_index*8+:8];
 assign cmd_ready=rst_n&&state==IDLE;assign busy=state!=IDLE;
 assign rsp_valid=rst_n&&state==RESPONSE;
 assign wr_valid=rst_n&&(state==CLEAR||state==TRANSPOSE_WRITE||(state==DATA&&(packed_layout?have:live_byte)));
 // Live byte order is channel-major. Retain the kernel endpoint instead of
 // recomputing a channel-group product on the shared BRAM address bus.
 assign wr_row=state==CLEAR ? clear_row[6:0] : data_row;
 generate for(genvar lane=0;lane<8;lane=lane+1)begin:g_write_byte
  wire [3:0] offset=4'(lane)-{1'b0,c[2:0]};
  wire [3:0] source_lane={1'b0,byte_index}+offset;
  assign wr_data[lane*8+:8]=state==CLEAR ? 8'd0 : state==TRANSPOSE_WRITE ?
      transpose_selected[lane*8+:8] : packed_layout ?
      ((cin[2:0]!=0&&data_row>=rows-area&&lane>=cin[2:0])?8'd0:held[lane*8+:8]) : word_path ?
      (!offset[3] && offset<word_bytes ? held[source_lane[2:0]*8+:8] : 8'd0) :
      (c[2:0]!=lane ? 8'd0 : selected_byte);
  // The first local Cin byte initializes the entire row to zero before
  // later channels patch their lanes, so raw tails need no active preclear.
  assign wr_strb[lane]=state==CLEAR || state==TRANSPOSE_WRITE || packed_layout || c[2:0]==0 || (word_path ?
      (!offset[3] && offset<word_bytes) : c[2:0]==lane);
 end endgenerate
 assign rd_cmd_valid=rst_n&&state==SEND;
 assign rd_cmd_addr=address;assign rd_cmd_bytes={21'd0,length};
 // Packed [OC][Cin-group][kernel][8] words already match one WBUF row.
 // Consume and replace the elastic word on the same edge, with no byte FSM.
 wire packed_replace=packed_layout&&have&&wr_ready&&data_row+1<rows;
 assign rd_ready=rst_n&&(state==DRAIN||(state==TRANSPOSE_READ&&!stopped&&!stop&&rd_fault==0)||
     (state==DATA&&!stopped&&!stop&&
     (!have||packed_replace)));
 // Extra raw data selects DRAIN. Hold a simultaneous terminal response for
 // that state so it cannot be acknowledged and then awaited a second time.
 assign rd_rsp_ready=rst_n&&(state==DRAIN||
     (state==FINISH&&!(raw_fast&&rd_valid)));
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;bank_base<=0;full_k<=0;start_c<=0;channels<=0;cin<=0;area<=0;c<=0;k<=0;
   address<=0;length<=0;channel_groups<=0;start_offset<=0;end_offset<=0;
   rows<=0;clear_row<=0;data_row<=0;group_row_base<=0;held<=0;keep<=0;byte_index<=0;
   have<=0;stopped<=0;packed_layout<=0;bank_stride<=0;wr_page<=0;wr_bank<=0;rsp_fault<=0;
   raw_fast<=0;transpose_beat<=0;transpose_word<=0;
  end else begin
   if(stop&&state!=IDLE&&state!=RESPONSE)stopped<=1;
   if(rd_valid&&rd_ready&&state==DATA)begin held<=rd_data;keep<=rd_keep;byte_index<=0;have<=1;end
   case(state)
    IDLE:if(cmd_valid)begin
     bank_base<=cmd_base;full_k<=cmd_full_k;start_c<=cmd_start_c;channels<=cmd_channels;
     cin<=cmd_cin;area<=cmd_area;wr_page<=cmd_page;wr_bank<=0;clear_row<=0;
     packed_layout<=cmd_packed;bank_stride<=cmd_bank_stride;
     rsp_fault<=0;stopped<=0;have<=0;state<=CHECK;
    end
    CHECK:if(cin==0||cin>32||channels==0||channels>32||area==0||area>49||start_c>4095)begin
      rsp_fault<=1;state<=RESPONSE;
     end else begin
      raw_fast<=ENABLE_RAW_TRANSPOSE&&!packed_layout&&area==9&&cin[2:0]==0&&
          start_c[2:0]==0&&bank_base[2:0]==0&&full_k[2:0]==0;
      channel_groups<=({1'b0,cin}+7'd7)>>3;state<=GEOMETRY_PRODUCT;
     end
    // Bounds above make each product exact at these narrower widths. Keep
    // the multipliers, end-offset addition and limit comparison on separate edges.
    GEOMETRY_PRODUCT:begin
     start_offset<=start_c[11:0]*area;length<=packed_layout ? (channel_groups*area)<<3 : cin*area;
     rows<=channel_groups*area;state<=GEOMETRY_SUM;
    end
    GEOMETRY_SUM:begin
     end_offset<={1'b0,start_offset}+{8'd0,length};state<=GEOMETRY_CHECK;
    end
    GEOMETRY_CHECK:if(rows>128||{13'd0,end_offset}>(packed_layout?bank_stride:full_k)||
       (packed_layout&&(area!=9||start_c[2:0]!=0||bank_base[2:0]!=0||bank_stride[2:0]!=0||bank_stride<full_k)))begin rsp_fault<=1;state<=RESPONSE;end
     else begin
      // Every active bank/row is overwritten as a complete word, including
      // padded Cin bytes. Only inactive output banks need an explicit clear.
      if(channels==32)begin wr_bank<=0;state<=ADDRESS;end
      else begin wr_bank<=channels[4:0];state<=CLEAR;end
     end
    CLEAR:if(stopped||stop)begin if(wr_ready)begin rsp_fault<=8'he1;state<=RESPONSE;end end
     else if(wr_ready)begin
      if(clear_row+1<rows)clear_row<=clear_row+1'b1;
      // Clear every bank so inactive output lanes cannot overflow the PE.
      else if(wr_bank!=31)begin wr_bank<=wr_bank+1'b1;clear_row<=0;end
      else begin wr_bank<=0;state<=ADDRESS;end
     end
    ADDRESS:begin
     address<=bank_base+{14'd0,start_offset};c<=0;k<=0;have<=0;
     data_row<=0;group_row_base<=0;transpose_beat<=0;transpose_word<=0;state<=SEND;
    end
    SEND:if(rd_cmd_ready)state<=raw_fast?TRANSPOSE_READ:DATA;
    TRANSPOSE_READ:if(stopped||stop||rd_fault!=0)begin
      rsp_fault<=(stopped||stop)?8'he1:{4'h2,rd_fault};state<=DRAIN;
     end else if(rd_valid&&rd_ready)begin
      if(raw_packet_bad)begin rsp_fault<=8'h23;state<=DRAIN;end
      else if(transpose_beat==8)begin transpose_word<=0;state<=TRANSPOSE_WRITE;end
      else transpose_beat<=transpose_beat+1'b1;
     end else if(rd_rsp_valid&&!rd_valid)begin
      // A short successful packet must also terminate, rather than waiting
      // forever for the rest of a partially filled transpose group.
      rsp_fault<=8'h23;state<=DRAIN;
     end
    TRANSPOSE_WRITE:if(stopped||stop||rd_fault!=0)begin
      // Keep an already presented complete word stable through backpressure
      // until its accepted edge, then drain the original descriptor response.
      if(wr_ready)begin rsp_fault<=(stopped||stop)?8'he1:{4'h2,rd_fault};state<=DRAIN;end
     end else if(wr_ready)begin
      if(transpose_word<8)begin transpose_word<=transpose_word+1'b1;data_row<=data_row+1'b1;end
      else if(data_row+1<rows)begin
       data_row<=data_row+1'b1;transpose_beat<=0;state<=TRANSPOSE_READ;
      end else state<=FINISH;
     end
    DATA:if(stopped||stop||rd_fault!=0||(packed_layout&&have&&keep!=8'hff))begin
      rsp_fault<=(stopped||stop) ? 8'he1 : rd_fault!=0 ? {4'h2,rd_fault} : 8'h23;
      // A presented packed write remains stable until its acceptance, even
      // if cancellation or a stream error arrives while BRAM is stalled.
      if(!(have&&(packed_layout||live_byte)&&!wr_ready))begin have<=0;state<=DRAIN;end
     end else if(packed_layout)begin
      if(have&&wr_ready)begin
       if(!(rd_valid&&rd_ready))have<=0;
       if(data_row+1<rows)data_row<=data_row+1'b1;
       else begin have<=0;state<=FINISH;end
      end
     end else if(have&&(!live_byte||wr_ready))begin
      if(word_path&&live_byte)begin
       if({1'b0,byte_index}+word_bytes==8)have<=0;
       else byte_index<=byte_index+word_bytes;
       if({1'b0,c}+word_bytes=={1'b0,cin})begin have<=0;state<=FINISH;end
       else begin c<=c+word_bytes;data_row<=({1'b0,c}+word_bytes)>>3;end
      end else begin
      if(byte_index==7)have<=0;else byte_index<=byte_index+1'b1;
      if(live_byte)begin
       if(k+1<area)begin k<=k+1'b1;data_row<=data_row+1'b1;end
       else if(c+1<cin)begin
        c<=c+1'b1;k<=0;
        // Channels in a group revisit its kernel rows. Channel7's endpoint
        // starts the next group. Validated rows<=128 keeps all used rows
        // in seven bits; an endpoint of128 is never used by another group.
        if(c[2:0]==3'd7)begin
         data_row<=data_row+1'b1;group_row_base<=data_row+1'b1;
        end else data_row<=group_row_base;
       end
       else begin have<=0;state<=FINISH;end
      end
      end
     end
    FINISH:if(raw_fast&&rd_valid)begin rsp_fault<=8'h23;state<=DRAIN;end
     else if(rd_rsp_valid)begin
     if(rd_fault!=0)begin rsp_fault<={4'h2,rd_fault};state<=RESPONSE;end
     else if(stopped||stop)begin rsp_fault<=8'he1;state<=RESPONSE;end
     else if(wr_bank+1<channels)begin
      wr_bank<=wr_bank+1'b1;bank_base<=bank_base+(packed_layout?bank_stride:full_k);state<=ADDRESS;
     end
     else state<=RESPONSE;
    end
    DRAIN:if(rd_rsp_valid)state<=RESPONSE;
    RESPONSE:if(rsp_ready)state<=IDLE;
    default:begin rsp_fault<=1;state<=RESPONSE;end
   endcase
  end
 end
// STALL_DIAGNOSTIC_BEGIN
 generate if(ENABLE_STALL_DIAG)begin:g_stall_diag
 reg stall_prev_request;
 always @(posedge clk)if(!rst_n)stall_prev_request<=0;else stall_prev_request<=rd_cmd_valid;
 always @*begin
  stall_events=0;
  stall_events[29]=busy;
  stall_events[30]=rd_cmd_valid&&!stall_prev_request;
  stall_events[31]=rd_cmd_valid&&rd_cmd_ready;
  stall_events[32]=rd_rsp_valid&&rd_rsp_ready;
  stall_events[33]=stall_events[31];
  stall_events[34]=rd_valid&&rd_ready;
  stall_events[36]=state==CLEAR;
  stall_events[37]=(state==DATA&&!packed_layout&&!word_path||state==TRANSPOSE_WRITE)&&wr_valid&&wr_ready;
  stall_events[38]=state==DATA&&!packed_layout&&word_path&&wr_valid&&wr_ready;
  stall_events[39]=state==DATA&&packed_layout&&wr_valid&&wr_ready;
  stall_events[50]=(state==DATA||state==TRANSPOSE_WRITE)&&wr_valid&&wr_ready&&wr_strb==8'hff;
  stall_events[72]=state==CLEAR&&wr_valid&&wr_ready;
  stall_events[75]=state==FINISH&&rd_rsp_valid&&rd_rsp_ready&&rd_fault==0&&!stopped&&!stop&&wr_bank+1<channels;
  if(busy)begin
   if(wr_valid&&!wr_ready)stall_events[43]=1;
   else if(state==CHECK||state==GEOMETRY_PRODUCT||state==GEOMETRY_SUM||state==GEOMETRY_CHECK||state==ADDRESS)stall_events[41]=1;
   else if(state==SEND&&!rd_cmd_ready)stall_events[42]=1;
   else if(state==DRAIN)stall_events[47]=1;
   else if(state==FINISH&&!rd_rsp_valid)stall_events[46]=1;
   else if((state==DATA&&!have||state==TRANSPOSE_READ)&&rd_ready&&!rd_valid&&!stop&&!stopped&&rd_fault==0)stall_events[44]=1;
   else if(state==DATA||state==TRANSPOSE_READ||state==TRANSPOSE_WRITE||state==CLEAR||state==FINISH||state==SEND)stall_events[45]=1;
   else stall_events[48]=1;
  end
 end
 end else begin:g_no_stall_diag
 assign stall_events=0;
 end endgenerate
// STALL_DIAGNOSTIC_END
endmodule
