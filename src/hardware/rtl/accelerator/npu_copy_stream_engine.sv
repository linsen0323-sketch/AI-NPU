`timescale 1ns/1ps
// Continuous same-dtype copies use bounded 512-byte DMA tiles. Strides and
// conversions retain the checked scalar implementation. On a read fault,
// finish the accepted output descriptor with zero padding; the job is faulty
// and cannot be published. On a write fault, discard/drain all accepted reads.
module npu_copy_stream_engine #(
 parameter bit EXTERNAL_MATH = 1'b0,
 parameter bit ENABLE_RESIZE_BATCH = 1'b0,
 parameter bit ENABLE_RESIZE_BURST = 1'b0,
 parameter bit ENABLE_AFFINE_COALESCE = 1'b0
) (

 output wire rd_cmd_valid,input wire rd_cmd_ready,output wire [31:0] rd_cmd_addr,rd_cmd_bytes,
 input wire rd_valid,output wire rd_ready,input wire [63:0] rd_data,input wire [7:0] rd_keep,input wire rd_last,
 input wire rd_rsp_valid,output wire rd_rsp_ready,input wire [3:0] rd_fault,
 output wire wr_cmd_valid,input wire wr_cmd_ready,output wire [31:0] wr_cmd_addr,wr_cmd_bytes,
 output wire wr_valid,input wire wr_ready,output wire [63:0] wr_data,output wire [7:0] wr_keep,output wire wr_last,
 input wire wr_rsp_valid,output wire wr_rsp_ready,input wire [3:0] wr_fault,
 input logic clk,rst_n,input logic cmd_valid,output logic cmd_ready,
 input logic [31:0] cmd_tag,cmd_input_base,cmd_output_base,cmd_count,
 input logic [31:0] cmd_input_stride,cmd_output_stride,
 input logic [2:0] cmd_input_dtype,cmd_output_dtype,
 // Internal iterator sideband only: consecutive I32 sources, each repeated
 // twice. The stored AFF1 record and runtime package ABI remain unchanged.
 input logic cmd_repeat2,
 input logic cmd_transpose2,
 input logic cancel_valid,
 output logic mem_req_valid,input logic mem_req_ready,output logic mem_req_write,
 output logic [31:0] mem_req_addr,output logic [1:0] mem_req_size,
 output logic [63:0] mem_req_wdata,input logic mem_rsp_valid,output logic mem_rsp_ready,
 input logic signed [63:0] mem_rsp_rdata,input logic [3:0] mem_rsp_fault,
 output logic rsp_valid,input logic rsp_ready,output logic [31:0] rsp_tag,
 output logic [7:0] rsp_fault,output logic [31:0] rsp_completed,output logic busy,
 output logic math_req_valid,input logic math_req_ready,
 output logic [2:0] math_req_op,output logic signed [63:0] math_req_a,math_req_b,
 output logic [6:0] math_req_shift,input logic math_rsp_valid,output logic math_rsp_ready,
 input logic signed [63:0] math_rsp_result,input logic [1:0] math_rsp_fault
);
 typedef enum logic [4:0]{IDLE,CHECK_BYTES,CHECK_ENDS,CHECK,SELECT_PATH,SEND,STREAM,NEXT,FALLBACK_SEND,FALLBACK_WAIT,RESPONSE,
  REPEAT_READ_REQ,REPEAT_READ_WAIT,REPEAT_WRITE_REQ,REPEAT_WRITE_WAIT,REPEAT_NEXT,
  ROW_READ_CMD,ROW_READ_DATA,ROW_WRITE_CMD,ROW_WRITE_DATA,ROW_WRITE_WAIT,
  TRANSPOSE_READ_REQ,TRANSPOSE_READ_WAIT,GATHER_PREP,GATHER_READ_REQ,GATHER_READ_WAIT,
  GATHER_WRITE_CMD,GATHER_WRITE_DATA,GATHER_WRITE_WAIT}state_t;
 state_t state;
 reg [31:0] a,y,count,as_,ys,tag;
 reg [2:0] adtype,ydtype;
 reg [31:0] remaining,offset,length;
 reg read_started,write_started,read_done,write_done;
 reg [6:0] sent_words;
 reg [6:0] tile_words;
 reg [7:0] tile_last_keep;
 reg [7:0] error;
 wire [3:0] width=(adtype>=1&&adtype<=4) ? (4'd1<<(adtype-1'b1)) : 0;
 reg [35:0] total_bytes;
 reg [36:0] aend,yend;
 reg basic_eligible,eligible_q;
 reg repeat2,repeat_eligible_q,repeat_upper,repeat_cancelled;
 reg [63:0] repeat_word;
 reg [36:0] repeat_aend;
 // One 128-byte staging store, mutually reused by Resize source rows,
 // two-column transpose, and strided/unaligned I32 copy chunks. Output owns
 // the sealed contents through the complete descriptor's terminal response.
 (* ram_style="distributed" *) reg [63:0] repeat_row[0:15];
 reg transpose2;
 reg [3:0] transpose_row;
 reg [31:0] transpose_address;
 reg [5:0] gather_count,gather_index;
 reg [4:0] gather_sent,gather_words;
 reg [31:0] gather_address;
 wire gather_pair=as_==4 && a[2:0]==0 && !gather_index[0] && gather_index+1<gather_count;
 reg [36:0] gather_aend;
 reg gather_eligible_q,transpose_eligible_q;
 wire gather_eligible=ENABLE_AFFINE_COALESCE && !repeat2 && !transpose2 && count!=0 &&
     adtype==3 && ydtype==3 && (as_==4 || as_==8) && ys==4 && (a[1:0]|y[1:0])==0 &&
     gather_aend<=37'h100000000 && yend<=37'h100000000 &&
     (gather_aend<={5'd0,y} || yend<={5'd0,a});
 reg [32:0] transpose_aend;
 wire transpose_eligible=ENABLE_AFFINE_COALESCE && transpose2 && !repeat2 &&
     adtype==3 && ydtype==3 && count==22 && as_==5376 && ys==4 && a[2:0]==0 && y[2:0]==0 &&
     transpose_aend<=33'h100000000 && yend<=37'h100000000 &&
     ({4'd0,transpose_aend}<={5'd0,y} || yend<={5'd0,a});
 wire signed [6:0] gather_low_index=$signed({1'b0,gather_sent,1'b0})-$signed({6'd0,y[2]});
 wire signed [6:0] gather_high_index=gather_low_index+7'sd1;
 wire [7:0] gather_keep={ {4{gather_high_index>=0 && gather_high_index<$signed({1'b0,gather_count})}},
                         {4{gather_low_index>=0 && gather_low_index<$signed({1'b0,gather_count})}} };
 reg [4:0] row_received,row_sent;
 reg row_read_bad,row_last_seen;
 wire [4:0] row_input_words=count==32 ? 5'd8 : 5'd4;
 wire [4:0] row_output_words=transpose2 ? 5'd11 : count==32 ? 5'd16 : 5'd8;
 wire row_packet_bad=row_received>=row_input_words || rd_keep!=8'hff ||
     rd_last!=(row_received+1'b1==row_input_words);
 // Row repeat, transpose and gather own the same store in disjoint states.
 // Select their addresses before the two asynchronous read ports instead
 // of inferring a separate port for every output expression. The original
 // five-bit transpose arithmetic and signed gather bounds are retained.
 wire [4:0] transpose_low_index={row_sent[3:0],1'b0};
 wire [4:0] transpose_high_index=transpose_low_index+5'd1;
 reg [3:0] repeat_read_address[0:1];
 reg [1:0] repeat_read_upper,repeat_read_present;
 always @* begin
  repeat_read_address[0]={1'b0,row_sent[3:1]};
  repeat_read_address[1]={1'b0,row_sent[3:1]};
  repeat_read_upper={2{row_sent[0]}};
  repeat_read_present=2'b11;
  if(state==GATHER_WRITE_DATA)begin
   repeat_read_address[0]=gather_low_index[4:1];
   repeat_read_address[1]=gather_high_index[4:1];
   repeat_read_upper={gather_high_index[0],gather_low_index[0]};
   repeat_read_present={gather_high_index>=0 && gather_high_index<$signed({1'b0,gather_count}),
                        gather_low_index>=0 && gather_low_index<$signed({1'b0,gather_count})};
  end else if(transpose2)begin
   repeat_read_address[0]=transpose_low_index<11 ? transpose_low_index[3:0] : 4'(transpose_low_index-11);
   repeat_read_address[1]=transpose_high_index<11 ? transpose_high_index[3:0] : 4'(transpose_high_index-11);
   repeat_read_upper={transpose_high_index>=11,transpose_low_index>=11};
  end
 end
 wire [63:0] repeat_read_word[0:1];
 wire [31:0] repeat_read_value[0:1];
 generate for(genvar port_index=0;port_index<2;port_index=port_index+1)begin:g_repeat_read
  assign repeat_read_word[port_index]=repeat_row[repeat_read_address[port_index]];
  assign repeat_read_value[port_index]=!repeat_read_present[port_index] ? 32'd0 :
      repeat_read_upper[port_index] ? repeat_read_word[port_index][63:32] : repeat_read_word[port_index][31:0];
 end endgenerate
 // Every fill is state-exclusive and completes before its output state.
 // One word address and two half-word enables preserve scalar gather writes
 // without adding write ports or read-after-write bypass logic.
 wire repeat_row_write=rst_n && state==ROW_READ_DATA && rd_valid && rd_ready && row_received<row_input_words;
 wire repeat_transpose_write=rst_n && state==TRANSPOSE_READ_WAIT && mem_rsp_valid && mem_rsp_fault==0 &&
     !(repeat_cancelled || cancel_valid);
 wire repeat_gather_write=rst_n && state==GATHER_READ_WAIT && mem_rsp_valid && mem_rsp_fault==0 &&
     !(repeat_cancelled || cancel_valid);
 wire [3:0] repeat_write_address=repeat_row_write ? {1'b0,row_received[2:0]} :
     repeat_transpose_write ? transpose_row : gather_index[4:1];
 wire [63:0] repeat_write_data=repeat_row_write ? rd_data :
     repeat_gather_write && !gather_pair ? {2{mem_rsp_rdata[31:0]}} : mem_rsp_rdata;
 wire [1:0] repeat_write_enable=(repeat_row_write || repeat_transpose_write || (repeat_gather_write && gather_pair)) ? 2'b11 :
     repeat_gather_write ? (gather_index[0] ? 2'b10 : 2'b01) : 2'b00;
 always @(posedge clk)begin
  if(repeat_write_enable[0])repeat_row[repeat_write_address][31:0]<=repeat_write_data[31:0];
  if(repeat_write_enable[1])repeat_row[repeat_write_address][63:32]<=repeat_write_data[63:32];
 end
 // With row bursts disabled, retain Stage 4's acknowledged-pair fallback.
 wire repeat_eligible=ENABLE_RESIZE_BATCH && adtype==3 && ydtype==3 &&
  as_==0 && ys==4 && y[2:0]==0 &&
  ((repeat2 && (count==16 || count==32) && a[2:0]==0) ||
   (!repeat2 && count==2 && a[1:0]==0)) &&
  yend<=37'h100000000 && repeat_aend<=37'h100000000 &&
  (repeat_aend<={5'd0,y} || yend<={5'd0,a});
 wire repeat_request=state==REPEAT_READ_REQ || state==REPEAT_WRITE_REQ ||
     state==TRANSPOSE_READ_REQ || state==GATHER_READ_REQ;
 wire repeat_response=state==REPEAT_READ_WAIT || state==REPEAT_WRITE_WAIT ||
     state==TRANSPOSE_READ_WAIT || state==GATHER_READ_WAIT;
 wire [31:0] repeat_value=repeat_upper ? repeat_word[63:32] : repeat_word[31:0];
 wire eligible=basic_eligible&&total_bytes<=36'hffffffff&&aend<=37'h100000000&&yend<=37'h100000000&&
  (aend<={5'd0,y}||yend<={5'd0,a}||a==y);
 wire fallback=state==FALLBACK_SEND||state==FALLBACK_WAIT;
 wire inner_ready,inner_valid,inner_busy;
 wire [31:0] inner_tag,inner_completed;wire [7:0] inner_fault;
 wire m_valid,m_ready,m_write,m_rsp_valid,m_rsp_ready;
 wire [31:0] m_addr;wire [1:0] m_size;wire [63:0] m_wdata,m_rdata;wire [3:0] m_fault;
 assign cmd_ready=rst_n&&state==IDLE;assign busy=state!=IDLE;assign rsp_valid=rst_n&&state==RESPONSE;
 assign mem_req_valid=rst_n&&(repeat_request || (fallback&&m_valid));assign m_ready=fallback&&mem_req_ready;
 assign mem_req_write=repeat_request ? state==REPEAT_WRITE_REQ : m_write;
 assign mem_req_addr=state==TRANSPOSE_READ_REQ ? transpose_address : state==GATHER_READ_REQ ? gather_address :
     repeat_request ? (state==REPEAT_READ_REQ ? a+(rsp_completed<<1) : y+(rsp_completed<<2)) : m_addr;
 assign mem_req_size=state==GATHER_READ_REQ ? (gather_pair ? 2'd3 : 2'd2) :
     repeat_request ? ((state==REPEAT_READ_REQ && !repeat2) ? 2'd2 : 2'd3) : m_size;
 assign mem_req_wdata=repeat_request ? {repeat_value,repeat_value} : m_wdata;
 assign m_rsp_valid=fallback&&mem_rsp_valid;
 assign mem_rsp_ready=rst_n&&(repeat_response || (fallback&&m_rsp_ready));assign m_rdata=mem_rsp_rdata;assign m_fault=mem_rsp_fault;
 assign rd_cmd_valid=rst_n&&((state==SEND&&!read_started)||state==ROW_READ_CMD);
 assign wr_cmd_valid=rst_n&&((state==SEND&&!write_started)||state==ROW_WRITE_CMD||state==GATHER_WRITE_CMD);
 assign rd_cmd_addr=state==ROW_READ_CMD ? a : a+offset;
 assign wr_cmd_addr=state==ROW_WRITE_CMD ? y : state==GATHER_WRITE_CMD ? y+(rsp_completed<<2) : y+offset;
 assign rd_cmd_bytes=state==ROW_READ_CMD ? count<<1 : length;
 assign wr_cmd_bytes=state==ROW_WRITE_CMD ? count<<2 : state==GATHER_WRITE_CMD ? {26'd0,gather_count}<<2 : length;
 // Registered one-beat stream bridge. No fall-through data/valid path:
 // while a queued word is consumed, the next word can replace it on the
 // same edge. The reverse ready path is retained; throughput stays1/clock.
 // STREAM never uses rd_last: output last is the accepted descriptor's
 // sent_words/tile_words contract, exactly as before. Row paths retain
 // their existing rd_last packet checks and never enter this bridge.
 reg stream_valid;
 reg [63:0] stream_data;
 reg [7:0] stream_keep;
 wire stream_room=!stream_valid||wr_ready;
 wire discard=write_done||wr_fault!=0;
 wire last_word=sent_words+7'd1==tile_words;
 wire padding=read_done&&!stream_valid&&sent_words<tile_words;
 assign rd_ready=rst_n&&(state==ROW_READ_DATA || (state==STREAM&&(discard||stream_room)));
 assign wr_valid=rst_n&&((state==ROW_WRITE_DATA&&row_sent<row_output_words&&wr_fault==0) ||
     (state==GATHER_WRITE_DATA&&gather_sent<gather_words&&wr_fault==0) ||
     (state==STREAM&&!discard&&(stream_valid||padding)));
 assign wr_data=(state==GATHER_WRITE_DATA || state==ROW_WRITE_DATA) ?
     {repeat_read_value[1],repeat_read_value[0]} : (stream_valid ? stream_data : 64'd0);
 assign wr_keep=state==GATHER_WRITE_DATA ? gather_keep : state==ROW_WRITE_DATA ? 8'hff : (stream_valid ? stream_keep : (last_word ? tile_last_keep : 8'hff));
 assign wr_last=state==GATHER_WRITE_DATA ? gather_sent+1'b1==gather_words : state==ROW_WRITE_DATA ? row_sent+1'b1==row_output_words : last_word;
 assign rd_rsp_ready=rst_n&&((state==STREAM&&!read_done)||state==ROW_READ_DATA);
 assign wr_rsp_ready=rst_n&&((state==STREAM&&!write_done)||state==ROW_WRITE_DATA||state==ROW_WRITE_WAIT||
     state==GATHER_WRITE_DATA||state==GATHER_WRITE_WAIT);
 npu_copy_engine #(.EXTERNAL_MATH(EXTERNAL_MATH)) u_fallback (
  .clk(clk),.rst_n(rst_n),.cmd_valid(state==FALLBACK_SEND),.cmd_ready(inner_ready),
  .cmd_tag(tag),.cmd_input_base(a),.cmd_output_base(y),.cmd_count(count),
  .cmd_input_stride(as_),.cmd_output_stride(ys),.cmd_input_dtype(adtype),.cmd_output_dtype(ydtype),
  .mem_req_valid(m_valid),.mem_req_ready(m_ready),.mem_req_write(m_write),.mem_req_addr(m_addr),.mem_req_size(m_size),.mem_req_wdata(m_wdata),
  .mem_rsp_valid(m_rsp_valid),.mem_rsp_ready(m_rsp_ready),.mem_rsp_rdata(m_rdata),.mem_rsp_fault(m_fault),
  .rsp_valid(inner_valid),.rsp_ready(state==FALLBACK_WAIT),.rsp_tag(inner_tag),.rsp_fault(inner_fault),.rsp_completed(inner_completed),.busy(inner_busy),
  .math_req_valid(math_req_valid),.math_req_ready(math_req_ready),.math_req_op(math_req_op),.math_req_a(math_req_a),.math_req_b(math_req_b),
  .math_req_shift(math_req_shift),.math_rsp_valid(math_rsp_valid),.math_rsp_ready(math_rsp_ready),.math_rsp_result(math_rsp_result),.math_rsp_fault(math_rsp_fault));
 // Read terminal may arrive while the final word remains queued. Always
 // retire that word before padding. On a write fault, the descriptor owner
 // drains accepted reads, while the invalidated queue cannot publish data.
 always @(posedge clk)begin
  if(!rst_n)stream_valid<=0;
  else if(state!=STREAM||discard)stream_valid<=0;
  else if(stream_room)stream_valid<=rd_valid;
  if(rst_n&&state==STREAM&&!discard&&rd_valid&&stream_room)begin
   stream_data<=rd_data;stream_keep<=rd_keep;
  end
 end
 // Each payload is consumed only after its producer state. Keep the shift,
 // endpoint addition and range/overlap verdict off the same control path.
 always @(posedge clk)begin
  if(state==CHECK_BYTES)begin
   total_bytes<={4'd0,count}<<(adtype-1'b1);
   basic_eligible<=count!=0&&adtype>=1&&adtype<=4&&adtype==ydtype&&as_==width&&ys==width&&a[2:0]==0&&y[2:0]==0;
  end
  if(state==CHECK_ENDS)begin
   aend<={5'd0,a}+{1'b0,total_bytes};yend<={5'd0,y}+{1'b0,total_bytes};
   repeat_aend<={5'd0,a}+(repeat2 ? ({5'd0,count}<<1) : 37'd4);
   // Geometry is immutable from IDLE through terminal response. Register
   // complete affine endpoints here, then verdicts in CHECK, so SELECT_PATH
   // never combines stride selection, address arithmetic and overlap checks.
   gather_aend<={5'd0,a}+({5'd0,count}<<(as_==8 ? 3 : 2))-(as_==8 ? 37'd4 : 37'd0);
   transpose_aend<={1'b0,a}+33'd53768;
  end
  if(state==CHECK)begin
   eligible_q<=eligible;repeat_eligible_q<=repeat_eligible;
   gather_eligible_q<=gather_eligible;transpose_eligible_q<=transpose_eligible;
  end
  // Streaming tiles are already bounded to1..512 bytes by SELECT_PATH/NEXT.
  // SEND always precedes STREAM and holds length, including descriptor stalls.
  // Keep length rounding out of the downstream write-valid/last control cone.
  if(state==SEND)begin
   tile_words<=(length[9:0]+10'd7)>>3;
   tile_last_keep<=length[2:0]==0 ? 8'hff : (8'hff>>(4'd8-{1'b0,length[2:0]}));
  end
 end
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;a<=0;y<=0;count<=0;as_<=0;ys<=0;tag<=0;adtype<=0;ydtype<=0;remaining<=0;offset<=0;length<=0;
   read_started<=0;write_started<=0;read_done<=0;write_done<=0;sent_words<=0;error<=0;rsp_tag<=0;rsp_fault<=0;rsp_completed<=0;
   repeat2<=0;repeat_upper<=0;repeat_word<=0;repeat_cancelled<=0;
   row_received<=0;row_sent<=0;row_read_bad<=0;row_last_seen<=0;
   transpose2<=0;transpose_row<=0;transpose_address<=0;
   gather_count<=0;gather_index<=0;gather_sent<=0;gather_words<=0;gather_address<=0;
  end else begin
   if(cancel_valid && state!=IDLE && state!=RESPONSE)repeat_cancelled<=1;
   case(state)
   IDLE:if(cmd_valid)begin
    a<=cmd_input_base;y<=cmd_output_base;count<=cmd_count;as_<=cmd_input_stride;ys<=cmd_output_stride;
    tag<=cmd_tag;adtype<=cmd_input_dtype;ydtype<=cmd_output_dtype;rsp_tag<=cmd_tag;rsp_fault<=0;rsp_completed<=0;error<=0;offset<=0;state<=CHECK_BYTES;
    repeat2<=ENABLE_RESIZE_BATCH && cmd_repeat2;repeat_upper<=0;
    transpose2<=ENABLE_AFFINE_COALESCE && cmd_transpose2;
    repeat_cancelled<=cancel_valid;
   end
   CHECK_BYTES:state<=CHECK_ENDS;
   CHECK_ENDS:state<=CHECK;
   CHECK:state<=SELECT_PATH;
   SELECT_PATH:if((repeat2 || transpose2) && (repeat_cancelled || cancel_valid))begin rsp_fault<=8'he1;state<=RESPONSE;end
   else if(transpose_eligible_q)begin transpose_row<=0;transpose_address<=a;state<=TRANSPOSE_READ_REQ;end
   else if(transpose2)begin rsp_fault<=8'h03;state<=RESPONSE;end
   else if(repeat_eligible_q)begin
    if(ENABLE_RESIZE_BURST && repeat2)begin
     row_received<=0;row_sent<=0;row_read_bad<=0;row_last_seen<=0;state<=ROW_READ_CMD;
    end else state<=REPEAT_READ_REQ;
   end
   else if(repeat2)begin rsp_fault<=8'h03;state<=RESPONSE;end
   else if(eligible_q)begin remaining<=total_bytes[31:0];length<=total_bytes>512 ? 512 : total_bytes[31:0];
    read_started<=0;write_started<=0;read_done<=0;write_done<=0;sent_words<=0;state<=SEND;
   end else if(gather_eligible_q)state<=GATHER_PREP;
   else state<=FALLBACK_SEND;
   SEND:begin
    if(rd_cmd_valid&&rd_cmd_ready)read_started<=1;
    if(wr_cmd_valid&&wr_cmd_ready)write_started<=1;
    if((read_started||(rd_cmd_valid&&rd_cmd_ready))&&(write_started||(wr_cmd_valid&&wr_cmd_ready)))state<=STREAM;
   end
   STREAM:begin
    if(wr_valid&&wr_ready)sent_words<=sent_words+1'b1;
    if(rd_rsp_valid&&rd_rsp_ready)begin read_done<=1;error<=error|{4'h2,rd_fault} & {8{rd_fault!=0}};end
    if(wr_rsp_valid&&wr_rsp_ready)begin
     write_done<=1;
     error<=error|({4'h2,wr_fault}&{8{wr_fault!=0}})|((rd_rsp_valid&&rd_rsp_ready) ? ({4'h2,rd_fault}&{8{rd_fault!=0}}) : 8'd0);
    end
    if(read_done&&write_done&&!stream_valid)begin
     if(error!=0)begin rsp_fault<=error;state<=RESPONSE;end
     else begin rsp_completed<=rsp_completed+(length>>(adtype-1'b1));state<=NEXT;end
    end
   end
   NEXT:if(remaining==length)state<=RESPONSE;
    else begin
     offset<=offset+length;remaining<=remaining-length;length<=(remaining-length)>512 ? 512 : remaining-length;
     read_started<=0;write_started<=0;read_done<=0;write_done<=0;sent_words<=0;state<=SEND;
    end
   FALLBACK_SEND:if(inner_ready)state<=FALLBACK_WAIT;
   FALLBACK_WAIT:if(inner_valid)begin rsp_fault<=inner_tag!=tag ? 8'hf2 : inner_fault;rsp_completed<=inner_completed;state<=RESPONSE;end
   REPEAT_READ_REQ:if(mem_req_ready)state<=REPEAT_READ_WAIT;
   REPEAT_READ_WAIT:if(mem_rsp_valid)begin
    if(mem_rsp_fault!=0)begin rsp_fault<={4'h2,mem_rsp_fault};state<=RESPONSE;end
    else if(repeat2 && (repeat_cancelled || cancel_valid))begin rsp_fault<=8'he1;state<=RESPONSE;end
    else begin repeat_word<=mem_rsp_rdata;repeat_upper<=0;state<=REPEAT_WRITE_REQ;end
   end
   REPEAT_WRITE_REQ:if(mem_req_ready)state<=REPEAT_WRITE_WAIT;
   REPEAT_WRITE_WAIT:if(mem_rsp_valid)begin
    if(mem_rsp_fault!=0)begin rsp_fault<={4'h2,mem_rsp_fault};state<=RESPONSE;end
    else begin
     rsp_completed<=rsp_completed+32'd2;
     if(repeat2 && (repeat_cancelled || cancel_valid))begin rsp_fault<=8'he1;state<=RESPONSE;end
     else state<=REPEAT_NEXT;
    end
   end
   REPEAT_NEXT:if(repeat2 && (repeat_cancelled || cancel_valid))begin rsp_fault<=8'he1;state<=RESPONSE;end
    else if(rsp_completed==count)state<=RESPONSE;
    else if(!repeat_upper)begin repeat_upper<=1;state<=REPEAT_WRITE_REQ;end
    else state<=REPEAT_READ_REQ;
   ROW_READ_CMD:if(rd_cmd_ready)state<=ROW_READ_DATA;
   ROW_READ_DATA:begin
    if(rd_valid&&rd_ready)begin
     row_received<=row_received+1'b1;row_last_seen<=row_last_seen||rd_last;
     if(row_packet_bad)row_read_bad<=1;
    end
    if(rd_rsp_valid)begin
     if(rd_fault!=0 || row_read_bad || (rd_valid&&rd_ready&&row_packet_bad) ||
        row_received+5'(rd_valid&&rd_ready)!=row_input_words || !(row_last_seen||(rd_valid&&rd_ready&&rd_last)))begin
      rsp_fault<=rd_fault!=0 ? {4'h2,rd_fault} : 8'h28;state<=RESPONSE;
     end else if(repeat_cancelled||cancel_valid)begin rsp_fault<=8'he1;state<=RESPONSE;end
     else begin row_sent<=0;state<=ROW_WRITE_CMD;end
    end
   end
   ROW_WRITE_CMD:if(wr_cmd_ready)state<=ROW_WRITE_DATA;
   ROW_WRITE_DATA:begin
    if(wr_valid&&wr_ready)begin
     row_sent<=row_sent+1'b1;
     if(wr_last)state<=ROW_WRITE_WAIT;
    end
    // Transport faults revoke its input lease, but never its terminal lease.
    if(wr_fault!=0)begin error<={4'h2,wr_fault};state<=ROW_WRITE_WAIT;end
    if(wr_rsp_valid)begin
     if(wr_fault!=0 || error!=0)rsp_fault<=error!=0 ? error : {4'h2,wr_fault};
     else if(row_sent+5'(wr_valid&&wr_ready)!=row_output_words)rsp_fault<=8'h28;
     else begin rsp_completed<=count;if(repeat_cancelled||cancel_valid)rsp_fault<=8'he1;end
     state<=RESPONSE;
    end
   end
   ROW_WRITE_WAIT:if(wr_rsp_valid)begin
    if(wr_fault!=0 || error!=0)rsp_fault<=error!=0 ? error : {4'h2,wr_fault};
    else if(row_sent!=row_output_words)rsp_fault<=8'h28;
    else begin rsp_completed<=count;if(repeat_cancelled||cancel_valid)rsp_fault<=8'he1;end
    state<=RESPONSE;
   end
   TRANSPOSE_READ_REQ:if(mem_req_ready)state<=TRANSPOSE_READ_WAIT;
   TRANSPOSE_READ_WAIT:if(mem_rsp_valid)begin
    if(mem_rsp_fault!=0)begin rsp_fault<={4'h2,mem_rsp_fault};state<=RESPONSE;end
    else if(repeat_cancelled||cancel_valid)begin rsp_fault<=8'he1;state<=RESPONSE;end
    else begin
     if(transpose_row==10)begin row_sent<=0;state<=ROW_WRITE_CMD;end
     else begin transpose_row<=transpose_row+1'b1;transpose_address<=transpose_address+32'd5376;state<=TRANSPOSE_READ_REQ;end
    end
   end
   GATHER_PREP:if(repeat_cancelled||cancel_valid)begin rsp_fault<=8'he1;state<=RESPONSE;end
    else begin
     gather_count<=count-rsp_completed>32 ? 6'd32 : 6'(count-rsp_completed);
     gather_words<=5'(((count-rsp_completed>32 ? 32'd128 : (count-rsp_completed)<<2)+{29'd0,y[2:0]}+7)>>3);
     gather_index<=0;gather_sent<=0;gather_address<=a+(rsp_completed<<(as_==8 ? 3 : 2));
     state<=GATHER_READ_REQ;
    end
   GATHER_READ_REQ:if(mem_req_ready)state<=GATHER_READ_WAIT;
   GATHER_READ_WAIT:if(mem_rsp_valid)begin
    if(mem_rsp_fault!=0)begin rsp_fault<={4'h2,mem_rsp_fault};state<=RESPONSE;end
    else if(repeat_cancelled||cancel_valid)begin rsp_fault<=8'he1;state<=RESPONSE;end
    else begin
     gather_index<=gather_index+(gather_pair ? 6'd2 : 6'd1);
     gather_address<=gather_address+(gather_pair || as_==8 ? 32'd8 : 32'd4);
     if(gather_index+(gather_pair ? 6'd2 : 6'd1)==gather_count)state<=GATHER_WRITE_CMD;
     else state<=GATHER_READ_REQ;
    end
   end
   GATHER_WRITE_CMD:if(wr_cmd_ready)state<=GATHER_WRITE_DATA;
   GATHER_WRITE_DATA:begin
    if(wr_valid&&wr_ready)begin gather_sent<=gather_sent+1'b1;if(wr_last)state<=GATHER_WRITE_WAIT;end
    if(wr_fault!=0)begin error<={4'h2,wr_fault};state<=GATHER_WRITE_WAIT;end
    if(wr_rsp_valid)begin
     // A terminal before the last beat is a failed descriptor, never a prefix.
     rsp_fault<=error!=0 ? error : wr_fault!=0 ? {4'h2,wr_fault} : 8'h28;state<=RESPONSE;
    end
   end
   GATHER_WRITE_WAIT:if(wr_rsp_valid)begin
    if(wr_fault!=0 || error!=0 || gather_sent!=gather_words)begin
     rsp_fault<=error!=0 ? error : wr_fault!=0 ? {4'h2,wr_fault} : 8'h28;state<=RESPONSE;
    end else begin
     rsp_completed<=rsp_completed+{26'd0,gather_count};
     if(repeat_cancelled||cancel_valid)begin rsp_fault<=8'he1;state<=RESPONSE;end
     else if(rsp_completed+{26'd0,gather_count}==count)state<=RESPONSE;
     else state<=GATHER_PREP;
    end
   end
   RESPONSE:if(rsp_ready)state<=IDLE;
   default:begin rsp_fault<=1;state<=RESPONSE;end
  endcase
  end
 end
endmodule
