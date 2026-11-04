`timescale 1ns/1ps
// Whole-descriptor permission checks. Physical aligned bus beats must also
// stay in an allocated region. A rejected write drains its producer without
// issuing AXI; a rejected read returns a terminal error without data.
module npu_stream_guard (
 input wire clk,rst_n,input wire [31:0] model_base,model_bytes,plan_base,plan_bytes,workspace_base,workspace_bytes,
 input wire c_rd_cmd_valid,output wire c_rd_cmd_ready,input wire [31:0] c_rd_cmd_addr,c_rd_cmd_bytes,
 output wire c_rd_valid,input wire c_rd_ready,output wire [63:0] c_rd_data,
 output wire [7:0] c_rd_keep,output wire c_rd_last,
 output wire c_rd_rsp_valid,input wire c_rd_rsp_ready,output wire [3:0] c_rd_fault,
 input wire c_wr_cmd_valid,output wire c_wr_cmd_ready,input wire [31:0] c_wr_cmd_addr,c_wr_cmd_bytes,
 input wire c_wr_valid,output wire c_wr_ready,input wire [63:0] c_wr_data,
 input wire [7:0] c_wr_keep,input wire c_wr_last,
 output wire c_wr_rsp_valid,input wire c_wr_rsp_ready,output wire [3:0] c_wr_fault,
 output wire rd_cmd_valid,input wire rd_cmd_ready,output reg [31:0] rd_cmd_addr,rd_cmd_bytes,
 input wire rd_valid,output wire rd_ready,input wire [63:0] rd_data,input wire [7:0] rd_keep,input wire rd_last,
 input wire rd_rsp_valid,output wire rd_rsp_ready,input wire [3:0] rd_fault,
 output wire wr_cmd_valid,input wire wr_cmd_ready,output reg [31:0] wr_cmd_addr,wr_cmd_bytes,
 output wire wr_valid,input wire wr_ready,output wire [63:0] wr_data,
 output wire [7:0] wr_keep,output wire wr_last,
 input wire wr_rsp_valid,output wire wr_rsp_ready,input wire [3:0] wr_fault,output wire idle
);
 localparam [2:0] IDLE=0,SEND=1,ACTIVE=2,REJECT=3,DISCARD=4,CHECK_ENDS=5,CHECK_ACCESS=6;
 reg [2:0] rstate,wstate;
 reg [32:0] discard_beats;
 reg [32:0] read_end,write_end,read_aligned_end,write_aligned_end;
 reg [32:0] read_model_end,read_plan_end,read_workspace_end,write_workspace_end;
 reg [2:0] read_start_inside;
 reg write_start_inside;
 wire read_allowed=rd_cmd_bytes!=0&&read_end<=33'h100000000&&read_aligned_end<=33'h100000000&&
  ((read_start_inside[2]&&read_aligned_end<=read_workspace_end&&read_workspace_end<=33'h100000000)||
   (read_start_inside[0]&&read_aligned_end<=read_model_end&&read_model_end<=33'h100000000)||
   (read_start_inside[1]&&read_aligned_end<=read_plan_end&&read_plan_end<=33'h100000000));
 wire write_allowed=wr_cmd_bytes!=0&&write_end<=33'h100000000&&write_aligned_end<=33'h100000000&&
  write_start_inside&&write_aligned_end<=write_workspace_end&&write_workspace_end<=33'h100000000;
 assign idle=rstate==IDLE&&wstate==IDLE;
 assign c_rd_cmd_ready=rst_n&&rstate==IDLE;assign rd_cmd_valid=rst_n&&rstate==SEND;
 assign c_rd_valid=rstate==ACTIVE&&rd_valid;assign rd_ready=rstate==ACTIVE&&c_rd_ready;
 assign c_rd_data=rd_data;assign c_rd_keep=rd_keep;assign c_rd_last=rd_last;
 assign c_rd_rsp_valid=rst_n&&(rstate==REJECT||(rstate==ACTIVE&&rd_rsp_valid));
 assign rd_rsp_ready=rstate==ACTIVE&&c_rd_rsp_ready;assign c_rd_fault=rstate==REJECT ? 4'b0010 : rstate==ACTIVE ? rd_fault : 4'd0;
 assign c_wr_cmd_ready=rst_n&&wstate==IDLE;assign wr_cmd_valid=rst_n&&wstate==SEND;
 assign wr_valid=wstate==ACTIVE&&c_wr_valid;
 assign c_wr_ready=rst_n&&(wstate==DISCARD||(wstate==ACTIVE&&wr_ready));
 assign wr_data=c_wr_data;assign wr_keep=c_wr_keep;assign wr_last=c_wr_last;
 assign c_wr_rsp_valid=rst_n&&(wstate==REJECT||(wstate==ACTIVE&&wr_rsp_valid));
 assign wr_rsp_ready=wstate==ACTIVE&&c_wr_rsp_ready;assign c_wr_fault=wstate==REJECT ? 4'b0010 : wstate==ACTIVE ? wr_fault : 4'd0;
 // Snapshot start membership and window ends with the accepted descriptor.
 // Upstream may change its windows as soon as the command handshake completes.
 // State ownership keeps these payload registers out of the reset/control tree.
 always @(posedge clk)begin
  if(rstate==IDLE&&c_rd_cmd_valid)begin
   read_end<={1'b0,c_rd_cmd_addr}+{1'b0,c_rd_cmd_bytes};
   read_model_end<={1'b0,model_base}+{1'b0,model_bytes};
   read_plan_end<={1'b0,plan_base}+{1'b0,plan_bytes};
   read_workspace_end<={1'b0,workspace_base}+{1'b0,workspace_bytes};
   read_start_inside[0]<={c_rd_cmd_addr[31:3],3'b000}>=model_base;
   read_start_inside[1]<={c_rd_cmd_addr[31:3],3'b000}>=plan_base;
   read_start_inside[2]<={c_rd_cmd_addr[31:3],3'b000}>=workspace_base;
  end
  if(wstate==IDLE&&c_wr_cmd_valid)begin
   write_end<={1'b0,c_wr_cmd_addr}+{1'b0,c_wr_cmd_bytes};
   write_workspace_end<={1'b0,workspace_base}+{1'b0,workspace_bytes};
   write_start_inside<={c_wr_cmd_addr[31:3],3'b000}>=workspace_base;
  end
  if(rstate==CHECK_ENDS)read_aligned_end<=(read_end+33'd7)&33'h1fffffff8;
  if(wstate==CHECK_ENDS)write_aligned_end<=(write_end+33'd7)&33'h1fffffff8;
 end
 always @(posedge clk)begin
  if(!rst_n)begin rstate<=IDLE;wstate<=IDLE;rd_cmd_addr<=0;rd_cmd_bytes<=0;wr_cmd_addr<=0;wr_cmd_bytes<=0;discard_beats<=0;end
  else begin
   case(rstate)
    IDLE:if(c_rd_cmd_valid)begin
     rd_cmd_addr<=c_rd_cmd_addr;rd_cmd_bytes<=c_rd_cmd_bytes;
     rstate<=CHECK_ENDS;
    end
    CHECK_ENDS:rstate<=CHECK_ACCESS;
    CHECK_ACCESS:rstate<=read_allowed ? SEND : REJECT;
    SEND:if(rd_cmd_ready)rstate<=ACTIVE;
    ACTIVE:if(rd_rsp_valid&&c_rd_rsp_ready)rstate<=IDLE;
    REJECT:if(c_rd_rsp_ready)rstate<=IDLE;
    default:rstate<=IDLE;
   endcase
   case(wstate)
    IDLE:if(c_wr_cmd_valid)begin
     wr_cmd_addr<=c_wr_cmd_addr;wr_cmd_bytes<=c_wr_cmd_bytes;
     wstate<=CHECK_ENDS;
    end
    CHECK_ENDS:begin
     discard_beats<=({1'b0,wr_cmd_bytes}+{30'd0,wr_cmd_addr[2:0]}+33'd7)>>3;
     wstate<=CHECK_ACCESS;
    end
    CHECK_ACCESS:wstate<=write_allowed ? SEND : wr_cmd_bytes==0 ? REJECT : DISCARD;
    SEND:if(wr_cmd_ready)wstate<=ACTIVE;
    ACTIVE:if(wr_rsp_valid&&c_wr_rsp_ready)wstate<=IDLE;
    DISCARD:if(c_wr_valid)begin
     if(discard_beats<=1||c_wr_last)wstate<=REJECT;else discard_beats<=discard_beats-1'b1;
    end
    REJECT:if(c_wr_rsp_ready)wstate<=IDLE;
    default:wstate<=IDLE;
   endcase
  end
 end
endmodule
