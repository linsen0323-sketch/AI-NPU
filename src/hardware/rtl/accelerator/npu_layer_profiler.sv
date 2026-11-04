`timescale 1ns/1ps
// One-shot, passive graph-instruction trace. Never drives execution readiness.
// One 256-bit BRAM row per instruction, frozen after graph completion. Payload
// RAM has no reset; count/ready make old and uninitialised rows inaccessible.
module npu_layer_profiler (
 input wire clk,rst_n,arm,graph_start,graph_done,
 input wire [31:0] start_frame,start_generation,done_task,
 input wire op_start,op_done,input wire [31:0] op_index,
 input wire pe_vector,input wire [4:0] conv_events,
 input wire read_cmd,write_cmd,input wire [31:0] read_bytes,write_bytes,
 input wire [11:0] select_word,
 output wire [31:0] read_data,status,
 output reg [31:0] frame,generation,task_id
);
 reg armed,capturing,ready,overflow,op_active;
 reg [9:0] count;
 reg [31:0] index_q,elapsed,vectors,input_wait,output_wait,reads,writes;
 reg [15:0] loads,hits;
 // Isolate execution predicates from counter carry chains and BRAM inputs.
 // Sample the ENTIRE observation stream together, including arm/start/done
 // and metadata, so the instruction interval and terminal-cycle events stay
 // exact. None of these registers feeds an execution ready/valid signal.
 reg arm_sample,start_sample,done_sample,op_start_sample,op_done_sample;
 reg vector_sample,read_sample,write_sample;
 reg [4:0] events_sample;
 reg [31:0] frame_sample,generation_sample,task_sample,index_sample;
 reg [31:0] read_bytes_sample,write_bytes_sample;
 always @(posedge clk)begin
  if(!rst_n)begin
   arm_sample<=0;start_sample<=0;done_sample<=0;op_start_sample<=0;op_done_sample<=0;
   vector_sample<=0;read_sample<=0;write_sample<=0;events_sample<=0;
  end else begin
   arm_sample<=arm;start_sample<=graph_start;done_sample<=graph_done;
   op_start_sample<=op_start;op_done_sample<=op_done;vector_sample<=pe_vector;
   read_sample<=read_cmd;write_sample<=write_cmd;events_sample<=conv_events;
  end
  frame_sample<=start_frame;generation_sample<=start_generation;task_sample<=done_task;index_sample<=op_index;
  read_bytes_sample<=read_bytes;write_bytes_sample<=write_bytes;
 end
 (* ram_style="block" *) reg [255:0] trace[0:511];
 reg [255:0] trace_q;
 reg [2:0] word_q;
 wire [31:0] next_elapsed=elapsed+1'b1;
 wire [31:0] next_vectors=vectors+vector_sample;
 wire [31:0] next_input=input_wait+events_sample[1];
 wire [31:0] next_output=output_wait+events_sample[2];
 wire [31:0] next_reads=reads+(read_sample?read_bytes_sample:32'd0);
 wire [31:0] next_writes=writes+(write_sample?write_bytes_sample:32'd0);
 wire [15:0] next_loads=loads+{15'd0,(events_sample[3] && loads!=16'hffff)};
 wire [15:0] next_hits=hits+{15'd0,(events_sample[4] && hits!=16'hffff)};
 wire commit=capturing&&op_active&&op_done_sample;
 assign status={12'd0,overflow,ready,capturing,armed,6'd0,count};
 assign read_data=ready&&{1'b0,select_word[11:3]}<count ? trace_q[word_q*32+:32] : 32'd0;
 always @(posedge clk)begin
  if(commit && count<512)
   trace[count[8:0]]<={next_hits,next_loads,next_writes,next_reads,next_output,next_input,next_vectors,next_elapsed,index_q};
  trace_q<=trace[select_word[11:3]];
  word_q<=select_word[2:0];
 end
 always @(posedge clk)begin
  if(!rst_n)begin
   armed<=0;capturing<=0;ready<=0;overflow<=0;op_active<=0;count<=0;
   frame<=0;generation<=0;task_id<=0;index_q<=0;
   elapsed<=0;vectors<=0;input_wait<=0;output_wait<=0;reads<=0;writes<=0;loads<=0;hits<=0;
  end else begin
   if(arm_sample&&!capturing)begin armed<=1;ready<=0;end
   if(start_sample&&armed)begin
    capturing<=1;armed<=0;ready<=0;overflow<=0;count<=0;op_active<=0;
    frame<=frame_sample;generation<=generation_sample;
   end
   if(capturing)begin
    if(op_start_sample)begin
     op_active<=1;index_q<=index_sample;
     elapsed<=0;vectors<=0;input_wait<=0;output_wait<=0;reads<=0;writes<=0;loads<=0;hits<=0;
    end else if(op_active)begin
     elapsed<=next_elapsed;vectors<=next_vectors;input_wait<=next_input;output_wait<=next_output;
     reads<=next_reads;writes<=next_writes;loads<=next_loads;hits<=next_hits;
    end
    if(commit)begin
     op_active<=0;
     if(count<512)count<=count+1'b1;else overflow<=1;
    end
    if(done_sample)begin capturing<=0;ready<=1;op_active<=0;task_id<=task_sample;end
   end
  end
 end
endmodule

`timescale 1ns/1ps
// STL1: one selected graph operator, no execution feedback and no trace RAM.
// Entire observation stream is sampled together, exactly as in PRF3.
module npu_stall_snapshot #(parameter integer COUNTER_W=32) (
 input wire clk,rst_n,arm,clear,input wire [31:0] target_index,
 input wire [7:0] select_word,
 input wire graph_start,graph_done,input wire [31:0] start_frame,start_generation,
 input wire [15:0] graph_fault,input wire [31:0] done_task,done_model,
 input wire op_start,op_done,input wire [31:0] op_index,input wire [7:0] op_fault,
 input wire [31:0] exec_frame,exec_generation,exec_task,exec_model,
 input wire [84:0] events,input wire [31:0] input_bytes,weight_bytes,dma_bytes,
 input wire [4:0] window_count,
 output wire [31:0] read_data,status,
 output reg [31:0] frame,generation,task_id,model_id,index_q,fault
);
 localparam integer N=85;
 reg a_s,c_s,gs_s,gd_s,os_s,od_s;
 reg [84:0] e_s;
 reg [31:0] ib_s,wb_s,db_s,idx_s,target_s;
 reg [4:0] win_s;
 reg [31:0] sf_s,sg_s,ef_s,eg_s,et_s,em_s;
 reg [31:0] dt_s,dm_s;reg [15:0] gf_s;reg [7:0] of_s;
 always @(posedge clk)begin
  if(!rst_n)begin a_s<=0;c_s<=0;gs_s<=0;gd_s<=0;os_s<=0;od_s<=0;e_s<=0;end
  else begin
   a_s<=arm;c_s<=clear;gs_s<=graph_start;gd_s<=graph_done;
   os_s<=op_start;od_s<=op_done;e_s<=events;
  end
  ib_s<=input_bytes;wb_s<=weight_bytes;db_s<=dma_bytes;win_s<=window_count;
  idx_s<=op_index;target_s<=target_index;sf_s<=start_frame;sg_s<=start_generation;
  ef_s<=exec_frame;eg_s<=exec_generation;et_s<=exec_task;em_s<=exec_model;
  gf_s<=graph_fault;of_s<=op_fault;dt_s<=done_task;dm_s<=done_model;
 end
 reg armed,capturing,ready,watching,found,not_found,aborted,complete;
 reg [31:0] target_q;
 (* ram_style="registers" *) reg [COUNTER_W-1:0] counters[0:N-1];
 reg [N-1:0] overflow;
 reg [COUNTER_W-1:0] input_run,weight_run;
 // Ownership observers follow accepted source descriptors and the transport's
 // scalar/bulk admission independently. A pending source descriptor must NOT
 // misattribute an older scalar DMA response as an input/weight beat.
 reg [1:0] source_owner,dma_owner;
 wire [1:0] admitted_owner=e_s[9]?2'd1:e_s[31]?2'd2:source_owner;
 always @(posedge clk)begin
  if(!rst_n)begin source_owner<=0;dma_owner<=0;end
  else begin
   if(e_s[10]||e_s[32])source_owner<=0;
   if(e_s[9])source_owner<=1;
   if(e_s[31])source_owner<=2;
   if(e_s[51])dma_owner<=e_s[73]?admitted_owner:2'd0;
  end
 end
 wire [84:0] count_events=e_s | (e_s[55]&&dma_owner==1 ? (85'd1<<13):85'd0) |
                                     (e_s[55]&&dma_owner==2 ? (85'd1<<35):85'd0);
 wire [6:0] selected=select_word[6:0];
 wire [31:0] selected_value={{(32-COUNTER_W){1'b0}},counters[selected<N?selected:0]};
 assign read_data=ready&&selected<N ? (select_word[7]?{31'd0,overflow[selected]}:selected_value):32'd0;
 assign status={24'd0,watching,complete,aborted,not_found,(|overflow),ready,capturing,armed};
 integer k;
 reg [32:0] addend,sum;
 always @(posedge clk)begin
  if(!rst_n)begin
   armed<=0;capturing<=0;ready<=0;watching<=0;found<=0;not_found<=0;aborted<=0;complete<=0;
   target_q<=16;frame<=0;generation<=0;task_id<=0;model_id<=0;index_q<=0;fault<=0;
   input_run<=0;weight_run<=0;overflow<=0;
   for(k=0;k<N;k=k+1)counters[k]<=0;
  end else if(c_s||(a_s&&!watching&&!capturing))begin
   armed<=a_s&&!c_s;capturing<=0;ready<=0;watching<=0;found<=0;not_found<=0;aborted<=0;complete<=0;
   target_q<=target_s;index_q<=target_s;frame<=0;generation<=0;task_id<=0;model_id<=0;fault<=0;
   input_run<=0;weight_run<=0;overflow<=0;
   for(k=0;k<N;k=k+1)counters[k]<=0;
  end else begin
   if(gs_s&&armed)begin watching<=1;frame<=sf_s;generation<=sg_s;end
   if(os_s&&watching&&armed&&idx_s==target_q)begin
    armed<=0;capturing<=1;found<=1;
    frame<=ef_s;generation<=eg_s;task_id<=et_s;model_id<=em_s;index_q<=idx_s;
   end else if(capturing)begin
    for(k=0;k<N;k=k+1)begin
     if(k!=15&&k!=40&&k!=71)begin
      addend=k==0?33'd1:!count_events[k]?33'd0:
       k==11?{1'b0,ib_s}:k==33?{1'b0,wb_s}:k==53?{1'b0,db_s}:
       k==24?{28'd0,win_s}:33'd1;
      sum={{(33-COUNTER_W){1'b0}},counters[k]}+addend;
      counters[k]<=sum[COUNTER_W-1:0];
      if(|(sum>>COUNTER_W))overflow[k]<=1;
     end
    end
    if(e_s[14])begin
     if(&input_run)begin overflow[15]<=1;counters[15]<={COUNTER_W{1'b1}};end
     else begin input_run<=input_run+1'b1;if(input_run+1'b1>counters[15])counters[15]<=input_run+1'b1;end
    end else input_run<=0;
    if(e_s[50])begin
     if(&weight_run)begin overflow[40]<=1;counters[40]<={COUNTER_W{1'b1}};end
     else begin weight_run<=weight_run+1'b1;if(weight_run+1'b1>counters[40])counters[40]<=weight_run+1'b1;end
    end else weight_run<=0;
    if(e_s[24]&&win_s>counters[71])begin counters[71]<=COUNTER_W'(win_s);if((33'(win_s)>>COUNTER_W)!=0)overflow[71]<=1;end
    if(od_s)begin capturing<=0;fault<={24'd0,of_s};if(of_s!=0)aborted<=1;end
   end
   if(gd_s&&watching)begin
    watching<=0;armed<=0;capturing<=0;ready<=1;complete<=1;not_found<=!found;
    fault[31:16]<=gf_s;
    if(!found)begin task_id<=dt_s;model_id<=dm_s;end;
    if(capturing&&!od_s)aborted<=1;
    if(gf_s!=0)aborted<=1;
   end
  end
 end
endmodule
