`timescale 1ns/1ps
// Execute the compiled records associated with ONE checked graph instruction.
// Plan cache is keyed by immutable model generation and all physical ranges.
// No PS per-layer stepping; completion preserves task/frame/generation/index.
module npu_graph_plan_backend #(
 parameter bit STREAMING=1'b1,parameter bit PS_PREDECODED=1'b0,
 parameter bit ENABLE_PE_SPATIAL4=1'b1,ENABLE_RESIZE_BURST=1'b1,
 parameter bit ENABLE_MAXPOOL_BULK=1'b1,ENABLE_AFFINE_COALESCE=1'b1,
 parameter bit ENABLE_PROFILE_TRACE=1'b1,ENABLE_STALL_DIAG=1'b1,
 parameter bit ENABLE_LUT_TDP=1'b0,
 parameter bit SHARED_WEIGHT_SELECT=1'b0
) (

 output wire rd_cmd_valid,input wire rd_cmd_ready,output wire [31:0] rd_cmd_addr,rd_cmd_bytes,
 input wire rd_valid,output wire rd_ready,input wire [63:0] rd_data,input wire [7:0] rd_keep,input wire rd_last,
 input wire rd_rsp_valid,output wire rd_rsp_ready,input wire [3:0] rd_fault,

 output wire wr_cmd_valid,input wire wr_cmd_ready,output wire [31:0] wr_cmd_addr,wr_cmd_bytes,
 output wire wr_valid,input wire wr_ready,output wire [63:0] wr_data,output wire [7:0] wr_keep,output wire wr_last,
 input wire wr_rsp_valid,output wire wr_rsp_ready,input wire [3:0] wr_fault,
 input logic clk,rst_n,input logic cmd_valid,output logic cmd_ready,
 input logic [31:0] cmd_task_id,cmd_frame_id,cmd_model_generation,cmd_op_index,
 input logic [1023:0] cmd_op_record,
 input logic [31:0] cmd_model_id,cmd_model_base,cmd_image_bytes,cmd_graph_ops,
 input logic [31:0] cmd_plan_base,cmd_plan_capacity,
 input logic [31:0] cmd_workspace_base,cmd_workspace_capacity,
 input logic cancel_valid,output logic cancel_ready,input logic invalidate,
 output logic mem_req_valid,input logic mem_req_ready,output logic mem_req_write,
 output logic [31:0] mem_req_addr,output logic [1:0] mem_req_size,output logic [63:0] mem_req_wdata,
 input logic mem_rsp_valid,output logic mem_rsp_ready,input logic signed [63:0] mem_rsp_rdata,input logic [3:0] mem_rsp_fault,
 output logic packed_req_valid,input logic packed_req_ready,output logic packed_req_a16,packed_req_first,packed_req_last,
 output logic [127:0] packed_req_act,output logic [2047:0] packed_req_weight,
 output wire packed_req_spatial4,output wire [511:0] packed_req_act4,
 input logic packed_rsp_valid,output logic packed_rsp_ready,input logic [2047:0] packed_rsp_acc,input logic [1:0] packed_rsp_fault,
 input logic packed_busy,output logic packed_abandon_valid,input logic packed_abandon_ready,
 output logic rsp_valid,input logic rsp_ready,output logic [31:0] rsp_task_id,rsp_frame_id,rsp_model_generation,rsp_op_index,
 output logic [7:0] rsp_fault,output logic busy,output logic plan_cache_hit,
 output wire [84:0] stall_events,
 output wire [31:0] stall_input_bytes,stall_weight_bytes,
 output wire [4:0] stall_window_count,
 output wire [4:0] perf_conv_events,
 output logic [1:0] packed_req_weight_group
);

 wire d_rd_cmd_valid,d_rd_cmd_ready,d_rd_valid,d_rd_ready,d_rd_last,d_rd_rsp_valid,d_rd_rsp_ready,bulk_guard_idle;
 wire [31:0] d_rd_cmd_addr,d_rd_cmd_bytes;
 wire [63:0] d_rd_data;wire [7:0] d_rd_keep;wire [3:0] d_rd_fault;
 wire d_wr_cmd_valid,d_wr_cmd_ready,d_wr_valid,d_wr_ready,d_wr_last,d_wr_rsp_valid,d_wr_rsp_ready;
 wire [31:0] d_wr_cmd_addr,d_wr_cmd_bytes;wire [63:0] d_wr_data;wire [7:0] d_wr_keep;wire [3:0] d_wr_fault;
 typedef enum logic [4:0] {IDLE,CHECK_COMMAND,HEADER_WORD,HEADER_VALUE,HEADER_CHECK,
  BODY_WORD,BODY_VALUE,MODEL_CRC,MODEL_VALUE,LUT_COMMAND,LUT_RESPONSE,
  INDEX_FIRST,INDEX_FIRST_VALUE,INDEX_COUNT,INDEX_COUNT_VALUE,RECORD_WORD,RECORD_VALUE,
  RECORD_FLUSH,RECORD_CHECK,DISPATCH,DISPATCH_WAIT,MEM_REQUEST,MEM_WAIT,CRC_BYTE,RESPONSE} state_t;
 state_t state,mem_return;
 logic [31:0] h[0:31];logic [4095:0] record;
 // OPT1 plan word32: bit0 permits exact SiLU fusion, bit1 requires immutable
 // PS-checked affine records. Both are retained with the generation/LUT cache.
 logic [31:0] plan_features;
 logic [31:0] model_id,model_base,image_bytes,graph_ops,plan_base,plan_capacity,workspace_base,workspace_capacity;
 logic [31:0] opcode,body_offset,first_record,record_count,record_number;
 logic [5:0] header_index;logic [6:0] record_word;
 logic [31:0] mem_address,mem_value,header_crc,body_crc;
 logic cancelled,cache_valid,admission_hit;
 logic [31:0] cached_model,cached_image,cached_plan,cached_plan_capacity,cached_workspace,cached_workspace_capacity,cached_generation,cached_id;
 logic [31:0] const_base;
 logic dispatch_ready,dispatch_valid,dispatch_rsp_valid,dispatch_rsp_ready,dispatch_busy;
 logic [7:0] dispatch_fault;logic [31:0] dispatch_tag;
 logic config_valid,config_ready,config_rsp_valid,config_rsp_ready;logic [3:0] config_fault;
 logic [1:0] c_req_valid,c_req_ready,c_req_write,c_rsp_valid,c_rsp_ready;
 logic [63:0] c_req_addr;logic [3:0] c_req_size;
 logic [127:0] c_req_wdata,c_rsp_rdata;logic [7:0] c_rsp_fault;
 logic fabric_idle,guard_idle,admission_idle;
 logic guard_req_valid,guard_req_ready,guard_req_write,guard_rsp_valid,guard_rsp_ready;
 logic [31:0] guard_req_addr;logic [1:0] guard_req_size;logic [63:0] guard_req_wdata;
 logic signed [63:0] guard_rsp_rdata;logic [3:0] guard_rsp_fault;
 logic [32:0] model_end,plan_end,workspace_end,index_end,const_end;
 logic [40:0] records_size,records_end,record_region_base,record_address;
 logic command_bad,header_bad,record_bad;
 logic header_reserved_bad,record_reserved_bad;
 logic crc_is_header;logic [1:0] crc_byte_index;
 logic [31:0] crc_data,crc_work,crc_next;
 npu_stream_guard u_bulk_guard (
  .clk(clk),.rst_n(rst_n),.model_base(model_base),.model_bytes(image_bytes),.plan_base(plan_base),.plan_bytes(plan_capacity),
  .workspace_base(workspace_base),.workspace_bytes(workspace_capacity),
  .c_rd_cmd_valid(d_rd_cmd_valid),
  .c_rd_cmd_ready(d_rd_cmd_ready),
  .c_rd_cmd_addr(d_rd_cmd_addr),
  .c_rd_cmd_bytes(d_rd_cmd_bytes),
  .c_rd_valid(d_rd_valid),
  .c_rd_ready(d_rd_ready),
  .c_rd_data(d_rd_data),
  .c_rd_keep(d_rd_keep),
  .c_rd_last(d_rd_last),
  .c_rd_rsp_valid(d_rd_rsp_valid),
  .c_rd_rsp_ready(d_rd_rsp_ready),
  .c_rd_fault(d_rd_fault),
  .rd_cmd_valid(rd_cmd_valid),
  .rd_cmd_ready(rd_cmd_ready),
  .rd_cmd_addr(rd_cmd_addr),
  .rd_cmd_bytes(rd_cmd_bytes),
  .rd_valid(rd_valid),
  .rd_ready(rd_ready),
  .rd_data(rd_data),
  .rd_keep(rd_keep),
  .rd_last(rd_last),
  .rd_rsp_valid(rd_rsp_valid),
  .rd_rsp_ready(rd_rsp_ready),
  .rd_fault(rd_fault),
  .c_wr_cmd_valid(d_wr_cmd_valid),
  .c_wr_cmd_ready(d_wr_cmd_ready),
  .c_wr_cmd_addr(d_wr_cmd_addr),
  .c_wr_cmd_bytes(d_wr_cmd_bytes),
  .c_wr_valid(d_wr_valid),
  .c_wr_ready(d_wr_ready),
  .c_wr_data(d_wr_data),
  .c_wr_keep(d_wr_keep),
  .c_wr_last(d_wr_last),
  .c_wr_rsp_valid(d_wr_rsp_valid),
  .c_wr_rsp_ready(d_wr_rsp_ready),
  .c_wr_fault(d_wr_fault),
  .wr_cmd_valid(wr_cmd_valid),
  .wr_cmd_ready(wr_cmd_ready),
  .wr_cmd_addr(wr_cmd_addr),
  .wr_cmd_bytes(wr_cmd_bytes),
  .wr_valid(wr_valid),
  .wr_ready(wr_ready),
  .wr_data(wr_data),
  .wr_keep(wr_keep),
  .wr_last(wr_last),
  .wr_rsp_valid(wr_rsp_valid),
  .wr_rsp_ready(wr_rsp_ready),
  .wr_fault(wr_fault),
  .idle(bulk_guard_idle));
 function automatic logic [31:0] crc_byte(input logic [31:0] seed,input logic [7:0] data);
  logic [31:0] c;begin
   c=seed^{24'd0,data};
   for(integer b=0;b<8;b=b+1) c=c[0] ? ((c>>1)^32'hedb88320) : (c>>1);
   crc_byte=c;
  end
 endfunction
 // Route each DDR word through one local eight-word bank before commit.
 // Distinct capture enables keep the bank registers independent, reducing
 // mem_value fanout without retaining a second full record. Payload needs
 // no reset: HEADER_CHECK/RECORD_CHECK follow complete, committed loads.
 generate
  for(genvar bank=0;bank<16;bank=bank+1) begin : g_load_bank
   localparam integer FIRST_WORD=bank*8;
   localparam bit HAS_RECORD=bank!=7 && FIRST_WORD<(PS_PREDECODED ? 122 : 91);
   if(bank<4 || HAS_RECORD)begin:g_payload
    logic pending,header_q;
    logic [31:0] data_q;
    logic [2:0] word_q;
    wire header_capture=bank<4 && rst_n && state==HEADER_VALUE && header_index[5:3]==3'(bank);
    wire record_capture=HAS_RECORD && rst_n && state==RECORD_VALUE && record_word[6:3]==4'(bank) &&
      record_word<(PS_PREDECODED ? 122 : 91);
    wire capture=header_capture || record_capture;
    always_ff @(posedge clk)begin
     if(!rst_n)pending<=0;
     else pending<=capture;
     if(capture)begin
      data_q<=mem_value;
      word_q<=header_capture ? header_index[2:0] : record_word[2:0];
      header_q<=header_capture;
     end
    end
    for(genvar word=0;word<8;word=word+1)begin:g_word
     localparam integer INDEX=FIRST_WORD+word;
     if(bank<4)begin:g_header
      always_ff @(posedge clk)
       if(rst_n && pending && header_q && word_q==3'(word)) h[INDEX]<=data_q;
     end
     if((INDEX>=56 && INDEX<64) || INDEX>=(PS_PREDECODED ? 122 : 91))begin:g_reserved
      assign record[INDEX*32+:32]=32'd0;
     end else begin:g_record
      always_ff @(posedge clk)
       if(rst_n && pending && !header_q && word_q==3'(word)) record[INDEX*32+:32]<=data_q;
     end
    end
   end else begin:g_reserved_bank
    assign record[FIRST_WORD*32+:256]=256'd0;
   end
  end
 endgenerate
 always_comb begin
  // Constant-fold the CRC datapath out of the production specialization,
  // independently of the tool's unreachable-state/FSM pruning decisions.
  crc_next=PS_PREDECODED ? 32'd0 : crc_byte(crc_work,crc_data[7:0]);
  cmd_ready=rst_n && state==IDLE && admission_idle;
  cancel_ready=rst_n;rsp_valid=rst_n && state==RESPONSE;
  busy=state!=IDLE || !admission_idle;
  admission_hit=cache_valid && cached_model==cmd_model_base && cached_image==cmd_image_bytes &&
   cached_plan==cmd_plan_base && cached_plan_capacity==cmd_plan_capacity && cached_workspace==cmd_workspace_base &&
   cached_workspace_capacity==cmd_workspace_capacity && cached_generation==cmd_model_generation && cached_id==cmd_model_id;
  command_bad=(model_id!=1 && model_id!=3) || model_base[11:0]!=0 || plan_base[11:0]!=0 || workspace_base[11:0]!=0 ||
   image_bytes==0 || plan_capacity<4096 || plan_capacity[11:0]!=0 || workspace_capacity==0 ||
   workspace_capacity[11:0]!=0 || graph_ops==0 || graph_ops>32'h1fffffff || rsp_op_index>=graph_ops ||
   model_end>33'h100000000 || plan_end>33'h100000000 || workspace_end>33'h100000000 ||
   ({1'b0,model_base}<plan_end && {1'b0,plan_base}<model_end) ||
   ({1'b0,workspace_base}<plan_end && {1'b0,plan_base}<workspace_end) ||
   ({1'b0,model_base}<workspace_end && {1'b0,workspace_base}<model_end);
  records_size=({9'd0,h[8]}<<9);
  const_base=model_base+h[18];
  header_bad=h[0]!=32'h5055504e || h[1]!=32'h00314e4c || h[2]!=1 || h[3]!=256 ||
   h[4]!=model_id || h[5]!=2 || h[6]!=512 || h[7]!=graph_ops || h[8]==0 || h[9]!=4096 ||
   {1'b0,h[10]}!=({1'b0,h[7]}<<3) || h[11][11:0]!=0 || {1'b0,h[11]}<index_end ||
   records_size!={9'd0,h[12]} || records_end>{9'd0,h[13]} || h[13][11:0]!=0 || h[13]>plan_capacity ||
   h[15]!=image_bytes || h[19]==0 || h[18][11:0]!=0 || const_end>{1'b0,image_bytes} ||
   h[31]==0 || h[31]>workspace_capacity || h[31][11:0]!=0 ||
   (!PS_PREDECODED && (header_crc^32'hffffffff)!=h[17]) ||
   header_reserved_bad || h[22]>7 || h[25]>7;
  // Only the explicitly adapted ResNet profile may request original signed40
  // accumulation and signed72/73 quantization. Q16 model records stay flags=0.
  record_bad=record_reserved_bad || record[1*32+:32]!=rsp_op_index ||
   record[3*32+:32]!=opcode ||
   record[7*32+:32]>8 || record[0+:32]<1 || record[0+:32]>6;
  if(PS_PREDECODED&&(record[120*32+:32]!=0||record[121*32+:32]!=0)&&
     (!plan_features[3]||record[0+:32]!=5||record[120*32+:32]!=32'h314b5057))record_bad=1;
  if(model_id==1)begin
   if(record[2*32+:32]!=32'd1)record_bad=1;
  end else if(record[2*32+:32]!=0)begin
   if(record[2*32+3] || record[2*32+4])begin
    if(!plan_features[2] || !STREAMING || record[0+:32]!=5 || opcode!=2 || record[6*32+:32]!=3 ||
       (record[2*32+:32]!=8 && record[2*32+:32]!=16 && record[2*32+:32]!=24))record_bad=1;
   end else if(!plan_features[0] || opcode!=9 || record[0+:32]!=1 ||
      (record[2*32+:32]!=32'd2 && record[2*32+:32]!=32'd6) ||
      record[4*32+:32]!=3 ||
      (record[2*32+2] ? (record[6*32+:32]!=1 && record[6*32+:32]!=2) : record[6*32+:32]!=3))record_bad=1;
  end
  case(opcode)
   1,4,5,9,10,11: if(record[0+:32]!=1) record_bad=1;
   20: if(record[0+:32]!=2 || model_id!=1) record_bad=1;
   12,13,14,15,16,17,18: if(record[0+:32]!=4) record_bad=1;
   2,3: if(record[0+:32]!=5) record_bad=1;
   19: if(record[0+:32]!=6 ||
     record[4*32+:32]!=(model_id==1 ? 32'd1 : 32'd3) ||
     record[6*32+:32]!=(model_id==1 ? 32'd1 : 32'd3)) record_bad=1;
   default: record_bad=1;
  endcase
  if(model_id==1 && opcode!=2 && opcode!=3 && opcode!=4 && opcode!=11 && opcode!=19 && opcode!=20)record_bad=1;
  c_req_valid[0]=rst_n && state==MEM_REQUEST;c_req_write[0]=0;c_req_addr[31:0]=mem_address;
  c_req_size[1:0]=2'd2;c_req_wdata[63:0]=0;c_rsp_ready[0]=rst_n && state==MEM_WAIT;
  config_valid=rst_n && state==LUT_COMMAND;config_rsp_ready=rst_n && state==LUT_RESPONSE;
  dispatch_valid=rst_n && state==DISPATCH;dispatch_rsp_ready=rst_n && state==DISPATCH_WAIT;
 end
 // Child work starts only after a command is accepted. Retain the drained
 // admission token until that handshake, then rearm only back in IDLE after
 // every child has drained. This cuts engine-state fanout to parent enables.
 always_ff @(posedge clk)begin
  if(!rst_n)admission_idle<=0;
  else if(state!=IDLE || (cmd_valid && cmd_ready))admission_idle<=0;
  else admission_idle<=fabric_idle && guard_idle && !dispatch_busy && bulk_guard_idle;
 end
 // Prepare full endpoints on the same handshake that captures their operands.
 // CHECK_COMMAND consumes them on the following edge; equality with2^32
 // remains legal. No child work or memory access is admitted before checking.
 always_ff @(posedge clk)begin
  if(rst_n && cmd_valid && cmd_ready)begin
   model_end<={1'b0,cmd_model_base}+{1'b0,cmd_image_bytes};
   plan_end<={1'b0,cmd_plan_base}+{1'b0,cmd_plan_capacity};
   workspace_end<={1'b0,cmd_workspace_base}+{1'b0,cmd_workspace_capacity};
  end
 end
 // All range operands have committed before the final reserved header word.
 // HEADER_CHECK follows this edge in both predecoded and CRC-scanning modes.
 always_ff @(posedge clk) begin
  if(rst_n && state==HEADER_VALUE && header_index==63)begin
   index_end<={1'b0,h[9]}+{1'b0,h[10]};
   records_end<={9'd0,h[11]}+{9'd0,h[12]};
   const_end<={1'b0,h[18]}+{1'b0,h[19]};
  end
 end
 task automatic fail(input logic [7:0] code);begin rsp_fault<=code;state<=RESPONSE;end endtask
 task automatic read_word(input logic [31:0] address,input state_t destination);
  begin mem_address<=address;mem_return<=destination;state<=MEM_REQUEST;end
 endtask
 // Record loading cannot resume until dispatch's terminal response is
 // consumed. The local write stages drain before RECORD_CHECK, so the
 // iterator borrows one immutable, completely committed record.
 npu_plan_dispatch #(.SHARED_WEIGHT_SELECT(SHARED_WEIGHT_SELECT),
  .ENABLE_PROFILE_TRACE(ENABLE_PROFILE_TRACE),.ENABLE_STALL_DIAG(ENABLE_STALL_DIAG),
  .ENABLE_LUT_TDP(ENABLE_LUT_TDP),
  .BORROW_RECORD(1'b1),.STREAMING(STREAMING),.PS_PREDECODED(PS_PREDECODED),
  .ENABLE_PE_SPATIAL4(ENABLE_PE_SPATIAL4),.ENABLE_RESIZE_BURST(ENABLE_RESIZE_BURST),
  .ENABLE_MAXPOOL_BULK(ENABLE_MAXPOOL_BULK),.ENABLE_AFFINE_COALESCE(ENABLE_AFFINE_COALESCE)) u_dispatch (
  .stall_events(stall_events),.stall_input_bytes(stall_input_bytes),.stall_weight_bytes(stall_weight_bytes),.stall_window_count(stall_window_count),
  .perf_conv_events(perf_conv_events),
  .rd_cmd_valid(d_rd_cmd_valid),
  .rd_cmd_ready(d_rd_cmd_ready),
  .rd_cmd_addr(d_rd_cmd_addr),
  .rd_cmd_bytes(d_rd_cmd_bytes),
  .rd_valid(d_rd_valid),
  .rd_ready(d_rd_ready),
  .rd_data(d_rd_data),
  .rd_keep(d_rd_keep),
  .rd_last(d_rd_last),
  .rd_rsp_valid(d_rd_rsp_valid),
  .rd_rsp_ready(d_rd_rsp_ready),
  .rd_fault(d_rd_fault),
  .wr_cmd_valid(d_wr_cmd_valid),
  .wr_cmd_ready(d_wr_cmd_ready),
  .wr_cmd_addr(d_wr_cmd_addr),
  .wr_cmd_bytes(d_wr_cmd_bytes),
  .wr_valid(d_wr_valid),
  .wr_ready(d_wr_ready),
  .wr_data(d_wr_data),
  .wr_keep(d_wr_keep),
  .wr_last(d_wr_last),
  .wr_rsp_valid(d_wr_rsp_valid),
  .wr_rsp_ready(d_wr_rsp_ready),
  .wr_fault(d_wr_fault),
  .clk(clk),.rst_n(rst_n),.cmd_valid(dispatch_valid),.cmd_ready(dispatch_ready),
  .cmd_tag(rsp_op_index),.cmd_record(record),.cmd_constants_base(const_base),.cmd_constants_bytes(h[19]),
  .cmd_workspace_base(workspace_base),.cmd_workspace_bytes(h[31]),
  // Local same-cycle cancellation checks below still prevent publication.
  // Forward the sticky flag one clock later; accepted child work still drains.
  .cancel_valid(cancelled && (state==DISPATCH || state==DISPATCH_WAIT)),.cancel_ready(),
  .config_valid(config_valid),.config_ready(config_ready),
  .sigmoid_base(const_base+h[20]),.sigmoid_entries(h[21]),.sigmoid_dtype(h[22][2:0]),
  .exp_base(const_base+h[23]),.exp_entries(h[24]),.exp_dtype(h[25][2:0]),
  .config_rsp_valid(config_rsp_valid),.config_rsp_ready(config_rsp_ready),.config_rsp_fault(config_fault),
  .mem_req_valid(c_req_valid[1]),.mem_req_ready(c_req_ready[1]),.mem_req_write(c_req_write[1]),
  .mem_req_addr(c_req_addr[63:32]),.mem_req_size(c_req_size[3:2]),.mem_req_wdata(c_req_wdata[127:64]),
  .mem_rsp_valid(c_rsp_valid[1]),.mem_rsp_ready(c_rsp_ready[1]),.mem_rsp_rdata(c_rsp_rdata[127:64]),.mem_rsp_fault(c_rsp_fault[7:4]),
  .packed_req_valid(packed_req_valid),.packed_req_ready(packed_req_ready),.packed_req_a16(packed_req_a16),
  .packed_req_first(packed_req_first),.packed_req_last(packed_req_last),.packed_req_act(packed_req_act),.packed_req_weight(packed_req_weight),.packed_req_weight_group(packed_req_weight_group),
  .packed_req_spatial4(packed_req_spatial4),.packed_req_act4(packed_req_act4),
  .packed_rsp_valid(packed_rsp_valid),.packed_rsp_ready(packed_rsp_ready),.packed_rsp_acc(packed_rsp_acc),.packed_rsp_fault(packed_rsp_fault),
  .packed_busy(packed_busy),.packed_abandon_valid(packed_abandon_valid),.packed_abandon_ready(packed_abandon_ready),
  .rsp_valid(dispatch_rsp_valid),.rsp_ready(dispatch_rsp_ready),.rsp_tag(dispatch_tag),.rsp_fault(dispatch_fault),.rsp_completed(),.busy(dispatch_busy));
 npu_scalar_fabric #(.CLIENTS(2)) u_fabric (
  .clk(clk),.rst_n(rst_n),.c_req_valid(c_req_valid),.c_req_ready(c_req_ready),
  .c_req_write(c_req_write),.c_req_addr(c_req_addr),.c_req_size(c_req_size),.c_req_wdata(c_req_wdata),
  .c_rsp_valid(c_rsp_valid),.c_rsp_ready(c_rsp_ready),.c_rsp_rdata(c_rsp_rdata),.c_rsp_fault(c_rsp_fault),
  .req_valid(guard_req_valid),.req_ready(guard_req_ready),.req_write(guard_req_write),.req_addr(guard_req_addr),
  .req_size(guard_req_size),.req_wdata(guard_req_wdata),.rsp_valid(guard_rsp_valid),.rsp_ready(guard_rsp_ready),
  .rsp_rdata(guard_rsp_rdata),.rsp_fault(guard_rsp_fault),.idle(fabric_idle),.active_owner());
 npu_scalar_guard u_guard (
  .clk(clk),.rst_n(rst_n),.model_base(model_base),.model_bytes(image_bytes),.plan_base(plan_base),.plan_bytes(plan_capacity),
  .workspace_base(workspace_base),.workspace_bytes(workspace_capacity),
  .req_valid(guard_req_valid),.req_ready(guard_req_ready),.req_write(guard_req_write),.req_addr(guard_req_addr),
  .req_size(guard_req_size),.req_wdata(guard_req_wdata),.rsp_valid(guard_rsp_valid),.rsp_ready(guard_rsp_ready),
  .rsp_rdata(guard_rsp_rdata),.rsp_fault(guard_rsp_fault),
  .mem_req_valid(mem_req_valid),.mem_req_ready(mem_req_ready),.mem_req_write(mem_req_write),.mem_req_addr(mem_req_addr),
  .mem_req_size(mem_req_size),.mem_req_wdata(mem_req_wdata),.mem_rsp_valid(mem_rsp_valid),.mem_rsp_ready(mem_rsp_ready),
  .mem_rsp_rdata(mem_rsp_rdata),.mem_rsp_fault(mem_rsp_fault),.idle(guard_idle));

 always_ff @(posedge clk) begin
  if(!rst_n) begin
   state<=IDLE;mem_return<=IDLE;model_id<=0;model_base<=0;image_bytes<=0;graph_ops<=0;plan_base<=0;plan_capacity<=0;
   workspace_base<=0;workspace_capacity<=0;opcode<=0;header_index<=0;body_offset<=0;record_word<=0;
   first_record<=0;record_count<=0;record_number<=0;mem_address<=0;mem_value<=0;header_crc<=0;body_crc<=0;
   cancelled<=0;cache_valid<=0;cached_model<=0;cached_image<=0;cached_plan<=0;cached_plan_capacity<=0;
   cached_workspace<=0;cached_workspace_capacity<=0;cached_generation<=0;cached_id<=0;
   rsp_task_id<=0;rsp_frame_id<=0;rsp_model_generation<=0;rsp_op_index<=0;rsp_fault<=0;plan_cache_hit<=0;
   header_reserved_bad<=0;record_reserved_bad<=0;crc_is_header<=0;crc_byte_index<=0;crc_data<=0;crc_work<=0;plan_features<=0;
  end else begin
   plan_cache_hit<=0;
   if(invalidate) cache_valid<=0;
   if(cancel_valid && state!=IDLE && state!=RESPONSE) cancelled<=1;
   case(state)
    IDLE: if(cmd_valid && cmd_ready) begin
     model_id<=cmd_model_id;model_base<=cmd_model_base;image_bytes<=cmd_image_bytes;graph_ops<=cmd_graph_ops;
     plan_base<=cmd_plan_base;plan_capacity<=cmd_plan_capacity;workspace_base<=cmd_workspace_base;workspace_capacity<=cmd_workspace_capacity;
     rsp_task_id<=cmd_task_id;rsp_frame_id<=cmd_frame_id;rsp_model_generation<=cmd_model_generation;rsp_op_index<=cmd_op_index;
     opcode<=cmd_op_record[31:0];rsp_fault<=0;cancelled<=0;record_number<=0;record_reserved_bad<=0;
     if(admission_hit) begin plan_cache_hit<=1;state<=CHECK_COMMAND;end
     else begin
      cache_valid<=0;header_index<=0;header_crc<=32'hffffffff;body_crc<=32'hffffffff;
      header_reserved_bad<=0;state<=CHECK_COMMAND;
     end
     // Preserve whether the checked header/LUT configuration belongs to this
     // generation. New keys do not become valid until all validation finishes.
     cached_model<=cmd_model_base;cached_image<=cmd_image_bytes;cached_plan<=cmd_plan_base;cached_plan_capacity<=cmd_plan_capacity;
     cached_workspace<=cmd_workspace_base;cached_workspace_capacity<=cmd_workspace_capacity;cached_generation<=cmd_model_generation;cached_id<=cmd_model_id;
    end
    CHECK_COMMAND: if(command_bad) fail(8'h01);
     else if(cancelled || cancel_valid) fail(8'he1);
     else if(cache_valid && h[7]!=graph_ops) fail(8'h02);
     else if(cache_valid) state<=INDEX_FIRST;
     else state<=HEADER_WORD;
    HEADER_WORD: read_word(plan_base+{24'd0,header_index,2'b00},HEADER_VALUE);
    HEADER_VALUE: begin
     if(header_index==32)begin
      plan_features<=mem_value;
      // Fail closed: production never skips CRC scans for an ordinary plan.
      if((mem_value&(PS_PREDECODED?32'hfffffff0:32'hfffffff8))!=0 || mem_value[1]!=PS_PREDECODED ||
         (model_id==1 && (mem_value[0] || mem_value[2])))header_reserved_bad<=1;
     end else if(header_index>32 && mem_value!=0) header_reserved_bad<=1;
     if(PS_PREDECODED)begin
      if(header_index==63)state<=HEADER_CHECK;
      else begin header_index<=header_index+1'b1;state<=HEADER_WORD;end
     end else begin
      crc_data<=header_index==17 ? 32'd0 : mem_value;crc_work<=header_crc;
      crc_byte_index<=0;crc_is_header<=1;state<=CRC_BYTE;
     end
    end
    HEADER_CHECK: if(header_bad) fail(8'h02);
     else if(PS_PREDECODED)state<=LUT_COMMAND;
     else begin body_offset<=256;body_crc<=32'hffffffff;state<=BODY_WORD;end
    BODY_WORD: if(body_offset==h[13]) begin
     if((body_crc^32'hffffffff)!=h[16]) fail(8'h03);else state<=MODEL_CRC;
    end else read_word(plan_base+body_offset,BODY_VALUE);
    BODY_VALUE: begin
     crc_data<=mem_value;crc_work<=body_crc;crc_byte_index<=0;crc_is_header<=0;state<=CRC_BYTE;
    end
    CRC_BYTE: begin
     crc_work<=crc_next;crc_data<=crc_data>>8;
     if(crc_byte_index!=3) crc_byte_index<=crc_byte_index+1'b1;
     else if(crc_is_header) begin
      header_crc<=crc_next;
      if(header_index==63) state<=HEADER_CHECK;
      else begin header_index<=header_index+1'b1;state<=HEADER_WORD;end
     end else begin body_crc<=crc_next;body_offset<=body_offset+4;state<=BODY_WORD;end
    end
    MODEL_CRC: read_word(model_base+64,MODEL_VALUE);
    MODEL_VALUE: if(mem_value!=h[14]) fail(8'h03);else state<=LUT_COMMAND;
    LUT_COMMAND: if(config_ready) state<=LUT_RESPONSE;
    LUT_RESPONSE: if(config_rsp_valid) begin
     if(config_fault!=0) fail({4'h3,config_fault});
     else if(cancelled || cancel_valid) fail(8'he1);
     else begin cache_valid<=1;state<=INDEX_FIRST;end
    end
    INDEX_FIRST: if(cancelled || cancel_valid) fail(8'he1);
     else read_word(plan_base+h[9]+(rsp_op_index<<3),INDEX_FIRST_VALUE);
    INDEX_FIRST_VALUE: begin first_record<=mem_value;state<=INDEX_COUNT;end
    INDEX_COUNT: begin
     // Prepare the record region while the existing index read is in flight.
     record_region_base<={9'd0,plan_base}+{9'd0,h[11]};
     read_word(plan_base+h[9]+(rsp_op_index<<3)+4,INDEX_COUNT_VALUE);
    end
    INDEX_COUNT_VALUE: if(({1'b0,first_record}+{1'b0,mem_value})>{1'b0,h[8]}) fail(8'h02);
     else if(mem_value==0)begin
      // Only the separately checksummed OPT1 compiler may absorb these
      // instructions. The producer committed the fused final tensor first.
      if(!(plan_features[0] || plan_features[2]) || model_id==1 || (opcode!=1 && opcode!=5 && opcode!=9))fail(8'h02);
      else if(cancelled || cancel_valid)fail(8'he1);
      else state<=RESPONSE;
     end else begin
      record_count<=mem_value;record_word<=0;record_reserved_bad<=0;
      record_address<=record_region_base+({9'd0,first_record}<<9);
      state<=RECORD_WORD;
     end
    RECORD_WORD: if(record_address>={8'd0,plan_end} || record_address[40:32]!=0)fail(8'h02);
     else read_word(record_address[31:0],RECORD_VALUE);
    RECORD_VALUE: begin
     // The final word also advances to the next record's first word.
     // Keep the full width so every word still receives the range/overflow check.
     record_address<=record_address+41'd4;
     if(((record_word>=56 && record_word<64) ||
         record_word>=(PS_PREDECODED ? 122 : 91)) && mem_value!=0)record_reserved_bad<=1;
     if(record_word==127) state<=RECORD_FLUSH;
     else begin record_word<=record_word+1'b1;state<=RECORD_WORD;end
    end
    RECORD_FLUSH: state<=RECORD_CHECK;
    RECORD_CHECK: if(cancelled || cancel_valid) fail(8'he1);
     else if(record_bad) fail(8'h02);else state<=DISPATCH;
    DISPATCH: if(dispatch_ready) state<=DISPATCH_WAIT;
    DISPATCH_WAIT: if(dispatch_rsp_valid) begin
     if(dispatch_tag!=rsp_op_index) fail(8'hf2);
     else if(dispatch_fault!=0) fail(dispatch_fault);
     else if(cancelled || cancel_valid) fail(8'he1);
     else if(record_number+1<record_count) begin
      record_number<=record_number+1'b1;record_word<=0;record_reserved_bad<=0;state<=RECORD_WORD;
     end
     else state<=RESPONSE;
    end
    MEM_REQUEST: if(c_req_ready[0]) state<=MEM_WAIT;
    MEM_WAIT: if(c_rsp_valid[0]) begin
     if(c_rsp_fault[3:0]!=0) fail({4'h2,c_rsp_fault[3:0]});
     else if(cancelled || cancel_valid) fail(8'he1);
     else begin mem_value<=c_rsp_rdata[31:0];state<=mem_return;end
    end
    RESPONSE: if(rsp_ready) state<=IDLE;
    default: fail(8'h01);
   endcase
  end
 end
endmodule
