`timescale 1ns/1ps
// Connected numerical backend for one resolved NPUPLN1 record, including its
// affine outer iterations. Scalar clients share the caller's DDR port.
// One external packed PE client; no second array is instantiated. Scalar
// math clients, including max pooling geometry, share one wide unit.
module npu_plan_dispatch #(
 parameter bit BORROW_RECORD = 1'b0,parameter bit STREAMING=1'b1,
 parameter bit PS_PREDECODED=1'b0,
 parameter bit ENABLE_INPUT_STRIPE=1'b1,
 parameter bit ENABLE_WEIGHT_RESIDENCY=1'b1,
 parameter bit ENABLE_MAXPOOL_FASTPATH=1'b1,
 parameter bit ENABLE_RESIZE_BATCH=1'b1,
 parameter bit ENABLE_PE_SPATIAL4=1'b1,
 parameter bit ENABLE_RESIZE_BURST=1'b1,
 parameter bit ENABLE_MAXPOOL_BULK=1'b1,
 parameter bit ENABLE_AFFINE_COALESCE=1'b1,
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
 input logic [31:0] cmd_tag,input logic [4095:0] cmd_record,
 input logic [31:0] cmd_constants_base,cmd_constants_bytes,cmd_workspace_base,cmd_workspace_bytes,
 input logic cancel_valid,output logic cancel_ready,
 input logic config_valid,output logic config_ready,
 input logic [31:0] sigmoid_base,sigmoid_entries,exp_base,exp_entries,
 input logic [2:0] sigmoid_dtype,exp_dtype,
 output logic config_rsp_valid,input logic config_rsp_ready,output logic [3:0] config_rsp_fault,
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
 output wire [84:0] stall_events,
 output wire [31:0] stall_input_bytes,stall_weight_bytes,
 output wire [4:0] stall_window_count,
 output wire [4:0] perf_conv_events,
 output logic [1:0] packed_req_weight_group
);
 wire [84:0] stall_conv_local;wire [3:0] stall_dispatch_owner;
 wire pool_rd_cmd_valid,pool_rd_cmd_ready,pool_rd_valid,pool_rd_ready,pool_rd_rsp_valid,pool_rd_rsp_ready;
 wire pool_wr_cmd_valid,pool_wr_cmd_ready,pool_wr_valid,pool_wr_ready,pool_wr_last,pool_wr_rsp_valid,pool_wr_rsp_ready;
 wire [31:0] pool_rd_cmd_addr,pool_rd_cmd_bytes,pool_wr_cmd_addr,pool_wr_cmd_bytes;
 wire [63:0] pool_wr_data;wire [7:0] pool_wr_keep;
 wire conv_rd_cmd_valid,conv_rd_cmd_ready,conv_rd_valid,conv_rd_ready,conv_rd_last,conv_rd_rsp_valid,conv_rd_rsp_ready,conv_wr_cmd_valid,conv_wr_cmd_ready,conv_wr_valid,conv_wr_ready,conv_wr_last,conv_wr_rsp_valid,conv_wr_rsp_ready;
 wire [31:0] conv_rd_cmd_addr,conv_rd_cmd_bytes,conv_wr_cmd_addr,conv_wr_cmd_bytes;
 wire [63:0] conv_rd_data,conv_wr_data;
 wire [7:0] conv_rd_keep,conv_wr_keep;
 wire [3:0] conv_rd_fault,conv_wr_fault;
 wire copy_rd_cmd_valid,copy_rd_cmd_ready,copy_rd_valid,copy_rd_ready,copy_rd_last,copy_rd_rsp_valid,copy_rd_rsp_ready,copy_wr_cmd_valid,copy_wr_cmd_ready,copy_wr_valid,copy_wr_ready,copy_wr_last,copy_wr_rsp_valid,copy_wr_rsp_ready;
 wire [31:0] copy_rd_cmd_addr,copy_rd_cmd_bytes,copy_wr_cmd_addr,copy_wr_cmd_bytes;
 wire [63:0] copy_rd_data,copy_wr_data;
 wire [7:0] copy_rd_keep,copy_wr_keep;
 wire [3:0] copy_rd_fault,copy_wr_fault;
 wire scalar_rd_cmd_valid,scalar_rd_cmd_ready,scalar_rd_valid,scalar_rd_ready,scalar_rd_last,scalar_rd_rsp_valid,scalar_rd_rsp_ready;
 wire scalar_wr_cmd_valid,scalar_wr_cmd_ready,scalar_wr_valid,scalar_wr_ready,scalar_wr_last,scalar_wr_rsp_valid,scalar_wr_rsp_ready;
 wire [31:0] scalar_rd_cmd_addr,scalar_rd_cmd_bytes,scalar_wr_cmd_addr,scalar_wr_cmd_bytes;
 wire [63:0] scalar_wr_data;wire [7:0] scalar_wr_keep;
 wire stream_lut_available,stream_lut_req_valid,stream_lut_req_ready,stream_lut_rsp_valid,stream_lut_rsp_ready;
 wire [1:0] stream_lut_kind;wire [12:0] stream_lut_index;
 wire signed [63:0] stream_lut_y0,stream_lut_y1;wire [3:0] stream_lut_fault;
 wire [63:0] stream_read_data;wire [7:0] stream_read_keep;wire stream_read_last;
 wire [3:0] stream_read_fault,stream_write_fault;wire stream_reads_idle,stream_writes_idle;
 assign conv_rd_data=stream_read_data;assign copy_rd_data=stream_read_data;
 assign conv_rd_keep=stream_read_keep;assign copy_rd_keep=stream_read_keep;
 assign conv_rd_last=stream_read_last;assign copy_rd_last=stream_read_last;
 assign conv_rd_fault=stream_read_fault;assign copy_rd_fault=stream_read_fault;
 assign conv_wr_fault=stream_write_fault;assign copy_wr_fault=stream_write_fault;
 npu_stream_read_fabric #(.CLIENTS(4),.ENABLE_STALL_DIAG(ENABLE_STALL_DIAG)) u_stream_reads (
 .stall_other_owner(stall_dispatch_owner),
 .clk(clk),.rst_n(rst_n),.c_cmd_valid({pool_rd_cmd_valid,scalar_rd_cmd_valid,copy_rd_cmd_valid,conv_rd_cmd_valid}),.c_cmd_ready({pool_rd_cmd_ready,scalar_rd_cmd_ready,copy_rd_cmd_ready,conv_rd_cmd_ready}),
 .c_cmd_addr({pool_rd_cmd_addr,scalar_rd_cmd_addr,copy_rd_cmd_addr,conv_rd_cmd_addr}),.c_cmd_bytes({pool_rd_cmd_bytes,scalar_rd_cmd_bytes,copy_rd_cmd_bytes,conv_rd_cmd_bytes}),
 .c_valid({pool_rd_valid,scalar_rd_valid,copy_rd_valid,conv_rd_valid}),.c_ready({pool_rd_ready,scalar_rd_ready,copy_rd_ready,conv_rd_ready}),
 .c_data(stream_read_data),.c_keep(stream_read_keep),.c_last(stream_read_last),
 .c_rsp_valid({pool_rd_rsp_valid,scalar_rd_rsp_valid,copy_rd_rsp_valid,conv_rd_rsp_valid}),.c_rsp_ready({pool_rd_rsp_ready,scalar_rd_rsp_ready,copy_rd_rsp_ready,conv_rd_rsp_ready}),.c_fault(stream_read_fault),
 .cmd_valid(rd_cmd_valid),.cmd_ready(rd_cmd_ready),.cmd_addr(rd_cmd_addr),.cmd_bytes(rd_cmd_bytes),
 .valid(rd_valid),.ready(rd_ready),.data(rd_data),.keep(rd_keep),.last(rd_last),
 .rsp_valid(rd_rsp_valid),.rsp_ready(rd_rsp_ready),.fault(rd_fault),.idle(stream_reads_idle));
 npu_stream_write_fabric #(.CLIENTS(4)) u_stream_writes (
 .clk(clk),.rst_n(rst_n),.c_cmd_valid({pool_wr_cmd_valid,scalar_wr_cmd_valid,copy_wr_cmd_valid,conv_wr_cmd_valid}),.c_cmd_ready({pool_wr_cmd_ready,scalar_wr_cmd_ready,copy_wr_cmd_ready,conv_wr_cmd_ready}),
 .c_cmd_addr({pool_wr_cmd_addr,scalar_wr_cmd_addr,copy_wr_cmd_addr,conv_wr_cmd_addr}),.c_cmd_bytes({pool_wr_cmd_bytes,scalar_wr_cmd_bytes,copy_wr_cmd_bytes,conv_wr_cmd_bytes}),
 .c_valid({pool_wr_valid,scalar_wr_valid,copy_wr_valid,conv_wr_valid}),.c_ready({pool_wr_ready,scalar_wr_ready,copy_wr_ready,conv_wr_ready}),
 .c_data({pool_wr_data,scalar_wr_data,copy_wr_data,conv_wr_data}),.c_keep({pool_wr_keep,scalar_wr_keep,copy_wr_keep,conv_wr_keep}),.c_last({pool_wr_last,scalar_wr_last,copy_wr_last,conv_wr_last}),
 .c_rsp_valid({pool_wr_rsp_valid,scalar_wr_rsp_valid,copy_wr_rsp_valid,conv_wr_rsp_valid}),.c_rsp_ready({pool_wr_rsp_ready,scalar_wr_rsp_ready,copy_wr_rsp_ready,conv_wr_rsp_ready}),.c_fault(stream_write_fault),
 .cmd_valid(wr_cmd_valid),.cmd_ready(wr_cmd_ready),.cmd_addr(wr_cmd_addr),.cmd_bytes(wr_cmd_bytes),
 .valid(wr_valid),.ready(wr_ready),.data(wr_data),.keep(wr_keep),.last(wr_last),
 .rsp_valid(wr_rsp_valid),.rsp_ready(wr_rsp_ready),.fault(wr_fault),.idle(stream_writes_idle));
 logic iterator_ready,iterator_busy,inner_valid,inner_ready,inner_rsp_valid,inner_rsp_ready;
 logic [4095:0] inner_record;
 wire inner_copy_repeat2,inner_copy_transpose2;
 wire [31:0] copy_completed;
 logic [7:0] inner_rsp_fault;
 logic [31:0] tag;
 logic [2:0] active_engine;
 logic active,memory_idle,quiet,admission_idle;
 logic fusion_active;
 logic [5:0] e_cmd_valid,e_cmd_ready,e_rsp_valid,e_rsp_ready,e_busy;
 logic [191:0] e_rsp_tag;
 logic [47:0] e_rsp_fault;
 logic [6:0] c_req_valid,c_req_ready,c_req_write,c_rsp_valid,c_rsp_ready;
 logic [223:0] c_req_addr;logic [13:0] c_req_size;
 logic [447:0] c_req_wdata,c_rsp_rdata;logic [27:0] c_rsp_fault;
 logic lut_valid,lut_ready,lut_reply_valid,lut_reply_ready;
 logic [1:0] lut_kind;logic [12:0] lut_index;
 logic signed [63:0] lut_y0,lut_y1;logic [3:0] lut_fault;
 logic reader_req_valid,reader_req_ready,reader_rsp_valid,reader_rsp_ready;
 logic [1:0] reader_kind;logic [12:0] reader_index;
 logic signed [63:0] reader_y0,reader_y1;logic [3:0] reader_fault;
 logic reader_config_ready;
 logic [6:0] m_req_valid,m_req_ready,m_rsp_valid,m_rsp_ready;
 logic [20:0] m_req_op;logic [447:0] m_req_a,m_req_b;logic [48:0] m_req_shift;
 logic signed [63:0] m_result;logic [1:0] m_fault;
 logic math_idle,math_req_valid,math_req_ready,math_rsp_valid,math_rsp_ready;
 logic [2:0] math_req_op;logic [6:0] math_req_shift;
 logic signed [63:0] math_req_a,math_req_b,math_result;logic [1:0] math_fault;
 // Conv, residual and GAP are mutually exclusive clients of one exact
 // signed40/72/73 -> INT8 quantizer. No legacy controller/cache is needed.
 logic [2:0] q_req_valid,q_req_ready,q_req_residual,q_rsp_valid,q_rsp_ready;
 logic [119:0] q_req_value;
 logic [191:0] q_req_ma,q_req_mb;
 logic [23:0] q_req_b,q_req_shift;
 logic q_valid,q_ready,q_residual,q_result_valid,q_result_ready;
 logic signed [39:0] q_value;
 logic signed [63:0] q_ma,q_mb;
 logic signed [7:0] q_b,q_shift,q_result;
 logic [1:0] q_selected,q_owner;
 wire conv_quant_valid,conv_quant_ready,conv_quant_rsp_valid,conv_quant_overflow,shared_quant_busy;
 wire signed [39:0] conv_quant_value;
 wire signed [63:0] conv_quant_multiplier;
 wire signed [7:0] conv_quant_shift,conv_quant_result8;
 wire signed [31:0] conv_quant_result32;
 wire [18:0] conv_quant_tag,conv_quant_rsp_tag;
 wire quant_idle=q_ready&&!q_result_valid&&!shared_quant_busy;
 always_comb begin
  q_valid=0;q_residual=0;q_value=0;q_ma=0;q_mb=0;q_b=0;q_shift=0;q_selected=0;
  q_req_ready=0;q_rsp_valid=0;
  // Fixed slices avoid a dynamic shift of the concatenated wide payloads.
  if(active)case(active_engine)
   0:begin
    q_selected=0;q_valid=q_req_valid[0];q_residual=q_req_residual[0];q_value=q_req_value[0+:40];
    q_ma=q_req_ma[0+:64];q_mb=q_req_mb[0+:64];q_b=q_req_b[0+:8];q_shift=q_req_shift[0+:8];q_req_ready[0]=q_ready;
   end
   1:begin
    q_selected=1;q_valid=q_req_valid[1];q_residual=q_req_residual[1];q_value=q_req_value[40+:40];
    q_ma=q_req_ma[64+:64];q_mb=q_req_mb[64+:64];q_b=q_req_b[8+:8];q_shift=q_req_shift[8+:8];q_req_ready[1]=q_ready;
   end
   4:begin
    q_selected=2;q_valid=q_req_valid[2];q_residual=q_req_residual[2];q_value=q_req_value[80+:40];
    q_ma=q_req_ma[128+:64];q_mb=q_req_mb[128+:64];q_b=q_req_b[16+:8];q_shift=q_req_shift[16+:8];q_req_ready[2]=q_ready;
   end
   default:;
  endcase
  q_result_ready=0;
  for(integer n=0;n<3;n=n+1)if(q_owner==2'(n))begin
   q_rsp_valid[n]=q_result_valid;q_result_ready=q_rsp_ready[n];
  end
 end
 always_ff @(posedge clk)begin
  if(!rst_n)q_owner<=0;
  else if(q_valid&&q_ready)q_owner<=q_selected;
 end
 // The current engine owns this pipe through all tagged Conv results or its
 // scalar response. Conv retains one accepted lane every clock.
 npu_resnet_quant #(.SHARED_CONV(STREAMING)) u_resnet_quant(
  .clk(clk),.rst_n(rst_n),.req_valid(q_valid),.req_ready(q_ready),.req_residual(q_residual),
  .req_value(q_value),.req_multiplier_a(q_ma),.req_multiplier_b(q_mb),.req_b(q_b),.req_shift(q_shift),
  .rsp_valid(q_result_valid),.rsp_ready(q_result_ready),.rsp_result(q_result),
  .conv_valid(conv_quant_valid),.conv_ready(conv_quant_ready),.conv_value(conv_quant_value),
  .conv_multiplier(conv_quant_multiplier),.conv_shift(conv_quant_shift),.conv_tag(conv_quant_tag),
  .conv_rsp_valid(conv_quant_rsp_valid),.conv_result8(conv_quant_result8),.conv_result32(conv_quant_result32),
  .conv_overflow32(conv_quant_overflow),.conv_rsp_tag(conv_quant_rsp_tag),.pipe_busy(shared_quant_busy));
 // synthesis translate_off
 always @(posedge clk)if(rst_n&&conv_quant_valid&&!conv_quant_ready)
  $fatal(1,"Conv lost exclusive ownership of the shared requant pipeline");
 // synthesis translate_on
 always_comb begin
  // The reader is not idle while a configuration is being checked/committed,
  // including cycles before config_rsp_valid. Keep new jobs blocked until
  // the complete configuration response retires.
  quiet=stream_reads_idle && stream_writes_idle && !iterator_busy && !(|e_busy) && memory_idle && math_idle && quant_idle && reader_config_ready;
  cmd_ready=rst_n && iterator_ready && admission_idle && !config_valid;
  config_ready=rst_n && admission_idle && reader_config_ready;
  busy=!admission_idle;
  e_cmd_valid=0;e_rsp_ready=0;inner_ready=0;inner_rsp_valid=0;inner_rsp_fault=0;
  case(inner_record[0+:3])
   3'd1: begin e_cmd_valid[0]=inner_valid; inner_ready=e_cmd_ready[0]; end
   3'd2: begin e_cmd_valid[1]=inner_valid; inner_ready=e_cmd_ready[1]; end
   3'd3: begin e_cmd_valid[2]=inner_valid; inner_ready=e_cmd_ready[2]; end
   3'd4: begin e_cmd_valid[3]=inner_valid; inner_ready=e_cmd_ready[3]; end
   3'd5: begin e_cmd_valid[4]=inner_valid; inner_ready=e_cmd_ready[4]; end
   3'd6: begin e_cmd_valid[5]=inner_valid; inner_ready=e_cmd_ready[5]; end
   default: begin end
  endcase
  for(integer n=0;n<6;n=n+1) begin
   if(active && active_engine==3'(n)) begin
    inner_rsp_valid=e_rsp_valid[n];
    inner_rsp_fault=e_rsp_tag[n*32+:32]==tag ? e_rsp_fault[n*8+:8] : 8'hf2;
    e_rsp_ready[n]=inner_rsp_ready;
   end
  end
  lut_ready=0;lut_reply_valid=0;lut_y0=reader_y0;lut_y1=reader_y1;lut_fault=reader_fault;
  reader_req_valid=0;reader_kind=0;reader_index=0;reader_rsp_ready=0;
  // Only the scalar engine uses the sigmoid/exp tables.
  if(active && active_engine==0) begin
   reader_req_valid=lut_valid;lut_ready=reader_req_ready;
   reader_kind=lut_kind;reader_index=lut_index;
   lut_reply_valid=reader_rsp_valid;reader_rsp_ready=lut_reply_ready;
  end
 end
 // Neither engines nor the LUT reader can start work without one of these
 // handshakes. Clear before starting it, and rearm only after complete drain.
 // Configuration and record commands share the token; configuration wins.
 always_ff @(posedge clk)begin
  if(!rst_n)admission_idle<=0;
  else if((cmd_valid && cmd_ready)||(config_valid && config_ready))admission_idle<=0;
  else if(!admission_idle && quiet)admission_idle<=1;
 end
 always_ff @(posedge clk) begin
  if(!rst_n) begin tag<=0;active<=0;active_engine<=0;rsp_tag<=0;fusion_active<=0;end
  else begin
   if(cmd_valid && cmd_ready) begin tag<=cmd_tag;rsp_tag<=cmd_tag;end
   if(inner_valid && inner_ready) begin
    active<=1;active_engine<=inner_record[0+:3]-3'd1;
    // Command selection stays fixed through every accepted pipeline result.
    fusion_active<=STREAMING && inner_record[0+:3]==3'd5 &&
        (inner_record[2*32+3] || inner_record[2*32+4]);
   end
   if(inner_rsp_valid && inner_rsp_ready) active<=0;
  end
 end
 generate if(PS_PREDECODED)begin:g_ps_predecoded_iterator
 npu_predecoded_iterator #(.REUSE_AXIS_SCAN(1),.BORROW_RECORD(BORROW_RECORD),.ENABLE_RESIZE_BATCH(ENABLE_RESIZE_BATCH && STREAMING),
  .ENABLE_AFFINE_COALESCE(ENABLE_AFFINE_COALESCE && STREAMING)) u_iterator (.clk(clk),.rst_n(rst_n),
  .cmd_valid(cmd_valid && admission_idle && !config_valid),.cmd_ready(iterator_ready),.cmd_record(cmd_record),
  .cmd_constants_base(cmd_constants_base),.cmd_constants_bytes(cmd_constants_bytes),
  .cmd_workspace_base(cmd_workspace_base),.cmd_workspace_bytes(cmd_workspace_bytes),
  .cancel_valid(cancel_valid),.cancel_ready(cancel_ready),
  .inner_valid(inner_valid),.inner_ready(inner_ready),.inner_record(inner_record),
  .inner_copy_repeat2(inner_copy_repeat2),.inner_copy_completed(e_rsp_tag[127:96]==tag ? copy_completed : 32'd0),
  .inner_copy_transpose2(inner_copy_transpose2),
  .inner_rsp_valid(inner_rsp_valid),.inner_rsp_ready(inner_rsp_ready),.inner_rsp_fault(inner_rsp_fault),
  .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_fault(rsp_fault),.rsp_completed(rsp_completed),.busy(iterator_busy));
 assign m_req_valid[0]=1'b0;assign m_req_op[0+:3]=3'd0;
 assign m_req_a[0+:64]=64'd0;assign m_req_b[0+:64]=64'd0;
 assign m_req_shift[0+:7]=7'd0;assign m_rsp_ready[0]=1'b1;
 end else begin:g_legacy_iterator
 assign inner_copy_repeat2=1'b0;
 assign inner_copy_transpose2=1'b0;
 npu_plan_iterator #(.EXTERNAL_MATH(1'b1),.BORROW_RECORD(BORROW_RECORD)) u_iterator (.clk(clk),.rst_n(rst_n),
  .cmd_valid(cmd_valid && admission_idle && !config_valid),.cmd_ready(iterator_ready),.cmd_record(cmd_record),
  .cmd_constants_base(cmd_constants_base),.cmd_constants_bytes(cmd_constants_bytes),
  .cmd_workspace_base(cmd_workspace_base),.cmd_workspace_bytes(cmd_workspace_bytes),
  .cancel_valid(cancel_valid),.cancel_ready(cancel_ready),
  .inner_valid(inner_valid),.inner_ready(inner_ready),.inner_record(inner_record),
  .inner_rsp_valid(inner_rsp_valid),.inner_rsp_ready(inner_rsp_ready),.inner_rsp_fault(inner_rsp_fault),
  .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_fault(rsp_fault),.rsp_completed(rsp_completed),.busy(iterator_busy),
  .math_req_valid(m_req_valid[0]),.math_req_ready(m_req_ready[0]),.math_req_op(m_req_op[0+:3]),
  .math_req_a(m_req_a[0+:64]),.math_req_b(m_req_b[0+:64]),.math_req_shift(m_req_shift[0+:7]),
  .math_rsp_valid(m_rsp_valid[0]),.math_rsp_ready(m_rsp_ready[0]),.math_rsp_result(m_result),.math_rsp_fault(m_fault));
 end endgenerate
 wire fusion_valid,fusion_ready,fusion_rsp_valid;
 wire [31:0] fusion_data,fusion_result;
 wire [9:0] fusion_tag,fusion_rsp_tag;
 wire [7:0] fusion_fault;
 npu_q16_scalar_engine #(.BITWISE_RESULT_RANGE(1'b1),.EXTERNAL_MATH(1'b1),.EXTERNAL_RESNET_QUANT(1'b1),.STREAMING(STREAMING),.EXTERNAL_FUSION(STREAMING)) u_element (
  .fusion_active(fusion_active),.fusion_valid(fusion_valid),.fusion_ready(fusion_ready),
  .fusion_op(inner_record[2*32+4] ? (inner_record[2*32+3] ? 5'd23 : 5'd22) : 5'd1),
  .fusion_dtype(inner_record[21*32+:3]),.fusion_multiplier($signed({32'd0,inner_record[18*32+:32]})),
  .fusion_shift(inner_record[19*32+:7]),.fusion_data(fusion_data),.fusion_tag(fusion_tag),
  .fusion_rsp_valid(fusion_rsp_valid),.fusion_result(fusion_result),.fusion_rsp_tag(fusion_rsp_tag),.fusion_fault(fusion_fault),
  .rd_cmd_valid(scalar_rd_cmd_valid),.rd_cmd_ready(scalar_rd_cmd_ready),.rd_cmd_addr(scalar_rd_cmd_addr),.rd_cmd_bytes(scalar_rd_cmd_bytes),
  .rd_valid(scalar_rd_valid),.rd_ready(scalar_rd_ready),.rd_data(stream_read_data),.rd_keep(stream_read_keep),.rd_last(stream_read_last),
  .rd_rsp_valid(scalar_rd_rsp_valid),.rd_rsp_ready(scalar_rd_rsp_ready),.rd_fault(stream_read_fault),
  .wr_cmd_valid(scalar_wr_cmd_valid),.wr_cmd_ready(scalar_wr_cmd_ready),.wr_cmd_addr(scalar_wr_cmd_addr),.wr_cmd_bytes(scalar_wr_cmd_bytes),
  .wr_valid(scalar_wr_valid),.wr_ready(scalar_wr_ready),.wr_data(scalar_wr_data),.wr_keep(scalar_wr_keep),.wr_last(scalar_wr_last),
  .wr_rsp_valid(scalar_wr_rsp_valid),.wr_rsp_ready(scalar_wr_rsp_ready),.wr_fault(stream_write_fault),
  .stream_lut_available(stream_lut_available),.stream_lut_req_valid(stream_lut_req_valid),.stream_lut_req_ready(stream_lut_req_ready),
  .stream_lut_req_kind(stream_lut_kind),.stream_lut_req_index(stream_lut_index),.stream_lut_rsp_valid(stream_lut_rsp_valid),.stream_lut_rsp_ready(stream_lut_rsp_ready),
  .stream_lut_y0(stream_lut_y0),.stream_lut_y1(stream_lut_y1),.stream_lut_fault(stream_lut_fault),
  .clk(clk),.rst_n(rst_n),.cmd_valid(e_cmd_valid[0]),.cmd_ready(e_cmd_ready[0]),.cmd_tag(tag),
  .cmd_op(inner_record[2*32+1] ? (inner_record[2*32+2] ? 5'd23 : 5'd22) : inner_record[3*32+:5]),.cmd_count(inner_record[64*32+:32]),.cmd_input_a(inner_record[8*32+:32]),.cmd_input_b(inner_record[9*32+:32]),.cmd_output_base(inner_record[10*32+:32]),
  .cmd_stride_a(inner_record[65*32+:32]),.cmd_stride_b(inner_record[66*32+:32]),.cmd_stride_output(inner_record[67*32+:32]),
  .cmd_dtype_a(inner_record[4*32+:3]),.cmd_dtype_b(inner_record[5*32+:3]),.cmd_dtype_output(inner_record[6*32+:3]),
  .cmd_multiplier($signed({inner_record[18*32+:32],inner_record[17*32+:32]})),.cmd_shift(inner_record[19*32+:7]),
  .cmd_resnet_legacy(inner_record[2*32]),
  .cmd_multiplier_b($signed({inner_record[22*32+:32],inner_record[21*32+:32]})),
  .cmd_resnet_shift(inner_record[19*32+:8]),
  .mem_req_valid(c_req_valid[0]),.mem_req_ready(c_req_ready[0]),.mem_req_write(c_req_write[0]),
  .mem_req_addr(c_req_addr[31:0]),.mem_req_size(c_req_size[1:0]),.mem_req_wdata(c_req_wdata[63:0]),
  .mem_rsp_valid(c_rsp_valid[0]),.mem_rsp_ready(c_rsp_ready[0]),.mem_rsp_rdata(c_rsp_rdata[63:0]),.mem_rsp_fault(c_rsp_fault[3:0]),
  .lut_req_valid(lut_valid),.lut_req_ready(lut_ready),.lut_req_kind(lut_kind),.lut_req_index(lut_index),
  .lut_rsp_valid(lut_reply_valid),.lut_rsp_ready(lut_reply_ready),.lut_rsp_y0(lut_y0),.lut_rsp_y1(lut_y1),.lut_rsp_fault(lut_fault),
  .rsp_valid(e_rsp_valid[0]),.rsp_ready(e_rsp_ready[0]),.rsp_tag(e_rsp_tag[31:0]),.rsp_fault(e_rsp_fault[7:0]),.rsp_completed(),.busy(e_busy[0]),
  .math_req_valid(m_req_valid[1]),.math_req_ready(m_req_ready[1]),.math_req_op(m_req_op[3+:3]),
  .math_req_a(m_req_a[64+:64]),.math_req_b(m_req_b[64+:64]),.math_req_shift(m_req_shift[7+:7]),
  .math_rsp_valid(m_rsp_valid[1]),.math_rsp_ready(m_rsp_ready[1]),.math_rsp_result(m_result),.math_rsp_fault(m_fault),
  .quant_req_valid(q_req_valid[0]),.quant_req_ready(q_req_ready[0]),.quant_req_residual(q_req_residual[0]),
  .quant_req_value(q_req_value[0+:40]),.quant_req_multiplier_a(q_req_ma[0+:64]),.quant_req_multiplier_b(q_req_mb[0+:64]),
  .quant_req_b(q_req_b[0+:8]),.quant_req_shift(q_req_shift[0+:8]),
  .quant_rsp_valid(q_rsp_valid[0]),.quant_rsp_ready(q_rsp_ready[0]),.quant_rsp_result(q_result));
 npu_resnet_gap_engine u_reduce (
  .clk(clk),.rst_n(rst_n),.cmd_valid(e_cmd_valid[1]),.cmd_ready(e_cmd_ready[1]),.cmd_tag(tag),
  .cmd_op(inner_record[3*32+:5]),.cmd_input_base(inner_record[8*32+:32]),.cmd_output_base(inner_record[10*32+:32]),
  .cmd_element_count(inner_record[64*32+:32]),.cmd_input_stride(inner_record[65*32+:32]),
  .cmd_input_dtype(inner_record[4*32+:3]),.cmd_output_dtype(inner_record[6*32+:3]),
  .cmd_resnet_legacy(inner_record[2*32]),.cmd_resnet_multiplier(inner_record[17*32+:32]),.cmd_resnet_shift(inner_record[19*32+:8]),
  .mem_req_valid(c_req_valid[1]),.mem_req_ready(c_req_ready[1]),.mem_req_write(c_req_write[1]),
  .mem_req_addr(c_req_addr[63:32]),.mem_req_size(c_req_size[3:2]),.mem_req_wdata(c_req_wdata[127:64]),
  .mem_rsp_valid(c_rsp_valid[1]),.mem_rsp_ready(c_rsp_ready[1]),.mem_rsp_rdata(c_rsp_rdata[127:64]),.mem_rsp_fault(c_rsp_fault[7:4]),
  .rsp_valid(e_rsp_valid[1]),.rsp_ready(e_rsp_ready[1]),.rsp_tag(e_rsp_tag[63:32]),.rsp_fault(e_rsp_fault[15:8]),.busy(e_busy[1]),
  .math_req_valid(m_req_valid[2]),.math_req_ready(m_req_ready[2]),.math_req_op(m_req_op[6+:3]),
  .math_req_a(m_req_a[128+:64]),.math_req_b(m_req_b[128+:64]),.math_req_shift(m_req_shift[14+:7]),
  .math_rsp_valid(m_rsp_valid[2]),.math_rsp_ready(m_rsp_ready[2]),.math_rsp_result(m_result),.math_rsp_fault(m_fault),
  .quant_req_valid(q_req_valid[1]),.quant_req_ready(q_req_ready[1]),.quant_req_residual(q_req_residual[1]),
  .quant_req_value(q_req_value[40+:40]),.quant_req_multiplier_a(q_req_ma[64+:64]),.quant_req_multiplier_b(q_req_mb[64+:64]),
  .quant_req_b(q_req_b[8+:8]),.quant_req_shift(q_req_shift[8+:8]),
  .quant_rsp_valid(q_rsp_valid[1]),.quant_rsp_ready(q_rsp_ready[1]),.quant_rsp_result(q_result));
 // Reserved engine ID 3 terminates with an error; it owns no compute path.
 generate begin:g_unsupported_engine
 logic pending;
 assign e_cmd_ready[2]=rst_n && !pending;
 assign e_rsp_valid[2]=rst_n && pending;assign e_busy[2]=pending;
 assign e_rsp_tag[95:64]=tag;assign e_rsp_fault[23:16]=8'h01;
 assign c_req_valid[2]=1'b0;assign c_req_write[2]=1'b0;
 assign c_req_addr[95:64]=32'd0;assign c_req_size[5:4]=2'd0;assign c_req_wdata[191:128]=64'd0;
 assign c_rsp_ready[2]=1'b1;
 assign m_req_valid[3]=1'b0;assign m_req_op[9+:3]=3'd0;
 assign m_req_a[192+:64]=64'd0;assign m_req_b[192+:64]=64'd0;assign m_req_shift[21+:7]=7'd0;
 assign m_rsp_ready[3]=1'b1;
 always_ff @(posedge clk)begin
  if(!rst_n)pending<=1'b0;
  else if(pending && e_rsp_ready[2])pending<=1'b0;
  else if(e_cmd_valid[2] && e_cmd_ready[2])pending<=1'b1;
 end
 end endgenerate
 generate if(STREAMING)begin:g_stream_copy
 npu_copy_stream_engine #(.EXTERNAL_MATH(1'b1),.ENABLE_RESIZE_BATCH(ENABLE_RESIZE_BATCH),.ENABLE_RESIZE_BURST(ENABLE_RESIZE_BURST),
  .ENABLE_AFFINE_COALESCE(ENABLE_AFFINE_COALESCE)) u_copy (
  .rd_cmd_valid(copy_rd_cmd_valid),
  .rd_cmd_ready(copy_rd_cmd_ready),
  .rd_cmd_addr(copy_rd_cmd_addr),
  .rd_cmd_bytes(copy_rd_cmd_bytes),
  .rd_valid(copy_rd_valid),
  .rd_ready(copy_rd_ready),
  .rd_data(copy_rd_data),
  .rd_keep(copy_rd_keep),
  .rd_last(copy_rd_last),
  .rd_rsp_valid(copy_rd_rsp_valid),
  .rd_rsp_ready(copy_rd_rsp_ready),
  .rd_fault(copy_rd_fault),
  .wr_cmd_valid(copy_wr_cmd_valid),
  .wr_cmd_ready(copy_wr_cmd_ready),
  .wr_cmd_addr(copy_wr_cmd_addr),
  .wr_cmd_bytes(copy_wr_cmd_bytes),
  .wr_valid(copy_wr_valid),
  .wr_ready(copy_wr_ready),
  .wr_data(copy_wr_data),
  .wr_keep(copy_wr_keep),
  .wr_last(copy_wr_last),
  .wr_rsp_valid(copy_wr_rsp_valid),
  .wr_rsp_ready(copy_wr_rsp_ready),
  .wr_fault(copy_wr_fault),
  .clk(clk),.rst_n(rst_n),.cmd_valid(e_cmd_valid[3]),.cmd_ready(e_cmd_ready[3]),.cmd_tag(tag),
  .cmd_input_base(inner_record[8*32+:32]),.cmd_output_base(inner_record[10*32+:32]),.cmd_count(inner_record[64*32+:32]),.cmd_input_stride(inner_record[65*32+:32]),.cmd_output_stride(inner_record[67*32+:32]),
  .cmd_input_dtype(inner_record[4*32+:3]),.cmd_output_dtype(inner_record[6*32+:3]),
  .cmd_repeat2(inner_copy_repeat2),.cancel_valid(cancel_valid),
  .cmd_transpose2(inner_copy_transpose2),
  .mem_req_valid(c_req_valid[3]),.mem_req_ready(c_req_ready[3]),.mem_req_write(c_req_write[3]),
  .mem_req_addr(c_req_addr[127:96]),.mem_req_size(c_req_size[7:6]),.mem_req_wdata(c_req_wdata[255:192]),
  .mem_rsp_valid(c_rsp_valid[3]),.mem_rsp_ready(c_rsp_ready[3]),.mem_rsp_rdata(c_rsp_rdata[255:192]),.mem_rsp_fault(c_rsp_fault[15:12]),
  .rsp_valid(e_rsp_valid[3]),.rsp_ready(e_rsp_ready[3]),.rsp_tag(e_rsp_tag[127:96]),.rsp_fault(e_rsp_fault[31:24]),.rsp_completed(copy_completed),.busy(e_busy[3]),
  .math_req_valid(m_req_valid[4]),.math_req_ready(m_req_ready[4]),.math_req_op(m_req_op[12+:3]),
  .math_req_a(m_req_a[256+:64]),.math_req_b(m_req_b[256+:64]),.math_req_shift(m_req_shift[28+:7]),
  .math_rsp_valid(m_rsp_valid[4]),.math_rsp_ready(m_rsp_ready[4]),.math_rsp_result(m_result),.math_rsp_fault(m_fault));
 end endgenerate
 generate if(STREAMING)begin:g_stream_conv
 npu_conv2d_stream_engine #(.SHARED_WEIGHT_SELECT(SHARED_WEIGHT_SELECT),.ENABLE_PROFILE_TRACE(ENABLE_PROFILE_TRACE),.ENABLE_STALL_DIAG(ENABLE_STALL_DIAG),.EXTERNAL_MATH(1'b1),.EXTERNAL_RESNET_QUANT(1'b1),.EXTERNAL_EPILOGUE(1'b1),.EXTERNAL_FUSION(1'b1),.ENABLE_INPUT_STRIPE(ENABLE_INPUT_STRIPE),.ENABLE_WEIGHT_RESIDENCY(ENABLE_WEIGHT_RESIDENCY),.ENABLE_PE_SPATIAL4(ENABLE_PE_SPATIAL4)) u_conv (
  .stall_events(stall_conv_local),.stall_input_bytes(stall_input_bytes),.stall_weight_bytes(stall_weight_bytes),.stall_window_count(stall_window_count),
  .perf_events(perf_conv_events),.fusion_available(stream_lut_available),.fusion_valid(fusion_valid),.fusion_ready(fusion_ready),
  .fusion_data(fusion_data),.fusion_tag(fusion_tag),.fusion_rsp_valid(fusion_rsp_valid),
  .fusion_result(fusion_result),.fusion_rsp_tag(fusion_rsp_tag),.fusion_fault(fusion_fault),
  .rd_cmd_valid(conv_rd_cmd_valid),
  .rd_cmd_ready(conv_rd_cmd_ready),
  .rd_cmd_addr(conv_rd_cmd_addr),
  .rd_cmd_bytes(conv_rd_cmd_bytes),
  .rd_valid(conv_rd_valid),
  .rd_ready(conv_rd_ready),
  .rd_data(conv_rd_data),
  .rd_keep(conv_rd_keep),
  .rd_last(conv_rd_last),
  .rd_rsp_valid(conv_rd_rsp_valid),
  .rd_rsp_ready(conv_rd_rsp_ready),
  .rd_fault(conv_rd_fault),
  .wr_cmd_valid(conv_wr_cmd_valid),
  .wr_cmd_ready(conv_wr_cmd_ready),
  .wr_cmd_addr(conv_wr_cmd_addr),
  .wr_cmd_bytes(conv_wr_cmd_bytes),
  .wr_valid(conv_wr_valid),
  .wr_ready(conv_wr_ready),
  .wr_data(conv_wr_data),
  .wr_keep(conv_wr_keep),
  .wr_last(conv_wr_last),
  .wr_rsp_valid(conv_wr_rsp_valid),
  .wr_rsp_ready(conv_wr_rsp_ready),
  .wr_fault(conv_wr_fault),
  .clk(clk),.rst_n(rst_n),.cmd_valid(e_cmd_valid[4]),.cmd_ready(e_cmd_ready[4]),.cmd_tag(tag),.cmd_record(inner_record),
  .mem_req_valid(c_req_valid[4]),.mem_req_ready(c_req_ready[4]),.mem_req_write(c_req_write[4]),
  .mem_req_addr(c_req_addr[159:128]),.mem_req_size(c_req_size[9:8]),.mem_req_wdata(c_req_wdata[319:256]),
  .mem_rsp_valid(c_rsp_valid[4]),.mem_rsp_ready(c_rsp_ready[4]),.mem_rsp_rdata(c_rsp_rdata[319:256]),.mem_rsp_fault(c_rsp_fault[19:16]),
  .packed_req_valid(packed_req_valid),.packed_req_ready(packed_req_ready),.packed_req_a16(packed_req_a16),
  .packed_req_first(packed_req_first),.packed_req_last(packed_req_last),.packed_req_act(packed_req_act),.packed_req_weight(packed_req_weight),.packed_req_weight_group(packed_req_weight_group),
  .packed_req_spatial4(packed_req_spatial4),.packed_req_act4(packed_req_act4),
  .packed_rsp_valid(packed_rsp_valid),.packed_rsp_ready(packed_rsp_ready),.packed_rsp_acc(packed_rsp_acc),.packed_rsp_fault(packed_rsp_fault),
  .packed_busy(packed_busy),.packed_abandon_valid(packed_abandon_valid),.packed_abandon_ready(packed_abandon_ready),
  .rsp_valid(e_rsp_valid[4]),.rsp_ready(e_rsp_ready[4]),.rsp_tag(e_rsp_tag[159:128]),.rsp_fault(e_rsp_fault[39:32]),.rsp_completed(),.busy(e_busy[4]),
  .math_req_valid(m_req_valid[5]),.math_req_ready(m_req_ready[5]),.math_req_op(m_req_op[15+:3]),
  .math_req_a(m_req_a[320+:64]),.math_req_b(m_req_b[320+:64]),.math_req_shift(m_req_shift[35+:7]),
  .math_rsp_valid(m_rsp_valid[5]),.math_rsp_ready(m_rsp_ready[5]),.math_rsp_result(m_result),.math_rsp_fault(m_fault),
  .quant_req_valid(q_req_valid[2]),.quant_req_ready(q_req_ready[2]),.quant_req_residual(q_req_residual[2]),
  .quant_req_value(q_req_value[80+:40]),.quant_req_multiplier_a(q_req_ma[128+:64]),.quant_req_multiplier_b(q_req_mb[128+:64]),
  .quant_req_b(q_req_b[16+:8]),.quant_req_shift(q_req_shift[16+:8]),
  .quant_rsp_valid(q_rsp_valid[2]),.quant_rsp_ready(q_rsp_ready[2]),.quant_rsp_result(q_result),
  .epilogue_req_valid(conv_quant_valid),.epilogue_req_value(conv_quant_value),.epilogue_req_multiplier(conv_quant_multiplier),
  .epilogue_req_shift(conv_quant_shift),.epilogue_req_tag(conv_quant_tag),
  .epilogue_rsp_valid(conv_quant_rsp_valid),.epilogue_rsp_result8(conv_quant_result8),.epilogue_rsp_result32(conv_quant_result32),
  .epilogue_rsp_overflow32(conv_quant_overflow),.epilogue_rsp_tag(conv_quant_rsp_tag),.epilogue_pipe_busy(shared_quant_busy));
 end else begin:g_no_conv_profile
  assign packed_req_weight_group=0;
  assign perf_conv_events=0;assign stall_events=0;assign stall_input_bytes=0;assign stall_weight_bytes=0;assign stall_window_count=0;
 end endgenerate
 npu_maxpool_engine #(.EXTERNAL_MATH(1'b1),.ENABLE_MAXPOOL_FASTPATH(ENABLE_MAXPOOL_FASTPATH),.ENABLE_MAXPOOL_BULK(ENABLE_MAXPOOL_BULK && STREAMING)) u_pool (
  .rd_cmd_valid(pool_rd_cmd_valid),.rd_cmd_ready(pool_rd_cmd_ready),.rd_cmd_addr(pool_rd_cmd_addr),.rd_cmd_bytes(pool_rd_cmd_bytes),
  .rd_valid(pool_rd_valid),.rd_ready(pool_rd_ready),.rd_data(stream_read_data),.rd_keep(stream_read_keep),.rd_last(stream_read_last),
  .rd_rsp_valid(pool_rd_rsp_valid),.rd_rsp_ready(pool_rd_rsp_ready),.rd_fault(stream_read_fault),
  .wr_cmd_valid(pool_wr_cmd_valid),.wr_cmd_ready(pool_wr_cmd_ready),.wr_cmd_addr(pool_wr_cmd_addr),.wr_cmd_bytes(pool_wr_cmd_bytes),
  .wr_valid(pool_wr_valid),.wr_ready(pool_wr_ready),.wr_data(pool_wr_data),.wr_keep(pool_wr_keep),.wr_last(pool_wr_last),
  .wr_rsp_valid(pool_wr_rsp_valid),.wr_rsp_ready(pool_wr_rsp_ready),.wr_fault(stream_write_fault),
  .clk(clk),.rst_n(rst_n),.cmd_valid(e_cmd_valid[5]),.cmd_ready(e_cmd_ready[5]),.cmd_tag(tag),.cmd_record(inner_record),
  .mem_req_valid(c_req_valid[5]),.mem_req_ready(c_req_ready[5]),.mem_req_write(c_req_write[5]),
  .mem_req_addr(c_req_addr[191:160]),.mem_req_size(c_req_size[11:10]),.mem_req_wdata(c_req_wdata[383:320]),
  .mem_rsp_valid(c_rsp_valid[5]),.mem_rsp_ready(c_rsp_ready[5]),.mem_rsp_rdata(c_rsp_rdata[383:320]),.mem_rsp_fault(c_rsp_fault[23:20]),
  .rsp_valid(e_rsp_valid[5]),.rsp_ready(e_rsp_ready[5]),.rsp_tag(e_rsp_tag[191:160]),.rsp_fault(e_rsp_fault[47:40]),.busy(e_busy[5]),
  .math_req_valid(m_req_valid[6]),.math_req_ready(m_req_ready[6]),.math_req_op(m_req_op[18+:3]),
  .math_req_a(m_req_a[384+:64]),.math_req_b(m_req_b[384+:64]),.math_req_shift(m_req_shift[42+:7]),
  .math_rsp_valid(m_rsp_valid[6]),.math_rsp_ready(m_rsp_ready[6]),.math_rsp_result(m_result),.math_rsp_fault(m_fault));
 npu_lut_reader #(.ENABLE_LUT_TDP(ENABLE_LUT_TDP)) u_lut (
  .stream_available(stream_lut_available),.stream_req_valid(stream_lut_req_valid),.stream_req_ready(stream_lut_req_ready),
  .stream_req_kind(stream_lut_kind),.stream_req_index(stream_lut_index),.stream_rsp_valid(stream_lut_rsp_valid),.stream_rsp_ready(stream_lut_rsp_ready),
  .stream_rsp_y0(stream_lut_y0),.stream_rsp_y1(stream_lut_y1),.stream_rsp_fault(stream_lut_fault),
  .clk(clk),.rst_n(rst_n),.config_valid(config_valid && admission_idle),.config_ready(reader_config_ready),
  .const_base(cmd_constants_base),.const_bytes(cmd_constants_bytes),
  .sigmoid_base(sigmoid_base),.sigmoid_entries(sigmoid_entries),.sigmoid_dtype(sigmoid_dtype),
  .exp_base(exp_base),.exp_entries(exp_entries),.exp_dtype(exp_dtype),
  .config_rsp_valid(config_rsp_valid),.config_rsp_ready(config_rsp_ready),.config_rsp_fault(config_rsp_fault),
  .req_valid(reader_req_valid),.req_ready(reader_req_ready),.req_kind(reader_kind),.req_index(reader_index),
  .rsp_valid(reader_rsp_valid),.rsp_ready(reader_rsp_ready),.rsp_y0(reader_y0),.rsp_y1(reader_y1),.rsp_fault(reader_fault),
  .scalar_req_valid(c_req_valid[6]),.scalar_req_ready(c_req_ready[6]),.scalar_req_write(c_req_write[6]),
  .scalar_req_addr(c_req_addr[223:192]),.scalar_req_size(c_req_size[13:12]),.scalar_req_wdata(c_req_wdata[447:384]),
  .scalar_rsp_valid(c_rsp_valid[6]),.scalar_rsp_ready(c_rsp_ready[6]),.scalar_rsp_rdata(c_rsp_rdata[447:384]),.scalar_rsp_fault(c_rsp_fault[27:24]));
 // Omit reserved engine ID 3 from the memory and arithmetic fabrics.
 assign c_req_ready[2]=1'b0;assign c_rsp_valid[2]=1'b0;
 assign c_rsp_rdata[191:128]=64'd0;assign c_rsp_fault[11:8]=4'd0;
 assign m_req_ready[3]=1'b0;assign m_rsp_valid[3]=1'b0;
 npu_scalar_fabric #(.CLIENTS(6)) u_memory (
  .clk(clk),.rst_n(rst_n),
  .c_req_valid({c_req_valid[6:3],c_req_valid[1:0]}),.c_req_ready({c_req_ready[6:3],c_req_ready[1:0]}),
  .c_req_write({c_req_write[6:3],c_req_write[1:0]}),.c_req_addr({c_req_addr[223:96],c_req_addr[63:0]}),
  .c_req_size({c_req_size[13:6],c_req_size[3:0]}),.c_req_wdata({c_req_wdata[447:192],c_req_wdata[127:0]}),
  .c_rsp_valid({c_rsp_valid[6:3],c_rsp_valid[1:0]}),.c_rsp_ready({c_rsp_ready[6:3],c_rsp_ready[1:0]}),
  .c_rsp_rdata({c_rsp_rdata[447:192],c_rsp_rdata[127:0]}),.c_rsp_fault({c_rsp_fault[27:12],c_rsp_fault[7:0]}),
  .req_valid(mem_req_valid),.req_ready(mem_req_ready),.req_write(mem_req_write),.req_addr(mem_req_addr),
  .req_size(mem_req_size),.req_wdata(mem_req_wdata),.rsp_valid(mem_rsp_valid),.rsp_ready(mem_rsp_ready),
  .rsp_rdata(mem_rsp_rdata),.rsp_fault(mem_rsp_fault),.idle(memory_idle),.active_owner());
 npu_math_fabric #(.CLIENTS(6)) u_math_fabric (
  .clk(clk),.rst_n(rst_n),
  .c_req_valid({m_req_valid[6:4],m_req_valid[2:0]}),.c_req_ready({m_req_ready[6:4],m_req_ready[2:0]}),
  .c_req_op({m_req_op[20:12],m_req_op[8:0]}),.c_req_a({m_req_a[447:256],m_req_a[191:0]}),
  .c_req_b({m_req_b[447:256],m_req_b[191:0]}),.c_req_shift({m_req_shift[48:28],m_req_shift[20:0]}),
  .c_rsp_valid({m_rsp_valid[6:4],m_rsp_valid[2:0]}),.c_rsp_ready({m_rsp_ready[6:4],m_rsp_ready[2:0]}),
  .c_rsp_result(m_result),.c_rsp_fault(m_fault),
  .req_valid(math_req_valid),.req_ready(math_req_ready),.req_op(math_req_op),
  .req_a(math_req_a),.req_b(math_req_b),.req_shift(math_req_shift),
  .rsp_valid(math_rsp_valid),.rsp_ready(math_rsp_ready),.rsp_result(math_result),.rsp_fault(math_fault),.idle(math_idle));
 npu_wide_math u_shared_math (
  .clk(clk),.rst_n(rst_n),.req_valid(math_req_valid),.req_ready(math_req_ready),.req_op(math_req_op),
  .req_a(math_req_a),.req_b(math_req_b),.req_shift(math_req_shift),
  .rsp_valid(math_rsp_valid),.rsp_ready(math_rsp_ready),.rsp_result(math_result),.rsp_fault(math_fault));
 initial if(!STREAMING) $error("Only the streaming production profile is supported");
 generate if(STREAMING)begin:g_stall_dispatch
 if(ENABLE_STALL_DIAG)begin:g_enabled
  assign stall_events=stall_conv_local | (stall_dispatch_owner[0] ? (85'd1<<78):85'd0);
 end else begin:g_disabled
  assign stall_events=0;
 end
 end endgenerate
endmodule
