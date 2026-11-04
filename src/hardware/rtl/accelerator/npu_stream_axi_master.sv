`timescale 1ns/1ps
// Scalar control/checked fallback and bulk clients share one ordered 64-bit
// AXI DMA. Scalar writes are acknowledged after BRESP. Idle includes every
// descriptor, stream FIFO, terminal response and bus transaction.
module npu_stream_axi_master #(
 parameter bit ENABLE_STALL_DIAG=1'b1,ENABLE_PERF_COUNTERS=1'b1
) (
 output wire [84:0] stall_dma_events,output wire [31:0] stall_dma_bytes,
 input wire clk,rst_n,
 input wire req_valid,output wire req_ready,input wire req_write,
 input wire [31:0] req_addr,input wire [1:0] req_size,input wire [63:0] req_wdata,
 output wire rsp_valid,input wire rsp_ready,output reg signed [63:0] rsp_rdata,
 output reg [3:0] rsp_fault,output wire busy,
 input wire bulk_rd_cmd_valid,output wire bulk_rd_cmd_ready,
 input wire [31:0] bulk_rd_cmd_addr,bulk_rd_cmd_bytes,
 output wire bulk_rd_valid,input wire bulk_rd_ready,output wire [63:0] bulk_rd_data,
 output wire [7:0] bulk_rd_keep,output wire bulk_rd_last,
 output wire bulk_rd_rsp_valid,input wire bulk_rd_rsp_ready,output wire [3:0] bulk_rd_fault,
 input wire bulk_wr_cmd_valid,output wire bulk_wr_cmd_ready,
 input wire [31:0] bulk_wr_cmd_addr,bulk_wr_cmd_bytes,
 input wire bulk_wr_valid,output wire bulk_wr_ready,input wire [63:0] bulk_wr_data,
 input wire [7:0] bulk_wr_keep,input wire bulk_wr_last,
 output wire bulk_wr_rsp_valid,input wire bulk_wr_rsp_ready,output wire [3:0] bulk_wr_fault,
 output wire [63:0] read_bytes,write_bytes,read_wait_cycles,write_wait_cycles,
 output wire [31:0] read_bursts,write_bursts,
 output wire [2:0] max_reads,output wire [1:0] max_writes,
 output wire [31:0] m_axi_araddr,output wire [7:0] m_axi_arlen,
 output wire [2:0] m_axi_arsize,output wire [1:0] m_axi_arburst,
 output wire m_axi_arlock,output wire [3:0] m_axi_arcache,
 output wire [2:0] m_axi_arprot,output wire [3:0] m_axi_arqos,
 output wire m_axi_arvalid,input wire m_axi_arready,
 input wire [63:0] m_axi_rdata,input wire [1:0] m_axi_rresp,
 input wire m_axi_rlast,m_axi_rvalid,output wire m_axi_rready,
 output wire [31:0] m_axi_awaddr,output wire [7:0] m_axi_awlen,
 output wire [2:0] m_axi_awsize,output wire [1:0] m_axi_awburst,
 output wire m_axi_awlock,output wire [3:0] m_axi_awcache,
 output wire [2:0] m_axi_awprot,output wire [3:0] m_axi_awqos,
 output wire m_axi_awvalid,input wire m_axi_awready,
 output wire [63:0] m_axi_wdata,output wire [7:0] m_axi_wstrb,
 output wire m_axi_wlast,m_axi_wvalid,input wire m_axi_wready,
 input wire [1:0] m_axi_bresp,input wire m_axi_bvalid,output wire m_axi_bready
);
 typedef enum logic [3:0]{IDLE,READ_COMMAND,READ_DATA,READ_RESPONSE,WRITE_COMMAND,WRITE_DATA,WRITE_RESPONSE,RESPONSE}state_t;
 state_t state;
 reg [31:0] address,length;
 reg [1:0] size;
 reg [63:0] write_data,read_data;
 reg [2:0] byte_offset;
 wire [1:0] r_cmd_valid,r_cmd_ready,r_valid,r_ready,r_rsp_valid,r_rsp_ready;
 wire [1:0] w_cmd_valid,w_cmd_ready,w_valid,w_ready,w_last,w_rsp_valid,w_rsp_ready;
 wire [63:0] r_data;
 wire [7:0] r_keep;
 wire r_last;
 wire [3:0] r_fault,w_fault;
 wire r_idle,w_idle,dma_idle;
 wire dma_rd_cmd_valid,dma_rd_cmd_ready,dma_rd_valid,dma_rd_ready,dma_rd_last,dma_rd_rsp_valid,dma_rd_rsp_ready;
 wire [31:0] dma_rd_cmd_addr,dma_rd_cmd_bytes;
 wire [63:0] dma_rd_data;
 wire [7:0] dma_rd_keep;
 wire [3:0] dma_rd_fault;
 wire dma_wr_cmd_valid,dma_wr_cmd_ready,dma_wr_valid,dma_wr_ready,dma_wr_last,dma_wr_rsp_valid,dma_wr_rsp_ready;
 wire [31:0] dma_wr_cmd_addr,dma_wr_cmd_bytes;
 wire [63:0] dma_wr_data;
 wire [7:0] dma_wr_keep;
 wire [3:0] dma_wr_fault;
 assign req_ready=rst_n&&state==IDLE;assign rsp_valid=rst_n&&state==RESPONSE;
 assign busy=state!=IDLE||!r_idle||!w_idle||!dma_idle;
 assign r_cmd_valid={bulk_rd_cmd_valid,rst_n&&state==READ_COMMAND};
 assign r_ready={bulk_rd_ready,rst_n&&state==READ_DATA};
 assign r_rsp_ready={bulk_rd_rsp_ready,rst_n&&state==READ_RESPONSE};
 assign bulk_rd_cmd_ready=r_cmd_ready[1];assign bulk_rd_valid=r_valid[1];
 assign bulk_rd_data=r_data;assign bulk_rd_keep=r_keep;assign bulk_rd_last=r_last;
 assign bulk_rd_rsp_valid=r_rsp_valid[1];assign bulk_rd_fault=r_fault;
 assign w_cmd_valid={bulk_wr_cmd_valid,rst_n&&state==WRITE_COMMAND};
 assign w_valid={bulk_wr_valid,rst_n&&state==WRITE_DATA};
 assign w_last={bulk_wr_last,1'b1};assign w_rsp_ready={bulk_wr_rsp_ready,rst_n&&state==WRITE_RESPONSE};
 assign bulk_wr_cmd_ready=w_cmd_ready[1];assign bulk_wr_ready=w_ready[1];
 assign bulk_wr_rsp_valid=w_rsp_valid[1];assign bulk_wr_fault=w_fault;
 wire [1:0] stall_transport_owner;wire [84:0] stall_dma_raw;
 npu_stream_read_fabric #(.ENABLE_STALL_DIAG(ENABLE_STALL_DIAG)) u_read (
  .stall_other_owner(stall_transport_owner),
  .clk(clk),.rst_n(rst_n),.c_cmd_valid(r_cmd_valid),.c_cmd_ready(r_cmd_ready),
  .c_cmd_addr({bulk_rd_cmd_addr,address}),.c_cmd_bytes({bulk_rd_cmd_bytes,length}),
  .c_valid(r_valid),.c_ready(r_ready),.c_data(r_data),.c_keep(r_keep),.c_last(r_last),
  .c_rsp_valid(r_rsp_valid),.c_rsp_ready(r_rsp_ready),.c_fault(r_fault),
  .cmd_valid(dma_rd_cmd_valid),.cmd_ready(dma_rd_cmd_ready),.cmd_addr(dma_rd_cmd_addr),.cmd_bytes(dma_rd_cmd_bytes),
  .valid(dma_rd_valid),.ready(dma_rd_ready),.data(dma_rd_data),.keep(dma_rd_keep),.last(dma_rd_last),
  .rsp_valid(dma_rd_rsp_valid),.rsp_ready(dma_rd_rsp_ready),.fault(dma_rd_fault),.idle(r_idle));
 npu_stream_write_fabric u_write (
  .clk(clk),.rst_n(rst_n),.c_cmd_valid(w_cmd_valid),.c_cmd_ready(w_cmd_ready),
  .c_cmd_addr({bulk_wr_cmd_addr,address}),.c_cmd_bytes({bulk_wr_cmd_bytes,length}),
  .c_valid(w_valid),.c_ready(w_ready),.c_data({bulk_wr_data,write_data}),
  .c_keep({bulk_wr_keep,8'(((9'd1<<length)-1)<<byte_offset)}),.c_last(w_last),
  .c_rsp_valid(w_rsp_valid),.c_rsp_ready(w_rsp_ready),.c_fault(w_fault),
  .cmd_valid(dma_wr_cmd_valid),.cmd_ready(dma_wr_cmd_ready),.cmd_addr(dma_wr_cmd_addr),.cmd_bytes(dma_wr_cmd_bytes),
  .valid(dma_wr_valid),.ready(dma_wr_ready),.data(dma_wr_data),.keep(dma_wr_keep),.last(dma_wr_last),
  .rsp_valid(dma_wr_rsp_valid),.rsp_ready(dma_wr_rsp_ready),.fault(dma_wr_fault),.idle(w_idle));
 npu_stream_dma #(.ENABLE_STALL_DIAG(ENABLE_STALL_DIAG),.ENABLE_PERF_COUNTERS(ENABLE_PERF_COUNTERS)) u_dma (
  .stall_events(stall_dma_raw),
  .clk(clk),.rst_n(rst_n),.stop(1'b0),
  .rd_cmd_valid(dma_rd_cmd_valid),.rd_cmd_ready(dma_rd_cmd_ready),.rd_cmd_addr(dma_rd_cmd_addr),.rd_cmd_bytes(dma_rd_cmd_bytes),
  .rd_valid(dma_rd_valid),.rd_ready(dma_rd_ready),.rd_data(dma_rd_data),.rd_keep(dma_rd_keep),.rd_last(dma_rd_last),
  .rd_rsp_valid(dma_rd_rsp_valid),.rd_rsp_ready(dma_rd_rsp_ready),.rd_fault(dma_rd_fault),
  .wr_cmd_valid(dma_wr_cmd_valid),.wr_cmd_ready(dma_wr_cmd_ready),.wr_cmd_addr(dma_wr_cmd_addr),.wr_cmd_bytes(dma_wr_cmd_bytes),
  .wr_valid(dma_wr_valid),.wr_ready(dma_wr_ready),.wr_data(dma_wr_data),.wr_keep(dma_wr_keep),.wr_last(dma_wr_last),
  .wr_rsp_valid(dma_wr_rsp_valid),.wr_rsp_ready(dma_wr_rsp_ready),.wr_fault(dma_wr_fault),
  .idle(dma_idle),.read_bytes(read_bytes),.write_bytes(write_bytes),.read_wait_cycles(read_wait_cycles),
  .write_wait_cycles(write_wait_cycles),.read_bursts(read_bursts),.write_bursts(write_bursts),.max_reads(max_reads),.max_writes(max_writes),
  .m_axi_araddr(m_axi_araddr),
  .m_axi_arlen(m_axi_arlen),
  .m_axi_arsize(m_axi_arsize),
  .m_axi_arburst(m_axi_arburst),
  .m_axi_arlock(m_axi_arlock),
  .m_axi_arcache(m_axi_arcache),
  .m_axi_arprot(m_axi_arprot),
  .m_axi_arqos(m_axi_arqos),
  .m_axi_arvalid(m_axi_arvalid),
  .m_axi_arready(m_axi_arready),
  .m_axi_rdata(m_axi_rdata),
  .m_axi_rresp(m_axi_rresp),
  .m_axi_rlast(m_axi_rlast),
  .m_axi_rvalid(m_axi_rvalid),
  .m_axi_rready(m_axi_rready),
  .m_axi_awaddr(m_axi_awaddr),
  .m_axi_awlen(m_axi_awlen),
  .m_axi_awsize(m_axi_awsize),
  .m_axi_awburst(m_axi_awburst),
  .m_axi_awlock(m_axi_awlock),
  .m_axi_awcache(m_axi_awcache),
  .m_axi_awprot(m_axi_awprot),
  .m_axi_awqos(m_axi_awqos),
  .m_axi_awvalid(m_axi_awvalid),
  .m_axi_awready(m_axi_awready),
  .m_axi_wdata(m_axi_wdata),
  .m_axi_wstrb(m_axi_wstrb),
  .m_axi_wlast(m_axi_wlast),
  .m_axi_wvalid(m_axi_wvalid),
  .m_axi_wready(m_axi_wready),
  .m_axi_bresp(m_axi_bresp),
  .m_axi_bvalid(m_axi_bvalid),
  .m_axi_bready(m_axi_bready));
 always @(posedge clk)begin
  if(!rst_n)begin state<=IDLE;address<=0;length<=0;size<=0;byte_offset<=0;write_data<=0;read_data<=0;rsp_rdata<=0;rsp_fault<=0;end
  else case(state)
   IDLE:if(req_valid)begin
    address<=req_addr;length<=32'd1<<req_size;size<=req_size;byte_offset<=req_addr[2:0];
    write_data<=req_wdata<<(req_addr[2:0]*8);rsp_rdata<=0;rsp_fault<=0;read_data<=0;
    if((req_addr&((32'd1<<req_size)-1))!=0 || ({1'b0,req_addr}+(33'd1<<req_size))>33'h100000000)begin rsp_fault<=1;state<=RESPONSE;end
    else state<=req_write ? WRITE_COMMAND : READ_COMMAND;
   end
   READ_COMMAND:if(r_cmd_ready[0])state<=READ_DATA;
   READ_DATA:begin
    if(r_valid[0])begin read_data<=r_data>>(byte_offset*8);if(r_last)state<=READ_RESPONSE;end
    // A failed read can return no data. Consume the terminal response only
    // after all data already buffered by the DMA has been drained.
    else if(r_rsp_valid[0])state<=READ_RESPONSE;
   end
   READ_RESPONSE:if(r_rsp_valid[0])begin
    rsp_fault<=r_fault;
    case(size)
     0:rsp_rdata<={{56{read_data[7]}},read_data[7:0]};
     1:rsp_rdata<={{48{read_data[15]}},read_data[15:0]};
     2:rsp_rdata<={{32{read_data[31]}},read_data[31:0]};
     default:rsp_rdata<=read_data;
    endcase
    state<=RESPONSE;
   end
   WRITE_COMMAND:if(w_cmd_ready[0])state<=WRITE_DATA;
   WRITE_DATA:if(w_ready[0])state<=WRITE_RESPONSE;
   WRITE_RESPONSE:if(w_rsp_valid[0])begin rsp_fault<=w_fault;state<=RESPONSE;end
   RESPONSE:if(rsp_ready)state<=IDLE;
   default:begin rsp_fault<=1;state<=RESPONSE;end
  endcase
 end
// STALL_DIAGNOSTIC_BEGIN
 generate if(ENABLE_STALL_DIAG)begin:g_stall_diag
 reg [84:0] stall_transport;
 always @*begin
  stall_transport=0;stall_transport[69]=stall_transport_owner[1];
  stall_transport[73]=r_cmd_valid[1]&&r_cmd_ready[1];
 end
 assign stall_dma_events=stall_dma_raw|stall_transport;
 assign stall_dma_bytes=dma_rd_cmd_bytes;
 end else begin:g_no_stall_diag
 assign stall_dma_events=0;assign stall_dma_bytes=0;
 end endgenerate
// STALL_DIAGNOSTIC_END
endmodule
