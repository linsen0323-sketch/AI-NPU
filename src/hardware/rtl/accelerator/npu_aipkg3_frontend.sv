`timescale 1ns/1ps
// Checked AIPKG3 package reader. This module validates an immutable DDR image;
// it does not claim that a validated profile is implemented by an executor.
// One aligned 32-bit memory request is outstanding. Requests and responses
// remain stable under backpressure. A fault is reported only after its read
// response has been consumed, so no memory transaction is abandoned.
module npu_aipkg3_frontend (
 input logic clk,rst_n,
 input logic cmd_valid,output logic cmd_ready,
 input logic [31:0] cmd_model_base,cmd_model_capacity,
 input logic [31:0] cmd_workspace_base,cmd_workspace_capacity,
 output logic mem_req_valid,input logic mem_req_ready,
 output logic [31:0] mem_req_addr,
 input logic mem_rsp_valid,output logic mem_rsp_ready,
 input logic [31:0] mem_rsp_data,input logic mem_rsp_fault,
 output logic rsp_valid,input logic rsp_ready,
 output logic [3:0] rsp_fault,
 output logic [31:0] rsp_model_id,rsp_profile,rsp_image_bytes,rsp_workspace_bytes,
 output logic [31:0] rsp_input_id,rsp_output_id,rsp_input_lut_id,
 // Slot 0=META, 1=TENSORS (profile1: LEGACY_IMAGE), 2=INSTRUCTIONS,
 // 3=ATTRIBUTES, 4=CONSTANTS; absolute DDR addresses and byte lengths.
 output logic [159:0] rsp_section_addr,rsp_section_bytes,
 output logic busy
);
 localparam [3:0] BAD_COMMAND=1,BAD_HEADER=2,BAD_CRC=3,BAD_DIRECTORY=4,MEMORY_ERROR=5;
 typedef enum logic [3:0] {IDLE,HREQ,HWAIT,HCHECK,BREQ,BWAIT,DCHECK,FINAL,HOLD,
  CRC_BYTE,BADVANCE,DCHECK_CRC} state_t;
 state_t state;
 // Retain only meaningful header words and one directory entry. Reserved
 // header words are checked while read; entry data is consumed before reuse.
 logic [31:0] header[0:17],directory[0:15];
 logic [31:0] section_begin[0:4],section_end[0:4],section_crc[0:4],section_expected[0:4];
 logic [31:0] base,model_capacity,workspace_base,workspace_capacity,ptr;
 logic [31:0] header_crc,body_crc,directory_crc,previous_end;
 logic [5:0] hw;
 logic [2:0] di;
 logic [4:0] seen;
 logic reserved_bad,directory_bad;
 integer i,j,section_bytes_this_word;
 logic [2:0] slot;
 logic slot_valid;
 logic [127:0] section_name;
 logic [31:0] directory_end,entry_begin,entry_bytes;
 logic [32:0] entry_end,image_end,workspace_end;
 logic entry_bad;
 logic [1:0] crc_target,crc_byte_index;
 logic [2:0] crc_length,crc_section,section_index,section_length;
 logic section_hit;
 logic [31:0] crc_work,crc_data,crc_word,crc_next;

 function automatic [31:0] crc_byte(input [31:0] crc,input [7:0] data);
  reg [31:0] c; integer k;
  begin
   c=crc^{24'd0,data};
   for(k=0;k<8;k=k+1)c=c[0] ? ((c>>1)^32'hedb88320) : (c>>1);
   crc_byte=c;
  end
 endfunction
 // No runtime packed-word writes or reset on payload storage.
 generate
  for(genvar n=0;n<18;n=n+1)begin:g_header
   always_ff @(posedge clk)
    if(rst_n && state==HWAIT && mem_rsp_valid && !mem_rsp_fault && hw==6'(n))
     header[n]<=mem_rsp_data;
  end
  for(genvar n=0;n<16;n=n+1)begin:g_directory
   always_ff @(posedge clk)
    if(rst_n && state==BWAIT && mem_rsp_valid && !mem_rsp_fault &&
       ptr<directory_end && ptr[5:2]==4'(n)) directory[n]<=mem_rsp_data;
  end
 endgenerate
 always_comb begin
  cmd_ready=state==IDLE;
  busy=state!=IDLE && state!=HOLD;
  rsp_valid=state==HOLD;
  mem_req_valid=state==HREQ || state==BREQ;
  mem_req_addr=base+(state==HREQ ? {24'd0,hw,2'b0} : ptr);
  mem_rsp_ready=state==HWAIT || state==BWAIT;
  directory_end=32'd256+({29'd0,header[6][2:0]}<<6);
  image_end={1'b0,base}+{1'b0,header[8]};
  workspace_end={1'b0,workspace_base}+{1'b0,header[10]};
  crc_next=crc_byte(crc_work,crc_data[7:0]);
  section_hit=0;section_index=0;section_length=0;
  for(integer n=0;n<5;n=n+1)begin
   if(seen[n] && ptr>=section_begin[n] && ptr<section_end[n])begin
    section_hit=1;section_index=3'(n);
    // ptr is word-aligned; a same-word end contributes only its byte offset.
    section_length=section_end[n][31:2]!=ptr[31:2] ?
     3'd4 : {1'b0,section_end[n][1:0]};
   end
  end
  section_name={directory[3],directory[2],directory[1],directory[0]};
  entry_begin=directory[4]; entry_bytes=directory[6];
  entry_end={1'b0,entry_begin}+{1'b0,entry_bytes};
  slot=0;slot_valid=0;
  if(section_name==128'h0000000000000000000000004154454d)begin slot=0;slot_valid=1;end
  if(header[5]==1 && section_name==128'h00000000004547414d495f59434147454c)begin slot=1;slot_valid=1;end
  if(header[5]==2)begin
   if(section_name==128'h00000000000000000053524f534e4554)begin slot=1;slot_valid=1;end
   if(section_name==128'h00000000534e4f495443555254534e49)begin slot=2;slot_valid=1;end
   if(section_name==128'h00000000000053455455424952545441)begin slot=3;slot_valid=1;end
   if(section_name==128'h0000000000000053544e4154534e4f43)begin slot=4;slot_valid=1;end
  end
  entry_bad=!slot_valid || directory[5]!=0 || directory[7]!=0 ||
    entry_begin[11:0]!=0 || entry_begin<previous_end || entry_begin<4096 ||
    entry_end>{1'b0,header[8]} || directory[9]!=4096;
  if(slot_valid)entry_bad=entry_bad || seen[slot];
  for(j=10;j<16;j=j+1)if(directory[j]!=0)entry_bad=1;
 end
 always_ff @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE; rsp_fault<=0; rsp_section_addr<=0; rsp_section_bytes<=0;
   rsp_model_id<=0; rsp_profile<=0; rsp_image_bytes<=0; rsp_workspace_bytes<=0;
   rsp_input_id<=0; rsp_output_id<=0; rsp_input_lut_id<=0;
   base<=0; model_capacity<=0; workspace_base<=0; workspace_capacity<=0;
   hw<=0; ptr<=0; di<=0; seen<=0; reserved_bad<=0;directory_bad<=0;
   crc_target<=0;crc_byte_index<=0;crc_length<=0;crc_section<=0;
   crc_work<=0;crc_data<=0;crc_word<=0;
   header_crc<=32'hffffffff; body_crc<=32'hffffffff; directory_crc<=32'hffffffff; previous_end<=4096;
   for(i=0;i<5;i=i+1)begin section_begin[i]<=0; section_end[i]<=0; section_crc[i]<=32'hffffffff; section_expected[i]<=0; end
  end else case(state)
   IDLE:if(cmd_valid)begin
    rsp_fault<=0; rsp_section_addr<=0; rsp_section_bytes<=0;
    base<=cmd_model_base; model_capacity<=cmd_model_capacity;
    workspace_base<=cmd_workspace_base; workspace_capacity<=cmd_workspace_capacity;
    hw<=0; di<=0; seen<=0; reserved_bad<=0;directory_bad<=0; previous_end<=4096;
    header_crc<=32'hffffffff; body_crc<=32'hffffffff; directory_crc<=32'hffffffff;
    for(i=0;i<5;i=i+1)begin section_begin[i]<=0; section_end[i]<=0; section_crc[i]<=32'hffffffff; section_expected[i]<=0; end
    if(cmd_model_base[11:0]!=0 || cmd_workspace_base[11:0]!=0 ||
       cmd_model_capacity<256 || cmd_workspace_capacity==0)begin rsp_fault<=BAD_COMMAND; state<=HOLD; end
    else state<=HREQ;
   end
   HREQ:if(mem_req_ready)state<=HWAIT;
   HWAIT:if(mem_rsp_valid)begin
    if(mem_rsp_fault)begin rsp_fault<=MEMORY_ERROR;state<=HOLD;end
    else begin
     crc_work<=header_crc;crc_data<=hw==14 ? 32'd0 : mem_rsp_data;
     crc_target<=0;crc_byte_index<=0;crc_length<=4;state<=CRC_BYTE;
     if(hw>=18 && mem_rsp_data!=0)reserved_bad<=1;
    end
   end
   HCHECK:begin
    rsp_model_id<=header[4];rsp_profile<=header[5];rsp_image_bytes<=header[8];rsp_workspace_bytes<=header[10];
    rsp_input_id<=header[12];rsp_output_id<=header[13];rsp_input_lut_id<=header[17];
    if(~header_crc!=header[14])begin rsp_fault<=BAD_CRC;state<=HOLD;end
    else if(header[0]!=32'h4b504941 || header[1]!=32'h00003347 || header[2]!=3 || header[3]!=256 ||
       header[9]!=0 || header[11]!=0 || header[15]!=0 || reserved_bad ||
       header[8]<4096 || header[8][11:0]!=0 || header[8]>model_capacity ||
       header[10]==0 || header[10][11:0]!=0 || header[10]>workspace_capacity ||
       image_end>33'h100000000 || workspace_end>33'h100000000 ||
       ({1'b0,base}<workspace_end && {1'b0,workspace_base}<image_end) ||
       !((header[4]==1 && header[5]==1 && header[6]==2 && header[12]==32'hffffffff && header[13]==32'hffffffff && header[17]==32'hffffffff) ||
         ((header[4]==1 || header[4]==3) && header[5]==2 && header[6]==5)))begin rsp_fault<=BAD_HEADER;state<=HOLD;end
    else begin ptr<=256;state<=BREQ;end
   end
   BREQ:if(mem_req_ready)state<=BWAIT;
   BWAIT:if(mem_rsp_valid)begin
    if(mem_rsp_fault)begin rsp_fault<=MEMORY_ERROR;state<=HOLD;end
    else begin
     crc_word<=mem_rsp_data;crc_data<=mem_rsp_data;crc_work<=body_crc;
     crc_target<=1;crc_byte_index<=0;crc_length<=4;state<=CRC_BYTE;
     crc_section<=section_index;
    end
   end
   CRC_BYTE:begin
    crc_work<=crc_next;crc_data<=crc_data>>8;
    if({1'b0,crc_byte_index}+3'd1<crc_length)crc_byte_index<=crc_byte_index+1'b1;
    else case(crc_target)
     0:begin
      header_crc<=crc_next;
      if(hw==63)state<=HCHECK;
      else begin hw<=hw+1'b1;state<=HREQ;end
     end
     1:begin
      body_crc<=crc_next;crc_data<=crc_word;crc_byte_index<=0;
      if(ptr<directory_end)begin crc_target<=2;crc_length<=4;crc_work<=directory_crc;end
      else if(section_hit)begin
       crc_target<=3;crc_length<=section_length;crc_work<=section_crc[section_index];
      end else state<=BADVANCE;
     end
     2:begin directory_crc<=crc_next;state<=BADVANCE;end
     3:begin
      for(integer n=0;n<5;n=n+1)
       if(crc_section==3'(n))section_crc[n]<=crc_next;
      state<=BADVANCE;
     end
    endcase
   end
   BADVANCE:begin
     ptr<=ptr+4;
     if(ptr<directory_end && ptr[5:2]==15)state<=DCHECK;
     else if(ptr+4==header[8])state<=FINAL;
     else state<=BREQ;
   end
   DCHECK:begin
    // Delay directory failure publication until its complete CRC is checked,
    // retaining CRC error priority even for a malformed early entry.
    if(entry_bad)directory_bad<=1;
    else begin
     previous_end<=entry_end[31:0];
     for(integer n=0;n<5;n=n+1)if(slot==3'(n))begin
      seen[n]<=1;
      section_begin[n]<=entry_begin;section_end[n]<=entry_end[31:0];section_expected[n]<=directory[8];
      rsp_section_addr[n*32+:32]<=base+entry_begin;rsp_section_bytes[n*32+:32]<=entry_bytes;
     end
    end
    if(di+1==header[6])state<=DCHECK_CRC;
    else begin di<=di+1'b1;state<=BREQ;end
   end
   DCHECK_CRC:begin
    if(~directory_crc!=header[7])begin rsp_fault<=BAD_CRC;state<=HOLD;end
    else if(directory_bad)begin rsp_fault<=BAD_DIRECTORY;state<=HOLD;end
    else state<=BREQ;
   end
   FINAL:begin
    state<=HOLD;
    if(~body_crc!=header[16])rsp_fault<=BAD_CRC;
    else if((header[5]==1 && seen!=5'b00011) || (header[5]==2 && seen!=5'b11111))rsp_fault<=BAD_DIRECTORY;
    else if(header[5]==2 && (rsp_section_bytes[38:32]!=0 || rsp_section_bytes[64+:32]==0 ||
      rsp_section_bytes[70:64]!=0 || header[12]>=(rsp_section_bytes[32+:32]>>7) ||
      header[13]>=(rsp_section_bytes[32+:32]>>7) ||
      (header[17]!=32'hffffffff && header[17]>=(rsp_section_bytes[32+:32]>>7))))rsp_fault<=BAD_DIRECTORY;
    for(i=0;i<5;i=i+1)if(seen[i] && ~section_crc[i]!=section_expected[i])rsp_fault<=BAD_CRC;
   end
   HOLD:if(rsp_ready)state<=IDLE;
   default:state<=IDLE;
  endcase
 end
endmodule
