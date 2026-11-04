`timescale 1ns/1ps
// One NCHW channel plane, exact I32 or flagged ResNet I8 max pooling.
// Padding is the minimum signed value of the selected tensor dtype.
// Geometry products use the scalar math service once per command. The pixel
// scan uses only coordinate/address increments; no private address multipliers.
// A command-private associative word cache reuses overlapping input windows.
// An aligned 8-byte fill is issued only when its complete range is inside
// the already checked input envelope; boundary words retain scalar reads.
(* use_dsp="no" *)
module npu_maxpool_engine #(
 parameter bit EXTERNAL_MATH = 1'b0,
 parameter integer CACHE_WORDS = 4,
 parameter bit ENABLE_MAXPOOL_FASTPATH = 1'b1,
 parameter bit ENABLE_MAXPOOL_BULK = 1'b0
) (
 input logic clk,rst_n,input logic cmd_valid,output logic cmd_ready,
 input logic [31:0] cmd_tag,input logic [4095:0] cmd_record,
 output logic mem_req_valid,input logic mem_req_ready,output logic mem_req_write,
 output logic [31:0] mem_req_addr,output logic [1:0] mem_req_size,
 output logic [63:0] mem_req_wdata,input logic mem_rsp_valid,output logic mem_rsp_ready,
 input logic signed [63:0] mem_rsp_rdata,input logic [3:0] mem_rsp_fault,
 output logic rsp_valid,input logic rsp_ready,output logic [31:0] rsp_tag,
 output logic [7:0] rsp_fault,output logic busy,
 output logic math_req_valid,input logic math_req_ready,
 output logic [2:0] math_req_op,output logic signed [63:0] math_req_a,math_req_b,
 output logic [6:0] math_req_shift,input logic math_rsp_valid,output logic math_rsp_ready,
 input logic signed [63:0] math_rsp_result,input logic [1:0] math_rsp_fault,
 output wire rd_cmd_valid,input wire rd_cmd_ready,output wire [31:0] rd_cmd_addr,rd_cmd_bytes,
 input wire rd_valid,output wire rd_ready,input wire [63:0] rd_data,input wire [7:0] rd_keep,input wire rd_last,
 input wire rd_rsp_valid,output wire rd_rsp_ready,input wire [3:0] rd_fault,
 output wire wr_cmd_valid,input wire wr_cmd_ready,output wire [31:0] wr_cmd_addr,wr_cmd_bytes,
 output wire wr_valid,input wire wr_ready,output wire [63:0] wr_data,output wire [7:0] wr_keep,output wire wr_last,
 input wire wr_rsp_valid,output wire wr_rsp_ready,input wire [3:0] wr_fault
);
 typedef enum logic [4:0] {IDLE,CHECK,GEOMETRY_SEND,GEOMETRY_WAIT,REGION_CHECK,
  BEGIN_PIXEL,ADDRESS,READ_REQ,READ_WAIT,ADVANCE_KERNEL,WRITE_REQ,
  WRITE_WAIT,RESPONSE,ADDRESS_CHECK,FAST_READ_REQ,FAST_READ_WAIT,
  FAST_H_BEGIN,FAST_H_SCAN,FAST_H_STORE,FAST_V_BEGIN,FAST_V_SCAN,
  FAST_PACK,FAST_WRITE_REQ,FAST_WRITE_WAIT,FAST_BULK_READ_CMD,FAST_BULK_READ_DATA,
  FAST_BULK_WRITE_CMD,FAST_BULK_BEAT,FAST_BULK_DRAIN} state_t;
 state_t state;
 logic [31:0] a,y;
 logic [12:0] ih,iw,oh,ow,pt,pl;
 logic [4:0] kh,kw,ky,kx;
 logic [6:0] sh,sw;
 logic [11:0] oy,ox;
 logic signed [31:0] iy,ix,maximum;
 logic signed [31:0] sample_value;
 logic sample_valid;
 logic signed [31:0] origin_y,origin_x;
 logic [31:0] input_bytes,output_bytes,row_bytes,output_row_bytes;
 logic [32:0] aend,yend;
 logic [31:0] row_base,pixel_base,kernel_row,kernel_address,output_address;
 logic [31:0] output_row_step,padding_rows,horizontal_step;
 logic command_bad,resnet_legacy;
 wire [31:0] element_bytes=resnet_legacy ? 32'd1 : 32'd4;
 wire [31:0] padding_columns={19'd0,pl}<<(resnet_legacy ? 0 : 2);
 logic [1:0] geometry_index;
 logic math_ready,math_valid;
 logic signed [63:0] geometry_a,geometry_b,math_result;
 logic [1:0] math_fault;
 localparam integer CACHE_AW=CACHE_WORDS>1?$clog2(CACHE_WORDS):1;
 logic [CACHE_WORDS-1:0] cache_valid;
 (* ram_style="distributed" *)logic [28:0] cache_tag[0:CACHE_WORDS-1];
 (* ram_style="distributed" *)logic [63:0] cache_data[0:CACHE_WORDS-1];
 logic [CACHE_AW-1:0] cache_victim;
 logic cache_hit,read_word,cache_hit_q,word_in_region_q;
 logic [63:0] cache_word;
 logic [2:0] read_byte;
 // The eligible plane is only 8x8 I32. Horizontal maxima occupy 256 bytes
  // of LUTRAM; four packed source words hold one row. No extra DMA or BRAM.
 (* ram_style="distributed" *) logic signed [31:0] horizontal_max[0:63];
  // Each accepted beat writes one complete word. A single write address
  // exposes distributed-RAM inference instead of two dynamic 32-bit writes.
  (* ram_style="distributed" *) logic [63:0] source_words[0:3];
 logic [2:0] fast_row,fast_x,fast_y,fast_scan;
 logic [1:0] fast_word;
 logic [31:0] fast_input_address;
 logic [63:0] fast_output_word;
 logic [2:0] fast_received;
 logic [4:0] fast_sent;
 logic fast_read_bad,fast_last_seen,fast_write_owned;
 wire fast_bulk=ENABLE_MAXPOOL_BULK && a[4:0]==0 && y[6:0]==0;
 wire fast_read_packet_bad=fast_received>=4 || rd_keep!=8'hff || rd_last!=(fast_received==3);
 assign rd_cmd_valid=rst_n&&state==FAST_BULK_READ_CMD;
 assign rd_cmd_addr=fast_input_address;assign rd_cmd_bytes=32'd32;
 assign rd_ready=rst_n&&state==FAST_BULK_READ_DATA;
 assign rd_rsp_ready=rst_n&&state==FAST_BULK_READ_DATA;
 assign wr_cmd_valid=rst_n&&state==FAST_BULK_WRITE_CMD;
 assign wr_cmd_addr=output_address;assign wr_cmd_bytes=32'd128;
 assign wr_valid=rst_n&&state==FAST_BULK_BEAT&&wr_fault==0;
 assign wr_data=fast_output_word;assign wr_keep=8'hff;assign wr_last=fast_sent==15;
 assign wr_rsp_ready=rst_n&&state==FAST_BULK_DRAIN;
 wire fast_eligible=ENABLE_MAXPOOL_FASTPATH && !resnet_legacy &&
  ih==8 && iw==8 && oh==8 && ow==8 && sh==1 && sw==1 &&
  ((kh==5 && kw==5 && pt==2 && pl==2) ||
   (kh==9 && kw==9 && pt==4 && pl==4) ||
   (kh==13 && kw==13 && pt==6 && pl==6)) && a[2:0]==0 && y[2:0]==0;
 // Eligible kernels/pads match on both axes. Five bits cover 0..7 + 13.
 wire [2:0] fast_axis=state==FAST_H_SCAN ? fast_x : fast_y;
 wire [4:0] fast_padded_scan={2'd0,fast_scan}+{2'd0,pl[2:0]};
 wire [4:0] fast_window_end={2'd0,fast_axis}+{1'd0,kw[3:0]};
 wire fast_inside=fast_padded_scan>={2'd0,fast_axis} && fast_padded_scan<fast_window_end;
  wire [63:0] source_word=source_words[fast_scan[2:1]];
  wire signed [31:0] source_sample=fast_scan[0] ? source_word[63:32] : source_word[31:0];
  wire signed [31:0] fast_sample=state==FAST_H_SCAN ? source_sample :
  horizontal_max[{fast_scan,fast_x}];
 wire signed [31:0] compare_value=(state==FAST_H_SCAN || state==FAST_V_SCAN) ? fast_sample : sample_value;
 wire sample_greater=compare_value>maximum;
 wire [31:0] aligned_word={kernel_address[31:3],3'b000};
 wire word_in_region={1'b0,aligned_word}>={1'b0,a} &&
     ({1'b0,aligned_word}+33'd8)<=aend;
 wire [63:0] hit_shifted=cache_word>>{kernel_address[2:0],3'b000};
 wire [63:0] fill_shifted=mem_rsp_rdata>>{read_byte,3'b000};
 wire signed [31:0] hit_value=resnet_legacy?
     {{24{hit_shifted[7]}},hit_shifted[7:0]}:hit_shifted[31:0];
 wire signed [31:0] fetched_value=read_word?
     (resnet_legacy?{{24{fill_shifted[7]}},fill_shifted[7:0]}:fill_shifted[31:0]):
     (resnet_legacy?{{24{mem_rsp_rdata[7]}},mem_rsp_rdata[7:0]}:mem_rsp_rdata[31:0]);
 always_comb begin
  cache_hit=0;cache_word=0;
  for(integer c=0;c<CACHE_WORDS;c=c+1)
   if(cache_valid[c]&&cache_tag[c]==kernel_address[31:3])begin
    cache_hit=1;cache_word=cache_data[c];
   end
 end
 always_comb begin
  cmd_ready=rst_n && state==IDLE;busy=state!=IDLE;rsp_valid=rst_n && state==RESPONSE;
  mem_req_valid=rst_n && (state==READ_REQ || state==WRITE_REQ ||
   state==FAST_READ_REQ || state==FAST_WRITE_REQ);
  mem_req_write=state==WRITE_REQ || state==FAST_WRITE_REQ;
  mem_req_size=(state==FAST_READ_REQ || state==FAST_WRITE_REQ ||
   (state==READ_REQ&&read_word))?2'd3:(resnet_legacy?2'd0:2'd2);
  mem_req_wdata=state==FAST_WRITE_REQ ? fast_output_word : {{32{maximum[31]}},maximum};
  mem_rsp_ready=rst_n && (state==READ_WAIT || state==WRITE_WAIT ||
   state==FAST_READ_WAIT || state==FAST_WRITE_WAIT);
  row_bytes={19'd0,iw}<<(resnet_legacy ? 0 : 2);
  output_row_bytes={19'd0,ow}<<(resnet_legacy ? 0 : 2);
  horizontal_step={25'd0,sw}<<(resnet_legacy ? 0 : 2);
  geometry_a=0;geometry_b=$signed({32'd0,row_bytes});
  case(geometry_index)
   0: geometry_a=$signed({51'd0,ih});
   1: begin geometry_a=$signed({51'd0,oh});geometry_b=$signed({32'd0,output_row_bytes});end
   2: geometry_a=$signed({51'd0,pt});
   3: geometry_a=$signed({57'd0,sh});
   default: ;
  endcase
 end
 npu_math_port #(.EXTERNAL_MATH(EXTERNAL_MATH)) u_geometry (
  .clk(clk),.rst_n(rst_n),.req_valid(rst_n && state==GEOMETRY_SEND),.req_ready(math_ready),
  .req_op(3'd1),.req_a(geometry_a),.req_b(geometry_b),.req_shift(7'd0),
  .rsp_valid(math_valid),.rsp_ready(rst_n && state==GEOMETRY_WAIT),
  .rsp_result(math_result),.rsp_fault(math_fault),
  .math_req_valid(math_req_valid),.math_req_ready(math_req_ready),.math_req_op(math_req_op),
  .math_req_a(math_req_a),.math_req_b(math_req_b),.math_req_shift(math_req_shift),
  .math_rsp_valid(math_rsp_valid),.math_rsp_ready(math_rsp_ready),
  .math_rsp_result(math_rsp_result),.math_rsp_fault(math_rsp_fault));
 task automatic fail(input logic [7:0] code);begin rsp_fault<=code;state<=RESPONSE;end endtask
 // ADVANCE_KERNEL compares the captured sample while advancing coordinates.
 // Payload is unreset; sample_valid owns whether it may update maximum.
 always_ff @(posedge clk) begin
  if(state==ADDRESS) sample_value<=hit_value;
  else if(state==READ_WAIT) sample_value<=fetched_value;
 end
 // Geometry operands commit before the final product response. Keep their
 // full 33-bit endpoints, including the legal exclusive endpoint at 2^32.
 always_ff @(posedge clk)begin
  if(rst_n && state==GEOMETRY_WAIT && math_valid && geometry_index==3)begin
   aend<={1'b0,a}+{1'b0,input_bytes};
   yend<={1'b0,y}+{1'b0,output_bytes};
  end
  if(rst_n && state==ADDRESS)begin
   cache_hit_q<=cache_hit;word_in_region_q<=word_in_region;
  end
 end
 always_ff @(posedge clk) begin
  if(!rst_n) begin
   state<=IDLE;a<=0;y<=0;ih<=0;iw<=0;oh<=0;ow<=0;kh<=0;kw<=0;sh<=0;sw<=0;pt<=0;pl<=0;
   oy<=0;ox<=0;ky<=0;kx<=0;iy<=0;ix<=0;maximum<=0;
   origin_y<=0;origin_x<=0;input_bytes<=0;output_bytes<=0;
   row_base<=0;pixel_base<=0;kernel_row<=0;kernel_address<=0;output_address<=0;
   output_row_step<=0;padding_rows<=0;command_bad<=0;geometry_index<=0;resnet_legacy<=0;
   rsp_tag<=0;rsp_fault<=0;mem_req_addr<=0;
   cache_valid<=0;cache_victim<=0;read_word<=0;read_byte<=0;sample_valid<=0;
   fast_row<=0;fast_x<=0;fast_y<=0;fast_scan<=0;fast_word<=0;fast_input_address<=0;
   fast_output_word<=0;
   fast_received<=0;fast_sent<=0;fast_read_bad<=0;fast_last_seen<=0;fast_write_owned<=0;
  end else if(fast_write_owned && wr_fault!=0 && state!=FAST_BULK_DRAIN)begin
   rsp_fault<={4'h2,wr_fault};state<=FAST_BULK_DRAIN;
  end else case(state)
   IDLE: if(cmd_valid) begin
    rsp_tag<=cmd_tag;rsp_fault<=0;a<=cmd_record[8*32+:32];y<=cmd_record[10*32+:32];
    cache_valid<=0;cache_victim<=0;read_word<=0;
    // Validate every full-width field before narrowing. Values with nonzero
    // upper bits must not alias a supported geometry.
    resnet_legacy<=cmd_record[2*32];
    command_bad<=cmd_record[2*32+:32]>1 ||
     cmd_record[4*32+:32]!=(cmd_record[2*32] ? 32'd1 : 32'd3) ||
     cmd_record[6*32+:32]!=(cmd_record[2*32] ? 32'd1 : 32'd3) ||
     cmd_record[64*32+:32]==0 || cmd_record[64*32+:32]>4096 ||
     cmd_record[65*32+:32]==0 || cmd_record[65*32+:32]>4096 ||
     cmd_record[66*32+:32]==0 || cmd_record[66*32+:32]>4096 ||
     cmd_record[67*32+:32]==0 || cmd_record[67*32+:32]>4096 ||
     cmd_record[68*32+:32]==0 || cmd_record[68*32+:32]>31 ||
     cmd_record[69*32+:32]==0 || cmd_record[69*32+:32]>31 ||
     cmd_record[70*32+:32]==0 || cmd_record[70*32+:32]>64 ||
     cmd_record[71*32+:32]==0 || cmd_record[71*32+:32]>64 ||
     cmd_record[72*32+:32]>4096 || cmd_record[73*32+:32]>4096;
    ih<=cmd_record[64*32+:13];iw<=cmd_record[65*32+:13];
    oh<=cmd_record[66*32+:13];ow<=cmd_record[67*32+:13];
    kh<=cmd_record[68*32+:5];kw<=cmd_record[69*32+:5];
    sh<=cmd_record[70*32+:7];sw<=cmd_record[71*32+:7];
    pt<=cmd_record[72*32+:13];pl<=cmd_record[73*32+:13];
    oy<=0;ox<=0;state<=CHECK;
   end
   CHECK: if(command_bad || (!resnet_legacy && (a[1:0]!=0 || y[1:0]!=0))) fail(8'h03);
    else begin geometry_index<=0;state<=GEOMETRY_SEND;end
   GEOMETRY_SEND: if(math_ready) state<=GEOMETRY_WAIT;
   GEOMETRY_WAIT: if(math_valid) begin
    if(math_fault!=0 || math_result[63:32]!=0) fail(8'h03);
    else begin
     case(geometry_index)
      0: input_bytes<=math_result[31:0];
      1: output_bytes<=math_result[31:0];
      2: padding_rows<=math_result[31:0];
      3: output_row_step<=math_result[31:0];
      default: ;
     endcase
     if(geometry_index==3) state<=REGION_CHECK;
     else begin geometry_index<=geometry_index+1'b1;state<=GEOMETRY_SEND;end
    end
   end
   REGION_CHECK: if(aend>33'h100000000 || yend>33'h100000000 ||
     ({1'b0,a}<yend && {1'b0,y}<aend)) fail(8'h03);
    else begin
     origin_y<=-$signed({19'd0,pt});origin_x<=-$signed({19'd0,pl});
     row_base<=a-padding_rows;
     pixel_base<=a-padding_rows-padding_columns;
     output_address<=y;
     if(fast_eligible)begin
      fast_row<=0;fast_word<=0;fast_input_address<=a;mem_req_addr<=a;
      fast_received<=0;fast_read_bad<=0;fast_last_seen<=0;fast_sent<=0;fast_write_owned<=0;
      state<=fast_bulk ? FAST_BULK_READ_CMD : FAST_READ_REQ;
     end else state<=BEGIN_PIXEL;
    end
   BEGIN_PIXEL: begin
    ky<=0;kx<=0;maximum<=resnet_legacy ? -32'sd128 : 32'sh80000000;
    iy<=origin_y;ix<=origin_x;kernel_row<=pixel_base;kernel_address<=pixel_base;
    // Coordinates and their modulo-2^32 byte address advance together. A
    // wrapped padding address is never issued: ADDRESS checks both axes.
    state<=ADDRESS;
   end
   ADDRESS: begin
    sample_valid<=0;
    if(iy<0 || ix<0 || $unsigned(iy)>=ih || $unsigned(ix)>=iw) state<=ADVANCE_KERNEL;
    else state<=ADDRESS_CHECK;
   end
   ADDRESS_CHECK:begin
    if(cache_hit_q)begin sample_valid<=1;state<=ADVANCE_KERNEL;end
    else begin
     read_word<=word_in_region_q;read_byte<=kernel_address[2:0];
     mem_req_addr<=word_in_region_q?aligned_word:kernel_address;state<=READ_REQ;
    end
   end
   READ_REQ: if(mem_req_ready) state<=READ_WAIT;
   READ_WAIT: if(mem_rsp_valid) begin
    if(mem_rsp_fault!=0) fail({4'h2,mem_rsp_fault});
    else begin
     if(read_word)begin
      cache_valid[cache_victim]<=1;cache_tag[cache_victim]<=mem_req_addr[31:3];
      cache_data[cache_victim]<=mem_rsp_rdata;
      cache_victim<=cache_victim==CACHE_WORDS-1?0:cache_victim+1'b1;
     end
     sample_valid<=1;state<=ADVANCE_KERNEL;
    end
   end
   ADVANCE_KERNEL: begin
    if(sample_valid && sample_greater) maximum<=sample_value;
    sample_valid<=0;
    if({1'b0,kx}+6'd1<{1'b0,kw}) begin
     kx<=kx+1'b1;ix<=ix+32'sd1;kernel_address<=kernel_address+element_bytes;state<=ADDRESS;
    end else if({1'b0,ky}+6'd1<{1'b0,kh}) begin
     kx<=0;ky<=ky+1'b1;iy<=iy+32'sd1;ix<=origin_x;
     kernel_row<=kernel_row+row_bytes;kernel_address<=kernel_row+row_bytes;state<=ADDRESS;
    end else begin mem_req_addr<=output_address;state<=WRITE_REQ;end
   end
   WRITE_REQ: if(mem_req_ready) state<=WRITE_WAIT;
   WRITE_WAIT: if(mem_rsp_valid) begin
    if(mem_rsp_fault!=0) fail({4'h2,mem_rsp_fault});
    else if({1'b0,ox}+13'd1<ow) begin
     ox<=ox+1'b1;origin_x<=origin_x+$signed({25'd0,sw});
     pixel_base<=pixel_base+horizontal_step;output_address<=output_address+element_bytes;state<=BEGIN_PIXEL;
    end else if({1'b0,oy}+13'd1<oh) begin
     ox<=0;oy<=oy+1'b1;origin_y<=origin_y+$signed({25'd0,sh});origin_x<=-$signed({19'd0,pl});
     row_base<=row_base+output_row_step;
     pixel_base<=row_base+output_row_step-padding_columns;
     output_address<=output_address+element_bytes;state<=BEGIN_PIXEL;
    end
    else state<=RESPONSE;
   end
   FAST_READ_REQ:if(mem_req_ready)state<=FAST_READ_WAIT;
   FAST_READ_WAIT:if(mem_rsp_valid)begin
    if(mem_rsp_fault!=0)fail({4'h2,mem_rsp_fault});
    else begin
      source_words[fast_word]<=mem_rsp_rdata;
     fast_input_address<=fast_input_address+32'd8;
     if(fast_word==3)begin fast_x<=0;state<=FAST_H_BEGIN;end
     else begin fast_word<=fast_word+1'b1;mem_req_addr<=fast_input_address+32'd8;state<=FAST_READ_REQ;end
    end
   end
   FAST_H_BEGIN:begin fast_scan<=0;maximum<=32'sh80000000;state<=FAST_H_SCAN;end
   FAST_H_SCAN:begin
    if(fast_inside && sample_greater)maximum<=fast_sample;
    if(fast_scan==7)state<=FAST_H_STORE;
    else fast_scan<=fast_scan+1'b1;
   end
   FAST_H_STORE:begin
    horizontal_max[{fast_row,fast_x}]<=maximum;
    if(fast_x!=7)begin fast_x<=fast_x+1'b1;state<=FAST_H_BEGIN;end
    else if(fast_row!=7)begin
     fast_row<=fast_row+1'b1;fast_word<=0;mem_req_addr<=fast_input_address;
     fast_received<=0;fast_read_bad<=0;fast_last_seen<=0;
     state<=fast_bulk ? FAST_BULK_READ_CMD : FAST_READ_REQ;
    end else begin fast_y<=0;fast_x<=0;state<=FAST_V_BEGIN;end
   end
   FAST_V_BEGIN:begin fast_scan<=0;maximum<=32'sh80000000;state<=FAST_V_SCAN;end
   FAST_V_SCAN:begin
    if(fast_inside && sample_greater)maximum<=fast_sample;
    if(fast_scan==7)state<=FAST_PACK;
    else fast_scan<=fast_scan+1'b1;
   end
   FAST_PACK:begin
    if(!fast_x[0])begin
     fast_output_word[31:0]<=maximum;fast_x<=fast_x+1'b1;state<=FAST_V_BEGIN;
    end else begin
     fast_output_word[63:32]<=maximum;mem_req_addr<=output_address;
     state<=fast_bulk ? (fast_write_owned ? FAST_BULK_BEAT : FAST_BULK_WRITE_CMD) : FAST_WRITE_REQ;
    end
   end
   FAST_WRITE_REQ:if(mem_req_ready)state<=FAST_WRITE_WAIT;
   FAST_WRITE_WAIT:if(mem_rsp_valid)begin
    if(mem_rsp_fault!=0)fail({4'h2,mem_rsp_fault});
    else begin
     output_address<=output_address+32'd8;
     if(fast_x!=7)begin fast_x<=fast_x+1'b1;state<=FAST_V_BEGIN;end
     else if(fast_y!=7)begin fast_x<=0;fast_y<=fast_y+1'b1;state<=FAST_V_BEGIN;end
     else state<=RESPONSE;
    end
   end
   FAST_BULK_READ_CMD:if(rd_cmd_ready)state<=FAST_BULK_READ_DATA;
   FAST_BULK_READ_DATA:begin
    if(rd_valid&&rd_ready)begin
     if(fast_received<4)begin
       source_words[fast_received[1:0]]<=rd_data;
     end
     fast_received<=fast_received+1'b1;fast_last_seen<=fast_last_seen||rd_last;
     if(fast_read_packet_bad)fast_read_bad<=1;
    end
    if(rd_rsp_valid)begin
     if(rd_fault!=0 || fast_read_bad || (rd_valid&&rd_ready&&fast_read_packet_bad) ||
       fast_received+3'(rd_valid&&rd_ready)!=4 || !(fast_last_seen||(rd_valid&&rd_ready&&rd_last)))
      fail(rd_fault!=0 ? {4'h2,rd_fault} : 8'h28);
     else begin fast_input_address<=fast_input_address+32'd32;fast_x<=0;state<=FAST_H_BEGIN;end
    end
   end
   FAST_BULK_WRITE_CMD:if(wr_cmd_ready)begin fast_write_owned<=1;fast_sent<=0;state<=FAST_BULK_BEAT;end
   FAST_BULK_BEAT:if(wr_valid&&wr_ready)begin
    fast_sent<=fast_sent+1'b1;output_address<=output_address+32'd8;
    if(fast_sent==15)state<=FAST_BULK_DRAIN;
    else if(fast_x!=7)begin fast_x<=fast_x+1'b1;state<=FAST_V_BEGIN;end
    else begin fast_x<=0;fast_y<=fast_y+1'b1;state<=FAST_V_BEGIN;end
   end
   FAST_BULK_DRAIN:if(wr_rsp_valid)begin
    fast_write_owned<=0;
    if(wr_fault!=0 || rsp_fault!=0 || fast_sent!=16)
     fail(rsp_fault!=0 ? rsp_fault : wr_fault!=0 ? {4'h2,wr_fault} : 8'h28);
    else if(fast_y==7)state<=RESPONSE;
    else begin fast_x<=0;fast_y<=fast_y+1'b1;state<=FAST_V_BEGIN;end
   end
   RESPONSE: if(rsp_ready) state<=IDLE;
   default: fail(8'h01);
  endcase
 end
endmodule
