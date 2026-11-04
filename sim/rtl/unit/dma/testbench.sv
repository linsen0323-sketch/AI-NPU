`timescale 1ns/1ps
module dma_nonempty_case #(parameter integer FIFO=64,RO=4,WO=2,ID=0,DIAG=1,PERF=1,SEED=32'h10293847)(output reg done=0);
reg clk=0; always #5 clk=~clk;
reg  rst_n=0;
reg  stop=0;
reg  rd_cmd_valid=0;
reg [31:0] rd_cmd_addr=0;
reg [31:0] rd_cmd_bytes=0;
reg  rd_ready=0;
reg  rd_rsp_ready=0;
reg  wr_cmd_valid=0;
reg [31:0] wr_cmd_addr=0;
reg [31:0] wr_cmd_bytes=0;
reg  wr_valid=0;
reg [63:0] wr_data=0;
reg [7:0] wr_keep=0;
reg  wr_last=0;
reg  wr_rsp_ready=0;
reg  m_axi_arready=0;
reg [63:0] m_axi_rdata=0;
reg [1:0] m_axi_rresp=0;
reg  m_axi_rlast=0;
reg  m_axi_rvalid=0;
reg  m_axi_awready=0;
reg  m_axi_wready=0;
reg [1:0] m_axi_bresp=0;
reg  m_axi_bvalid=0;
wire [84:0] stall_events,old_stall_events;
wire  rd_cmd_ready,old_rd_cmd_ready;
wire  rd_valid,old_rd_valid;
wire [63:0] rd_data,old_rd_data;
wire [7:0] rd_keep,old_rd_keep;
wire  rd_last,old_rd_last;
wire  rd_rsp_valid,old_rd_rsp_valid;
wire [3:0] rd_fault,old_rd_fault;
wire  wr_cmd_ready,old_wr_cmd_ready;
wire  wr_ready,old_wr_ready;
wire  wr_rsp_valid,old_wr_rsp_valid;
wire [3:0] wr_fault,old_wr_fault;
wire  idle,old_idle;
wire [63:0] read_bytes,old_read_bytes;
wire [63:0] write_bytes,old_write_bytes;
wire [63:0] read_wait_cycles,old_read_wait_cycles;
wire [63:0] write_wait_cycles,old_write_wait_cycles;
wire [31:0] read_bursts,old_read_bursts;
wire [31:0] write_bursts,old_write_bursts;
wire [2:0] max_reads,old_max_reads;
wire [1:0] max_writes,old_max_writes;
wire [31:0] m_axi_araddr,old_m_axi_araddr;
wire [7:0] m_axi_arlen,old_m_axi_arlen;
wire [2:0] m_axi_arsize,old_m_axi_arsize;
wire [1:0] m_axi_arburst,old_m_axi_arburst;
wire  m_axi_arlock,old_m_axi_arlock;
wire [3:0] m_axi_arcache,old_m_axi_arcache;
wire [2:0] m_axi_arprot,old_m_axi_arprot;
wire [3:0] m_axi_arqos,old_m_axi_arqos;
wire  m_axi_arvalid,old_m_axi_arvalid;
wire  m_axi_rready,old_m_axi_rready;
wire [31:0] m_axi_awaddr,old_m_axi_awaddr;
wire [7:0] m_axi_awlen,old_m_axi_awlen;
wire [2:0] m_axi_awsize,old_m_axi_awsize;
wire [1:0] m_axi_awburst,old_m_axi_awburst;
wire  m_axi_awlock,old_m_axi_awlock;
wire [3:0] m_axi_awcache,old_m_axi_awcache;
wire [2:0] m_axi_awprot,old_m_axi_awprot;
wire [3:0] m_axi_awqos,old_m_axi_awqos;
wire  m_axi_awvalid,old_m_axi_awvalid;
wire [63:0] m_axi_wdata,old_m_axi_wdata;
wire [7:0] m_axi_wstrb,old_m_axi_wstrb;
wire  m_axi_wlast,old_m_axi_wlast;
wire  m_axi_wvalid,old_m_axi_wvalid;
wire  m_axi_bready,old_m_axi_bready;
npu_stream_dma_before #(.FIFO_WORDS(FIFO),.READ_OUTSTANDING(RO),.WRITE_OUTSTANDING(WO),.ENABLE_STALL_DIAG(DIAG),.ENABLE_PERF_COUNTERS(PERF)) before_dut(
.stall_events(old_stall_events),
.clk(clk),
.rst_n(rst_n),
.stop(stop),
.rd_cmd_valid(rd_cmd_valid),
.rd_cmd_ready(old_rd_cmd_ready),
.rd_cmd_addr(rd_cmd_addr),
.rd_cmd_bytes(rd_cmd_bytes),
.rd_valid(old_rd_valid),
.rd_ready(rd_ready),
.rd_data(old_rd_data),
.rd_keep(old_rd_keep),
.rd_last(old_rd_last),
.rd_rsp_valid(old_rd_rsp_valid),
.rd_rsp_ready(rd_rsp_ready),
.rd_fault(old_rd_fault),
.wr_cmd_valid(wr_cmd_valid),
.wr_cmd_ready(old_wr_cmd_ready),
.wr_cmd_addr(wr_cmd_addr),
.wr_cmd_bytes(wr_cmd_bytes),
.wr_valid(wr_valid),
.wr_ready(old_wr_ready),
.wr_data(wr_data),
.wr_keep(wr_keep),
.wr_last(wr_last),
.wr_rsp_valid(old_wr_rsp_valid),
.wr_rsp_ready(wr_rsp_ready),
.wr_fault(old_wr_fault),
.idle(old_idle),
.read_bytes(old_read_bytes),
.write_bytes(old_write_bytes),
.read_wait_cycles(old_read_wait_cycles),
.write_wait_cycles(old_write_wait_cycles),
.read_bursts(old_read_bursts),
.write_bursts(old_write_bursts),
.max_reads(old_max_reads),
.max_writes(old_max_writes),
.m_axi_araddr(old_m_axi_araddr),
.m_axi_arlen(old_m_axi_arlen),
.m_axi_arsize(old_m_axi_arsize),
.m_axi_arburst(old_m_axi_arburst),
.m_axi_arlock(old_m_axi_arlock),
.m_axi_arcache(old_m_axi_arcache),
.m_axi_arprot(old_m_axi_arprot),
.m_axi_arqos(old_m_axi_arqos),
.m_axi_arvalid(old_m_axi_arvalid),
.m_axi_arready(m_axi_arready),
.m_axi_rdata(m_axi_rdata),
.m_axi_rresp(m_axi_rresp),
.m_axi_rlast(m_axi_rlast),
.m_axi_rvalid(m_axi_rvalid),
.m_axi_rready(old_m_axi_rready),
.m_axi_awaddr(old_m_axi_awaddr),
.m_axi_awlen(old_m_axi_awlen),
.m_axi_awsize(old_m_axi_awsize),
.m_axi_awburst(old_m_axi_awburst),
.m_axi_awlock(old_m_axi_awlock),
.m_axi_awcache(old_m_axi_awcache),
.m_axi_awprot(old_m_axi_awprot),
.m_axi_awqos(old_m_axi_awqos),
.m_axi_awvalid(old_m_axi_awvalid),
.m_axi_awready(m_axi_awready),
.m_axi_wdata(old_m_axi_wdata),
.m_axi_wstrb(old_m_axi_wstrb),
.m_axi_wlast(old_m_axi_wlast),
.m_axi_wvalid(old_m_axi_wvalid),
.m_axi_wready(m_axi_wready),
.m_axi_bresp(m_axi_bresp),
.m_axi_bvalid(m_axi_bvalid),
.m_axi_bready(old_m_axi_bready));
npu_stream_dma #(.FIFO_WORDS(FIFO),.READ_OUTSTANDING(RO),.WRITE_OUTSTANDING(WO),.ENABLE_STALL_DIAG(DIAG),.ENABLE_PERF_COUNTERS(PERF)) dut(
.stall_events(stall_events),
.clk(clk),
.rst_n(rst_n),
.stop(stop),
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
.idle(idle),
.read_bytes(read_bytes),
.write_bytes(write_bytes),
.read_wait_cycles(read_wait_cycles),
.write_wait_cycles(write_wait_cycles),
.read_bursts(read_bursts),
.write_bursts(write_bursts),
.max_reads(max_reads),
.max_writes(max_writes),
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
integer cycles=0,compared=0,cases=0,full_cycles=0,wfull_cycles=0,credit_cycles=0,both_cycles=0,empty_to_one=0,one_to_empty=0,held_terminal=0,stop_active=0,resets_inflight=0;
integer max_used=0,max_reserved=0,max_r_count=0;
always @(posedge clk) begin
 cycles=cycles+1;
 if(!rst_n && (dut.r_active||dut.w_active))resets_inflight=resets_inflight+1;
 if(rst_n)begin
  if(dut.r_used==FIFO)full_cycles=full_cycles+1;
  if(dut.w_used==FIFO)wfull_cycles=wfull_cycles+1;
  if(dut.r_used+dut.r_reserved==FIFO)credit_cycles=credit_cycles+1;
  if(dut.r_store&&dut.r_pop)both_cycles=both_cycles+1;
  if(dut.r_store&&!dut.r_pop&&dut.r_used==0)empty_to_one=empty_to_one+1;
  if(!dut.r_store&&dut.r_pop&&dut.r_used==1)one_to_empty=one_to_empty+1;
  if((rd_rsp_valid&&!rd_rsp_ready)||(wr_rsp_valid&&!wr_rsp_ready))held_terminal=held_terminal+1;
  if(stop&&(dut.r_active||dut.w_active))stop_active=stop_active+1;
  if(dut.r_used>max_used)max_used=dut.r_used;
  if(dut.r_reserved>max_reserved)max_reserved=dut.r_reserved;
  if(dut.r_count>max_r_count)max_r_count=dut.r_count;
 end
 #1;
 if(dut.r_nonempty !== (dut.r_used!=0))$fatal(1,"nonempty invariant id=%0d cycle=%0d used=%0d flag=%b",ID,cycles,dut.r_used,dut.r_nonempty);
 if({dut.r_used,dut.r_reserved,dut.r_count,dut.rf_head,dut.rf_tail,dut.w_used,dut.w_reserved,dut.w_count,dut.w_responses,dut.wf_head,dut.wf_tail} !== {before_dut.r_used,before_dut.r_reserved,before_dut.r_count,before_dut.rf_head,before_dut.rf_tail,before_dut.w_used,before_dut.w_reserved,before_dut.w_count,before_dut.w_responses,before_dut.wf_head,before_dut.wf_tail})$fatal(1,"state miter id=%0d cycle=%0d",ID,cycles);
 if(rst_n && (dut.r_used>FIFO || dut.r_used+dut.r_reserved>FIFO || dut.r_count>RO || dut.w_used>FIFO))$fatal(1,"credit bounds id=%0d cycle=%0d",ID,cycles);
 if(stall_events !== old_stall_events)$fatal(1,"public output stall_events id=%0d cycle=%0d new=%h old=%h",ID,cycles,stall_events,old_stall_events);
 if(rd_cmd_ready !== old_rd_cmd_ready)$fatal(1,"public output rd_cmd_ready id=%0d cycle=%0d new=%h old=%h",ID,cycles,rd_cmd_ready,old_rd_cmd_ready);
 if(rd_valid !== old_rd_valid)$fatal(1,"public output rd_valid id=%0d cycle=%0d new=%h old=%h",ID,cycles,rd_valid,old_rd_valid);
 if(rd_data !== old_rd_data)$fatal(1,"public output rd_data id=%0d cycle=%0d new=%h old=%h",ID,cycles,rd_data,old_rd_data);
 if(rd_keep !== old_rd_keep)$fatal(1,"public output rd_keep id=%0d cycle=%0d new=%h old=%h",ID,cycles,rd_keep,old_rd_keep);
 if(rd_last !== old_rd_last)$fatal(1,"public output rd_last id=%0d cycle=%0d new=%h old=%h",ID,cycles,rd_last,old_rd_last);
 if(rd_rsp_valid !== old_rd_rsp_valid)$fatal(1,"public output rd_rsp_valid id=%0d cycle=%0d new=%h old=%h",ID,cycles,rd_rsp_valid,old_rd_rsp_valid);
 if(rd_fault !== old_rd_fault)$fatal(1,"public output rd_fault id=%0d cycle=%0d new=%h old=%h",ID,cycles,rd_fault,old_rd_fault);
 if(wr_cmd_ready !== old_wr_cmd_ready)$fatal(1,"public output wr_cmd_ready id=%0d cycle=%0d new=%h old=%h",ID,cycles,wr_cmd_ready,old_wr_cmd_ready);
 if(wr_ready !== old_wr_ready)$fatal(1,"public output wr_ready id=%0d cycle=%0d new=%h old=%h",ID,cycles,wr_ready,old_wr_ready);
 if(wr_rsp_valid !== old_wr_rsp_valid)$fatal(1,"public output wr_rsp_valid id=%0d cycle=%0d new=%h old=%h",ID,cycles,wr_rsp_valid,old_wr_rsp_valid);
 if(wr_fault !== old_wr_fault)$fatal(1,"public output wr_fault id=%0d cycle=%0d new=%h old=%h",ID,cycles,wr_fault,old_wr_fault);
 if(idle !== old_idle)$fatal(1,"public output idle id=%0d cycle=%0d new=%h old=%h",ID,cycles,idle,old_idle);
 if(read_bytes !== old_read_bytes)$fatal(1,"public output read_bytes id=%0d cycle=%0d new=%h old=%h",ID,cycles,read_bytes,old_read_bytes);
 if(write_bytes !== old_write_bytes)$fatal(1,"public output write_bytes id=%0d cycle=%0d new=%h old=%h",ID,cycles,write_bytes,old_write_bytes);
 if(read_wait_cycles !== old_read_wait_cycles)$fatal(1,"public output read_wait_cycles id=%0d cycle=%0d new=%h old=%h",ID,cycles,read_wait_cycles,old_read_wait_cycles);
 if(write_wait_cycles !== old_write_wait_cycles)$fatal(1,"public output write_wait_cycles id=%0d cycle=%0d new=%h old=%h",ID,cycles,write_wait_cycles,old_write_wait_cycles);
 if(read_bursts !== old_read_bursts)$fatal(1,"public output read_bursts id=%0d cycle=%0d new=%h old=%h",ID,cycles,read_bursts,old_read_bursts);
 if(write_bursts !== old_write_bursts)$fatal(1,"public output write_bursts id=%0d cycle=%0d new=%h old=%h",ID,cycles,write_bursts,old_write_bursts);
 if(max_reads !== old_max_reads)$fatal(1,"public output max_reads id=%0d cycle=%0d new=%h old=%h",ID,cycles,max_reads,old_max_reads);
 if(max_writes !== old_max_writes)$fatal(1,"public output max_writes id=%0d cycle=%0d new=%h old=%h",ID,cycles,max_writes,old_max_writes);
 if(m_axi_araddr !== old_m_axi_araddr)$fatal(1,"public output m_axi_araddr id=%0d cycle=%0d new=%h old=%h",ID,cycles,m_axi_araddr,old_m_axi_araddr);
 if(m_axi_arlen !== old_m_axi_arlen)$fatal(1,"public output m_axi_arlen id=%0d cycle=%0d new=%h old=%h",ID,cycles,m_axi_arlen,old_m_axi_arlen);
 if(m_axi_arsize !== old_m_axi_arsize)$fatal(1,"public output m_axi_arsize id=%0d cycle=%0d new=%h old=%h",ID,cycles,m_axi_arsize,old_m_axi_arsize);
 if(m_axi_arburst !== old_m_axi_arburst)$fatal(1,"public output m_axi_arburst id=%0d cycle=%0d new=%h old=%h",ID,cycles,m_axi_arburst,old_m_axi_arburst);
 if(m_axi_arlock !== old_m_axi_arlock)$fatal(1,"public output m_axi_arlock id=%0d cycle=%0d new=%h old=%h",ID,cycles,m_axi_arlock,old_m_axi_arlock);
 if(m_axi_arcache !== old_m_axi_arcache)$fatal(1,"public output m_axi_arcache id=%0d cycle=%0d new=%h old=%h",ID,cycles,m_axi_arcache,old_m_axi_arcache);
 if(m_axi_arprot !== old_m_axi_arprot)$fatal(1,"public output m_axi_arprot id=%0d cycle=%0d new=%h old=%h",ID,cycles,m_axi_arprot,old_m_axi_arprot);
 if(m_axi_arqos !== old_m_axi_arqos)$fatal(1,"public output m_axi_arqos id=%0d cycle=%0d new=%h old=%h",ID,cycles,m_axi_arqos,old_m_axi_arqos);
 if(m_axi_arvalid !== old_m_axi_arvalid)$fatal(1,"public output m_axi_arvalid id=%0d cycle=%0d new=%h old=%h",ID,cycles,m_axi_arvalid,old_m_axi_arvalid);
 if(m_axi_rready !== old_m_axi_rready)$fatal(1,"public output m_axi_rready id=%0d cycle=%0d new=%h old=%h",ID,cycles,m_axi_rready,old_m_axi_rready);
 if(m_axi_awaddr !== old_m_axi_awaddr)$fatal(1,"public output m_axi_awaddr id=%0d cycle=%0d new=%h old=%h",ID,cycles,m_axi_awaddr,old_m_axi_awaddr);
 if(m_axi_awlen !== old_m_axi_awlen)$fatal(1,"public output m_axi_awlen id=%0d cycle=%0d new=%h old=%h",ID,cycles,m_axi_awlen,old_m_axi_awlen);
 if(m_axi_awsize !== old_m_axi_awsize)$fatal(1,"public output m_axi_awsize id=%0d cycle=%0d new=%h old=%h",ID,cycles,m_axi_awsize,old_m_axi_awsize);
 if(m_axi_awburst !== old_m_axi_awburst)$fatal(1,"public output m_axi_awburst id=%0d cycle=%0d new=%h old=%h",ID,cycles,m_axi_awburst,old_m_axi_awburst);
 if(m_axi_awlock !== old_m_axi_awlock)$fatal(1,"public output m_axi_awlock id=%0d cycle=%0d new=%h old=%h",ID,cycles,m_axi_awlock,old_m_axi_awlock);
 if(m_axi_awcache !== old_m_axi_awcache)$fatal(1,"public output m_axi_awcache id=%0d cycle=%0d new=%h old=%h",ID,cycles,m_axi_awcache,old_m_axi_awcache);
 if(m_axi_awprot !== old_m_axi_awprot)$fatal(1,"public output m_axi_awprot id=%0d cycle=%0d new=%h old=%h",ID,cycles,m_axi_awprot,old_m_axi_awprot);
 if(m_axi_awqos !== old_m_axi_awqos)$fatal(1,"public output m_axi_awqos id=%0d cycle=%0d new=%h old=%h",ID,cycles,m_axi_awqos,old_m_axi_awqos);
 if(m_axi_awvalid !== old_m_axi_awvalid)$fatal(1,"public output m_axi_awvalid id=%0d cycle=%0d new=%h old=%h",ID,cycles,m_axi_awvalid,old_m_axi_awvalid);
 if(m_axi_wdata !== old_m_axi_wdata)$fatal(1,"public output m_axi_wdata id=%0d cycle=%0d new=%h old=%h",ID,cycles,m_axi_wdata,old_m_axi_wdata);
 if(m_axi_wstrb !== old_m_axi_wstrb)$fatal(1,"public output m_axi_wstrb id=%0d cycle=%0d new=%h old=%h",ID,cycles,m_axi_wstrb,old_m_axi_wstrb);
 if(m_axi_wlast !== old_m_axi_wlast)$fatal(1,"public output m_axi_wlast id=%0d cycle=%0d new=%h old=%h",ID,cycles,m_axi_wlast,old_m_axi_wlast);
 if(m_axi_wvalid !== old_m_axi_wvalid)$fatal(1,"public output m_axi_wvalid id=%0d cycle=%0d new=%h old=%h",ID,cycles,m_axi_wvalid,old_m_axi_wvalid);
 if(m_axi_bready !== old_m_axi_bready)$fatal(1,"public output m_axi_bready id=%0d cycle=%0d new=%h old=%h",ID,cycles,m_axi_bready,old_m_axi_bready);
 compared=compared+1;
end
`include "dma_environment.svh"
endmodule

module tb_dma_nonempty;
wire [5:0] done;
dma_nonempty_case #(.FIFO(16),.RO(1),.WO(1),.ID(0),.DIAG(1),.PERF(1),.SEED(32'h10293847)) c0(done[0]);
dma_nonempty_case #(.FIFO(32),.RO(2),.WO(2),.ID(1),.DIAG(1),.PERF(1),.SEED(32'h103c5c5a)) c1(done[1]);
dma_nonempty_case #(.FIFO(64),.RO(4),.WO(2),.ID(2),.DIAG(1),.PERF(1),.SEED(32'h104f806d)) c2(done[2]);
dma_nonempty_case #(.FIFO(128),.RO(4),.WO(2),.ID(3),.DIAG(1),.PERF(1),.SEED(32'h1062a480)) c3(done[3]);
dma_nonempty_case #(.FIFO(64),.RO(3),.WO(2),.ID(4),.DIAG(1),.PERF(1),.SEED(32'h1075c893)) c4(done[4]);
dma_nonempty_case #(.FIFO(16),.RO(2),.WO(1),.ID(5),.DIAG(0),.PERF(0),.SEED(32'h1088eca6)) c5(done[5]);
initial begin wait(&done);$display("TEST_PASS dma_nonempty configurations=6 public_outputs=45");$finish;end
initial begin #2000000;$fatal(1,"global watchdog");end
endmodule
