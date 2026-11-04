`timescale 1ns/1ps
// Package/task/graph CONTROL integration. Actual operator execution and the
// profile-1 mutable-image bootstrap are external explicit capabilities.
// This module does not instantiate any PE and must share the single array in
// npu_shared_pe. An instruction decoder is not a full-network executor.
module npu_model_control_top #(
 parameter bit STREAMING=1'b1,parameter integer AXI_DATA_W=STREAMING ? 64 : 32,
 parameter bit PS_PREDECODED=1'b0,
 parameter bit ENABLE_STALL_DIAG=1'b1,ENABLE_PERF_COUNTERS=1'b1
) (

 output wire [84:0] stall_dma_events,output wire [31:0] stall_dma_bytes,
 input wire rd_cmd_valid,output wire rd_cmd_ready,input wire [31:0] rd_cmd_addr,rd_cmd_bytes,
 output wire rd_valid,input wire rd_ready,output wire [63:0] rd_data,output wire [7:0] rd_keep,output wire rd_last,
 output wire rd_rsp_valid,input wire rd_rsp_ready,output wire [3:0] rd_fault,

 input wire wr_cmd_valid,output wire wr_cmd_ready,input wire [31:0] wr_cmd_addr,wr_cmd_bytes,
 input wire wr_valid,output wire wr_ready,input wire [63:0] wr_data,input wire [7:0] wr_keep,input wire wr_last,
 output wire wr_rsp_valid,input wire wr_rsp_ready,output wire [3:0] wr_fault,
 output wire [63:0] perf_read_bytes,perf_write_bytes,perf_read_wait,perf_write_wait,
 output wire [31:0] perf_read_bursts,perf_write_bursts,
 output wire [2:0] perf_max_reads,output wire [1:0] perf_max_writes,
 input logic clk, rst_n,
 input logic start_valid, output logic start_ready,
 input logic [31:0] start_model_base, start_model_capacity,
 input logic [31:0] start_workspace_base, start_workspace_capacity,
 input logic [31:0] start_frame_id, start_model_generation,
 input logic capability_legacy, capability_graph,
 input logic [31:0] capability_op_mask,
 // Cache reuse is valid only while package bytes stay immutable for the
 // supplied generation. Invalidate before replacing bytes of a cached image.
 input logic allow_model_cache,
 input logic invalidate_valid, output logic invalidate_ready,
 output logic package_cache_hit,
 output logic busy, workspace_owned, workspace_release,
 output logic [31:0] active_task_id, active_frame_id, active_model_generation,
 input logic cancel_valid, output logic cancel_ready,
 input logic [31:0] cancel_task_id, cancel_frame_id, cancel_model_generation,
 input logic async_fault_valid, input logic [7:0] async_fault_code,
 // Include legacy AXI, every backend FIFO/response, and shared PE ownership.
 input logic executor_reads_idle, executor_writes_idle,
 input logic executor_fifos_idle, executor_compute_idle,
 output logic done_valid, input logic done_ready,
 output logic [31:0] done_task_id, done_frame_id, done_model_generation,
 output logic [31:0] done_model_id, done_profile,
 output logic [15:0] done_fault,
 output logic stale_event,

 output logic legacy_cmd_valid, input logic legacy_cmd_ready,
 output logic legacy_cancel_valid, input logic legacy_cancel_ready,
 // Stable throughout the complete task; also supplies graph backend context.
 output logic [31:0] exec_task_id, exec_frame_id, exec_model_generation,
 output logic [31:0] exec_model_base, exec_workspace_base, exec_model_id, exec_profile,
 output logic [31:0] exec_image_bytes, exec_workspace_bytes,
 output logic [31:0] exec_input_id, exec_output_id, exec_input_lut_id,
 output logic [159:0] exec_section_addr, exec_section_bytes,
 input logic legacy_rsp_valid, output logic legacy_rsp_ready,
 input logic [31:0] legacy_rsp_task_id, legacy_rsp_frame_id, legacy_rsp_model_generation,
 input logic [7:0] legacy_rsp_fault,

 output logic op_cmd_valid, input logic op_cmd_ready,
 output logic [1023:0] op_record, output logic [31:0] op_index,
 input logic op_rsp_valid, output logic op_rsp_ready,
 input logic [31:0] op_rsp_task_id, op_rsp_frame_id, op_rsp_model_generation, op_rsp_index,
 input logic [7:0] op_rsp_fault,
 output logic op_cancel_valid, input logic op_cancel_ready,
 output logic [31:0] graph_fault_op_index,
 output logic [7:0] graph_backend_fault,
 output logic [3:0] graph_memory_fault,

 // Auxiliary scalar clients: backend/tensor/reduction arbiter and LUT reader.
 // Every accepted auxiliary access must have a terminal response, even fault.
 input logic [1:0] aux_req_valid, output logic [1:0] aux_req_ready,
 input logic [1:0] aux_req_write,
 input logic [63:0] aux_req_addr, input logic [3:0] aux_req_size,
 input logic [127:0] aux_req_wdata,
 output logic [1:0] aux_rsp_valid, input logic [1:0] aux_rsp_ready,
 output logic [127:0] aux_rsp_rdata, output logic [7:0] aux_rsp_fault,
 output logic transport_idle,

 output wire [31:0] m_axi_awaddr, output wire [7:0] m_axi_awlen,
 output wire [2:0] m_axi_awsize, output wire [1:0] m_axi_awburst,
 output wire m_axi_awlock, output wire [3:0] m_axi_awcache,
 output wire [2:0] m_axi_awprot, output wire [3:0] m_axi_awqos,
 output wire m_axi_awvalid, input wire m_axi_awready,
 output wire [AXI_DATA_W-1:0] m_axi_wdata, output wire [AXI_DATA_W/8-1:0] m_axi_wstrb,
 output wire m_axi_wlast, m_axi_wvalid, input wire m_axi_wready,
 input wire [1:0] m_axi_bresp, input wire m_axi_bvalid, output wire m_axi_bready,
 output wire [31:0] m_axi_araddr, output wire [7:0] m_axi_arlen,
 output wire [2:0] m_axi_arsize, output wire [1:0] m_axi_arburst,
 output wire m_axi_arlock, output wire [3:0] m_axi_arcache,
 output wire [2:0] m_axi_arprot, output wire [3:0] m_axi_arqos,
 output wire m_axi_arvalid, input wire m_axi_arready,
 input wire [AXI_DATA_W-1:0] m_axi_rdata, input wire [1:0] m_axi_rresp,
 input wire m_axi_rlast, m_axi_rvalid, output wire m_axi_rready
);
 logic fe_cmd_valid, fe_cmd_ready, fe_rsp_valid, fe_rsp_ready, fe_busy;
 logic [31:0] fe_model_base,fe_model_capacity,fe_workspace_base,fe_workspace_capacity;
 logic [3:0] fe_rsp_fault;
 logic [31:0] fe_rsp_model_id,fe_rsp_profile,fe_rsp_image_bytes,fe_rsp_workspace_bytes;
 logic [31:0] fe_rsp_input_id,fe_rsp_output_id,fe_rsp_input_lut_id;
 logic [159:0] fe_rsp_section_addr,fe_rsp_section_bytes;
 logic [31:0] fe_mem_addr;
 logic fe_mem_valid,fe_mem_ready,fe_mem_rsp_ready;
 logic graph_cmd_valid,graph_cmd_ready,graph_cancel_valid,graph_cancel_ready;
 logic graph_rsp_valid,graph_rsp_ready,graph_busy,task_stale,graph_stale;
 logic [31:0] graph_rsp_task_id,graph_rsp_frame_id,graph_rsp_model_generation;
 logic [7:0] graph_rsp_fault;
 logic [31:0] graph_op_mask;
 logic task_start_ready,cache_allowed,cache_flush_ready,cache_busy,admission_quiet;
 logic check_cmd_valid,check_cmd_ready,check_rsp_valid,check_rsp_ready;
 logic [31:0] check_model_base,check_model_capacity,check_workspace_base,check_workspace_capacity;
 logic [3:0] check_rsp_fault;
 logic [31:0] check_rsp_model_id,check_rsp_profile,check_rsp_image_bytes,check_rsp_workspace_bytes;
 logic [31:0] check_rsp_input_id,check_rsp_output_id,check_rsp_input_lut_id;
 logic [159:0] check_rsp_section_addr,check_rsp_section_bytes;
 logic [3:0] c_req_valid,c_req_ready,c_req_write,c_rsp_valid,c_rsp_ready;
 logic [127:0] c_req_addr;
 logic [7:0] c_req_size;
 logic [255:0] c_req_wdata,c_rsp_rdata;
 logic [15:0] c_rsp_fault;
 logic scalar_req_valid,scalar_req_ready,scalar_req_write,scalar_rsp_valid,scalar_rsp_ready;
 logic [31:0] scalar_req_addr;
 logic [1:0] scalar_req_size;
 logic [63:0] scalar_req_wdata;
 logic signed [63:0] scalar_rsp_rdata;
 logic [3:0] scalar_rsp_fault;
 logic fabric_idle,scalar_busy;
 assign stale_event=task_stale || graph_stale;
 assign transport_idle=fabric_idle && !scalar_busy;
 assign admission_quiet=!busy && transport_idle && !fe_busy && !cache_busy && !graph_busy &&
  executor_reads_idle && executor_writes_idle && executor_fifos_idle && executor_compute_idle;
 assign invalidate_ready=admission_quiet && cache_flush_ready;
 assign start_ready=task_start_ready && !invalidate_valid && admission_quiet;
 // Capture at task admission, rather than allowing PS changes while the
 // package's CRC stream is still being read to alter this job's capabilities.
 always_ff @(posedge clk) begin
  if(!rst_n) begin graph_op_mask<=0; cache_allowed<=0; end
  else if(start_valid && start_ready) begin
   graph_op_mask<=capability_op_mask; cache_allowed<=allow_model_cache;
  end
 end
 npu_task_controller u_tasks (
  .clk(clk),.rst_n(rst_n),
  .start_valid(start_valid && !invalidate_valid && admission_quiet),.start_ready(task_start_ready),
  .start_model_base(start_model_base),.start_model_capacity(start_model_capacity),
  .start_workspace_base(start_workspace_base),.start_workspace_capacity(start_workspace_capacity),
  .start_frame_id(start_frame_id),.start_model_generation(start_model_generation),
  .capability_legacy(capability_legacy),.capability_graph(capability_graph),
  .busy(busy),.workspace_owned(workspace_owned),.workspace_release(workspace_release),
  .active_task_id(active_task_id),.active_frame_id(active_frame_id),.active_model_generation(active_model_generation),
  .fe_cmd_valid(fe_cmd_valid),.fe_cmd_ready(fe_cmd_ready),
  .fe_model_base(fe_model_base),.fe_model_capacity(fe_model_capacity),
  .fe_workspace_base(fe_workspace_base),.fe_workspace_capacity(fe_workspace_capacity),
  .fe_rsp_valid(fe_rsp_valid),.fe_rsp_ready(fe_rsp_ready),.fe_rsp_fault(fe_rsp_fault),
  .fe_rsp_model_id(fe_rsp_model_id),.fe_rsp_profile(fe_rsp_profile),
  .fe_rsp_image_bytes(fe_rsp_image_bytes),.fe_rsp_workspace_bytes(fe_rsp_workspace_bytes),
  .fe_rsp_input_id(fe_rsp_input_id),.fe_rsp_output_id(fe_rsp_output_id),.fe_rsp_input_lut_id(fe_rsp_input_lut_id),
  .fe_rsp_section_addr(fe_rsp_section_addr),.fe_rsp_section_bytes(fe_rsp_section_bytes),
  .legacy_cmd_valid(legacy_cmd_valid),.legacy_cmd_ready(legacy_cmd_ready),
  .graph_cmd_valid(graph_cmd_valid),.graph_cmd_ready(graph_cmd_ready),
  .exec_task_id(exec_task_id),.exec_frame_id(exec_frame_id),.exec_model_generation(exec_model_generation),
  .exec_model_base(exec_model_base),.exec_workspace_base(exec_workspace_base),
  .exec_model_id(exec_model_id),.exec_profile(exec_profile),
  .exec_image_bytes(exec_image_bytes),.exec_workspace_bytes(exec_workspace_bytes),
  .exec_input_id(exec_input_id),.exec_output_id(exec_output_id),.exec_input_lut_id(exec_input_lut_id),
  .exec_section_addr(exec_section_addr),.exec_section_bytes(exec_section_bytes),
  .legacy_rsp_valid(legacy_rsp_valid),.legacy_rsp_ready(legacy_rsp_ready),
  .legacy_rsp_task_id(legacy_rsp_task_id),.legacy_rsp_frame_id(legacy_rsp_frame_id),
  .legacy_rsp_model_generation(legacy_rsp_model_generation),.legacy_rsp_fault(legacy_rsp_fault),
  .graph_rsp_valid(graph_rsp_valid),.graph_rsp_ready(graph_rsp_ready),
  .graph_rsp_task_id(graph_rsp_task_id),.graph_rsp_frame_id(graph_rsp_frame_id),
  .graph_rsp_model_generation(graph_rsp_model_generation),.graph_rsp_fault(graph_rsp_fault),
  .cancel_valid(cancel_valid),.cancel_ready(cancel_ready),
  .cancel_task_id(cancel_task_id),.cancel_frame_id(cancel_frame_id),.cancel_model_generation(cancel_model_generation),
  .legacy_cancel_valid(legacy_cancel_valid),.legacy_cancel_ready(legacy_cancel_ready),
  .graph_cancel_valid(graph_cancel_valid),.graph_cancel_ready(graph_cancel_ready),
  .async_fault_valid(async_fault_valid),.async_fault_code(async_fault_code),
  .reads_idle(transport_idle && executor_reads_idle),
  .writes_idle(transport_idle && executor_writes_idle),
  .fifos_idle(executor_fifos_idle),.compute_idle(!fe_busy && !cache_busy && !graph_busy && executor_compute_idle),
  .done_valid(done_valid),.done_ready(done_ready),
  .done_task_id(done_task_id),.done_frame_id(done_frame_id),.done_model_generation(done_model_generation),
  .done_model_id(done_model_id),.done_profile(done_profile),.done_fault(done_fault),.stale_event(task_stale)
 );
 generate if(PS_PREDECODED)begin:g_ps_predecoded
 // Fixed metadata is inexpensive to reread at task admission. No duplicate
 // 3-entry package cache or whole-image parser is present in this netlist.
 assign cache_busy=1'b0;assign cache_flush_ready=1'b1;assign package_cache_hit=1'b0;
 npu_predecoded_frontend u_package (
  .clk(clk),.rst_n(rst_n),.cmd_valid(fe_cmd_valid),.cmd_ready(fe_cmd_ready),
  .cmd_model_base(fe_model_base),.cmd_model_capacity(fe_model_capacity),
  .cmd_workspace_base(fe_workspace_base),.cmd_workspace_capacity(fe_workspace_capacity),
  .mem_req_valid(fe_mem_valid),.mem_req_ready(fe_mem_ready),.mem_req_addr(fe_mem_addr),
  .mem_rsp_valid(c_rsp_valid[0]),.mem_rsp_ready(fe_mem_rsp_ready),
  .mem_rsp_data(c_rsp_rdata[31:0]),.mem_rsp_fault(|c_rsp_fault[3:0]),
  .rsp_valid(fe_rsp_valid),.rsp_ready(fe_rsp_ready),.rsp_fault(fe_rsp_fault),
  .rsp_model_id(fe_rsp_model_id),.rsp_profile(fe_rsp_profile),
  .rsp_image_bytes(fe_rsp_image_bytes),.rsp_workspace_bytes(fe_rsp_workspace_bytes),
  .rsp_input_id(fe_rsp_input_id),.rsp_output_id(fe_rsp_output_id),.rsp_input_lut_id(fe_rsp_input_lut_id),
  .rsp_section_addr(fe_rsp_section_addr),.rsp_section_bytes(fe_rsp_section_bytes),.busy(fe_busy)
 );
 end else begin:g_legacy_checked_package
 npu_package_cache #(.ENTRIES(3)) u_package_cache (
  .clk(clk),.rst_n(rst_n),.cmd_valid(fe_cmd_valid),.cmd_ready(fe_cmd_ready),
  .cmd_model_base(fe_model_base),.cmd_model_capacity(fe_model_capacity),
  .cmd_workspace_base(fe_workspace_base),.cmd_workspace_capacity(fe_workspace_capacity),
  .cmd_generation(active_model_generation),.cmd_allow_cache(cache_allowed),
  .invalidate_valid(invalidate_valid && admission_quiet),.invalidate_ready(cache_flush_ready),
  .cache_hit_pulse(package_cache_hit),.busy(cache_busy),
  .rsp_valid(fe_rsp_valid),.rsp_ready(fe_rsp_ready),.rsp_fault(fe_rsp_fault),
  .rsp_model_id(fe_rsp_model_id),.rsp_profile(fe_rsp_profile),
  .rsp_image_bytes(fe_rsp_image_bytes),.rsp_workspace_bytes(fe_rsp_workspace_bytes),
  .rsp_input_id(fe_rsp_input_id),.rsp_output_id(fe_rsp_output_id),.rsp_input_lut_id(fe_rsp_input_lut_id),
  .rsp_section_addr(fe_rsp_section_addr),.rsp_section_bytes(fe_rsp_section_bytes),
  .inner_cmd_valid(check_cmd_valid),.inner_cmd_ready(check_cmd_ready),
  .inner_cmd_model_base(check_model_base),.inner_cmd_model_capacity(check_model_capacity),
  .inner_cmd_workspace_base(check_workspace_base),.inner_cmd_workspace_capacity(check_workspace_capacity),
  .inner_rsp_valid(check_rsp_valid),.inner_rsp_ready(check_rsp_ready),.inner_rsp_fault(check_rsp_fault),
  .inner_rsp_model_id(check_rsp_model_id),.inner_rsp_profile(check_rsp_profile),
  .inner_rsp_image_bytes(check_rsp_image_bytes),.inner_rsp_workspace_bytes(check_rsp_workspace_bytes),
  .inner_rsp_input_id(check_rsp_input_id),.inner_rsp_output_id(check_rsp_output_id),
  .inner_rsp_input_lut_id(check_rsp_input_lut_id),
  .inner_rsp_section_addr(check_rsp_section_addr),.inner_rsp_section_bytes(check_rsp_section_bytes)
 );
 npu_aipkg3_frontend u_package (
  .clk(clk),.rst_n(rst_n),.cmd_valid(check_cmd_valid),.cmd_ready(check_cmd_ready),
  .cmd_model_base(check_model_base),.cmd_model_capacity(check_model_capacity),
  .cmd_workspace_base(check_workspace_base),.cmd_workspace_capacity(check_workspace_capacity),
  .mem_req_valid(fe_mem_valid),.mem_req_ready(fe_mem_ready),.mem_req_addr(fe_mem_addr),
  .mem_rsp_valid(c_rsp_valid[0]),.mem_rsp_ready(fe_mem_rsp_ready),
  .mem_rsp_data(c_rsp_rdata[31:0]),.mem_rsp_fault(|c_rsp_fault[3:0]),
  .rsp_valid(check_rsp_valid),.rsp_ready(check_rsp_ready),.rsp_fault(check_rsp_fault),
  .rsp_model_id(check_rsp_model_id),.rsp_profile(check_rsp_profile),
  .rsp_image_bytes(check_rsp_image_bytes),.rsp_workspace_bytes(check_rsp_workspace_bytes),
  .rsp_input_id(check_rsp_input_id),.rsp_output_id(check_rsp_output_id),.rsp_input_lut_id(check_rsp_input_lut_id),
  .rsp_section_addr(check_rsp_section_addr),.rsp_section_bytes(check_rsp_section_bytes),.busy(fe_busy)
 );
 end endgenerate
 npu_graph_sequencer #(.PS_PREDECODED(PS_PREDECODED)) u_graph (
  .clk(clk),.rst_n(rst_n),.cmd_valid(graph_cmd_valid),.cmd_ready(graph_cmd_ready),
  .cmd_task_id(exec_task_id),.cmd_frame_id(exec_frame_id),.cmd_model_generation(exec_model_generation),
  .cmd_model_base(exec_model_base),.cmd_workspace_base(exec_workspace_base),
  .cmd_model_id(exec_model_id),.cmd_profile(exec_profile),
  .cmd_image_bytes(exec_image_bytes),.cmd_workspace_bytes(exec_workspace_bytes),
  .cmd_input_id(exec_input_id),.cmd_output_id(exec_output_id),.cmd_input_lut_id(exec_input_lut_id),
  .cmd_section_addr(exec_section_addr),.cmd_section_bytes(exec_section_bytes),.capability_op_mask(graph_op_mask),
  .mem_req_valid(c_req_valid[1]),.mem_req_ready(c_req_ready[1]),.mem_req_write(c_req_write[1]),
  .mem_req_addr(c_req_addr[63:32]),.mem_req_size(c_req_size[3:2]),.mem_req_wdata(c_req_wdata[127:64]),
  .mem_rsp_valid(c_rsp_valid[1]),.mem_rsp_ready(c_rsp_ready[1]),
  .mem_rsp_rdata(c_rsp_rdata[127:64]),.mem_rsp_fault(c_rsp_fault[7:4]),
  .op_cmd_valid(op_cmd_valid),.op_cmd_ready(op_cmd_ready),.op_record(op_record),.op_index(op_index),
  .op_task_id(),.op_frame_id(),.op_model_generation(),.op_model_base(),.op_workspace_base(),
  .op_model_id(),.op_profile(),.op_image_bytes(),.op_workspace_bytes(),
  .op_input_id(),.op_output_id(),.op_input_lut_id(),.op_section_addr(),.op_section_bytes(),
  .op_rsp_valid(op_rsp_valid),.op_rsp_ready(op_rsp_ready),
  .op_rsp_task_id(op_rsp_task_id),.op_rsp_frame_id(op_rsp_frame_id),
  .op_rsp_model_generation(op_rsp_model_generation),.op_rsp_index(op_rsp_index),.op_rsp_fault(op_rsp_fault),
  .cancel_valid(graph_cancel_valid),.cancel_ready(graph_cancel_ready),
  .cancel_task_id(exec_task_id),.cancel_frame_id(exec_frame_id),.cancel_model_generation(exec_model_generation),
  .op_cancel_valid(op_cancel_valid),.op_cancel_ready(op_cancel_ready),
  .rsp_valid(graph_rsp_valid),.rsp_ready(graph_rsp_ready),
  .rsp_task_id(graph_rsp_task_id),.rsp_frame_id(graph_rsp_frame_id),.rsp_model_generation(graph_rsp_model_generation),
  .rsp_model_id(),.rsp_profile(),.rsp_op_index(graph_fault_op_index),
  .rsp_fault(graph_rsp_fault),.rsp_backend_fault(graph_backend_fault),.rsp_memory_fault(graph_memory_fault),
  .busy(graph_busy),.stale_event(graph_stale)
 );
 assign c_req_valid[0]=fe_mem_valid;
 assign fe_mem_ready=c_req_ready[0];
 assign c_req_write[0]=0; assign c_req_addr[31:0]=fe_mem_addr;
 assign c_req_size[1:0]=2'd2; assign c_req_wdata[63:0]=0;
 assign c_rsp_ready[0]=fe_mem_rsp_ready;
 assign c_req_valid[3:2]=aux_req_valid; assign aux_req_ready=c_req_ready[3:2];
 assign c_req_write[3:2]=aux_req_write; assign c_req_addr[127:64]=aux_req_addr;
 assign c_req_size[7:4]=aux_req_size; assign c_req_wdata[255:128]=aux_req_wdata;
 assign aux_rsp_valid=c_rsp_valid[3:2]; assign c_rsp_ready[3:2]=aux_rsp_ready;
 assign aux_rsp_rdata=c_rsp_rdata[255:128]; assign aux_rsp_fault=c_rsp_fault[15:8];
 npu_scalar_fabric #(.CLIENTS(4)) u_fabric (
  .clk(clk),.rst_n(rst_n),.c_req_valid(c_req_valid),.c_req_ready(c_req_ready),
  .c_req_write(c_req_write),.c_req_addr(c_req_addr),.c_req_size(c_req_size),.c_req_wdata(c_req_wdata),
  .c_rsp_valid(c_rsp_valid),.c_rsp_ready(c_rsp_ready),.c_rsp_rdata(c_rsp_rdata),.c_rsp_fault(c_rsp_fault),
  .req_valid(scalar_req_valid),.req_ready(scalar_req_ready),.req_write(scalar_req_write),
  .req_addr(scalar_req_addr),.req_size(scalar_req_size),.req_wdata(scalar_req_wdata),
  .rsp_valid(scalar_rsp_valid),.rsp_ready(scalar_rsp_ready),.rsp_rdata(scalar_rsp_rdata),.rsp_fault(scalar_rsp_fault),
  .idle(fabric_idle),.active_owner()
 );
 generate if(STREAMING)begin:g_stream_transport
 npu_stream_axi_master #(.ENABLE_STALL_DIAG(ENABLE_STALL_DIAG),.ENABLE_PERF_COUNTERS(ENABLE_PERF_COUNTERS)) u_transport (
  .stall_dma_events(stall_dma_events),.stall_dma_bytes(stall_dma_bytes),
  .bulk_rd_cmd_valid(rd_cmd_valid),
  .bulk_rd_cmd_ready(rd_cmd_ready),
  .bulk_rd_cmd_addr(rd_cmd_addr),
  .bulk_rd_cmd_bytes(rd_cmd_bytes),
  .bulk_rd_valid(rd_valid),
  .bulk_rd_ready(rd_ready),
  .bulk_rd_data(rd_data),
  .bulk_rd_keep(rd_keep),
  .bulk_rd_last(rd_last),
  .bulk_rd_rsp_valid(rd_rsp_valid),
  .bulk_rd_rsp_ready(rd_rsp_ready),
  .bulk_rd_fault(rd_fault),
  .bulk_wr_cmd_valid(wr_cmd_valid),
  .bulk_wr_cmd_ready(wr_cmd_ready),
  .bulk_wr_cmd_addr(wr_cmd_addr),
  .bulk_wr_cmd_bytes(wr_cmd_bytes),
  .bulk_wr_valid(wr_valid),
  .bulk_wr_ready(wr_ready),
  .bulk_wr_data(wr_data),
  .bulk_wr_keep(wr_keep),
  .bulk_wr_last(wr_last),
  .bulk_wr_rsp_valid(wr_rsp_valid),
  .bulk_wr_rsp_ready(wr_rsp_ready),
  .bulk_wr_fault(wr_fault),
  .read_bytes(perf_read_bytes),.write_bytes(perf_write_bytes),.read_wait_cycles(perf_read_wait),.write_wait_cycles(perf_write_wait),
  .read_bursts(perf_read_bursts),.write_bursts(perf_write_bursts),.max_reads(perf_max_reads),.max_writes(perf_max_writes),
  .clk(clk),.rst_n(rst_n),.req_valid(scalar_req_valid),.req_ready(scalar_req_ready),
  .req_write(scalar_req_write),.req_addr(scalar_req_addr),.req_size(scalar_req_size),.req_wdata(scalar_req_wdata),
  .rsp_valid(scalar_rsp_valid),.rsp_ready(scalar_rsp_ready),.rsp_rdata(scalar_rsp_rdata),.rsp_fault(scalar_rsp_fault),
  .busy(scalar_busy),
  .m_axi_awaddr(m_axi_awaddr),.m_axi_awlen(m_axi_awlen),.m_axi_awsize(m_axi_awsize),.m_axi_awburst(m_axi_awburst),
  .m_axi_awlock(m_axi_awlock),.m_axi_awcache(m_axi_awcache),.m_axi_awprot(m_axi_awprot),.m_axi_awqos(m_axi_awqos),
  .m_axi_awvalid(m_axi_awvalid),.m_axi_awready(m_axi_awready),
  .m_axi_wdata(m_axi_wdata),.m_axi_wstrb(m_axi_wstrb),.m_axi_wlast(m_axi_wlast),
  .m_axi_wvalid(m_axi_wvalid),.m_axi_wready(m_axi_wready),
  .m_axi_bresp(m_axi_bresp),.m_axi_bvalid(m_axi_bvalid),.m_axi_bready(m_axi_bready),
  .m_axi_araddr(m_axi_araddr),.m_axi_arlen(m_axi_arlen),.m_axi_arsize(m_axi_arsize),.m_axi_arburst(m_axi_arburst),
  .m_axi_arlock(m_axi_arlock),.m_axi_arcache(m_axi_arcache),.m_axi_arprot(m_axi_arprot),.m_axi_arqos(m_axi_arqos),
  .m_axi_arvalid(m_axi_arvalid),.m_axi_arready(m_axi_arready),
  .m_axi_rdata(m_axi_rdata),.m_axi_rresp(m_axi_rresp),.m_axi_rlast(m_axi_rlast),
  .m_axi_rvalid(m_axi_rvalid),.m_axi_rready(m_axi_rready)
 );
 end endgenerate
 initial if(!STREAMING) $error("Only the streaming production profile is supported");
endmodule
