// Ordered, independently stalled AXI slave plus numeric FIFO scoreboards.
// All stimulus reaches both DUTs through public inputs; no force/deposit.
integer read_mode=0,write_mode=0,scenario=0;
integer qra[0:511],qrb[0:511],qrs[0:511],qrm[0:511];
integer rh=0,rt=0,rc=0,read_burst_index=0;
integer qwb[0:511],qwbi[0:511],wh=0,wt=0,wc=0;
integer brsp[0:511],bh=0,bt=0,bc=0,write_burst_index=0;
integer erdata_addr[0:4095],erkeep[0:4095],erlast[0:4095],eh=0,et=0,ec=0;
integer read_address=0,read_length=0,write_address=0,write_length=0;
integer write_source_index=0,write_source_words=0,write_bus_index=0;
integer read_consumed=0,write_consumed=0,read_responses=0,write_responses=0;
integer read_faults=0,write_faults=0,short_lasts=0,late_lasts=0;
integer source_words_total=0,read_words_total=0,write_words_total=0;
integer freeze_read=0,freeze_write_bus=0,fast_read=0,fast_write_source=0;
reg source_running=0,consume_reads=1,release_terminals=1,environment_enable=1;
reg r_accepted=0,b_accepted=0,w_accepted=0;
reg [31:0] rng=SEED;
integer random_value;
function automatic [31:0] rand32;
 rng=rng*32'd1664525+32'd1013904223;
 return rng;
endfunction
function automatic [63:0] read_value(input integer address);
 return {32'h8ace0246^32'(address),32'hf13579bd+32'(address*13)};
endfunction
function automatic [63:0] write_value(input integer index);
 return {32'hd431789a+32'(index*173),32'h0ef2b569^32'(index*9257)};
endfunction
function automatic [7:0] byte_mask(input integer address,first,bytes);
 for(integer b=0;b<8;b++)byte_mask[b]=(address+b>=first)&&(address+b<first+bytes);
endfunction

always @(negedge clk)begin
 if(!rst_n || !environment_enable)begin
  m_axi_arready=0;m_axi_awready=0;m_axi_wready=0;
  m_axi_rvalid=0;m_axi_rlast=0;m_axi_rresp=0;m_axi_rdata=0;
  m_axi_bvalid=0;m_axi_bresp=0;
  rd_ready=0;rd_rsp_ready=0;wr_rsp_ready=0;wr_valid=0;
 end else begin
  random_value=rand32();
  m_axi_arready=(random_value&7)!=0;
  m_axi_awready=((random_value>>4)&7)!=0;
  m_axi_wready=wc!=0 && freeze_write_bus==0 && ((random_value>>8)&7)!=0;
  rd_ready=consume_reads && freeze_read==0 && (fast_read || ((random_value>>12)&7)!=0);
  rd_rsp_ready=release_terminals && ((random_value>>16)&3)!=0;
  wr_rsp_ready=release_terminals && ((random_value>>20)&3)!=0;
  if(!m_axi_rvalid || r_accepted)begin
   m_axi_rvalid=0;m_axi_rresp=0;m_axi_rlast=0;
   if(rc!=0 && (fast_read || ((random_value>>24)&3)!=0))begin
    m_axi_rvalid=1;m_axi_rdata=read_value(qra[rh]+qrs[rh]*8);
    m_axi_rlast=qrs[rh]+1==qrb[rh];
    if(qrm[rh]==1 && qrs[rh]==2)begin m_axi_rlast=1;end
    if(qrm[rh]==2 && qrs[rh]==1)m_axi_rresp=2'b10;
    if(qrm[rh]==3)m_axi_rlast=qrs[rh]+1==qrb[rh]+2;
   end
  end
  if(!m_axi_bvalid || b_accepted)begin
   m_axi_bvalid=0;m_axi_bresp=0;
   if(bc!=0 && ((random_value>>27)&7)!=0)begin
    m_axi_bvalid=1;m_axi_bresp=brsp[bh];
   end
  end
  if(wr_fault!=0 || wr_rsp_valid)wr_valid=0;
  else if(!wr_valid || w_accepted)begin
   wr_valid=0;
   if(source_running && write_source_index<write_source_words && wr_fault==0 &&
      (fast_write_source || ((random_value>>29)&3)!=0))begin
    wr_valid=1;wr_data=write_value(write_source_index);wr_keep=8'hff;
    wr_last=write_source_index+1==write_source_words;
   end
  end
 end
end

always @(posedge clk)begin
 r_accepted=rst_n&&m_axi_rvalid&&m_axi_rready;
 b_accepted=rst_n&&m_axi_bvalid&&m_axi_bready;
 w_accepted=rst_n&&wr_valid&&wr_ready;
 if(!rst_n)begin
  rh=0;rt=0;rc=0;wh=0;wt=0;wc=0;bh=0;bt=0;bc=0;
  eh=0;et=0;ec=0;read_burst_index=0;write_burst_index=0;
  write_source_index=0;write_bus_index=0;
 end else begin
  if(m_axi_arvalid&&m_axi_arready)begin
   if(rc>=500)$fatal(1,"AXI read model queue overflow");
   if(m_axi_araddr[2:0]!=0 || m_axi_arlen>15 || m_axi_araddr[11:0]+(m_axi_arlen+1)*8>4096)
    $fatal(1,"AXI read burst geometry id=%0d",ID);
   qra[rt]=m_axi_araddr;qrb[rt]=m_axi_arlen+1;qrs[rt]=0;
   qrm[rt]=read_burst_index==0 ? read_mode : 0;
   if(read_mode==1 && read_burst_index==0 && m_axi_arlen<2)$fatal(1,"short-last case requires burst>=3");
   rt=(rt+1)%512;rc++;read_burst_index++;
  end
  if(m_axi_rvalid&&m_axi_rready)begin
   if(rc==0)$fatal(1,"R beat without AR id=%0d",ID);
   if(qrs[rh]<qrb[rh])begin
    erdata_addr[et]=qra[rh]+qrs[rh]*8;
    erkeep[et]=byte_mask(erdata_addr[et],read_address,read_length);
    erlast[et]=erdata_addr[et]+8>=read_address+read_length;
    et=(et+1)%4096;ec++;
   end
   if(m_axi_rresp!=0)read_faults++;
   if(m_axi_rlast)begin
    if(qrs[rh]+1<qrb[rh])short_lasts++;
    if(qrs[rh]+1>qrb[rh])late_lasts++;
    rh=(rh+1)%512;rc--;
   end else qrs[rh]++;
  end
  if(rd_valid&&rd_ready)begin
   if(ec==0)$fatal(1,"read FIFO produced unrequested data id=%0d",ID);
   if({rd_data,rd_keep,rd_last} !== {read_value(erdata_addr[eh]),8'(erkeep[eh]),1'(erlast[eh])})
    $fatal(1,"read numeric/keep/last id=%0d case=%0d beat=%0d",ID,cases,read_consumed);
   eh=(eh+1)%4096;ec--;read_consumed++;read_words_total++;
  end
  if(wr_valid&&wr_ready)begin write_source_index++;source_words_total++;end
  if(m_axi_awvalid&&m_axi_awready)begin
   if(wc>=500)$fatal(1,"AXI write model queue overflow");
   if(m_axi_awaddr[2:0]!=0 || m_axi_awlen>15 || m_axi_awaddr[11:0]+(m_axi_awlen+1)*8>4096)
    $fatal(1,"AXI write burst geometry id=%0d",ID);
   qwb[wt]=m_axi_awlen+1;qwbi[wt]=write_burst_index;
   wt=(wt+1)%512;wc++;write_burst_index++;
  end
  if(m_axi_wvalid&&m_axi_wready)begin
   if(wc==0 || m_axi_wlast!==(qwb[wh]==1))$fatal(1,"AXI write framing id=%0d",ID);
   if(m_axi_wdata!==write_value(write_bus_index) ||
      m_axi_wstrb!==byte_mask((write_address&32'hfffffff8)+write_bus_index*8,write_address,write_length))
    $fatal(1,"write numeric/keep id=%0d case=%0d index=%0d",ID,cases,write_bus_index);
   write_bus_index++;write_consumed++;write_words_total++;
   if(m_axi_wlast)begin
    brsp[bt]=(write_mode==1 && qwbi[wh]==0) ? 2 : 0;
    bt=(bt+1)%512;bc++;wh=(wh+1)%512;wc--;
   end else qwb[wh]--;
  end
  if(m_axi_bvalid&&m_axi_bready)begin
   if(bc==0)$fatal(1,"B response without AW id=%0d",ID);
   if(m_axi_bresp!=0)write_faults++;
   bh=(bh+1)%512;bc--;
  end
  if(rd_rsp_valid&&rd_rsp_ready)read_responses++;
  if(wr_rsp_valid&&wr_rsp_ready)write_responses++;
 end
end

task automatic clock_steps(input integer n);
 repeat(n)@(negedge clk);
endtask
task automatic reset_case(input bit inflight=0);
 @(negedge clk);rst_n=0;rd_cmd_valid=0;wr_cmd_valid=0;source_running=0;
 stop=0;consume_reads=1;release_terminals=1;freeze_read=0;freeze_write_bus=0;
 clock_steps(3);rst_n=1;clock_steps(2);
 if(!idle || rd_valid || dut.r_nonempty || dut.r_used!=0)$fatal(1,"reset idle id=%0d",ID);
endtask
task automatic read_command(input integer address,bytes);
 @(negedge clk);read_address=address;read_length=bytes;read_burst_index=0;read_consumed=0;
 rd_cmd_addr=address;rd_cmd_bytes=bytes;rd_cmd_valid=1;
 do @(posedge clk);while(!rd_cmd_ready);
 @(negedge clk);rd_cmd_valid=0;
endtask
task automatic write_command(input integer address,bytes);
 @(negedge clk);write_address=address;write_length=bytes;write_burst_index=0;write_consumed=0;
 write_source_index=0;write_bus_index=0;write_source_words=(bytes+(address&7)+7)/8;
 wr_cmd_addr=address;wr_cmd_bytes=bytes;wr_cmd_valid=1;
 do @(posedge clk);while(!wr_cmd_ready);
 @(negedge clk);wr_cmd_valid=0;source_running=bytes!=0 && address+64'(bytes)<=64'h100000000;
endtask
task automatic wait_read_terminal(input integer expected_fault);
 integer watchdog;
 watchdog=0;
 while(!rd_rsp_valid)begin @(negedge clk);watchdog++;if(watchdog>100000)$fatal(1,"read watchdog id=%0d case=%0d used=%0d reserved=%0d rc=%0d",ID,cases,dut.r_used,dut.r_reserved,rc);end
 if(rd_fault!==4'(expected_fault))$fatal(1,"read terminal fault id=%0d got=%h expected=%h",ID,rd_fault,expected_fault);
 if(ec!=0 || rc!=0 || rd_valid || dut.r_used!=0)$fatal(1,"read terminal before drain id=%0d",ID);
endtask
task automatic wait_write_terminal(input integer expected_fault);
 integer watchdog;
 watchdog=0;
 while(!wr_rsp_valid)begin @(negedge clk);watchdog++;if(watchdog>100000)$fatal(1,"write watchdog id=%0d case=%0d used=%0d wc=%0d",ID,cases,dut.w_used,wc);end
 source_running=0;
 if(wr_fault!==4'(expected_fault))$fatal(1,"write terminal fault id=%0d got=%h expected=%h",ID,wr_fault,expected_fault);
 if(wc!=0 || bc!=0)$fatal(1,"write terminal before AXI drain id=%0d",ID);
endtask
task automatic finish_case;
 release_terminals=1;
 wait(idle);clock_steps(2);
 if(rc||wc||bc||ec)$fatal(1,"case did not drain id=%0d",ID);
 cases++;
 $display("PROGRESS dma id=%0d case=%0d cycle=%0d",ID,cases,cycles);
endtask
task automatic read_case(input integer bytes,mode=0,offset=0,fill=0,stop_mid=0);
 read_mode=mode;release_terminals=0;consume_reads=!fill;fast_read=fill;
 read_command((fill ? 32'h2000 : 32'h1ff0)+offset,bytes);
 if(fill)begin
  wait(dut.r_used==FIFO);clock_steps(9);consume_reads=1;
 end
 if(stop_mid)begin stop=1;clock_steps(27);if(rd_cmd_ready||wr_cmd_ready)$fatal(1,"stop admission id=%0d",ID);end
 wait_read_terminal(mode==1||mode==3 ? 8 : mode==2 ? 4 : 0);
 clock_steps(5);stop=0;fast_read=0;finish_case();
endtask
task automatic duplex_case(input integer bytes,wm=0,fill=0);
 read_mode=0;write_mode=wm;release_terminals=0;consume_reads=1;
 freeze_write_bus=fill;fast_write_source=fill;
 fork read_command(32'h3003,bytes);write_command(32'h9005,bytes);join
 if(fill)begin wait(dut.w_used==FIFO);clock_steps(7);freeze_write_bus=0;end
 fork wait_read_terminal(0);wait_write_terminal(wm==1 ? 4 : 0);join
 if(wm==0 && write_bus_index!=write_source_words)$fatal(1,"write count id=%0d",ID);
 clock_steps(7);fast_write_source=0;finish_case();
endtask

initial begin
 reset_case();
 // Full receive credit and full FIFO, followed by sustained simultaneous pop/store.
 read_case(FIFO*8+512,0,0,1,1);
 read_case(193,0,5);read_case(1,0,7);read_case(513,0,0);
 // First accepted burst crosses no page and is long enough for framing faults.
 read_mode=1;release_terminals=0;consume_reads=1;read_command(32'h2000,FIFO*8+512);
 wait_read_terminal(8);clock_steps(5);finish_case();
 read_case(385,0,1);
 read_mode=2;release_terminals=0;read_command(32'h2000,FIFO*8+512);
 wait_read_terminal(4);clock_steps(5);finish_case();
 read_case(257,0,0);
 read_mode=3;release_terminals=0;read_command(32'h2000,FIFO*8+512);
 wait_read_terminal(8);clock_steps(5);finish_case();
 read_case(129,0,3);
 duplex_case(FIFO*8+521,0,1);duplex_case(FIFO*8+521,1,0);duplex_case(265,0,0);
 // Zero-byte and 2^32-overflow admissions must leave the predicate clear.
 read_mode=0;release_terminals=0;read_command(32'h2000,0);wait_read_terminal(2);clock_steps(4);finish_case();
 release_terminals=0;read_command(32'hfffffff8,16);wait_read_terminal(2);clock_steps(4);finish_case();
 // Stop blocks held new descriptors until explicitly released.
 @(negedge clk);stop=1;rd_cmd_valid=1;rd_cmd_addr=32'h2000;rd_cmd_bytes=73;
 read_address=32'h2000;read_length=73;read_burst_index=0;release_terminals=0;
 clock_steps(13);if(rd_cmd_ready||wr_cmd_ready||m_axi_arvalid)$fatal(1,"stopped descriptor admitted id=%0d",ID);
 stop=0;do @(posedge clk);while(!rd_cmd_ready);@(negedge clk);rd_cmd_valid=0;
 wait_read_terminal(0);clock_steps(4);finish_case();
 // Reset with active queues, a stalled payload, a full FIFO, and terminal held.
 read_mode=0;consume_reads=0;read_command(32'h2000,FIFO*16);wait(dut.r_used>=4);reset_case(1);cases++;
 duplex_case(377,0,0);
 consume_reads=0;fast_read=1;read_command(32'h2000,FIFO*16);wait(dut.r_used==FIFO);reset_case(1);cases++;
 freeze_write_bus=1;write_mode=0;write_command(32'h9000,FIFO*16);wait(dut.w_used>=4);reset_case(1);cases++;
 release_terminals=0;read_mode=0;read_command(32'h2000,65);wait_read_terminal(0);reset_case();cases++;
 // Replayable mixed descriptor lengths/page offsets, random independent stalls.
 for(integer n=0;n<96;n++)begin
  random_value=rand32();
  if(n%3==0)duplex_case(1+(random_value&1023),0,0);
  else read_case(1+(random_value&2047),0,(random_value>>12)&7,0,n%17==0);
 end
 if(full_cycles==0||wfull_cycles==0||credit_cycles==0||both_cycles==0||empty_to_one==0||one_to_empty==0||held_terminal==0||stop_active==0||resets_inflight<3||short_lasts==0||late_lasts==0||read_faults==0||write_faults==0)
  $fatal(1,"required coverage missing id=%0d full=%0d wfull=%0d credit=%0d both=%0d empty=%0d drain=%0d held=%0d stop=%0d reset=%0d short=%0d late=%0d rfault=%0d wfault=%0d",ID,full_cycles,wfull_cycles,credit_cycles,both_cycles,empty_to_one,one_to_empty,held_terminal,stop_active,resets_inflight,short_lasts,late_lasts,read_faults,write_faults);
 $display("CASE_PASS dma_nonempty id=%0d FIFO=%0d RO=%0d WO=%0d diag=%0d perf=%0d seed=%h cases=%0d cycles=%0d compared=%0d rdwords=%0d wrwords=%0d full=%0d wfull=%0d credit=%0d simultaneous=%0d empty_set=%0d last_clear=%0d held_terminal=%0d stop_active=%0d reset_active=%0d shortlast=%0d latelast=%0d readfault=%0d writefault=%0d maxused=%0d maxreserved=%0d maxoutstanding=%0d",ID,FIFO,RO,WO,DIAG,PERF,SEED,cases,cycles,compared,read_words_total,write_words_total,full_cycles,wfull_cycles,credit_cycles,both_cycles,empty_to_one,one_to_empty,held_terminal,stop_active,resets_inflight,short_lasts,late_lasts,read_faults,write_faults,max_used,max_reserved,max_r_count);
 done=1;
end
