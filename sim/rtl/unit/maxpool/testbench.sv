`timescale 1ns/1ps
module tb_maxpool_source_words #(parameter bit BULK=1);
  reg clk=0;
  always #5 clk=~clk;
  reg rst_n=0,cmd_valid=0,rsp_ready=0;
  reg [31:0] cmd_tag=0;
  reg [4095:0] cmd_record=0;
  integer cycle=0, case_no=0, fault_mode=0, stall_mode=1;
  integer passed=0, golden_pixels=0, compared_cycles=0;
  integer scalar_reads=0,scalar_writes=0,bulk_reads=0,bulk_writes=0;
  reg [7:0] memory[0:32767];
  integer scalar_wait=0;
  reg scalar_pending=0;
  reg mem_rsp_valid=0;
  reg signed [63:0] mem_rsp_rdata=0;
  reg [3:0] mem_rsp_fault=0;
  reg [31:0] scalar_addr=0;
  reg [1:0] scalar_size=0;
  reg scalar_write=0;
  reg math_pending=0,math_rsp_valid=0;
  integer math_wait=0;
  reg signed [63:0] math_rsp_result=0,math_saved=0;
  reg [1:0] math_rsp_fault=0;
  reg rd_active=0,rd_valid=0,rd_last=0,rd_rsp_valid=0;
  reg [63:0] rd_data=0;
  reg [7:0] rd_keep=0;
  reg [3:0] rd_fault=0;
  reg [31:0] read_base=0;
  integer read_beat=0,read_target=4,read_reply_wait=-1;
  reg write_active=0,wr_rsp_valid=0;
  reg [3:0] wr_fault=0;
  reg [31:0] write_base=0;
  integer write_beat=0,write_reply_wait=-1;
  wire mem_req_ready=rst_n&&!scalar_pending&&(!stall_mode || cycle%5!=1);
  wire math_req_ready=rst_n&&!math_pending&&(!stall_mode || cycle%4!=0);
  wire rd_cmd_ready=rst_n&&!rd_active&&!rd_rsp_valid&&read_reply_wait<0&&(!stall_mode || cycle%3!=1);
  wire wr_cmd_ready=rst_n&&!write_active&&!wr_rsp_valid&&write_reply_wait<0&&(!stall_mode || cycle%4!=1);
  wire wr_ready=rst_n&&write_active&&(!stall_mode || (cycle%7!=2&&cycle%7!=3));
  wire cmd_ready[0:1];
  wire mem_req_valid[0:1];
  wire mem_req_write[0:1];
  wire [31:0] mem_req_addr[0:1];
  wire [1:0] mem_req_size[0:1];
  wire [63:0] mem_req_wdata[0:1];
  wire mem_rsp_ready[0:1];
  wire rsp_valid[0:1];
  wire [31:0] rsp_tag[0:1];
  wire [7:0] rsp_fault[0:1];
  wire busy[0:1];
  wire math_req_valid[0:1];
  wire [2:0] math_req_op[0:1];
  wire [63:0] math_req_a[0:1];
  wire [63:0] math_req_b[0:1];
  wire [6:0] math_req_shift[0:1];
  wire math_rsp_ready[0:1];
  wire rd_cmd_valid[0:1];
  wire [31:0] rd_cmd_addr[0:1];
  wire [31:0] rd_cmd_bytes[0:1];
  wire rd_ready[0:1];
  wire rd_rsp_ready[0:1];
  wire wr_cmd_valid[0:1];
  wire [31:0] wr_cmd_addr[0:1];
  wire [31:0] wr_cmd_bytes[0:1];
  wire wr_valid[0:1];
  wire [63:0] wr_data[0:1];
  wire [7:0] wr_keep[0:1];
  wire wr_last[0:1];
  wire wr_rsp_ready[0:1];
  npu_maxpool_engine_before #(.EXTERNAL_MATH(1),.ENABLE_MAXPOOL_BULK(BULK)) dut0(
    .clk(clk),
    .rst_n(rst_n),
    .cmd_valid(cmd_valid),
    .cmd_tag(cmd_tag),
    .cmd_record(cmd_record),
    .mem_req_ready(mem_req_ready),
    .mem_rsp_valid(mem_rsp_valid),
    .mem_rsp_rdata(mem_rsp_rdata),
    .mem_rsp_fault(mem_rsp_fault),
    .rsp_ready(rsp_ready),
    .math_req_ready(math_req_ready),
    .math_rsp_valid(math_rsp_valid),
    .math_rsp_result(math_rsp_result),
    .math_rsp_fault(math_rsp_fault),
    .rd_cmd_ready(rd_cmd_ready),
    .rd_valid(rd_valid),
    .rd_data(rd_data),
    .rd_keep(rd_keep),
    .rd_last(rd_last),
    .rd_rsp_valid(rd_rsp_valid),
    .rd_fault(rd_fault),
    .wr_cmd_ready(wr_cmd_ready),
    .wr_ready(wr_ready),
    .wr_rsp_valid(wr_rsp_valid),
    .wr_fault(wr_fault),
    .cmd_ready(cmd_ready[0]),
    .mem_req_valid(mem_req_valid[0]),
    .mem_req_write(mem_req_write[0]),
    .mem_req_addr(mem_req_addr[0]),
    .mem_req_size(mem_req_size[0]),
    .mem_req_wdata(mem_req_wdata[0]),
    .mem_rsp_ready(mem_rsp_ready[0]),
    .rsp_valid(rsp_valid[0]),
    .rsp_tag(rsp_tag[0]),
    .rsp_fault(rsp_fault[0]),
    .busy(busy[0]),
    .math_req_valid(math_req_valid[0]),
    .math_req_op(math_req_op[0]),
    .math_req_a(math_req_a[0]),
    .math_req_b(math_req_b[0]),
    .math_req_shift(math_req_shift[0]),
    .math_rsp_ready(math_rsp_ready[0]),
    .rd_cmd_valid(rd_cmd_valid[0]),
    .rd_cmd_addr(rd_cmd_addr[0]),
    .rd_cmd_bytes(rd_cmd_bytes[0]),
    .rd_ready(rd_ready[0]),
    .rd_rsp_ready(rd_rsp_ready[0]),
    .wr_cmd_valid(wr_cmd_valid[0]),
    .wr_cmd_addr(wr_cmd_addr[0]),
    .wr_cmd_bytes(wr_cmd_bytes[0]),
    .wr_valid(wr_valid[0]),
    .wr_data(wr_data[0]),
    .wr_keep(wr_keep[0]),
    .wr_last(wr_last[0]),
    .wr_rsp_ready(wr_rsp_ready[0])
  );
  npu_maxpool_engine #(.EXTERNAL_MATH(1),.ENABLE_MAXPOOL_BULK(BULK)) dut1(
    .clk(clk),
    .rst_n(rst_n),
    .cmd_valid(cmd_valid),
    .cmd_tag(cmd_tag),
    .cmd_record(cmd_record),
    .mem_req_ready(mem_req_ready),
    .mem_rsp_valid(mem_rsp_valid),
    .mem_rsp_rdata(mem_rsp_rdata),
    .mem_rsp_fault(mem_rsp_fault),
    .rsp_ready(rsp_ready),
    .math_req_ready(math_req_ready),
    .math_rsp_valid(math_rsp_valid),
    .math_rsp_result(math_rsp_result),
    .math_rsp_fault(math_rsp_fault),
    .rd_cmd_ready(rd_cmd_ready),
    .rd_valid(rd_valid),
    .rd_data(rd_data),
    .rd_keep(rd_keep),
    .rd_last(rd_last),
    .rd_rsp_valid(rd_rsp_valid),
    .rd_fault(rd_fault),
    .wr_cmd_ready(wr_cmd_ready),
    .wr_ready(wr_ready),
    .wr_rsp_valid(wr_rsp_valid),
    .wr_fault(wr_fault),
    .cmd_ready(cmd_ready[1]),
    .mem_req_valid(mem_req_valid[1]),
    .mem_req_write(mem_req_write[1]),
    .mem_req_addr(mem_req_addr[1]),
    .mem_req_size(mem_req_size[1]),
    .mem_req_wdata(mem_req_wdata[1]),
    .mem_rsp_ready(mem_rsp_ready[1]),
    .rsp_valid(rsp_valid[1]),
    .rsp_tag(rsp_tag[1]),
    .rsp_fault(rsp_fault[1]),
    .busy(busy[1]),
    .math_req_valid(math_req_valid[1]),
    .math_req_op(math_req_op[1]),
    .math_req_a(math_req_a[1]),
    .math_req_b(math_req_b[1]),
    .math_req_shift(math_req_shift[1]),
    .math_rsp_ready(math_rsp_ready[1]),
    .rd_cmd_valid(rd_cmd_valid[1]),
    .rd_cmd_addr(rd_cmd_addr[1]),
    .rd_cmd_bytes(rd_cmd_bytes[1]),
    .rd_ready(rd_ready[1]),
    .rd_rsp_ready(rd_rsp_ready[1]),
    .wr_cmd_valid(wr_cmd_valid[1]),
    .wr_cmd_addr(wr_cmd_addr[1]),
    .wr_cmd_bytes(wr_cmd_bytes[1]),
    .wr_valid(wr_valid[1]),
    .wr_data(wr_data[1]),
    .wr_keep(wr_keep[1]),
    .wr_last(wr_last[1]),
    .wr_rsp_ready(wr_rsp_ready[1])
  );
  function automatic [63:0] read_word(input [31:0] address);
    reg [63:0] v;
    begin
      if(address>32760)$fatal(1,"read outside TB memory %h",address);
      for(integer b=0;b<8;b=b+1)v[b*8+:8]=memory[address+b];
      read_word=v;
    end
  endfunction
  function automatic signed [63:0] read_scalar(input [31:0] address,input [1:0] size);
    reg [63:0] v;
    begin
      v=read_word(address);
      case(size)
        0:read_scalar={{56{v[7]}},v[7:0]};
        1:read_scalar={{48{v[15]}},v[15:0]};
        2:read_scalar={{32{v[31]}},v[31:0]};
        3:read_scalar=v;
      endcase
    end
  endfunction
  task automatic store_word(input [31:0] address,input [63:0] data,input integer bytes);
    begin
      if(address+bytes>32768)$fatal(1,"write outside TB memory %h",address);
      for(integer b=0;b<bytes;b=b+1)memory[address+b]=data[b*8+:8];
    end
  endtask

  always @(posedge clk) begin
    cycle<=cycle+1;
    if(!rst_n)begin
      scalar_pending<=0;mem_rsp_valid<=0;mem_rsp_rdata<=0;mem_rsp_fault<=0;scalar_wait<=0;
      math_pending<=0;math_rsp_valid<=0;math_rsp_result<=0;math_rsp_fault<=0;math_wait<=0;
      rd_active<=0;rd_valid<=0;rd_last<=0;rd_rsp_valid<=0;rd_fault<=0;read_reply_wait<=-1;
      write_active<=0;wr_rsp_valid<=0;wr_fault<=0;write_reply_wait<=-1;
    end else begin
      if(mem_rsp_valid&&mem_rsp_ready[0])begin mem_rsp_valid<=0;scalar_pending<=0;end
      if(mem_req_valid[0]&&mem_req_ready)begin
        scalar_pending<=1;scalar_wait<=stall_mode?2+(cycle%3):0;
        scalar_addr<=mem_req_addr[0];scalar_size<=mem_req_size[0];scalar_write<=mem_req_write[0];
        if(mem_req_write[0])begin
          scalar_writes<=scalar_writes+1;
          store_word(mem_req_addr[0],mem_req_wdata[0],1<<mem_req_size[0]);
        end else scalar_reads<=scalar_reads+1;
      end
      if(scalar_pending&&!mem_rsp_valid)begin
        if(scalar_wait!=0)scalar_wait<=scalar_wait-1;
        else begin
          mem_rsp_valid<=1;mem_rsp_rdata<=read_scalar(scalar_addr,scalar_size);
          mem_rsp_fault<=(!scalar_write&&fault_mode==1)?4'd1:(scalar_write&&fault_mode==9)?4'd4:4'd0;
        end
      end
      if(math_rsp_valid&&math_rsp_ready[0])begin math_rsp_valid<=0;math_pending<=0;end
      if(math_req_valid[0]&&math_req_ready)begin
        if(math_req_op[0]!=1 || math_req_shift[0]!=0)$fatal(1,"unexpected geometry op");
        math_pending<=1;math_wait<=stall_mode?2:0;
        math_saved<=$signed(math_req_a[0])*$signed(math_req_b[0]);
      end
      if(math_pending&&!math_rsp_valid)begin
        if(math_wait!=0)math_wait<=math_wait-1;
        else begin math_rsp_valid<=1;math_rsp_result<=math_saved;math_rsp_fault<=fault_mode==11?1:0;end
      end
      if(rd_rsp_valid&&rd_rsp_ready[0])begin rd_rsp_valid<=0;rd_fault<=0;end
      if(rd_cmd_valid[0]&&rd_cmd_ready)begin
        if(rd_cmd_bytes[0]!=32)$fatal(1,"bad bulk read size");
        bulk_reads<=bulk_reads+1;
        rd_active<=1;read_base<=rd_cmd_addr[0];read_beat<=0;
        read_target<=fault_mode==6?3:fault_mode==7?5:4;
      end
      if(rd_active&&!rd_valid&&(!stall_mode || cycle%4!=0))begin
        rd_valid<=1;rd_data<=read_word(read_base+read_beat*8);
        rd_keep<=(fault_mode==3&&read_beat==1)?8'h7f:8'hff;
        rd_last<=fault_mode==4?(read_beat==1):fault_mode==5?0:(read_beat==read_target-1);
        if(read_beat==read_target-1&&stall_mode!=2)begin
          rd_rsp_valid<=1;rd_fault<=fault_mode==2?4'd2:4'd0;
        end
      end
      if(rd_valid&&rd_ready[0])begin
        rd_valid<=0;read_beat<=read_beat+1;
        if(read_beat==read_target-1)begin
          rd_active<=0;
          if(stall_mode==2)read_reply_wait<=3;
        end
      end
      if(read_reply_wait>=0)begin
        if(read_reply_wait==0)begin
          rd_rsp_valid<=1;rd_fault<=fault_mode==2?4'd2:4'd0;read_reply_wait<=-1;
        end else read_reply_wait<=read_reply_wait-1;
      end
      if(wr_rsp_valid&&wr_rsp_ready[0])begin wr_rsp_valid<=0;wr_fault<=0;end
      if(wr_cmd_valid[0]&&wr_cmd_ready)begin
        if(wr_cmd_bytes[0]!=128)$fatal(1,"bad bulk write size");
        bulk_writes<=bulk_writes+1;write_active<=1;write_base<=wr_cmd_addr[0];write_beat<=0;
      end
      if(wr_valid[0]&&wr_ready)begin
        if(wr_keep[0]!=8'hff || wr_last[0]!=(write_beat==15))$fatal(1,"bad output packet");
        store_word(write_base+write_beat*8,wr_data[0],8);write_beat<=write_beat+1;
        if(fault_mode==8&&write_beat==3)begin
          wr_fault<=4'd3;write_active<=0;write_reply_wait<=2;
        end else if(wr_last[0])begin write_active<=0;write_reply_wait<=stall_mode?3:0;end
      end
      if(write_reply_wait>=0)begin
        if(write_reply_wait==0)begin wr_rsp_valid<=1;write_reply_wait<=-1;end
        else write_reply_wait<=write_reply_wait-1;
      end
    end
  end

  // Every public output, including VALID/READY and fault payload, is compared
  // every cycle with four-state equality. The memory model uses only dut0.
  always @(posedge clk) begin
    #1;
    if(rst_n)begin
      compared_cycles=compared_cycles+1;
      if(cmd_ready[0] !== cmd_ready[1]) $fatal(1,"miter case=%0d cycle=%0d signal=cmd_ready ref=%h candidate=%h",case_no,cycle,cmd_ready[0],cmd_ready[1]);
      if(mem_req_valid[0] !== mem_req_valid[1]) $fatal(1,"miter case=%0d cycle=%0d signal=mem_req_valid ref=%h candidate=%h",case_no,cycle,mem_req_valid[0],mem_req_valid[1]);
      if(mem_req_write[0] !== mem_req_write[1]) $fatal(1,"miter case=%0d cycle=%0d signal=mem_req_write ref=%h candidate=%h",case_no,cycle,mem_req_write[0],mem_req_write[1]);
      if(mem_req_addr[0] !== mem_req_addr[1]) $fatal(1,"miter case=%0d cycle=%0d signal=mem_req_addr ref=%h candidate=%h",case_no,cycle,mem_req_addr[0],mem_req_addr[1]);
      if(mem_req_size[0] !== mem_req_size[1]) $fatal(1,"miter case=%0d cycle=%0d signal=mem_req_size ref=%h candidate=%h",case_no,cycle,mem_req_size[0],mem_req_size[1]);
      if(mem_req_wdata[0] !== mem_req_wdata[1]) $fatal(1,"miter case=%0d cycle=%0d signal=mem_req_wdata ref=%h candidate=%h",case_no,cycle,mem_req_wdata[0],mem_req_wdata[1]);
      if(mem_rsp_ready[0] !== mem_rsp_ready[1]) $fatal(1,"miter case=%0d cycle=%0d signal=mem_rsp_ready ref=%h candidate=%h",case_no,cycle,mem_rsp_ready[0],mem_rsp_ready[1]);
      if(rsp_valid[0] !== rsp_valid[1]) $fatal(1,"miter case=%0d cycle=%0d signal=rsp_valid ref=%h candidate=%h",case_no,cycle,rsp_valid[0],rsp_valid[1]);
      if(rsp_tag[0] !== rsp_tag[1]) $fatal(1,"miter case=%0d cycle=%0d signal=rsp_tag ref=%h candidate=%h",case_no,cycle,rsp_tag[0],rsp_tag[1]);
      if(rsp_fault[0] !== rsp_fault[1]) $fatal(1,"miter case=%0d cycle=%0d signal=rsp_fault ref=%h candidate=%h",case_no,cycle,rsp_fault[0],rsp_fault[1]);
      if(busy[0] !== busy[1]) $fatal(1,"miter case=%0d cycle=%0d signal=busy ref=%h candidate=%h",case_no,cycle,busy[0],busy[1]);
      if(math_req_valid[0] !== math_req_valid[1]) $fatal(1,"miter case=%0d cycle=%0d signal=math_req_valid ref=%h candidate=%h",case_no,cycle,math_req_valid[0],math_req_valid[1]);
      if(math_req_op[0] !== math_req_op[1]) $fatal(1,"miter case=%0d cycle=%0d signal=math_req_op ref=%h candidate=%h",case_no,cycle,math_req_op[0],math_req_op[1]);
      if(math_req_a[0] !== math_req_a[1]) $fatal(1,"miter case=%0d cycle=%0d signal=math_req_a ref=%h candidate=%h",case_no,cycle,math_req_a[0],math_req_a[1]);
      if(math_req_b[0] !== math_req_b[1]) $fatal(1,"miter case=%0d cycle=%0d signal=math_req_b ref=%h candidate=%h",case_no,cycle,math_req_b[0],math_req_b[1]);
      if(math_req_shift[0] !== math_req_shift[1]) $fatal(1,"miter case=%0d cycle=%0d signal=math_req_shift ref=%h candidate=%h",case_no,cycle,math_req_shift[0],math_req_shift[1]);
      if(math_rsp_ready[0] !== math_rsp_ready[1]) $fatal(1,"miter case=%0d cycle=%0d signal=math_rsp_ready ref=%h candidate=%h",case_no,cycle,math_rsp_ready[0],math_rsp_ready[1]);
      if(rd_cmd_valid[0] !== rd_cmd_valid[1]) $fatal(1,"miter case=%0d cycle=%0d signal=rd_cmd_valid ref=%h candidate=%h",case_no,cycle,rd_cmd_valid[0],rd_cmd_valid[1]);
      if(rd_cmd_addr[0] !== rd_cmd_addr[1]) $fatal(1,"miter case=%0d cycle=%0d signal=rd_cmd_addr ref=%h candidate=%h",case_no,cycle,rd_cmd_addr[0],rd_cmd_addr[1]);
      if(rd_cmd_bytes[0] !== rd_cmd_bytes[1]) $fatal(1,"miter case=%0d cycle=%0d signal=rd_cmd_bytes ref=%h candidate=%h",case_no,cycle,rd_cmd_bytes[0],rd_cmd_bytes[1]);
      if(rd_ready[0] !== rd_ready[1]) $fatal(1,"miter case=%0d cycle=%0d signal=rd_ready ref=%h candidate=%h",case_no,cycle,rd_ready[0],rd_ready[1]);
      if(rd_rsp_ready[0] !== rd_rsp_ready[1]) $fatal(1,"miter case=%0d cycle=%0d signal=rd_rsp_ready ref=%h candidate=%h",case_no,cycle,rd_rsp_ready[0],rd_rsp_ready[1]);
      if(wr_cmd_valid[0] !== wr_cmd_valid[1]) $fatal(1,"miter case=%0d cycle=%0d signal=wr_cmd_valid ref=%h candidate=%h",case_no,cycle,wr_cmd_valid[0],wr_cmd_valid[1]);
      if(wr_cmd_addr[0] !== wr_cmd_addr[1]) $fatal(1,"miter case=%0d cycle=%0d signal=wr_cmd_addr ref=%h candidate=%h",case_no,cycle,wr_cmd_addr[0],wr_cmd_addr[1]);
      if(wr_cmd_bytes[0] !== wr_cmd_bytes[1]) $fatal(1,"miter case=%0d cycle=%0d signal=wr_cmd_bytes ref=%h candidate=%h",case_no,cycle,wr_cmd_bytes[0],wr_cmd_bytes[1]);
      if(wr_valid[0] !== wr_valid[1]) $fatal(1,"miter case=%0d cycle=%0d signal=wr_valid ref=%h candidate=%h",case_no,cycle,wr_valid[0],wr_valid[1]);
      if(wr_data[0] !== wr_data[1]) $fatal(1,"miter case=%0d cycle=%0d signal=wr_data ref=%h candidate=%h",case_no,cycle,wr_data[0],wr_data[1]);
      if(wr_keep[0] !== wr_keep[1]) $fatal(1,"miter case=%0d cycle=%0d signal=wr_keep ref=%h candidate=%h",case_no,cycle,wr_keep[0],wr_keep[1]);
      if(wr_last[0] !== wr_last[1]) $fatal(1,"miter case=%0d cycle=%0d signal=wr_last ref=%h candidate=%h",case_no,cycle,wr_last[0],wr_last[1]);
      if(wr_rsp_ready[0] !== wr_rsp_ready[1]) $fatal(1,"miter case=%0d cycle=%0d signal=wr_rsp_ready ref=%h candidate=%h",case_no,cycle,wr_rsp_ready[0],wr_rsp_ready[1]);
    end
  end

  task automatic reset_pair;
    begin
      @(negedge clk);rst_n=0;cmd_valid=0;rsp_ready=0;
      repeat(4)@(negedge clk);
      rst_n=1;repeat(3)@(negedge clk);
    end
  endtask

  integer active_a,active_y,active_h,active_w,active_oh,active_ow,active_k,active_pad,active_stride,active_legacy;
  task automatic setup_case(input integer k,input integer bulk_aligned,input integer legacy_mode,input integer generic_mode);
    integer value;
    begin
      cmd_record=0;
      active_a=4096;active_y=bulk_aligned?16384:16392;
      active_h=generic_mode?5:8;active_w=generic_mode?7:8;
      active_oh=generic_mode?3:8;active_ow=generic_mode?4:8;
      active_k=generic_mode?3:k;active_pad=generic_mode?1:(k-1)/2;
      active_stride=generic_mode?2:1;active_legacy=legacy_mode;
      for(integer b=0;b<2048;b=b+1)begin memory[active_a+b]=0;memory[active_y+b]=8'ha5;end
      for(integer p=0;p<active_h*active_w;p=p+1)begin
        if(legacy_mode)begin value=((p*73+case_no*17)%256)-128;store_word(active_a+p,value,1);end
        else begin
          value=(p*32'h9e3779b9)^(case_no*32'h1234567)^(p<<23);
          if(p==0)value=32'h80000000;
          if(p==37)value=32'h7fffffff;
          store_word(active_a+p*4,value,4);
        end
      end
      cmd_record[2*32+:32]=legacy_mode;
      cmd_record[4*32+:32]=legacy_mode?1:3;
      cmd_record[6*32+:32]=legacy_mode?1:3;
      cmd_record[8*32+:32]=active_a;cmd_record[10*32+:32]=active_y;
      cmd_record[64*32+:32]=active_h;cmd_record[65*32+:32]=active_w;
      cmd_record[66*32+:32]=active_oh;cmd_record[67*32+:32]=active_ow;
      cmd_record[68*32+:32]=active_k;cmd_record[69*32+:32]=active_k;
      cmd_record[70*32+:32]=active_stride;cmd_record[71*32+:32]=active_stride;
      cmd_record[72*32+:32]=active_pad;cmd_record[73*32+:32]=active_pad;
    end
  endtask

  task automatic check_golden;
    integer expected,observed,iy,ix,value;
    reg [63:0] word;
    begin
      for(integer oy=0;oy<active_oh;oy=oy+1)begin
        for(integer ox=0;ox<active_ow;ox=ox+1)begin
          expected=active_legacy?-128:32'sh80000000;
          for(integer ky=0;ky<active_k;ky=ky+1)begin
            for(integer kx=0;kx<active_k;kx=kx+1)begin
              iy=oy*active_stride-active_pad+ky;ix=ox*active_stride-active_pad+kx;
              if(iy>=0&&iy<active_h&&ix>=0&&ix<active_w)begin
                value=read_scalar(active_a+(iy*active_w+ix)*(active_legacy?1:4),active_legacy?0:2);
                if(value>expected)expected=value;
              end
            end
          end
          observed=read_scalar(active_y+(oy*active_ow+ox)*(active_legacy?1:4),active_legacy?0:2);
          if(observed!==expected)$fatal(1,"golden case=%0d pixel=(%0d,%0d) expected=%h observed=%h",case_no,oy,ox,expected,observed);
          golden_pixels=golden_pixels+1;
        end
      end
    end
  endtask

  task automatic execute_case(input integer k,input integer aligned,input integer legacy_mode,input integer generic_mode,
                              input integer faults,input integer stalls,input integer expected_fault);
    integer begin_cycle,guard;
    begin
      @(negedge clk);case_no=case_no+1;fault_mode=faults;stall_mode=stalls;
      setup_case(k,aligned,legacy_mode,generic_mode);
      if(faults==10)cmd_record[68*32+:32]=32'h10000005;
      cmd_tag=32'ha5000000+case_no;cmd_valid=1;begin_cycle=cycle;
      do @(posedge clk);while(!cmd_ready[0]);
      @(negedge clk);cmd_valid=0;
      guard=0;
      while(!rsp_valid[0])begin
        @(negedge clk);guard=guard+1;
        if(guard>50000)$fatal(1,"case timeout case=%0d state=%0d",case_no,dut0.state);
      end
      if(rsp_fault[0]!==8'(expected_fault)||rsp_tag[0]!==cmd_tag)
        $fatal(1,"terminal case=%0d expected_fault=%h observed=%h tag=%h",case_no,expected_fault,rsp_fault[0],rsp_tag[0]);
      // Deliberately hold the terminal result under backpressure.
      repeat(7)@(negedge clk);
      if(!rsp_valid[0]||rsp_fault[0]!==8'(expected_fault))$fatal(1,"response not held");
      if(expected_fault==0)check_golden();
      rsp_ready=1;@(negedge clk);rsp_ready=0;
      if(busy[0])$fatal(1,"engine did not return idle");
      passed=passed+1;
      $display("CASE_PASS bulk=%0d case=%0d k=%0d legacy=%0d generic=%0d fault_mode=%0d cycles=%0d",BULK,case_no,k,legacy_mode,generic_mode,faults,cycle-begin_cycle);
    end
  endtask

  task automatic reset_in_flight(input integer target_state);
    integer guard;
    begin
      @(negedge clk);case_no=case_no+1;fault_mode=0;stall_mode=1;
      setup_case(9,1,0,0);cmd_tag=case_no;cmd_valid=1;
      do @(posedge clk);while(!cmd_ready[0]);
      @(negedge clk);cmd_valid=0;guard=0;
      // Reset only after the transaction has made real progress, so partially
      // rewritten source storage and an owned write packet are exercised.
      while(dut0.state!=target_state ||
            (target_state==25 && read_beat<2) ||
            (target_state==27 && write_beat<3) ||
            (target_state==17 && dut0.fast_scan<3))begin
        @(negedge clk);guard=guard+1;
        if(guard>5000)$fatal(1,"reset target unreachable %0d",target_state);
      end
      reset_pair();
      if(busy[0]||rsp_valid[0]||rd_cmd_valid[0]||wr_cmd_valid[0])$fatal(1,"reset did not quiesce");
      passed=passed+1;$display("RESET_PASS bulk=%0d state=%0d",BULK,target_state);
    end
  endtask

  initial begin
    for(integer b=0;b<32768;b=b+1)memory[b]=0;
    reset_pair();
    execute_case(5,1,0,0,0,0,0);
    execute_case(9,1,0,0,0,1,0);
    execute_case(13,1,0,0,0,2,0);
    execute_case(5,0,0,0,0,1,0);
    execute_case(9,0,0,0,0,2,0);
    execute_case(13,0,0,0,0,0,0);
    execute_case(3,1,0,1,0,1,0);
    execute_case(3,1,1,1,0,2,0);
    execute_case(5,0,0,0,1,1,8'h21);
    execute_case(5,0,0,0,9,1,8'h24);
    execute_case(5,1,0,0,10,1,8'h03);
    execute_case(5,1,0,0,11,1,8'h03);
    if(BULK)begin
      execute_case(5,1,0,0,2,1,8'h22);
      execute_case(5,1,0,0,3,1,8'h28);
      execute_case(5,1,0,0,4,2,8'h28);
      execute_case(5,1,0,0,5,1,8'h28);
      execute_case(5,1,0,0,6,2,8'h28);
      execute_case(5,1,0,0,7,1,8'h28);
      execute_case(5,1,0,0,8,1,8'h23);
      reset_in_flight(25); // FAST_BULK_READ_DATA
      reset_in_flight(27); // FAST_BULK_BEAT
    end else reset_in_flight(15); // FAST_READ_WAIT
    reset_in_flight(17); // FAST_H_SCAN
    execute_case(13,1,0,0,0,1,0);
    $display("TEST_PASS maxpool_source_words BULK=%0d cases=%0d golden_pixels=%0d compared_cycles=%0d scalar_reads=%0d scalar_writes=%0d bulk_reads=%0d bulk_writes=%0d",BULK,passed,golden_pixels,compared_cycles,scalar_reads,scalar_writes,bulk_reads,bulk_writes);
    $finish;
  end
  initial begin #20000000;$fatal(1,"watchdog case=%0d",case_no);end
endmodule
module tb_maxpool_source_words_bulk;
  tb_maxpool_source_words #(.BULK(1)) test();
endmodule
module tb_maxpool_source_words_scalar;
  tb_maxpool_source_words #(.BULK(0)) test();
endmodule
