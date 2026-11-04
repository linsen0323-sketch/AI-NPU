`timescale 1ns/1ps
// Two 16-KiB input pages. Eight channel banks provide
// eight A8/A16 activations per read; each bank stores packed spatial bytes.
// DMA fills one page while the window path reads the other page.
module npu_stream_ibuf #(
 parameter bit RESERVE_PENDING_READ_PAGE=0,
 parameter integer READ_LATENCY=1,
 parameter bit EXTERNAL_READ_RESERVATION=0
) (
 input wire clk,rst_n,
 input wire wr_valid,output wire wr_ready,input wire wr_page,
 input wire [2:0] wr_bank,input wire [7:0] wr_word,input wire [63:0] wr_data,
 input wire rd_valid,output wire rd_ready,input wire rd_page,
 // Optional registered page lease. A read without a matching reservation is
 // not admitted; same-page writes remain excluded for the entire lease.
 input wire reserve_valid,reserve_page,
 input wire [7:0] rd_word,input wire [2:0] rd_byte,
 input wire rd_a16,input wire [7:0] rd_mask,
 output reg rsp_valid,input wire rsp_ready,output wire [127:0] rsp_data,
 output wire [511:0] rsp_words
);
 wire advance=!rsp_valid||rsp_ready;
 reg read_valid;
 wire read_advance=READ_LATENCY==1 ? advance : !read_valid||advance;
 wire reservation_matches=!EXTERNAL_READ_RESERVATION ||
     (reserve_valid && reserve_page==rd_page);
 // READY may stay low without an owner, including idle cycles. Do not
 // feed transient VALID/fault selection into the reverse READY path.
 assign rd_ready=rst_n&&read_advance&&reservation_matches;
 wire admitted_rd_valid=rd_valid&&reservation_matches;
 // A registered execution lease replaces the fault/ready-dependent read
 // request only in the explicit mode. Default users retain the old guard.
 wire read_page_owned=EXTERNAL_READ_RESERVATION ? reserve_valid :
     rd_valid&&(RESERVE_PENDING_READ_PAGE||rd_ready);
 wire read_owned_page=EXTERNAL_READ_RESERVATION ? reserve_page : rd_page;
 assign wr_ready=rst_n&&!(read_page_owned&&read_owned_page==wr_page);
 reg [2:0] byte_q,byte_read;reg a16_q,a16_read;reg [7:0] mask_q,mask_read;
 initial if(READ_LATENCY<1||READ_LATENCY>2)$fatal(1,"npu_stream_ibuf: READ_LATENCY must be 1 or 2");
 genvar b;
 generate for(b=0;b<8;b=b+1)begin:g_bank
  // Accepted reads and writes use different pages, including during refill.
  (* ram_style="block", rw_addr_collision="no" *) reg [63:0] memory[0:511];
  reg [63:0] selected;
  always @(posedge clk)begin
   if(wr_valid&&wr_ready&&wr_bank==b)memory[{wr_page,wr_word}]<=wr_data;
   if(rd_valid&&rd_ready)selected<=memory[{rd_page,rd_word}];
  end
  wire [63:0] selected_output;
  if(READ_LATENCY==2)begin:g_output_register
   reg [63:0] selected_q;
   always @(posedge clk)if(advance)selected_q<=selected;
   assign selected_output=selected_q;
  end else begin:g_latch_output
   assign selected_output=selected;
  end
  wire [63:0] shifted=selected_output>>{byte_q,3'b000};
  assign rsp_words[b*64+:64]=selected_output;
  assign rsp_data[b*16+:16]=!mask_q[b] ? 16'd0 : a16_q ? shifted[15:0] : {{8{shifted[7]}},shifted[7:0]};
 end endgenerate
 always @(posedge clk)begin
  if(!rst_n)begin
   rsp_valid<=0;read_valid<=0;byte_q<=0;a16_q<=0;mask_q<=0;
   byte_read<=0;a16_read<=0;mask_read<=0;
  end else if(READ_LATENCY==1)begin
   if(advance)begin
    rsp_valid<=admitted_rd_valid;
    if(admitted_rd_valid)begin byte_q<=rd_byte;a16_q<=rd_a16;mask_q<=rd_mask;end
   end
  end else begin
   if(read_advance)begin
    read_valid<=admitted_rd_valid;
    if(admitted_rd_valid)begin byte_read<=rd_byte;a16_read<=rd_a16;mask_read<=rd_mask;end
   end
   if(advance)begin
    rsp_valid<=read_valid;
    if(read_valid)begin byte_q<=byte_read;a16_q<=a16_read;mask_q<=mask_read;end
   end
  end
 end
endmodule
