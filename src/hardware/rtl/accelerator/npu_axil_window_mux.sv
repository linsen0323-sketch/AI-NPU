`timescale 1ns/1ps
// Route bit15=0 to the existing camera register bank, bit15=1 to graph control.
// AW/W are collected independently; read and write each retain their owner.
module npu_axil_window_mux (
 input logic clk,rst_n,input logic [15:0] s_awaddr,input logic s_awvalid,output logic s_awready,
 input logic [31:0] s_wdata,input logic [3:0] s_wstrb,input logic s_wvalid,output logic s_wready,
 output logic [1:0] s_bresp,output logic s_bvalid,input logic s_bready,
 input logic [15:0] s_araddr,input logic s_arvalid,output logic s_arready,
 output logic [31:0] s_rdata,output logic [1:0] s_rresp,output logic s_rvalid,input logic s_rready,
 output logic [31:0] m_awaddr,output logic [1:0] m_awvalid,input logic [1:0] m_awready,
 output logic [63:0] m_wdata,output logic [7:0] m_wstrb,output logic [1:0] m_wvalid,input logic [1:0] m_wready,
 input logic [3:0] m_bresp,input logic [1:0] m_bvalid,output logic [1:0] m_bready,
 output logic [31:0] m_araddr,output logic [1:0] m_arvalid,input logic [1:0] m_arready,
 input logic [63:0] m_rdata,input logic [3:0] m_rresp,input logic [1:0] m_rvalid,output logic [1:0] m_rready
);
 typedef enum logic [1:0] {W_COLLECT,W_SEND,W_RESPONSE} wstate_t;
 typedef enum logic [1:0] {R_IDLE,R_SEND,R_RESPONSE} rstate_t;
 wstate_t ws;rstate_t rs;
 logic aw_hold,w_hold,aw_sent,w_sent,wo,ro;
 logic [15:0] aw,ar;logic [31:0] wd;logic [3:0] strobe;
 always_comb begin
  s_awready=rst_n && ws==W_COLLECT && !aw_hold;s_wready=rst_n && ws==W_COLLECT && !w_hold;
  s_arready=rst_n && rs==R_IDLE;
  m_awaddr={aw,aw};m_wdata={wd,wd};m_wstrb={strobe,strobe};m_araddr={ar,ar};
  m_awvalid=0;m_wvalid=0;m_bready=0;m_arvalid=0;m_rready=0;
  s_bvalid=0;s_bresp=0;s_rvalid=0;s_rresp=0;s_rdata=0;
  if(rst_n && ws==W_SEND) begin m_awvalid[wo]=!aw_sent;m_wvalid[wo]=!w_sent;end
  if(rst_n && ws==W_RESPONSE) begin s_bvalid=m_bvalid[wo];s_bresp=m_bresp[int'(wo)*2+:2];m_bready[wo]=s_bready;end
  if(rst_n && rs==R_SEND) m_arvalid[ro]=1;
  if(rst_n && rs==R_RESPONSE) begin
   s_rvalid=m_rvalid[ro];s_rdata=m_rdata[int'(ro)*32+:32];s_rresp=m_rresp[int'(ro)*2+:2];m_rready[ro]=s_rready;
  end
 end
 always_ff @(posedge clk) begin
  if(!rst_n) begin ws<=W_COLLECT;rs<=R_IDLE;aw_hold<=0;w_hold<=0;aw_sent<=0;w_sent<=0;wo<=0;ro<=0;aw<=0;ar<=0;wd<=0;strobe<=0;end
  else begin
   case(ws)
    W_COLLECT: begin
     if(s_awvalid && s_awready) begin aw<=s_awaddr;wo<=s_awaddr[15];aw_hold<=1;end
     if(s_wvalid && s_wready) begin wd<=s_wdata;strobe<=s_wstrb;w_hold<=1;end
     if((aw_hold || (s_awvalid && s_awready)) && (w_hold || (s_wvalid && s_wready))) begin
      aw_sent<=0;w_sent<=0;ws<=W_SEND;
     end
    end
    W_SEND: begin
     if(m_awvalid[wo] && m_awready[wo]) aw_sent<=1;
     if(m_wvalid[wo] && m_wready[wo]) w_sent<=1;
     if((aw_sent || (m_awvalid[wo] && m_awready[wo])) &&
        (w_sent || (m_wvalid[wo] && m_wready[wo]))) ws<=W_RESPONSE;
    end
    W_RESPONSE: if(s_bvalid && s_bready) begin aw_hold<=0;w_hold<=0;ws<=W_COLLECT;end
    default: ws<=W_COLLECT;
   endcase
   case(rs)
    R_IDLE: if(s_arvalid && s_arready) begin ar<=s_araddr;ro<=s_araddr[15];rs<=R_SEND;end
    R_SEND: if(m_arvalid[ro] && m_arready[ro]) rs<=R_RESPONSE;
    R_RESPONSE: if(s_rvalid && s_rready) rs<=R_IDLE;
    default: rs<=R_IDLE;
   endcase
  end
 end
endmodule
