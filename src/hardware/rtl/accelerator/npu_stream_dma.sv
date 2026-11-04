`timescale 1ns/1ps
// Ordered AXI4 bulk transport. One streaming descriptor in each direction;
// up to four read bursts and two writes are independently in flight. All IDs
// are the same, therefore AXI ordering supplies response/descriptor matching.
// 64-word receive credit includes both buffered and not-yet-returned data.
// Accepted descriptors always drain; stop gates NEW descriptors only.
module npu_stream_dma #(
 parameter integer READ_OUTSTANDING=4, WRITE_OUTSTANDING=2,
 parameter integer FIFO_WORDS=64,
 parameter bit ENABLE_STALL_DIAG=1'b1,ENABLE_PERF_COUNTERS=1'b1
)(
 output reg [84:0] stall_events,
 input wire clk,rst_n,stop,
 input wire rd_cmd_valid,output wire rd_cmd_ready,
 input wire [31:0] rd_cmd_addr,rd_cmd_bytes,
 output wire rd_valid,input wire rd_ready,output wire [63:0] rd_data,
 output wire [7:0] rd_keep,output wire rd_last,
 output reg rd_rsp_valid,input wire rd_rsp_ready,output reg [3:0] rd_fault,
 input wire wr_cmd_valid,output wire wr_cmd_ready,
 input wire [31:0] wr_cmd_addr,wr_cmd_bytes,
 input wire wr_valid,output wire wr_ready,input wire [63:0] wr_data,
 input wire [7:0] wr_keep,input wire wr_last,
 output reg wr_rsp_valid,input wire wr_rsp_ready,output reg [3:0] wr_fault,
 output wire idle,output reg [63:0] read_bytes,write_bytes,
 output reg [63:0] read_wait_cycles,write_wait_cycles,
 output reg [31:0] read_bursts,write_bursts,
 output reg [2:0] max_reads,output reg [1:0] max_writes,
 output reg [31:0] m_axi_araddr,output reg [7:0] m_axi_arlen,
 output wire [2:0] m_axi_arsize,output wire [1:0] m_axi_arburst,
 output wire m_axi_arlock,output wire [3:0] m_axi_arcache,
 output wire [2:0] m_axi_arprot,output wire [3:0] m_axi_arqos,
 output reg m_axi_arvalid,input wire m_axi_arready,
 input wire [63:0] m_axi_rdata,input wire [1:0] m_axi_rresp,
 input wire m_axi_rlast,m_axi_rvalid,output wire m_axi_rready,
 output reg [31:0] m_axi_awaddr,output reg [7:0] m_axi_awlen,
 output wire [2:0] m_axi_awsize,output wire [1:0] m_axi_awburst,
 output wire m_axi_awlock,output wire [3:0] m_axi_awcache,
 output wire [2:0] m_axi_awprot,output wire [3:0] m_axi_awqos,
 output reg m_axi_awvalid,input wire m_axi_awready,
 output wire [63:0] m_axi_wdata,output wire [7:0] m_axi_wstrb,
 output wire m_axi_wlast,m_axi_wvalid,input wire m_axi_wready,
 input wire [1:0] m_axi_bresp,input wire m_axi_bvalid,output wire m_axi_bready
);
 localparam integer FW=$clog2(FIFO_WORDS), RW=(READ_OUTSTANDING>1 ? $clog2(READ_OUTSTANDING) : 1),
                    WW=(WRITE_OUTSTANDING>1 ? $clog2(WRITE_OUTSTANDING) : 1);
 reg r_active,r_abort,w_active,w_abort,w_input_done;
 reg [32:0] r_begin,r_end,w_begin,w_end;
 reg [32:0] r_issue,r_receive,w_issue,w_input;
 reg [31:0] r_left,w_left;
 reg [RW-1:0] rq_head,rq_tail;
 reg [WW-1:0] wq_head,wq_tail;
 reg [4:0] rq_beats[0:READ_OUTSTANDING-1],wq_beats[0:WRITE_OUTSTANDING-1];
 reg [RW:0] r_count;
 reg [WW:0] w_count,w_responses;
 reg [FW:0] r_used,r_reserved,w_used,w_reserved;
 // A redundant occupancy predicate shares the receive FIFO's update edges.
 // Keep its multibit reduction out of the downstream stream-valid cone.
 reg r_nonempty;
 reg [FW-1:0] rf_head,rf_tail,wf_head,wf_tail;
 (* ram_style="distributed" *) reg [63:0] rf_data[0:FIFO_WORDS-1],wf_data[0:FIFO_WORDS-1];
 (* ram_style="distributed" *) reg [7:0] rf_keep[0:FIFO_WORDS-1],wf_keep[0:FIFO_WORDS-1];
 reg [FIFO_WORDS-1:0] rf_last;
 wire ar_fire=m_axi_arvalid&&m_axi_arready;
 wire aw_fire=m_axi_awvalid&&m_axi_awready;
 wire r_fire=m_axi_rvalid&&m_axi_rready;
 wire w_fire=m_axi_wvalid&&m_axi_wready;
 wire b_fire=m_axi_bvalid&&m_axi_bready;
 wire r_pop=rd_valid&&rd_ready;
 wire w_push=wr_valid&&wr_ready;
 wire r_expected=r_count!=0 && rq_beats[rq_head]!=0;
 wire r_store=r_fire&&r_expected;
 wire r_complete=r_fire&&m_axi_rlast;
 wire w_complete=w_fire&&m_axi_wlast;
 reg [4:0] r_next_beats,w_next_beats;
 reg [4:0] r_candidate_beats,w_candidate_beats;
 reg r_plan_valid,w_plan_valid;
 reg [7:0] r_mask,w_mask;
 reg [4:0] r_short_release;
 // Both byte counters are aligned at admission and advance by eight.
 wire r_word_after_begin=r_receive[32:3]>r_begin[32:3];
 wire r_word_at_begin=r_receive[32:3]==r_begin[32:3];
 wire r_word_before_end=r_receive[32:3]<r_end[32:3];
 wire r_word_at_end=r_receive[32:3]==r_end[32:3];
 wire w_word_after_begin=w_input[32:3]>w_begin[32:3];
 wire w_word_at_begin=w_input[32:3]==w_begin[32:3];
 wire w_word_before_end=w_input[32:3]<w_end[32:3];
 wire w_word_at_end=w_input[32:3]==w_end[32:3];
 integer n;
 always @* begin
  r_candidate_beats=r_left>=16 ? 5'd16 : r_left[4:0];
  if(r_candidate_beats>((13'd4096-{1'b0,r_issue[11:0]})>>3))
   r_candidate_beats=(13'd4096-{1'b0,r_issue[11:0]})>>3;
  w_candidate_beats=w_left>=16 ? 5'd16 : w_left[4:0];
  if(w_candidate_beats>((13'd4096-{1'b0,w_issue[11:0]})>>3))
   w_candidate_beats=(13'd4096-{1'b0,w_issue[11:0]})>>3;
  r_mask=0;w_mask=0;
  for(integer k=0;k<8;k=k+1) begin
   r_mask[k]=(r_word_after_begin || (r_word_at_begin && 3'(k)>=r_begin[2:0])) &&
    (r_word_before_end || (r_word_at_end && 3'(k)<r_end[2:0]));
   w_mask[k]=(w_word_after_begin || (w_word_at_begin && 3'(k)>=w_begin[2:0])) &&
    (w_word_before_end || (w_word_at_end && 3'(k)<w_end[2:0]));
  end
  r_short_release=(r_complete && r_expected && rq_beats[rq_head]>1) ? rq_beats[rq_head]-1'b1 : 0;
 end
 assign rd_cmd_ready=rst_n&&!stop&&!r_active&&!rd_rsp_valid;
 assign wr_cmd_ready=rst_n&&!stop&&!w_active&&!wr_rsp_valid;
 assign rd_valid=rst_n&&r_nonempty;
 assign rd_data=rf_data[rf_head];assign rd_keep=rf_keep[rf_head];assign rd_last=rf_last[rf_head];
 assign wr_ready=rst_n&&w_active&&!w_input_done&&!w_abort&&w_used<FIFO_WORDS;
 assign m_axi_rready=rst_n&&r_active&&r_count!=0&&(!r_expected || r_used<FIFO_WORDS);
 assign m_axi_wvalid=rst_n&&w_count!=0&&w_used!=0;
 assign m_axi_wdata=wf_data[wf_head];assign m_axi_wstrb=wf_keep[wf_head];
 assign m_axi_wlast=w_count!=0&&wq_beats[wq_head]==1;
 assign m_axi_bready=rst_n&&w_active&&w_responses!=0;
 assign m_axi_arsize=3'd3;assign m_axi_awsize=3'd3;
 assign m_axi_arburst=2'b01;assign m_axi_awburst=2'b01;
 assign m_axi_arlock=0;assign m_axi_awlock=0;
 assign m_axi_arcache=4'b0011;assign m_axi_awcache=4'b0011;
 assign m_axi_arprot=0;assign m_axi_awprot=0;
 assign m_axi_arqos=0;assign m_axi_awqos=0;
 assign idle=rst_n&&!r_active&&!w_active&&!rd_rsp_valid&&!wr_rsp_valid&&
  !m_axi_arvalid&&!m_axi_awvalid&&r_count==0&&w_count==0&&w_responses==0;
 always @(posedge clk) begin
  if(!rst_n) begin
   r_active<=0;r_abort<=0;w_active<=0;w_abort<=0;w_input_done<=0;
   r_plan_valid<=0;w_plan_valid<=0;
   r_begin<=0;r_end<=0;r_issue<=0;r_receive<=0;r_left<=0;
   w_begin<=0;w_end<=0;w_issue<=0;w_input<=0;w_left<=0;
   rq_head<=0;rq_tail<=0;wq_head<=0;wq_tail<=0;
   r_count<=0;w_count<=0;w_responses<=0;r_used<=0;r_nonempty<=0;r_reserved<=0;w_used<=0;w_reserved<=0;
   rf_head<=0;rf_tail<=0;wf_head<=0;wf_tail<=0;rf_last<=0;
   m_axi_araddr<=0;m_axi_arlen<=0;m_axi_arvalid<=0;
   m_axi_awaddr<=0;m_axi_awlen<=0;m_axi_awvalid<=0;
   rd_rsp_valid<=0;rd_fault<=0;wr_rsp_valid<=0;wr_fault<=0;
   for(n=0;n<READ_OUTSTANDING;n=n+1) rq_beats[n]<=0;
   for(n=0;n<WRITE_OUTSTANDING;n=n+1) wq_beats[n]<=0;
  end else begin
   if(rd_rsp_valid&&rd_rsp_ready) rd_rsp_valid<=0;
   if(wr_rsp_valid&&wr_rsp_ready) wr_rsp_valid<=0;
   if(rd_cmd_valid&&rd_cmd_ready) begin
    r_plan_valid<=0;
    rd_fault<=0;r_abort<=0;rf_head<=0;rf_tail<=0;r_used<=0;r_nonempty<=0;r_reserved<=0;
    // Inactive payload is unobservable; capture independently of the verdict.
    r_begin<={1'b0,rd_cmd_addr};r_end<={1'b0,rd_cmd_addr}+{1'b0,rd_cmd_bytes};
    r_issue<={1'b0,rd_cmd_addr[31:3],3'b000};r_receive<={1'b0,rd_cmd_addr[31:3],3'b000};
    r_left<=({1'b0,rd_cmd_bytes}+{30'd0,rd_cmd_addr[2:0]}+33'd7)>>3;
    if(rd_cmd_bytes==0 || ({1'b0,rd_cmd_addr}+{1'b0,rd_cmd_bytes})>33'h100000000) begin
     rd_rsp_valid<=1;rd_fault<=4'b0010;
    end else begin
     r_active<=1;
    end
   end
   if(r_active) begin
    // The issue address/remaining count stay fixed until this plan handshakes.
    if(!m_axi_arvalid&&!r_plan_valid&&r_left!=0&&!r_abort)begin
     r_next_beats<=r_candidate_beats;r_plan_valid<=1;
    end
    if(r_plan_valid&&!m_axi_arvalid&&!r_abort&&r_left!=0&&r_count<READ_OUTSTANDING&&
       r_used+r_reserved+r_next_beats<=FIFO_WORDS) begin
     m_axi_araddr<=r_issue[31:0];m_axi_arlen<=r_next_beats-1'b1;m_axi_arvalid<=1;
    end
    if(ar_fire) begin
     r_plan_valid<=0;
     m_axi_arvalid<=0;r_issue<=r_issue+(({25'd0,m_axi_arlen}+33'd1)<<3);
     r_left<=r_left-({24'd0,m_axi_arlen}+32'd1);
     rq_beats[rq_tail]<=m_axi_arlen+1'b1;rq_tail<=rq_tail==READ_OUTSTANDING-1 ? 0 : rq_tail+1'b1;
    end
    case({ar_fire,r_complete})
     2'b10:r_count<=r_count+1'b1;2'b01:r_count<=r_count-1'b1;default:;
    endcase
    if(r_fire) begin
     if(m_axi_rresp!=0 || m_axi_rlast!=(r_expected&&rq_beats[rq_head]==1)) begin
      rd_fault<=rd_fault|(m_axi_rresp!=0 ? 4'b0100:4'b0000)|
        (m_axi_rlast!=(r_expected&&rq_beats[rq_head]==1) ? 4'b1000:4'b0000);r_abort<=1;
     end
     if(r_expected) begin
      rq_beats[rq_head]<=rq_beats[rq_head]-1'b1;
      rf_data[rf_tail]<=m_axi_rdata;rf_keep[rf_tail]<=r_mask;
      rf_last[rf_tail]<=r_receive+8>=r_end;rf_tail<=rf_tail+1'b1;r_receive<=r_receive+8;
     end
     if(m_axi_rlast) rq_head<=rq_head==READ_OUTSTANDING-1 ? 0 : rq_head+1'b1;
    end
    r_reserved<=r_reserved+(ar_fire ? {1'b0,m_axi_arlen}+9'd1 : 9'd0)-
      (r_store ? 9'd1 : 9'd0)-{4'd0,r_short_release};
    case({r_store,r_pop})
     2'b10:begin r_used<=r_used+1'b1;r_nonempty<=1'b1;end
     2'b01:begin r_used<=r_used-1'b1;r_nonempty<=r_used!=1;end
     default:;
    endcase
    if(r_pop) rf_head<=rf_head+1'b1;
    if((r_left==0||r_abort)&&!m_axi_arvalid&&r_count==0&&r_used==0) begin
     r_active<=0;rd_rsp_valid<=1;
    end
   end
   if(wr_cmd_valid&&wr_cmd_ready) begin
    w_plan_valid<=0;
    wr_fault<=0;w_abort<=0;w_input_done<=0;wf_head<=0;wf_tail<=0;w_used<=0;w_reserved<=0;
    w_begin<={1'b0,wr_cmd_addr};w_end<={1'b0,wr_cmd_addr}+{1'b0,wr_cmd_bytes};
    w_issue<={1'b0,wr_cmd_addr[31:3],3'b000};w_input<={1'b0,wr_cmd_addr[31:3],3'b000};
    w_left<=({1'b0,wr_cmd_bytes}+{30'd0,wr_cmd_addr[2:0]}+33'd7)>>3;
    if(wr_cmd_bytes==0 || ({1'b0,wr_cmd_addr}+{1'b0,wr_cmd_bytes})>33'h100000000) begin
     wr_rsp_valid<=1;wr_fault<=4'b0010;
    end else begin
     w_active<=1;
    end
   end
   if(w_active) begin
    if(!m_axi_awvalid&&!w_plan_valid&&w_left!=0&&!w_abort)begin
     w_next_beats<=w_candidate_beats;w_plan_valid<=1;
    end
    if(w_push) begin
     wf_data[wf_tail]<=wr_data;wf_keep[wf_tail]<=wr_keep&w_mask;wf_tail<=wf_tail+1'b1;w_input<=w_input+8;
     if(wr_last!=(w_input+8>=w_end)) begin wr_fault<=wr_fault|4'b1000;w_abort<=1;end
     if(wr_last||w_input+8>=w_end) w_input_done<=1;
    end
    if(w_plan_valid&&!m_axi_awvalid&&!w_abort&&w_left!=0&&w_responses<WRITE_OUTSTANDING&&
       w_count<WRITE_OUTSTANDING&&w_used>=w_reserved+w_next_beats) begin
     m_axi_awaddr<=w_issue[31:0];m_axi_awlen<=w_next_beats-1'b1;m_axi_awvalid<=1;
    end
    if(aw_fire) begin
     w_plan_valid<=0;
     m_axi_awvalid<=0;w_issue<=w_issue+(({25'd0,m_axi_awlen}+33'd1)<<3);
     w_left<=w_left-({24'd0,m_axi_awlen}+32'd1);
     wq_beats[wq_tail]<=m_axi_awlen+1'b1;wq_tail<=wq_tail==WRITE_OUTSTANDING-1 ? 0 : wq_tail+1'b1;
    end
    case({aw_fire,w_complete})
     2'b10:w_count<=w_count+1'b1;2'b01:w_count<=w_count-1'b1;default:;
    endcase
    case({aw_fire,b_fire})
     2'b10:w_responses<=w_responses+1'b1;2'b01:w_responses<=w_responses-1'b1;default:;
    endcase
    if(w_fire) begin
     wf_head<=wf_head+1'b1;wq_beats[wq_head]<=wq_beats[wq_head]-1'b1;
     if(m_axi_wlast) wq_head<=wq_head==WRITE_OUTSTANDING-1 ? 0 : wq_head+1'b1;
    end
    w_reserved<=w_reserved+(aw_fire ? {1'b0,m_axi_awlen}+9'd1 : 9'd0)-(w_fire ? 9'd1 : 9'd0);
    case({w_push,w_fire})
     2'b10:w_used<=w_used+1'b1;2'b01:w_used<=w_used-1'b1;default:;
    endcase
    if(b_fire && m_axi_bresp!=0) begin
     wr_fault<=wr_fault|4'b0100|((w_push&&wr_last!=(w_input+8>=w_end)) ? 4'b1000 : 4'b0000);w_abort<=1;
    end
    if((w_left==0||w_abort)&&!m_axi_awvalid&&w_count==0&&w_responses==0&&
       (w_input_done||w_abort)) begin
     w_active<=0;w_used<=0;wr_rsp_valid<=1;
    end
   end
  end
 end
 // Passive statistics have no execution feedback. Functional credit,
 // FIFO, fault, framing and terminal-response state remains above.
 generate if(ENABLE_PERF_COUNTERS)begin:g_perf_counters
  always @(posedge clk)begin
   if(!rst_n)begin
    read_bytes<=0;write_bytes<=0;read_wait_cycles<=0;write_wait_cycles<=0;
    read_bursts<=0;write_bursts<=0;max_reads<=0;max_writes<=0;
   end else begin
    if(r_count>max_reads)max_reads<=r_count;
    if(w_responses>max_writes)max_writes<=w_responses;
    if(r_active && ((!rd_valid&&rd_ready)||m_axi_arvalid&&!m_axi_arready))read_wait_cycles<=read_wait_cycles+1'b1;
    if(w_active && ((!m_axi_wready&&m_axi_wvalid)||m_axi_awvalid&&!m_axi_awready))write_wait_cycles<=write_wait_cycles+1'b1;
    if(r_active&&ar_fire)read_bursts<=read_bursts+1'b1;
    if(w_active&&aw_fire)write_bursts<=write_bursts+1'b1;
    if(r_active&&r_fire&&r_expected)read_bytes<=read_bytes+8;
    if(w_active&&w_fire)write_bytes<=write_bytes+8;
   end
  end
 end else begin:g_no_perf_counters
  assign read_bytes=0;assign write_bytes=0;assign read_wait_cycles=0;assign write_wait_cycles=0;
  assign read_bursts=0;assign write_bursts=0;assign max_reads=0;assign max_writes=0;
 end endgenerate
// STALL_DIAGNOSTIC_BEGIN
 generate if(ENABLE_STALL_DIAG)begin:g_stall_diag
 wire stall_credit=r_active&&r_plan_valid&&!m_axi_arvalid&&!r_abort&&r_left!=0&&
    (r_count>=READ_OUTSTANDING||r_used+r_reserved+r_next_beats>FIFO_WORDS);
 wire stall_tail=r_active&&r_left==0&&!m_axi_arvalid&&r_count==0&&r_used==0;
 always @*begin
  stall_events=0;
  stall_events[27]=r_active&&r_used==FIFO_WORDS;
  stall_events[49]=stall_credit;
  stall_events[51]=rd_cmd_valid&&rd_cmd_ready;
  stall_events[52]=rd_rsp_valid&&rd_rsp_ready;
  stall_events[53]=stall_events[51];
  stall_events[54]=ar_fire;
  stall_events[55]=r_fire;
  stall_events[56]=r_active||rd_rsp_valid;
  stall_events[74]=m_axi_rvalid&&!m_axi_rready;
  // Raw predicates intentionally overlap; priority buckets alone cannot
  // expose simultaneous DDR starvation, credit limits and backpressure.
  stall_events[80]=r_active&&m_axi_arvalid&&!m_axi_arready;
  stall_events[81]=r_active&&r_count!=0&&r_used==0&&!m_axi_rvalid;
  stall_events[82]=r_active&&rd_valid&&!rd_ready;
  stall_events[83]=r_active&&r_plan_valid&&!m_axi_arvalid&&!r_abort&&r_left!=0&&r_count>=READ_OUTSTANDING;
  stall_events[84]=r_active&&r_plan_valid&&!m_axi_arvalid&&!r_abort&&r_left!=0&&r_used+r_reserved+r_next_beats>FIFO_WORDS;
  // Priority partition of read-busy. Raw full/credit predicates are separate.
  if(stall_events[56])begin
   if(rd_rsp_valid)stall_events[64]=1;
   else if(rd_valid&&!rd_ready)stall_events[61]=1;
   else if(r_used==FIFO_WORDS)stall_events[58]=1;
   else if(m_axi_arvalid&&!m_axi_arready)stall_events[59]=1;
   else if(stall_credit)stall_events[57]=1;
   else if(r_used==0&&r_count!=0&&!m_axi_rvalid)stall_events[60]=1;
   else if(stall_tail)stall_events[65]=1;
   else if(r_left!=0)stall_events[62]=1;
   else stall_events[63]=1;
  end
 end
 end else begin:g_no_stall_diag
 assign stall_events=0;
 end endgenerate
// STALL_DIAGNOSTIC_END
endmodule
